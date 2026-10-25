# Simulation and client profiling

`profile_simulation.py` implements the workflow in
`../../../docs/game-performance-and-profiling.md` §3, §7 and §9 using the
existing engine's Uber battle benchmark and real Godot client. Python 3.10+;
no Python packages required. Windows OS counters use ctypes. Other platforms
retain timing/log analysis, with unavailable OS counters recorded as null.

Build matching Release binaries first (`build.bat Release`). Import the Godot
project once (`godot --headless --editor --path godot --import --quit`). Native
tests must include `OPENBFME_UBER_FRAMES_DUMP` support. An older runner that
prints only aggregate timings fails validation rather than passing with no
frame measurements. All capture paths below must be new directories.

```powershell
python tools/sim/profile_simulation.py `
  --tests engine/build/openbfme_tests.exe `
  --godot C:/tools/Godot_v4.7.2-stable_win64_console.exe `
  --bfme2 C:/Games/BFME2 --rotwk C:/Games/RotWK `
  --out workspace/profiles/battle-baseline
```

The default matrix runs both Faithful and Uber, 10k/20k/40k requested troops,
one and all logical CPU threads, three repeats, 50 warm-up logic frames,
100 measured logic frames, and 20-second real-client battle windows. Runs are
sequential to avoid benchmark contention; profile order reverses on alternating
repeats. `--root` selects a different source/project checkout. `--kind logic`
or `--kind client` isolates a harness. Each process has a 900-second timeout.

For a short functional check:

```powershell
python tools/sim/profile_simulation.py --tests engine/build/openbfme_tests.exe `
  --godot C:/tools/Godot_v4.7.2-stable_win64_console.exe `
  --bfme2 C:/Games/BFME2 --rotwk C:/Games/RotWK `
  --out workspace/profiles/smoke --units 1000 --threads 4 `
  --repeats 1 --frames 30 --warmup 10 --seconds 10
```

## Measurements and boundaries

* **Native simulation:** six individual logic phases; logic, per-frame state
  hashing and combined tick mean/p50/p95/p99/max; over-budget counts including
  200 ms (the 5 Hz logic clock); actual pool size; hash dispatch/chunks; exact
  engine summary and hash chain; initial/sustained/minimum/end living troop
  census. Frame dumps round to 0.1 ms. Engine summaries have higher precision.
* **Whole client:** the engine's bounded battle-window FPS, p99, worst frame,
  logic advancement per wall second, start/end troop census, actual profile,
  adapter/window details; whole-play raw render intervals and thresholds;
  frame-count-weighted `GAME PERF` phase means for sync, pose evaluation,
  palette upload, HUD, main-thread CPU and logic handover where provided;
  worker waits, publication contention, client windows and hitches.
* **OS process observations (Windows):** process and per-thread CPU time, working set, private bytes,
  page faults and read/write/other operation and byte counters at 250 ms.
  CPU uses one logical core = 100%. Thread creation time guards against ID reuse;
  short-lived threads can be missed. Device I/O is included. Full-process and
  native measurement-flag windows are reported separately. A short native
  window can have too few observations; that measurement stays unavailable.
  Collector pass costs are recorded, and system CPU utilization (all cores,
  including other applications) provides context for background load. Pass
  costs do not measure the full slowdown caused by instrumentation.
* **Identity:** binary SHA-256/size/path (including the console launcher's
  companion executable), extension hashes, checkout commit and dirty status,
  hardware CPU identifier, OS, exact commands, relevant environment, options,
  renderer, resolution, pool size and all workload settings.

Native and client workloads are **different**: native uses eight human slots,
four Men versus four Mordor, seed 7, and a specified simulation-frame warm-up;
the existing real-client gate uses the game's auto lobby with an AI opponent
and a three-wall-second settle. Compare Faithful/Uber *within* each harness.
Troop survival and Uber rules can diverge. Requested troops are not sustained
troops. Render logs cover the whole playing session, while `UBER1` measures
only its battle window. No guessed alignment, no sum of overlapping phases,
and no conversion of sample observations into elapsed time.

The real-client gate also accepts `--uber1-profile-log=PATH`. The runner enables
it to buffer battle-only render intervals, non-blocking engine timing snapshots
and HUD timings, then write `battle.json` after timing ends. No per-frame file
writes occur in that window. `--no-client-detail` disables this extra collection
for an overhead control. Worker last-completed timings can repeat across render
frames; their render-sampled distributions are explicitly labelled and do not
count simulation ticks. State census and wait/window snapshots bracket the
same battle. Windows `_console.exe` paths resolve to the companion game `.exe`
when present, so resource counters and sampler PID target the game itself.

## Burst, steady battle and instrumentation controls

### All units receive move orders

Move captures now default to **strict all-unit movement validation**. A run
passes only when every soldier in the fixed spawned population changes XY by
more than 0.01 map units on **every measured tick**, and that population meets
the requested troop count. Pre-existing map troops are excluded. Missing,
dead, blocked or arrived soldiers count against acceptance; the denominator
never shrinks. Failed captures retain their timings for diagnosis but cannot
support an all-units-moving comparison. Use a specified `--warmup` to measure
sustained movement after the initial order; warm-up ticks are not measured.
No slow or stationary ticks are silently discarded from the chosen window.
`--move-spacing` sets initial horde spacing (default 75); increasing it can
reduce initial crowding, but does not establish movement. Parallel armies
start facing east to avoid an initial half-turn. The movement spawner now
subtracts the pre-existing troop census when satisfying the requested count.
Both settings and source identities are retained in the capture manifest.

