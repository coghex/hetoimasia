#!/usr/bin/env python3
"""Write the PNG fixtures asset-image-tests decodes.

This is an encoder written for the fixtures alone, independent of the decoder
under test and of JuicyPixels: it uses only Python's standard library (zlib,
struct). Every texel a fixture holds is written out literally here and,
separately, in the test that reads it (Test.Asset.Image.Fixtures); neither
side is derived from the other or from a decode.

Rows are filtered with a different PNG filter type per row (row index mod 5),
so the fixtures exercise all five filters, not only "None".

Run it from this directory to regenerate the committed files:

    python3 make_fixtures.py

The output is byte-for-byte deterministic; a rerun on an unchanged script
leaves `git status` clean.
"""

import struct
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
SIGNATURE = b"\x89PNG\r\n\x1a\n"

GREY, RGB, PALETTE, GREY_ALPHA, RGBA = 0, 2, 3, 4, 6
CHANNELS = {GREY: 1, RGB: 3, PALETTE: 1, GREY_ALPHA: 2, RGBA: 4}

# Adam7: (first column, column step, first row, row step) for passes 1 to 7.
ADAM7 = [(0, 8, 0, 8), (4, 8, 0, 8), (0, 4, 4, 8), (2, 4, 0, 4),
         (0, 2, 2, 4), (1, 2, 0, 2), (0, 1, 1, 2)]


def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))


def ihdr(width, height, depth, colour, interlace=0):
    return chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, depth, colour, 0, 0, interlace))


