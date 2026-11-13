# GPU retention and frame ownership

The contract of `Hetoimasia.GPU.Model`, the pure model in
`packages/gpu-vulkan/model`: typed identities for everything a graphics
session tracks, the holds that decide when any of it may be disposed of, frame
ownership phases, validated admission budgets, recovery accounting, and
bounded owner progress.

**The model proves no native completion.** It makes no native call, names no
native type, owns no thread and reads no clock. A submitted use, a
presentation obligation and an unpresented frame's synchronization end only
when the owning boundary supplies the corresponding fact through the injected
`EvidenceSource`. Elapsed time, a returned call, a cancellation, a reset fence
and a CPU scope exit are not evidence.

| Owner | Owns |
| --- | --- |
| This model | Identities, holds, frame phases, admission budgets, recovery accounting, progress bounds and deadlines |
| The owning boundary | The session identity, every completion and disposal fact, reading the clock |
| Foundation | `Instant`, `Duration`, deadline arithmetic ([time](time.md)) |
| The backend (`packages/gpu-vulkan/native`) | Native handles, calls, threads, and the evidence |

## The package boundary

`hetoimasia-gpu-vulkan-model` depends only on `hetoimasia-foundation`: not the
Vulkan binding, GLFW, the runtime or a game. It builds under
`cabal.project.cpu`, so a developer with no Vulkan SDK can build and test it;
that is a permanent property. Only `Hetoimasia.GPU.Model`, `.Access`,
`.Budget` and `.Identity` are exposed. Identities are unforgeable because the
implementation is hidden: every value a model is handed was issued by some
model.

### Implementation modules

One immutable `GpuModel` value divided by responsibility under
`Hetoimasia.GPU.Model.Internal`, acyclic without boot files:

| Layer | Modules |
| --- | --- |
| Value types | `Identity`, `Hold`, `Budget`, `Recovery`, `Access` |
| Representation | `Records`, `State` |
| Shared building blocks | `Resolve`, `Accounting` |
| Read-only queries | `Work` |
| Scheduling | `Scheduling` |
| Transitions | `Session`, `Targets`, `Generations`, `Resources`, `Initialization`, `Memory`, `Frames`, `Recording`, `Submission`, `Presentation`, `Completion`, `TargetRecovery`, `Disposal` |
| Composition | `Progress` |
| Views | `Observation` |

Queries sit below every transition because the schedule is decided from them.
`Work`'s `eligible` is the only rule for offering a subject for disposal: a
retired generation or a managed resource, every hold ended, and no earlier
failed disposal. The public `disposalEligible` is narrower: it answers only
whether a live subject still owes a hold, and never authorizes a disposal or a
retry after one failed.

## Answers

Every mutating operation answers exactly one of:

- `Admitted a`: the operation happened;
- `Backpressure kind`: a validated budget is exhausted; nothing failed and
  nothing changed;
- `Rejected misuse`: typed misuse, detected before any state changed.

A failed session admits no new work (`SessionAlreadyFailed`). Recording what a
native call already did is not new work, so the outcome of a call whose own
failure ended the session is still recorded.

## Identities

`SessionIdentity`, `DeviceId`, `TargetId`, `GenerationId`, `ImageId`,
`FrameSlotId`, `BatchId`, `SubmissionId`, `PresentationId`, `ResourceId` and
`AllocationId`.

- Target and frame slot numbers are reused once their records are forgotten;
  incarnations and use counters are not. A retained identity is therefore
  stale, never a handle on its successor, and staleness is decided by
  comparing counters.
- `Misuse` distinguishes `ForeignIdentity`, `UnknownIdentity`,
  `StaleIdentity`, `AlreadyConsumed`, `WrongPhase`, `DuplicateSubject`,
  `WrongParent`, `EmptySubmission`, `EmptyAllocation` and
  `SessionAlreadyFailed`. Each names the kind of identity, never the value. A
  compound identity is reported as itself, not as its parent.
- A managed resource is rebuilt only through its current generation, and the
  successor comes from the resource's own counter.
- An image has one unpresented owner at a time. Until the frame that took an
  image enqueues a presentation for it, a second acquisition of that image is
  refused. After the enqueue the image may be acquired again against a
  separate free pool record; the older record still owes its own retirement
  and is discharged only by evidence for itself. No free pool record is
  backpressure, not a refusal.
- A target is `RequiredTarget` or `OptionalTarget`. The classification decides
  only what exhausted recovery escalates to.

## Holds

Five holds are tracked separately on each generation and managed resource:

| Hold | Ends when |
| --- | --- |
| Logical release | The owner releases or retires the subject |
| Ended CPU use | The owner certifies no retained capability can record it again |
| Recorded reference | Its batch is discarded, its recorder reset, or the batch is submitted |
| Submitted use | The boundary supplies the completion fact for that submission record |
| Presentation obligation | The boundary supplies retirement evidence, or unpresented-frame settlement |

