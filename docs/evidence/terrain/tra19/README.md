# TRA-19 evidence: compressed knowledge and resumable discovery after removal

Evidence for [#661](https://github.com/coghex/hetoimasia/issues/661) (TRA-19 of #636),
delivered by pull request [#671](https://github.com/coghex/hetoimasia/pull/671).

**Revision.** Implementation head `e6e5b19cd776` (branch `issue-661-discovery-model`, based on
`origin/master` `d8b2aa7b1b78`, with the landed docs merged; round 1 of the review repaired). Every figure below was produced at that revision with the
qualified toolchain (GHC 9.14.1, Cabal 3.18.1.0). The suite's own output is the primary record;
this document restates it with the commands that reproduce it. It qualifies a **pure model and
its logical records only**. Runtime atomicity, real file retention, physical resource bounds,
store pages and visual fog or picking remain later integration gates (TRA-20 to TRA-22, P-14).
Retention is session semantics, not a save or crash-recovery promise, and an accounted byte is a
conservative model figure, not a heap or process-RSS figure and not an encoded page.

## Commands

```sh
export PATH="$HOME/.cache/hetoimasia/toolchain/ghc-9.14.1/bin:$PATH" PYTHONDONTWRITEBYTECODE=1
ghc --numeric-version            # 9.14.1
cabal --numeric-version          # 3.18.1.0
cabal build --project-file cabal.project.cpu lib:hetoimasia-terrain lib:hetoimasia-terrain-render-2d
cabal test  --project-file cabal.project.cpu hetoimasia-terrain:terrain-tests --test-show-details=direct
cabal test  --project-file cabal.project.cpu hetoimasia-terrain-render-2d:terrain-render-2d-tests --test-show-details=direct
(cd packages/terrain && cabal check)
python3 tools/validation/plan.py --catalog-check
PKG_CONFIG_PATH="$HOME/.cache/hetoimasia/native/glfw/lib/pkgconfig" cabal test workflow-tests --test-show-details=direct
# the discovery examples alone, with the evidence rows printed:
cabal test --project-file cabal.project.cpu hetoimasia-terrain:terrain-tests --test-show-details=direct \
  --test-option=--match --test-option="Discovery"
```

Results at the revision: `terrain-tests` 886 examples, 0 failures (49 are the `Discovery` group);
`terrain-render-2d-tests` 298 and `workflow-tests` 965, 0 failures; `cabal check` clean;
catalog valid (36 groups); clean rebuild of the terrain package without a warning.

## The independent oracle

`Test.Terrain.DiscoveryHarness` shares no code with the production overlay. It reads the source as
plain data (`Test.Terrain.Model.modelCell`, a naive scan of every layer, patch and removal), decides
whether two face-adjacent cells connect by testing a 32 x 32 grid of exact rational sample points
of the shared face for membership in both open regions (`Test.Terrain.ConnectivityOracle`; every
open region has corners on multiples of 1/4, so a positive-area overlap contains a sample and an
edge or point contact contains none), and floods the explicit window cell by cell.

Expected knowledge is derived from first principles and never from a production query:

* the void cells of a flood component are **known** when any of them is above the authored sky
  level, is a top-level cell open to the upper boundary, or was known before (monotone);
* a solid cell is **known** when its own void cell is known, or over some sampled point of a shared
  face it lies against the open region of a known void cell (a table of exposed pairs for every
  content kind and direction), or it is a top-level cell whose top face has solid section;
* after each removal the oracle recomputes the known set from the previous one over the current
  grid.

After every event of every trace the harness checks: (1) the retained state rebuilds from its own
records (`retainedFromRecords`); (2) the removed runs expand to exactly the applied removals; (3)
every report is within the validated limits; (4) the connections inspected equal six per finished
obligation plus the progress of pending ones (none twice, none lost); (5) production knowledge lies
**between** the oracle after the removals whose obligations are finished and the oracle after every
removal; (6) when the obligations are drained, production knowledge **equals** the oracle after
every removal, for every void and solid cell of the window's inner cells.

## Fixtures

All worlds are stone from the lowest level to a sky level, then air to the upper limit, with the
patches listed (`caveRow y z x0 x1` is air along X). Windows are 3 cells beyond the content.

| Scene | Sky | Patches (air unless stated) | Removals / purpose |
| --- | --- | --- | --- |
| two openings | 8 | cave `y=0, z=5, x=2..8`; side branch `x=5, y=1..3, z=5` | opening A `(1,0,5..7)`, opening B `(9,0,5..7)` |
| sealed pockets | 8 | pockets `y=0, z=5` at `x=2..3`, `x=5..6`, `x=8..9` | raw `(4,0,5)` joining two pockets, `(7,0,5)`, a sealed buried stack `(0,3,1..6)` in six orders, then reveal `(1,0,5..7)` |
| ramp and barrier | 8 | corridor `y=1, z=5, x=1..7`; N ramp (shape 1) at `(4,0,5)` with stone above; sealed cavity `(2,-3..-2,5)` | reveal `(0,1,5..7)`: ramp solid known / void unknown; barrier `(2,0,5)` known, cavity unknown |
| edge and point contact | 8 | cave `y=0, z=5, x=2..4`; pocket `(5,1,5)` (edge contact), pocket `(5,-1,6)` (corner contact) | reveal `(1,0,5..7)`: both pockets stay unknown |
| ramp pair | 8 | N ramp `(1,0,5)`, S ramp `(2,0,5)` | shaft `(0,0,5..7)`: quarter-face overlap connects |
| ramp family `w` | `w` | stone below 0; N-ramp layer on `[0,w)`; stone block exception at `(3,1,w-3)` | `(1,1,w-2)`, `(2,1,w-3)`, `(1,1,w-1)` for `w` = `2^20` and `2^60` |
| generated | 8, 32, -32 | 4 x 4 core of random air, block and shape patches (all 16 identities); 9 random removals | origins `(0,0,8)`, `(-2,-2,8)`, `(-3,-3,32)`, `(-2,-2,-32)` (negative X/Y/Z region seams), seeds `1..12` each; batches of 3 |
| extremes | none | air `(highest-1, 0, topEnd-3)`; air at the lowest level | removals at `z = topEnd-1` and `x = highest` (upper limit reaches the exterior, X limit opens nothing) and at `lowest+2`, `lowest+3` |

Seeds are the literal ranges in the examples (a SplitMix64 stream, `Test.Terrain.ConnectivityFixtures`);
a failing trace names its scene (origin and seed) and the event.

## Required cases and results

| Case (issue requirement 8) | Result |
| --- | --- |
| Two opposite openings, both orders; second immediately after the first, between batches, after partial expansion | pass; whole cavern, side branch and exposed walls known; stone beyond the branch's wall unknown |
| Every interleaving of the two shafts (20) at batch limits 1, 2, 3 and 64 | pass, 80 traces, invariants after each event |
| Exit to known exterior without ending the discovery of the other front | with batch 1 and six queued obligations, pending stays above zero after the first batch and the drain still matches the oracle |
| New connection beside an already expanded known region; union between pending regions; a later removal while older discovery is suspended | pass (`discover a removal made beside...`; six-cell run in three orders before any batch; a removal staged while the head obligation's record is withheld, then restored) |
| Raw buried removal and long coalesced runs, then a later opening | stay `VoidUnknown` until the reveal; then both joined pockets and the run known; the sealed stack stays unknown |
| Air and repeated removals | `EditNoOp`; records and header byte for byte unchanged; pending work kept |
| All 16 shapes and four orientations, real diagonal openings, edge/point-only controls, negative seams, extreme coordinates | generated traces (48), ramp pair, edge/point scene and extremes pass |
| Known ramp side beside an unknown void; known barrier beside a separate sealed cavity | `(SolidKnown, VoidUnknown)` = `KnownSolidUnknownVoid`; `(NoSolid, VoidUnknown)` = `FullyUnknown`; barrier `SolidKnown`, next cell `SolidUnknown` |
| Existing logical queries independent of knowledge | `cellAt` over `Changes` rebuilt from the retained runs is identical drained and partial |
| Huge families and symbolic joins at `2^20` and `2^60` | the four-field report of every edit and batch is identical at both spans (see below) |
| After every discovery batch: discard and reconstruct, round-trip the records, resume, compare | final records and header identical to the uninterrupted run |
| A required record delayed, then restored | `BatchStalled (KeyTodo 0)`; cell query is `MissingRecord`, not unknown; restoring and draining matches the oracle |
| Batch limits 1 and 64; an operation of more than 64 updates; exact/insufficient allowances; invalid limits; arithmetic | limit 1: one update per batch; 12 removals queue 72 connections: a batch of exactly 64 (`HaltBatchFull`) then 8 (`HaltDrained`); each of reads, writes, delta bytes, scratch bytes: the exact figure gives the same updates, one fewer fewer; `0`, `-1`, `65`, below-minimum refused by field; content, store and sequence at `maxBound` refused `AuthorityOverflow` |
| Rejected edit leaves no orphan; discovery refusal loses nothing; resume without reissuing | edit refused by allowance, obligation cap and retained-byte cap leaves records unchanged; after a drain the same edit is accepted |
| Stale, foreign and repeated candidates | `StaleBase` for the second of two from one base and for a repeat; `WrongArena` for another incarnation |

## Bounds measured for the required traces

Accounted counts and bytes, from the suite's `evidence` rows (max over the reports of the trace;
"resident detail" is the number of resident cells the model instantiated, always 0):

| Trace | edits | reports | max updates | max reads | max writes | max delta bytes | max scratch bytes | retained records | retained bytes | pending | resident detail |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| two openings | 6 | 7 | 36 | 44 | 10 | 1,576 | 12,712 | 6 | 1,128 | 0 | 0 |
| sealed pockets + coalesced run + reveal | 11 | 13 | 64 | 81 | 18 | 2,808 | 23,416 | 11 | 2,016 | 0 | 0 |
| ramp family 2^20 | 3 | 4 | 18 | 28 | 8 | 1,632 | 8,672 | 10 | 2,152 | 0 | 0 |
| ramp family 2^60 | 3 | 4 | 18 | 28 | 8 | 1,632 | 8,672 | 10 | 2,152 | 0 | 0 |

Scratch is accounted deterministically: every provider read is charged the largest record (256 bytes) and every staged write its entry, each checked before the read or the staging, so the scratch column is reads x 256 plus the staged entries (a conservative admission figure, not heap). Worst-case constants the limit validation enforces: an edit reads at most 197 records and writes
at most 7; one structural update reads at most 132 and writes at most 3; a union chain is at most 64
hops. The shared compiled source is charged once per arena (`envSharedBytes`), never to a candidate.

**Bounded working window.** The same three edits and drain, with 0 and with 100,000 unrelated
retained removed runs, produce the identical `(reads, writes, delta bytes)` for every report, all
within the validated limits. Forced-result allocation (`GHC.Stats` across major collections, 20
repetitions of the three edits and a drain; measured allocation, not accounted bytes and not RSS):

| Variation | Allocated bytes |
| --- | --- |
| span `2^20` | 7,005,096 |
| span `2^60` | 7,009,720 |
| history of 100 runs | 7,096,224 |
| history of 100,000 runs | 7,264,224 |
| source with 0 patches (one removal and drain, 20 repetitions) | 50,904 |
| source with 200 separated patches | 50,904 |

The class lookup is bounded: with the first version of `Connectivity.isExterior`, which materialized every member of the class, the same 200-patch row allocates 874,408 B against 51,112 B for 0 patches (a control run locally, not committed). Each pair is within a factor of two plus 64 KiB, and the example fails if the statistics are
disabled. No cost is proportional to a span, to represented cells, to boundary tiles or to
retained history.

**Compressed boundary.** `queryKnownBoundary` of a known top-row component returns the same number
of faces at `2^20` and `2^60`, and `Nothing` for the unknown lower-row component.

## Per-step expected and observed state

The `evidence` example prints one row per event of an interleaved trace (batch limit 1; edits
alternate between the two shafts). "known voids" counts the compared inner cells reported known;
"oracle between" is the sandwich bounds (finished obligations, every removal):

```
step  1 edit (1,0,5): pending 1, known voids 196 (oracle between 196 and 196), known solids 98 (oracle after every removal 98)
step  2 batch:        pending 1, known voids 196 (oracle between 196 and 196), known solids 98 (oracle after every removal 98)
step  3 edit (9,0,5): pending 2, known voids 196 (oracle between 196 and 196), known solids 98 (oracle after every removal 98)
step  4 batch:        pending 2, ...
step  5 batch:        pending 2, ...
step  6 edit (1,0,6): pending 3, known voids 196 (oracle between 196 and 196), known solids 98 (oracle after every removal 98)
step  7 batch:        pending 3, ...
step  8 edit (9,0,6): pending 4, ...
step  9 batch:        pending 4, ...
step 10 batch:        pending 3, known voids 196 (oracle between 196 and 196), known solids 98 (oracle after every removal 98)
step 11 edit (1,0,7): pending 4, known voids 196 (oracle between 196 and 211), known solids 97 (oracle after every removal 149)
step 12 batch:        pending 4, known voids 196 (oracle between 196 and 211), known solids 97 (oracle after every removal 149)
step 13 edit (9,0,7): pending 5, known voids 196 (oracle between 196 and 212), known solids 96 (oracle after every removal 148)
step 14 batch:        pending 5, known voids 196 (oracle between 196 and 212), known solids 96 (oracle after every removal 148)
step 15 batch:        pending 5, known voids 196 (oracle between 196 and 212), known solids 96 (oracle after every removal 148)
step 16 drain:        pending 0, known voids 212 (oracle between 212 and 212), known solids 148 (oracle after every removal 148)
```

The cave stays unknown until the first shaft reaches the sky, then the sandwich closes at the drain.
Production knowledge never leaves the oracle's bounds, and it equals the oracle exactly at the end
(212 known voids, 148 known solids). The known solids dip by one when a known wall cell is removed
(its solid no longer exists) and recover as the new surface is exposed.

## Negative controls

Each was applied locally to `Internal/Discovery/Core.hs`, the discovery group run, and the file
restored from git (never committed). Counts are of the 41 discovery examples then present.

| Protected behavior broken | Failing examples |
| --- | --- |
| finding an exit retires the front's obligation (stop the reveal on reaching sky) | 15 |
| a partly inspected (pending) obligation is treated as expanded | 22 |
| a known solid makes its void known | 4 |
| an already known cell is permission to ignore an added edge | 4 |

The `negative controls` examples additionally apply three wrong behaviours to the real results
(a driver that forgets the remaining obligations after a batch that finds an exit, a claim that a
pending state is complete, and a known-solid-implies-known-void transformation of the answers); the
independent comparison rejects each while accepting the honest result.

## Round 1 of the review and its repairs

The first canonical review (Codex) requested changes on five points, all valid, repaired at the head above:

| Finding | Repair | Evidence |
| --- | --- | --- |
| capacity was checked after an inspection ran, so a rejected inspection's reads and scratch were discarded from the report | every read, staged write, candidate record, candidate byte and retained byte is checked before it is made; a rejected inspection reports its reads as `reportAttemptedReads` | `accounting before the work`: a counting provider independent of the model, over a grid of read, scratch, write and delta allowances, for batches, edits and a suspension: requests never exceed the allowance and equal the reported attempted reads |
| `isExterior` enumerated every member of the class | it resolves the representative only | allocation with 0 and 200 patches identical (50,904 B); the enumerating version fails the example |
| extending a known run changed knowledge without advancing the knowledge revision | a removal that joins an existing run whose class is known reports it as newly known space | the reviewer's removal sequence: `candidateKnowledge`, the revision, the oracle and overflow at the maximum revision |
| restored runs were checked only for `lo < hi` | endpoints must lie in `[-2^62, 2^62]` | legal limits accepted, `-2^62-1`, `2^62+1` and `(2^62, 2^62+1)` refused; `retainedRemovals` keeps both legal runs |
| replay and invariants were not applied after every batch of a drain | drains check state and oracle bounds after each batch; a lockstep example rebuilds a run from its records after every edit and batch and compares it record for record with an uninterrupted run | 3 authored and 10 generated scenes |

Each repair was reverted locally and the examples run (never committed): the enumerating `isExterior` fails the structure example, an extension that reports no knowledge fails the revision example, a scratch check that follows the read fails the counting-provider and rejected-inspection examples, and unchecked run endpoints fail the range example.

## Defect found by the oracle and fixed

The first sandwich run on the ramp family showed a removed top-level cell reported unknown until its
obligation ran, although its void had been known. Knowledge must never decrease, so the removal now
joins the new full-air cell to its own old void in the same candidate. The sandwich invariant and
the family example pin it; a second change charges a deletion as the largest record of its kind so a
candidate's accounted size never shrinks as updates are staged, which makes an exact allowance mean
what it says.

## Not exercised here

A multi-void shape (the catalog has none; `lookupVoid` is index 0 only, as in TRA-18); a bulk run
removal (not offered: the paired single-cell path is the only edit); store pages, file and
asynchronous I/O, live scheduling and publication atomicity (TRA-20 to TRA-22); the Linux X11 and
Wayland native groups and the rest of `test.vulkan-headless` (CI). Visual fog and picking are P-14.
