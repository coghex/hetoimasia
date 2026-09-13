# Project Review Findings: PRs #46–#43

Correctness audit of `coghex/hetoimasia` at
`2e06ade35c559555409740327ffeec63e04b9d06` on 2026-09-12. Reviewed exactly
PRs **#46, #45, #44, and #43**, newest first, against issues **#42, #41, #40,
and #39**, their canonical specification amendments, PR reviews, individual
commits, merged patches, and current consumers. The first-parent interval from
`0a5fcb3` through this revision contains those four PR merges and no direct
commits. Earlier CI and logging implementations, GPU ownership, and the planned
test-suite reorganization are outside this batch.

The four original reproductions have concrete repairs: composite metadata is
evaluated before acquisition; `Scoped` no longer exports a writable field;
inspection no longer repeatedly expands an unchanged failure's carried context;
and reporting cancellation is rethrown with its own context. One additional
public-representation problem undermines the new inspection invariant below.
It needs a bounded correction, not a redesign of the ownership policy.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]` reviewed and deliberately never to be filed · `[deferred]` blocked on a concrete precondition

## Status

- [x] PRR-1. Protect cleanup-failure identity and payload from public record updates — [#47]

Processing is complete. Issue [#47](https://github.com/coghex/hetoimasia/issues/47)
was closed by merged [PR #48](https://github.com/coghex/hetoimasia/pull/48) on
2026-09-12. The evidence below records the defect at the audited revision,
before that repair; it is not a new outstanding finding.

## 1. Cleanup evidence representation

### [#47] PRR-1. Protect cleanup-failure identity and payload from public record updates

> **Captured note:** P2. PR #45 treats a `CleanupFailureId` as proof that the
> entry's carried context has already been inspected, but public record updates
> can change that context while retaining the same identity. Reachable, distinct
> cleanup evidence is then silently omitted. The representation also permits
> replacing another entry's identity and label. The constructor is hidden, but
> the three exported record selectors leave these operations available.

**Verification:** An independent Hspec client, compiled against the built public
foundation package on GHC 9.12.2, obtains two real cleanup failures from two
`withResourceLabelled` scopes. It adds the second failure to the first entry's
carried context using ordinary record update, then places the original first
entry and its augmented copy in one exception context. No unsafe operation,
internal import, forged constructor, or fabricated identifier is used.

```haskell
-- first and second were returned by cleanupFailures after actual failed releases.
let ExceptionWithContext ctx ex = cleanupFailureException first
    augmented = first
      { cleanupFailureException =
          ExceptionWithContext (addExceptionAnnotation second ctx) ex
      }
    combined = addExceptionAnnotation first
      (addExceptionAnnotation augmented emptyExceptionContext)
map cleanupFailureLabel (cleanupFailuresInContext combined)
  `shouldBe` ["first", "second"]
