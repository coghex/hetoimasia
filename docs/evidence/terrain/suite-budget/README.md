# Terrain-runtime suite budget: bounded representatives, the parallel group and the full-depth probe

Issue #681, PR #689, code head `fb77525c`, base `19bc8ade`; Apple M3 Max, 16
cores, GHC 9.14.1. `terrain-runtime-tests` runs the temporary store's long
families at a bounded, fixed representative of their parameters, builds each
large fixture when the first example reads it, and runs its pure families in
parallel; `terrain-runtime-full-depth-tests`, an optional local probe, runs the
same families at their original parameters. The rule and the budget are in
[test_classification.md](../../../test_classification.md#the-suites-budget-and-its-parallel-group);
the later two-capability pass has [its own record](../../../removed_records.md).

The full write-up (every measurement window, the per-example times, all 64
store controls with their failing examples, the printed-line oracle) is in git
history: `git show 218ba408:docs/evidence/terrain/suite-budget/README.md`.

```sh
cabal test --project-file cabal.project.cpu hetoimasia-terrain-runtime:terrain-runtime-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-terrain-runtime:terrain-runtime-full-depth-tests --test-show-details=direct
```

## Final figures

Whole process by `/usr/bin/time -p` around the first command on an
already-built tree, on a machine in daily use (load 8 to 13 from other work).

| Run | Examples | Wall | Budget |
| --- | ---: | ---: | ---: |
| Base, sequential suite | 829 | 1,155.9 s (Hspec 901.3 s) | |
| Routine, three runs at `fb77525c`, 8 jobs | 882 | 133.4, 137.7, 142.3 s | 240 s |
| Routine at 4 jobs (an earlier head, 828 examples) | 828 | 148.0 s | 240 s |
| No example selected | 0 | 1.8 s | 10 s |
| Full-depth probe, one run | 96 | 1,004.9 s | none |
| CI "Finished in", three runs, 4 jobs | 828 to 838 | 128.1, 227.8, 244.2 s | 300 s at the time |

The two slower CI runs were on a slower runner: the untouched `terrain-tests`
and `terrain-render-2d-tests` ran 1.7 to 2.0 times slower in the same jobs.
Every one of the 829 example titles of the base run appears in the routine run
or in the full-depth run.

Where the time went, base to routine, by module at one job: `Rebalance` 389 to
32 s, `Scattered` 113 to 43 s, `Large` 110 to 17 s, `Protocol` 77 to 17 s,
`Evidence` 38 to 21 s, `FuzzTrees` 30 to 15 s, `History` 28 to 7 s, `Trees` 21
to 8 s. The memory rows (`Storage/Memory.hs`, 28 s) are unreduced: they measure
the whole process and run alone on one capability.

## Representatives: routine and full parameters

Every reduced family keeps every assertion of the original. A class stated
absolutely (tree height 2 or 3, a collapsed root, deletions that split a node,
exactly 256 pages) is never rescaled; where a smaller parameter did not reach
it, the family is not reduced that far. Three representatives were enlarged
until they caught a control the full depth catches: progress point 269, cycles
seed 202 and 3,500 links. The controls are numbered below.

| Family | Routine parameters | Full parameters | Controls the routine depth must catch |
| --- | --- | --- | --- |
| `Rebalance` 2-level histories | 1 seed; 160 source + 100 run keys | seeds 1-6; 700 + 500 keys | none; reach height 2 |
| `Rebalance` small histories, root collapse | size (30,30), seed 1 | 24 sizes x seeds 1-4 | 4, 5; reach "some root collapsed" |
| `Rebalance` 3-level histories | 1 seed; 1,600 + 100 keys | seeds 1-2; 2,800 + 900 keys | none; reach height 3 (1,400 + 100 keys reaches only 2) |
| `Rebalance` minimum fill, 300 commits | seed 1 | seeds 1-3 | none |
| `Rebalance` deletion histories | first hand-built tree | four hand-built trees | none |
| `Rebalance` tree level: mixed, long, banded, edge | seeds 1, 3, 5, 12; 2,000, 5,000, 2,500, 1,500 operations | seeds 1-2, 3-4, 5-8, 9-24; 8,000, 14,000, 10,000, 1,500 | 4, 6, 7; reach tallest level and "some split" |
| `Large` | 3,500 links, 2,400 retired pages, 20 recycling rounds; batch sizes 64, 300; 1,300 pinned commits; seed 1 | 12,000 links, 14,100 retired pages, 150 rounds; 24 sizes; 3,000 commits; seeds 1-3 | 2 (needs an inner page of 63-66 children: 3,300 links and up), 30, 31, 32, 33 |
| `Scattered` progress points | 269 | 0, 63, 64, 128, 269 | 33, 35 (only the longest entry) |
| `Scattered` forged jumps | 65 | 1, 10, 63, 64, 65, 128, 200, 269 | 36, 49 |
| `Scattered` batch sizes, layouts, pinned versions | 64; fragmented; 16 | 12 sizes; four layouts; 1, 2, 4, 8, 16 | 30, 42 |
| `Protocol` fragmented entry | starting limit 8 | 1, 2, 3, 7, 8, 16, 33, 63, 64 | 42 |
| `History` random histories | seed 1; fixture 12,000 runs | seeds 1-6 | none |
| `Trees`, `Evidence` growth | seed 11; 33 x 33 columns | seeds 11, 29, 47; side 20 | none; reach three levels grown |
| `Evidence` | seed 11; cycles seed 202 | seeds 11, 29, 47; cycles 101, 202, 303 | 22 (seed 202 of the cycles only) |
| `Fuzz` | seed 101 (60 mutations) | seeds 101-606 (360) | none |
| `FuzzTrees` | seed 11 in each of five trees (50 mutations) | seeds 11-55 (250) | 16, 23 |
| `Cycles` | seed 202 | 101, 202, 303 | 22 |

Unreduced by the owner's decision: the round-14 `Scattered` example of a loose
list at exactly its cap is kept whole in both tiers. The examples that encode a
reviewer's exact failing sequence stay routine at full strength.

## Controls

Each control is a mutation applied in a scratch worktree, never committed. The
baseline passes at both depths.

| # | Protected behaviour broken | Site |
| ---: | --- | --- |
| 1 | the merge repack sizes an internal entry at 8 bytes | `Tree.rebalanceChild` |
| 2 | the fit of a rewritten internal node at 8 bytes | `Tree.bodyBytesOf` |
| 4 | the repack after an insertion not applied | `Tree.insertKey` |
| 5 | insertion skips the root collapse | `Tree.insertKey` |
| 6 | deletion rewrites an over-full parent instead of splitting it | `Tree.deleteKey` |
| 7 | a deletion's root split ignored by the exit | `Tree.deleteKey` |
| 16 | the child checksum not compared | `Tree.load` |
| 22 | plans and maintenance without the pins | `Model.pinnedRoots` |
| 23 | the minimum-fill rule not applied at descent | `Tree.load` |
| 30 | the bookkeeping count not checked before numbering | `Plan.planDelta` |
| 31 | the larger supply never asked for | `Plan.planDelta` |
| 32 | a bookkeeping overflow not shrinkable | `Plan.shrinkable` |
| 33 | the spill of the loose list removed | `Plan.planReclaim` |
| 35 | the whole consumed prefix verified at the end of the entry | `Plan.planReclaim` |
| 36 | no verification of the consumed prefix | `Plan.planReclaim` |
| 42 | maintenance ignores the work limit | `Plan.chunkSizes` |
| 49 | an index record under the entry's own version accepted | `Plan.goneFromIndex` |
| 62, 63, 64 | a volume profile, an open's directory, a configuration's names kept as views of a larger buffer (the copy undone) | `Storage.Volume`, `Storage.Service`, `Storage.Types`; caught by the `Storage.Memory` retention rows |

**Caught by no example of either tier**, on the base as well, so findings
outside that issue: 10 to 13 (a floor, a ceiling, a scan start and a
reachability conclusion made without the landing validation), 14 (a key below
the first separator concluded absent), 38 (a spilled page the supply also
takes not refused), 59 (a loose page outside the used space accepted), 60 (a
page handed out twice by one supply). Control 3 (the split at 8 bytes) is an
equivalent mutant.

The other controls of the temporary store are caught by families that were not
reduced (`Codec`, `Ownership`, `Readers`, `Allowance`, the read-phase examples
of `Protocol`).

Isolation of the parallel group, five controls: an example that reads the live
heap, the memory rows or a storage example placed in the group fails at its
guarded entry point; a guard that does not return the runtime to one
capability, or a parallel helper that outlives its example, fails every
sequential example. **The guard cannot see a file, thread or clock used by a
parallel example that calls none of the guarded entry points**; the rule in
`Test.TerrainRuntime.Parallel` and review keep those out.
