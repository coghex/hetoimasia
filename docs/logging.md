# Logging

Contract of `Hetoimasia.Foundation.Log`, the public logging facade, and of the
runtime modules built on it: the logging lifetime, the asynchronous adapter and
the reporting adapter. Not provided: rotation, owned log files, telemetry, JSON
output, live reconfiguration, a logging monad.

## Module structure

`Hetoimasia.Foundation.Log` is the only logging module a client imports. It
defines the logger operations and re-exports the rest from hidden modules of the
foundation's main library. A client that imports a hidden module is refused, and
`Component`, `LogSink` and `Logger` stay abstract through the facade.

| Module | Owns |
| --- | --- |
| `Log.Base` | `LogLevel`, `SourceLocation`, the option records `FormatOptions` and `LogVariables` |
| `Log.Component` | The validated `Component` and the quoting every diagnostic and record shares |
| `Log.Types` | The filter, entry, sink, metadata-provider and logger records |
| `Log.Filter` | Startup configuration parsing and the admission predicate |
| `Log.Format` | The record layout and its bare-or-quoted rule |
| `Log.Sink` | Handle and callback sinks, their serialized writes, forwarding to a sink |

Dependencies run one way: `Log.Types` imports `Log.Base` and `Log.Component`;
filter, format and sink consume those; the facade composes them. `Log.Base` and
`Log.Component` sit below everything else, which lets
[failure attribution](failures.md#module-structure) import `Component` and
`SourceLocation` without the logger.

The opacity of both families is checked by external-client examples:
`cabal test hetoimasia-foundation:foundation-tests --test-option=--match "--test-option=Logging and failure opacity"`.

## Public interface

- A `Logger` is opaque. `mkLoggerWith filter providers sink` is its only
  constructor; `mkLogger` supplies the real clock and thread providers;
  `handleLogger filter handle` adds a borrowed-handle sink and is in `IO`
  because that sink owns the state serializing every logger that shares it.
- There is no global or shared mutable logging state. A subsystem or worker
  receives its logger as a plain argument.
- Emission goes through `logEvent logger level component message fields`, with
  `logDebug`, `logInfo`, `logWarning` and `logError` on top. All take
  `HasCallStack`. An emitted `LogEntry` carries the level, component, message,
  a `Map Text Text` of fields, the breadcrumbs, a UTC timestamp, the thread
  identity and an optional `SourceLocation`.
- Emission is synchronous on the calling thread, and a sink exception
  propagates to the caller. Logging at `Error` raises nothing by itself.
- A `LogSink` is a write and a flush. The caller owns its resources and its
  concurrency policy ([Sinks](#sinks)).

## Component names

A `Component` is a validated value: one or more segments matching
`[a-z][a-z0-9_-]*` joined by `.`, such as `gpu.vulkan` or `lua`.

- `mkComponent` validates and rejects an invalid name with a message quoting
  it; it never normalizes. Configuration, files and user input go through it.
- `unsafeComponent` is for source literals only and fails loudly with the same
  message. `componentText` reads the name back.
- Rejected: uppercase (`Gpu.Vulkan`), an empty segment (`gpu..vulkan`, `gpu.`),
  a leading digit or space, the empty name, and the standalone names `all` and
  `none`, which are reserved Debug selectors.
- **Matching is exact everywhere.** There is no hierarchy, registry or central
  enum: `gpu` and `gpu.vulkan` are unrelated names.

## Filtering

`LogFilter` is a pure configuration value; it is never reconfigured in place.
`defaultLogFilter` is the defaults column.

| Field | Meaning | Default |
| --- | --- | --- |
| `filterEnabled` | Master switch | `True` |
| `filterGlobalLevel` | Threshold for components without an override | `Info` |
| `filterComponentLevels` | Exact per-component thresholds | empty |
| `filterDebug` | Which components may emit `Debug`: `DebugNone`, `DebugAll` or `DebugComponents` | `DebugNone` |
| `filterSource` | Whether an entry records its call site | `True` |

Decisions, in order:

1. `filterEnabled = False` suppresses everything.
2. A `Debug` entry is emitted only when `filterDebug` selects its component.
   **A threshold never enables `Debug`**: a component level of `Debug` under
   `DebugNone` still suppresses that component's `Debug` entries.
3. Any other level is emitted when it meets its component's threshold, or the
   global one when the component has no override.
4. `filterSource = False` yields no source location.

Filtering happens before the message or fields are forced and before either
metadata provider runs: a suppressed entry whose payload would throw does not
throw, and costs no timestamp or thread lookup.

## Startup configuration

Configuration is resolved once at startup. The foundation supplies pure parsers
(`parseLogLevel`, `parseComponentLevels`, `parseDebugSelection`) and
`resolveLogFilter variables lookup base`, which assembles a filter over a
caller-supplied lookup. The parsers take values, never variable names, and the
names (`LogVariables`) and the lookup are arguments: the spelling of the
variables and the environment access belong to the application, and a test
supplies a pure lookup.

The console executable chooses these:

| Variable | Configures | Accepted form | Default |
| --- | --- | --- | --- |
| `HETOIMASIA_LOG_LEVEL` | `filterGlobalLevel` | `debug`, `info`, `warn`, `warning` or `error`, case-insensitively | `info` |
| `HETOIMASIA_LOG_LEVELS` | `filterComponentLevels` | comma-separated `component=level` pairs, such as `gpu.vulkan=warn,lua=info` | no overrides |
| `HETOIMASIA_DEBUG` | `filterDebug` | exactly `none`, exactly `all`, or a comma-separated component list | `none` |

`filterEnabled` and `filterSource` stay programmatic; `resolveLogFilter` carries
the base's values through. Surrounding whitespace is trimmed from a value, each
list entry and each side of a pair; whitespace inside a name is not accepted. A
repeated component in `HETOIMASIA_DEBUG` collapses to one.

An absent variable keeps its default. **An empty or malformed value is an
error, never a default:**

| Rejected | Reason |
| --- | --- |
| `HETOIMASIA_LOG_LEVEL=verbose`, `=warnings`, `=` | not one of the five spellings, or empty |
| `HETOIMASIA_LOG_LEVELS=gpu.vulkan` | no `=` in the entry |
| `HETOIMASIA_LOG_LEVELS=gpu.vulkan=warn,gpu.vulkan=info` | the same component twice |
| `HETOIMASIA_LOG_LEVELS=Gpu.Vulkan=warn` | `mkComponent` rejects the name |
| `HETOIMASIA_LOG_LEVELS=gpu.vulkan=warn,` | an empty entry |
| `HETOIMASIA_DEBUG=NONE`, `=All` | the selectors are lowercase |
| `HETOIMASIA_DEBUG=all,gpu.vulkan` | a selector combined with names |

### Failure behavior

The application reads the environment once, each variable a single time, before
any value is parsed and before either command-line path runs. A present but
invalid value fails startup: one line naming the variable and the reason goes to
stderr and the process exits non-zero, before any entry is emitted and before
the application action runs. `--help` validates the same configuration and
fails the same way.

```text
$ HETOIMASIA_LOG_LEVEL=bogus hetoimasia --smoke
HETOIMASIA_LOG_LEVEL: invalid level "bogus": expected debug, info, warn, warning, or error
```

The diagnostic is always one line: a rejected value is quoted and escaped by
[the record layout's rule](#quoting-and-escaping), so a value carrying a
newline cannot forge a second line. Help text is application output on stdout,
visible at any threshold.

```sh
hetoimasia --smoke                                    # three records: runtime, console, runtime
HETOIMASIA_LOG_LEVEL=warn hetoimasia --smoke          # none: the smoke path only emits at Info
HETOIMASIA_LOG_LEVELS=runtime=warn hetoimasia --smoke # the console record only
HETOIMASIA_DEBUG=gpu.vulkan,lua hetoimasia --smoke    # those two components may emit Debug
```

## Record layout

`formatEntry` renders one entry as exactly one line with no terminating newline;
a sink adds its own terminator. Segments are separated by single spaces, and an
optional segment is omitted rather than left empty:

```text
<time> <LEVEL> <component> thread=<n> [src=<file>:<line>] [crumbs=<a>><b>] msg=<message> [<key>=<value> ...]
```

| Segment | Content |
| --- | --- |
| `<time>` | UTC, ISO 8601, exactly three fractional digits, `Z` suffix; sub-millisecond digits are truncated, not rounded |
| `<LEVEL>` | `DEBUG`, `INFO`, `WARN` or `ERROR` |
| `<component>` | The validated name, never quoted |
| `thread=` | The numeric GHC thread identity; omitted when `formatThread` is off |
| `src=` | Only when the entry carries a source location |
| `crumbs=` | Only with at least one breadcrumb, joined by `>` |
| `msg=` | Always present |
| fields | After the message, sorted by key |

### Quoting and escaping

Every piece of text in a record (message, breadcrumb, field key, field value,
source filename, thread) goes through one rule, so nothing a caller supplies
can split a record or forge a segment. Text is written bare when it is nonempty
and holds only printable non-space characters other than the four reserved
ones, `"`, `\`, `=` and `>`. Anything else is wrapped in double quotes with
`\"`, `\\`, `\n`, `\r` and `\t` escapes and every other control character as
`\uXXXX` in uppercase hex. Empty text renders as `""`. Non-ASCII text is
printable. Field keys are not validated and follow the same rule. In
`src=<file>:<line>` the filename is quoted and the line number stays outside
the quotes.

```text
2026-09-10T12:34:56.789Z INFO runtime thread=3 msg="Starting hetoimasia"
2026-09-10T12:34:56.790Z WARN gpu.vulkan thread=7 src=app/Main.hs:42 crumbs=runtime>gpu msg="Device lost\nretrying" attempt=2 device="Radeon RX"
```

`FormatOptions` holds `formatThread` (emit the `thread=` segment) and
`formatFlush` (flush after every record); `defaultFormatOptions` enables both.

## Sinks

| Sink | Constructor | Behaviour |
| --- | --- | --- |
| Handle | `newHandleSink`, `newHandleSinkWith options` | Borrows the caller's handle. Writes each record as one whole line and serializes every write and flush across all loggers sharing the sink: no interleaving within a line, each producer's order kept, order between threads unspecified. |
| Callback | `callbackSink`, `callbackSinkWith write flush` | Wraps a caller's `LogEntry → IO ()` and a flush (a no-op by default). The callback may be called concurrently and supplies its own synchronization; it must not emit to the same sink recursively. |

- **The serialization belongs to the sink value, not the handle.** Two roots
  writing to one handle must share one sink; two handle sinks over one handle
  are unsupported. Derived loggers share their root's sink automatically.
- `flushLogger` flushes a logger's sink whether or not `formatFlush` is set;
  flushing any derived logger flushes what all of them wrote.
- `writeEntry sink entry` and `flushSink sink` are all a caller holding a sink
  without a logger can do. `writeEntry` forwards a prepared entry unchanged: no
  filter is applied and no metadata provider runs, so an entry carried across a
  thread boundary keeps its timestamp, thread and source attribution. Both keep
  the sink's synchronous write, flush and exception semantics. They exist for
  the [asynchronous adapter](#asynchronous-adapter).

## Ownership and failures

The handle stays the caller's. A handle sink never closes it, never changes its
buffering, and leaves it usable after every logger over it is discarded; set
the buffering before constructing the sink. A derived logger is an immutable
value and holding one is no claim on the handle.

The application's logging scope outlives every subsystem or worker borrowing
its sink. Shut down in this order:

1. Stop and join the producers.
2. Finish subsystem cleanup, which may itself emit diagnostics.
3. Make the terminal report, once, through the boundary chosen to own it.
4. Make the final flush. The [logging lifetime](#logging-lifetime) owns this
   step: after the callback holding steps 1 to 3 has returned or thrown, and
   outside every controlled resource release.
5. Close any handle the application owns, after the lifetime has returned.

Failures:

- A sink failure propagates to the caller of the logging operation, for both
  sink kinds and for `flushLogger`. Asynchronous cancellation is never
  swallowed.
- After a sink exception or an interruption during a write, the handle sink
  releases its serialization state before the exception leaves, so the next
  call on any sharing logger proceeds.
- A failed write may leave a partial record.
- **A sink failure is never reported back through the failing sink**, and an
  error-reporting or cleanup boundary preserves its own primary failure when
  the diagnostic it tried to emit fails too.
- Resource scopes run their cleanup and expose their outcome with no logger, or
  a broken one. How a logger call composes with a scope is in
  [Application lifecycle](resources.md#application-lifecycle).

### Logging lifetime

`Hetoimasia.Runtime.Logging` makes step 4 a boundary. `withLoggingLifetime
logger callback` is an explicit `IO` callback, outside the `Scoped` runner: it
borrows a logger the caller built, lends it through a `LoggingLifetime` handle
and makes the final flush once the callback has finished.
`withHandleLoggingLifetime filter handle` builds one `handleLogger` first; the
console runs both smoke paths through it over `stderr`.

- **The handle lends and records, nothing else.** `lifetimeLogger` is the
  borrowed logger. `recordReport` records what became of one runtime-managed
  reporting attempt: pass it as the recorder of `reportTerminalFailureWith`, or
  give it the `ReportResult` of `reportOutcome`. `recordedReports` reads them
  back. The handle owns no handle, changes no buffering and does not change
  ordinary logging calls. It is not an application environment.
- **The callback owes:** every producer stopped and every component scope
  unwound before it returns, and the one terminal report made inside it. The
  lifetime reports nothing itself.
- **The final flush:** at most one attempt per lifetime, through `flushLogger`,
  with the caller's masking state and ordinary interruptibility. No bounded
  duration is promised. **Never enter a lifetime from a release callback**: a
  release runs under `uninterruptibleMask_`.

Finalization follows the settled outcome:

| Outcome entering finalization | What the lifetime does |
| --- | --- |
| The callback returned; diagnostics usable | Flush once. Return the result only if the flush succeeds; a synchronous flush failure fails the run with the flush's own exception, marked `DiagnosticFailure`. |
| The callback threw synchronously; diagnostics usable | Flush once, then rethrow the callback's failure with its type, value and context. A synchronous flush failure rides on that context as secondary evidence that `flushFailures` reads back. No `CleanupFailure` is forged. |
| A managed reporting attempt already failed | No flush and no new attempt. Return the result, or rethrow the failure with every failed attempt attached as evidence that `failedReports` reads back. |
| The callback threw a failure marked `DiagnosticFailure` | No flush: the failed sink is the one a flush would use. The failure propagates unchanged. |
| The callback is being cancelled | Propagate the cancellation with its context. No report, no flush. |
| A cancellation arrives during the flush | Propagate it as itself in place of the settled outcome. The flush is not retried. |

Diagnostic usability comes from explicit provenance only: the
`DiagnosticFailure` mark on what the callback threw, or a `ReportFailed`
recorded on the handle. An exception's type is never consulted and there is no
sink-health registry.

Not owned: the handle behind the sink, its buffering and its closing (step 5).
Configuration parsing and logger construction happen before the lifetime, so a
failure there propagates as its own typed failure with no promise of a record.
The console's resource-smoke path runs `managedResourceSmoke`, which records
its report's outcome on the lifetime.

| State | Owner | Writers | Readers | Thread | Lifetime and reset |
| --- | --- | --- | --- | --- | --- |
| Recorded reporting-attempt outcomes | The `withLoggingLifetime` call | `recordReport`, atomically; nothing is removed | `recordedReports`; finalization, once | Any thread holding the handle | Created empty per call, never shared or reset. A record made after finalization read it is kept and has no effect. |
| The final flush attempt | Finalization | Finalization, at most once | None: its outcome is the lifetime's result or evidence on its failure | The thread that called `withLoggingLifetime` | Not stored. |

Tests: `cabal test hetoimasia-runtime:runtime-tests --test-option=--match "--test-option=Logging lifetime"`.

### Asynchronous adapter

`Hetoimasia.Runtime.AsyncLog` is an **optional** adapter that takes sink I/O off
the producers. An application opts in by injecting a logger built over
`adapterSink`; nothing else in this document changes. It is not the Vulkan
capture path ([below](#vulkan-validation-capture)).

The adapter lifetime **encloses** the logging lifetime, so it outlives every
producer, graphics teardown and the terminal report:

```haskell
sink ← newHandleSink stderr                      -- the caller's, throughout
withAsyncLogAdapter defaultAsyncLogConfig sink $ \adapter →
  withLoggingLifetime (mkLogger filters (adapterSink adapter)) $ \lifetime →
    application (lifetimeLogger lifetime)
```

| `AsyncLogConfig` field | Default | Range |
| --- | --- | --- |
| `asyncQueueCapacity` | 1024 | at least 1 |
| `asyncTextBudget` | 4096 | 256 to 65536 |
| `asyncControlCapacity` | 16 | at least 1 |

`validateAsyncLogConfig` checks the bounds without IO and `withAsyncLogAdapter`
runs it first: an out-of-range value is raised synchronously, before a writer
exists.

- **Admission never waits.** The sink's write prepares a bounded copy of the
  entry on the producer thread and enqueues it in one non-blocking transaction.
  It never waits for space and never falls back to the borrowed sink, so a
  normal return from `logInfo` proves neither admission nor delivery.
  `adapterStatus` (and `adapterStatusSTM`) is the only account of a record.
- **What a queued record retains.** Every textual member is copied and forced
  at admission. Their UTF-8 byte lengths, plus the truncation marker, are
  summed against one per-record total, `asyncTextBudget`. A record keeps at
  most `maxRetainedFields` (64) fields and `maxRetainedBreadcrumbs` (32)
  breadcrumbs.
- **Truncation never rejects a record.** A record over a bound is admitted with
  what fits and carries the reserved field `log.truncated`, whose value names
  the affected categories and dropped counts (`msg,fields=36`); the marker
  takes one of the field entries and its maximum size is reserved inside the
  budget. An oversized component becomes the component `log.truncated`. What
  fits is decided in order: component, thread, source, fields, breadcrumbs,
  then the message, which may shrink to empty. A field or breadcrumb that does
  not fit is dropped whole and counted. A producer field named `log.truncated`
  is removed and counted as dropped.
- **Loss is counted, never hidden.** A record arriving at a full queue is
  discarded and counted by severity. Records still queued when the writer is
  gone are counted as unattempted-abandoned. A record whose write failed or
  was interrupted is counted as that and never replayed.
- **The writer** dequeues in admission order, formats and writes through the
  borrowed sink; no formatting or sink I/O runs on a producer. A synchronous
  write or flush failure latches and terminates the writer: nothing after it is
  attempted, a later failure never replaces the first, and it is never reported
  through the writer.
- **Flushing is a precise barrier.** `flushAdapter` returns a typed
  `FlushOutcome`: every record admitted before the request is written before
  the borrowed sink's flush is attempted, and later records do not extend it. A
  waiter observes writer termination rather than waiting forever. The adapter
  sink's own flush is the same barrier and raises `AsyncLogFlushFailure` on an
  unsuccessful result, so the logging lifetime's final flush keeps its
  precedence. Control requests are bounded by `asyncControlCapacity`, counting
  a request the writer has taken and not settled: an excess request returns
  `FlushRejected` without waiting, and cancelling a waiter releases its slot.
- **Shutdown.** When the callback returns or throws, admission stops, the
  writer drains and the adapter joins it before ending its borrow. It never
  closes the borrowed sink, adds no second final flush and never retries a
  failed one. A latched failure is visible through `adapterStatus` and the
  barrier; the adapter never raises it itself and never replaces an application
  failure.
- **Cancellation.** The adapter requests the writer's cancellation, then
  performs a protected drain with the borrowed sink still live, as
  [the worker contract](workers.md) drains a group. The original outcome
  propagates unchanged; the backlog is counted as unattempted-abandoned.
  **An uncancellable sink, such as a foreign call, can hold the lifetime open
  indefinitely**: the writer is never detached and there is no deadline.

Pure record preparation (the budget, the limits, the marker, the detached copy)
is in the private `Hetoimasia.Runtime.AsyncLog.Entry`; admission evaluates it on
the producer thread.

| State | Owner | Writers | Readers | Lifetime and reset |
| --- | --- | --- | --- | --- |
| Record queue and admission flag | The `withAsyncLogAdapter` call | Admission (any producer thread) while open; the writer, dequeuing; shutdown | The writer; `adapterStatus` as counters | Created empty per call. Closed when the callback returns or throws. |
| Control requests and waiter cells | The call | `flushAdapter`, registering or releasing; the writer, taking and settling | The waiting caller; `statusControlPending` | Bounded by `asyncControlCapacity`. Every registration is released by its waiter, by settlement or by writer termination. |
| Latched writer failure and terminal state | The writer | The writer, once each | `adapterStatus`; every barrier | Never reset. Published however the writer ends. |
| Counters | The call | Admission and the writer, atomically; shutdown | `adapterStatus` | Zero per call, cumulative: nothing resets one. |

Tests: `cabal test hetoimasia-runtime:runtime-tests --test-options='--match=Asynchronous'`;
the forwarding operations, `cabal test hetoimasia-foundation:foundation-tests --test-options='--match=Forwarding'`.

### Vulkan validation capture

The Vulkan backend's validation diagnostics reach the logger beside the
adapter, not through it. The debug-utils callback is C: it copies a capped
record into bounded storage and returns, never running Haskell. A drain worker
then emits each record as an ordinary `logEvent` under
`gpu.vulkan.diagnostics` (info and verbose at `Debug`, warnings at `Warning`,
errors at `Error`), through a borrowed logger it never flushes, and is joined
inside the [logging lifetime](#logging-lifetime). Whether validation failed
never depends on the logger's filter. The contract is
[Vulkan validation diagnostics](vulkan_diagnostics.md).

## Context and precedence

`withFields` and `withBreadcrumb` derive a logger that adds immutable context
and shares its parent's filter, providers and sink. Deriving never mutates the
parent.

- An event's own fields override the logger's context fields; an inner derived
  logger's fields override inherited ones; within one `withFields` list a later
  pair overrides an earlier one with the same key.
- Breadcrumbs accumulate in derivation order, outermost first.
- Give each worker its own derived logger: context lives in the immutable
  value, so two workers cannot observe each other's fields.

## Source attribution

An emitted entry records the outermost call-stack frame: the call site outside
every function that declared `HasCallStack`. A wrapper declaring the constraint
is attributed to its caller. `SourceLocation` holds the file, the line and the
name of the function whose call produced that site.

That site is where the entry was reported. Where a failure was raised is a
different fact, carried on the exception with no logger involved; see
[failures.md](failures.md#origin-is-not-the-log-entrys-source).

## Metadata injection for tests

`MetadataProviders` holds the two values an entry cannot derive from its call:
`metadataClock ∷ IO UTCTime` and `metadataThread ∷ IO Text`. `systemMetadata`
supplies the real clock and the numeric thread identity. A test passes fixed or
counting providers to `mkLoggerWith`: an emitted entry carries exactly what
they returned, and a suppressed one invokes neither.

## Module authoring guide

The conventions a new subsystem follows.

- **Take a logger, never reach for one.** A subsystem receives a `Logger` as a
  plain argument. There is no ambient logger or service locator: a module that
  cannot be given a logger does not log.
- **One stable component name per subsystem**, a source literal through
  `unsafeComponent`. Matching is exact, and a renamed component breaks every
  threshold and Debug selection that named it.
- **Add context at subsystem boundaries.** Derive with `withFields` or
  `withBreadcrumb` where a scope begins (entering a subsystem, accepting a
  request, starting a worker) and pass the derived value inward.
- **Identifiers and values go in fields, not the message.** The message stays
  the same text across occurrences:
  `logWarning logger component "Device lost" [("device", name), ("attempt", "2")]`.
- **Mean one thing by each level.**

  | Level | What belongs at it |
  | --- | --- |
  | `Debug` | Optional detail for someone investigating this component. Off unless selected. |
  | `Info` | Meaningful lifecycle activity: started, finished, connected, loaded. |
  | `Warning` | Degraded or recoverable behavior: work continued, but not as intended. |
  | `Error` | Failed work. Logging it raises nothing; the failure is reported by returning or throwing. |

  **No routine per-frame `Info` output.** A per-frame or per-entity diagnostic
  is `Debug` behind its own component, or a counter summarized at a boundary.
- **Report a propagated failure once, at the boundary that handles it.** A
  subsystem that returns or rethrows has handled nothing and logs no `Error`.
  A boundary that recovers, degrades or ends work through
  `Hetoimasia.Foundation.Recovery` reports through
  [the reporting adapter](#recovery-and-terminal-reports) rather than calling
  `logWarning` or `logError`.
- **Engine libraries log; applications print.** A library writes to no handle
  of its own. Help, results and anything the user asked to see are application
  output on stdout.
- **Construct through one scoped constructor and an opaque handle.** A
  subsystem that owns resources exposes one constructor in `Scoped`, takes a
  pure configuration the application validated before any acquisition, and
  documents every state in one table in its module. See
  [the component convention](resources.md#the-component-convention).
- **Produce inside the logging lifetime.** Anything that emits is stopped and
  joined inside the [logging lifetime](#logging-lifetime) callback. A subsystem
  never flushes the shared sink on shutdown and never enters a lifetime of its
  own over a lent logger.
- **Compose an application through the runner.**
  `Hetoimasia.Runtime.Application.runScopedApplication` enters the lifetime,
  constructs dependencies, supervises, reports and flushes; the application
  does not assemble that order or log the run's terminal failure itself. See
  [the application runner](resources.md#the-application-runner).
- **Supervise workers at checkpoints, not with a monitor.** Start owned workers
  through [`Hetoimasia.Runtime.Supervision`](supervision.md), declaring each
  one's role, disposition and failure classifier. Supervision emits an optional
  worker's `Warning` itself. See
  [where checkpoints go](supervision.md#checkpoints-and-supervised-waits).
- **Logging imposes no error type.** A failing sink is the only exception this
  module raises.

### Usage

A root logger is built once, where the application assembles its services:

```haskell
main ∷ IO ()
main = do
  configuration ← resolveLogFilter logVariables readVariable defaultLogFilter
  logFilter ← either (die . Text.unpack) pure configuration
  withHandleLoggingLifetime logFilter stderr $ \lifetime → do
    let root = lifetimeLogger lifetime
    runApplication root "hetoimasia" (application root)
```

A subsystem takes that logger, derives its scope once and uses its own
component for every entry:

```haskell
renderComponent ∷ Component
renderComponent = unsafeComponent "render"

startRenderer ∷ Logger → Text → IO Renderer
startRenderer logger device = do
  let scoped = withFields [("device", device)] (withBreadcrumb "render" logger)
  logInfo scoped renderComponent "Starting renderer" []
  renderer ← openRenderer device
  logDebug scoped renderComponent "Renderer details" [("queues", "2")]
  pure renderer { rendererLogger = scoped }
```

A worker gets its own derived logger. Its handling is a named action with the
work injected, and `packages/foundation/test/Test/Foundation/Logging/Worker.hs`
mirrors this body:

```haskell
uploadComponent ∷ Component
uploadComponent = unsafeComponent "upload"

-- The terminal reporting boundary for one uploader.
uploaderWorker ∷ Logger → Int → (Logger → IO Int) → IO ()
uploaderWorker logger worker work = do
  let scoped = withFields [("worker", Text.pack (show worker))] logger
  outcome ← try (work scoped)
  case outcome of
    Right uploaded →
      logInfo scoped uploadComponent "Uploads drained"
        [("uploaded", Text.pack (show uploaded))]
    Left failure
      | isCancellation failure → throwIO failure
      | otherwise → reportAbandoned scoped failure

-- One reporting attempt, and never a second one through the same sink.
reportAbandoned ∷ Logger → SomeException → IO ()
reportAbandoned scoped failure = do
  reported ← try (logError scoped uploadComponent "Uploads abandoned"
                    [("reason", Text.pack (show failure))])
  case reported of
    Right () → pure ()
    Left reportingFailure
      | isCancellation reportingFailure → throwIO reportingFailure
      | otherwise → throwIO failure

-- Anything thrown as asynchronous is cancellation, so ThreadKilled,
-- UserInterrupt, and the exception a timeout delivers are classified alike.
isCancellation ∷ SomeException → Bool
isCancellation failure = isJust (fromException failure ∷ Maybe SomeAsyncException)

spawnUploader ∷ Logger → Int → IO ThreadId
spawnUploader logger worker =
  forkIO (uploaderWorker logger worker drainUploadQueue)
```

`uploaderWorker` is a terminal reporting boundary:

| Outcome of the work | Result |
| --- | --- |
| Success | One `Info`. This path is unguarded: a failing `Info` propagates its sink exception. |
| Ordinary failure, working sink | Exactly one `Error`; the worker ends and nothing rethrows. |
| Ordinary failure, `logError` fails synchronously | The work's own exception is rethrown intact after the one attempt. |
| Cancellation from the work | Escapes unchanged and unreported. With `forkIO` and no supervisor it reaches GHC's uncaught-exception handler. |
| Cancellation during the reporting attempt | Escapes as itself, not displaced by the earlier work failure. |

### Recovery and terminal reports

`Hetoimasia.Runtime.Reporting` explains the outcomes of [recovery](recovery.md)
and the evidence of [failures](failures.md) through an injected logger. It lives
in the runtime package so that the foundation never needs a logger.

- `reportOutcome logger component operation outcome` returns a `ReportResult`:
  `NoReport`, `ReportAccepted` or `ReportFailed` with the failure.
- `reportTerminalFailure logger component message fields work` runs the work
  and reports a failure that reaches it. `reportTerminalFailureWith recorder`
  is the same boundary with a recorder called between the attempt and the
  rethrow: it receives `ReportAccepted` or `ReportFailed` exactly when an
  attempt was made. The recorder must neither block nor throw; a
  [logging lifetime](#logging-lifetime) supplies `recordReport`.
- `markDiagnostic`, `raisedByDiagnostic` and `terminalReportAttempted` set and
  read the marks below.

Rules:

- **The boundary that chooses the disposition owns the report**: the code that
  called `recover` and decides what to do with its outcome, or the code that
  stops a failure from propagating. A helper that returns an outcome or
  rethrows reports nothing.
- **Record the outcome before the diagnostic.** Store the availability the
  outcome selects, then call `reportOutcome`. A failed report comes back as
  `ReportFailed` instead of being thrown, so it cannot undo the decision.

  ```haskell
  outcome ← recover loadAudio audioPolicy openAudio
  writeIORef audioAvailability (availability outcome)   -- the decision, first
  _ ← reportOutcome logger audioComponent loadAudio outcome
  ```

- **Levels follow what happened, never the exception's type.**

  | What happened | Report |
  | --- | --- |
  | The first attempt succeeded | None: `NoReport`. |
  | A retry or fallback succeeded | One `Warning`, `Operation recovered`. |
  | Optional work is `Unavailable` | One `Warning`, `Operation unavailable`. |
  | A failure reached the boundary that handles it | One `Error`, with the caller's message. |

- **Report once.** A recovery report summarizes every failed attempt in one
  record. `reportTerminalFailure` makes one guarded attempt, then rethrows the
  failure preservingly with a mark, so an enclosing `reportTerminalFailure`
  rethrows without a second `Error`. A failed attempt is not retried and
  filtering is never bypassed.
- **Diagnostics are best effort here, and only here.** A synchronous failure
  while computing the fields, formatting or writing never replaces the failure
  being reported, never changes an outcome and never reruns the operation.
  Direct `logInfo` or `logError` calls elsewhere still propagate sink failures.
- **A diagnostic's own failure is never reported.** Every emission the adapter
  makes is marked `DiagnosticFailure`. Wrap a boundary's own lifecycle records
  in `markDiagnostic`; `reportTerminalFailure` rethrows a failure raised by one
  without an attempt. The mark is added to synchronous failures only.
- **Cancellation is never reported or displaced.** Anything thrown as
  asynchronous escapes unreported with its context unchanged, including one
  that arrives during a report.
- **Never inside a release, never before protection.** Do not call either
  function from a release callback or between an acquisition and the
  installation of its release; see
  [Application lifecycle](resources.md#application-lifecycle).

The entry's `SourceLocation` is where the boundary was called. Where the
failure was raised goes in fields:

| Field | Value |
| --- | --- |
| `disposition` | `recovered`, `unavailable` or `propagated` |
| `availability` | `available` or `unavailable` |
| `operation` | The recovered or unavailable operation; for a terminal failure, the one whose recorded recovery ended in it |
| `attempts`, `attempts.failed` | Recovered or unavailable: the total attempt count and every failed attempt as `number:kind`, oldest first |
| `recovery` | Terminal: `recorded` when `recover` attached a history, otherwise `unrecorded` |
| `attempts.earlier`, `attempts.terminal` | Terminal: the earlier failed attempts as `number:kind` (`none` when unrecorded), and the propagated attempt's number |
| `recovered.by` | `retry` or `fallback "name"` |
| `reason` | The latest failure's `displayException` text |
| `cleanup.failures`, `cleanup.labels` | Retained cleanup evidence, on a terminal failure |
| `origin` | `engine` when `throwFailure` recorded one, otherwise `unrecorded` |
| `origin.component`, `origin.operation`, `origin.identifiers` | The recorded origin |
| `origin.site`, `origin.function` | Where it was raised; `origin.site=unknown` when no site was recorded |
| `observed.*` | The innermost `withOperationContext` boundary: where the failure was seen, never where it was thrown |

A failure of a recovery's first attempt carries no history and cannot be told
apart from one that never passed through `recover`: its report says
`recovery=unrecorded` and `attempts.earlier=none`. A terminal report's extra
fields win over these on a shared key and are computed inside the guarded
attempt, after the work's scopes have unwound.

Tests: `cabal test hetoimasia-runtime:runtime-tests --test-option=--match "--test-option=Outcome reporting"`.
