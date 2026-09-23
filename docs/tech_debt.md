# Technical-debt findings

An accumulating record of verified maintenance concerns in Hetoimasia, for
later one-at-a-time processing into solvable issues. This report records
evidence and recommendations; it authorizes no implementation or tracker
mutation.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Methodology

- Initial entry recorded on 2026-09-22 from the owner's request to preserve the
  GPU-model refactoring recommendation while opposite-agent review is
  unavailable. Owning repository: `coghex/hetoimasia`; default branch: `master`.
- Source inspection used `master@da81087bb2c81e844588a0fc30197bd99201c6b9`:
  the GPU model's implementation, public facade, Cabal component declarations,
  package-owned tests, and `docs/gpu_model.md`. Line references below belong
  to that snapshot.
- No tests were rerun to create this report. The preceding comment-correction
  task passed all 134 GPU-model examples on `1098d86`, the head created for
  [PR #241](https://github.com/coghex/hetoimasia/pull/241). That is historical
  validation evidence, not validation of a future refactor.
- File length was a search lead, not proof of a defect. TD-1 is supported by
  the distinct responsibilities and dependencies found in the implementation.
  No new runtime correctness defect is claimed.
- TD-2 through TD-5 were added on 2026-09-22 after focused inspection of the
  GLFW host, graphics owner, window implementation, and graphics-owner tests
  at the same `da81087` snapshot, including their Cabal and suite wiring.
  These are verified structural concerns; no tests were run for these additions.
- A final focused pass on 2026-09-22 added TD-6 through TD-8 from the Lua
  session model, validation planner and its consumers, and asynchronous logging
  adapter at the same `da81087` revision. These additions are source-based
  refactoring recommendations, not reproduced runtime defects. No tests ran.
- Tracker deduplication and final issue scope belong to a later
  `process-report` invocation. Recheck current code, open work, and tracker
  coverage then.

## Status

- [ ] TD-1. GPU-model state implementation concentrates several responsibilities
- [ ] TD-2. Graphics-owner implementation mixes worker progress with client handover and exit
- [ ] TD-3. Main-thread window host combines composition, scheduling, and protected shutdown
- [ ] TD-4. Window implementation combines callback capture with native mode transitions
- [ ] TD-5. Graphics-owner tests embed shared fixtures among many lifecycle scenarios
- [ ] TD-6. Lua session model concentrates several aggregate transition protocols
- [ ] TD-7. Validation planner mixes repository parsing, selection policy, and CLI integration
- [ ] TD-8. Asynchronous logger embeds pure record preparation in its concurrent adapter

## Maintaining this report

Append new findings with the next unused `TD-N` key, preserving existing keys.
Keep checklist order aligned with finding order. Each new finding should name
its inspected revision, evidence, practical cost, and uncertainty. Keep related
symptoms together when they would receive one disposition.

New findings remain unprocessed. Let `process-report` record dispositions and
issue links, handling one finding per invocation. Re-read this file before
editing it because other agents may be adding findings concurrently.

The owner's size preference is approximately 200 lines per file, with around
500 acceptable for more involved, cohesive modules. These are guidelines:
preserve clear ownership and useful boundaries rather than splitting solely
to meet a count. Only the candidates with focused evidence below have been
promoted into findings; other large files still need their own inspection.

Suggested sequencing: retain TD-1 as the next GPU-model cleanup. For work on
the GLFW graphics integration, TD-5 is a useful preparatory extraction before
TD-2; TD-3 is next when extending the host, and TD-4 when extending window
behavior. These are separate reviewable changes, not prerequisites that must
all block unrelated development. TD-2 and TD-3 share composition boundaries:
coordinate them rather than refactoring the same interfaces concurrently.

## Review of the proposed combined layout

Reviewed on 2026-09-22 against `da81087`, following the owner's request to
assess the eventual layout as a whole. Verdict: the responsibility boundaries
are sensible, but the earlier extraction lists alone are not a complete module
design. Apply the refinements below when processing TD-1 through TD-5. This is
a source-based architectural assessment, not a compiled implementation or a
readiness approval.

Keep the existing package/component boundaries and public entry points. The
proposed changes organize private implementation; they need no new package,
service framework, or additional runtime owner. In particular, the pure GPU
model remains SDK-independent. GLFW's private component named `model` already
contains IO over injected native operations; only its pure helpers should be
described as pure.

### Naming and navigation

Use the following as a naming guide, with exact files settled from dependencies:

| Existing private namespace | Suggested organization | Navigation rule |
| --- | --- | --- |
| `GPU.Model.Internal` | `State`, focused queries, `Scheduling`, domain transitions, `Progress`, `Observation` | State defines representation; Progress composes transitions; Observation exposes views |
| `Runtime.GLFW.Internal` | `Host/State`, `Host/Windows`, `Host/Loop`, `Host/Pacing`, `Host/Lifetime`, `Host/Attachments` | Host means the process-main-thread window host |
| `Runtime.GLFW.Internal.Owner` | `Operations`, `State`, existing `Handoff`, `Worker`, `Handover`, `Lifetime` | Owner means the supervised graphics worker; Handover is its client-side attachment path |
| `GLFW.Internal.Window` | `Identity`, observation types, `State`, `Callbacks`, `Reconcile`, `ModeTransition`, construction/control | Window means one native window; ModeTransition interprets the existing pure Mode planner |
| `Test.GLFW.Owner` | Behavior-group specs and focused fixture modules | Specs assert behavior; fixtures provide the fake backend, journal, timer, and host rig |

These names do not require one file per cell or one file per small helper.
Retain existing public facade names and the existing `Owner.Handoff` name.
Explain that Handoff is the cross-thread publication protocol, whereas Handover
is the protected attach/reserve/announce operation. New internal code should
import its owning leaf modules directly, rather than importing an umbrella
that re-exports the consumer and creates a cycle. Prefer domain names over
`Common`, `Utils`, or an unbounded `Types` module.

### Dependency refinements

1. **GPU scheduling must depend on queries, not transition implementations.**
   The intended direction, with arrows meaning imports, is:

   ```text
   public facade -> Progress -> domain transitions -> Scheduling
   Scheduling -> read-only eligibility/work/deadline queries -> State
   Observation -> read-only queries / State
   State -> existing Identity / Hold / Budget / Recovery value types
   ```

   This is a layering sketch; higher layers may also import lower layers
   directly. Shared accounting edits belong below the transitions that compose
   them. In particular, eligibility and recovery-deadline queries cannot live
   only in mutation modules that themselves import Scheduling. Keep one
   authoritative eligibility rule. The current `Internal.Recovery` is already
   a focused policy/value module; model-wide recovery transitions need a
   distinct home such as `TargetRecovery`, rather than enlarging or shadowing
   that existing module. Separate allocation/reclamation only where their
   dependency and review boundaries justify it.

2. **Host and graphics owner are distinct lifetimes, joined by composition.**
   Host implementation must not import the graphics owner's composition facade.
   Owner handover and lifetime composition can consume narrow host operations;
   worker progress consumes the existing handoff, injected backend operations,
   coherent read-only publications, and wake capability. The current
   `GraphicsOwner` already stores narrow STM readers for host pending/retiring
   attachments, not a `WindowHost`; preserve that useful boundary. Keep host
   attachment retirement and whole-worker destruction/join in their respective
   lifetimes, with their ordering visible at composition. Do not merge them
   into one generic Shutdown module.

3. **Remove the existing window/input identity cycle as part of TD-4.**
   `Internal.Input` currently SOURCE-imports `WindowId` and
   `windowLocalIdentity` from `Internal.Window` (line 305), while Window imports
   Input. `Window.hs-boot` exists for that identity interface. The definition
   at Window lines 720–736 needs only `Unique`, `Natural`, and ordinary class
   instances, so it has a natural private leaf home, `Window.Identity`, imported
   by both. Preserve public re-exports and constructor opacity; remove the boot
   interface once its consumers no longer need it. This is an existing compiler-
   supported cycle, not a runtime bug. Do not introduce replacement SOURCE
   imports merely to accommodate new file boundaries.

4. **Keep each invariant's implementation locally understandable.**
   State modules define records and document ownership; they must not become
   replacement miscellaneous implementation files. Callback capture and its
   reconciliation commit may be in different modules, but the generation check,
   latch clearing, observation publication, and input admission remain one
   coherent operation. Similarly, do not spread one masked target handover or
   close commit across independently callable partial operations. Private
   exports should make the valid operation easier to use than a partial update.

### Acceptance standard for the eventual layout

A reviewer should be able to locate a behavior from its domain name, identify
its state owner and thread, and follow a transition plus its invariant without
traversing a chain of forwarding-only modules. Require an acyclic import graph
within each refactored area, preserve public opacity and component direction,
and run the existing behavioral coverage. Explicit export lists and a short
module ownership comment are more useful than a new central module inventory.

Use file length as a prompt to inspect cohesion. A coherent 400–600-line
transition module can be preferable to several 200-line fragments that always
change together. Conversely, a small identity leaf is justified when it removes
a dependency cycle. Keep useful existing modules, and split further only when
the resulting names and dependency edges explain the subsystem more clearly.

---

## GPU model structure

### TD-1. GPU-model state implementation concentrates several responsibilities

`packages/gpu-vulkan/model/src/Hetoimasia/GPU/Model/Internal/State.hs` contains
2,943 lines at the inspected revision. It defines the model's records and
resolution helpers alongside target and generation lifecycle, recording and
frame transitions, completion processing, scheduling, recovery, reclamation,
and observation.

This concentration makes a focused change expensive to review: a reviewer must
trace shared scheduling and accounting rules across several distant sections
while also checking the transition's own ownership obligations. For example,
the work summary reads disposal eligibility and recovery deadlines, and
mutating transitions use that summary to decide whether to reset scheduling.
The responsibilities have useful extraction boundaries, but mechanically
moving existing sections without understanding those dependencies could
introduce import cycles or duplicate policy.

**Evidence:**

The following references are in
`packages/gpu-vulkan/model/src/Hetoimasia/GPU/Model/Internal/State.hs`:

- Lines 262–495 define internal records, the aggregate model, and construction.
- Lines 559–675 define work summaries and the shared scheduling wrappers;
  `work` at line 572 consults `eligibleSubjects`, `replacementOwed`, and
  `recoveryDeadlines`.
- Lines 681–881 resolve identities and provide editing/accounting helpers.
- Lines 894–1323 implement targets, generations, and managed resources.
- Lines 1332–1886 implement frame reservation, acquisition, batch recording,
  submission, presentation, and abandonment.
- Lines 1893–2099 define completion evidence and apply it to held obligations.
- Lines 2104–2459 combine owner-turn orchestration, disposal, deadlines, and
  outstanding-work observation.
- Lines 2465–2759 combine recovery transitions, allocation attempts,
  reclamation, and disposal eligibility.
- Lines 2765–2943 expose read-only views and accounting observations.

Related boundaries:

- `packages/gpu-vulkan/model/src/Hetoimasia/GPU/Model.hs` is the public
  facade. Its existing exports can remain stable while implementation moves.
- `packages/gpu-vulkan/model/hetoimasia-gpu-vulkan-model.cabal` explicitly
  separates exposed modules from hidden implementation modules. The library's
  only project dependency is foundation.
- The existing `Internal/Hold.hs`, `Internal/Budget.hs`,
  `Internal/Identity.hs`, and `Internal/Recovery.hs` contain 124, 340, 337,
  and 357 lines respectively. They already have focused responsibilities;
  their lengths do not independently justify further splitting.
- `packages/gpu-vulkan/model/test/Test/GPU/Model/Spec.hs` composes the
  Identities, Holds, Frames, Budgets, Opacity, Recovery, Progress, and Sequences
  groups. Existing public-contract and cross-transition coverage must survive
  the extraction.

**Handoff context:**

- **Current behavior:** one coherent pure model value represents a graphics
  session. It receives time and completion facts from its caller, performs no
  native calls, and retains obligations until the appropriate evidence arrives.
  The concern is implementation organization, not that ownership model.
- **Expected direction:** cohesive private modules with explicit exports and
  an acyclic dependency structure, making a transition and its supporting
  invariants easier to locate and review. Preserve the public API, opacity,
  dependencies, accounting, failure precedence, and scheduling behavior.
- **Priority:** a useful next structural cleanup before additional work builds
  on this model. Independent native provisioning need not wait for it.
- **Scope and constraints:** keep one coherent model value; preserve the
  separation of submission completion, presentation retirement, and CPU
  lifetime. Keep invariant comments beside the behavior they explain.
  Accompanying contract updates belong in the same implementation PR.
  Native Vulkan implementation, optimizations, public API redesign, GLFW
  restructuring, and unrelated test-suite cleanup are outside this finding.
- **Coordination:** PR #241 contains the comment corrections already discussed
  with the owner, including this model's disposal and scheduling descriptions.
  At report creation it awaits review. Before extraction, recheck its status
  and preserve its corrections; preferably land it first. Its pending review
  does not block maintaining or extending this report.
- **Remaining uncertainty:** exact module boundaries and internal exports need
  validation against the complete dependency graph during issue preparation
  and implementation. The suggested partition below is advisory, not an
  approved module layout. No new performance or runtime-bug claim is made.

**Candidate responsibility boundaries:**

| Responsibility | Contents to keep coherent |
| --- | --- |
| State representation | Internal records, phases, and the aggregate model |
| Identity resolution | Handle validation and record lookup |
| Accounting and disposal | Budget charges/releases, eligibility, retained disposal failures |
| Scheduling | Work summaries, backoff resets, absolute deadlines |
| Targets and generations | Admission, suspension, replacement, publication, retirement |
| Recording and frames | Batch retention, acquisition, submission, presentation, abandonment |
| Completion | Applying evidence and settling its exact obligations |
| Recovery and allocation | Recovery transitions, allocation attempts, retry accounting |
| Progress | Selecting and executing bounded owner-turn work |
| Observation | Read-only views and usage reports |

These are conceptual boundaries, not a fixed number of files. Recording and
frame transitions may warrant separate modules. Aim near the owner's 200-line
preference where cohesive, allowing larger modules around 500 lines when a
transition sequence benefits from staying together.

Shared scheduling queries must remain below the transitions that use them:
scheduling already depends on disposal eligibility and recovery deadlines.
Resolve those dependencies explicitly instead of introducing cycles or copying
the same policy into multiple modules.

Private names such as `note`, `work`, `roused`, and `eligible` can be
clarified during extraction where their meaning remains unclear in the new
scope. Public renaming is outside the proposed behavior-preserving cleanup.

**Delivery and validation considerations:**

A single focused PR appears feasible, with reviewable commits separating shared
representation/query extraction, transition extraction, and progress/facade
wiring. This is a sizing recommendation to verify during processing, not an
instruction to implement now.

On the qualified toolchain, preserve existing tests and use:

```sh
cabal build all
cabal test --project-file cabal.project.cpu hetoimasia-gpu-vulkan-model:gpu-model-tests --test-show-details=direct
python3 tools/validation/plan.py --base origin/master --head HEAD
```

Run the checks required by the resulting validation plan through the normal
delivery workflow. The existing 134-example count is a dated baseline, not a
permanent required count. Verify unchanged public opacity and SDK-independent
CPU builds, and inspect the resulting module dependencies. Add a regression
test only if extraction exposes an actual uncovered contract; avoid tests that
merely assert the chosen file layout.

---

## GLFW implementation structure

### TD-2. Graphics-owner implementation mixes worker progress with client handover and exit

**Verified at:** `da81087`; source inspection only.

`packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal/Owner.hs`
contains 2,602 lines. It combines the backend operation contract, custody
records, worker execution, main-thread target handover, supervision, and
protected exit. These responsibilities cross a real thread and lifetime
boundary; reviewing a backend change currently requires tracing them through
one large module.

**Evidence:** all references below are in that file.

- Lines 290–556 define evidence, injected backend operations, and configuration;
  lines 563–918 define custody/state and observations.
- `ownerRun` (1117), `ownerRound` (1151), `offerStep` (1197), and `ownerWait`
  (1501) implement worker progress. `offerStep` reads coherent inputs and
  records their seen revisions in one STM transaction; the wait predicates
  depend on those revisions.
- `ownerDrain` (1576) retires targets, retires the whole owner, and destroys
  it, retaining failures and cancellation. `finishOwnerExit` (1869) waits for
  destruction evidence before joining and avoids reporting a supervised
  failure twice.
- `handOverGraphicsTarget` (2120) belongs to the client-side attachment path.
  Its mask spans reservation, attachment, and announcement, including recovery
  when attachment succeeded but its answer was lost.

**Proposed direction:** extract cohesive private modules for operation/evidence
types, shared custody state, worker progress, client handover, and protected
lifetime/supervision. Keep a small composition facade. These are candidate
boundaries, not a settled file layout. The existing `Owner/Handoff.hs` already
owns bounded publications; retain that boundary instead of duplicating it.

**Constraints:** keep the public API and private Cabal boundary unchanged.
Preserve coherent input transactions and wake predicates, masked handover,
exact retirement evidence, evidence-before-join ordering, and failure identity.
The backend worker must not gain a GLFW capability; only its authorized wake
crosses that boundary. Extraction must not introduce another state owner or
generic lifecycle framework.

**Priority and validation:** valuable before substantial backend integration
adds more cases here. TD-5 can make this review easier first. Preserve and run
the headless `GLFW graphics owner` examples, attachment/protected-host coverage,
and opacity checks, plus the resulting validation plan. Recheck PR #241's
comment corrections. Exact exports and the dependency graph need issue-time
design; no runtime defect or performance improvement is claimed.

### TD-3. Main-thread window host combines composition, scheduling, and protected shutdown

**Verified at:** `da81087`; source inspection only.

`packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal.hs` contains
2,796 lines. Application assembly, window admission/close, command and event
dispatch, pacing policy, attachment services, and protected retirement all
live together. A host-loop change therefore shares a review surface with
resource-unwinding rules and application-facing service construction.

**Evidence:** all references below are in that file.

- `allocHostOver` (698) constructs the host; `beginClose` (1122),
  `commitClosing` (1139), and `retireClosing` (1166) implement distinct stages
  of closing a window.
- `runOwnerLoop` (1418) and `runScheduledOwnerLoop` (1782) share `turnWork`
  (1468). Pure deadline/pacing decisions at 1736–1780 sit beside event
  processing and effectful loop orchestration.
- Protected host lifetime occupies 1928–2214, including
  `retirementEnvironmentOf`, `settleProtectedExit`, and failure settlement.
- Attachment operations and service publication occupy 2216 onward, including
  `publishService` (2525) and `advanceHostRetirements` (2745).

**Proposed direction:** separate host representation and window lifecycle,
turn/dispatch execution, pure pacing decisions, protected lifetime, and
attachment-service assembly behind the existing public facade. Reuse existing
retirement/render-demand modules. Start with the dependency graph and small
leaf extractions; splitting the file at section markers alone is insufficient.

**Constraints:** retain one main-thread host and one shared turn implementation.
Keep close-phase publication, command admission closure, and input closure in
their existing protected commit. Preserve event-processing/checkpoint order,
deadline semantics, and protected housekeeping's exclusion of application
hooks. Keep shutdown failure precedence and retained failures unchanged.
Internal representations must stay within the private `runtime-glfw-core`
component; do not broaden the public API merely to connect extracted files.

**Priority and validation:** useful ahead of further host scheduling or
attachment work; coordinate its composition boundary with TD-2. Run the
headless host, scheduled, dynamic-window, protected, attachment, and opacity
coverage and required validation groups. The detailed module graph remains
unsettled. This is a maintainability concern, not evidence of faulty pacing.

### TD-4. Window implementation combines callback capture with native mode transitions

**Verified at:** `da81087`; source inspection only.

`packages/glfw/model/Hetoimasia/GLFW/Internal/Window.hs` contains 2,321 lines.
It includes observation/configuration types, native resource construction,
callback capture, reconciliation/publication, ordinary controls, and effectful
mode transitions with recovery. Callback/input maintenance and mode-recovery
maintenance thus require navigating the same large stateful implementation.

**Evidence:** all references below are in that file.

- `windowAssembly` (1042), `createNative` (1141), and `nativeRelease` (1173)
  own native construction and release.
- Callbacks and staged input occupy 1248–1411; `reconciled` (1459) is a pure
  observation fold, while `reconcileAdjusted` (1522) prepares and commits it.
- `reconcileAdjusted` verifies the captured generation before clearing the
  latch and publishing. Fresh capture triggers another reconciliation;
  cancellation must not drop an input prefix or an unpublished observation.
- Mode execution occupies 1851–2271: `modeAttempt` (1997) coordinates monitor
  reservations and constraint restoration; `runModeSteps` (2098) executes a
  plan. Pure planning already lives in `Internal/Mode.hs`.

**Proposed direction:** extract callback capture/staging and observation
reconciliation, and separate the native mode-effect interpreter from ordinary
window construction/control. Keep the existing pure mode planner separate.
Use narrow internal operations where one area must update another's state;
avoid exposing mutable fields through the public window API.

**Constraints:** preserve the captured-generation check, masked publication,
and bounded input ordering as one coherent protocol. Keep native mode effects
out of callbacks. Preserve monitor-claim custody, constraint restoration,
required/optional recovery, and the host's protected close-phase commit.
Window lifetime and main-thread ownership must remain explicit after extraction.

**Priority and validation:** follow TD-2/TD-3 unless upcoming work specifically
extends window modes or input. Existing window, input, control, mode, dynamic,
and opacity examples provide headless contract coverage. Follow the resulting
validation plan; this report does not authorize a disruptive desktop session.
Exact internal interfaces require design; no native behavioral fault is claimed.

## GLFW test organization

### TD-5. Graphics-owner tests embed shared fixtures among many lifecycle scenarios

**Verified at:** `da81087`; source inspection only.

`packages/glfw/test/Test/GLFW/Owner.hs` contains 2,806 lines. Its spec lists
handover, independent progress, bounded-port, cancellation, exit, failure,
thread-discipline, and extent scenarios (121–254). Shared deterministic
fixtures occupy roughly 257–667, followed by scenarios and further support
helpers. Changing a fake operation or understanding one lifecycle scenario
requires navigating across unrelated behavior groups and their common setup.

**Evidence:** the module defines a journal (257 onward), `Fake` (298),
`fakeOperations` (338), `ScriptedTimer` (392), the native seam (426), and
`Rig` (560). Scenario helpers also appear much later, including `awaitIdle`
(1574), `awaitDiagnostic` (1662), and `killInside` (2457).
`Test.GLFW.Spec` already composes `Owner.spec`; the suite boundary is suitable
for retaining a small composer while moving its implementation.

**Proposed direction:** keep `Test.GLFW.Owner` as a thin spec composer. Move
shared fake backend, journal, deterministic clock/timer, and host runner into
cohesive `Test.GLFW.Owner` support modules. Split scenarios by the existing
behavior groups, leaving single-use helpers beside their scenarios. Do not
create one equally oversized `Support.hs`.

**Constraints:** fixtures belong to this component, not the neutral
`tools/test-support` library. No spec may import another spec's helpers.
Preserve Hspec paths, example count/order, assertions, explicit STM/MVar
coordination, bounded waits, and injected cancellation points. Do not change
timeouts or add sleeps to make extraction pass. This is not a proposal to
change what the tests prove or to claim faster execution.

**Priority and validation:** a useful small preparatory PR before TD-2. Compare
the selected example inventory before/after, run the existing headless
`GLFW graphics owner` group, and follow required validation groups. Update
Cabal's module list in the same PR. Other oversized test files, including
Attachments and Protected, need their own fixture/dependency inspection before
being folded into any later cleanup; this finding covers only Owner.

---

## Lua protocol organization

### TD-6. Lua session model concentrates several aggregate transition protocols

**Verified at:** `da81087`; source inspection only.

`packages/scripting-lua/model/Hetoimasia/Scripting/Lua/Internal/Protocol/Session.hs`
contains 1,467 lines. The neighboring Task, Request, and Subscription modules
already describe individual records; Session combines their aggregate state,
admission, task execution bookkeeping, provider replies, event delivery, epoch
replacement, failure invalidation, and stop reporting. The maintenance cost is
tracing session-wide accounting through many unrelated transition entry points.

**Evidence:** Session defines its aggregate at 327, shared retirement and
request revocation at 528–617, admission/task operations from 625, request
operations before `cancelRequestIn` at 951, subscriptions around 1025, epoch
replacement at 1118, failure reporting at 1238, and stop at 1398. The shared
`revokeOne`, `revocableRequests`, and `reclaim` helpers govern retained provider
accounting across these domains. `advanceEpoch`, `invalidateEverything`, and
`stopSession` clear overlapping stores but intentionally retain different
records and report different counts.

**Proposed direction:** retain Session as an internal facade over one coherent
pure session value. Put representation and construction under `Session.State`,
shared reservation/revocation operations below their consumers, and group
session-level admission/task, request, subscription, and epoch/failure/stop
operations in focused modules. Preserve the existing single-record modules;
use the `Session` namespace to distinguish aggregate operations from them.
Settle the exact grouping from imports rather than imposing a file per verb.

**Constraints:** preserve the private `model` component, with no interpreter,
clock, scheduler, or IO dependencies. Keep monotonically issued identities,
result reservations, and both request obligations intact. Rejection can retain
evidence and, for an oversized provider reply, settle a request; it is not a
transactional rollback. Do not merge epoch, failure, and stop into one generic
reset merely because their record updates look similar. Invalidation must
continue to exclude already-revoked provider-only stubs from new counts.

**Priority and validation:** useful before substantial scheduler/interpreter
integration extends the aggregate, but independent of the GPU/GLFW refactors.
Run the existing `lua-host-tests` Protocol group, including cross-domain
determinism, isolation, boundary, epoch, failure, and stop cases, and retain its
zero-interpreter construction report. Follow required validation groups. Exact
exports need design; no accounting bug or performance gain is claimed.

## Validation tooling organization

### TD-7. Validation planner mixes repository parsing, selection policy, and CLI integration

**Verified at:** `da81087`; source inspection only.

`tools/validation/plan.py` contains 1,507 lines and serves both as a CLI and a
library for sibling tools. It mixes Git/worktree access, a bounded Cabal parser,
dependency closure, catalog/request validation, changed-path classification,
candidate fingerprints, group selection, and rendering. A parser enhancement
and a validation-policy change consequently share one large review surface.

**Evidence:** `GitTree`/`WorkTree` begin at 179/218; Cabal/project parsing and
component input derivation occupy 252–556; catalog validation starts at 617;
request parsing at 771; identity computation at 871–981; `build_plan` at 987;
rendering at 1201; CLI assembly at 1342. `range.py:35` imports Git/error helpers
from plan, and `aggregate.py:48` imports request parsing from it. These are
concrete consumers of functionality whose owner need not be the CLI module.

**Proposed direction:** extract repository/path access, Cabal component inputs,
catalog/request contracts, and candidate identity into cohesive local modules.
Keep selection composition separate from CLI argument handling and rendering.
Have sibling tools import the actual owner of a helper. Reuse the existing
`receipts.py` and `ci_image.py` boundaries, with no generic plugin framework or
new parser dependency. Start with a leaf extraction rather than a whole-tooling
rewrite; exact imports and delivery size need issue-time review.

**Constraints:** keep CLI flags, JSON schemas, selection reasons, fail-closed
parsing, two-endpoint input derivation, optional/platform policy, and mandatory
policy roots unchanged. Identity algorithms stay equivalent for identical
inputs; the refactor's changed policy files should naturally invalidate prior
policy fingerprints. New modules must remain covered by policy inputs.
`run.py` deliberately checks candidate provenance before loading these modules
with `candidate_module`; update its explicit loading dependencies without
weakening that order or reopening its restricted import path. Preserve disabled
bytecode writes and update fixture file-copy lists that need new modules.

**Priority and validation:** worthwhile when next extending validation tooling;
lower urgency than the engine modules receiving active features. Use existing
workflow coverage for planning, execution/provenance, aggregation, reuse, and
CI-image identity, including temporary repository fixtures, and follow the
validation plan. This recommendation does not establish a current validation
loophole. Import/bootstrap behavior makes it more involved than a cosmetic move.

## Runtime logging organization

### TD-8. Asynchronous logger embeds pure record preparation in its concurrent adapter

**Verified at:** `da81087`; source inspection only.

`packages/runtime/src/Hetoimasia/Runtime/AsyncLog.hs` contains 970 lines.
There is a particularly clear small extraction here: its UTF-8 budgeting,
truncation markers, detached text copying, and forcing helpers implement
record preparation, whereas the adapter manages STM admission, flush barriers,
worker execution, and borrowed-sink lifetime.

**Evidence:** truncation definitions/formatting occupy 251–306;
`withAsyncLogAdapter` begins at 464; `admit` at 502 calls `boundEntry`, evaluates
`forceEntry`, then enqueues in STM. Text preparation occupies 784–970, including
`takeBytes` (790), `boundEntry` (824), and `forceEntry` (946). Those helpers need
log-entry data, not the adapter's TVar, worker, or sink.

**Proposed direction:** extract a private
`Hetoimasia.Runtime.AsyncLog.Entry` module containing the cohesive preparation
policy and its supporting constants/types, exposing only what the adapter
needs. Preserve public constants through re-exports. Keep it an `other-modules`
implementation in the existing runtime library; do not add a public library or
move an adapter-specific policy into foundation. No broader adapter split is
required to make this extraction useful.

**Constraints:** preserve byte rather than character budgeting, full code-point
prefixes, marker reservation, collection limits, attribution priority, and
detached copies of every retained text. Most critically, preparation must still
be forced on the producer before enqueueing; moving definitions must not defer
that work to the writer. Preserve all admission, flush, loss, and lifetime
semantics. A pure signature alone does not guarantee the forcing point.

**Priority and validation:** the smallest additional refactor, suitable as an
independent cleanup when convenient. Run the existing runtime
`Asynchronous logging adapter` examples, particularly bounded retention and
admission, plus required checks. Existing behavioral tests can stay on the
public API; do not expose implementation solely for tests. No throughput or
memory improvement is claimed for moving the code.

## End-of-pass handoff

There are eight verified structural findings, not an exhaustive declaration
that all other modules are healthy. Process each against current code and
tracker work before creating issues. The layout review above still applies to
TD-1 through TD-5; TD-6 through TD-8 stay within their existing Lua, tooling,
and runtime boundaries and introduce no dependency on the GPU/GLFW changes.

The comment corrections remain separately tracked by PR #241; recheck its
status rather than filing another blanket comment-cleanup issue. Clarify local
names during their owning extraction where needed. This pass did not establish
an additional standalone rename, dead-code deletion, or shared lifecycle
framework that would justify expanding the report. Similar-looking shutdown
and invalidation code needs semantic comparison before any deduplication.

Recommended stopping point: process this backlog before another broad sweep.
Prefer the smallest extraction relevant to upcoming work, and preserve the
existing behavioral tests and invariant comments in each implementation PR.
