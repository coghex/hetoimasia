# Foundation

Buildable package: `hetoimasia-foundation`.

Owns small independent services. Currently provides an abstract `Logger` with
validated component names, pure filter configuration, immutable scoped context,
injectable clock and thread metadata, a deterministic one-line record layout,
and two sinks: a borrowed handle and a caller-supplied callback.

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

Depends on `base`, `text`, `containers`, and `time`. It must not import runtime,
rendering, scripting, application, or game modules. Add a helper here only when
it has an independent purpose; this is not a miscellaneous bucket.
