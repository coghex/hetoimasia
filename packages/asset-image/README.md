# hetoimasia-asset-image

Image codecs implementing [`hetoimasia-asset`](../asset/README.md)'s decoder
interface. PNG decodes through JuicyPixels into one tightly packed RGBA8 level
the GPU upload endpoint (#342) takes unchanged
([asset design](../../docs/designs/asset_design.md), AST-1). BC7 levels are
checked, marked, and decoded to RGBA8 in software for devices that cannot
sample BC7 (AST-3). A decoded image gets a full mip chain only when its caller
asks for one (AST-4). KTX2 files carrying RGBA8 or BC7 levels are read by pure
Haskell code, with their own levels (AST-2).

| Module | Contents |
| --- | --- |
| `Hetoimasia.Asset.Image.Png` | `pngDecoder ∷ ImageKind → Decoder DecodedImage`; `decodePng ∷ ImageKind → Asset → ByteString → Either AssetRefusal DecodedImage` |
| `Hetoimasia.Asset.Image.Mips` | `MipRequest` (`mipCoverage`), `Coverage` (`CoverageFromMark`, `PreserveCoverage`, `PlainAverages`), `mipRequest`; `generateMips ∷ MipRequest → DecodedImage → Either Text DecodedImage`; `mipmapped ∷ MipRequest → Decoder DecodedImage → Decoder DecodedImage` |
| `Hetoimasia.Asset.Image.Ktx2` | `Ktx2Image` (`Ktx2Rgba8`, `Ktx2Bc7`), `ktx2DecodedImage`; `ktx2Decoder ∷ ImageKind → Decoder Ktx2Image`; `decodeKtx2 ∷ ImageKind → Asset → ByteString → Either AssetRefusal Ktx2Image` |
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

## KTX2

`decodeKtx2` reads a KTX2 file's bytes, with the asset's identity and the
caller's stated kind, as a pure function. It reads no file, performs no IO,
and uses no KTX or codec library. It returns either `Ktx2Rgba8`, an RGBA8
`DecodedImage`, or `Ktx2Bc7`, a `Bc7Image`. Either way the result has the
file's width and height and every stored level, level 0 first, in the upload
endpoint's layout. Otherwise it refuses the file, naming the asset and the
reason. The same bytes and kind always give the same result, no exception
escapes, and no part of an image comes with a refusal. KTX2 files bring their
own levels; nothing is generated for them.

### The accepted profile

A file is read only when all of these hold (design D-9):

- `vkFormat` is `R8G8B8A8_SRGB` (43), `R8G8B8A8_UNORM` (37), `BC7_SRGB_BLOCK`
  (146) or `BC7_UNORM_BLOCK` (145), and `typeSize` is 1;
- the data format descriptor's transfer function agrees with the format:
  sRGB (2) for the `_SRGB` formats, linear (1) for the `_UNORM` ones;
- the texture is two-dimensional, with one layer and one face: `pixelWidth`
  and `pixelHeight` are positive, `pixelDepth` is 0, `layerCount` is 0 or 1,
  and `faceCount` is 1;
- `supercompressionScheme` is 0;
- `levelCount` is between 1 and the extent's full chain,
  `floor (log2 (max width height)) + 1`. A partial chain is valid. A count of
  0, which asks the loader to generate levels, is refused;
- `KTXorientation` is absent or `rd`, and `KTXswizzle` is absent or `rgba`;
- a data file does not carry the descriptor's premultiplied-alpha flag;
- a colour BC7 file carries the premultiplied-alpha flag, or, without it, is
  opaque: every texel of every stored level, decoded with the BC7 decoder,
  has alpha 255. Texels a block holds outside its level's extent do not
  count. One non-opaque texel at any level refuses the file.

Only those descriptor fields and key/value entries are read for the profile.
The colour model, the colour primaries, any further descriptor block, and
every other key/value entry are not checked.

Each refusal names the condition that failed: a format outside the four, a
`typeSize` other than 1, a transfer function that disagrees with the format,
a zero width, a 1D, 3D, array or cube-map file, supercompression, a level
count of 0, an orientation or a swizzle that is not accepted, a data file
with the premultiplied-alpha flag, or a colour BC7 file without the flag
that is not opaque in every level.

### The kind and the format

A colour read (`ColourImage`) requires an `_SRGB` format, and a data read
(`DataImage`) a `_UNORM` format. A mismatch is refused, naming the kind and
the format. The kind decides the colour space; the file must agree with it.

### Structure

The whole file is checked before anything is returned, and these are refused
rather than read past or partly returned:

- bytes that do not begin with the KTX2 identifier, KTX 1 files included;
- a header, level index, data format descriptor, key/value data,
  supercompression global data or level range that lies outside the file,
  and any two occupied ranges that overlap;
- a data format descriptor with no bytes, whose `dfdTotalSize` differs from
  its `dfdByteLength`, whose blocks do not fill it exactly or have a size
  that is not a multiple of four, whose first
  block is not a basic descriptor block, or whose basic block is shorter
  than its 24 bytes of fields or is not 24 bytes plus whole 16-byte samples;
- key/value data whose entries, with their padding, do not fill it exactly,
  an entry shorter than two bytes, an entry with no NUL-terminated key or
  with an empty key, padding that is not zero, a key that appears twice, or a
  `KTXorientation` or `KTXswizzle` value that is not a NUL-terminated
  string. Other values may be binary;
- a level whose `byteLength` differs from its `uncompressedByteLength`, or
  from its format's size at its extent: `4 × w × h` bytes for RGBA8 and
  `16 × ceil (w / 4) × ceil (h / 4)` for BC7, at `w = max 1 (width >> L)` and
  `h = max 1 (height >> L)`;
- a level count beyond the full chain.

Offsets, lengths and level sizes are compared as exact integers, so a field
near its type's maximum is refused, never wrapped. Nothing is indexed,
sliced or allocated until its range is known to lie inside the file. Levels
are returned in the level index's order, level 0 first, whatever order the
file stores them in (KTX2 stores the smallest first). The padding between
levels is not returned.

### Levels

- **RGBA8**, tightly packed, top row first. A colour file without the
  premultiplied-alpha flag is straight alpha, and every level is
  premultiplied in linear light at load, exactly as a PNG is (see the
  colour-kind rule above). With the flag, colour texels are returned as
  stored. A data file's texels are returned unchanged.
- **BC7**, every level exactly as the file stores it, in a `Bc7Image`. The
  blocks are never altered or replaced by decoded texels. BC7 content for a
  colour texture with alpha must be premultiplied when it is encoded, and the
  file must carry the premultiplied-alpha flag; straight-alpha BC7 cannot be
  premultiplied without re-encoding its blocks. A colour BC7 file without
  the flag is accepted only when it is opaque in every level, as above. BC7
  is decoded only to check that opacity and to compute the mark.

On a device without BC7, a `Ktx2Bc7` result goes through the BC7 fallback
like any other `Bc7Image`. The caller passes it to `bc7Fallback` with the
device's reported support, and logs the software decode. `ktx2DecodedImage`
gives the result as a `DecodedImage` for a device that takes BC7.

### The cutout mark

Every result carries the mark computed from level 0's alpha: true exactly
when every texel's alpha is 0 or 255. For RGBA8 it is read from level 0 as
returned, since premultiplication leaves alpha unchanged. For BC7,
`bc7Image` decodes level 0 to compute it, counting only texels inside the
level's extent. The mark does not depend on the device.

## Mip chains

Mips are optional (design D-6). Pixel art drawn with nearest filtering needs
none; smoothly zoomed art does. Generating them is a separate step a caller
applies to an image it has already decoded:

```haskell
decodePng ColourImage asset bytes >>= first (AssetRefusal asset) . generateMips mipRequest
-- or, as one decoder:
mipmapped mipRequest (pngDecoder ColourImage)
```

A caller that does not ask calls the PNG decoder exactly as before: the
decoder never reaches `Hetoimasia.Asset.Image.Mips`, and its image keeps one
level. Nothing is computed, allocated or retained for mips that were not
requested.

### The chain

A generated chain holds level 0 unchanged, followed by every level down to
1 × 1. Level `L` is `max 1 (width >> L)` by `max 1 (height >> L)`, as the
upload endpoint (#342) takes them, so the levels upload unchanged. The
format, extent and cutout mark stay as decoded; the mark is level 0's. Any
levels after level 0 are replaced, so generating twice gives the same chain.
Mips are generated only for RGBA8 images: a BC7 image (`TexelBc7Srgb`,
`TexelBc7Linear`) brings its own levels and is refused. An image with a zero
width or height, one whose level 0 does not hold width × height four-byte
texels (compared without overflow), or one with no level, is refused too.
Each refusal gives the reason; `mipmapped` refuses it naming
the asset, and passes the decoder's own refusals through.

### The filter

Every level is computed from level 0 directly, never from the level above
it. Output texel (x, y) of a w × h level is the area-weighted average of
level 0's rectangle [x·W/w, (x+1)·W/w) × [y·H/h, (y+1)·H/h), each level 0
texel weighted by its overlap. Every level 0 texel contributes, at odd
extents too: a texel straddling two output texels is shared between them.

### The colour-space rule

- **Colour images** (`TexelRgba8Srgb`): level 0's colour bytes already
  encode linear premultiplied values, so they are decoded with the sRGB
  transfer function and not multiplied by alpha again. The linear colour
  and alpha are averaged, and colour is re-encoded with the inverse
  function.
- **Data images** (`TexelRgba8Linear`): all four channels are averaged as
  stored, with no premultiplication.

Every channel is rounded to nearest, halves up. Alpha, which is linear in
both kinds, is averaged, scaled and rounded in exact integer arithmetic.

### Coverage preservation

The 2D renderer's cutout variant discards a fragment whose alpha is below 0.5
(render-2d D-26). A texel counts as covered when its alpha byte is at least
128, the 8-bit form of that threshold. When coverage is preserved, each
generated level's alpha is multiplied by one scale for the whole level, so
that the level's covered fraction is as close as any scale allows to level
0's (design D-10). Level 0 is never altered.

- **Which requests.** `mipCoverage` says: `PreserveCoverage` always,
  `PlainAverages` never, and `CoverageFromMark` (the default, `mipRequest`)
  exactly when the image's cutout mark, `decodedBinaryAlpha`, is true.
- **What is achievable.** Coverage is counted on the final, rounded and
  clamped alpha bytes. A texel whose averaged alpha is zero stays zero and
  is never covered, and texels with equal averaged alpha are covered
  together, so only some counts are achievable.
- **Which scale.** If the unscaled level already has a closest achievable
  count, it is left unscaled. Otherwise, of two equally close counts the one
  nearer the unscaled count is taken; the scale then puts the least opaque
  covered texel exactly on the threshold (127.5 before rounding, so 128),
  or, when the closest count is 0, the most opaque texel at 127.
- **Saturation.** Scaled alpha is clamped to 255. A colour image's
  premultiplied colour is multiplied by the factor alpha actually changed by
  after the clamp (scaled ÷ averaged alpha, before rounding), so the
  un-premultiplied colour, and its hue, are unchanged. A data image's colour
  is not scaled.

### Atlases

Whole-image mips mix neighbouring regions of an atlas. Until the sheet
stitcher exists (design D-11), atlases are drawn with nearest filtering and
no mips; supported mipmapped content is single-image textures.

KTX2 files bring their own levels and are out of this step's scope (AST-2).

## Owned state, threads and lifetimes

None. Decoding is pure: it reads only the caller's bytes, writes no file,
starts no thread and keeps nothing between calls. The premultiplication table
and the BC7 partition and weight tables are constants shared by every decode.
BC7 checking, decoding, the mark and the fallback step are pure too, as are
KTX2 reading and mip generation: the same bytes and kind always give the same
result, and the same image and request always give the same levels. The
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

The mip examples' expected texels come from `test/fixtures/mip_reference.py`,
an independent reference using only Python's standard library, with exact
rational footprints; run `python3 mip_reference.py` in that directory to
print them. Their coverage and colour properties are checked against the
suite's own exact-rational reference averages.

Its KTX2 fixtures, `test/fixtures/*.ktx2`, come from `make_ktx2_fixtures.py`.
It assembles each file byte by byte using only Python's standard library, and
shares no code with the reader. `ktx2-fixtures.txt` records each fixture's
producer and version beside it, and each file except the one without
key/value data names them in a `KTXwriter` entry. The BC7 fixtures are mode-6
blocks with constant endpoints, so every texel's alpha follows from the
block's construction. The suite states every expected level, and the expected
premultiplied RGBA8 texels are computed independently of the reader. Run
`python3 make_ktx2_fixtures.py` in that directory to regenerate them; the
output is byte-for-byte deterministic.
