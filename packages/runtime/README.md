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

`Hetoimasia.Runtime.Supervision` supervises an owned worker group on the
application thread: `withSupervision` lends a narrow `RuntimeControl` for
managed startup with a per-worker service-or-job role, required-or-optional
disposition, and component classifier; `checkRuntime` and `awaitSupervised`
observe worker outcomes only where the application places them; a fatal
failure is latched for the invocation; optional warnings go through the logging
lifetime; and closing settles every outcome before the boundary returns or
rethrows. It reuses the foundation worker group's stop and drain, and reports
no terminal `Error` and flushes nothing. The contract is
[Supervision](../../docs/supervision.md).

`Hetoimasia.Runtime.Inbox` is an optional adapter for a supervised service with
one FIFO inbox: `startInboxService` constructs a component's context and then
its inbox inside the worker's startup, hands the send endpoint to the
application, dispatches one prepared message at a time until a stop, and aborts
the inbox before the component is torn down on every exit, returning an
`InboxExit` discard count on an ordinary stop. It adds no supervisor, scheduler,
or restart policy. The contract is
[Supervised inbox services](../../docs/messaging.md#supervised-inbox-services).

Future lifecycle and scheduling APIs belong here. Concrete Vulkan creation and
game binding registration belong in application composition. Resource-owning
APIs need scoped cleanup and explicit exception/cancellation behavior before
they are introduced; the current runner is not a resource manager.

## Tests

`runtime-tests` owns this package's contracts. Its sources live in `test/`
alone: `Main.hs`, the composer `Test.Runtime.Spec`, which roots the `Runtime`
group, one module per component — the runner, application lifecycle, inbox
services and their finish, logging lifetime, opacity, reporting, supervision,
supervised messaging waits, and the resource smoke — and the supervision, inbox,
and logger fixtures beside them. Examples run against real foundation services
through their public APIs rather than mocks, and a foundation primitive's own
contract belongs to `foundation-tests`, not here. A new runtime example belongs
in the component module whose behaviour it asserts. It may use only this
package, the foundation, the neutral `hetoimasia-test-support` library, and
third-party packages; an example that launches the console executable belongs
in the root suite's `Console` group instead. Run the suite, or one component of
it:

```bash
cabal test hetoimasia-runtime:runtime-tests --test-show-details=direct
cabal test hetoimasia-runtime:runtime-tests --test-show-details=direct \
  --test-options='--match Supervision'
```

A selector that matches no example fails the suite. Without the GLFW SDK, add
`--project-file cabal.project.cpu`; see
[docs/validation.md](../../docs/validation.md#building-without-the-glfw-sdk).
The validation catalog runs the suite as the floor group `test.runtime`.
