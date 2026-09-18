# Project Review Findings: PRs #165–#150

Reviewed 2026-09-18 against `master@8e4eb6e2be8ee8fbd1ef88230e64107b0a170425`
in `coghex/hetoimasia`. The exact batch is **#165, #164, #163, #162, #161,
#159, #156, #154, #153, #152, #151, and #150**, newest first, against issues
**#144, #139, #143, #138, #136, #134, #141, #142, #135, #133, #130, and
#129**, including their canonical issue-review amendments, merged patches,
commit messages, current consumers, tests, and contracts. Direct documentation
commits `8d24909` and `b0a24df` in this interval were also inspected. This is
explicit coverage of those twelve PRs, not every number in the filename range.

The architecture remains aligned: narrow owning packages, no universal engine
environment, application-owned simulation policy, monotonic scheduling,
bounded cross-thread publication, and CPU lifetime kept distinct from graphics
retirement. The managed application lifetime composes around worker drain
without introducing a global shutdown registry. Test ownership now matches the
packages, with console integration at root and workflow tests separate. The
merged #136 accounts for notification obligations transactionally and installs
automatic exit reporting; those earlier review blockers are resolved.

Four current problems need repairs before treating the graphics-lifetime
boundary as ready for real GPU dependents. They do not require an architectural
restart. Toolchain qualification, native compatibility proofs, and the pure
Vulkan ownership model can progress independently.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]` reviewed and deliberately never to be filed · `[deferred]` blocked on a concrete precondition

## Status

- [ ] PRR-1. Contain completion-policy evaluation before dependent construction
- [ ] PRR-2. Revive retirement consistently when the owner certifies new evidence
- [ ] PRR-3. Let waiting retirements beyond the turn budget become idle
- [ ] PRR-4. Preserve diagnostic-failure identity across GLFW lifecycle reporting

## 1. Protected lifetime safety

### PRR-1. Contain completion-policy evaluation before dependent construction

> **Captured note:** P1. PR #165 adds a lazy `protocolCompletion` field which
> is evaluated outside the retirement attempt's exception boundary. An exception
> in that field can escape the protected drain and release the native window and
> session while a successfully constructed attachment still owes every fact.

**Verification:** A temporary Hspec example uses the existing attachment fixture
with `scriptCompletion = error "review: deferred completion policy"`. Construction
succeeds and the application returns normally, without running an owner turn.
The protected exit then raises that exception. The independent journal is:

```text
[Constructed "alpha", WindowGone 1, SessionEnded]
```

There are no `Certified` entries: destruction happened without CPU-use,
submission, presentation, or dependent-disposal evidence. This is an actual
escape from the protected boundary, not merely an unhelpful error message.

**Evidence:**

- `packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal/Retirement.hs:449`
  — `AttachmentProtocol` leaves completion metadata unevaluated.
- The same file at `:548` — reservation and construction proceed without
  validating that metadata; construction results themselves are correctly forced
  inside their handler.
- The same file at `:885` and `:1141` — both ordinary-turn and protected-drain
  guards demand `protocolCompletion` outside `tryWithContext`.
- `packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal.hs:1873`
  and `:1939` — an exception escaping `drainRetirement` leaves the enclosing
  `withScoped` and releases the window collection/session.

**Handoff context:**

- **Current behavior:** a synchronous metadata exception after acquisition
  bypasses the very guard meant to retain live dependents.
- **Expected behavior:** reject invalid protocol metadata before dependent
  construction, or contain its failure while retaining all unsafe dependencies
  until independent evidence permits release. A metadata failure must never
  authorize unwinding an unretired attachment.
- **Scope and constraints:** a focused repair to the public attachment and
  protected-retirement boundary, with tests and contract comments in the same
  PR. Audit metadata demanded outside callback handlers, including the handoff
  into construction; merely making a field strict at a late use is insufficient.
  Preserve primary/cleanup context, cancellation, and the prohibition on
  pretending an unknown disposal succeeded.
- **Verification target:** inject an exception in completion-policy evaluation
  and assert acquisition/destruction ordering both on normal application exit
  and an in-run retirement. Keep the existing callback-result, rollback, and
  cancellation regressions. A useful early-rejection test asserts construction
  never ran; an after-acquisition failure test must provide independent evidence
  before expecting scope exit.
- **Deduplication:** open tracker inventory and all-state searches for
  retirement/completion-policy failures found no repair issue. #144 is closed;
  epic #140 and Vulkan model #160 do not specify this correction.
- **Remaining uncertainty:** no GPU was involved. The violated parent-lifetime
  invariant is established with the production host and scripted dependents.

## 2. Retirement progress and scheduling

### PRR-2. Revive retirement consistently when the owner certifies new evidence

> **Captured note:** P2. The direct owner-thread certification path records a
> new fact but leaves a stalled registration withdrawn. The queued publication
> path revives that same registration on the same new evidence. An owner using
> the public direct operation can therefore strand retirement unnecessarily.

**Verification:** In the production public attachment API, attach an owner whose
first retirement step returns `RetirementStalled`, detach it, and run one turn.
Prepare its remaining finite steps, then call
`certifyGraphicsFact host acknowledgement CpuUseRetired` on the owner thread.
It answers:

```text
Just (FactRecorded [SubmittedWorkEnded,PresentationEnded,DependentsDisposed])
```

After another turn the step count is still one, not two. The registration remains
excluded from progress. The test then publishes independent completion notices
for all facts and exits safely. Publishing only a duplicate of the direct fact
cannot rescue it either: duplicates correctly do not revive a path.

**Evidence:**

- `packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal.hs:2374`
  — public `certifyGraphicsFact` delegates to owner-thread certification.
- `packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal/Retirement.hs:698`
  — direct certification records/prunes but never revives the registration.
- The same file at `:1091` — notice folding revives registrations only for
  genuinely new facts, using `established`.
- The same file at `:849` and `:1123` — both progress paths skip withdrawn
  registrations.
- `docs/glfw.md:2801` and `:3106` — implementation prose currently describes
  revival specifically through notices. This restriction should be reconciled
  with the public owner-authority interface, not silently left in the contract.

**Handoff context:**

- **Current behavior:** liveness depends on which transport carries valid
  evidence from the same acknowledgement. A main-thread integration must queue
  a fact to itself instead of using its direct certification operation to obtain
  equivalent progress.
- **Expected behavior:** new independent certified evidence may restore a
  withdrawn progress path consistently on the owner thread and through queued
  publication. Duplicate, stale, refused, and foreign facts must not do so.
  Fresh evidence is still required; no unconditional replay of failed effects.
- **Scope and constraints:** the mismatch originates in #143/PR #163's private
  coordinator and becomes public through #144/PR #165. Correct code and the
  notice-only wording together. Preserve exclusive ownership, acknowledgement
  validation, retirement ordering, and bounded state. Do not create a worker or
  weaken the rule that actual completion is certified by the integration.
- **Verification target:** cover a stalled owner receiving the same new fact
  through direct and queued operations, and verify another finite opportunity
  is offered. Exercise duplicate/refused facts as negative controls and confirm
  disposal still waits for every remaining fact.
- **Deduplication:** all-state retirement/stall searches and the open inventory
  found no issue for this asymmetry. The completed LIFE children do not track a
  follow-up; #160 is a different, pure Vulkan ownership model.
- **Remaining uncertainty:** the implementation's notice-only wording is
  explicit. This finding calls out an integration-contract gap as well as the
  reproduced liveness difference; update the contract deliberately in the repair.

### PRR-3. Let waiting retirements beyond the turn budget become idle

> **Captured note:** P2. PR #165 treats every progressing attachment not visited
> in the current turn as immediate deferred work, including attachments already
> known to be waiting. If their count exceeds the budget, every turn polls forever.

**Verification:** Configure two windows and `hostRetirementBudget = 1`. Detach
both attachments. Every offered step answers `RetirementAwaitingUntil` at 10 ms;
the scripted monotonic clock stays at zero and there is no application demand or
queued work. Run six scheduled turns. Actual pacing is:

```text
[PolledForWork,PolledForWork,PolledForWork,
 PolledForWork,PolledForWork,PolledForWork]