A subject is eligible for disposal only when every hold has ended.

- Submitted uses are keyed by submission record and presentation obligations
  by presentation record. Frames submitted in one call share one record.
  Rendering completion never recycles presentation synchronization.
- A subject whose logical release or ended CPU use is certified takes no new
  recorded reference.
- Discard, reset and abandonment each discharge exactly their own references.
  A batch keeps the exact generations it recorded, so rebuilding a resource
  beneath it leaves that generation undisposable.
- `recordBatch` admits a batch against an acquired frame and reserves its one
  record. `extendBatch` adds references before each command that names them
  and charges nothing, so an exhausted object budget never refuses a reference
  an existing batch owes.
- A batch leaves by discard, reset, skip or submission. `submissionCarries`
  answers whether an outstanding submission consumed a given batch.

## Frame ownership

| Phase | Retains | Legal exits |
| --- | --- | --- |
| Reserved | A slot and a presentation-pool record; no image | Acquire; a not-ready or out-of-date result returns the reservation whole |
| Acquired | The exact generation and image, and the pool record | Record, submit, or safely skip |
| Submitted | Its submission record, the image and the pool record | Enqueue a presentation, or close before presenting |
| Presentation enqueued | Its presentation record, and its submission until it completes | The record retires on retirement evidence; the slot frees when the submission does |
| Retiring or abandoning | Exactly the obligations it had | Each settles on its own evidence |
| Uncertain effect | Its parents, permanently; admission has stopped | None |
| Reusable | Nothing | The slot is issued again under a fresh use number |

Distinctions that lose obligations when collapsed:

- **Not ready against suboptimal.** A not-ready or timed-out acquisition owns
  nothing and gives its slot and pool record back. A suboptimal acquisition is
  successful: it keeps its image and coalesces a replacement request.
- **The slot against the record.** A frame slot owns command storage and
  acquisition synchronization; the presentation record owns the image once a
  presentation is enqueued. The slot goes back as soon as its own submission
  has completed.
- **Skipped against closed.** A skipped unsubmitted frame keeps its image and
  acquisition synchronization. A submitted frame closed before presentation
  keeps both its submission obligation and its image obligation.
- **No effect against uncertain effect.** A submission that failed with no
  effect leaves the acquisition and its recording owned and resubmittable. An
  uncertain effect creates a record that can never be discharged, retains
  every parent and escalates the session.
- **A reset fence is not work.** Resetting a fence and submitting nothing
  leaves no obligation.
- **A presentation that enqueued nothing** leaves the rendering and the image
  owned and no presentation fence to wait on.

A frame reserves two objects before the native calls they account for: the
presentation-pool record and the submission record. So backpressure never
leaves an admitted frame without the capacity to be abandoned safely, and a
submission the native call already performed is never refused for want of
accounting.

## Admission budgets

A configuration is a `BudgetRequest` of `Integer`s validated once. Zero,
negative and unrepresentable limits are rejected, never clamped; there is no
unbounded value. A validated `Budgets` is read-only to clients.

