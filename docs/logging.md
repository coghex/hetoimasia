# Logging

Current behavior of `Hetoimasia.Foundation.Log`, the public logging facade.
The approved contract and its alternatives live in
[the logging design](logging_design.md) (P-1 and P-2); this document describes
what the code does today.

Scope of this slice: the logger model, validated components, filtering, scoped
context, injectable metadata, the record layout, the two sink kinds, flushing,
and the ownership and failure contract. Reading `HETOIMASIA_LOG_LEVEL`,
`HETOIMASIA_LOG_LEVELS`, and `HETOIMASIA_DEBUG`, and the module authoring
guide, are LOG-3 work.

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
