# hetoimasia-render-2d

The 2D renderer's frame as a value: the snapshot game code builds, the pure
validation that refuses a bad one, the draw plan that routes, orders and
splits a validated frame into draw runs, the mapping of a view between window,
framebuffer, UI and world space, and the 64-byte instance encoding a backend
uploads. It also holds the backend-free half of retained chunks, application
materials, clip tables and frame-table animation. Everything that records
commands is [`hetoimasia-render-2d-vulkan`](../render-2d-vulkan/README.md)'s;
expected pixels are [`hetoimasia-render-2d-oracle`](../render-2d-oracle/README.md)'s.

Modules, all under `Hetoimasia.Render.TwoD`: `Snapshot`, `Animation`, `Clip`,
`Material`, `Chunk`, `Culling`, `Settings`, `Target`, `Validation`,
`ZoomSteps`, `Metrics`, `Mapping`, `DrawPlan`, `Encoding`. The `.Backend`
modules of `Material`, `Chunk` and `Target` build opaque references and are
for backends and tests standing in for one; game code does not import them.
There is no collecting module.

## Boundary

The library depends on `base`, `array`, `containers`, `bytestring`,
[`hetoimasia-math`](../math/README.md) and
[`hetoimasia-render-api`](../render-api/README.md) (the texture handle). It
names no GPU, GLFW, Vulkan, runtime or Lua package, holds no native handle,
reads no file and performs no IO, and builds in the CPU project. Adapters own
game concepts such as facings, z-slices and isometric projection.

Every value is pure and immutable: the package starts no thread and owns no
resource or mutable state. Keeping referenced objects alive and publishing a
snapshot belong to the backend and the host adapter.

## The frame

A snapshot is an ordered list of passes. Each pass names its target (the
window, or an offscreen texture by `TargetRef`), a clear colour and its
ordered views; there is at most one window pass and it comes last. A view is a
camera, a viewport rectangle within the target, its settings, its clip table,
its frame tables and animation time, and its ordered layers. A layer is a
world layer (game units through the camera, with depth enabled or not) or a UI
layer (logical pixels from the upper left); it lists the retained chunks it
draws and holds its dynamic instances in submission order. **Y points down
everywhere**: world, UI, texture coordinates and clip space.

- **Camera:** a finite position, a finite positive zoom and an optional
  rotation in radians. A zero-size viewport is accepted and draws nothing.
- **Per-view settings**, refused rather than clamped: UI scale 0.5 to 4.0;
  pixel snap; default texture filter (nearest or linear); brightness 0.5 to
  3.0; zoom mode (pixels per world unit, or a fixed half-height in world
  units). Defaults: 1.0, off, nearest, 1.0, pixels per world unit.
- **Instance:** a 2×3 affine transform, a UV rectangle, a texture handle, a
  depth key, an RGBA8 tint multiplier, a sampler choice, a translucent flag,
  an additive flag, a clip index, a frame-table index, a material parameter
  word and a `MaterialRef`.
- **Depth keys** lie in [0, 2²⁴); a larger key is nearer. A larger value is
  refused, never wrapped.

An instance's transform places the **unit square** [0, 1]² in its layer's
space: local (0, 0) is the instance's origin, which pixel snap rounds, and
texture coordinates interpolate affinely from `(u0, v0)` at local (0, 0) to
`(u1, v1)` at local (1, 1). This is the contract a recorder's vertex stage
must meet; the oracle states and tests it.

## Validation

`validateSnapshot` turns a candidate into a `ValidSnapshot` or refuses it with
every reason found, each naming where (pass, view, clip entry, frame table,
layer, instance, chunk). Nothing is clamped, wrapped or corrected, and the
valid snapshot holds exactly the candidate's values in order. Validation is
total and deterministic, and checks everything wherever it sits, a zero-size
viewport included. NaN and both infinities are refused explicitly.

Refusals cover: more than one window pass or one that is not last; clear
colour outside [0, 1]; non-finite camera, viewport, transform or UV; a
non-positive zoom or half-height; a negative viewport extent; UI scale or
brightness out of range; a depth key of 2²⁴ or more; the clip, chunk,
material and frame-table rules in the sections below.

`ValidSnapshot` and `ValidLayer` are made only by validation (private
constructors, no record update), so a function that takes one can rely on
every check. A snapshot with only offscreen passes is valid. A `TargetRef` is
an index and generation a backend issues; it holds no native handle and starts
no lifetime.

## Clip tables

A view carries an ordered clip table (`viewClips`). Entry `i` is the one clip
index `i + 1` selects; clip index 0 means no clip. An entry is a `ClipRect`
and an optional parent, which must be an earlier entry of the same table, so
chains cannot cycle. A clip index always means its own view's entry.

