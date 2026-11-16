# Terrain commit preparation outside the transaction (#695)

On two or more capabilities the terrain owner's commit transaction was restarted by the Lua host's per-update STM writes for as
long as the script ran. Three heavy examples of `lua-engine-tests` never completed in the multi-capability pass. The fix moves
the transaction's size-dependent work out of it: an open's palette interning, and a read's settlement (lua-engine's conversion of
the answer and scripting-lua's reply validation). Both are prepared once and fully evaluated before the work is staged. The
arbitration (eligibility, publication, settlement) is unchanged and still one transaction. Every figure is a lab observation on
an Apple M3 Max (16 logical cores, macOS 26.7.1) with GHC 9.14.1.

Heads: this branch `8693d5a8` (off master `6b35b315`); #692 `bb8bbb52` (local, unchanged); the combination `02365be8` (local,
never pushed): master merged with #692 (`ee88b0dd`), #692's held-out list emptied (`6a536fcd`), this branch merged.

## The third example's mechanism

From a captured failing run (scratch diagnostic, run 1 of at most 10), the 1,024-run column example stalled in the column's
commit, not in its arena's open: `Owner.hs` `commitReq` → `atomically (commitTx …)` → the staged answer's `endpointSettle` →
lua-engine `settleInto` → `answerReply` → scripting-lua `checkReplyPure` over the 1,024-run reply, with the provider state's
`psVar` (written on every Lua update) in the read set. 14,961 attempts in 10 s, none committed: the same class as the two opens.

## Commit attempts per committed request

Scratch counters around `commitReq` (never committed), one run per example in the pass, default 2 capabilities. The after
column was measured in the combination's earlier merge `e1db1429` (this branch at `c852ef08`); the later commits add the tests
and make the seam opt-in, and lua-engine's endpoint takes the same prepared path.

| Example | Before (master + #692, list emptied) | After (the combination) |
| --- | --- | --- |
| The 1,024-run column | 15,202 attempts by the 10 s bound; committed only after the script stopped; fails | 1 attempt; passes in 0.11 s |
| The 256 KiB definition | the open never committed by the 10 s bound; fails | 1 attempt; passes in 0.08 s |
| The 4,095 materials | intermittent: passed in this run (1 attempt); #692's capture, about 310 attempts/s, none committed in 9 s | 1 attempt; passes in 0.03 s |

The short commit transaction still reads `psVar`, so a host write can still restart it. Each restart now costs a few
microseconds (the column's prepared settlement ran in about 1.5 µs; its preparation, about 0.6 ms, now runs before staging), and
in every run above it committed at the first attempt.

## Acceptance 3: the series

`lua-engine-tests` in the combination, the three examples in the multi-capability pass, 10 consecutive runs at each count, every
run bounded, nothing retried, a failure stopping the series.

| Example | -N2 | -N4 |
| --- | --- | --- |
| The 256 KiB definition | 10/10 | 10/10 |
| The 4,095 materials | 10/10 | 10/10 |
| The 1,024-run column | 10/10 | 10/10 |

Each run is one process selecting the three examples: `HETOIMASIA_CONCURRENT_PASS_CAPABILITIES=<2|4> lua-engine-tests --match
"/The multi-capability pass/Terrain/Terrain matrices/accepts a definition of exactly the validator's 256 KiB" --match "/The
multi-capability pass/Terrain/Terrain matrices/accepts a definition of exactly the validator's 4,095 materials" --match "/The
multi-capability pass/Terrain/Terrain limits/answers a column of exactly 1,024 runs"`, bounded at 60 s. Every run reported
`3 examples, 0 failures` at the effective count asked for, in 0.27 to 0.86 s of wall time.

## The whole suite in the combination

Whole `lua-engine-tests` (1,575 examples: the one-capability set, then the pass with every terrain example), each series stopping
at its first failure. With this change: 5/5 runs, 0 failures (69 to 72 s). Without it (master with #692, list emptied): run 1
failed only the 256 KiB definition example, in the pass. That is the starvation this change fixes, so that series stops there.

One earlier whole run with this change failed one example once, in the one-capability set, not in the pass: `Terrain lifecycle
model`'s "keeps the service's use equal to what the live handles account for … (seed 23)", on its lease check (3 leases held
against 2 live handles), hspec seed 592421650. It did not reproduce: 5/5 alone, and in the six whole runs above (the model example
passed in each, the run without this change included). This change does not touch leases; #692 changed that example's file.
