# Vulkan window integration

Buildable package: `hetoimasia-gpu-vulkan-glfw`, in `packages/gpu-vulkan/glfw`.

The one package that depends on both the native Vulkan backend
([`../native`](../native/README.md)) and the GLFW package. It composes three
delivered contracts and replaces none of them: the native backend's roots, the
GLFW package's supervised graphics owner (VK-18), and its surface bridge
(VK-5). Neither of those packages depends on this one. VK-16 later adds the
loop adapter here.

- `Hetoimasia.GPU.Vulkan.GLFW` is the public interface. `withVulkanOwnerHost`
  composes, in the order the backend design's P-5 fixes, the diagnostic
  lifetime, the loader-aware session, and the protected window host with its
  graphics owner, whose operations are this package's controller.
  `handOverVulkanTarget` creates one window's surface through GLFW on the main
  thread, inside that window's attachment, and hands it to the owner as a
  required or optional target.
- The private `controller` sublibrary holds the controller —
  `GraphicsOperations` over the native roots — and the record through which it
  reaches the surface bridge, which the package's own examples replace with a
  stand-in.

Every Vulkan object is created and destroyed on the graphics owner's thread;
the controller makes no GLFW call. [`docs/gpu_backend.md`](../../../docs/gpu_backend.md)
is the contract: the ownership graph, the composition order, how a later
window's surface is checked against the session's device, and the destruction
order.

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
