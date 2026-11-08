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

## Acceptance commands

Collected on branch head `a677b9fd` (the pull request body carries the final-head
acceptance record), with the qualified toolchain activated on `PATH`
(`ghc --numeric-version` 9.14.1, `cabal --numeric-version` 3.18.1.0). The package was
rebuilt from a removed package build directory, so the `-Werror` build is a clean
compile of every module, not an incremental one.

| Command | Result |
| --- | --- |
| `cabal build --project-file cabal.project.cpu lib:hetoimasia-terrain-runtime` | success, no warning |
| `cabal test --project-file cabal.project.cpu hetoimasia-terrain-runtime:terrain-runtime-tests --test-show-details=direct` | 66 examples, 0 failures |
| `cabal test --project-file cabal.project.cpu hetoimasia-terrain:terrain-tests --test-show-details=direct` | 501 examples, 0 failures |
| `cabal test --project-file cabal.project.cpu hetoimasia:workflow-tests --test-show-details=direct` | 965 examples, 0 failures |
| `(cd packages/terrain-runtime && cabal check)` | No errors or warnings could be found in the package |
| `python3 tools/validation/plan.py --catalog-check` | catalog valid: 37 groups, policy version 25 |
| `python3 tools/validation/plan.py --base origin/master --head HEAD` | selects `test.terrain-runtime` and every affected predecessor and mandatory group (29 of 37; the catalog and workflow changes are policy inputs and widen the plan) |
| `python3 tools/validation/owned_starts.py check` and `ratchet --base origin/master` | pass; the new package has no unowned start |

The suite was also run eight times at `+RTS -N4` after the one example that raced its own
bookkeeping was corrected (it asserted the order of two events that nothing orders), and
six more times after the owner was made to stop only when asked; every run passed.
The native display groups the plan selects were not run locally: this slice opens no
window, and CI runs them.
