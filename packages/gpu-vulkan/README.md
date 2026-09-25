# Vulkan backend

Owns device resources, transfers, command submission, synchronization, and render
targets. Public game-facing interfaces must not expose Vulkan handles. Its
internal API may be Vulkan-specific; a universal graphics abstraction is deferred.
It must not depend on application state or a concrete game.

The component is deliberately split into four packages, and the split is
permanent rather than a staging step:

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
  backend. It owns the binding, the handles and the calls, and depends on the
  diagnostics and model packages and on no window system. It holds VK-6's
  messengers and C callback, VK-9's shader adapter — GLSL compiled during the
  build by the provisioned compiler, embedded as SPIR-V, with the compiler's
  identity a rebuild input — and VK-7's roots: the runtime profile's
  decisions, and the instance, the explicit messenger, the one shared device
  and a record per target surface, over an open native layer. It is listed
  only in `cabal.project.vulkan`, with its local dependency closure, so
  CPU-only and ordinary project selection both exclude it, and only
  [`tools/vulkan/run.sh`](../../tools/vulkan/run.sh) builds it. Neither the model nor the
  diagnostics package will ever depend on it: completion reaches the model only
  as abstract facts through an injected interface, so the model proves no
  native completion and cannot be made to.
- [`glfw/`](glfw/README.md) — `hetoimasia-gpu-vulkan-glfw`, the window
  integration. It is the only package that depends on both the native backend
  and the GLFW package: it supplies the GLFW package's supervised graphics
  owner with the roots as its operations, hands each window's surface over from
  the main thread, and composes the diagnostic lifetime, the loader-aware
  session and the protected host. Like the native package it is listed only in
  `cabal.project.vulkan`. Nothing depends on it but an application; its own
  native suite is the package-native Vulkan fixture.

The dependency direction is one way: the model and the diagnostics package
depend on neither of the other two, the native package does not depend on the
integration, and the GLFW package depends on no GPU package at all.
[`docs/gpu_backend.md`](../../docs/gpu_backend.md) is the roots' and the
integration's contract.

[The Vulkan backend design](../../docs/vulkan_backend_design.md) records the
accepted policy behind all three.
