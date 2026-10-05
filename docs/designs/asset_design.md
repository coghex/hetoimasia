# Asset decoding design

Give Hetoimasia small, separately built packages that turn asset files into
data the engine's services accept, starting with images: PNG and KTX2 files
become upload-ready RGBA8 or BC7 levels for the
[bindless texture table](gpu_resource_services_design.md#d-1-bindless-atlased-textures).
Its first consumer is the [2D renderer](render_2d_design.md)'s
static-image milestone (render-2d D-14). Each kind of codec lives in its own
package, so audio, video and later formats never drag image code along and
CI stays light.

Design state: `exploring`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Asset: establish decoding packages, starting with images
- [ ] AST-1. Decode PNG into premultiplied RGBA8 levels in `asset` and `asset-image`
- [ ] AST-2. Read KTX2 files carrying BC7 or RGBA8 levels in `asset-image`
- [ ] AST-3. Decode BC7 to RGBA8 in software for devices without BC support

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
- End to end, `render-2d`'s R2D-8 sample shows a decoded image.

## Delivery plan

### AST-1. Decode PNG into premultiplied RGBA8 levels in `asset` and `asset-image`

- **Outcome:** an application turns PNG bytes into upload-ready levels.
- **Scope:** the `asset` core (identity, decoded types, decoder interface,
  provenance); PNG decoding through JuicyPixels into premultiplied RGBA8,
  sRGB or linear.
- **Phase:** 1
- **Depends on:** `none`
- **Ordering:** can land first
- **Relevant decisions:** D-1, D-2, D-3, D-4, D-5, D-6
- **Acceptance signals:** Hspec decodes fixture PNGs to known texels,
  including linear-space premultiplication of sRGB colour and untouched data
  textures, reports the binary-alpha mark correctly, generates requested mip
  chains matching an independent linear premultiplied downsample, and
  refuses malformed input; the packages build in the CPU project.
- **Out of scope:** KTX2, background loading, mod assets.
- **Open questions:** None

### AST-2. Read KTX2 files carrying BC7 or RGBA8 levels in `asset-image`

- **Outcome:** compressed textures load alongside PNG.
- **Scope:** a pure Haskell KTX2 reader without supercompression; BC7 and
  RGBA8 levels, sRGB and linear; refusal of unsupported files.
- **Phase:** 1
- **Depends on:** AST-1
- **Ordering:** independent
- **Relevant decisions:** D-1, D-3, D-4, D-5
- **Acceptance signals:** Hspec reads fixture KTX2 files to the expected
  levels and binary-alpha mark.
- **Out of scope:** decoding BC7 in software (AST-3), encoding BC7, the
  sheet stitcher.
- **Open questions:** None

### AST-3. Decode BC7 to RGBA8 in software for devices without BC support

- **Outcome:** BC7 content works on devices that cannot sample it.
- **Scope:** a software BC7 decoder covering every mode, producing RGBA8
  levels in the same colour space; selecting it when the device's BC query
  (GRS D-21) finds no BC7; one diagnostic when it is used.
- **Phase:** 1
- **Depends on:** AST-2
- **Ordering:** not on the critical path
- **Relevant decisions:** D-1, D-7
- **Acceptance signals:** Hspec shows the decoder matches independently
  established texels for every BC7 mode, including the sprites sample's
  mode-6 fixture.
- **Out of scope:** encoding BC7.
- **Open questions:** None
