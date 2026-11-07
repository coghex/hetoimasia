# TRA-3 evidence: bounded residency and admission (#639)

Evidence for the pure residency and admission model of
`hetoimasia-terrain` (`Hetoimasia.Terrain.Residency`), epic #636. It is
retained deliberately with its issue: an ignored capture alone is not a delivered
artifact. Contract: [the package README](../../../../packages/terrain/README.md#residency-and-admission).
Design: [the terrain arena design](../../../designs/terrain_arena_design.md), P-5 and
TRA-3.

No window, GPU capture, concurrent-service test or numeric speed claim is part of
this slice. The byte figures are conservative accounting, not process memory and
not a measured performance claim.

## How the traces were produced

The tables below are the output of a throwaway program that calls only the
package's public interface (it is not committed; the same sequences are asserted
step by step in `Test.Terrain.Residency`, so the figures cannot drift from the
suite). Each row is one `step` of the pure model. The ledgers read
`occupied+reserved/limit` for the three banks, and the slots read in use over limit.
Charges are those of the contract: a one-cell job reserves 400 resident bytes (256
region metadata, 48 column entry, 32 segment, 64 for the dense payload bound of its
interval), stores 338 when its cell needs two payload bytes, and reserves 258 bytes
of scratch; an interest record is 64 staging bytes and an accepted command naming
one region 160; a whole-cell removal reserves 64 edit bytes, 512 staging bytes and
62 resident bytes for its rebuilt segment.

```sh
cabal exec --project-file cabal.project.cpu -- ghc -O0 -package hetoimasia-terrain -o evidence Evidence.hs
./evidence
```

Limits: A uses 1,000 resident, 192 edit and 2,048 staging bytes with 3 jobs and
3 commands; B uses 400 resident bytes; C uses 800; D uses 480; E uses 4,000 resident
and 4,096 staging bytes, aging threshold 3.

## A. Reservation, completion, cancellation: shared job survives one caller canceling
| step | decision | ledgers (occupied+reserved/limit) | slots |
| --- | --- | --- | --- |
| caller 1 queries region X | accepted jobs=[0] shared=0 victims=0 deferred=0 | resident 0+400/1000  edit 0+0/192  staging 224+258/2048 | jobs 1/3 commands 1/3 |
| caller 2 queries the same cells | accepted jobs=[] shared=1 victims=0 deferred=0 | resident 0+400/1000  edit 0+0/192  staging 448+258/2048 | jobs 1/3 commands 2/3 |
| dispatch | Dispatched job 0 | resident 0+400/1000  edit 0+0/192  staging 448+258/2048 | jobs 1/3 commands 2/3 |
| caller 1 cancels (caller 2 still needs the job) | Withdrawn dropped=0 cancelling=0 | resident 0+400/1000  edit 0+0/192  staging 224+258/2048 | jobs 1/3 commands 1/3 |
| caller 2 cancels (last interest; job is running) | Withdrawn dropped=0 cancelling=1 | resident 0+400/1000  edit 0+0/192  staging 0+258/2048 | jobs 1/3 commands 0/3 |
| late completion arrives (dropped, nothing published) | Discarded job 0 | resident 0+0/1000  edit 0+0/192  staging 0+0/2048 | jobs 0/3 commands 0/3 |

## B. Pinned and held data cannot be evicted
| step | decision | ledgers | slots |
| --- | --- | --- | --- |
| query X | accepted jobs=[0] shared=0 victims=0 deferred=0 | resident 0+400/400  edit 0+0/192  staging 224+258/2048 | jobs 1/3 commands 1/3 |
| dispatch | Dispatched job 0 | resident 0+400/400  edit 0+0/192  staging 224+258/2048 | jobs 1/3 commands 1/3 |
| complete X | Published job 0 owners 1 | resident 338+0/400  edit 0+0/192  staging 224+0/2048 | jobs 0/3 commands 1/3 |
| settle query | Withdrawn dropped=0 cancelling=0 | resident 338+0/400  edit 0+0/192  staging 0+0/2048 | jobs 0/3 commands 0/3 |
| pin X for view 1 | HoldAcquired | resident 338+0/400  edit 0+0/192  staging 64+0/2048 | jobs 0/3 commands 0/3 |
| query Y (needs eviction; only X resident) | REFUSED Busy (NoEligibleEviction 338 0 (Blockers {blockedEvicting = 0, blockedHandoff = 0, blockedDirty = 0, blockedHeld = 1, blockedInterest = 0, blockedJob = 0, blockedByRequest = 0})) | resident 338+0/400  edit 0+0/192  staging 64+0/2048 | jobs 0/3 commands 0/3 |
| release the pin | HoldReleased | resident 338+0/400  edit 0+0/192  staging 0+0/2048 | jobs 0/3 commands 0/3 |
| query Y again (X is now the victim) | accepted jobs=[1] shared=0 victims=1 deferred=338 | resident 338+62/400  edit 0+0/192  staging 224+258/2048 | jobs 1/3 commands 1/3 |

