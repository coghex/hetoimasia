# hetoimasia-render-2d-oracle

The 2D renderer's oracle: expected pixels computed from a validated snapshot,
without a GPU.

From a validated `render-2d` snapshot, the cutout marks it is planned with,
each target's metrics, colour format and pixel extent, and a lookup from texture
handle to decoded image, the oracle says what one pixel of one pass's target
holds once that pass has run: an 8-bit RGBA value with a per-channel tolerance,
or **indeterminate** with the reason it will not guess, or **unevaluable** with
the input defect that stops it. A pure reader returns a pixel of a tightly
packed readback, and a verdict compares the two. Every rendering slice proves
itself against it ([the design](../../docs/designs/render_2d_design.md): D-12,
*Verification strategy*), and the recorder's offscreen readbacks (R2D-7, and
R2D-9 for the cutout path and depth, and R2D-10 for retained chunks) are its
client. Expectations come from the
snapshot, never from an observed image.

It is a pure package. The library depends on `hetoimasia-render-2d` (the
snapshot, validation, the view mapping and the draw plan), `hetoimasia-render-api`
(the texture handle), `hetoimasia-math`, `hetoimasia-asset` (the decoded image)
and `hetoimasia-asset-image` (software BC7 decoding), and on `array`,
`bytestring`, `containers`, `text` and `base`. It depends on no GPU, GLFW,
Vulkan, runtime or Lua package, so it builds in the CPU project.

## Inputs

`newOracle` takes an `OracleInput`:

| Field | Meaning |
| --- | --- |
| `inputSnapshot` | A `ValidSnapshot`. |
| `inputCutoutMarks` | The `CutoutMarks` the snapshot is planned with (`planSnapshot`). |
| `inputWindow` | The window target's `TargetSpec`, if any pass draws to it. |
| `inputOffscreen` | A `TargetSpec` for each offscreen `TargetRef` a pass draws to. |
| `inputTextures` | The `DecodedImage` behind a complete handle, generation included. |

A `TargetSpec` holds the target's `TargetMetrics` (logical extent, framebuffer
extent, content scale), its colour format (`R8G8B8A8` or `B8G8R8A8`, each sRGB
or UNORM) and its pixel extent. The metrics are what the view mappings are built
from, and the pixel extent must be the metrics' framebuffer extent: the oracle
checks, and refuses a disagreement, so a mapping built for one size is never
read as another's pixels.

A `Probe` names a pass by index and a pixel by column and row within that pass's
target, with the origin at the upper left. Its expectation is the target's value
once that pass has run. Each pass starts from its own clear colour, so two
passes that clear the same target each keep their own expectation.

## The quad

An instance's transform places the **unit square** [0, 1]² in its layer's space
(choice A). This is the contract the recorder's vertex stage must meet:

- local (0, 0) is the instance's origin, the translation of its transform; it is
  the point pixel snap rounds;
- local (1, 0) and (0, 1) are the transform's first and second columns added to
  the origin;
- texture coordinates interpolate affinely from `(u0, v0)` at local (0, 0) to
  `(u1, v1)` at local (1, 1), so `u = u0 + (u1 − u0) · x` and
  `v = v0 + (v1 − v0) · y`, with Y pointing down in texture space as everywhere.

## Placement

A world instance maps to target pixels through `render-2d`'s world transform
(`worldTransform`), and a UI instance through its UI transform (`uiTransform`);
the oracle composes the layer's transform with the instance's, exactly, in
rational arithmetic over the 32-bit coefficients. With the view's pixel snap on,
the camera's translation is already rounded inside the world transform (the UI
transform stays continuous), and the whole quad is then shifted rigidly so that
its origin lands on `snapPoint` of its mapped origin, `worldToTarget` or
`uiToTarget` of the instance's translation. A quad's size and shape never snap.

- A view draws only pixels whose centre its viewport contains
  (`viewportContains`: left and top inclusive, right and bottom exclusive).
