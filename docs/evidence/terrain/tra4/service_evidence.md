# TRA-4 service evidence (#640)

Evidence for `hetoimasia-terrain-runtime`: gated traces with before and after
accounting, the negative controls, and the acceptance results. It is a record for
people; nothing reads it. The contract is
[the package README](../../../../packages/terrain-runtime/README.md).

No native display, GPU capture, timing benchmark or measured performance claim is
part of this slice, and none is made here.

## How the traces were produced

A throwaway script (not committed, like `terrain-measure`) drove the production
service through the same public interface the suite uses, holding the owner at a
named `Probe` point with an `MVar` gate, and printed the model's three byte banks
(occupied/reserved), the command and load-job slots, the job phases and the number of
resident regions before and after each step. The default profile of #639 is in force
(256 MiB resident, 64 MiB retained edits, 128 MiB staging); trace 4 uses a tight
resident bank (a 2 x 1 x 2 extent) so that eviction really happens. The figures are the
model's conservative accounting, not process memory.

A one-cell region is charged 338 resident bytes (256 region metadata, 48 for its
column entry, 32 for its segment, 2 for the payload); a removal reserves 62
resident-growth bytes, 64 retained-edit bytes and 512 staging bytes until it commits.

```text
== 1. Cancel versus commit (gated at the commit boundary)
- cancel wins
    quiescent       : resident occ/res 0/0  edit 0/0  staging 0/0  commands 0  loadJobs 0  jobs []  regions 0
    owner at boundary: resident occ/res 338/62  edit 0/64  staging 224/512  commands 1  loadJobs 0  jobs []  regions 1
    cancel -> CancelWon
    removal settlement -> (cancelled before it could settle)
    cell afterwards -> revision Revision 0, solid
    after           : resident occ/res 338/0  edit 0/0  staging 0/0  commands 0  loadJobs 0  jobs []  regions 1
- commit wins
    quiescent       : resident occ/res 0/0  edit 0/0  staging 0/0  commands 0  loadJobs 0  jobs []  regions 0
    owner at boundary: resident occ/res 338/62  edit 0/64  staging 224/512  commands 1  loadJobs 0  jobs []  regions 1
    removal settlement -> Right (RemoveAnswer {removeIncarnation = ArenaId 0, removeRevision = Revision 1, removeChangedFlag = True})
    late cancel -> AlreadySettled
    cell afterwards -> revision Revision 1, air
    after           : resident occ/res 338/0  edit 64/0  staging 0/0  commands 0  loadJobs 0  jobs []  regions 1

== 2. Close versus a pending load (gated while the load runs)
  before request    : resident occ/res 0/0  edit 0/0  staging 0/0  commands 0  loadJobs 0  jobs []  regions 0
  load running      : resident occ/res 0/400  edit 0/0  staging 224/258  commands 1  loadJobs 1  jobs [JobRunningPhase]  regions 0
    pending request -> Left (Failed ArenaClosed)
  arena closed      : resident occ/res 0/400  edit 0/0  staging 0/258  commands 0  loadJobs 1  jobs [JobCancellingPhase]  regions 0
  load acknowledged : resident occ/res 0/0  edit 0/0  staging 0/0  commands 0  loadJobs 0  jobs []  regions 0

== 3. Snapshot retirement
  region loaded     : resident occ/res 338/0  edit 0/0  staging 0/0  commands 0  loadJobs 0  jobs []  regions 1
  snapshot held     : resident occ/res 338/0  edit 0/0  staging 64/0  commands 0  loadJobs 0  jobs []  regions 1
    edit while held -> RemoveAnswer {removeIncarnation = ArenaId 0, removeRevision = Revision 1, removeChangedFlag = True}
    snapshot still shows -> Known (Solid (MaterialId "soil") (ShapeId 0)) at Revision 0
  edit committed    : resident occ/res 338/0  edit 64/0  staging 64/0  commands 0  loadJobs 0  jobs []  regions 1
  snapshot released : resident occ/res 338/0  edit 64/0  staging 0/0  commands 0  loadJobs 0  jobs []  regions 1

== 4. Offload and reload (a tight resident bank forces eviction)
    removal -> RemoveAnswer {removeIncarnation = ArenaId 0, removeRevision = Revision 1, removeChangedFlag = True}
  after commit      : resident occ/res 338/0  edit 64/0  staging 0/0  commands 0  loadJobs 0  jobs []  regions 1
  after transfer    : resident occ/res 338/0  edit 64/0  staging 0/0  commands 0  loadJobs 0  jobs []  regions 1
  after pressure    : resident occ/res 3718/0  edit 64/0  staging 0/0  commands 0  loadJobs 0  jobs []  regions 11
    edited region resident? -> False
    reload: cell -> revision Revision 1, air
  after reload      : resident occ/res 3718/0  edit 64/0  staging 0/0  commands 0  loadJobs 0  jobs []  regions 11
    retained store has changes -> True, working regions -> []
```

