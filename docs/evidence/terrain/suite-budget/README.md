# Terrain-runtime suite budget: bounded representatives, the parallel group and the full-depth probe

`terrain-runtime-tests` (group `test.terrain-runtime`) runs the temporary store's long families at a bounded, fixed
representative of their parameters, builds every large fixture when the first example reads it, and runs its pure families in
parallel, in one executable with one "Finished in" line; `terrain-runtime-full-depth-tests` (group `test.terrain-runtime-full-depth`, an optional probe)
is the second test component, by the owner's decision (issue comment 6872272575), and runs the same
families at their complete original parameters. Base `19bc8ade`, code head `4000e2fb` (the acceptance record below; the earlier figures name their head), GHC 9.14.1 (PATH `$HOME/.cache/hetoimasia/toolchain/ghc-9.14.1/bin`),
machine Apple M3 Max (16 cores). Every figure is a lab observation; CI figures are from the CI record.

```sh
cabal test --project-file cabal.project.cpu hetoimasia-terrain-runtime:terrain-runtime-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-terrain-runtime:terrain-runtime-full-depth-tests --test-show-details=direct
```

## Results

**Acceptance record, code head `4000e2fb`** (the suite is 876 examples: the 828 of the earlier heads and the 48 of the oracle of the printed lines), 2026-11-14 07:53Z to 08:00Z, the built tree, nothing built in any run (no `Compiling` or `Linking` line), no other build or test of this repository running. `/usr/bin/time -p` around the literal acceptance command below; every run exited 0 with 0 failures, 8 jobs on 8 capabilities (`RUNNER jobs=8 capabilities=8`, `PHASE sequential: 1 capability`). The load is as observed, not quiet: a sampler recorded every 5 s any process over 50% CPU other than the suite and `fseventsd`, and any compiler of any project; other projects' `cargo test` ran beside the routine runs.

