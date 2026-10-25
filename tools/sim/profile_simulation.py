#!/usr/bin/env python3
"""Repeatable native logic + rendered-client profiling. Python 3.10+, no packages.

See profile_simulation.md. No simulation rules or player options are modified.
"""
from __future__ import annotations

import argparse
import csv
import ctypes
import hashlib
import html
import json
import math
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone


MAP = "maps/map mp fall back 8p/map mp fall back 8p.map"
NUMBER = r"[0-9]+(?:\.[0-9]+)?"
FRAME = re.compile(r"frame (\d+): logic (" + NUMBER + r") ms \(phases (.*?)\) hash (" + NUMBER + r") ms")


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False), encoding="utf-8")


def identity(path):
    path = Path(path).resolve()
    if not path.is_file():
        return {"path": str(path), "available": False}
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return {"path": str(path), "bytes": path.stat().st_size, "sha256": h.hexdigest()}


def git_identity(root):
    def git(*args):
        p = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)
        return p.stdout.strip() if p.returncode == 0 else None
    return {"root": str(root), "commit": git("rev-parse", "HEAD"), "status": git("status", "--short")}


def distribution(values):
    if not values:
        return None
    s = sorted(values)
    # Nearest-rank percentiles; fixed convention shared by every run in this tool.
    def percentile(p):
        return s[max(0, math.ceil(len(s) * p) - 1)]
    return {"n": len(s), "mean_ms": statistics.mean(s), "p50_ms": percentile(.5),
            "p95_ms": percentile(.95), "p99_ms": percentile(.99), "max_ms": s[-1],
            "over_ms": {str(t): sum(x > t for x in s) for t in (6.944, 16.667, 33.333, 50, 100, 200)}}


def parse_logic(text):
    rows = []
    for m in FRAME.finditer(text):
        phases = [float(x.strip()) for x in m[3].split("/")]
        if len(phases) != 6:
            continue
        logic, state_hash = float(m[2]), float(m[4])
        rows.append(dict(frame=int(m[1]), logic_ms=logic, hash_ms=state_hash,
                         tick_ms=logic + state_hash, **{f"phase{i+1}_ms": x for i, x in enumerate(phases)}))
    summary = re.search(r"info: uber bench (\w+) (\d+) troops: (.*)", text)
    result = {"frames": rows, "profile": summary[1] if summary else None,
              "requested_troops": int(summary[2]) if summary else None,
              "engine_summary": summary[0] if summary else None}
    result["metrics"] = {k: distribution([r[k] for r in rows]) for k in
                         ["tick_ms", "logic_ms", "hash_ms"] + [f"phase{i}_ms" for i in range(1, 7)]}
    chain = re.search(r"hash chain ([0-9a-fA-F]+)", text)
    result["hash_chain"] = chain[1] if chain else None
    threads = re.search(r"(\d+) logic threads, (\d+) frames: TICK", text)
    result["actual_threads"] = int(threads[1]) if threads else None
    result["reported_frames"] = int(threads[2]) if threads else None
    workload = re.search(r"workload: (\w+); commands ([0-9.]+) ms; tracked troops (\d+)", text)
    result["scenario"] = workload[1] if workload else "battle"
    result["command_ms"] = float(workload[2]) if workload else None
    warmup = re.search(r"(\d+) warm-up frames", text)
    result["actual_warmup"] = int(warmup[1]) if warmup else None
    result["spawned_motion_population"] = "motion population: fixed spawned troops; missing or dead count as stationary" in text
    result["move_field"] = "open" if "movement field: open" in text else "retail"
    result["path_pool"] = {m[1]: dict(capacity=int(m[2]), free=int(m[3]), exhausted=bool(int(m[4])))
                           for m in re.finditer(r"path pool after (orders|warmup): capacity (\d+) free (\d+) exhausted ([01])", text)}
    by_frame = {r["frame"]: r for r in rows}
    work_names = set()
    for m in re.finditer(r"work (\d+) (\w+) ([0-9.]+) ms", text):
        key = "work_" + m[2] + "_ms"
        work_names.add(key)
        if int(m[1]) in by_frame:
            by_frame[int(m[1])][key] = float(m[3])
    for key in sorted(work_names):
        result["metrics"][key] = distribution([r[key] for r in rows if key in r])
    motion_samples = []
    for m in re.finditer(r"motion (\d+): (\d+) of (\d+) troops changed XY", text):
        if int(m[1]) in by_frame:
            by_frame[int(m[1])].update(moved_troops=int(m[2]), tracked_troops=int(m[3]))
            motion_samples.append((int(m[1]), int(m[2]), int(m[3])))
    moved = [sample[1] for sample in motion_samples]
    result["motion"] = dict(tracked_troops=int(workload[3]), sampled_ticks=len(moved),
                            mean_moved=statistics.mean(moved), min_moved=min(moved), max_moved=max(moved),
                            zero_motion_ticks=sum(n == 0 for n in moved)) if moved and workload else None
    if result["motion"]:
        result["motion"].update(
            all_moving_ticks=sum(n == total and total > 0 for _, n, total in motion_samples),
            frame_sequence_complete=[f for f, _, _ in motion_samples] == [r["frame"] for r in rows],
            population_consistent=all(total == int(workload[3]) for _, _, total in motion_samples))
    result["time_windows"] = {"first_10_ticks": distribution([r["tick_ms"] for r in rows[:10]]),
                              "after_first_10_ticks": distribution([r["tick_ms"] for r in rows[10:]])}
    return result


