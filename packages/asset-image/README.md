# hetoimasia-asset-image

Image codecs implementing [`hetoimasia-asset`](../asset/README.md)'s decoder
interface: PNG to one tightly packed RGBA8 level, a bounded PNG path for the
Lua texture profile, BC7 checking and software decoding, KTX2 reading, optional
mip generation, and pure helpers for data maps and atlas regions.

Modules, under `Hetoimasia.Asset.Image`: `Png`, `PngPreflight`, `PngDecode`,
`Mips`, `Ktx2`, `Bc7`, `DataMap`, `Region`.

## Boundary

The library depends on `hetoimasia-asset`, JuicyPixels, its `zlib` binding,
`vector` and boot libraries. It depends on no foundation, GPU, GLFW, render or
runtime package, so it holds no logger. It builds in the CPU project.

The C zlib is the copy `zlib-clib` bundles: `cabal.project.common` sets
`+bundled-c-zlib -pkg-config`, so a system libz never reaches the build.

Everything is pure except `decodeBounded`, which is effectful only through the
caller's byte account and owns nothing beyond one call. The package starts no
thread and keeps nothing between calls. A decoded image's bytes are the
caller's.

## PNG

`decodePng` decodes every PNG colour type at every bit depth, interlaced or
not, through JuicyPixels to one RGBA8 level, top row first.

- A greyscale or RGB `tRNS` colour key is honoured at the file's own bit depth
  before any reduction to 8 bits: a matching texel has alpha 0, every other
  255. JuicyPixels itself applies no colour key and misreads low-depth
  greyscale keys, so this decoder applies the key to the stored sample. A
  malformed `tRNS` chunk is ignored.
- 16-bit components round to nearest: `nearest(v × 255 ÷ 65535)`.
- Colour-space chunks (`gAMA`, `cHRM`, `sRGB`, `iCCP`) never change a texel.

**The colour-kind rule.** The caller states with every decode whether the
image is colour or data; the file never decides.

- `ColourImage` yields `TexelRgba8Srgb`, premultiplied in linear light: each
  channel is decoded with the sRGB transfer function, multiplied by
  alpha ÷ 255, re-encoded and rounded. Multiplying the encoded values directly
  would darken semi-transparent edges.
- `DataImage` (masks, face maps) yields `TexelRgba8Linear`, texels exactly as
  decoded and not premultiplied.

**The cutout mark.** Every decoded image carries `decodedBinaryAlpha`: true
exactly when every texel's alpha is 0 or 255.

**Refusals** name the asset and a reason and never come with part of an image:
empty or non-PNG bytes, truncation, a CRC failure, a zero extent, an illegal
bit depth, a stream that fails to inflate or is too short, a palette index
outside the palette. JuicyPixels reads inflated data and the palette without
bounds checks, so those checks run before it. Every synchronous exception from
evaluation becomes a refusal.

## Bounded static-PNG preflight

`PngPreflight` is the opt-in boundary the M1 Lua texture profile uses. Before
any size-derived allocation and before a decoder runs, it decides whether the
bytes are a static PNG inside the caller's limits. `decodePng` does not use it.
A successful preflight is not a decoded image: it says the framing and CRCs
are sound, the header is inside the profile, and the image data inflates to at
least the scanline bytes the header needs and at most the inflation limit.

| Limit | M1 value (`m1PngLimits`) | Bounds |
| --- | --- | --- |
| `settingSourceBytes` | 32 MiB | the encoded bytes |
| `settingChunks` | 4,096 | chunks from IHDR through IEND |
| `settingWidth`, `settingHeight` | 2,048 each | each axis |
| `settingPixels` | 4,194,304 | width × height |
| `settingRgba8Bytes` | 16 MiB | the single RGBA8 output |
| `settingInflatedBytes` | 40 MiB | decompressed scanline bytes |

- `pngLimits` refuses any value below 1 or above 2³¹ − 1. No value means
  unlimited.
- Everything derived from a header is an `Integer`, compared with its limit
  first and narrowed only when within it. Nothing wraps or clamps, and nothing
  is allocated from a declared size.
- All baseline variants are accepted, noninterlaced or Adam7. Recognition is
  by the signature. Animated PNGs (`acTL`, `fcTL`, `fdAT`) are refused, never
  decoded as a first frame.
- Ancillary chunks are framed, counted and CRC-checked but never decompressed.

**Refusal classes**, with a bounded reason that never contains the offending
bytes:

- `UnsupportedFormat`: not a PNG, or an animated PNG;
- `MalformedPng`: has the signature but is not a sound PNG of the profile;
- `ExceededLimit kind`: sound so far and over a limit.

