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

Limits: A, D and E use the tiny configuration: 1,000 resident, 192 edit and 2,048
staging bytes with 3 load jobs and 3 commands, at most two regions per query, no holds,
camera descriptions of up to 64 and a one-cell region extent (it meets the minimum
budgets: a query of two regions needs 964 resident bytes and 994 staging bytes that
camera work and holds leave free); E has 4,000 resident and 4,096 staging bytes and an
aging threshold of 3. B has 1,302 resident bytes and holds of one region (the 964 an
explicit request may need and the held region at its stored maximum, 338, with 64 more
staging bytes for its record); C uses 964, the least the tiny configuration allows. A
load-job slot is taken when a job is dispatched, so the slot column reads 0 for admitted
work that waits.

## A. Reservation, completion, cancellation: shared job survives one caller canceling
| step | decision | ledgers (occupied+reserved/limit) | slots |
| --- | --- | --- | --- |
| caller 1 queries region X | accepted jobs=[0] shared=0 victims=0 deferred=0 | resident 0+400/1000  edit 0+0/192  staging 224+258/2048 | jobs 0/3 commands 1/3 |
| caller 2 queries the same cells | accepted jobs=[] shared=1 victims=0 deferred=0 | resident 0+400/1000  edit 0+0/192  staging 448+258/2048 | jobs 0/3 commands 2/3 |
| dispatch | Dispatched job 0 | resident 0+400/1000  edit 0+0/192  staging 448+258/2048 | jobs 1/3 commands 2/3 |
| caller 1 cancels (caller 2 still needs the job) | Withdrawn dropped=0 cancelling=0 | resident 0+400/1000  edit 0+0/192  staging 224+258/2048 | jobs 1/3 commands 1/3 |
| caller 2 cancels (last interest; job is running) | Withdrawn dropped=0 cancelling=1 | resident 0+400/1000  edit 0+0/192  staging 0+258/2048 | jobs 1/3 commands 0/3 |
| late completion arrives (dropped, nothing published) | Discarded job 0 | resident 0+0/1000  edit 0+0/192  staging 0+0/2048 | jobs 0/3 commands 0/3 |

## B. Pinned and held data cannot be evicted
| step | decision | ledgers | slots |
| --- | --- | --- | --- |
| query X | accepted jobs=[0] shared=0 victims=0 deferred=0 | resident 0+400/1302  edit 0+0/192  staging 224+258/2048 | jobs 0/3 commands 1/3 |
| dispatch | Dispatched job 0 | resident 0+400/1302  edit 0+0/192  staging 224+258/2048 | jobs 1/3 commands 1/3 |
| complete X | Published job 0 owners 1 | resident 338+0/1302  edit 0+0/192  staging 224+0/2048 | jobs 0/3 commands 1/3 |
| settle query | Withdrawn dropped=0 cancelling=0 | resident 338+0/1302  edit 0+0/192  staging 0+0/2048 | jobs 0/3 commands 0/3 |
| query W (stays open: W is in use) | accepted jobs=[1] shared=0 victims=0 deferred=0 | resident 338+400/1302  edit 0+0/192  staging 224+258/2048 | jobs 0/3 commands 1/3 |
| dispatch | Dispatched job 1 | resident 338+400/1302  edit 0+0/192  staging 224+258/2048 | jobs 1/3 commands 1/3 |
| complete W | Published job 1 owners 1 | resident 676+0/1302  edit 0+0/192  staging 224+0/2048 | jobs 0/3 commands 1/3 |
| query V (stays open: V is in use) | accepted jobs=[2] shared=0 victims=0 deferred=0 | resident 676+400/1302  edit 0+0/192  staging 448+258/2048 | jobs 0/3 commands 2/3 |
| dispatch | Dispatched job 2 | resident 676+400/1302  edit 0+0/192  staging 448+258/2048 | jobs 1/3 commands 2/3 |
| complete V | Published job 2 owners 1 | resident 1014+0/1302  edit 0+0/192  staging 448+0/2048 | jobs 0/3 commands 2/3 |
| pin X for view 1 (338 pinned bytes are the most a hold may take here) | HoldAcquired | resident 1014+0/1302  edit 0+0/192  staging 512+0/2048 | jobs 0/3 commands 2/3 |
| pin W as well (would pin more than the bank leaves for explicit work) | REFUSED Busy (BankFull ResidentBank 338 338 338) | resident 1014+0/1302  edit 0+0/192  staging 512+0/2048 | jobs 0/3 commands 2/3 |
| query Y (needs eviction; X is pinned, W and V are in use) | REFUSED Busy (NoEligibleEviction 112 0 (Blockers {blockedEvicting = 0, blockedHandoff = 0, blockedDirty = 0, blockedHeld = 1, blockedInterest = 2, blockedJob = 0, blockedByRequest = 0})) | resident 1014+0/1302  edit 0+0/192  staging 512+0/2048 | jobs 0/3 commands 2/3 |
| release the pin on X | HoldReleased | resident 1014+0/1302  edit 0+0/192  staging 448+0/2048 | jobs 0/3 commands 2/3 |
| query Y again (X is now the victim) | accepted jobs=[3] shared=0 victims=1 deferred=112 | resident 1014+288/1302  edit 0+0/192  staging 672+258/2048 | jobs 0/3 commands 3/3 |

