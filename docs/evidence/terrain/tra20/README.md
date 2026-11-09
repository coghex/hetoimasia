# TRA-20 evidence: the temporary store's pure model

Implementation head `64a8ed36` (issue #662, PR #675 for `Closes #662`). Every figure below is the output of one suite run, not a paraphrase; the suite is `hetoimasia-terrain-runtime:terrain-runtime-tests` and these are observations of the pure model and the codec. **They are not physical filesystem, durability, preallocation, latency or RSS figures**, and none is proof of live request settlement or crash recovery.

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

Results: `terrain-runtime-tests` 379 examples, 0 failures; `terrain-tests` 901/0; `terrain-render-2d-tests` 649/0.

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
EVIDENCE allocation a one-record edit plan history500runs=451328B history20000runs=983728B ratio=2.179629892229155
EVIDENCE allocation a pinned point read history500runs=136848B history20000runs=229824B ratio=1.6794107330761137
EVIDENCE allocation a usage and control report history500runs=1232B history20000runs=1232B ratio=1.0
EVIDENCE allocation a reclamation step over an equal retirement list history500runs=472328B history20000runs=466496B ratio=0.9876526481597534
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

After review round 3 (the two repairs):

| Protected behavior broken | Result |
| --- | --- |
| root collapse follows single children without level or bounds checks | 1 of 375 examples fail |
| a run node's level is not range-checked | 1 of 375 examples fail |

After the round 4 sweep (the allocator's supply):

| Protected behavior broken | Result |
| --- | --- |
| a free extent may reach past the used page space | 1 of 376 examples fail |
| a loose page may lie outside the used page space | 1 of 376 examples fail |
| a page may be handed out twice by one supply | 1 of 376 examples fail |

After review round 4 (the three repairs):

| Protected behavior broken | Result |
| --- | --- |
| reclamation frees a page the committed trees still reach | 1 of 379 examples fail |
| a shrink is classified by building a replacement configuration first | 1 of 379 examples fail |
| a cache entry may be charged less than its own record | 1 of 379 examples fail |
| a grant may be charged less than its own record | 1 of 379 examples fail |

## Limits of this evidence

The model is checked against references written independently of it, at routine scale. Nothing here measures a file, a filesystem, an fsync, a descriptor, a worker, latency or process memory (TRA-21), the live owner's publication and request settlement (TRA-22) or the Lua control (TRA-23). The memory figures are the accounted bytes of the representation (validated page buffers, packed new pages, a few parsed nodes), checked against the live heap of a window of 310 dense pages (`holds a window of dense pages in memory close to what it accounts`); they are not a process-RSS claim. The tree height bound (8 levels) is shown unreachable below about 36 GiB of leaves by the derivation in `Format.maxLevel`, not by building a 36 GiB store.

## Review round 1 (Codex, CHANGES_REQUESTED at `9fd9fbf9`)

Six findings, all valid and repaired in `12fad45f`: the discovery header's retained-history byte total was charged as transaction memory (now its fixed record size; `does not charge the retained history's size...`); windows were bound to a version but not to a store (now identity and version are checked at every read and plan entry; `refuses a window of another arena or version...`); transaction tokens carried a bare serial (now the store; `binds a transaction token to its store...`); a floor lookup suspended on a deleted separator named no page (now resolved with the same lookup kind; `names the previous leaf...`); decoded pages were accounted as 4 KiB plus 256 bytes (a decoded leaf is a pointer structure; windows now keep validated buffers and the plan's new pages are held packed, both with byte budgets, and the live-heap check above); and credit sums could wrap (now totals in `Integer`; `checked credit arithmetic`).

## Review round 2 (Codex, CHANGES_REQUESTED at `84ae4eff`)

Three findings, all valid and repaired in `560c3c78`: output pages were assembled as parsed pages and encoded lazily, so a returned plan retained every parsed page through the lazy page number of each output pair (a dense 180-leaf plan held 3.9 MB while reporting 2.8 MB; pages are now numbered, encoded and forced one at a time, and `holds a dense 180-leaf plan within the RAM it reports...` measures the live heap); a retirement list could name a page that was free, loose or consumed by the same plan's supply, which the free-extent insertion could not see (the pages are now checked before the supply is consumed; `refuses to free a page that is already free, loose or claimed...`); and rebalancing loaded its siblings without their parent's separator bounds, so a malformed sibling could be merged into a page `decodePage` rejects (`refuses a sibling whose keys break its parent's separators...`).

## Review round 3 (Codex, CHANGES_REQUESTED at `8f44876e`)

Two findings, both valid and repaired in `d5f50cc5` and `7f179551`: the root collapse after a deletion followed single-child nodes with an unchecked load, so a malformed subtree containing a cycle never terminated (the collapse now carries the expected level, one lower per step, and the inherited separator bounds; `refuses a root collapse that would follow a cycle or a child of the wrong level` fails instead of hanging under a wall-clock guard if the cycle is followed again); and a run node's level was accepted for any `Int64`, in link keys and in parent values (now `levelMin <= lo < levelMaxExclusive`, with boundary and out-of-range fixtures for both: `refuses a run node whose level is outside the supported coordinate range...`).

## Round 4 sweep (before the fourth review)

Rounds 1-3 kept finding one class: a value read from an untrusted page used without a range, level or cycle check. Before round 4 every bounded loop and every node, level, index and page-number read in the store model was walked (`Tree.hs` descents, collapse, rebalance, range and successor reads; `Plan.hs` supply, overlap, free-extent insertion and reclamation; `Page.hs` and `Records.hs` decoders; `Model.hs` readers). Every tree descent now carries its expected level and its parent's separator bounds, and a bounded range read is clamped to 256 records. The sweep found one more site: the allocator's supply decoded free extents against the whole page space instead of the used space and trusted the free tree and the loose list to be disjoint, so a valid-checksum free-extent page reaching past the high-water mark, an overlapping extent or a page both loose and free could be handed out twice. The supply now refuses each as `Integrity` (`refuses a supply that names a page outside the used space...`, three scenarios), and a free neighbour that does not decode is corruption rather than absence (unreachable behind the page decoder's validation; defense in depth, no example). Each check has a negative control above except the overlap-with-previous-extent condition, which the distinct-supply check backs (a cross-leaf overlap needs a two-leaf free tree).

## Review round 4 (Codex, CHANGES_REQUESTED at `1e1f85d2`)

Three findings, all valid, repaired in `64a8ed36`: reclamation freed any page a retirement entry named that was not free, loose or claimed, so a valid-checksum entry naming a live root made authoritative data reusable (now each candidate must lie inside the used space, be a tree page and not be the page the committed tree of its header reaches on the path of its first key, checked by `livePageAt` through the window; `refuses to reclaim a page the committed trees still reach...` covers the runs root, a live page below it, the free tree's root and the retirement tree's root, and a loose or list page is refused as well); cache credits of zero or a few bytes were granted while allocating an entry and map node each (every cache entry is now charged at least a page, every grant at least 128 bytes in the staging and control accounts); a shrink with large configured overhead was classified `GrowthInvalid (OverheadInvalid ..)` because the replacement configuration was built first (the size rules now come first, and a replacement is built only for an increase).

## Review round 5 (Codex, CHANGES_REQUESTED at `af881bd6`)

Two findings, both valid: a forged free extent naming the committed runs root (re-sealed, valid checksum) was accepted by `takeSupply`, so a plan wrote that page while it was a live root and an abort could not preserve it; and reclamation's liveness check covered only the current roots and trusted the retirement entry's version, so pinning version 1, publishing 2 and lowering the entry's version to 1 freed a page the reader still read, which was later reused (the reader then got `BadPage KindMismatch`). Round 5 was the last the issue allowed; the owner granted rounds 6 and 7 on the condition that the class be closed as a class.

## Round 6: the class-wide ownership proof (before the sixth review)

The manager's instruction: enumerate every site where the store trusts a persisted record about which pages are live, free, pinned or reclaimable, validate each against the live and pinned roots, and give each a tamper test with a forged record that passes its checksum plus a negative control. The sites and their guards are the table in the runtime README ("Ownership: what no persisted record is trusted for"). The design is one test at the one place a page is overwritten: every page a plan writes below the used space, and every page reclamation frees, is classified from a probe (never read into the window as a 4 KiB buffer) and looked for on the path of its first key in the committed tree and in each pinned reader's tree; a retirement list carries the version of its entry and is looked for under it; a reference at or past the used space is refused by every descent. `Test.TerrainRuntime.Store.Ownership` holds ten tamper tests; the runtime suite is 389 examples, 0 failures at the round-6 head.

Negative controls (a mutation applied locally to the library, never committed, file restored; the ownership tests, and for the second batch the retirement tests too, run against each):

| Mutation | Result |
| --- | --- |
| pinned roots are not consulted when proving a page unreachable | 2 failures (the pinned extent and the lowered version) |
| a candidate overwrites supplied pages without the proof | 4 failures (free extents, loose pages) |
| maintenance overwrites supplied pages without the proof | 1 failure (the maintenance variant) |
| reclamation checks a retired page against the committed roots only | 1 failure (lowered version past a pinned reader) |
| a list's stamp is not compared with its entry's version | 1 failure |
| a reference at or past the used space is followed | 2 failures (a root and a child past it) |
| a retirement list page past the used space is read | 1 failure |
| a loose page listed twice beyond the supply is accepted | 1 failure |
| a pinned read is not bounded by its version's used space | 1 failure |
| a retirement list page is never looked for under its version | 2 failures |
| an entry's count is not compared with its list | 1 failure |
| a page that is not a page of this store is treated as live | the suite aborts (its histories cannot be built); the false-refusal direction is also held by `overwrites a free page that holds garbage...` |
| a reachable tree page is never refused | 5 failures |
| the double-free overlap check is removed | 1 failure |
| a free extent past the used space is handed out | 1 failure |

Limits: the proof is bounded by the pages a plan writes (at most 256) times the pinned readers (at most 16) times the tree height, and a plan that cannot afford the extra window pages is refused with the typed window result, never accepted unproven. A record that is consistently forged across every record that mentions a page, including the committed trees themselves, cannot be told from the truth by any local check; what is guaranteed is that no single forged record, and no inconsistency between a record and the trees a reader can still reach, lets a plan overwrite or free such a page.


## Review round 6 (Codex, CHANGES_REQUESTED at `0f2da543`)

Two findings, both valid. A probe kept its key as a slice of the 4,096-byte page it was decoded from while `windowProbeBytes` accounted 160 bytes a probe and no bound counted probes: 1,200 valid pages through `addProbe` and `planRemoval` returned `Planned` reporting 683,673 bytes while the retained buffers alone were 4,915,200. And the supply accepted a record page that no committed or pinned root reached even when a retirement entry still owned it: a free record naming retired page 122 (the free-page count preserved, the roots unchanged) let the 49th later plan overwrite it, the publication then owned the page twice and the next maintenance failed with `RetiredPageLive`.

## Round 7: both closed as classes (before the seventh review)

*Memory.* Every `ByteString` that crosses a window, probe, overlay or plan boundary was audited: a window now copies the buffer it is given (a caller's buffer may be a slice of a large read), a probe copies its key, an overlay node is packed into a buffer of its own or is a parsed view of an accounted window page, and plan output and decoded records are fresh values. A probe is accounted at its measured retention (`probeBytes` 320; 500 probes read as slices of one large buffer held about 260 bytes each), a window may hold at most 512 probes (`ProbesExceeded`) and the worst-case RAM figures include them.

*Ownership.* The supply, loose and maintenance paths now go through one proof over every owner (committed trees, pinned trees, retirement lists, outstanding retirement entries, free extents for loose pages, the supply itself). What was missing was an index from a page to the retirement entry that owns it, which cannot be had by reading the entries (a long-held reader keeps hundreds of them): every retired page is now also recorded in the retirement tree under `0xFF` and its number, valued with its entry's version, so one bounded lookup answers it. A commit indexes what it replaced, reclamation frees a page only if the index holds it under that entry and removes it as it frees it, and the retired backlog is bounded (16,384 pages; an ordinary plan past it is refused until maintenance runs; maintenance is never refused). `Test.TerrainRuntime.Store.Ownership` holds 17 tamper examples with re-sealed records, one per owner class; the independent traversal (`Reference.ownership`) checks the index against the lists after every step of every suite.

The negative controls (a mutation applied locally to the library, never committed, file restored; the ownership, retirement and bound examples run against each) all fail the suite except where another layer refuses the same forgery first, which is recorded:

| Mutation | Result |
| --- | --- |
| pinned roots are not consulted when proving a page unreachable | 2 failures |
| a candidate overwrites supplied pages without the proof | 7 failures |
| maintenance overwrites supplied pages without the proof | 2 failures |
| reclamation checks a retired page against the committed roots only | 1 failure |
| a retirement list's stamp is not compared with its entry's version | 1 failure |
| a reference at or past the used space is followed | 2 failures |
| a retirement list page past the used space is read | 1 failure |
| a page that is not a page of this store is treated as live | the suite aborts (its histories cannot be built) |
| a pinned read is not bounded by its version's used space | 1 failure |
| a retirement list page is never looked for under its version | 2 failures |
| an entry's count is not compared with its list | 1 failure |
| a reachable tree page is never refused | 5 failures |
| a free extent past the used space is handed out | 1 failure (the extent wholly past the used space) |
| a page a retirement entry still owns may be overwritten | 3 failures |
| replaced pages are not indexed as retired | 21 failures |
| a freed page need not be indexed under its entry | 2 failures |
| a loose page that is also a free extent is accepted | 1 failure |
| the retired backlog is not bounded | 1 failure |
| the probes a window holds are not bounded | 1 failure |
| a probe keeps its key as a slice of the page buffer | 1 failure |
| a window keeps the caller's buffer | 1 failure |
| a loose page listed twice is not checked by the loose list's own check | not caught alone: the supply's distinctness check refuses it first (both layers kept) |
| the double-free overlap check is removed | not caught alone: the retired-page index refuses a freed page that is loose or claimed, and the allocator tree's own neighbour check refuses a free one (both layers kept) |

Limits: the proof is bounded by the pages a plan writes (at most 256), the readers (at most 16), the tree height (at most 8) and one index lookup per page. A record that is consistently forged across every record that mentions a page, including the committed trees and the index together, cannot be told from the truth by any local check; what is guaranteed is that no single forged record, and no inconsistency between two records that describe the same page, lets a plan overwrite or free a page that a root, a pinned reader or a retirement entry still owns.


## Review round 7 (Codex, CHANGES_REQUESTED at `74746b89`)

Two findings, both valid, repaired locally after the round budget ended: re-sealing a two-page retirement entry's progress field from 0 to 1 made maintenance reclaim only the second page, delete the entry and release its list, leaving the first page indexed and charged as retired with its obligation lost (an entry is now finished only when every page its progress field says was reclaimed is gone from the retired-page index; `refuses a retirement entry whose progress field was re-sealed past pages that were not reclaimed`); and an internal page's separators were only order-checked, so a runs separator of 24 bytes of 0xFF passed decode and a reader's lookup answered that a record that exists is absent (separators are now validated against their tree's key format in every internal page; `refuses a re-sealed internal page whose separator is no key of its tree...` and the per-tree table in `Codec`). Controls: the skipped prefix need not be gone from the index (1 failure); separators only ordered (1 failure). The PR body gained a field table: every field of every on-disk record and page, its invariant, its validator and its re-sealed test.

After the manager's check of the field table, the counters row was strengthened: the partition identity and the empty-tree implications are validated at every plan and maintenance transaction (previously only a negative result was refused); the row states what a consistent forgery can change (capacity and reporting, never which page is overwritten) and `refuses a re-sealed counter that disagrees with the pages, whatever its sign...` shows both. Three controls fail the suite (the identity, the free counter against an absent free tree, the retired counter against an absent retirement tree).

## Review round 8 (Codex, CHANGES_REQUESTED at `2207de4a`)

One finding, valid: the round-7 progress check refused any index record for a page of the reclaimed prefix, but a partially consumed retirement list keeps page numbers that later transactions legitimately reuse and retire again under a newer version; maintenance always works on the oldest entry, so it could never reach the newer one and was blocked for good (reproduced without any corruption: retire 67 pages at version 2, reclaim 64, reuse page 0, retire it at version 9, finish version 2). The check now accepts a prefix page that is absent from the index or indexed under a newer version and refuses one indexed under the entry's own or an older version. Because the last two rounds each found an interaction between a validator and legitimate history, `Test.TerrainRuntime.Store.History` adds a bounded randomized model: six fixed seeds of 45 steps of edits (a handful of pages and more than one transaction frees), partial maintenance, reuse and retirement again, and readers pinned and released, after each of which the independent ownership checker, the readers' answers and the progress of maintenance (never refused, the retired count goes down) must hold, ending in a full drain; and the reviewer's case as a deterministic example. Controls: the previous form of the check (the reclaimed-prefix regression fails), a prefix page under the entry's own version accepted, and the prefix not checked (the tamper example fails).

## Review round 9 (Codex, CHANGES_REQUESTED at `bddb6420`)

One finding, valid: in a valid two-leaf runs tree, changing the first root separator from 1000 to 2000 (still below the next) and recomputing the checksum made `readerLookup` and `readerFloor` return `Read Nothing` for the run at 1000, because a key below the first separator was concluded absent without visiting any child. The finding was closed on a principle, not on the case: a conclusion of absence (a lookup that finds nothing, a floor, a ceiling, the start of a ranged scan, the unreachability of a page) is drawn only after the landing node's neighbouring subtrees were loaded through their own separators (`validateLanding`), and a key below the first separator descends into the first child. A re-seal fuzz (`Test.TerrainRuntime.Store.Fuzz`) was built first as the instrument: 360 fixed-seed mutations (one byte of one live page of the runs tree, checksum recomputed; 60 percent of them in the few internal pages), each judged by 134 reads on average (lookups, floors, ceilings, ranged scans started at keys around the first separators, a full scan, and the reachability of ten live pages): 48,294 reads, 22,498 integrity failures, 24,754 exactly the reference's answer, 1,042 excused as data (a record of the changed leaf), 0 defects. Before the fix the first version of the fuzz found 11 false absences in 360 mutations (moved separators at 3 byte offsets of the root); with the below-first-separator descent alone it still found them (separators moved to other valid keys, raised and lowered), which is what the neighbour validation closes. A one-off run of 4,800 mutations found only a test expectation to correct (a changed child pointer orphans its old child, which is then correctly unreachable). Controls (one per conclusion): neighbours not loaded (the union of the next five), a miss, a floor, a ceiling, a scan start and a reachability conclusion without the validation (each fails the fuzz), a key below the first separator concluded absent (2 failures), and the descent as it was at the round-9 head (both fuzz examples fail). `Identity`'s examples now state that a miss waits for the neighbouring leaf.

## Round 10 prerequisites: the five-tree fuzz and the child checksum

The manager asked for the re-seal fuzz to cover all five trees, since their key formats and validators differ although the descent is shared. `Test.TerrainRuntime.Store.FuzzTrees` builds a store whose five trees are each several pages deep (360 commits of records of the three kinds, rewritten so that pages are retired, then four fifths reclaimed: runs 123 pages, links 233, todo 125, free 6, retirement 6 with its retired-page index and version entries) and mutates one field of one live page of one tree, 250 times per tree, judging about 210 tree operations a mutation against the independent traversal. On the first version of that store the **retirement tree** produced defects (41 defective reads over 2 mutations of an internal page): a child pointer changed to the page number of a *stale but valid* page, a replaced copy of a leaf of the same tree and level whose keys fit the same bounds, so every structural check passed and reads returned the old content. Nothing the pages recorded said which version of the child a pointer meant. The owner approved the format change that does: every internal entry records its child's checksum, a node loaded through a parent is refused when its page carries another, and a new page's entries get the checksums of the children encoded before it.

Counts after the change (mutations, reads, integrity failures, answers exactly the reference's, answers excused as data, defects): runs 250, 53,497, 21,363, 32,013, 121, 0; links 250, 57,384, 8,986, 48,333, 65, 0; todo 250, 51,928, 17,809, 34,001, 118, 0; free 250, 53,037, 35,979, 16,920, 138, 0; retirement 250, 52,711, 34,855, 17,778, 78, 0. The deterministic regression builds the stale-pointer substitution directly (a pointer in an internal page named a stale leaf from the loose list, with the checksum recorded for the page that was there) for each tree that has such a leaf: 3 differing records in the free tree and 9 and 35 in the retirement tree would have been answered from the stale page, and every lookup is now an integrity failure or the reference's answer. Controls: the child checksum not compared (the stale-pointer regression and the retirement-tree fuzz fail); a cached node used whatever checksum the pointer records (the `Codec` example fails); a new page's entry recording another checksum than its child's (the suite aborts). Because a re-sealed leaf now fails its parent's record, the records excused as data fell from about a thousand to about a hundred per tree (the pages with no parent: a root).

The manager's check of the child checksum found the chain unanchored: the roots were loaded unchecked, so one re-sealed page could name a stale page *and record that page's own checksum*, and nothing above it authenticated the forged page except its parent's entry, which stops at the root. The root record now carries each tree root's checksum (`rRootCrcs`; windows hold them, a transaction publishes those of the roots it wrote and keeps the others, a reader's pin records those of its version), so every page on a path, the root included, is authenticated by the record above it. The fuzz gained the targeted class (an entry retargeted to a stale page of the same tree and level *with that page's own checksum recorded*, among the per-tree mutations and as a deterministic example, where the forged page is itself the root of the free and of the retirement tree and only the root record can tell) and root-record mutations (per tree, the checksum flipped and the root replaced by four other pages of the tree and four dead pages: in each of the 9 variants all 30 reads are integrity failures). Controls: the window holding no root checksums (7 fail); a transaction publishing the old checksums of the roots it wrote (7 fail). The residual, out of the model: a re-seal of the root record together with what it names.

The manager's check also required that a root with no recorded checksum fail closed. It does: `RootChecksumMissing` refuses it in every window a store hands out (the facade's committed and reader windows carry the trust of the root record or the pin; a plan's window also holds the pinned readers' roots, which making the check closed showed the plans had been reading unchecked), and only the test-only `windowUnchecked` (not exported by the facade; the suites that build root sets by hand use it through `uncheckedWindow`) reads such a root. Example: `Codec`, `refuses a root with no recorded checksum in every production window, and reads it only through the test-only unchecked window`. Controls: the guard removed (1 fails); plans without the pinned roots' checksums (2 fail); the committed window without checksums (2 fail).

Round 10 (head `3923632f`, Codex): CHANGES_REQUESTED, one finding, valid and a regression of the child-checksum format change: the deletion rebalance still sized an internal entry at 8 bytes after entries grew to 12 (`1 + key + page(8) + checksum(4)`), merged two internal siblings that did not fit one page (28 and 90 children: 117 entries counted 3,861 bytes, encoded 4,329) and refused a legitimate deletion as corruption. Closed at the root: the encoded size of an internal entry is defined once (`innerKeyBytes`, `innerEntryTail` in `Page.hs`) and the page decoder, the split, the merge and redistribution, the fit of a rewritten node and the overlay accounting use it (the literals 8, 12 and 13 in the store library are gone except the definition, the decoder's offset of the checksum and the overlay's one tag byte). The class is held by `Rebalance`: the reviewer's case (hand-built three-level runs tree, 28 and 90 children, 30 records a leaf, delete the first record: asserts the merged entries overflow a page at the size they encode to and would have fitted at 8 bytes, then that the deletion commits, the independent checker agrees and a read answers as the reference) and deletion-heavy random histories (four hand-built trees, 45 steps each of 1 to 40 deletions, a fifth re-inserting deleted records) in which a legitimate operation is never refused and the checker agrees after every step. Controls: the merge repack at 8 bytes (2 fail); the fit of a rewritten internal node at 8 bytes (the suite aborts); the split at 8 bytes survives as an equivalent mutant (an even split of an overfull node yields halves that fit either way).
