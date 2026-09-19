# GPU retention and frame ownership

Current behavior of `Hetoimasia.GPU.Model`, the pure model in
`packages/gpu-vulkan/model`: typed identities for everything a graphics session
tracks, the holds that decide when any of it may be disposed of, frame ownership
phases and their obligations, validated admission budgets, recovery accounting,
and bounded owner progress. The accepted policy lives in
[the Vulkan backend design](vulkan_backend_design.md) (D-15 through D-18, D-22
through D-26, and P-1, P-2, P-8, P-14 and P-15); this document describes what the
code does today.

**This model proves no native completion.** It makes no native call, names no
native type, owns no thread and reads no clock. A submitted use, a presentation
obligation and an unpresented frame's synchronization end when — and only when —
the owning boundary supplies the corresponding fact through the injected
`EvidenceSource`. Elapsed time, a returned call, a cancellation, a reset fence
and a CPU scope exit are none of them evidence, and there is no operation by
which any of them becomes one. Which native mechanism proved a fact is the
boundary's business and is deliberately absent from the fact.

Scope: one graphics session's bookkeeping, as a value the owner threads. The
native backend package that will own handles, calls and threads does not exist
yet; when it does it will depend on this package, and this package will not
depend on it.

## Ownership

| Owner                | Owns                                                                                                |
| -------------------- | --------------------------------------------------------------------------------------------------- |
| This model           | Identities, holds, frame phases, admission budgets, recovery accounting, progress bounds and deadlines |
| The owning boundary  | The session identity, every completion and disposal fact, and reading the clock                      |
| Foundation           | `Instant`, `Duration`, validated construction and deadline arithmetic ([time](time.md))              |
| A later backend      | Native handles, calls, threads, and the evidence that answers the injected interface                  |

## The package boundary

`hetoimasia-gpu-vulkan-model` depends on `hetoimasia-foundation` and on nothing
else in this repository: not the Vulkan binding, not GLFW, not the runtime, not a
game. It is listed in both `cabal.project` and `cabal.project.cpu`, carries the
per-package `-Werror` entry in `cabal.project.common`, and its suite is
registered as the CPU validation group `test.vulkan`, whose command runs through
`cabal.project.cpu`. A developer with no Vulkan SDK can therefore build and run
it, and that is a permanent property rather than a convenience.

Only `Hetoimasia.GPU.Model`, `Hetoimasia.GPU.Model.Budget` and
`Hetoimasia.GPU.Model.Identity` are exposed. The implementation lives in hidden
`Hetoimasia.GPU.Model.Internal` modules, which is what makes an identity
unforgeable: no client can build one, so every value a model is handed was issued
by some model, and the model it reaches can say whether that model was this one.

## Answers

Every mutating operation answers exactly one of three things, and they are kept
apart because they are different facts:

```haskell
data Outcome a
  = Admitted !a           -- the operation happened
  | Backpressure !BudgetKind  -- a validated budget is exhausted; nothing failed
  | Rejected !Misuse      -- typed misuse, detected before any state changed
```

A rejected call is never a partially applied one. Misuse is checked before
anything is written, so the answer and the state can never disagree about whether
something happened.

## Identities

| Identity         | Names                                                                    |
| ---------------- | ------------------------------------------------------------------------ |
| `SessionIdentity`| The session, from a `Unique` the boundary created for it alone            |
| `DeviceId`       | The one logical device the session owns                                   |
| `TargetId`       | A rendering target: its number and the incarnation that number is on      |
| `GenerationId`   | One swapchain generation of one target                                    |
| `ImageId`        | One tracked image record of one generation, at its index                  |
| `FrameSlotId`    | One use of one frame slot: the target, the slot, and the use it is on     |
| `BatchId`        | One recorded batch of commands                                            |
| `SubmissionId`   | One submission record, shared by every frame one call submitted           |
| `PresentationId` | One record of the target's finite presentation pool                       |
| `ResourceId`     | One generation of one managed resource                                    |
| `AllocationId`   | One native allocation attempt, stable across its reclamation and retry    |