## C. Old vertical regions turn over under fixed caps (resident bank 964 bytes, two regions)
| step | decision | ledgers | slots |
| --- | --- | --- | --- |
| descend to region z=-1 | accepted jobs=[0] shared=0 victims=0 deferred=0 evicts [] | resident 0+400/964  edit 0+0/192  staging 224+258/2048 | jobs 0/3 commands 1/3 |
| descend to region z=-2 | accepted jobs=[1] shared=0 victims=0 deferred=0 evicts [] | resident 338+400/964  edit 0+0/192  staging 224+258/2048 | jobs 0/3 commands 1/3 |
| descend to region z=-3 | accepted jobs=[2] shared=0 victims=1 deferred=112 evicts [-1] | resident 676+288/964  edit 0+0/192  staging 224+258/2048 | jobs 0/3 commands 1/3 |
| descend to region z=-4 | accepted jobs=[3] shared=0 victims=1 deferred=112 evicts [-2] | resident 676+288/964  edit 0+0/192  staging 224+258/2048 | jobs 0/3 commands 1/3 |
| descend to region z=-5 | accepted jobs=[4] shared=0 victims=1 deferred=112 evicts [-3] | resident 676+288/964  edit 0+0/192  staging 224+258/2048 | jobs 0/3 commands 1/3 |
| descend to region z=-6 | accepted jobs=[5] shared=0 victims=1 deferred=112 evicts [-4] | resident 676+288/964  edit 0+0/192  staging 224+258/2048 | jobs 0/3 commands 1/3 |
resident regions after the descent: [-6,-5]

## D. Retained edits: reserve, commit, handoff failure, handoff success, exhaustion
| step | decision | ledgers | slots |
| --- | --- | --- | --- |
| reserve a removal at tile (0,0,0) | accepted jobs=[0] shared=0 victims=0 deferred=0 | resident 0+462/1000  edit 0+64/192  staging 224+770/2048 | jobs 0/3 commands 1/3 |
| dispatch | Dispatched job 0 | resident 0+462/1000  edit 0+64/192  staging 224+770/2048 | jobs 1/3 commands 1/3 |
| complete the load | Published job 0 owners 1 | resident 338+62/1000  edit 0+64/192  staging 224+512/2048 | jobs 0/3 commands 1/3 |
| commit the removal (64 retained bytes) | Committed rev 1 returned=0 | resident 338+0/1000  edit 64+0/192  staging 0+0/2048 | jobs 0/3 commands 0/3 |
| two-region query under pressure (changed region is protected) | REFUSED Busy (NoEligibleEviction 138 0 (Blockers {blockedEvicting = 0, blockedHandoff = 0, blockedDirty = 1, blockedHeld = 0, blockedInterest = 0, blockedJob = 0, blockedByRequest = 0})) | resident 338+0/1000  edit 64+0/192  staging 0+0/2048 | jobs 0/3 commands 0/3 |
| begin handoff (64-byte duplicate in staging) | HandoffStarted | resident 338+0/1000  edit 64+0/192  staging 64+0/2048 | jobs 0/3 commands 0/3 |
| handoff fails | HandoffAbandoned | resident 338+0/1000  edit 64+0/192  staging 0+0/2048 | jobs 0/3 commands 0/3 |
| two-region query again (changes and protection kept, no automatic retry) | REFUSED Busy (NoEligibleEviction 138 0 (Blockers {blockedEvicting = 0, blockedHandoff = 0, blockedDirty = 1, blockedHeld = 0, blockedInterest = 0, blockedJob = 0, blockedByRequest = 0})) | resident 338+0/1000  edit 64+0/192  staging 0+0/2048 | jobs 0/3 commands 0/3 |
| begin handoff again | HandoffStarted | resident 338+0/1000  edit 64+0/192  staging 64+0/2048 | jobs 0/3 commands 0/3 |
| handoff confirmed (no new edit allocation) | HandoffSettled | resident 338+0/1000  edit 64+0/192  staging 0+0/2048 | jobs 0/3 commands 0/3 |
| two-region query (the clean region is now the victim) | accepted jobs=[1,2] shared=0 victims=1 deferred=138 | resident 338+662/1000  edit 64+0/192  staging 320+516/2048 | jobs 0/3 commands 1/3 |
| owner discards the victim's detail | VictimFreed | resident 0+800/1000  edit 64+0/192  staging 320+516/2048 | jobs 0/3 commands 1/3 |

