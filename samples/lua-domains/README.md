# Lua domains sample

LUA-29's consumer (owner decision D-44 of
[`docs/lua_runtime_design.md`](../../docs/lua_runtime_design.md)): a small, headless,
application-owned program that runs a **UI** Lua VM owner and a **gameplay** Lua VM owner side
by side, so that the UI keeps making progress and reads a coherent, completed view while gameplay
is busy, and so that what the UI asks of gameplay reaches it exactly once.

It composes the two owners directly from the Lua package's public modules
(`Hetoimasia.Scripting.Lua.Scheduled`, `.Instance`, `.Owner`, `.Registration`, `.Value`,
`.Runtime`, `.Scheduler`) and the foundation's latest-value snapshot. It does not use the
single-VM runner (`Hetoimasia.Scripting.Lua.Runner`) or any `Internal` module, and it has no Vulkan,
GLFW or console dependency, so it builds in both `cabal.project` and `cabal.project.cpu`. No engine
library depends on it, and nothing routine launches its executable.

This sample covers the two-domain core (LUA-29) and, on top of it, the paths that decide whether the
design is trustworthy (LUA-30): a failed gameplay session, overload beyond the `full` answer, the stop and
cancellation paths with cleanup evidence on every path, the leases a gameplay instance holds, and the UI's
pause and resume of gameplay. Determinism qualification is a later slice; nothing below claims it.

## Reproduce

```sh
cabal run exe:hetoimasia-lua-domains -- --ticks 20 --seed 1
cabal run exe:hetoimasia-lua-domains -- --scenario normal     # exits 0
cabal run exe:hetoimasia-lua-domains -- --scenario failure    # exits 1, with the failure as evidence
cabal run exe:hetoimasia-lua-domains -- --help
cabal test hetoimasia-sample-lua-domains:lua-domains-tests --test-show-details=direct
```

Add `--project-file cabal.project.cpu` to any of them for the CPU-only configuration. The
validation group is `test.lua-domains`, a non-optional group of the `haskell-engine` worker.

## What owns what

The sample's own state is one value, `Shared` (`Hetoimasia.Sample.LuaDomains.Shared`), created on the
application thread before either owner starts and dropped with the session. No field is a Lua value or
a handle into a VM; each owner's bindings borrow what they need and nothing else.

| State | Owner (writer) | Readers | Thread | Lifetime |
| --- | --- | --- | --- | --- |
| Committed world (entities, committed tick, session, random state) | the driver | gameplay's bindings through the tick's candidate | application thread | the session |
| Tick candidate (applied intentions, staged batch, stream state, finished flag) | made and discarded by the driver; written, between the two, by gameplay's bindings only | gameplay's bindings, the driver | gameplay owner's callback thread | one tick |
| Intention queue | any producer's transaction (the UI's binding in production); sealed and settled by the driver | the driver | any | the session; closed first at retirement |
| Snapshot (`GameSnapshot`, one revision per commit) | the driver, in the transaction that commits the tick | the UI owner's per-segment capture | any | the session; closed after both owners are retired |
| UI view (the segment's capture) | the UI owner, as each of its segments is about to run | the UI's bindings | UI owner's thread and its callback thread | one segment |
| Fake input source, completed-update count | the UI's bindings | the UI's bindings, the examples | UI owner's callback thread | the session |
| Counters by answer and by disposition | the answering and committing transactions | the report, the examples | any | the session |
| Session state (`Session`): the failures told of, whether a stop was asked for, how the session ended | the owners' escalation callbacks, the driver's stop | the driver, the report | the owner's thread, the driver | the session |
| Control bookkeeping (next place per tick, requests in flight, counts, receipts held) | the UI's facade, the assignment callback | the driver (it waits on the in-flight count), the report | the UI owner's thread, any | the session |
| Workspace tally (acquired, released, release failed) | the workspace's acquire and release, on the gameplay owner's threads | the report, the examples | any | the session |

The UI never reads the committed world or the candidate; gameplay never reads the view or the snapshot.

Every integer a script supplies is compared directly and never through `abs`, whose result for the minimum
integer is itself negative: one check (`deltaWithin`) serves the admission of an intention and the staging of
a move, and a move adds in `Integer` before it clamps, so no delta can wrap.

## The two owners

`withDomains` creates one `LuaRuntime` and two scheduled owners, each with its own VM, standard
libraries, scheduling bounds, initial chunk and `vmPolicy`, under the supervision boundary its caller
provides. The executable and the examples reach one through `runScopedApplication`/`withSupervision`.

* **Gameplay**, `GameplayDomain`: its behavior is a `Periodic` instance on `LogicalTicks 1`, so its
  `update` runs once in every tick the driver grants. Its logical time moves only when the driver
  grants a step.
* **UI**, `InterfaceDomain`: its behavior is a `Periodic` instance on `ElapsedEvery`, on the clock and
  timer the configuration supplies: the real ones in the executable, an injected clock and a fake
  timer wake in the examples that move it by hand.

Gameplay is started first and the UI second. Retirement runs in the opposite order, on every way out
(`withDomains`, `runSession`, or `retireDomains` itself): admission to the queue closes first, then the UI
owner is retired and awaited (the producer of intentions and reader of snapshots is gone), then gameplay,
then the snapshot's publication ends. Each wait is for the owner's worker to have *actually ended* (its raw
completion), never for supervision's status: supervision latches one owner's fatal failure and wakes its own
waits with it, which says nothing of the other owner, so a retirement that relied on it could leave an owner
running a Lua segment when the call returned. The wait is not a resource release, so it is interruptible;
an interruption is recorded and the wait goes on until both owners have ended, and then what happened is
raised, a cancellation first. A segment an owner is inside is let return: nothing is preempted. The same
protected wait retires an owner that came up when the other failed to start. Each owner's exit record and its
instance's settlement are read back (`Retirement`), and when `withDomains` returns or raises, from inside
the supervision boundary, neither owner is live.

Grants start only after the owners' behaviors are active (`init` has run), or have failed: an `init` that
raises ends the instance, which is the session's failure and is published before the first tick (below).

Both owners are created with the engine's `vmPolicy` for what each exposes, but the cross-owner link is the
engine's own: the UI owner is granted **control and inspection of the gameplay owner's endpoint and nothing
else** (`lifecycleGrant`), and gameplay admits those controls logically, at an application-assigned tick.

## Registration and exposure

One `Registration` defines every binding once. A namespace outside an owner's policy is absent from
its VM's globals, and the production registration contains exactly these (a test that needs a binding
of its own adds it through `DomainsConfig.configExtensions`, which the production configuration leaves
empty).

