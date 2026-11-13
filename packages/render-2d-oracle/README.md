# hetoimasia-render-2d-oracle

The 2D renderer's oracle: expected pixels computed from a validated snapshot,
without a GPU.

From a validated `render-2d` snapshot, the cutout marks it is planned with,
each target's metrics, colour format and pixel extent, and a lookup from
texture handle to decoded image, the oracle says what one pixel of one pass's
target holds once that pass has run: an 8-bit RGBA value with a per-channel
tolerance, **indeterminate** with the reason it will not guess, or
**unevaluable** with the input defect that stops it. Every rendering slice
proves itself against it, and the recorder's offscreen readbacks are its
client. Expectations come from the snapshot, never from an observed image.

It is pure: it depends on `hetoimasia-render-2d`, `-render-api`, `-math`,
`-asset` and `-asset-image` (software BC7 decoding) and boot libraries, on no
GPU, GLFW, Vulkan, runtime or Lua package, and builds in the CPU project. It
owns no state and starts no thread; an `Oracle` is an immutable value and each
defect is reported by the probes it affects.

## Inputs

`newOracle` takes an `OracleInput`: the `ValidSnapshot`, the `CutoutMarks` it
is planned with, a `TargetSpec` for the window and for each offscreen target a
pass draws to, and the texture lookup by complete handle. A `TargetSpec` holds
the target's `TargetMetrics`, its colour format (`R8G8B8A8` or `B8G8R8A8`,
sRGB or UNORM) and its pixel extent, which must equal the metrics' framebuffer
extent. `newOracleWith models` also takes a model for each application
material the snapshot uses.

A `Probe` names a pass by index and a pixel by column and row, origin upper
left. Its expectation is the target's value once that pass has run; each pass
starts from its own clear colour.

## Placement and coverage

