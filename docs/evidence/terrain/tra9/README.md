# TRA-9 evidence: terrain views

Issue #645. The judged results of the terrain-view adapter on a real device and the headless
examples that stand for the rest. The contract is the graphics package's README ("Terrain views")
and terrain-runtime's README (the precondition guard, the outside staging account).

| | |
| --- | --- |
| Device | Apple M3 Max, MoltenVK (the pinned Homebrew driver), surface-free targets with a `D32_SFLOAT` depth image |
| Final code | `005653c3` (review round 8). Every run below is at `f05a589f` in the strict window w645t unless it names `005653c3`; the one change between them is in the headless suite alone (its reads of the adopted plan are forced inside the reader, review 7042883412), and that suite was run once again at `005653c3`. The native suite's code is the same at both heads |
| Renderings | captured at `f05a589f` in w645t, after the native suite's reads of the adopted plan were moved inside the reader; the pixel and pick tables below are for that head (each rendering's counts equal round 7's) |
| Effective spec | `758dc5c3`, approved in review 7042883412: the atlas amendment 6731831183 as amended by reviews 6731944497, 6908703832, 6909126590, 6924738094, 7017099664, 7017281625, 7020912271, 7024627413 and 7031547736; the comments 6908430167, 6909009968, 6924532805 (the overlap's completion hold), 7016919733, 7017110545, 7020752728, 7024520210 (flaky examples are recorded and moved), 7031377779 (the approved design `docs/designs/terrain_view_service_design.md`) and 7042721491 (the guarantee covers trusted in-engine callers; the round-7 split) |
| Moved out | #706 (a camera tail the terrain service cut, asked again by an idle view); #709 (progress under a binding bound: whole-unit publication under the renderer's record window, a partial plan's continuation, a distant jump under the cap, multi-turn builds, and a preparation the account binds); #710 (stronger witnesses: the record window against the recorder and its diagnostic, the far background tied to a drawn quad, every pixel accounted, the intent on the adopted plan, the native suite's focused selection, item 7, a release that did not run beside another view's retirements, and the quiet-projection witness, issuecomment-7043805583); #711 (headless examples that ran past their bound or attempt limit under load); #712 (terrain-runtime's store allocation-ratio example under load); #713, by comment 7042721491, eight behaviours outside the trusted-caller guarantee that no example here judges: a window target's issuer taken from its host argument, style parents from another session, `Word64` overflow in granule rounding, lazy `readView` and `viewDemand` readings, a retained precondition's reach, the whole-ledger and registry reads of retirements and uploads, attachment priority over ordinary work, and a per-view terminal cause |

## Results

| Run | Command | Result |
| --- | --- | --- |
| Required native witness | `bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests -- --complete` | 33/33 in 10.85 s on the terrain-disabled host (the quiet-worker example included); 4/4 in 3.12 s on the terrain-enabled host; 13.97 s of test time, 21 s wall, under the 30 s rule (`docs/vision.md:272`) |
| Focused native selection | the same suite with `-- --match "terrain views"` | 2/2 in 3.42 s: "draws the adopted world into a surface-free target with its depth image, keeps drawing it across the Lua handles' release and an edit, and hands back a real empty revision" and "keeps an idle view's worker asleep while the host's owner adopts another target's publications" |
| Full qualification | the same suite with `-- --terrain-views-full` | 13/13 in 29.36 s, then the overlap witness on its own held host, 1/1 in 5.69 s; every pixel judged, 0 failed; every pick exact; synchronization validation clean (64 records) |
| Headless | `bash tools/vulkan/run.sh test` (the `test.vulkan-headless` set) | at `f05a589f`, every suite passed (`lua-engine-graphics-tests` 449, `integration-tests` 212); at `005653c3`, `lua-engine-graphics-tests` 449/449 and its `--match "terrain views"` selection 129/129 |
| Every other group the planner selects on macOS (w645t) | as `tools/validation/catalog.json` names them | at `f05a589f`, each once, all passed: engine 159, foundation 489, runtime 243, glfw 1097, lua host 642, lua runtime 1184, lua domains 418, gpu model 277, diagnostics 84, math 128, terrain 920, terrain-render-2d 559, terrain-runtime 1796, lua-engine 1574, content 520 (5 pending), asset-image 1413, render-api 19, render-2d 544, oracle 219, run-native 59, vulkan-native 208 (2 pending), glfw-native 163 (25 pending), workflow 965. The two Wayland groups are Linux-only: CI |

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

## Removed examples

Each was removed from the suite, never rerun, and is recorded with its follow-up; the final counts do not include it.
The command of the first four is `bash tools/vulkan/run.sh test hetoimasia-lua-engine-graphics:test:lua-engine-graphics-tests`
with `--match` the path given; the bound is the suite's example bound, 15 s, unless named.

| Example (`--match` path) | Failed | Removed under | Follow-up |
| --- | --- | --- | --- |
| `/terrain views/eviction/keeps publishing while another holder loads a region at every step of a panning camera: at most two attempts per publication/` | 21 attempts against 20, seed 689505196 (CI run 44620294984 at `9bbd7e0a`); 21, seed 1398494402 (local, `6d306f02`); 21, seed 279248281 (CI run 44641923134 at `638f4187`); 22, seed 1096541889 (CI run 44661948923 at `455d86ef`) | item 3 of 7024520210; the design's eviction witnesses in #711 | #711 |
| `/terrain views/eviction/keeps every region of the view's visible demand resident while another holder's demand evicts others, the far background included/` | bound expired, seed 928086029 (local w645r series at `cdc34252`); seed 689505196 (CI run 44620294984 at `9bbd7e0a`); seed 1096541889 (CI run 44661948923 at `455d86ef`) | item 3 of 7024520210; the design's eviction witnesses in #711 | #711 |
| `/terrain views/a pick's consistency reference/refuses a pick's removal once a load moves the residency generation, and removes through one picked from the revision made at the new generation/` | bound expired, seed 1402948167 (local w645s at `bd3f6f7d`); seed 2126882287 (CI 44691869860 at `ffde9cfe`) | item 3 of 7024520210 | #711 |
| `/terrain views/stages, waits and readers/keeps a release that did not run as evidence with its charges, and goes on retiring another view's regions/` | bound expired, seed 928086029 (local w645r series at `cdc34252`); seed 1386309823 (local, `c1f08f99`) | items 1 and 2 of 7024520210 | #710 item 7 |
| `/Offscreen scene targets (LFE-27)/registration and publication/keeps its room, release-lane room, settled-upload and owner-end projections unwritten by owner rounds that adopt publications, and writes them when an action is queued/` (`hetoimasia-gpu-vulkan-glfw:test:integration-tests`) | no failed run: removed on round 7's finding that it read the watcher's count without its acknowledgement | 7042721491 | #710, issuecomment-7043805583 |

What the removals leave unwitnessed, judged by the pull request's review with no example counted: a release
that does not run keeps its region's failure and charges while other retirements go on (`retireSettled`); a
pick's removal refused once the residency generation moved (the remaining removal examples refuse it after
another edit, a newer adoption, a revoked target and a resize, none after a load alone); and the owner's
action, release-lane, settled-upload and owner-end projections written on change only.

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
and picks. That the view's visible demand, far background included, stays resident under another
holder's pressure is #711: its example's bound rested on the run's timing and was removed.

## Files

`full/` holds, for each rendering of the full qualification, the lossless readback (`<name>.png`) and
the oracle comparison (`<name>.json`: revision, view, plan, framebuffer, chunks, passed, failed,
indeterminate, clear pixels, the judge and the completion). The CI receipt of the required native
group is in the pull request's body.