def validate_all_moving(native, expected_frames, requested_troops):
    """Every soldier in the fixed population must move on every measured tick.

    No tick selection, denominator reduction or allowance for death/arrival.
    This is a workload acceptance check, independent of timing validity.
    """
    motion = native.get("motion") or {}
    rows = native.get("frames", [])
    tracked = motion.get("tracked_troops", 0)
    failed = [r["frame"] for r in rows
              if r.get("tracked_troops") != tracked or tracked <= 0
              or r.get("moved_troops") != tracked]
    passed = (native.get("spawned_motion_population") is True and tracked >= requested_troops and len(rows) == expected_frames
              and motion.get("sampled_ticks") == expected_frames
              and motion.get("frame_sequence_complete") is True
              and motion.get("population_consistent") is True and not failed
              and [r["frame"] for r in rows] == list(range(expected_frames)))
    return dict(passed=passed, requirement="every fixed spawned troop changes XY > 0.01 on every measured tick",
                tracked_troops=tracked, requested_troops=requested_troops,
                measured_ticks=len(rows), all_moving_ticks=motion.get("all_moving_ticks", 0),
                failed_ticks=failed,
                reason=None if passed else "not every requested troop was verified moving on every measured tick")


def parse_client(text, frames_path):
    rows, malformed = [], 0
    if frames_path.exists():
        for line in frames_path.read_text(encoding="utf-8").splitlines():
            try:
                logic, us = map(int, line.split())
                if us <= 0:
                    raise ValueError("nonpositive interval")
                rows.append({"logic_frame": logic, "interval_ms": us / 1000})
            except ValueError:
                malformed += 1
    # GAME PERF windows cover the whole play session; never claim battle alignment.
    weights, sums = 0, {}
    for m in re.finditer(r"GAME PERF frames=(\d+)[^\n]*?\| mean([^\n]*)", text):
        n = int(m[1])
        weights += n
        for key, value in re.findall(r"(\w+_ms)=([0-9.]+)", m[2]):
            sums[key] = sums.get(key, 0) + n * float(value)
    battle = re.search(r"UBER1 battle \d+: profile (\w+), living troops (\d+) at the window's start, (\d+) at its end.*?average ([0-9.]+) fps.*?p99 ([0-9.]+) ms.*?worst frame ([0-9.]+) ms; logic ([0-9.]+) frames/s[^\n]*", text)
    result = {"profile": battle[1] if battle else None, "battle": None,
              "whole_play_render": distribution([r["interval_ms"] for r in rows]),
              "whole_play_phase_means_ms": {k: v / weights for k, v in sums.items()} if weights else None,
              "phase_window_render_frames": weights, "malformed_frame_rows": malformed,
              "diagnostics": [s for s in text.splitlines() if any(k in s for k in
                  ("GAME PERF WAIT", "GAME PERF WINDOWS", "UBER1 wait", "UBER1 client", "UBER1 second", "GAME HITCH"))]}
    if battle:
        result["battle"] = dict(troops_start=int(battle[2]), troops_end=int(battle[3]),
                                fps=float(battle[4]), p99_ms=float(battle[5]),
                                worst_ms=float(battle[6]), logic_hz=float(battle[7]), raw=battle[0])
    detail_path = frames_path.with_name("battle.json")
    if detail_path.exists():
        detail = json.loads(detail_path.read_text(encoding="utf-8"))
        result["scenario"] = detail.get("scenario", "battle")
        result["command_ms"] = detail.get("command_ms")
        result["army_motion"] = {k: detail.get(k) for k in ("motion_begin", "motion_rows", "motion_end")}
        result["move_field"] = detail.get("move_field", "retail")
        result["battle_render"] = distribution([r["interval_ms"] for r in detail["rows"]])
        result["battle_detail_profile"] = detail.get("profile")
        result["battle_timing_distributions"] = {}
        for section in ("timings", "hud"):
            keys = {k for r in detail["rows"] for k in r.get(section, {}) if k.endswith("_ms") and k != "logic_wait_ms"}
            for key in sorted(keys):
                result["battle_timing_distributions"][section + "." + key] = distribution(
                    [r[section][key] for r in detail["rows"] if key in r.get(section, {}) and r[section][key] >= 0])
        result["battle_counter_deltas"] = {}
        for before, after in (("waits_before", "waits_after"), ("client_before", "client_after")):
            for key in detail.get(before, {}):
                if key in ("logic_waits", "logic_wait_ms", "contended_locks", "opened", "missed", "parks", "park_timeouts", "worker_held_ms"):
                    result["battle_counter_deltas"][key] = detail[after][key] - detail[before][key]
        result["battle_detail_note"] = "Worker last-frame timings can repeat across render samples; these are render-sampled observations, not a tick distribution."
        result["presentation_motion"] = presentation_motion(detail["rows"])
    return result


def validate_client_all_moving(client, requested_troops):
    motion = client.get("army_motion") or {}
    begin, rows, end = motion.get("motion_begin") or {}, motion.get("motion_rows") or [], motion.get("motion_end") or {}
    tracked = begin.get("tracked_troops", 0)
    start = begin.get("frame", -1)
    failed = [r.get("frame") for r in rows if r.get("tracked_troops") != tracked
              or r.get("moved_troops") != tracked or r.get("skipped_ticks") != 0]
    passed = (tracked >= requested_troops and len(rows) > 0 and not failed
              and [r.get("frame") for r in rows] == list(range(start + 1, start + 1 + len(rows)))
              and end.get("frame") == start + len(rows) and end.get("tracked_troops") == tracked)
    return dict(passed=passed, tracked_troops=tracked, requested_troops=requested_troops,
                measured_ticks=len(rows), all_moving_ticks=sum(r.get("moved_troops") == tracked and tracked > 0
                    and r.get("skipped_ticks") == 0 for r in rows), failed_ticks=failed,
                reason=None if passed else "every soldier must move on every completed tick; missing snapshots or army probes fail acceptance")


