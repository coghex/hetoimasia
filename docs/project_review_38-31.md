# Project Review Findings: PRs #38–#31

Correctness audit of `coghex/hetoimasia` at
`4949e8c62c7bb9f7e232ac182b77c537dd632a6a` on 2026-09-12. Reviewed exactly
PRs **#38, #37, #36, #35, #34, #33, #32, and #31**, newest first, against their
linked issues **#30, #29, #28, #25, #27, #26, #24, and #23**, trusted review
amendments, merged changes, and current callers and contracts. There are no
direct first-parent commits in this landing interval. Earlier logging work,
GPU completion/retirement, the test-suite reorganization, and deferred
`test`/`autotest` integration are outside this batch.

The component direction and the small ownership APIs match the accepted design.
The four previous CI findings have concrete repairs in PRs #31–#34, and no new
CI defect was confirmed in the exercised paths. The resource work has four
current findings below. Fix these before treating the CPU ownership foundation
as finished; none calls for a universal environment, a different failure policy,
or a GPU retirement implementation.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]` reviewed and deliberately never to be filed · `[deferred]` blocked on a concrete precondition

## Status

- [x] PRR-1. Prevent deferred cleanup metadata from bypassing composite release — [#39]
- [x] PRR-2. Make Scoped opaque to public record updates — [#40]
- [x] PRR-3. Avoid exponential traversal of retained cleanup evidence — [#41]
- [x] PRR-4. Preserve cancellation context through the runtime reporting boundary — [#42]

## 1. Composite cleanup

### [#39] PRR-1. Prevent deferred cleanup metadata from bypassing composite release

> **Captured note:** P1. PR #36 stores unevaluated part metadata and later
> forces it outside the release exception handlers. A throwing rank or label
> can abandon every acquired part without attempting a release.

**Verification:** Three additional Hspec regressions use the public
`withComposite`/`acquirePart` API. With two successful acquisitions and
`releaseRank (error "rank lookup failed")` on the second part, the body returns,
then cleanup throws and the release trail is empty: acquired `[2,1]`, released
`[]`. Replacing the rank fault with a deferred label fault has the same result.
A third example acquires two real temporary file handles; both still satisfy
`hIsOpen` after the composite has failed. An independent outer audit finalizer
closes them after inspection.

The trigger is an exception in evaluating metadata, such as a deferred partial
lookup, rather than an acquisition or release callback that failed. Constant
labels and ranks in the current console demonstration do not trigger it.

**Evidence:**

- `packages/foundation/src/Hetoimasia/Foundation/Resource.hs:307` — `Part`
  has strict rank and label fields, but its containing list is not strict in
  its elements.
- `packages/foundation/src/Hetoimasia/Foundation/Resource.hs:374` —
  `acquirePart` acquires first, then prepends a `Part` thunk through
  `atomicModifyIORef'`. Forcing the list's outer constructor does not force
  the part's metadata.
- `packages/foundation/src/Hetoimasia/Foundation/Resource.hs:448` —
  `releaseAcquired` empties the authoritative slot before evaluating the
  declared order.
- `packages/foundation/src/Hetoimasia/Foundation/Resource.hs:461` —
  `sortOn partRank` forces the part and its metadata; this can throw before
  `attemptRelease` is reached for any part.
- `packages/foundation/src/Hetoimasia/Foundation/Resource.hs:428` and
  `:432` — both rollback and normal exit call this orchestration outside
  `tryScope`; a bookkeeping failure can also displace the failure already
  being unwound.
- `test/Test/Engine/Resources/Spec.hs:166` — existing composite examples
  inject acquisition, binding, cancellation, and release failures, but use
  total metadata.

**Handoff context:**

- **Current behavior:** A delayed metadata exception skips registered cleanup
  altogether, including cleanup for earlier parts with valid metadata.
- **Expected behavior:** Metadata evaluation must not become an unprotected
  failure after acquisition or during release ordering. A rejected stage must
  leave all earlier acquisitions protected; every successful acquisition still
  needs its one release attempt.