| Namespace | Exposed to | Bindings |
| --- | --- | --- |
| `view` | UI | `tick()`, `session()`, `count()`, `entity(i)`: snapshot queries answering from the segment's one capture |
| `intent_raw` | UI | `submit(...)`, the typed intention binding, and `malformed()`; the UI's initial chunk reads both and removes the namespace |
| `input` | UI | `poll()`: the next entry of the fixed fake input source, and `scenario()`: the scenario's name |
| `ui` | UI | `updated()`: one update completed; `busy()`, `saw(status)`: what the UI noted |
| `control_raw` | UI | bookkeeping for the control facade (`begin`, `finish`, `note`, `settled`), removed from the globals by the UI's initial chunk |
| `lifecycle_raw` | UI | the engine's lifecycle namespace (`pause`, `resume`, `result`) over the granted gameplay endpoint, wrapped by the facade and removed |
| `workspace` | gameplay | `open()`, `note(handle, n)`, `read(handle)`: the per-instance leased workspace |
| `world` | gameplay | `tick()`, `session()`, `count()`, `entity(i)` over the tick's candidate |
| `staging` | gameplay | `move(i, dx, dy)` into the bounded batch, `finish()` |
| `rand` | gameplay | `below(n)`: a draw from the application-owned stream |

The one capability type is `workspace`, issued by the gameplay VM for the gameplay instance that opened the
workspace; it is a lease handle, valid only in that VM and only while the lease is live, and nothing in it
names anything in the other VM. The UI sees no capability type: it reaches gameplay only through the
engine's lifecycle controls, whose target is a plain record of the gameplay behavior's engine identity
(read from the view). Module state, including a global or an upvalue, is per VM.

## The world and one tick

The world is deliberately small: at most 64 entities (eight by default), each with an integer position
and a version that changes if and only if its position does, the committed tick, the session's identity
and the random stream's state. Positions are clamped to ±10⁹.

The driver's `stepTick`:

1. In one transaction, check the session still runs (nothing failed, no stop was asked for), **wait while a
   control request is between the assignment of its place and the engine's admission of it** (the UI's
   bracket; a UI that has ended is not waited for), then **seal** the next unstarted tick of the queue and
   make the tick's **candidate**: the committed world with the tick's intentions revalidated against it, in
   the order of their places, and applied (below). The tick's random stream starts at the committed state.
2. **Grant** gameplay one logical step of the configured duration (ten milliseconds). One grant is
   outstanding at a time.
