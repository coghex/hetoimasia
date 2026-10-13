# Why "release requests are refused after the session's failure" ran into its bound on Linux CI

Issue #438, PR #439. Evidence for the cause of one Linux CI failure of the
`hetoimasia-gpu-vulkan-glfw:test:integration-tests` example

> Vulkan scenes for each window (R2D-14) / release requests / are refused after
> the session's failure, including one queued before it that never started

(`packages/gpu-vulkan/glfw/test/Test/GPU/Vulkan/GLFW/Scenes.hs`), which ran into
its 60 s bound once, on PR #437's run `38324286322` (job `vulkan`, group
`test.vulkan-headless`, seed `1777504540`).

## Cause

A test race. Not a missed settlement in the controller, and no contract
changes.

The example makes a window with a scene publication and no target, queues a
release request that waits on it, reports a validation error from the test
thread with `reportErrorNow`, and then waits (`readOwnerFailure`) for the owner
to fail. The contract latches an error-severity report **at the owner's next
checkpoint** (docs/gpu_backend.md, "The latch"); reporting one wakes nobody. A
sink failure, and a primary latched on another thread, are the only failures
with a wake (`failureOwed`). The one thing queued is #423's release request,
and a request that cannot start is not work: it does not wake an idle owner
(docs/gpu_backend.md, release requests). So whether the example finishes was
down to the scheduler: if the owner was still inside the round that took the
publication when the error was reported, its checkpoint latched it and the
session failed; if it had already ended that round, nothing asked it for
another, and the wait for the owner's failure never ended.

Settlement itself is sound. A queued request's reader and the owner's retirement
both settle a not-yet-started request as refused with the gate's answer first
(`Actions.readActionTicket`, `Actions.refuseRemaining`), so the session's
failure, not the owner's closure, is what a request refused after the failure
names; a request that had started keeps its own outcome. Neither path was
reached in the stalled runs, because the session had not failed.

The sibling examples that report an error each follow `reportErrorNow` with
something that wakes the owner (an admitted action in `testTerminalRefusal`,
`demandFrame` in the consumer example). This one did not, because its only
queued work is, by #423's design, blocked.

## The stalled phase

Instrumentation (commit `c263794d`; removed in `450bb461`): test-only phase
markers around every wait of the example including setup (`setup`,
`supervise`, `wait-ready`, `publish`, `request`, `report-error`,
`wait-owner-failure`, `wait-settlement`, `later-request`, `check-runtime`) and
teardown (`teardown`, `after-teardown`), and a watchdog that, 20 s in, prints
the phase, readiness, whether the owner has failed, the owner's completed
rounds, whether a primary is latched, and the queued request's standing.

Every one of the 120 stalled runs of batch D1 printed

```
HET438-WATCHDOG phase=wait-owner-failure elapsed=20.0…
HET438-WATCHDOG readiness=RootsReady ownerFailure=False ownerRounds=2 terminalLatched=False
HET438-WATCHDOG ticket=queued-or-running
```

so setup, readiness, the publication, the request and the error report had all
completed; the owner had ended two rounds and was idle; nothing was latched; the
request was still queued. Nothing stalled in teardown.

## Batches

