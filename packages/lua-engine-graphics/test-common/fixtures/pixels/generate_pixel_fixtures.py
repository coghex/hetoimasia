#!/usr/bin/env python3
"""Generate the technical PNG fixtures of the `Lua offscreen pixels` subgroup (LFE-24), deterministically.

These are technical test assets, labelled as such: they are not approved production art. Each is a small RGBA8
static PNG written with the standard library only (filter type 0 on every scanline, one IDAT chunk compressed at
level 9, no ancillary chunk), so the bytes are a pure function of this file, wholly owned by this repository.

    python3 packages/lua-engine-graphics/test-common/fixtures/pixels/generate_pixel_fixtures.py [OUTPUT-DIRECTORY]

The default output directory is this script's own. The texel tables below are the *source* of each image and are
stated again, independently, in the suites' Haskell (Test.LuaEngine.Graphics.Pixels), which checks the committed
files against them and against the SHA-256 listed here; neither side is derived from the other, from the PNG
decoder under test, or from any captured framebuffer.

  grid4x3.png     4 x 3, opaque, twelve distinct colours: no mirror, flip, rotation or channel swap of it equals
                  itself, and every texel blocks out cleanly when enlarged.
  red_a192.png    2 x 2, one colour (255, 0, 0) at alpha 192: partial alpha, so it takes the ordered, premultiplied
                  path (a texture with only alpha 0 and 255 is a cutout).
  blue_a192.png   2 x 2, one colour (0, 0, 255) at alpha 192.
  grey128.png     2 x 2, opaque (128, 128, 128): the byte that distinguishes sRGB-byte decoding from 128/255 taken
                  as linear light.
  magenta.png     2 x 2, opaque (210, 40, 170): a solid used for placement, clipping and copy checks.
"""
import hashlib
import struct
import sys
import zlib
from pathlib import Path

GRID = [
    [(230, 30, 30, 255), (30, 200, 60, 255), (40, 60, 230, 255), (230, 210, 40, 255)],
    [(30, 210, 210, 255), (210, 40, 200, 255), (240, 130, 20, 255), (130, 60, 200, 255)],
    [(245, 245, 245, 255), (15, 15, 15, 255), (160, 230, 70, 255), (240, 150, 170, 255)],
]


def solid(width, height, colour):
    return [[colour] * width for _ in range(height)]


FIXTURES = {
    "grid4x3.png": GRID,
    "red_a192.png": solid(2, 2, (255, 0, 0, 192)),
    "blue_a192.png": solid(2, 2, (0, 0, 255, 192)),
    "grey128.png": solid(2, 2, (128, 128, 128, 255)),
    "magenta.png": solid(2, 2, (210, 40, 170, 255)),
}


def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def png(rows):
    height, width = len(rows), len(rows[0])
    raw = b"".join(b"\x00" + b"".join(bytes(texel) for texel in row) for row in rows)
    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def main():
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent
    target.mkdir(parents=True, exist_ok=True)
    for name, rows in FIXTURES.items():
        data = png(rows)
        (target / name).write_bytes(data)
        print(f"{name} {len(data)} bytes sha256 {hashlib.sha256(data).hexdigest()}")


if __name__ == "__main__":
    main()
