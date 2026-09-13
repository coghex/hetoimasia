# Logging

Current behavior of `Hetoimasia.Foundation.Log`, the public logging facade.
The approved contract and its alternatives live in
[the logging design](logging_design.md) (P-1 and P-2); this document describes
what the code does today.

Scope: the logger model, validated components, filtering, startup
configuration, scoped context, injectable metadata, the record layout, the two
sink kinds, flushing, the ownership and failure contract, and the authoring
conventions new subsystems follow. The logging arc is complete; queues,
rotation, telemetry, JSON output, live reload, and a logging monad are not part
of it.

## Public interface

A `Logger` is an opaque value. `mkLoggerWith` is its only constructor:

```haskell
mkLoggerWith ∷ LogFilter → MetadataProviders → LogSink → Logger
mkLogger     ∷ LogFilter → LogSink → Logger              -- systemMetadata
handleLogger ∷ LogFilter → Handle → IO Logger            -- mkLogger + newHandleSink
```

`mkLogger` is the production constructor: it supplies the real clock and thread
providers. `handleLogger` adds the borrowed-handle sink, and is in `IO` because
that sink owns the state serializing every logger that shares it. There is no
global or shared mutable logging state; a subsystem or worker receives its own
logger explicitly, as a plain argument.

Emission goes through one path, `logEvent`, with per-level helpers on top:

```haskell
logEvent ∷ HasCallStack ⇒ Logger → LogLevel → Component → Text → [(Text, Text)] → IO ()
logDebug, logInfo, logWarning, logError
         ∷ HasCallStack ⇒ Logger → Component → Text → [(Text, Text)] → IO ()
```

The last argument holds the event's own fields. An emitted `LogEntry` carries
the level, component, message, `Map Text Text` fields, the breadcrumb list, a
UTC timestamp, thread identity, and an optional `SourceLocation`.

A `LogSink` is a write and a flush. Emission is synchronous on the calling
thread, and a sink exception propagates to the caller — logging at `Error`
raises nothing by itself. The caller owns the sink's resources and its
concurrency policy. The two kinds and their ownership rules are below.

## Component names

A `Component` is a validated value, not raw text. A name is one or more
nonempty segments matching `[a-z][a-z0-9_-]*` joined by `.`, for example
`gpu.vulkan`, `game.world`, or `lua`.

```haskell
mkComponent     ∷ Text → Either Text Component   -- validating
unsafeComponent ∷ HasCallStack ⇒ Text → Component -- source literals only
componentText   ∷ Component → Text
```

`mkComponent` rejects an invalid name with a message quoting it rather than
normalizing it. `unsafeComponent` is for names written as literals in the
source — it fails loudly with the same message — so configuration, files, and
user input go through `mkComponent`.

Rejected: `Gpu.Vulkan` (uppercase), `gpu..vulkan` and `gpu.` (empty segment),
`1gpu` (leading digit), ` gpu` (leading space), the empty name, and the
standalone names `all` and `none`, which are reserved Debug selectors.

Matching is exact everywhere — in configuration and in output. There is no
hierarchy, registry, or central enum, so `gpu` and `gpu.vulkan` are unrelated
names and a threshold on one says nothing about the other.

## Filtering

`LogFilter` is a pure configuration value that a logger applies; it is never
reconfigured in place.

| Field | Meaning | Default |
|---|---|---|
| `filterEnabled` | Master switch | `True` |
| `filterGlobalLevel` | Threshold for components without an override | `Info` |
| `filterComponentLevels` | Exact per-component thresholds | empty |
| `filterDebug` | Which components may emit `Debug` | `DebugNone` |
| `filterSource` | Whether an entry records its call site | `True` |

`defaultLogFilter` is exactly that row of defaults.

Decisions, in order:

1. `filterEnabled = False` suppresses everything, whatever else is set.
2. A `Debug` entry is emitted only when `filterDebug` is `DebugAll` or a
   `DebugComponents` set containing its component. A threshold never enables
   `Debug`: with `filterComponentLevels` mapping `gpu.vulkan` to `Debug` and
   `filterDebug = DebugNone`, a `Debug` entry for `gpu.vulkan` is still
   suppressed while its `Info` entries are emitted.
3. Any other level is emitted when it meets its component's own threshold, or
   `filterGlobalLevel` when that component has no override.
