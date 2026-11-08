# TRA-8 (#644): terrain materials and depth ordering, offscreen (Q-13 assessment)

**Outcome: the existing fixed-quad/material ABI represents the supported terrain
geometry correctly. Q-13 passes for depth, cutaway coverage, transparent coverage
and pick/render agreement on the 29 fixtures below, offscreen.** This qualifies the
material and geometry path on one device; it is not runtime qualification, not a
statement about live streaming, retirement under changing terrain, gameplay or
performance, and not a flat-arena screenshot. One fidelity finding against Synarchy's
reference sprites is recorded separately below and needs the owner's reading; it is not
a renderer inability.

## What was run

- Command (macOS, under the desktop-consent policy; the scenario creates no window):
  `HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --private-roots tra8-terrain`
  (Linux: the same command without the variable, through the runner's isolated display.)
- Source revision `fc7125ee32d5f36bb1005b3488c981c3f48e9f21` (clean tree), source digest `bad3d131e784aa4e968aafb275dd7bb9ca60f8cc5e8ad5e09042a40dc1705380`; device
  `Apple M3 Max` (MoltenVK); depth format `Depth32Float`, target `Rgba8Srgb`; validation and
  synchronization validation clean through teardown.
- Shader identity (SPIR-V SHA-256 of the checked fragment variants): cutout
  `4e7997e31dd44362029aa20491f58c4e59df0be86dd5735314d80b89a0bd0c1a`, translucent `c4ddbadebac97f03a141adf3c7a44c2acae2ca3ae66bde0430fbd7ed0d9f834e`, equivalent second material `332e4fa7c0a36b749b3332eb7df0212507d7182481d990f5d50fa58d099dac4c`; the glslang that
  compiled them is the one `tools/vulkan/run.sh` reports.
- Art: approved loam (SHA-256 `f449a06b...05e1`) and granite (`776a28d3...79d1`), byte for byte from
  Synarchy `3777d437ea00e1302bf55162ad5693fee4879187`, 96 x 64 sRGB with binary alpha; and a
  technical diagnostic sheet (not artwork). Every fixture's record lists each sheet's cutout mark
  (all `true`, the decoded default) and the draw path its faces took: **every face of every fixture
  took the cutout path**, so the conclusion holds for the path the approved art takes with its decoded
  mark; no mark override was used.
- Budget: scenario body 3.84 s; the scenario's child ran 4.1 s against the 20 s child deadline and the whole
  `--complete` profile 15.9 s against its 30 s watchdog (`complete-profile-transcript.txt`, same head). Every
  batch's completion was awaited before its readback; the oracle's per-pixel judging still dominates the time
  (about 2.6 s of the 3.8 s), recording and readback of all fixtures together taking about 1.1 s. The
  oracle first placed each instance afresh at every pixel, which made the scenario 9.1 s on the same machine and
  about 15.6 s on the Linux runner (where the watchdog expired at 30.1 s in total); it now places each instance
  once, with the same exact values, and every oracle and independent count in this record is the same as before.

## How a pixel is judged

1. **The render-2d oracle**, given the material's pure model, judges every pixel of every target.
   Probes it cannot decide are listed with their reason and counted for nothing.
2. **An independent expectation** (`Hetoimasia.Terrain.Render2D.Evidence`), worked out from half-spaces
   and lines of sight without the planner, its faces, its depth keys, its picking, the material or the
   oracle, judges every pixel it can decide against the art's texel (through each face's diagnostic tint
   in tinted fixtures), within a tolerance declared in advance (2 channel steps; 3 for tinted). Pixels it
   cannot decide (a line of sight along an edge or within a hundredth of a pixel of one, or within a
   sixteenth of a texel's boundary) are counted as ambiguous, never compared.
3. **The pure planner coverage, the material model and the pure pick** are compared with the same
   expectation on a stride of each scene's pixel centres (frontmost cell, face and plane,
   transparent-texel fall-through, and pick = geometric frontmost).

No expectation is derived from the observed image and nothing updates a golden image. Across all
fixtures: 106206 oracle-determinate pixels and 8514 reported indeterminate; 112904 pixels compared
with the independent expectation and 1816 ambiguous. The indeterminate and ambiguous pixels are
platform-sensitive boundaries (a pixel centre within 1/16 pixel of a quad or mask edge, or of a texel
boundary at the fractional zooms); nothing here claims cross-platform bit identity.

## Fixtures

The 16 shapes in each of the 4 facings are 16 one-cell passes per facing (so the oracle's cost for a
pixel is that of its own cell), each face tinted by the diagnostic colour of its plane so that every face
of every shape is visibly its own colour, plus two shapes at native scale with the approved art alone.
Occlusion fixtures are small scenes at low zoom; each shows its behaviour by named probes that are
determinate for the oracle and differ from their contrasts (see the record). Variants of one scene (plan
order, scrambled submission, two registered materials of identical behaviour, two retained chunks plus a
dynamic remainder) must draw one image.

