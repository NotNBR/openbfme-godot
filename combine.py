#!/usr/bin/env python3
"""Build a combo branch: an upstream base with chosen topic branches merged in, in recipe order.

    python combine.py studio              # build combo/studio from recipes/studio.txt
    python combine.py studio --push       # also push combo/studio and its tag to origin
    python combine.py --resume            # after resolving a conflict in the build folder
    python combine.py --abort             # give up a stopped build

A recipe (recipes/<name>.txt) is a `base <ref>` line, then one branch per line; `#` starts a comment. A branch is taken
from its local ref when there is one, else from origin/<branch>. The build runs in its own worktree in the git
directory, so no checkout (the studio's submodule, a topic worktree) changes under you.

combo/<name> is generated: never commit on it. A fix goes on its topic branch, then the combo is built again. git rerere
is turned on, so a conflict between two topics is resolved once and replayed on every later build. Each build is tagged
combo/<name>/<date>, so every commit a consumer (the studio's submodule) ever pinned stays reachable.
"""
from __future__ import annotations

import argparse
import datetime
import json
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def git(*args: str, cwd: Path = HERE, check: bool = True) -> str:
    r = subprocess.run(["git", *args], cwd=cwd, text=True, capture_output=True, encoding="utf-8")
    if check and r.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed:\n{(r.stderr or r.stdout).strip()}")
    return r.stdout.strip()


def ok(*args: str, cwd: Path = HERE) -> bool:
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True).returncode == 0


COMMON = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir"))
BUILD = COMMON / "combo-build"
STATE = COMMON / "combo-build.json"


def read_recipe(name: str) -> tuple[str, list[str]]:
    path = HERE / "recipes" / f"{name}.txt"
    if not path.exists():
        raise SystemExit(f"no recipe {path}")
    base, branches = None, []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("base "):
            base = line[5:].strip()
        else:
            branches.append(line)
    if base is None:
        raise SystemExit(f"{path}: the recipe needs a `base <ref>` line")
    return base, branches


def resolve(branch: str) -> str:
    """The local branch when there is one (warning when origin differs), else origin's."""
    local, remote = f"refs/heads/{branch}", f"refs/remotes/origin/{branch}"
    if ok("rev-parse", "--verify", "-q", local):
        if ok("rev-parse", "--verify", "-q", remote) and git("rev-parse", local) != git("rev-parse", remote):
            ahead = git("rev-list", "--count", f"{remote}..{local}")
            behind = git("rev-list", "--count", f"{local}..{remote}")
            print(f"  note: {branch} is {ahead} ahead / {behind} behind origin; using the local branch")
        return git("rev-parse", local)
    if ok("rev-parse", "--verify", "-q", remote):
        return git("rev-parse", remote)
    raise SystemExit(f"no branch {branch} (local or on origin)")


def unmerged() -> list[str]:
    return [p for p in git("diff", "--name-only", "--diff-filter=U", cwd=BUILD).splitlines() if p]


def save(state: dict) -> None:
    STATE.write_text(json.dumps(state, indent=1), encoding="utf-8")


def stop_for_conflict(state: dict, branch: str) -> None:
    save(state)
    raise SystemExit(f"conflict merging {branch}, in:\n  " + "\n  ".join(unmerged()) +
                     f"\nresolve it in {BUILD}, `git add` the files, then: python {HERE / 'combine.py'} --resume"
                     f"\n(or python {HERE / 'combine.py'} --abort)")


def merge_all(state: dict) -> None:
    while state["done"] < len(state["steps"]):
        branch, sha = state["steps"][state["done"]]
        message = f"Combine {branch} into combo/{state['name']}"
        r = subprocess.run(["git", "merge", "--no-ff", "-q", "-m", message, sha], cwd=BUILD, capture_output=True, text=True)
        if r.returncode != 0:
            if not Path(git("rev-parse", "--path-format=absolute", "--git-path", "MERGE_HEAD", cwd=BUILD)).exists():
                save(state)
                raise SystemExit(f"merging {branch} failed:\n{(r.stderr or r.stdout).strip()}")
            if unmerged():
                stop_for_conflict(state, branch)
            git("commit", "-q", "--no-edit", cwd=BUILD)
            print(f"  {branch}  (conflicts replayed by rerere)")
        else:
            print(f"  {branch}")
        state["done"] += 1
        save(state)


def finish(state: dict, push: bool) -> None:
    name = state["name"]
    combo = f"combo/{name}"
    head = git("rev-parse", "HEAD", cwd=BUILD)
    stamp = datetime.date.today().isoformat()
    tag, n = f"{combo}/{stamp}", 2
    while ok("rev-parse", "--verify", "-q", f"refs/tags/{tag}"):
        tag, n = f"{combo}/{stamp}-{n}", n + 1
    lines = [f"{combo} built on {state['base']} ({state['base_sha'][:8]})", ""]
    lines += [f"{b} {s[:8]}" for b, s in state["steps"]]
    git("tag", "-a", tag, "-m", "\n".join(lines), head)
    remove_build()
    git("branch", "-f", combo, head)
    STATE.unlink(missing_ok=True)
    print(f"{combo} is now {head[:8]} (tag {tag})")
    if push:
        git("push", "-q", "--force-with-lease", "origin", combo)
        git("push", "-q", "origin", tag)
        print(f"pushed {combo} and {tag} to origin")
    else:
        print(f"to publish: git push --force-with-lease origin {combo} && git push origin {tag}")


def remove_build() -> None:
    if BUILD.exists():
        git("worktree", "remove", "--force", str(BUILD))
    git("worktree", "prune")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("recipe", nargs="?", help="the recipe's name (recipes/<name>.txt)")
    ap.add_argument("--push", action="store_true", help="push the combo branch and its tag to origin when done")
    ap.add_argument("--resume", action="store_true", help="continue after resolving a conflict")
    ap.add_argument("--abort", action="store_true", help="give up a stopped build")
    a = ap.parse_args()

    if a.abort:
        remove_build()
        STATE.unlink(missing_ok=True)
        print("build abandoned")
        return
    if a.resume:
        if not STATE.exists():
            raise SystemExit("nothing to resume")
        state = json.loads(STATE.read_text(encoding="utf-8"))
        if unmerged():
            stop_for_conflict(state, state["steps"][state["done"]][0])
        git("commit", "-q", "--no-edit", cwd=BUILD)
        print(f"  {state['steps'][state['done']][0]}  (resolved by hand)")
        state["done"] += 1
        push = a.push or state.get("push", False)
    else:
        if not a.recipe:
            ap.error("name a recipe, or give --resume / --abort")
        if STATE.exists():
            raise SystemExit(f"a build is stopped: python {HERE / 'combine.py'} --resume, or --abort")
        git("config", "rerere.enabled", "true")
        git("config", "rerere.autoUpdate", "true")
        print("fetching upstream and origin...")
        git("fetch", "-q", "upstream")
        git("fetch", "-q", "--prune", "origin")
        base, branches = read_recipe(a.recipe)
        base_sha = git("rev-parse", "--verify", f"{base}^{{commit}}")
        state = {"name": a.recipe, "base": base, "base_sha": base_sha, "steps": [[b, resolve(b)] for b in branches],
                 "done": 0, "push": a.push}
        remove_build()
        git("worktree", "add", "-q", "--detach", str(BUILD), base_sha)
        print(f"combo/{a.recipe} on {base} {base_sha[:8]}:")
        push = a.push
    merge_all(state)
    finish(state, push)


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    main()
