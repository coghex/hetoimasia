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
duration. The module imports no logger and no other module in this package.

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

Depends on `base`, `text`, `containers`, and `time`. It must not import runtime,
rendering, scripting, application, or game modules. Add a helper here only when
it has an independent purpose; this is not a miscellaneous bucket.