3. Wait for the owner to complete the tick (`awaitTicksComplete`).
4. **Accounting.** A completed tick says only that the grant was applied and nothing is left it could run: the
   scheduler reconciles the grant *before* the instance layer has accounted for what the tick's last segment
   did, so an invocation the scheduler ended with a refused wait still looks, for a moment, like an active
   instance with nothing in flight. The driver therefore waits for the owner's accounting
   (`awaitScheduledAccounting`, D-47), which takes no task, ticket or slot: an instance that failed has ended (its
   `shutdown` and the release of what it held included) and the application's escalation has been called and has
   returned. If the owner ended instead (`AccountingOwnerEnded`) nothing was accounted for and nothing is
   committed. The wait is one of the supervised waits the sample makes, and those are the application thread's (the
   thread that created the session, which owns the supervision handle), one at a time: `stepTick` and `stopSession`
   refuse any other thread (`DriverOffApplicationThread`, `StopOffApplicationThread`), and another thread asks for a
   stop with `requestStop`, which waits for nothing, so a stop never waits beside the driver. The admissions of tasks that are in flight are waited for next, and the tasks the
   session admitted are read: the faults of those that have settled are told, though each was told when it happened
   by the task's own watcher, so a task a tick resumed that faulted in it is told here, whatever its watcher and the
   ticket's observation have done, and its failure is that tick's and never the next's (the accounting wait does not
   consume a task's result; the sample does). **Attribution (D-48).** Tick T's failures are those of its own work
   (a segment, or a task resumption of its grants) and every ending begun by the end of the final boundary the
   accounting covered; each is recorded before the wait returns, and none ever lets T commit, on every ordering. A
   failure that begins after that cutoff (an independently running instance, a task running outside T's grants, an
   admission that completes late) belongs to the first tick not yet committed when it is recorded: told before T's
   commit step it stops T; told after it T commits and stays the last good snapshot, and the session fails at T+1,
   with no further grant and T+1's batch discarded. Either outcome is correct.