## E. Sustained foreground arrivals still allow an aged prefetch job to run (aging threshold 3)
dispatch order (job 0 is the prefetch job, queued first): [1,2,3,0]

What each shows:

- **A.** A job shared by two callers survives one caller canceling (the job and its
  whole reservation stay) and, when the last interest cancels while it is running, keeps
  its scratch and resident reservation until its completion is reported; the late
  result is dropped and publishes nothing. The three ledgers move separately: the
  resident bank only reserves, staging holds the interests and commands.
- **B.** A pinned region is never selected, nor are regions in use: the refusal names
  the pinned region (held), the two regions with open requests (interest) and the 112
  bytes still missing. A second pin over W is refused (338 pinned bytes are the most
  this bank lets holds take, leaving the 964 an explicit request may need unpinned).
  After the pin on X is released the same request is admitted with X committed as its
  victim, 288 bytes funded now and 112 when the victim's release arrives.
- **C.** Six regions down one column under a two-region bank: the resident bank never
  exceeds 964 bytes, each admission past the second commits the oldest region as its
  victim, and the last two regions remain.
- **D.** The removal reserves 64 edit bytes and 62 resident bytes for its rebuilt
  segment; the commit occupies the 64 edit bytes, returns the reservations and the
  command, and the changed region is protected under pressure (a two-region query
  needs 800 bytes of 662 free, and the only resident region is changed). A failed
  handoff loses nothing (the retained bytes, the changes and the protection are
  intact, and the model does not retry); a confirmed handoff changes no edit byte and
  makes the region the victim.
- **E.** With foreground arrivals before every dispatch, the prefetch job (job 0) is
  served fourth, after being passed over three times, ahead of the fourth arrival.

## Reconstruction after resident detail is discarded

`Test.Terrain.ResidencyCycle` plays the later terrain service over the real
TRA-2 `Source`, `Changes`, `Palette` and `Resident`, on a soil-over-stone source
whose soil reaches level 40, in a configuration of two columns and two levels per
region and two regions per query (a region stores at most 488 bytes and a job
beyond that reserves 288: the bank holds 1,552 at the least). Six cycles remove the
cells (0,0,0), (1,0,0), (0,0,1), (1,0,1), (0,0,32), (1,0,32). Each cycle reserves
and loads the cell, removes it with `removeCell`, stages the resident cell, commits
at the next revision with the real retained growth (64, 64, 0, 0, 16, 16: the second
level of each column joins the existing interval, level 32 starts another, each time
returning the unused part of the 64-byte reservation) and the real growth of the
rebuilt segment, hands the changes off, evicts the edited regions under pressure from
other demand (two queries of two fresh regions, 544 reserved bytes each; the real
detail of every victim is discarded), and reconstructs every cell removed so far from the source plus
the retained changes. After the reconstruction every removed cell is a known air value
in the resident detail, an unrequested cell stays unmaterialized and never air, and
every cell in a 3 x 1 x 40 box equals the independent naive model of
`Test.Terrain.Model`. At the end the model's retained bytes (160) equal
`changesBytes` of the real changes (two columns and two intervals each), and no
reservation or staging charge remains. After every
completion, commit and individual victim release the model's resident charge is
checked against the real detail: it is never less than 256 bytes for each resident
region plus the accounted payload, segment metadata and column entries the real
`Resident` holds.

