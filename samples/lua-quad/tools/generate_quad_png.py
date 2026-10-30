#!/usr/bin/env python3
"""Generate the technical fixture content/images/quad.png, deterministically.

The image is an 8 x 8 RGBA8 static PNG written with the standard library only: four 4 x 4 quadrants (top
left red, top right green, bottom left blue, bottom right yellow), one white texel at the top left corner and
one black texel at the bottom right corner, so orientation and every channel can be told apart by eye and by
a probe. It is technical evidence for the launcher and the graphics adapter, not approved production art.

    python3 samples/lua-quad/tools/generate_quad_png.py [OUTPUT]

The default output is samples/lua-quad/content/images/quad.png. The bytes are a pure function of this file:
filter type 0 on every scanline, one IDAT chunk compressed at level 9, no ancillary chunk.
"""
import hashlib
import struct
import sys
import zlib
from pathlib import Path

WIDTH = HEIGHT = 8
RED, GREEN, BLUE, YELLOW = (255, 0, 0, 255), (0, 255, 0, 255), (0, 0, 255, 255), (255, 255, 0, 255)
WHITE, BLACK = (255, 255, 255, 255), (0, 0, 0, 255)


def texel(x, y):
    if (x, y) == (0, 0):
        return WHITE
    if (x, y) == (WIDTH - 1, HEIGHT - 1):
        return BLACK
    if y < HEIGHT // 2:
        return RED if x < WIDTH // 2 else GREEN
    return BLUE if x < WIDTH // 2 else YELLOW


def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def png():
    rows = b"".join(b"\x00" + b"".join(bytes(texel(x, y)) for x in range(WIDTH)) for y in range(HEIGHT))
    header = struct.pack(">IIBBBBB", WIDTH, HEIGHT, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")


def main():
    default = Path(__file__).resolve().parent.parent / "content" / "images" / "quad.png"
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else default
    data = png()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    print(f"{target} {len(data)} bytes sha256 {hashlib.sha256(data).hexdigest()}")


if __name__ == "__main__":
    main()
