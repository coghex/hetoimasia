# TRA-17 evidence: the amended Q-13 verdict for the terrain material

Issue #659, epic #636. This is the measured evidence for the cell-quad, atlas-region,
lit and depth-shaded terrain material on a real device. It replaces, for the
cell-quad contract, the per-face evidence under `../tra8/`, which stays as labelled
history of the old model (revision-pinned, never current behaviour). The texel rule
under test is the owner's Q-13 amendment v2 (`owner-decision:659-q13-texel-bias-v2`,
2026-11-09): `i = min(w-1, floor(clamp(u,0,1)*w + 1/128))`, defined once as `texelBias`.

## Verdict

**The amended Q-13 material obligations listed under "What passes" pass on the
device below; the obligations under "What remains" are not proved by this evidence.**
Under the amended rule no sampling, geometry, order or ABI counterexample remains:
every decided pixel of every non-control fixture agrees, within the declared
tolerance, with an independent hand-stated expectation, the render-2d oracle agrees
with the device wherever it can decide, and the two sampling counterexamples found
on the way (below) are retained as negative controls that this judge rejects.

| | |
| --- | --- |
| Device | Apple M3 Max (Vulkan through MoltenVK on macOS), surface-free, no window |
| Depth | `Depth32Float` (an unsupported depth is a failure, never a skip) |
| Tested head | `f9ba49ca6d0f93a7cf645cc9ab5a6b2ca8f17e0f` on a clean tree, master already merged |
| Source digest | `37b2de435d1fd9a80a71ac74ecd09c15b9a77389c27e1d1510d46ab1ad4c37ff` |
| Tolerance | 3 8-bit steps per channel, declared before any pixel is read (sRGB round trip, one linear rounding, 32-bit against 64-bit arithmetic) |
| Full run | `tra17-terrain`: 76 fixtures, 10.6 s of fixtures, 11.1 s scenario |
| Bounded run | `tra17-terrain-ci`: 11 fixtures, 0.8 s of fixtures, 1.3 s scenario |
| Atlas layout identity | `263cb64032502aa0` |

Reproduce (macOS, under the standing per-command consent; on Linux use the runner's
isolated display):

```sh
bash tools/vulkan/run.sh build hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests
HETOIMASIA_NATIVE_SESSION=desktop HETOIMASIA_VALIDATION_EVIDENCE=/tmp/het-tra17-evidence \
  bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --private-roots tra17-terrain
```

Files: `full/` holds the per-fixture machine-readable results
(`tra17-terrain-fixtures.json`, `tra17-terrain-probes.json`) and a lossless PNG of
every target; `bounded/` the same records for the bounded selection (no images);
`*-run-record.md` and `*-transcript.txt` the runner's record and output.
`reference-tint-comparison.md` is the labelled comparison with the reference's
multiplicative blue depth tint. Each fixture record carries the scene (cells,
camera, zoom, facing, knowledge), the plan identity, the quad and record counts, the
draw path, the cutout marks, the oracle's probe counts, the independent judge's
compared, ambiguous, covered, reveal and overlap counts and mismatches, the pick
comparison, the shader SPIR-V hashes and the atlas files' SHA-256 and layout identity.

## The Q-13 sampling counterexamples, retained

Both are float32 interpolation reading the lower texel where the specified rule selects
the higher one, measured on the Apple M3 Max, judged in exact `Rational` arithmetic
with no undecided band, and each is kept as a negative control (a material that draws
with the broken rule, which the same judge must reject).

1. **No bias** (the rule `floor(clamp u 0 1 * w)`). In `exact-boundary-{0,5,15,9}-<facing>-beside-ordinary`
   (one cell, zoom 1/2, no pan, an even target, so every pixel centre lies exactly on a
   texel boundary) the device selects the lower texel at 106, 94, 92 and 95 of 4800, 4462,
   4416 and 4508 covered pixels (about 2 %). Control: `...-control-unbiased-index`
   (`terrainMaterialUnbiasedControl`). Owner amendment v1 chose a 1/10000 texel bias.
