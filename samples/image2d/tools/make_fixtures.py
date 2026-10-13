#!/usr/bin/env python3
"""Write the image2d sample's committed images from nothing but this script.

Uses only Python's standard library. Each image is made here, texel by texel,
from the region tables below, which `Hetoimasia.Sample.Image2d.Fixtures`
restates independently in Haskell and the suite checks the decoders against:
nothing is a third party's work, so no third-party rights attach to any of
them. The output is byte-for-byte deterministic. Run it from anywhere:

    python3 samples/image2d/tools/make_fixtures.py

It writes, into samples/image2d/renderer/assets/:

* quadrants.png  64 x 64, 8-bit RGBA, every texel opaque: four coloured
                 quadrants and two corner markers, so a flip, a rotation or a
                 swapped channel is visible. Its alpha is binary.
* fade.png       64 x 64, 8-bit RGBA: the left half at alpha 128 and the right
                 half opaque. Its alpha is not binary: it is the replacement a
                 swap to a different mark is refused for.
* stripes.ktx2   32 x 32, R8G8B8A8_SRGB, one level, no supercompression, every
                 texel opaque: four horizontal bands and a corner marker.

The KTX2 file follows https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html:
identifier, header and index, level index, a basic data format descriptor, a
KTXwriter entry, and the level.
"""

import struct
import zlib
from pathlib import Path

ASSETS = Path(__file__).resolve().parent.parent / "renderer" / "assets"

# (x0, y0, x1, y1, (r, g, b, a)), later regions over earlier ones.
QUADRANTS = [
    (0, 0, 32, 32, (220, 40, 40, 255)),
    (32, 0, 64, 32, (40, 200, 60, 255)),
    (0, 32, 32, 64, (50, 70, 220, 255)),
    (32, 32, 64, 64, (240, 220, 50, 255)),
    (4, 4, 12, 12, (255, 0, 255, 255)),
    (52, 52, 60, 60, (255, 255, 255, 255)),
]
FADE = [
    (0, 0, 32, 64, (200, 60, 60, 128)),
    (32, 0, 64, 64, (60, 60, 200, 255)),
]
STRIPES = [
    (0, 0, 32, 8, (0, 200, 200, 255)),
    (0, 8, 32, 16, (255, 140, 0, 255)),
    (0, 16, 32, 24, (150, 60, 200, 255)),
    (0, 24, 32, 32, (128, 128, 128, 255)),
    (0, 0, 4, 4, (255, 255, 255, 255)),
]


def texels(width, height, regions):
    """Row-major RGBA bytes, top row first: transparent black, then the regions."""
    rows = []
    for y in range(height):
        row = bytearray()
        for x in range(width):
            colour = (0, 0, 0, 0)
            for x0, y0, x1, y1, region in regions:
                if x0 <= x < x1 and y0 <= y < y1:
                    colour = region
            row += bytes(colour)
        rows.append(bytes(row))
    return rows


def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))


def png(width, height, regions):
    """An 8-bit RGBA PNG, no interlace, filter type 0 on every row."""
    raw = b"".join(b"\x00" + row for row in texels(width, height, regions))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


# --- KTX2 ---------------------------------------------------------------------

IDENTIFIER = bytes([0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A])
R8G8B8A8_SRGB = 43
TRANSFER_SRGB = 2
MODEL_RGBSDA = 1
PRIMARIES_BT709 = 1


def sample(bit_offset, bit_length, channel, lower, upper):
    return struct.pack("<HBB4BII", bit_offset, bit_length - 1, channel, 0, 0, 0, 0, lower, upper)


def descriptor():
    """The data format descriptor of an sRGB R8G8B8A8 texture: one basic block."""
    alpha = 15 | 0x10  # alpha, linear
    samples = b"".join(sample(8 * c, 8, ch, 0, 255) for c, ch in enumerate([0, 1, 2, alpha]))
    block = (
        struct.pack("<IHH", 0, 2, 24 + len(samples))
        + bytes([MODEL_RGBSDA, PRIMARIES_BT709, TRANSFER_SRGB, 0])
        + bytes(4)
        + bytes([4, 0, 0, 0, 0, 0, 0, 0])
        + samples
    )
    return struct.pack("<I", 4 + len(block)) + block


def key_values(entries):
    out = b""
    for key, value in entries:
        entry = key + b"\0" + value
        out += struct.pack("<I", len(entry)) + entry + bytes(-len(entry) % 4)
    return out


def ktx2(width, height, level):
    """A one-level RGBA8 sRGB KTX2 file holding these texels."""
    dfd = descriptor()
    kvd = key_values([(b"KTXwriter", b"make_fixtures.py 1\0")])
    dfd_at = 80 + 24
    kvd_at = dfd_at + len(dfd)
    level_at = kvd_at + len(kvd)
    level_at += -level_at % 4
    out = bytearray(level_at + len(level))
    out[0:12] = IDENTIFIER
    struct.pack_into("<9I", out, 12, R8G8B8A8_SRGB, 1, width, height, 0, 0, 1, 1, 0)
    struct.pack_into("<4I2Q", out, 48, dfd_at, len(dfd), kvd_at, len(kvd), 0, 0)
    struct.pack_into("<3Q", out, 80, level_at, len(level), len(level))
    out[dfd_at : dfd_at + len(dfd)] = dfd
    out[kvd_at : kvd_at + len(kvd)] = kvd
    out[level_at : level_at + len(level)] = level
    return bytes(out)


def main():
    ASSETS.mkdir(parents=True, exist_ok=True)
    (ASSETS / "quadrants.png").write_bytes(png(64, 64, QUADRANTS))
    (ASSETS / "fade.png").write_bytes(png(64, 64, FADE))
    (ASSETS / "stripes.ktx2").write_bytes(ktx2(32, 32, b"".join(texels(32, 32, STRIPES))))


if __name__ == "__main__":
    main()
