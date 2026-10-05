# Asset decoding design

Give Hetoimasia small, separately built packages that turn asset files into
data the engine's services accept, starting with images: PNG and KTX2 files
become upload-ready RGBA8 or BC7 levels for the
[bindless texture table](gpu_resource_services_design.md#d-1-bindless-atlased-textures).
Its first consumer is the [2D renderer](render_2d_design.md)'s
static-image milestone (render-2d D-14). Each kind of codec lives in its own
package, so audio, video and later formats never drag image code along and
CI stays light.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Asset: establish decoding packages, starting with images — [#398]
- [x] AST-1. Decode PNG into premultiplied RGBA8 levels in `asset` and `asset-image` — [#399]
- [x] AST-4. Generate mip chains for decoded images — [#400]
- [ ] AST-3. Decode BC7 to RGBA8 in software for devices without BC support
- [ ] AST-2. Read KTX2 files carrying BC7 or RGBA8 levels in `asset-image`

## Epic contract

- **Goal:** an application turns PNG and KTX2 bytes into texture levels the
  upload endpoint accepts, through pure, separately tested packages, with no
  GPU dependency.
- **Done when:** every slice has merged; `asset` and `asset-image` build and
  test in the CPU project; fixture files decode to independently known texels
  and levels; and `render-2d`'s sample (R2D-8) shows an image decoded here.
- **Users and operators:** applications and game adapters loading textures,
  the 2D renderer's sample, the later content-loading arc (RTC-4) and the
  later text arc.
- **Arc label:** `asset`, a new GitHub issue label (owner decision
  2026-10-05, D-2).

## Current state and evidence

Checked against `master@22688297` on 2026-10-04. No builds ran for this
document.

- **The upload endpoint** accepts RGBA8 and BC7, sRGB or linear, with every
  mip level supplied by the caller; the GPU generates none, and BC support is
  queried, never assumed (GRS D-21, #342).
- **GRS D-3** ended the GPU services arc at "bytes in, handle out": decoding,
  build tooling, file watching and loader concurrency were left to a later
  content-loading arc. **RTC-4** in the
  [runtime capability findings](../runtime_capabilities_findings.md) is
  deferred until a first content type and consumer are named.
- **Content-side decisions of 2026-09-29** are preserved in the GPU services
  design's Source notes: sheets as a texture plus an optional region table, a
  stitching build script, PNG plus KTX2/BC7 as the baseline, hot reload, and
  bounded background decoding.
- **No decoding exists.** The sprites sample uses generated or embedded bytes
  (`samples/sprites/README.md`); it does hold an independent BC7 mode-6
  decoder as its oracle.
- **JuicyPixels 3.3.9**, checked against the local Hackage index: its
  revision of 2026-01-15 lifts the `containers < 0.8` bound, so it resolves
  at the project's `index-state: 2026-09-18`. Of its dependencies (base,
  bytestring, mtl, binary, transformers, deepseq, containers, vector,
  primitive, zlib) only `zlib`, a binding to C zlib, is new to the build;
  `vector` arrives with the `vulkan` binding and brings `primitive`.
- **Synarchy** (read-only) decoded images with JuicyPixels synchronously on
  the main thread, with no mips and no compressed formats, and deferred KTX2
  (`src/Engine/Scripting/Lua/Message/Texture.hs`).
- **Reference workload:** Synarchy's 6,251 PNGs, 243 MiB as RGBA8, 97% under
  64 KiB (GRS design, *Current state*).

## Desired experience

- An application reads a PNG's bytes, calls `asset-image`, and gets
  premultiplied levels it uploads and registers with no further conversion.
- A KTX2 file carrying BC7 levels loads the same way, and a device without
  BC support is reported rather than silently mishandled.
- Game code depends on `asset` and the codec packages it needs, and nothing
  else.

## Scope

### In scope

- The `asset` core: asset identity, decoded-asset types, the decoder
  interface and provenance (where bytes came from).
- `asset-image`: PNG through JuicyPixels, premultiplied at load; a pure
  Haskell KTX2 reader; RGBA8 and BC7 levels, sRGB and linear.

### Out of scope

- Background decoding workers, loader budgets, file watching and hot reload
  (RTC-4, RTC-3).
- `asset-image-tools`: the sheet stitcher and BC7 encoding.
- Mod-supplied assets and decoding untrusted files.
- Audio, video and other codecs (later `asset-*` packages).
- Uploading and registering textures, which the GPU services already own.
- Supercompressed KTX2, ASTC, and other image formats.

## Design

Both proposals below were accepted by the owner as written on 2026-10-05
(D-8).

- **P-1. Pure decoding.** Decoders are pure functions from bytes to decoded
  values or a refusal naming the asset and the reason; reading files stays
  with the caller.
- **P-2. Levels match the upload endpoint.** `asset-image` produces exactly
  the format, extent and levels GRS D-21 accepts, so no conversion layer sits
  between them.

## Decisions

All decisions below were made by the owner in the design conversation of
2026-10-04 (render-2d D-13 and D-15).

### D-1. `asset` core and one package per kind of codec

| Package | Contents |
| --- | --- |
| `asset` | asset identity, decoded-asset types, the decoder interface, provenance; no codecs |
| `asset-image` | PNG through JuicyPixels, premultiplied at load; a pure Haskell KTX2 reader; RGBA8 or BC7 levels for upload |
| `asset-image-tools` (later) | the sheet stitcher and BC7 encoding |
| `asset-audio` and other codecs (later) | one package per kind of codec |

More packages are preferred because they keep CI testing light.

### D-2. Asset decoding is its own epic

The asset packages form their own epic, with an epic tracker named for
assets and a GitHub issue label `asset` applied to its issues (confirmed
2026-10-05), rather than slices of the 2D renderer epic; `render-2d`'s R2D-8
depends on AST-1.

### D-3. PNG through JuicyPixels, with KTX2 and BC7 alongside it

- JuicyPixels is pure Haskell and memory-safe, and adds only itself and the
  `zlib` binding (a pinned native input under V-11) to the build.
- Compressed textures are built alongside PNG: KTX2 is read without a codec
  library, and BC7 blocks upload as they are through GRS D-21.
- Mod-supplied assets are deferred.
- This revises GRS D-3 by bringing decoding forward; background workers,
  budgets, file watching and hot reload stay in the content-loading arc
  (RTC-4).

Rejected: `stb_image.h`, since JuicyPixels' extra dependencies are slight and
it is memory-safe.

### D-4. Colour textures are sRGB, premultiplied in linear space

Owner decision 2026-10-05; resolves Q-1. Colour art uses sRGB formats and is
premultiplied correctly at decode: decoded to linear light, multiplied by
alpha, and re-encoded. Data textures, such as masks and face maps, use
linear UNORM formats and are not premultiplied. The caller states which kind
a texture is. KTX2 BC7 content follows the same rule, applied when it is
encoded.

Rejected: multiplying the encoded values directly, which darkens
semi-transparent edges.

### D-5. Decoding computes a texture's cutout-safe mark

Owner decision 2026-10-05; resolves Q-4 (render-2d D-19). `asset-image`
reports whether a decoded texture's alpha is binary and carries that as
metadata. `render-2d` uses it as the default cutout mark, and the
application may override it at registration.

### D-6. Mip chains on request, downsampled correctly

Owner decision 2026-10-05; resolves Q-2. `asset-image` generates a full mip
chain for a PNG when the caller asks, and none otherwise: pixel art drawn
with nearest filtering needs none, and smoothly zoomed art does. Downsampling
happens in linear, premultiplied space. KTX2 files bring their own levels.

Rejected: never generating mips, which makes smoothly zoomed-out art shimmer.

### D-7. BC7 decodes in software on devices without BC support

Owner decision 2026-10-05; resolves Q-3. Where the device's BC support query
(GRS D-21) finds no BC7, `asset-image` decodes BC7 levels to RGBA8 in
software, covering every BC7 mode, and the condition is logged once as a
diagnostic. Content then works everywhere, at four times the texture memory
on such devices.

Rejected: refusing BC7 content on such devices. AST-3 delivers the decoder,
split from AST-2 by owner decision of 2026-10-05.

### D-8. The design's proposals are accepted

Owner decision 2026-10-05: P-1 (pure decoders refusing with the asset and
the reason, file reading left to the caller) and P-2 (levels shaped exactly
as GRS D-21 accepts) are accepted as written.

### Review of 2026-10-05

An independent review found gaps in the KTX2 profile, cutout content, atlas
filtering and AST-2's dependency on alpha decoding. D-9 to D-11 are recorded
under the owner's standing instruction of 2026-10-05 to take the correct
approach without asking, after being listed to the owner; D-12 is an owner
decision delegating delivery order.

### D-9. The accepted KTX2 profile

A KTX2 file is accepted only when all of these hold, and otherwise refused
with the reason:

- `vkFormat` is `R8G8B8A8_SRGB`, `R8G8B8A8_UNORM`, `BC7_SRGB_BLOCK` or
  `BC7_UNORM_BLOCK`, and the data format descriptor's transfer function
  agrees with it (sRGB with the `_SRGB` formats, linear otherwise);
- it is two-dimensional, with one layer and one face, no supercompression,
  and at least one level stored (a level count of 0, asking the loader to
  generate levels, is refused);
- `KTXorientation` is absent or `rd`, and `KTXswizzle` is absent or `rgba`;
- for a colour texture with alpha, the descriptor's premultiplied-alpha flag
  is set for BC7, since straight-alpha BC7 cannot be premultiplied without
  re-encoding its blocks; straight-alpha RGBA8 is premultiplied at load,
  correctly (D-4);
- for a data texture, the premultiplied-alpha flag is not set.

### D-10. Cutout content: the mark and coverage-preserving mips

- The mark (D-5) is computed from level 0's alpha: binary means every texel's
  alpha is 0 or 255.
- For BC7, the mark is computed by decoding the alpha of level 0's blocks,
  which needs AST-3's decoder (D-12).
- Generated mip levels (D-6) of a cutout-marked texture preserve coverage at
  `render-2d`'s discard threshold of 0.5 (render-2d D-26): each level's
  alpha is scaled so the fraction of texels at or above the threshold
  matches level 0's. Coverage in BC7 levels is the encoder's obligation, and
  is part of the stitcher's output contract (D-11).

### D-11. The atlas content contract

Clamp-to-edge clamps the whole image, not a region, and whole-sheet mips mix
neighbouring regions. So atlases have an output contract the later stitcher
must meet:

- each region is padded by extruding its edge texels by at least 2ᴸ texels,
  where L is the deepest mip level shipped;
- for BC7, region origins and padded extents are multiples of 4 × 2ᴸ
  texels, so every level's blocks hold one region;
- a sheet ships only the mip levels its padding supports;
- cutout sheets preserve coverage per D-10.

Until the stitcher exists, supported content is single-image textures, or
atlases drawn with nearest filtering and no mips.

### D-12. Delivery order revised after the review

Owner decision 2026-10-05, delegating ordering and splitting: AST-3, the
BC7 decoder, moves before AST-2, so KTX2 can compute BC7's mark (D-10). The
decoder decodes raw blocks as a pure function; choosing it for a device
without BC7 (D-7) is the caller's, from the device's reported BC support.
Mip generation (D-6, D-10) moves from AST-1 into its own slice, AST-4, so
each pull request stays reviewable.

## Open questions

### Q-1. Colour space and premultiplication

Resolved by D-4.

### Q-2. Mip levels for decoded PNGs

Resolved by D-6.

### Q-3. A device without BC7

Resolved by D-7.

### Q-4. Where a texture's cutout-safe mark is stored

Resolved by D-5.

## Verification strategy

- Hspec suites in the CPU project, with no Vulkan SDK.
- Fixture PNG and KTX2 files with independently known texels and level
  layouts, including premultiplication, sRGB and linear variants, and
  malformed or unsupported inputs that must be refused.
- BC7 levels checked against an independent decode, never a GPU readback.
- Each slice updates the packages' READMEs in the same pull request (owned
  state, threads and lifetimes, as AGENTS.md requires). Decoding is pure and
  deterministic; nothing here is persisted beyond the input files.
- End to end, `render-2d`'s R2D-8 sample shows a decoded image.

## Delivery plan

### AST-1. Decode PNG into premultiplied RGBA8 levels in `asset` and `asset-image`

- **Outcome:** an application turns PNG bytes into upload-ready levels.
- **Scope:** the `asset` core (identity, decoded types, decoder interface,
  provenance); PNG decoding through JuicyPixels into premultiplied RGBA8,
  sRGB or linear, as a single level; the binary-alpha mark.
- **Phase:** 1
- **Depends on:** `none`
- **Ordering:** can land first
- **Relevant decisions:** D-1, D-2, D-3, D-4, D-5, D-10
- **Acceptance signals:** Hspec decodes fixture PNGs to known texels,
  including linear-space premultiplication of sRGB colour and untouched data
  textures, reports the binary-alpha mark correctly, and refuses malformed
  input; the packages build in the CPU project.
- **Out of scope:** mip generation (AST-4), KTX2, background loading, mod
  assets.
- **Open questions:** None

### AST-4. Generate mip chains for decoded images

- **Outcome:** smoothly zoomed art gets correct mip levels on request.
- **Scope:** full mip chains generated on the caller's request, downsampled
  in linear premultiplied space; coverage preserved at 0.5 for
  cutout-marked textures.
- **Phase:** 1
- **Depends on:** AST-1
- **Ordering:** independent
- **Relevant decisions:** D-6, D-10
- **Acceptance signals:** Hspec shows generated levels match an independent
  linear premultiplied downsample, and that every generated level of a
  cutout-marked fixture keeps level 0's coverage at 0.5.
- **Out of scope:** mips for KTX2 files, which carry their own.
- **Open questions:** None

### AST-3. Decode BC7 to RGBA8 in software for devices without BC support

- **Outcome:** BC7 content works on devices that cannot sample it, and BC7
  alpha can be classified.
- **Scope:** a pure software BC7 decoder over raw blocks, covering every
  mode, producing RGBA8 in the same colour space; binary-alpha
  classification of decoded blocks; the caller chooses the decoder from the
  device's reported BC support (GRS D-21), and its use is logged once.
- **Phase:** 1
- **Depends on:** AST-1
- **Ordering:** not on the critical path
- **Relevant decisions:** D-1, D-7, D-10, D-12
- **Acceptance signals:** Hspec shows the decoder matches independently
  established texels for every BC7 mode, including the sprites sample's
  mode-6 fixture, and classifies alpha correctly.
- **Out of scope:** KTX2, encoding BC7.
- **Open questions:** None

### AST-2. Read KTX2 files carrying BC7 or RGBA8 levels in `asset-image`

- **Outcome:** compressed textures load alongside PNG.
- **Scope:** a pure Haskell KTX2 reader enforcing the accepted profile;
  BC7 and RGBA8 levels, sRGB and linear; premultiplying straight-alpha
  RGBA8; the mark, through AST-3's decoder for BC7.
- **Phase:** 1
- **Depends on:** AST-3
- **Ordering:** independent
- **Relevant decisions:** D-1, D-3, D-4, D-5, D-9, D-10, D-12
- **Acceptance signals:** Hspec reads fixture KTX2 files to the expected
  levels and mark, and refuses each case outside the profile:
  supercompression, other dimensionality, orientation or swizzle,
  straight-alpha BC7, and a transfer function that disagrees with the
  format.
- **Out of scope:** encoding BC7, the sheet stitcher.
- **Open questions:** None
