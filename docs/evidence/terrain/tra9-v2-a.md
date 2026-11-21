# TRA-9-V2-A evidence: terrain views publish retained terrain

Issue #714. Code head `34509273` (round 4's repairs, quiet window w714g). Device: Apple M3 Max, MoltenVK (the pinned
driver). Contract: the graphics package's README, "Terrain views (TRA-9)".

| Check | Command | Result |
| --- | --- | --- |
| Native, surface-free target | `HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests -- --match 'terrain views'` | 1/1, the drawn revision covering 25,600 of 25,600 pixels, an edit drawn again, every chunk retired after the handback |
| Native, real window | the same with `-- --terrain-views-full` | 1/1, opened directly on a fresh window (planned at its live geometry); each of zoom 0.5, 2 and 1 drawn as a new revision presented with that zoom (480 x 320 logical, 960 x 640 framebuffer) |
| Headless | `bash tools/vulkan/run.sh test hetoimasia-lua-engine-graphics:test:lua-engine-graphics-tests -- --match 'terrain views (TRA-9 v2)'` | 52/52, every example bounded |

**Planning time (acceptance 4).** Budget: one refresh of a 60 Hz display, 16,666,667 ns. Before the planner moved
off the owner's thread (`7fcd3eb6`): 154,147,000 ns between two presentations' enqueues, 65,865,000 ns in one owner
step. At `34509273` (the real-window command above): owner-thread planning (the reuse comparison and the copies' run
counts) 416,000 ns between two presentations and 286,000 ns in one owner step; the views' whole work on the owner's
thread (planning, camera, builds, publication, retirement) 3,599,000 ns between two presentations and 1,661,000 ns in
one owner step: within the budget.

**Admission (acceptance 2).** Default profile: 2 targets, 128 slots of 32 KiB, 16,384 quads, 8,192 pending spans,
512 copied regions, 131,072 input runs and intervals, 64 regions a request, 16 builds a step, 3 copy rounds. Declared
reservation 101,744,640 bytes. At `34509273`, a full default-profile view over the fixture arena: 6 chunks occupied;
peak live heap of the whole headless test process 4,739,480 bytes (`bash tools/vulkan/run.sh test
hetoimasia-lua-engine-graphics:test:lua-engine-graphics-tests -- --match "/terrain views (TRA-9 v2)/evidence/" +RTS
-T -RTS`, `max_live_bytes`).
