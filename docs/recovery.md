# Recovery

Current behavior of `Hetoimasia.Foundation.Recovery`: bounded, classified
recovery around one complete owned operation, and the outcome or preserved
failure it hands back. The accepted policy lives in
[the runtime foundation design](runtime_foundation_design.md) (D-2 through D-7,
P-2, P-3, and P-5); this document describes what the code does today.

Scope: the boundary, its policy, the attempt order, its outcomes, and the
evidence it leaves on a propagated failure. Reporting recovery through the
logger belongs to the runtime adapter described in
[Recovery and terminal reports](logging.md#recovery-and-terminal-reports).
Deadlines and worker supervision are not part of it.

A fallback that hands a live replacement component to the rest of the
application is not `recover` either. The same module's `allocComponent` does
that: it selects among composite alternatives under this same policy, attempt
order, and evidence, and keeps the selected parts alive for the enclosing
scope. Its contract lives with the scopes it extends, in
[Component construction](resources.md#component-construction).

The module takes no logger, emits no diagnostics, and does not import the
logging module. It reads cleanup evidence through
[the resource contract](resources.md) and names operations with the `Operation`
type from [failures.md](failures.md); it changes neither.

## Public interface

```haskell
recover        ∷ Operation → RecoveryPolicy a → IO a → IO (Outcome a)
allocComponent ∷ Operation → RecoveryPolicy (Assembly a) → Assembly a → Scoped (Outcome a)

data RecoveryPolicy a = RecoveryPolicy
  { policyDisposition ∷ Disposition
  , policyBudget      ∷ Int
  , policyClassifier  ∷ AttemptFailure → IO (Maybe (Strategy a))
  , policyWait        ∷ Int → IO () }

data Disposition = Required | Optional
data Strategy a  = Retry | Fallback Operation (IO a)
newtype InvalidRecoveryPolicy = NonPositiveBudget Int

data Outcome a      = Available (Recovered a) | Unavailable Unavailability
data Recovered a    = Recovered
  { recoveredValue ∷ a, recoveredBy ∷ AttemptKind, recoveredFailures ∷ [AttemptFailure] }
data Unavailability = Unavailability
  { unavailableOperation ∷ Operation, unavailableReason ∷ AttemptFailure
  , unavailableEarlier ∷ [AttemptFailure] }

data AttemptKind    = InitialAttempt | RetryAttempt | FallbackAttempt Operation
data AttemptFailure = AttemptFailure
  { attemptNumber ∷ Int, attemptKind ∷ AttemptKind
  , attemptException ∷ ExceptionWithContext SomeException }

data RecoveryHistory = RecoveryHistory
  { historyOperation ∷ Operation, historyAttempts ∷ [AttemptFailure] }
recoveryHistory          ∷ SomeException    → [RecoveryHistory]
recoveryHistoryInContext ∷ ExceptionContext → [RecoveryHistory]
```

## The complete owned operation

`recover` runs exactly the `IO` action it is given. Every scope that action
opens is inside it, so one attempt includes every inner scope's release
obligations, and when an attempt fails its releases have all been attempted
before the boundary looks at the failure. Scopes enclosing the call are not
touched and stay usable afterwards.

```haskell
withScoped (allocResource openCache closeCache) $ \cache → do
  outcome ←
    recover (operation "load-texture") texturePolicy $
      withScoped (allocResource (openFile path ReadMode) hClose) $ \file →
        decodeTexture cache file
  continueWith outcome   -- outside the boundary: runs once, is never retried
```

The extent is exactly that action. Code the caller runs after `recover` returns
is outside it: a failure there is neither caught nor retried, and that code runs
once whether or not recovery happened. This is why recovery is a function over a
complete `IO` operation rather than a catch instance on `Scoped`: a `withScoped`
invocation includes the caller's continuation, and a catch around it would treat
a later caller failure as the operation's and could run the continuation again.
`Scoped` still has no catch instance.

A successful result leaving the boundary is an ordinary value. `recover`
evaluates it to weak head normal form inside the attempt, so a result that fails
to evaluate is that attempt's failure. Anything deeper — a lazy field, a closure,
a borrowed handle — is the operation's responsibility: produce the result fully
while its resources are live, and never return a handle whose owning scope has
closed. A fallback that must hand a live replacement service to the rest of
application startup needs a scoped consumer: use `allocComponent`, described in
[Component construction](resources.md#component-construction).

## The policy

A policy is explicit data the caller supplies for one named operation. There is
no default policy, no policy that retries every `IOException`, and no unbounded
budget.

- **Classifier.** Supplied by the component that knows its own failures. It
  receives one `AttemptFailure` and returns the strategy for a failure it can
  handle — `Retry` the operation given to `recover`, or `Fallback` to a named
  alternative — or `Nothing` for a failure it does not recognize. `Retry` after a
  fallback runs the original operation again.
- **Budget.** The total number of attempts: the initial attempt and every retry
  and fallback. Switching strategy never resets it.
- **Disposition.** `Required` or `Optional`. The caller decides this for the
  operation it is running; it is never a severity attached to an exception type.
- **Wait.** Runs before each later attempt with that attempt's number, for
  example to back off.

`recover` evaluates the policy and validates it before doing anything else. A
budget below one throws `InvalidRecoveryPolicy` before the operation, the
classifier, or the wait runs.

## Attempt order

After an attempt fails, and therefore after its cleanup has finished:

1. **Cancellation propagates.** Anything in the `SomeAsyncException` hierarchy,
   the project's convention for cancellation, is rethrown as itself with its
   existing context and cleanup evidence and nothing added. It is never retried,
   never turned into `Unavailable`, and never replaced by an earlier synchronous
   failure.
2. **Failed cleanup propagates.** A failure whose context retains any cleanup
   evidence (`cleanupFailuresInContext` is non-empty) is not retried and gets no
   fallback. The resource library guarantees a release was attempted, not that it
   left the resource disposed. There is no override that treats failed cleanup
   as complete; recovering despite it needs a component contract proving safe
   postconditions, which this module does not offer.
3. **The classifier is consulted.** Only for the remaining synchronous failures.
   A failure it does not recognize propagates.
4. **Budget remaining:** the wait runs, then the selected strategy starts.
5. **No budget left:** `Required` work propagates the failure; `Optional` work
   returns `Unavailable`.

The two exclusions come before the classifier and before disposition, so an
optional operation never downgrades a cancellation, a failed cleanup, or an
unrecognized failure into `Unavailable`, including when no attempts remain. The
classifier is consulted for the last attempt too, because only a recognized
failure may become `Unavailable`.

The wait and the classifier run with the caller's masking state, outside every
release callback, after the failed attempt's cleanup and before the next
attempt starts. A blocking wait therefore stays cancellable.

## Outcomes

- **`Available`** carries the actual result, `recoveredBy` saying whether it came
  from the initial attempt, a retry, or a named fallback, and every failed attempt
  before it, oldest first.
- **`Unavailable`** is returned only for an `Optional` policy whose last attempt
  failed with a recognized failure. It names the operation, the reason (that last
  attempt), and every attempt before it.
- **A propagated failure** is the latest attempt's own exception: its type,
  value, and context — origin and cleanup evidence included — are kept, so a
  typed catch still matches. When earlier attempts failed, one `RecoveryHistory`
  annotation lists them, oldest first. This holds for exhausted required work
  and for recovery stopped early by an unrecognized failure or failed cleanup.
  A failure on the first attempt propagates with nothing added. The terminal
  cause is never replaced by a generic "retries exhausted" value.

Each `AttemptFailure` keeps the exception with the context it propagated with, so
`failureEvidenceInContext` reads its origin and `cleanupFailuresInContext` its
cleanup evidence:

```haskell
outcome ← tryWithContext @TextureFailure (recover loadTexture policy load)
case outcome of
  Left (ExceptionWithContext context failure) →
    for_ (recoveryHistoryInContext context) $ \history →
      for_ (historyAttempts history) $ \attempt → case attemptException attempt of
        ExceptionWithContext earlier _ →
          inspect (failureEvidenceInContext earlier) (cleanupFailuresInContext earlier)
  Right (Available recovered) → use (recoveredValue recovered)
  Right (Unavailable reason) → disable reason
```

`recoveryHistoryInContext` lists histories innermost boundary first, when one
`recover` runs inside another. History is attached only by `recover`; its
annotation type is not exported. The rendered annotation is one line naming the
operation and each attempt's number and kind, with no exception text.

## Failures of the policy itself

A synchronous failure raised by the classifier, by evaluating the strategy it
selected, or by the wait stops recovery at once. It is not fed back into the
classifier. It propagates with its own context and the failure being handled
attached as a `WhileHandling` annotation — the convention a `catch` handler
follows — and that handled failure carries the history so far. A cancellation
arriving in any of those steps propagates as itself.

## What an operation must guarantee

Recovery does not roll anything back. Cleanup does not undo `IORef` writes,
consumed messages, or external effects, and it does not make an operation
idempotent.

- Select `Retry` only for an operation that has restored, or never disturbed,
  the state its next attempt relies on.
- Select `Fallback` only for an alternative that is valid from whatever state the
  failed attempt left.
- An operation with no established safe replay or fallback must not be given a
  policy that selects one; let its failure propagate.
- A finite budget is an attempt count, not a wall-clock bound. A stuck foreign
  call needs its own deadline.

## Verification

`cabal test hetoimasia-tests --test-show-details=direct --test-options='--match /Recovery/'`
runs the `Recovery` examples from `test/Test/Engine/Recovery/Spec.hs`. They use
injected typed failures, real CPU scopes, an ordered trace, and `MVar`
coordination with no sleeps, and cover:

- a failed attempt's release finishing before the wait and the fallback start;
- an enclosing scope's resource still valid after recovery;
- a first-attempt success, and a result evaluated inside its attempt;
- a caller failure after the boundary neither caught nor retried, with the
  continuation run once;
- a non-positive budget rejected before any effect;
- one budget exhausted across a retry, a fallback, and a change back to retry;
- recovery by retry and by fallback with the correct status and history;
- required exhaustion propagating the latest failure with the earlier attempts,
  their origins, and their cleanup evidence in order;
- optional exhaustion returning `Unavailable`;
- an unrecognized failure, an attempt with cleanup evidence, a classifier
  failure, and a wait failure each propagating as specified;
- earlier history kept when a later attempt is unrecognized or its cleanup fails;
- optional work with a budget of one not downgrading an unrecognized failure, a
  cleanup failure, or a cancellation;
- cancellation during work, classification, the wait, and a fallback escaping
  with its own context and cleanup evidence.

The validation catalog covers them through the floor group `test.engine`; see
[validation.md](validation.md).
