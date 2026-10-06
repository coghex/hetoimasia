#!/usr/bin/env python3
"""Write bc7-reference.txt: BC7 blocks and levels with their reference texels.

The blocks are built here, bit by bit, from the BC7 format's field layout.
Their texels come from an independent reference decoder, never from the
decoder under test: Pillow's BCn decoder (PIL's "bcn" codec, implemented in
src/libImaging/BcnDecode.c), at exactly the version REFERENCE names. Each block
or level is wrapped in a DDS file with a DX10 header and decoded by Pillow.

Run it in this directory with that Pillow installed:

    python3 make_bc7_fixtures.py

The output is byte-for-byte deterministic: the blocks come from a fixed seed.

One case is not taken from Pillow. A block whose first byte is zero has no
valid mode; the BC7 format defines its texels as all channels zero, and
Pillow 12.2.0 decodes it with alpha 255 instead. The suite states that
expectation itself, from the format's definition, and this file holds no
such block.
"""

import io
import random
import struct

import PIL
from PIL import Image

REFERENCE = "Pillow 12.2.0"

# mode: subsets, partition bits, rotation bits, index-selection bits,
# colour bits, alpha bits, a p-bit per endpoint, a p-bit per subset,
# primary index bits, secondary index bits.
MODES = {
    0: (3, 4, 0, 0, 4, 0, True, False, 3, 0),
    1: (2, 6, 0, 0, 6, 0, False, True, 3, 0),
    2: (3, 6, 0, 0, 5, 0, False, False, 2, 0),
    3: (2, 6, 0, 0, 7, 0, True, False, 2, 0),
    4: (1, 0, 2, 1, 5, 6, False, False, 2, 3),
    5: (1, 0, 2, 0, 7, 8, False, False, 2, 2),
    6: (1, 0, 0, 0, 7, 7, True, False, 4, 0),
    7: (2, 6, 0, 0, 5, 5, True, False, 2, 0),
}


def block(mode, rest, partition=0, rotation=0, selection=0):
    """A block of the mode: its header fields as given, and every bit after
    them taken from ``rest``."""
    _, pb, rb, isb, *_ = MODES[mode]
    header = mode + 1 + pb + rb + isb
    value = 1 << mode
    position = mode + 1
    value |= partition << position
    position += pb
    value |= rotation << position
    position += rb
    value |= selection << position
    bits = (rest << header) & ((1 << 128) - 1) | value
    return bits.to_bytes(16, "little")


def mode6(alpha_endpoints, indices):
    """A mode 6 block: endpoint 0 opaque-red-ish, endpoint 1 blue-ish, with
    the given 7-bit alphas and p-bits 0 and 1, and the given sixteen 4-bit
    indices (texel 0's must fit in 3 bits)."""
    a0, a1 = alpha_endpoints
    fields = [(0b1000000, 7)]
    for e0, e1 in [(127, 0), (0, 0), (0, 127), (a0, a1)]:
        fields += [(e0, 7), (e1, 7)]
    fields += [(0, 1), (1, 1)]
    fields += [(indices[0], 3)] + [(i, 4) for i in indices[1:]]
    value, position = 0, 0
    for field, width in fields:
        assert 0 <= field < (1 << width)
        value |= field << position
        position += width
    assert position == 128
    return value.to_bytes(16, "little")


def dds(width, height, data, srgb):
    pixel_format = struct.pack("<II4s5I", 32, 0x4, b"DX10", 0, 0, 0, 0, 0)
    header = (
        struct.pack("<7I", 124, 0x1 | 0x2 | 0x4 | 0x1000 | 0x80000, height, width, len(data), 0, 1)
        + b"\0" * 44
        + pixel_format
        + struct.pack("<5I", 0x1000, 0, 0, 0, 0)
    )
    dx10 = struct.pack("<5I", 99 if srgb else 98, 3, 0, 1, 0)
    return b"DDS " + header + dx10 + data


def reference(width, height, data):
    """The reference decoder's RGBA8 texels for one level, row by row. Both
    DXGI formats are decoded, and must agree: BC7 stores the same texels in
    either colour space."""
    decoded = []
    for srgb in (False, True):
        image = Image.open(io.BytesIO(dds(width, height, data, srgb)))
        image.load()
        assert image.mode == "RGBA" and image.size == (width, height)
        decoded.append(image.tobytes())
    assert decoded[0] == decoded[1]
    return decoded[0]


