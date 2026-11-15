# TRA-22 evidence: edits and discovery committed through the temporary store

Code head `63ac28f0`, run on 2026-11-15 from 05:20 to 05:46 UTC on macOS (arm64, 16 processors), with qualified
GHC 9.14.1 and Cabal 3.18.1.0 on `PATH`, after removing the build directories of `hetoimasia-terrain`,
`hetoimasia-terrain-runtime` and `hetoimasia-lua-engine`. Each suite ran once and nothing was rerun. Other projects
loaded the machine (load average 3.6 to 4.7); nothing else of this repository ran. Contract:
`packages/terrain-runtime/README.md`.

## Commands

```sh
cabal build --project-file cabal.project.cpu hetoimasia-terrain:test:terrain-tests hetoimasia-terrain-runtime:test:terrain-runtime-tests hetoimasia-terrain-runtime:test:terrain-runtime-full-depth-tests hetoimasia-lua-engine:test:lua-engine-tests
cabal test --project-file cabal.project.cpu hetoimasia-terrain:terrain-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-terrain-runtime:terrain-runtime-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-lua-engine:lua-engine-tests --test-show-details=direct
cabal test --project-file cabal.project.cpu hetoimasia-terrain-runtime:terrain-runtime-full-depth-tests --test-show-details=direct
```

| Suite | Examples | Failures | "Finished in" |
| --- | --- | --- | --- |
| terrain-tests | 905 | 0 | 47.8 s |
| terrain-runtime-tests (8 jobs) | 1,032 | 0 | 150.7 s |
| lua-engine-tests | 1,382 | 0 | 45.3 s |
| terrain-runtime-full-depth-tests (probe) | 100 | 0 | 1,022.1 s |

The build was warning-free under `-Werror`. The timed run, `terrain-runtime-tests` alone after the others (load 3.9
before, 3.7 after): 1,032 examples, 0 failures, "Finished in" 150.0 s, 152.0 s for the whole process (budget 240 s).

Fixtures: each backed example opens its arenas in a fresh `withSystemTempDirectory` directory with a 64 MiB
allowance, so no example fills the ordinary drive. `storage_full` is reached under a pinned old version: in the
routine suite on a store whose overhead leaves 128 pages beyond the least the store accepts, and at full depth
on the default overhead. The randomized interleaving keeps its 24 seeds of 300 steps; no other example is
seeded.

## What the examples assert

| Item | Where it is asserted | Value |
| --- | --- | --- |
| Root and revision identities | "writes a removal to the arena's file before it publishes it, and reads it back from the store"; the decision's checked increments | a changing removal: content +1, store +1 (knowledge +1 when its batch changes knowledge); a no-op removal: none; a cancelled or failed transaction keeps the old root |
| Terminal outcomes | the removal sweep (3 held steps × 5 exits), the open sweep (13), the write-prefix sweep | each request settles exactly once; the slot, credits and pins are back at rest after each |
| Recorded obligations | the discovery traces (A then B, B then A, buried then opening, sealed stack) | the obligations drain through the decision, and what the store knows equals #661's reference |
| Replay | "after every committed batch, what the store knows and the work it keeps are the uninterrupted reference's after as many batches" | the collapsed sequence of committed states equals the reference's |
| Offload and reload | "keeps nothing of an acknowledged removal in RAM ..."; "keeps every retained removal across repeated eviction and reconstruction" | the region is a cache at once; eviction and reload reconstruct it from the store |
| Retained history beyond the cache | the `storage_full` trace, full depth | 2,945 buried removals fill the 64 MiB allowance under a pinned old version until `AllowanceExhausted` (needed + protected > available); growth to 128 MiB clears it; both refused cells stay solid and each refused host settled once (routine: 17 removals, the same assertions) |
| Bounded working set as history exceeds the cache | the same trace samples the edit bank after every commit and asserts each account within its limit | peaks over the 2,945 commits (bytes): cache 2,844,160 of 50,331,648; staging 1,850,624 of 8,388,608; control 1,144,960 of 8,388,608 |
| Records nothing bounds | the held-close examples, on the least control account the service accepts | 261 held closes and one closing leave 1,131,648 B against a transaction's 1,132,672 B; 260 and one leave 1,135,744 B. While the last close is held, the owner waits; once it has closed, the owner ends with a recorded defect naming the held closes, and every request settles |
| Last reader and write retirement | "lets a cancellation win while the writes are held, keeps the old root, and retires the claims only after the write returns"; "closes an arena while its write is held: the request ends once, the write drains, then the file closes" | claims retire only after the write job returns; the file closes after the drain |

## Accounted bounds against actual buffers

Accounted, checked at construction:
- the edit bank (48 MiB cache, 8 MiB staging, 8 MiB control): one read's result page (4,864 B, cache) and
  transfer buffer (8,320 B, staging) beside the worst transaction and every configured pin; the control
  account beside the storage service's own records at their most (`maxRecordControlBytes`: 1,204,224 B for
  two arenas, 1,212,416 B for four);
- the compile account: 102 MiB for four arenas (three per-arena bounds of 18 MiB plus one 48 MiB peak).

Actual: the observed edit-bank peaks above, and the storage service's own records compared with the bank at
rest after every backed example (`backedAtRestSTM`). Process RSS is not measured, and no throughput is
claimed.
