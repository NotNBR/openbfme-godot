#!/usr/bin/env python3
"""Rebuild the studio branch: upstream's main, every open upstream pull request, then the studio's own commits.

bfme2-map-studio plays maps in this fork (its submodule native/openbfme-godot). The branch it uses, studio/main, is
not developed on directly; it is regenerated from three parts:

1. Open-BFME/openbfme-godot's main (the remote `upstream`);
2. every open pull request on upstream that is not a draft, merged in this order: the fork owner's own pull requests
   (the studio's work in review), then the others by number. --skip leaves pull requests out;
3. the studio's own commits: the commits on studio/main after its last merge, replayed on top (the camera, the
   cinematics, the extra archives, --no-shroud, ...). Commits with the trailer `Studio-Rebuild: generated` are this
   script's own (the README's open stop count) and are made again instead.

A pull request that upstream merges drops out of the list by itself, and its commits come in with upstream's main.

Conflicts: git rerere is turned on, so a conflict resolved once is resolved the same way next time (--train teaches
it the resolutions in the current studio/main's merges). A conflict rerere cannot resolve stops the script: resolve
it, `git add` the files, then run `python .git/studio-rebuild.py --resume` (the script's copy, as this file is not in
the half-rebuilt checkout; it commits the merge or pick for you).

The result is tagged studio-YYYY-MM-DD (a rebuild makes new commits; the tags keep every commit the studio's
submodule ever pointed at reachable) and studio/main moves to it. Nothing is pushed unless --push is given:

    python tools/studio/rebuild_branch.py              # rebuild studio/main
    python tools/studio/rebuild_branch.py --skip 60    # without pull request #60
    python tools/studio/rebuild_branch.py --resume     # after resolving a conflict
    python tools/studio/rebuild_branch.py --push       # also push studio/main and its tag to origin
"""
from __future__ import annotations

import argparse
import datetime
import json
import subprocess
import sys
from pathlib import Path

import shutil

# the clone the script is run in (it may run from its copy in the git directory, see --resume)
REPO = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], text=True, capture_output=True, check=True).stdout.strip())
UPSTREAM_REPO = "Open-BFME/openbfme-godot"
BRANCH = "studio/main"
WORK = "studio/rebuild"
TRAILER = "Studio-Rebuild: generated"


def git(*args: str, check: bool = True, capture: bool = True) -> str:
    r = subprocess.run(["git", *args], cwd=REPO, text=True, capture_output=capture, encoding="utf-8")
    if check and r.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed:\n{(r.stderr or r.stdout or '').strip()}")
    return (r.stdout or "").strip()


def ok(*args: str) -> bool:
    return subprocess.run(["git", *args], cwd=REPO, capture_output=True).returncode == 0


def git_dir() -> Path:
    return Path(git("rev-parse", "--absolute-git-dir"))


def state_file() -> Path:
    return git_dir() / "studio-rebuild.json"


def unmerged() -> list[str]:
    return [p for p in git("diff", "--name-only", "--diff-filter=U").splitlines() if p]


def open_pull_requests(skip: set[int]) -> list[dict]:
    r = subprocess.run(["gh", "pr", "list", "-R", UPSTREAM_REPO, "--state", "open", "--limit", "200",
                        "--json", "number,title,author,isDraft"], cwd=REPO, text=True, capture_output=True, encoding="utf-8")
    if r.returncode != 0:
        raise SystemExit(f"gh pr list failed (is the GitHub CLI installed and logged in?):\n{r.stderr.strip()}")
    owner = git("remote", "get-url", "origin").rstrip("/").removesuffix(".git").split("/")[-2].lower()
    prs = [p for p in json.loads(r.stdout) if not p["isDraft"] and p["number"] not in skip]
    prs.sort(key=lambda p: (p["author"]["login"].lower() != owner, p["number"]))
    return prs


