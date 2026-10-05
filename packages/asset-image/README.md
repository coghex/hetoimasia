# hetoimasia-asset-image

Image codecs implementing [`hetoimasia-asset`](../asset/README.md)'s decoder
interface. PNG decodes through JuicyPixels into one tightly packed RGBA8 level
the GPU upload endpoint (#342) takes unchanged
([asset design](../../docs/designs/asset_design.md), AST-1).

| Module | Contents |
| --- | --- |
| `Hetoimasia.Asset.Image.Png` | `pngDecoder ∷ ImageKind → Decoder DecodedImage`; `decodePng ∷ ImageKind → Asset → ByteString → Either AssetRefusal DecodedImage` |

## Boundary

The library depends on `hetoimasia-asset`, JuicyPixels and its `zlib`
binding, and boot libraries; on no GPU, GLFW, render or runtime package. It
builds and tests in the CPU project (`cabal.project.cpu`).

The C zlib that `zlib` links is the copy `zlib-clib` bundles, pinned by the
index state: `cabal.project.common` sets `zlib`'s flags to
`+bundled-c-zlib -pkg-config`, so a libz found on the machine never reaches the
build (vision V-11), as with the Lua interpreter.

## PNG

Every PNG colour type — greyscale, greyscale with alpha, palette (with `tRNS`
alpha), RGB and RGBA — at every bit depth, interlaced or not, decodes to one
RGBA8 level at the image's width and height, top row first:

- A missing alpha channel becomes 255. A `tRNS` colour key on a greyscale or
  RGB image is not applied.
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
when every texel's alpha is 0 or 255. A 16-bit alpha of 129 rounds to 1, so it
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

## Owned state, threads and lifetimes

None. Decoding is pure: it reads only the caller's bytes, writes no file,
starts no thread and keeps nothing between calls. The premultiplication table
is a constant shared by every decode. A decoded image's bytes are the caller's.

## Tests

`asset-image-tests` is the validation group `test.asset-image`:

```sh
cabal test --project-file cabal.project.cpu hetoimasia-asset-image:asset-image-tests --test-show-details=direct
```

Its fixtures in `test/fixtures/` come from `make_fixtures.py`, an encoder that
uses only Python's standard library, independent of this decoder and of
JuicyPixels. Every expected texel is written out in the test. To regenerate
the fixtures, run `python3 make_fixtures.py` in that directory; the output is
byte-for-byte deterministic.
