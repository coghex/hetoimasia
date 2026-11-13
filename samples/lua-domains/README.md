# Lua domains sample

A small, headless, application-owned program that runs a **UI** Lua VM owner
and a **gameplay** Lua VM owner side by side, so that the UI keeps making
progress and reads a coherent, completed view while gameplay is busy, and so
that what the UI asks of gameplay reaches it exactly once. It also carries the
qualification of deterministic gameplay: a canonical state digest, a
tick-assigned input log and its replay.

It composes the two owners from the Lua package's public modules and the
foundation's latest-value snapshot. It uses no `Internal` module and has no
Vulkan, GLFW or console dependency, so it builds in both projects. No engine
library depends on it, and nothing routine launches its executable.

## Reproduce

```sh
cabal run exe:hetoimasia-lua-domains -- --ticks 20 --seed 1
cabal run exe:hetoimasia-lua-domains -- --scenario normal     # exits 0
cabal run exe:hetoimasia-lua-domains -- --scenario failure    # exits 1, with the failure as evidence
cabal run exe:hetoimasia-lua-domains -- --help
cabal test hetoimasia-sample-lua-domains:lua-domains-tests --test-show-details=direct
# the input log, its replay and the digest trace (SCRATCH is a directory of your own)
cabal run exe:hetoimasia-lua-domains -- --scenario normal --ticks 50 --seed 1 --record "$SCRATCH"/log.txt --digests
cabal run exe:hetoimasia-lua-domains -- --replay "$SCRATCH"/log.txt --ticks 50 --seed 1 --digests
# the optional profiling probe: prints records, asserts no number
cabal test hetoimasia-sample-lua-domains:lua-domains-profile --test-show-details=direct
```

Add `--project-file cabal.project.cpu` for the CPU-only configuration. The
validation group is `test.lua-domains`; the probe is the optional
`test.lua-domains-profile`, which affected inputs never select. The two
`--digests` runs print the same `digest N HEX` lines.

## What owns what

The sample's state is one `Shared` value created on the application thread
before either owner starts. No field is a Lua value or a handle into a VM.

| State | Writer | Readers |
| --- | --- | --- |
| Committed world (entities, tick, session, random state) | the driver | gameplay's bindings, through the tick's candidate |
| Tick candidate (applied intentions, staged batch, stream state) | the driver makes and discards it; gameplay's bindings write between | gameplay's bindings, the driver |
| Intention queue | any producer's transaction; sealed and settled by the driver | the driver |
| Snapshot (`GameSnapshot`, one revision per commit) | the driver, in the committing transaction | the UI owner's per-segment capture |
| UI view | the UI owner, as each segment is about to run | the UI's bindings |
| Session state, counters, control bookkeeping, workspace tally | the owners' escalation callbacks, the driver, the answering transactions | the driver, the report |
| Digest trace, input recorder, replay feed | the driver and the admitting transactions | the report |

The UI never reads the committed world or the candidate; gameplay never reads
the view or the snapshot.

## The two owners

`withDomains` creates one `LuaRuntime` and two scheduled owners, each with its
own VM, standard libraries, scheduling bounds and `vmPolicy`.

- **Gameplay** is a `Periodic` instance on `LogicalTicks 1`: its `update` runs
  once per tick the driver grants, and its logical time moves only then.
- **UI** is a `Periodic` instance on `ElapsedEvery`, on the clock and timer
  the configuration supplies (real in the executable, injected in examples).

Gameplay starts first. Retirement runs in the opposite order on every way out:
queue admission closes, the UI owner is retired and awaited, then gameplay,
then the snapshot's publication ends. Each wait is for the owner's worker to
have actually ended, never for supervision's status. The wait is
interruptible; an interruption is recorded and the wait continues until both
owners have ended. Nothing is preempted.

The UI owner is granted control and inspection of the gameplay owner's
endpoint and nothing else (`lifecycleGrant`).

**Registration.** One `Registration` defines every binding once; a namespace
outside an owner's policy is absent from its VM's globals.

