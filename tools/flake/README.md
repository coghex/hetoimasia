# Local test and flake lab

`$test` runs one optional probe. `$flake` measures one registered workload in a
bounded batch: optional probes, individual Hspec examples, or a newly developed
reproducer. CI-covered Hspec examples are eligible for a flake investigation,
not ordinary `$test` repetition. The ordinary regression stays in its owning
suite. Python manages subprocesses and records; Hspec keeps engine assertions.

The installed skills select through this tool, not through a second handwritten
queue. From a checkout containing the lab, with the qualified toolchain on PATH:

```sh
python3 tools/flake/lab.py run
python3 tools/flake/lab.py run --mode test
python3 tools/flake/lab.py status
```

One invocation owns at most one workload. By default it fetches `origin/master`
and pins that commit without moving any user branch. For an explicitly requested
candidate or baseline, use `run --ref <commit-or-branch>`. The invocation records
which ref it resolved. Uncommitted lab implementation cannot measure: commit it
first so another agent can recover exactly which harness produced the evidence.
This does not require merging it. Results from an unmerged revision remain
candidate evidence, never a claim about master.

## Selection

The checked-in `probes.json` starts with the Lua callback-cancellation example
reported in PR #241: 100 fresh processes, its original seed and `-N2`, a 15-second
trial ceiling, and a 300-second execution budget. A timeout records failure to
finish, not permission to destroy a production resource in-process.

The lab also discovers local-only Hspec probes from the validation catalog:
optional, category `probe`, and absent from hosted worker declarations. Commands
and component ownership come from that catalog. Current platform constraints
exclude Linux confinement on Darwin and macOS confinement on Linux. Native
interactive workloads declare `desktop: true` and are never automatically run;
after the human approves that specific disruptive session, an explicit
`run --probe ID --desktop` supplies consent for that invocation only. A flag is
not proof the conversation occurred; the skill must obtain approval first.
Hspec components routed to a display worker are automatically marked desktop.

Selection excludes deferred, unavailable, wrong-platform, and desktop workloads
first. Priority orders eligible workloads, then never-measured/oldest evidence,
then stable id. A fresh identical configuration is not selected again for 24
hours, including failed or blocked batches. Known failures do not cause a retry
loop. Relevant source or harness changes make evidence stale immediately. One
flake batch can satisfy ordinary test freshness; one ordinary test is not a flake
batch. `--probe ID` explicitly requests a registered workload again but never
bypasses deferral, platform, or mode restrictions; desktop runs additionally
require the per-session consent above.

Source identity uses the validation planner's Cabal component/dependency closure,
its additional group inputs, project settings, toolchain and native-search
configuration, probe parameters, and harness code hashes. Unconsumed prose-only
commits do not create new work. Each run still records the exact tested commit,
harness commit, UTC timestamps, build argv, executable/build-tool hashes,
working directory, seed and RTS configuration. Build and Hspec discovery happen
once before the measured batch; each trial starts a fresh executable directly.
The owning package is the test's working directory and Cabal build tools are on
its PATH. Ambient Hspec/RTS filters and native consent are removed.

## State and ownership

The common Git directory owns `flake-lab/lab.sqlite3`, `coordinator.md`, and
`runs/<uuid>/`. Every linked worktree sees the same ledger. SQLite transactions,
full synchronization and a versioned schema own registrations, deferrals,
proposals, attempts and outcomes. Unknown schema versions are refused. Completed
attempts are immutable and ingestion is idempotent. The Markdown page and final
run JSON are regenerable views of the database; never hand-edit them.

A repository-local OS lock serializes test/flake execution and prevents competing
lab runs from consuming the same resources. It does not lock other repositories
or stop their builds. A detached checkout per revision lives in a sibling
`.hetoimasia-flake-worktrees/` directory and is reused for incremental builds.
The lab verifies its repository, detached commit and cleanliness; it never
resets a dirty cache. Preserve and inspect an unexpected edit. These caches may
be removed with ordinary `git worktree remove <exact-owned-path>` when no lab
run is active; retained results live separately in the common Git directory.

Each child has a separate process group and a guardian holding the execution
lock. The guardian observes parent-pipe EOF, deadlines and termination signals;
it sends TERM, then KILL after a one-second grace, and reaps its direct child.
Only its own groups are signalled. A successful leader leaving descendants is a
harness error. Trials have a 64 MiB log ceiling. Build preparation has a separate
30-minute ceiling; it never spends the probe's execution budget. Batch deadlines
exclude build/discovery. A trial starts only with enough budget for its full
deadline, so a shortened final window cannot masquerade as a flaky timeout.
Deadlines can overrun only for bounded process cleanup and
recording. The OS, compiler and scheduler can still prevent a meaningful run;
they are reported as setup/infrastructure limitations, not product failures.

Logs and guardian results are synchronized before database ingestion. After a
coordinator crash the next run acquires the execution lock, recovers finished
trial files only after checking their identity and log hash, marks the old run
interrupted, and executes no replacement attempts. Missing or invalid result
files never become passes. Killing the guardian itself or machine failure is
outside the parent-death guarantee; inspect retained evidence before attempting
manual process cleanup. The lab never guesses that an old PID still belongs to
it.