The order of checks is fixed and the first failure decides the class: source
length, signature, each chunk in file order (framing, chunk limit, CRC,
meaning), the header, the size limits, then inflation.

**Faults are not refusals.** An allocator failure, an inflater fault other
than its own corrupt-stream report, and any asynchronous exception propagate
as exceptions. This is deliberately unlike `decodePng`.

**Bounded inflation.** The IDAT chunks are handed to the inflater as slices,
and each output piece is counted as it is produced. The piece that crosses the
limit ends the work, independently of the header, so a one-pixel image with
excessive data cannot consume unlimited work.

A `PngPreflight` is built only by `preflightPng` and carries the bytes and
limits it checked, so it cannot authorize decoding other bytes. It retains the
caller's `ByteString` and slices of it; nothing inflated is kept.

## Bounded PNG decode

`PngDecode.decodeBounded account preflight` is the decoding stage of the same
profile. It does not wrap JuicyPixels, whose intermediate allocations cannot
be accounted. It feeds the IDAT slices to the zlib inflater one output piece
at a time into one working buffer, unfilters each scanline in place, and
writes each pixel to its final place in the output. There is no sample vector,
no pass image and no second copy.

The result is one RGBA8 level under the colour-image contract above.
`decodeBoundedWith DecodeData` produces the data-image form instead, byte for
byte what the general decoder gives, with identical reservations and refusals.

### The accounting contract

The caller passes a `PayloadAccount` (`reservePayload`, `releasePayload`) onto
its pipeline's byte bank. The decoder reserves each buffer's bytes before
allocating it; a refused reservation is `ExceededLimit LimitWorkspaceBytes`.

| Stage | Bytes | Released |
| --- | --- | --- |
| `StageOutput` | the RGBA8 level | on every outcome but success; on success it is the result |
| `StageScratch` | `fixedScratchBytes` (173,056) plus the widest row | before the call returns |
| `StageWorking` | the filtered scanlines | before the call returns |

- On success the account has gained exactly the output's bytes. On a refusal
  or any exception, asynchronous included, it has gained nothing.
- The encoded input is the caller's charge: its whole backing allocation, not
  the view's length.
- **Hand-over.** The output reservation passes to the caller when the call
  returns. A caller that can be cancelled calls the decoder under `mask`; the
  decoder stays cancellable between steps (one inflater piece or one row).
- A staging copy of the level is a separate payload the pipeline charges.
- A reservation runs under `mask` and a release under `uninterruptibleMask_`,
  so an account's release must have a controlled blocking duration. Failed
  releases are retained beside the body's failure in a
  `PayloadCleanupFailure`.
- A caller must not release the workspace or the input while a call is in
  progress. The call returning is the only evidence that it is done.

Beyond the preflight's refusals this stage also refuses a scanline whose
filter-type byte is not 0 to 4, an indexed image with a missing or malformed
`PLTE`, and a palette index outside the palette. JuicyPixels treats a filter
byte above 4 as "none", and `decodePng` still does.

**The peak** is at conversion: `input + output + scratch + scanlines`. At the
M1 maxima the largest is 16-bit RGBA under Adam7 at 84,079,360 bytes, under
the 128 MiB bank (`m1WorkspaceBytes`), so no approved variant is refused for
the bank. The figures exclude allocator overhead, uncollected garbage and GPU
memory; this is not a whole-process heap guarantee.

### Dependency audit

With `zlib` 0.7.1.1 (bundled C zlib 1.3.2) and JuicyPixels 3.3.9:

- The bounded path calls no JuicyPixels decoder; the only JuicyPixels function
  it runs is `pngComputeCrc`.
- The `zlib` binding's incremental interface allocates, per stream, the
  inflate state (about 7 KiB) and a 32 KiB window, and one 32 KiB buffer per
  output piece. Input is handed over by reference. The state is freed when the
  stream ends or fails, and by a finalizer otherwise. Every step runs under
  `mask_`.

## Data maps (TRA-15)

`DataMap` is pure validation and CPU coverage for a decoded data level.

- **Binary coverage.** `buildBinaryCoverage width height level` accepts only
  alpha 0 and 255; any other alpha is `CoverageNotBinary column row alpha` and
  nothing is thresholded. The result is an immutable `CoveragePlane`: one bit
  per texel, row-major, no row padding, least significant bit first.
