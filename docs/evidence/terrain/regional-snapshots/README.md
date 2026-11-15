# #690 evidence: regional terrain-and-knowledge snapshots

Code head `b34ac959`, run on 2026-11-15 from 16:07 to 16:33 UTC on macOS (arm64, 16 processors), with qualified GHC 9.14.1
and Cabal 3.18.1.0 on `PATH`, after removing the build directories of `hetoimasia-terrain`,
`hetoimasia-terrain-runtime` and `hetoimasia-lua-engine` (the warning-clean `cabal build all`, GLFW prefix on
`PKG_CONFIG_PATH`). Each suite ran once and nothing was rerun. Contracts: `packages/terrain-runtime/README.md`
(Regional snapshots), `packages/terrain/README.md` (Regions; the copied hold).

## Commands

```sh
cabal test --project-file cabal.project.cpu hetoimasia-terrain-runtime:terrain-runtime-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-terrain:terrain-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-lua-engine:lua-engine-tests --test-show-details=direct
cabal test workflow-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-terrain-runtime:terrain-runtime-full-depth-tests --test-show-details=direct --test-option=--match --test-option="Regional snapshots (full depth)"
```

| Suite | Examples | Failures | "Finished in" |
| --- | --- | --- | --- |
| terrain-runtime-tests (8 jobs) | 1,076 | 0 | 170.8 s |
| terrain-tests | 920 | 0 | 48.0 s |
| lua-engine-tests | 1,382 | 0 | 43.5 s |
| workflow-tests | 965 | 0 | 695.0 s |
| terrain-runtime-full-depth-tests, `Regional snapshots (full depth)` | 7 | 0 | 23.6 s |

Every other group the plan selects on Darwin passed through `tools/validation/run.py` with a local receipt
(build.all, engine 159, foundation 482, runtime 243, glfw 1,097, smoke.console, terrain-render-2d 558,
vulkan-headless, and the native vulkan-native, vulkan-lua-engine-native and vulkan-run-native under the owner's
standing consent); `test.vulkan-wayland` runs only on the Linux display worker. `cabal check` is clean for both
terrain packages; the build is warning-free.

The timed run, `terrain-runtime-tests` alone in the strict window `het-w690-1`: load 6.73 before, 6.08
after; "Finished in" 170.8 s, 197.9 s for the whole run (budget 240 s), on master `03fe6bd7` (before #685's
second pass). The regional examples' routine share, focused under load 11.7: 5.5 s (the oracle 3.5 s).

## Tiering

| Family | Routine (`terrain-runtime-tests`) | Full depth (`terrain-runtime-full-depth-tests`) |
| --- | --- | --- |
| The every-cell oracle (`Test.TerrainRuntime.Regional`) | one region, (0,0,0), holding all six fixture shapes side by side and both seam cases: 8,192 cells against `cellAt`, `knowledgeAt` and the suite-local expectation | `fullSpec`: the seven fixtures each on its own (the six and the seam), every cell of every region each holds: ten regions, 81,920 cells, the same comparisons |

## Compression, absolute

| Snapshot | Footprint (accounted bytes) | Knowledge classes | Work (columns, runs, classes, pieces, evaluations, per level) |
| --- | ---: | ---: | --- |
| two pristine regions, buried and sky | 608 | 1 each | (320, 0, 1, 1, 3, 0) each |
| one pristine buried region | 368 | 1 | (320, 0, 1, 1, 3, 0) |
| the same region with one removal | 640 (+272) | 2 | (320, 1, 6, 16, 38, 0) |

Admission reserves `regionSnapshotReservation n` = 128 + 25,840 n + 747,520 bytes (773,488 for one region) and the
charge becomes the footprint in the settlement transaction.

## Round 1 repairs

Code head `c045c615` (merged with master as `9c487af6`), 2026-11-15: the routine regional examples, focused
(`--match "Regional snapshots"`), 29 examples, 0 failures, 7.2 s; the heap measurements are in the examples
under "what a regional build retains". Functional runs at `9c487af6` (during another issue's lab window, so
not timings): terrain-runtime-tests 1,085/0, terrain-tests 920/0, lua-engine-tests 1,401/0.
