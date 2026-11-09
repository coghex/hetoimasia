# TRA-20 evidence: the temporary store's pure model

Implementation head `560c3c78` (the branch is merged with origin/master at `8f44876e` with no source change; issue #662, PR #675 for `Closes #662`). Every figure below is the output of one suite run, not a paraphrase; the suite is `hetoimasia-terrain-runtime:terrain-runtime-tests` and these are observations of the pure model and the codec. **They are not physical filesystem, durability, preallocation, latency or RSS figures**, and none is proof of live request settlement or crash recovery.

## Commands

```sh
export PATH=$HOME/.cache/hetoimasia/toolchain/ghc-9.14.1/bin:$PATH
ghc --numeric-version    # 9.14.1
cabal --numeric-version  # 3.18.1.0
cabal test --project-file cabal.project.cpu hetoimasia-terrain-runtime:terrain-runtime-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-terrain:terrain-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-terrain-render-2d:terrain-render-2d-tests --test-show-details=direct
# this document's tables: the evidence printer alone
$(cabal list-bin --project-file cabal.project.cpu hetoimasia-terrain-runtime:terrain-runtime-tests) --match "TRA-20 evidence"
```

Results: `terrain-runtime-tests` 373 examples, 0 failures; `terrain-tests` 901/0; `terrain-render-2d-tests` 649/0.

## Fixtures, seeds and references

- **Reference map and independent traversal.** `Test.TerrainRuntime.Store.Reference` holds a bitwise CRC32C, a page parser written from the documented layout, and a traversal that decides, from the disk's bytes alone, which pages are live, retired, free or loose, that they partition `[0, hw)` exactly (so freeing a page a root still reaches fails the partition, not a count), that every tree is ordered, bounded by its parents' separators and at least a quarter full, and that the store's counters equal what it found.
- **Generated histories** (`Test.TerrainRuntime.Store.Workload`/`Trees`): seeds 11, 29 and 47 (400 steps, up to 30 writes each), seed 5 (grow then delete in random order), seeds 101/202/303 (450-step cycles), seed 2024 (fault fixture), seed 77 (readers), seed 5 (exhaustion). Every sequence is a `Rng` seed in the example name, so a failure replays by seed.
- **#661 replay** (`Scenes`/`Replay`): the `two openings` scene (a cave along X with a side branch under a sky at level 8), batch sizes 64 and 1, and a sealed stack; the store plans each removal and batch through pages and the reference `Retained` applies the same candidate.
- **Independent bytes**: iSCSI CRC32C vectors, hand-built pages for every record kind, and each header and entry field wrong in turn with a recomputed valid checksum (`Test.TerrainRuntime.Store.Codec`).

## Measurements (evidence printer output)

```text
EVIDENCE trees seed=11 steps=400 records=1587 commits=400 totalPageWrites=5038 maxPagesPerTransaction=23 maxRam=737187 maxWindowPages=23 maxReadSteps=140 maxClaim=71
EVIDENCE trees seed=11 heights=[(TreeRuns,2),(TreeLinks,2),(TreeTodo,2),(TreeFree,0),(TreeRetire,2)] live=431 retired=3999 free=0 loose=68 highWater=4498 violations=0
EVIDENCE trees seed=29 steps=400 records=1581 commits=400 totalPageWrites=4986 maxPagesPerTransaction=25 maxRam=755783 maxWindowPages=24 maxReadSteps=142 maxClaim=70
EVIDENCE trees seed=29 heights=[(TreeRuns,2),(TreeLinks,2),(TreeTodo,2),(TreeFree,0),(TreeRetire,2)] live=429 retired=3947 free=0 loose=68 highWater=4444 violations=0
EVIDENCE trees seed=47 steps=400 records=1621 commits=400 totalPageWrites=5134 maxPagesPerTransaction=24 maxRam=749594 maxWindowPages=25 maxReadSteps=136 maxClaim=70
EVIDENCE trees seed=47 heights=[(TreeRuns,2),(TreeLinks,2),(TreeTodo,2),(TreeFree,0),(TreeRetire,2)] live=432 retired=4090 free=0 loose=68 highWater=4590 violations=0
EVIDENCE growAndShrink seed=5 runsTreeHeightAtPeak=3 rootAfterDeletingEverything=empty
EVIDENCE bounds history=20000runs exactPlan pages=256 bytes=1048576 recordPages=254 listPages=1 bookkeepingPages=1 replacedRecordPages=254 replacedBookkeepingPages=1 slack=67 claimed=255 windowPages=255 readSteps=1490 ramTotal=3213404
EVIDENCE bounds onePastPages=257 refused=TxnPagesExceeded
EVIDENCE bounds worstTransactionRam io=1048576 decoded=2388992 keys=24960 scratch=491872 pagePins=8192 rootControl=1152 continuation=5120 total=3968864 limit=4194304
EVIDENCE bounds format maxLevel=7 worstUpdatePagesAtMaxHeight=17 bookkeepingReserve=68 maxClaimPages=324 minimumRemovalPages=188 minimumRemovalRam=3654510
EVIDENCE replay twoOpenings batch=1 pendingAfterFirstBatch=3 drainBatches=35 plans=42 maxStructuralUpdates=1 maxPagesPerTransaction=4 pendingAtEnd=0
EVIDENCE fault fixture pages=12 prefixes=13 oldRootIntactInEvery=True rollbackWrites=0 usageRestored=True
EVIDENCE readers pinnedVersions=[40,65] retiredBytesWhileHeld=4599808 oldestPin=Just 40
EVIDENCE readers reclaimedBeforeThePin transactions=39 retiredBytesStillHeld=3600384
EVIDENCE readers reclaimOutcomeWhileHeld=BlockedByReader entry=41 pin=40
EVIDENCE readers afterLastRelease reclaimTransactions=65 retiredBytes=0 maxPagesPerTransaction=20 totalPagesFreed=1123
EVIDENCE exhaustion tight=64MiB allowance, 48MiB overhead commits=124 refusal=Capacity (DiskFull 324 2359 2048)
EVIDENCE exhaustion at refusal allowance=67108864 used=57446400 live=602112 staged=0 retired(pending reclaim)=6234112 loose=278528 free=9662464 protected=8388608 available=1273856 readers=0 pinnedVersions=0
EVIDENCE exhaustion after 123 reclaim transactions allowance=67108864 used=51236864 live=98304 staged=0 retired(pending reclaim)=0 loose=806912 free=15872000 protected=8388608 available=7483392 readers=0 pinnedVersions=0
EVIDENCE exhaustion maxPagesPerTransaction=21 totalPagesFreed=1522
EVIDENCE cycles CycleReport {crSeed = 101, crCommits = 186, crAborts = 52, crFailedWrites = 24, crReads = 57, crReclaims = 36, crMaxReaders = 6, crMaxPages = 18, crMaxWindow = 17, crMaxRam = 671959, crMaxSteps = 136, crPagesWritten = 2402, crHighWater = 1402, crRecords = 893}
EVIDENCE cycles CycleReport {crSeed = 202, crCommits = 177, crAborts = 50, crFailedWrites = 22, crReads = 51, crReclaims = 37, crMaxReaders = 6, crMaxPages = 19, crMaxWindow = 19, crMaxRam = 684291, crMaxSteps = 114, crPagesWritten = 2378, crHighWater = 1424, crRecords = 914}
EVIDENCE cycles CycleReport {crSeed = 303, crCommits = 194, crAborts = 49, crFailedWrites = 28, crReads = 24, crReclaims = 42, crMaxReaders = 5, crMaxPages = 19, crMaxWindow = 18, crMaxRam = 682100, crMaxSteps = 110, crPagesWritten = 2546, crHighWater = 1465, crRecords = 921}
EVIDENCE allocation a one-record edit plan history500runs=437008B history20000runs=941096B ratio=2.1534983341266063
EVIDENCE allocation a pinned point read history500runs=131864B history20000runs=229824B ratio=1.7428866104471274
EVIDENCE allocation a usage and control report history500runs=1232B history20000runs=1232B ratio=1.0
EVIDENCE allocation a reclamation step over an equal retirement list history500runs=154968B history20000runs=148192B ratio=0.956274843838728
EVIDENCE allocation control: a map of every record key history500runs=35304B history20000runs=1361640B ratio=38.569000679809655
```

Reading the lines: `maxPagesPerTransaction` is the most encoded pages one plan wrote, metadata included (the bound is 256, 1 MiB); `maxRam` is the largest RAM a plan reserved, by component (the bound is 4 MiB; `worstTransactionRam` is the worst case at the format's bounds); `maxWindowPages` the most validated page buffers a plan held (the window is bounded to 1,310,720 accounted bytes, about 310 pages, at 4,224 bytes a page); `maxReadSteps` the most node visits a plan made; `maxClaim` the most pages taken from the allocator; `exactPlan` the plan that wrote exactly 256 pages and `onePastPages` the page count one more write needs (refused as `TxnPagesExceeded`); `maxStructuralUpdates` the most structural updates a discovery batch performed (bound 64); `used/live/staged/retired/loose/free/protected/available` the usage identities of `usage` (`used + free = allowance`; retired pages, the pending reclaim, are a subset of used); `allocation ... ratio` the bytes one forced computation allocated at a history forty times larger over a small one (the `control` row, a map of every record key, shows the measurement would notice a history-sized structure: its ratio is about 40).

## Required cases to results

| Case | Where | Result |
| --- | --- | --- |
| every prefix of a multi-page write sequence then failure, cancellation or a provider that writes no more; rollback needs no write | `Faults` (three modes over every prefix of a 12-page plan), evidence `fault fixture` | old root, usage, records and pages intact in all 13 prefixes; `rollbackWrites=0` |
| a fully written, unpublished candidate abandoned; duplicate, late and foreign outcomes; late cancellation after publication | `Faults` | roots unchanged; `Unknown`/`Duplicate` results change nothing |
| several pinned old roots across later updates and cache eviction, shared pages, reclaim only after the last reader, reuse, stale tokens | `Readers`, evidence `readers` | pinned versions 40 and 65 answer from their own records; reclamation stops at the first entry newer than the oldest pin and runs after the last release; a released token reads nothing |
| full allowance with retired pages, ordinary space exhausted with the 8 MiB reserve intact, delayed-reader release then incremental reclaim | `Allowance`, evidence `exhaustion` | ordinary history refused (`DiskFull 324 2359 2048`) with `protected=8388608`; reclamation spends the reserve; ordinary history resumes |
| exact and one-past 256 pages, 64 updates, 512 window pages, 4 MiB RAM, checked path reservations, minimum removal | `Bounds`, evidence `bounds` | exactly 256 pages met, 257 refused; 65 updates refused; 513 pages refused; `minimumRemovalPages=188`, `minimumRemovalRam=3017742` |
| growth: pending, confirmed, failed, equal no-op, refused shrink, release, integrity not cleared | `Allowance` | the old allowance until commit; pending extra reservation accounted until released; only the capacity pause clears |
| repeated update, abort, publish, read, reclaim cycles; replay of #661 incl. two openings and a pending continuation; caches dropped | `Cycles`, `Replay`, evidence `cycles`, `replay` | three seeds, every pinned reader exact, partition holds, `pendingAfterFirstBatch=3` carried between openings, `pendingAtEnd=0` |
| range reads and exact lookups across leaves | `Readers` | from/after a key, cut at 256, empty past the end, absence confirmed |
| independent codec, CRC and refusal matrix | `Codec` | every field wrong in turn with a valid checksum refused with its own error; every single bit flip refused as `BadChecksum` |
| edit-bank division, all-or-nothing credits, backed-only eviction, protected staging, no circular wait | `AdmissionSpec` | see the suite |
| external client | `Boundary` | one accepted client runs; constructors, record updates and private modules refused |

## Negative controls (mutation applied locally to the library, never committed; file restored)

First round of the implementation:

| Protected behavior broken | Result |
| --- | --- |
| ordinary history may spend the protected reserve | 3 of 365 examples fail |

Three of these were first not caught (a freed page freed twice, spending the protected reserve, committing growth before the reservation was reported); a test was added for the first, the reserve mutation was widened to all three of its checks and the growth mutation rewritten. Each is caught in the final suite.

After review round 1 (the six repairs):

| Protected behavior broken | Result |
| --- | --- |
| the discovery header's retained-history bytes are charged as resident memory | 1 of 371 examples fail |
| a window of another store is accepted (planning and reads) | 1 of 371 examples fail |
| a window of another store is accepted by readers | 1 of 371 examples fail |
| a transaction token ignores its store | 1 of 371 examples fail |
| a floor suspension is resolved as an exact lookup only | 1 of 371 examples fail |
| credit sums wrap as Word64 | 1 of 371 examples fail |
| the window's accounted bytes are not bounded | 1 of 371 examples fail |

After review round 2 (the three repairs):

| Protected behavior broken | Result |
| --- | --- |
| a page named by a retirement entry may already be free, loose or claimed by the plan | 1 of 373 examples fail |
| rebalancing loads its siblings without their separator bounds | 1 of 373 examples fail |
| an output page's number keeps its whole parsed page alive | 1 of 373 examples fail |

## Limits of this evidence

The model is checked against references written independently of it, at routine scale. Nothing here measures a file, a filesystem, an fsync, a descriptor, a worker, latency or process memory (TRA-21), the live owner's publication and request settlement (TRA-22) or the Lua control (TRA-23). The memory figures are the accounted bytes of the representation (validated page buffers, packed new pages, a few parsed nodes), checked against the live heap of a window of 310 dense pages (`holds a window of dense pages in memory close to what it accounts`); they are not a process-RSS claim. The tree height bound (8 levels) is shown unreachable below about 36 GiB of leaves by the derivation in `Format.maxLevel`, not by building a 36 GiB store.

## Review round 1 (Codex, CHANGES_REQUESTED at `9fd9fbf9`)

Six findings, all valid and repaired in `12fad45f`: the discovery header's retained-history byte total was charged as transaction memory (now its fixed record size; `does not charge the retained history's size...`); windows were bound to a version but not to a store (now identity and version are checked at every read and plan entry; `refuses a window of another arena or version...`); transaction tokens carried a bare serial (now the store; `binds a transaction token to its store...`); a floor lookup suspended on a deleted separator named no page (now resolved with the same lookup kind; `names the previous leaf...`); decoded pages were accounted as 4 KiB plus 256 bytes (a decoded leaf is a pointer structure; windows now keep validated buffers and the plan's new pages are held packed, both with byte budgets, and the live-heap check above); and credit sums could wrap (now totals in `Integer`; `checked credit arithmetic`).

## Review round 2 (Codex, CHANGES_REQUESTED at `84ae4eff`)

Three findings, all valid and repaired in `560c3c78`: output pages were assembled as parsed pages and encoded lazily, so a returned plan retained every parsed page through the lazy page number of each output pair (a dense 180-leaf plan held 3.9 MB while reporting 2.8 MB; pages are now numbered, encoded and forced one at a time, and `holds a dense 180-leaf plan within the RAM it reports...` measures the live heap); a retirement list could name a page that was free, loose or consumed by the same plan's supply, which the free-extent insertion could not see (the pages are now checked before the supply is consumed; `refuses to free a page that is already free, loose or claimed...`); and rebalancing loaded its siblings without their parent's separator bounds, so a malformed sibling could be merged into a page `decodePage` rejects (`refuses a sibling whose keys break its parent's separators...`).
