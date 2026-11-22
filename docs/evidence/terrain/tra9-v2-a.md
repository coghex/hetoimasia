# TRA-9-V2-A evidence: terrain views publish retained terrain

Issue #714. Code head `d3774e5a` (the settlement hand-off and post-bind upload exits, quiet window of 2026-11-22 03:35Z). Every row below ran once at that head. Device: Apple M3 Max, MoltenVK (the
pinned driver). Contract: the graphics package's README, "Terrain views (TRA-9)".

| Check | Command | Result |
| --- | --- | --- |
| Native, surface-free target | `HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests -- --match 'terrain views'` | 1/1, no window requested; the drawn revision covering 25,600 of 25,600 pixels, an edit drawn again, every chunk retired after the handback |
| Native, real window | the same with `-- --terrain-views-full` | 2/2: a window showing an M1 scene, whose metrics are not kept, keeps it when the first candidate is refused and after the close; a fresh window planned at its live geometry, each of zoom 0.5, 2 and 1 drawn as a new revision presented with that zoom (480 x 320 logical, 960 x 640 framebuffer). A target's observed zero, then unknown geometry with no new frame, its demand cleared and restored, runs headless on a held target, and the window adapter's mapping is a pure example |
| Headless | `bash tools/vulkan/run.sh test hetoimasia-lua-engine-graphics:test:lua-engine-graphics-tests -- --match 'terrain views (TRA-9 v2)'` | 97/97, every example bounded |
| Retained chunks | `bash tools/vulkan/run.sh test hetoimasia-render-2d-vulkan:test:render-2d-vulkan-tests -- --match 'Retained chunks'` | 52/52 |
| Native groups | `HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native` with `-- --complete`: `hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests`; `hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests`; `hetoimasia:test:run-native-tests` | 208 examples, 0 failures, 2 pending; 32/32; 59/59 |
| Native uploads | `bash tools/vulkan/run.sh test hetoimasia-gpu-vulkan-native:test:native-tests -- --match Uploads` | 38/38 |
| GLFW native | `HETOIMASIA_NATIVE_SESSION=desktop cabal test glfw-native-tests` | 163 examples, 0 failures, 25 pending |

**Planning time (acceptance 4).** Budget: one refresh of a 60 Hz display, 16,666,667 ns. Before the planner moved
off the owner's thread (`7fcd3eb6`): 154,147,000 ns between two presentations' enqueues, 65,865,000 ns in one owner
step. At `d3774e5a` (the real-window command above, one run): owner-thread planning (the reuse comparison and the
copies' run counts) 15,000 ns between two presentations and 6,000 ns in one owner step; the views' whole work on the
owner's thread (planning, camera, copies, part preparation, builds, publication, retirement) 2,201,000 ns between two
presentations and 1,102,000 ns in one owner step: within the budget.

**Admission (acceptance 2).** Default profile: 2 targets, 128 slots of 32 KiB, 16,384 quads, 8,192 pending spans,
512 copied regions, 131,072 input runs and intervals, 64 regions a request, 16 builds a step. Declared reservation
101,744,640 bytes. A full default-profile view over the fixture arena: 4 chunks occupied; peak live
heap of the whole headless test process 4,229,392 bytes (`bash tools/vulkan/run.sh test
hetoimasia-lua-engine-graphics:test:lua-engine-graphics-tests -- --match "/terrain views (TRA-9 v2)/evidence/" +RTS
-T -RTS`, `max_live_bytes`). The copy census of the approved design (TRA-9 fixture, 320 x 240): 36 regions, 3,104
expanded runs at 1x; 164 regions, 15,504 runs at 0.125x.

**CI intermittents (outside this change's diff, each noted and not fixed; the rerun of the failed jobs is a separate
result).** Run 44966322928 attempt 1, `test.scripting-lua-runtime`: "the Lua runtime adapter / Opt-in admission / the
settlement seam and the declining hand-off / judges a prepared reply when it is evaluated, outside any transaction, and
settles it in the caller's transaction without judging it again", seed 317395274: expected `(0,ReplySettled,1)`, got
`(14,ReplySettled,15)`; 1,184 examples, 1 failure (#720). Attempt 2 passed. Run 44971235617 attempt 1,
`test.terrain-runtime`: "Storage backend: the live-heap reading's noise floor / is measured, with nothing between two
readings and around a change that leaves nothing", seed 1185987298: `ErrorCall` "a bounded test call never returned"
(`Test.Support.Bounded`); 1,786 examples, 1 failure. Attempt 2 passed.
