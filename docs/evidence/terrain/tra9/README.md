# TRA-9 evidence: terrain views

Issue #645. The judged results of the terrain-view adapter on a real device and the headless
examples that stand for the rest. The contract is the graphics package's README ("Terrain views")
and terrain-runtime's README (the precondition guard, the outside staging account).

| | |
| --- | --- |
| Device | Apple M3 Max, MoltenVK (the pinned Homebrew driver), surface-free targets with a `D32_SFLOAT` depth image |
| Tested head | `e3a625c9`, on base `6b35b315` |
| Effective spec | `98a673fb` (review 6909126590): the atlas amendment 6731831183 as amended by reviews 6731944497, 6908703832 and 6909126590 and the decision comments 6908430167 and 6909009968 |

## Results

| Run | Command | Result |
| --- | --- | --- |
| Required native witness | `bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests -- --complete` | 32/32 in 8.86 s on the terrain-disabled host; 1/1 in 0.06 s on the terrain-enabled host (window depth on); 16 s wall, under the 30 s rule (`docs/vision.md:272`) |
| Full qualification | the same suite with `-- --terrain-views-full` | 8/8 in 10.47 s |
| Headless | `bash tools/vulkan/run.sh test hetoimasia-lua-engine-graphics:test:lua-engine-graphics-tests` (group `terrain views`) | 38/38, about 24 s, three runs in a row |

Native commands run on macOS under the standing per-command consent (`HETOIMASIA_NATIVE_SESSION=desktop`);
the full qualification wrote its files with `HETOIMASIA_VALIDATION_EVIDENCE` set.

**Host configuration per witness.** The terrain views witness and every subgroup the native suite
already had run on the terrain-disabled host. M1 output also runs, in a second short session, on a
terrain-enabled host (`configureWorldDepth`, every window generation with a depth image): a published
M1 scene is adopted, recorded and presented there.

**Pixels.** Every pixel of each rendering is judged by the render-2d oracle with the terrain
material's own model, independent of the production picker:

| Rendering | Framebuffer | Passed | Failed | Indeterminate |
| --- | --- | --- | --- | --- |
| required A, required B (after the handles' release and an edit) | 128 x 96 | 12,288 each | 0 | 0 |
| facing south, east, north, west | 128 x 96 | 12,288 each | 0 | 0 |
| zoom 2 | 128 x 96 | 12,288 | 0 | 0 |
| zoom 0.5 | 128 x 96 | 5,480 | 0 | 6,808 (minified texels the oracle cannot decide; determinacy floor a quarter) |
| portrait | 64 x 128 | 8,192 | 0 | 0 |

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
