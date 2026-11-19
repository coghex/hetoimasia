# TRA-9 evidence: terrain views

Issue #645. The judged results of the terrain-view adapter on a real device and the headless
examples that stand for the rest. The contract is the graphics package's README ("Terrain views")
and terrain-runtime's README (the precondition guard, the outside staging account).

| | |
| --- | --- |
| Device | Apple M3 Max, MoltenVK (the pinned Homebrew driver), surface-free targets with a `D32_SFLOAT` depth image |
| Final code | `50cf61d3` (review round 6). Its qualification is CI's native receipts at the pull request's head, which carries this code: `test.vulkan-native`, `test.vulkan-lua-engine-native` (with `--complete`), `test.glfw-native` and `test.vulkan-wayland`, recorded in the pull request's body with the head each ran at |
| Renderings | captured at `cdc34252` on base `26579849` (round 5), before rounds 5 and 6 changed the worker's selection, close, pins, waits and admission charge; the pixel and pick tables below are for that head |
| Effective spec | `d107834a`, approved in review 7024627413: the atlas amendment 6731831183 as amended by reviews 6731944497, 6908703832 and 6909126590, the decision comments 6908430167 and 6909009968, the round-3 scope split 7016919733 (owner X), the frame-limit amendment 7017110545, the round-4 scope split 7020752728 (owner N) and the flaky-example amendment 7024520210 (round 5's review read `3b7424f6`, before it) |
| Moved out | #706 (a camera tail the terrain service cut, asked again by an idle view); #709 (progress under a binding bound: whole-unit publication under the renderer's record window, a partial plan's continuation, a distant jump under the cap, multi-turn builds, and a preparation the account binds); #710 (stronger witnesses: the record window against the recorder and its diagnostic, the far background tied to a drawn quad, every pixel accounted, the intent on the adopted plan, the native suite's focused selection, and, item 7, a deterministic witness for a release that did not run beside another view's retirements); #711 (two headless examples that ran past their bound or their attempt limit under machine load) |

## Results

| Run | Command | Result |
| --- | --- | --- |
| Required native witness (at `cdc34252`) | `bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests -- --complete` | 32/32 in 10.38 s on the terrain-disabled host; 4/4 in 3.23 s on the terrain-enabled host; 13.61 s of test time, 22 s wall, under the 30 s rule (`docs/vision.md:272`) |
| Full qualification (at `cdc34252`) | the same suite with `-- --terrain-views-full` | 13/13 in 29.37 s, then the overlap witness on its own held host, 1/1 in 5.35 s |
| Headless | `bash tools/vulkan/run.sh test hetoimasia-lua-engine-graphics:test:lua-engine-graphics-tests` (group `terrain views`) | at `6d306f02`: 118/119 in 58.9 s under load 16 to 20 from another workload; the attempts example of the eviction group took 21 attempts (#711). At `58eba55d`: 108/108 in 51.8 s. At `cdc34252`, under load about 14, the eviction example ran past its bound (#711) |

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
| a revealed cavity: ordinary, fog and mixed cells | 128 x 96 | 12,288 | 0 | 0 |
| the adopted image, kept after a refused stale replacement, then the replacement | 128 x 96 | 12,288 each | 0 | 0 |
| A, held in GPU use while B was adopted; B after A's batch completed | 128 x 96 | 12,288 each | 0 | 0 |

Indeterminate pixels are minified or enlarged texel boundaries the oracle cannot decide. The
determinacy floor is a quarter of the pixels.

**Picks.** Judged exactly. At every pixel the oracle decides, it names the instances that draw there in
drawing order (`probeSources`, its own depth and cutout pipeline, apart from its colour judgement and from
the picker). The frontmost is one quad of the adopted plan; the pick must be a hit on that quad's cell and
part, no hit for fog, and no hit over the clear colour. Every decided pixel of every rendering agrees. A
picker that answered the rearmost quad containing the pixel would fail at most of them (11,520 of 12,288
at each facing).

Every rendering and every arming waits until the residency generation has stopped moving with the view
idle (the view's demand resident and no terrain job, nothing retiring, the view's publication adopted and
prepared at the arena's current generation), so the image drawn is the one the picks answer from.

**Overlap and stale replacement.** The overlap is asserted on a host whose test-only completion hold is
set (owner decision S, #645 comment 6924532805): A's batch is held from its recording, B is adopted, and
A's four own chunks stay held by the ledger and the terrain GPU bank while a step observes A's batch
pending; the hold lets go, A's batch completes on its fence and its chunks retire. The timing is
hook-held, not natural. The stale replacement is causal: the replacement is held as its uploads end, a
far view moves the residency, its publication is refused, the kept image is judged, and the replacement
made again is judged.

The far lower background (a 250-level band) is qualified by the headless example "demands, retains and
draws a lower background far outside the camera's radius but inside the projected viewport": by owner
decision A (recorded in 7016919733) the native example was removed, and tying a drawn quad to the far
contributor is #710.

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