```

After both owners have been inspected, subsequent turns should be able to wait
toward the earliest deadline, bounded by the fallback. The same condition is
reachable with the defaults: five waiting attachments exceed the budget of four,
within the host's sixteen-window capacity. The test supplies safe facts before
exit; it neither sleeps nor leaves a hanging drain.

**Evidence:**

- `packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal/Retirement.hs:844`
  — rotating selection is fair but retains no cross-turn waiting assessment.
- The same file at `:858` — `roundDeferred` includes every progressing entry
  not offered this turn, even if the preceding turn learned its future deadline.
- `packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal.hs:2444`
  — any positive deferred count sets immediate retirement demand.
- The same file at `:1729` — the scheduler responds by polling.
- `packages/glfw/test/Test/GLFW/Attachments.hs` — existing rotating-budget
  coverage checks fairness, and the deadline example uses one retiring owner;
  neither tests their combination.

**Handoff context:**

- **Current behavior:** a bounded number of callbacks per turn becomes an
  unbounded stream of turns while retirement is merely waiting, defeating idle
  scheduling and potentially consuming a CPU core during delayed presentation.
- **Expected behavior:** new or genuinely ready unserved work receives timely,
  fair opportunities, but already inspected waiting owners permit finite waits.
  Preserve their earliest relevant deadline across budgeted rounds.
- **Scope and constraints:** retirement accounting and its scheduling contract,
  not a replacement owner loop. Keep state bounded by the window limit. Do not
  remove the first-opportunity guarantee, raise the budget as a workaround, or
  make a stalled owner starve an unserved neighbour.
- **Verification target:** deterministic Hspec cases with more waiting owners
  than the budget, different deadlines, no deadlines, a stalled neighbour, and
  new evidence/new retirement arriving between turns. Assert eventual waits
  without losing fairness, wake responsiveness, or ordinary frame demand.
- **Deduplication:** no open or closed repair covers this budget/deadline
  combination; TIME #138 and LIFE #144 are complete implementation issues.
- **Remaining uncertainty:** the probe proves continuous polling, not a measured
  wall-clock CPU percentage. No performance percentage is claimed.

## 3. Diagnostic lifecycle integration

### PRR-4. Preserve diagnostic-failure identity across GLFW lifecycle reporting

> **Captured note:** P2. The wake warning introduced by PR #161 and the stall
> warning introduced by PR #163 propagate unmarked diagnostic failures. The
> runtime consequently reports the sink failure through the same sink and may
> flush it, contrary to the existing logging-lifetime failure policy.

**Verification:** Two headless examples run through the real application and
logging lifetimes with a callback sink that records every write, throws only for
the specified GLFW warning, and counts flushes.

1. An expected native wake failure follows a demand publication, and the
   ordinary `runWindowApplication` exit owes its warning. Actual operations:
   `(["glfw.wake", "runtime"], 1 flush)`.
2. An attachment stalls during protected shutdown. The scripted warning
   callback publishes independent safe retirement facts before throwing, so the
   drain can finish without a hung thread. Actual operations:
   `(["glfw.retirement", "runtime"], 1 flush)`.

Both retain the original thrown exception, but both perform a second diagnostic
write and a flush. Expected: just the first warning attempt and no flush through
that failed diagnostic path.

**Evidence:**

- `packages/glfw/model/Hetoimasia/GLFW/Internal/Notify.hs:219` — the guarded
  warning attempt records notifier-local failure but rethrows without the
  runtime's diagnostic distinction.
- `packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal/Retirement.hs:1213`
  — the stall warning likewise retains its failure as an unmarked exception.
- `packages/runtime/src/Hetoimasia/Runtime/Reporting.hs:255` — terminal reporting
  suppresses a diagnostic failure only when its context carries that distinction.
- `packages/runtime/src/Hetoimasia/Runtime/Logging.hs:165` — finalization checks
  recorded failed reports and the diagnostic annotation before deciding to flush.
- `docs/runtime_foundation_design.md:979` — a known failed runtime-managed
  diagnostic path must not be retried or flushed.

**Handoff context:**

- **Current behavior:** the new host owns its one warning attempt but does not
  carry that failure identity into the outer runtime reporting/finalization.
- **Expected behavior:** preserve the original exception and context while
  conveying that diagnostics have failed, so outer owners neither report that
  failure back through the sink nor flush it. Preserve an existing application
  primary and retain secondary diagnostic evidence.
- **Scope and constraints:** repair the GLFW/runtime integration, including both
  warning paths and documentation, without a model-to-runtime dependency
  inversion. `Notify` lives below the runtime package; importing runtime reporting
  there directly is not a valid shortcut. Reporting stays outside controlled
  uninterruptible releases. Cancellation remains cancellation, not a synchronous
  logging failure, and failed diagnostics never authorize early window release.
- **Verification target:** full ordinary and protected application lifetimes,
  warning failure after successful work and alongside an existing primary,
  cancellation, filtered warnings, and normal successful warnings/flushes. Check
  writes, flush count, retained context, and resource order, not only exception type.
- **Deduplication:** all-state `diagnostic` and `sink` searches found the closed
  logging/runtime issues (#55/#58/#60 and earlier logging repairs), but no current
  issue for these new GLFW paths. The open Vulkan diagnostics design is separate.
- **Remaining uncertainty:** both warning paths are reproduced at HEAD. The
  appropriate cross-package propagation mechanism remains a repair design choice.

## Validation and handoff

At the reviewed revision, `cabal build all` succeeded. Existing Hspec suites all
passed: foundation **336**, runtime **184**, headless GLFW **423**, root console
**11**, workflow **335** — **1,289 examples, zero failures**. Native tests were
compiled but not run. No desktop session, real GLFW window, or GPU was used by
this review; local native verification still requires the human's explicit
approval. The merged PRs' GitHub records carry passing aggregate CI evidence;
that is historical evidence, not a native run performed by this review.

Five additional temporary Hspec examples reproduce the four findings against
unchanged production libraries: **5 examples, 5 failures**, seed `207715269`.
They reuse `Test.GLFW.Attachments`' scripted owner and native seam in a temporary
copy, with deterministic clocks and explicit completion evidence. No production
or checked-in test file was edited. The retained local reproduction directory is:

```text
/var/folders/xs/kyf0vrg92c340wk3jncyp1fr0000gn/T/hetoimasia-review-165-150-s5gvud0s/
```

It contains `ReviewAttachments.hs`, `ReviewMain.hs`, `probe-command.json`,
`probe-build.log`, `probe-results.log`, `headless.log`, `build-all.log`,
`workflow.log`, and the downloaded PR/issue evidence. The numbered reproductions
above preserve the required setup and observable results independently of that
temporary directory.

Repair PRR-1 before live graphics dependencies. PRR-2/PRR-3 touch the same
retirement coordinator and should be sequenced or reconciled carefully; PRR-4
has a distinct reporting concern. Keep each repair's tests, comments, and
contract corrections in its code PR. Process this report one finding at a time;
no tracker issues were created or edited by the review.