An instance's transform places the unit square [0, 1]² in its layer's space,
with texture coordinates interpolating affinely across it
([render-2d](../render-2d/README.md#the-frame)). The oracle composes the
layer's transform (`worldTransform` or `uiTransform`) with the instance's
exactly, in rational arithmetic over the 32-bit coefficients. With pixel snap
on, the whole quad is shifted rigidly so its origin lands on `snapPoint` of
its mapped origin; a quad's size and shape never snap.

- A view draws only pixels whose centre its viewport contains (left and top
  inclusive, right and bottom exclusive).
- An empty viewport and a singular quad contribute nothing, and neither is a
  refusal. A reflected quad is sampled with its texture reflected.
- A placement that cannot be represented as finite `Float`s is a refusal,
  never a silent skip.
- An instance covers a pixel whose centre lies inside its placed quad. A
  centre within 1/16 pixel of the quad's edge, or of a viewport edge that is
  not on a whole pixel, is indeterminate: a rasterizer's fixed-point snapping
  can fall either side.

## Sampling

- The instance's sampler resolves through the view's default filter.
  Addressing is clamp-to-edge.
- **Nearest** takes the texel containing the coordinate. Within 1/16 texel of
  an interior boundary the probe is indeterminate unless the texels on both
  sides are alike.
- **Linear** weighs the four texels around `coordinate × extent − ½`, exactly.
- An sRGB texture's colour channels decode to linear light before filtering.
  Colour art is already premultiplied by the asset pipeline. BC7 levels are
  decoded in software.
- A handle absent from the lookup samples the placeholder, a 1×1
  transparent-black texel. A handle is compared complete, generation included.
  A malformed image the lookup returns is refused, never replaced by the
  placeholder.

**The mip level** is computed from the placed quad's texture-coordinate
derivatives as Vulkan's `ρmax`, exactly, with `λ = log₂ ρmax`.

- One level, or a magnified probe (`λ ≤ 0`), samples level 0.
- A minified probe is determinate when the derivatives are axis-aligned (no
  shear, rotation only by quarter turns) and `λ` is exactly a whole number or
  at least the last level's index.
- Any other minified probe on a texture with more than one level is
  indeterminate. There is no tolerance: a camera turned by the 32-bit `π/2` is
  not axis-aligned, while a transform written with exact coefficients is.

## Colour

With `t` the sampled texel (premultiplied, linear), `m` the material's colour
(`t` for the default material), `c` the tint and `b` the view's brightness:

```
s     = m × c                     componentwise
s.rgb = s.rgb × b
s.a   = 0                         for an additive instance
s     = clamp s to [0, 1]
result = s + destination × (1 − s.a)      clamped to [0, 1]
```

- **Every store is rounded, and a tie is a range.** Each blended fragment's
  result is encoded to the target's 8-bit storage before the next fragment
  reads it. Vulkan requires round-to-nearest but does not fix the direction of
  a tie, so a store holds every byte within half a step plus 1/1024 of the
  value, and that range carries through later blends. A channel is determinate
  when its possible final bytes span at most three; a wider range makes the
  probe indeterminate (`RoundingNotBounded`), never given a wider tolerance.
- An sRGB target decodes the destination before blending and encodes on
  store; alpha is linear in every format.
- The result is reported in RGBA order whatever the target's channel order.

## Order and depth

The oracle visits a pass's views, each view's layers, and each layer's
instances in the plan's drawing order
([render-2d](../render-2d/README.md#the-draw-plan)). A layer without depth
draws each covering instance in that order, blended. Retained chunks are
evaluated as the plan merges them, from the chunks the `ValidSnapshot`
carries, with the routing each chunk was built with. A view that culls a
chunk contributes none of it; culling changes no pixel the view draws.

A depth-enabled world layer, per probe pixel:

1. **The clear.** Depth is 1.0 at every pixel the viewport contains when the
   layer begins. Two depth-enabled layers' keys are independent.
2. **Depth from the key.** An instance of key *k* has depth
   `(2²⁴ − 1 − k) / 2²⁴`, constant across its quad. The comparison is
   less-or-equal.
3. **Cutout runs** come first. The cutout variant computes `s = m × c` and
   discards a fragment whose `s.a`, before brightness, is below ½, writing
   neither colour nor depth. A surviving fragment that passes the depth test
   writes depth and the colour `(s.rgb / s.a) × b` with alpha 1. A filtered
   edge sample `(0.6, 0.6, 0.6, 0.6)` therefore writes white, not grey.
4. **Ordered instances** follow. Each is tested against the depth the cutouts
   left, blended if it passes, and writes no depth.

Among cutouts of an equal key the later draw wins, and at an equal key an
ordered instance draws over a cutout.

**The threshold band.** A cutout sample whose filtered alpha lies within 2/255
of ½ (8-bit alphas 126 to 129) is indeterminate (`NearCutoutThreshold`),
whether or not another instance would hide it.

## Clips

An instance with a nonzero clip index is clipped by its view's resolved clip
rectangle ([render-2d](../render-2d/README.md#clip-tables)), exactly:

- **Membership.** The probe's pixel centre is carried back to the layer's
  space by the exact inverse of the layer's transform and compared with the
  half-open rectangle. Outside it the instance draws neither colour nor depth.
  The sprite's own origin snap is not part of the clip.
- **The edge band.** A centre within 1/16 pixel, measured in target pixels, of
  the transformed rectangle's boundary is `NearClipEdge`, for an instance that
  could draw at the probe. `NearQuadEdge` wins when both hold.
- **An empty clip** holds no point and has no boundary: the instance gives
  nothing and no probe is indeterminate for its edge.

## Application materials

The default material's model is built in. Any other material needs a model
passed to `newOracleWith`: a pure Haskell function
(`MaterialModel`, in `Hetoimasia.Render.TwoD.Oracle.Material`) of the same
inputs the material's GLSL function receives: the primary texel, the texture
coordinates, the instance's parameter word, the record it indexes, the push
block's bytes, and samplers for other textures.

- Secondary sampling is generation-aware, like the primary's.
- The oracle knows the rate of change only for the fragment's own coordinates.
  `materialSample` at other coordinates of a multi-level texture is
  indeterminate (`UnrelatedSecondaryCoordinates`); a model that derives its
  coordinates from the fragment's states the scale factor with
  `materialSampleScaled`.
- The oracle applies the same wrapping to the model's colour as to the default
  texel: tint, brightness, the additive rule, and the cutout rule and its
  threshold band.
- A material with no model is `MissingMaterialModel`; a non-finite colour is
  `ModelOutputNotFinite`.

`Oracle.Material.Sample.mixModel` is the model of the sample material in
`render-2d-vulkan`.

## Animation (R2D-18, D-32)

An instance whose frame-table index selects a table of its view shows the
rectangle of the table's current frame at the view's animation time, in place
of its own UV rectangle, for dynamic and chunk instances alike. The frame is
`currentFrame`, the same function the recorder evaluates
([render-2d](../render-2d/README.md#animation)). Boundaries are exact: there
is no epsilon and no indeterminacy band for animation.

## Verdicts and exactness

An expectation is `Expected value tolerance`, `Indeterminate why` or
`Unevaluable failure`. `judge` and `judgeReadback` pass when every channel is
within its tolerance; an indeterminate or unevaluable probe is never a pass.
If a probe is both, it is unevaluable.

**The exactness rule.** A channel's tolerance is 0 when its final stored value
involves no rounding, and 1 otherwise:

- a texel byte carried through unchanged is exact only when the texture and
  target store colour alike, the filter reads one texel or alike texels, the
  tint byte is 255, the brightness is 1, and the fragment replaces the
  destination or lands on a destination byte of 0;
- a value that is exactly 0 or 1 is exact in every format;
- anything else is within one, including all additive colour;
- a cutout fragment's colour is exact only when its alpha is exactly 1 and its
  colour exact, or the quotient is exactly 0 or 1.

| Indeterminate reason | When |
| --- | --- |
| `NearViewportEdge` | Within 1/16 pixel of a viewport edge that is not on a whole pixel |
| `NearQuadEdge` | Within 1/16 pixel of an instance's quad edge |
| `NearClipEdge` | Within 1/16 target pixel of a clip boundary of an instance that could draw there |
| `NearCutoutThreshold` | A cutout sample's alpha within 2/255 of ½ |
| `MinifiedNotAxisAligned`, `MinifiedFractionalLevel` | A minified probe on a multi-level texture that is sheared, rotated off a quarter turn, or between levels |
| `NearTexelBoundary` | A nearest coordinate within 1/16 texel of a boundary between differing texels |
| `UnrelatedSecondaryCoordinates` | A model sampled a multi-level texture at coordinates of unknown rate |
| `RoundingNotBounded` | A channel's possible stored bytes span more than three |

| Unevaluable failure | When |
| --- | --- |
| `PassOutOfRange`, `PixelOutsideTarget` | The probe names no pass or pixel of the snapshot |
| `MissingTarget`, `InvalidMetrics`, `ExtentDisagrees`, `TargetTooLarge` | The target's spec is absent, invalid, inconsistent, or beyond 2²³ pixels |
| `MappingNotRepresentable`, `PlacementNotRepresentable` | A needed mapping or quad is not finite `Float`s |
| `MissingMaterialModel`, `ModelOutputNotFinite` | See above |
| `MalformedImage` | A texture the lookup returned is not well formed, for a probe an instance covers |

`readPixel` and `readProbe` read a pixel from a tightly packed readback (rows
top first, four bytes a pixel, the target's own format), swizzling `B8G8R8A8`
to RGBA. `ReadbackSizeWrong`, `ReadbackPixelOutside` and
`ReadbackExtentInvalid` are faults, never pixels.

## What is shared with `render-2d`, and what is independent

**Shared**, so a mistake in one is a mistake in both and the fixtures do not
rely on them: `ValidSnapshot` and its validation, the chunks it carries,
`chunkCulled`, `viewMapping` and its transforms, `snapPoint`,
`viewportContains`, `planSnapshot` with its drawing order and routing, and
`currentFrame`.

**Independent**, written here in rational arithmetic: composing transforms,
coverage, clip membership and edge distance, derivatives, level selection,
texel addressing and filtering, the sRGB transfer function, shading and blend
equations, store rounding, the exactness rule, verdicts and the readback
reader.

The suite's fixtures are independent of both: each expected value is written
in the test as a hand-drawn picture or as bytes worked from the equations
above. Against synthetic readbacks the suite shows the oracle rejects reversed
overlap, a channel off by two and a wrong snap.

## Precision

Placement and texel addressing are exact over the snapshot's 32-bit
coefficients, while the recorder places in 32-bit arithmetic. The 1/16-pixel
band absorbs the difference while placed coordinates stay below about 2¹⁶
pixels. Beyond that the oracle claims only its own arithmetic, and a game that
places quads that far from the origin should not read a probe near an edge as
determinate.

## Tests

```bash
cabal test --project-file cabal.project.cpu hetoimasia-render-2d-oracle:render-2d-oracle-tests --test-show-details=direct
```
