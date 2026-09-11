# Project Review Findings: PRs #21–#15

Correctness audit of `coghex/hetoimasia` at
`82a607fcc284432b4cceafc705914a5ee592d3e8` on 2026-09-11, before the resource
ownership arc. Reviewed exactly PRs **#21, #20, #16, and #15**, newest first,
against issues #13, #12, #11, and #10, their trusted specification amendments,
their merged patches, and the combined implementation. There are no direct
first-parent commits between these four landings. Earlier logging work and
deferred `test`/`autotest` integration are outside this batch.

All four CI children are closed and merged. Epic #8 remains open. The core
selection and reuse policies are implemented, but approval inheritance needs
the correction below before relying on it for the resource PRs. These findings
do not call for a CI redesign or removal of the owner's clean-merge shortcut.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]` reviewed and deliberately never to be filed · `[deferred]` blocked on a concrete precondition

## Status

- [ ] PRR-1. Bind inherited approval to a proven approved revision across successive pushes
- [ ] PRR-2. Verify the executed candidate before certifying a plan
- [ ] PRR-3. Keep timing collection failures out of the required validation verdict
- [ ] PRR-4. Include workflow test dependencies in the source distribution

## 1. Approval provenance

### PRR-1. Bind inherited approval to a proven approved revision across successive pushes

> **Captured note:** P1. The review gate treats an event's `before` commit as
> approved merely because the PR still has its label. A delayed dismissal of
> an earlier code push breaks that assumption. PR #16 introduced the problem
> for identical-tree follow-ups; PR #21 also carries it through clean base merges.

**Verification:** Two Hspec regressions reproduced this with real temporary
Git histories and the shipped `review_replay.py` and `review_gate.py`. No sleeps,
GitHub mutations, or manually fabricated replay verdicts were needed.

The sequence is deterministic when the first event is processed after the
second push:

1. Head A is reviewed and the approval label is attached.
2. Push B, which adds unreviewed behavior. Before its dismissal runs, push C.
3. C is either Git's clean merge of B with `master`, or a new commit with
   exactly B's tree. B has never received review or a successful inheritance
   decision.
4. A→B's delayed dismissal sees current head C and exits 3 without removing
   the label. This is the intended protection against obsolete mutations.
5. B→C sees the still-attached label and returns `action=none`,
   `expected=kept`. Its review verdict succeeds. It never proves that B was
   entitled to the label it inherited from A.

Both new regressions expected invalidation and failed against current master.
The clean-merge case really runs `git merge-tree` through the production tool;
the identical-tree case works even when replay itself returns `strip`.

**Evidence:**

- `.github/workflows/review-gate.yml:73` — supplies event `before` as the
  starting point, with no durable approval provenance lookup.
- `tools/validation/review_gate.py:121` — a superseded dismissal exits without
  changing the label.
- `tools/validation/review_gate.py:126` — either tree equality or replay `keep`
  suffices to carry whichever label is currently attached.
- `.github/workflows/review-gate.yml:199` — `action=none` leaves that label
  attached; the successful job is the signal the drainer consumes.
- `tools/validation/review_gate.py:155` — the current event's successful
  dismissal and attached label satisfy the review verdict.
- Installed Kanban `tools/drain_prs.py:3031` at `a25862add2cc` — stale-head
  recovery trusts successful `dismiss-stale-approval` plus the retained label,
  then records the new approved head. The downstream consumer does not repair
  this missing proof.

**Handoff context:**

- **Current behavior:** A clean merge of an unreviewed intermediate head can
  inherit an older review. The same hole exists for an identical-tree follow-up.
- **Expected behavior:** Inheritance must begin at a revision with established
  approval, or a verified chain of eligible updates from that revision.
  Unproven intermediates must not acquire approval from a surviving PR label.
- **Scope and constraints:** Preserve valid repeated clean merges and the
  distinction between review and CI. Keep obsolete runs from stripping a real
  newer approval. Do not solve this by reattaching labels or assuming GitHub
  events finish in order. A separately owned Kanban prerequisite is necessary
  only if the chosen provenance contract requires one; do not edit installed
  Kanban scripts as part of this repository's fix.
- **Verification target:** Hspec cases for both sequences above, a delayed or
  failed earlier invalidation, an actually reviewed newer head, and multiple
  legitimate inherited base updates. Exercise the decision-to-mutation-to-gate
  composition, then verify the hosted drainer handshake on a controlled PR.
- **Deduplication:** All-state searches for approval/push and the open tracker
  found the original closed #11/#13 contracts, not a follow-up for this race.
- **Remaining uncertainty:** The race was reproduced locally and traced into
  the installed drainer. No evidence claims it has already caused a bad merge
  on GitHub; no live race was induced during this read-only audit.

