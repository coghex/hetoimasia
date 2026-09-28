# Graphics-owner progress during macOS window interactions: VK-16's verdict

**Measured: during a Cocoa menu-bar interaction the graphics owner kept
rendering at the display's rate while the main thread was blocked.** For the
whole of a 13.03 s block of the main thread's native event call, with no owner
turn in between, the owner made 776 present requests, all 776 present calls
returned with the presentation enqueued, and it observed all 776 present fences
signalled — about 60 a second, each frame a newer scene published by a thread
other than the main one.

**Measured, and returned to the owner: during a Cocoa live resize it did not.**
For a 23.62 s block of the same call the owner rendered 12 frames on the old
swapchain in the first 0.18 s, then **none for 15.44 s**, then 9 on a new
swapchain built while the person paused, then none for the remaining 7.88 s.
The swapchain's presentation answered suboptimal as the resize began; from then
on the target stayed *settling* — P-15's rule that a resize waits for its
geometry to be quiet for 16 ms before rebuilding — because Cocoa delivered a
framebuffer change about every 8.5 ms throughout the drag, and while a target
is settling the frames layer acquires nothing from it. So D-29's aim of
removing the stale or stretched surface during a live resize **is not met by
the delivered composition under P-15's settling policy**, and this verdict does
not declare D-29 proved. What to do is [the owner's](#what-the-owner-has-to-decide).

**Not proved: visible progress.** A present call's return proves the request
was admitted, and a signalled present fence proves the presentation engine
finished with the image; neither proves a frame reached the screen, and no
screen recording was retained. The person who performed the interactions
reported that the window's colour **kept changing while the menu was open** and
stayed **mostly frozen while dragging the resize**. That is recorded as their
observation, consistent with the records, and not as evidence of visible
progress.

This is a Cocoa result. No Linux or X11 run substitutes for it, and none was
used.

## Identities

| | |
| --- | --- |
| OS | macOS 26.7.1 (`25G313`), arm64, Apple M3 Max |
| Vulkan | loader 1.3.296 (`e06fb20c74be`), driver MoltenVK 1.4.0 (`6e9ec5b29689`), `VK_LAYER_KHRONOS_validation` 1.3.296 (`dc6b9c2fd7b6`) with synchronization validation, glslang 15.0.0 (`7167bc1261b1`); `vulkan` identity `7649fd77acafd8617de5731e9c2f333b90fa2172367c1ef7d36c0d426bb7d718` |
| GLFW | 3.4, static Cocoa build from `tools/native/glfw.pin`; native manifest `31eb8773c4a115276a97b77e2e7ff8f35772804831b00037abc863cee822388b` |
| Compiler | GHC 9.14.1, Cabal 3.18.1.0; Apple clang 21.0.0 (`clang-2100.3.34.2`) built the prefix |
| Measured revision | `340ade7808984db601c8b08a57d0ab290a5ac8a6` on `issue-232-compose-render-time-life`, off `master@a6e7582`; source digest `3cadd4a2eab7cd468176aa4ed23ab3e54bc536c54c58290e59fd54f6650016a2` |
| Prefix | A private prefix built for this session with `tools/native/native.py build`, because the shared one predates the machine's Command Line Tools; its identities are the ones above |
| Loop | `runVulkanOwnerLoop` over `withVulkanOwnerHost`, one shown 640×480 window handed over as a required target |
| Pacing | `defaultHostConfig`: idle wait **0.100 s**; the model's default budgets: two frame slots, the 5–100 ms poll backoff, a 16 ms settling period |
| Scene | A thread other than the main one publishes a new scene every 16 ms; the owner clears each frame to a colour that moves with the scene's revision |
| Human approval | The owner was told what the run does to the desktop and approved this session before it ran, on 2026-09-28, and performed the interactions. One session was approved and run. |

## The approved command

Run by the owner, from the issue worktree, with the qualified toolchain and
the private prefix on the environment, exactly as written and nowhere else:

```bash
HETOIMASIA_NATIVE_SESSION=desktop HETOIMASIA_INTERACTION_PROBE_SECONDS=12 \
  HETOIMASIA_INTERACTION_PROBE_OUTPUT=<scratchpad>/graphics-owner-probe.tsv \
  bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --interaction-probe
```

`--interaction-probe` is the child the suite's own example starts with the
parent's terminal; running it directly is the same measurement without Hspec
around it. `HETOIMASIA_NATIVE_SESSION=desktop` authorized only that one
command, and the owner's standing approval for native runs was not relied on:
the probe is interactive, and it ran because the owner asked for it and
performed the interactions. `HETOIMASIA_INTERACTION_PROBE_SECONDS` is what
makes the probe run at all; without it the example is pending and opens no
window, which is how the required `test.vulkan-native` group meets it on both
platforms.

## How it was measured

The session's bounded trace (`Hetoimasia.Runtime.GLFW.Trace`, the same storage
RR-4's probe used) stamps, from one monotonic clock: each main-thread owner
turn's beginning; the native event call's entry and exit, with the seconds it
asked for; each window callback as it is delivered; and the update hook's entry
and exit. The graphics owner's frame observer records into the **same** trace,
from the owner's thread, each acquisition, each present request *before* its
call, each present call's return with what it enqueued, and each present fence
the owner's own poll observed signalled — so a record the owner made while the
main thread was blocked falls between that block's `pump entered` and its
`pump left`. Recording is one clock reading and one non-blocking `IORef` update;
nothing is printed inside a measured interval.

A present fence is observed when the owner polls it, which during continuous
rendering is every frame, so the fence record's instant is when the owner saw
the completion, never earlier than it happened.

**Every phase reported 0 lost and 0 faults**, and the session's records run
`1` to `49611` with no gap, so no number below is read from truncated evidence,
and no absence below is a missing record. Validation reported nothing.

Every record is retained in [the records](graphics_owner_interaction_evidence.md),
complete and in order.

## What was measured

| Phase | Owner turns | Present requests | Present returns | Present-fence completions | Main-thread blocks ≥ 250 ms |
| --- | --- | --- | --- | --- | --- |
| idle baseline | 1935 | 716 | 716 | 715 | 0 |
| window move | 1902 | 715 | 715 | 715 | 0 |
| window resize | 462 | 201 | 201 | 202 | 1: 23 624 ms |
| menu-bar interaction | 437 | 974 | 974 | 973 | 2: 13 033 ms and 754 ms |

Twelve seconds of an idle window and of a window move each took about 1900
owner turns and about 715 frames, so neither blocked anything: RR-4's move
result holds with the owner rendering beside it.

### The menu-bar interaction

The main thread entered a finite wait of 100 ms at +3334.368 ms and did not
return until +16367.020 ms: **13 032.652 ms**, with no owner turn and no
callback in between. Between those two records the graphics owner made 776
present requests, 776 present returns with the presentation enqueued, and
observed 776 present fences signalled; the longest gap between two requests was
18.48 ms. The frames rendered scenes `3219` through `3994`, 776 distinct
revisions, each published by the scene thread while the main thread was
blocked. A shorter block at +1064.448 ms, 753.590 ms long with the two
callbacks of opening the menu, carried 45 of each.

**Established:** request and completion progress at the display's rate for the
whole of a Cocoa menu tracking loop. **Not established by evidence:** that the
frames became visible; the person reported that they did.

### The live resize

The main thread entered a finite wait of 100 ms at +3031.782 ms and did not
return until +26656.193 ms: **23 624.411 ms**, with no owner turn and 5591
callbacks delivered from inside the call — 2794 of the whole phase's were
framebuffer-size callbacks, about 118 a second.

Inside it the owner:

1. rendered 12 frames on generation 0 at the window's old extent, scenes
   `1614`–`1625`, until the present at +3215.428 ms answered
   `PresentationEnqueuedSuboptimal`;
2. from +3232 ms answered every frame the scenes asked for with
   `AcquisitionPending PendingGeneration` — 4071 times in the phase — because
   the target's generations were *settling*: each reconciliation found the
   extent the surface's capabilities supplied had changed again within the
   16 ms settling period, so the replacement was never built and the frames
   layer, which acquires only from a target that is presenting, acquired
   nothing;
3. at +18 659 ms, when the drag paused long enough, built generation 1 at the
   extent the capabilities then supplied and rendered 9 frames on it, scenes `2544`–`2552`,
   with their present fences observed;
4. then settled again, and rendered nothing more until the person let go.

The longest gap between two present requests inside the block is
**15 443.639 ms**. Every present request that was made returned enqueued and
had its present fence observed signalled — there is no case here of queued
requests without completion — but for most of the resize no request was made at
all.

**Established:** a live resize on Cocoa starves the owner's rendering under the
settling policy as delivered, because the framebuffer changes faster than the
settling period. **Not shown:** that D-30's capabilities extent path is
insufficient. The main thread published no observation during the block, so the
last one the owner held was the window's size before the drag; a replacement
planned from it would have had generation 0's extent and been no replacement at
all. Generation 1 was planned at a different extent, which only the surface's
capabilities could have supplied — and the settling rule compares exactly those
successive extents. Nothing here needed the reserve callback record.

## What is measured and what is inferred

Measured, from the records: the durations of the main thread's blocks; that no
owner turn began inside either; every present request, return and observed
present-fence completion the owner made inside each, with instants; the
acquisition answers during the resize; and the scene revision each frame
rendered.

Inferred, and labelled so: that the resize's settling never completed because
the extent kept changing — the records show the pending answers and the
framebuffer callbacks' rate, not the reconciliation's own condition, which the
probe does not record; the `vk16-composed` native case and the headless
examples prove the policy that produces it.

Not measured at all: what reached the screen.

## What the owner has to decide

D-29 moved rendering to the graphics owner so that a Cocoa modal loop would
not leave a stale or stretched surface. The menu case shows the owner doing
exactly that. The resize case shows P-15's settling rule, applied to the only
target being resized, undoing it. The alternatives, none of which this pull
request implements:

1. **Keep presenting to the active generation while a resize settles.** A
   swapchain that answered suboptimal still presents; the frames would be
   scaled to the new window until the replacement is built. This changes the
   frames layer's rule that it acquires only from a presenting target, and
   trades a frozen surface for a stretched one.
2. **Rebuild during a live resize without waiting for quiet**, bounded by
   D-18's generation budget: at the rate Cocoa changes the framebuffer this
   rebuilds on nearly every frame, retiring each generation on its present
   fence.
3. **Shorten, or adapt, the settling period** — to about one frame interval, or
   to the rate at which the capabilities' extent actually changes — which is
   P-15's to change with a documented reason.
4. **Accept the frozen surface during a live resize** and record it as a
   known limitation of D-29 on Cocoa.

D-30's reserve callback record is not among them: nothing here showed the
capabilities path insufficient.

## Reproducing this

The probe is VK-16's example in `vulkan-native-tests`
([gpu_backend.md](gpu_backend.md#the-native-suite)). Run it only with the
owner's approval for that session, with the owner performing the interactions,
and size the phases so a person can see each instruction as it begins; a
blocked phase ends only when the person lets go, so the whole run is longer
than four times the seconds asked for.
