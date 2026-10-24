# A failed worker's status while a sibling's start is held: evidence (#568)

Evidence write-up for issue #568 (child #6 of the #563 triage), pull request branch
`issue-568-failed-status-published-first`. Measured by a Class B solver for the manager (request
`user-het-deflake-20261022-2109`) on 2026-10-24, base `origin/master` `b2e382db`, head `cde1822e`
(code identical to the final head unless the pull request says otherwise). Every statement is a measurement
(command and counts given), a quoted output, or labelled **hypothesis**.

## 1. The traced path: confirmed, with two corrections

Confirmed, as the issue states, by the code and by the mutation of section 4: `startSupervised`'s startup wait threw
`StartupInterrupted` from STM; `startWorkerWith` then cancelled and drained the new worker (`drainWorker` absorbs
every interruption, `Worker/Requests.hs`) and only afterwards did `startSupervised` call `checkRuntime`, which is the
first place the sibling's failure was classified and committed. A new worker held where it cannot end therefore kept
the sibling's `workerStatus` at `WorkerLive`. With the product fix reverted, the new deterministic example reads
`WorkerLive` at the moment the held worker first sees the drain's cancellation (section 4).

Corrections to the issue's account, both found while reading the code:

1. **The interruption is absorbed, not recorded, in the late-wake path.** The drain inside `startWorkerWith` discards
   every interruption; the recording waits (`Scheduled.hs:705-716`, `withStartedOwner`) belong to the normal ordering.
   (The second review of the issue had already said so; the harness example of section 3 absorbs without recording.)
2. **An optional sibling never woke the old wait.** The wait interrupted only for a "certainly fatal" outcome
   (required, or failed cleanup). A recognized optional sibling's `WorkerUnavailable` was therefore committed only at
   a checkpoint after the start returned, i.e. after the held worker was released: the same defect for the tolerated
   case, which the old tests did not cover.

The late-wake case (new worker acknowledged, waiter not yet rescheduled) takes **the same path** as the
held-before-acknowledgement case: both are the one `Left others` branch of the wait transaction, whose
failure check precedes `awaitStartup`. It cannot be forced deterministically without a timing dependency: forcing it
needs the starting thread's wake-up to follow both the acknowledgement and the sibling's publication, and the
acknowledgement is written by the new worker's own thread after the starter opened the gate. A first attempt (the
sibling already failed before the start, the new worker held after acknowledgement) is not holdable either: the
latch's stop request reaches the worker before it runs, so it is cancelled before it can acknowledge. The examples
therefore hold the new worker in its startup.

## 2. The fix

- `Hetoimasia.Runtime.Supervision.startSupervised`: the startup wait is now an `IO` loop. In one transaction it
  reads the latch, every other pending outcome and, last, the new worker's startup; when the latch is set or another
  worker has a published failure it settles the other workers' pending outcomes (`settle`, the same classification
  and commit a checkpoint makes), then ends the wait with `StartupInterrupted` if that latched a fatal failure, else
  waits again. The latch's stop request reaches every pending worker, the new one included, in the commit's own
  transaction. `startWorkerWithIO` (new, foundation) takes the `IO` wait and keeps every other behaviour of the
  handoff; `startWorkerWith` is `startWorkerWithIO` with the transaction run by `atomically`.
- The primary failure is unchanged: the new worker is always registered last, so a sibling's failure was and is
  primary, and one batch is still committed in registration order.
- Not changed: `settleClosing` and `docs/supervision.md` "Closing" (decided audit-only, section 6).

## 3. The harness

`Test.LuaRuntime.Support.boundedAfter`, used by `bounded`:

