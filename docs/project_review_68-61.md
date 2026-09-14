# Project Review Findings: PRs #68–#61

Correctness and architecture audit of `coghex/hetoimasia` at
`766c0431d9b5ad1264a335351d64a80d83cf2590` on 2026-09-13. Reviewed exactly
PRs **#68, #67, #66, #65, #64, #63, #62, and #61**, newest first, against
issues **#60, #59, #58, #57, #56, #55, #54, and #53**, their canonical
specification amendments, PR reviews, commits, merged changes, current consumers,
and runtime epic #52. The first-parent interval after `b15208a` contains these
eight PR merges and no direct commits. All eight children are closed; epic #52
remains open. Graphics, messaging transport, and independent GLFW implementation
remain deliberately outside this arc and audit.

**Follow-up completion, 2026-09-13:** Both findings below were filed as #69 and
#70, fixed by PRs #71 and #72, and verified at `8979877`. The original two
evidence-loss reproductions pass; the public handle now rejects the record
update at compilation. Local build, 298 engine and 262 workflow Hspec examples,
and both smoke modes passed; current-master CI is green. The owner subsequently
requested housekeeping, and epic #52 is now closed with its checklist complete.
The original audit and finding evidence below describe `766c043` and remain
historical; there is no outstanding repair from this report.

The implementation preserves the accepted boundaries: foundation owns failure
evidence, bounded recovery, scoped construction, and raw worker lifetimes;
runtime owns reporting, logging finalization, and supervision; the generic
application runner composes application-owned dependencies and immutable
services on the caller's thread. No universal environment, service locator,
application-wide monad, or premature graphics implementation was added.

