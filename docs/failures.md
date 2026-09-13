# Failures

Current behavior of `Hetoimasia.Foundation.Failure`: where an engine failure
came from, what operation it passed through, and how a caller reads that back.
The accepted policy lives in
[the runtime foundation design](runtime_foundation_design.md) (D-4, D-5, P-1,
and P-4); this document describes what the code does today.

Scope: raising an engine failure with its origin, adding operation context at
an outer boundary, native causes, cancellation, inspection, and the caller
patterns that discard evidence. Recovery policy, reporting through the logger,
and component or application lifecycle are not part of it.

The module owns no state, defines no central engine error type or component
taxonomy, and works over any `Exception` instance. A component's exception type
stays with that component. The only things it takes from
[the logging module](logging.md) are the validated `Component` name and the
`SourceLocation` record; it needs no logger.

## Public interface

```haskell
data Operation
operation     ∷ Text → Operation
operationText ∷ Operation → Text

throwFailure
  ∷ (HasCallStack, MonadIO m, Exception e)
  ⇒ Component → Operation → [(Text, Text)] → e → m a

withOperationContext
  ∷ HasCallStack
  ⇒ Component → Operation → [(Text, Text)] → IO a → IO a

failureEvidence          ∷ SomeException    → FailureEvidence
failureEvidenceInContext ∷ ExceptionContext → FailureEvidence
```

```haskell
data FailureEvidence  = FailureEvidence
  { failureCause ∷ FailureCause, failureContexts ∷ [OperationContext] }

data FailureCause     = EngineOrigin FailureOrigin | NativeCause

data FailureOrigin    = FailureOrigin
  { originComponent ∷ Component, originOperation ∷ Operation
  , originIdentifiers ∷ [(Text, Text)], originSite ∷ Maybe FailureSite }

data OperationContext = OperationContext
  { contextComponent ∷ Component, contextOperation ∷ Operation
  , contextIdentifiers ∷ [(Text, Text)], contextBoundary ∷ Maybe FailureSite }

data FailureSite      = FailureSite
  { siteLocation ∷ SourceLocation, siteCallStack ∷ [SourceLocation] }
```

An `Operation` is a stable name chosen in code, such as `load-texture`. The
identifiers are caller-supplied key/value pairs for a particular request, such
as a path or a resource name.

## Raising a failure

`throwFailure` throws the component's own exception with an origin attached to
its `ExceptionContext`:

```haskell
data TextureFailure = TextureMissing FilePath | TextureCorrupt FilePath Int
instance Exception TextureFailure

failTexture ∷ HasCallStack ⇒ FilePath → TextureFailure → IO a
failTexture path = throwFailure textures (operation "load-texture") [("path", Text.pack path)]
```

The exception is not wrapped. Its type, its value, and every annotation already
attached to it are kept, so `catch`, `try`, and `fromException` on
`TextureFailure` match exactly as they would for a plain `throwIO`. That stays
true after `withOperationContext` adds context and after the failure propagates
through nested `withResource`, `withComposite`, and `Scoped` scopes, whose
rethrows preserve context.

The identifiers and the source information are evaluated before the failure is
raised, so the evidence holds only values: names, text, and line numbers. It
holds no handle, borrowed resource, or lazy computation that could need a
closed scope. A faulting identifier raises its own exception in place of the
failure.

Raising needs no logger and writes nothing first. `throwFailure` is `MonadIO`,
so it can be used directly inside a `Scoped` block.

## Caller attribution