- **Decision: `bounded` itself is hardened** (the issue's own review made this non-optional). The example's thread is
  interrupted with `BoundExpired` when the limit expires and again every `min limit 10 s` until the example has ended.
  A protected wait (a drain, a retirement) takes the first interruption and carries on; the next one ends the wait the
  example then goes on to (an unbounded `takeMVar`, say). Why not restructure only the one example: every caller of
  `alongside`/`alongsideOpening` has the same exposure, and a fix in one example leaves the others hanging on the
  next regression.
- The gates are opened from a thread of its own, as before; the expiry is recorded before the first interruption;
  an example that returns after its bound expired fails (`Gates.hs:52`, still passing); a failure the example raised
  itself after its gates were opened is reported **with** the expiry, not in its place.
- Nothing weakens production retirement or cleanup: only test code changed. A thread that cannot be interrupted at all
  is still not ended (documented in `docs/test_classification.md`).
- `Runner/Retirement.hs` and `Readiness.hs`: every `takeMVar observed` after a boundary became `expectObserved`, a
  non-blocking read that fails the example with a message naming what was missing. `Retirement.hs:77` keeps its name
  and every assertion.
- New examples in `Gates.hs`: a bound that expires inside a protected wait that takes the interruption (no record), then
  an example that waits on an MVar nothing will fill (kept reachable by a live thread so the runtime does not end the
  wait itself), must fail with the bound's expiry and not hang; and an example's own failure after its gates were
  opened is reported beside the expiry.

## 4. Mutation checks (Acceptance 4), local, not committed

Toolchain GHC 9.14.1, `--project-file cabal.project.cpu`. Every command ran under an external alarm; none needed it.

**(a) Product fix reverted** (`Supervision.hs` restored from `b2e382db`, the new examples kept), `runtime-tests --match
"A sibling's failure while a start is in progress"`, exit 1 after 60.0 s (the examples' own deadlines; process ended by
itself, alarm 300 s unused), `5 examples, 5 failures`:

```
1) ... for a required worker, while the new worker is held in its startup
     predicate failed on: ... (Reason "predicate failed on: WorkerLive")
2) ... for an optional worker whose failure is not recognized, ...
     predicate failed on: ... (Reason "the held worker never saw a request")
3) ... for a recognized optional worker: the tolerated status is readable while the new worker is held, and the start goes on
     predicate failed on: Nothing
4) ... during a classifier the start is running, ...      the start never classified the sibling
5) ... after a tolerated sibling was committed and the start went back to waiting
                                                           the start never committed the tolerated sibling
```

Each fails with its own message and the held worker was released each time (no stuck drain).

**(b) The `Retirement.hs:77` helper changed to wait for a status never published** (`WorkerCompleted`), built and run alone:
exit 1 after 60.0 s, the process ended by itself:

```
the example did not finish within its bound
The example had failed with: the helper never observed the other worker's failure while the owner was held: its
terminal status was not readable until the owner was let go
```

**(c) Harness mutation** (the repeated interruption replaced by the former single one): the new `Gates.hs` example
under `alarm 60` was killed by the alarm (exit 142, no output); with the hardened bound it passes in 0.2 s.

## 5. Load protocol (Acceptance 5)

Same protocol as #563 sections 2 and 4: the `lua-runtime-tests` binary at the base (`b2e382db`, built before any edit) and
at the head (`cde1822e`), `+RTS -N2 -T`, 16 concurrent copies, a fresh random seed per trial, per-copy
`TMPDIR=/tmp/h568-<k>` (short), run from `packages/scripting-lua` with
`--ignore-dot-hspec --no-color --unicode --fail-on=empty --seed=<s>`. Driver and tally script: appendix. `$flake` was
not used: the lab runs one copy serially. A hang is a trial killed by its alarm (by the pid the driver started); a bound
failure is an exit-1 trial whose failure block contains `did not finish within its bound` for that example.

| batch | binary | trials | alarm | load 1-min start -> end | hangs | `Retirement.hs:77` bound failures | other failures of that example | other examples |
|---|---|---|---|---|---|---|---|---|
| (a) whole binary | base | 2400 | 300 s | 5.9 -> 21.7 | **2** (seeds 406970780, 1234656628) | 0 | 0 | see below |
| (a) whole binary | head | 2400 | 300 s | 11.4 -> 32.5 | **0** | 0 | 0 | see below |
| (b) example alone | base | 4000 | 120 s | 4.2 -> 5.9 | 0 | 0 | 0 | |
| (b) example alone | head | 4000 | 120 s | 10.1 -> 11.4 | 0 | 0 | 0 | |
| (b') example alone, extra | base | 40000 | 120 s | 15.7 -> 21.9 | 0 | 0 | 0 | |
| (b') example alone, extra | head | 40000 | 120 s | 32.5 -> 41.9 | 0 | 0 | 0 | |

The two base hangs left a `lua-runner-*` directory each and their logs end at the same byte, mid-word at
`delivers each eve`, the signature recorded in #563. The example alone did not hang on the base in 44000 trials: the
machine load of these batches (a few to 40 on 16 CPUs) is below the #563 batches (16-65), so (b) cannot show a
difference; (a) is the batch that does, 2/2400 against 0/2400 (the same order as #563's 7/2400).

Failures of other examples (not this issue's; A, B, C are known load-sensitive failures, #563 children):

- base (a): `idle and stop ... enters no Lua until an event arrives` (A) x5 (seeds 327666239, 18197021, 1410451270,
  2146037127, 1356554039); `Opt-in admission / failure ... reaches the application through the existing escalation
  boundary` (B) x1 (1217248828); `the script instances ... ends one instance without ending the others` (C) x1 (1066015828).
- head (a): A x7 (1494453782, 145971678, 183520669, 432086309, 2022059511, 2095408874, 1908972431),
  B x2 (1628139833, 1835795947), C x1 (1945653033).

## 6. The `BlockedIndefinitelyOnMVar` exit (seed 1066060567)

**Not reproduced; not shown to share the cause; consistent with it.** On the base binary: the seed alone, serial, 10
runs, 10 passes; the whole binary under the loaded protocol with this seed fixed, 160 trials (16 copies), 160
passes, no `BlockedIndefinitely`, no hang. On the head: the same 160 loaded trials, 160 passes. No trial of any batch of section 5
(base and head, 93 130 trials in all) printed `BlockedIndefinitely`.

**Hypothesis** (not measured): the example thread blocked in `takeMVar observed` stays reachable while the bound's
watcher threads hold its `ThreadId`, so the runtime does not end the wait (the hang); once those threads have finished
(the 60 s bound expired, its openers ran) the thread is found blocked on an MVar nothing else can fill, and the runtime
raises `BlockedIndefinitelyOnMVar` in it: a 124 s exit is two bounds. That is the same unbounded `takeMVar`, ended by
the garbage collector instead of never. Requirement 4 removes that wait; the after-runs show none.

## 7. Audit (requirement 7)

**Fixed (same shape).**

- (b) `takeMVar observed` after a boundary, whose only writer is a helper stopped when the main action returns:
  `Runner/Retirement.hs` x5 (all five examples) and `Readiness.hs` x2 ("is observed only after a configured module has loaded" and "does not mistake the startup acknowledgement for readiness"). All now fail naming
  the observation they lacked.
- (b) The single-interruption bound itself (every `bounded` example): hardened, section 3.
- (a) A sibling's failure published only after a held new worker is released, in `startSupervised`: fixed, section 2.
  Every creation that starts a worker through supervision (`startScheduledOwner`, `startLuaOwner`) is covered by it.

**Different, left as is.**

- (a) `settleClosing` (`Supervision.hs:500`): **decided audit-only** by the manager (2026-10-24). A published failure stays
  `WorkerLive` while another worker is held during closing; this is the documented contract (`docs/supervision.md`
  "Closing": drain before settlement, owner cancellation exempt from classification). Behaviour and section unchanged.
- (a) A failure first published after the wait ended, while the new worker is already draining: committed by the checkpoint
  after the drain, as at closing; the drain has begun, so it is the closing shape, and the examples hold the start in its wait.
- (a) `Run.hs` `awaitOwnerEnded`/`retireOwner`, `Scheduled.hs` `awaitTicksComplete` (988), `awaitScheduledAccounting` (1106),
  `Shared.hs` `readiness` (81), `Waits.hs:119`: each waits for its **own** worker's raw completion or status inside
  `awaitSupervised`, which commits every published outcome in the same transaction before it waits; none waits behind a
  held sibling's start.
- (a) `Scheduled.hs` creation (705-716) and `withStartedOwner` (430-441): the retirement waits that record interruptions
  wait for the owner they created to end; they are a different wait from the starter's, and the held owner there is the
  one being retired.
- (b) `Readiness.hs` `takeMVar outcome` ("leaves an abandoned creation owned, stopped and drained"): the creator thread it waits for is unwound by the example's own
  `ThreadKilled`, needs no gate, and, if it did wait on a held gate, the bound's openers end that wait.
- (b) `Runner/Production.hs` (168, 180, 186) and the other `takeMVar` of a thread the example itself drives to completion
  (`Scheduler/*`, `Lifecycle/Logical`, `Admission/Races`): the writer is a thread the example started and released, not a
  helper the main action's end stops; with the hardened bound a stuck one is interrupted anyway.
- (b) The remaining callers of `alongside`/`alongsideOpening` (`Runner/Tables|Failures|Output|Ending|Events|Ticks|Kinds|Determinism`)
  take no value from the helper after the boundary.
- (b) The `lua-engine` suites' own `exampleBound` (`Data|Modules|Request|Texture/Support.hs`) and the graphics rig
  (`Rig.hs`): each is a single `timeout` around the example with the gates opened in `finally`, **after** the body ends.
  That is a different defect (the gates are not opened at expiry, so a protected wait for a held gate can never end),
  and its fix is a harness-wide watchdog for those suites, which #568 puts out of scope; no hang of theirs was
  measured. Worth a follow-up issue.
- (b) `foundation` `Resources/Spec.hs` and `runtime` `ResourceSmoke.hs` (`timeout` of 30 s): bound a call that holds no
  gate and has no protected exit.

## Appendix: driver and tally

`load_driver.py` (run as `python3 -I load_driver.py BINARY CWD OUTDIR TRIALS ALARM [--match PATH] [--seed N] [--copies 16]`,
with `PYTHONDONTWRITEBYTECODE=1`):

```python
#!/usr/bin/env python3
"""Loaded-trial driver for lua-runtime-tests (issue #568, acceptance 5).

Runs COPIES concurrent loops of one test binary. Each trial is one process with a fresh random
seed (or a fixed one), its own short TMPDIR, `+RTS -N2 -T`, and a hard per-trial alarm. A trial
over its alarm is killed by the pid this driver started. Results go to one JSON line per trial.

usage: load_driver.py BINARY CWD OUTDIR TRIALS ALARM_SECONDS [--match PATH] [--seed N] [--copies 16]
"""
import json, os, random, re, shutil, signal, subprocess, sys, threading, time

def main():
    args = sys.argv[1:]
    binary, cwd, outdir, trials, alarm = args[0], args[1], args[2], int(args[3]), int(args[4])
    match = None; seed = None; copies = 16
    i = 5
    while i < len(args):
        if args[i] == '--match': match = args[i + 1]; i += 2
        elif args[i] == '--seed': seed = int(args[i + 1]); i += 2
        elif args[i] == '--copies': copies = int(args[i + 1]); i += 2
        else: raise SystemExit('bad argument ' + args[i])
    os.makedirs(outdir, exist_ok=True)
    jsonl = open(os.path.join(outdir, 'trials.jsonl'), 'a')
    lock = threading.Lock()
    counter = {'next': 0}
    rng = random.SystemRandom()
    load_start = os.getloadavg()[0]
    started = time.time()

    def trial_number():
        with lock:
            n = counter['next']; counter['next'] += 1
            return n

    def worker(copy):
        tmp = '/tmp/h568-%d' % copy          # short: a long TMPDIR truncates Lua chunk names
        while True:
            n = trial_number()
            if n >= trials: return
            s = seed if seed is not None else rng.randrange(1, 2**31)
            shutil.rmtree(tmp, ignore_errors=True); os.makedirs(tmp)
            cmd = [binary, '--ignore-dot-hspec', '--no-color', '--unicode', '--fail-on=empty', '--seed=%d' % s]
            if match: cmd += ['--match', match]
            cmd += ['+RTS', '-N2', '-T', '-RTS']
            env = dict(os.environ, TMPDIR=tmp)
            t0 = time.time()
            proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            hung = False
            try:
                out, _ = proc.communicate(timeout=alarm)
            except subprocess.TimeoutExpired:
                hung = True
                os.kill(proc.pid, signal.SIGKILL)   # the pid this driver started
                out, _ = proc.communicate()
            text = out.decode('utf8', 'replace')
            failures = []
            for m in re.finditer(r'^\s+\d+\) (.+?)\n((?:(?!\n\s*\n).)*)', text, re.M | re.S):
                failures.append({'name': m.group(1).strip(), 'bound': 'did not finish within its bound' in m.group(2),
                                 'text': m.group(2)[:600]})
            blocked = 'BlockedIndefinitely' in text
            leftover = [d for d in os.listdir(tmp) if d.startswith('lua-runner-')]
            rec = {'trial': n, 'seed': s, 'exit': proc.returncode, 'hung': hung, 'seconds': round(time.time() - t0, 1),
                   'failures': failures, 'blocked_indefinitely': blocked, 'leftover_runner_dirs': len(leftover)}
            with lock:
                jsonl.write(json.dumps(rec) + '\n'); jsonl.flush()
                if hung or proc.returncode != 0:
                    open(os.path.join(outdir, 'trial-%05d.log' % n), 'w').write(text)
    threads = [threading.Thread(target=worker, args=(c,)) for c in range(copies)]
    for t in threads: t.start()
    for t in threads: t.join()
    summary = {'trials': trials, 'copies': copies, 'alarm': alarm, 'seed': seed, 'match': match, 'binary': binary,
               'load_1min_start': round(load_start, 1), 'load_1min_end': round(os.getloadavg()[0], 1),
               'wall_seconds': round(time.time() - started)}
    open(os.path.join(outdir, 'summary.json'), 'w').write(json.dumps(summary) + '\n')
    for c in range(copies): shutil.rmtree('/tmp/h568-%d' % c, ignore_errors=True)
    print(json.dumps(summary))

main()
```

`tally.py OUTDIR`:

```python
import json,sys,collections
d=sys.argv[1]
rows=[json.loads(l) for l in open(d+'/trials.jsonl')]
RET='completes before the run propagates a failure another supervised worker latched during startup'
hung=[r for r in rows if r['hung']]
failed=[r for r in rows if not r['hung'] and r['exit']!=0]
ret_fail=[r for r in failed if any(RET in f['name'] for f in r['failures'])]
ret_bound=[r for r in ret_fail if any(RET in f['name'] and f['bound'] for f in r['failures'])]
others=collections.Counter()
seeds=collections.defaultdict(list)
for r in failed:
    if not r['failures']:
        others['(exit %d, no failure block)'%r['exit']]+=1; seeds['(exit %d, no failure block)'%r['exit']].append(r['seed'])
    for f in r['failures']:
        others[f['name'][-110:]]+=1; seeds[f['name'][-110:]].append(r['seed'])
print('trials',len(rows),'hung',len(hung),'failed(exit!=0)',len(failed),'retirement:77 failures',len(ret_fail),'of which bound',len(ret_bound),'blocked_indef',sum(r['blocked_indefinitely'] for r in rows),'leftover dirs',sum(r['leftover_runner_dirs'] for r in rows))
print('hung seeds',[r['seed'] for r in hung])
for k,v in others.most_common(): print(v,k,seeds[k][:6])
```

Commands used: whole binary `load_driver.py BIN packages/scripting-lua OUT 2400 300`; example alone
`load_driver.py BIN packages/scripting-lua OUT 4000 120 --match "/the Lua runtime adapter/Runner/retirement/completes before the run propagates a failure another supervised worker latched during startup/"`;
seed `load_driver.py BIN packages/scripting-lua OUT 160 300 --seed 1066060567`.