- An empty viewport (a zero width or height) and a **singular** quad (a zero
  determinant, which is exact here) contribute nothing, and neither is a
  refusal. A reflected quad (a negative determinant) is placed and sampled like
  any other, with its texture reflected.
- A required placement that cannot be represented is a refusal, never a silent
  skip: a view whose mapping `viewMapping` cannot build as finite `Float`s, an
  instance whose snapped origin cannot be represented, or a non-singular quad any
  corner of which is beyond the finite `Float` range, since the recorder's 32-bit
  vertices could not carry it. Such a refusal applies to every probe whose centre
  is within the view's viewport. A singular quad is not that: it has no area, and
  its own transform shows it covers nothing, so it needs no mapping: a view whose
  mapping cannot be built and whose instances are all singular draws nothing and
  refuses nothing.

## Coverage

An instance covers a pixel whose centre lies inside its placed quad. A probe
whose centre lies within 1/16 pixel of the quad's edge, or of a viewport edge
that is not on a whole pixel, is **indeterminate** and reported as such, never
guessed (choice E): a rasterizer's fixed-point snapping can fall either side of
an edge that close. The distance is the Euclidean distance to the edge segments,
computed exactly, and 1/16 itself is inside the band. A viewport edge on a whole
pixel is half a pixel from every centre and so never reports.

## Sampling

- The instance's sampler resolves through the view's default filter:
  `SamplerDefault` takes `settingFilter`, the others are what they say.
- Addressing is clamp-to-edge (choice F), per axis.
- **Nearest** takes the texel containing the coordinate. Within 1/16 texel of an
  interior texel boundary the recorder's rounding picks either side, so the probe
  is indeterminate unless the texels on both sides are alike.
- **Linear** weighs the four texels around `coordinate × extent − ½`, with the
  weights computed exactly, so a coordinate at a texel's centre reads that texel
  alone.
- An sRGB texture's colour channels decode to linear light before filtering
  (`TexelRgba8Srgb`, and BC7 decoded from `TexelBc7Srgb`); alpha, and a linear
  texture, are read as they are. Colour art is premultiplied in linear light by
  the asset pipeline, so the oracle does not premultiply again. BC7 levels are
  decoded with `asset-image`'s software decoder.
- **A handle absent from the lookup** samples the placeholder, a 1×1
  transparent-black texel, whatever the sampler. A handle is compared complete,
  generation included, so two handles with one index and two generations are two
  textures. A handle the lookup returns an image for is *not* absent: an image
  that is not well formed is refused (below), never replaced by the placeholder.

### The mip level (choice C)

The level of detail is computed from the placed quad's constant texture-coordinate
derivatives, as Vulkan's `ρmax`: the larger of the lengths of the two columns of
the matrix of derivatives of the level-0 texel coordinates with respect to target
pixels, and `λ = log₂ ρmax`. The derivatives are taken exactly.

- A texture with one level, and a magnified probe (`λ ≤ 0`, exactly
  `ρmax² ≤ 1`), sample level 0.
- A minified probe is determinate when the derivatives are **axis-aligned** (no
  shear, and no rotation other than quarter turns) and `λ` is **exactly** a whole
  number, or at least the last level's index. It then samples that level, or the
  last: no sampler clamps the level of detail, and a linear sampler at a whole `λ`
  weighs the neighbouring level by zero.
- Any other minified probe on a texture with more than one level is
  indeterminate: not axis-aligned, or between two levels.

