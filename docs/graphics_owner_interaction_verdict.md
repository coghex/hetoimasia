# Graphics-owner progress during macOS window interactions: VK-16's verdict

**Measured: during a Cocoa live resize and during a Cocoa menu-bar interaction
the graphics owner kept making present requests and observing present-fence
completion, on average every 13 ms and 17 ms respectively and never more than
21 ms apart, while the main thread was blocked.**

- **Live resize.** For the whole of a 14.55 s block of the main thread's native
  event call, with no owner turn in between, the owner made 1154 present
  requests. All 1154 present calls returned with the presentation enqueued, and
  the owner observed 1155 present fences signalled. The longest gap between two
  requests was 19.17 ms. The frames rendered 862 distinct scenes published by
  another thread. Meanwhile the owner built a replacement swapchain for the
  changing window about every 25 ms: 506 generations in the block.
- **Menu bar.** For a 23.47 s block, the owner made 1391 present requests, all
  1391 returned enqueued, and it observed 1390 present fences signalled. The
  longest gap between two requests was 20.87 ms, and each frame rendered a
  newer scene.

D-29 moved rendering to the graphics owner so that a Cocoa modal loop would not
leave a stale or stretched surface. For both modal loops, the request and
completion evidence this probe can collect now shows the owner kept presenting
throughout; whether the surface stayed fresh and unstretched is the visual
question below, which this evidence does not settle.

**Not proved by evidence: visible progress.** A present call's return proves
the request was admitted. A signalled present fence proves the presentation
engine finished with the image. Neither proves a frame reached the screen, and
no screen recording was retained. The owner, who performed the interactions,
reported that the colour "kept changing at the proper speed throughout" the
resize, with "no wobble, stretching or artifacts", adding that stretching is
hard to judge on a solid colour, and that "overall everything was expected and
responsive". That is recorded as the owner's observation, consistent with the
records, not as evidence of visible progress.

This is a Cocoa result. No Linux or X11 run substitutes for it, and none was
used.

## How it got here

The owner approved three sessions on 2026-09-28 and performed each one. Only
the first and third produced records.

