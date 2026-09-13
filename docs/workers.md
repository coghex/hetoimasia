# Workers

Current behavior of `Hetoimasia.Foundation.Worker`: a worker group that owns CPU
worker threads from a successful fork until terminal completion, and keeps the
dependencies those workers borrow alive on every exit. The accepted policy
lives in [the runtime foundation design](runtime_foundation_design.md) (D-11 as
revised by D-13, D-17, P-8, and P-12 "Worker lifetime and state ownership");
this document describes what the code does today.

Scope: the group lifetime boundary and its `Scoped` adapter, the fork and
registration handoff, startup, the four worker operations and their races, the
run-exit record and terminal publication, the drain on every exit path,
retirement, and the evidence all of it leaves. Supervision — services versus
finite jobs, required versus optional workers, checkpoints, supervised waits,
and failure classification — belongs to the runtime and is not part of it.

The module takes no logger, depends on `base`, `containers`, `text`, and the
`stm` boot library, and does not use `async`. It reads cleanup evidence through
[the resource contract](resources.md), which it does not change.

## Public interface

```haskell
withWorkerGroup   ∷ (WorkerGroup → IO a) → IO a
allocWorkerGroup  ∷ Scoped WorkerGroup
closeWorkerGroup  ∷ WorkerGroup → IO GroupReport
activeWorkerCount ∷ WorkerGroup → STM Int

workerDefinition ∷ Text → (StopToken → Scoped s) → (StopToken → s → IO r) → WorkerDefinition r
stopRequested    ∷ StopToken → STM Bool
awaitStopRequest ∷ StopToken → STM ()

startWorker     ∷ WorkerGroup → WorkerDefinition r → IO (StartOutcome r)
startWorkerWith ∷ WorkerGroup → WorkerDefinition r
                → (Worker r → IO ()) → (Worker r → STM a)
                → IO (Either StartRejection (Worker r, a))
data StartOutcome r = Started (Worker r) | StartupFailed (Worker r) (Completion r)
                    | StartRejected StartRejection
data StartRejection = RegistrationClosed
workerId    ∷ Worker r → WorkerId
workerLabel ∷ Worker r → Text

requestStop   ∷ Worker r → STM ()
requestCancel ∷ Worker r → IO ()
data WorkerCancelled = WorkerCancelled      -- asynchronous

awaitStartup      ∷ Worker r → STM (Startup r)
awaitCompletion   ∷ Worker r → STM (Completion r)
pollCompletion    ∷ Worker r → STM (Maybe (Completion r))
observeCompletion ∷ Worker r → STM (Maybe (Completion r))
data Startup r = Acknowledged | NotAcknowledged (Completion r)

data Completion r = Completion
  { completionWorker ∷ WorkerId, completionLabel ∷ Text, completionExit ∷ RunExit
  , completionResult ∷ Result r, completionCleanup ∷ [CleanupFailure] }
data Result r  = Succeeded r | Failed (ExceptionWithContext SomeException)
               | Cancelled (ExceptionWithContext SomeException)
data RunExit   = RunNotEntered | RunExited RunEnd Requested
data RunEnd    = RunReturned | RunFailed | RunCancelled
data Requested = NothingRequested | StopWasRequested | CancelWasRequested
type WorkerSummary = Completion ()

data GroupReport = GroupReport
  { reportExitedBeforeClosing ∷ [WorkerSummary], reportDrained ∷ [WorkerSummary]
  , reportObservedFailures ∷ [WorkerSummary] }
data WorkerEvidence = AbandonedStart WorkerSummary | GroupExit GroupReport
workerEvidence          ∷ SomeException    → [WorkerEvidence]
workerEvidenceInContext ∷ ExceptionContext → [WorkerEvidence]
```

## The group lifetime boundary