The origin's `siteLocation` is the outermost call-stack frame: the call site
outside every function that declared `HasCallStack`. This is the same policy
the logger uses for an entry's source (see
[Source attribution](logging.md#source-attribution)). A component wrapper that
declares the constraint, like `failTexture` above, is attributed to *its*
caller. There is no list of helper names to skip. `siteCallStack` keeps every
frame, innermost first, as `GHC.Stack.getCallStack` orders them.

A wrapper that does not declare `HasCallStack` is attributed to itself, because
the stack ends there. `originSite` is `Nothing` only when the caller's call stack
was empty.

### Origin is not the log entry's source

A log entry's `SourceLocation` is where the entry was *reported*. It exists only
when a logger is present and its source switch is on. A failure's origin is
where the failure was *raised*, and it rides on the exception whether or not
any logger exists. A boundary that later reports the failure through a logger
records its own reporting site in the entry; that never changes the origin the
exception carries.

## Adding operation context

`withOperationContext` runs an operation and adds one `OperationContext` to a
synchronous failure that passes through it:

```haskell
renderFrame ∷ Int → IO ()
renderFrame frame =
  withOperationContext renderer (operation "render-frame") [("frame", tshow frame)] $
    drawScene
```

The failure is rethrown with `rethrowIO`, keeping its type, value, and context.
An origin already attached is untouched, so a boundary never becomes the origin.
`failureContexts` lists every added context in the order it was attached, which
is innermost boundary first. `contextBoundary` is where the boundary was
entered: the observation boundary, not a throw site.

The identifiers and the boundary's source information are evaluated before the
operation runs. A faulting identifier fails the boundary before the operation
starts, so it can never displace a failure being propagated.

## Native causes

A native or library exception, such as an `IOException` from `openFile`, carries
no origin. A boundary around it attaches the known engine operation and where it
was observed, and the exception stays an `IOException` with its own payload. It
is never converted into a textual engine exception.

Inspection distinguishes the two cases. An exception raised by `throwFailure`
has `failureCause = EngineOrigin origin`, with its throw site known.
Any other exception has `failureCause = NativeCause`: no engine origin was
recorded, and the throw site is unknown. No site is invented for it. Any
backtrace `base` itself collected remains in the exception's context, untouched.

## Cancellation

A boundary adds nothing to an asynchronous exception. That includes one thrown
synchronously with an asynchronous type, such as `throwIO ThreadKilled`. It is
rethrown with the context it already had, including annotations attached below
the boundary. A cancellation is therefore never recorded as an engine origin or
given operation context.

## Beside the resource contract

Origin and operation context are annotations on the same context the resource
scopes preserve. An origin-annotated primary failure propagates through
`withResource`, `withComposite`, and `Scoped` with every retained
`CleanupFailure` still reachable through `cleanupFailures`. The failure table,
the mask discipline, and the evidence boundary in [resources.md](resources.md)
are unchanged, and `Scoped` has no catch instance.

## Inspection

`failureEvidence` reads a caught `SomeException`. `failureEvidenceInContext`
reads the context a context-aware catch hands back:

```haskell
outcome ← tryWithContext @TextureFailure (loadTexture path)
case outcome of
  Left (ExceptionWithContext context failure) →
    report failure (failureEvidenceInContext context) (cleanupFailuresInContext context)
  Right texture → use texture
```

Inspection is a pure read. It needs no logger and works the same when logging
is disabled, filtered out, or broken. If more than one origin were ever present,
the earliest attached is reported. `displayExceptionContext` renders each piece
of evidence as one line, such as
`failure origin: gpu.textures load-texture (path=a.png) raised at src/Textures.hs:42 in failTexture`.

Evidence is attached only by `throwFailure` and `withOperationContext`: the
annotation type they use is not exported. The evidence records a caller reads
are ordinary values. Constructing one attaches nothing.

## Caller patterns that discard evidence

As with [cleanup evidence](resources.md#caller-patterns-that-discard-evidence),
recognizing an exception by type and keeping its context are separate
properties. Inspection needs the context, and no helper can recover a context
the caller discarded.

- **A bare typed `try`** (`try @TextureFailure`) returns the value without its
  context. Use `tryWithContext @TextureFailure`, or `try @SomeException` and
  `failureEvidence`.
- **A `try` followed by a plain `throwIO`** throws the value again with a fresh
  context, so the origin and every operation context are gone. Use `rethrowIO`
  on the `ExceptionWithContext` value, or `catchNoPropagate`.
- **A `catch` handler that throws** leaves the original only inside a
  `WhileHandling` annotation. Inspection does not follow that nesting: the
  handler may be throwing a different failure, and reporting the handled
  exception's origin for it would misattribute it. Rethrow preservingly instead.

## Verification

`cabal test hetoimasia-tests --test-show-details=direct --test-options='--match /Failures/'`
runs the `Failures` examples from `test/Test/Engine/Failures/Spec.hs`. They
cover:

- typed catch of the original payload, including through nested `withResource`,
  `withComposite`, and `Scoped` scopes and from inside a `Scoped` block;
- the recorded component, operation, identifiers, and site for a direct call;
- attribution to the caller through an extra `HasCallStack` wrapper;
- two outer contexts in attachment order, with the origin unchanged;
- an origin that survives a later preserving handler;
- evidence lost through a `try` followed by a plain `throwIO`;
- a real `IOException` from `openFile` keeping its type, with no invented throw
  site;
- the engine and native cases distinguished side by side;
- cleanup evidence retained beside an annotated failure;
- a delivered cancellation and a synchronously thrown `ThreadKilled`, both left
  unannotated with their existing context;
- inspection after the owning scope released the resource the identifiers were
  copied from, with no logger.

The validation catalog covers them through the floor group `test.engine`; see
[validation.md](validation.md).