5. **Decide.** A failure told of fails the session and commits nothing; a stop commits nothing; otherwise the
   tick commits only if its work **finished successfully**: gameplay called `staging.finish()` and the instance
   is active with nothing in flight and no update owed, or the engine says why there is no work (the behavior
   is paused, was paused when the tick began, or a control was applied at the tick's boundary). Anything else
   raises `TickNotCompleted`, commits nothing and halts the session. Tick completion alone never authorizes a
   commit.
6. **The commit step**, one transaction: it first checks that no failure is recorded (one that is stops the tick, and
   is published instead), and then replaces the committed world, publishes the snapshot (its status taken from the engine's
   inspection of the behavior, `Paused` or `Running`), settle the tick's reservations in the queue and count
   its dispositions. A reader sees the whole tick or none of it.

Gameplay reads the world through `world`, stages moves through `staging.move` into a batch bounded by
`boundStaging` (a move past it, of no entity or over the delta bound is answered `false`, a recoverable
answer), and says it is done through `staging.finish()`. Staging changes nothing: the batch is not visible
to gameplay's own reads, nor to anything else, and it is applied by the commit, in the order it was staged.

A tick that is held inside a segment (an example's barrier) has not got past step 3: it publishes
nothing, so the snapshot always shows the last completed tick, and real delays change when a commit
happens and never what it contains.

A **snapshot** (`GameSnapshot`) carries the session's identity, the completed tick, the whole world, the
tick's dispositions, the gameplay behavior's engine identity (which the UI addresses its controls to) and a
session status: `Running`, `Paused` (the behavior is paused; ticks and accepted intentions go on), `Failed`
with its evidence, or `Stopped`. Its revision advances by exactly one per committed tick, and by one for the
session's ending (a failure or a stop), which is published once.

## Intentions

A UI intention is *move an entity by a delta*, carrying the session it acts in, the committed tick of the
view it acted on, the entity, and the entity's version in that view. The UI script calls
`intent.submit(session, tick, entity, version, dx, dy)`, which answers `true, nil` or `false, reason`,
**never blocking and never waiting for gameplay**:

| Answer | Meaning |
| --- | --- |
| `true, nil` | the queue has taken the intention for the next tick that has not started |
| `false, "full"` | the queue's bound or that tick's places are all taken |
| `false, "closed"` | no tick that has not started is left to take it: the finite session's last tick has begun, or the session is retiring |
| `false, "malformed"` | a wrong number of arguments, or a value that is not an integer; answered by the facade |
| `false, "session"`, `"tick"`, `"entity"`, `"version"`, `"delta"` | a value outside the application's bounds; answered by the typed binding |

The reasons are fixed words, never text the script wrote, and at most 256 bytes.

**The facade.** The typed binding checks its six integers against a schema, and a call with the wrong arity
or a value of the wrong type is a fault of the call that Lua's `pcall` cannot turn into an answer: it
fails the instance. The recoverable answers are therefore given before the typed binding is reached, by
the UI's initial chunk (`src/lua/ui_facade.lua`), which checks the arity and that every value is an
integer, and removes the raw namespace from the globals. Over-bound values reach the binding as
integers, and the binding answers them as data.

**Bounds.** `boundQueue` (twelve by default) counts accepted intentions not yet *settled*: from
acceptance until the commit of the tick they were accepted for. `boundPlaces` (eight) is how many
intentions one tick holds. `boundDelta` (eight) bounds each component of a move.

**Tick assignment cannot race the tick.** The admission seam takes the tick and the place within it
explicitly (`admitAt`), so a later slice can feed it an input log whose places were assigned beforehand:
a tick that has begun answers *late*, an occupied place *duplicate*, and neither is ever applied at a later
boundary. The UI's path (`admitNext`) reads the next unstarted tick and takes the next free place in it in
one transaction. A tick begins when the driver seals it, in a transaction on the same variable that
advances the next unstarted tick, so an admission either precedes the seal (and is in the sealed batch) or
reads the advanced tick: an accepted intention is never for a tick that has begun, and the UI's path has no
late answer.

**Exactly once, with revalidation.** Every accepted intention gets exactly one terminal disposition: applied
at its tick, or rejected as stale at its tick. It is stale when the world's session is not the one it acted
in or when the entity's version in the candidate no longer equals the version it carried. Revalidation is
sequential: a tick's intentions are applied in the order of their places against a candidate the earlier
ones have already moved, so two intentions for one entity with one version apply the first and reject the
second. Stale rejections appear in the snapshot of the tick that rejected them, at most `boundStaleListed`
(four) of them, with a count of any that did not fit; the applied places are listed too. The counters, by
answer and by disposition, satisfy *accepted = applied + stale* once nothing is pending.

**A finite session conserves its intentions.** A queue made for a session of N ticks answers `closed` for
every tick beyond N, which is every UI-path admission once tick N has been sealed. Everything accepted
before that is for a tick up to N and is settled by that tick's commit. `runSession` retires the owners,
the UI first, before it reads the counters, so no producer of the UI's is left, and raises
`ConservationViolated` if anything is pending or the law does not hold.

## A failed session

Any failure of script execution on the gameplay owner fails the session: an `init`, `update`, `run` or
`shutdown` that raises, a callback that raises, a delivery the instance cannot be handed, a wait the
scheduler refuses, and the fault of a task the session admitted. The first failure is the session's
(*primary*); later ones are *evidence* (`maxSecondaryKept`, four, are kept and the rest only counted).
Application code that fails, a binding that raises for instance, is not a script failure: it is an owner
failure, which supervision reports as it always does, and the snapshot does not say `Failed` for it.

What the session does, by design (D-26, D-27, P-7):

* the instance's escalation callback records the failure in the session state and answers `Isolate`, so the
  engine keeps the owner and its VM alive, running nothing. It records the primary and, beside it, what else
  failed while the instance ended (a `shutdown` that raised after an `update` did): each of those is counted and
  kept as evidence and never replaces the primary. A failed *release* is cleanup evidence, fatal under supervision,
  and is neither;
* **admission closes in the same transaction that records the failure**, so no intention is accepted for a tick
  that will never run after the failure, whenever the driver gets to publish it;
* from the moment the driver knows of a failure it grants nothing more and commits nothing: **the driver learns
  of a failure in tick T before it decides T's commit**, on every ordering, which is what the accounting wait of
  step 4 enforces (a failure in the last segment, in the only segment, two failures, a wait the scheduler refused
  in the final segment with a held `shutdown`, and a failure whose escalation is still pending after the grant
  completed are covered by examples that force each ordering with gates);
* the driver publishes **one** snapshot for the failure. The publication is *taken* first: from that moment it is
  the publisher's alone, and a stop, a second failure or a retirement that arrives meanwhile waits for it, so the
  publisher is never closed under it: the last good world and committed tick, status
  `Failed` with the primary failure (who, which stage, which tick, which kind, a bounded message), the number
  of failures told of by then, and the **invalidated** intentions;
* the session **takes no task from the moment it fails or is stopping** (`admitGameplayTask` answers
  `TaskAdmissionClosed`, and nothing reaches the owner or runs), in the transaction that records the failure or
  the stop; an admission that began before is finished, and its task watched, before the stop settles anything and
  before the ending is published (both wait for it);
* the session **holds at most `boundSessionTasks`, three by default (at most sixteen), tasks it has not been told the
  settlement of**: a task holds its slot and result reservation until its settlement is observed, and each task's
  watcher observes it as soon as there is one, so a fourth is refused (`TaskQueueFull`) while three are running or
  suspended, and a tick or a stop never waits for a slot nobody will free. A live instance's invocation takes an
  active slot of the same pool, so the gameplay owner's scheduling is *made from* that bound and from the instances
  the owner may hold live (one active slot for each, and queued admissions and retained results twice that): an
  update has a slot whichever tasks are suspended and whichever instances are suspended, in every supported
  configuration (examples at one, three and sixteen tasks);
* the settlements of the tasks the session watches are **told once**: the task's watcher, the driver (before it
  decides a tick) and the stop each learn a settlement, and learning it is one transaction that takes the task off the
  registry and records its fault as a session failure, so a fault is recorded once, never twice, and a thread that is
  interrupted tells nothing half;
* a failure **asks everything the session holds to stop as soon as it is told**, from the owner's thread (an
  instance's escalation) or the task's watcher, without waiting: every gameplay instance and every task is claimed and
  asked in one step, so a tick that a surviving instance, or a task that has woken on it and stays ready, would keep
  outstanding can complete, and the driver reaches the failure's publication; a stop asks the same before it waits for
  anything;
* the session is **quiescent when its failure is published**: every gameplay instance has been asked to stop, through
  the engine's instance controls (see above), and the driver waits for each to settle (the one that failed has ended; a
  surviving instance, one with work still to run included, runs its `shutdown` and its leases are released), waits
  for the owner's accounting of those endings, and settles what the session admitted (a task that has no
  settlement, one that goes on running after it yields included, is asked to stop and waited for), with the owner
  left alive. Nothing the session admitted and no instance runs after the failure's snapshot; a failure such an
  instance or task raises first (a `shutdown` that raises, say) is counted in the failure's evidence;
