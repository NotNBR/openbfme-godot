# Collision module caches

Public base: `87579746` (upstream main, "Sync the rebuild: 2026-10-28").

## What was slow

An army ordered to one point piles up there. Allied soldiers overlap, as in retail
(S-781), so `AIWorld::processCollisions` finds a contact pair for nearly every two
soldiers in the pile. That is 4,000 to 5,000 pairs a frame for 24 hordes.
Faithful mode applies every pair, both ways, on the logic thread. Each
application ran two lookups that did not need to be repeated:

- `SquishCollide::onCollide` calls `PhysicsBehavior::find`, which did a
  `dynamic_cast` on every module of the object.
- `HordeMemberCollide::onCollide` casts the horde's AI to `HordeAIUpdate`, in
  `hordeAiOf` (Uber's `ObjectCollide::pairFacts` does the same).

## The change

`Object::rebuildCollideModules` already keeps the collide list and the
attribute pool. It runs at the end of `buildModules` and after
`friend_replaceModule`, which is the only later change to the module list (the
horde formation swap). It now also keeps:

- the first `PhysicsBehavior`, which is what the scan returned;
- `m_ai` as a `HordeAIUpdate`. `m_ai` is set only in `buildModules`, and the
  formation swap replaces the contain, not the AI.

`~Object` switches both caches off before it deletes the modules, so a lookup
from a module's destructor scans what is left, as before.
`AIUpdateInterface`'s locomotor host had its own lazy copy of the physics
module, written from the job threads in Uber's facts pass. It now asks
`PhysicsBehavior::find`. All its callers run during frames, after the
object's modules are built.

No answer changes, so no stop and no simulation rule changes.

## Checks

- **Hash identity.** Every frame of the following hashes as on the base build:
  - `perf1: the big battle (400 frames) and a 4-player AI skirmish ... (6000 frames)`
    against the stored `big_battle_400.hashes` and `skirmish4_6000.hashes`;
  - `uber1: the Uber battle hashes as its pin vector ...` with 1, 4 and 16 threads;
  - the new `perf1: the allied blob (300 frames)`. Its reference
    `tests/data/perf1/allied_blob_300.hashes` was measured on the base build, in
    its own commit, before the change.

  The base build passed the first two against their stored vectors on the same
  machine.
- **The caches themselves.**
  - `perf1: every template with a PhysicsBehavior or an AI ...` creates 1,547
    objects (1,297 with a PhysicsBehavior, 163 horde AIs). For each, the kept
    module and the kept cast must equal the scan and the cast.
  - `perf1: a formation swap ...` toggles a tower shield horde's formation there
    and back, and checks the horde object and its members after each swap.

## Timing

Logic time per frame (thread CPU of the logic thread), Release build. Each
scenario ran alternately on the base build and the changed build, three times
for the blob and twice for the battle:

| scenario | base mean | changed mean | base p95 | changed p95 |
|---|---|---|---|---|
| allied blob, 24 hordes, 300 frames | 5.40 ms | 1.69 ms | 7.8 ms | 3.4 ms |
| big battle, 400 frames | 10.1 ms | 8.1 ms | 16.2 ms | 13.4 ms |

The blob averages 4,218 contact pairs a frame, with a peak of 5,134. The hash
chains of the timed runs were equal on both builds: blob `4904f2be`, battle
`bf518661`.

Measured on Windows 11, AMD Ryzen 7 7800X3D, llvm-mingw clang 23.1.3, CMake 3.29,
Ninja, `CMAKE_BUILD_TYPE=Release`, with retail RotWK 2.01 and BFME2 1.06 mounts
that pass the archive policy.

## Reproduce

```sh
cmake -S engine -B engine/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DOPENBFME_BUILD_TESTS=ON
cmake --build engine/build --target openbfme_tests
cd engine/build
# ROTWK_INSTALL / BFME2_INSTALL: unmodified retail installs
./openbfme_tests -tc="perf1: the allied blob*,perf1: the big battle*,uber1: the Uber battle*,perf1: every template*,perf1: a formation swap*"
./openbfme_tests -tc="perf1 bench: allied blob*,perf1 bench: big battle*" --no-skip
```

For the base timing, build `970127f3` (the benchmark commit, before the change)
the same way.
