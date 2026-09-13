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

`Hetoimasia.Runtime.Reporting` is the adapter that explains recovery outcomes
and terminal failures through an injected logger: `reportOutcome` warns about a
recovered or unavailable outcome the caller already holds, and
`reportTerminalFailure` makes one guarded `Error` attempt at the boundary that
handles a failure and rethrows it preservingly. `resourceSmoke` reports through
it. The contract is
[Recovery and terminal reports](../../docs/logging.md#recovery-and-terminal-reports).

`Hetoimasia.Runtime.Logging` is the borrowed logging lifetime:
`withLoggingLifetime` lends a caller-built logger to a callback through a narrow
handle that records managed reporting-attempt outcomes, then makes at most one
final flush after the callback, outside every resource release, following the
settled outcome. It owns no handle and changes no buffering. Both console smoke
paths run inside it; `managedResourceSmoke` is `resourceSmoke` with its report's
outcome recorded on the lifetime. The contract is
[Logging lifetime](../../docs/logging.md#logging-lifetime).

Future lifecycle and scheduling APIs belong here. Concrete Vulkan creation and
game binding registration belong in application composition. Resource-owning
APIs need scoped cleanup and explicit exception/cancellation behavior before
they are introduced; the current runner is not a resource manager.
