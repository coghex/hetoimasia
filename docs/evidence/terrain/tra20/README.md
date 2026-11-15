# TRA-20 evidence: the temporary store's pure model

Issue #662, PR #675. Final gates at `f129732f`: `terrain-runtime-tests` 536
examples, `terrain-tests` 905, `terrain-render-2d-tests` 558, `workflow-tests`
965, all with 0 failures. The figures are observations of the pure model and
its codec. **They are not filesystem, durability, preallocation, latency or RSS
figures**, and none is proof of live request settlement or crash recovery
(TRA-21 to TRA-23 own those).

The round-by-round write-up (twenty review rounds, every negative control, the
measured-memory audit) is in git history:
`git show 21e527cc:docs/evidence/terrain/tra20/README.md`.

## Commands

```sh
export PATH=$HOME/.cache/hetoimasia/toolchain/ghc-9.14.1/bin:$PATH
cabal test --project-file cabal.project.cpu hetoimasia-terrain-runtime:terrain-runtime-tests --test-show-details=direct
# the figures below: the evidence printer at full depth (the routine suite bounds these families)
$(cabal list-bin --project-file cabal.project.cpu hetoimasia-terrain-runtime:terrain-runtime-full-depth-tests) --match "TRA-20 evidence"
```

## Depth

- Generated histories: seeds 11, 29 and 47 (400 steps, up to 30 writes each),
  seed 5 (grow, then delete in random order), seeds 101, 202 and 303 (450-step
  update, abort, publish, read, reclaim cycles), seed 2024 (fault fixture),
  seed 77 (readers), seed 5 (exhaustion). Every sequence is a seed in its
  example's name, so a failure replays by seed.
- The bounds rows use a 20,000-run history; the allocation rows compare a
  500-run history with a 20,000-run one.
- Replay of the discovery model's `two openings` scene at batch sizes 64 and 1.
- References written independently of the model
  (`Test.TerrainRuntime.Store.Reference`): a bitwise CRC32C, a page parser from
  the documented layout, and a traversal that decides from the bytes alone
  which pages are live, retired, free or loose and that they partition the
  used space exactly.

## Final figures

| Observation | Value | Bound |
| --- | --- | --- |
| Most pages one plan wrote (seeds 11 / 29 / 47) | 25 / 27 / 26 | 256 pages, 1 MiB |
| Largest RAM one plan reserved | 971,907 / 987,978 / 990,141 B | 4,194,304 B |
| Most validated window pages held | 32 / 31 / 35 | 1,310,720 accounted bytes, about 310 pages |
| Violations found by the independent traversal | 0 in every history | 0 |
| The exact plan | 256 pages, 1,048,576 B, RAM 3,626,629 B | met exactly; 257 pages refused as `TxnPagesExceeded` |
| Format | tree level at most 7; worst update at full height 17 pages; bookkeeping reserve 68 pages; largest claim 324 pages | |
| Minimum removal | 188 pages, 3,945,392 B of RAM | fits 4,194,304 B with 249 KB to spare |
| Discovery unit | 3,324,256 B of RAM | fits with 870 KB to spare |
| Worst components summed (I/O, decoded, keys, scratch, pins, root and control, continuation) | 5,663,872 B | above the limit: this sum is an account bound, and `chargeFor` is what gates each plan |
| Fault fixture (14 pages, 15 prefixes; failure, cancellation, a provider that writes no more) | old root intact in every prefix, 0 rollback writes, usage restored | |
| Readers pinned at versions 40 and 65 | reclamation stops at the first entry newer than the oldest pin (`BlockedByReader`); after the last release 65 reclaim transactions leave 0 retired bytes | |
| Exhaustion (64 MiB allowance, 48 MiB overhead) | 123 commits, then `Capacity (DiskFull 324 2362 2048)` with the 8 MiB reserve intact; 122 reclaim transactions restore 7,389,184 B available | |
| Cycles (seeds 101 / 202 / 303) | 186 / 177 / 194 commits, 52 / 50 / 49 aborts, 24 / 22 / 28 failed writes; most pages in one transaction 20 / 22 / 22 | 256 |
| Replay, batch 1 | 3 pending carried between openings, 35 drain batches, at most 1 structural update a batch, 0 pending at the end | 64 updates |
| Allocation at a history 40 times larger | edit plan 6.1x, pinned point read 1.8x, usage report 1.0x, reclamation step 1.0x | the control, a map of every record key, grows 38x |

## Negative controls

Each protected behaviour was broken by a mutation applied locally to the
library, run, and restored, never committed; every one fails at least one
example in the final suite. Three were first missed (a page freed twice,
ordinary history spending the protected reserve, growth committed before the
reservation was reported) and gained a test. The controls each store family
still catches at its routine depth are listed in
[the suite-budget record](../suite-budget/README.md).

## Limits

Nothing here measures a file, a filesystem, an fsync, a descriptor, a worker,
latency or process memory. The memory figures are accounted bytes of the
representation, checked against the live heap of a window of 310 dense pages;
each accounted constant is held with a margin above its measured maximum, the
thin ones being the window page (0.5%), the written page (1%) and the overlay
page (2%), on this GHC and machine. The 8-level height bound is shown
unreachable below about 36 GiB of leaves by the derivation in
`Format.maxLevel`, not by building such a store. The fixtures' batches read at
most 46 records, so the production read cap of 2,463 never binds in a protocol
fixture; the early end is shown at a lowered cap.
