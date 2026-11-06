# #632 evidence: the ps-fallback no-kill cleanup example

Records for PR #633 (issue #632). Candidate evidence: nothing here is a CI
receipt. The runs below were made at candidate head `fa56ecc20df16199a2fc82e398738900da486cb5`
(tree of the test change; later heads are listed in the PR body).

## What the local series are

`series.py` (below) launches the built `workflow-tests` executable once per run,
each its own process under `perl -e 'alarm 180; exec @ARGV'`, one after the
other, output to `run-NNNN.log` and `run-NNNN.status` in the series directory.
With `churn`, an unrelated Python process that forks and reaps in a tight loop
(the loop of `churnStage`) runs for the whole run and is killed by its PID
afterwards. `summarize` reads only the retained files: launched = logs,
completed = logs with an Hspec summary line, failures = completed runs whose
summary is not `1 example, 0 failures`, process timeouts = no summary and
status `-14` (SIGALRM).

Selector for every series: `--match "reports no kill for a command that exits on the termination signal, reading the ps fallback's table"`
(exactly one example in both trees). Effective RTS: the executable bakes in
`-with-rtsopts=-N2` (`hetoimasia.cabal:199-205`); "default" below means exactly
that, no `+RTS` argument was given.

Retained files (not tracked): `~/.local/state/project-manager/hetoimasia/solve-632-evidence/`.

## Churn control (Acceptance 3)

| Series | Binary | Launched | Completed | Failures | Process timeouts | Window (UTC) |
|---|---|---|---|---|---|---|
| candidate | `fa56ecc2` | 500 | 500 | 0 | 0 | 2026-11-06 07:40:48-07:54:38, no declared load |
| baseline (unchanged example) | `origin/master` `20c869cf` | 500 | 500 | 392 | 0 | 07:55:00-10:08:06; overlaps the declared 30-wide loads of #629 (08:24-about 09:00) and #631 (09:37-10:17) |

Baseline failure shapes: 328 of `["timeout","True","False"]`, 64 of
`["timeout","False","False"]` (expected `["timeout","False","True"]`): cleanup
reported a kill, or took 5 s or more.

## Lab series (quruntul flake), `--ref fa56ecc20df16199a2fc82e398738900da486cb5`

`quruntul flake --target "<id>" --trials 100 --trial-deadline 300 --owner solve-632-<tag> --ref fa56ecc2... [--rts-capabilities 2]`
from the primary checkout; `<id>` is
`workflow-tests::Validation execution/preparation and the watchdog/<example>`.
Reports are `.git/quruntul/runs/<run id>/report.md` of the primary checkout.
`--rts-capabilities 2` sets `-N2`, which is also the executable's baked-in
default, so the two settings are the same capability count; both were run as
asked and are recorded as what they are.

| Target | RTS | Run id | Result |
|---|---|---|---|
| the existing example | `-N2` explicit | `7e63504b-0313-4b31-b700-ed6af232b46c` | 100 passed |
| the existing example | default | `1f457f6e-77e1-4dbf-bc25-bd11542b589b` | 100 passed |
| the new case | `-N2` explicit | `03dfea1a-a3b1-4500-803c-5970a9687fb0` | 100 passed |
| the new case | default | `fde196af-cdc5-4baf-9966-e8783169aff3` | 100 passed |

These ran 10:09-10:21 UTC, the first ones overlapping the end of #631's declared
30-wide load (to 10:17); they are labelled loaded in that window. One 1-trial
probe batch (`--rts-capabilities 2`, same ref, owner suffix `-probe`) was run
first to check the lab accepts the candidate ref; it passed and is not part of
any count.

## Deliberate breaks of `tools/validation/run.py` (never committed)

`breaks.py` applies each break to the worktree's `run.py`, runs
`--match "ps fallback"`, and restores `run.py` in a `finally`.

| Break | Result |
|---|---|
| A: `if members or strict:` becomes `if members is not None:` in `cleanup_observation` | new case fails (`["1","False","True"]` for `["4","True","True"]`); the existing example passes |
| B: `strict_observation` returns `False` as its quiet flag | both fail (`["timeout","True","False"]`) |
| C: `observer_creations += 1` removed from `ps_process_table` | both fail (`["timeout","True","False"]`) |
| D: `expected = 1 + observer_creations - own` becomes `expected = 1` | both fail (`["timeout","True","False"]`) |

## Scripts

### series.py

```python
#!/usr/bin/env python3
"""Local example series for #632 (not a lab record or a CI receipt).

  series.py run <exe> <outdir> <runs> <churn|quiet> <match> [rts-args...]
  series.py summarize <outdir>

`run` launches the built workflow-tests executable once per run, each its own
process under perl alarm, output to <outdir>/run-NNNN.log, one run after the
other. With `churn`, an unrelated process that forks and reaps in a tight loop
(as churnStage does) runs for the whole run and is stopped by its PID afterwards.
`summarize` reads only the retained per-run files.
"""
import os, re, signal, subprocess, sys, time

CHURN = """
import os
while True:
    child = os.fork()
    if child == 0:
        os._exit(0)
    os.waitpid(child, 0)
"""

def run(exe, outdir, runs, mode, match, rts):
    os.makedirs(outdir, exist_ok=True)
    for index in range(1, runs + 1):
        producer = None
        if mode == "churn":
            producer = subprocess.Popen(["python3", "-c", CHURN], start_new_session=True)
        began = time.monotonic()
        try:
            command = ["perl", "-e", "alarm 180; exec @ARGV", exe, "--match", match] + (["+RTS"] + rts + ["-RTS"] if rts else [])
            with open(f"{outdir}/run-{index:04d}.log", "w") as log:
                status = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1")).returncode
            with open(f"{outdir}/run-{index:04d}.status", "w") as handle:
                handle.write(f"{status} {time.monotonic() - began:.3f}\n")
        finally:
            if producer is not None:
                producer.kill()
                producer.wait()

def summarize(outdir):
    logs = sorted(name for name in os.listdir(outdir) if name.endswith(".log"))
    launched = completed = failures = timeouts = other = 0
    failed = []
    for name in logs:
        launched += 1
        text = open(f"{outdir}/{name}").read()
        status = open(f"{outdir}/{name[:-4]}.status").read().split()[0] if os.path.exists(f"{outdir}/{name[:-4]}.status") else "missing"
        done = re.search(r"^(\d+) examples?, (\d+) failures?", text, re.M)
        if done:
            completed += 1
            if done.group(2) != "0" or done.group(1) != "1":
                failures += 1
                failed.append(name)
        elif status in ("-14", "142"):
            timeouts += 1
        else:
            other += 1
            failed.append(name + " (no summary)")
    print(f"launched={launched} completed={completed} failures={failures} process_timeouts={timeouts} other_incomplete={other}")
    for name in failed:
        print("failed:", name)

if __name__ == "__main__":
    if sys.argv[1] == "run":
        run(sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5], sys.argv[6], sys.argv[7:])
    else:
        summarize(sys.argv[2])
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
