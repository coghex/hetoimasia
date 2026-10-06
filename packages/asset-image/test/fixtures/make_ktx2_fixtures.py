#!/usr/bin/env python3
"""Write the KTX2 fixtures for asset-image-tests, assembled byte by byte.

Uses only Python's standard library and shares no code with the reader under
test. Each file follows the KTX2 specification's layout
(https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html): the identifier,
header and index, the level index, the data format descriptor, the key/value
data, and the levels stored smallest first, each aligned and padded as the
specification requires. BC7 blocks are mode-6 blocks built bit by bit with
constant endpoints, so every texel's alpha follows from the block's
construction alone. Refusal fixtures are valid files with one field or range
changed afterwards.

Every fixture except the one without key/value data carries a KTXwriter entry
naming this script and its version, and ktx2-fixtures.txt records each
fixture's producer and version beside it. The suite states every expected
level itself. Run `python3 make_ktx2_fixtures.py` in this directory; the
output is byte-for-byte deterministic.
"""

import struct
from pathlib import Path

VERSION = "1"
PRODUCER = f"make_ktx2_fixtures.py {VERSION}"
HERE = Path(__file__).resolve().parent

IDENTIFIER = bytes([0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A])
KTX1_IDENTIFIER = bytes([0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A])

R8G8B8A8_UNORM = 37
R8G8B8A8_SRGB = 43
B8G8R8A8_UNORM = 44
BC7_UNORM_BLOCK = 145
BC7_SRGB_BLOCK = 146

TRANSFER_LINEAR = 1
TRANSFER_SRGB = 2
FLAG_PREMULTIPLIED = 1

MODEL_RGBSDA = 1
MODEL_BC7 = 134
PRIMARIES_BT709 = 1

WRITER = [(b"KTXwriter", PRODUCER.encode() + b"\0")]

# Header field offsets.
VK_FORMAT, TYPE_SIZE, PIXEL_WIDTH, PIXEL_HEIGHT, PIXEL_DEPTH = 12, 16, 20, 24, 28
LAYER_COUNT, FACE_COUNT, LEVEL_COUNT, SUPERCOMPRESSION = 32, 36, 40, 44
DFD_OFFSET, DFD_LENGTH, KVD_OFFSET, KVD_LENGTH = 48, 52, 56, 60


def is_bc7(vk_format):
    return vk_format in (BC7_UNORM_BLOCK, BC7_SRGB_BLOCK)


def sample(bit_offset, bit_length, channel, lower, upper):
    return struct.pack("<HBB4BII", bit_offset, bit_length - 1, channel, 0, 0, 0, 0, lower, upper)


def basic_block(vk_format, transfer, flags, model=None, primaries=PRIMARIES_BT709):
    """A basic descriptor block for the format."""
    if is_bc7(vk_format):
        samples = sample(0, 128, 0, 0, 0xFFFFFFFF)
        dimensions = bytes([3, 3, 0, 0])
        plane = 16
        model = MODEL_BC7 if model is None else model
    else:
        alpha = 15 | (0x10 if transfer == TRANSFER_SRGB else 0)
        samples = b"".join(sample(8 * c, 8, ch, 0, 255) for c, ch in enumerate([0, 1, 2, alpha]))
        dimensions = bytes(4)
        plane = 4
        model = MODEL_RGBSDA if model is None else model
    size = 24 + len(samples)
    return (
        struct.pack("<IHH", 0, 2, size)
        + bytes([model, primaries, transfer, flags])
        + dimensions
        + bytes([plane, 0, 0, 0, 0, 0, 0, 0])
        + samples
    )


def descriptor(blocks):
    body = b"".join(blocks)
    return struct.pack("<I", 4 + len(body)) + body


def key_values(entries):
    """Key/value data: each entry a (key, value) pair, or raw keyAndValue
    bytes, each padded to four bytes."""
    out = b""
    for entry in entries:
        if isinstance(entry, tuple):
            key, value = entry
            entry = key + b"\0" + value
        out += struct.pack("<I", len(entry)) + entry + bytes(-len(entry) % 4)
    return out


def align(n, to):
    return n + (-n % to)


