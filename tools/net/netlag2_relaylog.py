#!/usr/bin/env python3
"""Lane NETLAG-2: timing facts of a game from the online relay's command log (services/online/relay/RelayCore.h "Log format", version 1 or 2).

  netlag2_relaylog.py LOG...

Per game: the players, the length, the run-ahead changes (the packet router's RUNAHEAD frame commands: the command delay every player had from that
frame on), the logic frames per second each sender's FRAMEINFOs arrived at the relay (5.0 = no stall; lower = the game waited), the waits (gaps of
400 ms or more between a sender's consecutive FRAMEINFOs), the game commands per player, and the run-ahead in effect when each game command executed.
Reads the log only (the relay's receive times, ms since the game's first HELLO); it never runs the game.
"""
import struct
import sys
from collections import defaultdict

FRAMEINFO, GAMECOMMAND, RUNAHEAD = 3, 4, 0x82


def records(data):
    if data[:8] != b"OBFMERLG":
        raise ValueError("not a relay log")
    version, game_id, mask, start = struct.unpack_from("<IQBI", data, 8)
    pos = 8 + 4 + 8 + 1 + 4
    yield ("header", version, game_id, mask, start)
    while pos < len(data):
        kind = data[pos]
        pos += 1
        if kind == 1:
            sender, ms, length = struct.unpack_from("<BII", data, pos)
            pos += 9
            yield ("command", sender, ms, data[pos:pos + length])
            pos += length
        elif kind == 2:
            slot, event, ms = struct.unpack_from("<BBI", data, pos)
            pos += 6
            yield ("event", slot, event, ms)
        elif kind == 3:
            pos += 7
        elif kind == 4:
            ms, reason = struct.unpack_from("<IB", data, pos)
            pos += 5 + 24 * 8
            yield ("end", ms, reason)
        elif kind == 5:
            slot, gen, ms = struct.unpack_from("<BHI", data, pos)
            pos += 7
            yield ("rejoined", slot, gen, ms)
        else:
            raise ValueError(f"unknown record {kind} at {pos - 1}")


def analyze(path):
    data = open(path, "rb").read()
    frameinfo = defaultdict(dict)  # sender -> frame -> first relay ms
    commands = defaultdict(list)   # sender -> [(exec frame, ms)]
    runahead = []                  # (exec frame, value, ms)
    end_ms = None
    for r in records(data):
        if r[0] == "header":
            version, game_id, mask, start = r[1:]
        elif r[0] == "command":
            sender, ms, b = r[1:]
            if len(b) < 6:
                continue
            ctype, slot, frame = b[0], b[1], struct.unpack_from("<I", b, 2)[0]
            if ctype == FRAMEINFO:
                frameinfo[sender].setdefault(frame, ms)
            elif ctype == GAMECOMMAND:
                commands[sender].append((frame, ms))
            elif ctype == RUNAHEAD:
                runahead.append((frame, struct.unpack_from("<I", b, 6)[0], ms))
        elif r[0] == "end":
            end_ms = r[1]
    print(f"game {path.split('/')[-1]} version {version} slots {bin(mask).count('1')} start_unix {start} end_ms {end_ms}")
    ra_sorted = sorted(runahead)
    print("  runahead_changes " + (" ".join(f"frame{f}->{v}@{ms / 1000:.1f}s" for f, v, ms in ra_sorted) or "none"))

    def ra_at(frame, base):
        v = base
        for f, val, _ in ra_sorted:
            if f <= frame:
                v = val
        return v

    for s in sorted(frameinfo):
        fi = frameinfo[s]
        frames = sorted(fi)
        if len(frames) < 2:
            continue
        span = fi[frames[-1]] - fi[frames[0]]
        fps = (frames[-1] - frames[0]) / (span / 1000) if span > 0 else 0
        waits = [(frames[i], fi[frames[i]] - fi[frames[i - 1]]) for i in range(1, len(frames)) if fi[frames[i]] - fi[frames[i - 1]] >= 400]
        wait_total = sum(w for _, w in waits)
        print(f"  slot {s}: frames {frames[0]}..{frames[-1]} over {span / 1000:.1f}s = {fps:.2f} frames/s; waits>=400ms {len(waits)} total {wait_total / 1000:.1f}s "
              f"longest {max([w for _, w in waits], default=0)}ms; game commands {len(commands[s])}")
    hist = defaultdict(int)
    base = 1
    for s in commands:
        for f, _ in commands[s]:
            hist[ra_at(f, base)] += 1
    print("  game commands by run-ahead in effect (base 1 assumed before the first change): " + " ".join(f"{k}:{v}" for k, v in sorted(hist.items())))


for p in sys.argv[1:]:
    analyze(p)