2. **1/10000** (amendment v1). With that bias the exact-boundary fixtures pass, but at
   pixel-snapped zooms 9/8 and 5/4 (`snapped-9-8`, `snapped-5-4`: the ramps-and-corners
   scene, a 96 x 64 target, snapping on) the device still selects the lower texel at 12
   and 15 of about 6100 pixels, every one on an exact texel boundary or within 2e-6 texel
   of it (largest gap above the biased threshold the device still crossed: 1.019e-4
   texel; the smallest it did not cross: 9.8e-5). Control: `...-control-stale-bias-1e-4`
   (`terrainMaterialStaleBiasControl`). Amendment v2 chose 1/128.

With 1/128 every one of these fixtures passes with 0 mismatches and the two controls
are rejected (table below).

| fixture | rule | covered | mismatches |
| --- | --- | ---: | ---: |
| exact-boundary-0-FaceSouth-beside-ordinary | 1/128 | 4800 | 0 |
| exact-boundary-5-FaceSouth-beside-ordinary | 1/128 | 4462 | 0 |
| exact-boundary-15-FaceWest-beside-ordinary | 1/128 | 4416 | 0 |
| exact-boundary-9-FaceEast-beside-ordinary | 1/128 | 4508 | 0 |
| exact-boundary-0-FaceSouth-beside-ordinary-control-unbiased-index | none | 4800 | 106 (rejected) |
| exact-boundary-5-FaceSouth-beside-ordinary-control-unbiased-index | none | 4462 | 94 (rejected) |
| exact-boundary-15-FaceWest-beside-ordinary-control-unbiased-index | none | 4416 | 92 (rejected) |
| exact-boundary-9-FaceEast-beside-ordinary-control-unbiased-index | none | 4508 | 95 (rejected) |
| snapped (zoom 1) | 1/128 | 6044 | 0 |
| snapped-9-8 | 1/128 | 6123 | 0 |
| snapped-5-4 | 1/128 | 6144 | 0 |
| snapped-9-8-beside-ordinary-control-stale-bias-1e-4 | 1/10000 | 9963 | 12 (rejected) |
| snapped-5-4-beside-ordinary-control-stale-bias-1e-4 | 1/10000 | 9984 | 15 (rejected) |

(The control fixtures draw an ordinary pass first, so their covered counts include it.)
The oracle that disagreed with the device at about a hundred pixels of the snapped 9/8
and 5/4 scenes before any bias (recorded in the earlier version of this evidence)
agrees with the device at every determinate probe under 1/128, so that discrepancy was
this same sampling effect, not an oracle fault.

## How a pixel is judged

Twice, independently. The render-2d oracle is given the material's pure model
(`terrainModel`) and the same snapshot; it decides what it can and lists the rest
as indeterminate with its reason. The independent expectation
(`Hetoimasia.Terrain.Render2D.Evidence`) reads nothing from the planner, its keys,
the picker, the atlas adaptation, the material or the oracle: it states by hand the
canvas corner of every quad, the painter order (the larger of
`(viewX + viewY, z, viewX, viewY)` is nearer, fog behind the known solid at one
cell), the texel under the pixel centre by the amended rule evaluated exactly in
rational arithmetic, the opaque test of the independently decoded colour and map
source images, the lit, darkened and hazed linear colour by the specified equations,
and the sRGB encoding. Scenes whose pixel centres lie on texel boundaries on purpose
(the exact-boundary fixtures) and every snapped scene are judged exactly: every pixel
is decided. For an unsnapped scene at a fractional scale or pan, a pixel centre within
1/1000 texel of the threshold of a texel boundary (the boundary less 1/128) or of a
canvas edge is undecided: counted, never compared, never passed. The count is
**0 in every one of the 76 fixtures** (`ambiguous` below). A fixture with more
undecided than compared pixels, no covered pixel, or no named probe whose expectation
differs from its contrast fails. The pure pick is compared with the same expectation
on a stride of every pass, and a pixel the pick answers `NoHit` for fog is the
expectation's fog.

## What passes

- **Region sampling and atlas packing on the device**: the 16 identities in each of
  4 facings (one cell a pass) and the bounded matrix, every colour and map region
  read at its own nonzero origin in a 288 x 64 colour atlas and a 768 x 384 normal
  atlas of unequal extent, with transparent padding and adjacent regions of
  different art, at zoom 0.25 and at native scale: the neighbours never bleed
  (the negative controls below prove the judge would see it).
