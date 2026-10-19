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

This slice is the two-domain core. A failed gameplay session, intention overload beyond the `full`
answer, the stop and cancellation paths with cleanup evidence on every path, and determinism
qualification are later slices; nothing below claims them.

## Reproduce

```sh
cabal run exe:hetoimasia-lua-domains -- --ticks 20 --seed 1
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

Grants start only after the owners' behaviors are active (`init` has run).

## Registration and exposure

One `Registration` defines every binding once. A namespace outside an owner's policy is absent from
its VM's globals, and the production registration contains exactly these (a test that needs a binding
of its own adds it through `DomainsConfig.configExtensions`, which the production configuration leaves
empty).

| Namespace | Exposed to | Bindings |
| --- | --- | --- |
| `view` | UI | `tick()`, `session()`, `count()`, `entity(i)`: snapshot queries answering from the segment's one capture |
| `intent_raw` | UI | `submit(...)`, the typed intention binding, and `malformed()`; the UI's initial chunk reads both and removes the namespace |
| `input` | UI | `poll()`: the next entry of the fixed fake input source |
| `ui` | UI | `updated()`: one update completed |
| `world` | gameplay | `tick()`, `session()`, `count()`, `entity(i)` over the tick's candidate |
| `staging` | gameplay | `move(i, dx, dy)` into the bounded batch, `finish()` |
| `rand` | gameplay | `below(n)`: a draw from the application-owned stream |

No binding takes or returns a capability and the registration declares no capability type, so nothing
one VM holds names anything in the other; module state, including a global or an upvalue, is per VM.

## The world and one tick

The world is deliberately small: at most 64 entities (eight by default), each with an integer position
and a version that changes if and only if its position does, the committed tick, the session's identity
and the random stream's state. Positions are clamped to ±10⁹.

The driver's `stepTick`:

1. In one transaction, **seal** the next unstarted tick of the queue and make the tick's
   **candidate**: the committed world with the tick's intentions revalidated against it, in the order of
   their places, and applied (below). The tick's random stream starts at the committed state.
2. **Grant** gameplay one logical step of the configured duration (ten milliseconds). One grant is
   outstanding at a time.
3. Wait for the owner to complete the tick (`awaitTicksComplete`).
4. Check that the work **finished successfully**. A completed tick says only that the grant was applied
   and nothing is left it could run; a task that waits, fails, pauses or stops completes its tick too. The
   tick commits only if gameplay called `staging.finish()` and the instance is still active with nothing in
   flight and no update owed. Otherwise nothing is committed and `TickNotCompleted` is raised, and the
   session is halted: a later `stepTick` raises `TickAlreadyInProgress`.
5. In one transaction, replace the committed world, publish the snapshot, settle the tick's
   reservations in the queue and count its dispositions. A reader sees the whole tick or none of it.

Gameplay reads the world through `world`, stages moves through `staging.move` into a batch bounded by
`boundStaging` (a move past it, of no entity or over the delta bound is answered `false`, a recoverable
answer), and says it is done through `staging.finish()`. Staging changes nothing: the batch is not visible
to gameplay's own reads, nor to anything else, and it is applied by the commit, in the order it was staged.

A tick that is held inside a segment (an example's barrier) has not got past step 3: it publishes
nothing, so the snapshot always shows the last completed tick, and real delays change when a commit
happens and never what it contains.

A **snapshot** (`GameSnapshot`) carries the session's identity, the completed tick, the whole world, the
tick's dispositions and a session status. The status type admits a failed session, which a later slice
sets; in this slice only `Running` is reachable. Its revision advances by exactly one per committed tick.

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
hetoimasia-lua-domains [--ticks N] [--seed N]
hetoimasia-lua-domains --help
```

It runs both owners against the fixed scripted fake input source (forty entries, the same on every run;
the UI script polls it through a UI-owned binding), commits N ticks (1 to 100000, twenty by default;
`--seed` defaults to 1), retires both owners and exits **0** after one bounded report on stdout:

```
hetoimasia-lua-domains: session 1, seed 1
ticks committed: 20
intentions answered: accepted 32, full 8, closed 0, refused 0, malformed 0
intentions settled: applied 24, stale 8
ui updates: 56
intentions pending: 0
```

The counts vary from run to run, because the UI runs on elapsed time and so decides which tick takes an
intention; *accepted = applied + stale* and *pending 0* do not. `--help` prints the usage and exits 0. Any
unknown, repeated or malformed argument, or a missing value, prints one bounded line on stderr (the user's
text escaped and cut) and exits **2**. Diagnostics go to stderr and no window is created. Between ticks the
executable waits five milliseconds of real time so the UI owner has something to do; that pacing changes
when a commit happens and never what it contains.

## Tests

`lua-domains-tests` is package-owned Hspec with real interpreters under real supervision, with no
timing sleeps for concurrency correctness: explicit gates, STM waits and bounded waits through
`hetoimasia-test-support`. It covers, by requirement: the package and import boundary read from the Cabal
description and the imports; both owners' exit records and nothing left live, on a clean run, when the body
fails, when the driver is cancelled in the middle of a held tick, and when a gameplay binding fails;
exposure per owner, module state per VM and no handle into the other VM; a staged batch invisible until the
commit, one snapshot per completed tick and none for a held tick or one whose work did not finish; the
answers to valid, full, malformed and over-bound intentions with a held gameplay tick; admissions raced
against the grants; conservation, including a finite session's final grant racing admissions; the coherent
view; both progress proofs; the random stream; and the executable's report, `--help` and exit status 2. The
executable is reached through the suite's `build-tool-depends` and run as a child process, and no
validation group launches it any other way.