- **Scope and constraints:** Preserve the declared ordering, masking discipline,
  and primary/secondary failure policy. Evaluating metadata before the stage's
  acquisition is one bounded approach. Merely forcing the new `Part` after
  acquisition creates a different unprotected gap. Do not use a catch that
  discards the problem after the slot has already been emptied.
- **Verification target:** Hspec cases for deferred rank and label exceptions
  at a later stage, real owned handles, normal exit and rollback, and retention
  of the appropriate primary failure. Assert acquired/released ownership, not
  only that an exception was thrown. Keep existing cancellation tests.
- **Deduplication:** The complete tracker snapshot and cleanup searches found
  the original closed #28/#25 contracts and open epic #22, with no separate
  correction for deferred metadata.
- **Remaining uncertainty:** No Vulkan resources exist here yet. The leak is
  established for public-API release callbacks and actual file handles.

## 2. Continuation encapsulation

### [#40] PRR-2. Make Scoped opaque to public record updates

> **Captured note:** P2. PR #37 hides the `Scoped` constructor but exports
> `withScoped` as a record selector. Client code can use record-update syntax
> to replace the continuation and manufacture the resumption behavior the
> public contract forbids.

**Verification:** This separate client module imports only public exports and
compiles successfully on GHC 9.12.2:

```haskell
import Hetoimasia.Foundation.Resource (Scoped, withScoped)

rewritten :: Scoped ()
rewritten =
  (pure () :: Scoped ()) { withScoped = \k -> k () >> k () }
```

An additional Hspec example runs `withScoped rewritten` with a counting
callback and observes **two calls from one run**. The counterexample needs no
constructor import, unsafe operation, internal module, or extra language escape
hatch. Inspecting the export list alone therefore did not prove opacity.

**Evidence:**

- `packages/foundation/src/Hetoimasia/Foundation/Resource.hs:77` — the public
  facade exports `Scoped` and `withScoped`.
- `packages/foundation/src/Hetoimasia/Foundation/Resource.hs:483` — the
  contract says callers cannot resume or take apart a scope's continuation.
- `packages/foundation/src/Hetoimasia/Foundation/Resource.hs:488` —
  `withScoped` is the field of the newtype, exposing the update operation.
- `docs/resource_ownership_design.md` D-3/D-8 and issue #29 require the
  constructor and arbitrary continuation resumption to stay hidden. The
  proposed record-field representation itself shares this defect; satisfying
  that syntactic sketch is not sufficient to satisfy the intended abstraction.

**Handoff context:**

- **Current behavior:** A client can replace a scope's runner and bypass the
  construction rules, including resuming the supplied callback more than once.
- **Expected behavior:** Ordinary external Haskell code using only public
  exports cannot construct or overwrite the continuation representation.
  `withScoped` retains its existing public runner signature.
- **Scope and constraints:** Keep lawful composition, `allocResource`,
  `allocComposite`, and `locally`. A public runner function over a private
  representation can preserve the API. Do not add runtime callback counting
  as a substitute for closing the representation leak. This is separate from
  the accepted inability to prevent borrowed handles escaping through `IO`.
- **Verification target:** An external-client compilation regression must
  reject record updates while a normal client using the runner and allocators
  still compiles. Retain the existing lifetime and failure tests; a textual
  search for an exported constructor cannot establish this property.
- **Deduplication:** All-state searches for record updates and `Scoped` found
  no follow-up beyond the original closed #29 and open umbrella #22.
- **Remaining uncertainty:** None about the public update capability; both
  compilation and doubled callback execution were reproduced.

## 3. Cleanup evidence inspection

### [#41] PRR-3. Avoid exponential traversal of retained cleanup evidence

> **Captured note:** P2. PR #35 removes duplicate cleanup failures only after
> recursively expanding all paths to them. Nested releases that themselves
> use resource scopes produce shared evidence that is revisited exponentially.

**Verification:** A small Haskell fixture recursively puts the next scope
inside a release. The leaf release throws:

```haskell
nested 0 = throwIO (userError "leaf release failed")
nested n =
  withResourceLabelled (pack ("release-" <> show n)) (pure ())
    (const (nested (n - 1))) (const (pure ()))
```