Three further real-data examples cover the accounting the review rounds found
missing. A uniform 32-cell segment (2 bytes) of the stone region is edited in a
3,166-byte bank (the minimum for one 32-level region per query is 2,976), where eight
pinned regions and the segment leave 124 bytes: the removal reserves its 62 bytes of
growth, a second removal takes the other 62, a third is busy (nothing may be
evicted), the real rebuilt segment (three runs, 12 bytes) grows by 10, and the
commit charges exactly 10. Two vertical regions of one column share one real column
index entry; each is charged for its own column, and evicting the older region leaves
the survivor charged its own 338 bytes. And the accumulation the eighth review round
found: one 32-level column per region and the least bank the configuration allows
(2,976 bytes), sixteen separate queries load levels 0, 2, ..., 30, each completed with
the real net growth and withdrawn. The column entry is charged once, so the region
holds the 848 bytes the real detail needs (not a column entry for every job, which
reached 1,568), and the query for levels 1, 3, ..., 31 (one job of sixteen intervals,
1,584 reserved) is admitted with nothing evicted.

## Negative controls

Each protected behavior was broken once locally while keeping the scenario premise,
the focused suite (`Residency`, 94 to 112 examples) was run, and the mutation was
reverted without being committed (the implementation was committed first). Every
row failed at least the examples named. The controls of the retired state-dependent
feasibility computation, of the camera cap and of the job-slot reserve were removed
with them, and a stale-running-job branch in `failJob` and `completeJob` that no
transition can reach (a superseded running job becomes cancelling) was deleted rather
than controlled. Three protections are not controlled because they are redundant by
construction (the step gate is a backstop that valid events never reach, and the
camera staging share repeats what the admission checks of free staging enforce): a camera demand's own regions need no protection from camera eviction
(its own interest already blocks them), and the held-region bound in the invariants
repeats what hold acquisition enforces.