## C. Old vertical regions turn over under fixed caps (resident bank 800 bytes, two regions)
| step | decision | ledgers | slots |
| --- | --- | --- | --- |
| descend to region z=-1 | accepted jobs=[0] shared=0 victims=0 deferred=0 evicts [] | resident 0+400/800  edit 0+0/192  staging 224+258/2048 | jobs 1/3 commands 1/3 |
| descend to region z=-2 | accepted jobs=[1] shared=0 victims=0 deferred=0 evicts [] | resident 338+400/800  edit 0+0/192  staging 224+258/2048 | jobs 1/3 commands 1/3 |
| descend to region z=-3 | accepted jobs=[2] shared=0 victims=1 deferred=276 evicts [-1] | resident 676+124/800  edit 0+0/192  staging 224+258/2048 | jobs 1/3 commands 1/3 |
| descend to region z=-4 | accepted jobs=[3] shared=0 victims=1 deferred=276 evicts [-2] | resident 676+124/800  edit 0+0/192  staging 224+258/2048 | jobs 1/3 commands 1/3 |
| descend to region z=-5 | accepted jobs=[4] shared=0 victims=1 deferred=276 evicts [-3] | resident 676+124/800  edit 0+0/192  staging 224+258/2048 | jobs 1/3 commands 1/3 |
| descend to region z=-6 | accepted jobs=[5] shared=0 victims=1 deferred=276 evicts [-4] | resident 676+124/800  edit 0+0/192  staging 224+258/2048 | jobs 1/3 commands 1/3 |
resident regions after the descent: [-6,-5]

## D. Retained edits: reserve, commit, handoff failure, handoff success, exhaustion
| step | decision | ledgers | slots |
| --- | --- | --- | --- |
| reserve a removal at tile (0,0,0) | accepted jobs=[0] shared=0 victims=0 deferred=0 | resident 0+462/480  edit 0+64/192  staging 224+770/2048 | jobs 1/3 commands 1/3 |
| dispatch | Dispatched job 0 | resident 0+462/480  edit 0+64/192  staging 224+770/2048 | jobs 1/3 commands 1/3 |
| complete the load | Published job 0 owners 1 | resident 338+62/480  edit 0+64/192  staging 224+512/2048 | jobs 0/3 commands 1/3 |
| commit the removal (64 retained bytes) | Committed rev 1 returned=0 | resident 338+0/480  edit 64+0/192  staging 0+0/2048 | jobs 0/3 commands 0/3 |
| query Y under pressure (changed region is protected) | REFUSED Busy (NoEligibleEviction 258 0 (Blockers {blockedEvicting = 0, blockedHandoff = 0, blockedDirty = 1, blockedHeld = 0, blockedInterest = 0, blockedJob = 0, blockedByRequest = 0})) | resident 338+0/480  edit 64+0/192  staging 0+0/2048 | jobs 0/3 commands 0/3 |
| begin handoff (64-byte duplicate in staging) | HandoffStarted | resident 338+0/480  edit 64+0/192  staging 64+0/2048 | jobs 0/3 commands 0/3 |
| handoff fails | HandoffAbandoned | resident 338+0/480  edit 64+0/192  staging 0+0/2048 | jobs 0/3 commands 0/3 |
| query Y again (changes and protection kept, no automatic retry) | REFUSED Busy (NoEligibleEviction 258 0 (Blockers {blockedEvicting = 0, blockedHandoff = 0, blockedDirty = 1, blockedHeld = 0, blockedInterest = 0, blockedJob = 0, blockedByRequest = 0})) | resident 338+0/480  edit 64+0/192  staging 0+0/2048 | jobs 0/3 commands 0/3 |
| begin handoff again | HandoffStarted | resident 338+0/480  edit 64+0/192  staging 64+0/2048 | jobs 0/3 commands 0/3 |
| handoff confirmed (no new edit allocation) | HandoffSettled | resident 338+0/480  edit 64+0/192  staging 0+0/2048 | jobs 0/3 commands 0/3 |
| query Y (the clean region is now the victim) | accepted jobs=[1] shared=0 victims=1 deferred=258 | resident 338+142/480  edit 64+0/192  staging 224+258/2048 | jobs 1/3 commands 1/3 |
| owner discards the victim's detail | VictimFreed | resident 0+400/480  edit 64+0/192  staging 224+258/2048 | jobs 1/3 commands 1/3 |

## E. Sustained foreground arrivals still allow an aged prefetch job to run (aging threshold 3)
dispatch order (job 0 is the prefetch job, queued first): [1,2,3,0]

What each shows:

- **A.** A job shared by two callers survives one caller canceling (the job and its
  whole reservation stay) and, when the last interest cancels while it is running, keeps
  its scratch and resident reservation until its completion is reported; the late
  result is dropped and publishes nothing. The three ledgers move separately: the
  resident bank only reserves, staging holds the interests and commands.
- **B.** A pinned region is never selected: the refusal names the held region. After
  the pin is released the same request is admitted with the region committed as its
  victim, 62 bytes funded now and 338 when the victim's release arrives.
