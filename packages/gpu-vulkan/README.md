# Vulkan backend — planned

Reserved component; no Vulkan dependency or implementation exists yet.

Owns device resources, transfers, command submission, synchronization, and render
targets. Public game-facing interfaces must not expose Vulkan handles. Its
internal API may be Vulkan-specific; a universal graphics abstraction is deferred.
It must not depend on application state or a concrete game.