| Mutation | Failing examples |
| --- | --- |
| Eviction ignores holds | the held-region skip and pinned-region refusal examples, the random properties |
| Eviction ignores unsettled changes | the changed-region refusal and failed-handoff examples, the random property |
| Handoff protection dropped | the handoff-protection example |
| A job is cancelled when any caller withdraws | the coverage-growth, own-column, shared-victim and superseded-job examples (9 in all) |
| Aging disabled | the aging example |
| Retained-edit exhaustion not checked | the retained-bound and arena-retirement examples, the long random sequence |
| Stored cost not reconciled with the reservation | the contract-failure example |
| A cancelled job publishes its late result | the cancellation and retirement examples |
| A released victim does not fund the waiting job | the funded-eviction and turnover examples (14 in all) |
| Zero limits accepted | the limit-validation examples |
| Eviction ignores every interest | the shortfall, resident-busy, rollback and zoom-out examples (10 in all) |
| A victim's credit promised twice | the shared-victim example and the random properties |
| The validated-limits constructor exported | the external-client constructor examples |
| Payload reserved per cell instead of the dense bound | 33 ledger, reconciliation, boundary and growth examples |
| A job does not reserve its columns | 35 examples, including the largest-request boundary |
| No resident growth reserved for a removal | the edit-reservation, growth-contract and compressed-segment examples (9) |
| An older handoff clears newer changes | the handoff-interleaving example |
| An obsolete camera interest survives a busy replacement | the busy-replacement example and a random property |
| Unsupported region keys accepted | the region-boundary examples |
| A removal commit does not add the rebuilt segment growth | the growth-contract and compressed-segment examples |
| Retirement settles with a victim release outstanding | the cross-arena retirement example and a random property |
| A successful replacement drops its cancellation lists | the same-region replacement report example |
| A commit does not report the changed region's jobs | the commit-report example |
| A failure does not report the jobs it leaves unneeded | the failure-report example |
| A superseded running job is not cancelling | the late-failure and acknowledgement-after-commit examples |
| Camera admission skips past a busy region | the in-order example |
| Service skips past a busy region | the in-order example (service quantum) |
| A job-slot refusal off by one | 12 bank and slot examples |
| A request may evict the regions it names | the names-a-region example |
| A staging shortfall off by one byte | the bank-full and retained-bound examples (7) |
| The oldest evictable region is never a victim | 21 least-recently-used and funded-eviction examples |
| The resident minimum ignores a region at its stored maximum | the defaults, below-minimum and largest-request examples, the minimum property |
| The extent is not enforced | the over-cap example and the over-cap property |
| An oversized handoff duplicate is accepted | the handoff-duplicate example |
| Camera interests protect a region from an explicit request | the zoom-out example and the explicit-with-camera properties (5) |
| An evicted region keeps its camera interest | the zoom-out example and the properties (5) |
| Camera work ignores the staging headroom | the staging-headroom examples |
| A camera description ignores the staging headroom | the truncation example |
| A region is charged the columns each job reports | the own-column example and the incremental real-data regression |
| The stored maximum of a region is not enforced | the completion-past-the-maximum example |
| Pinned bytes are not bounded | the re-pinning example |
| A hold draws on the explicit staging headroom | the hold example |
| A load-job slot is taken at admission | the 257-region column, the job-slot and camera examples (9) |
| Dispatch ignores the load-job slots | the 257-region column and job-slot examples (4) |
| A hold is not bounded by its region cap | the hold-cap example |
| Job reservations inside held regions are not charged to the camera | the widening examples (2) |
| A removal commit is not held to the charge rules | the removal-growth example |
| A completion is not held to the charge rules | the completion-past-the-maximum example |
| The stored maximum is not a charge rule | the removal-growth and completion examples |
| Camera admission is not tested against the state it would produce | the camera examples (6) |
| Camera jobs in flight are not kept within the room explicit work leaves | the re-admission, zoom-out, partial-admission and widening examples (5) |
| A held region is charged what it holds now, not its stored maximum | the widening example and two random properties (4) |
| The camera unit is left out of the resident minimum | the re-admission example (1,025 refused) and the minimum property (1) |
| The largest hold is left out of the resident minimum | the defaults, below-minimum and hold examples and the minimum property (4) |
| A camera description is not cut to the staging it may use | the truncation example and two random properties |
| A camera description is not left room for its first region to start | the minimum-budget example and the starts-what-it-keeps property |
| A camera description is not cut to its structural maximum | the structural-maximum example |
| Repeated camera keys are not coalesced | the normalization example |
| Cells outside the extent are not clipped from a camera description | the normalization and over-cap examples |
| An empty camera description is kept as the demand | the normalization and over-cap examples |

### Randomized properties

`Test.Terrain.ResidencyProperty` drives 22 kinds of event (open, retire, query,
removal, camera replacement and clear, withdraw, service, dispatch, complete, fail,
acknowledge, commit, hold, release, handoff start/confirm/fail, victim release, and
a targeted "advance an edit" step) chosen from random integers against the model's
current state, so most are valid and some are deliberately wrong. After every
step it checks: a refusal returned the model unchanged; the invariants; every bank
recomputed from the model's records; no bank over its limit; retained edits never
decrease; a changed region is not lost without a handoff; the owner can perform
every action the model has asked of it (each accepted); and every explicit query
and removal was answered in the class the brute-force oracle says. At the end of
each run, performing the owner's actions leaves no job, victim, hold, retiring
arena or reserved byte. It runs 200 random sequences of 250 events, a 12,000-event
fixed sequence under tight budgets, a 12,000-event fixed sequence under room for
concurrent work (where commits meet queued and running jobs of their region), and
the properties of the amendment below. The fixed sequences assert workload floors
so that a degenerate generator fails.

### Brute-force admission oracle