`withWorkerGroup` is an `IO` callback boundary. Call it **inside** the scopes of
every component the group's workers borrow: the drain below runs before the
boundary returns or rethrows, so those scopes cannot begin to unwind while a
worker still uses them. A worker must not borrow a component whose scope is
shorter than the group's, merely because its handle can be captured in a
closure; the [borrowing rules](resources.md#ownership-and-borrowing) still
apply.

`allocWorkerGroup` is the same boundary composed in `Scoped`. Allocations made
before that line outlive the drain; allocations made after it are released
before the drain begins and must not be lent to the group's workers. It is
built through the foundation library's
[hidden implementation seam](resources.md#the-implementation-seam), so the
`Scoped` constructor stays unexported and no catch instance is added to
`Scoped`.

The drain is not an `allocResource` release. A release runs under
`uninterruptibleMask_` and [must have a controlled blocking
duration](resources.md#what-a-release-may-do); waiting for a thread has none, and
a `throwTo` sent from inside an uninterruptible region can block on delivery.

A group's registration closes exactly once, and a closed group is never reused.

## Starting a worker

A `WorkerDefinition` is a label, a startup written as a `Scoped` construction,
and a run action. `startWorkerWith` performs the handoff in this order:

1. **Registration.** One transaction checks that registration is open and
   registers the worker, issuing its `WorkerId` in registration order. A closed
   group returns `Left RegistrationClosed` as an ordinary outcome, and nothing
   is forked.
2. **Fork.** The starter is masked, and nothing between registration and the
   fork is interruptible, so a successful fork is already registered and owned.
   The child inherits that mask and installs its outcome handler before
   anything interruptible, then waits at a closed gate: none of its definition
   runs yet. A fork that itself fails is published as that worker's terminal
   `Failed` outcome with `RunNotEntered`, and the failure propagates.
3. **Preparation.** The caller's `prepare` runs with the caller's masking state
   and the worker handle, before any child user code. A later supervisor
   registers its own policy for the worker here.
4. **Wait.** The gate opens and the caller's `wait` transaction runs with the
   caller's masking state, cancellably. It is ordinary STM, so a supervisor can
   combine `awaitStartup` with any other condition in one transaction, and its
   result is returned with the handle.

If `prepare` or `wait` fails or is cancelled, cancellation of the worker is
requested and the starter waits — absorbing further interruptions — until the
worker is terminal and its helper has finished. The failure then propagates
with its own type, value, and context, an `AbandonedStart` annotation carrying
the worker's summary, and the worker's cleanup failures retained. The child
therefore cannot outlive the dependencies the starter borrowed. A `wait` that
returns without acknowledgement leaves the worker running and owned by the
group.

`startWorker` is `startWorkerWith` with no preparation and `awaitStartup` as the
wait. It returns `Started` on acknowledgement, `StartupFailed` with the
completion when the worker ended first (its cleanup has already finished), and
`StartRejected` for a closed group.

### Startup on the worker thread

Once the gate opens, the child enters its startup scope with asynchronous
exceptions unmasked. When startup succeeds, the child masks, publishes
acknowledgement from **inside** the scope — so the worker-owned resources are
protected and stay live — installs the handler for its run action's exit, and
only then unmasks the run action. The run action runs unmasked whatever masking
state the starter had; it never inherits the starter's temporary registration
mask.

The run action's result is evaluated to weak head normal form inside the
worker's scope. A result whose validity depends on the worker's resources must
be fully produced there.

`awaitStartup` retries until the worker acknowledges, or until it is terminal
without acknowledging, which it reports as `NotAcknowledged` with the
completion. A startup failure is therefore reported only after the startup
scope has unwound, carrying the failure's origin and cleanup evidence.
Acknowledgement is independent of completion, and both can be ready at once: a
finite worker that already finished still reports `Acknowledged`, and its
completion is ready too.

Bounded recovery of worker-owned initialization can run inside the startup
with `allocComponent`. `startWorker` must not run inside `recover` as an
attempt that returns a live handle.

## Stop, cancel, and observe

These are distinct operations.

- **Stop.** `requestStop` is a non-blocking STM transition of the worker's owned
  stop token. The worker reads it with `stopRequested` or `awaitStopRequest`
  and decides how to exit. It is idempotent, runs no callback, never weakens a
  cancellation request, and never resets to running.
- **Cancel.** `requestCancel` records the request at once, and a cancellation
  request is also a stop request. The first request of a live worker registers
  and forks one group-owned helper thread that delivers `WorkerCancelled` with
  `throwTo`. Delivery can block for as long as the worker sits in an
  uninterruptible region or a foreign call, so it never runs on the requesting
  thread and never inside a resource release. The helper is registered before
  it is forked and joined by the drain; it is never detached. Repeated requests,
  and a request of a terminal worker, fork nothing.
- **Observe.** `awaitCompletion` and `pollCompletion` are raw reads: any number
  of readers, nothing consumed, and no effect on the worker. A reader cancelled
  while waiting leaves the worker running and not stopped. `observeCompletion`
  is the owner's commit of an observation, which drives retirement below.
  Observing a worker's cancellation never cancels the observer: a completion is
  data, never a rethrow.

A worker that ignores both its stop token and cancellation — a loop in an
uninterruptible region, for example — is not interrupted by anything here.

## The run-exit record and terminal publication

When the run action exits, the child records a `RunExit` under masking, before
any of its own cleanup begins, in the same transaction that reads the worker's
requests. The record fixes how the run action ended (`RunReturned`,
`RunFailed`, or `RunCancelled`) and the strongest request already made when it
did. A stop or cancellation request arriving while the worker cleans up cannot
change it, so an unexpected exit is never retroactively made an expected one.
A worker whose run action never started — startup failed or was cancelled, the
handoff was abandoned, or the fork failed — keeps `RunNotEntered`, which is
never mistaken for a recorded exit and never leaves a reader waiting.

After the startup scope and every allocation in it have unwound, the child
publishes exactly one `Completion` under masking, in one transaction, and does
nothing else afterwards. It carries the identity, the run-exit record, the
cleanup failures its terminal failure retained, and one `Result`:

| Result | When |
|---|---|
| `Succeeded r` | The run action returned and every release succeeded. |
| `Failed e` | A synchronous failure of startup, the run action, or a release, or a failed fork. |
| `Cancelled e` | An asynchronous exception ended the worker. |

Classification is by the terminal exception's type. A cancellation that becomes
deliverable only after the run action returned — pending through an
uninterruptible release, for instance — ends the worker as `Cancelled` while
its record still says `RunReturned`. The completion is terminal, immutable, and
readable through STM by any number of readers; after it, no worker code or
finalizer of that worker touches a borrowed dependency.

## Closing and the drain

Closing begins once, in one transaction that is synchronized with terminal
publication and registration:

1. It snapshots what has already happened: every published outcome not yet
   observed with `observeCompletion` becomes `reportExitedBeforeClosing`, and
   every non-success outcome an owner already observed becomes
   `reportObservedFailures`. A worker that already exited can therefore never
   appear to have stopped on request.
2. It closes registration, so a later start is rejected without forking.
3. It requests a stop from every live worker. All requests are made before any
   worker is waited for.

`withWorkerGroup` then runs the drain on every exit path — normal return,
startup failure, body failure, and owner cancellation:

- If the body failed or was cancelled, cancellation is also requested of every
  live worker.
- The owner waits until every worker has published its completion and every
  cancellation helper has finished, with every borrowed dependency still live.
- An asynchronous exception delivered to the owner during that wait does not
  end it. If the body had returned normally, the first such exception becomes
  the owner's pending failure and cancellation is requested of the live
  workers; later ones are absorbed. A helper that cannot be forked leaves that
  worker's requests in place, and the drain still waits for it.
- Once every worker is terminal, the body's result is returned, or the pending
  failure is rethrown with its own type, value, and context, a `GroupExit`
  annotation carrying the `GroupReport`, and every cleanup failure the report's
  workers retained, which `cleanupFailures` reads back.

A worker that never becomes terminal keeps the owner waiting with its
dependencies live. No deadline, detach, or process termination is added.

`closeWorkerGroup` runs the same closing transaction from inside the body and
waits for the report, which the body can use before its dependencies unwind.
Its wait is cancellable; a cancellation escapes to the owner, whose exit then
requests cancellation and performs the protected drain. Calling it again, or
the owner's own exit after it, reuses the same report. A normal return from
`withWorkerGroup` otherwise discards the report. A worker of the group must not
call it, since the wait includes that worker.

## Retirement

After the owner has observed a worker's completion with `observeCompletion` and
its cancellation helper, if any, has finished, the group retires the worker from
active bookkeeping. A retired success is dropped from the group, so completing
many finite workers does not retain every handle until group exit. A retired
`Failed` or `Cancelled` outcome is kept for `reportObservedFailures`. A retained
handle still exposes the same immutable completion. Retirement never discards a
running worker or an unobserved outcome, and raw readers never retire anything.
`activeWorkerCount` reports how many workers are not yet retired.

## State

| State | Owner | Readers and writers | Thread | Lifetime and reset |
|---|---|---|---|---|
| Group phase (open, closing, closed) | The group | Registration reads; closing and the final report write | Any thread holding the group, in STM | One `withWorkerGroup` invocation; closes once, never reopens |
| Registration order and active set | The group | Registration inserts; retirement deletes; closing and the report read | Starter, owner, helpers, observers, in STM | One invocation; emptied when the group closes |
| Retained observed failures | The group | Retirement inserts; closing reads | Observer and helpers, in STM | One invocation; emptied when the group closes |
| Closing snapshot and report | The group | Closing writes the snapshot; the drain writes the report once | Owner or `closeWorkerGroup` caller | Written once; the report never changes |
| Worker thread identity | The group | Starter writes after the fork; helpers read | Starter, helpers | One worker; set once |
| Stop and cancellation request | The worker's entry | `requestStop`, `requestCancel`, and closing write; the worker reads through its stop token; the run-exit record reads | Any thread, in STM | One worker; only strengthens, never reset to running |
| Start gate | The worker's entry | Starter opens it; child reads | Starter, child | One worker; opened at most once |
| Startup acknowledgement | The worker | Child writes inside its startup scope; starter and observers read | Child, in STM | One startup; set once; independent of completion |
| Run-exit record | The worker | Child writes before cleanup, reading the requests in the same transaction; publication reads | Child | One worker; written at most once |
| Terminal completion and evidence | The worker | Child publishes once; any number of readers | Child, in STM | Never taken, never reset; kept by every retained handle |
| Observed flag, helper count, helper sent flag | The worker's entry | `observeCompletion`, `requestCancel`, and helpers write; retirement and the drain read | Owner, helpers, in STM | One worker; the helper count returns to zero when its helper finishes |

## What the contract does not promise

- **OS-thread affinity.** A worker is a Haskell thread, not a bound OS thread.
  Audio or other foreign owners that need a particular OS thread must select a
  bound-thread contract separately.
- **Wall-clock termination.** There is no deadline, and none can establish that
  a worker has stopped using its dependencies.
- **Interruption of arbitrary blocking IO.** Cancellation is delivered with
  `throwTo`; a foreign call or an uninterruptible region delays it, and the
  drain waits.
- **Supervision.** Nothing here decides whether an exit was expected, whether a
  failure is fatal, or whether a worker is required.

## Raw completion and supervision

The completion, the run-exit record, the closing snapshot, and the report are
raw evidence. A supervisor built on this group can tell a finite job's
successful result from a service that returned before any stop was requested,
an expected stop from an unexpected exit, and an owner-requested cancellation
from an unexpected one — and can register its policy in `prepare`, wait for
startup alongside other failures in one transaction, and commit observations
with `observeCompletion` — but none of that classification is implemented
here. Nothing is restarted or replayed. The runtime's supervisor,
`Hetoimasia.Runtime.Supervision`, does exactly that on top of this group; its
contract is [supervision.md](supervision.md).

## Verification

`cabal test hetoimasia-tests --test-show-details=direct --test-options='--match /Workers/'`
runs the `Workers` examples from `test/Test/Engine/Workers/Spec.hs`. They use
injected CPU actions, real CPU scopes, ordered release traces, and explicit
`MVar`, STM, and `threadStatus` coordination with no sleeps and no wall-clock
assertion, and cover:

- acknowledged startup with the worker's resources live for its run;
- a typed startup failure retaining its origin and cleanup evidence;
- cancellation during startup published as `RunNotEntered`;
- a cancelled startup wait draining the child before the starter's dependency
  is released, and a failed composed wait and a failed preparation draining
  the child, with preparation observed before any child code;
- acknowledgement and completion ready together;
- idempotent stop and a single helper for repeated cancellation;
- cancellable observation that neither cancels nor falsely joins the worker,
  and observed cancellation that does not cancel the observer;
- completion after cleanup, read identically by several readers;
- every stop requested before any worker is waited for;
- the registration-versus-closing race and a rejected start after closing;
- a run exit before the stop request staying recorded when the request lands
  during cleanup, and an outcome published before closing reported as exited;
- owner failure cancelling live workers and propagating after their cleanup,
  with a further owner cancellation during the drain not shortening it;
- a stuck worker and a blocking cancellation delivery each keeping their parent
  alive until explicitly released, then settling with their evidence;
- retirement that keeps retained handles' results, and an observed failure kept
  through retirement and an exceptional group exit.

The validation catalog covers them through the floor group `test.engine`; see
[validation.md](validation.md).
