# #632 evidence: the ps-fallback no-kill cleanup example

Records for PR #633 (issue #632). Candidate evidence: nothing here is a CI
receipt or a lab record unless it says so. Every run below was made at candidate
head `fa56ecc20df16199a2fc82e398738900da486cb5` (the PR's test change; later
heads differ from it by merges of `origin/master` only, which touch no file under
`tools/test/`). Acceptance 4 was dropped by the owner's amendment
(https://github.com/coghex/hetoimasia/issues/632#issuecomment-6688200179) and is
not run.

Retained per-run files (not tracked): `~/.local/state/project-manager/hetoimasia/solve-632-evidence/`.

## Effective RTS

`workflow-tests` is built with `-with-rtsopts=-N2` (`hetoimasia.cabal:199-205`).
"Default RTS" below means no `+RTS` override, which is two capabilities in
effect; `--rts-capabilities 2` is the same capability count, set explicitly.

## What the local series are

`series.py` (below) launches the built `workflow-tests` executable once per run,
each its own process under `perl -e 'alarm N; exec @ARGV'`, output to
`run-NNNN.log` and `run-NNNN.status` in the series directory. With `--churn`, an
unrelated Python process that forks and reaps in a tight loop (the loop of
`churnStage`) runs for the whole run and is killed by its PID afterwards.
`summarize` reads only the retained files: launched = logs; completed = logs with
an Hspec summary line; failures = completed runs whose summary reports a failure;
process timeouts = no summary and status `-14` (SIGALRM). The churn series were
launched with the first version of the script (positional arguments, one example,
alarm 180, working directory the primary checkout); the version below reproduces
their counts exactly from the retained files, and is the one used for the
whole-suite series.

## Acceptance 1: the example and the case alone (lab)

`quruntul flake --target "<id>" --trials 100 --trial-deadline 300 --owner solve-632-<tag> --ref fa56ecc20df16199a2fc82e398738900da486cb5 [--rts-capabilities 2]`
from the primary checkout; `<id>` is
`workflow-tests::Validation execution/preparation and the watchdog/<example>`.
Reports: `.git/quruntul/runs/<run id>/report.md` of the primary checkout.

| Target | RTS | Run id | Result |
|---|---|---|---|
| the existing example | `-N2` explicit | `7e63504b-0313-4b31-b700-ed6af232b46c` | 100 passed |
| the existing example | default | `1f457f6e-77e1-4dbf-bc25-bd11542b589b` | 100 passed |
| the new case | `-N2` explicit | `03dfea1a-a3b1-4500-803c-5970a9687fb0` | 100 passed |
| the new case | default | `fde196af-cdc5-4baf-9966-e8783169aff3` | 100 passed |

These ran 10:09-10:21 UTC; the first two overlapped the end of #631's declared
30-wide load (to about 10:17-10:50 by the manager's later correction). All passed.
One 1-trial probe batch (`--rts-capabilities 2`, same ref) checked that the lab
takes the candidate ref; it passed and counts toward nothing.

## Acceptance 2: the whole suite

### `-N2`, lab: runs `5a896f18-7316-47a6-a3e1-3beb17129b9d` and `8085094b-8b9b-41a8-88fe-da28d1ef7559`

`quruntul flake --target workflow-tests --trials 20 --rts-capabilities 2 --owner solve-632-<tag> --ref fa56ecc2...`
ended `budget-exhausted`: "batch budget left room for 19 of 20 trials". 19
trials ran, 964 examples each. The 20th never ran, and by the manager's ruling a
one-trial top-up at the same ref and setting is the 20th: run `8085094b-...`, 1
trial, 964 examples, passed, 0 failed (788 s). Totals: 20 trials, 19 passed
completely, 1 failed.

- 0 failures of the changed example, of the new case, and of any example in
  `tools/test/Execution.hs` in any of the 20 trials.
- The one failing trial is trial 1 of `5a896f18` (seed 1826637804, ran about
  10:22-10:37 UTC, inside #631's declared load, which began about 10:25 UTC): 1
  failure of 964 in `tools/test/OwnedSubprocess.hs:545`, "the shared subprocess
  facility (Test.Support.Subprocess), the escalation, sends nothing to a child
  that exited by itself and left no member of its group", expected `[]` but got
  `[(ToGroup,15),(ToGroup,9)]`. Not retried (manager's ruling). It is outside this
  issue and is a separate follow-up candidate filed by the manager.

### Default RTS, lab: run `2c1633e1-79cc-4bcf-894d-482cb6976612` (did not run the suite)

`quruntul flake --target workflow-tests --trials 20 --owner solve-632-<tag> --ref fa56ecc2...`
(no `--rts-capabilities`). The lab selected only the never-measured test: the
result reports `"planned_trials": 20, "selected": 1`, and the single measured
test is the new case; each trial ran one example (1.4 s) and passed (20/20).
Stable tests are not re-measured by a default selection. This is the issue's
refusal case (Requirement 10): the lab did not run the batch as specified, so the
default-RTS half ran locally.

### Default RTS, local: 20 sequential whole-suite runs

```
python3 -I series.py run --exe <worktree>/dist-newstyle/build/aarch64-osx/ghc-9.14.1/hetoimasia-0.1.0.0/t/workflow-tests/opt/build/workflow-tests/workflow-tests --out suite-default-local --runs 20 --alarm 3000
```

Built from `fa56ecc2` with `cabal build --project-file cabal.project.cpu workflow-tests`
under the qualified GHC 9.14.1; working directory the issue worktree; no
`--match` (the whole suite), no `+RTS`. Window 14:13-18:04 UTC, no declared load
(the manager posted none; runs took 630-710 s).

| Launched | Completed | Examples per completed run | Failures | Process timeouts |
|---|---|---|---|---|
| 20 | 20 | 965 | 0 | 0 |

## Acceptance 3: the churn control (local)

Selector for both: `--match "reports no kill for a command that exits on the termination signal, reading the ps fallback's table"` (exactly one example in both trees); churn for the whole run.

| Series | Binary | Launched | Completed | Failures | Process timeouts | Window (UTC) |
|---|---|---|---|---|---|---|
| candidate | `fa56ecc2` | 500 | 500 | 0 | 0 | 2026-11-06 07:40:48-07:54:38, no declared load |
| baseline (unchanged example) | `origin/master` `20c869cf` | 500 | 500 | 392 | 0 | 07:55:00-10:08:06; overlaps #629's (about 08:24-09:00) and #631's (09:37-10:17) declared loads |

Baseline failure shapes: 328 of `["timeout","True","False"]`, 64 of
`["timeout","False","False"]` (expected `["timeout","False","True"]`): cleanup reported a kill, or took 5 s or more.

## Deliberate breaks of `tools/validation/run.py` (never committed)

`breaks.py` applies each break to the worktree's `run.py`, runs
`--match "ps fallback"`, and restores `run.py` in a `finally`.

| Break | Result |
|---|---|
| A: `if members or strict:` becomes `if members is not None:` in `cleanup_observation` | new case fails (`["1","False","True"]` for `["4","True","True"]`); the existing example passes (it scripts no spoil) |
| B: `strict_observation` returns `False` as its quiet flag | both fail (`["timeout","True","False"]`) |
| C: `observer_creations += 1` removed from `ps_process_table` | both fail (`["timeout","True","False"]`) |
| D: `expected = 1 + observer_creations - own` becomes `expected = 1` | both fail (`["timeout","True","False"]`) |

## Scripts

### series.py

```python
#!/usr/bin/env python3
"""Local example series for #632 (not a lab record or a CI receipt).

  series.py run --exe EXE --out DIR --runs N [--lanes L] [--churn] [--match M]
                [--alarm SECONDS] [--rts ARG ...]
  series.py summarize DIR

`run` launches the built workflow-tests executable N times, each launch its own
process under perl alarm, output to DIR/run-NNNN.log and DIR/run-NNNN.status
("<exit status> <seconds>"). With --lanes L, L launches run side by side, a wave
at a time (a wave ends when every lane has ended); the default is one after the
other. With --churn, an unrelated process that forks and reaps in a tight loop
(as churnStage does) runs for the whole of each launch (each wave) and is
stopped by its PID afterwards. --match limits the run to the examples whose
path contains M (default: the whole suite). --rts adds `+RTS ARG... -RTS`.
`summarize` reads only the retained per-run files.
"""
import argparse, os, re, subprocess, sys, time

CHURN = """
import os
while True:
    child = os.fork()
    if child == 0:
        os._exit(0)
    os.waitpid(child, 0)
"""

def run(arguments):
    os.makedirs(arguments.out, exist_ok=True)
    command = ["perl", "-e", f"alarm {arguments.alarm}; exec @ARGV", arguments.exe]
    if arguments.match:
        command += ["--match", arguments.match]
    if arguments.rts:
        command += ["+RTS"] + arguments.rts + ["-RTS"]
    environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    index = 0
    while index < arguments.runs:
        lanes = min(arguments.lanes, arguments.runs - index)
        producer = None
        if arguments.churn:
            producer = subprocess.Popen(["python3", "-c", CHURN], start_new_session=True)
        try:
            launched = []
            for _ in range(lanes):
                index += 1
                log = open(f"{arguments.out}/run-{index:04d}.log", "w")
                launched.append((index, time.monotonic(), log, subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, env=environment)))
            for number, began, log, process in launched:
                status = process.wait()
                log.close()
                with open(f"{arguments.out}/run-{number:04d}.status", "w") as handle:
                    handle.write(f"{status} {time.monotonic() - began:.3f}\n")
        finally:
            if producer is not None:
                producer.kill()
                producer.wait()

def summarize(directory):
    logs = sorted(name for name in os.listdir(directory) if name.endswith(".log"))
    launched = completed = failures = timeouts = other = 0
    examples = []
    failing = {}
    for name in logs:
        launched += 1
        text = open(f"{directory}/{name}", errors="replace").read()
        status_path = f"{directory}/{name[:-4]}.status"
        status = open(status_path).read().split()[0] if os.path.exists(status_path) else "missing"
        done = re.search(r"^(\d+) examples?, (\d+) failures?", text, re.M)
        if done:
            completed += 1
            examples.append(int(done.group(1)))
            if done.group(2) != "0":
                failures += 1
                for line in re.findall(r"^\s*(?:\d+\) )?(.+?) \[✘\]\s*$", text, re.M):
                    failing.setdefault(line.strip(), []).append(name)
                if not re.search(r"\[✘\]", text):
                    failing.setdefault("(failure without a marked example)", []).append(name)
        elif status in ("-14", "142"):
            timeouts += 1
        else:
            other += 1
    print(f"launched={launched} completed={completed} failures={failures} process_timeouts={timeouts} other_incomplete={other}")
    if examples:
        print(f"examples per completed run: min={min(examples)} max={max(examples)}")
    for example, runs in sorted(failing.items()):
        print(f"failed example x{len(runs)}: {example}  ({', '.join(runs[:5])}{'...' if len(runs) > 5 else ''})")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    runner = sub.add_parser("run")
    runner.add_argument("--exe", required=True)
    runner.add_argument("--out", required=True)
    runner.add_argument("--runs", type=int, required=True)
    runner.add_argument("--lanes", type=int, default=1)
    runner.add_argument("--churn", action="store_true")
    runner.add_argument("--match", default="")
    runner.add_argument("--alarm", type=int, default=180)
    runner.add_argument("--rts", nargs="*", default=[])
    summary = sub.add_parser("summarize")
    summary.add_argument("directory")
    parsed = parser.parse_args()
    if parsed.command == "run":
        run(parsed)
    else:
        summarize(parsed.directory)
```

### breaks.py

```python
import subprocess, sys, os
W = "/Users/vincentcoghlan/worktrees/coghex/hetoimasia/issue-632-ps-fallback-cleanup"
EXE = W + "/dist-newstyle/build/aarch64-osx/ghc-9.14.1/hetoimasia-0.1.0.0/t/workflow-tests/opt/build/workflow-tests/workflow-tests"
RUN = W + "/tools/validation/run.py"
OUT = sys.argv[1]
BREAKS = {
 "A-accept-spoiled-empty": ("        if members or strict:\n            return members, True", "        if members is not None:\n            return members, True"),
 "B-never-quiet": ("    return members, before is not None and after is not None and after == before + expected", "    return members, False"),
 "C-ps-not-counted": ("    observer_creations += 1\n    try:\n        listing", "    try:\n        listing"),
 "D-ps-not-discounted": ("    expected = 1 + observer_creations - own", "    expected = 1"),
}
original = open(RUN).read()
env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
try:
    for name, (old, new) in BREAKS.items():
        assert original.count(old) == 1, name
        open(RUN, "w").write(original.replace(old, new))
        with open(f"{OUT}/break-{name}.log", "w") as log:
            r = subprocess.run(["perl", "-e", "alarm 400; exec @ARGV", EXE, "--match", "ps fallback"], stdout=log, stderr=subprocess.STDOUT, cwd=W, env=env)
        print(name, "exit", r.returncode, flush=True)
finally:
    open(RUN, "w").write(original)
```
