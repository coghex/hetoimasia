# Native Vulkan backend

Buildable package: `hetoimasia-gpu-vulkan-native`, in `packages/gpu-vulkan/native`.

The package that owns the Vulkan binding, the handles and the calls: VK-6's
diagnostic messengers, and VK-7's roots. It depends on no window system: a
surface reaches it as a 64-bit handle and the action that destroys it.

- `Hetoimasia.GPU.Vulkan.Native.Profile` is the runtime profile as pure
  decisions: what the instance asks for (`planInstance`), which physical device
  and queue family the session takes against a bootstrap surface
  (`selectDevice`), and why a later surface is refused (`TargetRejection`).
  It names no binding type, and its examples hold its extension names to the
  binding's.
- `Hetoimasia.GPU.Vulkan.Native.Roots` owns one session's instance, explicit
  messenger, shared device and per-target surface records, keyed by the GPU
  model's `TargetId`, over an open native layer (`RootOps`). It creates parent
  before child, destroys child before parent and refuses rather than reorders,
  never retries an uncertain destruction, and latches device loss. It makes no
  native call of its own.
- `Hetoimasia.GPU.Vulkan.Native.Roots.Vulkan` is the production native layer:
  the binding's own calls, reporting into a diagnostic capture.

- `Hetoimasia.GPU.Vulkan.Native.Diagnostics` builds the two debug-utils
  messengers an instance can have — the one chained into `VkInstanceCreateInfo`
  and the explicit one — from one
  [diagnostic capture](../diagnostics/README.md). Both register
  `captureMessengerCallback`, a C function in `cbits/` with Vulkan's exact
  callback type that hands its arguments to the diagnostics package's C
  producer, with the capture's storage as user data. No Haskell is reachable
  from it, so a Vulkan call made through a genuine `unsafe` import can report
  through it.
- `destroyInstanceQuiesced` destroys an instance whose messengers deliver into a
  capture and returns the `Quiesced` evidence the diagnostic lifetime demands:
  `vkDestroyInstance` is the last call that can invoke the callback, so its
  return is what establishes that none can still run.
- `cbits/hetoimasia_vulkan_native.c` is the one translation unit that sees both
  the diagnostics package's header and the Vulkan headers, and it asserts at
  compile time that the diagnostics package's layout mirror is the headers'
  layout.
- `nativeFfiConfiguration` records this package's own use of the binding: the
  binding-wide flags `cabal.project.vulkan` constrains, the C-only capture
  callback, no Haskell callbacks, and no `unsafe` imports yet — the audited
  recording subset is VK-11's. The roots add no recording or submission.

It is listed only in `cabal.project.vulkan`, beside its local dependency closure
— the diagnostics package, `hetoimasia-gpu-vulkan-model` and the foundation — so
neither ordinary project resolves the binding, the Vulkan headers or a loader.
The only thing that builds it is `tools/vulkan-proof/run-proof.sh`, which points
Cabal at the provisioned loader and headers. Its headless suite, `native-tests`,
runs the profile's and the roots' examples over a stand-in native layer through
`run-proof.sh --headless`; its native cases run in the harness until VK-8 moves
them into a package-native fixture — see
[the proof harness](../../../tools/vulkan-proof/README.md).

[`docs/vulkan_diagnostics.md`](../../../docs/vulkan_diagnostics.md) is the
messengers' contract in prose, and [`docs/gpu_backend.md`](../../../docs/gpu_backend.md)
the roots'.
