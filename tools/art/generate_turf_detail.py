"""Bake the original, seamless turf relief used by the natural-ground visual mod.

No retail assets or third-party packages. RG = tangent normal, B = turf height,
A = soil grain (reserved). Run from any folder; the optional argument is the PNG path.
"""

import math
from pathlib import Path
import random
import struct
import sys
import zlib


def bake(path: Path, size: int = 512) -> None:
    rng = random.Random(271828)
    height = [rng.uniform(0.07, 0.13) for _ in range(size * size)]
    # Bent, tapering blades embedded in the turf, drawn across the periodic boundary.
    for _ in range(5200):
        x, y = rng.uniform(0, size), rng.uniform(0, size)
        angle = rng.uniform(0, math.tau)
        length = rng.uniform(5, 22)
        width = rng.uniform(0.65, 1.6)
        bend = rng.uniform(-4, 4)
        rise = rng.uniform(0.22, 0.70)
        dx, dy = math.cos(angle), math.sin(angle)
        for step in range(int(length * 2)):
            t = step / (length * 2)
            bx = x + dx * length * t - dy * bend * t * t
            by = y + dy * length * t + dx * bend * t * t
            radius = width * (1 - t * 0.85)
            for oy in range(-2, 3):
                for ox in range(-2, 3):
                    px, py = int(bx) + ox, int(by) + oy
                    distance = math.hypot(px + 0.5 - bx, py + 0.5 - by)
                    if distance > radius + 0.5:
                        continue
                    weight = max(0.0, 1 - distance / (radius + 0.5))
                    index = (py % size) * size + px % size
                    height[index] = max(height[index], 0.1 + rise * weight * (1 - t * 0.5))
    rows = bytearray()
    for y in range(size):
        rows.append(0)  # PNG filter: none
        for x in range(size):
            sx = (height[y * size + (x + 1) % size] - height[y * size + (x - 1) % size]) * 2.0
            sy = (height[((y + 1) % size) * size + x] - height[((y - 1) % size) * size + x]) * 2.0
            inv = 1 / math.sqrt(sx * sx + sy * sy + 1)
            rows.extend((round((0.5 - sx * inv * 0.5) * 255),
                         round((0.5 - sy * inv * 0.5) * 255),
                         round(min(height[y * size + x], 1) * 255),
                         rng.randrange(80, 220)))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\x89PNG\r\n\x1a\n"
                     + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))
    print(f"Baked seamless turf detail: {path} ({size} x {size})")


if __name__ == "__main__":
    bake(Path(sys.argv[1]) if len(sys.argv) > 1 else
         Path(__file__).resolve().parents[2] / "godot/assets/natural_ground/turf_detail.png")