def presentation_motion(rows):
    """Observed unchanged spans, bounded by timestamps; no guessed between-sample motion."""
    clock_last, clock_start, clock_max = None, None, 0.0
    probes = {}
    for row in rows:
        now = row.get("elapsed_us", 0) / 1000
        timings = row.get("timings", {})
        if "presented_alpha" in timings:
            signature = (row.get("logic_frame"), timings["presented_alpha"])
            if signature != clock_last:
                clock_start = now
            elif clock_start is not None:
                clock_max = max(clock_max, now - clock_start)
            clock_last = signature
        for pose in row.get("poses", []):
            if not pose.get("ok"):
                continue
            key = str(pose["id"])
            xy = (pose["x"], pose["y"])
            if key not in probes:
                probes[key] = dict(first_xy=xy, last_xy=xy, unchanged_since_ms=now, longest_unchanged_ms=0.0, changes=0, observations=0)
            probe = probes[key]
            probe["observations"] += 1
            dx, dy = xy[0] - probe["last_xy"][0], xy[1] - probe["last_xy"][1]
            if dx * dx + dy * dy > 1e-8:
                probe["changes"] += 1
                probe["unchanged_since_ms"] = now
            else:
                probe["longest_unchanged_ms"] = max(probe["longest_unchanged_ms"], now - probe["unchanged_since_ms"])
            probe["last_xy"] = xy
    held0 = rows[0].get("timings", {}).get("held_presentations") if rows else None
    held1 = rows[-1].get("timings", {}).get("held_presentations") if rows else None
    return dict(longest_unchanged_presentation_clock_ms=clock_max if clock_start is not None else None,
                held_presentation_delta=held1 - held0 if held0 is not None and held1 is not None else None,
                fixed_pose_probes=probes,
                note="Unchanged spans include legitimately stopped/blocked units. Probe displacement and native moving-troop census distinguish those cases; spans exclude unsampled time.")


class WindowsCounters:
    """OS counters for the launched process; I/O includes device I/O. No injection."""
    def __init__(self, process):
        self.handle = int(process._handle)
        self.pid = process.pid
        from ctypes import wintypes as w
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self.psapi = ctypes.WinDLL("psapi", use_last_error=True)
        self.kernel.GetProcessTimes.argtypes = [w.HANDLE] + [ctypes.c_void_p] * 4
        self.kernel.GetSystemTimes.argtypes = [ctypes.c_void_p] * 3
        self.kernel.GetProcessIoCounters.argtypes = [w.HANDLE, ctypes.c_void_p]
        self.kernel.CreateToolhelp32Snapshot.argtypes = [w.DWORD, w.DWORD]
        self.kernel.CreateToolhelp32Snapshot.restype = w.HANDLE
        self.kernel.Thread32First.argtypes = [w.HANDLE, ctypes.c_void_p]
        self.kernel.Thread32Next.argtypes = [w.HANDLE, ctypes.c_void_p]
        self.kernel.OpenThread.argtypes = [w.DWORD, w.BOOL, w.DWORD]
        self.kernel.OpenThread.restype = w.HANDLE
        self.kernel.GetThreadTimes.argtypes = [w.HANDLE] + [ctypes.c_void_p] * 4
        self.kernel.CloseHandle.argtypes = [w.HANDLE]
        class ThreadEntry(ctypes.Structure):
            _fields_ = [("size", w.DWORD), ("usage", w.DWORD), ("tid", w.DWORD), ("pid", w.DWORD),
                        ("priority", w.LONG), ("delta", w.LONG), ("flags", w.DWORD)]
        self.ThreadEntry = ThreadEntry
        self.psapi.GetProcessMemoryInfo.argtypes = [w.HANDLE, ctypes.c_void_p, w.DWORD]
        class Memory(ctypes.Structure):
            _fields_ = [("cb", w.DWORD), ("faults", w.DWORD)] + [(n, ctypes.c_size_t) for n in
                ("peak_rss", "rss", "peak_paged", "paged", "peak_nonpaged", "nonpaged", "pagefile", "peak_pagefile", "private")]
        self.Memory = Memory

    def read(self):
        times = [ctypes.c_ulonglong() for _ in range(4)]
        io = (ctypes.c_ulonglong * 6)()
        memory = self.Memory()
        memory.cb = ctypes.sizeof(memory)
        row = {}
        system = [ctypes.c_ulonglong() for _ in range(3)]
        if self.kernel.GetSystemTimes(*(ctypes.byref(t) for t in system)):
            total = system[1].value + system[2].value
            row.update(system_total_s=total / 1e7, system_busy_s=(total - system[0].value) / 1e7)
        if self.kernel.GetProcessTimes(self.handle, *(ctypes.byref(t) for t in times)):
            row["cpu_s"] = (times[2].value + times[3].value) / 1e7
        if self.psapi.GetProcessMemoryInfo(self.handle, ctypes.byref(memory), memory.cb):
            row.update(rss_bytes=memory.rss, private_bytes=memory.private, page_faults=memory.faults)
        if self.kernel.GetProcessIoCounters(self.handle, ctypes.byref(io)):
            row.update(zip(("read_ops", "write_ops", "other_ops", "read_bytes", "write_bytes", "other_bytes"), io))
        snapshot = self.kernel.CreateToolhelp32Snapshot(4, 0) # TH32CS_SNAPTHREAD
        if snapshot and snapshot != ctypes.c_void_p(-1).value:
            threads = {}
            entry = self.ThreadEntry()
            entry.size = ctypes.sizeof(entry)
            try:
                found = self.kernel.Thread32First(snapshot, ctypes.byref(entry))
                while found:
                    if entry.pid == self.pid:
                        handle = self.kernel.OpenThread(0x0800, False, entry.tid) # QUERY_LIMITED_INFORMATION
                        if handle:
                            try:
                                tt = [ctypes.c_ulonglong() for _ in range(4)]
                                if self.kernel.GetThreadTimes(handle, *(ctypes.byref(t) for t in tt)):
                                    # Creation time disambiguates reused thread IDs.
                                    threads[f"{entry.tid}:{tt[0].value}"] = (tt[2].value + tt[3].value) / 1e7
                            finally:
                                self.kernel.CloseHandle(handle)
                    found = self.kernel.Thread32Next(snapshot, ctypes.byref(entry))
            finally:
                self.kernel.CloseHandle(snapshot)
            row["thread_cpu_s"] = threads
        return row


