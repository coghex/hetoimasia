# Runtime

Buildable package: `hetoimasia-runtime`.

Invokes a caller-supplied application action and reports startup/success through
an injected logger. Exceptions propagate. There are no windows, GPU resources,
worker threads, game managers, or global environment in this initial component.

Future lifecycle and scheduling APIs belong here. Concrete Vulkan creation and
game binding registration belong in application composition. Resource-owning
APIs need scoped cleanup and explicit exception/cancellation behavior before
they are introduced; the current runner is not a resource manager.
