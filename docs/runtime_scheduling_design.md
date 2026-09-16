# Runtime timing, scheduling, and native wake design

Give the existing owner loop explicit work demand and monotonic deadlines before
it hosts simulation or graphics. Preserve Synarchy's elapsed-time discipline and
Hetoimasia's bounded dispatch, supervision, and scoped ownership.

Design state: `ready for issue processing`

Owner: `coghex/hetoimasia`. Started 2026-09-16. No tracker items have been created
from this document. Final review requested by the owner completed on 2026-09-16
against `master@e2d30ea`. P-1 through P-5 specify the reviewed contracts for
D-1 through D-4; D-5 records the review and processing handoff.

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Establish monotonic scheduling and responsive native waits
- [ ] TIME-1. Add the monotonic time and deadline boundary
- [ ] TIME-2. Add bounded variable and fixed-step update policies
- [ ] TIME-3. Own a cross-thread native wake capability with the GLFW session
- [ ] TIME-4. Connect admitted commands and published demand to native wake
- [ ] TIME-5. Drive owner turns from ready work and absolute deadlines
- [ ] TIME-6. Compose per-window render demand with application simulation

## Epic contract

- **Goal:** applications choose event-driven, deadline-driven, or fixed-step
  updates without incidental queue activity setting the frame rate; worker
  submissions wake the native owner without weakening session lifetime.
- **Done when:** scripted clocks and native X11 evidence establish bounded
  catch-up, fair owner turns, safe wake/termination races, and independent
  window suspension. Cocoa evidence is collected only after human approval.
- **Users and operators:** engine/game authors, background workers submitting
  commands, and agents running focused validation.
- **Arc label:** existing `runtime`; crossing slices also use the existing
  `glfw` and `tests` labels as appropriate during issue processing.

## Current state and evidence

Verified at `master@e2d30ea` on 2026-09-16:

