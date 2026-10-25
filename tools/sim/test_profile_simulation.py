"""Parsing and capture-lifecycle checks; no retail assets or Godot required."""
import importlib.util
import json
from pathlib import Path
import os
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("profile_simulation", Path(__file__).with_name("profile_simulation.py"))
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class ProfilingTests(unittest.TestCase):
    def test_client_full_army_motion_rejects_gaps_and_stationary_soldiers(self):
        motion = dict(motion_begin=dict(frame=20, tracked_troops=4000),
                      motion_rows=[dict(frame=f, tracked_troops=4000, moved_troops=4000, skipped_ticks=0) for f in (21, 22)],
                      motion_end=dict(frame=22, tracked_troops=4000))
        self.assertTrue(p.validate_client_all_moving(dict(army_motion=motion), 4000)["passed"])
        for field, value in [("moved_troops", 3999), ("tracked_troops", 3999), ("skipped_ticks", 1), ("frame", 23)]:
            changed = json.loads(json.dumps(motion))
            changed["motion_rows"][1][field] = value
            self.assertFalse(p.validate_client_all_moving(dict(army_motion=changed), 4000)["passed"])
        self.assertFalse(p.validate_client_all_moving({}, 4000)["passed"])
        self.assertFalse(p.validate_client_all_moving(dict(army_motion=motion), 4001)["passed"])

    def test_all_moving_requires_every_soldier_on_every_tick(self):
        header = ("workload: move; commands 1.000 ms; tracked troops 1000\n"
                  "motion population: fixed spawned troops; missing or dead count as stationary\n")
        frames = "".join(f"frame {i}: logic 6.0 ms (phases 1 / 1 / 1 / 1 / 1 / 1) hash 1.0 ms\n" for i in range(2))
        complete = "motion 0: 1000 of 1000 troops changed XY\nmotion 1: 1000 of 1000 troops changed XY\n"
        def check(motion, prefix=header, population=1000):
            return p.validate_all_moving(p.parse_logic(prefix + frames + motion), 2, population)
        self.assertTrue(check(complete)["passed"])
        for bad in [complete.replace("motion 1: 1000", "motion 1: 999"),
                    complete.replace("motion 1: 1000 of 1000", "motion 1: 999 of 999"),
                    complete.splitlines()[0] + "\n", complete + complete.splitlines()[0] + "\n",
                    complete.replace("motion 1:", "motion 5:")]:
            with self.subTest(motion=bad):
                self.assertFalse(check(bad)["passed"])
        self.assertFalse(check(complete, population=1001)["passed"])
        self.assertFalse(check(complete, prefix=header.splitlines()[0] + "\n")["passed"])
        self.assertEqual(check(complete.replace("motion 1: 1000", "motion 1: 999"))["failed_ticks"], [1])

    def test_mass_move_work_and_actual_motion(self):
        r = p.parse_logic("info: uber bench uber 1000 troops: 4 logic threads, 1 frames: TICK hash chain ab123456\n"
                          "workload: move; commands 12.345 ms; tracked troops 1020\n"
                          "frame 0: logic 60.0 ms (phases 1.0 / 30.0 / 9.0 / 8.0 / 7.0 / 5.0) hash 2.0 ms\n"
                          "work 0 pathfinderQueue 10.2000 ms\nwork 0 partitionAndCollision 25.5000 ms\n"
                          "motion 0: 900 of 1020 troops changed XY\n")
        self.assertEqual(r["scenario"], "move")
        self.assertEqual(r["command_ms"], 12.345)
        self.assertEqual(r["motion"]["max_moved"], 900)
        self.assertEqual(r["metrics"]["work_partitionAndCollision_ms"]["mean_ms"], 25.5)
        self.assertEqual(r["frames"][0]["moved_troops"], 900)

    def test_fixed_pose_freezes_and_clock_holds(self):
        rows = []
        for stamp, x, alpha, held in [(0, 1, 1, 10), (250000, 1, 1, 11), (500000, 1, 1, 12), (750000, 2, .5, 12)]:
            rows.append(dict(elapsed_us=stamp, logic_frame=3, timings=dict(presented_alpha=alpha, held_presentations=held),
                             poses=[dict(id=7, ok=True, x=x, y=5)]))
        r = p.presentation_motion(rows)
        self.assertEqual(r["longest_unchanged_presentation_clock_ms"], 500)
        self.assertEqual(r["held_presentation_delta"], 2)
        self.assertEqual(r["fixed_pose_probes"]["7"]["changes"], 1)
        self.assertEqual(r["fixed_pose_probes"]["7"]["longest_unchanged_ms"], 500)

    def test_tail_distribution_and_budget(self):
        d = p.distribution([1] * 98 + [20, 250])
        self.assertEqual(d["p99_ms"], 20)
        self.assertEqual(d["over_ms"]["200"], 1)
        self.assertIsNone(p.distribution([]))

    def test_logic_profile_phases_hash_and_missing_dump(self):
        log = ("info: uber bench faithful 1000 troops: 4 logic threads, 2 frames: TICK hash chain abcdef01\n"
               "frame 0: logic 21.0 ms (phases 1.0 / 2.0 / 3.0 / 4.0 / 5.0 / 6.0) hash 2.0 ms\n"
               "frame 1: logic 42.0 ms (phases 2.0 / 4.0 / 6.0 / 8.0 / 10.0 / 12.0) hash 4.0 ms\n")
        r = p.parse_logic(log)
        self.assertEqual(r["profile"], "faithful")
        self.assertEqual(r["actual_threads"], 4)
        self.assertEqual(r["metrics"]["tick_ms"]["mean_ms"], 34.5)
        self.assertEqual(r["metrics"]["phase6_ms"]["max_ms"], 12)
        self.assertEqual(r["hash_chain"], "abcdef01")
        self.assertIsNone(p.parse_logic("SKIP missing install")["metrics"]["tick_ms"])

    def test_client_window_weighting_and_battle_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / "frames.log"
            f.write_text("1 10000\n1 20000\n4 50000\nbad row\n")
            r = p.parse_client("GAME PERF frames=10 fps=100 | mean sync_ms=2.0\n"
                               "GAME PERF frames=30 fps=100 | mean sync_ms=6.0\n"
                               "UBER1 battle 1000: profile uber, living troops 1100 at the window's start, 1050 at its end; average 50.0 fps (20.0 ms), 1% low 20 fps (p99 50.0 ms), worst frame 60.0 ms; logic 4.9 frames/s\n", f)
            self.assertEqual(r["whole_play_phase_means_ms"]["sync_ms"], 5)
            self.assertEqual(r["battle"]["logic_hz"], 4.9)
            self.assertEqual(r["profile"], "uber")
            self.assertEqual(r["malformed_frame_rows"], 1)
            self.assertEqual(r["whole_play_render"]["n"], 3)

    def test_battle_snapshots_keep_counters_separate_and_unavailable_null(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "battle.json").write_text(json.dumps({"profile": "uber", "rows": [
                {"interval_ms": 10, "timings": {"worker_frame_ms": 8, "main_cpu_ms": -1, "logic_wait_ms": 50}},
                {"interval_ms": 20, "timings": {"worker_frame_ms": 8, "main_cpu_ms": -1, "logic_wait_ms": 60}}],
                "waits_before": {"logic_wait_ms": 50}, "waits_after": {"logic_wait_ms": 60}}))
            r = p.parse_client("", root / "frames.log")
            self.assertEqual(r["battle_counter_deltas"]["logic_wait_ms"], 10)
            self.assertIsNone(r["battle_timing_distributions"]["timings.main_cpu_ms"])
            self.assertNotIn("timings.logic_wait_ms", r["battle_timing_distributions"])
            self.assertEqual(r["battle_render"]["p99_ms"], 20)

    def test_process_timeout_keeps_partial_log_and_counters(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            r = p.run_process([sys.executable, "-u", "-c", "import time; print('partial'); time.sleep(10)"],
                              os.environ.copy(), folder, .25, .05)
            self.assertEqual(r["status"], "timeout")
            self.assertIn("partial", (folder / "engine.log").read_text())
            samples = json.loads((folder / "resources.json").read_text())
            self.assertGreaterEqual(len(samples), 2)
            if os.name == "nt":
                self.assertIn("cpu_s", samples[0])
                self.assertIn("private_bytes", samples[0])
                self.assertIn("thread_cpu_s", samples[0])

    def test_script_error_stops_empty_client(self):
        with tempfile.TemporaryDirectory() as tmp:
            r = p.run_process([sys.executable, "-u", "-c", "import time; print('SCRIPT ERROR: bad'); time.sleep(10)"],
                              os.environ.copy(), Path(tmp), 3, .05)
            self.assertEqual(r["status"], "failed")
            self.assertLess(r["elapsed_s"], 3)

    def test_reports_flag_within_profile_hash_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            native = p.parse_logic("info: uber bench faithful 1000 troops: 1 logic threads, 1 frames: TICK hash chain 11111111\n"
                                   "frame 0: logic 6.0 ms (phases 1.0 / 1.0 / 1.0 / 1.0 / 1.0 / 1.0) hash 1.0 ms")
            run = dict(name="logic-faithful", kind="logic", requested_profile="faithful", units=1000,
                       threads=1, status="completed", logic=native)
            other = dict(run, name="logic-faithful-t4", threads=4,
                         logic=dict(native, hash_chain="22222222"))
            p.report(Path(tmp), [run, other], {})
            result = json.loads((Path(tmp) / "summary.json").read_text())
            self.assertFalse(result["hash_guards"][0]["selected_state_consistent"])
            self.assertIn("WARNING", (Path(tmp) / "report.md").read_text())
            self.assertIn("<table>", (Path(tmp) / "report.html").read_text())


if __name__ == "__main__":
    unittest.main()
