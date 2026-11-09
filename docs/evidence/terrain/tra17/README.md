# TRA-17 evidence: the amended Q-13 verdict for the terrain material

Issue #659, epic #636. This is the measured evidence for the cell-quad, atlas-region,
lit and depth-shaded terrain material on a real device. It replaces, for the
cell-quad contract, the per-face evidence under `../tra8/`, which stays as labelled
history of the old model (revision-pinned, never current behaviour).

## Verdict

**The amended Q-13 material obligations listed under "What passes" pass on the
device below; the obligations under "What remains" are not proved by this evidence.**
No required geometry, order, sampling or ABI counterexample was found: every
decided pixel of every non-control fixture agrees, within the declared tolerance,
with an independent hand-stated expectation, and the render-2d oracle agrees with
the device wherever it can decide.

| | |
| --- | --- |
| Device | Apple M3 Max (Vulkan through MoltenVK on macOS), surface-free, no window |
| Depth | `Depth32Float` (an unsupported depth is a failure, never a skip) |
| Tested head | `3f7b6f996efa13310fc56692bb17c6a6dd351a45` on a clean tree |
| Source digest | `822a60dc0964600463d57a1642281146eb555a4008d7e06635c4c362cc61b78e` |
| Tolerance | 3 8-bit steps per channel, declared before any pixel is read (sRGB round trip, one linear rounding, 32-bit against 64-bit arithmetic) |
| Full run | `tra17-terrain`: 54 fixtures, 5.6 s |
| Bounded run | `tra17-terrain-ci`: 10 fixtures, 0.9 s |
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
every target; `bounded/` the same records for the bounded selection;
`*-run-record.md` and `*-transcript.txt` the runner's record and output. Each
fixture record carries the scene (cells, camera, zoom, facing, knowledge), the plan
identity, the quad and record counts, the draw path, the cutout marks, the oracle's
probe counts, the independent judge's compared, ambiguous, covered, reveal and
overlap counts and mismatches, the pick comparison, the shader SPIR-V hashes and
the atlas files' SHA-256 and layout identity.

## How a pixel is judged

Twice, independently. The render-2d oracle is given the material's pure model
(`terrainModel`) and the same snapshot; it decides what it can and lists the rest
as indeterminate with its reason. The independent expectation
(`Hetoimasia.Terrain.Render2D.Evidence`) reads nothing from the planner, its keys,
the picker, the atlas adaptation, the material or the oracle: it states by hand the
canvas corner of every quad, the painter order (the larger of
`(viewX + viewY, z, viewX, viewY)` is nearer, fog behind the known solid at one
cell), the texel under the pixel centre, the opaque test of the independently
decoded colour and map source images, the lit, darkened and hazed linear colour by
the specified equations, and the sRGB encoding. A pixel within a sixteenth of a
texel boundary is ambiguous: counted, never compared, never passed. A fixture with
more ambiguous than compared pixels, no covered pixel, or no named probe whose
expectation differs from its contrast fails. The pure pick is compared with the
same expectation on a stride of every pass, and a pixel the pick answers
`NoHit` for fog is the expectation's fog.

## What passes

- **Region sampling and atlas packing on the device**: the 16 identities in each of
  4 facings (one cell a pass) and the bounded matrix, every colour and map region
  read at its own nonzero origin in a 288 x 64 colour atlas and a 768 x 384 normal
  atlas of unequal extent, with transparent padding and adjacent regions of
  different art, at zoom 0.25 and at native scale: the neighbours never bleed
  (nine negative controls below prove the judge would see it).
- **Ordinary, full-fog and mixed known/fog parts**, hidden air against hidden solid
  indistinguishable as fog, and known ramp sides beside unknown void.
- **Overlap and depth**: roofs over a cavity cut at and below the roof, disconnected
  spans, ramps and corners, manual cutaways at several depths, the automatic follow
  and a floor 34 levels below the cut; the nearer quad hides the farther where
  both are opaque and a transparent texel shows what lies behind (the `reveals`
  and `overlaps` counts in the record), by real depth testing and discard.
- **Views**: the zoom endpoints (1/8 and 8), a fractional camera, a viewport away
  from the corner, a target of content scale 2, and pixel snapping at zoom 1.
- **Lighting**: the default light with the camera turned (fixed world sun), and the
  sun varied at a fixed camera: sun only, ambient only, all illumination off beside
  the default light in a second pass of the same snapshot (two views sharing a
  registered material keep their own push blocks), the horizon, below the
  horizon, a west sun at 10 degrees and a high north sun.