def blocks():
    rng = random.Random(401)
    named = []
    # Every partition of every partitioned mode, so every partition and
    # anchor-index table entry is exercised.
    for mode, count in [(0, 16), (1, 64), (2, 64), (3, 64), (7, 64)]:
        for partition in range(count):
            named.append((f"mode{mode}-partition{partition:02d}", block(mode, rng.getrandbits(128), partition=partition)))
    # Every rotation, and for mode 4 both index selections.
    for rotation in range(4):
        for selection in range(2):
            named.append((f"mode4-rotation{rotation}-selection{selection}", block(4, rng.getrandbits(128), rotation=rotation, selection=selection)))
        named.append((f"mode5-rotation{rotation}", block(5, rng.getrandbits(128), rotation=rotation)))
    # Every mode with random fields, and with every bit after the mode's
    # header clear and set.
    for mode in range(8):
        _, pb, rb, isb, *_ = MODES[mode]
        for n in range(6):
            named.append(
                (
                    f"mode{mode}-random{n}",
                    block(mode, rng.getrandbits(128), rng.getrandbits(pb) if pb else 0, rng.getrandbits(rb) if rb else 0, rng.getrandbits(isb) if isb else 0),
                )
            )
        named.append((f"mode{mode}-zeros", block(mode, 0)))
        named.append((f"mode{mode}-ones", block(mode, (1 << 128) - 1, (1 << pb) - 1, (1 << rb) - 1, (1 << isb) - 1)))
    # Alpha for the mark: binary, intermediate, and intermediate only where a
    # 3 × 3 image crops the block (column 3 and row 3).
    binary = [0, 15, 15, 0, 15, 0, 0, 15, 0, 15, 15, 0, 15, 15, 0, 0]
    intermediate = binary[:5] + [7] + binary[6:]
    edges = [7 if i % 4 == 3 or i // 4 == 3 else binary[i] for i in range(16)]
    named.append(("alpha-binary", mode6((0, 127), binary)))
    named.append(("alpha-intermediate", mode6((0, 127), intermediate)))
    named.append(("alpha-intermediate-edges", mode6((0, 127), edges)))
    return named, rng


def levels(rng):
    """A 9 × 6 image's full chain: 3 × 2 blocks at level 0, then 4 × 3,
    2 × 1 and 1 × 1, each block of a different mode."""
    width, height = 9, 6
    chain = []
    modes = iter([1, 6, 3, 0, 5, 7, 2, 4, 6])
    level = 0
    while True:
        w, h = max(1, width >> level), max(1, height >> level)
        count = ((w + 3) // 4) * ((h + 3) // 4)
        data = b"".join(block(m := next(modes), rng.getrandbits(128), rng.getrandbits(MODES[m][1]) if MODES[m][1] else 0) for _ in range(count))
        chain.append((f"chain9x6-level{level}", w, h, data))
        if w == 1 and h == 1:
            return chain
        level += 1


def main():
    if PIL.__version__ != REFERENCE.split()[1]:
        raise SystemExit(f"the reference is {REFERENCE}; this is Pillow {PIL.__version__}")
    named, rng = blocks()
    lines = [
        "# BC7 blocks and levels with their reference texels, written by make_bc7_fixtures.py.",
        f"# reference decoder: {REFERENCE} (PIL BCn decoder, src/libImaging/BcnDecode.c)",
        "# block <name> <16 block bytes, hex> <16 RGBA8 texels, row by row, hex>",
        "# level <name> <width> <height> <blocks, row by row, hex> <RGBA8 texels, row by row, hex>",
    ]
    for name, data in named:
        lines.append(f"block {name} {data.hex()} {reference(4, 4, data).hex()}")
    for name, w, h, data in levels(rng):
        lines.append(f"level {name} {w} {h} {data.hex()} {reference(w, h, data).hex()}")
    with open("bc7-reference.txt", "w", encoding="ascii", newline="\n") as out:
        out.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