| Run | Load before | Wall s | "Finished in" s | CPU user s | Samples | What the samples show |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| routine 1 | 5.46 | 149.04 | 146.20 | 269.9 | 139 | other projects' `cargo test` and test binaries, a `clang`, `mds` |
| routine 2 | 14.61 | 137.02 | 135.47 | 261.8 | 63 | another project's `cargo test`, `mds` |
| routine 3 | 9.15 | 138.26 | 136.52 | 263.7 | 23 | light processes (`pijul status`, a compiler's check) |
| no example selected | 7.40 | 1.87 | 0.0001 | 1.54 | 2 | two other processes |

Each routine run is within the 240 s budget (the worst by 91.0 s) and the no-example run within 10 s. The full-depth probe, one run at the code head `7ec6fd45` (the later changes touch the oracle and, only when progress is reported, the line state; the probe does not run the oracle) beside other agents' test runs (load 5.6 to 11, not a budgeted run): 96 examples, 0 failures, "Finished in" 1004.86 s, wall 1004.88 s, CPU user 997.2 s. The documented selection `--match "TRA-20 evidence"` runs 8 examples with 0 failures in each executable, prints 23 `EVIDENCE` lines (routine) and 29 (full depth), and every one starts a line; the 29 of the full-depth executable equal the 29 `EVIDENCE` lines of `tra20/README.md` byte for byte except three allocation counters (`allocation a one-record edit plan`, `a pinned point read` and the control map), which moved by under 3 percent between runs. All `EVIDENCE`, `MEMORY` and `memory ...` records of the four runs above and of the full-depth run start a line.

The earlier windows follow, at the heads they name (828 examples, before the oracle).

Two windows on an already-built tree (`cabal build` before each; nothing built inside any measured run), one run after another, nothing repeated; every run exited 0 with 0 failures. Load is `uptime`'s one-minute average immediately before the run. The default job count is `min 8 processors` (16 here); `--jobs N` replaces it; capabilities equal the job count for the parallel group and are 1 for every sequential example (every run prints `RUNNER jobs= capabilities=` and `PHASE sequential: 1 capability`). Machine: Apple M3 Max, 16 cores, 64 GiB, macOS 26.7.1.

**Acceptance boundary** (requirement 9): `/usr/bin/time -p` around the literal command, from process launch to exit, cabal's whole output kept:

```sh
cabal test --project-file cabal.project.cpu hetoimasia-terrain-runtime:terrain-runtime-tests --test-show-details=direct
# no example: the same plus  --test-option=--match --test-option="/zzz no such example/"
# 4 jobs:     the same plus  --test-option=--jobs --test-option=4
```

Window 2, 2026-11-14 01:30Z to 01:39Z, head `9a1b7ff5` (the suites' sources are those of `774c23c9`). Nothing was built: each run's cabal output is `Build profile` / `In order, the following will be built ... (ephemeral targets)` / `Preprocessing test suite` / `Building test suite 'terrain-runtime-tests'` / `Running 1 test suites` with 0 `Compiling` and 0 `Linking` lines, no component rebuilt. The machine was busier than in window 1: other projects' processes ran (a `codekarl` worker at about one core during the first run, `rustc`/`clippy-driver` during the 4-job run) and `fseventsd` held about one core throughout; none is a build or test of this repository.

| Run | Jobs (capabilities: group / sequential) | Load before | Wall s | "Finished in" s | CPU user s | Examples |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| routine 1 | 8 (8 / 1) | 6.13 | 135.63 | 131.69 | 266.1 | 828 |
| routine 2 | 8 (8 / 1) | 7.39 | 127.36 | 125.85 | 256.6 | 828 |
| routine 3 | 8 (8 / 1) | 6.44 | 134.84 | 133.36 | 265.7 | 828 |
| routine, 4 jobs | 4 (4 / 1) | 6.63 | 147.96 | 146.13 | 248.3 | 828 |
| no example selected | 8 | 6.77 | 1.86 | 0.0002 | 1.58 | 0 |

**Executable boundary** (a second column, true and useful: `/usr/bin/time -p` around the built executable, no cabal), window 1, 2026-11-14 00:46Z to 01:15Z, head `774c23c9`, load 4.0 to 4.8; `fseventsd` about one core:

| Run | Jobs (capabilities: group / sequential) | Load before | Wall s | "Finished in" s | CPU user s | Examples |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| base `19bc8ade` (sequential suite, cabal boundary, earlier session, load about 10) | 1 (1 / 1) | 9.8 | 1155.9 | 901.3 | 1116.8 | 829 |
| routine 1 | 8 (8 / 1) | 4.83 | 123.26 | 123.17 | 254.9 | 828 |
| routine 2 | 8 (8 / 1) | 3.96 | 121.03 | 120.98 | 254.6 | 828 |
| routine 3 | 8 (8 / 1) | 4.04 | 122.70 | 122.65 | 253.4 | 828 |
| routine, 4 jobs | 4 (4 / 1) | 4.33 | 134.17 | 134.13 | 238.9 | 828 |
| routine, 1 job (the per-example times below; not a budgeted configuration) | 1 (1 / 1) | 4.12 | 239.98 | 239.69 | 225.7 | 828 |
| no example selected | 8 | 4.52 | 0.02 | 0.0001 | 0.01 | 0 |
| full depth (`terrain-runtime-full-depth-tests`) | 1 (1 / 1) | 4.52 | 982.03 | 981.13 | 977.1 | 96 |

**The same command, six runs under the quiet-run sampler** (2026-11-14 01:43Z to 01:57Z, head `9a1b7ff5`; a sampler recorded every 5 s any process over 50% CPU other than the suite and `fseventsd`, and any `ghc`, `cabal`, `rustc`, `cargo` or `clippy-driver` of any project; a run is quiet when its samples are empty; none was, and six is the most the acceptance item allows, so the repetition stopped). Each: `/usr/bin/time -p` around the literal acceptance command, 8 jobs (8 / 1 capabilities), nothing built (0 `Compiling`, 0 `Linking`), 828 examples, 0 failures:

| Run | Load before | Wall s | "Finished in" s | CPU user s | Samples | What the samples show |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| q1 | 5.44 | 130.13 | 128.11 | 260.1 | 47 | a python `unittest` at about one core for most of the run; `cmux` 76% |
| q2 | 9.87 | 128.97 | 127.44 | 259.2 | 30 | another project's `cargo test` and its test binaries (two cores) |
| q3 | 7.69 | 131.15 | 129.61 | 261.7 | 24 | python 86-89%, `XprotectService` 60%, a `ghc` of another project |
| q4 | 7.90 | 132.83 | 131.14 | 264.0 | 28 | `clippy-driver` at one core, `cargo check`/`doc`, two `clang` |
| q5 | 5.15 | 128.60 | 127.03 | 260.5 | 9 | a `cargo build` with a `clang` at one core |
| q6 | 5.32 | 132.26 | 130.77 | 259.3 | 23 | python `unittest`, a python chat tool, a `pijul clone`, `mds` |

All three sets of local runs agree to within about 10 percent (the executable boundary 121.0 to 123.3 s, the cabal boundary under load 127.4 to 135.6 s, the six sampled runs 128.6 to 132.8 s) and the loads differ by a factor of two; every one is 104 s or more under the 240 s budget. The six sampled runs are the acceptance figures of item 2 that the owner's decision of 2026-11-14 names (a daily-use machine cannot be made quiet; "if each run is under budget they pass"; issue comment 6870133533), at the head they were taken (828 examples): a run passes when it is within the budget, no quiet condition applies, and each run's load is stated as observed. After the suite gained the examples of the oracle of the printed lines, the item was taken again at the final code head `4000e2fb` under the same rule, the three runs above (intermediate heads gave 145.6, 137.2, 144.4 s at `7ec6fd45`, 838 examples, and 141.8, 142.0, 150.5 s at `428a6625`, 856 examples); every run of all these sets is within the budget. The executable-boundary and first cabal-boundary sets are observations.

Budget (owner decision 2026-11-13): 240 s whole process locally, 300 s CI "Finished in", 10 s no-example. Headroom locally at the cabal boundary: 91 s in the worst of the three runs at the code head (149.0 s); at the earlier heads 104 s at 8 jobs under load (107 s in the six sampled runs) and 92 s at 4 jobs.

**CI** (acceptance item 9; the runner has 4 processors, so the default is 4 jobs, `RUNNER jobs=4 capabilities=4 (processors 4)`, then `PHASE sequential: 1 capability`). Three validation runs of this branch (the first two on identical code, their heads differing by the one catalog line that fixed the workflow guard; the third at `12c29156`, with the oracle of the printed lines, which failed under CI's colour and was then repaired):

| Run (head) | `terrain-runtime-tests` "Finished in" | `haskell-engine` job | Cache | `test.terrain` | `test.terrain-render-2d` |
| --- | ---: | ---: | --- | ---: | ---: |
| 43540991554 (`9a1b7ff5`), validation green | 128.13 s | 01:32:34Z to 01:40:25Z, 7 min 51 s | package store and build tree: hit on the exact key; no `Compiling` line in the job | 40.81 s | 66.54 s |
| 43539809123 (`83f14cc9`), `haskell-workflow` red (the owned-start guard, fixed by `9a1b7ff5`), `haskell-engine` green | 227.84 s | 01:19:06Z to 01:31:58Z, 12 min 52 s | both: hit on a restore key (a partial match), 28 `Compiling` lines in the job | 72.74 s | 135.82 s |
| 43567093134 (`12c29156`), `haskell-engine` red (the oracle's colour cases, repaired after it) | 244.18 s (838 examples, 7 failures) | 06:35:55Z to 06:48:33Z, 12 min 38 s | both: hit on a restore key, 17 `Compiling` lines in the job | 69.86 s | 134.85 s |

The cache state does not explain the difference in the suite's own time, since compilation is outside "Finished in". What the logs show is a slower runner in the second and third runs: the two groups this change does not touch ran 1.78 and 2.04 times slower in the second (`test.terrain` 40.81 to 72.74 s, `test.terrain-render-2d` 66.54 to 135.82 s) and 1.71 and 2.03 times slower in the third (69.86 s, 134.85 s), against 1.78 and 1.91 times for `terrain-runtime-tests`; the runner version is the same in all three (2.338.2). All three are under 300 s; CI headroom for the next suite additions is 300 minus the worst figure, 244.18 s, which is 55.8 s. The two groups of acceptance item 8 (`terrain-tests`, 905 examples; `terrain-render-2d-tests`, 558) passed in all three runs.

## Where the time went, base to routine

Per module and per example of 1 s or more, Hspec `--times` of the single-job routine run (`--jobs 1`, row above) against the base run
(829 examples, 901.3 s of Hspec, 1155.9 s whole process, taken with load about 10 from other projects). Modules under 4.5 s are omitted.

| Module (`test/Test/TerrainRuntime/`) | Base s | Routine s |
| --- | ---: | ---: |
| Store/Rebalance.hs | 389.4 | 31.6 |
| Store/Scattered.hs | 112.8 | 43.4 |
| Store/Large.hs | 110.0 | 16.7 |
| Store/Protocol.hs | 76.8 | 17.0 |
| Store/Evidence.hs | 37.5 | 20.7 |
| Store/FuzzTrees.hs | 30.2 | 15.2 |
| Storage/Memory.hs | 29.2 | 28.1 |
| Store/History.hs | 28.4 | 6.9 |
| Store/Trees.hs | 20.9 | 8.3 |
| Store/Fuzz.hs | 9.5 | 1.6 |
| Store/Bounds.hs | 7.3 | 6.6 |
| Store/Cycles.hs | 7.1 | 2.6 |
| Opacity.hs | 7.1 | 6.4 |
| Store/Boundary.hs | 6.5 | 5.6 |
| Storage/Classes.hs | 5.3 | 4.2 |
| Store/Allowance.hs | 4.7 | 4.6 |


| Base s | Routine s | Example (base location) | Disposition | Reason |
| ---: | ---: | --- | --- | --- |
| 186.4 | 22.6 | `Store/Rebalance.hs:241` keeps the root and every page legal through 3-level historie | reduced | protected family (independent checker after every commit; height 3 is asserted absolutely, reached from 1,700 links): 1 seed, 1,600+100 keys |
| 84.9 | 4.5 | `Store/Large.hs:244` keeps committing random batches, the checker agreeing after  | reduced | protected family: 1 seed of 3 |
| 73.4 | 1.6 | `Store/Rebalance.hs:229` keeps the root and every page legal through 2-level historie | reduced | protected family (height 2, the checker after every commit): 1 seed, 160+100 keys |
| 70.1 | 0.5 | `Store/Rebalance.hs:233` keeps the root legal through small histories whose root has  | reduced | protected family; the root-collapse reach assertion kept: sizes (30,30) of 24, seed 1 of 4 |
| 65.8 | 6.4 | `Store/Protocol.hs:268` reclaims the oldest entry of the fragmented store (64 disper | reduced | protected family: starting limit 8 of 9 |
| 55.2 | 10.7 | `Store/Scattered.hs:276` makes progress at every progress point of a long entry, at w | reduced | protected family: progress point 269 of 5 (the point that catches the whole-prefix control) |
| 26.0 | 4.6 | `Store/History.hs:138` keeps the ownership checker, the readers and maintenance in  | reduced | protected family: 1 seed of 6 (the 12,000-run fixture stays: the round-8 case needs it) |
| 17.7 | 0.3 | `Store/Rebalance.hs:549` keeps the tree legal and complete through random histories o | reduced | protected family, no recorded control reaches it: 1 seed, 2,500 operations |
| 17.3 | 1.6 | `Store/Rebalance.hs:545` keeps the tree legal and complete through random histories o | reduced | protected family; height 3 reach kept: 1 seed of 2, 5,000 operations of 14,000 |
| 14.1 | 3.8 | `Store/Large.hs:225` drains thousands of small retirement entries without the loo | reduced | protected family: 1,300 pinned commits of 3,000 |
| 12.9 | 1.3 | `Store/Scattered.hs:329` refuses jumps shorter and longer than the span checked in ev | reduced | protected family: forged jump 65 of 8 |
| 12.2 | 10.8 | `Store/Scattered.hs:498` drains by spilling first, then finishes an entry whose delet | kept | owner exception to requirement 4 (issue comment 6872272575): kept whole in both tiers; not a direct regression under 3(a), its input came from the manager's pre-check of 4d4146c2, not from the reviewer's; one exact sequence with exact counts (270-page entry, list at exactly looseCap, 64 spills, 462 transactions); unchanged |
| 11.9 | 5.4 | `Store/Trees.hs:57` splits leaves, internal pages and the root, and merges them  | reduced | class `grown >= 3` kept: 33 by 33 columns of 41 by 41 (side 16 of 20; 14 does not reach it) |
| 10.8 | 10.4 | `Storage/Memory.hs:783` a qualified-filesystem name that is a short slice of a large | kept | owner exception to requirement 4 (issue comment 6872272575): the two 2 MiB buffers are built with BC.replicate instead of packed from a String; same bytes, K = 24, same rules and controls; 10.4 s -> 8 ms |
| 10.5 | 5.7 | `Store/Evidence.hs:72` grows to several levels and gives them back | reduced | class `grown >= 3` kept: side 16 of 20 |
| 9.7 | 9.5 | `Store/Scattered.hs:229` makes progress through the public API with the real limits,  | kept | a single scenario with no parameter; protects the drain controls |
| 9.5 | 1.6 | `Store/Fuzz.hs:235` reads every record exactly or fails as corrupt, over fixed s | reduced | protected family: 1 seed of 6 |
| 9.3 | 3.0 | `Store/Evidence.hs:57` reference comparison: generated histories against the indepe | reduced | protected family: 1 seed of 3 |
| 7.9 | 2.4 | `Store/Large.hs:152` plans every batch size across the bounds, dispersed and clus | reduced | protected family: batch sizes 64 and 300 of 24 |
| 7.8 | 1.5 | `Store/FuzzTrees.hs:307` reads exactly as the reference or fails as corrupt, TreeLink | reduced | protected family: 1 seed of 5, in each of five trees |
| 7.3 | 1.3 | `Store/FuzzTrees.hs:307` reads exactly as the reference or fails as corrupt, TreeRuns | reduced | protected family: 1 seed of 5, in each of five trees |
| 7.0 | 2.6 | `Store/Evidence.hs:155` cycles | reduced | protected family: seed 202 of 3 |
| 7.0 | 2.4 | `Store/Rebalance.hs:167` keeps every page above the minimum through shortened and len | reduced | protected family: 1 seed of 3 |
| 6.6 | 0.8 | `Store/Scattered.hs:206` never reports a batch of any size as corruption: committed o | reduced | protected family: batch sizes 64 of 12 |
| 6.6 | 6.5 | `Store/Evidence.hs:76` transaction bounds: exactly 256 pages, one past refused, RAM | kept | exactly 256 pages, as Bounds.hs:165 |
| 5.9 | 5.3 | `Store/Bounds.hs:165` writes at most 256 pages: met exactly, refused one past, wit | kept | exactly 256 pages needs at least 15,600 runs (one write per leaf at stride 60); measures nothing process-wide |
| 5.6 | 5.4 | `Storage/Memory.hs:749` a directory that is a short slice of a large buffer costs th | kept | under 10 s at base; untouched |
| 5.5 | 5.4 | `Storage/Memory.hs:797` a filesystem name that is a short slice of a large buffer (a | kept | under 10 s at base; untouched |
| 5.2 | 0.3 | `Store/Rebalance.hs:552` keeps the tree legal and complete through random histories t | reduced | protected family; deletion splits reached: seed 12 of 16 |
| 5.0 | <0.3 | `Store/Scattered.hs:303` stays inside the window's bound on every layout and every pr | reduced | protected family: layout fragmented of 4 |
| 4.8 | 4.6 | `Store/FuzzTrees.hs:207` refuses a pointer that names a stale valid page of the same  | kept | see the families table |
| 4.5 | 0.8 | `Store/FuzzTrees.hs:307` reads exactly as the reference or fails as corrupt, TreeTodo | reduced | protected family: 1 seed of 5, in each of five trees |
| 3.8 | 3.5 | `Storage/Memory.hs:180` is measured, with nothing between two readings and around a  | kept | see the families table |
| 3.5 | <0.3 | `Store/Rebalance.hs:94` never refuses a legitimate deletion or reinsertion, and the  | reduced | protected family: the first of four hand-built trees (the round-10 case itself is a direct regression, unchanged) |
| 3.5 | 3.0 | `Storage/Classes.hs:417` keeps descriptors, tracking and allocation consistent, and t | kept | see the families table |
| 3.5 | 0.2 | `Store/Rebalance.hs:541` keeps the tree legal and complete through random histories o | reduced | protected family: 1 seed of 2, 2,000 operations of 8,000 |
| 3.0 | 2.9 | `Store/Trees.hs:51` agrees with the reference map and the independent traversal  | reduced | protected family: 1 seed of 3 |
| 3.0 | <0.3 | `Store/Trees.hs:51` agrees with the reference map and the independent traversal  | reduced | protected family: 1 seed of 3 |
| 3.0 | <0.3 | `Store/Trees.hs:51` agrees with the reference map and the independent traversal  | reduced | protected family: 1 seed of 3 |
| 2.9 | 2.1 | `Store/Scattered.hs:368` makes progress at work one with a window of exactly the at-o | reduced | protected family: 16 pinned versions of 5 counts |
| 2.9 | 0.5 | `Store/FuzzTrees.hs:307` reads exactly as the reference or fails as corrupt, TreeFree | reduced | protected family: 1 seed of 5, in each of five trees |
| 2.6 | 2.6 | `Store/Cycles.hs:202` keeps every pinned version, the partition and the reference  | reduced | protected family: seed 202 of 3 |
| 2.6 | 0.5 | `Store/Large.hs:199` reclaims under a reserve too small for the larger chunks by  | kept | the reserve boundary; under the 3 s line after the fixture shrank |
| 2.5 | 0.5 | `Store/FuzzTrees.hs:307` reads exactly as the reference or fails as corrupt, TreeReti | reduced | protected family: 1 seed of 5, in each of five trees |
| 2.5 | <0.3 | `Store/Cycles.hs:202` keeps every pinned version, the partition and the reference  | reduced | protected family: seed 202 of 3 |
| 2.3 | 2.3 | `Store/History.hs:148` finishes a retirement entry whose reclaimed prefix was reuse | kept | direct regression (the round-8 reclaimed prefix), unchanged |
| 2.3 | 2.3 | `Storage/Memory.hs:768` a directory that is a short slice of a large buffer costs th | kept | retention row at 8 instances already |
| 2.3 | 2.3 | `Store/Protocol.hs:412` removes the cell between two runs whose chains are 12 and 64 | kept | under 3 s, not a family of the safeguard |
| 2.3 | 2.2 | `Store/Scattered.hs:407` plans through checkpoints exactly the plan one window would  | kept | single scenario, 2.3 s |
| 2.1 | <0.3 | `Store/Rebalance.hs:94` never refuses a legitimate deletion or reinsertion, and the  | reduced | protected family: the first of four hand-built trees (the round-10 case itself is a direct regression, unchanged) |
| 2.0 | 1.7 | `Storage/Lifecycle.hs:239` keeps every invariant for every kind of work, in every phase | kept | under 3 s, not a family of the safeguard |
| 2.0 | 1.8 | `Store/Boundary.hs:30` accepts and runs a client that plans, writes, publishes and  | kept | under 3 s, not a family of the safeguard |
| 1.9 | <0.3 | `Store/Cycles.hs:202` keeps every pinned version, the partition and the reference  | reduced | protected family: seed 202 of 3 |
| 1.9 | 1.9 | `Store/Protocol.hs:436` caps the reads of a read phase at what its typed set can hol | kept | under 3 s, not a family of the safeguard |
| 1.8 | 1.7 | `Store/AdmissionSpec.hs:163` charges at least a page per entry, so zero-byte and tiny cre | kept | under 3 s, not a family of the safeguard |
| 1.8 | 1.4 | `Store/Scattered.hs:262` finishes the reviewer's entry (270 dispersed pages, all but  | kept | direct regression (the reviewer's entry), unchanged |
| 1.4 | 1.1 | `Opacity.hs:35` accepts and runs a client that composes the public service | kept | under 3 s, not a family of the safeguard |
| 1.4 | 1.4 | `Store/Allowance.hs:160` keeps a pinned reader's pages in the used bytes, then reclai | kept | under 3 s, not a family of the safeguard |
| 1.4 | 1.3 | `Store/Protocol.hs:584` funds the ACTUAL credits of a removal, of a discovery unit a | kept | under 3 s, not a family of the safeguard |
| 1.4 | 1.4 | `Store/Allowance.hs:134` refuses ordinary history with the protected 8 MiB intact, an | kept | under 3 s, not a family of the safeguard |
| 1.4 | 1.4 | `Store/Evidence.hs:113` fault and reader traces | kept | under 3 s, not a family of the safeguard |
| 1.3 | 1.3 | `Store/Evidence.hs:136` exhaustion, the protected reserve and incremental reclamatio | kept | under 3 s, not a family of the safeguard |
| 1.3 | 1.0 | `Storage/Classes.hs:700` returns the shared admission to exactly its starting figures | kept | under 3 s, not a family of the safeguard |
| 1.3 | 0.1 | `Store/Evidence.hs:160` allocation: work independent of the history | kept | under 3 s, not a family of the safeguard |
| 1.2 | <0.3 | `Store/Rebalance.hs:94` never refuses a legitimate deletion or reinsertion, and the  | reduced | protected family: the first of four hand-built trees (the round-10 case itself is a direct regression, unchanged) |
| 1.2 | 1.2 | `Store/Scattered.hs:220` plans the largest chunk through checkpoints: the window neve | kept | under 3 s, not a family of the safeguard |
| 1.2 | 1.1 | `Store/Readers.hs:91` pins the version it was taken at, shares unchanged pages wit | kept | under 3 s, not a family of the safeguard |
| 1.2 | 1.1 | `Store/Rebalance.hs:94` never refuses a legitimate deletion or reinsertion, and the  | reduced | protected family: the first of four hand-built trees (the round-10 case itself is a direct regression, unchanged) |
| 1.1 | 1.0 | `Store/Protocol.hs:515` discovers through chains of 40 links at EXACTLY the promised | kept | under 3 s, not a family of the safeguard |
| 1.1 | 1.3 | `Storage/Opacity.hs:27` accepts and runs a client that composes the public backend | kept | under 3 s, not a family of the safeguard |
| 1.1 | 1.0 | `Store/Readers.hs:44` keeps every pinned version's answers through later writes, e | kept | under 3 s, not a family of the safeguard |
| 1.0 | 1.4 | `Store/Scattered.hs:187` is a valid store the independent checker accepts, three leve | kept | under 3 s, not a family of the safeguard |


## Representatives: routine and full parameters

Every reduced family keeps every assertion of the original; a literal that only restated a fixture's scale is restated
(`Large`: retired pages and rounds, `Rebalance` tree level: operations as seeds x operations, `Fuzz` and `FuzzTrees`: mutations as
50 or 60 x seeds), the original stays in the probe. A class stated absolutely (tree height 2 or 3, `grown >= 3`, a collapsed root,
deletions that split a node, exactly 256 pages) is never rescaled; where a smaller parameter did not reach it, the family is not
reduced that far (3-level histories under 1,700 keys, growth under side 15, an exact 256-page plan under 15,600 runs). The direct
regressions are unchanged and routine: `Rebalance` `:76`, `:151`, `:261`, `Protocol` `:182`, `Scattered` `:262`, `History` `:148`.

Requirement 6, the union: all 829 example titles of the base run appear in the routine run (828 examples, the single-job run above) or in the full-depth run (96 examples): 0 missing. A reduced example keeps its title and runs the routine parameters below in the routine suite and the full parameters in the probe; an example kept unchanged runs in the routine suite (and again in the probe where its module is listed).

| Family (module, base location) | Routine parameters | Full parameters | Controls attributed (routine catches each) |
| --- | --- | --- | --- |
| Rebalance 2-level histories (`:229`) | 1 seed; 160 source + 100 run keys | seeds 1-6; 700 + 500 keys | none; reach `h0 == 2` kept |
| Rebalance small histories, root collapse (`:233`) | size (30,30), seed 1 | 24 sizes x seeds 1-4 (96 histories) | 4 (repack after insertion), 5 (insertion skips the root collapse); reach "some root collapsed" kept |
| Rebalance 3-level histories (`:241`) | 1 seed; 1,600 + 100 keys | seeds 1-2; 2,800 + 900 keys | none; reach `h0 == 3` kept (1,400 + 100 keys reaches only 2) |
| Rebalance minimum fill, 300 commits (`:167`) | seed 1 | seeds 1-3 | none (control 4 is caught by the direct 51-link example) |
| Rebalance deletion histories (`:94`) | first hand-built tree | four hand-built trees | none (control 1 is caught by the direct round-10 example) |
| Rebalance tree level: mixed, long, banded, edge (`:541-:552`) | seeds 1, 3, 5, 12; 2,000, 5,000, 2,500, 1,500 operations | seeds 1-2, 3-4, 5-8, 9-24; 8,000, 14,000, 10,000, 1,500 | 4 (mixed), 6, 7 (edge, deletions that split a node); reach `tallest >= 2/3` and `splits > 0` kept; the operation literal restated as seeds x operations |
| Large (fixture, `:152`, `:225`, `:244`) | 3,500 links, 2,400 retired pages, 20 recycling rounds; batch sizes 64, 300; 1,300 pinned commits; seed 1 | 12,000 links, 14,100 retired pages, 150 rounds; 24 sizes; 3,000 commits; seeds 1-3 | 2 (node fit at 8 bytes: needs an inner page of 63-66 children, 3,300 links and up), 30, 31, 32 (bookkeeping), 33 (spill); the fixture literals restated (`>= 2,400` retired, `> 20` rounds) |
| Scattered progress points (`:276`) | 269 | 0, 63, 64, 128, 269 | 33 (spill), 35 (whole prefix at the end: only the longest entry) |
| Scattered forged jumps (`:329`) | 65 | 1, 10, 63, 64, 65, 128, 200, 269 | 36, 49 |
| Scattered batch sizes (`:206`), layouts (`:303`), pinned versions (`:368`) | 64; fragmented; 16 | 12 sizes; four layouts; 1, 2, 4, 8, 16 | 30 (sizes); 42 (layouts, pins) |
| Protocol fragmented entry (`:268`) | starting limit 8 | 1, 2, 3, 7, 8, 16, 33, 63, 64 | 42 (maintenance ignores the work limit) |
| History random histories (`:138`) | seed 1; fixture 12,000 runs | seeds 1-6 | none attributed |
| Trees (`:51`, `:57`), Evidence growth (`:72`) | seed 11; 33 x 33 columns (side 16) | seeds 11, 29, 47; side 20 | none; reach `grown >= 3` kept |
| Evidence (`:57`, `:155`) | seed 11; cycles seed 202 | seeds 11, 29, 47; cycles 101, 202, 303 | 22 (plans without the pins: seed 202 of the cycles only) |
| Fuzz (`:235`) | seed 101 (60 mutations) | seeds 101-606 (360) | none (6 landing controls are not caught at full depth either) |
| FuzzTrees (`:307`) | seed 11 in each of five trees (50 mutations) | seeds 11-55 (250) | 16 (child checksum), 23 (under-full rule) |
| Cycles (`:202`) | seed 202 | 101, 202, 303 | 22 |



The direct regressions of requirement 3(a), all unchanged by the diff (head locations): `Rebalance.hs:86` (round 10), `:161`
(the round-14 reproduction), `:273` (the round-15 sequence); `Protocol.hs:188` (the reviewer's repro at limits 1, 2, 3);
`Scattered.hs:271` (the reviewer's entry: 270 dispersed pages, progress 269) and the round-11 boundary examples (64 dispersed
updates against 68 bookkeeping pages); `History.hs:156` (round 8: a reclaimed prefix reused and retired again). `Scattered.hs:498` (round 14, a loose list at exactly its
cap) is not one of them: it is kept whole in both tiers by the owner's decision (issue comment 6872272575) as an exception to
requirement 4, and its input came from the manager's pre-check of `4d4146c2`, not from the reviewer's. Its sequence is exact: the
270-page entry, the list at exactly `looseCap`, 64 spills, 462 transactions.
Reduced examples whose titles cite a round or a
reviewer keep the exact sequence whole elsewhere: `Rebalance.hs:244` ("the reviewer's shape, many sizes") -> `:273`;
`Scattered.hs:285` (round 13 progress points) -> point 269 is the reviewer's entry, run whole at `:271`; `:337` and `:353`
(round 13) name no reviewer input, their routine jump 65 and 16 pins are members of the generated families; `Protocol.hs:274`
-> `:188`.

Kept examples of 3 s or more: the memory rows (`Store/Memory.hs`, `Storage/Memory.hs`) measure the whole process with their own
rules and run alone on one capability; the exact-256-page examples need 15,600 runs; `Scattered.hs:229` (9.7 s at base) is a single
scenario with no parameter and under 10 s. `Storage/Memory.hs:783` took 10.8 s at base because its two 2 MiB inputs were
packed from Strings (K and the rules were never the cost); by the owner's decision (issue comment 6872272575) they are built
with `BC.replicate`, an exception to requirement 4: the same bytes, K = 24, the same rules, and it takes 8 ms instead of 10.4 s, with
the three copy-undone controls (62, 63, 64) still failing their rows and the baseline passing.

## Safeguard of requirement 3(c)

Method. A scratch worktree off the head (never the delivery tree) carries the store and storage libraries with switchable
mutations, `HET_MUT=<n>`, uncommitted: the control is applied by an edit of the named site and restored with
`git checkout`; the delivered tree contains none. Each control was run against the routine representatives (the families'
module names above, `--match` by their describe titles) and, for every family a routine representative missed, against the
family's full depth. Attribution follows the issue: a control belongs to a family when its record names that family's example, or
when re-applying it at the base makes the family's full-depth examples fail. A routine representative that missed a control the
full depth catches was enlarged until it caught it (three: progress point 269, cycles seed 202, 3,500 links). The baseline (no
mutation) passes at both depths. The table gives, per control, the routine failing examples of the reduced families and one failure.

| # | Control | Record | How applied | Caught at routine depth by (reduced families) | Failure |
| ---: | --- | --- | --- | --- | --- |
| 1 | the merge repack sizes an internal entry at 8 bytes | tra20 round 10; #675 O21 | Tree.rebalanceChild: inner entry size -4 | Rebalance (1: redistributes two internal siblings whose combin…) | a legitimate operation was refused: Integrity (BadPage (EntryTooLarge 4329) (PageNo 122)) |
| 2 | the fit of a rewritten internal node at 8 bytes | tra20 round 10; #675 O21 | Tree.bodyBytesOf (NInner): entry size -4 | Evidence (3: grows to several levels and gives them back…); FuzzTrees (13: has every tree several pages deep, with the reti…); History (2: keeps the ownership checker, the readers and mai…); Large (5: builds a store that is deep, full of retirement …); Protocol (1: reclaims the oldest entry of the fragmented stor…); Rebalance (6: redistributes two internal siblings whose combin…); Scattered (7: plans the largest chunk through checkpoints: the…); Trees (1: splits leaves, internal pages and the root, and …); 10 in unreduced examples | a legitimate operation was refused: Integrity (BadPage (UnderFull 924) (PageNo 118)) |
| 3 | the split at 8 bytes (an equivalent mutant) | tra20 round 10; #675 O21 | Tree.exitNode splitEven: entry size -4 | — |  |
| 4 | the repack after an insertion not applied | tra20 round 14; #675 O28 | Tree.insertKey: no rebalanceChild | Rebalance (3: replaces the values of 51 run links one by one b…); 1 in unreduced examples | page 93 under-full: 989 |
| 5 | insertion skips the root collapse | tra20 round 15; #675 O31 | Tree.insertKey: exitRoot not called on InsOne | Rebalance (1: keeps the root legal through small histories who…); 1 in unreduced examples | expected: False |
| 6 | deletion rewrites an over-full parent instead of splitting it | tra20 round 15; #675 O31 | Tree.deleteKey: rewrite when over-full | Rebalance (3: splits a parent a deletion's repack made over-fu…) | expected: [] |
| 7 | a deletion's root split ignored by the exit | tra20 round 15; #675 O31 | Tree.deleteKey: InsTwo root keeps the left half | Rebalance (2: splits a parent a deletion's repack made over-fu…) | expected: 3 |
| 8 | neighbours of the landing node not loaded | tra20 round 9; #675 O18 | Tree.validateLanding: sides skipped | —; 1 in unreduced examples | expected: (True,True) |
| 9 | a miss concluded without the landing validation | tra20 round 9; #675 O18 | Tree.lookupKey: validateLanding skipped | —; 1 in unreduced examples | expected: (True,True) |
| 10 | a floor concluded without it | tra20 round 9; #675 O18 | Tree.floorKey: validateLanding skipped | — |  |
| 11 | a ceiling concluded without it | tra20 round 9; #675 O18 | Tree.ceilKey: validateLanding skipped | — |  |
| 12 | a scan start concluded without it | tra20 round 9; #675 O18 | Tree.rangeKeys: validateLanding skipped | — |  |
| 13 | a reachability conclusion without it | tra20 round 9; #675 O18 | Tree.livePageAt: validateLanding skipped | — |  |
| 14 | a key below the first separator concluded absent | tra20 round 9; #675 O18 | Tree.lookupKey: Nothing from chooseChild answers absent | — |  |
| 15 | the descent as at the round-9 head (8 and 14) | tra20 round 9; #675 O18 | 8 and 14 together | —; 1 in unreduced examples | expected: (True,True) |
| 16 | the child checksum not compared | tra20 round 9; #675 O19 | Tree.load: ChildChecksum test skipped | FuzzTrees (7: refuses a pointer that names a stale valid page …) | expected: [] |
| 17 | a cached node used whatever checksum the pointer records | tra20 round 9; #675 O19 | Tree.hotAgrees: always True | — |  |
| 18 | a new page's entry records another checksum than its child's | tra20 round 9; #675 O19 | Tree.assign: child checksum +1 | Cycles (1: keeps every pinned version, the partition and th…); Evidence (7: reference comparison: generated histories agains…); Fuzz (2: reads every record exactly or fails as corrupt, …); FuzzTrees (13: has every tree several pages deep, with the reti…); History (2: keeps the ownership checker, the readers and mai…); Large (6: builds a store that is deep, full of retirement …); Protocol (2: plans the smallest unit of discovery (one connec…); Rebalance (9: redistributes two internal siblings whose combin…); Scattered (4: commits 64 dispersed updates at the real reserve…); Trees (2: agrees with the reference map and the independen…); 13 in unreduced examples | page 124 records checksum 563429364 for child 122 which carries 563429363 |
| 19 | the window holds no root checksums | tra20 round 9; #675 O20 | Tree.windowTrust: empty root map | Cycles (1: keeps every pinned version, the partition and th…); Evidence (8: reference comparison: generated histories agains…); Fuzz (2: reads every record exactly or fails as corrupt, …); FuzzTrees (13: has every tree several pages deep, with the reti…); History (2: keeps the ownership checker, the readers and mai…); Large (6: builds a store that is deep, full of retirement …); Protocol (5: the reviewer's repro: after one batch through a …); Rebalance (8: redistributes two internal siblings whose combin…); Scattered (15: needs more than 68 bookkeeping pages for 64 disp…); Trees (2: agrees with the reference map and the independen…); 18 in unreduced examples | a legitimate operation was refused: Integrity (BadPage RootChecksumMissing (PageNo 120)) |
| 20 | a transaction publishes the old checksums of the roots it wrote | tra20 round 9; #675 O20 | Plan.rootCrcsAfter: the old checksum | Cycles (1: keeps every pinned version, the partition and th…); Evidence (8: reference comparison: generated histories agains…); Fuzz (2: reads every record exactly or fails as corrupt, …); FuzzTrees (13: has every tree several pages deep, with the reti…); History (2: keeps the ownership checker, the readers and mai…); Large (6: builds a store that is deep, full of retirement …); Protocol (5: the reviewer's repro: after one batch through a …); Rebalance (9: redistributes two internal siblings whose combin…); Scattered (4: commits 64 dispersed updates at the real reserve…); Trees (2: agrees with the reference map and the independen…); 17 in unreduced examples | Bad (ChildChecksum 558311296 2829538625) (PageNo 124) |
| 21 | an unchecked root (a root with no recorded checksum is read) | tra20 round 9; #675 O20 | Tree.load: RootChecksumMissing skipped | — |  |
| 22 | plans and maintenance without the pins | tra20 round 9; #675 O9 | Model.pinnedRoots: empty | Cycles (1: keeps every pinned version, the partition and th…); Evidence (2: fault and reader traces…); Scattered (1: keeps facts for the same state and drops them fo…) | expected: True |
| 23 | the minimum-fill rule not applied at descent | tra20 round 12; #675 O27 | Tree.load: UnderFull test skipped | FuzzTrees (1: refuses a re-sealed under-full non-root leaf and…); Scattered (1: answers an integrity result, never a window resu…) | a commit through an under-full inner of the retirement tree was not refused as corruption: |
| 30 | the bookkeeping count not checked before numbering | tra20 round 11; #675 O22 | Plan.planDelta: OutMoreBookkeeping not raised | Large (1: answers a bookkeeping need past the reserve with…); Scattered (3: needs more than 68 bookkeeping pages for 64 disp…) | a need past the reserve was not the shrinkable bookkeeping result: Refused (Integrity (Bro |
| 31 | the larger supply never asked for | tra20 round 11; #675 O22 | Plan.planDelta retry: no further attempt | Large (1: answers a bookkeeping need past the reserve with…); Scattered (2: commits 64 dispersed updates at the real reserve…) | 64 dispersed updates were not planned: Refused (Capacity (BookkeepingExceeded 69)) |
| 32 | a bookkeeping overflow not shrinkable | tra20 round 11; #675 O22 | Plan.shrinkable: BookkeepingExceeded False | Large (1: answers a bookkeeping need past the reserve with…) | predicate failed on: Capacity (BookkeepingExceeded 7) |
| 33 | the spill of the loose list removed | tra20 round 11; #675 O23 | Plan.planReclaim: excess = 0 | Large (1: drains thousands of small retirement entries wit…); Scattered (3: makes progress through the public API with the r…); 1 in unreduced examples | the drain did not end |
| 35 | the whole consumed prefix verified at the end of the entry | tra20 round 13; #675 O25 | Plan.planReclaim: prefix instead of its last 64 | Scattered (2: finishes the reviewer's entry (270 dispersed pag…) | expected: True |
| 36 | no verification of the consumed prefix | tra20 round 13; #675 O25 | Plan.planReclaim: no pages proven | Scattered (1: refuses jumps shorter and longer than the span c…) | a progress field of 65 over pages still indexed was not refused: Planned (Plan {plIdentity |
| 37 | the spill not proven | tra20 round 14; #675 O29 | Plan.planReclaim: provenFree skipped for the spill | — |  |
| 38 | a spilled page that the supply also takes not refused | tra20 round 14; #675 O29 | Plan.planReclaim: duplicate test skipped | — |  |
| 39 | the spill not drained first | tra20 round 14; #675 O30 | Plan.planReclaim: soft-cap test off | Scattered (1: drains by spilling first, then finishes an entry…); 1 in unreduced examples | a spill above the soft cap did not lower the list: (1024,1017,1) |
| 40 | discovery reads the raw window limit | tra20 round 16; #675 O34 | Model.planDiscovery: windowWork | Protocol (2: the reviewer's repro: after one batch through a …) | at limit 1 the remaining discovery was Refused (Invalid (DiscoveryRefusal (CapacityBlocked |
| 41 | the discovery atomic unit is worstEdgeWrites - 1 | tra20 round 16; #675 O34 | Model.planDiscovery: unit - 1 | Protocol (2: the reviewer's repro: after one batch through a …) | at limit 1 the remaining discovery was Refused (Invalid (DiscoveryRefusal (CapacityBlocked |
| 42 | maintenance ignores the work limit | tra20 round 16; #675 O34 | Plan.chunkSizes: top = maxReclaimPages | Protocol (1: reclaims the oldest entry of the fragmented stor…); Scattered (3: stays inside the window's bound on every layout …) | fragmented: (Planned (Plan {plIdentity = PlanIdentity {pidStore = StoreIdentity {siArena = |
| 43 | a retry that does not halve the work | #675 O24 | Tree.reduceWork: same work | Protocol (1: reclaims the oldest entry of the fragmented stor…); 1 in unreduced examples | the protocol did not settle in 102574 steps |
| 44 | facts not trusted | tra20 round 17; #675 O26 | Tree.windowFactsFor: facts dropped | Protocol (2: plans the smallest unit of discovery (one connec…); Scattered (5: plans the largest chunk through checkpoints: the…); 8 in unreduced examples | planning did not settle: too many pending pages |
| 45 | a freed page need not be indexed under its entry | tra20 round 6; #675 O12 | Plan.unindexRetired: version test skipped | — |  |
| 46 | replaced pages not indexed as retired | tra20 round 7; #675 O12 | Plan.indexRetired: nothing inserted | Cycles (1: keeps every pinned version, the partition and th…); Evidence (6: reference comparison: generated histories agains…); FuzzTrees (5: has every tree several pages deep, with the reti…); History (2: keeps the ownership checker, the readers and mai…); Large (5: builds a store that is deep, full of retirement …); Protocol (4: the reviewer's repro: after one batch through a …); Rebalance (9: redistributes two internal siblings whose combin…); Scattered (3: needs more than 68 bookkeeping pages for 64 disp…); Trees (2: agrees with the reference map and the independen…); 8 in unreduced examples | the retired-page index does not match the retirement lists: 0 indexed, 5 listed |
| 47 | the ownership proof removed | tra20 round 6-7; #675 O1, O2 | Plan.provenFree: returns at once | —; 1 in unreduced examples | expected: (True,True) |
| 48 | a reachable tree page never refused | tra20 round 6-7; #675 O2, O5 | Plan.unreachable: no refusal | — |  |
| 49 | an index record under the entry's own version accepted | tra20 round 7-8; #675 O15 | Plan.goneFromIndex: version - 1 | Scattered (1: refuses jumps shorter and longer than the span c…) | a progress field of 65 over pages still indexed was not refused: Planned (Plan {plIdentity |
| 50 | pinned roots not consulted when proving a page unreachable | tra20 round 6; #675 O2, O9 | Plan.unreachable: no pinned roots | — |  |
| 51 | the fingerprint ignored (facts trusted for any state) | tra20 round 17; #675 O26 | Tree.windowFactsFor / windowCheckpoint: always the same state | Scattered (1: keeps facts for the same state and drops them fo…); 1 in unreduced examples | expected: 0 |
| 52 | a checkpoint answered as the typed window result | tra20 round 17; #675 O26 | Plan.proving: checkpoint refused as capacity | Protocol (1: reclaims the oldest entry of the fragmented stor…); Scattered (2: plans the largest chunk through checkpoints: the…) | the largest chunk was not planned: Refused (Capacity (WindowBytesExceeded 1307840)) |
| 53 | a checkpoint that carries no new fact | tra20 round 17; #675 O26 | Plan.proving: empty facts allowed | Protocol (1: reclaims the oldest entry of the fragmented stor…); Scattered (1: answers the typed window result, never a checkpo…) | planning did not settle: too many pending pages |
| 54 | a retirement-owned page may be overwritten | tra20 round 7; #675 O12 | Plan.provenFree: notRetired accepts | — |  |
| 55 | a loose page that is also a free extent accepted | tra20 round 7; #675 O1 | Plan.provenFree: looseNotFree accepts | — |  |
| 56 | the root collapse follows single children without level or bounds checks | tra20 round 3; #675 O8 | Tree.collapseRoot: unchecked load | — |  |
| 57 | rebalancing loads its siblings without their separator bounds | tra20 round 2; #675 O8 | Tree.rebalanceChild: unchecked load | — |  |
| 59 | a loose page outside the used space accepted | tra20 round 4 sweep; #675 O1 | Plan.takeSupply: used-space test off | — |  |
| 60 | a page handed out twice by one supply | tra20 round 4 sweep; #675 O1 | Plan.takeSupply: distinctness test off | — |  |
| 61 | a free extent reaching past the used space | tra20 round 4 sweep; #675 O2 | Plan.takeSupply: extent test off | — |  |
| 62 | a volume profile keeps its filesystem name as a view of the mount table's buffer (the copy undone) | tra21 round 6 | Storage.Volume.profileOf: BC.copy removed | Storage.Memory retention rows (2: a directory that is a short slice of a large buf…) | predicate failed on: 4565.0 |
| 63 | an open keeps its directory as a view of its buffer (the copy undone) | tra21 round 6 | Storage.Service.submitOpen: BS.copy removed | Storage.Memory retention rows (2: a directory that is a short slice of a large buf…) | predicate failed on: 2098281.0 |
| 64 | a configuration keeps its qualified names as views (the copy undone) | tra21 round 6 | Storage.Types.mkStorageConfig: BS.copy removed | Storage.Memory retention rows (1: a qualified-filesystem name that is a short slic…) | predicate failed on: 4194546.0 |

### The isolation of the parallel group

The review's bindings, each with its control (the whole routine suite run under each):

| # | Control (applied in the scratch tree, uncommitted) | Where it is caught | Failure |
| ---: | --- | --- | --- |
| 71 | an example that reads the live heap (`Store.Bounds`) placed in the parallel group | the first measuring example of the module | a live-heap reading must run alone but 8 parallel examples are running |
| 72 | the memory rows (`Store.Memory`) placed in the group | the table example, at the first lazily built row | Memory.mPage must run alone but 8 parallel examples are running |
| 73 | a storage example (files, workers) placed in the group | `Storage.Open`, at the environment's entry | a storage example (files, workers) must run alone but 8 parallel examples are running |
| 74 | the guard does not return the runtime to one capability | every sequential example (739 fail) | a sequential example must run on one capability but 8 are active |
| 75 | a parallel example starts a helper (itself counted) that outlives it | the first sequential example and each after it (739 fail) | a sequential example started while 1 parallel examples are running |

A parallel example's body, setup and cleanup are inside the counted scope on every exit (a failure and an exception included:
`Isolation` has an example that shows the count back at 0 after both), and a helper is counted or not allowed (control 75).
What the guard cannot see is a file, thread or clock used by a parallel example that calls none of the guarded entry points: the
rule in `Test.TerrainRuntime.Parallel` and the review of the list keep those out; the guarded entry points are the live-heap and
allocation readings, the storage and service environments, and the lazily built rows.

### The printed lines

Two writers share standard output: the examples and the runner's formatter, which writes an item's text and its newline as
separate writes. `Test.TerrainRuntime.Output` holds one lock and a record of where the handle is (at a line start; after transient
text; mid-line). `printLine` writes its line with its newline as one write under the lock, after nothing, an erase or a newline by
that record, and every formatter the runner can select is wrapped so that each of its events runs under the same lock, to its end
(Hspec's format returns when the event has been written) and moves the record by what the event left on the line. Written through
it: every example of the parallel group, the suite's own sequential lines and the formatter. Written directly, with no lock: the
sequential examples of `Storage/*` (#663's, unedited); a sequential item starts only after the reporting thread has written every
earlier event and its own start, and the formatter is idle until the item ends (`Runner.JobQueue.runSequentially`,
`Runner.Eval.reportItem`, `Format.monadic`), and the isolation guard keeps every parallel example away.

What each kind of event leaves on the line, for each formatter, as the oracle observed it (the bytes of each event, compared with
the model `eventEffect` for a success, a pending and a failing item with info lines, in all three modes below). "Nothing" leaves
the record as it was; "ends a line" makes it a line start; "transient" (an item's start or progress, only when progress is
reported) writes text and an erase that the handle holds back, so the record says the line is open (a line printed to a handle that
is not a terminal begins with a newline, on a terminal with the erase); "dot" is content with no newline.

| Event | `checks` (the default) | `specdoc` | `progress` | `failed-examples` | `silent` |
| --- | --- | --- | --- | --- | --- |
| started | ends a line | ends a line | nothing | nothing | nothing |
| group started | ends a line | ends a line | nothing | nothing | nothing |
| group done | nothing | nothing | nothing | nothing | nothing |
| progress | transient, or nothing | transient, or nothing | nothing | nothing | nothing |
| item started | transient, or nothing | nothing | nothing | nothing | nothing |
| item done (success, pending, failure) | ends a line | ends a line | dot | nothing | nothing |
| done | ends a line | ends a line | ends a line | ends a line | nothing |

A formatter the model does not name leaves every event open: where the model is not certain the record is the one that costs a
newline, never a damaged record. Progress is reported when colour is on and neither GitHub Actions nor Buildkite is detected (in
practice on a terminal). The runner then hides the cursor before the first event and shows it again right after the last, with no
newline: these two are the only bytes it writes to standard output outside a formatter's events (`Runner.withHiddenCursor`; the
usage text of `--help` is written before the suite prints anything and ends the process), so the record is "after transient text"
at the start and after the run. Where progress is not reported nothing changes: the catalog command's output is byte for byte what
it was without the model (compared on `--match "TRA-20 evidence"`, a fixture and isolation selection and the no-example selection,
locally and under `GITHUB_ACTIONS=true`, apart from the time and the allocation counters).

The oracle (`Test.TerrainRuntime.OutputSpec`, sequential, 48 examples, holding the output lock while it redirects standard output
to a file) has two halves. It drives each guarded formatter directly, with no scheduling in it: built as the runner builds it (the
same `guardFormatters`, a real format configuration, the cursor hidden first when progress is reported) and fed the complete event
sequence of a small run (a start, a group, three items whose results are a success, a pending and a failure with info lines,
progress, the end of the group and of the run, the cursor shown), in each of fifteen cells (five formatters, three modes: colour
off; colour on as GitHub Actions sets it; colour on with progress). A record is printed through the same output at each of the 12
positions (before the first event, after each event but the last, after the run), all together and each alone, and on the raw
bytes each is a whole line at a line start; the formatter's own text is unchanged by the records; and the bytes each event wrote
by itself equal the model. The reviewer's case is kept by name: a run through `runSpec` that holds the first item's start until an
example has printed after the run's start, for each formatter with progress reported. The other half runs a parallel spec of 120
examples printing 20 records each (2,400 records beside 120 item lines) through `Runner.pinnedConfig` (the suite's defaults with
the formatter, colour, unicode and job count given), at 8 jobs on 8 capabilities, per formatter and mode, and a group of 40 parallel
examples followed by 100 sequential examples in nested describes writing 3 records each directly with `putStrLn`: every record a
whole line at a line start and once (on the raw bytes in the progress mode), every other line one the formatter writes whole, a
colour sequence recognized by its form and reset before the newline. The nested runs take nothing from their environment: no
`.hspec` file, no `HSPEC_*` variable, no command line, `GITHUB_ACTIONS` and `BUILDKITE` pinned; the oracle passes under
`GITHUB_ACTIONS=true`, `NO_COLOR`, `BUILDKITE`, `HSPEC_*`, `HSPEC_OPTIONS`, a `.hspec` file and `LANG=C`, which the outer run reads
and the nested runs do not. In the progress mode the direct records of #663's examples are checked on the rendered capture only
(a file keeps them after their item's transient text).

Controls, each run against the oracle: with the formatter's events not under the lock, three of the five formatters fail in each
of 3 runs (malformed records of 2,400: default 38, 23, 33; `specdoc` 44, 9, 20; `progress` 87, 98, 102) and 15, 15 and 14 of the
28 examples then in it fail under `GITHUB_ACTIONS=true`; with a state rule that decides by the kind of event and not by what it
wrote, `failed-examples` and `silent` fail with progress reported at 6 and 7 of the positions and in the reviewer's case (4
examples, 15 positions); with the state after the run not marked open, the five formatters fail with progress reported at the
position after the run (5 examples).

What was delivered: two of the 20 retained logs of the runs above had a record on a formatter line (the 1-job run and one 4-job run,
neither an acceptance run); every record was whole in itself, and no figure in this record came from either line.

### Controls outside every reduced family

For each control listed above as caught by no reduced family: the example of the whole suite that catches it (the routine run of every module under the control; the full-depth probe catches none of them), or the plain statement that none does. The none-does controls are findings outside this issue: the suite on the base does not observe them either (the base runs the same unreduced examples for them).

| # | Control | Example of the whole suite (routine run of every module, plus the full-depth probe, which catches none of these) that catches it |
| ---: | --- | --- |
| 3 | the split at 8 bytes (an equivalent mutant) | none |
| 8 | neighbours of the landing node not loaded | the read phase: records are facts, a window never holds more / discovers through chains of 40 links at EXACTLY the promised bound of ; windows, tokens and accounting bound to their store / names the previous leaf a floor lookup waits for when a separator was  |
| 9 | a miss concluded without the landing validation | the read phase: records are facts, a window never holds more / discovers through chains of 40 links at EXACTLY the promised bound of ; windows, tokens and accounting bound to their store / names the previous leaf a floor lookup waits for when a separator was  |
| 10 | a floor concluded without it | none |
| 11 | a ceiling concluded without it | none |
| 12 | a scan start concluded without it | none |
| 13 | a reachability conclusion without it | none |
| 14 | a key below the first separator concluded absent | none |
| 15 | the descent as at the round-9 head (8 and 14) | windows, tokens and accounting bound to their store / names the previous leaf a floor lookup waits for when a separator was  |
| 17 | a cached node used whatever checksum the pointer records | the private page codec against independent bytes / refuses a child whose page carries another checksum than its parent re |
| 21 | an unchecked root (a root with no recorded checksum is read) | the private page codec against independent bytes / refuses a root with no recorded checksum in every production window, a |
| 37 | the spill not proven | page ownership against forged records with valid checksums / proves every loose page maintenance hands to the allocator tree, at th |
| 38 | a spilled page that the supply also takes not refused | none |
| 45 | a freed page need not be indexed under its entry | page ownership against forged records with valid checksums / refuses a retirement entry whose version was lowered past a pinned rea; page ownership against forged records with valid checksums / refuses a retirement list that names a page the retired-page index hol |
| 47 | the ownership proof removed | the read phase: records are facts, a window never holds more / discovers through chains of 40 links at EXACTLY the promised bound of ; page ownership against forged records with valid checksums / refuses a free extent that offers a live page, whichever live page it ; page ownership against forged records with valid checksums / refuses a free extent that offers a page only a pinned reader reaches, (+6 more) |
| 48 | a reachable tree page never refused | pinned readers, retirement and reclamation / refuses to reclaim a page the committed trees still reach, whichever l; page ownership against forged records with valid checksums / refuses a free extent that offers a live page, whichever live page it ; page ownership against forged records with valid checksums / refuses a free extent that offers a page only a pinned reader reaches, (+3 more) |
| 50 | pinned roots not consulted when proving a page unreachable | page ownership against forged records with valid checksums / refuses a free extent that offers a page only a pinned reader reaches,; page ownership against forged records with valid checksums / refuses a retirement entry whose version was lowered past a pinned rea |
| 54 | a retirement-owned page may be overwritten | page ownership against forged records with valid checksums / refuses a free extent that offers a page only a pinned reader reaches,; page ownership against forged records with valid checksums / proves every loose page maintenance hands to the allocator tree, at th; page ownership against forged records with valid checksums / refuses to overwrite a retired page the allocator offers while its ret (+1 more) |
| 55 | a loose page that is also a free extent accepted | page ownership against forged records with valid checksums / refuses a loose page that is also a free extent, even when the extent  |
| 56 | the root collapse follows single children without level or bounds checks | the private page codec against independent bytes / refuses a root collapse that would follow a cycle or a child of the wr |
| 57 | rebalancing loads its siblings without their separator bounds | the private page codec against independent bytes / refuses a sibling whose keys break its parent's separators before merg |
| 59 | a loose page outside the used space accepted | none |
| 60 | a page handed out twice by one supply | none |
| 61 | a free extent reaching past the used space | page ownership against forged records with valid checksums / refuses a free extent that lies wholly past the used space, where no t |


Controls that belong to no reduced family: their full depth does not catch them either, so there is nothing the representatives must
preserve. The six landing-validation controls of the Fuzz record (8-14) and the round-9 descent (15), applied now, fail at most
an unreduced Protocol read-phase example and no reduced family at either depth: since round 9 every page read is checked against its parent's recorded checksum, which subsumes
them for re-sealed bytes (Fuzz and FuzzTrees catch the checksum controls, 16-21, at routine depth where attributed).
The ownership proofs (37, 38, 45, 47, 48, 50, 54, 55), the supply checks (59-61) and the forged-content refusals (56, 57) are
caught by no reduced family at either depth; their records name `Ownership`, `Readers` and `Codec`, which are not reduced
(not run here); 3 is an equivalent mutant, as recorded.

Records not re-applied, with the reason each reduced family cannot observe them: the field table's byte-level validators, the
admission and edit-bank accounts, the allowance and protected reserve, window and token identity, credit arithmetic, the accounted-bytes
constants, the read-phase facts and the memory rows (the records of rounds 1-5, 16-20 and `docs/evidence/terrain/tra21/README.md` that
name `Codec`, `Ownership`, `Readers`, `Allowance`, `AdmissionSpec`, `Memory`, `Boundary`, the read-phase examples of `Protocol`
or the storage service's examples): their named examples are not reduced and the reduced families build valid stores through
the planner and present no foreign window, token or credit, so a mutation of such a refusal is not observable by them.
The `Keys` controls (untagged keys) abort the suite in `History`'s fixture build, which the routine `History` reads.

## Construction records of the fixtures

A selection of a module that reads no large fixture constructs none:

```
$ terrain-runtime-tests --jobs 1 --match "independently written pages"
RUNNER jobs=1 capabilities=1 ...
4 examples, 0 failures                 (no FIXTURE line)
```

Two examples that share one large fixture construct it once:

```
$ terrain-runtime-tests --jobs 1 --match "randomized ownership history"
FIXTURE built History.wide 12000
2 examples, 0 failures                 (8.6 s)
```

A run that selects no example takes 0.02 s (`--match "/zzz no such example/"`; the rows of `Store/Memory.hs` and every large
fixture are built on first read).