- **C.** Six regions down one column under a two-region bank: the resident bank never
  exceeds 800 bytes, each admission past the second commits the oldest region as its
  victim, and the last two regions remain.
- **D.** The removal reserves 64 edit bytes and 62 resident bytes for its rebuilt
  segment; the commit occupies the 64 edit bytes, returns the reservations and the
  command, and the changed region is protected under pressure. A failed handoff loses
  nothing (the retained bytes, the changes and the protection are intact, and the
  model does not retry); a confirmed handoff changes no edit byte and makes the region
  the victim.
- **E.** With foreground arrivals before every dispatch, the prefetch job (job 0) is
  served fourth, after being passed over three times, ahead of the fourth arrival.

## Reconstruction after resident detail is discarded

`Test.Terrain.ResidencyCycle` plays the later terrain service over the real
TRA-2 `Source`, `Changes`, `Palette` and `Resident`. Six cycles remove the cells
(0,0,0), (1,0,0), (0,0,-1), (1,0,-1), (0,0,-2), (1,0,-2) of the soil-over-stone
fixture. Each cycle reserves and loads the cell, removes it with `removeCell`,
stages the resident cell, commits at the next revision with the real retained growth
(64, 64, then 0 four times as later cells join the existing intervals, each time
returning the unused part of the 64-byte reservation) and the real growth of the
rebuilt segment, hands the changes off, evicts the edited regions under pressure from
other demand (the real detail of every victim is discarded), and reconstructs every
cell removed so far from the source plus the retained changes. After the
reconstruction every removed cell is a known air value in the resident detail, an
unrequested cell stays unmaterialized and never air, and every cell in a 3 x 1 x 7
box equals the independent naive model of `Test.Terrain.Model`. At the end the
model's retained bytes (128) equal `changesBytes` of the real changes (two columns
and two intervals), and no reservation or staging charge remains. After every
completion, commit and individual victim release the model's resident charge is
checked against the real detail: it is never less than 256 bytes for each resident
region plus the accounted payload, segment metadata and column entries the real
`Resident` holds.

Two further real-data examples cover the accounting the first review round found
missing. A uniform 32-cell segment (2 bytes) of the stone region is edited with the
resident bank full: the removal reserves its 62 bytes of growth, the real rebuilt
segment (three runs, 12 bytes) grows by 10, the commit charges exactly 10, and the
bank (348 of 400) then refuses a second removal as busy by 10. Two vertical regions
of one column share one real column index entry; each is charged for its own column,
and evicting the older region leaves the survivor charged its own 338 bytes.

## Negative controls

Each protected behavior was broken once locally while keeping the scenario premise,
the focused suite was run, and the mutation was reverted without being committed
(the implementation was committed first). All were re-run against the final
accounting.

| Mutation | Failing examples |
| --- | --- |
| Eviction ignores holds | the held-region skip and the pinned-region refusal examples, the random property |
| Eviction ignores unsettled changes | the changed-region refusal and the failed-handoff examples, the random property |
| Handoff protection dropped | the handoff-protection example |
| A job is cancelled when any caller withdraws | the coverage-growth example |
| Aging disabled | the aging example |
| Retained-edit exhaustion not checked | the retained-bound example and the arena-retirement example |
| Stored cost not reconciled with the reservation | the contract-failure example |
| A cancelled job publishes its late result | cancellation and retirement examples |
| A released victim does not fund the waiting job | the funded-eviction example and the turnover examples |
| Zero limits accepted | the limit-validation examples |
| Eviction ignores interests | the resident-busy and multi-bank rollback examples, the random property |
| A victim's credit promised twice | the shared-victim example and the long random sequence |
| The validated-limits constructor exported | the external-client constructor examples |
| Payload reserved per cell instead of the dense bound | the ledger, reconciliation and growth examples (28 examples) |
| A job does not reserve its columns | the column-independence example and the ledger examples |
| No resident growth reserved for a removal | the edit-reservation, growth-contract and compressed-segment examples |
| An older handoff clears newer changes | the handoff-interleaving example |
| A stale failure acts on current demand | the stale-failure example |
| An obsolete camera interest survives a busy replacement | the camera-replacement example |
| The camera description left out of the permanent footprint | the combined-footprint example |
| Unsupported region keys accepted | the region-boundary example |
| The owner reports the shared index growth as the region's columns | the cycle example and the shared-column eviction example |
| A removal commit does not add the rebuilt segment growth | the growth-contract and compressed-segment examples |
| Retirement settles with a victim release outstanding | the cross-arena retirement example and the random properties |
| A successful replacement drops its cancellation lists | the replacement-report example |
| The camera footprint counts one interest only | the multi-region footprint example |
| Pinned camera regions not bounded by the resident bank | the multi-region footprint example |
| A commit does not report the queued and running jobs of the changed region | the commit-report and stale-failure examples |
| A failure does not report the jobs it leaves unneeded | the failure-report example |
| The camera peak ignores the last job's reservation | the multi-region footprint example |
