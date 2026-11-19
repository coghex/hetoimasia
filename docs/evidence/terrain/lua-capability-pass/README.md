# The Lua terrain set on several capabilities (#692)

`lua-engine-tests` runs its terrain set in place on one capability, then once more, last, on 2 capabilities (4 by override),
behind a test pump that wakes one update at a time; every other example runs on one.

Code head `02db861a`, GHC 9.14.1, Apple M3 Max (16 logical cores, macOS 26.7.1). Command, run consecutively, nothing rerun:

```
cabal test --project-file cabal.project.cpu hetoimasia-lua-engine:lua-engine-tests --test-show-details=direct
```

with `HETOIMASIA_CONCURRENT_PASS_CAPABILITIES=4` for the override. The capability control of #685
([capability pass](../capability-pass/README.md)) is reused, not repeated.

## Results

The series at `4102c5f3` (owner decision L, 2026-11-19: it stands as run; tests run once from then on):

| Runs | Pass line | Result |
| --- | --- | --- |
| 3 timed | `requested=2 (default) effective=2` | 2 with 0 failures; run 2 one failure outside the set, recorded as #708 |
| 10 at 2 | `requested=2 (default) effective=2` | 1578 examples, 0 failures each |
| 9 at 4 | `requested=4 (HETOIMASIA_CONCURRENT_PASS_CAPABILITIES) effective=4` | 8 with 0 failures; run 9 one test race in the pass (the growth outcomes example read its output mid-update), repaired at `02db861a` |

At `02db861a`, once each: that example (in place and in the pass), passed; the whole suite, 1578 examples, 0 failures, 70.8 s real.

Budget, the same command: 46.6 s real for the whole suite at `394939d1` (1402 examples, once), 70.8 s at `02db861a` (1578).

CI: the pull request's run at the final head, recorded in its body.

## Findings

Product defects the pass found, each repaired and merged first: #695
([commit preparation](../commit-preparation/README.md)), #700 ([catchSTM composition](../catchstm-composition/README.md)),
#703 ([reclaim after release](../reclaim-after-release/README.md)). #702: suites outside the set that fail at 2 capabilities
(out of scope; they now run on one).

Test mechanisms, repaired in the test code, each from a failing run (a capture, or the code and its contracts):
- the old pump woke a script's next update before the example looked (`Races.hs`, `Terrain arbitration`): the step pump;
- `StorageFaults` waited on momentary rest: it waits for quiescence;
- the lifecycle model read g's early attach before it answered, and checked the service before p's owner had accounted for the
  update that answered (`readtake`): it waits for the answer, and for p's accounting acknowledgement;
- the windows example signalled another VM's open while the opener was Stopping, before its drain ended the open's request: it
  waits for the opener's terminal phase;
- the taken-bank example asked again in the update that took the bank, before the owner's boundary returned it: it asks in the
  next update, after the owner's accounting acknowledgement;
- the growth outcomes example read its output in the middle of the update that printed its last line: it waits for `done`.

The lab trials (acceptance 4) were dropped by owner decision S (2026-11-19); no lab result is claimed. The run stopped then,
`801ef864-d92f-4829-88ab-e0a1d82e4b90`, and the abandoned `5792dc62-b0a2-48bd-bd60-cfb65a3a08a2` still read `running`:
quruntul has no command to close an abandoned run.