`--movement-validation observe` permits partial-movement diagnostic captures,
with an explicit all-unit movement verdict still included in the report.
The current real-client probes cover eight horde roots, so client movement
captures cannot pass strict validation. Use `observe` for those captures;
they do not establish that every soldier moves. Earlier captures that merely
required some motion are not validated all-unit movement benchmarks.

Use `--scenario move --move-pattern parallel` for all spawned hordes marching
east with their relative spacing retained (a common offset, at most 2,000 map
units, bounded by the map edge). Use `--move-pattern crossing` for the two
armies moving through one another to their opposite starting positions. These
are normal move orders, not attack orders. Both armies are allied; native
slots remain human-controlled. Existing map actors can still affect troops.

```powershell
python tools/sim/profile_simulation.py --kind logic --scenario move `
  --move-pattern parallel --units 10000 --threads 4 --repeats 2 --frames 100 `
  --tests engine/build/openbfme_tests.exe `
  --bfme2 C:/Games/BFME2 --rotwk C:/Games/RotWK `
  --out workspace/profiles/all-move-parallel
```

Movement defaults to **zero warm-up ticks**, so the capture starts at the first
tick after the mass order. Command submission time is measured separately.
The report splits the first ten ticks from subsequent ticks and preserves
every frame's phase timings. Test-only wrappers time the existing installed
phase-work callbacks, including queued path service and collision processing.
They preserve call order and restore the original functions before teardown.
Their times are inclusive parts of phases, not extra costs; queued service
does not include every pathfinding call made elsewhere. No production
simulation implementation or scheduling rule is changed.

A fixed population of spawned living infantry/cavalry/monsters is selected before the
orders. Between measured ticks, outside the tick timer, the benchmark counts
how many changed XY by more than 0.01 map units. `motion` in the summary and
`moved_troops` / `tracked_troops` in the CSV distinguish a mass order from an
actually moving population. Congestion, obstacles, queued paths, death and
arrival can prevent some troops from moving. These probes add work between
ticks; OS window CPU therefore includes diagnostic work outside tick timing.

`--no-simulation-detail` disables callback timers for an overhead/hash control.
Movement position probes remain enabled. Use `--kind both --godot PATH` to
also run this in the real Godot client. Client movement has **no settle**;
its timing starts before submitting all move orders, so the first render
interval includes submission stalls. The detail log samples eight fixed horde
render poses using non-blocking reads. `presentation_motion` reports observed
unchanged presentation-clock/pose spans; legitimately stopped or blocked
units also have unchanged poses. Native troop-motion counts and each probe's
changes/displacement must be considered alongside those spans. Native and
client setups retain the differences documented above.

### Battle controls

Use `--kind logic --warmup 0` in a separate output directory for the initial
mass-order/pathfinding burst. Use the default 50-frame warm-up for sustained
combat. Increase `--frames` and `--repeats` for stable tails. Native frames run
as fast as possible; client frames include the actual logic clock. Keep other
applications quiet and use the same renderer (`--renderer`), resolution
(`--resolution`), asset directories and thread matrix. Shader caches and
user data are isolated per run. Cold load/compilation may therefore affect
startup; battle and process-lifetime measurements remain separate.

An optional native stack profiler can be launched with `--sampler-argv file.json`.
The file is an argv array, never shell code; `{pid}` and `{out}` are replaced.
For example, with the separately available Map Workshop `mw profile` tool:

```json
["C:/tools/mw.exe", "profile", "capture", "--pid", "{pid}", "--engine", "godot", "--seconds", "10", "--interval", "20", "--out", "{out}"]
```

For native runs the sampler starts when `OPENBFME_SAMPLER_FLAG` exists, after
warm-up; use enough measured frames to keep the process alive for collection.
For client runs it starts at process launch and can include loading: inspect
timestamped stacks; it is not automatically aligned to the battle window.
Use symbol/debug files matching the recorded binaries. The actual profile is
validated from engine output independently of the sampler's engine label.
This supports investigating pathfinding, spatial/target/taunt/collision work,
AI/modules, shroud, animation, rendering, I/O and synchronization using named
stacks, alongside the phase totals. Stack names/classification depend on the
chosen external profiler and available symbols. Repeat without sampling and
with a longer sampling interval to assess perturbation. Sampler failure marks
the run failed; all available output is kept.

Idle, camera motion, selection/orders, save/load/replay, network traffic and
multiplayer latency require their own scripted workloads or live captures;
this battle runner does not claim those measurements. GPU execution times,
hardware cache counters and event-to-display latency also need separate tools.

## Output and validation

`report.html`, `report.md`, `summary.json`, `manifest.json`, plus one folder
per run containing `engine.log`, `launch.json`, `resources.json`, native
`logic_frames.csv`, or client `frames.log`/`Options.ini` and isolated user data.
Reports are saved after every run. Existing output is never overwritten.
Nonzero exit, timeout, script error, wrong profile/thread count, missing or
incomplete native frame dump, or missing client success marker is a failure.
Ctrl+C kills the launched process, preserves partial data and exits 130.
Only the launched process is terminated; run a game executable directly rather
than a launcher that detaches children. No player Options.ini is changed.

Within-profile native hash guards compare repeats and thread counts. A mismatch
is prominently reported; it is not silently merged into a performance claim.
Matching chains check selected state only. Faithful and Uber chains are never
compared as a compatibility test. Cold cache/startup and short smoke tests are
not evidence for the documented 144 FPS/40k target.
Repeated-run medians/min/max are retained by harness/profile/unit/thread group;
hash mismatch makes the command exit nonzero.

Parser/lifecycle regression checks:

```powershell
python -m unittest discover -s tools/sim -p test_profile_simulation.py -v
```
