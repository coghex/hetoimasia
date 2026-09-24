# Native Vulkan backend

Buildable package: `hetoimasia-gpu-vulkan-native`, in `packages/gpu-vulkan/native`.

The package that owns the Vulkan binding, the handles and the calls. Today it
holds VK-6's native integration and nothing else; VK-7 extends it with instance,
device and target ownership.

- `Hetoimasia.GPU.Vulkan.Native.Diagnostics` builds the two debug-utils
  messengers an instance can have — the one chained into `VkInstanceCreateInfo`
  and the explicit one — from one
  [diagnostic capture](../diagnostics/README.md). Both register
  `captureMessengerCallback`, a C function in `cbits/` with Vulkan's exact
  callback type that hands its arguments to the diagnostics package's C
  producer, with the capture's storage as user data. No Haskell is reachable
  from it, so a Vulkan call made through a genuine `unsafe` import can report
  through it.
- `cbits/hetoimasia_vulkan_native.c` is the one translation unit that sees both
  the diagnostics package's header and the Vulkan headers, and it asserts at
  compile time that the diagnostics package's layout mirror is the headers'
  layout.
- `nativeFfiConfiguration` records this package's own use of the binding: the
  binding-wide flags `cabal.project.vulkan` constrains, the C-only capture
  callback, no Haskell callbacks, and no `unsafe` imports yet — the audited
  recording subset is VK-11's. It adds no recording, submission, device or
  surface operation.

It is listed only in `cabal.project.vulkan`, beside its local dependency closure
— the diagnostics package, `hetoimasia-gpu-vulkan-model` and the foundation — so
neither ordinary project resolves the binding, the Vulkan headers or a loader.
The only thing that builds it is `tools/vulkan-proof/run-proof.sh`, which points
Cabal at the provisioned loader and headers. Its native cases run in that
harness until VK-8 moves them into a package-native fixture; see
[the proof harness](../../../tools/vulkan-proof/README.md#vk-6-validation-capture).

[`docs/vulkan_diagnostics.md`](../../../docs/vulkan_diagnostics.md) is the
contract in prose.