def studio_commits(tip: str) -> list[str]:
    """The non-merge commits on `tip`'s first-parent line after its last merge, oldest first, without this script's own."""
    out = []
    for sha in git("rev-list", "--first-parent", tip).splitlines():
        if len(git("rev-list", "--parents", "-n", "1", sha).split()) > 2:
            break
        if TRAILER not in git("log", "-1", "--format=%B", sha):
            out.append(sha)
    return out[::-1]


def enable_rerere() -> None:
    git("config", "rerere.enabled", "true")
    git("config", "rerere.autoUpdate", "true")


def train() -> None:
    """Teach rerere the resolutions in studio/main's merges (each merge redone in a scratch worktree)."""
    enable_rerere()
    tmp = git_dir() / "studio-rebuild-train"
    if tmp.exists():
        git("worktree", "remove", "--force", str(tmp))
    merges = git("rev-list", "--merges", "--first-parent", f"upstream/main..{BRANCH}").splitlines()
    git("worktree", "add", "--detach", str(tmp), "upstream/main")
    try:
        taught = 0
        for m in merges[::-1]:
            first, second = git("rev-list", "--parents", "-n", "1", m).split()[1:3]
            run = lambda *a: subprocess.run(["git", *a], cwd=tmp, capture_output=True, text=True)
            run("checkout", "-q", "--detach", first)
            if run("merge", "--no-commit", "--no-ff", second).returncode != 0:
                run("rerere")
                run("checkout", m, "--", ".")
                run("rerere")
                taught += 1
            run("merge", "--abort")
            run("reset", "-q", "--hard")
        print(f"rerere: learned the resolutions of {taught} conflicted merge(s) in {BRANCH}")
    finally:
        git("worktree", "remove", "--force", str(tmp))


def finish_step() -> None:
    """Commit a merge or pick whose conflicts are resolved (rerere's or by hand)."""
    if unmerged():
        raise SystemExit("unresolved conflicts in:\n  " + "\n  ".join(unmerged()) + f"\nresolve them, `git add` them, then run: python {(git_dir() / 'studio-rebuild.py').as_posix()} --resume")
    gd = git_dir()
    if (gd / "MERGE_HEAD").exists():
        git("commit", "--no-edit", "-q")
    elif (gd / "CHERRY_PICK_HEAD").exists():
        if ok("diff", "--cached", "--quiet"):
            git("cherry-pick", "--skip")  # its changes are all in already
        else:
            git("-c", "core.editor=true", "cherry-pick", "--continue")


def in_progress() -> bool:
    gd = git_dir()
    return (gd / "MERGE_HEAD").exists() or (gd / "CHERRY_PICK_HEAD").exists()


def run_steps(state: dict) -> None:
    steps = state["steps"]
    while state["done"] < len(steps):
        step = steps[state["done"]]
        if step["kind"] == "merge":
            label = f"pull request #{step['pr']}: {step['title']}"
            r = subprocess.run(["git", "merge", "--no-ff", "-q", "-m", f"Merge upstream PR #{step['pr']}: {step['title']}", step["sha"]],
                               cwd=REPO, capture_output=True, text=True)
        else:
            label = f"studio commit {step['sha'][:8]}: {git('log', '-1', '--format=%s', step['sha'])}"
            r = subprocess.run(["git", "cherry-pick", "--empty=drop", step["sha"]], cwd=REPO, capture_output=True, text=True)
        if r.returncode != 0:
            state_file().write_text(json.dumps(state, indent=1), encoding="utf-8")
            if not in_progress():
                raise SystemExit(f"{label} failed:\n{(r.stderr or r.stdout).strip()}")
            if unmerged():
                print(f"conflict in {label}")
            finish_step()  # stops here when files are left to resolve
            label += " (its conflicts resolved by rerere)"
        print(f"  {label}")
        state["done"] += 1
        state_file().write_text(json.dumps(state, indent=1), encoding="utf-8")