- **Space.** A clip rectangle is axis-aligned in the space of the layer whose
  instances reference it (world units or UI logical pixels) and moves, turns
  and zooms with that layer's content. An entry reached, directly or through
  descendants, from both a world layer and a UI layer is refused
  (`ClipSpaceMixed`).
- **Membership is half-open:** `left ≤ x < right`, `top ≤ y < bottom`. A zero
  extent holds no point and clips everything; a negative extent or non-finite
  coordinate is refused.
- **The resolver.** `resolveClips` intersects every entry with its whole
  parent chain, exactly over `Rational`s, and rounds once to floats, so the
  result does not depend on chain depth. An empty intersection is `emptyClip`;
  rectangles that only touch intersect in nothing.
- A retained chunk has no clip table: a chunk instance with a clip index is
  refused when the chunk is built.
- A clip index never changes the draw plan: it neither splits a run nor
  reorders. Applying a clip to a fragment is the recorder's and the oracle's.

## Retained chunks

Static content built once into device buffers by a backend, listed by
reference in every snapshot that draws it, and merged with the snapshot's
dynamic instances by a total order. This package holds the description every
pure step reads.

- **References.** A `ChunkRef` is an index and a generation a backend issues,
  opaque to game code. A reused index gets the next generation, so a stale
  reference never resolves to rebuilt content.
- **Kinds.** A chunk is built for one kind of layer (`ChunkWorldDepth`,
  `ChunkWorldFlat`, `ChunkUi`) and may be listed only by a layer of that kind.
- **Building.** `buildChunk marks kind bounds instances` validates every
  instance as a snapshot's would be, and the bounds, and either reports every
  reason or builds an immutable `Chunk` holding the instances in build order.
  `buildChunkWith` also carries the chunk's own material records.
- **Routing is fixed at build.** Only a `ChunkWorldDepth` chunk routes
  anything to the cutout path, under the same conditions as the draw plan. A
  texture swap shows through the chunk because an instance names the handle,
  and a swap that would change the handle's cutout mark is refused at the
  swap.
- **Bounds conservatively enclose the geometry.** `DeriveBounds` takes the
  exact rectangle over every instance and rounds each edge outward to a
  float. `SuppliedBounds` must be finite, not inverted and enclose that
  rectangle; larger bounds only make culling less eager. A chunk with no
  instance needs supplied bounds.
- **Resolution.** `validateSnapshotWith chunks snapshot` resolves every
  listed reference through the `Chunks` the caller holds, by exact reference.
  An unknown, stale or released reference is `ChunkUnresolved`; a chunk built
  for another kind of layer is `ChunkKindMismatch`. The valid snapshot keeps
  what each listing resolved to, so nothing after validation looks anything
  up.
- **Culling.** `chunkCulled` says whether a view skips a chunk: its bounds,
  mapped through the view's transform, lie wholly outside the viewport clamped
  to the target. It is conservative: the mapped rectangle is widened for pixel
  snap, for the oracle's undecided band, and for the shader's 32-bit
  rounding, so a chunk that cannot be decided is kept. Only chunks are culled,
  never dynamic instances.
- A chunk is rebuilt whole: build a new one, publish, release the old. There
  are no range writes into a chunk.

## Application materials

An application defines a material as a fragment function the build checks
(`render-2d-vulkan`'s splice), and the engine wraps its colour in the tint,
the brightness and the cutout discard or blend output, so no material can omit
them. This package is the pure side.

- **The reference.** A `MaterialRef` carries an opaque identity and the
  material's declared facts: whether it is cutout-capable (its output alpha is
  binary wherever its primary texture's is), the layout of its records (a
  number of full texture handles, then a number of 32-bit words), and the size
  of its push block in bytes. Game code can compare and read one but not
  construct or rewrite it. `defaultMaterial` has identity 0, is
  cutout-capable, and has no record and no push block.
- **Per instance.** `instanceMaterial` is read by the planner and is not
  encoded. The material parameter word (`instanceParameter`, byte offset 60)
  indexes the records the instance's view holds for its material, or the
  chunk's for a chunk instance. A material with an empty record layout ignores
  the word.
- **Records and push blocks.** A view holds a `MaterialData` per material its
  instances use. Validation refuses a parameter word beyond the records
  (`ParameterBeyondRecords`), a record that does not match the declared layout
  (`RecordLayoutMismatch`), a push block of the wrong size
  (`PushBlockSizeMismatch`), and a missing push block for a used material that
  declares one (`PushBlockMissing`). A chunk's own records are checked when it
  is built. Every handle in a record is a full handle with a generation, so a
  released and reused handle samples the transparent placeholder.
