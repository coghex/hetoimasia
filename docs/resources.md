# Resources

Current behavior of `Hetoimasia.Foundation.Resource`, the public CPU resource
scope. The approved policy and its alternatives live in
[the resource ownership design](resource_ownership_design.md) (D-1, D-2, and
D-6 through D-8); this document describes what the code does today.

Scope: the scope primitive, ownership and borrowing of the scoped value, the
argument order, the failure table, the mask discipline, what the release
guarantee does and does not cover, how to inspect and how not to discard the
secondary failures a scope retains, the staged constructor an owner built from
several parts is assembled with, the continuation facade those scopes are
composed in, and how an application composes them with logging.

Anything involving Vulkan, GPU completion, retirement queues, ownership
transfer, or public early release is not part of it yet. This module imports no
logger, runtime environment, graphics, or scripting module, and owns no
application state; [Application lifecycle](#application-lifecycle) describes
what the application does with it, and belongs to the application rather than to
the module.

## Public interface

```haskell
withResource         ∷        IO a → (a → IO ()) → (a → IO r) → IO r
withResourceLabelled ∷ Text → IO a → (a → IO ()) → (a → IO r) → IO r
```

The acquisition comes first and the release second, matching
`Control.Exception.bracket`. Synarchy's release-first order is not carried
over and no compatibility with it is promised.

`withResource` records cleanup failures under a default label.
`withResourceLabelled` takes the operation's label as its first argument, so
evidence retained from several nested scopes says which scope each entry came
from. The two are otherwise identical, and everything below applies to both.

This is not an alias for `bracket`. When the body and the release both fail,
`bracket` reports one of them and discards the other; this scope preserves the
body's failure and retains every cleanup failure beside it.

## Ownership and borrowing

The scope owns the acquired value for exactly the duration of the body. The
body borrows it: the release runs when the body returns or throws, so the value
is already released by the time the scope's caller sees a result.

Do not return the scoped value out of the body, and do not return anything
whose validity depends on it — a handle, a pointer, a lazily read `String`, a
record holding any of those. The type does not prevent it; this contract does.
Return ordinary, fully evaluated results instead.

There is no escape hatch, no transfer operation, and no public early release.
A value whose lifetime must outlast one scope belongs to an owner that has not
been designed yet, not to a scope that returns it.

## The failure table

| Body | Release | Outcome |
|---|---|---|
| Succeeds | Succeeds | The body's result is returned |
| Fails | Succeeds | The original exception propagates unchanged |
| Succeeds | Fails | The scope fails with the release's exception; the body's result is discarded |
| Fails | Fails | The body's failure propagates and every cleanup failure is retained beside it |

Details the table does not spell out:

- A failed acquisition propagates and runs **no** release, because no value
  exists to release. The body does not run either.
- Cancellation is a failure. A body that is cancelled is a body that failed,
  and its release runs.
- The propagating exception keeps its own type, value, and attached context. A
  typed catch above the scope still recognizes it.
- Successful cleanup is never reported for a body that threw or was cancelled.
  A scope with nothing to retain attaches nothing.
- When only the release fails, its exception is primary **and** is retained as
  one labelled entry, so inspection reports it beside any failure an enclosing
  scope adds later.
- Nested scopes append to the evidence they receive and never rebuild the
  primary exception. Entries are ordered by when they were observed during
  unwinding: innermost first.

## Mask discipline

Acquisition runs under `mask`, as `bracket` does, so a blocking acquisition
stays cancellable unless the caller already imposed an uninterruptible mask.
The scope's own handler is installed while still masked, so nothing runs
unprotected between a successful acquisition and its cleanup protection.

The body runs with the caller's masking state restored. An inner scope that
completes normally therefore hands control back to an enclosing body that is
cancellable again: a cancellation requested at that point is delivered there,
and the enclosing scope's release then runs under the protection below.

Each release runs under `uninterruptibleMask_`, and the orchestration around it
stays masked, with no interruptible gap between the releases of one unwind. So
an asynchronous exception aimed at the thread from elsewhere is not delivered
until that release and the remaining releases of the same unwind have finished.
The request is not swallowed: it stays pending until masking permits delivery.

An exception a release raises **itself** is a cleanup failure under the table
above, not an interruption — including one whose type belongs to the
asynchronous-exception hierarchy, such as `throwIO ThreadKilled`. It does not
stop the remaining releases from being attempted.

### What a release may do

A release must have a controlled blocking duration. This is the condition
GHC's own documentation sets for
[`uninterruptibleMask`](https://hackage.haskell.org/package/base-4.21.0.0/docs/Control-Exception.html#v:uninterruptibleMask),
and it is the caller's obligation to establish for the actual operation and its
synchronization. The names `close`, `free`, and `destroy` are not proof.

Closing an exclusively owned file handle and freeing host memory are
candidates. **No fence, queue, or device wait belongs inside a release**, even
with a timeout: a timeout establishes neither completion nor permission to
destroy anything. A release that blocks indefinitely hangs its thread
uninterruptibly, and no timeout inside the scope can rescue it.

### What the release guarantee covers

Each release registered in a scope is attempted exactly once per scope exit,
provided the releases before it return or throw within the contract above. A
release that throws has been attempted, not completed, and is never retried
automatically.

It does not cover:

- **Process termination.** Nothing runs after the process is gone: a signal
  that is not handled, `exitWith` from another thread unwinding past the scope
  in a way the runtime does not survive, or a hard abort.
- **A release that never returns.** The guarantee is that the release is
  invoked, not that it finishes.
- **GPU completion.** This arc establishes CPU scope exit only. A wait placed
  in the body protects nothing when the body throws or is cancelled before
  reaching it. Establishing completion on exceptional exits belongs to the
  future backend contract, and must not be solved by making a release
  interruptible.

## Composite construction

```haskell
data Assembly a          -- Functor, Applicative, Monad
data ReleaseRank

releaseRank   ∷ Int → ReleaseRank
acquirePart   ∷ Text → ReleaseRank → IO p → (p → IO ()) → Assembly p
restoredStep  ∷ IO a → Assembly a
withComposite ∷ Assembly a → (a → IO r) → IO r
```

A composite owner acquires several parts in sequence, may fail between any two
of them, and must release them in an order its own API dictates. One
`withResource` per part cannot express that: it releases in reverse allocation
order, and a part acquired inside another part's body cannot outlive it.

`withComposite` is `withResource` for that owner. An `Assembly` is the
construction, written in `do` notation so a later stage may use what an earlier
one produced:

```haskell
allocation ∷ Device → Assembly Allocation
allocation device = do
  handle ← acquirePart "handle" (releaseRank 0)
             (createHandle device) (destroyHandle device)
  needs  ← restoredStep (queryRequirements device handle)
  memory ← acquirePart "handle memory" (releaseRank 1)
             (allocateMemory device needs) (freeMemory device)
  restoredStep (bindMemory device handle memory)
  pure (Allocation handle memory)

withComposite (allocation device) $ \owned → use owned
```

### Ownership of partial state

At every moment after an acquisition returns, exactly one authoritative release
covers every part acquired so far. `acquirePart` extends that release; nothing
is unregistered to make room for the extension, and the accumulated release is
taken out of the construction when it runs, so no part is released twice.

A failure before the first acquisition releases nothing. A failure at any later
stage — while evaluating a part's declared label or rank, inside an
acquisition, inside a restored step, or at the final binding or publication
step — releases exactly the parts acquired so far, each exactly once, and
propagates the triggering failure as primary. The body never runs on that path,
so no half-built value is ever observable.

### The staged-protection guarantee

The whole assembly runs under `mask`. An acquisition and the installation of
its rollback are one protected step: installing a rollback cannot block, so
there is no interruptible gap between the two. This is the gap Synarchy's
`allocResource'` left open, and closing it is the point of the constructor.

Masking still permits cancellation at an interruptible operation *inside* an
acquisition, which is deliberate: a blocking acquisition stays cancellable, and
nothing was acquired when it is cancelled there. An acquisition that throws
before returning its handle is responsible for releasing whatever it acquired
internally, exactly as an acquisition passed to `withResource` is.

`restoredStep` runs work that acquires nothing with the caller's masking state
restored, as `withResource` restores it around its body. It is legal only
because every part acquired so far is already covered: a cancellation delivered
inside such a step rolls exactly those parts back. It inherits the caller's
state rather than forcing an unmasked one, so a caller that was already masked
stays masked. A step that acquires something belongs in `acquirePart`.

### When part metadata is evaluated

`acquirePart` takes the part's label and its rank as ordinary arguments, so
either can be a thunk — a rank read out of a table, a label built from a name
the caller assembled. Both are evaluated at the start of that stage, **before**
its acquisition runs, because the authoritative release needs both to order and
to label what it releases and must not be able to fail on either.

A label or rank that throws is therefore an ordinary construction failure at
its own stage, and it behaves exactly like one:

- That stage acquires nothing, so it owns nothing to release and contributes no
  cleanup entry. A rejected stage never needs a fabricated label.
- The stages after it and the body do not run.
- The parts acquired before it are released in the declared order, each exactly
  once, and a throwing release among them does not stop the remaining ones.
  Those failures are retained under their own parts' valid labels.
- The fault is primary because it was raised first, not because it displaced
  anything. A failure already being unwound stays primary: when an enclosing
  scope's body has failed and its release constructs a composite whose metadata
  faults, the body's failure remains primary and the fault arrives as that
  scope's own cleanup failure, with the composite's labelled evidence still
  reachable below it. A stage that fails *before* a later part's metadata would
  have thrown stays primary too, because the stage declaring that metadata
  never runs.

Both are forced exactly as far as the `Part` record forces them, so a total
label and rank behave as they always did and nothing is deep-forced. Evaluating
them at release time instead is the defect this rule exists to prevent: a thunk
that throws once the authoritative release has been taken out of the
construction abandons every acquired part without a release attempt and
replaces the failure being unwound with its own.

### The declared release order

The constructor declares the final release order with `releaseRank`. Lower
ranks are released first, and parts sharing a rank are released in acquisition
order. Both the rollback of a failed construction and the release at the end of
a successful body use that declared order. Computing that order demands every
acquired part's rank, and every one of them was evaluated before that part was
acquired, so ordering the release of an acquired part cannot fail.

The order is a property of the API the parts come from, not of when they were
acquired. A buffer is created before the memory behind it, and the correct
release is destroy the buffer, then free the memory — acquisition order, not
the reverse of it. A scope that always released in reverse would free memory
the buffer still referred to. Nothing about the ranks is tied to acquisition:
the same two stages can declare either order.

### Handoff to the enclosing scope

On success the finished value is lent to the body under the borrowing rules
above, and the declared release runs when that body returns or throws. The
release never becomes a value the caller holds. Each release runs under
`uninterruptibleMask_` and the orchestration between them stays masked, so an
asynchronous exception aimed at the thread from elsewhere is not delivered
until the whole declared order has been attempted.

Cleanup failures obey the failure table. Each is retained under its own part's
label, the remaining releases are still attempted, and a failure that triggered
a rollback stays primary. When the body succeeds and releases fail, the first
cleanup failure becomes the scope's exception and the body's result is
discarded, as for a single resource; every labelled failure is retained beside
it, once, including through an enclosing `withResource`.

### Patterns this constructor replaces

- **Delayed registration.** There is no helper that returns an action which
  installs cleanup when it is later run. Cleanup is installed by the stage that
  acquired the part, before that stage returns.
- **Returned cleanup closures.** A constructor does not hand a caller a manual
  release to invoke. Synarchy's `Image.hs` returned one only after several
  acquisitions, and sequenced two releases so that a throwing first release
  skipped the second.
- **Unregistering rollback before publication.** Nothing is removed and
  reinstalled around the final binding or publication step, so there is no
  window in which a part is acquired but unprotected.
- **A dependency scheduler.** `Assembly` is a sequence, not a graph. There are
  no public early-release tokens, and no way to move a part to another live
  owner.

## The continuation facade

```haskell
data Scoped a            -- Functor, Applicative, Monad, MonadIO

withScoped     ∷ Scoped a → forall r. (a → IO r) → IO r
allocResource  ∷ IO a → (a → IO ()) → Scoped a
allocComposite ∷ Assembly a → Scoped a
locally        ∷ Scoped a → Scoped a
```

`allocResource` takes the acquisition first and the release second, as
`withResource` and `bracket` do. Synarchy's release-first order is not carried
over, and the primed compatibility helpers have no successor here.

A `Scoped` value is a scope that has not been entered yet. Binding two of them
nests the second inside the first, so each allocation is one line of a `do`
block instead of one more level of callback indentation:

```haskell
stagedUpload ∷ Device → Scoped Upload
stagedUpload device = do
  staging ← allocResource (createStaging device) (destroyStaging device)
  target  ← allocComposite (allocation device)
  size    ← liftIO (measure staging)
  pure (Upload staging target size)

withScoped (stagedUpload device) $ \upload → run upload
```

The facade changes no lifetime. `withScoped (allocResource acquire release)` is
`withResource acquire release`, and `allocComposite` runs its assembly under
the same staged protection `withComposite` gives it. Every row of the failure
table, the mask discipline, and the retained evidence are the primitive's
unchanged: the direct path and the continuation path produce the same primary
exception and the same ordered secondary failures for the same outcomes.

`Scoped` is opaque and `withScoped` is the only runner. There is no way to
resume a scope's continuation, take a scope apart, or install cleanup for a
resource acquired elsewhere. A scope is built with `allocResource`,
`allocComposite`, `locally`, `pure`, `liftIO`, and the instances above, and is
consumed by running it.

That opacity rests on the representation being closed, not on a check made
while a scope runs. `Scoped` wraps its continuation in an unexported
constructor with no record field, so a client outside the package has no name
for the continuation: it cannot write one of its own into a `Scoped`, and it
cannot rewrite the one a scope it was handed already carries. Record
construction and record-update syntax both need a field label in scope, and a
field label is in scope wherever it is exported — which is why the continuation
is not a field and `withScoped` is an ordinary function over the closed type
rather than its selector. `withScoped`'s name and type are unaffected by that:
it is still applied to a scope and a continuation.

Nothing counts entries or refuses a second one at run time; the guarantee is
that the rewrite cannot be expressed, and it is checked when the client is
compiled. `test/Test/Engine/Resources/Opacity.hs` holds it there, compiling
clients against the built package: a client that replaces the continuation and
a client that names the constructor must both be rejected for exactly that
reason, while a client using only the runner and the allocators compiles,
links, and runs.

`allocComposite` allocates; it is not a second runner. Composite construction
is still written with `acquirePart` and `restoredStep`, and `withComposite`
remains the way to enter such a scope directly.

### The cleanup point

A resource allocated with `allocResource` is released when the enclosing
`withScoped` continuation returns or throws — **not** at the end of the `do`
block that allocated it. The rest of the block, and the final callback given to
`withScoped`, both run inside that resource's lifetime. This is the property
Synarchy's `allocResource'` existed to work around, and `locally` is the
supported way to end a group of lifetimes early.

A failed action in a scope never runs a later acquisition: everything after it
is inside its continuation.

### Release order

One scope releases its own allocations in reverse allocation order, on success,
on failure, and on asynchronous cancellation. That order is the scope's own
lifetime boundary, not a global rule across nested ones: a `locally` releases
its inner allocations before the outer scope resumes, and a composite released
by the scope keeps the order its constructor declared with `releaseRank`. A
different order within one scope needs the composite constructor above, not a
positioning trick.

### `locally`

`locally inner` runs `inner` to completion, releases everything `inner`
allocated, and only then continues the enclosing scope with `inner`'s result.
Staging work whose buffers must be gone before the rest of a block runs is the
case it exists for.

Its result must be an ordinary, fully evaluated value. The inner scope's
allocations are already released when the outer scope resumes, so a borrowed
handle returned from `inner` is a handle whose cleanup has run.

Cleanup failures inside `locally` propagate into the enclosing scope under the
failure table and are retained there as evidence `cleanupFailures` reads back,
beside anything the outer scope's own releases add.

### Borrowing and documented misuse

A scoped callback borrows its values, under the same rules as `withResource`.
Do not return a borrowed value, or anything whose validity depends on one, out
of `withScoped` or `locally`; return ordinary results.

`withScoped scope pure` is the documented misuse: it hands back a handle whose
cleanup has already run. The type does not prevent it — `pure` is a legitimate
continuation when the scope's result is an ordinary value — so this contract
and the examples forbid it for borrowed ones. There is no escape operation, no
transfer operation, and no public early-release token in this arc.

## Inspecting secondary failures

```haskell
data CleanupFailure
cleanupFailureId        ∷ CleanupFailure → CleanupFailureId
cleanupFailureLabel     ∷ CleanupFailure → Text
cleanupFailureException ∷ CleanupFailure → ExceptionWithContext SomeException
displayCleanupFailure   ∷ CleanupFailure → String

cleanupFailures          ∷ SomeException    → [CleanupFailure]
cleanupFailuresInContext ∷ ExceptionContext → [CleanupFailure]
```

A retained failure is structured data, not a rendered message: it carries the
operation's label and the exception together with the context that exception
had when the scope caught it, so its own annotations and backtrace are still
there to examine. Inspection needs no logger.

`cleanupFailures` takes the exception a caller caught and returns the retained
failures in the order they were observed while the scopes unwound.
`cleanupFailuresInContext` is the same for a caller that already holds the
context, from `tryWithContext` or `catchNoPropagate`.

No entry is lost or duplicated as nested scopes unwind. Evidence reached by
more than one route is reported once, while two distinct failures that render
identically stay distinct. Evidence nested inside a `WhileHandling` annotation
is found as well, and so is evidence a release carried out of a scope of its
own.

### What inspection costs

Inspection runs on a failure path, where a caller is already recovering and has
the least room to absorb a surprise, so what it costs is part of this contract
rather than an implementation detail.

Each distinct `CleanupFailure`'s own carried context is expanded once per
inspection, however many routes reach it. Nested releases that each carry the
cleanup context below them offer exponentially many such routes to the same
evidence; expanding each retained failure once is what keeps the cost
proportional to the evidence retained instead of to the number of routes.

What a caller pays beyond that is a scan of the annotations on each expanded
context — every annotation on it is examined, not only the cleanup failures —
together with the work of ordering the result by identity. A `WhileHandling`
annotation carries no identity of its own, so the contexts below one are
followed whenever they are reached rather than being expanded once; a caller
that nests handlers deeply pays for that scanning. Inspection is therefore
bounded by the retained evidence and the annotations sitting beside it, not by
the number of returned failures alone.

Recognizing a repeated failure skips that one entry, never the context holding
it: evidence standing beside an entry already reached, directly or below a
handler, is still reported.

```haskell
outcome ← try (withResourceLabelled "index buffer" acquire release body)
case outcome of
  Right result → use result
  Left (failure ∷ SomeException) →
    report failure (map displayCleanupFailure (cleanupFailures failure))
```

A boundary that reports resource failures through a logger follows the pattern
in [logging.md](logging.md#module-authoring-guide): the scope raises, and the
boundary decides what to log. A broken logger must not erase the outcome.

## Application lifecycle

Scopes and logging are peers. This module imports no logger, and a scope runs
its cleanup and exposes its outcome with no logger at all or with a broken one.
Composing the two is therefore the application's job, and these are the rules
that composition follows. `Hetoimasia.Runtime.Resources.resourceSmoke` is the
worked example: the console executable runs it as `--resource-smoke`, and the
suite runs the same body with failures injected.

### Where a logger call may go

**Never between an acquisition and its protection.** Nothing that can fail on
its own belongs there, and a sink write can fail. With the facade there is no
temptation to put one there: the continuation the facade enters is already
covered by that allocation's release, so an acquisition record emitted from it
is emitted after the resource is protected.

```haskell
smokeScope ∷ Logger → Ledger → ReleaseOutcomes → Scoped SmokeResources
smokeScope scoped ledger outcomes = do
  workspace ←
    allocResource
      (openSlot ledger "workspace")
      (closeSlot ledger (onReleaseWorkspace outcomes))
  liftIO $
    logInfo scoped resourceComponent "Acquired resource"
      [("resource", slotName workspace), ("id", slotId workspace)]
  channel ← allocComposite (channelAssembly ledger outcomes)
  liftIO $
    logInfo scoped resourceComponent "Acquired composite"
      [ ("resource", "channel")
      , ("buffer", slotId (channelBuffer channel))
      , ("store", slotId (channelStore channel))
      ]
  pure (SmokeResources workspace channel)
```

**Never inside a release.** A release runs under `uninterruptibleMask_` and must
have a controlled blocking duration; a sink write has none, and a sink that
fails would then be a cleanup failure of a resource that was destroyed
perfectly well. Collect a bounded lifecycle entry in the release and emit it
after the scope has unwound:

```haskell
closeSlot ∷ Ledger → IO () → Slot → IO ()
closeSlot ledger injected slot = do
  entries ← readIORef (slotEntries slot)
  atomicModifyIORef' (ledgerReleased ledger) $ \released →
    (Released (slotName slot) (slotId slot) (length entries) : released, ())
  writeIORef (slotOpen slot) False
  injected
```

The record is appended before anything can fail, so evidence shows every
release that was attempted rather than only those that succeeded, and the
destruction happens whether or not the diagnostic later reaches a sink. A
failed lifecycle log never skips a destruction, because no log runs inside one.

### The reporting boundary

A boundary that turns a resource failure into a diagnostic follows the worker
example of [the logging contract](logging.md#usage), with one difference: that
worker is terminal and swallows what it reported, while a boundary with a caller
must hand the structured outcome on. The rules:

- Classify anything thrown as asynchronous as cancellation and let it escape
  unreported. A record emitted while cancelling is one more place the
  cancellation could be lost.
- Report an ordinary failure — of a resource, of a release, or of the work —
  exactly once, with its context, which means the evidence
  `cleanupFailuresInContext` reads out of it rather than a rendered message.
- **A resource failure and a diagnostic failure are different things.** When
  what failed is the sink a lifecycle record was written to, there is no second
  sink to say so through and the one that just failed is not it: release
  everything, then propagate with no reporting attempt at all. An exception's
  type cannot tell you which it was — an `IOException` from a sink and an
  `IOException` from a release look alike — so mark the emission and check the
  mark. The example annotates every lifecycle record it emits with
  `DiagnosticFailure`, which rides on the exception's context through the
  scope's preserving rethrows.
- Make the one attempt guarded, and never a second one. A synchronous failure
  from that attempt is discarded in favour of the original, and a cancellation
  arriving during it escapes as itself.
- Rethrow preservingly. `rethrowIO` on the value `tryWithContext` returned keeps
  the primary exception's type, its value, and its retained evidence, so the
  caller can inspect the same outcome the boundary just reported.
- Never report successful completion for an action that threw or was
  interrupted.

```haskell
resourceSmoke ∷ Logger → ReleaseOutcomes → SmokeWork → IO Int
resourceSmoke logger outcomes work = do
  ledger ← newLedger
  outcome ← trySmoke (runSmoke scoped ledger outcomes work)
  case outcome of
    Right entries → pure entries
    Left primary@(ExceptionWithContext context failure)
      | isCancellation failure → rethrowIO primary
      | raisedByDiagnostic context → rethrowIO primary
      | otherwise → do
          released ← recordedReleases ledger
          reportAbandoned scoped released context failure primary
  where
    scoped = withBreadcrumb "resource-smoke" logger

-- Marks an exception raised by one of this demonstration's own lifecycle
-- diagnostics, rather than by a resource, a release, or the injected work.
data DiagnosticFailure = DiagnosticFailure
  deriving (Eq, Show)

instance ExceptionAnnotation DiagnosticFailure where
  displayExceptionAnnotation _ = "raised by a lifecycle diagnostic"

lifecycle ∷ IO () → IO ()
lifecycle = annotateIO DiagnosticFailure

raisedByDiagnostic ∷ ExceptionContext → Bool
raisedByDiagnostic context =
  not (null (getExceptionAnnotations context ∷ [DiagnosticFailure]))

-- One reporting attempt for an ordinary failure, and never a second one
-- through the same sink.
reportAbandoned scoped released context failure primary = do
  reported ← tryAny (logError scoped resourceComponent "Resource smoke abandoned" fields)
  case reported of
    Right () → rethrowIO primary
    Left reportingFailure
      | isCancellation reportingFailure → throwIO reportingFailure
      | otherwise → rethrowIO primary
  where
    evidence = cleanupFailuresInContext context
    fields =
      [ ("reason", Text.pack (displayException failure))
      , ("released", renderNames released)
      , ("cleanup.failures", number (length evidence))
      , ("cleanup.labels", renderLabels evidence)
      ]
```

The emission of the lifecycle records sits inside that boundary too, but on the
diagnostic side of it. If the sink fails while the lifecycle is being reported,
everything has already been released, the marked exception takes the second
branch above, and it propagates with nothing further written — the caller
learns that the sink failed by receiving the sink's own exception, which is the
only place that news can still go.

### Shutdown order

The order is the one [the logging contract](logging.md#ownership-and-failures)
establishes, and nothing here changes it:

1. Stop and join the producers, so nothing is still emitting.
2. Finish subsystem cleanup, which may itself emit diagnostics.
3. Flush and close any handle the application owns.

Step 2 is where a scope unwinds, and step 3 is why the lifecycle records
collected during that unwind are emitted before it. The console executable owns
no handle: its sink borrows the process's `stderr`, which it never closes and
never rebuffers, so its step 3 is empty. An application that opened its own log
file closes it there — after the scopes have unwound, never before.

### What the demonstration owns

Two resources through the facade, and nothing that outlives the process. The
workspace is a plain `allocResource`; the channel is an `allocComposite` of a
buffer and the backing store it is bound to, released in that declared order —
acquisition order, because what holds the reference goes before what it refers
to — while the enclosing scope releases the workspace it allocated first last.
There is no file, no thread, and no service: ownership is what the example
shows, and none of those is needed to show it.

Cleanup failures from the composite carry that constructor's own part labels;
the workspace's carry `withResource`'s default label, because the facade's
`allocResource` takes no label. Nesting a labelled `withResourceLabelled` by
hand is the way to name one today.

## Caller patterns that discard evidence

Recognizing an exception by type and keeping its attached context are separate
properties. Two ordinary-looking patterns keep the former and throw away the
latter, and no scope can recover what its caller has discarded.

**A bare typed `try`.** `try @IOException` or `try @ErrorCall` hands back the
concrete exception value. It has the right type and the right value, and no
context — so `cleanupFailures` on it reports nothing.

```haskell
-- Loses the evidence:
outcome ← try @ErrorCall scope

-- Keeps it: a context-aware typed catch.
outcome ← tryWithContext @ErrorCall scope
case outcome of
  Left (ExceptionWithContext context (ErrorCall message)) →
    report message (cleanupFailuresInContext context)
  Right result → use result
```

`try @SomeException` keeps the context, reachable through
`someExceptionContext`, so `cleanupFailures` works on its result directly.

**A `try` followed by a plain `throwIO`.** Re-raising a caught value with
`throwIO` starts a fresh context, and the evidence is gone. An ordinary `catch`
handler that does the same leaves the original only nested inside a
`WhileHandling` annotation; `cleanupFailures` does search there, but do not
rely on incidental handler nesting to carry evidence.

```haskell
-- Loses the evidence:
Left failure ← try @SomeException scope
throwIO failure

-- Keeps it: rethrow with the exception's own context.
Left failure ← try @SomeException scope
rethrowIO (ExceptionWithContext (someExceptionContext failure) failure)

-- Or do not take it apart at all:
scope `catchNoPropagate` \caught → case caught of
  ExceptionWithContext context (_ ∷ SomeException) → do
    note (cleanupFailuresInContext context)
    rethrowIO caught
```

Inside the scope module every rethrow already uses a preserving path, so an
annotation attached below a scope is directly reachable above it and the
primary exception is never rebuilt. See GHC's
[`rethrowIO`](https://hackage.haskell.org/package/base-4.21.0.0/docs/Control-Exception.html#v:rethrowIO)
and
[`catchNoPropagate`](https://hackage.haskell.org/package/base-4.21.0.0/docs/Control-Exception.html#v:catchNoPropagate).

## Verification

`cabal test hetoimasia-tests --test-show-details=direct` runs the `Resources`
examples from `test/Test/Engine/Resources/Spec.hs`, which drive every row of
the failure table, the failed acquisition, ordered nested evidence, the
cancellation and throwing-release cases of the mask discipline, inspection
through `WhileHandling`, each internal rethrow site, and both evidence losses
above. The composite examples in the same file add a failure injected before
and after each acquisition and at the binding step, the declared release order
in both its acquisition-order and its reordered form, a throwing rollback
release, the cancellation cases above, and the whole construction nested inside
`withResource`. The `Composite part metadata` group adds a throwing rank and a
throwing label at a later stage, each asserting which parts were acquired and
which were released: alone, ahead of a later stage that would itself have
failed, with an earlier part's release throwing while the remaining one is
still attempted, and beneath an enclosing scope whose body has already failed.
One further example owns two real file handles and asserts both are closed and
the rejected stage's file was never opened, and one asserts that an earlier
stage's failure stays primary when a later part's metadata would have thrown.
They drive it through the fake buffer of
`test/Test/Engine/Resources/Buffer.hs`, which models exactly the four steps
this contract needs and ships in no library.

The facade examples in the same file add the cleanup point observed from the
final callback, reverse-allocation release on success, failure, and
cancellation, a failed action leaving a later acquisition unrun, the `MonadIO`
path, composition through `fmap` and `<*>`, the direct and continuation paths
agreeing on one resource and on nested ones, `locally` releasing before the
outer scope resumes while its ordinary result survives, a `locally` cleanup
failure reaching the outer scope's evidence, and two composites allocated
through the facade keeping their declared order while the scope unwinds in
reverse.

The `Resource evidence inspection cost` examples in
`test/Test/Engine/Resources/Cost.hs` cover
[What inspection costs](#what-inspection-costs). They build twenty and then
forty nested scopes whose releases each run the next scope, with the innermost
release throwing, and hold each of `cleanupFailures` and
`cleanupFailuresInContext` to a fixed allocation budget — 128 MiB at the
shallower depth and 512 MiB at the deeper one — measured with `GHC.Stats`
across garbage collections, with the fixture built before the interval opens
and the returned failures and their order asserted after it closes. Two depths
are what separate a changed growth rate from a constant factor. The suite is
built with `-with-rtsopts=-T` so those statistics exist; an example that finds
them missing fails rather than reporting a budget as met. A measured inspection
that overruns a much larger reporting bound is abandoned and named as such, so
an unbounded traversal fails these examples in seconds instead of running for
hours.

The `Console resource smoke` examples in
`test/Test/Engine/Resources/Smoke.hs` cover
[Application lifecycle](#application-lifecycle) by running
`Hetoimasia.Runtime.Resources.resourceSmoke` — the body the console executable
runs — with a failure injected into the work, into one release, into two
releases at once with the report failing too, and into the sink of a lifecycle
record after acquisition — which releases everything and then propagates with
no reporting attempt, beside a companion example raising the same sink
exception from the work instead, which does get its one report — plus a
cancellation delivered to the work and another delivered while the report
blocks. Each asserts what a caller sees: the
exception that propagated, the evidence `cleanupFailures` reads out of it, the
records that reached the sink, and which releases ran. One further example
drives the body through a handle sink over a temporary file the example owns,
and closes that handle only after the scope has unwound, so every cleanup
record is in the file and the borrowed handle was neither closed nor rebuffered
by the sink. The `Console startup` group in `test/Main.hs` runs
`--resource-smoke` as a child process for the record sequence and for the quiet
path at a `warn` threshold. The validation catalog covers all of them through
the floor group `test.engine`; see [validation.md](validation.md).