4. `filterSource = False` yields `entrySource = Nothing`.

Under the defaults, `Info`, `Warning`, and `Error` are emitted for every
component, `Debug` for none, and every emitted entry carries a source location.

Filtering happens before the message or the fields are forced and before either
metadata provider runs. A suppressed entry whose payload would throw when
forced does not throw, and it costs no timestamp or thread lookup. No
allocation or throughput claim is made here beyond that ordering.

## Startup configuration

A `LogFilter` is a value, so configuration is resolved once at startup and never
reconfigured in place. The foundation supplies pure parsers for the three
configurable parts of one, plus an assembly over a caller-supplied lookup:

```haskell
parseLogLevel        ∷ Text → Either Text LogLevel
parseComponentLevels ∷ Text → Either Text (Map Component LogLevel)
parseDebugSelection  ∷ Text → Either Text DebugSelection

data LogVariables = LogVariables
  { variableGlobalLevel     ∷ Text
  , variableComponentLevels ∷ Text
  , variableDebug           ∷ Text
  }

resolveLogFilter
  ∷ Monad m
  ⇒ LogVariables → (Text → m (Maybe Text)) → LogFilter → m (Either Text LogFilter)
```

The parsers take values and never the name of a variable, and `resolveLogFilter`
takes the names and the lookup as arguments, so both the spelling of the
variables and the environment access belong to the application. Another
application over this library is free to use another prefix for the same
contract, and a test supplies a pure or counting lookup instead of the
environment.

The console executable chooses these three:

| Variable | Configures | Accepted form | Default |
|---|---|---|---|
| `HETOIMASIA_LOG_LEVEL` | `filterGlobalLevel` | `debug`, `info`, `warn`, `warning`, or `error`, case-insensitively | `info` |
| `HETOIMASIA_LOG_LEVELS` | `filterComponentLevels` | comma-separated `component=level` pairs, such as `gpu.vulkan=warn,lua=info` | no overrides |
| `HETOIMASIA_DEBUG` | `filterDebug` | exactly `none`, exactly `all`, or a comma-separated component list such as `gpu.vulkan,lua` | `none` |

`filterEnabled` and `filterSource` stay programmatic. No variable controls
them, and `resolveLogFilter` carries whatever the base configuration set for
them through untouched.