| Namespace | Exposed to | Purpose |
| --- | --- | --- |
| `view` | UI | snapshot queries answering from the segment's one capture |
| `intent_raw`, `control_raw`, `lifecycle_raw` | UI | raw bindings the UI's initial chunk wraps in a facade and removes from the globals |
| `input`, `ui` | UI | the fixed fake input source; notes of what the UI did |
| `workspace` | gameplay | the per-instance leased workspace |
| `world`, `staging`, `rand` | gameplay | the tick's candidate, the bounded move batch, the application-owned random stream |

The only capability type is `workspace`, valid only in the gameplay VM while
its lease is live. Module state is per VM.

## The world and one tick

At most 64 entities (eight by default), each with an integer position clamped
to ±10⁹ and a version that changes exactly when its position does.

The driver's `stepTick`, on the application thread only:

1. In one transaction: check the session still runs, wait while a control
   request is between its assignment and the engine's admission, seal the next
   unstarted tick of the queue, and make the tick's candidate (the committed
   world with the tick's intentions revalidated and applied in place order).
2. Grant gameplay one logical step. The check that the session still runs and
   the mark that a grant is being issued are one transaction, so no grant is
   issued once a failure or stop is recorded.
3. Wait for the owner to complete the tick.
4. Wait for the owner's accounting (`awaitScheduledAccounting`). Tick
   completion alone does not mean the instance layer has accounted for the
   tick's last segment. Tick T's failures are those of its own work and every
   ending begun by the end of that accounting; none ever lets T commit. A
   failure that begins after that cutoff belongs to the first tick not yet
   committed.
5. Decide: a failure fails the session and commits nothing; a stop commits
   nothing; otherwise the tick commits only if its work finished (gameplay
   called `staging.finish()` with nothing in flight), or the engine says why
   there was no work (the behavior is paused, was paused as the tick began, or
   a control was applied at its boundary). Anything else raises
   `TickNotCompleted`.
6. Commit in one transaction: replace the committed world, publish the
   snapshot, settle the tick's reservations and count its dispositions. A
   reader sees the whole tick or none of it.

Staging changes nothing until the commit and is not visible to gameplay's own
reads. A tick held inside a segment publishes nothing, so the snapshot always
shows the last completed tick. Real delays change when a commit happens and
never what it contains.

Whether an update began is application evidence: every gameplay `update` is
wrapped so `staging.began()` is recorded before the script's code runs. An
update that began must call `staging.finish()` to commit.

## Intentions

A UI intention is "move an entity by a delta", carrying the session, the tick
of the view it acted on, the entity and the entity's version in that view.
`intent.submit(...)` answers at once and never waits for gameplay:

| Answer | Meaning |
| --- | --- |
| `true, nil` | taken for the next tick that has not started |
| `false, "full"` | the queue's bound or that tick's places are all taken |
| `false, "closed"` | no unstarted tick is left to take it |
| `false, "malformed"` | wrong arity or a non-integer; answered by the Lua facade |
| `false, "session"`, `"tick"`, `"entity"`, `"version"`, `"delta"` | a value outside the application's bounds |

The facade exists because a wrong arity or type at the typed binding is a
fault `pcall` cannot turn into an answer.

- **Bounds.** `boundQueue` (12) counts accepted intentions not yet settled;
  `boundPlaces` (8) is how many one tick holds; `boundDelta` (8) bounds a move.
- **Tick assignment cannot race the tick.** Admission and the driver's seal
  are transactions on the same variable, so an accepted intention is never for
  a tick that has begun. The explicit seam `admitAt` answers *late* or
  *duplicate* and never applies at a later boundary.
- **Exactly once, with revalidation.** Every accepted intention gets exactly
  one terminal disposition. It is stale when the session differs or the
  entity's version in the candidate no longer matches. Revalidation is
  sequential in place order.

| Disposition | When |
| --- | --- |
| applied, rejected as stale | the tick it was accepted for committed |
| invalidated | a failure ended the session before that tick committed |
| discarded | a stop or retirement ended the session before that tick committed |

After a quiescent run `accepted = applied + stale + invalidated + discarded`
with nothing pending, and `runSession` raises `ConservationViolated`
otherwise. Offers satisfy
`accepted + full + closed + refused + malformed + declined`.

## A failed session

Any failure of script execution on the gameplay owner fails the session. The
first is the primary; later ones are evidence (four kept, the rest counted).
A binding that raises is an owner failure supervision reports, not a script
failure.