`Test.Terrain.ResidencyOracle` re-derives the class of every explicit admission
decision from the model's observations alone and the contract's charge table
restated by hand, and the random sequences compare it with the model at every query
and removal: __admitted__ exactly when every slot and bank has room and the resident
shortfall can be covered by some set of regions nothing needs, found by trying every
subset of them rather than the model's least-recently-used walk (a camera view's
interest in a region does not protect it from an explicit request); __busy__ otherwise;
__exhausted__ for a removal the retained-edit bank cannot take; and never invalid,
because the configuration was validated against the worst-case footprint (a model
answer of invalid for a well-formed request within its caps is a mismatch). In the
fixed sequences it checked 141 admitted, 1,080 busy and 652 exhausted decisions under
tight budgets and 192 admitted and 1,597 busy under room for concurrent work, and never disagreed with the model.

### Capacity by configuration for explicit requests; camera demand best effort (owner amendments and the approved clarifications, rounds 8 to 10)

Rounds 2 to 7 kept finding errors in a state-dependent decision of whether a request
could ever fit. The owner's amendment of #639 (issue comment 6709464089) removed the
decision for explicit requests: every admissible explicit request has a bounded size
validated from the request alone, and `mkLimits` validates that each bank holds the
worst-case footprint of the largest one of every kind, so such a request is never
invalid for capacity and every shortage is busy. Amendment 2 (comment 6710245034)
made camera demand best effort and raised the defaults to 256 MiB resident, 64 MiB
edits and 128 MiB staging, after the camera's approved envelope (zoom 0.125, a
3840 x 2160 display, a 250-level band and one-chunk prefetch: about 283,700 columns,
1,247 horizontal and up to about 11,200 regions) was shown to exceed any cap that
passes the minimum-budget rule at 64 MiB. The approved issue-review clarifications
(comments 6709544560 and 6710349797) fix how: the load-job slot is taken at dispatch
so the approved 8,192-level column (257 regions) fits the unchanged 128 slots; the
worst case is computed from the same charge rule admission reserves; holds, pins and
handoff duplicates have static bounds; camera holdings cannot starve explicit work,
including through pins that are released and re-acquired and camera jobs that are
re-admitted; camera descriptions are normalized and truncated in priority order
instead of refused. The mechanism is a partition of each bank into an explicit reserve
(the explicit worst case) and a camera share (the rest): every camera-originated
reservation (jobs, interests, pins and borrows, staging) draws only on the share and is
refused (busy) at admission when it would not fit. In the resident bank the camera side
keeps out of explicit reach each held region at its stored maximum plus the detail and
reservations of regions with a job only views need, within the bank less the explicit
minimum; the configuration check requires the share to hold the largest single camera
unit (the largest hold, or one region's camera job), so the camera can always make
progress and a configuration that cannot is refused at construction. The properties and examples:

- **In-cap requests are never invalid, in any state** (300 random states reached by
  the event sequences; a query, a removal and a camera demand each).
- **Busy ends when the releasable is released** (300 random states): after the
  owner finishes every job, releases every victim and hold, confirms every handoff
  (beginning those not yet begun), and withdraws every request and camera demand, the
  same in-cap query and removal are admitted at once; a removal may still find
  retained edits exhausted, which is unchanged.
- **Explicit requests are not blocked by any camera activity** (300 random states): with
  every camera demand, pin, interest and undispatched camera job left exactly as the
  sequence left them, once the explicit-only work has drained (requests withdrawn, running
  jobs finished, victims released, changed regions offloaded) an in-cap query or removal
  is admitted at once.
- **One charge function, checked after every step** (random sequences of load, complete,
  pin, unpin, camera expansion, withdraw, removal, handoff and eviction): under the
  three fixed profiles, 200 random sequences, 300 sequences under random budgets from
  exactly the minimum (4,384 resident, 1,530 staging) upward, and one 12,000-event
  sequence at exactly the minimum, `modelInvariants` (which is `chargeCheck` plus the
  structural checks) holds after every event.
- **Reservations inside a held region** (example, extent 1 x 1 x 32, 5,952 resident
  bytes): widening a pinned region one level at a time never lets the reservations in
  flight exceed the 1,584 the camera share has left, the charge rules hold at every step,
  and an explicit query for sixteen separate intervals is admitted.
- **A removal commit past the stored maximum** (example, extent 1 x 1 x 2): growth that
  would take a region to 400 where 372 is the most is a contract failure before anything
  changes; growth of 34 is accepted.
- **Reservation within the worst case** (2,000 random queries and removals into a
  model that holds nothing): the resident and staging bytes admission reserves never
  exceed the explicit minimum the construction check assumed.
- **Over-cap requests are invalid from every state** with a typed reason (200 random
  states): a third region, a cell above the extent or beyond its columns.
- **Configurations below the minimum are refused at construction** exactly when a
  bank falls short (5,000 random configurations, the minimum restated by hand in the
  test), naming the bank, the bytes needed and the bytes configured, and at the exact
  byte in the examples (963 and 964 resident, 1,249 and 1,250 staging, 63 and 64 edit,
  2,863 and 2,864 for the extent 2 x 1 x 6).
- **A camera demand completes when it is alone** and the camera's share of the banks
  holds it, under random banks and leftover resident regions (2,000 random cases).
- **The largest request fits** (example): the least bank admits two regions that
  already hold two queries' worth of detail plus the largest job beyond it with no
  victim.
- **The 8,192-level column** (example, at the default limits): 257 regions, the first
  and last partial, are admitted whole; 128 jobs run at once, the rest wait queued,
  and one completion frees one slot; 258 regions are invalid from every state.
- **Zoom-out sized camera demand** (example): 40 regions against a bank that holds
  two are admitted two at a time, nearest first, nothing refused or reserved for the
  rest; an explicit query for two other regions takes both of the camera's regions as
  victims and the view's demand for them is pending again; once the explicit work
  lets go the camera resumes nearest first, and panning on moves it to the next
  regions as the old interests are released.
- **Re-pinning cannot starve explicit work** (example): a camera view fills a 1,664-byte
  bank and keeps two pins (a held region is charged 338, its stored maximum), a third
  is busy, and each of four quanta in which the view releases a pin and re-pins another
  region an explicit two-region query arrives and is admitted at once.
- **Re-admitted camera jobs cannot starve explicit work** (example): at a bank of 944
  bytes the camera may have 400 in flight; five rounds in which the camera moves to a
  fresh region while an explicit query arrives each admit the query, and at exactly the
  explicit minimum (544) the camera is never admitted.
- **A pinned region that grows** (example, extent 16 x 1 x 1): two held regions are
  charged their stored maximum (1,568 each); widening both from one cell to the whole
  region is refused, so the pinned total cannot grow, and an explicit full-region query
  is admitted. The model's invariants include the held-region bound.
- **A hold the configuration allows fits** (example): the resident minimum includes the
  hold (544 + 338 = 882 refused at 881), and the one-region hold is acquired.
- **Camera headroom** (example): of 1,636 staging bytes the camera uses at most 642
  and the 994 a removal needs stay free; a hold draws on the camera's share, not the
  headroom.
- **A retained description can start** (example at the minimum budgets, 1,446 resident
  and 1,508 staging bytes, and a property over 2,000 random descriptions at any staging
  from the minimum): the camera's staging share of 514 holds one region (192 of
  description, 64 of interest, 258 of scratch) but not a two-region description (256)
  beside the first job, so it is cut to one region, the other reported, and the first is
  admitted at once; whatever description is retained has its first region admitted.
- **Normalized descriptions** (examples): an empty description withdraws the demand,
  repeated keys coalesce into the first occurrence, an unsupported key and a region
  wholly outside the extent are excluded and reported while the valid entries are
  served; a description longer than its structural maximum, or than the staging the
  camera may use, is cut at the lowest-priority end and the remainder reported.
- **Accumulated charge** (real-data example): sixteen separate jobs in one column
  leave the region at the 848 bytes the real detail needs, and a completion past the
  stored maximum is a contract failure.
- **The camera bookkeeping**: a replacement that retains the interest of a later
  region (the review's second round-7 finding) counts that interest in the staging
  the camera may use; with 1,636 staging bytes (994 of them kept for explicit work) it
  is accepted and completes instead of stalling.

The defaults record: a region stores at most 291,072 bytes (every cell its own
segment) and its largest job reserves 405,504 more, so a 257-region query needs
179,020,032 of 268,435,456 resident bytes, and the largest hold (256 regions at
their stored maximum) adds 74,514,432: 253,534,464 in all; the explicit staging worst
case is 4,301,280 of 134,217,728 bytes, plus 16,384 for the records of the largest hold;
a removal needs 64 of 67,108,864 edit bytes; a query needs one of the 128 load-job
slots.