def ktx2(
    vk_format,
    width,
    height,
    levels,
    *,
    transfer=None,
    flags=0,
    kv=None,
    dfd=None,
    layers=0,
):
    """A valid KTX2 file holding the levels, level 0 first."""
    if transfer is None:
        transfer = TRANSFER_SRGB if vk_format in (R8G8B8A8_SRGB, BC7_SRGB_BLOCK) else TRANSFER_LINEAR
    dfd_bytes = descriptor([basic_block(vk_format, transfer, flags)]) if dfd is None else dfd
    kvd_bytes = key_values(WRITER if kv is None else kv)
    count = len(levels)
    dfd_at = 80 + 24 * count
    kvd_at = dfd_at + len(dfd_bytes)
    end = kvd_at + len(kvd_bytes)
    # Levels are stored smallest first, each at a multiple of
    # lcm(texel block size, 4), with mip padding before it.
    alignment = 16 if is_bc7(vk_format) else 4
    offsets = [0] * count
    for level in reversed(range(count)):
        end = align(end, alignment)
        offsets[level] = end
        end += len(levels[level])
    out = bytearray(end)
    out[0:12] = IDENTIFIER
    struct.pack_into("<9I", out, 12, vk_format, 1, width, height, 0, layers, 1, count, 0)
    struct.pack_into(
        "<4I2Q", out, 48, dfd_at, len(dfd_bytes), kvd_at if kvd_bytes else 0, len(kvd_bytes), 0, 0
    )
    for level, data in enumerate(levels):
        struct.pack_into("<3Q", out, 80 + 24 * level, offsets[level], len(data), len(data))
        out[offsets[level] : offsets[level] + len(data)] = data
    out[dfd_at : dfd_at + len(dfd_bytes)] = dfd_bytes
    out[kvd_at : kvd_at + len(kvd_bytes)] = kvd_bytes
    return out


def patched(data, *fields):
    """The file with (format, offset, value) fields overwritten."""
    out = bytearray(data)
    for fmt, offset, value in fields:
        struct.pack_into(fmt, out, offset, value)
    return out


def level_entry(level):
    return 80 + 24 * level


def rgba8(texels):
    return bytes(channel for texel in texels for channel in texel)


# --- RGBA8 texels -----------------------------------------------------------

# Straight texels. The suite restates them, and the premultiplied values
# below, by hand.
SINGLE = [(255, 0, 0, 255), (0, 255, 0, 128), (0, 0, 255, 0), (200, 100, 50, 64)]
MULTI = [
    [
        (255, 255, 255, 255), (128, 64, 32, 200), (10, 20, 30, 40), (0, 0, 0, 0),
        (255, 128, 0, 1), (90, 180, 250, 254), (17, 34, 51, 128), (240, 240, 240, 255),
    ],
    [(100, 150, 200, 100), (50, 60, 70, 255)],
    [(33, 66, 99, 33)],
]


def to_linear(v):
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def from_linear(v):
    return v * 12.92 if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055


def premultiplied(texel):
    """IEC 61966-2-1 premultiplication in linear light, rounded to nearest."""
    *colour, a = texel
    if a == 0:
        return (0, 0, 0, 0)
    if a == 255:
        return texel
    return tuple(int(from_linear(to_linear(c / 255) * a / 255) * 255 + 0.5) for c in colour) + (a,)


def partial_level(width, height, level):
    return [(x * 30 + level, y * 60 + level, 100, 255 - x - y) for y in range(height) for x in range(width)]


# --- BC7 blocks -------------------------------------------------------------

WEIGHTS4 = [0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64]


def mode6(e0, e1, indices):
    """A mode-6 block: endpoints given as 8-bit RGBA, each endpoint's four
    channels sharing one parity (its p-bit); sixteen 4-bit indices, texel 0
    (the anchor) below 8."""
    fields = [(1 << 6, 7)]
    p0, p1 = e0[0] & 1, e1[0] & 1
    assert all(c & 1 == p0 for c in e0) and all(c & 1 == p1 for c in e1)
    for channel in range(4):
        fields += [(e0[channel] >> 1, 7), (e1[channel] >> 1, 7)]
    fields += [(p0, 1), (p1, 1)]
    assert indices[0] < 8
    fields += [(indices[0], 3)] + [(i, 4) for i in indices[1:]]
    value, at = 0, 0
    for bits, width in fields:
        value |= bits << at
        at += width
    assert at == 128
    return value.to_bytes(16, "little")


def mode6_alpha(e0, e1, index):
    w = WEIGHTS4[index]
    return ((64 - w) * e0[3] + w * e1[3] + 32) >> 6