- The instance's escalation callback records the failure and answers
  `Isolate`, so the engine keeps the owner and VM alive, running nothing.
- Admission closes in the transaction that records the failure, and the
  session takes no new task from that moment.
- The driver learns of a failure in tick T before it decides T's commit, on
  every ordering. From then it grants and commits nothing.
- A failure asks every gameplay instance and task to stop as soon as it is
  told, without waiting, so an outstanding tick can complete.
- The driver publishes one snapshot for the failure: the last good world and
  tick, status `Failed` with the primary failure, and the invalidated
  intentions. The session is quiescent when it is published. The failing tick
  is the last good tick plus one.
- Each watched task's settlement is told exactly once, and an accepted task is
  tracked from the moment the owner accepts it, whatever is cancelled.
- A failure told of later (a `shutdown` that raises during teardown) goes to
  the cleanup evidence and is never published.

A failure of the UI behavior is isolated: it is recorded once, the UI instance
ends and is not restarted, gameplay keeps ticking, and the exit status says
the UI failed.

## Stopping and cancellation

`stopSession` runs on the application thread and may be called again. It
closes admission and grants, asks every gameplay instance and task to stop
without waiting, waits for each instance to settle (its `shutdown` and lease
release included) and for the owner's accounting, publishes one last snapshot
(`Stopped`, or the failure if `shutdown` raised), lets the UI read its
receipts, then closes publication and retires both owners, UI first.

Another thread asks with `requestStop`, which records the intent, closes
admission and asks everything to stop; a tick in flight then answers
`TickHalted` and commits nothing.

Cancellation of the enclosing scope retires both owners by cancelling them:
what is not settled is discarded, and nothing hangs.

For every way a session can end, `cleanupEvidence` (and the report's last
lines) gives one bounded record: both owners' exits, each instance's
termination, workspaces acquired against released, the ledger, control counts
and late failures.

## Leases and controls

**Leases.** Each gameplay instance's `init` opens a workspace through the
engine's leases (capacity two) and never releases it. The engine releases
whatever an instance acquired when the instance ends, however the script
behaves. A release that itself fails is cleanup evidence that ends the owner
fatally; it is not a recoverable session failure.

**Controls.** The UI may ask the gameplay behavior to pause or resume. The
application assigns each request the next unstarted tick and a place in it,
and the engine applies it at that tick's boundary.

- A request is accepted, or refused at once (`unassigned`, `unknown_target`).
- An accepted request settles *applied*, *already in that state*, or *no
  longer applicable*. The UI reads it through a receipt; receipts it still
  holds when it ends are *abandoned*, and an abandoned control still applies.
- Pause stops the gameplay behavior's `update` and nothing else: ticks are
  still granted and committed and accepted intentions are applied while
  paused.
- The UI facade brackets each lifecycle call with an in-flight count the
  driver's begin transaction waits on, so a control is never late and the UI
  never waits for the driver.

## The UI's view and progress

The UI owner captures the latest committed snapshot at the start of each
segment, and every `view` query in that segment answers from that one capture.

UI progress is proven two ways, with no host instruction hook:

- **Barrier.** A test binding holds a gameplay segment while the UI owner
  completes a fixed number of updates, each made due by hand.
- **CPU-bound.** A pure-Lua computation with no binding call or yield runs as
  gameplay's update while the UI runs on the real clock. The UI's
  completed-update count taken when the computation starts and when it ends
  must differ by at least five. It needs the threaded runtime with at least
  two capabilities (`-threaded -with-rtsopts=-N2`).

## Randomness

Gameplay's randomness is an application-owned SplitMix64 stream, fixed in
`World.hs` so its output cannot change with a library version, seeded per
session (`--seed`). Its state is part of the committed world and advances only
in the tick's candidate. `math.random` and `math.randomseed` are removed from
the gameplay VM.

## The canonical state and its digest

`Canonical` encodes what the driver committed or published as bytes and
digests them with SHA-256. The encoding is versioned (`HLDS`, version 1):
fixed-width big-endian integers in a fixed order, with no `show`, no floating
point and no map iteration order. It covers the committed tick, the random
state, the entities, the status and the dispositions. It excludes run-local
identity and script-chosen text: session and instance identities, the
failure's message, tracebacks, timestamps and the snapshot's revision.