Both tests are exact, in rational arithmetic on the derivatives: `λ` is the whole
number `k` exactly when `ρmax² = 4ᵏ`, and an axis is aligned exactly when its
off-axis derivatives are zero. There is no tolerance to argue through the shading,
blending and 8-bit store that follow, and none could be: a level of detail a hair
from whole shifts a neighbouring level's weight, which brightness and the sRGB
encoding amplify, and repeated blends add the rounding of each store. A 1.9997-
pixel quad over 4 texels (`λ ≈ 1.0002`) and one of 1.99998 pixels (`λ ≈ 1.0000144`)
are both indeterminate. The consequence is that a rotation which is not exactly a
quarter turn, such as a camera turned by the 32-bit `π/2`, is not axis-aligned, so
a minified probe through it is indeterminate; a transform written with exact
coefficients, such as columns `(0, 1)` and `(−1, 0)`, is.

## Colour

With `t` the sampled texel (premultiplied, linear), `m = t` for the default
material, `c` the tint (each byte over 255) and `b` the view's brightness
(design D-24):

```
s     = m × c                     componentwise
s.rgb = s.rgb × b
s.a   = 0                         for an additive instance
s     = clamp s to [0, 1]         a fixed-point attachment clamps the source
result = s + destination × (1 − s.a)      clamped to [0, 1]
```

- **Every store is rounded, and a tie is a range.** The result of each blended
  fragment is encoded to the target's 8-bit storage before the next fragment
  reads it, decoding the colour channels on an sRGB target. Eight identical UNORM
  sources of byte 4 over transparent black give 32, not 30. Vulkan requires the
  conversion to round to nearest but does not fix the direction of a tie, and a
  device's floating-point arithmetic can fall either side of a value within a
  hair of one, so a store holds *every byte within half a step plus 1/1024 of
  the value*: usually one, two for a tie. The next blend reads that range, and
  because a blend is monotone in its destination the range carries through every
  store as its lowest and highest bytes. A channel is determinate when the bytes
  it could hold at the end span at most three (so one tolerance of 1 covers them
  all) and is reported at the middle, or, for a range of two, at the upper byte; a
  channel whose range is wider makes the probe **indeterminate**
  (`RoundingNotBounded`), never given a wider tolerance. Eight additive sources
  of exactly 2.5 channel steps are the standard case: rounding half up at every
  store would say 24, and a device may hold anything from 16 to 24.
- An sRGB target decodes the destination before blending and encodes the result
  on store; a UNORM target stores linear values; alpha is linear in every format.
  The encode and decode are the standard piecewise sRGB transfer function.
- A pass starts from its clear colour, a linear value encoded like any other.
- The result is reported in RGBA order whatever the target's channel order.
- Everything the target stores is an 8-bit channel. The pipeline is exact
  rational arithmetic; the sRGB transfer function, which is irrational, is
  evaluated in double precision and converted exactly, so no tie can come from
  its rounding.

## Order and depth

The oracle visits a pass's views in order, each view's layers in order, and each
layer's instances in the plan's drawing order (`drawingOrder` from
`planSnapshot`): the cutout-path instances first, by material and then
submission, then the ordered-path instances by depth key and then submission
(design D-2, D-22). A layer without depth, which is every UI layer and every
world layer with depth disabled, draws each instance that covers the probe, in
that order, blended.