All on GitHub-hosted `ubuntu-latest` (x86_64, 4 vCPU), inside the CI image the
validation workflow uses (`tools/ci-image/descriptor.json`, digest in each run's
summary), GHC 9.14.1, cabal 3.18.1.0, the suite's default RTS options (`-threaded
-rtsopts`, no `+RTS` flags). One run is one process running one bounded example
(`--match`, `--seed S`, 60 s example bound plus its 10 s cleanup grace, 100 s
process timeout), so bounded examples are sequential within each executable.
External load is `load` busy loops (`while :; do :; done`) outside the test
processes; `processes` test processes run at once, each running its share of
the runs one after another. Declared before each run in `stress-438/batch.json`
(removed before the final head; quoted below). The workflow is a temporary
`pull_request`-triggered one on the #438 branch, chosen by the owner on
2026-10-13T00:24:01Z (quruntul has no Linux runner). Failed batches are kept;
no unchanged revision was rerun.

| Batch | Revision | Run | Variant | Declared | Failed |
| --- | --- | --- | --- | --- | --- |
| D1 diagnostic (unfixed, instrumented) | `c263794d` | [38327990907](https://github.com/coghex/hetoimasia/actions/runs/38327990907) | natural, 4 procs, 8 busy loops, random seeds | 4000 | **95** (2.4 %) |
| | | | issue seed 1777504540, 2 procs, 8 busy loops | 1000 | **22** (2.2 %) |
| | | | natural, 1 proc, no external load | 1000 | 0 |
| | | | forced idle (300 ms pause before the report), 3 procs | 3 | **3** |
| M1 mutation (new idle example, fix absent) | `450bb461` | [38330696413](https://github.com/coghex/hetoimasia/actions/runs/38330696413) | idle example, 3 procs | 3 | **3** (60.0 s each) |
| | | | old example, issue seed, 2 procs, 8 busy loops (no instrumentation) | 1000 | **36** (3.6 %) |
| F1 acceptance (fix) | `bc80ade8` | [38331565003](https://github.com/coghex/hetoimasia/actions/runs/38331565003) | both examples, 1 proc, 8 busy loops, random seeds | 300 | 0 |
| | | | both examples, issue seed, 2 procs, 8 busy loops | 1000 | 0 |
| | | | both examples, 4 procs, 8 busy loops, random seeds | 4000 | 0 |
| | | | whole integration suite (160 examples), 1 proc, 8 busy loops | 30 | 0 |

Every failed run took the full 60.0 s bound and ended with "the example did not
finish within its bound" (`Bound.hs:183:9`), as on PR #437. Seed does not matter:
the 22 failures at the issue's seed and the 95 at random seeds have the same
rate. Without external load the owner is still in its round when the error is
reported and no run stalled (0 of 1000); the failure needs a loaded machine,
which a shared CI runner running a whole validation group is.

## The fix

Test only; no production code or contract changes.

- `requestAfterFailure`: after `reportErrorNow` the example publishes the
  window's next scene, which gives the owner the round at whose checkpoint the
  error is latched. Siblings admit an action or publish a demand for the same
  reason.
- A second example, "are refused after a failure reported while the owner is
  idle…", makes the interleaving that stalled deterministic: `awaitIdleOwner`
  waits, without a clock, for the owner to have ended a round that began after
  the example's publication and request, with nothing owed. It submits two
  barrier-less actions, the second after the first has settled; an action reads
  the owner's completed-round count from inside its round (the idiom
  `settleOwner` uses for a scene event), so the second ran in a later round that
  had read the publication, and `awaitOwnerRound` on that count returns when that
  round has ended. The release request that waits wakes no one, so the owner is
  then idle.
- Without the wake the new example fails every time (M1 on Linux 3/3; macOS 3/3
  locally), at the bound. The old example's failure rate with it removed is the
  batch D1/M1 rate above.

## Acceptance (F1, `bc80ade8`)

Declared in `stress-438/batch.json` at `bc80ade8` (`git show
bc80ade8:stress-438/batch.json`) before the run; every variant `mustPass`.
The fixed example and the new idle example together, every run a separate
process with its own random seed (the issue-seed variant: 1777504540), `--match
"are refused after the session's failure" --match "are refused after a failure
reported while the owner is idle"`, on the same runner class, image and load
generator as D1:

| Variant | Processes at once | Busy loops | Runs | Failures | Seconds per run (min / mean / max) |
| --- | --- | --- | --- | --- | --- |
| `f1-consecutive-load` | 1 (consecutive) | 8 | 300 | 0 | 0.031 / 0.060 / 0.090 |
| `f1-issue-seed-load` | 2 | 8 | 1000 | 0 | 0.019 / 0.067 / 0.172 |
| `f1-natural-load` | 4 | 8 | 4000 | 0 | 0.017 / 0.071 / 0.128 |
| `f1-suite-load` (whole `integration-tests`, 160 examples) | 1 (consecutive) | 8 | 30 | 0 | 3.564 / 3.767 / 3.952 |

That is 300 consecutive runs of both examples (600 example executions) under
parallel load with none failing, where the same load stalled 2.2–3.6 % of the
old example's runs. The reproduction command for one run is, from
`packages/gpu-vulkan/glfw` with the built `integration-tests` binary,

```
integration-tests --match "are refused after the session's failure" --match "are refused after a failure reported while the owner is idle" --seed SEED
```

with `stress-438/run-variant.sh` (at `bc80ade8`) generating the load and the
concurrency, and the batch's run summary and per-run times in the run's
`stress-438-evidence-*` artifacts (kept 90 days).

The validation workflow's own run for `bc80ade8` ([38331565002](https://github.com/coghex/hetoimasia/actions/runs/38331565002)):
`test.vulkan-headless` passed with both examples green;
`test.vulkan-native` passed; `test.vulkan-wayland` failed on the known WL-4
connection-loss example ("ended the session with the confirmed loss as the
application's failure, and reconnected nothing", `ConnectionLoss.hs:331`),
which #438 leaves out of scope.

Locally on macOS at `bc80ade8`: `bash tools/vulkan/run.sh test
hetoimasia-gpu-vulkan-glfw:test:integration-tests` 160 examples, 0 failures;
`cabal build all` warning-clean.

## Tested and final revisions

The acceptance batch F1 ran on the code at `bc80ade8` (the stress workflow
built the pull request's merge ref `c07394429cad`, whose toolchain record is in
the run's `stress-438-binary` artifact). The workflow and `stress-438/` were
then removed in `9f525a81`, and `origin/master` (documentation only) was merged
in at `d3a0d52b`. The production sources, the tests, the dependencies and every
build input are the same bytes at the tested and the final revision:

```
git diff --name-only bc80ade8 d3a0d52b | grep -v '\.md$'
.github/workflows/stress-438.yml
stress-438/batch.json
stress-438/run-variant.sh
```

and those three are the removed temporary files; the markdown files that differ
are the documentation merged from master. `git diff bc80ade8 d3a0d52b --
packages tools '*.cabal' 'cabal.project*'` is empty apart from markdown. So no
new acceptance batch was owed. The local acceptance commands were rerun at
`d3a0d52b` (the planner's required groups for that head).

## A note that is not part of this fix

The same wake rule means an application that reports a validation error from
another thread to an idle owner learns of it only at the owner's next round.
That is the documented contract (the next checkpoint), unchanged here.