After catching with `try @SomeException`, the audit measures only evaluation of
`length (cleanupFailures failure)`, using `GHC.Stats` with GC boundaries and
`+RTS -T`. The public inspector returns the correct distinct count, but
temporary allocation grows as follows:

| Nested releases / distinct failures | Bytes allocated by inspection |
|---|---:|
| 10 | 1,649,104 |
| 15 | 72,817,568 |
| 18 | 687,237,264 |
| 20 | 3,017,230,976 |

A separate Hspec regression gives 20 failures a generous **128 MiB allocation
budget**; it fails at 3,017,227,936 bytes. These are cumulative temporary
allocations, not a claim of 3 GB resident memory. The scale fixture was compiled
with `-O1` against the built foundation library.

**Evidence:**

- `packages/foundation/src/Hetoimasia/Foundation/Resource.hs:266` —
  inspection gathers everything, sorts it, and only then drops repeats.
- `packages/foundation/src/Hetoimasia/Foundation/Resource.hs:271` —
  `gatherFailures` recursively follows both `WhileHandling` annotations and
  the exception context inside every direct cleanup failure, without tracking
  which failure contexts were already visited.
- `packages/foundation/src/Hetoimasia/Foundation/Resource.hs:285` —
  deduplication cannot recover the time/allocation already spent expanding the
  same subgraphs.
- `test/Test/Engine/Resources/Spec.hs:496` and `:724` — the existing small
  nested-release and duplicate-route examples verify result contents, but not
  the cost of exploring shared evidence.
- `packages/runtime/src/Hetoimasia/Runtime/Resources.hs:382` — reporting
  evaluates the inspector to count and name cleanup failures.

**Handoff context:**

- **Current behavior:** A small structured failure can require billions of
  allocation bytes simply to inspect. Greater nesting can make diagnostics
  stall or exhaust memory precisely during error recovery.
- **Expected behavior:** Inspection avoids repeatedly expanding already-seen
  failure evidence while preserving order, type/context, distinct equal-message
  failures, and discovery through `WhileHandling`.
- **Scope and constraints:** Keep the existing failure identity semantics and
  every recorded failure. Do not truncate evidence, limit nesting to conceal
  the issue, or use logging as its storage. Ordinary nested body scopes are
  not claimed to have this measured cost; the verified shape is nested releases
  carrying prior cleanup contexts.
- **Verification target:** Preserve the existing content tests and add the
  nested-release/shared-evidence regression with a generous allocation bound
  or another stable work bound. Avoid a narrow wall-clock assertion.
- **Deduplication:** The full tracker and evidence/allocation searches found no
  corresponding performance correction; #25 and #28 describe the original
  behavior rather than this traversal defect.
- **Remaining uncertainty:** The exact allocation count is compiler/platform
  dependent. The repeated traversal is present in current code and the rapid
  growth is reproduced on the supported GHC 9.12.2 toolchain.

## 4. Runtime reporting cancellation

### [#42] PRR-4. Preserve cancellation context through the runtime reporting boundary

> **Captured note:** P2. PR #38 uses a preserving rethrow for the original work
> failure, but `try` followed by bare `throwIO` for cancellation during its
> report. That path loses the cancellation's own annotations and cleanup
> failures, and the lifecycle guide publishes the same pattern.

**Verification:** Two additional Hspec regressions drive the exported
`resourceSmoke`. In one, the Error-reporting sink raises an annotated
`ThreadKilled`; the caller still catches that type, but the annotation is
absent. In the second, the reporting sink opens its own `withResourceLabelled
"report sink"` scope and blocks after signalling an `MVar`. Another thread
cancels it with `killThread`; its release then throws synchronously. The
resource primitive retains that cleanup failure on the cancellation, but after
`resourceSmoke` rethrows, public inspection returns **[]** instead of
**["report sink"]**. No timing sleeps or production edits were used.

This concerns the *new cancellation's own context*. It does not ask the boundary
to replace cancellation with the older work failure: the accepted policy makes
cancellation during reporting escape as cancellation.

**Evidence:**