### Reading the traces

1. **Cancel versus commit.** The owner is held at the commit boundary with the edit
   staged: 62 resident, 64 retained-edit and 512 staging bytes are reserved and one
   command slot is in use. When cancellation wins, every reservation returns, the
   edit bank stays at zero and the cell is still solid at revision 0. When the commit
   wins, the settlement is `Right (RemoveAnswer ... Revision 1 True)`, the 64 retained
   bytes move from reserved to occupied, a late cancel answers `AlreadySettled`, and
   the cell is air at revision 1. In neither case does a success precede its edit or
   a cancellation accompany a committed edit.
2. **Close versus a pending load.** The load holds 400 reserved resident bytes, 258
   staging scratch bytes and one load-job slot while it runs. Closing the arena
   settles the other client's request once with `ArenaClosed` and returns the
   command's own 224 staging bytes, but the job is *cancelling* and still holds its
   400 and 258 bytes and its slot: a cancellation alone returns no in-use credits.
   They return when the owner acknowledges the job.
3. **Snapshot retirement.** Taking the borrow adds a 64-byte staging hold record and
   protects the region. An edit commits while it is held (revision 1, 64 retained
   bytes); the snapshot still shows the cell solid at revision 0. The 64 staging bytes
   return only when the snapshot is released.
4. **Offload and reload.** After the edit commits, the transfer to the retained store
   completes with no new edit capacity (the 64 retained bytes stay at 64). Pressure
   from other regions evicts the edited region once it is clean (the resident bank
   holds 11 regions at its peak and the edited one is gone); reading the cell again
   reconstructs it from the source plus the retained removals: air at revision 1.

## Negative controls

Each control breaks one *protected* behaviour while keeping the scenario premise,
was run once locally against the committed tree, and was reverted. No mutation was
committed. The failing assertion is the one that protects the behaviour.

| Control | Mutation | Example that fails | Failure |
| --- | --- | --- | --- |
| NC1 | `cancelRequest` answers `CancelWon` without removing the request | `Cancellation, staging and commit, arrival, cancelled at the commit boundary leaves the cell and the revision` | expected `(Revision 0,False)`, got `(Revision 1,True)`: an edit committed after a winning cancellation |
| NC2 | Staged work superseded by a committed edit is neither detected nor revalidated at commit | `recomputes a staged read that a committed edit superseded, and never relabels it` | expected `(Revision 1,True)`, got `(Revision 0,False)`: the stale answer was published |
| NC3 | The commit arbitration no longer reads the parent session's admission | `the parent session's admission is read inside the commit arbitration` | expected `[Failed ArenaClosed]`, got `[Succeeded (ARemoved ...)]`: an edit committed after the session closed |
| NC4 | A snapshot's hold is dropped as soon as it is taken | `keeps a held snapshot coherent through an edit and eviction pressure, and keeps its bytes charged` | the model holds no borrow while the snapshot is in use |
| NC5 | A failed transfer discards the working changes | `retains changes through a failed transfer and transfers them after the region changes again` | expected the region's changes retained, got none |
| NC6 | Closing an arena leaves its requests unsettled | `settles a staged edit once when its arena closes and commits nothing` | expected `[Failed ArenaClosed]`, got `[]`: a request never reached a terminal outcome |
| NC7 | A later eligible command may commit ahead of an earlier eligible, unstaged one | `commits the same ordered trace to the same results and terrain under different residency schedules` | the roomy and tight schedules answer different revisions for the same ordered trace |
| NC8 | A column is measured once per interval of the load, not once per column | `demands several intervals of one column and measures the load once per column` | the owner ended on an over-reported cost and the wait for the loaded demand never completed |
| NC6b | As NC6 | `randomized interleaving ... (seed 1)` | the request table claims model records the model lacks, found after the first mutated step |
| NC11 | The owner's terminal step no longer retires in-flight accounts | `retires every in-flight account when the owner is interrupted while a load runs` | the model still holds a cancelling job with 400 resident and 258 staging bytes reserved and an arena retiring |
| NC15 | Loads and retries starve behind a stream of ready requests | `gives a queued load its turn while ready requests keep arriving elsewhere` | the cold load settled after all 41 cache hits |
| NC16 | The owner drops the cleanup's defects when it had already failed | `attaches the cleanup's defects to the failure the owner already has` | no cleanup evidence reached supervision |
| NC17 | An untaken removal result is not charged bytes | `keeps an untaken removal result's bytes charged in the retained bank until it is taken` | expected 320 bytes charged, got 0 |
| NC18 | A fatal defect marks every earlier unreported one as reported | `reports an earlier unreported defect beside a later fatal one` | the earlier closure-callback failure never reached supervision |
| NC19 | Pending opens and attaches are not charged | `charges pending opens and attaches against the command slots and the retained bank` | a third delayed attachment was admitted into two slots |
| NC20 | A pending removal reserves nothing in the retained bank | `reserves a removal's result bytes at admission ...` | a third pending removal was admitted into a 330-byte bank |
| NC21 | Every readmission refusal is treated as temporary | `ends a superseded request with a typed failure when its readmission is permanently refused` | the request waited forever (bounded wait never returned) |
| NC22 | A failing logger replaces the defect it was reporting | `never lets a failing logger replace the defect it was reporting` | supervision saw only the sink's failure |
| NC23 | Staging keeps unconditional precedence over commits | `serves an eligible staged commit within a bounded number of preparations ...` (3 of 4 fairness examples fail; the sustained cancel/replace one does not, because replaced reads are cancelled before they are prepared) | the commit followed 6 preparations (5 hits), growing with the run |
| NC24 | A request waiting to be admitted again is not charged | `keeps a request that waits to be admitted again charged ...` | a second read was admitted into two full slots |
| NC25 | Only removals and acquisitions reserve a retained record at admission | `reserves a read's record at admission, so a read that starts waiting to be admitted again cannot overfill the retained bank` | a second removal was admitted into room the waiting read would need |
| NC28 | Retries (useful whenever a view exists) always ahead of dispatch, no dispatch turn | `dispatches a queued load while every preparation is followed by a cancellation and a replacement, with a view registered` | the load ran only after the stream ended (60 preparations) |
| NC29 | Same ordering with the old retry trigger | same example | same |
| NC30 | A cancelled request gives its credits back while its preparation runs | `keeps every credit of a request whose preparation is running ...` (cancel, lease release, close) | the model's staging, edit and slot credits were zero while the preparation still computed |
| NC31 | A closed arena is retired while a preparation of it runs | the same examples (lease release, close) | the same |
| NC32 | A capacity-refused transfer is suppressed like a failed one | `reconsiders a transfer refused for want of capacity as soon as capacity is returned` | the region stayed dirty after capacity returned (bounded wait never returned) |
| NC33 | Credits released while a preparation runs, caught by the randomized property | `keeps every invariant when releases arrive while a preparation runs` | 18 of 24 seeds: the request being prepared had no model record |
| NC9 | The drain does not wait for outstanding borrowers | `does not return while a borrower holds a snapshot after the owner failed` | expected the service not to have returned, got that it had |

