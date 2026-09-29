# The first windowed Vulkan backend: the milestone's verdict

**Met, on both platforms: an independent application renders a triangle in
each of two GLFW windows sharing one Vulkan device on macOS and on Linux; each
window resizes on its own and the first-created window's closure leaves the
other rendering; one- and two-frame-slot configurations both work; and the
required native profile completes well inside its 30-second budget on each
platform, with no validation error and no incomplete diagnostic capture.**

This is epic [#155](https://github.com/coghex/hetoimasia/issues/155)'s verdict,
recorded by its last slice, VK-17
([#233](https://github.com/coghex/hetoimasia/issues/233), pull request
[#302](https://github.com/coghex/hetoimasia/pull/302)). Each of the epic's
Done-when items is listed below with the retained evidence that satisfies it.
Nothing here is re-measured that an earlier slice already recorded: the Cocoa
stall evidence in particular is linked, with the limits it states, and not
repeated.

## The inputs

| | macOS (local) | Linux (remote CI) |
| --- | --- | --- |
| Where | the owner's machine, Cocoa, under the owner's standing desktop approval | the `vulkan` worker of run [36519341685](https://github.com/coghex/hetoimasia/actions/runs/36519341685), inside the published CI image, on an isolated X11 display |
| Driver | MoltenVK 1.4.2's library (`MoltenVK 1.4.0 05df2d2145b9`, the manifest's declared API) | Mesa Lavapipe, `lvp 1.4.318 9d69cae2004b` |
| Validation layer | `VK_LAYER_KHRONOS_validation 1.3.296 dc6b9c2fd7b6 +synchronization` | `VK_LAYER_KHRONOS_validation 1.3.275 1d486283e4ce +synchronization` |
| Executed | `fc8bfe0`, input identity `14437135…` | the merge candidate `5697a5c` of head `2040d1d`, input identity `2cb159e4…` |
| Record | [`docs/vulkan/macos-vk17.md`](vulkan/macos-vk17.md) | [`docs/vulkan/linux-vk17.md`](vulkan/linux-vk17.md) |

Both records carry their receipts verbatim, with the toolchain map each run
recorded; the macOS one names no CI image and records `Darwin`, so neither can
stand in for the other.

## The required profile

`test.vulkan-native` runs the whole native suite, and VK-17's required profile
is two of its private scenarios, `vk17-one-slot` and `vk17-two-slots`: the
triangle sample's own drawing through the production host with verification
capture on, over two mapped windows that request no focus, with a frame budget
of one slot and of two. In each, both windows are captured; the first is
resized through its command port and captured at its new generation's extent;
and the first-created window is closed and, once its target has retired, the
second is captured again. Every captured frame is checked at a clear-background
point and at the triangle's centroid within 6 per channel — never a
whole-image hash — beside that frame's own verified acquisition, submission,
presentation and present-fence retirement.

| | macOS | Linux |
| --- | --- | --- |
| Selection | 121 examples, 0 failures, 1 pending | 121 examples, 0 failures, 1 pending |
| Native execution (the 30 s watchdog's measure) | 5.3 s | 3.97 s |
| `vk17-one-slot` / `vk17-two-slots` | 0.33 s / 0.33 s | 0.30 s / 0.28 s |
| Captured frames | 8, every one clear (63, 63, 124, 255), triangle (243, 203, 89, 255) | 8, every one clear (63, 63, 124, 255), triangle (243, 203, 89, 255) |
| The resized window | captured at 400×300, from 320×240 | captured at 200×150, from 160×120 |
| Verdict after the last callback | no issue, no error report | no issue, no error report |

The pending example on both is the graphics-owner interaction probe, which
needs a person at the desktop and runs only when activated. The budget is one
aggregate for the whole selection — both frame-slot configurations and every
inherited case, with test-owned display, fixture and teardown included — and
the build, including the sample's executable, is measured apart in the
preparation stage.

## The sample, launched

The sample is launched explicitly and nothing routine runs it. On 2026-09-29
the owner launched it once on the macOS desktop, with validation on, in this
session, resized one window, minimized and restored one, closed the
first-created window and then the second. Asked what they observed, the owner
answered: "All as expected" — the option that read "Two windows, each an orange
triangle on a dark blue clear; resize, minimize/restore and closing the first
worked, the second kept rendering, and it exited with a clean verdict." That is
recorded as the owner's observation, not as recorded visual evidence; the
captured frames above are the evidence. Earlier launches in the same session,
timed with `--seconds`, printed each window's presented frames — 476 per
window over four seconds with one frame slot, and 357 over three seconds with
two — and a clean verdict, and those counts measure nothing about refresh cadence.

## The epic's Done-when, item by item

1. **All nineteen children are filed and completed, with code, contracts and
   required evidence together in each implementation pull request.** VK-1
   through VK-19 are filed, [the design's processing status](vulkan_backend_design.md#processing-status)
   links each, and every one but VK-17 was closed by its merged pull request;
   VK-17 is closed by #302, which carries its code, its contract documents and
   both platforms' evidence. VK-19 ([#299](https://github.com/coghex/hetoimasia/issues/299))
   was added on 2026-09-28, when no slice had assigned exposing managed
   construction and capture through the composed host.
2. **Pinned native and build identities are reproduced through local
   provisioning and the Linux image; missing or changed inputs cannot reuse
   incompatible evidence; CPU and window-only builds stay independent.** The
   provisioned prefixes are qualified in [`linux-provisioned.md`](vulkan/linux-provisioned.md)
   and [`macos-provisioned.md`](vulkan/macos-provisioned.md) against
   [the toolchain record](toolchain.md); every receipt binds its input identity
   and toolchain map ([validation.md](validation.md#receipts)), and a Darwin
   receipt names no CI image. `cabal build all` and `cabal build all
   --project-file cabal.project.cpu` build the same package set as before #302
   and resolve no binding, and the workflow suite's Vulkan project boundary
   holds the native, integration and sample packages to `cabal.project.vulkan`
   alone.
3. **The same tested VK-18 machinery runs the Vulkan owner; bounded ports,
   stop and terminal evidence, deadline independence, failed startup,
   cancellation and protected join order are proved; main-thread GLFW ownership
   is preserved.** [The supervised graphics owner](glfw.md#the-supervised-graphics-owner)
   (VK-18, #218) is the machinery [the composition](gpu_backend.md#composition)
   supplies its Vulkan operations to; its examples are in `glfw-tests` and the
   integration's `integration-tests`. In the required profile every Vulkan call
   ran on the graphics owner's thread and every surface was created on the main
   thread, on both platforms.
4. **Two windows render verifiable triangle images on both profiles, resize
   independently, and survive first-window closure with shared roots intact;
   one- and two-frame-slot configurations work.** The required profile above,
   on both platforms and in both configurations: the resized window's capture
   is at its new extent while the other window's stays at its own, and the
   second window's capture after the first-created window's retirement comes
   from the same session's roots and device. The owner's observation of the
   launched sample agrees.
5. **Actual submission and presentation obligations govern retirement;
   explicit skip and submitted-but-unpresented exits do not invent completion
   or replay consumer effects; unknown safety keeps parents live; all-exit
   cleanup preserves the initiating failure and additional evidence.** VK-12
   and VK-13 ([#225](https://github.com/coghex/hetoimasia/issues/225),
   [#227](https://github.com/coghex/hetoimasia/issues/227)): the
   [frames](gpu_backend.md#frames-acquisition-submission-and-abandonment) and
   [presentation and retirement](gpu_backend.md#presentation-and-retirement)
   contracts, with native evidence in [`macos-vk12.md`](vulkan/macos-vk12.md),
   [`linux-vk12.md`](vulkan/linux-vk12.md), [`macos-vk13.md`](vulkan/macos-vk13.md)
   and [`linux-vk13.md`](vulkan/linux-vk13.md); VK-15's
   [terminal failure](gpu_backend.md#terminal-failure) keeps the primary. Every
   frame the required profile captured retired on its own present fence.
6. **Bounded recovery preserves healthy targets and applies required and
   optional failure policy; lost devices are not automatically recreated; final
   validation and diagnostic failures reach the verdict.** VK-14
   ([#229](https://github.com/coghex/hetoimasia/issues/229)),
   [recovery](gpu_backend.md#recovery), with [`macos-vk14.md`](vulkan/macos-vk14.md)
   and [`linux-vk14.md`](vulkan/linux-vk14.md); VK-15
   ([#231](https://github.com/coghex/hetoimasia/issues/231)), whose
   `vk15-validation-stop` case, in both platforms' runs above, stops at the
   checkpoint after an injected validation error with that error in the
   verdict ([`macos-vk15.md`](vulkan/macos-vk15.md), [`linux-vk15.md`](vulkan/linux-vk15.md)).
   No device loss was induced natively, as [the compatibility record](vulkan_compatibility_record.md)
   states; device loss is specification evidence and the headless examples'.
7. **Retained Cocoa resize and menu records establish the claimed graphics
   progress while the main owner turn is stalled, separating present requests,
   completion and any visible-frame evidence; a present return alone is
   insufficient; the consented probe stays outside routine groups.** Linked,
   not re-measured: [VK-16's interaction verdict](graphics_owner_interaction_verdict.md)
   measured the graphics owner presenting through a 14.55 s live resize and a
   23.47 s menu-bar block on its request and present-fence completion records,
   and states plainly that **visible progress is not proved by evidence** — the
   owner's report that the colour kept changing is recorded there as an
   observation, and this verdict upgrades none of it. It also does not claim
   GLFW command, observation, simulation or input progress, which still wait for
   the main thread's pump. The earlier measurement it builds on is
   [the owner loop's interaction verdict](owner_loop_interaction_verdict.md).
   The probe runs only when activated, and is the one pending example in both
   runs above.
8. **The final required native profile completes in under 30 seconds on each
   platform, including test-owned setup and teardown, with nonempty applicable
   selections, no validation errors or incomplete diagnostic capture, and
   separate local macOS and remote Linux evidence.** 5.3 s on macOS and 3.97 s
   on Linux, for 121 examples each, with clean verdicts, in
   [`macos-vk17.md`](vulkan/macos-vk17.md) and
   [`linux-vk17.md`](vulkan/linux-vk17.md). The budget was not infeasible, so
   nothing returned to the owner, and no case was dropped or made optional to
   fit it.
9. **Builds remain warning-clean; required headless suites initialize no GLFW,
   display or device.** Every build `-Werror`s its local packages; the headless
   group `test.vulkan-headless` — `native-tests`' 312 examples, `shader-tests`'
   14 and `integration-tests`' 91 — passed in both runs and reads no consent,
   and its suites run over stand-ins.

## What this does not claim

- No refresh cadence, vertical blank or frame pacing: nothing is inferred from
  MoltenVK, Lavapipe or Xvfb timing, and the sample's frame counts measure none
  of it.
- No visible-frame evidence beyond the captured frames: the Cocoa stall
  verdict's limits stand as it states them.
- No induced device loss on either native profile.
- No scene graph, camera, assets, 2D or 3D renderer: the sample is an
  architecture check and an example.
