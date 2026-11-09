# TRA-17 evidence: the amended Q-13 verdict for the terrain material

Issue #659, epic #636. This is the measured evidence for the cell-quad, atlas-region, lit and
depth-shaded terrain material on a real device. It replaces, for the cell-quad contract, the
per-face evidence under `../tra8/`, which stays as labelled history of the old model. The rule
under test is the owner's Q-13 texel rule, amendments `owner-decision:659-q13-texel-bias-v1` to `-v4`
(2026-11-09): `i = min(w-1, floor(clamp(u,0,1)*w + 1/128))`, defined once in
`Hetoimasia.Terrain.Render2D.TexelRule` and evaluated exactly; the independent expectation restates
1/128 by hand and imports no production rule; the neutral region primitive stays unbiased.

## Verdict

**The amended Q-13 material obligations listed under "What passes" pass on the recorded device and,
for the bounded scenario, on CI's software device; the obligations under "What remains" are not proved
by this evidence.** Under the amended rule no sampling, geometry, order or ABI counterexample remains
open: every decided pixel of every non-control fixture agrees, within the declared tolerance, with the
independent hand-stated expectation, the render-2d oracle agrees with the device wherever it can decide,
and the three sampling observations found on the way (next section) are retained, each as a negative
control or a recorded band.

