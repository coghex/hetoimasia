# hetoimasia-render-2d

The 2D renderer's frame as a value: the snapshot game code builds, the pure
validation that refuses a bad one, the application-wide discrete-step-zoom
list, the pure draw plan that routes, orders and splits a validated frame's
instances into draw runs, the pure mapping of a view between window,
framebuffer, UI and world space, and the 64-byte instance encoding a backend
uploads, in submission order or in a planned layer's drawing order, and
**retained chunks** (R2D-10): static content built once, listed by reference in
the layers of later snapshots, merged with their dynamic content by a total
order and culled by their bounds. Everything
that records commands is [`hetoimasia-render-2d-vulkan`](../render-2d-vulkan/README.md)'s.
The decision record is
[the 2D renderer design](../../docs/designs/render_2d_design.md) (D-1 to D-4,
D-7 to D-10, D-12, D-16 to D-19, D-22 to D-25, D-27, D-29, D-31; R2D-1 to R2D-3, R2D-10); the package's place among the
others is [the foundation design](../../docs/engine_foundation_design.md).

| Module | Contents |
| --- | --- |
| `Hetoimasia.Render.TwoD.Snapshot` | `Snapshot`, `Pass`, `Target` (`WindowTarget`, `OffscreenTarget`), `ClearColour`, `View` (with its `viewClips` table), `Viewport`, `Camera`, `Layer` (the constructors `WorldLayerWith` and `UiLayerWith`, which list chunks, and the patterns `WorldLayer` and `UiLayer`, the layer that lists none), `LayerDepth`, `Instance`, `UvRect`, `Tint`, `Sampler`; `layerInstances`, `layerChunks`, `depthKeyLimit` |
| `Hetoimasia.Render.TwoD.Clip` | `ClipRect`, `ClipEntry` (a view's clip table is a list of them); `ResolvedClip`, `emptyClip`, `clipIsEmpty`, `clipContains` and `resolveClips`, the pure resolver; `clipEntryOfIndex` |
| `Hetoimasia.Render.TwoD.Chunk` | `ChunkRef`, the opaque chunk reference (`Eq`, `Ord`, `Show` only); `ChunkKind` (`ChunkWorldDepth`, `ChunkWorldFlat`, `ChunkUi`), `layerChunkKind`; `Bounds`, `BoundsRequest` (`DeriveBounds`, `SuppliedBounds`); `Chunk`, `buildChunk`, `ChunkRefusal`; `chunkKind`, `chunkBounds`, `chunkSize`, `chunkInstances`, `chunkInstanceAt`, `chunkCutoutPositions`, `chunkOrderedPositions`, `chunkTextures`; `Chunks`, `noChunks`, `chunksFrom`, `lookupChunk`, `chunkRefsOf` |
| `Hetoimasia.Render.TwoD.Chunk.Backend` | `chunkRef ∷ Word32 → Word32 → ChunkRef`; `chunkRefIndex`, `chunkRefGeneration` (backends, and tests standing in for one) |
| `Hetoimasia.Render.TwoD.Culling` | `chunkCulled`: whether a view skips a chunk of a kind and bounds, conservatively |
| `Hetoimasia.Render.TwoD.Settings` | `ViewSettings` and `defaultViewSettings`, `TextureFilter`, `ZoomMode`; `uiScaleRange`, `brightnessRange` |
| `Hetoimasia.Render.TwoD.Target` | `TargetRef`, the opaque offscreen target reference: `Eq`, `Ord` and `Show` only |
| `Hetoimasia.Render.TwoD.Target.Backend` | `targetRef ∷ Word32 → Word32 → TargetRef`; `targetRefIndex`, `targetRefGeneration` (backends, and tests standing in for one) |
| `Hetoimasia.Render.TwoD.Validation` | `validateSnapshot`, `validateSnapshotWith`; `Refusal`, `Location`, `Reason`, `instanceReasons`; `ValidSnapshot` with `validSnapshot`, `validLayers` and `validChunkRefs`; `ValidLayer` with `validLayerLocation`, `validLayerContents` and `validLayerChunks` |
| `Hetoimasia.Render.TwoD.ZoomSteps` | `ZoomSteps`, `zoomLevels`, `defaultZoomSteps`, `validateZoomSteps`; `stepZoomIn`, `stepZoomOut`; `ZoomRefusal`, `ZoomLocation`, `ZoomReason` |
| `Hetoimasia.Render.TwoD.Metrics` | `TargetMetrics` (logical extent, framebuffer extent, per-axis content scale), `PixelExtent`; `offscreenMetrics`, `validMetrics` |
| `Hetoimasia.Render.TwoD.Mapping` | `viewMapping ∷ TargetMetrics → View → Maybe ViewMapping`; the transforms `worldTransform`, `worldInverse`, `uiTransform`, `uiInverse`; the point conversions `worldToTarget`, `targetToWorld`, `uiToTarget`, `targetToUi`, `windowToTarget`, `targetToWindow`, `windowToWorld`, `worldToWindow`, `windowToUi`, `uiToWindow`; `viewportIsEmpty`, `viewportContains`; `snapPixel`, `snapPoint`; `mappingPixelSnap` |
| `Hetoimasia.Render.TwoD.DrawPlan` | `planSnapshot ∷ CutoutMarks → ValidSnapshot → DrawPlan`, `planSnapshotCulled` with a `ChunkCuller` (`noCulling` skips none); `CutoutMarks` with `cutoutMarks`, `noCutoutMarks`, `isMarkedCutout`; `DrawPlan`, `PlannedPass`, `PlannedView`, `PlannedLayer`, `LayerSpace`, `DrawRun`, `DrawPath` (`Cutout`, `Ordered`), `RunSource` (`RingRun`, `ChunkRun`), `InstanceSource`, `Material` (`DefaultMaterial`) with `materialCutoutCapable`; `drawingOrder`, `drawingSources`, `runIndices` |
| `Hetoimasia.Render.TwoD.Encoding` | `encodeLayer ∷ ValidLayer → ByteString`; `encodeLayerInDrawingOrder ∷ PlannedLayer → ValidLayer → Maybe ByteString`; `encodeChunkCutouts ∷ Chunk → ByteString`; `instanceStride`, `flagsWord` |

There is no collecting module and no prelude: import the module that owns what
you use.

## Boundary

The library's `build-depends` names `base`, `array` and `containers` (the plan's
permutation and the set of marked handles), `bytestring`,
[`hetoimasia-math`](../math/README.md) (for the camera's position and the
instance's 2×3 affine transform) and
[`hetoimasia-render-api`](../render-api/README.md) (for the texture handle). It
names no GPU, GLFW, Vulkan, runtime or Lua package, and no native handle appears
in any value: a window is a target, not a handle, and an offscreen target is an
opaque reference. It reads no file and performs no IO. The package builds and
tests in the CPU project (`cabal.project.cpu`). Adapters own game concepts such
as facings, z-slices and isometric projection; none appears here.

## The frame

A snapshot is an ordered list of passes. Each pass names its target (the
window, or an offscreen texture by `TargetRef`), a clear colour and its ordered
views; the window's pass comes last, and there is at most one. A view is a
camera, a viewport rectangle within the target, its per-view settings, its
ordered clip table and its ordered layers. A layer is a world layer (game units through the camera, with
depth enabled or not) or a UI layer (logical pixels from the upper left), each
listing the retained chunks it draws (below) and holding its dynamic instances
in submission order. Y points down everywhere: world, UI, texture coordinates
and clip space.

- **Camera:** a position, a zoom and an optional rotation in radians. The
  position and rotation must be finite and the zoom finite and positive. A
  zero-size viewport is accepted and draws nothing.
- **Per-view settings**, plain data refused rather than clamped: UI scale 0.5
  to 4.0; pixel snap; the default texture filter, nearest or linear;
  brightness 50% to 300% (the factor 0.5 to 3.0); and the zoom mode, pixels per
  world unit or a fixed half-height in world units. The defaults are UI scale
  1.0, pixel snap off, nearest filtering, brightness 100% and pixels per world
  unit.
- **Instance:** a 2×3 affine transform, a UV rectangle `(u0, v0, u1, v1)`, a
  texture handle, a depth key, an RGBA8 tint (a componentwise multiplier), a
  sampler choice (default, nearest, linear), a translucent flag, an additive
  flag, a clip index and a material parameter word.
- **Clip tables** ([below](#clip-tables)): a view carries an ordered table of
  clip rectangles, and an instance's clip index, 0 meaning none, selects an
  entry of its own view's table.
- **Depth keys** lie in [0, 2²⁴). A larger key is refused, never wrapped or
  collapsed; a larger key is nearer.

## Validation

`validateSnapshot` turns a candidate into a `ValidSnapshot` or refuses it with
**every** reason found, each naming where: the pass, view, layer and instance
index (`AtPass`, `AtView`, `AtClipEntry`, `AtLayer`, `AtInstance`; and `AtChunk`, which names the layer, the
chunk's position in the layer's list and the reference listed there, and `AtChunkInstance`, which names an instance of a
chunk, used by the oracle). Nothing is clamped,
wrapped or corrected, and a valid snapshot holds exactly the candidate's
values in the candidate's order (`validSnapshot`). Validation is total and
deterministic, and the refusals come in snapshot order. Everything is checked
wherever it sits, so invalid data inside a zero-size viewport is refused like
any other.

| `Reason` | Refused when |
| --- | --- |
| `MultipleWindowPasses` | a window pass follows another window pass |
| `WindowPassNotLast` | a window pass is followed by another pass |
| `ClearColourInvalid` | a clear component is NaN, infinite or outside [0, 1] |
| `CameraPositionNotFinite`, `CameraRotationNotFinite` | the position or rotation has a NaN or infinite value |
| `CameraZoomInvalid` | the zoom is NaN, infinite, zero or negative |
| `ViewportNotFinite` | the origin or extent has a NaN or infinite component |
| `ViewportExtentNegative` | an extent component is negative, negative infinity included; checked independently of `ViewportNotFinite`, so a viewport can be refused for both |
| `UiScaleOutOfRange` | the UI scale is NaN, infinite or outside [0.5, 4.0] |
| `BrightnessOutOfRange` | the brightness is NaN, infinite or outside [0.5, 3.0] |
| `HalfHeightInvalid` | a fixed half-height is NaN, infinite, zero or negative |
| `TransformNotFinite`, `UvNotFinite` | an instance's transform or UV rectangle has a NaN or infinite value |
| `DepthKeyTooLarge` | a depth key is 2²⁴ or more |
| `ClipIndexUnknown` | an instance's clip index `k` is past its view's clip table, which holds fewer than `k` entries (named by the instance) |
| `ClipParentInvalid` | a clip entry's parent is not an earlier entry of its table (named by the entry) |
| `ClipRectInvalid` | a clip rectangle has a NaN or infinite coordinate or a negative extent (named by the entry) |
| `ClipSpaceMixed` | a clip entry is referenced, directly or through a descendant, from both a world layer and a UI layer (named by the entry) |
| `ChunkUnresolved` | a layer lists a chunk the chunks validated against do not hold: never issued, stale (another generation) or released |
| `ChunkKindMismatch` | a layer lists a chunk built for another kind of layer |

NaN and both infinities are refused explicitly, so no range comparison can
accept one by accident. A snapshot holding only offscreen passes is valid, for
window-free rendering and evidence. That a snapshot published to a window holds
a window pass is a publication rule, not a validation one.

**Validated values are opaque.** A `ValidSnapshot` and a `ValidLayer` are made
only by validation: their constructors are private and no record-update route
exists, so a function that takes one can rely on every check above.
`validLayers` gives each layer of a valid snapshot, with its location, in pass,
view and layer order, and `encodeLayer` and `encodeLayerInDrawingOrder` accept only such a layer.

**Offscreen targets.** A `TargetRef` is an index and a generation a backend
issues. It holds no native handle, building one acquires nothing and starts no
lifetime, and game code can only compare, order and show one.
`Hetoimasia.Render.TwoD.Target.Backend` builds and reads one, for backends and
for tests that stand in for one.

## Clip tables

A view carries an ordered **clip table** (`viewClips`), and an instance's clip
index selects an entry of it (R2D-12, design D-11). The table's entry `i` is the
one clip index `i + 1` selects; clip index 0 means no clip. An entry is a
`ClipRect` (an origin and an extent) and an optional parent: the zero-based
index `p` of an *earlier* entry of the same table, `0 ≤ p < i`, so a chain only
runs toward lower indices and cannot close on itself. A clip index always means
its own view's entry: the same index in two views selects each view's own
rectangle.

**Space (choice B).** A clip rectangle is axis-aligned in the space of the
layer whose instances reference it: world units for a world layer, UI logical
pixels for a UI layer. It therefore moves, turns and zooms with that layer's
content under the view's transform. World clips use the world mapping, which
carries the camera's position, rotation and zoom and the snapped translation of
a pixel-snapping view; UI clips use the UI scale, the content scale and the
viewport's origin, independent of the camera. An entry is referenced from
layers of one space only.

**Rectangles.** Membership is half-open: a point is inside when
`left ≤ x < right` and `top ≤ y < bottom`, with `right = left + width` and
`bottom = top + height`. A zero width or height holds no point, and clips
everything; a negative extent or a coordinate that is not finite is refused.

**Validation.** Each entry's rectangle and parent are checked wherever the entry
sits, including entries no instance uses and entries of a view with no layers.
An instance's clip index must lie within its view's table. Finally the space of
every referencing layer, world or UI, is carried through the whole parent chain
of the entry it selects, and an entry reached from both spaces, directly or
through different descendants, is refused (`ClipSpaceMixed`): nesting would
intersect coordinates of different units. The refusals of a view come in this
order: its camera, viewport and settings, its table's entries, its instances,
then the mixed spaces. Every other refusal is unchanged.

**The resolver.** `resolveClips ∷ [ClipEntry] → [ResolvedClip]` intersects every
entry with its whole parent chain, in the entry's space, and answers one
`ResolvedClip` (the four edges, as floats) per entry in table order. It is pure,
total and deterministic. The intersection is computed exactly, over `Rational`s,
and rounded once to the nearest floats, so it does not depend on the depth of a
chain. An empty intersection is kept as `emptyClip` (all four edges zero),
which holds no point; an entry whose ancestor is empty is empty however its own
rectangle lies; two rectangles that only touch intersect in nothing. A sum that
overflows a float is clamped to the largest finite float, so no resolved field is
infinite or NaN because of finite endpoints, and a region narrower than the
spacing of floats at its position resolves as empty. On input that validation
would refuse, a parent that is not an earlier entry is ignored and a rectangle
that is not finite, or has a negative extent, resolves as empty.

The draw plan carries each view's resolved table (`plannedClips`). A clip index
never changes the plan: it neither splits a run nor moves an instance in the
drawing order, so instances of different clips share one draw, and an accepted
clip index reaches the encoded flags word unchanged. Applying a clip to a
fragment is the recorder's and the oracle's: see
[`hetoimasia-render-2d-vulkan`](../render-2d-vulkan/README.md) and
[`hetoimasia-render-2d-oracle`](../render-2d-oracle/README.md).

## Retained chunks

Retained chunks are D-1's static content (R2D-10, decision D-31): built once
into device buffers by a backend, listed by reference in every snapshot that
draws them, and merged with the snapshot's dynamic instances by a total order.
Only the dynamic content is republished. This package holds the backend-free
half: the **description** every pure step reads, so validation, planning, the
encoder and the oracle resolve a reference without a GPU or any Vulkan package.

**References.** A `ChunkRef` is an index and a generation a backend issues, like
a `TargetRef`: opaque to game code (`Eq`, `Ord` and `Show` only), holding no
native handle, acquiring nothing and keeping nothing alive. A backend that
reuses an index gives it the next generation, so a stale reference never
resolves to rebuilt content. `Hetoimasia.Render.TwoD.Chunk.Backend` builds and
reads one.

**Kinds.** A chunk is built for exactly one kind of layer (`ChunkKind`): a world
layer with depth (`ChunkWorldDepth`), a world layer without it
(`ChunkWorldFlat`) or a UI layer (`ChunkUi`), and may be listed only by a layer
of that kind. Its instances are in the layer's space, and so are its bounds.

**Building.** `buildChunk marks kind bounds instances` validates every instance
as a snapshot's would be (`instanceReasons`, each reported with its build
position as `ChunkInstanceInvalid`) and the bounds, and either reports every
reason or builds an immutable `Chunk` that holds the instances in **build
order** (the order the application gave them), the textures they name
(`chunkTextures`), the bounds and the routing. A chunk with no instance has no
geometry: it needs supplied bounds.

- **Routing is fixed at build (D-3, D-22, D-27).** Only a `ChunkWorldDepth`
  chunk routes anything to the cutout path, and then only an instance that
  meets every condition the draw plan's routing lists, against the marks the
  chunk is built with: a marked texture, a cutout-capable material, a tint alpha
  of 255 and neither flag. A `ChunkWorldFlat` or `ChunkUi` chunk puts every
  instance on the ordered path. The routing never changes: a texture swap shows
  through the chunk because an instance names the handle, and a swap that would
  change the handle's registered mark is refused at the swap (D-27), so the
  routing stays true. The chunk holds its cutout instances in the order a device
  buffer will hold them (`chunkCutoutPositions`: by material, then build order)
  and its ordered instances by ascending depth key and then build order
  (`chunkOrderedPositions`), so merging them needs no sort of their own.
- **Bounds conservatively enclose the geometry.** The geometry of an instance is
  the unit square its transform places, so on each axis it lies between
  `t + min 0 a + min 0 c` and `t + max 0 a + max 0 c` (for the x axis; likewise
  y). `DeriveBounds` takes the rectangle over every instance exactly, in
  rationals, and rounds each edge outward to a 32-bit float (`ChunkBoundsNotRepresentable`
  when the geometry leaves the float range, `ChunkBoundsUnderivable` for a chunk with no
  instance). `SuppliedBounds` are refused unless they are finite
  (`ChunkBoundsNotFinite`), not inverted (`ChunkBoundsInverted`) and enclose that
  rectangle exactly (`ChunkBoundsInsufficient`); bounds larger than needed are
  accepted and only make culling less eager.

**Resolution (no GPU lookup).** `validateSnapshotWith chunks snapshot` resolves
every listed reference through the `Chunks` the caller holds (`chunksFrom`, by
exact reference, generation included); `validateSnapshot` is the same against no
chunks, so it refuses a layer that lists one. A reference the chunks do not
hold is refused as `ChunkUnresolved`, and one built for another kind of layer as
`ChunkKindMismatch`, each at an `AtChunk` location naming the layer and the
chunk, before the layer's instances. The `ValidSnapshot` keeps what each listing
resolved to (`validLayerChunks`, in listed order, a chunk listed twice appearing
twice), so everything after validation reads the same description and nothing
looks anything up. `validChunkRefs` names every chunk the snapshot lists, once
each, in the order first listed.

**Culling (D-31).** `chunkCulled mapping extent viewport kind bounds` says
whether a view skips a chunk: its bounds, mapped through the view's transform
(`worldTransform` for a world chunk, `uiTransform` for a UI one, so a rotation,
a shear, a UI scale and a content scale enlarge it exactly as they enlarge the
chunk), lie wholly outside the viewport clamped to the target. It is
conservative: the mapped rectangle is widened by half a pixel when the view
snaps (an instance's origin rounds by at most that), by a sixteenth of a pixel
(the width of the oracle's band in which coverage is undecided) and by a
relative slack for 32-bit arithmetic, so a chunk whose edge touches the view is
kept and one that cannot be decided is never discarded. Only chunks are culled:
dynamic instances are not.

## The draw plan

`planSnapshot marks valid` is pure and total over a validated snapshot. It
keeps the snapshot's structure: the passes in list order, within each pass the
views in order, within each view the layers in order, and within each layer an
ordered list of draw runs. A `PlannedPass` keeps its target and clear, a
`PlannedView` its camera, viewport, settings and resolved clip table, and a `PlannedLayer` its
`Location` (`AtLayer`), its `LayerSpace` (`WorldSpace` with its depth, or
`UiSpace`) and whether it clears depth.

A `PlannedLayer` carries its drawing order as `plannedOrder`, a permutation of
the layer's submission indices (an unboxed array, the one structure the plan
keeps per instance; `drawingOrder` lists it), so a recorder can encode
instances in drawing order. A `DrawRun` names its `DrawPath` (`Cutout` or
`Ordered`), its `Material` and a contiguous range of that permutation
(`runStart`, `runCount`; `runIndices` lists it). A zero-size viewport and a
layer with no instances hold no runs, and a zero-size viewport holds no order
either. A world layer with depth enabled is marked `plannedClearsDepth`: it
clears depth within its viewport before its runs, whether or not any instance
takes the cutout path.

**The marks (choice A).** A texture's cutout mark is an input. The caller gives
`cutoutMarks` the complete handles, generation included, that are marked
cutout-safe; the mark is computed by `asset-image`, may be overridden when the
texture is registered with `render-2d`, and is fixed at registration (D-19,
D-27). This package computes and stores none. A handle that is not in the set,
including one that only shares a lookup index with a marked handle, is
unmarked and takes the ordered path.

**Routing (D-3, D-22, D-24, D-25).** An instance takes the cutout path only when
all of these hold; every other instance takes the ordered path:

| Condition | Why |
| --- | --- |
| it is in a world layer whose depth is enabled | without depth there is nothing to resolve overlap, so a layer without depth and every UI layer draw wholly in the ordered path |
| its texture is marked cutout-safe | an unmarked or unknown handle is ordered |
| its material is cutout-capable | only cutout-capable materials route to the cutout pass |
| its tint alpha is 255 | a fading sprite must blend |
| its translucent flag and its additive flag are both clear | both always take the ordered path |

Until application materials exist (R2D-11), every instance uses the built-in
`DefaultMaterial`, which is cutout-capable; how an instance names a material,
and splitting runs between materials, arrive with application materials.

**Ordering within a layer.** The cutout runs come first, ordered by material
and then by submission sequence (an instance's position in its own layer, from
zero); the depth buffer, not the sort, resolves their overlap. The
ordered-path instances follow, sorted back to front: ascending depth key, since
a larger key is nearer, then ascending submission sequence. **UI layers, and
every layer without depth, sort wholly this way**: by ascending depth key and
then submission sequence, which at equal keys is plain painter's order, so a
UI instance with a larger key draws over one submitted later with a smaller
key. The order is total and repeatable: the same snapshot and marks always
give the same plan.

**Runs.** Consecutive instances in the drawing order share a run when they
share a path and a material. A sampler choice, a tint, a depth key, a
transform, a UV rectangle or a material parameter word never splits a run,
because each travels in the instance; so a layer holds at most two runs until
application materials exist, its cutout run and its ordered run.

**Equal keys (D-23).** The plan realizes two documented outcomes:

1. Among cutouts at an equal key, the later draw in run order wins, because the
   recorder draws them with a less-or-equal depth test; runs are ordered by
   material, and instances within a run by submission sequence.
2. At an equal key, an ordered-path instance always draws after a cutout, and
   so over it, because the ordered path follows every cutout run.

An adapter that needs a guaranteed winner between two instances gives them
distinct depth keys.

**Chunks and the merge order (R2D-10).** A layer's content has a **source
order**: the chunks it lists, in the order it lists them, each listing in the
chunk's build order, then its dynamic instances in submission order. A chunk
listed twice contributes at both places. The plan merges the sources with the
rules above, the source order breaking every tie:

- the **cutout runs** come first, ordered by material and then by source order:
  within a material, each chunk listing's cutouts are one run that reads the
  chunk's own device buffer (`ChunkRun position`, from the first cutout the run
  holds, `runStart`, for `runCount` instances, in the chunk's cutout order),
  listings in order, then the dynamic cutouts as one run of the frame's ring
  (`RingRun`). The depth buffer resolves their overlap, and at an equal key the
  later source wins: a later listed chunk, or the dynamic instance over a
  chunk's.
- the **ordered runs** follow: the ordered-path instances of every listed chunk
  and of the layer's own are merged into one run by ascending depth key and then
  source order (a chunk before any dynamic instance, listings in order, build
  order), and are written to the ring each frame in that order. An ordered
  instance at an equal key therefore draws after, and so over, a cutout, from
  any source.

The ring's entries are `plannedOrder` with `plannedOrigin` (for each entry, `-1`
for a dynamic submission index and otherwise the listing the build position is
in; `drawingSources` lists them as `DynamicInstance` and `ChunkInstance`); a
chunk's cutouts are not among them, so they are never re-encoded or rewritten.
`RingRun`s partition the ring's entries, as every run did before chunks. The
order is total and repeatable. A zero-size viewport plans nothing from a chunk,
either.

`planSnapshotCulled culler marks valid` leaves out the chunk listings the culler
skips for each view (`ChunkCuller`: pass index, view index, kind and bounds; see
`chunkCulled`). The plan of a view is then exactly the plan without those
listings, and `plannedCulled` names them by position in the layer's list.
`planSnapshot` culls none.

**Cost.** Planning allocates the two index arrays per layer and sorts the merged
ordered instances once, O(n log n) in their count (a chunk's ordered instances
are held sorted, so the sort meets presorted runs); a chunk's cutout instances
cost nothing per frame.

## Mapping views

`viewMapping metrics view` is the one pure mapping of a view, shared by drawing
and picking. It converts window points (a cursor position) to world or UI
points and back, and knows the logical size, the framebuffer size and the
content scale. It is built from plain values, so this package needs no window
package: the caller fills a `TargetMetrics` from the window layer's
observation (its logical `Extent`, framebuffer `Extent` and `ContentScale`,
copied field by field) or, for an offscreen target, from
`offscreenMetrics (PixelExtent w h)`, whose logical extent equals its pixel
extent and whose content scale is 1.

**Units.** A viewport is a rectangle of **target pixels**: framebuffer pixels
for the window, the origin at the upper left and Y down. Every mapped position
is in target pixels. Converting them to Vulkan clip space belongs to the
recorder. Extents are whole, non-negative pixel counts (a zero extent is an
ordinary observation, as a minimized window reports), and a content-scale
component is finite and strictly positive.

**World.** With `C` the viewport's centre, `p` the camera position, `θ` its
rotation in radians (0 for none) and `s` the uniform scale on both axes:

```text
target = C + s · R(−θ) · (world − p)
s = zoom                          pixels per world unit
s = viewportHeight · zoom / (2h)  a fixed half-height h
```

The camera position appears at the viewport's centre (exactly, with snap off).
In pixels-per-unit mode one world unit spans `zoom` framebuffer pixels, so a
larger window shows more world and a whole-number zoom gives exact pixel
spacing. In fixed-half-height mode half the viewport's height spans `h ÷ zoom`
world units at any resolution; the same total area is visible only while the
aspect ratio is unchanged. `R` is the rotation of
[the math package](../math/README.md#affine2): a positive angle takes +X toward
+Y, which is clockwise on a Y-down screen. The camera is turned by `θ` about
the viewport's centre, so the target's +X axis points along world
`(cos θ, sin θ)` and the world appears turned by `−θ`: at `θ = π/2` world +Y
lies to the right of the centre and world +X above it.

**UI.** Independent of the camera, per axis, with UI scale `u` and content
scale `k`:

```text
target = viewportOrigin + uiPoint · (u · k)
```

so a UI element has the same physical size on any display.

**Window.** A window point maps to a framebuffer pixel by the ratio of the
framebuffer extent to the logical extent, per axis, and content scale plays no
part:

```text
framebuffer = window · framebufferExtent / logicalExtent
```

`windowToWorld` and `windowToUi` compose it with the inverse transforms, and
`worldToWindow` and `uiToWindow` go back.

**Pixel snap and picking.** `snapPixel x = floor (x + 0.5)` per axis, evaluated
exactly (halves round up: −0.5 gives 0; a whole Float such as 8388609 stays),
and `snapPoint` applies it to a position. With a view's pixel snap on, the
world mapping rounds its translation, which is the camera's. The UI transform
stays the continuous equation above, with the viewport's origin as it is; UI
snaps in device pixels through the rounding of UI instance origins. The recorder
rounds each instance's origin rigidly in the shader, which
`snapPoint (worldToTarget m origin)` and `snapPoint (uiToTarget m origin)`
reproduce (`mappingPixelSnap` says whether the view snaps). The inverse
conversions stay **unsnapped**: they invert the same transform drawing uses,
with its snapped translation where it has one, and round no result. So for the
transform `F` drawing uses, `|snapPoint (F p) − F p| ≤ 0.5` per axis, and a
snapped sprite's drawn origin differs from the unsnapped inverse's point by at
most half a device pixel per axis. That promise holds against `F`, not against
a separate transform with an unsnapped camera: with the viewport centre at 50,
zoom 1, camera 0.25 and an instance origin 0.5, the ideal position is 50.25,
the camera-snapped position 50.5 and the drawn origin 51. With snap on the
camera position appears within half a pixel of the centre. Which instance lies
under a point stays the game's question.

**Float resolution.** The transforms hold 32-bit coefficients. The world
translation is the viewport's centre minus the scale times the camera position,
and once that product exceeds 2²³ pixels one ulp of it is more than a pixel:
the mapping is still finite and inverts exactly what it holds, but the camera
position then appears at the centre only to that resolution, with snap on or
off (scale 40960 pixels per unit at position 999.99 lands pixels away). The
half-pixel promise is unaffected, because it compares a position with its own
rounding. A game with such ranges keeps its camera near the origin.

**Degenerate and unrepresentable input.** Nothing is clamped, and every refusal
is `Nothing`:

- A view that validation refuses (`viewReasons` lists why), metrics with a
  negative extent, or a content scale that is not finite and positive, give no
  mapping.
- A mapping whose coefficients, or whose inverse for a non-empty viewport,
  cannot be finite `Float`s gives no mapping: a camera position of 2e38 at zoom
  2 overflows, and a subnormal scale has no representable inverse.
- A viewport with a zero width or height draws nothing (`viewportIsEmpty`), and
  its inverse transforms and conversions are `Nothing`.
- A zero logical or framebuffer extent makes every window conversion `Nothing`;
  world and UI conversions still work.
- A conversion of a non-finite point, or one whose result overflows, is
  `Nothing`.
- A point outside the viewport still converts. `viewportContains` says whether
  a target-pixel point is inside: the left and top edges are in, the right and
  bottom edges out, and an empty viewport contains nothing.

No conversion produces a NaN or an infinity; every function is pure and total.

## Discrete step zoom

Discrete step zoom is an application-wide setting, independent of the per-view
settings, of pixel snap and of the zoom mode, and it is not part of a snapshot.
It is a list of zoom levels read in a view's zoom mode; smooth zoom stays
available whatever the list holds. `validateZoomSteps` refuses an empty list
(`ZoomListEmpty`), a level that is NaN, infinite, zero or negative
(`ZoomLevelInvalid`), and a level not greater than the one before it
(`ZoomLevelNotIncreasing`, checked independently of the first and skipped only next to a NaN, which has no order), each
naming the level (`AtLevel`) and all together. The default list is the whole
numbers 1 to 8.

`stepZoomIn` returns the smallest level greater than the current zoom, or the
largest level when none is greater; `stepZoomOut` returns the largest level
smaller than the current zoom, or the smallest when none is smaller. The levels
and the zoom are read in the same zoom mode, so the functions only compare
numbers. Smooth zoom stays a plain zoom value that they never touch.

## The instance encoding

`encodeLayer` writes a valid layer's instances, in submission order, into one
strict buffer of exactly 64 bytes per instance, little-endian. It is pure and
total, linear in the number of instances, allocates no per-instance buffer, and
gives the same bytes for the same layer.

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

The transform maps `(x, y)` to `(a·x + c·y + tx, b·x + d·y + ty)`; see
[the math package](../math/README.md#affine2).

The flags word:

| Bits | Field |
| --- | --- |
| 0–1 | sampler choice: 0 default, 1 nearest, 2 linear; 3 is never produced |
| 2 | translucent override |
| 3 | additive flag |
| 4–15 | reserved, always 0 |
| 16–31 | clip index (unsigned 16-bit, 0 meaning none) |

The clip index occupies the top 16 bits, so a shader reads it as `flags >> 16`.
A valid layer's clip index is 0 or selects an entry of its view's clip table
([above](#clip-tables)), and encoding writes it unchanged: it neither renumbers
nor resolves it, so the table's entry order is the one a shader indexes.
`flagsWord` packs any instance, so the layout is fixed and tested independently
of validation.

**Drawing order.** `encodeLayerInDrawingOrder planned layer` writes the same
chunks permuted by a planned layer's drawing order (`drawingOrder`): its *k*-th
chunk is byte for byte the chunk `encodeLayer` writes at the position the order
lists *k*-th, so a draw run's instances are one contiguous range of the buffer,
its `runStart` and `runCount` over it with no further reordering. A layer whose
plan holds no order (an empty layer, or one in a zero-size viewport) encodes to
the empty buffer, and `Nothing` answers a plan that names an instance the layer
does not hold, which planning that layer never does. It is pure and linear in
the instance count; it allocates the one result buffer of the exact final size
and holds the layer's instances in one array while it writes.

**std430.** The 64-byte stride is std430-compatible only when a shader declares
the UV rectangle as two `vec2`s, or reads the instance as vertex attributes.
Declared as a `vec4`, the UV rectangle would align to 16 bytes and move to
offset 32, breaking the 64-byte stride. Never declare it as a `vec4`.

`encodeLayerInDrawingOrder` reads each ring entry from the layer's dynamic
instances or from the chunk listing the plan names, so a layer that lists chunks
writes its dynamic cutouts and the merged ordered instances; for a layer that
lists none it is as it always was. `encodeChunkCutouts chunk` encodes a chunk's
cutout instances once, in the order its device buffer holds them, which is what
a backend uploads.

## The quad an instance places

An instance's transform places the **unit square** [0, 1]² in its layer's
space: local (0, 0) is the instance's origin, the translation of its transform,
which pixel snap rounds, and texture coordinates interpolate affinely from
`(u0, v0)` at local (0, 0) to `(u1, v1)` at local (1, 1). Nothing in this
package draws a quad, so this is the contract the recorder's vertex stage must
meet (R2D-7); it is stated and tested in
[`hetoimasia-render-2d-oracle`](../render-2d-oracle/README.md), which computes
the pixels a snapshot draws under it, and a recorder is proven against that
oracle's probes.

## Owned state, threads and lifetimes

None: every value is pure and immutable. The package starts no thread, owns no
resource and holds no mutable state. A snapshot references the objects it names
only by value (texture handles, target references and chunk references); a
`Chunk` is an immutable description that a backend retains and resolves
references to, and holding those objects alive, publishing a snapshot to a
window and pressure on either belong to the backend and the host adapter
(R2D-14, R2D-8, R2D-10).

## Not here

Which instance lies under a point (the game's question); clip-space conversion
and the shader's snapping (R2D-7); reading window metrics and publishing per
window (R2D-14, R2D-8); culling dynamic instances per view (chunks are culled by their bounds); expected pixels (R2D-4, in
[`hetoimasia-render-2d-oracle`](../render-2d-oracle/README.md)); range writes into
a chunk, which D-31 rules out (a chunk is rebuilt whole: build a new one, publish,
release the old); the material records a chunk carries, which arrive with application
materials (R2D-11), and splitting runs between them; computing or registering a texture's
mark (R2D-7, R2D-8); recording, shaders,
samplers, the device buffers, uploads and holds of chunks and everything in
`render-2d-vulkan`; publication; clip tables in retained content beyond what
R2D-12 defines for instances; material data records; sampling offscreen
targets; stencil-based or hardware clipping and rounded or non-rectangular
clips; animation (R2D-18); and Lua bindings.

## Tests

`render-2d-tests` is the package's Hspec suite, registered as the CPU
validation group `test.render-2d`:

```bash
cabal test --project-file cabal.project.cpu hetoimasia-render-2d:render-2d-tests --test-show-details=direct
```

It checks every refusal with its location and at its boundary (depth keys
2²⁴ − 1, 2²⁴ and 2³² − 1; the Floats either side of the UI scale and
brightness ranges; NaN and both infinities), that faults at different
locations are all retained, including inside a zero-size viewport, that
offscreen-only snapshots and unchanged valid snapshots are accepted, the
window-pass rules, the zoom list's refusals, the instance layout field by field
against bytes written out by hand and an independent reference encoder, zero,
one and many instances, the flags word for every sampler choice and flag
combination with its reserved bits zero and the clip index in the top 16 bits,
every clip refusal at its location, nested and three-deep intersections, an
empty intersection and its descendants, edges that only touch, a zero extent,
large finite coordinates and the resolver's determinism over generated tables,
a clip index never splitting a run, an accepted index surviving the encoder,
and, through separately compiled external clients, that a validated value and
an offscreen target reference cannot be forged. Generated and hand-written
inputs sit side by side. For the draw plan it checks the routing of every
combination of the conditions above (layer kind, mark, tint alpha, translucent
and additive flags), a mark for one generation leaving another handle that
reuses its lookup index unmarked, the exact drawing order and runs of
interleaved cutout and translucent inputs, both equal-key outcomes as concrete
fixtures, layers without depth and UI layers taking only the ordered path in
ascending key then submission order, the depth-clear mark on every
depth-enabled world layer including an ordered-only and an empty one, a
zero-size viewport and an empty layer holding no runs, the structure of
several passes, views and layers kept with their metadata, and, over generated
snapshots, that planning twice gives the same plan, that each layer's order is
a permutation of its submission indices and its runs partition it with maximal
path grouping, that the order meets an independent characterisation, and that
shuffled equal-key inputs keep their new submission order on each path; and, by walking the heap, that the closures reachable from a planned layer do not grow with its instance count, so only the permutation is retained. For the
view mapping it checks the equations against hand-computed values (the camera
at the viewport's centre, whole-number zoom spacing, a fixed half-height at two
window sizes, a quarter-turn rotation with its signed basis vectors, UI at the
same physical size on content scale 1 and 2, window conversion at ratios 1, 2
and a different ratio per axis, a content scale unlike the extent ratio);
every combination of pixel snap, both zoom modes and smooth or discrete step
zoom across window sizes and content scales; the camera-snap counterexample
above, the UI transform unchanged by snap, and the camera's position at the centre to the stated Float resolution, far from the origin; round trips for generated views and metrics within a stated tolerance;
the half-pixel property; the snapping function at half boundaries and the
whole Float 8388609; every degenerate case, containment at all four edges, the
refusal of unrepresentable results, and, over wild and extreme inputs, that no
conversion is non-finite; and the discrete stepping at, between, below and
above the levels. For chunks it checks, for each of the three kinds, building
and routing (only a world chunk with depth puts anything on the cutout path, and
only what meets every condition; the routing fixed against later marks and equal
to the plan's for the same instances submitted dynamically), the refusal of every
instance reason with its build position, derived bounds against a corner-by-corner
characterisation within one float step, supplied bounds exactly tight, one float
step short on each edge, not finite, inverted, and empty chunks and geometry
beyond the float range; validation of the nine pairings of a chunk kind and a layer
kind, each refusing a mismatch naming the layer and the chunk, unresolved and stale
references, a stale reference never reaching rebuilt content, and chunk refusals
before instance ones; the merge order as concrete fixtures (equal keys across
chunks and the dynamic instances, the listing's order rather than the references',
a chunk listed twice, cutout runs from chunk buffers before the ring's, an ordered
instance over a cutout) and, over generated chunks and layers, that planning is
repeatable and matches an independent characterisation that numbers the instances
in source order and sorts plainly; culling at every side, touching edges, a
sixteenth of a pixel beyond, half a pixel more under pixel snap, a quarter-turn
camera, UI and content scale, a viewport beyond the target, one chunk kept in one
view and skipped in another, and, over generated views, scales and snap, against a
brute force in exact arithmetic of which pixel centres an instance covers, that a
chunk with an instance covering one is never skipped; the encoding of a chunk's
cutouts and of the merged ring entries; and, through external clients, that a
chunk reference and a built chunk cannot be forged. Hspec, QuickCheck and the external-client harness are
the suite's dependencies, not the library's.