def stop_count() -> None:
    tool = REPO / "tools" / "stops_count.py"
    if tool.exists():
        subprocess.run([sys.executable, str(tool), "--write"], cwd=REPO, check=True, capture_output=True)
        if not ok("diff", "--quiet", "README.md"):
            git("add", "README.md")
            git("commit", "-q", "-m", f"The README's open stop count after the rebuild (tools/stops_count.py)\n\n{TRAILER}")
            print("  the README's open stop count")


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8")  # pull request titles (a Windows console's code page lacks some of their letters)
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--skip", default="", help="pull request numbers to leave out, comma-separated")
    ap.add_argument("--resume", action="store_true", help="continue after resolving a conflict")
    ap.add_argument("--train", action="store_true", help="teach rerere the resolutions in the current studio/main, then stop")
    ap.add_argument("--push", action="store_true", help="push studio/main and its tag to origin when done")
    a = ap.parse_args()

    if a.train:
        git("fetch", "-q", "upstream", "main")
        train()
        return
    if a.resume:
        if not state_file().exists():
            raise SystemExit("nothing to resume")
        state = json.loads(state_file().read_text(encoding="utf-8"))
        finish_step()
        state["done"] += 1
    else:
        if git("status", "--porcelain", "--untracked-files=no"):
            raise SystemExit("the working tree has changes: commit or stash them first")
        enable_rerere()
        if Path(__file__).resolve() != (git_dir() / "studio-rebuild.py").resolve():
            shutil.copyfile(__file__, git_dir() / "studio-rebuild.py")
        print("fetching upstream and its pull requests...")
        git("fetch", "-q", "upstream", "main")
        skip = {int(n) for n in a.skip.split(",") if n.strip()}
        prs = open_pull_requests(skip)
        for p in prs:
            git("fetch", "-q", "upstream", f"+pull/{p['number']}/head:refs/pr/{p['number']}")
        tip = git("rev-parse", BRANCH) if ok("rev-parse", "--verify", "-q", BRANCH) else None
        steps = [{"kind": "merge", "pr": p["number"], "title": p["title"], "sha": git("rev-parse", f"refs/pr/{p['number']}")} for p in prs]
        steps += [{"kind": "pick", "sha": s} for s in (studio_commits(tip) if tip else [])]
        state = {"steps": steps, "done": 0, "previous": tip, "skip": sorted(skip)}
        git("switch", "-q", "-C", WORK, "upstream/main")
        print(f"on upstream/main {git('rev-parse', '--short', 'upstream/main')}: {len(prs)} pull request(s), "
              f"{len(steps) - len(prs)} studio commit(s)")
    run_steps(state)
    stop_count()

    stamp = datetime.date.today().isoformat()
    tag, n = f"studio-{stamp}", 2
    while ok("rev-parse", "--verify", "-q", f"refs/tags/{tag}"):
        tag, n = f"studio-{stamp}-{n}", n + 1
    git("tag", "-a", tag, "-m", f"studio/main rebuilt on upstream {git('rev-parse', '--short', 'upstream/main')}")
    tags = [tag]
    previous = state["previous"]
    if previous and not any(t.startswith("studio-") for t in git("tag", "--points-at", previous).splitlines()):
        tags.append(f"{tag}-previous")  # an untagged studio/main (one made by hand) stays reachable too
        git("tag", tags[-1], previous)
    git("switch", "-q", "-C", BRANCH)
    git("branch", "-q", "-D", WORK)
    state_file().unlink(missing_ok=True)
    print(f"{BRANCH} is now {git('rev-parse', '--short', 'HEAD')} (tag {', '.join(tags)})")
    if a.push:
        git("push", "-q", "--force-with-lease", "origin", BRANCH)
        git("push", "-q", "origin", *tags)
        print(f"pushed {BRANCH} and {', '.join(tags)} to origin")
    else:
        print(f"to publish: git push --force-with-lease origin {BRANCH} && git push origin {' '.join(tags)}")


if __name__ == "__main__":
    main()