- **Exact texel-boundary ownership**: four shapes in three facings with every pixel
  centre exactly on a texel boundary (zoom 1/2), and the snapped scene at zoom 1, 9/8
  and 5/4, all judged in exact arithmetic with every pixel decided, 0 mismatches.
- **Ordinary, full-fog and mixed known/fog parts**, hidden air against hidden solid
  indistinguishable as fog, and known ramp sides beside unknown void.
- **Overlap and depth**: roofs over a cavity cut at and below the roof, disconnected
  spans, ramps and corners, manual cutaways at several depths, the automatic follow
  and a floor 34 levels below the cut; the nearer quad hides the farther where
  both are opaque and a transparent texel shows what lies behind (the `reveals`
  and `overlaps` counts in the record), by real depth testing and discard.
- **Views**: the zoom endpoints (1/8 and 8), a fractional camera, a viewport away
  from the corner, a target of content scale 2, and pixel snapping at zoom 1, 9/8 and
  5/4 (the snapped fixtures at 9/8 and 5/4 discriminate snapping: 967 and 1194 pixels
  differ from the unsnapped draw, above the 20 required).
- **Lighting**: the default light with the camera turned (fixed world sun), and the
  sun varied at a fixed camera: sun only, ambient only, all illumination off beside
  the default light in a second pass of the same snapshot (two views sharing a
  registered material keep their own push blocks), the horizon, below the
  horizon, a west sun at 10 degrees and a high north sun.
- **Depth effects**: a stack of nine levels at the default numbers and at a range of 4
  with neither effect, darkening only, haze only, both, black terrain under haze
  and haze disabled with no illumination, in two facings. A labelled comparison with
  the reference's multiplicative blue tint is in `reference-tint-comparison.md`
  (no Synarchy lighting parity is claimed).
- **Submission**: the same plan in plan order, scrambled, split between two
  registered materials of identical behaviour, split between two retained chunks
  and the dynamic layer, and through the ordered wrapper (the colour atlas
  registered with its cutout mark overridden off); the runs' draw path is checked
  (`Cutout` or `Ordered`).
- **Negative controls**, each a draw or a pick broken once on the scene that makes
  the protected behaviour matter, rejected by the same judge, and each differing at
  its named probes and covered pixels: reversed depth order, the whole-cell mask, the
  wrong facing's sun, the depth effects reset, swapped colour region origins, a normal
  region that spans the whole atlas (whole-atlas clamping), the normal atlas bound as
  colour (the wrong colour-versus-data treatment), half-texel-inset interpolation that
  shifts interior boundaries, the texel rule with no bias, the texel rule with the
  superseded 1/10000 bias (the last three are control-only materials, never used for
  terrain), a pick through the farthest covered quad, a pick through fog, and the wrong
  (next) map region. The negative controls and where each is rejected are in the tables.
- **CPU**: the `test.terrain-render-2d`, `test.asset-image` and device-free
  `test.vulkan-headless` terrain suites (the numbers are in the pull request),
  the generator's `--check` and `--check-atlases`, and the checked material
  declaration, record layout and 48-byte push block against the compiled shader
  interfaces and all checked variants.

## What remains (stated, not hidden)

- **UNEXERCISED on the device**: shared-diagonal edge ownership has no dedicated
  fixture (pixel centres fall on a quad's diagonal wherever it crosses the lattice of
  the exact fixtures, and every such pixel agrees, but nothing is placed on it on
  purpose); a wrong composition order of darkening and haze has no negative control
  (the depth-effect reset control is built); packed against single-image atlases on the
  GPU for every identity and role beyond the 49-image style that draws and picks as the
  packed one does (proved on the CPU for all 16 identities, four facings and the three
  roles: plans and picks equal); legal-coordinate extremes and chunk-seam streaming on
  the GPU; supplied snapshot sequences (pan, zoom, rotation, follow, jump, reveal,
  unload and reload) on the device; a texture-byte admission or capacity-refusal run
  (the adaptation never allocates textures and its refusal is whole, proved on the CPU
  for stale assets; the 4096-record bound is proved on the CPU).
