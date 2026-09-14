# Foundation

Buildable package: `hetoimasia-foundation`.

Owns small independent services. Currently provides an abstract `Logger` with
validated component names, pure filter configuration, immutable scoped context,
injectable clock and thread metadata, a deterministic one-line record layout,
and two sinks: a borrowed handle and a caller-supplied callback; and a CPU
resource scope that pairs an acquisition with a protected release, including a
staged constructor for an owner assembled from several parts and a continuation
facade those scopes are composed in.

Configuration is resolved once and never reconfigured in place. The pure parsers
`parseLogLevel`, `parseComponentLevels`, and `parseDebugSelection` validate the
three configurable parts of a filter, and `resolveLogFilter` assembles them over
a `LogVariables` and a lookup the caller supplies. Both are values-in,
values-out: the variable names and the environment access belong to the
application, and the master and source switches stay programmatic.

Logging is synchronous. A handle sink serializes every write and flush across
the loggers sharing it, so records never interleave and each producer keeps its
own order, and it flushes every record unless the caller turns that off and
flushes explicitly instead. The handle stays the caller's: the sink never closes
it and never changes its buffering, and the application's logging scope must
outlive every subsystem borrowing it. Sink failures propagate to the logging
call, and a failed or interrupted write releases the sink's serialization state
rather than stranding the loggers sharing it.

See [docs/logging.md](../../docs/logging.md) for the record layout, the quoting
rules, the startup configuration contract, the full ownership and failure
contract, and the module authoring guide new subsystems follow.

`Hetoimasia.Foundation.Resource` provides `withResource`, which acquires a
value, lends it to a body, and releases it. It takes the acquisition first and
the release second, as `bracket` does, but it is not an alias for it: when the
body and the release both fail it preserves the body's failure and retains
every cleanup failure beside it as ordered, structured evidence that
`cleanupFailures` reads back. Acquisition is cancellable, each release runs
uninterruptibly, and a release must therefore have a controlled blocking
duration. The module imports no logger and no public module in this package.

`withComposite` is the same scope for an owner assembled from several parts. Its
`Assembly` acquires each part and installs that part's rollback as one protected
step, so exactly one authoritative release always covers every part acquired so
far and a failure at any stage releases exactly those. The order that release
runs in is declared with `releaseRank`, because the correct order is a property
of the API the parts come from rather than the reverse of acquisition.

`Scoped` is the continuation facade over both. `allocResource` and
`allocComposite` yield a scope value that composes in `do` notation instead of
nesting one callback per resource, `withScoped` is its only runner, and
`locally` is its only early-release operation. No lifetime changes: a resource
allocated this way is released when the enclosing `withScoped` continuation
returns or throws, one scope's own allocations unwind in reverse, and a
composite keeps its declared order.

See [docs/resources.md](../../docs/resources.md) for the failure table, the
ownership and borrowing rules, the mask discipline and its limits, the staged
construction contract, the facade's cleanup point and documented misuse, and
the caller patterns that discard retained evidence.

`Hetoimasia.Foundation.Failure` records where an engine failure came from on
the exception itself. `throwFailure` throws a component's own typed exception
with its component, operation, identifiers, and caller source location
attached. `withOperationContext` lets an outer boundary add the operation it was
performing, including to a native exception, which keeps its type and is
reported with an unknown throw site. `failureEvidence` reads the evidence back
with no logger. The exception is never wrapped, so typed catches still match,
and cancellation is left unannotated. It imports only the `Component` and
`SourceLocation` types from the logging module. See
[docs/failures.md](../../docs/failures.md).

`Hetoimasia.Foundation.Recovery` runs one complete owned `IO` operation under
an explicit policy the caller supplies: a component classifier choosing a retry
or a named fallback, one finite attempt budget shared by both, and a required or
optional disposition. Cancellation and an attempt with failed cleanup propagate
before the classifier is consulted. A success reports how it was reached and the
failed attempts; exhausted optional work is explicitly unavailable; a propagated
failure keeps its own type and evidence with the earlier attempts attached. It
takes no logger. See [docs/recovery.md](../../docs/recovery.md).

`allocComponent`, in the same module, constructs a live component for the rest
of an enclosing `Scoped` block under that policy. Each attempt is an `Assembly`
with its own part ledger, rolled back before the classifier chooses another
alternative; the selected attempt's parts are released when the scope exits,
and the consumer runs once against an immutable `Available` or `Unavailable`
value. The `Scoped` representation and the part ledger it shares with the
resource module live in a hidden module that no client can import. See
[Component construction](../../docs/resources.md#component-construction).

`Hetoimasia.Foundation.Worker` owns CPU worker threads. `withWorkerGroup` is an
`IO` lifetime boundary that runs inside the scopes of the components its workers
borrow, and `allocWorkerGroup` composes it in `Scoped`. A worker's startup is a
scoped construction on its own thread; startup acknowledgement, a cooperative
stop request, a cancellation request delivered by a group-owned helper, and
terminal observation are distinct operations, observed through STM. Every exit
from the group requests all stops before waiting for any and drains every
worker and helper before the enclosing dependencies unwind; a worker that never
stops keeps them alive. The module publishes raw outcomes, run-exit ordering,
and cleanup evidence, and classifies none of them. See
[docs/workers.md](../../docs/workers.md).

`Hetoimasia.Foundation.Messaging.Payload` is the boundary later messaging
transports accept. `prepare` fully evaluates a value through its `NFData`
instance on the producer's thread and returns an opaque `Prepared` handle, so a
failure nested in a lazy field is raised to the producer rather than a consumer.
`preparedValue` reads the value without evaluating anything or needing
`NFData`, so an unchanged payload is forwarded without being prepared again. The
handle cannot be constructed, rewritten, coerced, or mapped from outside the
module. It owns no transport state. See
[docs/messaging.md](../../docs/messaging.md).

Depends on `base`, `deepseq`, `stm`, `text`, `containers`, and `time`. It must not import runtime,
rendering, scripting, application, or game modules. Add a helper here only when
it has an independent purpose; this is not a miscellaneous bucket.
