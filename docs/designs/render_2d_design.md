# 2D renderer design

Give Hetoimasia an independent 2D renderer, `render-2d`, over the shared GPU
resource services. Its first milestone also needs image decoding, which is a
separate epic in the [asset design](asset_design.md) (D-15).
A 2D game should draw textured sprites through cameras and views, with depth
for opaque art and correct ordering for translucent art, without constructing
a 3D renderer (foundation D-2). This arc carries FND-4 of the
[renderer findings](../renderer_foundation_findings.md), whose precondition
(#345 and #346 closed) is met, and answers the `render-api` question that
[GPU resource services D-8](gpu_resource_services_design.md#d-8-services-extend-the-native-backend-package)
left to it. Synarchy (`~/work/synarchy`) is prior experience to improve on,
not a compatibility target.

Design state: `exploring`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Establish an independent 2D renderer over the shared GPU services
- [ ] R2D-1. Create `render-api`'s texture handle and `render-2d`'s snapshot, settings and instance encoding
- [ ] R2D-2. Map cameras and views between window, UI and world space
- [ ] R2D-3. Build ordered draw runs from a snapshot
- [ ] R2D-4. Compute expected pixels from a snapshot in `render-2d-oracle`
- [no-issue] R2D-5. Decode PNG into premultiplied RGBA8 levels — moved to the asset epic as AST-1 (D-15)
- [no-issue] R2D-6. Read KTX2 files carrying BC7 or RGBA8 levels — moved to the asset epic as AST-2 (D-15)
- [ ] R2D-7. Record the translucent path in `render-2d-vulkan`, proven by offscreen readback
- [ ] R2D-8. Show a decoded image in a window through published snapshots
- [ ] R2D-9. Draw cutout sprites depth-tested in world layers
- [ ] R2D-10. Retain static instance content across frames
- [ ] R2D-11. Accept application materials as checked fragment functions
- [ ] R2D-12. Clip instances by index in the shader
- [ ] R2D-13. Sample an offscreen pass's target in later passes

## Epic contract

- **Goal:** an application publishes a 2D frame — an ordered list of passes,
  each a target with ordered views of camera-placed layers of sprite
  instances — and sees it rendered with depth-tested cutout art, ordered
  translucent art, application materials, shader clipping and correct UI
  scale on any display.
- **Done when:** every slice has merged; the pure packages build and test
  without the GPU; each rendering slice's offscreen readback matches
  `render-2d-oracle` with clean validation on the macOS profile and the Linux
  CI profile (or an honestly reported limitation); and the windowed sample
  shows an image file decoded by the asset epic's `asset-image`, drawn
  through `render-2d`.
- **Users and operators:** game and adapter authors building 2D presentation
  (a later Synarchy client among them), the later text arc and `render-3d`
  arc, and maintainers reading retained evidence.
- **Arc label:** `render-2d` (proposed; no such label exists yet).

## Current state and evidence

Checked against `master@22688297` on 2026-10-04. No builds or native sessions
ran for this document.

- **Shared services delivered under epic #330:** the bindless texture table
  with stable handles and per-batch lookup versions (#343), growth to a
  configured cap (#344), premultiplied-alpha blending as the only blend mode
  (#345), handle swap with completion-safe retirement (#346), bounded staging
  uploads of RGBA8 and BC7 with caller-supplied mips (#342, GRS D-21), the
  shared per-batch ring (#340, GRS D-33), offscreen colour targets with
  readback (#338) and frame-less batches (#337). See
  [gpu_backend.md](../gpu_backend.md).
- **Still open under #330:** offscreen depth with the 3D sample (#349) and
  per-generation windowed depth (#350).
- **The sprites sample** ([samples/sprites](../../samples/sprites/README.md))
  is scaffolding, not a renderer: a 40-byte instance (pixel rectangle, UV
  rectangle, handle index and generation), a fixed orthographic view of a
  256×256 target, no sorting, the sampler chosen per draw by push constant
  (GRS D-22), and an independent oracle checking readback probes.
- **Conventions fixed upstream:** Vulkan clip space with Y down and depth 0
  to 1, `D32_SFLOAT` preferred, compare and clear chosen per pass (GRS D-36);
  premultiplied alpha from the start (GRS D-1); texture handles are never
  persisted (GRS D-1); the arc stopped at "bytes in, handle out" (GRS D-3).
- **The host renderer** is called per window frame on the graphics owner
  thread with the latest published scene (`gpu_backend.md`, *Rendering a
  frame* and *Consumer construction*); the consumer begins dynamic rendering
  and the controller owns the transitions around it.
- **Not yet possible:** `registerTexture` takes only uploaded `TextureImage`s,
  so an offscreen `ColorTarget` cannot be sampled through the table.
- **Window facts available:** the GLFW layer observes logical extent,
  framebuffer extent and content scale per window (`docs/glfw.md:200`).
- **Reserved packages:** `packages/render-2d` and `packages/render-api` hold
  only READMEs; no Cabal libraries exist.
- **Content loading:** RTC-4 in the
  [runtime capability findings](../runtime_capabilities_findings.md) is
  deferred until a first content type and consumer are named; the asset epic
  names textures, and this arc's sample as their first consumer.
- **Synarchy's renderer, read-only survey (2026-10-04):**
  - One render pass with no depth buffer; every frame rebuilds all world,
    scene and UI quads into 56-byte vertices, six per quad, in host-coherent
    memory (`src/Engine/Scene/Render.hs`, `Scene/Types/Batch.hs`).
  - Painter order uses float keys with per-class epsilons, a one-ULP
    `justAbove` and a front-wall lift (`World/Render/SpriteDepth.hs`,
    `Batch.hs`).
  - Stable handles resolved through a GPU lookup table (#286) and a whole
    layer per draw are ideas this engine already adopted and hardened.
  - Static terrain is presorted and cached, with dynamic quads merged in
    linear time.
  - Text uses `stb_truetype.h` v1.26 for SDF glyphs with a separate
    descriptor set per font; the header supports `kern` and GPOS pair
    kerning, but `cbits/font_stb.c` never calls it, so layout uses advances
    only.
  - UI space is framebuffer pixels, top-left origin, Y down; UI scale is
    applied by hand in Lua (`scripts/ui/scale.lua`); there is no content
    scale handling.
  - Screen-to-world conversion is copied per module (`Unit/HitTest.hs`, flora
    and ground-item picking), and window versus framebuffer size was confused
    across modules (#747).
  - Graphics settings (`src/Engine/Graphics/Config.hs`): resolution, window
    mode, UI scale 0.5–4.0, vsync, frame limit, MSAA, brightness 50–300%,
    pixel snap (off by default) and texture filter (nearest by default).
  - Pixel snap shifts each world quad rigidly by its fractional pixel offset
    and snaps glyph origins; UI is not snapped.
  - Clipping trims quads and UVs on the CPU; the scissor is always
    full-screen (`UI/Clipping.hs`).

## Desired experience

- An application decodes a PNG with `asset-image`, uploads it, registers it,
  and publishes a snapshot with one pass, one view and one layer holding one
  instance; the window shows the image, crisp under pixel snapping and
  discrete step zoom, the same physical size of UI on a Retina and an
  ordinary display.
- A world layer holds thousands of opaque terrain and unit sprites that
  interleave freely, drawn in a few draws through depth, while shadows, fades
  and glows sort correctly over them.
- Static content is built once and retained; only the moving part of a scene
  is published each frame.
- Game code, adapters and their tests depend on pure packages and build in
  the CPU project without the Vulkan SDK.
- Picking converts a cursor position to world coordinates with the same
  mapping the renderer drew with.

## Scope

### In scope

- `render-api` with the backend-independent texture handle.
- Pure `render-2d`: snapshot types (passes, views, layers, cameras,
  instances, settings), view mapping in both directions, sorting and draw-run
  building, instance encoding.
- `render-2d-oracle` for expected pixels.
- `render-2d-vulkan`: recording, the built-in default material, the
  translucent and cutout paths, material wrapping, clipping.
- Retained static instance content.
- A windowed sample and offscreen evidence.
- The backend extension that lets an offscreen target be sampled (R2D-13).

### Out of scope

- Text and fonts: their own arc and design document (D-6).
- Image decoding (`asset`, `asset-image`) and every other asset concern:
  the [asset design](asset_design.md)'s epic (D-15).
- Runtime content loading: background decoding workers, loader budgets, file
  watching and hot reload (RTC-4, RTC-3).
- MSAA and alpha-to-coverage; the backend owns them, deferred.
- `render-3d`, and the frame types shared with it (D-12).
- Game adapters: isometric projection, face-map lighting, facings, z-slices.
- A UI widget or layout framework; `render-2d` supplies primitives.
- Lua bindings, owned by the Lua arc (D-20).
- Live shader loading (D-5), particles, lighting and post-processing
  effects, a render graph, ASTC.

## Design

The decisions below govern. The owner accepted these proposals as written on
2026-10-05 (D-21); they keep their P-numbers as stable references.

- **P-1. Frame shape.** A published 2D frame is a value: an ordered pass list
  (D-10), per-view settings (D-9), cameras (D-7), and layers holding dynamic
  instances or references to retained content (D-1). Pure `render-2d` turns
  it into draw runs; `render-2d-vulkan` records them. Nothing in the frame is
  a native handle.
- **P-2. Within a world layer.** Depth is cleared within the view's viewport
  (D-10); cutout runs draw first, one draw per material, depth-tested and
  written; translucent instances follow, sorted back to front by depth key
  and then submission sequence, depth-tested and not written. UI layers are
  painter-only in submission order.
- **P-3. Depth keys.** The adapter supplies an unsigned integer; the renderer
  maps it to depth exactly, using the 2²⁴ evenly spaced values a 32-bit float
  holds in [0, 1). Equal keys in the cutout pass resolve by draw order under
  less-or-equal compare.
- **P-4. The instance's flags word** holds the sampler choice (default,
  nearest, linear; 2 bits), the translucent override (1 bit) and the clip
  index (16 bits), with the rest reserved (D-4, D-11).
- **P-5. Per-batch tables** — clip rectangles (D-11) and material data
  (D-5) — are written to ring regions the batch claims (GRS D-33) and bound
  for that batch.
- **P-6. Material wrapping.** The engine generates each material's cutout
  and translucent variants and applies tint, the cutout discard or the blend
  output, and the view's brightness around the material's colour, so no
  material can omit them.
- **P-7. Picking.** `render-2d` provides only the view mapping; which
  instance lies under a point remains the game's question.

## Decisions

All decisions below were made by the owner in the design conversation of
2026-10-04.

### D-1. Retained static content and a per-frame dynamic snapshot

The application hands `render-2d` both retained static content, built once
into instance buffers with explicit lifetimes, and a per-frame dynamic
snapshot merged with it by a total order. The dynamic path is delivered
first; retained content follows (R2D-10). GRS D-23 already keeps handles in
built buffers valid across texture swaps.

Rejected: an immediate snapshot alone, which repeats Synarchy's full
rebuild each frame; renderer-owned retained layers alone, which add a
command protocol and renderer state for everything.

### D-2. Depth for opaque and cutout sprites; translucent sprites sorted

World layers use a depth buffer for opaque and cutout art and sort only
translucent instances. The adapter supplies an integer depth key; the
renderer never computes isometric depth. Coarse layers draw in a fixed
order, and UI and overlay layers are painter-only.

- The sorted translucent path needs no depth attachment, so it is delivered
  first (R2D-7) while #349 and #350 land; the cutout pass follows (R2D-9).
- Cutout edges alias under linear filtering, zoom-out and mipmaps;
  alpha-to-coverage is the remedy once MSAA exists, deferred.

Rejected: painter order everywhere, whose retained static runs split
whenever dynamic sprites interleave with them; a per-layer choice of mode,
which carries two paths from the start.

### D-3. Pass routing: the texture's mark, with an instance override

A texture marked cutout-safe defaults to the cutout pass. An instance whose
tint alpha is below 1, or that sets the translucent flag, goes to the sorted
pass, so fading sprites blend correctly. The renderer splits the dynamic
snapshot by pass; retained content fixes its pass when built. Where the mark
comes from is D-19.

### D-4. One 64-byte instance format

Both passes share one instance format:

| Field | Bytes |
| --- | --- |
| 2×3 affine transform, world placement | 24 |
| UV rectangle; the adapter resolves sheet regions | 16 |
| Texture handle (lookup index and generation) | 8 |
| Integer depth key | 4 |
| Premultiplied RGBA8 tint; alpha 0 gives additive | 4 |
| Flags (sampler choice, translucent override, clip index) | 4 |
| Material parameter word (D-5) | 4 |

The sampler choice moves into the instance, so mixed filtering stays in one
draw; this amends GRS D-22's per-draw push-constant sampler for `render-2d`.
Positions are 32-bit floats in world space, precise to about 0.008 pixels at
100,000 pixels from the origin; a chunk origin pushed per draw extends that
later without changing the format. Compact 16-bit UVs and GPU-side region
tables are deferred until measured.

Rejected: an axis-aligned rectangle (no rotation); centre, size, rotation and
pivot (trigonometry per vertex, less general).

### D-5. Materials are checked fragment functions supplied by the application

The engine owns the vertex stage, the instance format and the table bindings
and supplies a built-in default material. An application material is a
fragment function checked at build time through the Template Haskell
interface check (GRS D-19). The engine builds each material's cutout and
translucent variants. Parameters arrive in a small push-constant block per
draw and in the per-instance parameter word, which can carry, for example, a
second texture's lookup index or an index into per-batch material data.
Draws split by material.

Materials come only from the application's build: there is no live shader
loading, and mods choose among the materials the game provides. This is
needed so adapter effects such as Synarchy's face-map lighting stay out of
the engine.

Rejected: a fixed engine shader set, which makes adapter effects impossible;
raw recording by the game, which hands it synchronization, the table and
depth conventions (it can be added later for a real consumer).

### D-6. Text is its own arc, built on stb_truetype alone

Text has its own design document and epic, taken up after the static-texture
milestone (D-14). Its contract, fixed now:

- `stb_truetype.h` is the only dependency, with kerning (`kern` and GPOS
  pairs) used.
- Glyph atlas pages are ordinary textures in the bindless table, and text is
  a built-in material (D-5), so text mixes with sprites in the translucent
  pass.
- A dynamic glyph cache rasterises glyphs on demand, off the graphics owner,
  with a missing-glyph mark and a font fallback chain.
- Layout is a pure function from a styled string to a positioned glyph run,
  cached by the caller and retained when unchanged; text can be in world or
  UI space.
- Shaping and multi-channel SDF are later additions, implemented in a
  single-file C library or in the project's own code.

Rejected: FreeType and HarfBuzz, too heavy for the project's needs.

### D-7. Conventions, spaces, cameras and views

- Y points down in world, UI, UV and clip space alike, matching Vulkan.
- Two spaces: world space in game-defined units through a camera, and UI
  space in logical pixels with the origin at the upper left. Each layer
  declares its space.
- A camera is position, zoom and optional rotation, nothing game-specific.
  Facings, z-slices and every other game concept stay out of `render-2d`.
- A view is a camera, a viewport within the target and the set of layers it
  draws. A target may have several views, and every window its own.
- The renderer applies UI scale multiplied by the window's content scale to
  UI space, from the start, so scripts work in logical units.
- One pure mapping per view converts window points to world or UI points and
  back, shared by drawing and picking, and knows logical size, framebuffer
  size and content scale.
- Degenerate input is guarded: a zero-size viewport draws nothing, and a
  non-finite camera is refused at publication.

### D-8. Zoom modes per view, pixels per unit by default

A view's zoom mode is either pixels per world unit (the default: enlarging
the window shows more of the world, and whole-number zoom gives exact pixel
art) or a fixed half-height in world units (Synarchy's mode: the same area
at any resolution).

### D-9. Minimum per-view settings

From Synarchy's graphics settings, `render-2d` owns, per view, as plain
validated data refused rather than clamped:

- UI scale, 0.5 to 4.0;
- pixel snap: the camera's translation snaps to the device pixel grid and
  each instance's origin snaps rigidly in the vertex shader; UI snaps in
  device pixels as well;
- the default texture filter, nearest or linear, which resolves an
  instance's "default" sampler choice with no descriptor work;
- brightness, 50% to 300%, applied by the engine's material wrapping;
- the zoom mode (D-8).

Discrete step zoom is a separate, application-wide setting (D-16).
Elsewhere: MSAA (backend, deferred), vsync and frame limit (backend
presentation and scheduling), resolution and window mode (GLFW), tooltip
timings (game UI).

### D-10. The frame is an ordered pass list; layers clear their own depth

The snapshot carries an ordered list of passes. Each pass names a target (the
window or an offscreen texture), its clear and its ordered views, and the
window's pass comes last. Passes run in list order through the backend's
checked barriers, keeping order explicit (V-6). Each world layer clears depth
within its viewport when it begins, so layers stay independent and a layer's
keys use the full range. Sampling an offscreen target as a texture needs a
backend extension, delivered when a consumer asks for it (R2D-13).

Rejected: one pass per window, which rules out render-to-texture; a render
graph, excluded by epic #330 and the findings.

### D-11. Clipping by index in the shader

The flags word carries a 16-bit clip index, 0 meaning none, into a per-batch
table of clip rectangles in view space, written to the ring. Pixels outside
are discarded, or clipped by hardware clip distances where the device offers
them. Nested clips are intersected on the CPU when the table is built, mixed
clips stay in one draw, clipping holds under rotation and zoom, and each
view's scissor bounds the view.

Rejected: scissor rectangles, which split a draw at every clip change and
are axis-aligned in device pixels only; Synarchy's CPU trimming.

### D-12. Packages: pure renderer, separate recorder, minimal `render-api`

`render-api` starts with only the backend-independent texture handle and
grows into the functions `render-2d` and a future `render-3d` share when the
`render-3d` arc designs them; it never imports Vulkan. This answers GRS D-8:
2D needs a backend-independent handle so game code does not import Vulkan.
More packages are preferred because they keep CI testing light.

| Package | Contents | Builds without the GPU |
| --- | --- | --- |
| `render-api` | the texture handle; later the frame types shared with 3D | yes |
| `render-2d` | snapshot types, view mappings, sorting and draw runs, instance encoding | yes |
| `render-2d-oracle` | expected pixels from a snapshot, reused by every slice's evidence | yes |
| `render-2d-vulkan` | recorder, material wrapping, built-in shaders | no |
| `render-2d-text` | (text arc) glyph runs and layout | yes |
| `render-2d-text-stb` | (text arc) stb_truetype, the only native part of text | yes, C only |
| the 2D sample | windowed run and offscreen evidence | no |

Game adapters, such as an isometric adapter, stay outside the engine.

Rejected: one package over the native backend, which forces game code and
its tests through the Vulkan project; a full `render-api` now, which guesses
at 3D's needs.

### D-13. Image decoding arrives in `asset` packages

The first milestone shows an image file, and compressed textures are built
alongside PNG. D-15 moves this delivery to its own epic; the
[asset design](asset_design.md) carries this decision as its D-1 and D-3.

| Package | Contents |
| --- | --- |
| `asset` | asset identity, decoded-asset types, the decoder interface, provenance; no codecs |
| `asset-image` | PNG through JuicyPixels, premultiplied at load; a pure Haskell KTX2 reader; RGBA8 or BC7 levels for upload |
| `asset-image-tools` (later) | the sheet stitcher and BC7 encoding |
| `asset-audio` and other codecs (later) | one package per kind of codec |

- JuicyPixels is pure Haskell and memory-safe; it adds only itself and the
  `zlib` binding (a pinned native input under V-11) to the build.
- KTX2 files are read without a codec library; BC7 blocks upload as they are
  through GRS D-21, after the device's BC support is queried.
- Mod-supplied assets are deferred.
- This revises GRS D-3 by bringing decoding forward; background workers,
  budgets, file watching and hot reload stay in the content-loading arc
  (RTC-4).

Rejected: `stb_image.h`, since JuicyPixels' extra dependencies are slight and
it is memory-safe; embedded bytes only, which shows no real image.

### D-14. The first milestone is one static image in a window

Basic 2D rendering of a static texture decoded from an image file comes
first (R2D-1 to R2D-8, with the asset epic's AST-1), before depth, retained
content, materials, clipping and the text arc.

### D-15. Asset decoding is its own epic

Owner decision 2026-10-04; resolves Q-8. The `asset` packages form their own
epic, designed in the [asset design](asset_design.md), with their own
tracker label. R2D-5 and R2D-6 move there as AST-1 and AST-2, and R2D-8
depends on AST-1. The owner confirmed on 2026-10-05 that this means a GitHub
issue label, `asset`, and an epic tracker named for assets.

### D-16. Discrete step zoom is a standalone application-wide setting

Owner decision 2026-10-04; resolves Q-1. Discrete step zoom is its own
setting, application-wide rather than per view, and independent of pixel
snap and the zoom mode: every combination of pixel snap, zoom mode and
discrete step zoom is valid. What the steps are is D-17.

### D-17. Discrete steps come from a configurable list; smooth zoom stays

Owner decision 2026-10-05; resolves Q-12. Discrete step zoom steps through a
configurable list of zoom levels, of which whole numbers are one case.
Smooth, continuous zoom remains available and is what the owner's game
expects to use, so discrete steps are opt-in.

Accepted with D-21 on 2026-10-05: the list is validated like the other
settings (non-empty, finite, positive, strictly increasing, refused rather
than clamped); its values are read in the view's zoom mode (D-8); the
default list is the whole numbers 1 to 8.

### D-18. One snapshot per window

Owner decision 2026-10-05; resolves Q-7. Each window has its own published
2D snapshot carrying that window's pass list, matching the windows'
independent lifetimes and per-window render demand (V-3, V-5), so one
window's change never forces another to redraw.

Rejected: one application-wide snapshot holding a pass list per window.

### D-19. A texture's cutout mark: computed by default, overridable

Owner decision 2026-10-05; resolves Q-4. `asset-image` computes whether a
texture's alpha is binary and carries the result as metadata (asset D-5);
that is the default mark, and the application may override it when it
registers the texture with `render-2d`.

### D-20. Lua bindings belong to the Lua arc

Owner decision 2026-10-05; resolves Q-11. This arc exposes Haskell
interfaces that are easy to bind and exposes nothing to Lua itself; the Lua
arc, which owns VM ownership and the registration layer
([Lua design](../lua_runtime_design.md)), owns the bindings.

### D-21. The design's proposals are accepted

Owner decision 2026-10-05: P-1 to P-7 in *Design*, and the details of D-17,
are accepted as written — the frame as a value with no native handles, the
order within a world layer, exact integer depth-key mapping, the flags-word
layout, per-batch tables in the ring, engine-applied material wrapping, and
picking left to the game.

## Open questions

### Q-1. Integer zoom as a per-view setting

Resolved by D-16: a standalone application-wide setting, not tied to pixel
snap.

Q-2, Q-3 and Q-10 are deliberately open by owner agreement of 2026-10-05:
none affects the static-image milestone. R2D-10 stops and asks for Q-2 and
Q-3, and R2D-11 for Q-3, before either is drafted; R2D-13 stops and asks for
Q-10 when a consumer requests sampled offscreen targets.

### Q-2. Retained static content: storage, ownership and update

Retained content could live in device-local buffers filled through staging
uploads, or in host-visible memory. Its handle could be owned by the
application with explicit release, retired on completion evidence like other
managed resources. Updates could be whole rebuilds or range writes. Affects
R2D-10. Resolves before R2D-10 is drafted.

### Q-3. Animated content inside retained buffers

Animated tiles (water, torches) in retained content either force rebuilds or
need GPU-side frame selection, for example a frame-table index in the
parameter word and a time value pushed per draw. Affects R2D-10 and R2D-11.

### Q-4. Where a texture's cutout-safe mark is stored

Resolved by D-19: computed by `asset-image`, overridable by the application.

### Q-5. Colour space of textures and premultiplication

Premultiplying sRGB-encoded values is not the same as premultiplying linear
values. The choice of sRGB or UNORM formats for art, and where
premultiplication happens, is the asset design's Q-1; this arc must model
the result in the oracle, including for an sRGB window target. Affects R2D-4
and R2D-7.

Resolved by the asset design's D-4 (owner decision 2026-10-05): colour art
uses sRGB formats, premultiplied in linear space at decode; data textures
are linear UNORM and not premultiplied. The oracle models sRGB decoding on
sampling and encoding on an sRGB target.

### Q-6. Mip levels for decoded PNGs

Moved to the asset design's Q-2.

### Q-7. Publication granularity

Resolved by D-18: one snapshot per window.

### Q-8. Whether the asset slices belong to this epic

Resolved by D-15: their own epic.

### Q-9. A device without BC7

Moved to the asset design's Q-3.

### Q-10. Where the sampled-offscreen extension lives

R2D-13 needs a colour target that can also be registered in the texture
table. It could be a slice here or a follow-up to the GPU services arc, and
it may wait for a named consumer. Affects R2D-13.

### Q-11. Lua bindings

Resolved by D-20: the Lua arc owns them.

### Q-12. What discrete step zoom steps through

Resolved by D-17: a configurable list, with smooth zoom kept available.

## Verification strategy

- Pure packages (`render-api`, `render-2d`, `render-2d-oracle`) carry Hspec
  suites that run in the CPU project without the Vulkan SDK.
- Each rendering slice proves itself by offscreen readback checked against
  `render-2d-oracle` probes, computed from the snapshot and never from an
  observed image, with exactness and tolerance per probe as in the sprites
  sample. Evidence runs are window-free (GRS D-6) and fit
  `test.vulkan-native`'s 30-second budget, on macOS locally and Linux CI,
  with clean validation or an honestly reported limitation.
- The windowed sample is the owner-visible milestone, launched explicitly
  and never by tests.
- Performance claims (draw counts, batching, retained content) require
  retained measurements.

## Delivery plan

### R2D-1. Create `render-api`'s texture handle and `render-2d`'s snapshot, settings and instance encoding

- **Outcome:** game code can build and validate a 2D frame value and encode
  instances, with no GPU dependency.
- **Scope:** `render-api` with the opaque texture handle; pure `render-2d`
  with pass, target, view, layer, camera and instance types; per-view settings
  with validation that refuses rather than clamps; the 64-byte instance
  encoding and flags word. Both packages build in the CPU project.
- **Phase:** 1, static-texture milestone
- **Depends on:** `none`
- **Ordering:** critical path
- **Relevant decisions:** D-1, D-4, D-7, D-9, D-10, D-12, D-16, D-17, D-18
- **Acceptance signals:** Hspec covers validation refusals, the encoding's
  byte layout and flag packing; the packages build without the Vulkan SDK.
- **Out of scope:** view mapping, sorting, recording.
- **Open questions:** None

### R2D-2. Map cameras and views between window, UI and world space

- **Outcome:** one pure mapping per view, used for both drawing and picking.
- **Scope:** projections for both zoom modes and rotation; UI scale ×
  content scale; window point to world or UI point and back; pixel-snap
  arithmetic; discrete step zoom; degenerate viewports and non-finite
  cameras.
- **Phase:** 1
- **Depends on:** R2D-1
- **Ordering:** critical path
- **Relevant decisions:** D-7, D-8, D-9, D-16, D-17
- **Acceptance signals:** Hspec round trips between spaces, and covers every
  combination of pixel snap, zoom mode and smooth or discrete step zoom
  across window resizes and content scales.
- **Out of scope:** instance picking (P-7).
- **Open questions:** None

### R2D-3. Build ordered draw runs from a snapshot

- **Outcome:** a pure function turns a frame into ordered passes, views and
  draw runs.
- **Scope:** layer order, pass routing by mark and instance override, back to
  front translucent sorting by depth key and sequence, run splitting by
  pipeline and material.
- **Phase:** 1
- **Depends on:** R2D-1
- **Ordering:** critical path
- **Relevant decisions:** D-2, D-3, D-10, D-19
- **Acceptance signals:** Hspec shows total, repeatable orders and the
  expected runs for interleaved inputs.
- **Out of scope:** retained content (R2D-10).
- **Open questions:** None

### R2D-4. Compute expected pixels from a snapshot in `render-2d-oracle`

- **Outcome:** every rendering slice has an independent oracle.
- **Scope:** nearest and linear sampling, the premultiplied blend in order,
  view mapping and snapping, probes with exact or tolerance verdicts; reuses
  the sprites sample's oracle reasoning.
- **Phase:** 1
- **Depends on:** R2D-2, R2D-3
- **Ordering:** critical path
- **Relevant decisions:** D-2, D-7, D-9, D-12
- **Acceptance signals:** Hspec shows the oracle rejects reversed overlap, an
  off-by-two channel and a wrong snap.
- **Out of scope:** depth and clipping expectations, added by their slices.
- **Open questions:** None

### R2D-5. Decode PNG into premultiplied RGBA8 levels

Moved to the [asset design](asset_design.md) as AST-1 (D-15).

### R2D-6. Read KTX2 files carrying BC7 or RGBA8 levels

Moved to the [asset design](asset_design.md) as AST-2 (D-15).

### R2D-7. Record the translucent path in `render-2d-vulkan`, proven by offscreen readback

- **Outcome:** a frame's pass list renders through the default material.
- **Scope:** recording passes and views (viewport and scissor), the built-in
  default material, per-instance sampler choice, brightness and snapping in
  shaders, the translucent sorted path, offscreen targets and evidence.
- **Phase:** 1
- **Depends on:** R2D-3, R2D-4
- **Ordering:** critical path
- **Relevant decisions:** D-2, D-4, D-5, D-9, D-10, D-12
- **Acceptance signals:** offscreen readback matches the oracle at several
  zoom modes, snap settings and filters, with clean validation on macOS and
  Linux.
- **Out of scope:** depth, application materials, clipping.
- **Open questions:** None

### R2D-8. Show a decoded image in a window through published snapshots

- **Outcome:** the milestone: an image file shown in a window.
- **Scope:** a 2D sample that decodes a PNG with `asset-image`, uploads and
  registers it, and publishes snapshots to the host renderer; UI scale and
  content scale visible.
- **Phase:** 1
- **Depends on:** R2D-7; external: the asset epic's AST-1
- **Ordering:** critical path
- **Relevant decisions:** D-7, D-13, D-14, D-15, D-18, D-20
- **Acceptance signals:** offscreen evidence of the same frame matches the
  oracle; the owner launches the windowed mode and sees the image.
- **Out of scope:** KTX2 in the sample unless the asset epic's AST-2 has
  landed; the software BC7 decoder (AST-3).
- **Open questions:** None

### R2D-9. Draw cutout sprites depth-tested in world layers

- **Outcome:** opaque and cutout art interleaves freely in few draws.
- **Scope:** per-layer depth clears, depth-key mapping, the cutout variant
  with discard, translucent instances tested against depth.
- **Phase:** 2
- **Depends on:** R2D-7; external: #349 and #350
- **Ordering:** critical path
- **Relevant decisions:** D-2, D-3, D-10, D-19
- **Acceptance signals:** readback matches the oracle for interleaved cutout
  and translucent instances.
- **Out of scope:** alpha-to-coverage.
- **Open questions:** None

### R2D-10. Retain static instance content across frames

- **Outcome:** static content is built once and drawn every frame without
  republishing.
- **Scope:** building, referencing from layers, release on completion
  evidence, merging with dynamic content.
- **Phase:** 3
- **Depends on:** R2D-9
- **Ordering:** not on the critical path
- **Relevant decisions:** D-1, D-2
- **Acceptance signals:** readback over several frames with only dynamic
  content republished; a texture swap shows through retained content.
- **Out of scope:** GPU animation, unless Q-3 decides otherwise.
- **Open questions:** Q-2, Q-3

### R2D-11. Accept application materials as checked fragment functions

- **Outcome:** adapters supply effects without engine changes.
- **Scope:** material registration, generated cutout and translucent
  variants, per-draw push block, per-instance parameter word, per-batch
  material data.
- **Phase:** 3
- **Depends on:** R2D-9
- **Ordering:** independent
- **Relevant decisions:** D-4, D-5
- **Acceptance signals:** a sample material using a second texture through
  the parameter word matches the oracle; a misdeclared material fails to
  compile.
- **Out of scope:** live shader loading.
- **Open questions:** Q-3

### R2D-12. Clip instances by index in the shader

- **Outcome:** UI-style clipping without draw splits.
- **Scope:** the clip table, nested intersection, view-space rectangles,
  clipping under rotation.
- **Phase:** 3
- **Depends on:** R2D-7
- **Ordering:** independent
- **Relevant decisions:** D-11
- **Acceptance signals:** readback matches the oracle for nested and rotated
  clips within one draw.
- **Out of scope:** stencil-based clipping.
- **Open questions:** None

### R2D-13. Sample an offscreen pass's target in later passes

- **Outcome:** render-to-texture through the pass list.
- **Scope:** a colour target registrable in the texture table, its
  transitions between passes, and `render-2d` support.
- **Phase:** 4
- **Depends on:** R2D-7
- **Ordering:** not on the critical path
- **Relevant decisions:** D-10
- **Acceptance signals:** readback of a pass sampling an earlier pass's
  target matches the oracle.
- **Out of scope:** post-processing effects themselves.
- **Open questions:** Q-10
