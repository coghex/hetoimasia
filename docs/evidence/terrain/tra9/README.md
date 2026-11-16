# TRA-9 evidence: terrain views

Issue #645. The judged results of the terrain-view adapter on a real device and the headless
examples that stand for the rest. The contract is the graphics package's README ("Terrain views")
and terrain-runtime's README (the precondition guard, the outside staging account).

| | |
| --- | --- |
| Device | Apple M3 Max, MoltenVK (the pinned Homebrew driver), surface-free targets with a `D32_SFLOAT` depth image |
| Tested head | `34bdfb66`, on base `beb96171` (review round 2) |
| Effective spec | `98a673fb` (review 6909126590): the atlas amendment 6731831183 as amended by reviews 6731944497, 6908703832 and 6909126590 and the decision comments 6908430167 and 6909009968 |

## Results

| Run | Command | Result |
| --- | --- | --- |
| Required native witness | `bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests -- --complete` | 32/32 in 9.22 s on the terrain-disabled host; 4/4 in 3.12 s on the terrain-enabled host; 12.34 s of test time, 21 s wall, under the 30 s rule (`docs/vision.md:272`) |
| Full qualification | the same suite with `-- --terrain-views-full` | 14/14 in 24.76 s |
| Headless | `bash tools/vulkan/run.sh test hetoimasia-lua-engine-graphics:test:lua-engine-graphics-tests` (group `terrain views`) | 57/57, about 33 s |

Native commands run on macOS under the standing per-command consent (`HETOIMASIA_NATIVE_SESSION=desktop`);
the full qualification wrote its files with `HETOIMASIA_VALIDATION_EVIDENCE` set.

**Host configuration per witness.** The terrain views witness and every subgroup the native suite
already had run on the terrain-disabled host. A second short session runs a terrain-enabled host
(`configureWorldDepth`, every window generation with a depth image). On it, a published M1 scene is
adopted, recorded and presented. The shipped quad and the twelve-colour grid are judged pixel by pixel
there, as on the other host. A peer window keeps presenting while another is resized, and the resized
window's earlier generation, once retired, keeps its depth image until it is destroyed.

**Pixels.** Every pixel of each rendering is judged by the render-2d oracle with the terrain
material's own model, independent of the production picker:

| Rendering | Framebuffer | Passed | Failed | Indeterminate |
| --- | --- | --- | --- | --- |
| required A, required B (after the handles' release and an edit) | 128 x 96 | 12,288 each | 0 | 0 |
| facing south, east, north, west | 128 x 96 | 12,288 each | 0 | 0 |
| zoom 2 | 128 x 96 | 12,288 | 0 | 0 |
| zoom 8 | 128 x 96 | 10,911 | 0 | 1,377 |
| zoom 0.5 | 128 x 96 | 5,480 | 0 | 6,808 |
| zoom 0.125 | 128 x 96 | 6,416 | 0 | 5,872 |
| portrait | 64 x 128 | 8,192 | 0 | 0 |
| before and after a resize of the adopted view | 128 x 96, then 96 x 128 | 12,288 each | 0 | 0 |
| a far lower background (a 250-level band) | 128 x 96 | 12,288 | 0 | 0 |
| a revealed cavity: ordinary, fog and mixed cells | 128 x 96 | 12,288 | 0 | 0 |
| a revision whose batch was in flight while a newer one was adopted | 128 x 96 | 12,288 | 0 | 0 |

Indeterminate pixels are minified or enlarged texel boundaries the oracle cannot decide. The
determinacy floor is a quarter of the pixels.

**Picks.** The oracle names colours, not the quad that wins a pixel, so picks are judged against the
adopted plan's geometry. At every judged terrain pixel whose containing quads are all known parts, the
pick must be a hit on one of those quads' cells, examined nearest first. That is the frontmost quad
unless its texel there is a cutout. The rule does not decide texel coverage, which would repeat the
picker. About half the picks name the frontmost quad (6,144 of 12,288 at each facing): a diamond tile
fills half its quad's rectangle, and its corners are cutout texels.

**Limits.** In both runs the GPU finished the in-flight batch before the newer revision was adopted,
so the overlap was recorded, not exercised: no seam holds a batch's completion. A refused stale
replacement is judged by the headless examples. Natively, the real runtime's background loads move the
residency generation unpredictably, and the example cannot tell a fresh refresh from the replacement.

## Offload and reload (amendment 6909009968)

Covered by construction plus an example, not by a forced eviction. By construction: every terrain and
knowledge input of a view's plan, retained regions and pick metadata comes from regional copies, which
read the store whether or not a region is resident; the adapter never uses `withSnapshot` (graphics
README, "Inputs"). The residency generation a copy is labelled with is kept as a checked identity at
publication and in the removal guard. By example: a fresh view, a separate incarnation attached after
a sealed cavity's reveal committed, with its own copies, agrees with the original at the same intent
and revisions: 19 ordinary, 10 fog and 2 mixed cells, the same 768 sampled picks and the same drawn
instances.

Eviction itself is forced at the full region extent with the smallest valid resident bank (about
3.5 MB with four-region holds, 21.5 MB with 64): a view that pans away loses an original region to
another holder's pressure, by coordinate, and panning back reloads it and republishes the same plan
and picks; under pressure the view's visible demand, far background included, stays resident.

## Files

`full/` holds, for each rendering of the full qualification, the lossless readback (`<name>.png`) and
the oracle comparison (`<name>.json`: revision, view, plan, framebuffer, chunks, passed, failed,
indeterminate, clear pixels, the judge and the completion). The CI receipt of the required native
group is in the pull request's body.
