# combos

This branch of the fork holds no engine code: it holds the recipes that combine upstream OpenBFME with this fork's
own branches, and the tool that builds them.

## Branches

| Branch | What it is | Commit on it? |
|---|---|---|
| `main` | Open-BFME/openbfme-godot's `main`, mirrored | never |
| `feat/*`, `fix/*` | one change each, for an upstream pull request | yes |
| `studio/*` | one change each, kept in the fork (not for upstream) | yes |
| `combo/<name>` | generated from `recipes/<name>.txt` | never: it is rebuilt and force-pushed |
| `combos` | this branch: recipes and `combine.py` | yes |

A topic branch starts from the upstream commit it is written against and holds one change. Stacking one topic on
another is fine when it needs it (the recipe then lists the lower one first).

## Building a combo

    python combine.py studio            # combo/studio from recipes/studio.txt
    python combine.py studio --push     # and push it with its tag

To change what is in a combo, edit its recipe, commit it here, and build again. To fix something in a combo, fix it on
the topic branch and build again.

Conflicts: `git rerere` remembers how a conflict between two topics was resolved and replays it on every later build.
When it cannot, the build stops in `<git dir>/combo-build`: resolve there, `git add`, then `python combine.py --resume`.

Every build is tagged `combo/<name>/<date>`, so a commit that bfme2-map-studio's submodule pinned stays reachable
after later builds replace the branch.

## Upstream moves

Bring a topic forward by merging the new upstream into it, or let it go when upstream merges its pull request; then move
the recipe's `base` and build again. A topic that only conflicts textually with the new base can stay as it is: resolve
the conflict once during the build and rerere keeps it.