```

The client compiles on both revisions. With the pre-optimization implementation
at `4949e8c`, the example passes and returns `["first", "second"]`. With the
current implementation at `2e06ade`, it fails and returns only `["first"]`.
The earlier revision's inspector is the same gather/sort/deduplicate algorithm
replaced by PR #45; the intervening metadata and `Scoped` fixes do not change
that algorithm. A separate compiled client also confirms that
`second { cleanupFailureId = cleanupFailureId first }` is allowed and causes
two distinct releases to collapse to one reported entry. That identity-forging
capability predates this batch; skipping a changed carried context is the
additional behavior introduced by PR #45.

The preferred correction is to make these evidence entries read-only through
the public API, maintaining the invariant the optimization needs. The fixture
above then belongs among external-client compile-rejection tests, rather than
requiring the inspector to support mutable payloads behind a reused identity.
Keep supported inspection and reattachment of an unchanged entry working.

**Evidence:**

- `packages/foundation/src/Hetoimasia/Foundation/Resource.hs:90` — the abstract
  `CleanupFailure` type is exported beside its three selectors.
- `packages/foundation/src/Hetoimasia/Foundation/Resource.hs:127` — the identity
  contract says an identifier distinguishes one observed failure from another.
- `packages/foundation/src/Hetoimasia/Foundation/Resource.hs:143` — identity,
  label, and carried exception are record fields whose labels are exported;
  hiding the constructor does not prevent external record updates.
- `packages/foundation/src/Hetoimasia/Foundation/Resource.hs:279` — inspection
  uses the map both for returned entries and the record of visited identities.
- `packages/foundation/src/Hetoimasia/Foundation/Resource.hs:314` — a repeated
  identity bypasses both insertion and expansion of its carried context, even
  when a public client has replaced that context.
- `docs/resources.md:405` — the public inspection contract presents an abstract
  evidence type with readers, followed by the no-loss and distinct-failure
  guarantees; it defines no supported evidence-rewriting operation.
- `test/Test/Engine/Resources/Spec.hs:784` — the new mixed-route example correctly
  covers unchanged repeated entries beside new evidence, but never changes an
  entry's carried context through an exported field.
- `test/Test/Engine/Resources/Opacity.hs:46` — the new external-client tests
  protect `Scoped`; no analogous check protects `CleanupFailure`.

**Handoff context:**

- **Current behavior:** Public field labels allow callers to rewrite an entry's
  identity, label, or carried exception. In particular, two payloads can share
  an identity, so the optimized inspector can skip otherwise reachable evidence.
- **Expected behavior:** Each issued identity identifies one unchanged retained
  failure. Public readers must not also grant record-update access that breaks
  identity, ordering, or complete inspection. An unchanged failure may still be
  inspected and attached through ordinary exception-annotation APIs.
- **Scope and constraints:** Close the public representation while preserving
  the readers' names and types, typed exception evidence, identity ordering,
  duplicate suppression, and PR #45's bounded inspection. Follow the same
  representation lesson as #40; private fields or a positional constructor
  with ordinary reader functions are bounded options. Include the contract and
  tests in the code PR. Do not restore exponential traversal or introduce an
  application-wide evidence registry. Issue #41's instruction to preserve the
  representation overlooked this existing public-update capability; a follow-up
  must explicitly permit correcting it.
- **Verification target:** Hspec-driven external clients must fail specifically
  when attempting to replace each of the three fields, while supported readers
  and unchanged-entry reattachment compile and run. Keep the existing distinct
  equal-message, mixed-route, nested-release, cancellation, and allocation-budget
  examples. A broken compiler/package environment must not pass a rejection test.
- **Deduplication:** The full tracker inventory and all-state searches for
  `CleanupFailure record` and `identity context` found closed #39–#42 and the
  original resource contracts, with no separate corrective issue. #40 covers
  only `Scoped`, and #41 explicitly excludes representation changes.
- **Remaining uncertainty:** Current production consumers do not record-update
  cleanup entries, so the observed loss requires a client to use this exposed
  operation. This is a public API invariant defect, not a claim that ordinary
  unchanged resource unwinding currently loses evidence.

## Batch verification

At the immutable `2e06ade` checkout:

- `cabal build all`: passed with the repository's warnings-as-errors policy.
- `cabal test hetoimasia-tests --test-show-details=direct`: 140 examples passed,
  including all new metadata, external-client, allocation, and cancellation tests.
- `cabal test workflow-tests --test-show-details=direct`: 262 examples passed.
- Console `--smoke` and `--resource-smoke`: passed with the expected ordinary
  lifecycle output and release ordering.
- The documented planner command selects all four existing groups for
  `0a5fcb3..2e06ade`; all four commands above passed.
- An independent inspection measurement using the original audit fixture
  allocated 43,784 bytes at depth 20 and 108,720 bytes at depth 40, returning
  20 and 40 failures respectively. The earlier depth-20 measurement was about
  3.02 billion bytes. These are cumulative temporary allocations, not peak
  resident memory. The optimization fixes the original exponential case.
- The additional public-client Hspec regression above fails at the candidate
  and passes at the pre-optimization baseline.
- GitHub's validation run
  [34717117391](https://github.com/coghex/hetoimasia/actions/runs/34717117391)
  passed for the exact merged revision.

Audit artifacts, source fixtures, and command logs are retained locally under
`/var/folders/xs/kyf0vrg92c340wk3jncyp1fr0000gn/T/hetoimasia-resource-fix-review.qgs0iwef/`.
The isolated checkout is `.worktrees/review-resource-fixes-2e06ade`.
`EvidenceRewriteSpec.hs`, `evidence-rewrite-before.log`, and
`evidence-rewrite-after.log` contain the independent regression and its results.
`EvidenceRewrite.hs` additionally demonstrates identity replacement.
The snippet and trace above preserve the reproduction's substance even after
temporary artifacts are removed. No production files or tracker artifacts were
changed by this audit.
