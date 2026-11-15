# Terrain runtime on several capabilities (#685)

The concurrent examples of `terrain-runtime-tests` ran on one capability, so their threads interleaved and never executed at the
same instant. A routine run now runs them a second time, last, on 2 capabilities (the pass), in the same executable. Final
code head `ee69dbe1` (the budget runs name their own earlier head), GHC 9.14.1. Every figure is a lab observation on the machine below; CI figures are
from the CI record.

Machine: Apple M3 Max, 16 logical cores (16 performance and efficiency cores as one count), macOS 26.7.1. A capability count above 16
would be time-sliced, not simultaneous; the counts used (2 and 4) are below it. CI: the 4-vCPU `ubuntu-latest` runner.

## The named set

`Test.TerrainRuntime.Concurrent` is the one table: each of the 54 modules of the sequential order is `Concurrent` or `Alone` with its
reason. In (32): every module that drives the production service (its owner thread), the storage workers or a gate: 12 service
modules, 13 backed modules, 7 storage modules. Out (22), with the reason in the table: the pure store modules (no thread), `Storage.Filesystem` (one
thread, a recording seam), `Backed.Outcomes` (pure), the five modules that read the live heap or allocated bytes (`Store.Memory`,
`Store.Depth`, the measured part of `Store.Evidence`, `Store.Bounds`, `Storage.Memory`), the three that compile an external client (`Opacity`,
`Storage.Opacity`, `Store.Boundary`), and the harness's own examples. The rule that nothing which measures the process may join the set
is in the module and in `docs/test_classification.md`; a measurement placed in it fails the pass by `assertSequential`.

## Control

By hand, from its own selection (`terrain-runtime-tests --capability-control +RTS -N<K> -RTS`), in no routine group: two owned threads
pinned to capabilities 0 and 1 must each be inside a region at the same instant on different capabilities, a wait of 300,000,000 reads
and no sleep. `-N2`: completes on capabilities (0,1) in 0.02 s. `-N4`: the same. `-N1`: both threads end by their own read bound
("the peer was never inside the region on another capability than 0") in 0.9 s, exit 1, and are joined.

## Failures found at 2 capabilities

At one capability the suite was green. The first pass failed 1 to 2 examples in each of 10 of 10 runs; every mechanism found is test
code, none is product behaviour.

| Examples | Mechanism | Repair |
| --- | --- | --- |
| `Backed/Sweep.hs` (write count, and a one-shot write fault that missed), `Backed/Recovery.hs` (the "no more than eight failures" loop: 7 of 10 runs), the retry, probe and growth examples of `Backed/Recovery.hs` and `Backed/Creator.hs`, a grant example of `Credits.hs` | The example waited on `backedAtRestSTM`, which means momentarily idle and not quiescent, and then armed a one-shot fault or counted native operations. Internal work the owner chooses by design (reclamation of retired pages, discovery, a retry's probe, a settled request's trailing worker reads) started after the wait and took the fault or added an operation. Captured: `arenaStatus` showed 4096 bytes pending reclamation right after the wait in the run that then failed; a failing step showed 20 native reads on both workers for one request, the armed page read twice. At one capability that work drains before the test thread resumes. | New read-only `backedQuiescentSTM` in `Hetoimasia.Terrain.Runtime`, beside `backedAtRestSTM`: at rest and the owner's own chooser (`contenders`, the one slot grants are made from) offers nothing. Every affected wait uses it, and the Recovery loop waits on it before each armed rule. Every assertion kept. |
| `Test.LuaEngine.Terrain` races (a hang) | Handed over to the issue that moves the lua-engine pass: the pump advanced the clock again before looking, and on two capabilities the script's cancel ran before the owner staged the removal. | Not in this change. |

After the repair: 10 consecutive full passes at `-N2`, 618 examples each, 0 failures; the one-capability pass unchanged.

## Budget

`/usr/bin/time -p` around the literal acceptance command, built tree (0 `Compiling` or `Linking` lines), nothing else of this
repository running (a hold, load average 8.3 before the first run and 5.2 after the last; other projects' `fseventsd`, `cmux`,
`pijul` and `python` ran), head `6f4599a9`, 1,673 examples, every run 0 failures.

| Run | Wall s | "Finished in" s |
| --- | ---: | ---: |
| 1 | 213.4 | 210.7 |
| 2 | 209.0 | 207.1 |
| 3 | 214.9 | 212.6 |
| no example selected | 2.45 | 0.0001 |

Budget: 240 s whole process locally, 360 s CI "Finished in" (300 s before the pass; the owner's decision of 2026-11-15 on #685 raised it, both passes stay), 10 s no-example (`docs/test_classification.md`). The pass costs about 35
to 55 s beyond the one-capability suite (about 160 to 180 s on the same machine before it).

## Lab trials

`quruntul flake --target terrain-runtime-tests --ref ee69dbe1 --trials 20 --rts-capabilities K` (the lab's suite id is the
component name; each trial is the whole executable with `+RTS -NK -RTS`, 1,679 examples). Candidate evidence at the merged final
code, nothing rerun, no failure:

| K | Run identifier | Trials | Result | Per trial |
| --- | --- | ---: | --- | ---: |
| 2 | `13371efd-5af6-436d-8171-dc794f20c4ca` | 20 | 20 passed, 0 failed | 197 to 244 s |
| 4 | `37dd9498-958e-47c2-b8b1-fb2bf59d1664` | 20 | 20 passed, 0 failed | 210 to 243 s |

Every trial printed `PASS multi-capability: requested=K (+RTS -N) effective=K` with `PHASE sequential: 1 capability`: the lab's
option reaches the pass and nothing else. The trial times rose through the series because other projects shared the machine. A
first `-N2` series at the pre-merge head `d67965fe` (run `f8c4c837-b9be-4d11-9da5-5570920a18dd`) passed its 9 trials and was
stopped by hand when master's TRA-23 merge changed `terrain-runtime`'s source, so that the series is of the final candidate.


## CI

PR #693, the 4-vCPU runner, `terrain-runtime-tests` "Finished in" (budget 360 s), 0 failures, every job green, the pass printing
`PASS multi-capability: requested=2 (default) effective=2 (at start 1, processors 4)`:

| Head | Validation run | "Finished in" | Parallel group | One-capability phase | The pass |
| --- | --- | ---: | ---: | ---: | ---: |
| `d67965fe` | 43730908344 | 309.43 s | 107.9 s | 167.0 s | 34.5 s |
| `5ece2fed` (the same code) | 43753171955 | 210.66 s | 75.2 s | 113.4 s | 22.1 s |

The two runs of the same code differ by 100 s: the parallel group, which this change does not touch, took 107.9 s in the first and
75.2 s in the second (another pull request's run at the first run's time took 76.6 s and 110.9 s for its parallel group and
one-capability phase). The runner's speed varies by that much, so the pass costs 22 to 35 s of a figure that moves by 100 s.