- `packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal.hs`:
  `runOwnerLoop` decides the next turn is idle from command/event counts only.
  `loopUpdate` returns `Continue` or `Finish`, with no timing demand. The default
  idle wait is 0.1 seconds; it is finite but not a pacing policy.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Command.hs`:
  `submitWith` and `awaitSubmitWindowCommand` admit commands transactionally and
  create persistent tickets. They do not notify a native wait.
- `packages/glfw/native/Hetoimasia/GLFW/Internal/Native.hs`:
  `noteProgressForCheck` is a test helper, not a production wake contract.
- Session teardown marks the session dead before terminating GLFW, but there
  is no synchronization protocol for a new cross-thread native wake operation.
- The runtime already owns supervision/checkpoints and workers; messaging
  already owns bounded queues and prepared snapshots. Reuse them.
- Synarchy's `src/Engine/Core/Clock.hs`, inspected read-only at the previously
  recorded `064a255f` baseline, injects a monotonic source, sanitizes intervals,
  caps a sample at 0.25 seconds, and drops excess by advancing the raw baseline.
  Keep the ownership and interruption lessons, not its global game state.
- Open issues are #123 (monitor-recovery repair), #124 (native-test opt-in),
  #86 (delivered GLFW arc), and #49 (test architecture). Their bodies contain
  no scheduling/wake child.
  The older Vulkan design P-6/Q-6 now delegates this prerequisite to this doc.

## Desired experience and scope

An editor with no changes sleeps. An animation requests its next deadline and
continues even with quiet input. A worker's newly admitted command wakes that
sleep. Simulation and rendering may run at different cadences. Suspending one
window does not suspend another or stop the application's simulation.

In scope: a CPU-only time boundary and scheduling policies, session-owned wake,
production command/demand integration, the existing owner loop, and a small
per-window demand composition helper. No Vulkan dependency is needed.

Out of scope: a game simulation, a mandatory render worker, arbitrary scheduled
jobs, wall-clock timers/calendar time, GPU fences, present-mode selection,
asset streaming, platform-independent promises of hard real-time latency, and
changing the existing messaging or worker shutdown contracts.

## Decisions

### D-1. Support all three update styles with configurable limits

Owner accepted 2026-09-16: event-driven and deadline-driven updates plus an
optional fixed-step driver, with bounded catch-up and discarded excess after
long interruptions. Fixed stepping is not mandatory for engine consumers.

### D-2. Suspend rendering per window; simulation belongs to the application

Owner accepted 2026-09-16: hidden, minimized, or zero-framebuffer windows pause
their rendering. Simulation continues unless the application explicitly pauses
it. A focus change alone is not a simulation pause.

### D-3. Preserve platform and local-test policy

Existing owner decisions remain: GLFW events and the first render loop run on
the main thread; remote CI is Linux-only. Before any disruptive local test,
ask for the human user's explicit approval and wait for acceptance. Necessary
disruption is allowed within that approved session; a command in an issue body
does not provide that approval. Isolated X11 testing needs no desktop approval.

### D-4. Degrade wake failure without undoing accepted work

Owner accepted 2026-09-16: an expected native wake platform failure keeps
accepted commands and their tickets valid, warns once, and falls back to bounded
polling for that session. It does not justify resubmission or turn admission
into rejection. Unexpected programming/lifetime failures keep their existing
failure semantics.

### D-5. Final review and delivery boundaries

The owner's requested final review on 2026-09-16 checked P-1 through P-5 against
the current session, callback capture, command, owner-loop, and runtime code.
The six slices are ready for issue processing, with per-call wake error evidence,
concurrent-demand semantics, exact debt accounting, and explicit native proof
requirements clarified below. This status authorizes processing; each tracker
artifact still receives its own approval. No Vulkan decision blocks this arc.

## Design

### P-1. Time values and ownership

Foundation owns an injected monotonic source, opaque non-negative durations and
instants, and pure deadline arithmetic. Runtime owns step policy and GLFW owns
native wait conversion. No clock value is a wall-clock timestamp or portable
save-file value. Independently constructed scheduling clients share the same
clock domain when their deadlines are compared.

Use integral time units internally. Elapsed durations and remainders may be
zero; configured periods, caps, and native timed waits must be finite and
strictly positive. Arithmetic must not wrap silently. A fake source can
repeat or move backwards: elapsed time then contributes zero and its baseline
is replaced, matching Synarchy's no-replayed-debt principle. An IO failure of
the clock remains an attributed failure, not a fabricated timestamp.

The first sample establishes a baseline and supplies zero elapsed time. A
large positive jump is measured but only a configured bounded part is delivered
to an update policy. Store the latest raw instant after every sample; never
keep recharging a suspended interval. No user simulation rate is chosen by the
foundation. Configurations supply their periods and limits explicitly.

### P-2. Update policy is independent of rendering

- Event-driven consumers have no periodic deadline. Native events/commands can
  make an owner turn useful without advancing a simulated tick by themselves.
- Deadline consumers express immediate demand, an absolute deadline, or no
  current demand. Expired deadlines cause polling/processing, never an invalid
  zero or negative native timeout. Removing a deadline removes its demand.
- Variable-step consumers receive bounded elapsed time and explicit evidence
  of discarded elapsed time. A scheduling helper does not hide a long pause.
- Fixed-step configuration names a positive step duration, a positive maximum
  accepted elapsed interval, and a positive maximum number of steps per turn.
  Add the accepted elapsed time to the fractional remainder; run at most the
  configured number of whole steps. Drop whole overdue steps beyond that
  budget, retain only the sub-step remainder, and report the discarded time.
  Interpolation, if requested, is that remainder divided by the step duration
  and remains in [0,1). No replay queue grows with the interruption length.
  Account for both elapsed-time clipping and discarded whole steps, once each:
  old remainder + raw non-negative elapsed = executed step time + new remainder
  + total discarded time. For example, a 4 ms remainder and 85 ms elapsed, with
  a 70 ms elapsed cap, 10 ms steps, and three-step budget, execute 30 ms, retain
  4 ms, and report 55 ms discarded. The next step is due 6 ms after this sample;
  time spent performing those steps consumes that interval.
- Resume after an explicit simulation pause rebases time and clears outstanding
  catch-up debt; time spent paused is not simulated. Window visibility alone
  never invokes this operation.
- Step and frame deadlines are absolute: time spent in callbacks counts toward
  the next opportunity. Missed render opportunities coalesce into current
  demand; there is no backlog of obsolete frames. A consumer that returns
  immediate demand continuously explicitly chooses a busy loop.

Keep this as a testable policy with caller-owned state, not a background timer
thread or a new engine environment. Configuration errors fail before a loop
starts. Updating rates at runtime, if exposed, must explicitly rebase rather
than reinterpret accumulated debt; hot rate changes are not required here.

### P-3. Session lifetime and wake semantics

The production binding adds GLFW's documented cross-thread empty-event call;
ordinary event pumping and native window operations remain owner-thread-only.
A session lends an opaque wake capability that cannot be used to obtain native
handles. A retained capability becomes terminal when its session closes and
cannot accidentally wake a subsequent session.

Closing disables new native wake calls and establishes that already admitted
wake calls have finished before GLFW terminates or callback storage is freed.
An unchecked live flag followed by an FFI call is insufficient. The limited
wake operation must not invoke arbitrary user IO while participating in this
exclusion. Preserve error-callback capture on the calling thread, attributed
origins, startup rollback, and failure evidence during termination.

The current capture distinguishes only the process-main bucket from a shared
other-thread bucket. Draining that shared bucket after a wake cannot identify
which call failed. TIME-3 must establish bounded per-call native evidence without
consuming unrelated errors or re-reporting the same wake error as an unrelated
fatal error. If thread-local GLFW error state is used, the native call and its
error retrieval must stay on the same OS thread; a Haskell thread identity alone
does not establish this. Callback faults and lost evidence cannot become a
successful wake. Keep callback recording finite, nonblocking, and exception-safe.
Tests must overlap two wake callers and an unrelated callback report.

The wake is a hint; command and demand state are authoritative. No one-message,
one-event correspondence is required. Implementations may coalesce wakes, but
must prove that work arriving during wait entry, during a wait, or during
notification consumption cannot be forgotten. Spurious and repeated wakes
must not cause repeated execution. Idle waits always retain a finite configured
fallback bound; waking does not turn arbitrary hooks into bounded operations.

Expected platform wake failure degrades the wake path for that session, retains
attributed diagnostic evidence for the owner, and uses finite waits. It does
not reclassify admitted work as rejected or retry the command. Report the
degradation once, using the established diagnostic contract. Programming and
lifetime violations remain typed failures rather than automatic recovery.
This failure policy is accepted by D-4.

### P-4. Admission and demand publication

Connect both immediate and explicitly waiting command admission to wake,
including host commands and per-window commands. Full or closed admission
creates neither a ticket nor runnable demand. An accepted command retains its
existing ticket and settlement semantics even if a later wake attempt fails.

No asynchronous-exception gap may lose the notification obligation after an
admission commits. Cancellation before commit admits nothing; after commit,
the command is still accepted and can execute, and cancellation cannot retract
it or authorize automatic resubmission. As with the existing API, cancellation
can prevent a caller from receiving the returned ticket; do not promise an
impossible atomic IO return. Internal ownership must still settle that ticket
and arrange wake or bounded fallback progress.

Application demand published from a worker similarly records authoritative
state before notifying the owner. Provide a bounded, host-owned capability for
earlier deadlines or fresh demand, not an unbounded timer registry. Publishing
and taking demand must preserve newer revisions: a consumer acknowledging an
older revision cannot erase a new request. Repeated dirtiness coalesces; an
update cannot monopolize a turn by continuously replacing itself.

Bound publication to an application demand slot and live-window demand slots;
do not allocate an enduring slot per worker or per request. Concurrent worker
requests combine immediate demand and the earliest requested deadline. A later
request cannot overwrite an earlier pending deadline, and one publisher's
absence of demand cannot cancel another publisher's request. The owner consumes
the captured request revision and sets its own ongoing schedule; publication
after that capture remains pending. Keep ongoing periodic schedules distinct
from these coalesced requests so an old request does not become permanent work.
Closing a slot rejects publication and cannot resurrect an ended window.

Retained ports/demand capabilities remain safe after shutdown, and publication
cannot race GLFW termination into a late FFI call. Quiescence closes admission
and demand; internal retirement progress can keep its own wake capability until
the host/session actually finishes. Do not disable all wake support merely
because normal command admission has closed.

### P-5. Owner turns and per-window demand

Offer an additive scheduled-loop entry point or equivalent compatibility path;
preserve the current loop and existing consumers. The scheduled path samples
time, checks supervision and ready state, chooses polling or a bounded wait,
then resamples/reconciles after the native call. The effective wait is at most
the earliest deadline and the configured checkpoint/fallback bound. Demand
arriving between inspection and wait entry participates in P-3's wake protocol.

Keep finite command/event budgets and checkpoints. Due updates receive an
opportunity every bounded turn even under continuous traffic. An event wake
does not itself require a redraw, and finishing update work does not imply
there is immediate demand for another update. Fair per-window work opportunities
prevent one always-dirty window from consuming the entire render budget.

The helper owns only scheduling state keyed by opaque live window identity.
It combines application simulation demand with a window's explicit dirtiness
or frame deadline and observed eligibility. Known hidden/minimized state or
known zero framebuffer extent suspends that window's render opportunity.
Unknown observations are not invented: unknown framebuffer size defers rendering
until a usable extent is known; an unsupported visibility/minimize observation
does not assert suspension. Closing/ended windows lose normal render demand.

While suspended, keep the latest need to redraw but exclude that window's
expired frame deadlines from wait selection, preventing a busy loop. Resume
rebases its frame schedule and requests one current frame; it does not replay
missed frames. Deleting a window removes its scheduling state. Application
simulation still supplies its independent deadline, even if every window is
suspended. No simulation demand and no eligible window work means waiting.

This helper invokes no Vulkan API and infers no GPU readiness. A future backend
must additionally account for presentation backpressure and completion.
Retirement demand is separate from normal rendering eligibility: hiding or
closing a window must never suppress the progress that makes it safe to destroy.

## Open questions

### Q-1. Which update styles belong in the first arc?

Resolved by D-1.

### Q-2. Does inactive-window rendering pause simulation?

Resolved by D-2.

### Q-3. Approve the concrete policy and delivery split?

Resolved by D-5 following the requested final review. D-4 settles wake
degradation; P-1 through P-5 state the remaining contracts. TIME-1 remains
independent of native wake implementation, and no Vulkan capability decision
blocks any TIME slice.

### Q-4. Does an expected platform wake failure end the host?

Resolved by D-4.

## Verification strategy

Use Hspec with injected clocks, native seams, and coordinated concurrency.
Check exact deadlines/remainders rather than sleeping to test frame rates.
Cover first/repeated/backward samples; arithmetic boundaries; long jumps; pause
and resume; work that consumes its budget; constant command traffic; unrelated
native events; multiple windows; suspension; and demand revisions.

Wake tests cover pre-wait, in-wait, publication/notification cancellation,
full/closed queues, concurrent earlier/later deadlines, notification coalescing,
per-call error attribution, native failure, startup rollback,
concurrent termination, and stale capabilities reused during a later session.
Retain completion ticket outcomes and original failure evidence.

Real Linux X11 tests must exercise the production wake path against a genuinely
entered native wait, using synchronization/progress evidence rather than fragile
millisecond thresholds. Keep these in the affected native group. MacOS native
evidence uses the same production path, only after human approval; no remote
macOS CI. TIME-3 must retain the first production wake/teardown evidence on both
platforms before merge. Later slices use focused headless and selected Linux
checks; additional local native runs are chosen for the changed boundary and
require their own human approval. A model result is not native wake evidence.
Test failures and missing
required environments must never be reported as passes.

Each slice carries its Hspec coverage and owning contract documentation in its
implementation PR. Existing fixtures and CPU/native suite separation remain.
Logical test ownership follows the implementing package/component. A later
package-suite migration may change paths and catalog IDs, not these proof
obligations; processors use the then-current suite layout and do not duplicate
examples in both a root aggregate and a package suite.

## Delivery plan

### TIME-1. Add the monotonic time and deadline boundary

- **Outcome:** a CPU-only injected clock and safe time arithmetic.
- **Scope:** P-1, validated durations, origin-aware clock failures, component tests.
- **Phase:** independent foundation.
- **Depends on:** none.
- **Ordering:** can land first.
- **Relevant decisions:** D-1, D-3.
- **Acceptance signals:** exact scripted-time results; no display dependency;
  invalid/overflowing inputs are explicit; public opacity remains enforced.
- **Out of scope:** step policy, owner-loop changes, native wake.
- **Open questions:** None.

### TIME-2. Add bounded variable and fixed-step update policies

- **Outcome:** application-owned elapsed/debt policy with bounded work.
- **Scope:** P-2, independent CPU helper and focused Hspec examples.
- **Phase:** scheduling model.
- **Depends on:** TIME-1.
- **Ordering:** independent of native wake.
- **Relevant decisions:** D-1, D-2.
- **Acceptance signals:** exact steps, fractional remainder, dropped time,
  absolute next deadline, explicit pause/resume and configuration rejection.
- **Out of scope:** game logic, native calls, background tick threads.
- **Open questions:** None.

### TIME-3. Own a cross-thread native wake capability with the GLFW session

- **Outcome:** a narrow production wake operation cannot outlive its session.
- **Scope:** P-3, private binding, native error attribution, lifetime protocol,
  model and real native evidence. Introduce no command-path behavior yet.
- **Phase:** independent GLFW prerequisite.
- **Depends on:** none.
- **Ordering:** can land alongside TIME-1.
- **Relevant decisions:** D-3, D-4.
- **Acceptance signals:** a worker ends a native wait; cancellation/termination
  races never call GLFW after teardown; stale wake tokens cannot target a new
  session; no user callback runs under the lifetime exclusion; concurrent native
  failures retain their own attribution without stealing unrelated reports.
- **Out of scope:** scheduler, Vulkan, promoting test-only hooks to public API.
- **Open questions:** None.

### TIME-4. Connect admitted commands and published demand to native wake

- **Outcome:** accepted work published during native waits has owned notification.
- **Scope:** P-4 and P-3 degradation, all admission paths, bounded demand
  publication, existing owner-loop responsiveness, closure races.
- **Phase:** production handoff.
- **Depends on:** TIME-1, TIME-3.
- **Ordering:** critical path to scheduled integration.
- **Relevant decisions:** D-1, D-3, D-4.
- **Acceptance signals:** existing tickets settle once; later wake failure never
  looks like command rejection; adversarial wait-entry and publication schedules
  retain work; notification state remains bounded.
- **Out of scope:** fixed-step integration, render policy, new messaging primitives.
- **Open questions:** None.

### TIME-5. Drive owner turns from ready work and absolute deadlines

- **Outcome:** an additive scheduled loop preserves supervision and fairness.
- **Scope:** P-5 turn selection and wait calculation with TIME-4 publication.
- **Phase:** owner integration.
- **Depends on:** TIME-1, TIME-4.
- **Ordering:** critical path.
- **Relevant decisions:** D-1, D-3.
- **Acceptance signals:** quiet queues do not delay due updates by 100 ms;
  time spent working counts against deadlines; traffic cannot starve updates;
  idle turns wait; legacy loop examples remain green.
- **Out of scope:** per-window frame policy and actual rendering.
- **Open questions:** None.

### TIME-6. Compose per-window render demand with application simulation

- **Outcome:** a reusable CPU-tested helper composes independent simulation and
  per-window rendering opportunities without creating a renderer.
- **Scope:** P-5 eligibility, fair opportunities, suspend/resume, state removal,
  example composition with TIME-2 policies and TIME-5.
- **Phase:** pre-graphics consumer seam.
- **Depends on:** TIME-2, TIME-5.
- **Ordering:** last in this arc.
- **Relevant decisions:** D-1, D-2, D-3.
- **Acceptance signals:** multi-window Hspec cases; suspended windows cannot
  cause busy waits or stop simulation; new demand survives old acknowledgements;
  no growing state from closed windows or missed frames.
- **Out of scope:** GPU synchronization, frame submission, presentation modes.
- **Open questions:** None.

## Source notes and handoff

The [GLFW window reference](https://www.glfw.org/docs/3.4/group__window.html)
documents timed waits and cross-thread empty events. Timed waits require positive
finite arguments; native event processing itself may block during platform
interaction. That limits latency claims, not the scheduler's arithmetic.
The [GLFW error reference](https://www.glfw.org/docs/3.4/group__init.html)
defines calling-thread error retrieval; the existing Capture module's two
buckets are repository behavior, not a per-call attribution mechanism.

This is the scheduling owner; the [Vulkan design](vulkan_backend_design.md)
links here rather than drafting duplicate children. The test opt-in follow-up
is [#124](https://github.com/coghex/hetoimasia/issues/124), not a prerequisite
for CPU work. #123 should precede
new changes to the window controller, but does not block TIME-1/2/3. Final
issue processing must recheck the tracker and record current prerequisites.