- **Reference lighting**: Synarchy's lighting
  (`src/Engine/Graphics/Vulkan/ShaderCode.hs` at `3777d437`, lines 255-301: face
  weights `R,G,B` from the legacy map, a left/right swizzle by facing, `0.4 + 0.6 max 0 sunDir`
  side terms) is not reproduced and no parity is claimed; this repository's shader
  (`packages/terrain-render-2d-vulkan/src/Hetoimasia/Terrain/Render2D/Vulkan/Source.hs`)
  lights by the decoded unit normal.
- **CI timeline** for each affected required native group is not part of this
  record yet; it requires the pull request's CI runs and is added in a later
  documentation push (requirement 10).
- Live view ownership, streaming and retirement (#645), the Lua bindings (#646),
  the arena and its shortcuts (#647) and final integrated visual acceptance
  (#648) are outside this issue.

## Fixtures: the bounded selection

| fixture | verdict | compared | ambiguous | covered | mismatches | pick mismatches/compared | control |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| matrix-FaceSouth-0.25 | pass | 10560 | 0 | 2754 | 0 | 0/10560 |  |
| mixed-FaceSouth@0.25 | pass | 2640 | 0 | 1166 | 0 | 0/660 |  |
| mixed-FaceSouth@0.25-single-images | pass | 2640 | 0 | 1166 | 0 | 0/660 |  |
| roof-cut1-FaceWest@0.125 | pass | 1176 | 0 | 468 | 0 | 0/1176 |  |
| roof-cut1-FaceWest@0.125-scrambled | pass | 1176 | 0 | 468 | 0 | 0/1176 |  |
| roof-cut1-FaceWest@0.125-two-materials | pass | 1176 | 0 | 468 | 0 | 0/1176 |  |
| roof-cut1-FaceWest@0.125-retained | pass | 1176 | 0 | 468 | 0 | 0/1176 |  |
| roof-cut1-FaceWest@0.125-ordered-wrapper | pass | 1176 | 0 | 468 | 0 | 0/1176 |  |
| ramps-FaceEast@0.125 | pass | 1404 | 0 | 435 | 0 | 0/702 |  |
| depth-stack-FaceSouth@0.25@black-under-haze | pass | 4788 | 0 | 1093 | 0 | 0/684 |  |
| spans-FaceSouth@0.125-control-reversed-overlap | pass | 1008 | 0 | 420 | 235 | 0/1008 | rejected |

## Fixtures: the complete qualification

| fixture | verdict | compared | ambiguous | covered | mismatches | pick mismatches/compared | control |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| matrix-FaceSouth-0.25 | pass | 10560 | 0 | 2754 | 0 | 0/10560 |  |
| matrix-FaceWest-0.25 | pass | 10560 | 0 | 2718 | 0 | 0/10560 |  |
| matrix-FaceNorth-0.25 | pass | 10560 | 0 | 2718 | 0 | 0/10560 |  |
| matrix-FaceEast-0.25 | pass | 10560 | 0 | 2754 | 0 | 0/10560 |  |
| native-scale-FaceSouth-1 | pass | 14280 | 0 | 6336 | 0 | 0/1300 |  |
| mixed-FaceSouth@0.25 | pass | 2640 | 0 | 1166 | 0 | 0/660 |  |
| mixed-FaceWest@0.25 | pass | 2640 | 0 | 1128 | 0 | 0/660 |  |
| mixed-FaceNorth@0.25 | pass | 2640 | 0 | 1206 | 0 | 0/660 |  |
| mixed-FaceEast@0.25 | pass | 2640 | 0 | 1170 | 0 | 0/660 |  |
| matrix-FaceSouth-0.25-single-images | pass | 10560 | 0 | 2754 | 0 | 0/10560 |  |
| matrix-FaceWest-0.25-single-images | pass | 10560 | 0 | 2718 | 0 | 0/10560 |  |
| matrix-FaceNorth-0.25-single-images | pass | 10560 | 0 | 2718 | 0 | 0/10560 |  |
| matrix-FaceEast-0.25-single-images | pass | 10560 | 0 | 2754 | 0 | 0/10560 |  |
| mixed-FaceSouth@0.25-single-images | pass | 2640 | 0 | 1166 | 0 | 0/660 |  |
| mixed-FaceWest@0.25-single-images | pass | 2640 | 0 | 1128 | 0 | 0/660 |  |
| mixed-FaceNorth@0.25-single-images | pass | 2640 | 0 | 1206 | 0 | 0/660 |  |
| mixed-FaceEast@0.25-single-images | pass | 2640 | 0 | 1170 | 0 | 0/660 |  |
| roof-cut2-FaceSouth@0.125 | pass | 1260 | 0 | 540 | 0 | 0/630 |  |
| roof-cut1-FaceSouth@0.125 | pass | 1176 | 0 | 468 | 0 | 0/1176 |  |
| roof-cut1-FaceWest@0.125 | pass | 1176 | 0 | 468 | 0 | 0/1176 |  |
| roof-cut1-FaceWest@0.125-scrambled | pass | 1176 | 0 | 468 | 0 | 0/1176 |  |
| roof-cut1-FaceWest@0.125-two-materials | pass | 1176 | 0 | 468 | 0 | 0/1176 |  |
| roof-cut1-FaceWest@0.125-retained | pass | 1176 | 0 | 468 | 0 | 0/1176 |  |
| roof-cut1-FaceWest@0.125-ordered-wrapper | pass | 1176 | 0 | 468 | 0 | 0/1176 |  |
| spans-FaceNorth@0.125 | pass | 768 | 0 | 318 | 0 | 0/768 |  |
| ramps-FaceEast@0.125 | pass | 1404 | 0 | 435 | 0 | 0/702 |  |
| stairs-cut1-FaceSouth@0.125 | pass | 1440 | 0 | 362 | 0 | 0/720 |  |
| stairs-cut3-FaceSouth@0.125 | pass | 1440 | 0 | 450 | 0 | 0/720 |  |
| stairs-cut5-FaceSouth@0.125 | pass | 1440 | 0 | 490 | 0 | 0/720 |  |
| exact-boundary-0-FaceSouth-beside-ordinary | pass | 10212 | 0 | 4800 | 0 | 0/1265 |  |
| exact-boundary-5-FaceSouth-beside-ordinary | pass | 10212 | 0 | 4462 | 0 | 0/1265 |  |
| exact-boundary-15-FaceWest-beside-ordinary | pass | 10212 | 0 | 4416 | 0 | 0/1265 |  |
| exact-boundary-9-FaceEast-beside-ordinary | pass | 10212 | 0 | 4508 | 0 | 0/1265 |  |
| follow-FaceSouth@0.125 | pass | 6372 | 0 | 1854 | 0 | 0/638 |  |
| deep-FaceSouth | pass | 5096 | 0 | 1140 | 0 | 0/637 |  |
| zoom-0.125 | pass | 2392 | 0 | 409 | 0 | 0/798 |  |
| zoom-8.0 | pass | 6144 | 0 | 6144 | 0 | 0/615 |  |
| fractional@0.1875 | pass | 2808 | 0 | 980 | 0 | 0/702 |  |
| viewport@0.125 | pass | 1344 | 0 | 350 | 0 | 0/672 |  |
| scaled@0.125 | pass | 4992 | 0 | 435 | 0 | 0/624 |  |
| snapped | pass | 6144 | 0 | 6044 | 0 | 0/615 |  |
| snapped-9-8 | pass | 6144 | 0 | 6123 | 0 | 0/615 |  |
| snapped-5-4 | pass | 6144 | 0 | 6144 | 0 | 0/615 |  |
| ramps-FaceSouth@0.125 | pass | 1596 | 0 | 429 | 0 | 0/798 |  |
| ramps-FaceWest@0.125 | pass | 1404 | 0 | 429 | 0 | 0/702 |  |
| ramps-FaceSouth@0.125@sun-only | pass | 1596 | 0 | 429 | 0 | 0/798 |  |
| ramps-FaceSouth@0.125@ambient-only | pass | 1596 | 0 | 429 | 0 | 0/798 |  |
| ramps-FaceSouth@0.125@horizon | pass | 1596 | 0 | 429 | 0 | 0/798 |  |
| ramps-FaceSouth@0.125@below-horizon | pass | 1596 | 0 | 429 | 0 | 0/798 |  |
| ramps-FaceSouth@0.125@west-low | pass | 1596 | 0 | 429 | 0 | 0/798 |  |
| ramps-FaceSouth@0.125@north-high | pass | 1596 | 0 | 429 | 0 | 0/798 |  |
| ramps-FaceSouth@0.125@dark-beside-default | pass | 3192 | 0 | 858 | 0 | 0/1596 |  |
| depth-stack-FaceSouth@0.25@neither-effect | pass | 4788 | 0 | 1093 | 0 | 0/684 |  |
| depth-stack-FaceSouth@0.25@darkening-only | pass | 4788 | 0 | 1093 | 0 | 0/684 |  |
| depth-stack-FaceSouth@0.25@haze-only | pass | 4788 | 0 | 1093 | 0 | 0/684 |  |
| depth-stack-FaceSouth@0.25@both-short-range | pass | 4788 | 0 | 1093 | 0 | 0/684 |  |
| depth-stack-FaceSouth@0.25@black-under-haze | pass | 4788 | 0 | 1093 | 0 | 0/684 |  |
| depth-stack-FaceSouth@0.25@haze-no-light-beside-default | pass | 9576 | 0 | 2186 | 0 | 0/1368 |  |
| depth-stack-FaceNorth@0.25@black-under-haze | pass | 12852 | 0 | 1395 | 0 | 0/612 |  |
| spans-FaceSouth@0.125-control-reversed-overlap | pass | 1008 | 0 | 420 | 235 | 0/1008 | rejected |
| ramps-FaceSouth@0.125-control-whole-cell-mask | pass | 1596 | 0 | 429 | 389 | 0/798 | rejected |
| ramps-FaceWest@0.125-control-wrong-facing-light | pass | 1404 | 0 | 429 | 239 | 0/702 | rejected |
| depth-stack-FaceSouth@0.25@neither-effect-haze-control-depth-reset | pass | 4788 | 0 | 1093 | 934 | 0/684 | rejected |
| matrix-FaceSouth-1.0@0.25-control-swapped-region-origins | pass | 8664 | 0 | 2754 | 2754 | 0/619 | rejected |
| ramps-FaceSouth@0.125-control-whole-atlas-clamping | pass | 1596 | 0 | 429 | 424 | 0/798 | rejected |
| ramps-FaceSouth@0.125-control-normal-as-colour | pass | 1596 | 0 | 429 | 243 | 0/798 | rejected |
| ramps-FaceSouth@0.125-control-half-texel-inset | pass | 1596 | 0 | 429 | 18 | 0/798 | rejected |
| ramps-FaceSouth@0.125-control-wrong-map-region | pass | 1596 | 0 | 429 | 210 | 0/798 | rejected |
| fog-over-known-FaceSouth@0.25-control-pick-through-fog | pass | 1020 | 0 | 512 | 0 | 192/1020 | rejected |
| spans-FaceSouth@0.125-control-pick-through-nearer | pass | 1008 | 0 | 420 | 0 | 268/1008 | rejected |
| exact-boundary-0-FaceSouth-beside-ordinary-control-unbiased-index | pass | 10212 | 0 | 4800 | 106 | 0/1265 | rejected |
| exact-boundary-5-FaceSouth-beside-ordinary-control-unbiased-index | pass | 10212 | 0 | 4462 | 94 | 0/1265 | rejected |
| exact-boundary-15-FaceWest-beside-ordinary-control-unbiased-index | pass | 10212 | 0 | 4416 | 92 | 0/1265 | rejected |
| exact-boundary-9-FaceEast-beside-ordinary-control-unbiased-index | pass | 10212 | 0 | 4508 | 95 | 0/1265 | rejected |
| snapped-9-8-beside-ordinary-control-stale-bias-1e-4 | pass | 13284 | 0 | 9963 | 12 | 0/1265 | rejected |
| snapped-5-4-beside-ordinary-control-stale-bias-1e-4 | pass | 13284 | 0 | 9984 | 15 | 0/1265 | rejected |
