# TRA-9-V2-A evidence: terrain views publish retained terrain

Issue #714. Code head `d58227f6` (the view lifecycle, quiet window w714k). Device: Apple M3 Max, MoltenVK (the
pinned driver). Contract: the graphics package's README, "Terrain views (TRA-9)".

| Check | Command | Result |
| --- | --- | --- |
| Native, surface-free target | `HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests -- --match 'terrain views'` | 1/1, the drawn revision covering 25,600 of 25,600 pixels, an edit drawn again, every chunk retired after the handback |
| Native, real window | the same with `-- --terrain-views-full` | 3/3: a window showing an M1 scene, whose metrics are not kept, keeps it when the first candidate is refused and after the close; a fresh window planned at its live geometry, each of zoom 0.5, 2 and 1 drawn as a new revision presented with that zoom (480 x 320 logical, 960 x 640 framebuffer); a drawn window whose observed framebuffer becomes zero, with no new frame, clears its demand through the production adapter and restores it |
| Headless | `bash tools/vulkan/run.sh test hetoimasia-lua-engine-graphics:test:lua-engine-graphics-tests -- --match 'terrain views (TRA-9 v2)'` | 71/71, every example bounded |

**Planning time (acceptance 4).** Budget: one refresh of a 60 Hz display, 16,666,667 ns. Before the planner moved
off the owner's thread (`7fcd3eb6`): 154,147,000 ns between two presentations' enqueues, 65,865,000 ns in one owner
step. At `d58227f6` (the real-window command above, one run): owner-thread planning (the reuse comparison and the
copies' run counts) 17,000 ns between two presentations and 8,000 ns in one owner step; the views' whole work on the
owner's thread (planning, camera, copies, builds, publication, retirement) 2,872,000 ns between two presentations and
1,420,000 ns in one owner step: within the budget.

**Admission (acceptance 2).** Default profile: 2 targets, 128 slots of 32 KiB, 16,384 quads, 8,192 pending spans,
512 copied regions, 131,072 input runs and intervals, 64 regions a request, 16 builds a step. Declared reservation
101,744,640 bytes. At `d58227f6`, a full default-profile view over the fixture arena: 4 chunks occupied; peak live
heap of the whole headless test process 4,735,520 bytes (`bash tools/vulkan/run.sh test
hetoimasia-lua-engine-graphics:test:lua-engine-graphics-tests -- --match "/terrain views (TRA-9 v2)/evidence/" +RTS
-T -RTS`, `max_live_bytes`). The copy census of the approved design (TRA-9 fixture, 320 x 240): 36 regions, 3,104
expanded runs at 1x; 164 regions, 15,504 runs at 0.125x.
