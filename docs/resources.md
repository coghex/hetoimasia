# Resources

Current behavior of `Hetoimasia.Foundation.Resource`, the public CPU resource
scope. The approved policy and its alternatives live in
[the resource ownership design](resource_ownership_design.md) (D-1, D-2, and
D-6 through D-8); this document describes what the code does today.

Scope: the scope primitive, ownership and borrowing of the scoped value, the
argument order, the failure table, the mask discipline, what the release
guarantee does and does not cover, and how to inspect and how not to discard
the secondary failures a scope retains.

The continuation facade (`Scoped`, `allocResource`, `locally`, `withScoped`),
the staged composite constructor, runtime composition, and anything involving
Vulkan, GPU completion, retirement queues, ownership transfer, or public early
release are not part of it yet. This module imports no logger, runtime
environment, graphics, or scripting module, and owns no application state.

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
above. The validation catalog covers them through the floor group
`test.engine`; see [validation.md](validation.md).
