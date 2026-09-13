# Supervision

Current behavior of `Hetoimasia.Runtime.Supervision`: the runtime layer that
turns the raw worker evidence of [workers.md](workers.md) into decisions on the
application thread, through explicit checkpoints and supervised STM waits. The
accepted policy lives in [the runtime foundation design](runtime_foundation_design.md)
(D-2 through D-7, D-13, D-15 through D-18, P-12 "Checkpoints, waits, and
failure classification" and "Closing and reporting", and P-13); this document
describes what the code does today.

Scope: the supervision boundary and its control handle, managed startup,
service and job roles, required and optional dispositions, checkpoints and
supervised waits, the classification table, the fatal latch, optional warnings,
closing, and the evidence all of it leaves. The generic application runner, its
services value, dependency disposal, the application's single terminal `Error`
report, and final flushing belong to the application runner (RT-6), not here.

The module depends on `base`, `stm`, `text`, the foundation package's public
modules, and the runtime's own [logging lifetime](logging.md#logging-lifetime)
and [reporting adapter](logging.md#recovery-and-terminal-reports). It does not
reimplement worker ownership, stop, cancellation delivery, or the drain; it
calls `withWorkerGroup`, `startWorkerWith`, `observeCompletion`, and
`closeWorkerGroup` as they are.

## Public interface

```haskell
withSupervision ∷ LoggingLifetime → (RuntimeControl → IO a) → IO a
data RuntimeControl                          -- opaque

data WorkerPolicy = WorkerPolicy
  { policyRole ∷ Role, policyDisposition ∷ Disposition, policyComponent ∷ Component
  , policyClassifier ∷ ExceptionWithContext SomeException → IO Recognition }
data Role        = Service | Job
data Disposition = Required | Optional     -- from Hetoimasia.Foundation.Recovery
data Recognition = Recognized | Unrecognized

startSupervised  ∷ RuntimeControl → WorkerPolicy → WorkerDefinition r → IO (SupervisedStart r)
data SupervisedStart r = WorkerStarted (SupervisedWorker r)
                       | WorkerStartUnavailable (SupervisedWorker r) (ExceptionWithContext SomeException)
                       | WorkerStartRejected
supervisedWorker ∷ SupervisedWorker r → Worker r
stopSupervised   ∷ SupervisedWorker r → IO ()
cancelSupervised ∷ SupervisedWorker r → IO ()
workerStatus     ∷ SupervisedWorker r → STM WorkerStatus
data WorkerStatus = WorkerLive | WorkerCompleted | WorkerStopped
                  | WorkerUnavailable (ExceptionWithContext SomeException)
                  | WorkerFatal (ExceptionWithContext SomeException)

checkRuntime    ∷ RuntimeControl → IO ()
awaitSupervised ∷ RuntimeControl → STM a → IO a

newtype UnexpectedServiceExit       = UnexpectedServiceExit WorkerSummary
newtype UnexpectedWorkerTermination = UnexpectedWorkerTermination WorkerSummary
newtype WorkerCleanupFailed         = WorkerCleanupFailed WorkerSummary
data SupervisedFailure = SupervisedFailure
  { failedWorker ∷ WorkerId, failedLabel ∷ Text, failedSeverity ∷ Severity
  , failedException ∷ ExceptionWithContext SomeException }
data Severity = Fatal | Tolerated
supervisedFailures          ∷ SomeException    → [SupervisedFailure]
supervisedFailuresInContext ∷ ExceptionContext → [SupervisedFailure]
```

## The boundary and the control handle

`withSupervision` is an `IO` callback boundary over one worker group. Call it
inside the scopes of every component its workers borrow, and inside the
logging lifetime it is given: its drain runs before it returns or rethrows, and
optional warnings go through that lifetime while it is still open.

The body receives a `RuntimeControl`. It manages and supervises workers and
does nothing else: it looks up no engine or application service and carries no
application state. It is owned by the application thread. Do not give it to a
worker action; a worker receives its `StopToken` and the component handles its
definition captured, under the [borrowing rules](resources.md#ownership-and-borrowing).
The boundary needs no application runner and is usable on its own.

## Policies and who decides them

The code that starts a worker decides its policy, per worker, when it calls
`startSupervised`:

- **Role.** A `Service` runs until its owner asks it to stop; returning before
  then is a failure. A `Job` is finite; returning is completion, and its result
  stays inspectable through the raw handle, for example with
  `awaitSupervised control (awaitCompletion (supervisedWorker handle))`.
- **Disposition.** `Required` or `Optional`. It is never a severity attached to
  an exception type.
- **Classifier.** Supplied by the component that knows its failures. It returns
  `Recognized` for a failure the component supports once its bounded recovery
  is exhausted, and `Unrecognized` otherwise. It sees a worker's synchronous
  failure, or a synthetic `UnexpectedServiceExit` or
  `UnexpectedWorkerTermination`, and never a failure with retained cleanup
  evidence. It chooses a disposition only; nothing restarts a worker or replays
  a job. Recovery belongs inside the worker, before its outcome is published —
  for instance `allocComponent` in its startup.
- **Component.** The component an optional worker's warning is reported under.

## Managed startup

`startSupervised` performs the foundation handoff with a policy registered in
its preparation step, so supervision owns the worker's policy before any of the
worker's own code runs. Its startup wait is a supervised wait: in one
transaction it reads the fatal latch and every other supervised worker's
terminal state as well as the new worker's startup. It is woken, and gives up
waiting, when a failure is already latched or another worker's outcome is fatal
without consulting a classifier — any failure of a required worker, or failed
cleanup. The new worker is then cancelled and drained by `startWorkerWith`
before the start unwinds, that worker counts as stopped by its owner, and the
fatal failure is handled and rethrown. An owner cancellation of the wait drains
the new worker the same way and propagates.

Once startup ends, the new worker's own outcome, if it already has one, is
handled exactly once, after any failed startup has drained:

- a startup failure that is recognized and optional returns
  `WorkerStartUnavailable`, with its status committed before its one warning;
- a required, unrecognized, or cleanup failure is committed as fatal and
  rethrown;
- a job that acknowledged and already completed returns `WorkerStarted`, with
  status `WorkerCompleted`;
- a service that acknowledged and already exited is judged by the service-exit
  rule below before its starter can return it.

Because the disposition is committed first, no later checkpoint handles or
reports it again. A start after closing returns `WorkerStartRejected` and forks
nothing. Starting a worker is never run through `recover`.

## Checkpoints and supervised waits

Nothing interrupts the application thread. Supervision happens only where the
application asks for it.

- `checkRuntime` handles every pending outcome and rethrows the latched fatal
  failure, if any.
- `awaitSupervised control work` reads pending outcomes and the latch first, in
  the same transaction as `work`. If anything is pending, or a failure is
  latched, `work` is not committed: the outcomes are handled as at a
  checkpoint, a fatal failure is rethrown, and otherwise the wait starts again.
  Only when nothing is pending does `work` commit. A retry therefore waits on
  `work`'s reads and every supervised worker's terminal state together, so a
  worker failure wakes it without a monitor thread.

Place checkpoints:

1. before and after starting a worker;
2. at each iteration of an application loop;
3. before accepting a final result.

Block only in `awaitSupervised`. It supervises framework-owned STM reads and
nothing else: a foreign call, an ordinary `takeMVar`, a blocking read, or any
other user `IO` is not interrupted, and a worker failure during one is handled
at the next checkpoint. No failure-notification exception is injected into the
application thread. A future GLFW event wait must supply its own wake and check
integration.

Handling an outcome follows STM's rules. Pending outcomes are selected in STM
without being marked, classified outside STM, then committed — status set,
worker observed with `observeCompletion` so the group retires it, failures
recorded, latch set — in one transaction that rechecks each worker is still
pending, so one immutable outcome is never handled twice. Only then are
warnings attempted or the failure rethrown, in `IO`. A failure in the caller's
`work` rolls back with nothing marked. A failure that arrives after `work`
committed is handled at the next checkpoint.

## Classification

The owner's request below is the run-exit record's request, or a request the
owner made through `stopSupervised`, `cancelSupervised`, an abandoned start, or
closing.

| Terminal outcome | Status |
|---|---|
| A job returned | `WorkerCompleted`; its result stays on the handle; no warning and no stop |
| A service returned before any stop was requested (run-exit record) | `UnexpectedServiceExit`, judged by the policy |
| Returned, or cancelled, after the owner asked it to stop, with successful cleanup | `WorkerStopped`; the actual result or cancellation stays on the handle, and no successful result is invented |
| Cancelled while its run action had not been asked to stop | `UnexpectedWorkerTermination` carrying the child's cancellation, judged by the policy |
| A synchronous failure of startup or the run action, even after a stop request | That failure with its own type, value, and context, judged by the policy |
| Any retained cleanup failure | `WorkerFatal` whatever the policy: the failure itself, or `WorkerCleanupFailed` for a cancelled worker |

Judged by the policy: an `Optional` worker whose classifier returns `Recognized`
is `WorkerUnavailable`, and everything else — any failure of a `Required`
worker, and any `Unrecognized` failure — is `WorkerFatal`. An optional worker
is never downgraded past an unknown failure or failed cleanup. A cancellation is
never rethrown to the observer: it is always carried inside a synthetic typed
failure whose `WorkerSummary` holds the child's actual terminal evidence,
cleanup failures included.

A classifier that throws synchronously stops supervision: its exception becomes
the worker's fatal status, with the worker failure it was handling attached as
a `WhileHandling` annotation, the convention [recovery](recovery.md#failures-of-the-policy-itself)
uses. A cancellation during classification propagates as the owner's
cancellation, commits nothing from that batch, and the boundary still drains
every worker.

## Optional warnings

When a worker becomes `WorkerUnavailable`, its status is committed first, in the
same transaction that consumes its one warning attempt. The warning is then
attempted outside STM and outside any release, through `reportOutcome` as an
`Operation unavailable` `Warning` under the policy's component, and its
`ReportResult` is recorded on the logging lifetime with `recordReport`. It is
skipped when a managed report recorded on that lifetime has already failed. It
is never attempted again, and a failed warning does not change the status, so
it cannot make the worker available.

## The fatal latch and evidence

The first fatal status committed in an invocation is latched as its primary
failure, separately from the observation that produced it. Every later
`checkRuntime`, `awaitSupervised`, and the boundary's exit rethrow it again, so
catching a delivery neither clears it nor makes the run successful.

When one checkpoint commits several failures, the primary is the fatal failure
registered first. Registration order is stable; it is not a claim about which
thread failed first. An optional failure registered earlier never becomes
primary over a fatal one. Every other committed failure, fatal or tolerated, is
retained beside the propagated failure as a `SupervisedFailure` with its own
context, and `supervisedFailures` reads them back in commit order. A delivered
synchronous worker failure keeps its type, value, context, origin, and cleanup
evidence.

## Closing

When the body returns:

1. `closeWorkerGroup` snapshots every already-published, unobserved outcome,
   closes registration, and requests a stop from every live worker, in one
   transaction; then it waits, cancellably, for the drain. A later start is
   `WorkerStartRejected`.
2. With every worker drained and its dependencies still live, each outcome not
   yet handled is handled. An outcome in the snapshot is judged exactly as at a
   checkpoint, so a service that had already exited — or whose run action had
   exited while it was still cleaning up, as its run-exit record shows — stays
   an unexpected exit. A worker live at closing counts as stopped by its owner.
3. The latched failure, if any, is rethrown; otherwise the body's result is
   returned.

When the body throws, the group's own exit closes, requests cancellation of
live workers, and drains, as [workers.md](workers.md#closing-and-the-drain)
describes. Unhandled outcomes are then handled the same way, and the body's
failure is rethrown as primary with every committed worker failure retained
beside it. If the body's failure is a delivery of the latched failure, that
failure is not repeated in the retained list.

When the body is cancelled, the cancellation propagates as itself once the
drain has finished, with nothing more classified or warned about: no
classifier and no warning runs while the owner is being cancelled. It carries
the group's `GroupExit` report as raw evidence.

In every case, an expected owner-requested cancellation alone does not fail the
run; required failures, unknown failures, and retained cleanup failures do,
even for an optional worker. A cancelled child's cleanup evidence stays in its
summary; it is not flattened into a message or forged into a resource cleanup
entry. The boundary emits no terminal `Error` for the application and does not
flush or finalize the logger.

## Raw completion and supervision

The foundation group's outcome is raw data that any number of readers may
wait for; it never says whether an exit was expected or a failure fatal. The
supervisor is the single owner that commits observations, decides status, and
latches failures. Raw readers such as `awaitCompletion` on
`supervisedWorker handle` stay available beside it and never retire, handle,
or report anything.

## State

One `withSupervision` invocation owns every piece; none is global, and none is
shared with or reused by another invocation.

| State | Readers and writers | Thread | Lifetime and reset |
|---|---|---|---|
| Pending registrations | `startSupervised` inserts before the worker runs; commits remove; checkpoints, waits, and closing read | Application thread; the boundary at closing | One invocation; a worker leaves when its outcome is committed |
| Owner stop request flag | `stopSupervised`, `cancelSupervised`, and an abandoned start write; classification reads | Application thread | One worker; set once, never cleared |
| Worker status | A commit writes once; `workerStatus` reads | Application thread writes; any thread reads, in STM | One worker; `WorkerLive` until committed, then never changes |
| Committed failures and the fatal latch | Commits append and latch; deliveries and the boundary read | Application thread | One invocation; append-only; the latch is set once and never cleared |
| Warning attempt | Consumed by the commit that makes a worker unavailable, then attempted once | Application thread | At most one per worker; never repeated |

The logging lifetime's recorded reporting outcomes are the lifetime's state;
supervision only reads and appends to them.

## Verification

`cabal test hetoimasia-tests --test-show-details=direct --test-options='--match Supervision'`
runs the examples in `test/Test/Engine/Runtime/Supervision.hs`, inside the
`Runtime` component. They use real foundation workers, a logging lifetime over
an injected collecting sink, synthetic typed failures, and explicit `MVar`,
STM, and `threadStatus` coordination — no sleeps, no wall-clock assertions, no
window or GPU, and no application runner. Their fixtures live in
`Test.Engine.Runtime.Supervision.Support` for the application runner's examples
to reuse. They cover:

- a required failure waking an active supervised wait and a startup wait, with
  the new worker drained before the start unwinds;
- a ready failure handled before simultaneously ready caller work, which stays
  unconsumed;
- optional and required startup failures handled exactly once;
- finite-job completion, an expected exit after a requested stop, an
  unexpected service exit, and an unexpected child cancellation;
- a cleanup failure on an optional worker failing the run;
- an optional disposition committed before its warning, and a failed warning
  that neither repeats nor restores availability;
- a caught fatal delivery staying latched through the final settlement;
- simultaneous failures in registration order, a mixed optional and fatal
  batch, and the application's own failure staying primary;
- a classifier failure and a cancellation during classification;
- a run exit before closing's stop request staying unexpected, a failure
  published before closing observed before the boundary returns, an expected
  owner-requested cancellation, and a rejected start after closing.

The validation catalog covers them through the floor group `test.engine`; see
[validation.md](validation.md).
