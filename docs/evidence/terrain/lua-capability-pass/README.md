# The Lua terrain set on several capabilities (#692)

`lua-engine-tests` runs its terrain set in place on one capability, then once more, last, on 2 capabilities (4 by override),
behind a test pump that wakes one update at a time; every other example runs on one.

Code head `aa0ddf40`, GHC 9.14.1, on an Apple M3 Max (16 logical cores, macOS 26.7.1). Command, run consecutively with nothing
rerun:

```
cabal test --project-file cabal.project.cpu hetoimasia-lua-engine:lua-engine-tests --test-show-details=direct
```

with `HETOIMASIA_CONCURRENT_PASS_CAPABILITIES=4` for the override.

## Results

| Runs | Pass line | Result |
| --- | --- | --- |
| 3 timed | `requested=2 (default) effective=2` | 1576 examples, 0 failures each |
| 10 at 2 | `requested=2 (default) effective=2` | the pass and the set green in all 10; run 8 had one failure outside the set, the session example `Session/Failures.hs:875` (recorded) |
| 10 at 4 | `requested=4 (HETOIMASIA_CONCURRENT_PASS_CAPABILITIES) effective=4` | 1576 examples, 0 failures each |

Budget: 70.7 to 72.6 s real for the whole suite, the set and the pass included; before this change the one-capability set alone
took about 24 s (quoted from #685, not re-measured).

## Findings

The pass found three product defects, each repaired and merged first: #695
([commit preparation](../commit-preparation/README.md)), #700 ([catchSTM composition](../catchstm-composition/README.md)) and
#703 ([reclaim after release](../reclaim-after-release/README.md)). #702 records suites outside the set that fail at 2
capabilities (out of scope; they now run on one). The test mechanisms it found are repaired in the test code.

The lab trials (acceptance 4) were dropped by owner decision S (2026-11-19); no lab result is claimed. The run stopped then,
`801ef864-d92f-4829-88ab-e0a1d82e4b90`, and the earlier abandoned `5792dc62-b0a2-48bd-bd60-cfb65a3a08a2` still read `running`:
quruntul has no command to close an abandoned run.