Outcomes distinguish `passed`, `failed`, `crashed`, `timeout`, `inconclusive`,
`harness-error` and `interrupted`. Build/discovery failures block a run before
trials. A completed measurement can contain failures; exit zero means the batch
was recorded, not that every assertion passed. Read its counts and raw logs.
A zero-failure sample is evidence, not proof of stability. Time/budget exhaustion
is incomplete evidence, never a completed planned cohort.

State is local to this clone, not a remote backup. To retain or share a portable
snapshot containing history and artifacts:

```sh
python3 tools/flake/lab.py export --output /absolute/path/new-lab-evidence.zip
```

Export requires no active batch, includes the coordinator page and all retained
run files, and never overwrites an existing destination. Normal system backups
should also include the common Git directory. No operation publishes evidence,
creates issues, approves PRs, or changes failure tolerance.

## Register an investigation

Any Hspec component can be registered locally without editing tracked files:

```json
{
  "id": "runtime-cancellation",
  "kind": "hspec",
  "description": "Investigate a specific cancellation failure",
  "component": "hetoimasia-runtime:test:runtime-tests",
  "project": "cabal.project.cpu",
  "match": "the exact example or subgroup",
  "seed": 1196626676,
  "rts": ["-N2"],
  "attempts": 100,
  "trial_seconds": 15,
  "batch_seconds": 300
}
```

Save that to a temporary JSON file and use `lab.py register <file>`. Empty Hspec
selectors fail discovery rather than counting as passes; pending examples
cannot make a trial pass either. Use the component's
normal RTS configuration first; some suites intentionally have no RTS options.
New settings need a new versioned id instead of mutating an existing contract.
Local registration never changes CI selection. Optional Hspec registration must
reference an existing local-only catalog group; it cannot relabel a CI suite.
Use the default project for GLFW and its documented native SDK environment.

A new Python reproducer uses `kind: command`, `command` argv, optional `prepare`
argv, explicit repository-relative `inputs`, stable `checks`, and `optional:
true` when eligible for ordinary testing. Commit its code in an isolated
worktree before measuring it there with `--ref`; no merge is needed to gather
candidate evidence. It must emit `hetoimasia-probe/v1` JSON at the path supplied
in `HETOIMASIA_PROBE_RESULT`, naming exactly its declared checks, each `passed`,
`failed`, or `unproven`. Exit zero only when every check passed; otherwise exit
one. `probe.report` supplies this small reporter. The lab rejects missing checks,
unknown outcomes, or an exit status contradicting the report. An uncaught crash
or timeout remains recorded even when no report could be produced. A probe must
not detach children into another session or modify its source checkout.

## Deferrals and new coverage proposals

```sh
python3 tools/flake/lab.py defer PROBE --reason 'concrete blocker' --resume-when 'objective condition'
python3 tools/flake/lab.py resume PROBE --evidence 'how that condition was verified'
```

Deferral never erases measurements. Time alone does not resume a probe.
When selection returns `no-candidate`, inspect its skipped reasons and pending
proposals. Busy, blocked, or wrong-platform work does not imply missing coverage.
If useful existing work is exhausted, the skill verifies one distinct gap and
records a proposal with `lab.py propose <json-file>`. The fields are `probe_id`,
`question`, `gap`, `scenario`, `oracle`, `cost`, `tier`, and `revision` (all
nonblank strings). Stable ids deduplicate proposals. Present it for user approval;
proposing does not authorize implementing a new test or altering production.
`proposal-close ID --status accepted|rejected|implemented|superseded --note ...`
retains the disposition and its history.

Analysis consumes final run JSON and logs, determines whether the defect belongs
to the implementation, fixture or infrastructure, and deduplicates existing
tracker work. Repair compares the same probe/configuration against baseline and
candidate, retaining both. These are subsequent workflows; measurement does not
silently diagnose, fix or file anything. Changing a test's oracle is a new probe
contract, not evidence that a production repair worked.

## Maintenance and verification

`catalog.py` owns declarations/selection, `state.py` owns durable records,
`process.py` owns child lifetime, and `lab.py` composes them. There is one selector
and one writer shared by both skills. Future schema changes need explicit
transactional migrations and backward-compatibility tests; never reset the DB.

The focused `Local flake lab` examples in `workflow-tests` invoke `checks.py`
individually. Python fixtures are appropriate here because the asserted boundary
is SQLite locking, Python orchestration and OS process lifetime; they neither
replace nor duplicate engine Hspec assertions. They initialize no engine, Lua VM,
GPU or desktop. Actual repeated measurements remain optional local work.

`install_skills.py` installs the thin repository routes into the personal
`flake`, `test`, and `autotest` skills. Preview with no arguments; use `--apply`
only when the user authorized skill changes. It preserves Synarchy's original
workflow as a skill reference, keeps the other test workflows intact, backs up
changed files, and can be rerun without duplicating the adapter blocks. The
repository README remains the contract; no selector is copied into a skill.
