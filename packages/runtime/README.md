# Runtime

Buildable package: `hetoimasia-runtime`.

Invokes a caller-supplied application action and reports startup/success through
an injected logger. Exceptions propagate. There are no windows, GPU resources,
worker threads, game managers, or global environment in this initial component.

`Hetoimasia.Runtime.Resources` is this package's second entry point.
`resourceSmoke` is the owned-resource demonstration: it acquires a workspace and
a composite channel through the foundation's resource scopes, runs injected
bounded work with them, releases everything, and reports the lifecycle through
an injected logger. Its work, its cleanup outcomes, and its logger are all
arguments, so the console executable's `--resource-smoke` path and the suite's
injected-failure examples run the same body. It owns no file, thread, or
service, and it is the worked example behind
[Application lifecycle](../../docs/resources.md#application-lifecycle).

Future lifecycle and scheduling APIs belong here. Concrete Vulkan creation and
game binding registration belong in application composition. Resource-owning
APIs need scoped cleanup and explicit exception/cancellation behavior before
they are introduced; the current runner is not a resource manager.
