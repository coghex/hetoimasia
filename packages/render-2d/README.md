# hetoimasia-render-2d

The 2D renderer's frame as a value: the snapshot game code builds, the pure
validation that refuses a bad one, the application-wide discrete-step-zoom
list, and the 64-byte instance encoding a backend uploads. Mapping views to
screen space, sorting and draw runs, and everything that records commands
follow in later slices. The decision record is
[the 2D renderer design](../../docs/designs/render_2d_design.md) (D-1, D-4, D-7,
D-9, D-10, D-12, D-16 to D-18, D-23, D-24; R2D-1); the package's place among the
others is [the foundation design](../../docs/engine_foundation_design.md).

| Module | Contents |
| --- | --- |
| `Hetoimasia.Render.TwoD.Snapshot` | `Snapshot`, `Pass`, `Target` (`WindowTarget`, `OffscreenTarget`), `ClearColour`, `View`, `Viewport`, `Camera`, `Layer` (`WorldLayer`, `UiLayer`), `LayerDepth`, `Instance`, `UvRect`, `Tint`, `Sampler`; `layerInstances`, `depthKeyLimit` |
| `Hetoimasia.Render.TwoD.Settings` | `ViewSettings` and `defaultViewSettings`, `TextureFilter`, `ZoomMode`; `uiScaleRange`, `brightnessRange` |
| `Hetoimasia.Render.TwoD.Target` | `TargetRef`, the opaque offscreen target reference: `Eq`, `Ord` and `Show` only |
| `Hetoimasia.Render.TwoD.Target.Backend` | `targetRef ∷ Word32 → Word32 → TargetRef`; `targetRefIndex`, `targetRefGeneration` (backends, and tests standing in for one) |
| `Hetoimasia.Render.TwoD.Validation` | `validateSnapshot`; `Refusal`, `Location`, `Reason`; `ValidSnapshot` with `validSnapshot` and `validLayers`; `ValidLayer` with `validLayerLocation` and `validLayerContents` |
| `Hetoimasia.Render.TwoD.ZoomSteps` | `ZoomSteps`, `zoomLevels`, `defaultZoomSteps`, `validateZoomSteps`; `ZoomRefusal`, `ZoomLocation`, `ZoomReason` |
| `Hetoimasia.Render.TwoD.Encoding` | `encodeLayer ∷ ValidLayer → ByteString`; `instanceStride`, `flagsWord` |

There is no collecting module and no prelude: import the module that owns what
you use.

## Boundary

The library's `build-depends` names `base`, `bytestring`,
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
| `ViewportExtentNegative` | a finite extent is negative |
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

## Discrete step zoom

Discrete step zoom is an application-wide setting, independent of the per-view
settings, of pixel snap and of the zoom mode, and it is not part of a snapshot.
It is a list of zoom levels read in a view's zoom mode; smooth zoom stays
available whatever the list holds. `validateZoomSteps` refuses an empty list
(`ZoomListEmpty`), a level that is NaN, infinite, zero or negative
(`ZoomLevelInvalid`), and a level not greater than the one before it
(`ZoomLevelNotIncreasing`, reported only between two finite levels), each
naming the level (`AtLevel`) and all together. The default list is the whole
numbers 1 to 8.

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

View mapping and picking (R2D-2); routing between the cutout and ordered paths,
sorting and draw runs (R2D-3); expected pixels (R2D-4); recording, shaders,
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
inputs sit side by side. Hspec, QuickCheck and the external-client harness are
the suite's dependencies, not the library's.
