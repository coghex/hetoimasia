# Vulkan backend

Owns device resources, transfers, command submission, synchronization, and render
targets. Public game-facing interfaces must not expose Vulkan handles. Its
internal API may be Vulkan-specific; a universal graphics abstraction is deferred.
It must not depend on application state or a concrete game.

The component is deliberately split into packages, and the split is permanent
rather than a staging step:

- [`model/`](model/README.md) — `hetoimasia-gpu-vulkan-model`, the pure
  retention and frame-ownership model. Its only project dependency is
  `hetoimasia-foundation`: it has none on the Vulkan binding, GLFW, the runtime
  or a game, makes no native call and names no native type. It is listed in
  both `cabal.project` and `cabal.project.cpu`, so it and its suite stay
  buildable and runnable without a Vulkan SDK permanently. Its contract is
  [`docs/gpu_model.md`](../../docs/gpu_model.md), and its suite is the CPU
  validation group `test.vulkan`.
- [`diagnostics/`](diagnostics/README.md) — `hetoimasia-gpu-vulkan-diagnostics`,
  the header-free validation capture: the C storage and producer a debug-utils
  messenger calls, and the diagnostic lifetime whose drain worker delivers into
  the caller's logger. Like the model it depends only on
  `hetoimasia-foundation`, includes no Vulkan header, is listed in both
  `cabal.project` and `cabal.project.cpu`, and its suite is the CPU validation
  group `test.vulkan-diagnostics`. Its contract is
  [`docs/vulkan_diagnostics.md`](../../docs/vulkan_diagnostics.md).
- [`native/`](native/README.md) — `hetoimasia-gpu-vulkan-native`, the native
  backend. It owns the binding, the handles, the calls and the threads, and
  depends on the diagnostics and model packages. Today it holds VK-6's
  messengers and C callback and VK-9's shader adapter — GLSL compiled during the
  build by the provisioned compiler, embedded as SPIR-V, with the compiler's
  identity a rebuild input; VK-7 extends it. It is listed only in
  `cabal.project.vulkan`, with its local dependency closure, so CPU-only and
  ordinary project selection both exclude it, and only
  `tools/vulkan-proof/run-shaders.sh` and `tools/vulkan-proof/run-proof.sh`,
  which runs the former first, build it. Neither the model nor the
  diagnostics package will ever depend on it: completion reaches the model only
  as abstract facts through an injected interface, so the model proves no
  native completion and cannot be made to.

[The Vulkan backend design](../../docs/vulkan_backend_design.md) records the
accepted policy behind all three.