## 2. Execution evidence

### PRR-2. Verify the executed candidate before certifying a plan

> **Captured note:** P2. `run.py` can execute a different checkout from the
> plan's candidate while copying the plan's identity into its receipt, and
> `aggregate.py` accepts that receipt. PR #16 introduced the unchecked execution
> provenance; PR #20 also stamps the planned input identity onto it.

**Verification:** An Hspec fixture registered one mandatory group whose command
reads `src/flag` and succeeds only when its contents are `good`. Candidate A
contains `bad`; planning and running A correctly fails. The fixture then commits
`good` as B and invokes the unchanged plan for A from B. Both the runner and
aggregate exit 0. No receipt edits or `--executed-*` overrides are involved.

The aggregate prints a passed verdict for A and even names B as the execution:

```text
validation verdict for plan ... at head c20da0fc0fe9
  test.flag  floor  passed  executed at ba40c3bdac9e in 0.0s
verdict: passed
```

The fixture used real planner output, a real process whose outcome depends on
the checkout, and `--worker worker=success:test.flag` for aggregation.

**Evidence:**

- `tools/validation/run.py:182` — reads the actual checkout's commit and tree,
  but does not compare either with `plan["candidate"]` before execution.
- `tools/validation/run.py:214` — records the plan's head and plan identity
  beside the actual execution; :225 copies the plan's input identity unchanged.
- `tools/validation/aggregate.py:222` — validates plan identity, head, command,
  and outcome, but accepts the fresh receipt without comparing its execution
  against the candidate or checking the compatibility fields used for reuse.
- `tools/test/Execution.hs:51` — the existing provenance test supplies arbitrary
  execution overrides and checks that they are recorded. It does not establish
  that the execution matches a planned integration candidate.
- `.github/workflows/validation.yml:230` and :380 — hosted workers independently
  pin their checkouts, limiting exposure in the normal hosted path. This is a
  confirmed defect in the shared local runner/aggregate contract, not evidence
  that the current hosted checkout guard was bypassed.

**Handoff context:**

- **Current behavior:** A stale plan can certify the wrong committed code.
  Dirty relevant inputs likewise need an explicit policy before receiving a
  committed candidate's identity.
- **Expected behavior:** Execution must establish that the inputs it runs are
  those the plan identifies. Fresh evidence with inconsistent executed
  candidate, platform, toolchain, policy, or input identity must not pass the
  aggregate. Never silently certify a planned revision using a different one.
- **Scope and constraints:** Keep PR head and integration candidate distinct;
  compare against the latter. Preserve legitimate docs-only reuse through its
  existing applicability proof. Keep local uncommitted feature testing possible
  only with honest identity/attribution; a diagnostic refusing an unsupported
  dirty-input case is sufficient for the initial fix. Do not pull deferred
  `test`/`autotest` integration into this task.
- **Verification target:** The failing-A/passing-B regression above; a legitimate
  `--candidate` different from PR head; mismatched fresh receipt compatibility;
  relevant dirty inputs and any retained execution override behavior. Use
  Hspec and real Git/process fixtures.
- **Deduplication:** All-state searches for receipt/candidate found the original
  closed #11/#12 issues but no repair issue covering this execution mismatch.
- **Remaining uncertainty:** No hosted wrong-checkout run was observed.
  The reproduced defect needs no API access and exists independently of
  future periodic testing.

## 3. Required-check availability

### PRR-3. Keep timing collection failures out of the required validation verdict

> **Captured note:** P2. PR #16 makes a failure of the timings API prevent the
> aggregate from running, even when all validation evidence is available.

**Verification:** An Hspec regression extracted the shipped `Record the run
timings` shell body and substituted a deterministic failing `gh` boundary. The
step exits 7 on that API failure. The following `Decide the verdict` step has
the default success condition, so Actions skips it and `build-test` fails.
`if: always()` on the job does not make its later steps run after this failure.

**Evidence:**

- `.github/workflows/validation.yml:536` — the timings step uses `set -e`, a
  required `gh api` call, and no fallback or `continue-on-error`.
- `.github/workflows/validation.yml:546` — aggregation follows that step under
  the default step condition.
- `tools/validation/timings.py:9` — the tool's stated contract calls unavailable
  timings a reporting gap rather than a validation result.

**Handoff context:**

- **Current behavior:** A reporting-only GitHub API outage can suppress the
  actual verdict and force unnecessary retries of otherwise satisfied work.
- **Expected behavior:** Report unavailable timings visibly and still determine
  `build-test` from the required evidence and freshness checks.
- **Scope and constraints:** Keep failure of plan loading, current-state reads,
  selected workers, or validation evidence blocking. Making ancillary metrics
  tolerant must not make those real gates tolerant.