def opaque(r, g, b):
    """Every texel this odd-valued colour, alpha 255."""
    e = (r | 1, g | 1, b | 1, 255)
    return mode6(e, e, [0] * 16)


def translucent(r, g, b):
    """Every texel this even-valued colour, alpha 128."""
    e = (r & ~1, g & ~1, b & ~1, 128)
    return mode6(e, e, [0] * 16)


def holes(transparent):
    """Alpha 255 everywhere but the listed texels, which have alpha 0.
    Texel 0, the anchor, cannot be one of them."""
    return mode6((201, 101, 51, 255), (0, 0, 0, 0), [15 if t in transparent else 0 for t in range(16)])


def cropped(width, height):
    """Alpha 255 in the texels inside a width × height corner, and 188, from
    index 8, in the block's texels outside it."""
    indices = [0 if (t % 4 < width and t // 4 < height) else 8 for t in range(16)]
    block = mode6((255, 129, 1, 255), (128, 64, 0, 128), indices)
    assert mode6_alpha((0, 0, 0, 255), (0, 0, 0, 128), 8) == 188
    return block


# --- The fixtures -----------------------------------------------------------

FIXTURES = {}


def fixture(name, description, data):
    FIXTURES[name] = (description, bytes(data))


def accepted():
    single_pm = [premultiplied(t) for t in SINGLE]
    multi_pm = [[premultiplied(t) for t in level] for level in MULTI]

    fixture("rgba8-srgb.ktx2", "colour RGBA8, 2 × 2, one level, straight alpha",
            ktx2(R8G8B8A8_SRGB, 2, 2, [rgba8(SINGLE)]))
    fixture("rgba8-srgb-mips.ktx2", "colour RGBA8, 4 × 2, full chain of 3, straight alpha",
            ktx2(R8G8B8A8_SRGB, 4, 2, [rgba8(level) for level in MULTI]))
    fixture("rgba8-srgb-premultiplied.ktx2", "colour RGBA8, 2 × 2, one level, premultiplied-alpha flag",
            ktx2(R8G8B8A8_SRGB, 2, 2, [rgba8(single_pm)], flags=FLAG_PREMULTIPLIED))
    fixture("rgba8-srgb-premultiplied-mips.ktx2", "colour RGBA8, 4 × 2, full chain of 3, premultiplied-alpha flag",
            ktx2(R8G8B8A8_SRGB, 4, 2, [rgba8(level) for level in multi_pm], flags=FLAG_PREMULTIPLIED))
    fixture("rgba8-linear.ktx2", "data RGBA8, 2 × 2, one level",
            ktx2(R8G8B8A8_UNORM, 2, 2, [rgba8(SINGLE)]))
    fixture("rgba8-linear-mips.ktx2", "data RGBA8, 4 × 2, full chain of 3",
            ktx2(R8G8B8A8_UNORM, 4, 2, [rgba8(level) for level in MULTI]))
    fixture("rgba8-linear-partial.ktx2", "data RGBA8, 8 × 4, 2 levels of a full chain of 4",
            ktx2(R8G8B8A8_UNORM, 8, 4, [rgba8(partial_level(8, 4, 0)), rgba8(partial_level(4, 2, 1))]))
    fixture("rgba8-linear-layer-one.ktx2", "data RGBA8, 2 × 2, layerCount 1",
            ktx2(R8G8B8A8_UNORM, 2, 2, [rgba8(SINGLE)], layers=1))
    fixture("rgba8-linear-no-metadata.ktx2", "data RGBA8, 2 × 2, no key/value data at all",
            ktx2(R8G8B8A8_UNORM, 2, 2, [rgba8(SINGLE)], kv=[]))
    fixture("rgba8-linear-explicit-metadata.ktx2", "data RGBA8, 2 × 2, KTXorientation rd and KTXswizzle rgba",
            ktx2(R8G8B8A8_UNORM, 2, 2, [rgba8(SINGLE)],
                 kv=[(b"KTXorientation", b"rd\0"), (b"KTXswizzle", b"rgba\0")] + WRITER))
    ignored_dfd = descriptor([
        basic_block(R8G8B8A8_UNORM, TRANSFER_LINEAR, 0, model=0, primaries=0),
        # A vendor-specific block after the basic one: vendor 0x1234, type 7.
        struct.pack("<IHH", 0x1234 | (7 << 17), 0, 12) + bytes([1, 2, 3, 4]),
    ])
    fixture("rgba8-linear-ignored.ktx2",
            "data RGBA8, 2 × 2, unspecified colour model and primaries, a second vendor block, "
            "and unknown keys, one with a binary value",
            ktx2(R8G8B8A8_UNORM, 2, 2, [rgba8(SINGLE)], dfd=ignored_dfd,
                 kv=[(b"KTXdxgiFormat__", b"\x00\xff\x01"), (b"zz-unknown", b"anything\0")] + WRITER))

    fixture("bc7-srgb-premultiplied.ktx2",
            "colour BC7, 8 × 8, full chain of 4, premultiplied-alpha flag, level 0 alpha 0 and 255 only",
            ktx2(BC7_SRGB_BLOCK, 8, 8,
                 [holes({1, 5}) + opaque(11, 21, 31) + holes({15}) + opaque(41, 51, 61),
                  translucent(70, 80, 90), holes({3}), opaque(1, 3, 5)],
                 flags=FLAG_PREMULTIPLIED))
    fixture("bc7-srgb-premultiplied-translucent.ktx2",
            "colour BC7, 4 × 4, one level, premultiplied-alpha flag, level 0 alpha 128",
            ktx2(BC7_SRGB_BLOCK, 4, 4, [translucent(100, 110, 120)], flags=FLAG_PREMULTIPLIED))
    fixture("bc7-linear.ktx2", "data BC7, 8 × 4, full chain of 4, level 0 alpha 128 and 255",
            ktx2(BC7_UNORM_BLOCK, 8, 4,
                 [translucent(2, 4, 6) + opaque(7, 9, 11), opaque(13, 15, 17), holes({1}), translucent(20, 22, 24)]))
    fixture("bc7-srgb-straight-opaque.ktx2",
            "colour BC7, 5 × 3, full chain of 3, no flag, alpha 255 in every texel inside each level's extent "
            "and 188 in the edge blocks' texels outside it",
            ktx2(BC7_SRGB_BLOCK, 5, 3, [cropped(4, 3) + cropped(1, 3), cropped(2, 1), cropped(1, 1)]))


def refused():
    rgba = ktx2(R8G8B8A8_SRGB, 2, 2, [rgba8(SINGLE)])
    rgba_mips = ktx2(R8G8B8A8_SRGB, 4, 2, [rgba8(level) for level in MULTI])
    dfd_at = struct.unpack_from("<I", rgba, DFD_OFFSET)[0]
    kvd_at = struct.unpack_from("<I", rgba, KVD_OFFSET)[0]

    fixture("bc7-srgb-straight-deep-translucent.ktx2",
            "colour BC7, 8 × 8, full chain of 4, no flag, opaque but for one level 2 texel with alpha 0",
            ktx2(BC7_SRGB_BLOCK, 8, 8,
                 [opaque(11, 21, 31) * 4, opaque(41, 51, 61), holes({5}), opaque(1, 3, 5)]))
    fixture("bc7-srgb-straight-translucent.ktx2",
            "colour BC7, 4 × 4, one level, no flag, level 0 alpha 128",
            ktx2(BC7_SRGB_BLOCK, 4, 4, [translucent(100, 110, 120)]))

    # Requirement 2: the profile.
    fixture("refuse-format.ktx2", "vkFormat B8G8R8A8_UNORM",
            patched(ktx2(R8G8B8A8_UNORM, 2, 2, [rgba8(SINGLE)]), ("<I", VK_FORMAT, B8G8R8A8_UNORM)))
    fixture("refuse-transfer-srgb.ktx2", "R8G8B8A8_SRGB with a linear transfer function",
            ktx2(R8G8B8A8_SRGB, 2, 2, [rgba8(SINGLE)], transfer=TRANSFER_LINEAR))
    fixture("refuse-transfer-unorm.ktx2", "BC7_UNORM_BLOCK with an sRGB transfer function",
            ktx2(BC7_UNORM_BLOCK, 4, 4, [opaque(1, 1, 1)], transfer=TRANSFER_SRGB))
    fixture("refuse-1d.ktx2", "pixelHeight 0", patched(rgba, ("<I", PIXEL_HEIGHT, 0)))
    fixture("refuse-3d.ktx2", "pixelDepth 2", patched(rgba, ("<I", PIXEL_DEPTH, 2)))
    fixture("refuse-array.ktx2", "layerCount 2", patched(rgba, ("<I", LAYER_COUNT, 2)))
    fixture("refuse-cube.ktx2", "faceCount 6", patched(rgba, ("<I", FACE_COUNT, 6)))
    fixture("refuse-supercompressed.ktx2", "supercompressionScheme 2 (Zstandard)",
            patched(rgba, ("<I", SUPERCOMPRESSION, 2)))
    fixture("refuse-level-count-zero.ktx2", "levelCount 0", patched(rgba, ("<I", LEVEL_COUNT, 0)))
    fixture("refuse-orientation.ktx2", "KTXorientation ru",
            ktx2(R8G8B8A8_SRGB, 2, 2, [rgba8(SINGLE)], kv=[(b"KTXorientation", b"ru\0")] + WRITER))
    fixture("refuse-swizzle.ktx2", "KTXswizzle bgra",
            ktx2(R8G8B8A8_SRGB, 2, 2, [rgba8(SINGLE)], kv=[(b"KTXswizzle", b"bgra\0")] + WRITER))
    fixture("refuse-data-premultiplied.ktx2", "R8G8B8A8_UNORM with the premultiplied-alpha flag",
            ktx2(R8G8B8A8_UNORM, 2, 2, [rgba8(SINGLE)], flags=FLAG_PREMULTIPLIED))

    # Requirement 4 and the review's structural additions.
    fixture("refuse-not-ktx2.ktx2", "bytes without the KTX2 identifier", b"\x89PNG\r\n\x1a\n" + bytes(80))
    fixture("refuse-ktx1.ktx2", "the KTX 1 identifier", KTX1_IDENTIFIER + bytes(68))
    fixture("refuse-truncated-header.ktx2", "the first 60 bytes of rgba8-srgb.ktx2", rgba[:60])
    fixture("refuse-level-index-outside.ktx2", "rgba8-srgb-mips.ktx2 cut inside its level index",
            rgba_mips[:120])
    fixture("refuse-dfd-outside.ktx2", "dfdByteOffset past the end of the file",
            patched(rgba, ("<I", DFD_OFFSET, len(rgba))))
    fixture("refuse-kvd-outside.ktx2", "kvdByteLength past the end of the file",
            patched(rgba, ("<I", KVD_LENGTH, len(rgba))))
    fixture("refuse-level-outside.ktx2", "level 0's byteOffset past the end of the file",
            patched(rgba, ("<Q", level_entry(0), len(rgba))))
    fixture("refuse-level-length.ktx2", "a 2 × 2 RGBA8 level of 12 bytes",
            ktx2(R8G8B8A8_SRGB, 2, 2, [rgba8(SINGLE)[:12]]))
    fixture("refuse-level-count-chain.ktx2", "levelCount 3 at 2 × 2, whose full chain is 2",
            ktx2(R8G8B8A8_SRGB, 2, 2, [rgba8(SINGLE), rgba8(SINGLE[:1]), rgba8(SINGLE[:1])]))
    fixture("refuse-zero-width.ktx2", "pixelWidth 0", patched(rgba, ("<I", PIXEL_WIDTH, 0)))
    fixture("refuse-type-size.ktx2", "typeSize 4", patched(rgba, ("<I", TYPE_SIZE, 4)))
    fixture("refuse-uncompressed-length.ktx2", "level 0's uncompressedByteLength 32, its byteLength 16",
            patched(rgba, ("<Q", level_entry(0) + 16, 32)))
    fixture("refuse-dfd-total.ktx2", "dfdTotalSize 4 bytes more than dfdByteLength",
            patched(rgba, ("<I", dfd_at, struct.unpack_from("<I", rgba, DFD_LENGTH)[0] + 4)))
    fixture("refuse-dfd-block-size.ktx2", "a basic descriptor block 4 bytes longer than the descriptor holds",
            patched(rgba, ("<H", dfd_at + 4 + 6, 24 + 64 + 4)))
    fixture("refuse-dfd-not-basic.ktx2", "a vendor-specific first descriptor block",
            patched(rgba, ("<I", dfd_at + 4, 0x1234)))
    fixture("refuse-dfd-short-basic.ktx2", "a 16-byte basic descriptor block",
            ktx2(R8G8B8A8_SRGB, 2, 2, [rgba8(SINGLE)],
                 dfd=descriptor([struct.pack("<IHH", 0, 2, 16) + bytes([1, 1, 2, 0]) + bytes(4)])))
    part_sample = patched(basic_block(R8G8B8A8_SRGB, TRANSFER_SRGB, 0)[:32], ("<H", 6, 32))
    fixture("refuse-dfd-samples.ktx2", "a basic descriptor block of 24 bytes and 8 bytes of a sample",
            ktx2(R8G8B8A8_SRGB, 2, 2, [rgba8(SINGLE)], dfd=descriptor([bytes(part_sample)])))
    fixture("refuse-dfd-empty.ktx2", "dfdByteLength 0", patched(rgba, ("<I", DFD_LENGTH, 0)))
    fixture("refuse-kv-length.ktx2", "a key/value entry 8 bytes longer than its section",
            patched(rgba, ("<I", kvd_at, len(WRITER[0][0]) + 1 + len(WRITER[0][1]) + 8)))
    fixture("refuse-kv-no-nul.ktx2", "a key/value entry with no NUL",
            ktx2(R8G8B8A8_SRGB, 2, 2, [rgba8(SINGLE)], kv=[b"abcd"]))
    fixture("refuse-kv-short.ktx2", "a 1-byte key/value entry holding only a NUL",
            ktx2(R8G8B8A8_SRGB, 2, 2, [rgba8(SINGLE)], kv=[b"\0"]))
    fixture("refuse-kv-empty-key.ktx2", "a key/value entry whose key is empty",
            ktx2(R8G8B8A8_SRGB, 2, 2, [rgba8(SINGLE)], kv=[b"\0value\0"]))
    kv_padding = ktx2(R8G8B8A8_SRGB, 2, 2, [rgba8(SINGLE)], kv=[b"x\0"])
    fixture("refuse-kv-padding.ktx2", "a key/value entry, key x, with padding bytes FF FF",
            patched(kv_padding, ("<H", struct.unpack_from("<I", kv_padding, KVD_OFFSET)[0] + 6, 0xFFFF)))
    fixture("refuse-kv-duplicate.ktx2", "KTXwriter twice",
            ktx2(R8G8B8A8_SRGB, 2, 2, [rgba8(SINGLE)], kv=WRITER + WRITER))
    fixture("refuse-kv-unterminated.ktx2", "a KTXorientation value of rd with no terminating NUL",
            ktx2(R8G8B8A8_SRGB, 2, 2, [rgba8(SINGLE)], kv=[(b"KTXorientation", b"rd")] + WRITER))
    fixture("refuse-overlap-levels.ktx2", "level 1 inside level 0's bytes",
            patched(rgba_mips, ("<Q", level_entry(1), struct.unpack_from("<Q", rgba_mips, level_entry(0))[0] + 4)))
    fixture("refuse-overlap-header.ktx2", "the data format descriptor inside the level index",
            patched(rgba, ("<I", DFD_OFFSET, 96)))
    fixture("refuse-overflow-level-offset.ktx2", "level 0's byteOffset 2^64 - 8",
            patched(rgba, ("<Q", level_entry(0), 2**64 - 8)))
    fixture("refuse-overflow-level-length.ktx2", "level 0's byteLength and uncompressedByteLength 2^64 - 1",
            patched(rgba, ("<Q", level_entry(0) + 8, 2**64 - 1), ("<Q", level_entry(0) + 16, 2**64 - 1)))
    fixture("refuse-overflow-extent.ktx2", "pixelWidth and pixelHeight 2^32 - 1, one 16-byte level",
            patched(rgba, ("<I", PIXEL_WIDTH, 2**32 - 1), ("<I", PIXEL_HEIGHT, 2**32 - 1)))
    fixture("refuse-overflow-dfd.ktx2", "dfdByteOffset and dfdByteLength 2^32 - 16",
            patched(rgba, ("<I", DFD_OFFSET, 2**32 - 16), ("<I", DFD_LENGTH, 2**32 - 16)))
    fixture("refuse-overflow-kv-entry.ktx2", "a keyAndValueByteLength of 2^32 - 1",
            patched(rgba, ("<I", kvd_at, 2**32 - 1)))


def main():
    accepted()
    refused()
    manifest = [
        "# The KTX2 fixtures, each assembled byte by byte by its producer, using",
        "# only Python's standard library. The suite states every expected level.",
        "# fixture\tproducer\tcontents",
    ]
    for name, (description, data) in sorted(FIXTURES.items()):
        (HERE / name).write_bytes(data)
        manifest.append(f"{name}\t{PRODUCER}\t{description}")
    (HERE / "ktx2-fixtures.txt").write_text("\n".join(manifest) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