* a stop **settles every task the session admitted** before it decides its status: a task with no settlement is
  asked to stop, its settlement is waited for, and a fault it raised first fails the session (a task a stop
  cancels has none to tell); a fault told of after the failure was published is counted in the final report;
* a stop **asks each gameplay instance to stop once, whoever asks and whoever is interrupted**: what was asked is
  tracked (not who asked first), and the requests are issued before the stop waits for anything, so a stop
  that is cancelled while it waits has asked already, and the next one completes (the request and the record of it
  are not separated by anything that waits, and a stop cancelled between recording its intent and asking the first
  instance leaves the next one to ask);
* **an accepted task is tracked from the moment the owner accepts it**: the admission hands the task to the
  session's tracking in one transaction that waits for nothing, so cancelling the admitting thread at any point
  leaves it tracked and counted, its fault told once, and its reservation given back when it is observed; a task the
  owner had not accepted is never counted;
* **the final publication is the next caller's if its first caller is cancelled**: before the ending is claimed
  nothing was taken, and after it was claimed the session is marked ended however the publisher ends, so no later
  caller waits for ever;
* a failure that is told of later (a teardown, a `shutdown` that raises when the session is stopped) is
  counted in the evidence the report and `cleanupEvidence` give; it is never published, and the snapshot is
  not republished.

A failed `init` of the behavior is the same failure, the failure of the first tick not yet committed (tick one): the initial world and committed tick zero are published with it. In general **the failing tick is the last good tick plus one**: a tick's own failure is that tick, and a failure told while no tick is in progress is the next one's.

**The commit condition.** Whether a tick that ran no work may commit is decided from evidence the application
holds, not from the engine's counters: every gameplay module's `update` is wrapped (`gameplay_update.lua`) so that
`staging.began()` says, before the script's own code runs, that the update began in this tick. An update that began
must have called `staging.finish()` to commit. A tick whose update never began commits only if the engine says
why: the behavior is paused, was paused as the tick began (this is the tick that resumes it), or a control was
applied at its boundary. A control is not proof that the update did not run: a request for the state it is
already in changes nothing, and the update runs and must finish.

## The ledger on every path

Every accepted intention reaches exactly one terminal disposition, and none is applied twice or retried:

| Disposition | When |
| --- | --- |
| applied, rejected as stale | the tick it was accepted for committed (these stand, whatever happens later) |
| **invalidated** | a failure ended the session before the tick the intention was for committed: those of the failing tick, those accepted for ticks that never began (listed in the failure snapshot, at most `boundDroppedListed`, eight, with a count of any not listed) |
| **discarded** | a stop (or retirement) ended the session before its tick committed (listed in the stopped snapshot the same way) |

