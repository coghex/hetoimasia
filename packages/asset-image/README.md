# hetoimasia-asset-image

Image codecs implementing [`hetoimasia-asset`](../asset/README.md)'s decoder
interface. PNG decodes through JuicyPixels into one tightly packed RGBA8 level
the GPU upload endpoint (#342) takes unchanged
([asset design](../../docs/designs/asset_design.md), AST-1). BC7 levels are
checked, marked, and decoded to RGBA8 in software for devices that cannot
sample BC7 (AST-3).

| Module | Contents |
| --- | --- |
| `Hetoimasia.Asset.Image.Png` | `pngDecoder ∷ ImageKind → Decoder DecodedImage`; `decodePng ∷ ImageKind → Asset → ByteString → Either AssetRefusal DecodedImage` |
| `Hetoimasia.Asset.Image.Bc7` | `Bc7Format` (`Bc7Srgb`, `Bc7Linear`); `Bc7Image` and `bc7Image ∷ Asset → Bc7Format → Word32 → Word32 → [ByteString] → Either AssetRefusal Bc7Image`, `bc7DecodedImage`; `decodeBc7 ∷ Bc7Image → DecodedImage`; `Bc7Support`, `bc7Fallback ∷ Bc7Support → Bc7Image → Bc7Fallback`, `fallbackImage`, `fallbackSoftwareDecode` |

## Boundary

The library depends on `hetoimasia-asset`, JuicyPixels and its `zlib`
binding, `vector`, and boot libraries; on no `hetoimasia-foundation`, GPU,
GLFW, render or runtime package, and so holds no `Logger`. It builds and tests
in the CPU project (`cabal.project.cpu`).

The C zlib that `zlib` links is the copy `zlib-clib` bundles, pinned by the
index state: `cabal.project.common` sets `zlib`'s flags to
`+bundled-c-zlib -pkg-config`, so a libz found on the machine never reaches the
build (vision V-11), as with the Lua interpreter.

## PNG

Every PNG colour type — greyscale, greyscale with alpha, palette (with `tRNS`
alpha), RGB and RGBA — at every bit depth, interlaced or not, decodes to one
RGBA8 level at the image's width and height, top row first:

- A greyscale or RGB image's `tRNS` colour key is honoured, at every bit depth
  (greyscale 1, 2, 4, 8 and 16; RGB 8 and 16): a texel whose stored samples
  exactly equal the key's, compared at the file's own bit depth before any
  reduction to 8 bits, has alpha 0, and every other texel alpha 255. A 16-bit
  sample that shares only the key's high byte is not keyed. A malformed `tRNS`
  chunk — a length the colour type does not take, one on a colour type with
  its own alpha channel, or a second `tRNS` — is ignored, as JuicyPixels
  decodes such files without complaint. JuicyPixels itself applies no colour
  key, and misreads a 1-, 2- or 4-bit greyscale key as a table of palette
  alphas; this decoder applies the key to the stored sample instead.
- Any other missing alpha channel becomes 255. Palette `tRNS` alpha is applied
  as JuicyPixels reads it.
- 16-bit components, alpha included, round to nearest:
  nearest(v × 255 ÷ 65535), so 129 becomes 1, not 0.
- Colour-space chunks (`gAMA`, `cHRM`, `sRGB`, `iCCP`) never change a texel.

### The colour-kind rule

The caller states with every decode whether the image is colour or data. The
file never decides.

- **`ColourImage`** yields `TexelRgba8Srgb`, premultiplied in linear light:
  each colour channel is decoded with the sRGB transfer function
  (IEC 61966-2-1), multiplied by alpha ÷ 255, re-encoded with the inverse and
  rounded to nearest. Alpha is unchanged; alpha 255 leaves the channels
  unchanged and alpha 0 makes them zero, exactly. Multiplying the encoded
  values directly would darken semi-transparent edges (design D-4). The
  results come from a 64 KiB table of every (alpha, channel) pair, built once
  and identical on every platform.
- **`DataImage`** (masks, face maps) yields `TexelRgba8Linear`, with texels
  exactly as decoded and not premultiplied.

### The cutout mark

Every decoded image, of either kind, carries `decodedBinaryAlpha`: true exactly
when every texel's alpha is 0 or 255. A texel keyed out by `tRNS` has alpha 0,
so an image whose only transparency is a colour key is binary; in a colour
image that texel is premultiplied to zero. A 16-bit alpha of 129 rounds to 1, so it
is not binary.

### Refusals

These are refused with the asset and a reason, never with part of an image:
empty bytes; bytes without the PNG signature; a truncated PNG (it lacks a
complete IEND); a chunk failing its CRC, the IHDR chunk's included; a zero
width or height; a bit depth the colour type does not allow; a compressed
stream that fails to inflate, or inflates to fewer bytes than the header's
extent needs; a palette index outside the palette; and anything else
JuicyPixels cannot decode.

JuicyPixels reads the inflated image data and the palette without bounds
checks. The checks above that it does not make run before it, or where the
palette is applied, so it never reads past a buffer. Each result is evaluated
completely before it is returned, and any synchronous exception that
evaluation throws becomes a refusal.

## BC7

### The BC7 image

A `Bc7Image` holds BC7 levels exactly as the upload endpoint takes them: a
width and height, and one or more levels, base level first, each its rows of
4 × 4 blocks of sixteen bytes, top row first, a block crossing the level's
right or bottom edge stored whole. Level `L` is `max 1 (width >> L)` ×
`max 1 (height >> L)`. `bc7Image` is the only way to make one, and refuses,
naming the asset:

- a zero width or height;
- no levels, or more than the extent's full chain,
  `floor (log2 (max width height)) + 1`; a partial chain is valid;
- a level whose byte count is not `ceil (w / 4) × ceil (h / 4) × 16` at its
  extent, computed without integer wraparound.

`Bc7Srgb` and `Bc7Linear` correspond one-to-one to the endpoint's `Bc7Srgb`
and `Bc7Linear`; `bc7DecodedImage` gives the image as a `DecodedImage` in
`TexelBc7Srgb` or `TexelBc7Linear` for upload, levels unchanged.

### The decoder

`decodeBc7` is a pure function from a `Bc7Image` to an RGBA8 `DecodedImage`
with the same extent, the same number of levels and each level's extent:

- every mode, 0 to 7, decodes as the BC7 format specifies, with its
  partitions, anchor indices, p-bits, rotation and index selection;
- texels of a block outside the level's extent are discarded;
- a block with no valid mode (a first byte of zero) decodes to four zero
  channels in every texel, as the format defines;
- decoding is exact and deterministic.

`Bc7Srgb` decodes to `TexelRgba8Srgb` and `Bc7Linear` to `TexelRgba8Linear`,
with texels exactly as the blocks encode them: no transfer function is
applied and nothing is premultiplied. BC7 colour textures with alpha must be
premultiplied when they are encoded (design D-4, D-9), since straight-alpha
BC7 cannot be premultiplied without re-encoding its blocks; BC7 data textures
stay unpremultiplied. The decoder changes neither.

### The cutout mark

A `Bc7Image`'s `bc7BinaryAlpha` is computed by `bc7Image`, on every device, by
decoding level 0's alpha: true exactly when every texel of level 0 inside its
extent has alpha 0 or 255. Texels a block holds outside the extent, and other
levels, do not count. The decoded RGBA8 image, and either outcome of the
fallback, carries the same mark.

### Devices without BC7

`bc7Fallback` is a pure step. The caller passes the device's reported BC7
support (`DeviceTakesBc7` or `DeviceLacksBc7`, from the GPU services' BC
support query, which this package never makes) and a `Bc7Image`, and gets:

- `KeptBc7 image`, the BC7 image unchanged, when the device takes BC7;
- `DecodedInSoftware (SoftwareDecode asset format) decoded`, the image
  decoded by `decodeBc7`, when it does not.

The result states whether this step converted BC7 storage to RGBA8
(`fallbackSoftwareDecode`), with the asset's identity and its BC7 format; the
image to upload is `fallbackImage`. Level 0's alpha is decoded for the mark
either way, so `KeptBc7` does not mean no block was ever decoded.

**The caller logs the fallback.** Nothing in this package logs, holds a
logger or keeps state across calls. The code that chooses the fallback for a
device — the 2D renderer or the application — logs one `Warning` per fallback
instance, normally once per device, from the `SoftwareDecode` the result
carries (design D-7).

**Memory.** On a device without BC7, decoded RGBA8 levels take nominally four
times the memory of their BC7 blocks: that is the texel-payload ratio for
fully populated 4 × 4 blocks, 4 × w × h bytes for RGBA8 against
16 × ceil (w / 4) × ceil (h / 4) for BC7 per level. Levels with cropped edge
blocks and small mips have a lower ratio, and the device's allocation is
its own.

## Owned state, threads and lifetimes

None. Decoding is pure: it reads only the caller's bytes, writes no file,
starts no thread and keeps nothing between calls. The premultiplication table
and the BC7 partition and weight tables are constants shared by every decode.
BC7 checking, decoding, the mark and the fallback step are pure too, and the
package holds no logger. A decoded image's bytes are the caller's.

## Tests

`asset-image-tests` is the validation group `test.asset-image`:

```sh
cabal test --project-file cabal.project.cpu hetoimasia-asset-image:asset-image-tests --test-show-details=direct
```

Its PNG fixtures in `test/fixtures/` come from `make_fixtures.py`, an encoder
that uses only Python's standard library, independent of this decoder and of
JuicyPixels. Every expected texel is written out in the test. To regenerate
the fixtures, run `python3 make_fixtures.py` in that directory; the output is
byte-for-byte deterministic.

Its BC7 fixture, `test/fixtures/bc7-reference.txt`, comes from
`make_bc7_fixtures.py`, which builds blocks bit by bit (every partition of
the partitioned modes, every rotation and index selection, random and
extreme fields in every mode, alpha cases for the mark, and a 9 × 6 image's
full chain) and records the texels of an independent reference decoder,
Pillow 12.2.0's BCn decoder, named with its version in the file's header.
No expected texel comes from the decoder under test. The script refuses any
other Pillow version; with Pillow 12.2.0 installed, run
`python3 make_bc7_fixtures.py` in that directory, and the output is
byte-for-byte deterministic. Two expectations are stated in the suite
instead: the sprites sample's mode-6 block and its `bc7Decoded` oracle, and a
block with no valid mode decoding to zeros, as the BC7 format defines it
(Pillow 12.2.0 gives that block alpha 255).