- `packages/runtime/src/Hetoimasia/Runtime/Resources.hs:375` — the report uses
  `tryAny`.
- `packages/runtime/src/Hetoimasia/Runtime/Resources.hs:379` — its cancellation
  branch rethrows the bare `SomeException` with `throwIO`.
- `packages/runtime/src/Hetoimasia/Runtime/Resources.hs:399` —
  `tryAny = try`; this is exactly the context-losing catch/rethrow combination
  the resource contract warns callers against.
- `docs/resources.md:514` and `:518` — the worked lifecycle example repeats
  the losing branch next to guidance to rethrow preservingly.
- `test/Test/Engine/Resources/Smoke.hs:109` — existing reporting-cancellation
  coverage checks that cancellation escapes, without giving that cancellation
  context or cleanup evidence to preserve.

**Handoff context:**

- **Current behavior:** Cancellation keeps its recognizable exception type but
  drops structured evidence before reaching the reporting boundary's caller.
- **Expected behavior:** Preserve the exception and context of whichever
  failure the policy propagates, including a new cancellation during reporting.
  Synchronous reporting failure still preserves the original work/resource
  failure, and reporting is still attempted at most once.
- **Scope and constraints:** Correct the runtime helper and its lifecycle
  documentation together. No change to the generic logger, failure precedence,
  or uninterruptible release policy is needed.
- **Verification target:** Hspec coverage for an annotated cancellation and
  coordinated external cancellation whose reporting scope adds a cleanup
  failure. Assert the propagated type and inspectable context/evidence, plus
  the existing ordinary-report and failed-report outcomes.
- **Deduplication:** Searches found closed #9's terminal logging-worker policy
  and closed #30's new consumer, but no follow-up for this new preserving
  reporting boundary's loss of cancellation context.
- **Remaining uncertainty:** None for the observed loss; both explicit
  cancellation-type throwing and externally delivered cancellation reproduce it.

## Verification and retained evidence

- `cabal test hetoimasia-tests workflow-tests --test-show-details=direct`:
  **120 engine examples and 262 workflow examples pass**.
- `cabal build all`: passes; all three `cabal check` invocations pass.
- Fresh `cabal sdist all` archives of the three packages were unpacked outside
  Git with an explicit pinned `cabal.project`; **262 workflow examples pass**
  there as well, including the packaging inventory and its negative mutation.
- `actionlint -shellcheck=`: passes.
- The documented planner followed by isolated `run.py smoke.console` executes
  successfully from the clean audited candidate and produces a receipt.
- Master validation run **34702542399** completed successfully at the audited
  commit. A live review-gate jobs response was checked against the provenance
  reader's job/head/workflow/attempt fields.
- Eight additional Hspec examples exercise this audit's hypotheses: **seven
  fail as expected**, establishing the four findings; one confirms that a
  deferred label does not by itself replace a simple scope's body exception.
  The metadata leak is specifically established for composite orchestration.
- The PR review history was inspected: earlier lifecycle-sink recursion,
  missing acquisition-handoff coverage, and the CI review-round blockers were
  repaired before their merges and are not new report entries.
- The whole all-state tracker snapshot contains 19 issues; its only open issues
  are epics #8 and #22. No tracker artifact was changed during this audit.
- This audit did not trigger a live branch update or deliberately race GitHub
  approval mutations. PR #31's description still marks the live post-approval
  branch-update observation pending; local composition tests and source/API
  inspection do not substitute for that production observation.

Local reproductions and logs are retained at
`/var/folders/xs/kyf0vrg92c340wk3jncyp1fr0000gn/T/hetoimasia-foundation-audit.7_9afc9e/`:
`ResourceRegressions.hs`, `ScopeOpacity.hs`, `ScopeOpacitySpec.hs`,
`EvidenceCost.hs`, `EvidenceBudgetSpec.hs`, their logs, baseline test/build
logs, merged PR/issue snapshots, and source-distribution evidence. The isolated
checkout is `.worktrees/review-foundation-4949e8c` at the full SHA above.
These temporary paths support the durable reproductions described here; they
are not required implementation files or a published release artifact.