- **Depth effects**: a stack of nine levels at the default numbers and at a range of 4
  with neither effect, darkening only, haze only, both, black terrain under haze
  and haze disabled with no illumination, in two facings.
- **Submission**: the same plan in plan order, scrambled, split between two
  registered materials of identical behaviour, split between two retained chunks
  and the dynamic layer, and through the ordered wrapper (the colour atlas
  registered with its cutout mark overridden off); the runs' draw path is checked
  (`Cutout` or `Ordered`).
- **Negative controls**, each a draw or a pick broken once on the scene that makes
  the protected behaviour matter, rejected by the same judge, and each differing at
  its named probes and the hundred covered pixels nearest the centre: reversed
  depth order, the whole-cell mask, the wrong facing's sun, the depth effects reset,
  swapped colour region origins, a normal region that spans the whole atlas
  (whole-atlas clamping), the normal atlas bound as colour (the wrong
  colour-versus-data treatment), half-texel-inset interpolation that shifts
  interior boundaries (a third, control-only material, never used for terrain),
  and a pick through the farthest covered quad.
- **CPU**: the `test.terrain-render-2d`, `test.asset-image` and device-free
  `test.vulkan-headless` terrain suites (the numbers are in the pull request),
  the generator's `--check` and `--check-atlases`, and the checked material
  declaration, record layout and 48-byte push block against the compiled shader
  interfaces and both checked variants.

## What remains (stated, not hidden)

- **UNEXERCISED on the device**: exact texel, raster and shared-diagonal edge
  ownership with pixel centres exactly on boundaries (the fixtures keep centres
  off boundaries by a nudge, and the pick's boundary rule is proved on the CPU);
  packed against single-image atlases on the GPU (proved on the CPU for all 16
  identities, four facings and the three roles: plans and picks equal);
  legal-coordinate extremes and chunk-seam streaming on the GPU; supplied snapshot
  sequences (pan, zoom, rotation, follow, jump, reveal, unload and reload) on the
  device; a texture-byte admission or capacity-refusal run (the adaptation never
  allocates textures and its refusal is whole, proved on the CPU for stale assets;
  the 4096-record bound is not exercised).
- **Oracle against device at fractional snap-compatible scales.** With pixel
  snapping on at zoom 9/8 and 5/4 the independent expectation agrees with the
  device at every decided pixel, while the render-2d oracle disagrees at about a
  hundred boundary-adjacent pixels (columns where the oracle puts a texel boundary
  a pixel away from the device). The snapped fixture therefore runs at zoom 1,
  where a nearest-sampled quad cannot change under a sub-pixel shift (so it does
  not discriminate snapping from an ignored setting; nothing claims it does). This
  is recorded, not hidden by a looser tolerance, and is the render-2d oracle's to
  look at.
- **Reference lighting comparison**: Synarchy's lighting
  (`src/Engine/Graphics/Vulkan/ShaderCode.hs` at `3777d437`, lines 255-301: face
  weights `R,G,B` from the legacy map, a left/right swizzle by facing, `0.4 + 0.6 max 0 sunDir`
  side terms) is not reproduced and no parity is claimed; this repository's shader
  (`packages/terrain-render-2d-vulkan/src/Hetoimasia/Terrain/Render2D/Vulkan/Source.hs`)
  lights by the decoded unit normal. The labelled comparison with the reference's
  multiplicative blue depth tint was not produced.
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
| follow-FaceSouth@0.125 | pass | 6372 | 0 | 1854 | 0 | 0/638 |  |
| deep-FaceSouth | pass | 5096 | 0 | 1140 | 0 | 0/637 |  |
| zoom-0.125 | pass | 2392 | 0 | 409 | 0 | 0/798 |  |
| zoom-8.0 | pass | 4704 | 1440 | 4704 | 0 | 0/403 |  |
| fractional@0.1875 | pass | 2304 | 504 | 654 | 0 | 0/576 |  |
| viewport@0.125 | pass | 1344 | 0 | 350 | 0 | 0/672 |  |
| scaled@0.125 | pass | 4992 | 0 | 435 | 0 | 0/624 |  |
| snapped | pass | 6144 | 0 | 6044 | 0 | 0/615 |  |
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
| spans-FaceSouth@0.125-control-pick-through-nearer | pass | 1008 | 0 | 420 | 0 | 268/1008 | rejected |