| Budget | Default | Counts |
| --- | --- | --- |
| Target records | 16 | Retiring targets too |
| Frame slots per target | 2 (1 supported) | Every live frame of the target |
| Aggregate frame slots | 32 | Every live frame of the session |
| Frame-less batches | 4 | Slots in use ([Frame-less batches](#frame-less-batches)) |
| Live generations | 2 | Active, constructing and retired together |
| Image tracking limit | 16 | Tracked image records of one generation |
| Presentation pool | 18 (derived) | Image tracking limit plus frame slots, shared by the target's generations |
| Accounted bytes | 256 MiB | Unsubmitted and retired allocations, reservations, and held device memory |
| Accounted objects | 4,096 | Pool, image, batch and submission records and resources |
| Reclaim examination | 64 | Records one reclamation pass may examine |
| Progress actions | 32 | Completion or disposal actions per owner turn |
| Idle backoff cap | 100 ms | The last step of the polling schedule |

- Exhaustion answers `Backpressure` naming the budget. It never consumes a
  cleanup record already reserved, and retired work keeps its accounting until
  it is disposed of.
- A driver image count of zero or above the tracking limit is refused: the
  candidate is retired, not published. So is a candidate whose construction
  finished after the session failed.
- A replacement request is counted, not flagged. A publication serves exactly
  the request its construction began for.
- An allocation attempt that reserves neither bytes nor objects is
  `EmptyAllocation`.
- Storage is finite even when no completion ever arrives: the record count is
  a function of the configuration.

### Device memory

Accounted bytes also charge the device memory the backend's allocator holds,
for as long as it holds it. Those charges belong to the memory, not to a
resource.

- `reserveDeviceMemory` reserves, per allocation attempt, the most an
  allocating call could open, before the call. Over budget is
  `Backpressure ByteBudget`.
- `settleDeviceMemory` settles one allocator call's `MemoryEffect`: the
  reservation is released, what was opened is charged, what was freed is
  released. It answers `MemorySettled`, `MemoryBeyondReservation` (charged in
  full, even over budget), or `MemoryFreedUnheld` (the charge no longer bounds
  the memory; the boundary must treat it as terminal). A failed session
  settles too.
- `createResource` and `rebuildResource` refuse an attempt whose reservation
  is unsettled.

## Recovery

A recovery episode belongs to its target and survives owner turns.

- At most three construction attempts: the second 100 ms after the first
  failure, the third 500 ms after the second. Asking early reports the
  deadline without spending an attempt.
- At most one attempt in flight (`RecoveryOutstanding`). A result reported
  with nothing outstanding is refused. A terminal session admits no recovery.
- The last failure exhausts the episode, not the next request.
- A spent budget returns only after a completed presentation-retirement cycle
  on the target and then one full second of monotonic progress without
  another failure. Elapsed time alone resets nothing.
- A cycle is both its facts: the presentation's retirement and its
  submission's completion, matched by identity and held on the target. Each
  half carries the target's recovery epoch at arrival, and a cycle is credited
  only when both halves belong to the current epoch. The epoch rises only when
  an attempt is admitted. Dropping a cycle's credit touches no hold.
- Exhaustion marks an optional target unavailable and fails the session for a
  required one. Device loss, a validation error, an unknown submission effect,
  a failed cleanup and a failed diagnostic sink escalate to the session
  whatever the target's classification.
- `declareTargetUnrecoverable` disposes of a target as exhaustion does, with
  attempts to spare.
- Close wins: a closing target admits no retry, and a construction that
  succeeds after the close is retired, not published.
- A construction ends only through `publishGeneration` or
  `failGenerationConstruction`. `retireGeneration` takes only an active
  generation.
- Only the current published generation may be handed over as `oldSwapchain`.
  That retires it at once and irreversibly, whatever the replacement does.
- An allocation attempt has a stable identity and one retry. It may retry only
  after a reclamation pass confirmed a successful disposal, and never if its
  construction already retired a generation as `oldSwapchain`.
- A reclamation pass examines a bounded window of records, eligible or not,
  with a cursor carried from pass to pass.
- A failed disposal keeps the subject's ownership and accounting, is never
  replayed, and escalates the session.

## Device loss

`noteDeviceLoss` records the loss and fails the session with `DeviceLost`,
unless something failed it first, whose cause is kept; `deviceLossObserved`
answers whether the loss was recorded.

`releaseToDeviceLoss` applies the specification's rule that a lost device's
objects may be destroyed without waiting for work that may never complete. It
releases every outstanding submission (certain or uncertain), every enqueued
presentation, every record awaiting unpresented-frame settlement, and every
frame that had left acquisition. It is not completion: nothing is recorded as
completed or retired, and no recovery episode sees progress.

It does not release a frame still reserved or acquired (the boundary skips
those first; the answer names them), recorded references, logical release,
ended CPU use, or any disposal that already failed.

## Owner progress

One turn performs at most `progressActionLimit` completion or disposal
actions, round-robin across the targets and the session's own place
(frame-less completions and managed resources), with the lead rotating every
turn.

The turn answers the instant of the next one:

- a target with render demand that is not suspended asks for a turn now;
- so does a pending obligation created since the last turn;
- otherwise the earliest of the poll the last turn anchored and every
  recovery deadline;
- with nothing pending there is no turn.

`progressDeadline` is the same answer without render demand, for an owner that
paces its own rendering
([gpu_backend.md](gpu_backend.md#polling-completion)).

**One scheduling rule.** The model keeps one work summary (render demand, live
frames, submissions, presentation records, retiring generations, disposable
subjects, retiring targets, replacements owed, recovery deadlines). A
transition restarts the schedule when that summary grew. An observed
completion and a close transition restart it by declaration. A transition that
only removed work, an observation that changed nothing, and a repeated close
leave the anchored deadline where it was.

`nextDeadline` takes no instant: its answer is a property of the model alone.
The turn is the only place an instant reaches the backoff. It answers
`NoTurnNeeded`, `TurnNow`, `TurnAt`, or `TurnUnschedulable` (there is work and
no candidate instant fits the clock's representation). A recovery delay that
overflows is kept as `AttemptUnschedulable`, never treated as no delay.

The backoff is 5, 10, 20, 40, 80 ms and then the configured cap. A turn that
made progress restarts the whole schedule. A suspended target contributes no
render deadline and keeps every obligation.

## Frame-less batches

Batches that belong to no frame: offscreen rendering and uploads, recorded
with no swapchain image and submitted by themselves. They hold what a frame's
batch holds under the same rules.

- `openFramelessBatch` admits one in the lowest free slot, naming the
  generations it retains. A slot counts against the budget from the opening
  until a discard or its submission's recorded completion. It reserves the
  batch record and the submission record before any native call.
- `extendBatch` and `discardBatch` work as for a frame batch; a frame's
  `resetRecorder` touches none of them.
- `submitFramelessBatch` with `SubmissionAccepted` promotes the references to
  submitted uses. A recorded completion discharges them and frees the slot.
- `SubmissionFailedWithoutEffect` changes nothing.
  `SubmissionEffectUncertain` retains everything for ever and fails the
  session.
- Device loss releases frame-less submissions with the rest. An unsubmitted
  one is the boundary's to discard.

## Ordering managed resources

`Hetoimasia.GPU.Model.Access` orders every access a batch makes to a managed
buffer or image, in engine terms. The backend maps each use onto its own
layouts, stages and accesses
([gpu_backend.md](gpu_backend.md#ordering-managed-resources)).

| `ResourceKind` | Resting use | Other legal uses |
| --- | --- | --- |
| `TextureResource` | `ShaderSampled` | `TransferWrite` |
| `DepthTargetResource` | `DepthAttachment` | none |
| `ColorTargetResource` | `ColorAttachment` | `TransferRead` |
| `VertexResource`, `IndexResource` | `GeometryRead` | `TransferWrite` |
| `InstanceResource` | `InstanceRead` | none |
| `LookupResource` | `StorageRead` | none |
| `StagingResource` | `TransferRead` | none |

Every batch finds a resource in its resting use and must leave it there. No
layout or access state is kept across batches.

A `BatchAccess` is threaded by the batch's recorder through three pure steps,
each answering the barriers owed or an `AccessRefusal` that changes nothing:

- `touch`: a command using a resource in the use it is already in. The first
  touch owes the entry barrier from the resting use (from undefined when the
  command discards the contents).
- `transition`: an explicit move into another legal use, starting from the use
  the batch left the resource in.
- `sealAccess`: refuses (`AwayFromRest`) a batch that leaves any resource away
  from its resting use; otherwise owes one exit barrier per resource touched.

Refusals are `UseNotLegal`, `DiscardNotLegal`, `UseMismatch` and
`KindMismatch`. On the one graphics queue each batch's entry barriers chain to
earlier batches' exit barriers, so accesses between batches are ordered even
when no layout changes.

**Initialization.** `requireInitialization` marks a new image `Uninitialized`.
`enterResource` admits a batch's first touch: an uninitialized image admits
only a touch that discards its contents, and an image another unsubmitted
batch is initializing admits none. Only an accepted submission publishes the
initialization. A discard, reset, skip, no-effect failure or uncertain effect
leaves the image `Uninitialized` again.

## State

The model owns no mutable state: it is an immutable value and every operation
returns the next one. Concurrency belongs to the boundary that threads it.

| State | Owner | Lifetime and disposal |
| --- | --- | --- |
| The `GpuModel` | The owning boundary | The session. A record leaves only when every hold has ended |
| Escalation notices | The owning boundary; `takeEscalations` drains | Bounded: at most one per target record plus the session's; the oldest is dropped and counted |
| Device-memory charges | The owning boundary | Released only as the boundary reports memory freed |
| A generation's initialization | The owning boundary | Leaves with the record |
| A batch's accesses | The batch's recorder | One batch's recording |
| Frame-less slots | The owning boundary | Bounded by the frame-less batch budget |

Nothing accumulates as history.

## What this contract does not promise

- That any native work has finished. Only an injected fact says that.
- That a disposal will succeed. A failure is preserved, not retried.
- That a budget is a driver limit. Byte accounting covers known backend
  allocations, not memory a driver allocates internally.
- That a retired presentation record means an image appeared on screen.

## The placement reference

The public sublibrary `placement-reference` holds a pure best-fit block
placement (free list with coalescing, alignment, `bufferImageGranularity`,
per-memory-type growth, dedicated routing). It is a test reference, not
production code: production allocation uses VMA. No library depends on it;
`gpu-model-tests` checks it against a brute-force reference, and the optional
allocator parity probe measures it.

## Verification

```bash
cabal test --project-file cabal.project.cpu hetoimasia-gpu-vulkan-model:gpu-model-tests --test-show-details=direct
```

This is the `test.vulkan` validation group. Time enters only as an `Instant`
the caller supplies, so a scripted clock drives the whole schedule.