def pack_row(samples, depth):
    """Pack one row of samples (already flattened over channels) into bytes."""
    if depth == 16:
        return b"".join(struct.pack(">H", s) for s in samples)
    if depth == 8:
        return bytes(samples)
    out, acc, used = bytearray(), 0, 0
    for s in samples:
        acc = (acc << depth) | s
        used += depth
        if used == 8:
            out.append(acc)
            acc, used = 0, 0
    if used:
        out.append(acc << (8 - used))
    return bytes(out)


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def filter_rows(rows, bpp):
    """Filter packed rows, choosing filter type (row index mod 5)."""
    out = bytearray()
    previous = bytes(len(rows[0])) if rows else b""
    for index, row in enumerate(rows):
        kind = index % 5
        out.append(kind)
        for i, x in enumerate(row):
            a = row[i - bpp] if i >= bpp else 0
            b = previous[i]
            c = previous[i - bpp] if i >= bpp else 0
            predictor = [0, a, b, (a + b) // 2, paeth(a, b, c)][kind]
            out.append((x - predictor) & 0xFF)
        previous = row
    return bytes(out)


def raw_data(pixels, depth, colour, interlace):
    """The filtered, uncompressed image data for rows of pixel tuples."""
    channels = CHANNELS[colour]
    bpp = max(1, channels * depth // 8)
    height, width = len(pixels), len(pixels[0])

    def encode(sub):
        packed = [pack_row([s for px in row for s in px], depth) for row in sub]
        return filter_rows(packed, bpp)

    if not interlace:
        return encode(pixels)
    data = b""
    for col0, dcol, row0, drow in ADAM7:
        sub = [[pixels[y][x] for x in range(col0, width, dcol)] for y in range(row0, height, drow)]
        if sub and sub[0]:
            data += encode(sub)
    return data


def png(pixels, depth, colour, interlace=0, before_idat=(), idat_pieces=1, payload=None):
    """A PNG of rows of pixel tuples; each tuple holds one value per channel."""
    height, width = len(pixels), len(pixels[0])
    compressed = payload if payload is not None else zlib.compress(raw_data(pixels, depth, colour, interlace), 9)
    step = -(-len(compressed) // idat_pieces)
    idats = b"".join(chunk(b"IDAT", compressed[i:i + step]) for i in range(0, len(compressed), step))
    return SIGNATURE + ihdr(width, height, depth, colour, interlace) + b"".join(before_idat) + idats + chunk(b"IEND", b"")


def plte(entries):
    return chunk(b"PLTE", b"".join(bytes(e) for e in entries))


def grey(rows):
    return [[(v,) for v in row] for row in rows]


def grey_key(value):
    """A greyscale tRNS colour key: one big-endian 16-bit sample."""
    return chunk(b"tRNS", struct.pack(">H", value))


def rgb_key(red, green, blue):
    """A truecolour tRNS colour key: three big-endian 16-bit samples."""
    return chunk(b"tRNS", struct.pack(">HHH", red, green, blue))


def s15(value):
    return struct.pack(">i", round(value * 65536))


def icc_profile():
    """A small, structurally valid ICC v2 RGB display profile."""
    def tag_desc(text):
        ascii_ = text.encode() + b"\0"
        return (b"desc" + bytes(4) + struct.pack(">I", len(ascii_)) + ascii_
                + bytes(4) + bytes(4) + bytes(2) + bytes(1) + bytes(67))

    def tag_text(text):
        return b"text" + bytes(4) + text.encode() + b"\0"

    def tag_xyz(x, y, z):
        return b"XYZ " + bytes(4) + s15(x) + s15(y) + s15(z)

    curve = b"curv" + bytes(4) + struct.pack(">I", 1) + struct.pack(">H", 0x0233)
    tags = [
        (b"desc", tag_desc("hetoimasia fixture")),
        (b"cprt", tag_text("No copyright: a test fixture")),
        (b"wtpt", tag_xyz(0.9642, 1.0, 0.8249)),
        (b"rXYZ", tag_xyz(0.4361, 0.2225, 0.0139)),
        (b"gXYZ", tag_xyz(0.3851, 0.7169, 0.0971)),
        (b"bXYZ", tag_xyz(0.1431, 0.0606, 0.7141)),
        (b"rTRC", curve),
        (b"gTRC", curve),
        (b"bTRC", curve),
    ]
    offset = 128 + 4 + 12 * len(tags)
    table, body = b"", b""
    for signature, data in tags:
        padded = data + bytes(-len(data) % 4)
        table += signature + struct.pack(">II", offset + len(body), len(data))
        body += padded
    size = offset + len(body)
    header = (struct.pack(">I", size) + bytes(4) + struct.pack(">I", 0x02100000)
              + b"mntr" + b"RGB " + b"XYZ " + struct.pack(">6H", 2026, 10, 5, 0, 0, 0)
              + b"acsp" + bytes(4) + struct.pack(">I", 0) + bytes(4) + bytes(4)
              + bytes(8) + struct.pack(">I", 0) + s15(0.9642) + s15(1.0) + s15(0.8249)
              + bytes(4) + bytes(16) + bytes(28))
    assert len(header) == 128
    return header + struct.pack(">I", len(tags)) + table + body


GREY1 = grey([[0, 1, 0, 1, 1, 0, 0, 1, 1, 1], [1, 0, 1, 0, 0, 1, 1, 0, 0, 0]])
GREY2 = grey([[0, 1, 2, 3, 0], [3, 2, 1, 0, 1]])
GREY4 = grey([[0, 7, 15], [1, 8, 14]])
GREY8 = grey([[0, 128, 255], [17, 64, 200]])
RGB8 = [[(255, 0, 0), (0, 255, 0)], [(0, 0, 255), (12, 34, 56)]]
RGBA8 = [[(255, 0, 0, 255), (0, 255, 0, 128), (0, 0, 255, 0)],
         [(200, 100, 50, 64), (255, 255, 255, 255), (1, 2, 3, 4)]]


def interlaced_rgba(x, y):
    return (x * 50, y * 50, (x + y) * 20, 255 - x * 10 - y * 20)


def fixtures():
    gama_one = chunk(b"gAMA", struct.pack(">I", 100000))
    gama_srgb = chunk(b"gAMA", struct.pack(">I", 45455))
    chrm = chunk(b"cHRM", struct.pack(">8I", 31270, 32900, 64000, 33000, 30000, 60000, 15000, 6000))
    srgb = chunk(b"sRGB", bytes([0]))
    iccp = chunk(b"iCCP", b"fixture\0\0" + zlib.compress(icc_profile(), 9))
    short_payload = zlib.compress(raw_data(RGB8, 8, RGB, 0)[:7], 9)
    good = zlib.compress(raw_data(RGB8, 8, RGB, 0), 9)
    # The zlib header stays valid; the first deflate block header becomes
    # BFINAL=1 with the reserved block type 3, so inflation itself fails.
    corrupt = good[:2] + bytes([0xFF]) + good[3:]

    return {
        "grey1.png": png(GREY1, 1, GREY),
        "grey2.png": png(GREY2, 2, GREY),
        "grey4.png": png(GREY4, 4, GREY),
        "grey8.png": png(GREY8, 8, GREY),
        "grey16.png": png(grey([[0, 129, 383], [386, 32896, 65535]]), 16, GREY),
        "grey-alpha8.png": png([[(10, 0), (128, 127), (255, 255)]], 8, GREY_ALPHA),
        "grey-alpha16.png": png([[(65535, 129), (32896, 386), (129, 65535)]], 16, GREY_ALPHA),
        "palette1.png": png(grey([[0, 1, 1, 0, 1, 0, 0, 1, 1]]), 1, PALETTE,
                            before_idat=[plte([(255, 0, 0), (0, 0, 255)])]),
        "palette2.png": png(grey([[3, 2, 1, 0, 2]]), 2, PALETTE,
                            before_idat=[plte([(0, 0, 0), (255, 0, 0), (0, 255, 0), (0, 0, 255)])]),
        "palette4.png": png(grey([[0, 5, 15], [10, 1, 9]]), 4, PALETTE,
                            before_idat=[plte([(i * 16, 255 - i * 16, i) for i in range(16)])]),
        "palette8.png": png(grey([[0, 100, 199]]), 8, PALETTE,
                            before_idat=[plte([(i, 255 - i, (i * 7) % 256) for i in range(200)])]),
        "palette-trns.png": png(grey([[0, 1, 2, 3]]), 8, PALETTE,
                                before_idat=[plte([(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)]),
                                             chunk(b"tRNS", bytes([0, 128, 255]))]),
        "rgb8.png": png(RGB8, 8, RGB),
        "rgb16.png": png([[(129, 383, 386), (65535, 0, 32896)]], 16, RGB),
        "rgba8.png": png(RGBA8, 8, RGBA),
        "rgba16.png": png([[(65535, 129, 0, 386), (32896, 386, 383, 65535)]], 16, RGBA),
        "interlaced-rgba8.png": png([[interlaced_rgba(x, y) for x in range(5)] for y in range(5)], 8, RGBA,
                                    interlace=1, idat_pieces=3),
        "interlaced-grey1.png": png(grey([[(x + y) % 2 for x in range(5)] for y in range(5)]), 1, GREY,
                                    interlace=1),
        # tRNS colour keys on greyscale and RGB: a texel whose stored samples
        # equal the key, at the file's own bit depth, is transparent.
        "grey1-trns.png": png(GREY1, 1, GREY, before_idat=[grey_key(1)]),
        "grey2-trns.png": png(GREY2, 2, GREY, before_idat=[grey_key(1)]),
        "grey4-trns.png": png(GREY4, 4, GREY, before_idat=[grey_key(7)]),
        "grey8-trns.png": png(GREY8, 8, GREY, before_idat=[grey_key(128)]),
        # 0x1299 shares only the key's high byte, 0x5534 only its low byte.
        "grey16-trns.png": png(grey([[0x1234, 0x1299, 0x5534], [0x1234, 0, 65535]]), 16, GREY,
                               before_idat=[grey_key(0x1234)]),
        "rgb8-trns.png": png(RGB8, 8, RGB, before_idat=[rgb_key(255, 0, 0)]),
        # (0x12ff, 0x56ff, 0x9aff) shares only the key's high bytes, and
        # (0x1234, 0x5678, 0x9abd) differs in one low byte.
        "rgb16-trns.png": png([[(0x1234, 0x5678, 0x9ABC), (0x12FF, 0x56FF, 0x9AFF)],
                               [(0x1234, 0x5678, 0x9ABD), (0x1234, 0x5678, 0x9ABC)]], 16, RGB,
                              before_idat=[rgb_key(0x1234, 0x5678, 0x9ABC)]),
        "interlaced-grey2-trns.png": png(grey([[(x + 2 * y) % 4 for x in range(5)] for y in range(5)]), 2, GREY,
                                         interlace=1, before_idat=[grey_key(2)]),
        "interlaced-rgb8-trns.png": png([[(x % 2 * 100, y % 2 * 100, 7) for x in range(5)] for y in range(5)], 8, RGB,
                                        interlace=1, before_idat=[rgb_key(100, 0, 7)]),
        # Keys no texel matches: absent from the image, beyond the 2-bit
        # range, and sharing an 8-bit texel's low byte but not the high byte.
        "grey8-trns-unmatched.png": png(GREY8, 8, GREY, before_idat=[grey_key(77)]),
        "grey2-trns-out-of-range.png": png(GREY2, 2, GREY, before_idat=[grey_key(5)]),
        "grey8-trns-high-byte.png": png(GREY8, 8, GREY, before_idat=[grey_key(0x0180)]),
        # Malformed tRNS chunks, which JuicyPixels decodes without complaint:
        # a length the colour type does not take, a colour type with its own
        # alpha, and a second tRNS chunk.
        "grey8-trns-rgb-length.png": png(GREY8, 8, GREY, before_idat=[rgb_key(128, 128, 128)]),
        "grey1-trns-rgb-length.png": png(GREY1, 1, GREY, before_idat=[rgb_key(1, 1, 1)]),
        "rgb8-trns-grey-length.png": png(RGB8, 8, RGB, before_idat=[grey_key(255)]),
        "rgba8-trns.png": png(RGBA8, 8, RGBA, before_idat=[rgb_key(255, 0, 0)]),
        "grey-alpha8-trns.png": png([[(10, 0), (128, 127), (255, 255)]], 8, GREY_ALPHA, before_idat=[grey_key(128)]),
        "grey8-two-trns.png": png(GREY8, 8, GREY, before_idat=[grey_key(128), grey_key(128)]),
        # Colour-space chunks over the same texels as rgba8.png and rgb8.png.
        "rgba8-colour-chunks.png": png(RGBA8, 8, RGBA, before_idat=[gama_one, chrm, srgb]),
        "rgb8-iccp.png": png(RGB8, 8, RGB, before_idat=[gama_srgb, iccp]),
        # The cutout mark.
        "alpha-binary.png": png([[(10, 20, 30, 0), (40, 50, 60, 255)], [(70, 80, 90, 255), (1, 2, 3, 0)]], 8, RGBA),
        "alpha-one.png": png([[(10, 20, 30, 255), (40, 50, 60, 1)]], 8, RGBA),
        "alpha-254.png": png([[(10, 20, 30, 0), (40, 50, 60, 254)]], 8, RGBA),
        # Refusals.
        "corrupt-stream.png": png(RGB8, 8, RGB, payload=corrupt),
        "short-stream.png": png(RGB8, 8, RGB, payload=short_payload),
        "palette-index-out-of-range.png": png(grey([[0, 5]]), 8, PALETTE,
                                              before_idat=[plte([(1, 2, 3), (4, 5, 6)])]),
        "no-palette.png": png(grey([[0, 1]]), 8, PALETTE),
        "rgb-depth4.png": png([[(1, 2, 3), (4, 5, 6)]], 4, RGB),
        "zero-width.png": SIGNATURE + ihdr(0, 1, 8, RGB) + chunk(b"IDAT", zlib.compress(b"\0", 9)) + chunk(b"IEND", b""),
    }


def main():
    for name, data in fixtures().items():
        (HERE / name).write_bytes(data)


if __name__ == "__main__":
    main()