| | |
| --- | --- |
| Device | Apple M3 Max, Vulkan through the driver the session reports: `driverName = MoltenVK`, `driverInfo = 1.4.2` (the pinned Homebrew MoltenVK), surface-free, no window; every value is queried from the rendering session's physical device and stored in each record |
| Device limit read | `subPixelPrecisionBits = 8`, **queried from the session** (`RootsView.viewSubPixelPrecisionBits`, with `viewDriverName` and `viewDriverInfo`) and recorded per pass; a standalone `vulkaninfo` printed 4 and did not reflect the session's device |
| Depth | `Depth32Float` (an unsupported depth is a failure, never a skip) |
| Tested head | `7bc5b98c0ddf5c82d65bff91a05907c230af6f66` on a clean tree, master (`651e79e0`) already merged |
| Source digest | `381400070997224a87bcbcbf809976e68cb0a6a9b03fac44863284cb37557805` |
| Tolerance | 3 8-bit steps per channel, declared before any pixel is read (the oracle's own probe tolerance, one step, judges the oracle path) |
| Full run | `tra17-terrain`: 133 fixtures, 63.5 s scenario; opt-in, excluded from `--complete` |
| Bounded run | `tra17-terrain-ci`: 11 fixtures, 1.7 s scenario; the CI-device records and `ci-timeline.md` are those of CI's run at the same head and the same source digest |
| Atlas layout identity | `263cb64032502aa0` |

Reproduce (macOS, under the standing per-command consent; on Linux use the runner's isolated display):

```sh
bash tools/vulkan/run.sh build hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests
HETOIMASIA_NATIVE_SESSION=desktop HETOIMASIA_VALIDATION_EVIDENCE=/tmp/het-tra17-evidence \
  bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --private-roots tra17-terrain
```

Files: `full/` holds the per-fixture machine-readable results (`tra17-terrain-fixtures.json`,
`tra17-terrain-probes.json`) and a lossless PNG of every target; `bounded/` the records of the bounded
selection (the recorded device's and, as `tra17-terrain-ci-fixtures-ci-device.json`, CI's); `*-run-record.md`
and `*-transcript.txt` the runner's record and output; `ci-timeline.md` the CI timeline of the required
native groups; `reference-tint-*` the labelled comparison with the reference's multiplicative blue depth
tint (a numeric table and lossless captures). Each fixture record carries the scene, the plan identity, the
counts, the draw path, the cutout marks, the oracle's probe counts, the independent judge's counts, the
pick comparison, the shader SPIR-V hashes, the atlas files' SHA-256 and, per pass, `device_undecided_by_pass`:
device, `b`, the band delta, eligibility, undecided and covered counts, their share and the raster margin.

## The Q-13 sampling observations, retained

All three are float32 interpolation reading a different texel than the specified rule selects, measured
on the Apple M3 Max in exact `Rational` arithmetic, and each is retained.

1. **No bias** (`floor(clamp u 0 1 * w)`). In `exact-boundary-{0,5,15,9}-<facing>-beside-ordinary` (one cell,
   zoom 1/2, no pan, an even target, every pixel centre exactly on a texel boundary) the device selects the
   lower texel at 106, 94, 92 and 95 of 4800, 4462, 4416 and 4508 covered pixels. Control:
   `...-control-unbiased-index` (`terrainMaterialUnbiasedControl`). Amendment v1 chose a 1/10000 bias.
2. **1/10000.** The exact-boundary fixtures pass, but at pixel-snapped zooms 9/8 and 5/4 (`snapped-9-8`,
   `snapped-5-4`) the device still selects the lower texel at 12 and 15 of about 6100 pixels, every one on
   an exact texel boundary or within 2e-6 texel of it (the largest gap above the biased threshold the device
   still crossed: 1.019e-4 texel). Control: `...-control-stale-bias-1e-4` (`terrainMaterialStaleBiasControl`).
   Amendment v2 chose 1/128.
3. **Unsnapped fractional scale, 1/128.** In the unsnapped sequence pass `atZoom 0.1875 (rampsCorners
   FaceSouth)` (zoom 3/16, target 60x54, pan (0.17146666666666666, 0.18926666666666667)) 113 pixels lying
   1.2436e-3 texel BELOW an interior biased threshold read the higher texel: just outside the 1/1000 band
   amendment v2 had allowed. It is consistent with the rasterizer's vertex quantisation: a vertex off the
   `2^-b` pixel grid moves the interpolated coordinate by at most `2^-(b+1)/s` texels. Amendment v3 (and its
   correction v4, b = 8 on the session's device) set the band for unsnapped fractional fixtures to
   `delta = 2^-(b+1)/s + 1/1000` texel; at b = 8 and s = 3/16 that is 0.0114, which covers the observation.

With 1/128 every fixture passes with 0 mismatches and the two controls are rejected (tables below).

## How a pixel is judged

Twice, independently. The render-2d oracle is given the material's pure model (`terrainModel`, which samples
at the exact biased index) and the same snapshot; it decides what it can and lists the rest as indeterminate
with its reason. The independent expectation (`Hetoimasia.Terrain.Render2D.Evidence`) reads nothing from the
planner, its keys, the picker, the atlas adaptation, the material or the oracle: by hand it states the
canvas corner of every quad, the painter order, the texel under the pixel centre by the amended rule in exact
`Rational` arithmetic (1/128 restated, no production import), the opaque test of the independently decoded
colour and map images, the lit, darkened and hazed colour by the specified equations and the sRGB encoding.
**Every pixel has an exact expectation.** The pure picker is compared with it at every pixel, banded or not.

**The device band** (amendment v3, v4). A pixel is undecided for the DEVICE READ-BACK only if all of: the
pass is UNSNAPPED and at least one quad vertex is off the `2^-b` pixel grid (so the rasterizer's vertex
quantisation applies; snapped passes put every vertex on a whole pixel, and the exact-boundary and edge
fixtures have whole or half-pixel corners, so they stay fully decided); the exact sample is within
`delta = 2^-(b+1)/s + 1/1000` texel of an INTERIOR threshold `n - 1/128` (`n = 1 .. extent - 1`; never a
canvas edge); and the texels selectable by samples within that band differ in coverage or in colour beyond the
tolerance (3 for the independent judge; one step for the oracle path, whose probe tolerance is one). `b` is
the device's queried `subPixelPrecisionBits`, `s` the PASS's view scale in pixels per texel. The oracle path is
banded identically (a banded pixel's probe is `NearTexelBoundary`, counted, never compared); an oracle
mismatch outside the band stands as a failure. Per pass the record carries the device, `b`, delta, eligibility,
undecided count, covered count and share. **Raster ownership is never banded**: for every eligible pass the
judge checks that no quad edge lies within `epsilon = 2^-(b+1) + s/1000` pixels of a pixel centre (so no
vertex movement can change which side of an edge a centre falls on) and records the margin; every eligible
pass passes by at least 0.07 pixel, so no fixture needed a nudge. The shared diagonal of a quad's two triangles
needs no margin: a pixel centre on it is covered by exactly one of the two triangles, so the quad's coverage and
colour do not change.

Undecided pixels in the full run occur in two unsnapped fractional fixtures only, `sequence-zoom` (618 of 6418
covered, 9.6 %) and `fractional@0.1875` (136 of 844, 16.1 %); every other fixture has none. The device band exempts DEVICE read-back only: the pure picker and the pure material model are compared with the exact
expectation at every pixel of these fixtures, banded or not (`Expectation`, `ModelAtBand`). On CI's device
(`llvmpipe (LLVM 20.1.2, 256 bits)`, which also reports `b = 8`) the bounded scenario has none.

## What passes

- **Region sampling and atlas packing on the device**: the 16 identities in 4 facings and the bounded matrix, every
  colour and map region read at its own nonzero origin in a 288 x 64 colour atlas and a 768 x 384 normal atlas of
  unequal extent, with transparent padding and adjacent regions of different art, at zoom 0.25 and at native scale.
- **Exact texel-boundary, edge, diagonal and minified-endpoint ownership**: four shapes in three facings with every
  pixel centre exactly on a texel boundary (zoom 1/2); `edges-*` fixtures with pixel centres exactly on a quad's left
  and top edge, one pixel beyond its right and bottom edge and on the shared diagonal, at zoom 1/8 (the minified
  endpoint), 1/2 and 1; and the snapped scene at zoom 1/8, 9/8, 5/4, 63/8 and 8, all exact with every pixel decided.
  Snapping is discriminated at 1/8, 9/8, 5/4 and 63/8 (100, 967, 1194 and 128 pixels differ from the unsnapped
  draw); at the whole scale 8 it cannot be: every texel and quad edge is the origin plus whole pixels, so rounding
  the origin by less than half a pixel moves no pixel centre across an edge except at an exact tie, which depends
  on the rounding rule, and that fixture is judged exactly without the discrimination need.
- **The shape x facing x role matrix**: the 16 identities, the 15 mixed known/fog maps and the full-fog map in every facing, drawn from the packed atlases AND from the 49 single images, each pass non-vacuous with its picks.
- **Ordinary, full-fog and mixed known/fog parts**, hidden air against hidden solid indistinguishable as fog, known
  ramp sides beside unknown void, **pending information** ahead of and behind known terrain (picks: loading where a
  pending cell could lie in front, a hit where it is proved behind; the one-pixel conservative ring around a nearer
  pending canvas is undecided by the picker contract and counted per fixture, every pixel outside it decided), and
  **transparent colour holes** independent of the maps' holes.
- **Overlap and depth, seams and extremes**: roofs over a cavity, disconnected spans, ramps and corners, cutaways, the
  automatic follow and a floor 34 levels below the cut; seams across the 16 x 16 x 32 region lattice and across zero;
  legal-coordinate extremes (maximum and minimum, levels included); real depth testing and discard.
- **Supplied sequences**: pan, zoom, rotation, manual/follow/manual and jump with and without Z (each restoring its
  first picture pixel for pixel), reveal (knowledge arriving) and unload/reload.
- **Views**: the zoom endpoints (1/8 and 8), a fractional camera, a viewport away from the corner, a target of content
  scale 2, pixel snapping at the scales above.
- **Lighting and depth effects**: the default light with the camera turned, the sun varied at a fixed camera, sun only,
  ambient only, illumination off, the horizon, a west sun at 10 degrees; a stack of nine levels at the default numbers
  and at a range of 4 with neither effect, darkening only, haze only, both, black terrain under haze, haze with no
  illumination. The labelled comparison with the reference's multiplicative blue tint is in `reference-tint-*`
  (`reference-tint-sheet.png` side by side, the two images, the table and the sources); no Synarchy parity is claimed.
- **Submission and retention**: the same plan in plan order, scrambled, split between two materials of identical
  behaviour, between retained chunks and the dynamic layer, through the ordered wrapper; and the
  `*-released-while-pending` fixtures, which mark the atlases' original ownership released between the frame's
  submission and its completion (retained chunks included): the frame completes and reads back correct.
- **Negative controls**, each a draw or a pick broken once and rejected by the same judge, each differing at its named
  probes: reversed depth order, the whole-cell mask, the wrong facing's sun, the depth effects reset, the depth effects composed in the wrong order (haze first, then darkening; on the short-range depth stack where both are strong), swapped colour
  region origins, whole-atlas clamping, the normal atlas bound as colour, half-texel-inset interpolation, the texel
  rule with no bias, with the superseded 1/10000 bias, a pick through the farthest covered quad, a pick through fog, a
  pick that answers loading as a miss, the wrong (next) map region, and colour holes ignored.
- **CPU**: the `test.terrain-render-2d`, `test.asset-image` and device-free `test.vulkan-headless` suites, the generator's
  `--check` and `--check-atlases`, the picker against the independent model at every pixel over every scene (including
  edges, seams, extremes, pending and holes), and the checked material declaration against the compiled shader interfaces.

## What remains (stated, not hidden)

- **UNEXERCISED on the device**: packed against single-image atlases on the GPU beyond the 49-image style that
  draws and picks as the packed one does; a streamed or live background (#645); the terrain adapter allocates no texture, so
  the lifetime of its parents is shown through #672's real pipeline instead of on the device: the lua-engine-graphics
  headless rig (`Test.LuaEngine.Graphics.TerrainParents`: original lease released while a batch still reads the parents,
  an adaptation built over the delivered handles, pressure with nothing partial) and the real byte banks
  (`Test.LuaEngine.Texture.TerrainParents`); the adapter's own all-or-none, one-charge-per-parent and
  unadmitted-parent refusals are CPU tests.
- **Reference lighting**: Synarchy's lighting (`ShaderCode.hs` at `3777d437`, lines 255-301) is not reproduced and no
  parity is claimed.
- Live view ownership, streaming and retirement (#645), the Lua bindings (#646), the arena and its shortcuts (#647) and
  final integrated visual acceptance (#648) are outside this issue.

## Fixtures: the bounded selection (recorded device)

| fixture | verdict | covered | mismatches | undecided (v3 band) | share of covered | eligible | delta (texels) | pick mismatches/compared | control |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- | ---: | --- |
| matrix-FaceSouth-0.25 | pass | 2754 | 0 | 0 | 0.0% | yes | 0.0088 | 0/10560 |  |
| mixed-FaceSouth@0.25 | pass | 1166 | 0 | 0 | 0.0% | yes | 0.0088 | 0/660 |  |
| mixed-FaceSouth@0.25-single-images | pass | 1166 | 0 | 0 | 0.0% | yes | 0.0088 | 0/660 |  |
| roof-cut1-FaceWest@0.125 | pass | 468 | 0 | 0 | 0.0% | yes | 0.0166 | 0/1176 |  |
| roof-cut1-FaceWest@0.125-scrambled | pass | 468 | 0 | 0 | 0.0% | yes | 0.0166 | 0/1176 |  |
| roof-cut1-FaceWest@0.125-two-materials | pass | 468 | 0 | 0 | 0.0% | yes | 0.0166 | 0/1176 |  |
| roof-cut1-FaceWest@0.125-retained | pass | 468 | 0 | 0 | 0.0% | yes | 0.0166 | 0/1176 |  |
| roof-cut1-FaceWest@0.125-ordered-wrapper | pass | 468 | 0 | 0 | 0.0% | yes | 0.0166 | 0/1176 |  |
| ramps-FaceEast@0.125 | pass | 435 | 0 | 0 | 0.0% | yes | 0.0166 | 0/702 |  |
| depth-stack-FaceSouth@0.25@black-under-haze | pass | 1093 | 0 | 0 | 0.0% | yes | 0.0088 | 0/684 |  |
| spans-FaceSouth@0.125-control-reversed-overlap | pass | 420 | 235 | 0 | 0.0% | yes | 0.0166 | 0/1008 | rejected |

## Fixtures: the complete qualification

| fixture | verdict | covered | mismatches | undecided (v3 band) | share of covered | eligible | delta (texels) | pick mismatches/compared | control |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- | ---: | --- |
| matrix-FaceSouth-0.25 | pass | 2754 | 0 | 0 | 0.0% | yes | 0.0088 | 0/10560 |  |
| matrix-FaceWest-0.25 | pass | 2718 | 0 | 0 | 0.0% | yes | 0.0088 | 0/10560 |  |
| matrix-FaceNorth-0.25 | pass | 2718 | 0 | 0 | 0.0% | yes | 0.0088 | 0/10560 |  |
| matrix-FaceEast-0.25 | pass | 2754 | 0 | 0 | 0.0% | yes | 0.0088 | 0/10560 |  |
| native-scale-FaceSouth-1 | pass | 6336 | 0 | 0 | 0.0% | yes | 0.003 | 0/1300 |  |
| mixed-FaceSouth@0.25 | pass | 1166 | 0 | 0 | 0.0% | yes | 0.0088 | 0/660 |  |
| mixed-FaceWest@0.25 | pass | 1128 | 0 | 0 | 0.0% | yes | 0.0088 | 0/660 |  |
| mixed-FaceNorth@0.25 | pass | 1206 | 0 | 0 | 0.0% | yes | 0.0088 | 0/660 |  |
| mixed-FaceEast@0.25 | pass | 1170 | 0 | 0 | 0.0% | yes | 0.0088 | 0/660 |  |
| matrix-FaceSouth-0.25-single-images | pass | 2754 | 0 | 0 | 0.0% | yes | 0.0088 | 0/10560 |  |
| matrix-FaceWest-0.25-single-images | pass | 2718 | 0 | 0 | 0.0% | yes | 0.0088 | 0/10560 |  |
| matrix-FaceNorth-0.25-single-images | pass | 2718 | 0 | 0 | 0.0% | yes | 0.0088 | 0/10560 |  |
| matrix-FaceEast-0.25-single-images | pass | 2754 | 0 | 0 | 0.0% | yes | 0.0088 | 0/10560 |  |
| mixed-FaceSouth@0.25-single-images | pass | 1166 | 0 | 0 | 0.0% | yes | 0.0088 | 0/660 |  |
| mixed-FaceWest@0.25-single-images | pass | 1128 | 0 | 0 | 0.0% | yes | 0.0088 | 0/660 |  |
| mixed-FaceNorth@0.25-single-images | pass | 1206 | 0 | 0 | 0.0% | yes | 0.0088 | 0/660 |  |
| mixed-FaceEast@0.25-single-images | pass | 1170 | 0 | 0 | 0.0% | yes | 0.0088 | 0/660 |  |
| roof-cut2-FaceSouth@0.125 | pass | 540 | 0 | 0 | 0.0% | yes | 0.0166 | 0/630 |  |
| roof-cut1-FaceSouth@0.125 | pass | 468 | 0 | 0 | 0.0% | yes | 0.0166 | 0/1176 |  |
| roof-cut1-FaceWest@0.125 | pass | 468 | 0 | 0 | 0.0% | yes | 0.0166 | 0/1176 |  |
| roof-cut1-FaceWest@0.125-scrambled | pass | 468 | 0 | 0 | 0.0% | yes | 0.0166 | 0/1176 |  |
| roof-cut1-FaceWest@0.125-two-materials | pass | 468 | 0 | 0 | 0.0% | yes | 0.0166 | 0/1176 |  |
| roof-cut1-FaceWest@0.125-retained | pass | 468 | 0 | 0 | 0.0% | yes | 0.0166 | 0/1176 |  |
| roof-cut1-FaceWest@0.125-ordered-wrapper | pass | 468 | 0 | 0 | 0.0% | yes | 0.0166 | 0/1176 |  |
| spans-FaceNorth@0.125 | pass | 318 | 0 | 0 | 0.0% | yes | 0.0166 | 0/768 |  |
| ramps-FaceEast@0.125 | pass | 435 | 0 | 0 | 0.0% | yes | 0.0166 | 0/702 |  |
| stairs-cut1-FaceSouth@0.125 | pass | 362 | 0 | 0 | 0.0% | yes | 0.0166 | 0/720 |  |
| stairs-cut3-FaceSouth@0.125 | pass | 450 | 0 | 0 | 0.0% | yes | 0.0166 | 0/720 |  |
| stairs-cut5-FaceSouth@0.125 | pass | 490 | 0 | 0 | 0.0% | yes | 0.0166 | 0/720 |  |
| exact-boundary-0-FaceSouth-beside-ordinary | pass | 4800 | 0 | 0 | 0.0% | yes | 0.003 | 0/1265 |  |
| exact-boundary-5-FaceSouth-beside-ordinary | pass | 4462 | 0 | 0 | 0.0% | yes | 0.003 | 0/1265 |  |
| exact-boundary-15-FaceWest-beside-ordinary | pass | 4416 | 0 | 0 | 0.0% | yes | 0.003 | 0/1265 |  |
| exact-boundary-9-FaceEast-beside-ordinary | pass | 4508 | 0 | 0 | 0.0% | yes | 0.003 | 0/1265 |  |
| edges-0-FaceSouth@0.125-beside-ordinary | pass | 3900 | 0 | 0 | 0.0% | yes | 0.003 | 0/1375 |  |
| edges-15-FaceEast@0.125-beside-ordinary | pass | 3876 | 0 | 0 | 0.0% | yes | 0.003 | 0/1375 |  |
| edges-0-FaceSouth@0.5-beside-ordinary | pass | 4800 | 0 | 0 | 0.0% | yes | 0.003 | 0/1287 |  |
| edges-9-FaceWest@0.5-beside-ordinary | pass | 4508 | 0 | 0 | 0.0% | yes | 0.003 | 0/1287 |  |
| edges-0-FaceSouth@1.0-beside-ordinary | pass | 7680 | 0 | 0 | 0.0% | yes | 0.003 | 0/1261 |  |
| edges-5-FaceNorth@1.0-beside-ordinary | pass | 6336 | 0 | 0 | 0.0% | yes | 0.003 | 0/1261 |  |
| seams-FaceSouth | pass | 24000 | 0 | 0 | 0.0% | yes | 0.003 | 0/605 |  |
| seams-FaceWest | pass | 30720 | 0 | 0 | 0.0% | yes | 0.003 | 0/605 |  |
| seams-FaceNorth | pass | 23776 | 0 | 0 | 0.0% | yes | 0.003 | 0/605 |  |
| seams-FaceEast | pass | 31712 | 0 | 0 | 0.0% | yes | 0.003 | 0/605 |  |
| seams-zero-FaceSouth | pass | 18112 | 0 | 0 | 0.0% | yes | 0.003 | 0/609 |  |
| seams-zero-FaceNorth | pass | 18144 | 0 | 0 | 0.0% | yes | 0.003 | 0/605 |  |
| extremes-max-FaceSouth | pass | 18880 | 0 | 0 | 0.0% | yes | 0.003 | 0/606 |  |
| extremes-max-FaceEast | pass | 20128 | 0 | 0 | 0.0% | yes | 0.003 | 0/602 |  |
| extremes-min-FaceSouth | pass | 18880 | 0 | 0 | 0.0% | yes | 0.003 | 0/606 |  |
| extremes-min-FaceEast | pass | 20128 | 0 | 0 | 0.0% | yes | 0.003 | 0/602 |  |
| pending-FaceSouth | pass | 8640 | 0 | 0 | 0.0% | yes | 0.003 | 0/597 |  |
| pending-FaceWest | pass | 9024 | 0 | 0 | 0.0% | yes | 0.003 | 0/594 |  |
| pending-FaceNorth | pass | 9408 | 0 | 0 | 0.0% | yes | 0.003 | 0/601 |  |
| pending-FaceEast | pass | 9024 | 0 | 0 | 0.0% | yes | 0.003 | 0/593 |  |
| shape-5-FaceSouth@1.0-colour-holes | pass | 1680 | 0 | 0 | 0.0% | yes | 0.003 | 0/650 |  |
| shape-9-FaceWest@1.0-colour-holes | pass | 1776 | 0 | 0 | 0.0% | yes | 0.003 | 0/650 |  |
| shape-0-FaceEast@1.0-colour-holes | pass | 2528 | 0 | 0 | 0.0% | yes | 0.003 | 0/650 |  |
| matrix-FaceSouth-0.25-colour-holes | pass | 1818 | 0 | 0 | 0.0% | yes | 0.0088 | 0/10560 |  |
| ramps-FaceSouth@0.125-colour-holes | pass | 317 | 0 | 0 | 0.0% | yes | 0.0166 | 0/798 |  |
| mixed-FaceSouth@0.25-colour-holes | pass | 1076 | 0 | 0 | 0.0% | yes | 0.0088 | 0/660 |  |
| matrix-mixed-FaceSouth-0.25 | pass | 3600 | 0 | 0 | 0.0% | yes | 0.0088 | 0/9900 |  |
| matrix-mixed-FaceSouth-0.25-single-images | pass | 3600 | 0 | 0 | 0.0% | yes | 0.0088 | 0/9900 |  |
| matrix-mixed-FaceWest-0.25 | pass | 3600 | 0 | 0 | 0.0% | yes | 0.0088 | 0/9900 |  |
| matrix-mixed-FaceWest-0.25-single-images | pass | 3600 | 0 | 0 | 0.0% | yes | 0.0088 | 0/9900 |  |
| matrix-mixed-FaceNorth-0.25 | pass | 3600 | 0 | 0 | 0.0% | yes | 0.0088 | 0/9900 |  |
| matrix-mixed-FaceNorth-0.25-single-images | pass | 3600 | 0 | 0 | 0.0% | yes | 0.0088 | 0/9900 |  |
| matrix-mixed-FaceEast-0.25 | pass | 3600 | 0 | 0 | 0.0% | yes | 0.0088 | 0/9900 |  |
| matrix-mixed-FaceEast-0.25-single-images | pass | 3600 | 0 | 0 | 0.0% | yes | 0.0088 | 0/9900 |  |
| matrix-fog-FaceSouth-0.25 | pass | 3840 | 0 | 0 | 0.0% | yes | 0.0088 | 0/628 |  |
| matrix-fog-FaceSouth-0.25-single-images | pass | 3840 | 0 | 0 | 0.0% | yes | 0.0088 | 0/628 |  |
| matrix-fog-FaceWest-0.25 | pass | 3648 | 0 | 0 | 0.0% | yes | 0.0088 | 0/609 |  |
| matrix-fog-FaceWest-0.25-single-images | pass | 3648 | 0 | 0 | 0.0% | yes | 0.0088 | 0/609 |  |
| matrix-fog-FaceNorth-0.25 | pass | 3840 | 0 | 0 | 0.0% | yes | 0.0088 | 0/628 |  |
| matrix-fog-FaceNorth-0.25-single-images | pass | 3840 | 0 | 0 | 0.0% | yes | 0.0088 | 0/628 |  |
| matrix-fog-FaceEast-0.25 | pass | 3648 | 0 | 0 | 0.0% | yes | 0.0088 | 0/609 |  |
| matrix-fog-FaceEast-0.25-single-images | pass | 3648 | 0 | 0 | 0.0% | yes | 0.0088 | 0/609 |  |
| sequence-pan | pass | 1711 | 0 | 0 | 0.0% | yes | 0.0166 | 0/3192 |  |
| sequence-zoom | pass | 6418 | 0 | 618 | 9.6% | yes | 0.0062..0.0166 | 0/3252 |  |
| sequence-rotation | pass | 1684 | 0 | 0 | 0.0% | yes | 0.0166 | 0/2874 |  |
| sequence-manual-follow-manual | pass | 1287 | 0 | 0 | 0.0% | yes | 0.0166 | 0/2394 |  |
| sequence-jump | pass | 1688 | 0 | 0 | 0.0% | yes | 0.0166 | 0/3192 |  |
| sequence-reveal | pass | 2939 | 0 | 0 | 0.0% | yes | 0.0088 | 0/1980 |  |
| sequence-unload-reload | pass | 900 | 0 | 0 | 0.0% | yes | 0.0166 | 0/2394 |  |
| follow-FaceSouth@0.125 | pass | 1854 | 0 | 0 | 0.0% | yes | 0.0166 | 0/638 |  |
| deep-FaceSouth | pass | 1140 | 0 | 0 | 0.0% | yes | 0.0166 | 0/637 |  |
| zoom-0.125 | pass | 409 | 0 | 0 | 0.0% | yes | 0.0166 | 0/798 |  |
| zoom-8.0 | pass | 6144 | 0 | 0 | 0.0% | yes | 0.0012 | 0/615 |  |
| fractional@0.1875 | pass | 844 | 0 | 136 | 16.1% | yes | 0.0114 | 0/797 |  |
| viewport@0.125 | pass | 350 | 0 | 0 | 0.0% | yes | 0.0166 | 0/672 |  |
| scaled@0.125 | pass | 435 | 0 | 0 | 0.0% | yes | 0.0166 | 0/624 |  |
| snapped | pass | 6044 | 0 | 0 | 0.0% | no | - | 0/615 |  |
| snapped-1-8 | pass | 412 | 0 | 0 | 0.0% | no | - | 0/615 |  |
| snapped-9-8 | pass | 6123 | 0 | 0 | 0.0% | no | - | 0/615 |  |
| snapped-5-4 | pass | 6144 | 0 | 0 | 0.0% | no | - | 0/615 |  |
| snapped-63-8 | pass | 6144 | 0 | 0 | 0.0% | no | - | 0/615 |  |
| snapped-8 | pass | 6144 | 0 | 0 | 0.0% | no | - | 0/615 |  |
| ramps-FaceSouth@0.125 | pass | 429 | 0 | 0 | 0.0% | yes | 0.0166 | 0/798 |  |
| ramps-FaceWest@0.125 | pass | 429 | 0 | 0 | 0.0% | yes | 0.0166 | 0/702 |  |
| ramps-FaceSouth@0.125@sun-only | pass | 429 | 0 | 0 | 0.0% | yes | 0.0166 | 0/798 |  |
| ramps-FaceSouth@0.125@ambient-only | pass | 429 | 0 | 0 | 0.0% | yes | 0.0166 | 0/798 |  |
| ramps-FaceSouth@0.125@horizon | pass | 429 | 0 | 0 | 0.0% | yes | 0.0166 | 0/798 |  |
| ramps-FaceSouth@0.125@below-horizon | pass | 429 | 0 | 0 | 0.0% | yes | 0.0166 | 0/798 |  |
| ramps-FaceSouth@0.125@west-low | pass | 429 | 0 | 0 | 0.0% | yes | 0.0166 | 0/798 |  |
| ramps-FaceSouth@0.125@north-high | pass | 429 | 0 | 0 | 0.0% | yes | 0.0166 | 0/798 |  |
| ramps-FaceSouth@0.125@dark-beside-default | pass | 858 | 0 | 0 | 0.0% | yes | 0.0166 | 0/1596 |  |
| depth-stack-FaceSouth@0.25@neither-effect | pass | 1093 | 0 | 0 | 0.0% | yes | 0.0088 | 0/684 |  |
| depth-stack-FaceSouth@0.25@darkening-only | pass | 1093 | 0 | 0 | 0.0% | yes | 0.0088 | 0/684 |  |
| depth-stack-FaceSouth@0.25@haze-only | pass | 1093 | 0 | 0 | 0.0% | yes | 0.0088 | 0/684 |  |
| depth-stack-FaceSouth@0.25@both-short-range | pass | 1093 | 0 | 0 | 0.0% | yes | 0.0088 | 0/684 |  |
| depth-stack-FaceSouth@0.25@black-under-haze | pass | 1093 | 0 | 0 | 0.0% | yes | 0.0088 | 0/684 |  |
| depth-stack-FaceSouth@0.25@haze-no-light-beside-default | pass | 2186 | 0 | 0 | 0.0% | yes | 0.0088 | 0/1368 |  |
| depth-stack-FaceNorth@0.25@black-under-haze | pass | 1395 | 0 | 0 | 0.0% | yes | 0.0088 | 0/612 |  |
| spans-FaceSouth@0.125-control-reversed-overlap | pass | 420 | 235 | 0 | 0.0% | yes | 0.0166 | 0/1008 | rejected |
| ramps-FaceSouth@0.125-control-whole-cell-mask | pass | 429 | 389 | 0 | 0.0% | yes | 0.0166 | 0/798 | rejected |
| ramps-FaceWest@0.125-control-wrong-facing-light | pass | 429 | 239 | 0 | 0.0% | yes | 0.0166 | 0/702 | rejected |
| depth-stack-FaceSouth@0.25@neither-effect-haze-control-depth-reset | pass | 1093 | 934 | 0 | 0.0% | yes | 0.0088 | 0/684 | rejected |
| depth-stack-FaceSouth@0.25@both-short-range-control-wrong-composition-order | pass | 1093 | 820 | 0 | 0.0% | yes | 0.0088 | 0/684 | rejected |
| matrix-FaceSouth-1.0@0.25-control-swapped-region-origins | pass | 2754 | 2754 | 0 | 0.0% | yes | 0.0088 | 0/619 | rejected |
| ramps-FaceSouth@0.125-control-whole-atlas-clamping | pass | 429 | 424 | 0 | 0.0% | yes | 0.0166 | 0/798 | rejected |
| ramps-FaceSouth@0.125-control-normal-as-colour | pass | 429 | 243 | 0 | 0.0% | yes | 0.0166 | 0/798 | rejected |
| ramps-FaceSouth@0.125-control-half-texel-inset | pass | 429 | 18 | 0 | 0.0% | yes | 0.0166 | 0/798 | rejected |
| ramps-FaceSouth@0.125-control-wrong-map-region | pass | 429 | 210 | 0 | 0.0% | yes | 0.0166 | 0/798 | rejected |
| fog-over-known-FaceSouth@0.25-control-pick-through-fog | pass | 512 | 0 | 0 | 0.0% | yes | 0.0088 | 192/1020 | rejected |
| spans-FaceSouth@0.125-control-pick-through-nearer | pass | 420 | 0 | 0 | 0.0% | yes | 0.0166 | 268/1008 | rejected |
| pending-FaceSouth-control-loading-as-miss | pass | 8640 | 0 | 0 | 0.0% | yes | 0.003 | 124/597 | rejected |
| shape-5-FaceSouth@1.0-control-colour-holes-ignored | pass | 1680 | 816 | 0 | 0.0% | yes | 0.003 | 75/650 | rejected |
| exact-boundary-0-FaceSouth-beside-ordinary-control-unbiased-index | pass | 4800 | 106 | 0 | 0.0% | yes | 0.003 | 0/1265 | rejected |
| exact-boundary-5-FaceSouth-beside-ordinary-control-unbiased-index | pass | 4462 | 94 | 0 | 0.0% | yes | 0.003 | 0/1265 | rejected |
| exact-boundary-15-FaceWest-beside-ordinary-control-unbiased-index | pass | 4416 | 92 | 0 | 0.0% | yes | 0.003 | 0/1265 | rejected |
| exact-boundary-9-FaceEast-beside-ordinary-control-unbiased-index | pass | 4508 | 95 | 0 | 0.0% | yes | 0.003 | 0/1265 | rejected |
| snapped-9-8-beside-ordinary-control-stale-bias-1e-4 | pass | 9963 | 12 | 0 | 0.0% | yes | 0.003 | 0/1265 | rejected |
| snapped-5-4-beside-ordinary-control-stale-bias-1e-4 | pass | 9984 | 15 | 0 | 0.0% | yes | 0.003 | 0/1265 | rejected |
| roof-cut1-FaceWest@0.125-retained-released-while-pending | pass | 468 | 0 | 0 | 0.0% | yes | 0.0166 | 0/1176 |  |
| mixed-FaceSouth@0.25-released-while-pending | pass | 1166 | 0 | 0 | 0.0% | yes | 0.0088 | 0/660 |  |