- **The sampling reference.** `sampleIndex n u` is
  `min (n − 1) (floor (clamp u 0 1 × n))`, evaluated exactly on the
  coordinate's mantissa and exponent, so the predecessor of an interior
  boundary is never rounded up onto it. An interior boundary selects the
  higher index and the outer edge the last texel.
- **Normal encodings.** `UnitNormalRgbV1` stores a unit normal as
  `round (128 + 127 × n)` per channel. `checkNormalEncoding` requires every
  nontransparent texel to have R, G and B in 1..255 and not be
  `(128, 128, 128)`.

## Image regions (TRA-17)

`Region` makes every texture an atlas; a single image is a one-region atlas.
An `ImageRegion` is a positive-extent rectangle. A `RegionView` is a rectangle
of one parent image's `CoveragePlane`, held by reference, carrying the
parent's version and a layout identity. Sampling applies `sampleIndex` to the
region's own extent and only then adds the origin, so a lookup never reaches a
neighbouring region.

## BC7

A `Bc7Image` holds BC7 levels as the upload endpoint takes them: base level
first, rows of 4 × 4 blocks of sixteen bytes, edge blocks stored whole.
`bc7Image` is the only constructor and refuses a zero extent, no levels or
more than the full chain (a partial chain is valid), and a level of the wrong
byte count.

- `decodeBc7` is a pure, exact decoder of every mode to RGBA8 at the same
  extents. No transfer function is applied and nothing is premultiplied.
- BC7 colour textures with alpha must be premultiplied when they are encoded;
  straight-alpha BC7 cannot be premultiplied without re-encoding its blocks.
- `bc7BinaryAlpha` is computed from level 0's decoded alpha, inside its extent
  only, on every device.
- `bc7Fallback support image` answers `KeptBc7` when the device takes BC7 and
  `DecodedInSoftware` otherwise. The caller supplies the device's support and
  logs one `Warning` per fallback; nothing here logs. Decoded RGBA8 takes
  nominally four times the memory of its BC7 blocks.

## KTX2

`decodeKtx2` reads a KTX2 file's bytes as a pure function, using no KTX or
codec library, and returns `Ktx2Rgba8` or `Ktx2Bc7` with every stored level,
level 0 first. KTX2 files bring their own levels; nothing is generated.

A file is read only when all of these hold:

- `vkFormat` is `R8G8B8A8_SRGB`, `R8G8B8A8_UNORM`, `BC7_SRGB_BLOCK` or
  `BC7_UNORM_BLOCK`, with `typeSize` 1;
- the descriptor's transfer function agrees with the format;
- it is two-dimensional with one layer and one face;
- there is no supercompression;
- `levelCount` is between 1 and the full chain (0, which asks the loader to
  generate levels, is refused);
- `KTXorientation` is absent or `rd`, and `KTXswizzle` is absent or `rgba`;
- a data file does not carry the premultiplied-alpha flag;
- a colour BC7 file carries that flag or is opaque in every stored level.

A colour read requires an `_SRGB` format and a data read a `_UNORM` one. The
whole file is checked before anything is returned: every range must lie inside
the file without overlap, the descriptor and key/value data must be well
formed, and each level must have its format's exact size. Offsets and lengths
are compared as exact integers.

A colour RGBA8 file without the premultiplied flag is premultiplied in linear
light at load, as a PNG is. BC7 blocks are never altered.

## Mip chains

Mips are optional and generated only when the caller asks:
`generateMips mipRequest image`, or `mipmapped mipRequest decoder`.

- The chain is level 0 unchanged followed by every level down to 1 × 1.
  Generating twice gives the same chain. Only RGBA8 images are accepted.
- Every level is computed from level 0 directly, as the area-weighted average
  of the level 0 rectangle each output texel covers.
- Colour images average in linear light and re-encode; data images average
  the stored bytes. Channels round to nearest, halves up.
- **Coverage preservation.** The cutout variant discards alpha below 0.5, so a
  texel counts as covered at alpha 128 or more. When coverage is preserved,
  each generated level's alpha is multiplied by one scale so its covered
  fraction is as close as possible to level 0's. `CoverageFromMark` (the
  default) preserves exactly when `decodedBinaryAlpha` is true;
  `PreserveCoverage` always; `PlainAverages` never. A colour image's
  premultiplied colour is scaled by the same factor, so hue is unchanged.
- **Atlases.** Whole-image mips mix neighbouring regions, so atlases are drawn
  with nearest filtering and no mips; mipmapped content is single-image
  textures.

## Tests

```sh
cabal test --project-file cabal.project.cpu hetoimasia-asset-image:asset-image-tests --test-show-details=direct
```

This is the validation group `test.asset-image`.
