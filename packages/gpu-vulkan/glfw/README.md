# Vulkan window integration

Buildable package: `hetoimasia-gpu-vulkan-glfw`, in `packages/gpu-vulkan/glfw`.

The one package that depends on both the native Vulkan backend
([`../native`](../native/README.md)) and the GLFW package. It composes three
delivered contracts and replaces none of them: the native backend's roots, the
GLFW package's supervised graphics owner (VK-18), and its surface bridge
(VK-5). Neither of those packages depends on this one. VK-16 adds the loop
adapter and the owner's rendering here, and VK-19 the consumer's construction
and the suites' verification capture.

- `Hetoimasia.GPU.Vulkan.GLFW` is the public interface. `withVulkanOwnerHost`
  composes, in the order the backend design's P-5 fixes, the diagnostic
  lifetime, the loader-aware session, and the protected window host with its
  graphics owner, whose operations are this package's controller.
  `handOverVulkanTarget` creates one window's surface through GLFW on the main
  thread, inside that window's attachment, and hands it to the owner as a
  required or optional target — or, once the session has failed, refuses naming
  its primary failure. `readVulkanTerminal` reads the session's terminal latch:
  that primary, the device's loss if it was observed, and what teardown found
  and retained beside it. `replaceVulkanSurfaces` creates, on the main
  thread, the replacement surface the owner asked for to recover a lost one,
  under the same attachment (VK-14); `readVulkanUnavailability` reports an
  optional target that could not be recovered, and a required one fails the
  session with `VulkanRequiredTargetFailed`. `runVulkanOwnerLoop` is the main
  thread's scheduled owner loop with the graphics owner composed in: every turn
  it publishes the windows' observations, their captured render demand and the
  replacement surfaces the owner asked for, and bounds its wait by the owner's
  deadline; `publishVulkanScene` publishes the scene the owner renders, from
  any application thread, with the configuration's `VulkanRenderer`.
- The renderer is the consumer's (VK-19). Each frame's `FrameRequest` names
  its target, slot and image and the image's extent and color format before
  anything of the renderer's is recorded, and the renderer is lent the
  session's `Construction`: on the graphics owner's thread it builds pipeline
  layouts and graphics pipelines over embedded shaders
  (`constructPipelineLayout`, `constructPipeline`), replaces and releases them
  (`replaceConstructedPipeline`, `releaseConstructed`), and binds one built for
  the frame's format inside the dynamic rendering it begins and ends. Any other
  thread is refused before anything native happens, a pipeline built for
  another format is refused at its binding, and it never holds a native
  handle. A construction refused, or one that raised having left nothing,
  skips only that frame; one the session latched as its failure ends the run
  with that primary. What the renderer did not release is destroyed with the
  session's other managed resources before the device, on normal and terminal
  exits alike. The module re-exports the recording vocabulary a renderer needs.
- A host configured with `DeviceSurfaceFree` (`vulkanDeviceStart`) creates
  the session's device in the owner's startup, with no surface and before any
  window; a window handed over later is admitted only if the chosen queue
  family presents to it. With or without windows, `submitVulkanAction` hands
  the owner a bounded `VulkanAction` from any thread, run once on the owner's
  thread with the same `Construction`, never beside a frame; admission refuses
  at once — a full queue, no device yet, a failed session, a closed owner —
  and an action still queued when the owner's exit or the session's failure
  begins is refused, never run. Inside an action, `constructFramelessBatch`
  records a frame-less batch (GRS-12), submitted with the action's other
  sealed ones when it returns and discarded if it raises, and answers a
  ticket its caller can read, or wait for with a deadline, from any other
  thread. A session with no target keeps polling
  completion and disposing of released resources until it is ended, and
  retires through the same protected exit.
- The private `controller` sublibrary holds the controller —
  `GraphicsOperations` over the native roots, with the recording and the frames
  composed into its step (`Internal.Rendering`) — the owner-thread actions'
  queue (`Internal.Actions`), the loop adapter (`Internal.Loop`), and the record through which it reaches the surface
  bridge, which the package's own examples replace with a stand-in, as they
  replace the recording's and the frames' native layers.
- Verification capture (VK-19) is visible only there, so only this package's
  suites reach it. `withVulkanOwnerHostAs CaptureOn` (`Internal.Production`)
  is the production host with its generations built unclipped and, where the
  surface offers it, as transfer sources; `requestVulkanCapture` asks for the
  next frame of an attachment's target, and `takeVulkanCapture` answers, once,
  its bytes, extent, format and identities after its batch's completion
  evidence, or why it was withheld (`Internal.Capture`). A host with capture
  off — `withVulkanOwnerHost`, every host outside the package — builds exactly
  the swapchains it did before and refuses every request. A surface offering
  no transfer-source usage is still admitted, and its capture is refused with
  a typed reason.

Every Vulkan object is created and destroyed on the graphics owner's thread;
the controller makes no GLFW call. [`docs/gpu_backend.md`](../../../docs/gpu_backend.md)
is the contract: the ownership graph, the composition order, how a later
window's surface is checked against the session's device, how a lost surface
is recovered, and the destruction order.

Its headless examples (`integration-tests`) run whole graphics hosts over the
GLFW package's scripted seam with a stand-in native layer and surface bridge;
they create no Vulkan object, and the validation group `test.vulkan-headless`
runs them. Like the native package, it is listed only in `cabal.project.vulkan`,
and only [`tools/vulkan/run.sh`](../../../tools/vulkan/run.sh) builds it.

Its native suite (`vulkan-native-tests`, in `native-test/`) is the
package-native Vulkan fixture: the process main thread owns one shared
production graphics session — this package's `withVulkanOwnerHost`, the roots
it owns, and GLFW — and serves Hspec, which runs on a thread of its own; the
native cases VK-2 and VK-5 through VK-7 once ran in the proof harness run in
child processes with roots of their own, beside a synchronization-validation
control. It is the validation group `test.vulkan-native`, built in a
preparation stage and timed without its compilation under a thirty-second
watchdog; on macOS it runs on the owner's desktop under the owner's standing
approval, with the consent on its own command.
[`docs/gpu_backend.md`](../../../docs/gpu_backend.md#the-native-suite) is its
contract.