Surrounding whitespace is trimmed from a value, from each list entry, and from
each side of a pair, so ` info ` and ` gpu.vulkan = warn ` are accepted.
Whitespace *inside* a name is not: a component name still has to satisfy
[`mkComponent`](#component-names). A repeated component in `HETOIMASIA_DEBUG`
collapses to one selection.

An absent variable keeps its default; an empty or malformed value is an error
rather than a default:

| Rejected value | Reason |
|---|---|
| `HETOIMASIA_LOG_LEVEL=verbose`, `=warnings`, `=` | not one of the five spellings, or empty |
| `HETOIMASIA_LOG_LEVELS=gpu.vulkan` | no `=` in the entry |
| `HETOIMASIA_LOG_LEVELS=gpu.vulkan=warn,gpu.vulkan=info` | the same component key twice |
| `HETOIMASIA_LOG_LEVELS=Gpu.Vulkan=warn`, `=gpu vulkan=warn` | `mkComponent` rejects the name |
| `HETOIMASIA_LOG_LEVELS=gpu.vulkan=warn,` | an empty entry |
| `HETOIMASIA_DEBUG=NONE`, `=All` | the selectors are spelled in lowercase |
| `HETOIMASIA_DEBUG=all,gpu.vulkan` | a selector combined with component names |

### Failure behavior

The application reads the environment exactly once, consulting each variable a
single time before any value is parsed, and it does so before either supported
command-line path runs. A present but invalid value fails startup: one line
naming the variable and the reason goes to stderr and the process exits
non-zero, before any entry is emitted and before the application action runs.

```text
$ HETOIMASIA_LOG_LEVEL=bogus hetoimasia --smoke
HETOIMASIA_LOG_LEVEL: invalid level "bogus": expected debug, info, warn, warning, or error
$ echo $?
1
```

That diagnostic is always one line. A rejected value is quoted and escaped by the
same rule the record layout applies to text (see
[Quoting and escaping](#quoting-and-escaping)), so a value carrying a newline, a
quote, or any other control character cannot split the message or forge a second
line of output:

```text
$ HETOIMASIA_LOG_LEVEL=$'bad\nforged' hetoimasia --smoke
HETOIMASIA_LOG_LEVEL: invalid level "bad\nforged": expected debug, info, warn, warning, or error
```

`--help` validates the same configuration and fails the same way. Help text
itself is ordinary application output on stdout rather than a diagnostic, so it
stays visible at any threshold; diagnostics go through the configured logger.

```sh
hetoimasia --smoke                                    # three records: runtime, console, runtime
HETOIMASIA_LOG_LEVEL=warn hetoimasia --smoke          # none: the smoke path only emits at Info
HETOIMASIA_LOG_LEVELS=runtime=warn hetoimasia --smoke # the console record only
HETOIMASIA_DEBUG=gpu.vulkan,lua hetoimasia --smoke    # those two components may emit Debug
```

## Record layout

`formatEntry` renders one entry as exactly one line of text and returns no
terminating newline; a sink adds its own record terminator. Segments are
separated by single spaces, and an optional segment is omitted entirely rather
than left empty:

```text
<time> <LEVEL> <component> thread=<n> [src=<file>:<line>] [crumbs=<a>><b>] msg=<message> [<key>=<value> ...]
```

| Segment | Content |
|---|---|
| `<time>` | UTC as ISO 8601 with exactly three fractional digits and a `Z` suffix |
| `<LEVEL>` | `DEBUG`, `INFO`, `WARN`, or `ERROR` |
| `<component>` | The validated name, never quoted |
| `thread=` | The numeric GHC thread identity; omitted when `formatThread` is off |
| `src=` | Present only when the entry carries a source location |
| `crumbs=` | Present only when there is at least one breadcrumb, joined by `>` |
| `msg=` | Always present |
| fields | After the message, sorted by key |

Sub-millisecond precision is truncated rather than rounded, so a timestamp never
depends on digits the layout does not show. `2026-09-10T12:34:56.789999Z`
renders as `2026-09-10T12:34:56.789Z`, and a whole second renders as `.000`.

### Quoting and escaping

Every piece of text in a record — message, breadcrumb, field key, field value,
source filename, and thread — goes through one rule, so nothing a caller
supplies can split a record or forge a segment. Text is written bare when it is
nonempty and holds only printable non-space characters other than the four the
layout reserves:

```text
" \ = >
```

Anything else is wrapped in double quotes, with `\"`, `\\`, `\n`, `\r`, and
`\t` escapes and every other control character written as `\uXXXX` with
uppercase hex digits. Empty text renders as `""`.

A component name is validated by `mkComponent` before it can reach an entry, so
it is always bare. A field key is not validated — `withFields` and the emission
helpers take raw `Text` — so it follows the same rule as everything else:
ordinary keys such as `attempt` or `gpu.device-id` are bare, and only a key that
would otherwise disturb the layout is quoted.

Quoting applies to the filename in `src=<file>:<line>` as well, so an unusual
path cannot split a record across lines; the line number stays outside the
quotes. Non-ASCII text is printable and passes through unchanged, quoted only
if it also holds a space or a reserved character.

With fixed metadata, these are the exact rendered lines:

```text
2026-09-10T12:34:56.789Z INFO runtime thread=3 msg="Starting hetoimasia"
2026-09-10T12:34:56.790Z WARN gpu.vulkan thread=7 src=app/Main.hs:42 crumbs=runtime>gpu msg="Device lost\nretrying" attempt=2 device="Radeon RX"
```

`FormatOptions` carries the two output choices; `defaultFormatOptions` enables
both:

| Field | Meaning | Default |
|---|---|---|
| `formatThread` | Whether the `thread=` segment is emitted | `True` |
| `formatFlush` | Whether the sink flushes after every record | `True` |

There is no separate thread-logging API: `formatThread` is the control.

## Sinks

```haskell
newHandleSink     ∷ Handle → IO LogSink                     -- defaultFormatOptions
newHandleSinkWith ∷ FormatOptions → Handle → IO LogSink
callbackSink      ∷ (LogEntry → IO ()) → LogSink            -- no-op flush
callbackSinkWith  ∷ (LogEntry → IO ()) → IO () → LogSink
flushLogger       ∷ Logger → IO ()
```

A handle sink borrows a caller-supplied handle. It writes each record as one
whole line, and it serializes every write and flush across all the loggers
sharing it, so concurrent producers never interleave within a line and each
producer's own order is preserved. Ordering *between* threads is unspecified.

That guarantee belongs to the sink value, not to the handle. Two roots writing
to one handle must share one sink:

```haskell
sink ← newHandleSink handle
let runtime = mkLogger defaultLogFilter sink
    tools   = mkLogger quieter          sink   -- same sink, its own filter
```

Constructing two handle sinks over one handle is unsupported: they serialize
against each other's records not at all. Derived loggers share their root's
sink automatically, so `withFields` and `withBreadcrumb` need no care here.

A callback sink wraps a caller-supplied `LogEntry → IO ()` and a flush action,
which defaults to a no-op for a callback with no flushable state. Callbacks may
receive concurrent calls and supply their own synchronization; a callback must
not emit to the same sink recursively.

`flushLogger` flushes a logger's sink on demand whether or not `formatFlush` is
enabled, and because derived loggers share their root's sink, flushing any one
of them flushes what all of them wrote.

## Ownership and failures

The handle stays the caller's. A handle sink never closes it, never changes its
buffering, and leaves it open and usable after every logger over it is
discarded. Set the buffering you want before constructing the sink.

The application's logging scope outlives every subsystem or worker borrowing
its sink. Shut down in this order:

1. Stop and join the producers, so nothing is still emitting.
2. Finish subsystem cleanup, which may itself emit diagnostics.
3. Flush and close any handle the application owns.

Deriving a logger extends no handle lifetime by itself: a derived logger is an
immutable value sharing its root's sink, and holding one is not a claim on the
handle behind it. These are caller obligations, not a file-owning logging
service; the borrowed `stderr` of the console smoke stays the process's.

Sink failures propagate to the caller of the logging operation, for both sink
kinds and for `flushLogger`. Logging at `Error` does not itself throw — the
level is a severity, not an exception — and asynchronous cancellation is never
swallowed. After a sink exception, or an interruption during a write, the
handle sink releases its serialization state before the exception leaves, so
the next logging call on any sharing logger proceeds rather than deadlocking.

A failed write may leave a partial record: no transactional file write is
promised. A sink failure is never reported back through the failing sink, and
an error-reporting or cleanup boundary must preserve its own primary failure
when the diagnostic it tried to emit fails too.

Generic resource-scope primitives stay out of this module; see
[the resource ownership design](resource_ownership_design.md). A scope must run
its cleanup and expose its outcome with no logger at all, or with a broken one.
Composing the two is the application's obligation, and
[Application lifecycle](resources.md#application-lifecycle) in the resource
contract is where that composition is written down: where a logger call may and
may not go around a scope, why a release collects a bounded lifecycle entry
instead of writing to a sink, how a boundary reports a resource failure once and
still hands the structured outcome to its caller, and how it tells a resource
failure apart from a failure of the diagnostic itself — which is never reported,
because the sink that would carry the report is the one that just failed.

## Context and precedence

A derived logger adds immutable context to a parent and shares the parent's
filter, providers, and sink. Deriving never mutates the parent.

```haskell
withFields     ∷ [(Text, Text)] → Logger → Logger
withBreadcrumb ∷ Text → Logger → Logger
```

Precedence, narrowest first: an event's own fields override the logger's
context fields, and an inner derived logger's fields override those it
inherited. Within a single `withFields` list, a later pair overrides an earlier
one with the same key. Breadcrumbs accumulate in derivation order, outermost
first.

```haskell
let outer = withBreadcrumb "startup" (withFields [("service", "engine"), ("scope", "outer")] root)
    inner = withBreadcrumb "worker"  (withFields [("scope", "inner")] outer)

logInfo inner component "inherited"  []                  -- scope=inner, breadcrumbs [startup, worker]
logInfo inner component "overridden" [("scope", "event")] -- scope=event
logInfo outer component "parent"     []                  -- scope=outer, breadcrumbs [startup]
```

Give each worker thread its own derived logger rather than sharing one mutable
context: context lives in the immutable `Logger` value, so two workers cannot
observe each other's fields. Entries from different threads reach a shared sink
in an unspecified relative order, but each worker's own entries keep theirs and
no record interleaves with another (see [Sinks](#sinks)).

## Source attribution

An emitted entry records the outermost call-stack frame — the call site outside
every function that declared `HasCallStack`. A wrapper that declares the
constraint is therefore attributed to *its* caller, not to the line inside it:

```haskell
emitStartup ∷ HasCallStack ⇒ Logger → IO ()
emitStartup logger = logInfo logger component "starting" []
```

An entry from `emitStartup` reports the site where `emitStartup` was called.
`SourceLocation` holds the file, the line, and the name of the function whose
call produced that site.

That site is where the entry was reported. Where a failure was raised is a
different fact: `Hetoimasia.Foundation.Failure` attributes a failure's origin
with the same outermost-frame policy and carries it on the exception, with no
logger involved. See [failures.md](failures.md#origin-is-not-the-log-entrys-source).

## Metadata injection for tests

`MetadataProviders` holds the two values an entry cannot derive from its call:

```haskell
data MetadataProviders = MetadataProviders
  { metadataClock  ∷ IO UTCTime
  , metadataThread ∷ IO Text
  }
```

`systemMetadata` supplies the real UTC clock and this thread's numeric GHC
identity — the number the `thread=` segment shows, not its `Show` spelling —
and `mkLogger` uses it. A test builds its logger with `mkLoggerWith` and passes
fixed or counting providers instead, which makes both the entry metadata and
the gating observable: an emitted entry carries exactly the values the
providers returned, and a suppressed one invokes neither.

```haskell
fixedMetadata ∷ MetadataProviders
fixedMetadata = MetadataProviders (pure fixedTime) (pure "3")
```

The Hspec suite in [`test/Main.hs`](../test/Main.hs) uses this for the
filtering matrix, payload and provider gating, field precedence, concurrent
context isolation, source attribution through a wrapper, component validation,
and every fixed-metadata record in [Record layout](#record-layout).

The sink checks in the same suite use temporary files and a pipe rather than
fixed providers: intact records and per-producer order across four coordinated
workers, per-entry and explicit flushing against a caller-configured block
buffer, an untouched borrowed handle, propagated write, flush, and callback
failures, and serialization state released after both a failed write and an
interruption mid-write. They coordinate with `MVar`s and use timeouts only to
bound a stuck test.

The `Worker reporting boundary` group runs the guide's own worker body from
[Usage](#usage) against substituted work and sinks: a success diagnostic, a
single error diagnostic for an ordinary failure, an escaping cancellation
delivered to blocked work with no diagnostic at all, a synchronous reporting
failure that preserves the work's exception after one reporting attempt, a
cancellation delivered while the reporting sink is blocked, and a failing
success diagnostic that still propagates. Its two cancellation cases signal
entry through an `MVar` and then block on one the test never fills, so
`killThread` lands at an interruptible point without a sleep.

The startup cases inject a lookup rather than an environment: a recording lookup
shows all three variables consulted exactly once and in order, before any value
is parsed and with nothing consulted afterwards, and the same injection covers
the defaults, the assembled filter, each variable being invalid alone, and the
programmatic master and source switches. The console cases run the built
executable as a child process with all three variables stripped from the
inherited environment and only the one under test set, which is what makes exit
status, the stderr diagnostic, an absent record, and the `--help` path
observable.

## Module authoring guide

These are the conventions a new subsystem follows. They are the reason the
interface looks the way it does, so a module that ignores them gets less out of
it than one that does not.

**Take a logger, never reach for one.** A subsystem receives a `Logger` as a
plain argument and holds it in its own state if it needs to. There is no ambient
logger, no global to initialize, and no service locator to ask: a module that
cannot be given a logger does not log. This is what makes a subsystem testable
with a callback sink and what keeps two subsystems from sharing mutable context.

**Choose one stable component name per subsystem.** Pick it when the subsystem
is written, spell it as a source literal through `unsafeComponent`, and keep it.
Matching is exact, so `gpu` and `gpu.vulkan` are unrelated names and a reader
filtering on one will not see the other. A name that changes between releases
breaks every threshold and Debug selection that mentioned it.

**Add context at subsystem boundaries.** Derive a logger with `withFields` or
`withBreadcrumb` where a scope begins — entering a subsystem, accepting a
request, starting a worker — and pass the derived value inward. Entries then
carry the scope they happened in without every call site repeating it, and the
parent keeps its own context.

**Put identifiers and values in fields, not in the message.** The message says
what happened and stays the same text across occurrences; the varying parts go
in fields, where they are quoted, sorted, and machine-readable. Write
`logWarning logger component "Device lost" [("device", name), ("attempt", "2")]`
rather than interpolating `name` into the message. Fields survive grepping and
future structured output; interpolated text does not.

**Mean one thing by each level.**

| Level | What belongs at it |
|---|---|
| `Debug` | Optional detail for someone already investigating this component. Off unless selected. |
| `Info` | Meaningful lifecycle activity: something started, finished, connected, or loaded. |
| `Warning` | Degraded or recoverable behavior — work continued, but not as intended. |
| `Error` | Failed work. Logging it raises nothing; the failure itself is reported by returning or throwing. |

No routine per-frame `Info` output. A per-frame or per-entity diagnostic is
`Debug`, behind its own component, or it is a counter summarized at a boundary.
An `Info` record that appears sixty times a second makes the level useless for
everything else.

**Report a propagated failure once, at the boundary that handles it.** A
subsystem that returns or rethrows has not handled anything yet, so it should
not also log an `Error` about it: the handling boundary — the one that retries,
degrades, or fails the operation — logs it, with the context it has. Logging at
every frame of the propagation turns one failure into a pile of records that
look like several.

**Engine libraries log; applications print.** A library reports diagnostics
through its injected logger and writes to no handle of its own. Command-line
help, results, and anything the user asked to see are application output on
stdout, which is why they stay visible at any threshold. The console
executable's `--help` text is application output; the records its smoke path
emits are diagnostics.

**Logging imposes no error type.** Nothing here asks a game or engine module to
adopt a shared exception or result type. `logError` is a severity on a record,
not a way to fail, and a failing sink is the only exception this module raises
(see [Ownership and failures](#ownership-and-failures)).

### Usage

A root logger is built once, where the application assembles its services, from
the configuration resolved at startup and a sink over a handle the application
owns:

```haskell
main ∷ IO ()
main = do
  configuration ← resolveLogFilter logVariables readVariable defaultLogFilter
  logFilter ← either (die . Text.unpack) pure configuration
  root ← handleLogger logFilter stderr
  runApplication root "hetoimasia" (application root)
```

A subsystem takes that logger, derives its own scope once, and uses its own
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

A worker gets its own derived logger rather than sharing one mutable context, so
two workers cannot observe each other's fields while their records still reach
the one sink in each worker's own order. Its handling is a named action with the
work injected rather than a lambda inside `forkIO`, so the body a reader sees
here is the body the suite runs:

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
```

The spawn site supplies the work and nothing else:

```haskell
spawnUploader ∷ Logger → Int → IO ThreadId
spawnUploader logger worker =
  forkIO (uploaderWorker logger worker drainUploadQueue)
```

`uploaderWorker` is a terminal reporting boundary: the point where an ordinary
failure stops being propagated and becomes a diagnostic instead. With a working
sink such a failure produces exactly one `Error` record and the worker ends —
nothing rethrows it, because no caller is left to interpret it.

Cancellation never reaches that boundary. An asynchronous exception from the
work escapes unchanged and unreported — no `Error`, no `Info` — because a
diagnostic emitted while cancelling is one more place the cancellation could be
lost, which [Ownership and failures](#ownership-and-failures) forbids. For a
`forkIO`-spawned worker, escaping means escaping the worker action: with no
supervisor in scope it reaches GHC's uncaught-exception handler, and giving the
spawner a way to observe it belongs to
[the resource ownership design](resource_ownership_design.md), not here.

The reporting attempt is guarded, and only it. A synchronous failure from
`logError` is discarded in favour of the work's own exception, which is rethrown
with its type and payload intact: a sink failure is never reported back through
the failing sink, and the boundary keeps its primary failure. A cancellation
arriving during that same attempt escapes as itself rather than being displaced
by the earlier work failure. The success path is deliberately unguarded — a
failing `Info` propagates its sink exception like any other logging call.

The `Worker reporting boundary` group in [`test/Main.hs`](../test/Main.hs) runs
this body verbatim for each of those outcomes.
