# Logging

Current behavior of `Hetoimasia.Foundation.Log`, the public logging facade.
The approved contract and its alternatives live in
[the logging design](logging_design.md) (P-1 and P-2); this document describes
what the code does today.

Scope of this slice: the logger model, validated components, filtering, scoped
context, and injectable metadata. The borrowed-handle layout, serialization
across derived loggers, explicit flushing, and callback sinks are LOG-2 work.
Reading `HETOIMASIA_LOG_LEVEL`, `HETOIMASIA_LOG_LEVELS`, and
`HETOIMASIA_DEBUG`, and the module authoring guide, are LOG-3 work.

## Public interface

A `Logger` is an opaque value. `mkLoggerWith` is its only constructor:

```haskell
mkLoggerWith ∷ LogFilter → MetadataProviders → LogSink → Logger
mkLogger     ∷ LogFilter → LogSink → Logger              -- systemMetadata
handleLogger ∷ LogFilter → Handle → Logger               -- mkLogger + handleSink
```

`mkLogger` is the production constructor: it supplies the real clock and thread
providers. `handleLogger` adds the borrowed-handle sink. There is no global or
shared mutable logging state; a subsystem or worker receives its own logger
explicitly, as a plain argument.

Emission goes through one path, `logEvent`, with per-level helpers on top:

```haskell
logEvent ∷ HasCallStack ⇒ Logger → LogLevel → Component → Text → [(Text, Text)] → IO ()
logDebug, logInfo, logWarning, logError
         ∷ HasCallStack ⇒ Logger → Component → Text → [(Text, Text)] → IO ()
```

The last argument holds the event's own fields. An emitted `LogEntry` carries
the level, component, message, `Map Text Text` fields, the breadcrumb list, a
UTC timestamp, thread identity, and an optional `SourceLocation`.

A `LogSink` is `LogEntry → IO ()`. Emission is synchronous on the calling
thread, and a sink exception propagates to the caller — logging at `Error`
raises nothing by itself. The caller owns the sink's resources and its
concurrency policy. `handleSink` borrows a handle: it writes one line per entry
and neither closes the handle nor changes its buffering. That layout is
provisional, and a message containing newlines is not yet escaped, so it does
not stay on one physical line; LOG-2 settles the final record format.

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
in an unspecified relative order; LOG-2 owns the ordering and serialization
guarantees for handle output.

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

`systemMetadata` supplies the real UTC clock and this thread's identity, and
`mkLogger` uses it. A test builds its logger with `mkLoggerWith` and passes
fixed or counting providers instead, which makes both the entry metadata and
the gating observable: an emitted entry carries exactly the values the
providers returned, and a suppressed one invokes neither.

```haskell
fixedMetadata ∷ MetadataProviders
fixedMetadata = MetadataProviders (pure fixedTime) (pure "ThreadId-fixture")
```

The Hspec suite in [`test/Main.hs`](../test/Main.hs) uses this for the
filtering matrix, payload and provider gating, field precedence, concurrent
context isolation, source attribution through a wrapper, and component
validation.
