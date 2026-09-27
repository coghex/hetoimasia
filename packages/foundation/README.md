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
`SourceLocation` types, from the logging family's hidden `Log.Component` and
`Log.Base` modules rather than the logger. See
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
resource module live in the package's private `internal` sublibrary, which no
client can import. See
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
and cleanup evidence, and classifies none of them. `groupStatus` reads one
coherent snapshot of the group's phase and the workers its drain still waits
for, without waiting or changing anything. See
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

`Hetoimasia.Foundation.Messaging.Channel` is a bounded FIFO channel of prepared
payloads. `newChannel` takes a capacity the owner chooses, rejecting one that is
not positive or too large with a typed failure carrying its engine origin, and
returns the owner-control endpoint, which hands out a send endpoint and a
receive endpoint that carry only their own authority. Every send and receive is
an STM operation: an ordinary send reports `Full` at once, and waiting for
capacity or for an entry is a separate operation. Close keeps the backlog for
draining; abort drops it and returns how many entries it discarded; neither
waits. Atomic statistics report capacity, depth, high-water, and accepted,
dequeued, and discarded counts under a conservation invariant. See
[docs/messaging.md](../../docs/messaging.md#bounded-fifo-channels).

`Hetoimasia.Foundation.Messaging.Snapshot` is a latest-value snapshot of a
prepared payload. `newSnapshot` creates one with a fresh identity from a prepared
initial value and returns the publisher endpoint, which hands out a read-only
endpoint. Each publication replaces the value and advances a non-wrapping
revision in one write. A read returns an opaque observation pairing the payload
with a cursor for this snapshot and revision; a waiting read from a cursor
returns the newest unseen publication, end-of-stream once closed, and retries
only while open. A cursor from another snapshot raises a typed misuse failure
with engine origin before anything is inspected. Close keeps the final value,
never retries, and never reopens. See
[docs/messaging.md](../../docs/messaging.md#latest-value-snapshots).

`Hetoimasia.Foundation.Time` is the monotonic time boundary. A
`MonotonicSource` is injected: `monotonicSource` reads the process's monotonic
clock, whose epoch every use shares, and `scriptedSource` scripts readings for
tests. `Instant` and `Duration` are opaque whole nanoseconds that are never
negative and have no wall-clock, numeric, or serializable representation.
Durations from caller input are validated as `AllowZero` or `RequirePositive`
and a refusal names its reason; a `Double` seconds conversion reports its
rounding. Deadline arithmetic reports overflow rather than wrapping, and
`sampleElapsed` reports zero on a first, repeated, or backward sample and the
full difference otherwise, always storing the latest raw sample. A clock failure
is attributed to `foundation.time` through the failure module, and cancellation
propagates unchanged. The foundation owns these values and this arithmetic; the
runtime owns step policy and GLFW owns native wait conversion. See
[docs/time.md](../../docs/time.md).

Depends on `base`, `deepseq`, `stm`, `text`, `containers`, and `time`. It must not import runtime,
rendering, scripting, application, or game modules. Add a helper here only when
it has an independent purpose; this is not a miscellaneous bucket.

## Module map

The logging and failure families each have one public facade over hidden
modules of the main library. A client imports the facade; the hidden modules
are refused. See [docs/logging.md](../../docs/logging.md#module-structure) and
[docs/failures.md](../../docs/failures.md#module-structure) for their dependency
direction.

The resource family has two public modules. Their implementation lives in the
private `internal` sublibrary, which exposes only the package-private facade
`Resource.Internal` (and the worker group's `Worker.Internal`); the rest of the
package imports that facade, and the modules behind it import one another
directly. The collection's representations are a hidden module of the main
library. See [docs/resources.md](../../docs/resources.md#the-implementation-seam)
for their dependency direction and state ownership.

The worker group has one public module, `Worker`, which re-exports the
package-private facade `Worker.Internal` without its coordination probe. Behind
that facade, eight hidden modules of the same sublibrary each own one
responsibility; they import one another and the resource family's `Scoped` and
`Cleanup` modules directly, and `Worker.Startup` and `Worker.Group` never import
each other. See [docs/workers.md](../../docs/workers.md#module-structure) for
their dependency direction and [its state table](../../docs/workers.md#state)
for the module that owns and writes each piece of state.

| Logical module | Source path | Cabal component | Visibility | Purpose |
| --- | --- | --- | --- | --- |
| `Hetoimasia.Foundation.Log` | `src/Hetoimasia/Foundation/Log.hs` | main library | exposed | Public logging facade; logger construction, scoped context, flushing, emission, and call-site extraction |
| `Hetoimasia.Foundation.Log.Base` | `src/Hetoimasia/Foundation/Log/Base.hs` | main library | hidden | Levels, source locations, and the format and variable-name options |
| `Hetoimasia.Foundation.Log.Component` | `src/Hetoimasia/Foundation/Log/Component.hs` | main library | hidden | The validated `Component`, its constructors and operations, and shared quoting |
| `Hetoimasia.Foundation.Log.Types` | `src/Hetoimasia/Foundation/Log/Types.hs` | main library | hidden | Filter, entry, sink, metadata-provider, and logger records |
| `Hetoimasia.Foundation.Log.Filter` | `src/Hetoimasia/Foundation/Log/Filter.hs` | main library | hidden | Startup configuration parsing and admission |
| `Hetoimasia.Foundation.Log.Format` | `src/Hetoimasia/Foundation/Log/Format.hs` | main library | hidden | The deterministic record layout and escaping |
| `Hetoimasia.Foundation.Log.Sink` | `src/Hetoimasia/Foundation/Log/Sink.hs` | main library | hidden | Handle and callback sinks, serialized writes, and forwarding |
| `Hetoimasia.Foundation.Failure` | `src/Hetoimasia/Foundation/Failure.hs` | main library | exposed | Public failure facade; raising, operation boundaries, and inspection |
| `Hetoimasia.Foundation.Failure.Base` | `src/Hetoimasia/Foundation/Failure/Base.hs` | main library | hidden | The abstract `Operation` and its naming operations |
| `Hetoimasia.Foundation.Failure.Types` | `src/Hetoimasia/Foundation/Failure/Types.hs` | main library | hidden | Origin, context, site, cause, and evidence records, and the private failure annotation |
| `Hetoimasia.Foundation.Resource` | `src/Hetoimasia/Foundation/Resource.hs` | main library | exposed | Public resource facade; resource and composite scopes, the continuation facade, and evidence inspection |
| `Hetoimasia.Foundation.Resource.Collection` | `src/Hetoimasia/Foundation/Resource/Collection.hs` | main library | exposed | Scoped collections of independently retired members; every collection operation |
| `Hetoimasia.Foundation.Resource.Collection.Types` | `src/Hetoimasia/Foundation/Resource/Collection/Types.hs` | main library | hidden | Collection, member state and token, and the result and rejection types |
| `Hetoimasia.Foundation.Resource.Internal` | `internal/Hetoimasia/Foundation/Resource/Internal.hs` | `internal` sublibrary | package-private (exposed to this package only) | Facade re-exporting the resource implementation to the rest of the package |
| `Hetoimasia.Foundation.Resource.Cleanup` | `internal/Hetoimasia/Foundation/Resource/Cleanup.hs` | `internal` sublibrary | hidden | Cleanup identity and evidence: identities, the counter issuing them, inspection, release attempts, and retention |
| `Hetoimasia.Foundation.Resource.Types` | `internal/Hetoimasia/Foundation/Resource/Types.hs` | `internal` sublibrary | hidden | Release ranks and the assembly representation: parts, `Assembly`, and the ledger |
| `Hetoimasia.Foundation.Resource.Assembly` | `internal/Hetoimasia/Foundation/Resource/Assembly.hs` | `internal` sublibrary | hidden | Staged acquisition, rollback, and lending over the assembly representation |
| `Hetoimasia.Foundation.Resource.Scoped` | `internal/Hetoimasia/Foundation/Resource/Scoped.hs` | `internal` sublibrary | hidden | The `Scoped` continuation type, its instances, and its runner |
| `Hetoimasia.Foundation.Worker` | `src/Hetoimasia/Foundation/Worker.hs` | main library | exposed | Public worker facade; group lifetime, drain status, definitions, starting, requests, observation, outcomes, and evidence, without the coordination probe |
| `Hetoimasia.Foundation.Worker.Internal` | `internal/Hetoimasia/Foundation/Worker/Internal.hs` | `internal` sublibrary | package-private (exposed to this package only) | Facade re-exporting the worker implementation, including the coordination probe, to the rest of the package |
| `Hetoimasia.Foundation.Worker.Base` | `internal/Hetoimasia/Foundation/Worker/Base.hs` | `internal` sublibrary | hidden | Worker identity, the request record, the stop token, `WorkerCancelled`, and the group phase |
| `Hetoimasia.Foundation.Worker.Outcome` | `internal/Hetoimasia/Foundation/Worker/Outcome.hs` | `internal` sublibrary | hidden | Run exits, results, completions, the startup and group reports, and the failure-classification helpers |
| `Hetoimasia.Foundation.Worker.Types` | `internal/Hetoimasia/Foundation/Worker/Types.hs` | `internal` sublibrary | hidden | The group, entry, closing snapshot, drain-status records, coordination probe, handle, and definition |
| `Hetoimasia.Foundation.Worker.Evidence` | `internal/Hetoimasia/Foundation/Worker/Evidence.hs` | `internal` sublibrary | hidden | Evidence attached to a propagated failure, its rendering, and its readers |
| `Hetoimasia.Foundation.Worker.Observation` | `internal/Hetoimasia/Foundation/Worker/Observation.hs` | `internal` sublibrary | hidden | Drain status, startup and completion reads, committed observation, and settled retirement |
| `Hetoimasia.Foundation.Worker.Requests` | `internal/Hetoimasia/Foundation/Worker/Requests.hs` | `internal` sublibrary | hidden | Stop and cancellation requests, the cancellation helper, and a failing starter's drain |
| `Hetoimasia.Foundation.Worker.Startup` | `internal/Hetoimasia/Foundation/Worker/Startup.hs` | `internal` sublibrary | hidden | Registration, the fork and startup handoff, the child thread, and terminal publication |
| `Hetoimasia.Foundation.Worker.Group` | `internal/Hetoimasia/Foundation/Worker/Group.hs` | `internal` sublibrary | hidden | The group lifetime boundary, closing, the report, and the protected drain |

## Tests

`foundation-tests` owns this package's contracts. Its sources live in `test/`
alone: `Main.hs`, the composer `Test.Foundation.Spec`, and one component tree
each for `Logging`, `Resources`, `Failures`, `Recovery`, `Workers`,
`Messaging`, and `Time`, with that component's own helpers beside its specs. A new example
belongs in the component spec whose contract it asserts. It may use only this
package, the neutral `hetoimasia-test-support` library, and third-party
packages; an example that needs the runtime, GLFW, or the console belongs to the
suite that owns that behaviour instead. Run the suite, or one component of it:

```bash
cabal test hetoimasia-foundation:foundation-tests --test-show-details=direct
cabal test hetoimasia-foundation:foundation-tests --test-show-details=direct \
  --test-options='--match Messaging'
```

A selector that matches no example fails the suite. Without the GLFW SDK, add
`--project-file cabal.project.cpu`; see
[docs/validation.md](../../docs/validation.md#building-without-the-glfw-sdk).
The validation catalog runs the suite as the floor group `test.foundation`.