- **The trace** holds the digest of the initial state and of each committed
  tick, appended in the committing transaction. It is bounded at 100,001
  entries and a full trace raises.
- **The final digest** is of the final published snapshot, status included, so
  a failure or stop after the last commit changes it without touching the
  trace.
- Two hand-built states are pinned to golden values. No whole-run digest is
  committed: the claim is the same build and platform.

## The input log and its replay

`InputLog` is a text format: a versioned header, one line per accepted record
in canonical order, and a trailer that counts them.

```
hetoimasia-lua-domains input log v1
control tick=5 place=0 target=gameplay op=pause
intent tick=6 place=0 session=current view=5 entity=3 version=0 dx=1 dy=-2
end records=2
```

A record is something the session accepted, with its tick and place; it never
names a run-local identity. The writer collects each admission in the
transaction that makes it and never hands back a log that lost a record. The
parser refuses a malformed, unordered, duplicated, over-bound or truncated
log whole, naming the line.

A replay (`--replay`) takes the session's intentions and controls from the log
and nothing else. The driver releases a tick's records when that tick is next,
through the same admission seams the live path uses. The UI's own offers are
answered `replay` (declined) and its control requests refused. A log that
cannot be replayed is refused before the session starts. A session that fails
or stops before a record's tick is reported as an incomplete replay.

## What was qualified

One gameplay VM, one scheduling configuration, the same build and platform,
and identical tick-assigned inputs (the log, the seed, the initial world and
the scenario) give the same digest at every tick boundary, however long
segments take, whatever the UI does and wherever grants are issued.
`Test.Domains.Qualify` shows it with real interpreters under real supervision:
held and released segments, differing spin work, extra UI activity, grants
back to back and with gaps, the UI on the real clock, and a replay with no UI
activity. Three negative controls (a different seed, a record moved to another
tick, two intentions exchanged in place order) each diverge at the first tick
they should.

**Not qualified:** different scheduling policies, worker counts, platforms or
library versions; cross-platform bitwise identity; cross-version replay;
network lockstep; a replay product (the log carries no seed, tick count or
scenario). A failure that begins after a tick's accounting cutoff may land at
that tick or the next, so a run that depends on one is never compared by
trace.

## The executable

```
hetoimasia-lua-domains [--ticks N] [--seed N] [--scenario NAME] [--record FILE] [--replay FILE] [--digests] [--expect-digest HEX]
```

It runs both owners against a fixed scripted input source (or a log), commits
N ticks (1 to 100,000, default 20), retires both owners and prints one bounded
report on stdout.

| Scenario | What it does | Exit |
| --- | --- | --- |
| `normal` | the fixed input | 0 |
| `pause` | the UI pauses gameplay at tick 4 and resumes it at tick 9 | 0 |
| `failure` | gameplay raises at tick 6; the session fails with tick 5's world | 1 |
| `flood` | the UI offers two hundred intentions; many are answered `full` | 0 |
| `stop` | the driver stops the session after tick 8 | 0 |

- `--record FILE` writes the accepted-input log. `FILE` must not exist: it is
  created exclusively after the session, written whole, and removed on every
  unsuccessful way out.
- `--digests` prints `digest TICK HEX` for each committed tick.
- `--expect-digest HEX` compares the final digest and exits 1 on a mismatch.

Exit status: **0** when the session ended without a failure (a stop is not
one); **1** when the gameplay session or the UI failed, the digest mismatched,
or a requested recording could not be written; **2** for a bad argument or an
unusable `--replay` or `--record` path, with one line on stderr and nothing
run. Counts in the report vary from run to run because the UI runs on elapsed
time; the conservation laws do not.

## Tests

`lua-domains-tests` is Hspec with real interpreters under real supervision and
no timing sleeps: explicit gates, STM waits and bounded waits through
`hetoimasia-test-support`. Run one group with
`--test-option=--match --test-option="NAME"`. The executable is reached
through `build-tool-depends` and run as a bounded child process. Shared
helpers are the private library `lua-domains-fixtures`. Every thread an
example starts is owned (`Test.Support.Owned`) and joined when its scope ends.

The optional probe `lua-domains-profile` prints one record per bounded
workload (UI update cadence, gameplay throughput, scheduler counters, RTS
statistics, repeated qualification runs) and asserts no number.