def run_process(command, env, folder, timeout, interval, flag=None, sampler=None):
    start = time.perf_counter()
    samples, errors = [], []
    status = "completed"
    external = None
    with (folder / "engine.log").open("wb") as log:
        p = subprocess.Popen(command, env=env, cwd=folder, stdout=log, stderr=subprocess.STDOUT)
        write_json(folder / "launch.json", {"pid": p.pid, "command": command, "environment":
            {k: v for k, v in env.items() if k.startswith("OPENBFME_") or k in ("BFME2_INSTALL", "ROTWK_INSTALL")}})
        counter = WindowsCounters(p) if os.name == "nt" else None
        try:
            while p.poll() is None:
                pass_start = time.perf_counter()
                now = time.perf_counter() - start
                measured = bool(flag and flag.exists())
                row = {"elapsed_s": now, "native_measured_window": measured}
                if counter:
                    row.update(counter.read())
                samples.append(row)
                # Script parse/startup failures can leave Godot's empty window running forever.
                with (folder / "engine.log").open("rb") as check:
                    check.seek(max(0, check.seek(0, 2) - 16384))
                    tail = check.read().decode("utf-8", errors="replace")
                if any(x in tail for x in ("SCRIPT ERROR:", "GAME FAIL", "UBER1 RESULT: 0 ok")):
                    status = "failed"
                    errors.append("engine reported a script/scenario failure; see engine.log")
                    p.kill()
                    break
                if sampler and external is None and (measured or flag is None):
                    # A JSON argv list, never evaluated by a shell. Duration must be bounded by the command.
                    argv = [v.replace("{pid}", str(p.pid)).replace("{out}", str(folder / "stacks")) for v in sampler]
                    stack_log = (folder / "sampler.log").open("wb")
                    try:
                        external = (subprocess.Popen(argv, stdout=stack_log, stderr=subprocess.STDOUT), stack_log)
                    except OSError:
                        stack_log.close()
                        raise
                if now >= timeout:
                    status = "timeout"
                    p.kill()
                    break
                row["collection_ms"] = (time.perf_counter() - pass_start) * 1000
                time.sleep(max(0, interval - (time.perf_counter() - pass_start)))
        except KeyboardInterrupt:
            status = "interrupted"
            p.kill()
        except Exception as exc:
            status = "failed"
            errors.append(str(exc))
            p.kill()
        finally:
            p.wait()
            if counter:
                samples.append({"elapsed_s": time.perf_counter() - start, "native_measured_window": False, **counter.read()})
            if external:
                try:
                    external[0].wait(timeout=30)
                except subprocess.TimeoutExpired:
                    external[0].kill()
                    external[0].wait()
                    errors.append("sampler exceeded 30 s after game exit; partial files retained")
                if external[0].returncode != 0:
                    errors.append(f"sampler exit {external[0].returncode}")
                external[1].close()
    write_json(folder / "resources.json", samples)
    def resource_summary(rows):
        if len(rows) < 2:
            return None
        first, last = rows[0], rows[-1]
        duration = last["elapsed_s"] - first["elapsed_s"]
        out = {"observed_s": duration, "samples": len(rows)}
        out["collector_pass_cost"] = distribution([r["collection_ms"] for r in rows if "collection_ms" in r])
        for k in ("cpu_s", "page_faults", "read_ops", "write_ops", "other_ops", "read_bytes", "write_bytes", "other_bytes"):
            out[k + "_delta"] = last[k] - first[k] if k in last and k in first else None
        out["cpu_percent_one_core"] = 100 * out["cpu_s_delta"] / duration if out["cpu_s_delta"] is not None and duration > 0 else None
        if all(k in first and k in last for k in ("system_total_s", "system_busy_s")):
            total = last["system_total_s"] - first["system_total_s"]
            out["system_cpu_percent_all_cores"] = 100 * (last["system_busy_s"] - first["system_busy_s"]) / total if total > 0 else None
        for k in ("rss_bytes", "private_bytes"):
            out[k + "_peak_observed"] = max((r[k] for r in rows if k in r), default=None)
        threads = {}
        for r in rows:
            for tid, cpu in r.get("thread_cpu_s", {}).items():
                if tid not in threads:
                    threads[tid] = {"first_s": r["elapsed_s"], "first_cpu_s": cpu}
                threads[tid].update(last_s=r["elapsed_s"], last_cpu_s=cpu)
        for t in threads.values():
            dt = t["last_s"] - t["first_s"]
            t["cpu_s_delta"] = t["last_cpu_s"] - t["first_cpu_s"]
            t["cpu_percent_one_core"] = 100 * t["cpu_s_delta"] / dt if dt > 0 else None
        out["threads"] = threads
        return out
    return {"status": status, "exit_code": p.returncode, "elapsed_s": time.perf_counter() - start,
            "errors": errors, "resources_whole_process": resource_summary(samples),
            "resources_native_window": resource_summary([r for r in samples if r["native_measured_window"]])}