Two current supervision defects remain. They need bounded repairs before new
subsystems depend on these handles and failure-inspection conventions, rather
than a redesign of the runtime. Existing tests pass; three additional public-API
Hspec examples reproduce the defects below.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]` reviewed and deliberately never to be filed · `[deferred]` blocked on a concrete precondition

## Status

- [x] PRR-1. Preserve supervised failure evidence across distinct invocations — [#69]
- [x] PRR-2. Prevent public record updates from separating a supervised worker from its state — [#70]

## 1. Supervision failure evidence

### [#69] PRR-1. Preserve supervised failure evidence across distinct invocations

> **Captured note:** P2. PR #67 identifies an already-delivered primary by a
> group-local `WorkerId`, then replaces the public view of retained failures
> with the newest invocation's list. A failure passing through another
> supervision boundary can lose both that outer boundary's worker evidence
> and previously retained inner secondary failures from public inspection.

**Verification:** Two coordinated Hspec examples run real workers through the
public runtime and foundation packages at the audited revision. Both use nested
`withSupervision` calls on the application thread and the same live injected
logging lifetime. No unsafe operation, private import, annotation fabrication,
record update, or sleep is involved. Gates control failures; raw
`awaitCompletion` observes every relevant terminal outcome before the inner
checkpoint runs. Every worker and scope has finished before assertions run.

1. Start one required job in each group. Both receive local `WorkerId 0`.
   Complete both with different typed failures, then call `checkRuntime` for
   the inner group. The inner failure correctly stays primary. However,
   `supervisedFailuresInContext` returns `[]`, instead of retaining the outer
   worker's failure. The outer boundary mistakes the inner `Delivered 0` marker
   for delivery of its own worker 0 and filters the outer entry out.
2. First complete and handle a successful outer job, so the outer failing job
   gets local ID 1. In the inner group, fail two required jobs together with
   IDs 0 and 1. After the inner primary propagates through the outer boundary,
   public inspection returns only `["outer"]`, instead of
   `["inner-secondary", "outer"]`. The outer entry is no longer filtered, but
   its newer `FailuresEntry` hides the previously attached inner list.

Actual independent results:

```text
same local ID: expected ["outer"], got []
outer adds evidence: expected ["inner-secondary", "outer"], got ["outer"]
```

The primary exception retains its original type and value in both cases, and
raw group reports remain available. This is a defect in the promised public
supervised-failure inspection and identity handling, not a claim that all raw
evidence bytes disappear or that either example releases a live worker.

**Evidence:**

- `packages/foundation/src/Hetoimasia/Foundation/Worker.hs:432` — a new group
  initializes its registration counter to zero; worker identity is explicitly
  local to its group.
- `packages/runtime/src/Hetoimasia/Runtime/Supervision.hs:433` — exceptional
  boundary exit settles its group, reads `deliveredWorker` from the incoming
  context, and excludes every local failure with that ID without checking the
  identity of the supervision invocation that attached the marker.
- `packages/runtime/src/Hetoimasia/Runtime/Supervision.hs:735` — delivery records
  only `Delivered (failedWorker primary)`.
- `packages/runtime/src/Hetoimasia/Runtime/Supervision.hs:741` — the private
  `Delivered` annotation contains no group or supervision identity.
- `packages/runtime/src/Hetoimasia/Runtime/Supervision.hs:758` — `withFailures`
  attaches only the supplied list, without combining evidence already carried
  from another invocation.
- `packages/runtime/src/Hetoimasia/Runtime/Supervision.hs:771` — public inspection
  selects the newest list, making older distinct lists inaccessible through
  this inspector.
- `docs/supervision.md:212` — fatal and secondary evidence is part of the
  public supervision contract. Issue #59 requirements 6 and 7 require retained
  structured worker evidence and preservation of the application's existing
  primary failure.

**Handoff context:**

- **Current behavior:** Group-local IDs are compared across exception boundaries,
  and a newer boundary's evidence replaces the public view of existing entries.
- **Expected behavior:** A delivered-primary marker identifies the invocation
  and worker it belongs to. An outer boundary preserves an existing primary
  and all distinct secondary failures already attached, and adds its own
  failures without dropping another group's entries or duplicating repeated
  deliveries from the same invocation. Public inspection keeps each retained
  exception's type, value, context, and worker provenance.
- **Scope and constraints:** Repair the supervision evidence protocol from
  #59 / PR #67. Keep registration order stable within each group, the original
  typed primary, optional/fatal dispositions, fatal latch behavior, and raw
  worker ownership unchanged. No service registry, global application state,
  restart policy, or scheduling feature is needed. Include the evidence
  contract and tests in the same code PR. Nesting here composes existing
  callback lifetimes; it does not ask workers to start nested work schedulers.
- **Verification target:** Both coordinated cases above pass. Add coverage for
  propagation through a later independent invocation and for repeated
  checkpoint deliveries, preserving all distinct entries without multiplying
  evidence. Retain current simultaneous-failure ordering, original typed catch,
  owner-failure precedence, cleanup, and cancellation examples.
- **Deduplication:** The complete all-state issue snapshot and a GitHub
  `supervision failure evidence` search found the original closed runtime
  children and open epic, but no repair issue. Existing findings reports contain
  no supervision finding. This differs from #41's cleanup-evidence traversal
  and #47's cleanup-evidence representation repair.
- **Remaining uncertainty:** No production subsystem uses nested supervision
  yet. The examples establish the public composition defect before such a
  consumer is introduced; they make no claim of a current gameplay failure.

## 2. Supervised handle encapsulation

### [#70] PRR-2. Prevent public record updates from separating a supervised worker from its state

> **Captured note:** P2. PR #67 hides `SupervisedWorker`'s constructor but
> exports `supervisedWorker` as a record selector. Ordinary client record update
> can replace the raw worker while retaining another worker's private managed
> state, so cancellation and status inspection refer to different workers.

**Verification:** A public-package Hspec client starts two required services
under one `RuntimeControl`, with both services waiting cooperatively on their
own stop tokens. This compiles without any private import or unsafe operation:

```haskell
let rewritten = first { supervisedWorker = supervisedWorker second }
cancelSupervised rewritten
void (awaitTerminal (supervisedWorker rewritten))
checkRuntime control
actual <- atomically (workerStatus second)
claimed <- atomically (workerStatus rewritten)
```

The second worker is cancelled and its committed status is `WorkerStopped`.
The rewritten handle still returns `WorkerLive`, the first worker's state,
despite exposing the second worker's terminal outcome. The first worker's
owner-request bookkeeping was also modified by the call that cancelled the
second worker. The group then closes and drains the first service normally;
no worker is left running by the example.

The independent assertion expected matching `("stopped", "stopped")` status
views and observed `("stopped", "live")`. This is the same Haskell abstraction
pitfall already repaired for `Scoped` (#40) and `CleanupFailure` (#47).

**Evidence:**

- `packages/runtime/src/Hetoimasia/Runtime/Supervision.hs:157` — the public export
  list exposes `supervisedWorker` alongside the abstract handle type.
- `packages/runtime/src/Hetoimasia/Runtime/Supervision.hs:395` — that name is a
  field label on the same record as private `supervisedManaged`; hiding the
  constructor does not hide record update through an exported field label.
- `packages/runtime/src/Hetoimasia/Runtime/Supervision.hs:545` — stop records
  intent through private managed state but requests stop through the raw handle.
- `packages/runtime/src/Hetoimasia/Runtime/Supervision.hs:552` — cancellation
  uses those same two independently replaceable routes.
- `packages/runtime/src/Hetoimasia/Runtime/Supervision.hs:565` — status reads
  only the private managed state, so it need not describe the exposed worker.
- `packages/foundation/src/Hetoimasia/Foundation/Resource/Internal.hs:105` — the
  existing cleanup-evidence contract documents why ordinary reader functions
  are needed when public record updates would break a hidden invariant.

**Handoff context:**

- **Current behavior:** A public client can construct a mismatched supervised
  handle with ordinary record-update syntax, despite the hidden constructor.
- **Expected behavior:** A handle's raw worker, stop/cancel bookkeeping, policy,
  committed status, and supervision identity remain inseparable. Public raw
  observation stays available through the existing reader name and type, but
  cannot rewrite that association.
- **Scope and constraints:** Close the representation in #59 / PR #67 without
  changing supported observation, stop/cancel semantics, or the worker-group
  ownership contract. Reuse the established opacity-testing approach. This
  does not require removing raw completion observation or introducing runtime
  validity checks for a mismatch that the public API should not construct.
  Documentation and test evidence belong in the repair's code PR.
- **Verification target:** An Hspec-driven external client using only public
  exports must fail specifically at the record update. A positive client must
  still compile and use `supervisedWorker`, completion observation, status, and
  stop/cancel together. A broken package/compiler environment must not count as
  a successful opacity rejection. Preserve the existing supervision suite.
- **Deduplication:** The complete all-state tracker snapshot and the
  `supervisedWorker record` search contain no matching repair issue. Closed #40
  and #47 cover different types and predate this newly introduced handle.
- **Remaining uncertainty:** Existing consumers do not perform this record
  update. The verified defect is an exposed API invariant, not a claim that
  well-formed handles currently target the wrong worker spontaneously.

## Batch verification and handoff

At the immutable `766c043` checkout, locally on macOS:

- `cabal build all`: passed under the repository's warnings-as-errors policy.
- `cabal test hetoimasia-tests workflow-tests --test-show-details=direct`:
  291 engine examples and 262 workflow examples passed.
- Both `cabal run exe:hetoimasia -- --smoke` and `-- --resource-smoke` passed,
  with the expected lifecycle records. The original `Runtime.hs` thin runner
  is byte-identical to the pre-runtime-arc baseline.
- The validation planner for `b15208a..766c043` selects all four existing
  groups: `build.all`, `test.engine`, `smoke.console`, and `test.workflow`.
  Every implementation path is covered; no unknown changed input was found.
- [Linux validation run 34782130345](https://github.com/coghex/hetoimasia/actions/runs/34782130345)
  passed for the exact merged revision.
- Three additional Hspec examples fail as recorded above: two reproduce PRR-1
  and one reproduces PRR-2. Their synchronization is explicit and all workers
  finish; no failure is inferred from a timeout.

Earlier PR-review blockers concerning cancellation origins, escaped failure
text, truthful terminal recovery fields, fatal-latch stop initiation,
post-publication owner requests, and the RT-6 memory status were repaired before
their PRs merged. They are not new findings here.

The runtime design's introductory status still describes outstanding
implementation even though its eight children have merged. Refresh that prose
when recording the arc's final verdict; it does not need a separate bug issue.
Keep epic #52 open until the repairs and the arc-level verification are settled.
Messaging and independent GLFW design remain the next infrastructure work,
before Vulkan; no new architecture decision is needed to begin those designs.

Review checkout: `.worktrees/review-runtime-766c043`.
Temporary source, raw tracker snapshots, PR diffs, and verification logs:
`/var/folders/xs/kyf0vrg92c340wk3jncyp1fr0000gn/T/hetoimasia-runtime-review.hvhius3t/`.
The independent examples are in `NestedSupervisionSpec.hs`; from the review
checkout, reproduce with:

```sh
cabal exec -- runghc -XGHC2024 -XUnicodeSyntax -XOverloadedStrings -itest /var/folders/xs/kyf0vrg92c340wk3jncyp1fr0000gn/T/hetoimasia-runtime-review.hvhius3t/NestedSupervisionSpec.hs
```

`build.log`, `tests.log`, `smoke.log`, `resource-smoke.log`, and
`nested-supervision.log` retain the outputs. The traces and reproduction steps
above preserve the substance if those temporary files are later removed.
No production code or tracker artifact was changed by this audit.
