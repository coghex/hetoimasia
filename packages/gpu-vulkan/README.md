# Vulkan backend

Owns device resources, transfers, command submission, synchronization, and render
targets. Public game-facing interfaces must not expose Vulkan handles. Its
internal API may be Vulkan-specific; a universal graphics abstraction is deferred.
It must not depend on application state or a concrete game.

The component is deliberately split into two packages, and the split is
permanent rather than a staging step:

- [`model/`](model/README.md) — `hetoimasia-gpu-vulkan-model`, the pure
  retention and frame-ownership model. Its only project dependency is
  `hetoimasia-foundation`: it has none on the Vulkan binding, GLFW, the runtime
  or a game, makes no native call and names no native type. It is listed in
  both `cabal.project` and `cabal.project.cpu`, so it and its suite stay
  buildable and runnable without a Vulkan SDK permanently. Its contract is
  [`docs/gpu_model.md`](../../docs/gpu_model.md), and its suite is the CPU
  validation group `test.vulkan`.
- The native backend package — planned. It will own the binding, the handles,
  the calls and the threads, and it will depend on the model package. CPU-only
  project selection excludes it. The model will never depend on it: completion
  reaches the model only as abstract facts through an injected interface, so
  the model proves no native completion and cannot be made to.

[The Vulkan backend design](../../docs/vulkan_backend_design.md) records the
accepted policy behind both halves.