def report(out, runs, manifest):
    # Compare hash chains only for native runs within one profile/unit/warm-up matrix.
    guards = []
    for profile in ("faithful", "uber"):
        for units in sorted({r["units"] for r in runs}):
            group = [r for r in runs if r["kind"] == "logic" and r["requested_profile"] == profile
                     and r["units"] == units and r["status"] == "completed"]
            chains = {r["logic"]["hash_chain"] for r in group}
            guards.append({"profile": profile, "units": units, "runs": len(group),
                           "hash_chains": sorted(c for c in chains if c),
                           "selected_state_consistent": len(chains) == 1 if len(group) > 1 else None})
    aggregates = []
    keys = sorted({(r["kind"], r["requested_profile"], r["units"], r["threads"]) for r in runs})
    for kind, profile, units, threads in keys:
        group = [r for r in runs if (r["kind"], r["requested_profile"], r["units"], r["threads"]) == (kind, profile, units, threads)
                 and r["status"] == "completed"]
        vals = [r["logic"]["metrics"]["tick_ms"]["mean_ms"] if kind == "logic" else r["client"]["battle"]["fps"] for r in group]
        aggregates.append(dict(kind=kind, profile=profile, units=units, threads=threads, completed=len(group),
                               metric="tick_mean_ms" if kind == "logic" else "battle_fps",
                               median=statistics.median(vals) if vals else None,
                               minimum=min(vals) if vals else None, maximum=max(vals) if vals else None))
    write_json(out / "summary.json", {"manifest": manifest, "runs": runs, "hash_guards": guards, "repeat_aggregates": aggregates})
    lines = ["# Simulation profiling", "", "Native tick includes logic + state hash. Client FPS uses the bounded workload window.",
             "Resource counters cover process lifetime unless explicitly marked native window.",
             "Phase/render logs can overlap and cover different windows. Missing values are unavailable.", "",
             "| Run | Status | Tick mean / p99 ms | Client FPS / p99 ms |", "|---|---|---|---|"]
    for r in runs:
        t = r.get("logic", {}).get("metrics", {}).get("tick_ms")
        b = r.get("client", {}).get("battle")
        tick = f'{t["mean_ms"]:.2f} / {t["p99_ms"]:.2f}' if t else "unavailable"
        client = f'{b["fps"]:.1f} / {b["p99_ms"]:.2f}' if b else "unavailable"
        lines.append(f'| {r["name"]} | {r["status"]} | {tick} | {client} |')
    for r in runs:
        check = r.get("movement_validation")
        if check:
            detail = (f'{check["all_moving_ticks"]} / {check["measured_ticks"]} measured ticks had every tracked troop moving.'
                      if "measured_ticks" in check else check["reason"])
            lines += ["", f'{r["name"]}: all-unit movement {"VERIFIED" if check["passed"] else "NOT VERIFIED"}. ' + detail]
    movement_rows = []
    for r in runs:
        native = r.get("logic", {})
        if native.get("scenario") != "move":
            continue
        metrics = native.get("metrics", {})
        def mean(key):
            d = metrics.get(key)
            return f'{d["mean_ms"]:.2f}' if d else "unavailable"
        motion = native.get("motion") or {}
        moving = f'{motion["mean_moved"]:.0f} / {motion["tracked_troops"]}' if motion else "unavailable"
        movement_rows.append([r["name"], mean("work_pathfinderQueue_ms"), mean("work_partitionAndCollision_ms"), moving])
    if movement_rows:
        lines += ["", "Movement workload: every spawned horde receives a move command. Actual moving population is measured; congestion/arrival can stop troops.",
                  "Callback times below are inclusive parts of the six phases, not additional tick costs. Queue service is not all pathfinding work.", "",
                  "| Run | Queued path service mean ms | Collision callback mean ms | Mean troops changing XY / tracked |", "|---|---|---|---|"]
        lines += ["| " + " | ".join(map(str, row)) + " |" for row in movement_rows]
    lines += ["", "Full phase distributions, hash chains, wait/hitch diagnostics, launch settings and resource observations: summary.json and each run folder.",
              "Native frame dumps round to 0.1 ms. The original engine summary retains its higher precision.",
              "Hash chains may be compared only within the same profile, data, workload and thread matrix; this is a selected-state guard, not proof of determinism.",
              "No GPU execution timers, cache counters, network latency or save/replay timings are inferred from these workloads."]
    mismatches = [g for g in guards if g["selected_state_consistent"] is False]
    if mismatches:
        lines += ["", "WARNING: native selected-state hash differs across repeats/thread counts; inspect summary.json before accepting comparisons."]
    text = "\n".join(lines) + "\n"
    (out / "report.md").write_text(text, encoding="utf-8")
    def table(headers, rows):
        def cells(tag, values):
            return "<tr>" + "".join(f"<{tag}>{html.escape(str(v))}</{tag}>" for v in values) + "</tr>"
        return "<table>" + cells("th", headers) + "".join(cells("td", r) for r in rows) + "</table>"
    phase_rows, resource_rows, repeat_rows = [], [], []
    for r in runs:
        metrics = r.get("logic", {}).get("metrics", {})
        if metrics.get("tick_ms"):
            phase_rows.append([r["name"]] + [f'{metrics[k]["mean_ms"]:.2f}' for k in
                ["tick_ms", "hash_ms"] + [f"phase{i}_ms" for i in range(1, 7)]])
        resources = r.get("resources_whole_process") or {}
        cpu = resources.get("cpu_percent_one_core")
        private = resources.get("private_bytes_peak_observed")
        resource_rows.append([r["name"], r["status"], f"{cpu:.1f}" if cpu is not None else "unavailable",
                              f"{private / 1048576:.1f}" if private is not None else "unavailable"])
    for group in aggregates:
        repeat_rows.append([group[k] for k in ("kind", "profile", "units", "threads", "completed", "metric")] +
                           [f'{group[k]:.2f}' if group[k] is not None else "unavailable" for k in ("median", "minimum", "maximum")])
    body = html.escape(json.dumps(runs, indent=2))
    (out / "report.html").write_text('<!doctype html><meta charset="utf-8"><title>Simulation profiling</title>'
        '<style>body{font:15px system-ui;margin:2em;max-width:1500px}pre{white-space:pre-wrap}details{margin:1em 0}'
        'table{border-collapse:collapse;margin-bottom:2em}td,th{border:1px solid #ccc;padding:.5em;text-align:right}'
        'td:first-child,th:first-child{text-align:left}th{background:#eee}</style>'
        '<h1>Simulation profiling</h1><pre>' + html.escape(text) + '</pre><h2>Native mean times (ms)</h2>' +
        table(["Run", "Tick", "Hash"] + [f"Phase {i}" for i in range(1, 7)], phase_rows) +
        '<h2>Whole-process resource observations</h2>' + table(["Run", "Status", "CPU % (one core = 100)", "Peak private MiB"], resource_rows) +
        ('<h2>Movement callback timings (included in phases)</h2>' + table(["Run", "Queued path service ms", "Collision callback ms", "Mean moving / tracked"], movement_rows) if movement_rows else '') +
        '<h2>Completed-run repeat statistics</h2>' + table(["Harness", "Profile", "Troops", "Threads", "Runs", "Metric", "Median", "Min", "Max"], repeat_rows) +
        '<details><summary>All measurements (including failures)</summary><pre>' + body + '</pre></details>' +
        '<details><summary>Build, data policies and capture settings</summary><pre>' + html.escape(json.dumps(manifest, indent=2)) + '</pre></details>', encoding="utf-8")