1. **The first session, under P-15's original settling rule** (revision
   `340ade7`, MoltenVK 1.4.0). The menu held up, with 776 presents in a
   13.03 s block. The live resize did not. The owner rendered 12 frames, then
   **none for 15.44 s**, then 9, in a 23.62 s block. A resize waited for its
   geometry to be quiet for 16 ms before rebuilding, and acquired nothing
   meanwhile. Cocoa changed the framebuffer about every 8.5 ms throughout the
   drag, so the replacement never settled. The owner reported the window
   "mostly frozen" during the resize. That session's records are kept complete
   in [the first session's records](graphics_owner_interaction_evidence.md),
   and its numbers are summarized [below](#the-first-session).
2. **The owner's decision.** The finding was returned to the owner, who asked
   for research into rendering during a Cocoa live resize. Every reference
   implementation surveyed rebuilds as soon as the extent differs, with no
   quiet period: Khronos's `swapchain_recreation` sample, Sascha Willems's
   examples, Dear ImGui's GLFW/Vulkan example, wgpu, and Apple's custom Metal
   view sample. MoltenVK answers suboptimal, never out of date, while a window
   resizes, and its images still present, scaled to the layer. The owner chose
   to do both: coalesce a move for 16 ms from when it was first seen, then
   build from the newest geometry; and keep presenting from the active
   generation while its replacement waits. P-15 records the amendment in
   [the design](vulkan_backend_design.md#p-15-bound-admission-progress-and-recovery-explicitly).
3. **The second session, on MoltenVK 1.4.0** (revision `9a81266`). It failed in
   the resize phase: "the graphics session failed: a required target could not
   be recovered". The probe retains records only for a completed session, so
   none exist; this is the run's own output. In MoltenVK 1.4.0, creating a
   swapchain over one with a presentation still in flight sets the layer's
   drawable size to 1×1, as a workaround for a Metal completion regression.
   The new swapchain then answers suboptimal at the surface's own extent, and
   rebuilding it at that extent is a recovery attempt. Presenting while
   rebuilding makes such a presentation nearly certain, so three attempts
   spent the required target's episode. That cause is read from MoltenVK
   1.4.0's source (`MVKSwapchain::forceUnpresentedImageCompletion`), not from
   records. MoltenVK 1.4.2 fixed it ("Fix swapchain recreation giving 1x1
   drawables"), and the owner chose to raise the pin rather than work around
   it.
4. **The third session, the one this verdict states** (revision `4311ebc`,
   MoltenVK 1.4.2).

## Identities

| | |
| --- | --- |
| OS | macOS 26.7.1 (`25G313`), arm64, Apple M3 Max |
| Vulkan | loader 1.3.296 (`4654c4e2873b`), driver MoltenVK **1.4.2** (library `05df2d2145b9`; its manifest declares API 1.4.0, which is what the recorded identity prints as `MoltenVK 1.4.0 05df2d2145b9`), `VK_LAYER_KHRONOS_validation` 1.3.296 (`dc6b9c2fd7b6`) with synchronization validation, glslang 15.0.0 (`7167bc1261b1`); `vulkan` identity `c322bbe5d49b65df145c0f49e7d33a1397511e2191eb9c1bf91af87b6c1f0964` |
| GLFW | 3.4, static Cocoa build from `tools/native/glfw.pin`; native manifest `71e952bd370b32c04c4a21d17fa86fc3afea9a9ed1c49a77a0b46628958bbdb4` |
| Compiler | GHC 9.14.1, Cabal 3.18.1.0; Apple clang 21.0.0 (`clang-2100.3.34.2`) built the prefix |
| Measured revision | `4311ebc8bf3a109dac58d6960184bd26de21af8c` on `issue-232-compose-render-time-life`; source digest `4d2e0308ff404e13dcfe8abbdb1bbca329eafbf539f0ce1b2ea26226b491e9d5` |
| Prefix | A private prefix built for this session with `tools/native/native.py build` from the pin that names MoltenVK 1.4.2; its identities are the ones above |
| Loop | `runVulkanOwnerLoop` over `withVulkanOwnerHost`, one shown 640×480 window handed over as a required target |
| Pacing | `defaultHostConfig`: idle wait **0.100 s**; the model's default budgets: two frame slots, two live generations, the 5–100 ms poll backoff, and a 16 ms coalescing period for a resize |
| Scene | A thread other than the main one publishes a new scene every 16 ms; the owner clears each frame to a colour that moves with the scene's revision |
| Human approval | The owner was told what the run does to the desktop, approved each session before it ran on 2026-09-28, and performed the interactions |

## The approved command

Run by the owner, from the issue worktree, with the qualified toolchain and
the private prefix on the environment, exactly as written and nowhere else:

```bash
HETOIMASIA_NATIVE_SESSION=desktop HETOIMASIA_INTERACTION_PROBE_SECONDS=12 \
  HETOIMASIA_INTERACTION_PROBE_OUTPUT=<scratchpad>/graphics-owner-probe3.tsv \
  bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --interaction-probe
```

`--interaction-probe` is the child the suite's own example starts with the
parent's terminal. Running it directly is the same measurement without Hspec
around it. `HETOIMASIA_NATIVE_SESSION=desktop` authorized only that one
command. The owner's standing approval for native runs was not relied on: the
probe is interactive, and it ran because the owner asked for it and performed
the interactions. `HETOIMASIA_INTERACTION_PROBE_SECONDS` is what makes the
probe run at all. Without it the example is pending and opens no window, which
is how the required `test.vulkan-native` group meets it on both platforms.

## How it was measured

The session's bounded trace (`Hetoimasia.Runtime.GLFW.Trace`, the same storage
RR-4's probe used) stamps, from one monotonic clock:

- each main-thread owner turn's beginning;
- the native event call's entry and exit, with the seconds it asked for;
- each window callback as it is delivered;
- the update hook's entry and exit.

The graphics owner's frame observer records into the **same** trace, from the
owner's thread:

- each acquisition;
- each present request *before* its call;
- each present call's return, with what it enqueued;
- each present fence the owner's own poll observed signalled.

So a record the owner made while the main thread was blocked falls between that
block's `pump entered` and its `pump left`. Recording is one clock reading and
one non-blocking `IORef` update, and nothing is printed inside a measured
interval.

A present fence is observed when the owner polls it. During continuous
rendering that is every frame, so a fence record's instant is when the owner
saw the completion, never earlier than it happened.

**Every phase reported 0 lost and 0 faults**, and the session's records run
`1` to `52241` with no gap. So no number below is read from truncated evidence,
and no absence below is a missing record. Validation reported nothing.

Every record is retained in [the live-resize records](graphics_owner_interaction_evidence_resize.md),
complete and in order.

## What was measured

| Phase | Owner turns | Present requests | Present returns | Present-fence completions | Main-thread blocks ≥ 250 ms |
| --- | --- | --- | --- | --- | --- |
| idle baseline | 1918 | 708 | 708 | 707 | 0 |
| window move | 1882 | 713 | 713 | 713 | 0 |
| window resize | 448 | 1313 | 1313 | 1314 | 1: 14 550 ms |
| menu-bar interaction | 297 | 1504 | 1504 | 1503 | 1: 23 473 ms |

Twelve seconds of an idle window and of a window move each took about 1900
owner turns and about 710 frames, so neither blocked anything. RR-4's move
result holds with the owner rendering beside it.

### The live resize

The main thread entered a finite wait of 100 ms at +2678.622 ms and did not
return until +17 228.974 ms: **14 550.352 ms**. No owner turn began in between,
and 3451 callbacks were delivered from inside the call. 1724 of them were
framebuffer-size callbacks, a median 8.33 ms apart.

Inside it the owner:

1. made 1154 present requests, from +2690.398 ms to +17 221.082 ms, about 79 a
   second, with the longest gap between two consecutive requests
   **19.168 ms** and the median 15.2 ms;
2. had every one return enqueued: 884 `PresentationEnqueuedSuboptimal`, the
   swapchain no longer matching the resized layer, and 270
   `PresentationEnqueued`;
3. observed 1155 present fences signalled, one of them for a request made
   before the block;
4. rendered scenes `1584` through `2445`, 862 distinct revisions, each
   published by the scene thread while the main thread was blocked;
5. presented on generations `0` through `505` of the one target. A new
   generation's first request followed the previous one's by a median
   25.1 ms (90th percentile 41.0 ms), so each generation served a median of
   two frames. It answered no acquisition `pending`.

**Established:** request and completion progress at the display's rate for the
whole of a Cocoa live-resize tracking loop, with the swapchain rebuilt from the
surface's changing extent throughout, on the owner's own thread.

**Not established by evidence:** that the frames became visible, or at which
size. The owner reported that they did, with no visible artifact.

The capabilities extent path (D-30) is what made this possible. The main thread
published no observation during the block, so the last one the owner held was
the window's size before the drag. A replacement planned from that observation
would have had generation 0's extent and been no replacement at all, so the 505
replacements can only have been planned at extents the surface's capabilities
supplied (inferred; [see below](#what-is-measured-and-what-is-inferred)).
Nothing here needed the reserve callback record.

### The menu-bar interaction

The main thread entered a finite wait of 100 ms at +1890.126 ms and did not
return until +25 362.756 ms: **23 472.630 ms**, with no owner turn and 5
callbacks in between. Between those two records the graphics owner made 1391
present requests and 1391 present returns with the presentation enqueued, and
observed 1390 present fences signalled. The longest gap between two requests
was 20.865 ms. The frames rendered scenes `2558` through `3948`, 1391 distinct
revisions, all on generation `506`.

**Established:** request and completion progress at the display's rate for the
whole of a Cocoa menu tracking loop.

**Not established by evidence:** that the frames became visible. The owner
reported, of the first session, that the colour kept changing while the menu
was open.

### The first session

At revision `340ade7`, under the original settling rule and MoltenVK 1.4.0,
with the same probe and pacing:

| Phase | Owner turns | Present requests | Present returns | Present-fence completions | Main-thread blocks ≥ 250 ms |
| --- | --- | --- | --- | --- | --- |
| idle baseline | 1935 | 716 | 716 | 715 | 0 |
| window move | 1902 | 715 | 715 | 715 | 0 |
| window resize | 462 | 201 | 201 | 202 | 1: 23 624 ms |
| menu-bar interaction | 437 | 974 | 974 | 973 | 2: 13 033 ms and 754 ms |

The resize block carried 21 present requests: 12 on generation 0 in its first
0.18 s, then `AcquisitionPending PendingGeneration` 4071 times over a
**15 443.639 ms** gap, then 9 on generation 1 when the drag paused. The menu
block carried 776. Those records are in
[the first session's records](graphics_owner_interaction_evidence.md), and the
headless example `keeps the owner rendering and rebuilding through a live
resize that never pauses while the native event call is held` reproduces the
gap under the old rule (one present, no replacement) and its absence under the
new one.

## What is measured and what is inferred

**Measured, from the records:**

- the durations of the main thread's blocks, and that no owner turn began
  inside either;
- every present request, return and observed present-fence completion the
  owner made inside each, with instants;
- the generation each frame was presented on;
- the scene revision each frame rendered.

**Inferred, and labelled so:**

- The second session's failure cause is read from MoltenVK 1.4.0's source and
  release notes, and from the model's recovery rule. The probe retained no
  records of that session, and it was not reproduced on 1.4.0 to confirm it.
- That each replacement was planned from the capabilities' extent is inferred
  from the absence of observations and the number of generations. The probe
  does not record the reconciliation's planned extents.

**Not measured at all:** what reached the screen.

## Reproducing this

The probe is VK-16's example in `vulkan-native-tests`
([gpu_backend.md](gpu_backend.md#the-native-suite)). Run it only with the
owner's approval for that session, with the owner performing the interactions,
and size the phases so a person can see each instruction as it begins. A
blocked phase ends only when the person lets go, so the whole run is longer
than four times the seconds asked for.