Staged is not committed: what a failed tick staged or applied into its candidate is thrown away with it and
the intentions are invalidated, never counted as applied. After a quiescent run
`accepted = applied + stale + invalidated + discarded` with nothing reserved, and `runSession` raises
`ConservationViolated` if it does not hold. Admission answers `closed` from the moment a failure, a stop or a
retirement begins.

## Overload

The answers to an intention are counted by kind, and `full` by cause (the queue's bound, or the places of the
tick): `accepted + full + closed + refused + malformed` is the number of offers made, and the UI never blocks
on any of them. The flood scenario and the examples with several producer threads show it; a UI that is
answered `full` shows a busy indication and offers the intention again at most three times.

## Stopping, cancellation and the cleanup evidence

`stopSession` is the one stop of the session, on the application thread (the one that created the session, whose
supervision handle the waits below are; another thread's call is refused with `StopOffApplicationThread`, and that
thread asks with `requestStop`), and it can be called again (it then only
reports how the owners ended). It:

1. closes admission and grants at once, so nothing is accepted for a tick that will never run;
2. asks the gameplay instances (the behavior and any others) and every task to stop, without waiting, and then waits
   for each instance to be **settled**,
   which includes its `shutdown` hook and the release of every lease it held, so a segment that is running is
   not preempted and the stop waits for it to return;
3. waits for the owner's accounting (`awaitScheduledAccounting`), and learns through it whether that settlement
   was a failure (the escalation of a `shutdown` that raised has returned before the outcome is decided);
4. publishes one last snapshot: `Stopped` with the intentions the stop discarded; or, if `shutdown` raised
   and nothing failed before, the failure (the world is the last committed one: frozen); a session that had
   already failed keeps the failure as its status, and nothing is published for the stop;
5. lets the UI owner read the receipts of the controls it asked for and, as the executable is configured
   (`configUiSeesEnd`), see the status that ends the session, both while the UI serves; then closes the
   publication and retires both owners, the UI first. The UI therefore notes `failed` (or `stopped`) with the last
   good tick, and the report says so.

A stop asked for from another thread (`requestStop`: it records the intent, closes admission and asks every instance
and task to stop, and waits for nothing) while a tick is in flight halts that tick (`TickHalted`): the tick commits
nothing, and the driver is told so, not left with a defect; the application thread then finalizes the stop with
`stopSession`, as `runSession` does when a tick is halted.

