# hetoimasia-render-2d

The 2D renderer's frame as a value: the snapshot game code builds, the pure
validation that refuses a bad one, the application-wide discrete-step-zoom
list, the pure draw plan that routes, orders and splits a validated frame's
instances into draw runs, the pure mapping of a view between window,
framebuffer, UI and world space, and the 64-byte instance encoding a backend
uploads. Everything that records commands follows in later slices. The decision
record is
[the 2D renderer design](../../docs/designs/render_2d_design.md) (D-1 to D-4,
D-7 to D-10, D-12, D-16 to D-19, D-22 to D-25, D-27, D-29; R2D-1 to R2D-3); the package's place among the
others is [the foundation design](../../docs/engine_foundation_design.md).

| Module | Contents |
| --- | --- |
| `Hetoimasia.Render.TwoD.Snapshot` | `Snapshot`, `Pass`, `Target` (`WindowTarget`, `OffscreenTarget`), `ClearColour`, `View`, `Viewport`, `Camera`, `Layer` (`WorldLayer`, `UiLayer`), `LayerDepth`, `Instance`, `UvRect`, `Tint`, `Sampler`; `layerInstances`, `depthKeyLimit` |
| `Hetoimasia.Render.TwoD.Settings` | `ViewSettings` and `defaultViewSettings`, `TextureFilter`, `ZoomMode`; `uiScaleRange`, `brightnessRange` |
| `Hetoimasia.Render.TwoD.Target` | `TargetRef`, the opaque offscreen target reference: `Eq`, `Ord` and `Show` only |
| `Hetoimasia.Render.TwoD.Target.Backend` | `targetRef ∷ Word32 → Word32 → TargetRef`; `targetRefIndex`, `targetRefGeneration` (backends, and tests standing in for one) |
| `Hetoimasia.Render.TwoD.Validation` | `validateSnapshot`; `Refusal`, `Location`, `Reason`; `ValidSnapshot` with `validSnapshot` and `validLayers`; `ValidLayer` with `validLayerLocation` and `validLayerContents` |
| `Hetoimasia.Render.TwoD.ZoomSteps` | `ZoomSteps`, `zoomLevels`, `defaultZoomSteps`, `validateZoomSteps`; `stepZoomIn`, `stepZoomOut`; `ZoomRefusal`, `ZoomLocation`, `ZoomReason` |
| `Hetoimasia.Render.TwoD.Metrics` | `TargetMetrics` (logical extent, framebuffer extent, per-axis content scale), `PixelExtent`; `offscreenMetrics`, `validMetrics` |
| `Hetoimasia.Render.TwoD.Mapping` | `viewMapping ∷ TargetMetrics → View → Maybe ViewMapping`; the transforms `worldTransform`, `worldInverse`, `uiTransform`, `uiInverse`; the point conversions `worldToTarget`, `targetToWorld`, `uiToTarget`, `targetToUi`, `windowToTarget`, `targetToWindow`, `windowToWorld`, `worldToWindow`, `windowToUi`, `uiToWindow`; `viewportIsEmpty`, `viewportContains`; `snapPixel`, `snapPoint`; `mappingPixelSnap` |
| `Hetoimasia.Render.TwoD.DrawPlan` | `planSnapshot ∷ CutoutMarks → ValidSnapshot → DrawPlan`; `CutoutMarks` with `cutoutMarks`, `noCutoutMarks`, `isMarkedCutout`; `DrawPlan`, `PlannedPass`, `PlannedView`, `PlannedLayer`, `LayerSpace`, `DrawRun`, `DrawPath` (`Cutout`, `Ordered`), `Material` (`DefaultMaterial`) with `materialCutoutCapable`; `drawingOrder`, `runIndices` |
| `Hetoimasia.Render.TwoD.Encoding` | `encodeLayer ∷ ValidLayer → ByteString`; `instanceStride`, `flagsWord` |

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
camera, a viewport rectangle within the target, its per-view settings and its
ordered layers. A layer is a world layer (game units through the camera, with
depth enabled or not) or a UI layer (logical pixels from the upper left), each
holding its instances in submission order. Y points down everywhere: world, UI,
texture coordinates and clip space.

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
- **Depth keys** lie in [0, 2²⁴). A larger key is refused, never wrapped or
  collapsed; a larger key is nearer.

## Validation

`validateSnapshot` turns a candidate into a `ValidSnapshot` or refuses it with
**every** reason found, each naming where: the pass, view, layer and instance
index (`AtPass`, `AtView`, `AtLayer`, `AtInstance`). Nothing is clamped,
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
| `ClipIndexNotZero` | a clip index is not zero, until clip tables exist |

