# Module update optimization and parallelization review

24 October 2026. Source review of this checkout, informed by the 10k mass-move
captures under `workspace/profiles/all-move-parallel-10k-20261024/`.

Workload qualification: these captures issued orders to every horde, but
only about 62–69% of the tracked troops changed position per tick on average.
They do not establish performance with every soldier moving. The profiler
now requires an explicit per-soldier, per-tick all-moving acceptance check;
the static dependency findings below remain code-review findings.

**There are worthwhile optimization candidates, but the complete module update
loop cannot safely become a parallel loop. Extract read-only preparation from
selected module paths, then commit changes in a deterministic order.**

## What the measurements establish

Uber's instrumented same-direction movement run measured 56.98 ms per tick,
including 13.79 ms of hashing. Phase 3 averaged 9.85 ms, phase 4 9.95 ms and
phase 5 12.92 ms: 32.71 ms combined.

Those phase times are **not measurements of `UpdateModule::update()` alone**.
Every phase also services the path queue. Phase 5 additionally runs subsystem
work, destruction, victory/experience/skirmish updates. We have callback timers
for some of that work, but no per-module-class or AI-substage timings yet.
Consequently the class-level priorities below are code-supported candidates,
not measured claims that one class consumes a particular number of ms.

Even if the entire 32.71 ms could run perfectly on four threads, the optimistic
tick time would be about 32.45 ms, versus 56.98 today (1.76x). Actual gains
would be smaller because part of those phases remains serial and preparation,
dispatch and commit cost time. Module work alone does not eliminate the separate
queued-pathfinding burst identified in the movement capture.

## Current scheduling and dependencies

`GameLogic::runModules`, `engine/src/GameLogic/GameLogic.cpp:690`:

| Engine phase | Scheduler vectors | Relevant classes |
|---|---|---|
| 3 | first half of `updates[0]` | AIUpdate family, EmotionTrackerUpdate |
| 4 | second half of `updates[0]` | same vector; then sleeping migration |
| 5 | `updates[1]`, then `updates[2]` | HordeContain (PHASE_PHYSICS), normal-phase modules |
| 6 | `updates[3]` | WeaponStatusHelper and other final-phase work |

The phase-3 split uses the **current** vector size inside the loop. Newly woken
modules can enter active vectors while another module runs. `m_current` affects
the behavior of `friend_awakenUpdateModule`; migration uses ordered reverse
scan/swap removal, and scheduler state participates in state hashing.
Freezing a list of jobs up front can therefore change results even without a
data race. A lock around each complete update would largely serialize the
work while still risking changed execution order.

Concrete shared effects:

* `AIUpdateInterface::update` (`Module/AIUpdate.cpp:547`) can run scripts,
  weapon tracking, a state machine, turret logic, movement/path requests and
  status transitions. This is not an isolated arithmetic update of one object.
* `HordeContain::update` (`Object/Contain/HordeContainRuntime.cpp:114`) runs
  formation/member work and can issue commands to many other objects. A job per
  object would conflict with jobs for those members.
* `Object::reactToTransformChange` (`Object/Object.cpp:355`) updates pathfinder
  occupancy, contain callbacks, shroud/partition dirty state and trigger/off-map
  state. Computing a new position and applying it are different ownership tasks.
* `EmotionTrackerUpdate::update` (`Module/EmotionModules.cpp:579`) reads other
  objects and draws from the shared logic RNG. Its quarrel draw occurs even
  when the probability prevents a quarrel; removing the draw changes subsequent
  randomness.
* Pathfinder search/line memos, scratch, pools and reservation lists are shared
  (`AI/AIPathfind.h:1276` onward). A query that looks like a read is not
  automatically safe to run concurrently.
* `Common/JobSystem.h` already requires pure parallel bodies, disjoint output,
  fixed chunk partitioning and ordered combination. Logic RNG and object
  creation/destruction are forbidden in a worker body. Workers have no world
  TLS context; moving existing module methods onto them is not supported.

## Prioritized candidates

### 1. Horde member motion: strongest parallelization candidate

`Module/AIUpdateHordeMember.cpp:160` has a common path for ordinary formation
members. It computes direction/length, a candidate step, facing, deterministic
sin/cos and a transform. At 10k troops this provides many independent numerical
tasks **once their inputs have been separated from live world state**.

Proposed boundary:

1. On the simulation owner, select eligible members and capture position,
   goal, speed, owner state and other required inputs.
2. Batch only the pure numerical part onto the existing logic pool, with fixed
   chunks and one output slot per input. Preserve the numeric facade and
   operation/rounding order.
3. Commit in original scheduler order: model conditions, transforms, occupancy,
   triggers, shroud, path changes and wake decisions stay on the owner.
4. Keep path failure/repath, turrets, active state-machine side effects, portals,
   garrisons, physics and other exceptional cases on the serial path initially.