- **Encoding.** `encodeRecords layout records` writes little-endian 32-bit
  words, record after record with no padding: a lookup index and generation
  per handle, then the words.

## Animation

An animated instance names a **frame table**: a frame count, a frame duration
and one UV rectangle per frame. The frame is chosen exactly from the view's
time, once per table, and replaces the instance's own rectangle. It works the
same for a dynamic instance and a retained chunk's, so animating never
rebuilds a chunk.

- `viewFrameTables` is ordered: table `i` is selected by frame-table index
  `i + 1`, and 0 means not animated. An index refers to the tables of the view
  the instance is drawn in, so one chunk drawn in two views shows each view's
  frames.
- A `FrameTable` has a count of at least 1, a finite positive duration in
  seconds and exactly one finite `UvRect` per frame. The count times the
  duration, and the view's time over the duration, must be finite in `Double`.
- `viewAnimationTime` is a finite non-negative `Double` in seconds, so a
  view's frames are determined by its snapshot alone.
- The index occupies 12 bits of the flags word, so at most 4095 tables can be
  named.

**Selection.** `f = floor (t / duration) mod count`, where the quotient is the
`Double` division, the floor is taken to an unbounded `Integer`, and `mod` is
the integer modulus (`currentFrame`). There is no tolerance, snapping or
indeterminacy band: when a quotient rounds, the frame follows it. Duration
`0.1` at time `43 × 0.1` gives quotient `42.99999999999999` and frame 42; a
test that means a boundary uses an exactly representable duration such as
`0.5`. The recorder computes `f` once per table per view and writes it as a
whole number, the shader does no time arithmetic, and the oracle evaluates the
same function.

Building a chunk refuses an instance whose index is above 4095. Validating a
snapshot checks each listed chunk's largest index against the tables of every
view that lists it, whether or not the view culls it.

Not here: easing, per-instance time offsets, ping-pong and one-shot animation,
and animating anything but the UV rectangle.

## The draw plan

`planSnapshot marks valid` is pure and total. It keeps the snapshot's
structure (passes, views, layers in order) and gives each layer an ordered
list of draw runs. A `PlannedLayer` carries its drawing order as a permutation
of submission indices; a `DrawRun` names its path (`Cutout` or `Ordered`), its
material, its record source and a contiguous range of that permutation. A
world layer with depth enabled clears depth within its viewport before its
runs.

**The marks.** A texture's cutout mark is an input: the caller passes the
complete handles, generation included, that are marked cutout-safe. The mark
is computed by `asset-image` and fixed when the texture is registered. A
handle not in the set, including one that only shares a lookup index, takes
the ordered path.

**Routing.** An instance takes the cutout path only when all of these hold:

- it is in a world layer whose depth is enabled;
- its texture is marked cutout-safe;
- its material is cutout-capable;
- its tint alpha is 255;
- its translucent and additive flags are both clear.

Every other instance, every UI layer and every layer without depth take the
ordered path.

**Ordering within a layer.** Cutout runs come first, ordered by material and
then submission sequence; the depth buffer resolves their overlap. Ordered
instances follow, back to front: ascending depth key, then ascending
submission sequence. The order is total and repeatable.

**Runs.** Consecutive instances share a run when they share a path, a material
and, where the material has records, a record source. A sampler, tint, depth
key, transform, UV rectangle or parameter word never splits a run.

**Equal keys.** Among cutouts at an equal key, the later draw in run order
wins (less-or-equal depth test). At an equal key an ordered instance always
draws over a cutout. An adapter that needs a guaranteed winner uses distinct
depth keys.

**Chunks and the merge order.** A layer's source order is the chunks it
lists, in order, each in its build order, then its dynamic instances in
submission order. The source order breaks every tie.

- Cutout runs: within a material, each chunk listing's cutouts are one run
  that reads the chunk's own device buffer (`ChunkRun`), then the dynamic
  cutouts as one run of the frame's ring (`RingRun`). A chunk's cutouts are
  never re-encoded.
- Ordered runs: the ordered instances of every listed chunk and of the layer
  are merged into one run by depth key and then source order, and written to
  the ring each frame.

`planSnapshotCulled culler marks valid` leaves out the chunk listings the
culler skips for each view and names them in `plannedCulled`. Planning sorts
the merged ordered instances once, O(n log n).

## Mapping views

`viewMapping metrics view` is the one pure mapping of a view, shared by
drawing and picking. The caller fills a `TargetMetrics` from the window
layer's observation (logical extent, framebuffer extent, content scale) or
from `offscreenMetrics`. A viewport is a rectangle of target pixels
(framebuffer pixels for the window), origin upper left, Y down. Clip-space
conversion belongs to the recorder.