| Fixture | Variant / look | Oracle determinate | Oracle indeterminate | Independent compared / ambiguous / mismatches | Pure judge compared / mismatches | Verdict |
| --- | --- | ---: | ---: | --- | --- | --- |
| matrix-FaceSouth-0.25 | Dynamic/Tinted | 10040 | 520 | 10560 / 0 / 0 | 2240 / 0 | pass |
| matrix-FaceWest-0.25 | Dynamic/Tinted | 9840 | 720 | 10560 / 0 / 0 | 2240 / 0 | pass |
| matrix-FaceNorth-0.25 | Dynamic/Tinted | 10026 | 534 | 10560 / 0 / 0 | 2240 / 0 | pass |
| matrix-FaceEast-0.25 | Dynamic/Tinted | 9851 | 709 | 10560 / 0 / 0 | 2240 / 0 | pass |
| native-scale-FaceSouth-1 | Dynamic/Plain | 12700 | 1580 | 14256 / 24 / 0 | 850 / 0 | pass |
| roof-cut2-FaceSouth@0.125 | Dynamic/Plain | 1260 | 0 | 1260 / 0 / 0 | 280 / 0 | pass |
| roof-cut1-FaceSouth@0.125 | Dynamic/Plain | 1176 | 0 | 1176 / 0 / 0 | 260 / 0 | pass |
| roof-cut1-FaceWest@0.125 | Dynamic/Plain | 1162 | 14 | 1176 / 0 / 0 | 260 / 0 | pass |
| roof-cut1-FaceWest@0.125-scrambled | Scrambled/Plain | 1162 | 14 | 1176 / 0 / 0 | 260 / 0 | pass |
| roof-cut1-FaceWest@0.125-two-materials | TwoMaterials/Plain | 1162 | 14 | 1176 / 0 / 0 | 260 / 0 | pass |
| roof-cut1-FaceWest@0.125-retained | Retained/Plain | 1162 | 14 | 1176 / 0 / 0 | 260 / 0 | pass |
| spans-FaceNorth@0.125 | Dynamic/Plain | 768 | 0 | 768 / 0 / 0 | 165 / 0 | pass |
| ramps-FaceEast@0.125 | Dynamic/Plain | 1333 | 71 | 1392 / 12 / 0 | 306 / 0 | pass |
| stairs-cut1-FaceSouth@0.125 | Dynamic/Plain | 1440 | 0 | 1440 / 0 / 0 | 322 / 0 | pass |
| stairs-cut3-FaceSouth@0.125 | Dynamic/Plain | 1440 | 0 | 1440 / 0 / 0 | 322 / 0 | pass |
| stairs-cut5-FaceSouth@0.125 | Dynamic/Plain | 1440 | 0 | 1440 / 0 / 0 | 322 / 0 | pass |
| follow-FaceSouth@0.125 | Dynamic/Plain | 6372 | 0 | 6372 / 0 / 0 | 377 / 0 | pass |
| deep-FaceSouth | Dynamic/Plain | 5096 | 0 | 5096 / 0 / 0 | 544 / 0 | pass |
| zoom-0.125 | Dynamic/Plain | 2349 | 43 | 2392 / 0 / 0 | 550 / 0 | pass |
| zoom-8.0 | Dynamic/Plain | 4325 | 1819 | 4700 / 1444 / 0 | 96 / 0 | pass |
| fractional@0.1875 | Dynamic/Plain | 2463 | 345 | 2484 / 324 / 0 | 312 / 0 | pass |
| viewport@0.125 | Dynamic/Plain | 1271 | 73 | 1344 / 0 / 0 | 300 / 0 | pass |
| scaled@0.125 | Dynamic/Plain | 4921 | 71 | 4980 / 12 / 0 | 542 / 0 | pass |
| snapped | Dynamic/Plain | 4719 | 1425 | 6144 / 0 / 0 | 384 / 0 | pass |
| diagnostic-FaceSouth@0.25 | Dynamic/Tinted | 2795 | 169 | 2964 / 0 / 0 | 312 / 0 | pass |
| diagnostic-FaceWest@0.25 | Dynamic/Tinted | 2368 | 332 | 2700 / 0 / 0 | 288 / 0 | pass |
| spans-FaceSouth@0.125-control-reversed-overlap | ReversedKeys/Plain | 1008 | 0 | 1008 / 0 / 137 | 220 / 0 | rejected (expected) |
| ramps-FaceSouth@0.125-control-whole-quad-mask | WholeQuad/Plain | 1549 | 47 | 1596 / 0 / 67 | 360 / 0 | rejected (expected) |
| spans-FaceSouth@0.125-control-pick-through-nearer-face | BackmostPick/Plain | 1008 | 0 | 1008 / 0 / 0 | 220 / 41 | rejected (expected) |