Target numbers and frame slot numbers are reused once their records are
forgotten; incarnations and use counters are not. So a retained identity for a
retired target or a finished frame is *stale* rather than a handle on its
successor, and staleness is decidable by comparing counters rather than by
remembering every identity ever issued.

`Misuse` distinguishes `ForeignIdentity` (another session's), `UnknownIdentity`
(never issued), `StaleIdentity` (issued, since retired), `AlreadyConsumed` (a
one-shot record settled twice), `WrongPhase`, `DuplicateSubject` (one call naming
the same object twice), `EmptySubmission`, and `SessionAlreadyFailed`. Each names
only the *kind* of identity, never the value, so a refusal about a foreign value
cannot smuggle that value back out.

A target is classified `RequiredTarget` or `OptionalTarget` when it is admitted.
The classification decides only what exhausted recovery escalates to; it never
weakens an ownership or completion requirement.

## Holds

Five holds are tracked separately on each generation and each managed resource,
because discharging one never implies another:

| Hold                       | Ends when                                                               |
| -------------------------- | ------------------------------------------------------------------------ |
| Logical release            | The owner releases or retires the subject                                |
| Ended CPU use              | The owner certifies no retained capability can record it again           |
| Recorded reference         | Its batch is discarded, its recorder reset, or the batch is submitted    |
| Submitted use              | The boundary supplies the completion fact for that submission record     |
| Presentation obligation    | The boundary supplies retirement evidence, or unpresented-frame settlement |

A subject is eligible for disposal only when **every** hold has ended, and the
model offers nothing else for disposal. `holdView` reports what is still owed and
`disposalEligible` answers the one question disposal turns on.

Submitted uses are keyed by their submission record and presentation obligations
by their presentation record. So a batch of several frames submitted in one call
shares exactly one record and discharges once, while frames submitted by separate
calls owe separate records; and rendering completion never recycles presentation
synchronization, because the two are different keys on different holds.

Discarding a batch, resetting a recorder and abandoning unsubmitted work each
discharge exactly their own references and nothing else. Recording retains the
exact generations it referenced: rebuilding a managed resource beneath a recorded
batch leaves the batch naming the generation it recorded, which therefore stays
undisposable.

## Frame ownership

| Phase                       | Retains                                                        | Legal exits                                                                 |
| --------------------------- | -------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Reserved                    | A slot and a presentation-pool record; no image                | Acquire; a not-ready or out-of-date result returns the reservation whole     |
| Acquired                    | The exact generation and image, and the pool record             | Record, submit, or safely skip                                              |
| Submitted                   | Its submission record, plus the image and the pool record       | Enqueue a presentation, or close before presenting                          |
| Presentation enqueued       | Its presentation record, and its submission until it completes  | The record retires on retirement evidence; the slot frees when the submission does |
| Retiring or abandoning      | Exactly the obligations it had when it left its previous phase  | Each settles on its own evidence                                            |
| Uncertain effect            | Its parents, permanently; admission has stopped                 | None: the record can never be discharged                                    |
| Reusable                    | Nothing                                                         | The slot is issued again under a fresh use number                           |

The distinctions that lose obligations when collapsed:

- **Not ready against suboptimal.** A not-ready or timed-out acquisition owns
  nothing, creates no synchronization obligation, and gives its slot and its
  untouched pool record straight back. A suboptimal acquisition is a *successful*
  one: it keeps its image index, coalesces a replacement request beside it, and
  can be finished or abandoned normally.
- **Out of date.** No new acquisition obligation is created and the reservation
  goes back, while every older obligation on the target is untouched.
- **Skipped against closed.** A skipped unsubmitted frame discharges its
  unsubmitted recording and keeps its image and acquisition synchronization; a
  submitted frame closed before presentation keeps *both* its submission
  obligation and its image obligation. Neither pretends the other happened, and
  each settles only on its own fact.
- **No effect against uncertain effect.** A submission that failed with no
  effects leaves nothing pending, clears the reset fence, and leaves the
  acquisition and its recording owned and resubmittable. An uncertain-effect
  outcome creates a record that can never be discharged, retains every parent,
  and escalates the session — it is never rolled back as if the call did nothing.
- **A reset fence is not work.** Resetting a submission fence and then submitting
  nothing leaves no pending submission and no obligation, so no drain may wait on
  it.
- **A presentation that enqueued nothing.** The prior rendering and the still-owned
  image stay owned, and no presentation fence exists to wait on.

The presentation-pool record is reserved at *reservation*, before acquisition, so
backpressure can never leave an admitted frame without the cleanup capacity it
needs to be abandoned safely. A reservation that creates no obligation returns
its record immediately; a record that ever covered an acquired image is recycled
only by retirement evidence for an enqueued presentation, or by explicit
settlement evidence for a frame that was never presented.

## Admission budgets

A configuration is stated as a `BudgetRequest` of `Integer`s and validated once,
before a model exists. Zero, negative and unrepresentable limits are rejected and
never clamped; there is no unbounded sentinel.

| Budget                 | Default   | Counts                                                              |
| ---------------------- | --------- | --------------------------------------------------------------------- |
| Target records         | 16        | Retiring targets too                                                 |
| Frame slots per target | 2 (1 supported) | Every live frame of the target                                 |
| Aggregate frame slots  | 32        | Every live frame of the session                                      |
| Live generations       | 2         | Active, constructing and retired together                            |
| Image tracking limit   | 16        | Tracked image records of one generation                              |
| Presentation pool      | 18 (derived) | Reserved, unpresented and pending records, shared by the target's active and retired generations |
| Accounted bytes        | 256 MiB   | Recorded-but-unsubmitted and retired allocations too                 |
| Accounted objects      | 4,096     | Pool records, image records, batch records, submission records and resources |
| Reclaim examination    | 64        | Records one reclamation pass may examine                             |
| Progress actions       | 32        | Completion or disposal actions per owner turn                        |
| Idle backoff cap       | 100 ms    | The last step of the polling schedule                                |

The presentation pool is **derived**, not configured: it is the overflow-checked
sum of the image tracking limit and the frame-slot count, so raising frame
capacity raises the pool with it instead of leaving a frozen constant behind. A
configuration whose derived sum would not fit is rejected as
`DerivedBudgetOverflows`.

Exhaustion answers `Backpressure` naming the budget. It is not a failure: nothing
changed, the session is still running, and the caller may try again when the
budget frees. It never consumes a cleanup record already reserved for admitted
work, and retired work keeps its accounting until it is actually disposed of, so
nothing vanishes from the metrics by being retired.

An image count the driver returns that is zero, or above the tracking limit, is
refused rather than published: the candidate is retired instead, and its
accounting stays until it is safely disposed of.

Because every admission point is bounded and every record is accounted, storage
is finite even when no completion ever arrives. The record count is a function of
the configuration, not of how many attempts were made.

## Recovery

A recovery episode belongs to its target and survives owner turns. It allows at
most three construction attempts, with the second 100 ms after the first failure
and the third 500 ms after the second. Asking early reports the deadline rather
than spending an attempt.

Nothing raises a spent budget. A nested helper, a changed framebuffer
observation and an allocation sub-retry all reach the same accounting, which only
counts up. The single path back to a full budget requires **two** separate
things: a completed presentation-retirement cycle on the target, and then a full
second of monotonic progress after it without another failure. Elapsed time alone
resets nothing.

Exhaustion marks an optional target unavailable and leaves the session running;
for a required target it fails the graphics session. Device loss, a validation
error, an unknown submission effect and a failed cleanup escalate to the session
rather than to a target, whatever the target's classification says.

Close wins. A target that is closing admits no retry, and a construction that
succeeds after the close was observed is retired rather than published back into
active rendering.

Handing a generation over as `oldSwapchain` retires it *there*, before anything is
known about the replacement, and that retirement is irreversible: a failed
construction leaves it retired, and it cannot be handed over a second time.

An allocation attempt carries its own stable identity and exactly one spent-retry
bit. It may retry only after a reclamation pass confirmed a **successful
disposal**: examining records is not progress, and neither is requesting a
disposal that then failed. If the attempt's construction already retired a
generation as `oldSwapchain`, the retry is refused outright, because the previous
creation arguments no longer describe the state to construct from.

A failed disposal retains the subject's ownership and its accounting, is never
replayed, and escalates the session. A cleanup failure is never permission to
proceed as though rollback succeeded.

## Owner progress

One turn performs at most `progressActionLimit` completion or disposal actions,
taken round-robin across targets and then the session's own managed resources.
The lead rotates every turn, so no target starves behind a busy neighbour, and
the report names the order it visited.

The turn answers the absolute instant of the next one:

- a target with render demand that is **not suspended** asks for an immediate
  opportunity;
- otherwise, if anything is pending, the deadline is one backoff interval away;
- with nothing pending at all there is no deadline.

The backoff schedule is 5, 10, 20, 40, 80 and then the configured cap of 100 ms.
The obligation that created the work schedules the first poll five milliseconds
out; each poll that finds nothing moves one step along, and the last step is the
steady state it stays at. New demand, a new obligation, an observed completion
and a close transition each schedule an immediate opportunity and start the
schedule over.

A suspended target contributes no render deadline and keeps every obligation it
had, including its retirement demand, so suspension silences a deadline and never
an obligation.

Time enters only as an `Instant` the caller read from the foundation's injected
clock. The model reads no clock, and a scripted clock is therefore enough to
prove the whole schedule.

## State

| State             | Owner              | Readers and writers       | Thread | Lifetime     | Reset or disposal                          |
| ----------------- | ------------------ | ------------------------- | ------ | ------------ | -------------------------------------------- |
| The `GpuModel`    | The owning boundary| Whoever threads the value | Any    | The session  | A record leaves only when every hold has ended |

The model owns no mutable state at all: it is an immutable value, and every
operation returns the next one. Concurrency, if any, belongs to the boundary that
threads it.

## What this contract does not promise

- That any native work has finished. Only an injected fact says that.
- That a disposal will succeed. A failure is preserved, not retried.
- That a budget is a driver limit. These are configuration values; byte
  accounting covers known backend allocations, not memory a driver allocates
  internally.
- That a presentation record retiring means an image has appeared on screen.
  Visual timing is a separate question from safe object reuse.

## Verification

`test.vulkan` runs `gpu-model-tests`, the package's own suite, through
`cabal.project.cpu`:

```
cabal test --project-file cabal.project.cpu hetoimasia-gpu-vulkan-model:gpu-model-tests --test-show-details=direct
```

Every example is deterministic and decided by ordering rather than by timing.
The suite covers no disposal while any hold remains; no completion without an
injected fact; suboptimal acquisition keeping its image; the skip and
submitted-unpresented paths settling only their own obligations; a no-effect
submission failure against the uncertain-effect state; duplicate, stale and
foreign identities rejected before effects; every budget's exhaustion as
backpressure; recovery episodes surviving nested helpers and turns without
replenishment; `oldSwapchain` retirement surviving failed construction; close
defeating late publication; the backoff schedule and its resets under a scripted
clock; bounded round-robin progress across several targets; suspended targets
retaining retirement demand; disposal failure retaining ownership and accounting
while escalating the session; and finite storage when completions never arrive.

`test.workflow` holds the group's registration to the routing it needs: it is
assigned to the `haskell-engine` worker, its receipt is published under the name
the reuse lookup asks for, it is selected when its own package changes or when a
pull request requests it, its evidence is required by the aggregate, and it stays
outside the mandatory floor.