- **Verification target:** Hspec execution of the shipped timing step for API
  failure and malformed/missing timing data, with aggregate execution still
  reached. Successful evidence must pass and a failing receipt must still fail
  when metrics are unavailable.
- **Deduplication:** All-state timing searches found the original #11/#12
  descriptions, not an existing issue for this failure path.
- **Remaining uncertainty:** API failure was injected locally; no hosted outage
  was triggered. The downstream skip follows the shipped workflow's conditions.

## 4. Source distribution completeness

### PRR-4. Include workflow test dependencies in the source distribution

> **Captured note:** P2. `hetoimasia.cabal` omits runtime files required by the
> workflow test suite: `tools/validation/reuse.py` added in PR #20, and
> `.github/workflows/review-gate.yml` consumed since PR #16.

**Verification:** `cabal sdist all --list-only` succeeds but lists neither file.
An Hspec assertion against that real source-distribution inventory fails for
both paths. Ordinary `cabal check` passes, so it does not detect the omissions.
The shipped tests call the absent Python script and read the absent workflow;
the source distribution therefore cannot run those tests as delivered.

**Evidence:**

- `hetoimasia.cabal:24` — the explicit `extra-source-files` list omits both
  files while including the other validation scripts.
- `tools/test/Reuse.hs:450` — executes `tools/validation/reuse.py`.
- `tools/test/DismissalStep.hs:224` — reads
  `.github/workflows/review-gate.yml` to extract the real step under test.

**Handoff context:**

- **Current behavior:** Git checkouts contain everything, masking an incomplete
  Cabal source distribution.
- **Expected behavior:** Distribute every file that the declared test suite
  executes or consumes. Do not solve this by skipping those tests outside Git.
- **Scope and constraints:** Package metadata and a focused completeness check;
  no release service or Hackage publication is required.
- **Verification target:** Inspect the generated archive or file inventory and
  run the affected workflow examples from an unpacked distribution. If testing
  the multi-package project, supply its project configuration explicitly rather
  than assuming `cabal.project` is part of a package archive.
- **Deduplication:** The all-state `sdist` search found no existing issue. The
  original CI issues require packaging their new scripts but are already closed.
- **Remaining uncertainty:** Missing members and their consumers are verified.
  A complete unpacked multi-package build was not run in this audit.

## Verification and review disposition

At the audited commit, `cabal build all`, the 137-example `workflow-tests`
suite, the 56-example `hetoimasia-tests` suite, console smoke, and root
`cabal check` pass. `actionlint -shellcheck=` passes. Full actionlint reports
one nonfunctional ShellCheck SC2016 warning for the intentionally literal
backticks in the provenance format string; it is not a finding here.

Five additional Hspec examples expose the four findings: two approval sequences,
one wrong-candidate execution, one timing API failure, and one source inventory
check. These are expected failing regression demonstrations, separate from the
193 passing repository examples. The temporary harness and captured outputs
are at:

```text
/var/folders/xs/kyf0vrg92c340wk3jncyp1fr0000gn/T/hetoimasia-ci-audit.v5oxiefj/
  RegressionSpec.hs
  regressions.log
  timing-regression.log
  workflow-tests.log
  engine-tests.log
  sdist-files.txt
```

The failure descriptions above retain the reproduction logic even if these
temporary files expire. The immutable audit checkout is
`.worktrees/review-ci-82a607f`; run the harness there with
`cabal exec -- runghc <path-to-RegressionSpec.hs>`.

The live ruleset `22930055` is active on `master`, requires `build-test` and
`review-approved`, enables strict branch freshness, and permits the explicitly
approved Admin-role `always` bypass for direct docs landings. These settings
match the owner's decision. The installed Kanban consumer was inspected at
`a25862add2cca8752c1fa1f9d1e724bba0bf8ddd` without modifying it or controlling
its service.

The latest [master validation run](https://github.com/coghex/hetoimasia/actions/runs/34643564852)
passed: both Haskell workers were skipped through evidence reuse, the planner
took 12 seconds, and the aggregate took 10 seconds. The preceding
[PR validation run](https://github.com/coghex/hetoimasia/actions/runs/34642040565)
executed both workers in parallel and passed. This supports the intended fast
path; it does not cover the exceptional sequences in this report.

Earlier review-round problems with policy self-exemption, expired-artifact
ordering, attempt attribution, malformed applicability, failed workers, timeout
descendants, label-read failures, and inherited test environments were repaired
before merge and are not new findings. The current policy correctly keeps
optional groups out of automatic selection. Per-group fingerprints and periodic
skill integration remain intentionally deferred.

No exact duplicate follow-up findings were found. Keep the epic open for the
approval correction; the other repairs can be bounded follow-ups. No issues,
labels, PRs, rulesets, services, or production code were changed by this audit.
