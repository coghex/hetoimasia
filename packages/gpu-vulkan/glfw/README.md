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
they create no Vulkan object. Like the native package, it is listed only in
`cabal.project.vulkan`, and only `tools/vulkan-proof/run-proof.sh` builds it:
`--headless` runs its examples, and the native run exercises it through the
proof harness's VK-7 session until VK-8 moves those cases into a
package-native fixture.