**Retained chunks (R2D-10, D-31).** A layer that lists chunks is evaluated as
the plan orders it, from the chunks the snapshot was validated against, which
the `ValidSnapshot` carries, so the oracle looks nothing up and needs no further
input. Its drawing order is the plan's: first each listed chunk's cutout
instances, as a run in the order the layer lists them, with the path the chunk was
**built** with (routing is fixed at build, whatever marks the oracle is given:
those are the dynamic instances'), then the layer's dynamic cutouts, then the
ordered instances of the chunks and the layer merged by ascending depth key and
then source order (a chunk before any dynamic instance, listings in order, each
in build order). A chunk listed twice is drawn twice. The equal-key outcomes
below follow unchanged: among cutouts the later source wins, an ordered instance
draws over a cutout. A fragment of a chunk's instance is named by an
`AtChunkInstance` location (pass, view, layer, the chunk's position in the layer's
list, the instance's build position), where an indeterminate probe or a refusal
names the instance.

**Culling.** A view that culls a chunk (`chunkCulled`, from the view's mapping,
its viewport and the target's extent, conservatively: see `render-2d`) contributes
none of it, as the recorder does not draw it. Because the bounds enclose the
chunk's geometry, culling changes no pixel the view draws, and the suite shows
it: a layer that lists chunks gives, at every pixel, the expectation of the layer
that holds the same instances itself, in source order, whatever the camera, scale
or snap.

A **depth-enabled world layer** has the depth model of design D-2, D-23 and
D-26, evaluated per probe pixel:

1. **The clear.** When the layer begins, depth is 1.0 at every pixel the view's
   viewport contains (the pixels whose centres `viewportContains` accepts, which
   are exactly the pixels of the recorder's scissor). A later layer in the same
   view or pass starts from its own clear, so what an earlier layer wrote never
   reaches it: two depth-enabled layers' keys are independent.
2. **Depth from the key.** An instance of key *k* has depth
   `(2²⁴ − 1 − k) / 2²⁴`, exact in a 32-bit float and constant across its quad,
   so a larger key is nearer. The comparison is less-or-equal, evaluated
   exactly.
3. **Cutout runs** come first, each instance in the plan's order. The cutout
   variant (D-26) computes `s = m × c` from the sample `m` (the texel) and the
   tint `c`, whose alpha is 255 by routing. It **discards** a fragment whose
   `s.a`, before brightness, is below ½, which writes neither colour nor depth.
   A surviving fragment is tested against the depth held, and if it passes it
   writes depth and the colour `(s.rgb / s.a) × b`, un-premultiplied and then
   brightened by the view's `b`, with alpha 1 (the destination is replaced). A
   filtered edge sample `(0.6, 0.6, 0.6, 0.6)` therefore writes white, not grey.
4. **Ordered instances** follow, in the plan's order. Each is tested against the
   depth the cutouts left and, if it passes, is shaded and blended as on the
   ordered path; it writes no depth.

Both equal-key outcomes follow from the model, and are tested: among cutouts of
an equal key the later draw in run order wins, since a less-or-equal test passes
it; and at an equal key an ordered instance passes against a cutout's depth and
is drawn after it, so it is over it.

**The threshold band (choice C).** A cutout sample whose filtered alpha, before
brightness, lies within 2/255 of ½ (inclusive) is **indeterminate**
(`NearCutoutThreshold`): a device's filtering and arithmetic may fall on either
side of the threshold. For 8-bit alphas of a nearest-filtered texture that is
126 to 129. A probe is indeterminate if any cutout instance covering it has such
a sample, whether or not another instance would hide it: the oracle does not
prove a hiding it need not rely on. A cutout instance whose quad edge is within
1/16 pixel of the probe is indeterminate for the same reason as an ordered
one's (`NearQuadEdge`).

## Clips (D-11, R2D-12)

An instance whose clip index `k` is not 0 selects entry `k − 1` of its view's
clip table, as the plan resolved it (`plannedClips`, from `resolveClips`: every
entry intersected with its parent chain, in the entry's space, rounded once to
floats; see [`render-2d`](../render-2d/README.md#clip-tables)). The oracle
applies the resolved rectangle as the recorder's fragment stage does, but exactly:

1. **Membership.** The probe's pixel centre is carried back to the layer's space
   by the exact inverse of the transform the layer's instances are placed with
   (the view's `worldTransform` with its snapped translation, or `uiTransform`),
   computed over `Rational`s from the transform's 32-bit coefficients, and
   compared with the half-open rectangle `left ≤ x < right`, `top ≤ y < bottom`
   of the resolved floats, exactly. Outside it the instance **receives nothing
   from the probe**: it draws neither colour nor depth (a clipped-away cutout
   leaves the farther one visible), whatever its quad covers. The sprite's own
   origin snap is not part of the clip: it neither moves the clip nor is undone
   by it.
2. **The edge band.** The rectangle's four corners are carried forward to target
   pixels by the same transform, and a centre within 1/16 pixel, in the Euclidean
   distance and measured **in target pixels**, of any of the four segments
   between them is `NearClipEdge` (1/16 itself is inside the band, as for a
   quad's edges). The band is measured in the target's pixels, not the layer's
   units, so a UI scale of 4 or a zoom of ¼ changes how far a unit of the layer
   is from the probe, and not the band.
3. **When it counts.** The band applies to an instance that could draw at the
   probe: one that covers it, or whose quad edge lies within 1/16 pixel of it
   (`NearQuadEdge` wins when both hold). An instance clearly outside its clip is
   `Nothing`, however its quad lies, and an instance whose quad does not reach
   the probe makes no pixel indeterminate for a clip edge it does not use.
   A placement that cannot be represented stays unevaluable before any clip is
   asked.
4. **An empty clip** (the resolved `emptyClip`: a zero extent, an empty
   intersection, or a descendant of one) holds no point and has no boundary:
   the instance gives nothing at any probe, and no probe is indeterminate for
   its edge, even at the rectangle's own origin.

Clip index 0 means none: no clip is asked. The oracle plans with the same marks
as the recorder, so a clipped cutout-path instance and a clipped ordered one are
both clipped before they are shaded.

## Verdicts and exactness

An expectation is `Expected value tolerance`, `Indeterminate why` or
`Unevaluable failure`. `judge` and `judgeReadback` compare it with a pixel or a
readback: the verdict **passes when every channel is within its tolerance**, and
an indeterminate or unevaluable probe is never a pass.

**The exactness rule (choice G).** A channel's tolerance is 0 when its final
*stored* value involves no rounding, and 1 otherwise. The oracle follows each
channel through sampling, shading, blending and the store:

- a stored texel byte carried through unchanged is exact only when every step
  preserves it: the texture and the target store the colour alike (an sRGB
  texture on an sRGB target, a linear one on a UNORM target; alpha always), the
  filter reads one texel or alike texels, the tint byte is 255, the brightness is
  1, and the fragment replaces the destination (source alpha of exactly 1) or lands
  on a destination byte of 0;
- a value that is exactly 0 or 1, from a clear component of 0 or 1, a texel byte
  of 0 or 255, a product of 0, or a clamp, is exact in every format;
- a channel a fragment leaves untouched keeps its stored byte and its flag;
- anything else is within one: a tint other than 255, brightness other than 1, a
  weighted filter, a destination blended under a partial alpha, a colour space
  that differs between texture and target, a clear component other than 0 or 1,
  and **additive colour**, which is summed into the destination and rounds
  whatever its alpha, so an additive source's alpha of zero never makes its colour
  exact. Exactness is per channel, so a pixel may be exact in alpha and within one
  in colour;
- a cutout fragment's colour is the sample's colour divided by its own alpha: the
  quotient is exact only when the alpha is exactly 1 and the colour is exact, or
  when the quotient is exactly 0 or 1 (a sample whose colour equals its alpha, as
  a filtered white edge does); any other is within one. Its alpha is exactly 1.

## Indeterminate cases

Each names where: the view as `AtView pass view`, or an instance as
`AtInstance pass view layer instance`, by submission index.

| Reason | When |
| --- | --- |
| `NearViewportEdge` | The probe's centre is within 1/16 pixel of an edge of a view's non-empty viewport that is not on a whole pixel, whatever the view draws. |
| `NearQuadEdge` | The centre is within 1/16 pixel of the edge of an instance's quad, on the ordered or the cutout path. |
| `NearClipEdge` | The centre is within 1/16 pixel, in target pixels, of the boundary after transformation of the non-empty clip rectangle of an instance that could draw there. |
| `NearCutoutThreshold` | A cutout-path instance's sample has an alpha, before brightness, within 2/255 of ½ (inclusive). |
| `MinifiedNotAxisAligned` | A minified probe, on a texture with more than one level, whose derivatives are sheared or rotated by other than a quarter turn. |
| `MinifiedFractionalLevel` | A minified, axis-aligned probe whose level of detail is between two levels. |
| `NearTexelBoundary` | A nearest-filtered coordinate within 1/16 texel of an interior boundary between texels that differ. |
| `RoundingNotBounded` | After the last draw, a channel's possible stored bytes (the stores' rounding, where a value is a tie or within 1/1024 of a byte of one) span more than three, which no tolerance of 1 can cover. |

If a probe is both indeterminate and unevaluable it is unevaluable: a defect in
the inputs is what to repair first.

## Unevaluable probes

A defect in an input is a non-passing result that names it, never a guess and
never a skip. `ValidSnapshot` validates neither the lookup, the targets nor the
readback, so the oracle does:

| Failure | When |
| --- | --- |
| `PassOutOfRange` | The probe's pass is not a pass of the snapshot, including a negative index. |
| `PixelOutsideTarget` | The probe's pixel is outside its target, including a negative coordinate and any pixel of a zero-extent target. |
| `MissingTarget` | No `TargetSpec` for the pass's target. |
| `InvalidMetrics` | The metrics have a negative extent, or a content scale that is not finite and positive. |
| `ExtentDisagrees` | The pixel extent is not the metrics' framebuffer extent. |
| `TargetTooLarge` | An extent beyond 2²³ pixels, where a pixel centre is not exactly a `Float`. |
| `MappingNotRepresentable` | A view's mapping cannot be built, and an instance in it needs one. |
| `PlacementNotRepresentable` | A non-singular quad's corners, or its snapped origin, are not finite `Float`s. |
| `MalformedImage` | A texture the lookup returned that is not a well-formed image: a zero extent, no levels or more than the extent's mip chain has, a level whose byte count is not its extent's, or BC7 levels the software decoder refuses. Byte counts are checked in `Integer`, so an extent near 2³² cannot wrap. |

A malformed texture is refused only for a probe an instance covers. A readback
fault is reported by the reader:

- `readPixel format extent bytes x y`, and `readProbe` at a `Probe`'s column and
  row, return the pixel at a column and row of a tightly packed readback (level 0, rows top first, four bytes a pixel, in the
  target's own format with no conversion), swizzling `B8G8R8A8` to RGBA and
  leaving every byte as stored, an sRGB-encoded one included.
- `ReadbackSizeWrong` (the bytes needed, then supplied; compared in `Integer`),
  `ReadbackPixelOutside` and `ReadbackExtentInvalid` are faults, never pixels.

## What is shared with `render-2d`, and what is independent

**Shared** (a mistake in one is a mistake in both, so the fixtures below do not
rely on them): `ValidSnapshot` and its validation, and the chunks it carries;
`chunkCulled`; `viewMapping`, with
`worldTransform`, `uiTransform`, `worldToTarget`, `uiToTarget`, `snapPoint` and
`mappingPixelSnap`, which place the camera and snap; `viewportContains` and
`viewportIsEmpty`; and `planSnapshot` with `drawingOrder` and each run's path,
which order the instances and route the cutout path.

**Independent**: composing the instance's transform with the layer's, coverage,
the clip's membership and its distance from an edge (the inverse of the layer's
transform is taken here, over `Rational`s, not read from the mapping), derivatives, level selection, texel addressing and
filtering, the sRGB transfer function, the shading and blend equations, the
rounding of every store, the exactness rule, the verdicts and the readback
reader. These are written here, in rational arithmetic where the question is
geometric.

The suite's fixtures are independent of both: each expected value is written in
the test, as a hand-drawn picture or as bytes worked on paper from the equations
above (the camera's position at the viewport's centre, whole-number zoom spacing
in both zoom modes, a quarter-turn rotation, UI at content scale 1 and 2, pixel
snap, nearest and linear filtering across a texel boundary, sRGB against UNORM,
tint, brightness with a clamped result, additive output, premultiplied overlap in
drawing order, equal keys in submission order, a UI instance with a larger key
over one submitted later, a 2:1 minified fixture reading level 1 with each filter
and a 45° minified probe reported indeterminate, the placeholder, a BC7 texture,
the depth model — cutouts and translucent instances interleaved, both equal-key
rules, a discarded fragment leaving farther art visible, a filtered edge writing
white, a cutout reading its mip level, the threshold band at its edges, two
layers with independent keys, and a UI layer and a world layer without depth
beside a depth-enabled one — clips: an axis-aligned one, nested and three-deep
intersections with unclipped, parent-clipped and child-clipped instances in one
layer, a 45° rotated camera with and without zoom, the edge band at its
boundary and measured in target pixels under a UI scale of 4 and a zoom of ¼, the
view's snapped translation, UI at content scale 2 from a viewport origin, a
clipped-away cutout, an empty clip and its descendants, and two views with
tables of their own — retained chunks of each kind, written as pictures:
the merge order of a layer's chunks and its dynamic instances (equal keys, the
listing's order, a chunk listed twice), the later source winning a cutout tie,
an ordered chunk instance over a cutout, a chunk's routing the one it was built
with whatever marks the oracle is given, a faint cutout-marked texel discarded by a
depth chunk and blended by a world chunk without depth and a UI chunk, and a chunk
shown in one view and skipped in another — and every indeterminate case). Against synthetic readbacks written as pictures,
the suite shows the oracle **rejects** reversed overlap, a channel off by two and
a wrong snap, and accepts the exact image.

## Precision

Placement and texel addressing are exact over the snapshot's 32-bit coefficients;
the recorder places in 32-bit arithmetic. The 1/16-pixel band is what absorbs the
difference, and it does while placed coordinates stay below about 2¹⁶ pixels,
where a `Float` is still finer than 1/128 pixel; beyond that the oracle claims
only its own exact arithmetic, and a game that places quads that far from the
origin should not read a probe near an edge as determinate. The window's pixel
centres are exact `Float`s up to the 2²³-pixel extent the oracle accepts.

A clip's membership and band are exact too, over the layer's transform and the
resolved floats, wherever the view looks: the recorder's clip test is taken about
a reference point near the view, so that it is exact in the same way even for a
camera far from the origin (world coordinates near 65536 at a zoom of 100, where
an absolute single-precision coordinate is spaced most of a pixel apart), and a
determinate clip probe there is held to the oracle's answer by the native case's
`far-camera` fixture. Where the scene is beyond the floats' range altogether (a
zoom so small that a view's scissor spans more than about 10³⁸ units) the
recorder refuses the frame, and the oracle's exact answer is its own.

## Purity, owned state, threads and lifetimes

Every function is pure and total over a validated snapshot and the lookups it is
given; the same inputs always give the same expectations. The package owns **no
state**, starts **no thread**, holds no native handle, performs no IO and reads
no file, so it has no lifetime to manage and nothing to reset or dispose of. An
`Oracle` is an immutable value that holds the snapshot's plan and the lookup;
building it checks nothing eagerly, and each defect is reported by the probes it
affects. The lookup is a pure function the caller supplies; it is called as the
probes need it, and nothing is cached.

## Tests

```
cabal test --project-file cabal.project.cpu hetoimasia-render-2d-oracle:render-2d-oracle-tests --test-show-details=direct
```

The suite is the CPU validation group `test.render-2d-oracle`; it needs no GPU
and no display. Its components, selectable with `--test-options='--match <name>'`
on the suite that owns them, are `Placement`, `Sampling`, `Colour`, `Probes`,
`Depth`, `Clip`, `Chunks` and `Verdicts`.