def positive(value):
    n = int(value)
    if n < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return n


def nonnegative(value):
    n = int(value)
    if n < 0:
        raise argparse.ArgumentTypeError("must be nonnegative")
    return n


def main(argv=None):
    a = argparse.ArgumentParser(description=__doc__)
    a.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    a.add_argument("--tests", type=Path, help="exact openbfme_tests executable")
    a.add_argument("--godot", type=Path)
    a.add_argument("--bfme2", type=Path, default=os.environ.get("BFME2_INSTALL"))
    a.add_argument("--rotwk", type=Path, default=os.environ.get("ROTWK_INSTALL"))
    a.add_argument("--out", type=Path, required=True, help="new output directory; never overwritten")
    a.add_argument("--kind", choices=("logic", "client", "both"), default="both")
    a.add_argument("--scenario", choices=("battle", "move"), default="battle")
    a.add_argument("--move-pattern", choices=("crossing", "parallel"), help="move defaults to parallel marching; crossing is a congestion diagnostic")
    a.add_argument("--movement-validation", choices=("all", "observe"), default="all",
                   help="move: require every troop moving on every measured tick (default); observe retains partial-movement diagnostic runs")
    a.add_argument("--move-spacing", type=positive, help="initial horde spacing: default 200 on open field, 75 on retail map")
    a.add_argument("--move-field", choices=("retail", "open"), help="move defaults to a flat controlled field without neutral map actors/scripts")
    a.add_argument("--profiles", nargs="+", choices=("faithful", "uber"), default=["faithful", "uber"])
    a.add_argument("--units", nargs="+", type=positive, help="default 4000 for open-field movement; 10000 20000 40000 otherwise")
    a.add_argument("--threads", nargs="+", type=positive, default=[1, max(1, os.cpu_count() or 1)])
    a.add_argument("--repeats", type=positive, default=3)
    a.add_argument("--frames", type=positive, default=100)
    a.add_argument("--warmup", type=nonnegative, help="default 50 for battle; 0 for move, retaining the mass-order burst")
    a.add_argument("--no-simulation-detail", action="store_true", help="disable test-only phase-work timers for an overhead/hash control")
    a.add_argument("--seconds", type=positive, default=20)
    a.add_argument("--timeout", type=positive, default=900)
    a.add_argument("--interval-ms", type=positive, default=250)
    a.add_argument("--resolution", default="1280x800")
    a.add_argument("--renderer", choices=("gl_compatibility", "mobile", "forward_plus"), default="gl_compatibility")
    a.add_argument("--sampler-argv", type=Path, help="optional JSON list of argv strings; {pid} and {out} substituted")
    a.add_argument("--no-client-detail", action="store_true", help="disable buffered per-render battle snapshots to check their overhead")
    args = a.parse_args(argv)
    if args.move_field is None:
        args.move_field = "open" if args.scenario == "move" else "retail"
    if args.move_pattern is None:
        args.move_pattern = "parallel" if args.scenario == "move" else "crossing"
    if args.move_spacing is None:
        args.move_spacing = 200 if args.move_field == "open" else 75
    if args.units is None:
        args.units = [4000] if args.scenario == "move" and args.move_field == "open" else [10000, 20000, 40000]
    if args.warmup is None:
        args.warmup = (20 if args.move_field == "open" else 0) if args.scenario == "move" else 50
    args.root = args.root.resolve()
    args.tests = (args.tests or args.root / "engine/build/openbfme_tests.exe").resolve()
    for name in ("bfme2", "rotwk"):
        path = getattr(args, name)
        if path is None or not path.is_dir():
            a.error(f"--{name} must name the retail asset directory")
    if args.kind in ("logic", "both") and not args.tests.is_file():
        a.error("--tests must name a built native test runner")
    if args.kind in ("client", "both") and (args.godot is None or not args.godot.is_file() or not (args.root / "godot/project.godot").is_file()):
        a.error("client runs require --godot and --root containing godot/project.godot")
    # Windows Godot's _console executable is a forwarding launcher. Profile the
    # companion game process directly so OS counters and stack PID describe work.
    if args.godot and str(args.godot).endswith("_console.exe"):
        companion = Path(str(args.godot).replace("_console.exe", ".exe"))
        if companion.is_file():
            args.godot = companion
    if not re.fullmatch(r"[1-9]\d*x[1-9]\d*", args.resolution):
        a.error("--resolution must be WIDTHxHEIGHT")
    sampler = json.loads(args.sampler_argv.read_text()) if args.sampler_argv else None
    if sampler is not None and (not isinstance(sampler, list) or not sampler or not all(isinstance(v, str) for v in sampler)):
        a.error("sampler JSON must be a nonempty string list")
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=False)
    manifest = {"created_utc": datetime.now(timezone.utc).isoformat(), "host": platform.platform(),
                "cpu": platform.processor(), "logical_cpus": os.cpu_count(), "python": sys.version,
                "profiler": identity(__file__),
                "source": git_identity(args.root), "tests": identity(args.tests),
                "godot": identity(args.godot) if args.godot else None,
                "extensions": [identity(p) for p in (args.root / "godot/bin").glob("*.*") if p.suffix in (".dll", ".so", ".dylib")],
                "asset_policies": [identity(p) for p in (args.root / "engine/data/retail-archives").glob("*.json")],
                "client_sources": [identity(args.root / p) for p in ("godot/project.godot", "godot/scripts/game.gd", "godot/scripts/uber1_player.gd")],
                "settings": {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
                "native_benchmark_sources": [identity(args.root / p) for p in ("engine/tests/test_uber1_bench.cpp", "engine/tests/UberScenarios.h")],
                "scenario": {"action": args.scenario, "move_pattern": args.move_pattern,
                             "native": "8 human slots, seed 7; move uses allied teams, crossing or parallel destinations as specified by move_pattern, fixed troop motion census",
                             "client": "real --uber1 client, seed 7; move uses allied slots, immediate mass move without settling", "map": MAP},
                "limitations": ["native and client scenarios differ; compare profiles within each harness", "source commit does not prove binary freshness; exact binary SHA256 recorded", "resource samples are observations; short peaks may be missed", "sampler perturbs execution; repeat without sampling and at a longer interval", "render phase means overlap; do not add into exclusive frame budget"]}
    write_json(args.out / "manifest.json", manifest)
    runs = []
    kinds = ["logic", "client"] if args.kind == "both" else [args.kind]
    try:
        for repeat in range(args.repeats):
            # Alternate order to reduce consistent first-run/cache bias.
            profiles = args.profiles if repeat % 2 == 0 else list(reversed(args.profiles))
            for units in dict.fromkeys(args.units):
                for threads in dict.fromkeys(args.threads):
                    for profile in profiles:
                        for kind in kinds:
                            name = f"{kind}-{profile}-{units}-t{threads}-r{repeat+1}"
                            folder = args.out / name
                            folder.mkdir()
                            env = os.environ.copy()
                            # Do not let inherited benchmark selectors silently alter this run.
                            for key in list(env):
                                if key.startswith(("OPENBFME_UBER_", "OPENBFME_BENCH_")) or key == "OPENBFME_SAMPLER_FLAG":
                                    env.pop(key)
                            env.update(BFME2_INSTALL=str(args.bfme2.resolve()), ROTWK_INSTALL=str(args.rotwk.resolve()),
                                       OPENBFME_LOGIC_THREADS=str(threads), OPENBFME_UBER_SCENARIO=args.scenario,
                                       OPENBFME_UBER_MOVE_PATTERN=args.move_pattern, OPENBFME_UBER_MOVE_SPACING=str(args.move_spacing))
                            env.pop("OPENBFME_SIM_DETAIL", None)
                            if args.scenario == "move" and args.move_field == "open":
                                env["OPENBFME_UBER_MOVE_FIELD"] = "1"
                            if not args.no_simulation_detail:
                                env["OPENBFME_SIM_DETAIL"] = "1"
                            # Keep Godot shader caches, recordings, settings and session logs local to the capture.
                            for key in ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
                                local = folder / key.lower()
                                local.mkdir()
                                env[key] = str(local)
                            flag = folder / "measuring.flag" if kind == "logic" else None
                            if kind == "logic":
                                env.update(OPENBFME_UBER_UNITS=str(units), OPENBFME_BENCH_FRAMES=str(args.frames),
                                           OPENBFME_UBER_WARMUP=str(args.warmup), OPENBFME_UBER_PROFILE=profile,
                                           OPENBFME_UBER_FRAMES_DUMP="1", OPENBFME_SAMPLER_FLAG=str(flag))
                                command = [str(args.tests), "-tc=uber bench*", "--no-skip", "--no-colors"]
                            else:
                                options = folder / "Options.ini"
                                options.write_text("OpenBFMEUberPerformance = " + ("yes" if profile == "uber" else "no") + "\nResolution = " + args.resolution.replace("x", " ") + "\n", encoding="utf-8")
                                command = [str(args.godot.resolve()), "--path", str(args.root / "godot"),
                                           "--rendering-method", args.renderer, "--", "--auto", "--map=" + MAP,
                                           "--seed=7", "--ai=2", f"--uber1={units}", f"--uber1-seconds={args.seconds}",
                                           "--vsync=off", "--res=" + args.resolution, "--perf", "--options-file=" + str(options),
                                           "--perf-log=" + str(folder / "frames.log")]
                                if not args.no_client_detail:
                                    command.append("--uber1-profile-log=" + str(folder / "battle.json"))
                                command.append("--uber1-action=" + args.scenario)
                                command.append("--uber1-move-spacing=" + str(args.move_spacing))
                                command.append("--uber1-move-field=" + args.move_field)
                                command.append("--uber1-move-warmup=" + str(args.warmup))
                                command.append("--uber1-move-pattern=" + args.move_pattern)
                                if args.scenario == "move":
                                    command.append("--teams=0,0")
                            print(f"Running {name}", flush=True)
                            r = dict(name=name, kind=kind, requested_profile=profile, units=units, threads=threads, repeat=repeat+1)
                            try:
                                r.update(run_process(command, env, folder, args.timeout, args.interval_ms / 1000, flag, sampler))
                            except OSError as exc:
                                r.update(status="failed", exit_code=None, errors=[str(exc)])
                            text = (folder / "engine.log").read_text(encoding="utf-8", errors="replace")
                            try:
                                parsed = parse_logic(text) if kind == "logic" else parse_client(text, folder / "frames.log")
                            except (ValueError, KeyError, TypeError) as exc:
                                r["status"] = "failed"
                                r["errors"].append(f"invalid measurement log: {exc}")
                                parsed = parse_logic("") if kind == "logic" else {"profile": None, "battle": None}
                            r[kind] = parsed
                            if kind == "logic":
                                valid = (parsed["profile"] == profile and parsed["requested_troops"] == units
                                         and parsed["reported_frames"] == args.frames and len(parsed["frames"]) == args.frames
                                         and parsed["actual_threads"] == threads and parsed["hash_chain"] is not None
                                         and all(row["frame"] == i for i, row in enumerate(parsed["frames"])))
                                valid = valid and parsed["scenario"] == args.scenario
                                valid = valid and parsed["actual_warmup"] == args.warmup
                                if args.scenario == "move":
                                    valid = valid and parsed["move_field"] == args.move_field
                                if args.scenario == "move":
                                    valid = valid and parsed["motion"] is not None and parsed["motion"]["sampled_ticks"] == args.frames and parsed["motion"]["max_moved"] > 0
                                    r["movement_validation"] = validate_all_moving(parsed, args.frames, units)
                                if not args.no_simulation_detail:
                                    valid = valid and all((parsed["metrics"].get(k) or {}).get("n") == args.frames
                                        for k in ("work_pathfinderQueue_ms", "work_partitionAndCollision_ms"))
                                if parsed["frames"]:
                                    with (folder / "logic_frames.csv").open("w", newline="", encoding="utf-8") as f:
                                        writer = csv.DictWriter(f, fieldnames=list(parsed["frames"][0]))
                                        writer.writeheader()
                                        writer.writerows(parsed["frames"])
                            else:
                                valid = parsed["profile"] == profile and parsed["battle"] is not None and "UBER1 RESULT: 1 ok, 0 failed" in text
                                if not args.no_client_detail:
                                    valid = valid and parsed.get("battle_detail_profile") == profile and parsed.get("battle_render") is not None
                                if args.scenario == "move":
                                    valid = valid and "UBER1 workload: move;" in text
                                    r["movement_validation"] = validate_client_all_moving(parsed, units)
                                    if args.move_field == "open":
                                        valid = valid and parsed.get("move_field") == "open" and "movement field: open" in text
                            r["measurement_valid"] = bool(valid)
                            if args.scenario == "move" and args.movement_validation == "all" and not r["movement_validation"]["passed"]:
                                r["errors"].append("all-unit movement requirement failed: " + r["movement_validation"]["reason"])
                            if r["status"] == "completed" and (r["exit_code"] != 0 or not valid or r["errors"]):
                                r["status"] = "failed"
                                if r["exit_code"] != 0:
                                    r["errors"].append(f"engine exit {r['exit_code']} (0x{r['exit_code'] & 0xffffffff:08X}); measurements retained")
                                if not valid:
                                    r["errors"].append("missing/incomplete measurements or actual profile/thread count differs from request")
                            runs.append(r)
                            write_json(folder / "summary.json", r)
                            report(args.out, runs, manifest)
                            print(f"{name}: {r['status']}", flush=True)
                            if r["status"] == "interrupted":
                                return 130
    finally:
        report(args.out, runs, manifest)
    summary = json.loads((args.out / "summary.json").read_text(encoding="utf-8"))
    hashes_ok = all(g["selected_state_consistent"] is not False for g in summary["hash_guards"])
    return 0 if runs and all(r["status"] == "completed" for r in runs) and hashes_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