**A finite session that ran its last tick** settles the same way before its publication closes (it asks the
gameplay instances to stop and waits for their `shutdown` and lease release, then for the owner's accounting): a `shutdown` that
raises is a session failure and is published, after the last tick, with the world frozen at it, and the status and
the exit status say so. When nothing failed, nothing more is published: the last tick's snapshot stands.

**Cancellation** of the enclosing scope retires both owners by cancelling them, not by stopping them: each exits
cancelled and its instance settles as discarded; what is not settled is discarded, and nothing hangs. The library
records an owner's exit as cancelled when the cancellation reaches it before its orderly stop check (a cancel request
is also a stop request, and the cancellation is raised in the owner's thread a moment later), so the example that
asserts `ExitCancelled` holds each owner's thread in Haskell, in the observer that runs before every segment, where
the cancellation can reach it and nothing else opens it (a barrier inside a Lua callback would leave the order to the
scheduler); the example that holds a Lua segment keeps the actual exit records and accepts either kind. Both check
that the workers ended, the publication closed, nothing is pending and the workspaces released.

**Evidence.** For every way a session can end, `cleanupEvidence` (and the last lines of the report) gives
one bounded record: both owners' exit records and statuses, each instance's termination (what it revoked
and discarded, what became of `shutdown`, the leases drained and failed), the workspaces acquired against
released and release-failed, whether the publication ended, the ledger and what was left pending, the UI's
control counts, and the failures told of after the failure snapshot (bounded). A teardown failure after the
snapshot goes there and is never republished.

## Leases: the gameplay workspace

Each gameplay instance's `init` opens a **workspace** through the engine's leases (capacity `boundWorkspaces`,
two); the script keeps the handle in `self` and never releases it. The engine releases whatever an instance
acquired when the instance ends, however the script behaves: a failed `init` after acquiring, a handle the
script overwrote or never stored, an absent or a raising `shutdown`, a stop, the owner's retirement. A third
open beyond the capacity is refused by the engine and faults the invocation (a session failure). The tally
distinguishes *released* from *release failed*; a release that itself fails is cleanup evidence that ends the
owner fatally and terminates its worker (the engine's rule), is reported in the evidence, and is not a
recoverable session failure: nothing in the sample catches it as one.

## Controls: pause and resume

The UI owner may ask the gameplay owner to **pause** or **resume** the gameplay behavior (the engine's
lifecycle controls, granted for control and inspection of that one endpoint). The application assigns each request
the next tick that has not begun and a place in it (`assignControl`), the engine applies it at that tick's
boundary, and the UI is answered with the engine's own reasons:

* a request is *accepted* (for that tick) or refused at once (`unassigned` when the session has failed, is
  stopping or is closed, or is finite and its last tick has begun (the next tick that has not begun is beyond the
  session), or the UI already holds `boundPendingControls`, four, unread receipts;
  `unknown_target` before gameplay's identity is known). The engine holds a reservation for each accepted
  control until its receipt is read; the owner has the pending bound's worth and one more for each instance
  the stop must reach, so the stop is admitted whatever the UI holds;
* an accepted request settles *applied*, *already in that state* (a pause of a paused behavior: both are
  accepted, in order, in one tick), or *no longer applicable* (the instance ended, or the session did, before
  its tick);
* the UI reads the settlement through a receipt (`control.settle()`); the receipts it still holds when it
  ends are *abandoned*, reported apart and never given a result; an abandoned control is not cancelled, an
  accepted control still applies; an orderly stop settles the pending gameplay controls, and waits for the UI to
  read them while the UI serves.

Pause stops the gameplay behavior's `update` and nothing else: **ticks go on being granted and committed,
intentions accepted are applied while paused**, and the committed snapshots say `Paused`. The tick that
resumes it runs no update; the first update is a full interval later. Control counts satisfy
`offered = accepted + refused` and, once quiescent, `accepted = applied + already + no longer applicable +
abandoned`.

**Serialization with the tick.** The assignment and the engine's admission are two steps, and a tick that
began between them would find the control late. The UI facade brackets each lifecycle call with an in-flight
count (`control_raw.begin`/`finish`); the driver's begin transaction waits on it, unless the UI that made the
request has ended. The UI is never made to wait for the driver, and never late. An example holds the interval open
with a test seam and shows that a tick attempted in it does not begin and that the control applies in the tick it
was assigned.

## A failure of the UI behavior

A failure of the UI owner's behavior is isolated: it is recorded once (bounded), the UI instance ends and is
not restarted, and nothing else changes: gameplay is not told and keeps ticking (its worlds are the same as for a
UI that offered nothing), intentions already accepted are still applied, the UI offers nothing more, its held
receipts are abandoned, and the report and the exit status say the UI failed.

## The UI's view

The UI owner captures the latest committed snapshot at the start of each of its segments, in
`scheduledObserve`, and every `view` query made in that segment answers from that one capture, whatever
gameplay publishes meanwhile; the next segment may see a newer one. The UI script reads the fake input
source through `input.poll()` and turns each entry into an intention from its current view.

## Progress proofs

UI progress is proven twice, with no host instruction hook (the host offers no `debug.sethook`):

* **Barrier (deterministic).** A test binding (`fx.hold`, in test code only) holds a gameplay segment
  inside a running segment while the UI owner completes a fixed number of updates, each made due by hand
  (the injected clock advanced, the fake timer's live registration fired) and awaited through its own
  completion signal. The snapshot still shows the last completed tick, and the tick commits when gameplay is
  released.
* **CPU-bound.** A pure-Lua finite computation with no binding call and no yield inside its loop runs as
  gameplay's update while the UI owner runs on the real clock and timer at its two-millisecond interval.
  The check is an ordering: the UI's completed-update count taken when the computation starts
  (`fx.mark`, outside the loop) and again when it ends differ by at least five, so updates before the
  computation or after it cannot satisfy it. The loop is sized by the example from a measurement of how fast
  the machine runs it, to last at least ten times what the required updates take, and the example prints the
  runtime options in force. It needs the threaded runtime with at least two capabilities, as the executable
  and the suite are built (`-threaded -with-rtsopts=-N2`); the only waits are deadlock guards.

## Randomness

Gameplay's randomness is an application-owned stream, seeded per session with the seed the configuration
supplies (`--seed`). The algorithm is SplitMix64, fixed and documented in `World.hs` so that its output
cannot change with a library version; a draw from `[0, n)` is the output modulo `n` for `n` from one to 2³¹,
and `rand.below` answers `-1`, drawing nothing, for any other bound. The stream's state is part of the
committed world and advances only in the tick's candidate. `math.random` and `math.randomseed` are removed
from the gameplay VM by an initial chunk (`src/lua/gameplay_init.lua`), because the standard `math` library
is opened whole; the UI VM keeps `math.random`, and drawing from it touches nothing of gameplay's. The
gameplay behavior draws three values in every tick.

With the same seed, the same initial state and the same tick-assigned intentions, the committed worlds are
the same; a different seed gives a different sequence. The examples compare them with a pure model of the
behavior. They hold the inputs fixed (no intentions at all) rather than claim equal worlds for a UI whose
intentions are assigned to ticks by elapsed time.

## The executable

```
hetoimasia-lua-domains [--ticks N] [--seed N] [--scenario NAME]
hetoimasia-lua-domains --help
```

It runs both owners against a fixed scripted fake input source (forty entries, the same on every run, or two
hundred for `flood`), commits N ticks (1 to 100000, twenty by default; `--seed` defaults to 1), retires both
owners and prints one bounded report on stdout.

| Scenario | What it does | Exit |
| --- | --- | --- |
| `normal` (default) | the fixed input and nothing else | 0 |
| `pause` | the UI pauses gameplay once its view shows tick 4 and resumes it at tick 9 | 0 |
| `failure` | gameplay's behavior raises at tick 6: the session fails there, with tick 5's world | **1** |
| `flood` | the UI offers two hundred intentions, sixteen an update: many are answered `full` | 0 |
| `stop` | the driver stops the session after tick 8 | 0 |

The exit status is **0** when the session ended without a failure (a stop is not one), **1** when the gameplay
session failed or a UI failure was recorded, and **2** for an unknown, repeated or malformed argument (one bounded line
on stderr, the user's text escaped and cut, and no report). `--help` prints the usage and exits 0. The report is
ten lines:

```
hetoimasia-lua-domains: session 1, seed 1, scenario failure
ticks committed: 5
status: failed at tick 6: gameplay active update, script error: gameplay@1:33: scripted failure at tick 6, later failures 0
intentions answered: accepted 40, full 16 (queue 0, places 16), closed 0, refused 0, malformed 0
intentions settled: applied 24, stale 4, invalidated 12, discarded 0
controls: offered 0, accepted 0, refused 0, applied 0, already 0, no longer applicable 0, abandoned 0
ui: updates 15, busy 16, retried 14, saw running,failed, no failure
cleanup: ui ended (status stopped, exit ExitStopped, not started 0, in flight 0); gameplay ended (status stopped, exit ExitStopped, not started 0, in flight 0)
cleanup: gameplay failed [shutdown ShutdownAbsent, leases drained 1 failed 0]; interface stopped [shutdown ShutdownAbsent, leases drained 0 failed 0]
cleanup: workspaces acquired 1, released 1, release failed 0; publication closed; pending 0; failures told of 1, after publication 0
```

The counts vary from run to run, because the UI runs on elapsed time and so decides which tick takes an
intention; the laws do not: *accepted = applied + stale + invalidated + discarded* and *pending 0*. Diagnostics go to stderr and no
window is created. Between ticks the executable waits five milliseconds of real time so the UI owner has
something to do; that pacing changes when a commit happens and never what it contains.

## Tests

`lua-domains-tests` is package-owned Hspec with real interpreters under real supervision, with no
timing sleeps for concurrency correctness: explicit gates, STM waits and bounded waits through
`hetoimasia-test-support`. It covers, by requirement: the package and import boundary read from the Cabal
description and the imports; both owners' exit records and nothing left live, on a clean run, when the body
fails, when the driver is cancelled in the middle of a held tick, and when a gameplay binding fails; exposure
per owner, module state per VM and no handle into the other VM; a staged batch invisible until the commit, one
snapshot per completed tick and none for a held tick or one whose work did not finish; the answers to valid,
full, malformed and over-bound intentions with a held gameplay tick; admissions raced against the grants;
conservation on every path (`Ledger`); the coherent view; both progress proofs; the random stream; the
failure of the gameplay session, with each failure timing forced by gates (`Failure`); events a provider
delivers and what a delivery failure does (`Delivery`); the stop paths and the cleanup evidence (`Stop`); the
workspace leases on every path an instance can end by, with a test-only workspace whose release fails
(`Leases`); the UI's failure (`UiFailure`); pause, resume and the serialization of controls with the tick
(`Controls`); and the executable's report, scenarios, `--help` and exit statuses. The executable is reached through the suite's
`build-tool-depends` and run as a child process, and no validation group launches it any other way.