## Acceptance commands

Collected on branch head `a677b9fd` (the pull request body carries the final-head
acceptance record), with the qualified toolchain activated on `PATH`
(`ghc --numeric-version` 9.14.1, `cabal --numeric-version` 3.18.1.0). The package was
rebuilt from a removed package build directory, so the `-Werror` build is a clean
compile of every module, not an incremental one.

| Command | Result |
| --- | --- |
| `cabal build --project-file cabal.project.cpu lib:hetoimasia-terrain-runtime` | success, no warning (package build directory removed first) |
| `cabal test --project-file cabal.project.cpu hetoimasia-terrain-runtime:terrain-runtime-tests --test-show-details=direct` | 175 examples, 0 failures |
| `cabal test --project-file cabal.project.cpu hetoimasia-terrain:terrain-tests --test-show-details=direct` | 669 examples, 0 failures (on the merged head) |
| `cabal test --project-file cabal.project.cpu hetoimasia:workflow-tests --test-show-details=direct` | 965 examples, 0 failures |
| `(cd packages/terrain-runtime && cabal check)` | No errors or warnings could be found in the package |
| `python3 tools/validation/plan.py --catalog-check` | catalog valid: 37 groups, policy version 25 |
| `python3 tools/validation/plan.py --base origin/master --head HEAD` | selects `test.terrain-runtime` and every affected predecessor and mandatory group (29 of 37; the catalog and workflow changes are policy inputs and widen the plan) |
| `python3 tools/validation/owned_starts.py check` and `ratchet --base origin/master` | pass; the new package has no unowned start |

After the first six review rounds the suite grew from 66 to 175 examples (24 seeds of a randomized interleaving, retained-size shrink on
coalescing, residency kept across a delayed commit, several intervals of one column,
the column length limit, a failing readiness callback, snapshot backing across
revisions, the drain on the failure path and under cancellation, the owner's logging
failures); it was then run six times at `+RTS -N4` and once at the default
capability count on the round-2 head, all passing. NC14 (a borrow release no longer
counted as a retry opportunity) was run and the progress example did not fail under it,
because that scenario also reaches a retry through other events; the rule is
structural (one function, `freesCapacity`) and is reported as not mutation-checked. Before that it was run eight times at `+RTS -N4` after the one example that raced its own
bookkeeping was corrected (it asserted the order of two events that nothing orders), and
six more times after the owner was made to stop only when asked; every run passed.
The native display groups the plan selects were not run locally: this slice opens no
window, and CI runs them.

NC26 (the retry trigger alone, a registered view with no pending demand) and NC27 (a retry pass handing the next turn to staging instead of dispatch) are not independently pinned by an example: the four-way rotation gives dispatch its turn anyway, so each is redundant with it and is disclosed as such rather than counted as a control.
