# hetoimasia-asset-image

Image codecs implementing [`hetoimasia-asset`](../asset/README.md)'s decoder
interface. PNG decodes through JuicyPixels into one tightly packed RGBA8 level
the GPU upload endpoint (#342) takes unchanged
([asset design](../../docs/archive/designs/asset_design.md), AST-1). BC7 levels are
checked, marked, and decoded to RGBA8 in software for devices that cannot
sample BC7 (AST-3). A decoded image gets a full mip chain only when its caller
asks for one (AST-4). KTX2 files carrying RGBA8 or BC7 levels are read by pure
Haskell code, with their own levels (AST-2).

| Module | Contents |
| --- | --- |
| `Hetoimasia.Asset.Image.Png` | `pngDecoder ∷ ImageKind → Decoder DecodedImage`; `decodePng ∷ ImageKind → Asset → ByteString → Either AssetRefusal DecodedImage` |
| `Hetoimasia.Asset.Image.PngPreflight` | `preflightPng ∷ PngLimits → Asset → ByteString → Either PngRefusal PngPreflight`; `PngLimits`, `pngLimits ∷ PngLimitSettings → Either LimitsRefusal PngLimits`, `m1PngLimits`; `PngRefusal` (`PngRefusalClass`: `UnsupportedFormat`, `MalformedPng`, `ExceededLimit LimitKind`); `PngPreflight` and its accessors |
| `Hetoimasia.Asset.Image.PngDecode` | `decodeBounded ∷ PayloadAccount → PngPreflight → IO (Either PngRefusal DecodedImage)`; `PayloadAccount` (`reservePayload`, `releasePayload`), `PayloadStage` (`StageOutput`, `StageScratch`, `StageWorking`), `PayloadCleanupFailure`; `decodeReservations`, `decodeReservationsFor`, `decodePeakBytes`, `fixedScratchBytes`, `m1WorkspaceBytes` |
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

## Bounded static-PNG preflight

`Hetoimasia.Asset.Image.PngPreflight` is the opt-in boundary the M1 Lua
texture profile uses (design D-65, D-77; LFE-14). It decides, before any
size-derived allocation and before a decoder runs, whether a PNG's bytes are
a static PNG inside a caller's limits. `pngDecoder` and `decodePng` do not
use it, impose none of these limits and are unchanged; so are the KTX2, BC7
and mip entry points.

A successful preflight is **not** a decoded image and not a usable texture. It
says: under these limits, these bytes have sound framing and CRCs, a header
inside the profile, and an image data stream that inflates to at least the
scanline bytes the header needs and at most the inflation limit. Decoding to
RGBA8 and the accounting of its buffers belong to the next stage (LFE-15).

### The limits

`PngLimitSettings` states seven limits as `Integer`s; `pngLimits` validates
them into `PngLimits`; `m1PngLimits` is the approved profile. KiB and MiB are
powers of 1024.

| Limit | M1 value | Bounds |
| --- | --- | --- |
| `settingSourceBytes` | 32 MiB | the encoded bytes supplied |
| `settingChunks` | 4,096 | chunks from IHDR through IEND inclusive |
| `settingWidth`, `settingHeight` | 2,048 each | each axis, in pixels |
| `settingPixels` | 4,194,304 | width × height |
| `settingRgba8Bytes` | 16 MiB | the eventual single RGBA8 output, 4 bytes a pixel |
| `settingInflatedBytes` | 40 MiB | decompressed scanline bytes, filter bytes included |

`pngLimits` refuses, naming the first limit in the order above (a bounded
`LimitsRefusal`), any value below 1 or above `largestLimit` = 2³¹ − 1. Zero,
negative and oversized values are all refused, and no value means
"unlimited". The upper bound is the PNG specification's largest dimension and a
value every `Int` represents, so no limit, narrowing or allocation size
depends on the machine word. Smaller limits (the suite's boundary cases) go
through the same validation and arithmetic; there is no Lua or product tuning
interface.

### Arithmetic

Everything derived from a header is an `Integer`: chunk lengths against the
remaining input, `width × height`, `× 4`, the packed row length
`⌈width_p × bitsPerPixel ÷ 8⌉` and its filter byte for each pass, and the
pass extents of Adam7 (an empty pass, no columns or no rows, contributes
nothing, not even filter bytes). A value is compared with its limit first and
narrowed to `Int` only when it is within a limit, which is at most 2³¹ − 1.
Nothing wraps or clamps. A declared huge chunk length or dimension is
refused without attempting its allocation: preflight allocates nothing from a
declared size at all.

At the M1 maxima a 2048 × 2048 RGBA16 image needs 33,556,480 scanline bytes
(33,558,272 with Adam7): under the 40 MiB limit, so the inflation limit binds
the stream, not any legal M1 header, and the pixel and RGBA8 limits equal the
axis limits' product (2048² and 2048² × 4). The suite reaches those limits'
one-past cases with smaller injected limits.

### The profile

All the supported baseline variants are accepted: greyscale at 1, 2, 4, 8 and
16 bits; palette at 1, 2, 4 and 8; RGB, greyscale-alpha and RGBA at 8 and 16;
each noninterlaced or Adam7. Recognition is by the eight-byte signature, never
an extension or hint. Animated PNGs (any `acTL`, `fcTL` or `fdAT` chunk up to
IEND, before or after the image data) are refused, never decoded as a first
frame.

Colour and profile metadata (`gAMA`, `cHRM`, `sRGB`, `iCCP`, text, anything
else) is framed, counted and CRC-checked but never decompressed and never
built into an object graph; the source and chunk limits bound it. A
transparency key is read as the general decoder reads it
(`preflightColourKey`: exactly one `tRNS` chunk of the colour type's length,
else ignored). A palette image's first `PLTE` and every `tRNS` chunk's data
are kept as slices for decoding (`preflightPalette`, `preflightTransparency`).
Palette indices, `tRNS` length for palette images and texel conversion are
decoding's.

### Preflight refusals

`PngRefusal` carries the asset, a class and a bounded reason built from fixed
text and numbers (never the offending bytes). The class is what a texture
provider maps:

- `UnsupportedFormat`: not a PNG, including empty input and a proper prefix of
  the signature; or an animated PNG.
- `MalformedPng`: begins with the complete signature and is not a sound PNG of
  the profile: truncation (including a declared chunk length past the end of
  the input, refused before anything is taken from it), a CRC failure in any
  chunk, no or a misplaced IHDR, no IEND, an invalid header, or an image data
  stream that is corrupt, truncated, or inflates to fewer bytes than the header
  needs.
- `ExceededLimit kind`: sound so far and over a limit.

**The order of the checks** is fixed, and the first that fails decides the
class: (1) the source length against its limit; (2) the signature; (3) each
chunk in file order from the first to IEND — its framing, then the chunk limit,
then its CRC, then its meaning (the first chunk must be a 13-byte IHDR; an
animation chunk is unsupported); (4) the header; (5) width, height, pixels,
RGBA8 bytes, then the header's scanline bytes against the inflation limit; (6)
inflation. A chunk-count overflow therefore wins over a later animation marker,
and an animation marker wins over a later CRC failure.

A dimension above 2³¹ − 1 is malformed, as the specification forbids it; one
between the limit and 2³¹ − 1 is `ExceededLimit`. Bytes after a complete IEND
are not parsed and do not count as chunks, but count towards the source limit;
the general decoder accepts them too, and they are accepted here.

**Faults are not refusals.** An allocator failure, an exception from the
inflater binding other than its own corrupt-or-truncated report, or any other
fault is never reported as one of the three classes. `preflightPng` does not
catch it: it propagates as an exception when the result is demanded, an
asynchronous exception included, so cancellation is never a successful result
or a malformed-content answer. This is deliberately unlike `decodePng`, which
turns every synchronous exception into a refusal. The result is built
strictly: a value in hand holds no suspended computation, inflater state or
inflater output.

### Bounded inflation

The IDAT chunks are one zlib stream, handed to the inflater as their slices
without concatenation. The preflight counts each output piece the moment the
inflater produces it, as an `Integer` comparison, and the piece that crosses the
inflation limit ends the work: the rest of the stream is never inflated. The
limit holds independently of the header, so a one-pixel image with excessive
data cannot consume unlimited work; and the header's scanline bytes are checked
against it before inflation starts. A stream that fails or ends early inside the
budget is `MalformedPng`; one that inflates to fewer bytes than the header needs is
`MalformedPng`; more than needed but within the limit is accepted, as the general
decoder accepts it.

The suite shows the stop through the public entry: past the budget by more than
one inflater piece (at most 32 KiB) a stream continues with a hand-written
reserved deflate block type, and the answer is `ExceededLimit`, not corruption;
the same stream with the budget beyond it is `MalformedPng`. It also splits the
stream over many IDAT chunks, and puts the budget inside an output piece.

### What a result retains, and its accounting

A `PngPreflight` can be built only by `preflightPng`, and carries the bytes and
limits it checked (`preflightSource`, `preflightLimits`), so it cannot authorize
decoding other bytes. It retains the caller's `ByteString` itself, not a copy,
and slices of it: the data of each IDAT chunk (`preflightImageData`), the first
`PLTE` and each `tRNS`. Nothing inflated is kept, only its count. The slices keep
the source buffer alive; dropping the result releases everything. Preflight
owns no thread, file or native handle.

| Item | Size | Lifetime |
| --- | --- | --- |
| Input view | the caller's buffer, not copied; at most the source limit | the caller's, kept alive by the result |
| Chunk descriptors | the scan's few words of state, plus one slice per IDAT, `tRNS` and the first `PLTE`: at most the chunk limit | the scan; retained slices live in the result |
| Inflater state | one zlib stream | from the first input to stream end or failure, or, when the budget ends the work, to the binding's finalizer |
| Inflater output scratch | one piece at a time, at most 32 KiB | counted and dropped |
| Inflated image | none; only the count | not applicable |

**Dependency assumptions.** The inflater's native state is created and
released by the pinned `zlib` binding (`inflateEnd` runs when a stream ends or
fails, and as a foreign-pointer finalizer for a stream the budget abandons);
this package adds no disposal machinery and holds the state only inside the
`ST` computation that drives it. Its per-call state is one inflater and one
output piece. The bundled C zlib is used; `cabal.project.common` keeps a system
libz out of the build. These figures cover the preflight only: the complete
decoder's workspace is not accounted here.

### The decoding stage

Preflight does not bound a decoder. [The bounded decode](#bounded-png-decode)
is the stage that does: it decodes from `preflightSource` with its own
inflation, held to the inflation limit in `preflightLimits` again, never the
unbounded general decoder, and accounts for the RGBA8 output and every
intermediate it allocates.

## Bounded PNG decode

`Hetoimasia.Asset.Image.PngDecode` is the decoding stage of the M1 Lua texture
profile (design D-65, D-77; LFE-15), over a `PngPreflight`. It is opt-in:
`pngDecoder` and `decodePng` are unchanged and still decode through
JuicyPixels, and so are the KTX2, BC7 and mip entry points. It imports no Lua
engine, profile, graphics package, console or registry; the limits are the
preflight's, and the byte account is a handle the caller passes.

```haskell
decodeBounded ∷ PayloadAccount → PngPreflight → IO (Either PngRefusal DecodedImage)

data PayloadAccount = PayloadAccount
  { reservePayload ∷ PayloadStage → Int → IO Bool
  , releasePayload ∷ PayloadStage → Int → IO ()
  }
```

### What it decodes

Every variant the preflight accepts: greyscale at 1, 2, 4, 8 and 16 bits,
palette at 1, 2, 4 and 8, RGB, greyscale-alpha and RGBA at 8 and 16, each
non-interlaced or Adam7. There is no first-frame fallback, no trial codec
dispatch and no narrowing of a format. The result is one `DecodedImage` of the
file's width and height with exactly one level: tightly packed RGBA8, top row
first, no padding and no mip chain, in `TexelRgba8Srgb`, each colour channel
premultiplied once in linear light by its texel's alpha and alpha unchanged,
with `decodedBinaryAlpha` as everywhere. The texel contract is the colour-image
contract above, applied exactly once: transparency keys and palette alpha at the
stored depth, 16-bit rounding to nearest, palette indices checked against the
palette. Opaque channels stay unchanged and alpha zero makes the channels zero.
There is no data-image, HDR or colour-profile option; `gAMA`, `cHRM`, `sRGB`,
`iCCP` and every other ignored chunk never change a texel and are never
decompressed (a decoder that inflated a compressed ancillary chunk would fail
on the suite's fixture whose `zTXt`, `iTXt` and `iCCP` payloads are not zlib
streams, and would allocate a 256 MiB expansion for its decompression-bomb
`iCCP`).

It is not a wrapper around JuicyPixels. That decoder inflates a lazy stream,
concatenates its chunks, builds a sample vector and then a second image: none of
that can be accounted from here, and its allocation behaviour is not a bound
(see [Dependency audit](#dependency-audit)). This stage inflates, unfilters and
converts its own way: the IDAT slices are fed to the zlib inflater as they are,
one output piece at a time, into one working buffer; each scanline is
unfiltered where it lies in that buffer; each pixel is written, premultiplied,
to its final place in the output, and for Adam7 to the place its pass gives it.
There is no sample vector, no pass image, no concatenation of the encoded data
and no second copy of anything.

### The accounting contract

The caller passes a `PayloadAccount` onto its pipeline's byte bank. The decoder
asks the account for each buffer's bytes, *before* allocating it; a refused
reservation is a refusal of class `ExceededLimit LimitWorkspaceBytes` and the
buffer is never allocated. The reservations are `decodeReservations`, in this
order:

| Stage | Bytes | Released |
| --- | --- | --- |
| `StageOutput` | the RGBA8 level, `preflightRgba8Bytes` | not on success: it is the result. On every other outcome |
| `StageScratch` | `fixedScratchBytes` (173,056) plus the widest row | before the call returns |
| `StageWorking` | the filtered scanlines, `preflightScanlineBytes` | before the call returns |

`fixedScratchBytes` is the inflater's state and window (8 KiB and 32 KiB,
rounded up from zlib's 7,116-byte state), two inflater output pieces (the one
being copied and the next, 32 KiB each), the shared premultiplication table
(64 KiB, charged on every call though it is shared) and the palette table
(1 KiB). The widest row is the all-zero row above each pass's first.

- **On success** the account has gained exactly `preflightRgba8Bytes` live
  bytes. **On a refusal or any exception, asynchronous ones included**, it has
  gained nothing: every grant the call took was released, in reverse order.
- **The caller's own charges are the caller's.** The encoded input is charged by
  whoever read it, from before the call until it drops it, and the decoder
  neither charges nor releases it. What is charged is the input's *backing
  allocation*: a `ByteString` view keeps its whole buffer alive, so a PNG that is
  a slice of a larger buffer costs the larger buffer, `ByteString.length
  (preflightSource pf)` is only a lower bound, and only the caller knows the
  allocation. `decodeWorkspaceBytes` is the decoder's own peak;
  `decodePeakBytes inputBytes` adds the input charge the caller states and is
  the most the bank holds while the decode runs. (A PNG read into a buffer of
  its own length, as the texture pipeline does, is charged its length; the
  suite reconciles the peak both ways, including a slice of a larger buffer.)
- **Hand-over.** The output reservation passes to the caller at the instant the
  call returns. A caller that can be cancelled asynchronously calls the decoder
  under `mask` (or `mask_`): the decoder's steps stay cancellable
  (`allowInterrupt` runs once per inflater piece and per row, and the account's
  calls may block) and no exception is delivered between its return and the
  caller's recording of the image, so the caller never holds the charge without
  the image. The caller then releases `StageOutput` with `preflightRgba8Bytes`
  once nothing refers to the level.
- **A staging copy** of the level (for the GPU provider, LFE-17) is a separate
  payload the pipeline charges itself, over and above the output, until the copy
  is retired. The decoder finishing does not free a buffer the consumer holds,
  and the result is independent of the decoder's scratch, of the preflight and
  of the encoded input: it is the level's own buffer, of exactly that length.
  Dropping the source and the preflight frees them while the level lives.
- **The scope.** Each reservation and its release form a scope with the failure
  table of `Hetoimasia.Foundation.Resource` (this package depends on no
  foundation): the body's failure propagates with its own type; a release that
  fails after a successful body fails the call and the body's result is
  discarded; if both fail, the body's failure propagates and every failed release
  is retained beside it in a `PayloadCleanupFailure`, innermost first, which is
  itself asynchronous if the body's failure was. A refused reservation runs no
  release. The reservation runs under `mask` and a release under
  `uninterruptibleMask_`, so an account's release must have a controlled
  blocking duration.

### Failures

A refusal is a `PngRefusal` of one of the preflight's classes, naming the
asset, with a bounded fixed-text reason, and no partial image. Beyond what the
preflight established (this stage reinflates, so it repeats them):

- `MalformedPng`: an image data stream that is corrupt, truncated or inflates to
  fewer bytes than the header needs; **a scanline whose filter-type byte is not
  0 to 4**; an indexed image whose first `PLTE` is missing or not a whole number
  of three-byte entries; a palette index outside the palette. Each is found by an
  explicit check or a typed error, never by catching an exception and never by
  reading prose.
- `ExceededLimit LimitInflatedBytes`: the second inflation produced more than the
  inflation limit.
- `ExceededLimit LimitWorkspaceBytes`: the account refused a reservation.

Anything else is not a refusal and is never relabelled as one: an allocation
failure, a fault in the inflater binding or the account, an asynchronous
exception, and a failing release all propagate as exceptions. This is
deliberately unlike `decodePng`'s `contained`, which turns every synchronous
exception into a refusal. The result is evaluated completely before it is
returned, so a late failure surfaces from the call and never from a value
already reported as a success. The invalid-filter refusal is the bounded path's:
JuicyPixels treats a filter-type byte above 4 as "none" and decodes the file,
and `decodePng` still does, unchanged (the suite pins that).

### Completion and abandonment

When the call returns or throws, the decoder has stopped using every buffer it
charged: the working buffer, the scratch and the inflater's input (the caller's
own slices) are no longer touched, and the account has seen every release. The
one thing it may still hold after an abandoned call is the inflater's native
state, which the pinned `zlib` binding frees; that state is counted in
`fixedScratchBytes` while the call runs and is not counted afterwards (see the
exclusions below). A caller must not release the pipeline's workspace, or the
encoded input, while a call is in progress: the call returning is the only
evidence that it is done, and a cancellation request is not. There is no
deadline and no hard interruption: a cancellation is delivered between steps,
each of which does at most one inflater piece or one row of work. Delivery of
the cancellation and the worker's execution slot are the texture pipeline's
(LFE-16).

### The live-buffer bound

Every buffer the decoder allocates or retains, by operation:

| Buffer | Allocated by | Size | Held from → until |
| --- | --- | --- | --- |
| Encoded input | the caller | the view is at most the source limit (32 MiB); the charge is its whole backing allocation | before the call → the caller drops it. Shared by the IDAT, `PLTE` and `tRNS` slices; never copied |
| Output level | `StageOutput` reservation, then `create` | width × height × 4, at most 16 MiB | reserved first → the caller disposes of it |
| Zero row | `mallocForeignPtrBytes` | the widest row's packed bytes, at most 16 KiB at 2,048 columns RGBA16 | scratch granted → end of call |
| Palette table | `makePalette` | at most 256 × 4 bytes | scratch granted → end of call |
| Inflater state | zlib's `inflateInit` (the binding) | about 7 KiB of state and a 32 KiB window | first input → end or failure of the stream |
| Inflater output piece | the binding, per piece | at most 32 KiB; the next is allocated while this one is copied | produced → copied; at most two live |
| Premultiplication table | a process-wide table, built in place | 64 KiB (built once, no intermediate list) | first use → process exit; charged on every call |
| Scanlines | `StageWorking`, then `mallocForeignPtrBytes` | `preflightScanlineBytes` (filtered rows, every pass), at most the inflation limit | granted → the last row is written; unfiltered in place |

Nothing else of size is allocated. The peak is at conversion, when the encoded
input, the output, the scratch and the scanlines are all live:
`input + output + scratch + scanlines`. At the approved maxima (a 2,048 × 2,048
image, the 32 MiB source limit and the one RGBA8 output of 16 MiB) the peak of
each family is:

| Colour type | Depth | Scanlines, plain / Adam7 | Scratch | Peak, plain / Adam7 |
| --- | --- | --- | --- | --- |
| greyscale | 1 | 526,336 / 528,128 | 173,312 | 51,031,296 / 51,033,088 |
| greyscale | 2 | 1,050,624 / 1,052,416 | 173,568 | 51,555,840 / 51,557,632 |
| greyscale | 4 | 2,099,200 / 2,100,992 | 174,080 | 52,604,928 / 52,606,720 |
| greyscale | 8 | 4,196,352 / 4,198,144 | 175,104 | 54,703,104 / 54,704,896 |
| greyscale | 16 | 8,390,656 / 8,392,448 | 177,152 | 58,899,456 / 58,901,248 |
| palette | 1 | 526,336 / 528,128 | 173,312 | 51,031,296 / 51,033,088 |
| palette | 2 | 1,050,624 / 1,052,416 | 173,568 | 51,555,840 / 51,557,632 |
| palette | 4 | 2,099,200 / 2,100,992 | 174,080 | 52,604,928 / 52,606,720 |
| palette | 8 | 4,196,352 / 4,198,144 | 175,104 | 54,703,104 / 54,704,896 |
| RGB | 8 | 12,584,960 / 12,586,752 | 179,200 | 63,095,808 / 63,097,600 |
| RGB | 16 | 25,167,872 / 25,169,664 | 185,344 | 75,684,864 / 75,686,656 |
| greyscale-alpha | 8 | 8,390,656 / 8,392,448 | 177,152 | 58,899,456 / 58,901,248 |
| greyscale-alpha | 16 | 16,779,264 / 16,781,056 | 181,248 | 67,292,160 / 67,293,952 |
| RGBA | 8 | 16,779,264 / 16,781,056 | 181,248 | 67,292,160 / 67,293,952 |
| RGBA | 16 | 33,556,480 / 33,558,272 | 189,440 | 84,077,568 / **84,079,360** |

The largest, 16-bit RGBA under Adam7, is 84,079,360 bytes (80.2 MiB), under the
128 MiB bank (`m1WorkspaceBytes`) by 47.8 MiB; every scanline figure is under the
40 MiB inflation limit, so no approved variant is refused for the bank. The
slack also holds the preflight's slice descriptors, which the caller's
`PngPreflight` retains (at most the chunk limit of them, 224 KiB at 4,096).
With a staging copy of the output (16 MiB) still owned at hand-over, after the
scanlines and scratch are released, the bank holds `source + 2 × output` at most
(64 MiB with a 32 MiB source). The suite counts every figure above from the
Adam7 pattern pixel by pixel, independently of the module, checks that the
decoder's reservations equal that count in the order made, and decodes real
images at the maxima.

**What the figures exclude.** Allocator overhead; memory the collector has not
yet returned for buffers already unreferenced (the working buffer after its
release is garbage, not a live payload); the object graphs of the preflight and
of the result; and driver or GPU memory. None of them is used to hide a live
referenced payload: every buffer above is charged for exactly as long as the
decoder or the caller refers to it. This is not a whole-process heap
guarantee, and no measurement of resident memory, no garbage-collector timing
and no catching of an allocation failure is part of the proof.

### Dependency audit

What the pinned dependencies actually allocate on every path this package reuses
(`zlib` 0.7.1.1 with the bundled C zlib 1.3.2, `JuicyPixels` 3.3.9):

- **JuicyPixels is not used for decoding on the bounded path.** Its
  `decodePngWithPaletteAndMetadata` inflates with `Z.decompress` to a lazy
  stream, concatenates its chunks into one strict buffer (a second copy of the
  whole inflated data, overlapping the lazy chunks), builds a sample vector
  (8- or 16-bit, `width × height × samples`) from it and then a palette or image
  value on top; nothing in its interface bounds those, and none of it can be
  charged. It treats a filter-type byte above 4 as "none". Its metadata
  extraction (`extractMetadatas`) inflates `zTXt` chunks if its result is forced.
  None of that is reached: the bounded path calls no JuicyPixels decoder, and
  the only JuicyPixels function it runs is `pngComputeCrc`, the chunk CRC.
- **The `zlib` binding's incremental interface** (`decompressIO`) allocates, per
  stream, a `z_stream` (112 bytes) and, through C `inflateInit2`, zlib's inflate
  state (about 7 KiB) and, on first output, a 32 KiB window; and, per output
  piece, one `mallocByteString` of the piece size (32 KiB here). Input chunks
  are handed over by reference and pinned, never copied. The state is freed by
  `inflateEnd` when the stream ends or fails, and by a foreign-pointer
  finalizer otherwise. Every step of the binding is run under `mask_` here, so
  an asynchronous exception cannot arrive between the creation of the state and
  the registration of its finalizer; each step does at most one output piece of
  work.
- **Slices of the caller's buffer** (the IDAT, `PLTE` and `tRNS` data of the
  preflight) are views, not copies: they are counted by their backing allocation,
  the encoded input, whose charge the caller holds until its last view ends.

### The M1 assembly

The assembly passes the fixed M1 limits (`m1PngLimits`, `m1WorkspaceBytes`) and
its pipeline's account; nothing here is tunable and no limit is silently
enlarged. A smaller validated profile or bank, which the suite uses, goes
through the same arithmetic and refuses at the same stage. An injected-small-bank
refusal is not a reason to refuse an approved M1 file under the production bank:
the largest peak above is under the bank.

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

The general decoders own none. They are pure: they read only the caller's
bytes, write no file, start no thread and keep nothing between calls. The
premultiplication table and the BC7 partition and weight tables are constants
shared by every decode. BC7 checking, decoding, the mark and the fallback step
are pure too, as are KTX2 reading and mip generation: the same bytes and kind
always give the same result, and the same image and request always give the same
levels. The bounded PNG preflight is pure as well; its accounting is above. The
package holds no logger. A decoded image's bytes are the caller's.

The bounded decode, `decodeBounded`, is effectful, and owns nothing beyond one
call:

| | |
| --- | --- |
| Owner | the call; there is no state between calls |
| Readers and writers | the calling thread alone: the working buffer, the zero row, the palette table and the output are written by it and read by it |
| Thread | the caller's; it starts none and shares nothing with another |
| Lifetime | the working buffer, scratch and inflater input end with the call; the output level is the caller's from the return |
| Reset and disposal | every reservation is released by the call on every outcome but a success's output; the inflater's native state is freed by the `zlib` binding (stream end or failure, or its finalizer) |
| Accounting | the caller's `PayloadAccount`; the decoder holds no bank of its own |

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

The bounded preflight's cases build their defects byte by byte in
`Test.Asset.Image.PngBuilder` (a bitwise CRC-32, zlib streams from the `zlib`
package or spelled out as stored blocks, and expected scanline sizes counted
pixel by pixel), independently of the production parser, JuicyPixels and the
formula the production code uses, over the committed fixtures where an existing
file already holds the defect. Boundary cases use small injected limits.

The bounded decode's examples run every fixture whose texels the suite states
by hand through the complete entry (preflight, then decode in a byte ledger the
suite models on a pipeline's bank), compare it with those texels and with the
general decoder's colour image byte for byte, and check the account:
`Test.Asset.Image.PayloadLedger` records every grant, refusal and release in
order, with the caller's own charges (the input, a staging copy) through the same
ledger so the peak is the whole bank's. The expected charges are counted in the
suite from the Adam7 pattern, not taken from the module; the bytes the thread
allocated while it decoded are measured against what was charged, so a copy the
account never saw shows. Cancellation examples coordinate with MVars and the
thread's own status, with no sleeps, and wait for their child threads to
terminate. `PngDecodeClient` compiles a separate client against the public
modules alone.

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