**World.** With `C` the viewport's centre, `p` the camera position, `θ` its
rotation and `s` the scale:

```text
target = C + s · R(−θ) · (world − p)
s = zoom                          pixels per world unit
s = viewportHeight · zoom / (2h)  a fixed half-height h
```

A positive angle takes +X toward +Y, which is clockwise on a Y-down screen
([the math package](../math/README.md#affine2)).

**UI.** `target = viewportOrigin + uiPoint · (u · k)` per axis, with UI scale
`u` and content scale `k`, independent of the camera.

**Window.** `framebuffer = window · framebufferExtent / logicalExtent` per
axis; content scale plays no part.

**Pixel snap and picking.** `snapPixel x = floor (x + 0.5)`, so halves round
up. With pixel snap on, the world mapping rounds its translation (the
camera's), and the recorder rounds each instance's origin in the shader. The
inverse conversions stay unsnapped: they invert the transform drawing uses and
round no result. For that transform `F`, `|snapPoint (F p) − F p| ≤ 0.5` per
axis. The promise is against `F`, not against a transform with an unsnapped
camera.

**Float resolution.** The transforms hold 32-bit coefficients. Once the scale
times the camera position exceeds 2²³ pixels, one ulp is more than a pixel and
the camera appears at the centre only to that resolution. A game with such
ranges keeps its camera near the origin.

**Degenerate input.** Nothing is clamped and every refusal is `Nothing`: an
invalid view or metrics, coefficients or an inverse that cannot be finite
floats, a conversion through a zero-size viewport, a window conversion with a
zero extent, a non-finite point or an overflowing result. A point outside the
viewport still converts; `viewportContains` is half-open like a clip.

## Discrete step zoom

An application-wide list of zoom levels, independent of per-view settings and
not part of a snapshot. `validateZoomSteps` refuses an empty list, a
non-positive or non-finite level, and a level not greater than the one before
it. The default is the whole numbers 1 to 8. `stepZoomIn` returns the smallest
level greater than the current zoom (or the largest level); `stepZoomOut` the
largest level smaller (or the smallest). Smooth zoom stays a plain value.

## The instance encoding

`encodeLayer` writes a valid layer's instances in submission order into one
strict buffer of exactly 64 bytes per instance, little-endian.

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 24 | the transform as six `f32`, column-major: `[a, b, c, d, tx, ty]` |
| 24 | 16 | the UV rectangle as four `f32`: `(u0, v0, u1, v1)` |
| 40 | 4 | the texture handle's lookup index (`u32`) |
| 44 | 4 | the texture handle's generation (`u32`) |
| 48 | 4 | the depth key (`u32`) |
| 52 | 4 | the tint, one byte each for R, G, B, A |
| 56 | 4 | the flags word (`u32`) |
| 60 | 4 | the material parameter word (`u32`) |

The transform maps `(x, y)` to `(a·x + c·y + tx, b·x + d·y + ty)`.

| Flags bits | Field |
| --- | --- |
| 0–1 | sampler choice: 0 default, 1 nearest, 2 linear; 3 is never produced |
| 2 | translucent override |
| 3 | additive flag |
| 4–15 | frame-table index (0 meaning not animated); a shader reads `(flags >> 4) & 0xFFF` |
| 16–31 | clip index (0 meaning none); a shader reads `flags >> 16` |

`flagsWord` writes only the low 12 bits of the frame-table index, so an
invalid index never reaches another field. Indices are written unchanged,
never renumbered.

**std430.** The 64-byte stride is std430-compatible only when a shader
declares the UV rectangle as two `vec2`s or reads the instance as vertex
attributes. Declared as a `vec4` it would align to 16 bytes and move to offset
32. Never declare it as a `vec4`.

`encodeLayerInDrawingOrder planned layer` writes the same 64-byte records
permuted by the planned drawing order, so a run's instances are one contiguous
range; for a layer that lists chunks it writes the dynamic cutouts and the
merged ordered instances. `encodeChunkCutouts chunk` encodes a chunk's cutout
instances once, in the order its device buffer holds them.

## Not here

Which instance lies under a point (the game's question); culling dynamic
instances; recording, shaders, samplers, device buffers, uploads and holds
(`render-2d-vulkan`); expected pixels (the oracle); computing or registering a
texture's mark; publication per window; materials that change the vertex
stage or the instance format; mod-supplied materials; sampling offscreen
targets; stencil, hardware, rounded or non-rectangular clips; Lua bindings.

## Tests

```bash
cabal test --project-file cabal.project.cpu hetoimasia-render-2d:render-2d-tests --test-show-details=direct
```

This is the CPU validation group `test.render-2d`.