This needs more than a `parallelFor`: parent AI and earlier modules can change
member inputs during a phase. To preserve current results, prove the selected
inputs invariant or validate captured inputs before using a result and fall
back when stale. A phase-start snapshot without such validation is an Uber
semantic change, requiring explicit profile/replay compatibility handling and
new acceptance vectors rather than silently changing the current profile.

### 2. Formation slot preparation and allocation/lookup reduction

`HordeContain::runMemberPass`, `Object/Contain/HordeMemberPass.cpp:685`, copies
`m_members` into a vector for every pass and performs repeated `slotOf` lookups.
The slot index is stored in a `std::map` (`HordeContainCore.h:184`).

Lower-risk candidates, before parallel execution:

* Use a local inline-capacity snapshot with a general-size fallback, preserving
  the member iteration snapshot and order. Removing the snapshot is not an
  equivalent optimization: called code can have side effects.
* Reuse one validated slot lookup within the uninterrupted lookup/calculation
  segment, and introduce a pure helper for that known slot if profiling shows
  worthwhile cost. Do not cache through callbacks that can change membership.
* Batch read-only slot-coordinate preparation across hordes only after capturing
  stable inputs. Avoid a separate thread-pool dispatch for each small horde.

Two important traps are already visible in the code:

* Owner trig is **already hoisted once per pass** (`owner.computeTrig()`). This
  is not a new optimization opportunity.
* `getSlotWorldPos(member, ...)` is not interchangeable with the existing
  `getSlotWorldPosByIndex(...)`: the former uses `x/y`, banner handling and an
  inserting map lookup; the latter uses the separate `x2/y2` coordinates.
  A faster known-slot helper must preserve the member form's semantics.

These allocation/lookup changes should preserve both profiles when correctly
implemented. Their speedup is unmeasured and may be modest.

### 3. AI/emotion query preparation

Spatial candidate collection and distance/filter preparation can be run over
immutable data, then consumed in order by state machines. This aligns with the
existing U2 proposal in `UBER.md`; it is not evidence that whole module phases
already execute in parallel.

The Uber enemy-layer filter already exists in `EmotionModules.cpp`; do not
duplicate it. New parallel preparation needs stable ownership/position/filter
inputs and worker-local scratch. Keep RNG draws, target/weapon decisions,
commands, emotion transitions and their application ordered. A phase snapshot
can change which target wins compared with the live sequential view; treat
that distinction explicitly.

### 4. Transform notifications and helper-module work: measure first

Every actual member transform reaches `Object::reactToTransformChange`, including
pathfinder occupancy, dirty flags and script trigger work. It is worth counting
these calls and the cases that make no effective change before attempting to
reduce them. Occupancy/goal slots and trigger transitions are observable by
later updates, so deferring them wholesale until phase end is not a transparent
optimization.

Some helpers run every tick even when little changes. For example, contained
EmotionTrackerUpdate objects return immediately once their current emotion is
stopped; WeaponStatusHelper runs in phase 6. Instrument call counts, skip rates
and times before introducing event-driven wake logic. Changing next-call frames
or RNG draw cadence can change hashes and behavior even if a unit looks idle.

### 5. Broad parallel module execution: later architectural work

Horde ownership is a better unit of ownership than arbitrary objects, but it is
not enough by itself: attacks, fear, scripts, shared occupancy and target state
cross horde boundaries. A task per horde still needs immutable reads and ordered
output application. Spatial tiles/conflict graphs are larger projects and should
follow an extracted, tested read/compute/commit path, not replace the scheduler
as the first optimization.

## Recommended implementation order and acceptance

1. Add opt-in per-class/substage instrumentation: AI ordinary/member arms,
   HordeContain member pass, member numeric step versus path validation and
   commit, transform notifications, emotion scans, scheduler/migration overhead.
   The existing phase totals cannot rank these individually.
2. Implement and benchmark the allocation/lookup reductions whose semantics are
   local, preserving snapshot iteration and the two slot-coordinate forms.
3. Extract the common member-motion numerical kernel and first call it serially.
   Verify unchanged hashes before introducing worker execution.
4. Add coarse parallel batches for eligible inputs, with explicit invalidation
   and a serial fallback; then evaluate snapshot queries if those remain costly.

Use the existing parallel/crossing mass-move scenarios, zero warm-up and per-tick
hashes. For result-preserving changes compare the complete per-frame hash vectors,
not only the final chain, across serial/control and 1/4/16-thread runs. Include
turning, blocked paths, death/removal, formation changes, garrison/layer changes
and combat/emotion transitions; repeat/sanitizer checks must target races and
out-of-order effects. Keep Faithful acceptance vectors unchanged. For intentional
Uber semantic changes, update identity/compatibility and acceptance evidence
explicitly. Measure with instrumentation disabled as well.

This review changes documentation only. No optimization speedup is claimed and
no module update implementation has been parallelized by this review.
