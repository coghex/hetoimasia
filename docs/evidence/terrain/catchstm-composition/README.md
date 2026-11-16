# A credit release that reran forever under catchSTM (#700)

On two or more capabilities, a Lua instance's exit could spin forever in the terrain retirement. The cause was GHC's
`catchSTM`, not the retirement code. The repair is `catchSTMRestarting` in `Hetoimasia.Foundation.Failure`, used by
scripting-lua's `releaseCredit` and terrain-runtime's guarded settlement callback. Every figure is a lab observation on an
Apple M3 Max (16 logical cores, macOS 26.7.1) with GHC 9.14.1.

Heads: this branch `5655a2e1` (off master `26579849`); #692 `b9806b06` (local, unchanged); the combination `80e5c6f1` (local,
never pushed): master merged with #692 (`5570e3d4`), then this branch merged.

## The mechanism

Captured in the combination without the repair (scratch C counters called through unsafe FFI, so they allocate nothing; run 2 of
at most 20):

- One `releaseSettled` transaction retired requests 4, 5 and 6 through `retireRequest`'s not-in-table path, each nested commit
  succeeding.
- Request 7's credit release, also not in the table, then reran 22 to 24 million times a second (139.4 million in 6 s). Credit-body
  runs equalled retire calls, and the transaction's run count did not move.

The `$wgo13` of the original sample is `Data.Map.lookup` over the request table.

GHC 9.14.1's `stg_catch_stm_frame` (rts `PrimOps.cmm:1330-1338`) reruns only the guarded action when its nested commit fails, against
an enclosing transaction that nothing revalidates. Only a heap check returns the thread to the scheduler, which restarts the whole
transaction, so an action that allocates nothing on that path loops forever and holds up every GC sync. `orElse`'s frame restarts the
whole transaction instead (`PrimOps.cmm:1217-1220`).

A standalone program (outside the repository) shows the same behaviour. With an allocation-free guarded action read after another
thread's commit, the bare `catchSTM` hung in 5 of 5 runs at `-N4`, and in 6 of 6 at `-N1` and `-N4` with a blocking `MVar` handshake;
each run was bounded at 3 s. The same action under `orElse` inside `catchSTM` committed in 6 of 6, after one restart of the whole
transaction. A macOS `sample` of a hung run shows the frames of #692's capture: `stmReadTVar`, `validate_and_acquire_ownership`,
`stmStartTransaction`, `stmCommitNestedTransaction`.

## Deterministic examples and controls

| Example | With the repair | Control (bare `catchSTM`) |
| --- | --- | --- |
| foundation: the helper, stale transaction (attempts, action runs) | (2, 2) | (2, 10001): the action reran to its cap within one attempt |
| lua-runtime: two credits in one `releaseSettled`, the second after another thread's commit | passes; each release ran once per transaction run | fails: the second release reran to its cap (`ReranAgainstStale`) |

## Acceptance: requirement 4

`lua-engine-tests` in the combination, `HETOIMASIA_CONCURRENT_PASS_CAPABILITIES=4` (the pass reported `effective=4` in every run),
sequential runs, each process bounded externally, nothing retried. Commands, from `packages/lua-engine`:

- isolated: `lua-engine-tests --match "/The multi-capability pass/Terrain/Terrain validation/refuses every copy and decode rejection as an ordinary error, before admission, and runs no metamethod/"`, bounded at 120 s;
- the whole set: `lua-engine-tests --match "/The multi-capability pass/Terrain/"`, bounded at 600 s.

| Series | Result | Wall time | Load (1 min) |
| --- | --- | --- | --- |
| The Validation example alone | 20/20, 0 failures, no timeout | 0.06 to 1.86 s | 7.5 |
| The whole terrain set (162 examples) | 20/20, 0 failures, no timeout | 24.4 to 25.2 s | 3.4 to 7.9 |

Before the repair, the Validation example alone hung in about 3 of 13 runs at 4 capabilities (#692's capture), and in run 2 of this
issue's capture.
