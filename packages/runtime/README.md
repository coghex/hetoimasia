# Runtime

Buildable package: `hetoimasia-runtime`.

Composes application lifetimes, reporting, supervised workers, inbox services,
logging lifetimes, and pure update policy over the foundation's public
services. The optional asynchronous logger owns a writer through a foundation
worker group. Callers inject narrow services; window and GPU ownership live in
their own components, and this package defines no game managers or global
environment.

The small `Hetoimasia.Runtime` entry point invokes a caller-supplied action and
reports startup/success through an injected logger. Exceptions propagate.

`Hetoimasia.Runtime.Resources.resourceSmoke` is the owned-resource
demonstration: it acquires a workspace and
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

`Hetoimasia.Runtime.AsyncLog` is the optional bounded asynchronous adapter over
a borrowed synchronous sink: `withAsyncLogAdapter` borrows an existing
`LogSink` and, for the duration of a callback, lends an adapter `LogSink` plus a
handle for status and flushing. Admission never waits and never writes through
the borrowed sink itself, a queued record's retained text and collections are
bounded and counted, and the writer's failure is latched rather than reported
back through itself. Its lifetime encloses `withLoggingLifetime`, it adds no
second final flush, and it never closes the caller's sink. Nothing else changes:
existing sinks, loggers, and callers keep their synchronous semantics, and an
application opts in by injecting a logger over `adapterSink`. It is not the
Vulkan native-capture path. The contract is
[Asynchronous adapter](../../docs/logging.md#asynchronous-adapter).

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

`Hetoimasia.Runtime.Application` is the generic application lifecycle.
`runScopedApplication` and `runScopedApplicationWithQuiescence` construct the
application's dependencies from a `Scoped` value, and are unchanged.
`runManagedApplication` runs the same lifecycle over a managed dependency
lifetime, `∀ r. (dependencies → IO r) → IO r`, so a component can enclose every
borrower in its own protected boundary and drain after the workers and before
its parents are released. The contract is
[The application runner](../../docs/resources.md#the-application-runner).

`Hetoimasia.Runtime.UpdatePolicy` is the caller-owned update policy over the
foundation's monotonic time values: `Demand` and `queryDemand` express and query
no demand, immediate demand, or an absolute deadline; `boundElapsed` caps a
variable-step sample and reports what it clipped; `advanceFixedStep` turns
elapsed time into a bounded number of whole steps, retains only the sub-step
remainder, reports discarded time, and places the next step absolutely; and
`pauseFixedStep` and `resumeFixedStep` rebase time so a paused interval is never
simulated. It reads no clock, starts no thread, and owns no rendering decision.
The contract is [Scheduling](../../docs/scheduling.md).

Future lifecycle and scheduling APIs belong here. Concrete Vulkan creation and
game binding registration belong in application composition. Resource-owning
APIs need scoped cleanup and explicit exception/cancellation behavior before
they are introduced; the current runner is not a resource manager.

## Tests

`runtime-tests` owns this package's contracts. Its sources live in `test/`
alone: `Main.hs`, the composer `Test.Runtime.Spec`, which roots the `Runtime`
group, one module per component — the runner, application lifecycle, inbox
services and their finish, logging lifetime, opacity, reporting, supervision,
supervised messaging waits, the resource smoke, and the update policy — and the supervision, inbox,
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