Captures are lossless PNGs under `captures/` (`terrain-<fixture>-<pass>.png`); the machine-readable
records are `tra8-terrain-fixtures.json` (per fixture: scene, camera and cutaway settings, cells, plan
identity, draw path, cutout marks, tolerances, counts, mismatches, pick outcomes, seconds by stage) and
`tra8-terrain-probes.json` (every named probe and every indeterminate or failed probe);
`tra8-terrain-journal.md` is the scenario's own transcript.

## Negative controls

Each control draws a scene broken once on purpose, on the scene that makes the protected behaviour
matter, and must be rejected by the same judge that passes the correct draw:

- **Reversed overlap** (`spans-...-control-reversed-overlap`): the depth keys' order inverted; the
  independent expectation found 137 mismatches (the oracle, given what was drawn, agrees with the draw).
- **Incorrect coverage mask** (`ramps-...-control-whole-quad-mask`): every mask the whole quad; 67 mismatches.
- **Pick through a nearer face** (`spans-...-control-pick-through-nearer-face`): drawn correctly, the pick
  answers through the backmost face; the pure judge found 41 disagreements.

## Fidelity finding: reference silhouettes (needs the owner's reading)

Reference: Synarchy `3777d437ea00e1302bf55162ad5693fee4879187`, `src/World/Render/Textures.hs:23-57`, the
`isoface.png` and `isoface_slope_*.png` face maps under `assets/textures/facemap/`. No face-map image is
retained in this repository. Compared at native scale, South facing, as the alpha of the reference's 96 x 64
image against the pixels a single cell of that identity covers (its hexagon placed as the art sheet is):

| Identity | Solid-only pixels | Reference-only pixels |
| --- | ---: | ---: |
| 0 flat | 0 | 96 |
| 1 N | 360 | 72 |
| 2 E | 24 | 72 |
| 3 NE | 0 | 72 |
| 4 S | 394 | 50 |
| 5 NS | 0 | 624 |
| 6 ES | 24 | 456 |
| 7 NES | 0 | 264 |
| 8 W | 0 | 816 |
| 9 NW | 1 | 409 |
| 10 EW | 0 | 664 |
| 11 NEW | 0 | 816 |
| 12 SW | 0 | 816 |
| 13 NSW | 0 | 456 |
| 14 ESW | 0 | 1440 |
| 15 NESW | 1488 | 48 |

The solids and the reference agree closely for identities 0, 2 and 3, and differ by hundreds of pixels for
the others (for 14 the reference is nearly the whole hexagon where the solid is a small tent; for 15 the
reference is smaller than the flat hexagon the solid gives). The reference sprites are surface tiles and
carry context a single-cell solid does not. The design makes the shared solids, not the face maps,
authoritative, and the renderer draws those solids correctly; this table is evidence for the owner's
decision on whether the reference silhouettes are to be matched, and no renderer change is implied.

## View-variant fixtures and a known gap

- **Follow headroom** stays on its anchor column: the camera is asserted by hand (surface 3, cut 28, reference 4) on the CPU
  and in the scenario, and a cap probe shows the tall columns cut flat at level 28.
- **Viewport offset** is set after the target is fitted (it starts away from the target's corner and stops short of its far
  edges); a probe pairs a pixel the viewport clips away (clear, though the scene would cover it) with a covered one.
- **Pixel snapping** runs at native scale with the camera about 0.3 pixel off the pixel grid. The fixture fails unless at least
  20 pixels read as the snapped view and not as the same snapshot with snapping off (judged by the oracle's own snapped and
  unsnapped expectations); this run read 53.
- **Known gap.** My independent line-of-sight texel model did not agree with the recorder under snapping where the technical
  diagnostic sheet has transparent blocks (192 mismatches in an earlier run, all at texel/hole boundaries; silhouettes and the
  pick agreed). The cause was not found. The snapped fixture therefore uses the approved art, and the pure CPU judge compares only
  the pick for a snapped scene (it models unsnapped faces).

## Baseline status

Per design P-16 this per-face material is the baseline, retained for its artwork provenance, material registration and package
separation, offscreen harness and this measured evidence; face-mapped quads are TRA-17, which replaces the per-face renderer and
carries the amended Q-13 gate. Nothing here qualifies the amended path.

## Remaining limits

One device and one backend; one approved material pair; scenes are small and mostly at low zoom to fit the
20-second child deadline (native scale is shown by two shapes and by the zoom endpoints 0.125 and 8, a
snapped zoom-1 view, a content-scale-2 target, a viewport away from the corner and a fractional camera).
Art with transparent texels is exercised through the technical diagnostic sheet, in scenes with no two
cells sharing a face (the planner omits a covered face, which a transparent texel could otherwise expose).
The oracle's quad coverage gained an exact bounding-box early-out for this evidence to fit its budget
(`packages/render-2d-oracle`, result-preserving, held to the definition by a randomized test). Live
retained-region construction, adoption, retirement budgets and streaming are TRA-9.
