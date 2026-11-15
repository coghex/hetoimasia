# Supervision

Contract of `Hetoimasia.Runtime.Supervision`: the runtime layer that turns the
raw worker evidence of [workers.md](workers.md) into decisions on the
application thread, through explicit checkpoints and supervised STM waits.

It does not reimplement worker ownership, stop, cancellation delivery or the
drain: it calls `withWorkerGroup`, `startWorkerWithIO`, `observeCompletion` and
`closeWorkerGroup` as they are. The application runner, its services value,
dependency disposal, the single terminal `Error` report and the final flush
belong to [the application runner](resources.md#the-application-runner). The
module uses the runtime's [logging lifetime](logging.md#logging-lifetime) and
[reporting adapter](logging.md#recovery-and-terminal-reports).

## Public interface

- `withSupervision lifetime body` is the boundary; the body receives an opaque
  `RuntimeControl`.
- `startSupervised control policy definition` returns `WorkerStarted handle`,
  `WorkerStartUnavailable handle failure` or `WorkerStartRejected`.
- A `WorkerPolicy` holds a `Role` (`Service` or `Job`), a `Disposition`
  (`Required` or `Optional`, from `Hetoimasia.Foundation.Recovery`), the
  `Component` warnings are reported under, and a classifier returning
  `Recognized` or `Unrecognized`.
- On a `SupervisedWorker`: `supervisedWorker` (the raw foundation worker),
  `stopSupervised`, `cancelSupervised`, and `workerStatus` in STM, one of
  `WorkerLive`, `WorkerCompleted`, `WorkerStopped`, `WorkerUnavailable failure`
  or `WorkerFatal failure`.
- `checkRuntime control` and `awaitSupervised control stmWork` are the
  checkpoints. `workerGroupStatus control` reads the drain status.
- Synthetic failures, each wrapping a `WorkerSummary`: `UnexpectedServiceExit`,
  `UnexpectedWorkerTermination`, `WorkerCleanupFailed`.
- Evidence: `supervisedFailures` and `supervisedFailuresInContext` return
  `SupervisedFailure` entries (worker ID, label, `Fatal` or `Tolerated`, the
  exception with its context).

## The boundary and the control handle

`withSupervision` is an `IO` callback boundary over one worker group. Call it
inside the scopes of every component its workers borrow, and inside the logging
lifetime it is given: its drain runs before it returns or rethrows, and
optional warnings go through that lifetime while it is still open. It needs no
application runner.

The `RuntimeControl` manages and supervises workers and nothing else: no
service lookup, no application state. It is owned by the application thread,
with one read-only exception, [the drain status](#drain-status). **Do not give
it to a worker action**; a worker receives its `StopToken` and the component
handles its definition captured, under the
[borrowing rules](resources.md#ownership-and-borrowing).

## Drain status

`workerGroupStatus control` is `groupStatus` over the control's group: the
group's [drain status](workers.md#drain-status) in one transaction. It performs
no checkpoint, classification, observation, latch delivery, warning or report,
and neither marks nor consumes anything supervision reads.

- **It is the one operation any thread may call**, for example a quit watchdog
  started outside the supervised group, including while `withSupervision` or
  the application runner is blocked in the protected drain.
- Reading never changes when the drain completes, the report, the propagated
  failure or the retained evidence.
- The status is observed state only: it names no cause for a stall and says
  nothing about whether resources are safe to release. `GroupClosed` means the
  foundation published its `GroupReport`; supervision's settlement, the
  dependency unwind and the terminal report come after it. While closing, the
  list can briefly be empty before the report is published.
- Elapsed time, sampling, output and any deadline belong to the observing
  application. The runtime adds no deadline, timeout, detach, forced release or
  process exit.

## Policies and who decides them

The code that starts a worker decides its policy, per worker:

- **Role.** A `Service` runs until its owner asks it to stop; returning before
  then is a failure. A `Job` is finite; returning is completion, and its result
  stays readable on the raw handle
  (`awaitSupervised control (awaitCompletion (supervisedWorker handle))`).
- **Disposition.** `Required` or `Optional`. Never a severity attached to an
  exception type.
- **Classifier.** Supplied by the component that knows its failures.
  `Recognized` means a failure the component supports once its bounded recovery
  is exhausted. It sees a worker's synchronous failure, or a synthetic
  `UnexpectedServiceExit` or `UnexpectedWorkerTermination`, and never a failure
  with retained cleanup evidence. It chooses a disposition only: nothing
  restarts a worker or replays a job. Recovery belongs inside the worker,
  before its outcome is published.

## Managed startup

`startSupervised` registers the policy in the foundation handoff's preparation
step, so supervision owns the policy before any of the worker's code runs. Its
startup wait is a supervised wait: in one transaction it reads the fatal latch
and every other supervised worker's terminal state as well as the new worker's
startup. Outcomes of other workers are handled as at a checkpoint before the
new worker's own acknowledgement is looked at and before anything is drained,
so a failed sibling's `workerStatus` is terminal as soon as its failure is
published, however long the new worker is held.

| During the startup wait | Result |
| --- | --- |
| A tolerated sibling failure (optional, recognized) | Committed as `WorkerUnavailable` with its one warning; the wait goes on and the new worker is neither stopped nor cancelled. |
| A fatal sibling failure | Committed and latched, which asks every pending worker to stop, the new one included. `startWorkerWithIO` cancels and drains the new worker, which counts as stopped by its owner; the latched failure is rethrown after the drain. |
| Owner cancellation of the wait, including inside a classifier | Nothing more is committed or classified. The new worker is drained and the cancellation propagates as itself, carrying the abandoned start and the worker's cleanup failures. |
| A failure first published while the new worker is already draining | Handled by the checkpoint that follows the drain. |

Once startup ends, the new worker's own outcome, if it has one, is handled
exactly once, after any failed startup has drained:

| The new worker | Result |
| --- | --- |
| Startup failure, recognized and optional | `WorkerStartUnavailable`, status committed before its one warning |
| Startup failure, required or unrecognized, or a cleanup failure | Committed as fatal and rethrown |
| A job that acknowledged and already completed | `WorkerStarted`, status `WorkerCompleted` |
| A service that acknowledged and already exited | Judged by the service-exit rule of [Classification](#classification) before the starter can return it |
| Started after closing | `WorkerStartRejected`; nothing is forked |
| Started with a fatal failure latched | The latched failure is rethrown; nothing is forked |

Because the disposition is committed first, no later checkpoint handles or
reports it again. Starting a worker is never run through `recover`.

## Checkpoints and supervised waits

**Nothing interrupts the application thread.** Supervision happens only where
the application asks for it.

- `checkRuntime` handles every pending outcome and rethrows the latched fatal
  failure, if any.
- `awaitSupervised control work` reads pending outcomes and the latch in the
  same transaction as `work`. If anything is pending or latched, `work` is not
  committed: the outcomes are handled, a fatal failure is rethrown, and
  otherwise the wait starts again. A retry waits on `work`'s reads and every
  supervised worker's terminal state together, so a worker failure wakes it
  without a monitor thread.

Place checkpoints:

1. before and after starting a worker;
2. at each iteration of an application loop;
3. before accepting a final result.

**Block only in `awaitSupervised`.** It supervises STM reads and nothing else:
a foreign call, a `takeMVar`, a blocking read or any other `IO` is not
interrupted, and a worker failure during one is handled at the next checkpoint.
The GLFW owner loops provide their own
[event-wait integration](glfw.md#idle-waits); a platform modal loop can still
delay the next checkpoint.

Handling an outcome: pending outcomes are selected in STM without being marked,
classified outside STM, then committed in one transaction that rechecks each
worker is still pending (status set, worker observed with `observeCompletion`
so the group retires it, failures recorded, latch set). One outcome is never
handled twice. Only then are warnings attempted or the failure rethrown, in
`IO`. A failure in the caller's `work` rolls back with nothing marked.

## Classification

The owner's request is the run-exit record's request, or one made through
`stopSupervised`, `cancelSupervised`, an abandoned start or closing. **A stop
or cancel requested after the worker's outcome was published is not recorded**:
it cannot explain an outcome that already happened.

| Terminal outcome | Status |
| --- | --- |
| A job returned | `WorkerCompleted`; its result stays on the handle |
| A service returned before any stop was requested | `UnexpectedServiceExit`, judged by the policy |
| Returned or cancelled after the owner asked it to stop, with successful cleanup | `WorkerStopped`; the actual result or cancellation stays on the handle |
| Cancelled while its run action had not been asked to stop | `UnexpectedWorkerTermination` carrying the child's cancellation, judged by the policy |
| A synchronous failure of startup or the run action, even after a stop request | That failure with its own type, value and context, judged by the policy |
| Any retained cleanup failure | `WorkerFatal` whatever the policy: the failure itself, or `WorkerCleanupFailed` for a cancelled worker |

Judged by the policy: an `Optional` worker whose classifier returns
`Recognized` is `WorkerUnavailable`; any failure of a `Required` worker and any
`Unrecognized` failure is `WorkerFatal`. A cancellation is never rethrown to
the observer: it is carried inside a synthetic typed failure whose
`WorkerSummary` holds the child's terminal evidence.

A classifier that throws synchronously stops supervision: its exception becomes
the worker's fatal status, with the failure it was handling attached as a
`WhileHandling` annotation, as in
[recovery](recovery.md#failures-of-the-policy-itself). A cancellation during
classification propagates as the owner's cancellation and commits nothing from
that batch; the boundary still drains every worker.

## Optional warnings

When a worker becomes `WorkerUnavailable`, its status is committed in the same
transaction that consumes its one warning attempt. The warning is then
attempted outside STM and outside any release, through `reportOutcome` as an
`Operation unavailable` `Warning` under the policy's component, and its
`ReportResult` is recorded on the logging lifetime. It is skipped when a
managed report on that lifetime has already failed. It is never attempted
again, and a failed warning does not change the status.

## The fatal latch and evidence

- The first fatal status committed in an invocation is latched as its primary
  failure. Every later `checkRuntime`, `awaitSupervised` and the boundary's
  exit rethrow it: **catching a delivery neither clears it nor makes the run
  successful.**
- When one checkpoint commits several failures, the primary is the fatal
  failure registered first (registration order, not a claim about which thread
  failed first). An optional failure never becomes primary over a fatal one.
- Every other committed failure, fatal or tolerated, is retained beside the
  propagated failure as a `SupervisedFailure`; `supervisedFailures` reads them
  back in commit order. A delivered synchronous worker failure keeps its type,
  value, context, origin and cleanup evidence.
- Latching initiates owned shutdown in the same transaction: a stop is
  requested of every supervised worker still pending, and a later
  `startSupervised` rethrows the latched failure without forking. Cancellation
  of live workers and the protected drain follow when a failure leaves the
  body.

### Evidence across invocations

Worker IDs are local to one group, so every `withSupervision` invocation has
its own identity, never reused. A delivery carries a `Delivered` marker naming
the invocation and the worker, and retained failures are kept under the same
pair. A failure may pass through more than one boundary (an inner delivery
through an outer body, or a caught delivery rethrown in a later invocation).
Each boundary or checkpoint it leaves keeps the evidence it already carries and
appends its own committed failures in commit order, skipping any already
retained and the primary it delivered. Duplicates are recognized by invocation
and worker together, never by local ID, label or exception value. So
`supervisedFailures` returns the union, each failure once, outer failures after
the inner evidence; a failure committed after an earlier delivery is still
added.

## Closing

When the body returns:

1. `closeWorkerGroup` snapshots every published, unobserved outcome, closes
   registration and requests a stop from every live worker, in one transaction;
   then it waits, cancellably, for the drain.
2. With every worker drained and its dependencies still live, each unhandled
   outcome is handled. An outcome in the snapshot is judged as at a checkpoint,
   so a service that had already exited (or whose run action had exited while
   it was still cleaning up) stays an unexpected exit. A worker live at closing
   counts as stopped by its owner.
3. The latched failure, if any, is rethrown; otherwise the body's result is
   returned.

When the body throws, the group's exit closes, cancels live workers and drains
([workers.md](workers.md#closing-and-the-drain)). Unhandled outcomes are then
handled the same way, and the body's failure is rethrown as primary with every
committed worker failure retained beside it. A delivery of this invocation's
own latched failure is not repeated in the retained list.

When the body is cancelled, the cancellation propagates as itself after the
drain, carrying the group's `GroupExit` report as raw evidence. No classifier
and no warning runs.

In every case an expected owner-requested cancellation alone does not fail the
run; required failures, unknown failures and retained cleanup failures do, even
for an optional worker. The boundary emits no terminal `Error` and does not
flush or finalize the logger.

## Raw completion and supervision

The foundation group's outcome is raw data any number of readers may wait for.
The supervisor is the single owner that commits observations, decides status
and latches failures. Raw readers such as `awaitCompletion` on
`supervisedWorker handle` never retire, handle or report anything.

## Supervised inbox services

`Hetoimasia.Runtime.Inbox` is an optional adapter over `startSupervised`, not a
second supervisor: `startInboxService` registers an ordinary `Service` with the
owner's `InboxPolicy`, and every rule above applies unchanged. Its contract is
in [messaging.md](messaging.md#supervised-inbox-services). In supervision
terms:

- **Startup order.** The worker's startup builds the component context, then
  allocates the inbox with its abort as the innermost release, then writes the
  endpoint into a private one-shot handoff before acknowledgement. The starter
  reads the handoff once after `WorkerStarted`; an empty handoff or duplicate
  write raises `InboxInvariantViolated`, and the worker is still owned and
  drained by the group.
- **Start outcomes.** `InboxStartRejected` and `InboxStartUnavailable` carry no
  endpoint; fatal failures and cancellation propagate as from
  `startSupervised`.
- **Every exit aborts the inbox** before component resources are released and
  before completion is published.
- **Handler failures.** A synchronous exception escaping the handler fails the
  service after the abort and cleanup, and is classified here. Nothing
  isolates, skips or replays a message.
- **Finish versus stop.** An ordinary stop discards accepted backlog.
  `finishInboxService` closes admission, lets the worker handle the in-flight
  message and the backlog in FIFO order, and waits through `awaitSupervised`
  for the worker's drain acknowledgement. Having acknowledged, the worker waits
  for its stop token, so it is never an `UnexpectedServiceExit`. Finish then
  calls `stopSupervised` and awaits the completion. **Finish while prerequisite
  services are still available**: closing's stop is an ordinary stop.

| Finish outcome | When |
| --- | --- |
| `InboxFinished` | The acknowledgement, a `Succeeded` exit record holding it with zero discards, and `WorkerStopped` |
| `InboxUnfinished` (with the acknowledgement, if any, and the actual completion) | A stop or cancellation before the drain, or a cancellation after it that settles as `WorkerStopped` |
| `InboxFinishUnavailable`, one warning | A recognized optional failure, including an unrequested cancellation after the drain |
| Propagated with evidence | Required, unrecognized and cleanup failures |

A stop returns an `InboxExit` with the cumulative discard count and the drain
acknowledgement, if recorded: status `WorkerStopped`, completion `Succeeded
InboxExit`. `WorkerStopped` after a cancellation is never read as an exit
record. `inboxCompletion`, `awaitInboxCompletion` and `inboxAcknowledgedDrain`
are raw, non-consuming reads.

| Adapter state (one start owns each) | Writer | Readers | Lifetime |
| --- | --- | --- | --- |
| Service handoff | The worker's startup, once, as its last step | The starter, once, on the application thread | Never cleared; dropped with the start |
| Drain acknowledgement | The dispatch decision that observes the closed, empty inbox, once | Finish, the exit record, handle readers; any thread, in STM | Kept after completion |
| Inbox exit record | The run, once, after the abort | Any completion reader, in STM | Published with the completion; never consumed |

## A read-only handle

A `SupervisedWorker` pairs the foundation worker with its supervision state.
`startSupervised` fixes the pairing and nothing outside the runtime package can
change it: the type is exported without its constructor or field labels, so no
mismatched handle can be built and supervision performs no runtime check for
one.

## State

One `withSupervision` invocation owns every piece; none is global or shared
with another invocation. All writes are on the application thread (the boundary
at closing).

| State | Writers | Readers | Lifetime and reset |
| --- | --- | --- | --- |
| Pending registrations | `startSupervised` inserts before the worker runs; commits remove | Checkpoints, waits, closing | A worker leaves when its outcome is committed |
| Owner stop request flag | `stopSupervised`, `cancelSupervised` (only while the outcome is unpublished), an abandoned start | Classification | One worker; set once, never cleared |
| Worker status | A commit, once | `workerStatus`, any thread, in STM | `WorkerLive` until committed, then never changes |
| Invocation identity | Created on entry | Deliveries and the boundary | Never reused |
| Committed failures and the fatal latch | Commits append and latch | Deliveries and the boundary | Append-only; the latch is set once and never cleared |
| Warning attempt | The commit that makes a worker unavailable | Attempted once after it | At most one per worker |

`workerGroupStatus` reads the foundation group's own state, whose table is in
[workers.md](workers.md#state). The logging lifetime's recorded reporting
outcomes are the lifetime's state; supervision reads and appends to them.

## Verification

```sh
cabal test hetoimasia-runtime:runtime-tests --test-show-details=direct --test-options='--match Supervision'
cabal test hetoimasia-runtime:runtime-tests --test-options='--match opacity'          # the read-only handle and the inbox service, at the package boundary
cabal test hetoimasia-runtime:runtime-tests --test-option=--match "--test-option=Drain status"
```

The examples use real foundation workers and explicit `MVar`, STM and
`threadStatus` coordination, with no sleeps. Their fixtures are in
`Test.Runtime.Supervision.Support`, which the application runner's examples
reuse. The validation group is `test.runtime`
([validation.md](validation.md)).