NaN and both infinities are refused explicitly, so no range comparison can
accept one by accident. A snapshot holding only offscreen passes is valid, for
window-free rendering and evidence. That a snapshot published to a window holds
a window pass is a publication rule, not a validation one.

**Validated values are opaque.** A `ValidSnapshot` and a `ValidLayer` are made
only by validation: their constructors are private and no record-update route
exists, so a function that takes one can rely on every check above.
`validLayers` gives each layer of a valid snapshot, with its location, in pass,
view and layer order, and `encodeLayer` accepts only such a layer.

**Offscreen targets.** A `TargetRef` is an index and a generation a backend
issues. It holds no native handle, building one acquires nothing and starts no
lifetime, and game code can only compare, order and show one.
`Hetoimasia.Render.TwoD.Target.Backend` builds and reads one, for backends and
for tests that stand in for one.

## The draw plan

`planSnapshot marks valid` is pure and total over a validated snapshot. It
keeps the snapshot's structure: the passes in list order, within each pass the
views in order, within each view the layers in order, and within each layer an
ordered list of draw runs. A `PlannedPass` keeps its target and clear, a
`PlannedView` its camera, viewport and settings, and a `PlannedLayer` its
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

**Cost.** Planning allocates the one permutation per layer and sorts it once,
O(n log n) in the layer's instance count.

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
mapping rounds the translation of each transform: the camera's translation for
the world, the UI origin for the UI. The recorder rounds each instance's origin
rigidly in the shader, which `snapPoint (worldToTarget m origin)` reproduces.
The inverse conversions stay **unsnapped**: they invert the same transform
drawing uses, with its snapped translation, and round no result. So for the
transform `F` drawing uses, `|snapPoint (F p) − F p| ≤ 0.5` per axis, and a
snapped sprite's drawn origin differs from the unsnapped inverse's point by at
most half a device pixel per axis. That promise holds against `F`, not against
a separate transform with an unsnapped camera: with the viewport centre at 50,
zoom 1, camera 0.25 and an instance origin 0.5, the ideal position is 50.25,
the camera-snapped position 50.5 and the drawn origin 51. With snap on the
camera position appears within half a pixel of the centre. Which instance lies
under a point stays the game's question.

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
A non-zero clip index is refused until clip tables exist, so a valid layer's
flags word has its top 16 bits zero for now; `flagsWord` packs any instance, so
the layout is fixed and tested independently of that refusal.

**std430.** The 64-byte stride is std430-compatible only when a shader declares
the UV rectangle as two `vec2`s, or reads the instance as vertex attributes.
Declared as a `vec4`, the UV rectangle would align to 16 bytes and move to
offset 32, breaking the 64-byte stride. Never declare it as a `vec4`.

## Owned state, threads and lifetimes

None: every value is pure and immutable. The package starts no thread, owns no
resource and holds no mutable state. A snapshot references the objects it names
only by value (texture handles and target references); holding those objects
alive, publishing a snapshot to a window and pressure on either belong to later
slices of the design (R2D-14, R2D-8).

## Not here

Which instance lies under a point (the game's question); clip-space conversion
and the shader's snapping (R2D-7); reading window metrics and publishing per
window (R2D-14, R2D-8); culling instances per view; expected pixels (R2D-4); retained static
content and its merge with the dynamic snapshot (R2D-10); application materials
and splitting runs between them (R2D-11); computing or registering a texture's
mark (R2D-7, R2D-8); recording, shaders,
samplers and everything in `render-2d-vulkan`; publication; retained static
content; material data records and clip tables; sampling offscreen targets; and
Lua bindings.

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
shuffled equal-key inputs keep their new submission order on each path. For the
view mapping it checks the equations against hand-computed values (the camera
at the viewport's centre, whole-number zoom spacing, a fixed half-height at two
window sizes, a quarter-turn rotation with its signed basis vectors, UI at the
same physical size on content scale 1 and 2, window conversion at ratios 1, 2
and a different ratio per axis, a content scale unlike the extent ratio);
every combination of pixel snap, both zoom modes and smooth or discrete step
zoom across window sizes and content scales; the camera-snap counterexample
above; round trips for generated views and metrics within a stated tolerance;
the half-pixel property; the snapping function at half boundaries and the
whole Float 8388609; every degenerate case, containment at all four edges, the
refusal of unrepresentable results, and, over wild and extreme inputs, that no
conversion is non-finite; and the discrete stepping at, between, below and
above the levels. Hspec, QuickCheck and the external-client harness are
the suite's dependencies, not the library's.
