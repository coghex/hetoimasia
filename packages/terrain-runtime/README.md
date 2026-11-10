# hetoimasia-terrain-runtime

The scoped, transactional terrain service (TRA-4 of epic #636). It executes the
pure residency model of [`hetoimasia-terrain`](../terrain/README.md#residency-and-admission)
against real owned data: one dedicated owner thread, bounded asynchronous loading
and eviction, atomic whole-cell removal that commits together with its successful
settlement, immutable borrowed snapshots, offload and reload from the immutable
source plus canonical retained removals, and an orderly close.

It depends on `hetoimasia-terrain`, `hetoimasia-foundation` and
`hetoimasia-runtime`. It has no Lua, GLFW, graphics, native or game dependency,
no global registry and no universal environment: everything it borrows is
injected through `Ports` (the parent session's admission, a supervision
capability, a logger and a diagnostics seam). The Lua request endpoint is TRA-5;
this package supplies a Lua-independent settlement seam it can attach to.

This is the **baseline** service of design P-16: it retains edits in RAM only. The
temporary store of TRA-20–TRA-23 replaces that retention later. Its pure model
(TRA-20) lives beside the service in this package and is described in
[the temporary store](#the-temporary-store-tra-20); nothing in the service uses it
until the terrain owner adopts it (TRA-22), so the service's behavior, admission
outcomes and tests are unchanged.

## Using it

```haskell
withWorkerGroup $ \group →
  withTerrainService defaultConfig (Ports alwaysAdmitting (standaloneSupervisor group) logger noProbe) $ \svc → do
    Right client ← registerClient svc
    Right opened ← openArena svc client "main" definition   -- a SourceSpec
    Right lease  ← await svc opened                          -- the creator's owner lease
    Right read   ← cellAt svc lease tile
    Right answer ← await svc read                            -- air, or a material and shape, with revision
    Right edit   ← removeAt svc lease tile Nothing
    Right done   ← await svc edit                            -- RemoveAnswer: changed flag, committed revision
```

An application supplies `supervisedOwner runtimeControl` (module
`Hetoimasia.Terrain.Runtime.Supervised`) in place of `standaloneSupervisor`, so the
owner is a required service of its supervised group. The control stays on the
application thread: the owner worker captures the service and nothing else.

Admission never blocks. A request is admitted and returns a handle, or it is refused
with a reason (`Refused`): `RefusedBusy` (temporary pressure: a bank or slot is
full, the retained edits are full, four arenas, 64 leases or eight views are in
use), `RefusedAuthority` (forged, foreign, released or wrong-service authority),
`RefusedInvalid` (a request that can never succeed), `RefusedExhausted` (an
identity would wrap) or `RefusedClosed` (the service or its parent session is
closed). A refusal creates no request, no work and no reservation. An outcome
already known at admission (a duplicate name, a closed arena, an invalid
definition) is admitted as a request that is settled at once.

## The settlement seam

`Hetoimasia.Terrain.Runtime.Settlement` is the narrow, Lua-independent seam TRA-5
attaches its request endpoint to. A host supplies an `Endpoint` per request:

| Operation | Meaning | When the service calls it |
| --- | --- | --- |
| `endpointReady` | Work is staged and could be committed | In the transaction that publishes the staged work |
| `endpointEligible` | The host's grant to commit | Read in the arbitration, on every attempt |
| `endpointSettle` | The terminal outcome | Inside the one transaction that decides the race |

These are distinct: a provider-ready notification is not an eligibility grant, and
neither is a settlement. There is **one** winner. The success settlement is
delivered in the same transaction that applies the content change and advances the
revision, and that same transaction is the only place cancellation, the parent
session's admission and the arena's closure are decided against it. Do not run an
ordinary IO completion after a commit and call that atomic. A callback that throws
is a provider defect: the transaction is abandoned with nothing committed, the
request ends without a second call into the host, and the defect reaches
supervision (the owner ends).

### Three read-only reads for a host's composition and precheck, and two transactional forms

The two queries are transactions and the third is a pure read; none writes anything or changes any behaviour of the service. They were added for
TRA-5 (#641) at the manager's authorization under the owner's 2026-11-09 decision, and the owner's later decision for `inspectConfig`.

* `stagedRemovalChanges service request` answers whether the removal the request has **staged** would change content: `Just True` for a
  removal that will advance the arena's revision by one, `Just False` for a removal of air, which commits as unchanged at the revision
  it finds, and `Nothing` for any request that has staged no removal (a read, an open or an attach, one not yet staged, one settled, or
  another service's). A host's eligibility callback uses it to decide, before the commit, whether a removal needs a revision the host
  cannot publish, so that a no-op removal at that revision succeeds without a defect.
* `serviceAdmitting service` answers whether the service is running and its parent session open. A host asks it where a permanent
  refusal is decided, before it reserves anything of its own. It is a precheck only: every admission asks the same question again,
  atomically with its own effect (`RefusedClosed`), so a service that closes between the host's check and the hand-off still refuses it
  and leaves nothing behind. `Closure` examples cover running, the session's end, closing and closed, and the closure between check and
  admission.
* `inspectConfig service` answers the `Config` the service was built with: a pure read of its own immutable field, no transaction, no state. A
  host that composes over a service asks it, instead of being handed a configuration that might differ from the one the service enforces
  (the Lua adapter reads every limit it applies from it, and refuses a service configured above the caps Lua is promised). A terrain-runtime
  example reports the limits a service was built with whatever configuration a caller holds.
* `retireSTM service request` and `releaseArenaLeaseSTM service lease` are `retire` and `releaseLease` as transactions (`Settlement`): the same functions, writing the same
  state, for a host that gives a result or a lease back from inside a transaction of its own. The Lua host gives a request's credit back in the
  transaction that takes the result or accounts its work, on whichever thread does, so it retires the result in that transaction instead of
  queueing it for a later call; a `terrain-runtime` example shows both forms.

## State, owner, thread and lifetime

All mutable state is one record behind one `TVar`. Admission, cancellation, release
and closure run as transactions on the caller's thread and write only
**bookkeeping**: the request table, leases, names, views and the accounting model.
The owner thread is the **sole writer of arena contents**: the resident detail, the
palette, the retained changes, the content revision and the residency generation.
Snapshots are the only way another thread reads contents, and they are immutable
values.

| State | Owner and writers | Readers | Thread | Bound | Commit point and retirement |
| --- | --- | --- | --- | --- | --- |
| Arena contents: resident detail, palette, retained changes (store plus working), revision, generation | The owner thread alone | Any thread through STM or a snapshot; the owner's own pure computations | The owner | Resident and edit banks (#639: 256 MiB, 64 MiB) | Content and revision change only in a commit transaction; resident detail is discarded by the owner when the model commits a victim |
| Accounting model (`Model`) | Port transactions (admission, cancel, release, close, holds, views) and the owner (job events, victims, transfers, commit) | The owner and inspection | Any, one transaction at a time | The three banks and three slots of #639 | Every credit is derived from the model's records, so none is freed twice |
| Request table (`Req`) | The port inserts; whoever finds a request in the table removes and settles it | The owner, the port | Any | 256 accepted commands (model) | Removed in the transaction that settles it; a settled read stays until its result is taken |
| Staged work (answer or prepared removal), tagged with incarnation and revision | The owner | The commit transaction | The owner | One per request | Published only if the arena still has the tagged revision; otherwise recomputed, never relabeled |
| Leases, clients, names | The port | The port, the owner | Any | 64 leases, four arenas | Released by `releaseLease`, `endClient`, arena closure or service closure; names freed at arena closure or when a pending open ends |
| View demand registrations | The port | The owner (`Service` quantum) | Any | Eight views; latest-value descriptions | Cleared by `closeView`, `endClient`, arena or service closure |
| Snapshot holds and the borrower count | The port acquires and releases | The owner (for closure) | Any | `specHoldRegions` per hold | Released on every exit of `withSnapshot`; closure waits for the count to reach zero |
| Victim queue | The port appends (from admission decisions); the owner drains | The owner | Port, owner | Bounded by the banks | Drained by the owner, which discards the detail and then reports the release |
| Defect record | Any thread that detects one | Inspection | Any | The latest 16 | Kept for the life of the service |
| Running-work record (`RunningWork`: every accepted load job as granted and as its coverage must hold it; the preparation; each handoff duplicate; each borrow's regions; each view description's regions) | The owner thread (running marks, preparation, handoffs, a job's end) and the port transactions that admit the work (a job's grant, a borrow, a view's demand), each in the transaction of the model event it mirrors | Inspection only (`inspectCensusSTM`); no production decision reads it | Owner and port | What the model bounds (jobs, holds, views) plus one preparation and one duplicate per changed region | Each entry ends with the work it describes (a job's report, the owner's safe point, a transfer's outcome, a borrow's release, a view's clearing); the owner's terminal step empties the owner's |

The owner runs bounded quanta: one dispatched load job, one staged computation or
one commit at a time. Waiting for a host's eligibility, for a load or for a caller is
a wait in the owner's selection transaction for state that changes; it never blocks
inside a quantum, so closure and other eligible work are always serviced. No Lua
callback, synchronous cross-VM call, native-window work or arbitrary client IO runs
on the owner. The owner never receives the runtime control.

## Removal, the commit point and ordering

A removal is staged, then committed:

1. **Admit** (port): validate authority, the incarnation and revision of an optional
   content precondition, and identity headroom; the model reserves the request's
   command, staging, retained-edit and resident-growth credits and its demand for
   the cell, all or nothing.
2. **Load** (owner): the model's job loads the cell's region from source plus all
   retained removals.
3. **Stage** (owner, pure): remove the whole cell (a slope included) from the
   authority and prove the cell's resident segment can be rebuilt. Nothing is
   published. The staged work carries only the content change, tagged with the
   incarnation and revision it was built for, and the host is told it is ready.
   (If that notification fails, nothing is staged: it is a provider defect.)
4. **Commit** (owner, one transaction): read the parent session's admission, the
   request's presence in the table (a cancellation removes it), the arena's
   incarnation and revision, and the host's eligibility. Re-check a supplied
   content precondition. If every check holds, rebuild the cell's resident segment
   over the residency *as it is now* (loads and evictions may have changed it while
   the commit waited for its grant, and none of that is overwritten), then apply the
   content, the revision, the retained bytes and the model's `RemovalCommitted`, delete the request, admit
   again at the new revision every other pending removal and every reader that lost
   its work to the commit, and deliver the success settlement. Any failure before
   the host callback leaves nothing written; a failing callback abandons the whole
   transaction.

Retained-edit bytes are accounted monotonically by the model: a removal that
*coalesces* two retained intervals shrinks the real changes, but the saving is not
credited (the added bytes are reported as zero), so the account stays an upper bound.

Every record the service itself holds for a request is charged **from admission** to
take, discard or cancellation, in the retained bank (160 accounted bytes each, a
one-region command record): a removal's (pending, then its settled result, a no-op's
included, until the holder takes it with `await`, or `retire` for a host) and a pending
open's or attach's. A settled result the model no longer records, and a pending open
or attach, also hold a command slot. Admission of any of them is busy once the slots
are full or the bank cannot hold one more record, and a snapshot cannot take space
promised to a pending request, nor the reverse; a read's record stays charged by the
model itself. The registered clients are bounded too (`configMaxClients`, 256).

Removing air is a no-op: `changed = false` and the unchanged revision. A removal
whose staged revision was superseded is recomputed against the current revision and
committed in order; it is not rejected. A supplied content precondition (the
incarnation plus the committed revision a displayed view was built from) that
differs from the arena's current state answers `stale_view`, even for a cell already
air, with nothing changed.

**Ordering.** Among the eligible commands of one arena the owner commits in
admission order. A command that is not yet eligible does not hold up the others; a
command that is eligible but not yet staged holds up the later ones. The same
ordered trace of eligible commands therefore yields the same terrain, results and
content revisions however loads and evictions interleave. Pending opens and
attaches order among themselves the same way. An attach is decided in its own
commit against the names that have settled, so a pending open is invisible to it.

## Offload and reload

Resident detail is a cache; the authority is the immutable source plus the retained
removals. A commit records its removed interval in the changed region's working set
and in the authority. The model keeps the region protected until a **transfer** moves
the working set into the retained store: the model reserves the temporary duplicate
in staging, the owner merges, and the outcome is reported. A failed transfer keeps
the working changes, the protection and every charge, and is not retried until the
region changes again. Because the retained bytes were funded when the removal was
admitted, a confirmed transfer needs no new edit capacity. An evicted region is
loaded again from source plus all retained removals, so identical terrain is
reconstructed across repeated cycles, buried edits, authored gaps and deep shafts
included, without materializing the cells between.

At the configured retained-edit bound a new edit answers busy (`BusyRetainedEdits`)
and creates nothing; earlier edits, reads and demand are untouched.

## Snapshots

`withSnapshot` takes a borrow (`AcquireHold`, which charges one staging record per
region and protects the regions from eviction) and builds an immutable `Snapshot`
whose resident detail is restricted to exactly the held regions. Its **backing
allocation is accounted**: each outstanding snapshot is charged the payload and
metadata bytes of its restricted detail, conservatively per snapshot, against a
retained bank (`configRetainedBytes`, 16 MiB by default) that is carved out of the
configured staging bank, which the accounting model is built without (so the two
cannot overbook the approved 128 MiB). An edit rebuilds a segment while an earlier
snapshot keeps the old one alive; a borrow that would retain a further version
beyond the bank is refused `RefusedBusy BusySnapshots`, and the charge returns when
the borrow is released. It is coherent through later edits, eviction and the
arena's closure until released, and grants no authority: it cannot make a request or
publish. Unknown detail is distinct from air (`NotHeld`, `Unloaded`, `Known`). The
borrow is released on every exit.

## Closure and shutdown

Closure order: close admission first, withdraw demand, settle or cancel pending
requests at bounded safe points, retire outstanding work, join the owner, and release
the stores only after the borrowers finish.

* The parent session's admission dominates every gate. It is read at admission and
  inside the commit arbitration; when it closes the owner closes the service and
  every accepted request ends with one terminal outcome.
* Releasing a lease cancels the requests made through it. Releasing the creator's
  final owner lease, or ending the creator, closes the arena even if attached leases
  remain: other clients' requests settle `arena_closed` and their leases answer
  `arena_closed` until released. Replacement is close plus a fresh incarnation.
* `withTerrainService` builds the service in a `withResource` scope whose release is
  non-blocking bookkeeping (close admission, settle what is pending). The drain is in
  the protected boundary around the body, outside that release: it waits for **both**
  proofs, the owner worker's own terminal acknowledgement (`OwnerControl`'s
  `awaitOwnerEnd`, so nothing of the owner, its logging included, still runs) and no
  outstanding borrower, with no deadline, detach or timeout. The owner's
  start, the body and the drain are one masked region (the start's own wait is
  interruptible, and the foundation's start drains a worker it could not
  acknowledge), so there is no window between a started owner and the drain that
  joins it. The drain survives *any* exception delivered while it waits, of whatever
  type (a cancellation can deliver any): it is remembered with its context, not
  obeyed, and delivered after the drain and the body's own failure, with its context, is the one
  that propagates. The owner's cleanup is installed before its first fallible step and, whatever
  ended the owner, retires every in-flight account at its terminal safe point:
  each cancelling load is acknowledged, each outstanding transfer is abandoned and
  each committed victim's release is finished, so no reservation outlives it (a
  hold still outstanding keeps only its own arena retiring until released).
* Reporting is tracked **per defect**: a defect the owner is about to throw is marked
  reported, and every other unreported one is attached to it, so nothing hides behind
  a later failure.
* A defect recorded where nothing could throw (a host settlement callback that
  failed inside a closing transaction) never hides: every settlement is still
  attempted, and then it reaches supervision whatever the owner ended with: as the
  owner's failure when it would have returned, or attached to its failure as cleanup
  evidence (`composeCleanup`) when it had already failed.
* **The fairness rule.** Staging, commits, retries and load dispatches take turns
  whenever two or more are ready: each ready kind gets one quantum in every four,
  whatever the others are being fed (`stateTurn` hands the next choice to the kind after
  the one that just ran). A continuous stream of new, cancelled or replaced reads cannot
  starve an eligible commit or a queued load. A retry pass is run only when it can matter
  (a registered view has pending demand, or a request waits to be admitted again); a
  freed credit alone does not make one. Within commits the per-arena admission order is
  unchanged, and the model's round-robin and aging choose among loads.
* **The retained-bank reservation.** Every request reserves one result record
  (`resultRecordBytes`) in the retained bank when it is admitted, because every request can
  come to hold a record the model does not charge (a result not yet taken, a wait to be
  admitted again). The reservation is simply kept through such a transition, so a wait
  never adds to a full bank; only a settled read, whose record the model still charges,
  holds none.
* **Readmission.** When a commit supersedes a pending request's revision it is admitted
  to the model again. Every refusal is classified: temporary pressure keeps the request
  waiting, and it stays charged (a command slot and a retained record) until it is
  readmitted or ends; a permanent refusal (its demand left the configured extent, the
  retained edits are full, its arena ended) ends it at once with a typed failure
  (`Superseded`, or `ArenaClosed`). Nothing waits on a refusal that will not clear.
* **R1: credits are released only at the owner's safe point.** A request's model record
  owns its command slot, staging, retained-edit and growth credits, and the arena's
  retirement gives back everything its requests hold. They are released through one
  function, `withdrawRecord` (and `retireArenaRecord` for an arena), and a release
  never touches credits that running work still uses. The owner runs a preparation
  (`running`, which records `stateRunning`) with the request's captured values; while it
  runs, a cancellation, lease release, client end or closure ends the request for its
  holder at once (the outcome is decided in the transaction that finds it) but the
  request becomes a ghost: the table forgets it, the model keeps its record, and
  the service keeps its reserved record, so no admission can spend them. The safe point
  (`safePointSTM`, run when the preparation ends, however it ends, and again by the
  owner's terminal step) is the only other code that issues those events: it withdraws
  the ghosts, then retires the arenas whose retirement waited. The release sites this
  replaces: `releaseReq` (every settlement: cancel, retire a result, lease release,
  client end, closure), the removal's `retainResult` at commit, `resubmitSTM`, and
  `closeArena`'s retirement. Releases that cannot overlap a preparation (victims,
  job acknowledgements, transfer outcomes, holds, camera demand) run on the owner thread
  or touch no request's credits, and are unchanged.
* **R2: a capacity refusal is never terminal.** A `Busy` refusal leaves the item pending,
  reconsidered whenever capacity is returned (`stateCapacityEpoch` advances on every event
  that can return a credit). The refusal sites: admission returns it to the caller and
  creates nothing; a read superseded by a commit and refused on readmission waits,
  charged, and the retry pass reconsiders it; a camera demand the model cannot yet
  admit stays pending in the model and the retry pass reconsiders it; and a changed
  region's transfer refused for want of staging capacity stays a candidate, suppressed
  only until the epoch moves (`stateHandoffBusy`), where it was previously marked as tried
  and never retried. Only a transfer that ran and failed is suppressed until the region
  changes again, and only refusals that can never clear (the arena is gone, the demand left
  the extent) end an item.
* **Retry memory is bounded by the regions the model holds.** What the owner remembers
  about retrying a region's transfer (tried at a generation; refused for want of capacity
  at an epoch) is written only by `rememberTried` and `rememberBusy`, and only for a region
  the model still holds in a live arena, so a transfer in flight when its arena ends leaves
  nothing behind. It is dropped only by `forgetRegionRetry` (a completed transfer, a
  released victim) and `forgetArenaRetry` (an arena's closure), and wholesale by the owner's
  terminal step; an invariant checks that no memory outlives its region, and
  `inspectRetryMemory` is zero once the regions and arenas have ended.
* **Diagnostics never decide.** A defect is thrown with a failing logger's failure attached
  as cleanup evidence, never replaced by it; a logger that fails on a routine record is
  itself recorded as a defect and the work goes on.
* Every release path steps the model through one function that says which events
  may have returned credits (`freesCapacity`); what waits for capacity (pending
  camera demand, a request waiting to be admitted again) is retried after each, so
  a release can never be a missed wake-up. The owner returns only when the service is closed, no
  borrower is outstanding, nothing is left to settle and it has been asked to stop
  (`OwnerControl`, returned by the `Supervisor`): a supervised service that returned
  on its own would be an unexpected exit, so an orderly close ends only at a stop
  request, and a parent session that closes first leaves the owner waiting for it.
* A settlement callback that fails during closure is recorded as a defect and does
  not stop the remaining requests from being settled.

## Expected failures and refusals

| Condition | Result |
| --- | --- |
| Duplicate name | `NameInUse` (settled) |
| Absent name, or a pending open, on attach | `NotFound` (settled) |
| Arena incarnation closed, through a well-formed lease | `ArenaClosed` (settled), no work admitted |
| Stale content precondition | `StaleView` (settled), nothing changed |
| Invalid source definition | `Definition` (settled), no name claimed |
| Column answer over 1,024 runs | `TooLarge` (settled), never truncated |
| Column range over 8,192 levels (refused in constant time, before any region is enumerated), a name that is empty or over 256 characters, a borrow naming more regions than a hold may, coordinates outside the extent | `RefusedInvalid` before admission |
| Forged, foreign, released or wrong-service authority | `RefusedAuthority` before admission |
| Bank, slot, arena, lease or view cap; retained edits full | `RefusedBusy`, nothing created |
| An identity or content revision that would wrap | `RefusedExhausted` before admission |
| Preparation failure (unexpected) | `HostFailure` (settled); the previous state is kept |
| Accounting defect after valid admission | `HostFailure`, a recorded `AccountingDefect`, and the owner ends |
| Provider defect: a settlement, readiness or eligibility callback that throws | A recorded `ProviderDefect`, nothing committed or staged, every request settled once, and the owner ends |

An accounting defect or a provider defect ends the owner, which surfaces through
supervision; it is never reported as busy and never as air. Diagnostics carry
bounded arena, request and revision context, never a per-cell stream.

## Bounds

The banks are those of the residency model (`defaultLimits`: 256 MiB resident,
64 MiB retained edits, 128 MiB CPU staging, 128 load jobs, 256 queued commands).
The service adds the approved caps of four arenas, 64 arena leases and eight views,
a snapshot backing bank carved from the staging bank (see Snapshots),
and uses the source (256 KiB, 8,192 authored runs) and query (1,024 runs, 8,192
levels) limits of `hetoimasia-terrain`. All are configurable through `Config`
within the model's minimum-budget rule.

### Every limit counts every state that holds the resource

A limit is checked against what is held, in every state, until the release has
actually completed (owner directive, round 10). Each service-wide limit is computed by
one function, and `inspectLimits` (the `LimitRow` list) sets each count beside an
independent enumeration of the entities holding the resource; `inspectInvariants`
requires the two to agree and the count never to exceed the limit.

| Limit | States counted | Function |
| --- | --- | --- |
| Arenas (four) | live arenas; pending opens (admitted, not settled); **retiring** arenas (closed, an outstanding snapshot or an unfinished release keeps them in the model) until the model reports their retirement complete | `arenaUse` |
| Arena leases (64) | every lease record, live or revoked, until it is released; pending opens and attaches | `leasesInUse` |
| Views (eight) | open views, until closed or their client ends | `Map.size stateViews` |
| Clients (256) | registered clients, until `endClient` | `Map.size stateClients` |
| Command slots | the model's accepted commands; untaken results; pending opens and attaches; reads and removals waiting to be admitted again; every ghost (a request withdrawn while its preparation runs) | `slotsHeldHere` with the model |
| Retained bank | outstanding snapshots' backing; one result record per request, from admission to take, including ghosts | `retainedBankUse` |
| Per-arena retained edits, resident, edit and staging banks, holds, jobs | the residency model's own accounting, whose records (live or retiring arenas, ghosts, running preparations) stay charged until released at the owner's safe point | the model's `chargeCheck` and invariants |

The enumeration reads the model's arenas, each client's lease and view sets, and the
request and ghost tables, so a state that one count forgot is a disagreement, not a
silent over-admission.

Identities (clients, leases, requests, the admission sequence, arenas, views, holds) and
content revisions are checked 64-bit counters; the residency generation saturates. The last value is never issued, and an admission that would
need it is refused before any work (`RefusedExhausted`).

## Invariants, traced from admission to release

Counts alone do not prove safe ownership. Each item below names where it is
admitted, what holds it, every way it is released and the example that exercises
that exit. `inspectInvariants` checks the structural rules after every example: the
model's own invariants and charge rules, the two-way agreement between the request
table and the model's records, lease and name consistency, no arena both live and
retiring, the borrower count against the model's holds, and every service-wide limit's
count against the entities that hold it (retiring arenas included).

| Item | Admitted by | Held in | Released by | Exercised by |
| --- | --- | --- | --- | --- |
| Reservation (command slot, record, interest, staging, retained-edit and growth credits) | `SubmitQuery` / `SubmitRemoval` in the admission transaction | The model's request record | `Withdraw` on settlement, cancellation, closure or a read being taken; `RemovalCommitted` at a commit | Races, Closure ("returns every credit"), Offload |
| Pending open (arena slot, lease slot, name claim) | `admit` | The request table and the name map | Commit (becomes an arena, a lease and a live name) or termination (cancel, client end, closure, session end) | Closure ("pending open"), Races |
| Arena and lease | The open commit | `stateArenas`, `stateLeases`, the client record | `releaseLease`, `endClient`, `closeArena`, `closeService` | Closure (names, leases and authority; limits) |
| Queued command | `admit` | `stateRequests` (Waiting, then Staged) | Settled by commit or termination in one transaction; a read stays Done until taken | Races, Closure, Lifecycle |
| Staged edit | The owner's staging transaction | The request's `Staged` phase, tagged with incarnation and revision | Commit, or recomputed when superseded, or terminated by cancellation or closure | Races, Revalidation |
| Load job | `Dispatch` | The model's job record and slot | `JobCompleted` (published or discarded), `JobFailed`, or `JobAcknowledged` after its interests are gone | Budgets ("safe point"), Closure |
| Victim | An admission's eviction set | The victim queue and the model | The owner discards the detail, then `VictimReleased` | Offload, Budgets |
| Snapshot hold | `AcquireHold` | The model's hold, the borrower count and the snapshot backing ledger | `ReleaseHold` on every exit of `withSnapshot`; closure waits for zero | Budgets (snapshot), Lifecycle (borrower) |
| Handoff | `BeginHandoff` (reserves the duplicate in staging) | The region's handoff record | `HandoffConfirmed` or `HandoffFailed` | Offload |
| Defect | Detection | The bounded defect record | Never; read by inspection | Races, Lifecycle |

## Tests

`hetoimasia-terrain-runtime:terrain-runtime-tests` is the non-optional CPU group
`test.terrain-runtime`:

```sh
cabal test --project-file cabal.project.cpu hetoimasia-terrain-runtime:terrain-runtime-tests --test-show-details=direct
```

`Test.TerrainRuntime.Hardening` includes an owner interrupted at each phase of
its work (a load, a read's capture, staging, the commit boundary, a transfer, a
victim's release), after which nothing may remain reserved, running, transferring or
retiring.

`Test.TerrainRuntime.Interleaving` runs a randomized interleaving of submit, cancel,
grant, release, end, edit, borrow and view demand (24 seeds of 300 steps each, the
sequence a function of the seed) beside the running owner, checking after every step
that the structural invariants and the model's charge rules hold and that no defect
was recorded, and at the end that every accepted request reached exactly one terminal
outcome and every bank is empty. A fourth group of 24 seeds runs under tight
service-wide limits (two arenas, five leases, two views, three clients) and, after
every step including those taken inside a held borrow, requires each limit's count to
equal the entities of every state that hold it (a closed arena whose snapshot is still
borrowed included) and never to exceed the limit; the group asserts that it saw
retiring arenas. The model-backed banks are checked too, in every run, under the owner's
accounting rule: **nothing is ever under-charged**. The model must charge at least what the
service holds, for every bank, slot and arena in every state, and exactly only where the
issue states an exact charge (a request's record, a removal's reservations, the slots and
holds); over-charging is allowed where the model is conservative by design (an edit that
coalesces keeps its monotone retained charge: remove levels 0, 2, then 1 and the arena is
charged 80 bytes where it holds 64). `Test.TerrainRuntime.Usage` states what each bank and
slot must hold from **the service's own data**, never from the accounting model's fields.
`inspectCensusSTM` (read-only, for verification, used by no production caller or decision; read in one
transaction with the model) reports, from the service's own structures, the bytes each
arena's resident detail holds in every vertical region (a region's fixed metadata, an index
entry per column and each segment's metadata and payload, measured on the `Resident` value),
each arena's retained-changes bytes, live or retiring, every request the service holds
(table and withdrawn ghosts) with whether it holds a removal reservation, its
outstanding snapshots, and **the service's record of the work it runs and holds**. That record
(`RunningWork`, the owner's ruling of 2026-11-08 on the issue, comment 6728512155) is written in the
transaction of the model event it mirrors, and no production decision reads it:

* **every accepted load job**, from its admission to its report (completed, failed or acknowledged),
  whether it is running, queued or waiting for victims: the resident reservation and the scratch the
  model **granted** it at that moment (400 and 258 for a one-cell read in a fresh region), so a later
  reduction while the job still holds them is seen (a stability check of the model against its own grant,
  not an expectation); and, once the owner **runs** it, the **least the job holds**, worked out from the
  coverage the owner is given to load and the data layer's own sizes and not from the model's cost
  functions (a column index entry is 48 bytes, a segment 32 of metadata and at least 2 of payload, the
  scratch a 256-byte frame and two bytes a cell: 82 and 258) together with the load-job slot (1 from its
  dispatch, 0 while it waits: a waiting job holds only a promise, so it contributes no expectation). The
  owner marks a job it runs and ends it with its report, so a model that forgets a running job is seen;
* the **preparation** the owner is running (a removal's resident growth, 62 bytes, staging, 512, and
  retained edit, 64, and the command record it reads under), from its start to the owner's safe point;
* each **handoff duplicate** (the bytes the owner copies, 64 for one removal), from the transfer's
  admission to its outcome;
* each outstanding **borrow**, the regions the snapshot handed out covers and the **accounted bytes it backs**
  (its payload, segment metadata and column index entries, measured on the snapshot value at hand-out, never
  read from the retained-bank ledger), until its borrower releases it, whether its arena is live or closed and
  retiring behind it; and each **view** with an accepted demand and the regions that demand describes
  (admitted and pending, from the receipt): the service's own account of what it lent and accepted.

Every inspection type (`Census`, `ArenaCensus`, `RequestCensus`, `RunningWork`, `JobWork`,
`PreparationWork`, `HandoffWork`) is abstract with read-only accessors that are functions, never field
labels: an external client cannot construct, forge or update one, and none carries an authority, a handle
or a snapshot. Reading them takes no hold, interest or reservation and changes no residency, LRU order or
scheduling. The check requires: each region charged at least what its detail
holds, and no region held by the service with no model record (nor charged, unless
evicting, when the service holds none); each arena (live or retiring) charged at least its
own retained changes, and the edit bank at least their sum; a removal's resident growth at
least the worst case of a segment (two bytes a cell for a dense segment, less the two bytes
of a uniform one) and its edit and staging reservations as stated; the staging bank's
request records exactly what the service's requests hold; the command slots exactly the
service's requests that hold a model record; and the snapshot holds exactly the service's
outstanding snapshots. The running work is compared in its own amounts, entity by entity and bank by
bank: every job the owner runs must be charged at least what its coverage needs, and every accepted job, running or
waiting, at least what the model granted it (a charge one byte short fails, as does a waiting job whose
charge was released early); the load-job slots at least the jobs the owner runs; the resident bank's
reservations (counting what still waits for victims) at least every job's plus the removals' growth;
the staging bank's reservations at least the removals' staging plus the running jobs' scratch; the retained-snapshot bank at least the backing of every snapshot handed out and still borrowed (per snapshot and in total, live and retiring incarnations alike) plus one record for each request the service holds; the view pin slots zero (the service never pins a view's revision); the service-wide limits (arenas, leases, views, clients, command slots, the retained bank) against enumerations that read only the service's own structures; each handoff
duplicate at least the bytes the owner copied; the model must still hold, with its growth, the request the
owner is preparing; each borrow's hold must name at least the regions of the snapshot handed out and
each view's description at least the regions of the accepted demand; and the staging bank's
occupied bytes at least what the service's own records need (the request records, one interest for each region
each held request demands, one hold record for each region each borrow covers, each view's description and
the duplicates). A camera demand's interests exist only in the model's own records, so they are not claimed;
the ledger is also compared exactly with the model's own entity lists (consistency of the model with itself,
named as such, not an independent expectation). These comparisons
run after every step of the property, inside every held borrow, at every job (where the record
must also show the job running, with a slot and non-zero amounts) and, with releases
injected, inside the preparation hook right after each cancellation, lease release or
client end, before the owner resumes. The property ends with every bank, occupied as well as reserved,
every slot and every arena at zero: no charge, a coalescing excess included, outlives its holder.
`Test.TerrainRuntime.Oracle` pins the record's literal amounts at a gated job (running and waiting), handoff,
preparation, borrow and view, and holds the controls that must fail: a model that charges the running job
1 byte of resident and 1 of scratch instead of 400 and 258 (and one byte short of each figure), a waiting job
whose 400 and 258 were released while another job runs (and one byte short), a job the model forgot while it
runs, a 64-byte handoff duplicate zeroed (or not charged at all), a preparation whose request the model dropped
or for which it reserved no growth, a borrow's hold shortened from two regions to one (the staging charge with
it) or dropped, a view's description shortened or dropped, a model rebuilt without the arena beside the
service's real census (every bank disagrees), and two arenas' retained charges swapped. It also shows that
reading the census changes neither the model, its clock, its requests nor its limits, and that an arena with
coalesced edits, charged more than it holds, returns every account when it retires.
`Test.TerrainRuntime.Budgets` pins D-42: a twelve-region camera demand over a resident bank of about two
regions is admitted best effort with a pending remainder (asserted, so the example cannot pass
without capacity pressure), and an explicit query and a removal are admitted and complete
while that demand stays registered and is never withdrawn.
`Test.TerrainRuntime.Limits` pins the examples: with the default limits, four closed
incarnations each held by a snapshot refuse a fifth admission; exactly one borrow is
released, three stay outstanding, and a replacement is admitted (and a further one is
refused again); and a transfer's duplicate, a removal's reservation and a borrow are
all accounted while the owner is held mid-transfer.

The examples drive the production service. A **gate** is an `MVar` the owner blocks
on at a named point (`Probe`), so an example decides which side of a race wins by
what it does, not by how long it waits; no example sleeps. Every thread an example
starts is owned through `Test.Support.Owned`, and every wait is bounded
(`Test.Support.Bounded`). Expected cell values come from an independent model that
shares no code with the library. The suite is built `-threaded` and is run at more
than one capability count. `Test.TerrainRuntime.Opacity` compiles clients outside the
package through `Test.Support.ExternalClient`: one composes the public service, and
every attempt to name an authority, snapshot, service or inspection-type constructor, forge
one, rewrite a snapshot or an inspection value (the census, its arenas and requests, the
record of the owner's running work) with record-update syntax or import a private module is
refused for the specific diagnostic that names the cause. Retained gated traces with before and after
accounting are in
[the TRA-4 evidence](../../docs/evidence/terrain/tra4/service_evidence.md).

## The temporary store (TRA-20)

The store is the **pure model** of the disk backing of design P-15 (D-40, D-41,
D-43, D-52, D-59): the private page format, the copy-on-write indexes over it, the
allocator and retirement work, staged transaction planning, pinned readers,
reclamation, the allowance and its growth, and the edit bank's storage-aware
admission. It performs **no file I/O, starts no thread, runs no STM and reads no
clock**. The baseline service above is unchanged and still retains its edits in RAM
until the terrain owner adopts the store (TRA-22); nothing here is wired into it.

| Surface | What it is |
| --- | --- |
| `Hetoimasia.Terrain.Runtime.Store` | the narrow public interface: configuration, windows, `Store`, planning, the transaction, readers, growth, feasibility |
| `Hetoimasia.Terrain.Runtime.Store.Admission` | the edit bank's division and its all-or-nothing, backed-only-eviction credits; every cache entry is charged at least a page (`minCacheEntryBytes`) and every grant at least 128 bytes in each account it draws on (`minGrantBytes`), so no number of tiny credits holds records the ledger does not show |
| private library `store` (`store/`) | the codec, trees, allocator, planner and state machine; visible to no client; this package's suite reaches it to check them against independent references |

A client, such as the later storage backend, holds a `Store` value, plans through a
`Window` (a bounded set of validated page buffers for one store and one version), writes the pages a `Plan`
names, and reports outcomes:

```haskell
plan <- planRemoval env store window tile      -- or planDiscovery, planMaintenance
case plan of
  Pending page  -> fetch it, addPage it to the window, plan again
  Planned p     -> admit p store            -- one active transaction, claims its pages
                   -- write planPages p; report dispatchWrite / completeWrite
                   -- publish tid store      (the owner's decision) or abortTransaction
  NoWork        -> nothing to append (a no-op appends no history)
  Refused why   -> classifyPlan why           -- busy, invalid, disk, integrity, replan, too large
```

**The caller protocol is a requirement on every consumer** (the storage backend of #663 and the owner of #665
among them). A plan reads through the window the caller gives it, and the window is the only state the caller
carries from one call to the next, so the retry for a window that outgrew its bounds is the caller's, through
the window: when a plan answers `Refused (Capacity (WindowExceeded _ | WindowBytesExceeded _ | ProbesExceeded _))`
the larger unit of work did not fit. The caller builds a fresh window for the same version, `reduceWork old fresh`
(the work the plan may take on, `windowWork`, halves: the pages one maintenance transaction frees, the writes of
one discovery batch; never below one), and plans again. A unit of one page or one write needs a bounded window,
so the retry ends in at most six steps with the work done or the typed result for a window that cannot hold even
that; a caller that retries the same window or restarts at the full work gets the same answer for ever (the
failure round 12 found). Every other capacity result either is handled inside the call (`TxnPagesExceeded`,
`TxnRamExceeded`, `ListTooLarge`, `OverlayExceeded`, `BookkeepingExceeded`: discovery halves its writes and
maintenance its chunk) or waits for a reader's release and maintenance (`DiskFull`, `RetirementBacklog`: the
`BlockedByReader` result names the reader), or is the typed refusal of a store beyond its format (`TreeTooTall`).
`Hetoimasia.Terrain.Runtime.Store` documents the same loop beside `Pending`; the suites drive it as a caller
does (`fillRetry`).

**The loose list has a caller rule too.** A page a plan replaces in the allocator or retirement trees returns to the
root set's loose list, which is capped (`looseCap`, 1,024). Maintenance drains it before anything else: a list above its
soft cap (`looseSoftCap`, 512) makes the next maintenance transaction a *spill*, which only inserts up to
`maxSpillPages` (8) loose pages into the allocator tree (each proven unreachable and unowned like a page a plan
writes), strictly lowers the list, and runs even when no retirement entry is left to reclaim (`NoWork` is answered only
once the list is at the soft cap) and while a reader holds the oldest entry. A transaction of one page that frees pages
adds at most `looseGrowthUnit` to a list at the soft cap or below, and an ordinary plan, a standalone removal included,
adds none while the list holds what the plan claims, so neither reaches the cap on a valid store. A plan that
nevertheless answers `Capacity (LooseExceeded _)` is shrunk like any other batch, and at the smallest unit the caller
runs maintenance and plans again; maintenance is never refused for it.

**Every consumer of the planner must also handle `Checkpoint`.** A plan about to overwrite or free a page
first proves that nobody but the allocator owns it (a path of its first key in the committed tree and in every
pinned reader's tree, the retired-page index, the free extents); a plan that frees pages also verifies the
last 64 pages its entry consumed are gone from the index. Each proof is a read-only fact about the committed and
pinned state, and the proofs are the only part of a plan whose window grows with the readers and the tree
heights. A plan whose window would outgrow its bound while proving answers `Checkpoint facts` instead: build a
fresh window of the same version with `windowCheckpoint facts old` (it drops the pages and probes, keeps the
facts, the work limit and the trust) and plan again; the plan does not repeat a proof it carries a fact for. The
`Facts` are opaque (no constructor reaches a client) and carry the state they were proven against (the store, the
version, the committed roots and the pinned roots with their versions): a window trusts them only for exactly
that state, so a reader acquired in between or a commit costs a proof again and never skips one it should have
made. A checkpoint always carries a new fact (a window that cannot hold the plan's edit and ONE proof is the typed
`WindowExceeded`), so a transaction takes at most as many checkpoints as the pages it writes plus the 64 it
verifies. What a window holds at once is the edit and one proof, `workOneWindowPages` for a unit of one page and
`removalWindowPages` for a standalone removal, which cannot shrink; both rest on `maxLevel` and `maxReaders`
alone, and both are asserted against `maxWindowBytes / windowPageBytes` (310 pages) for every height 1 to 8 and
every number of pinned readers (the removal's retirement-tree term, at most 17 internal pages, rests on two
checks the store makes: a non-root page below a quarter of a payload is refused when a plan descends to it
(`UnderFull`), and a root set retiring more than `maxRetiredPages` pages is refused at every plan).

### The page format

A page is exactly **4,096 bytes** and immutable once written. Header fields are
little-endian; keys inside entries are order-preserving big-endian (a signed number
has its sign bit flipped) so that the byte order of a key is its logical order.

| Offset | Bytes | Field |
| --- | --- | --- |
| 0 | 4 | magic `HTRP` |
| 4 | 2 | format version (1; any other is refused) |
| 6 | 1 | kind: 1 leaf, 2 internal, 3 retirement list |
| 7 | 1 | tree: 0 runs, 1 links, 2 todo, 3 free, 4 retire (a list page is tree 4) |
| 8 | 8 | arena incarnation |
| 16 | 8 | source identity |
| 24 | 8 | the page's own number |
| 32 | 1 | level: 0 for a leaf or a list, 1 to 7 for an internal page |
| 33 | 1 | reserved, zero |
| 34 | 2 | entry count (at least 1) |
| 36 | 2 | end of the payload (40 + payload bytes, at most 4,092) |
| 38 | 2 | reserved, zero |
| 40 | to 4,092 | payload, then zero padding |
| 4092 | 4 | CRC32C of bytes 0 to 4,091 (Castagnoli, reflected polynomial `0x82F63B78`, initial and final `0xFFFFFFFF`) |

Leaf entries are `keyLen(1) valueLen(1) key value` (key 1 to 64 bytes, value at most
64); internal entries are `keyLen(1) key childPage(8) childCrc(4)` (at most 77 bytes, so at most 52 children a page; a 24-byte key leaves room for 109); the size of an internal entry is defined once, `innerKeyBytes` in `Page.hs`, and every sizing decision (split, merge, redistribution, the accounting of a node, the page decoder) uses it, the key being the least key
the child may hold; a list is the eight-byte version of the retirement entry that
names it, then a strictly increasing run of eight-byte page numbers (at most 505). The records of each tree:

| Tree | Key | Value |
| --- | --- | --- |
| runs | column x(8) y(8), lower level(8): 24 | upper level(8) |
| links | `0` tile(24) and three optional parameters `present(1) coord(8)` (52), or `1` column(16) level(8) (25) | `0` size(8) known(1), or `1` parent node key |
| todo | sequence(8) | tile(24) done(1), `done` in 1 to 6 |
| free | start page(8) | length(8), at least 1 |
| retire | the version that replaced the pages(8): 8 bytes; or `0xFF` and a retired page number(8): 9 bytes | list page(8) count(2) done(2), `done` below `count`; or the version of the entry that owns the page(8) |

**What a decode checks, in order**, before anything uses the page: the buffer length
(short and oversized are refused before they are read), the checksum, magic,
version, kind, tree, arena, source and the page's own number (a page read from the
wrong place is refused), the reserved bytes, the level against the kind (an
internal page claims 1 to 7, so a malformed or cyclic structure cannot loop), the
count and payload end against the bytes available, every entry's lengths against
the bounds before it is sliced, that the entries end exactly at the stated end and
the padding is zero, strictly increasing keys, every child or list reference inside
the page space and never the page itself, **an internal page's separators as keys of the tree
it indexes** (a record tree's key decodes; a free extent's key is a page number; a retirement key is
a version or a retired page's marker and number: a separator no decoder accepts would make a
descent skip records that exist and answer that they are absent), and the structure of each leaf entry (a
well-formed key and value of the tree's own category: coordinates in range,
`lo < hi` inside the level limits (a link's run-node level too, in a key and in a parent value), a class size of at least 1, adjacent runs and free
extents already coalesced). A **valid checksum never rescues a malformed page**: the
same structure checks refuse a re-sealed page. A refusal is an explicit
`PageError`; it is never an empty index, absent history, air or the pristine source.
Page numbers convert to file offsets only through `pageFileOffset` and
`rangeFileEnd`, which check the page space, the allowance and the native signed
offset limit with no wrapping. This is an internal session format: not a game-save
schema, not `Show`/`Read`, never read by another run.

### The indexes

Five B+trees share one generic implementation over the page window: the three record
categories of #661 (`KeyRun`, `KeyLink`, `KeyTodo`), the **free** tree of free page
extents (coalesced) and the **retire** tree of retirement work. A tree reads only
through a window of validated page buffers: a page it needs and does not have is the
**pending** result (`Pending page`), never an empty answer; a page that contradicts
its place (a wrong tree, a wrong level, a key outside its parent's separators) is an
integrity failure. Updates copy the changed path into an overlay and never touch a
committed page. A node that falls under a quarter of a payload after a deletion is
repacked with a neighbour (both checked against the separators their parent promises before they are merged) (merged, or split evenly), so every non-root node is at
least a quarter full; an insertion that overflows splits by bytes; a root that
splits adds a level and a root left with one child gives it back (the collapse walks down one level at a time, checking each child's level and its parent's separator bounds, so a malformed or cyclic subtree is refused, never followed). A tree is at most
**8 levels** (0 to 7); a plan that would need more is refused with a typed
`TreeTooTall`, never truncated. A legitimate tree needs a ninth level only past
about 6.7e7 records (more than 36 GiB of leaves), so the default 1 GiB allowance and
every allowance below 36 GiB can never reach it. One update costs at most
`2 * 8 + 1 = 17` new pages at that height (a copy of the path, a split at every level
and a new root). A write that changes nothing (the same value, a deletion of an
absent key) copies no page.

### Page states, ownership and accounting

Every page below the high-water mark is in exactly one state:

| State | Meaning | Reachable by |
| --- | --- | --- |
| live | in a committed tree or a retirement list | the committed roots |
| retired | replaced by a commit, listed in a retirement entry | readers pinned before the commit |
| free | a free extent of the allocator tree | nobody |
| loose | an owner-private bookkeeping page, kept in the root set for the next plan | nobody |

Pages at or above the high-water mark, below the usable page count, are the untouched
tail: free, taken by raising the mark with no allocator record. The identity
`hw = live + retired + free + loose` holds after every commit, and the suite checks
it from the bytes of the disk by an independent traversal, not from the counters.
**Used** bytes are live, retired, loose and staged pages plus the overhead; **free
reserved extents are not used bytes**; **pending reclaim** (the retired pages) is a
subset of used and never extra free capacity; a page reached by several roots is one
page; each reader and control record has its own accounted cost (`controlBytes`).

*Why loose pages are safe to reuse.* A reader pins the **record** trees only; the
allocator and retirement trees are the owner's, read only while planning against the
committed roots. A bookkeeping page a commit replaced is unreachable from the new
roots and from every reader, so the next plan may take it at once. This is what
stops reclamation from retiring its own metadata forever. Record pages a commit
replaced are never loose: they go to a retirement entry and wait for the readers.

### Transactions

At most **one** mutating transaction is active. A plan takes
`d + 1 + 68` pages from the supply (loose pages first, then free extents lowest
first, then the untouched tail), writes the pages it needs and returns the rest as
loose pages, so the allocator's own updates need no fixed point and never overwrite a
committed page. The supply is checked as it is read: a loose page or free extent outside
the used page space, a free extent overlapping the one before it, or any page that would be
handed out twice is corruption (an `Integrity` refusal), never an allocation. It writes at most **256 pages (1 MiB), index, allocator and
retirement pages included**; reserves at most **4 MiB of RAM**; reads through a window of at
most **1.25 MiB of validated page buffers** (about 310 pages); and a discovery batch performs at most **64 structural
updates**, where a structural update is #661's: one connection inspected, at most one
pair of classes joined, and the obligation's progress. The batch keeps its
continuation in the obligation records; when a tighter bound stops it earlier, it is
planned again with fewer writes, never truncated.

| RAM item | Sub-budget of the 64 MiB edit bank |
| --- | --- |
| encoded I/O buffers, keys, scratch | staging (8 MiB, 4 MiB protected for a foreground mutation) |
| the window's page buffers and the plan's new pages (held packed) | caches (48 MiB), pinned while the plan runs |
| page-pin records, root and control records, retained continuation | control and frontier (8 MiB) |

*What the RAM figure counts.* It is the memory a plan really holds: the window keeps the
validated 4 KiB buffer of each page it read (a small header more, at most 1.25 MiB) and
parses entries from a buffer only while a node is visited; the new pages a plan builds
are held **packed** (their entries as one byte string, about 4.2 KiB each, 256 pages at
most when it ends) except for the last eight per tree edit, which stay parsed and are
accounted at 28,000 bytes each; the encoded output is 4 KiB a written page. The discovery
header is charged at its fixed 128-byte record size: its byte total counts the retained
*history*, which lives in pages, and is not transaction memory, so a history of any size
plans like an empty one. A plan whose window or new pages would hold more is refused
(`WindowBytesExceeded`, `OverlayExceeded`) with nothing changed. A plan numbers and encodes its new
pages one at a time and forces each output buffer and page number before the next page is
built, so no parsed page outlives the plan (a dense 180-leaf plan's measured live heap is
checked against what it reports).

A removal and its minimum connection obligation are **one** candidate, and so are a
discovery batch's knowledge, exposed-boundary records and remaining obligations: the
plan applies every write of the candidate or none. A plan names its base (the store,
the committed version and the authority); a transaction's token carries its store, so an
outcome for another store's transaction with the same serial changes nothing; an `admit` of a plan whose base is no
longer the committed root is `StalePlan`, never relabelled. Revision arithmetic is
checked (`RevisionArithmetic`, `VersionArithmetic`); a candidate that changes no page
and no header is `NoWork`.

```text
plan -> admit -> ( dispatchWrite -> completeWrite )* -> publish
                    |                                    ^
                    cancel (a request)                   | only when every page is Written
                    abort (after the writes have drained)
```

`admit` stages the plan's pages (unreachable from the committed roots, claimed by this
transaction alone). The owner reports each page's outcome (`WriteDone`,
`WriteFailed`). A transaction is `Eligible` only when every page completed and none
is in flight; **an I/O completion is not publication**. A cancellation is a request:
it is recorded and releases nothing. `abortTransaction` releases the claims once no
write is in flight and **needs no write**: the committed roots were never changed, so
the old content, knowledge and frontier are exactly as they were. After `publish` the
new roots are authoritative and a late cancellation or outcome changes nothing;
duplicate, stale and foreign outcomes change nothing. A successful write here means
the OS accepted it, not an `fsync` or power-loss durability.

### Readers and reclamation

`acquireReader` pins the record trees of one committed version (at most 16 per store,
each with an accounted record). Writes, publication and reclamation cannot change its
answers. A commit retires only the record pages it replaced, in one retirement entry
keyed by its version; an entry is reclaimable once the oldest pinned version is at
least that version (`BlockedByReader` otherwise). `planMaintenance` first checks that every page it frees is
a retired one: inside the used space, a record-tree page and not the page a committed
tree **or any pinned reader's tree** still reaches on the path of its first key (the
owner supplies the candidate pages as probes; a retirement entry naming a live root, a
shared live subtree, a bookkeeping page, a list page or a page a reader still pins, as a
lowered version does, is `RetiredPageLive`; a list whose stamped version is not its
entry's version is `MalformedRetirement`), and
that none is already free, loose or claimed by its own supply (`DoubleFree`), so
a corrupt retirement list never yields a page with two owners. It then frees an entry's
pages incrementally (at most 64 per transaction, fewer when a bound is tighter), is a
maintenance transaction and **may spend the protected reserve**. A token of a released
reader, of another store or of another incarnation reads nothing (`ReadStale`).

### Ownership: what no persisted record is trusted for

The store decides which pages are live, free, pinned or reclaimable from records it wrote
itself, and any of them can be re-sealed with a valid checksum and name the wrong page. It
therefore trusts none of them to say a page is *safe to overwrite*. **One proof**, at the one
place a page is overwritten or freed, asks every owner a page can have:

| Owner | Decided by | A page it owns is refused as |
| --- | --- | --- |
| a committed tree (live roots) | the page is on the path of its own first key at its level in the tree it belongs to | `SuppliedPageLive` |
| a pinned reader's tree (at most 16) | the same descent from each pinned record root | `SuppliedPageLive` / `RetiredPageLive` |
| a retirement list | looked for under the version it is stamped with in the retirement tree | `SuppliedPageLive` |
| an outstanding retirement entry | **one lookup in the retired-page index** (below) | `SuppliedPageRetired` |
| the free extents, for a page taken from the loose list | one floor lookup in the allocator tree | `SuppliedPageDoubleOwned` |
| the supply itself | the pages a plan takes are distinct; each loose page is inside the used space; extents are ordered, disjoint and inside the used space | `BrokenInvariant` |

Only a page that no owner but the allocator claims is written, and a refusal writes nothing.

* **A probe, not a page.** A plan that is about to write a page below the used space, or to
  free one, asks for all of them at once with `PendingProbes`; the owner reads each and calls
  `addProbe`, which keeps only a classification: *nothing a store could read* (it does not
  decode as a page of this store at that number: garbage, never written, another store's), a
  tree page with the first key it holds, or a retirement list with the version it is stamped
  with. A probe is accounted at `probeBytes` (320) and a window may hold at most 512
  (`ProbesExceeded` past that); costs no window page.
* **The retired-page index.** Every retired page is also recorded in the retirement tree under
  `0xFF` and its page number, valued with the version of the entry that owns it; the entries
  sort before them. A commit indexes every page it replaced (a page already indexed is
  `DoubleFree`); reclamation frees a page only if the index holds it under that entry's version
  (`RetiredIndexMismatch`) and removes it as it frees it. An entry is finished only when none of the
  pages its progress field says were already reclaimed is still indexed *under this entry or an older
  one*: a reclaimed page may have been reused and retired again under a newer version (its list keeps the
  number), which is history, not corruption, and an index record under the entry's own version means the
  page was skipped (`RetiredIndexMismatch`). A re-sealed progress field therefore cannot drop a page
  from the obligation for good, and legitimate reuse cannot block maintenance (`History`: a randomized
  model of edits, partial maintenance, reuse and pinned readers, and the reclaimed-prefix regression). The index is bounded by bounding the
  backlog: an ordinary plan that would take the retired pages past `maxRetiredPages` (16,384)
  is refused with `RetirementBacklog` until a reader releases and maintenance reclaims; a
  maintenance transaction never adds to it.
* **The used space bounds every reference.** A tree root, a child reference or a retirement
  list at or past the high-water mark has never been numbered: every descent, plan or read
  (through a reader's own used space for a pinned read) refuses it with `BadReference`.
* **A pointer names a version of its child.** Every internal entry records the checksum its child
  page carries (the four bytes at the end of that page), and a node loaded through a parent is refused
  (`ChildChecksum`) when its page carries another: a stale page that is valid in itself (a replaced copy
  of the same node, in the same tree and at the same level, its keys inside the same bounds) can no
  longer stand in for the page a pointer meant, and a re-sealed change to a child page fails the
  record its parent holds. A new page's entries get the checksums of the children encoded before
  it, and the **root record anchors the chain**: it carries the checksum each tree root's page must carry
  (a window holds them, a transaction publishes those of the roots it wrote, a reader's pin records those of
  its version), so one re-sealed page anywhere on a path, the root included, fails the record above it.
  A root with no recorded checksum **fails closed** (`RootChecksumMissing`): every window a store hands out carries
  the trust of the root record or the pin, a plan's window also that of every pinned reader's roots, and only the
  test-only `windowUnchecked`, which the facade does not export, reads a root no record names.
  The residual, out of the model, is a *consistent* re-seal of the root record together with what it
  names, or of a whole path of pages together with the record above it: the trees then say a different
  thing consistently, which no local check can tell from a different true history.
* **An absence is concluded only from checked separators.** A lookup that finds nothing, a floor,
  a ceiling, the start of a ranged scan and the unreachability of a page are each concluded from the
  leaf (or node) a key leads to, which is only as true as the separators that led there. Before any
  such conclusion the neighbouring subtrees of the landing node are loaded through their own
  separators (`validateLanding`), so a separator moved to another valid key, raised or lowered, the first
  or a later one, is checked against the leaves on both sides of it and surfaces as an integrity
  failure, never as an absent record; a key below the first separator descends into the first child.
  The cost is bounded by the height: a conclusion reads the landing path (at most 8 pages) and, for each
  side, the extreme leaf of the nearest sibling subtree (at most 7 pages each, shared with what is already
  in the window), so at most `2 * (height - 1)` more pages than before, 2 in a two-level tree and 4 in a
  three-level one; they count as read steps and against the window, and a plan that cannot afford them is
  refused with the typed window result. The regression is a re-seal fuzz (`Fuzz`, `FuzzTrees`): fixed seeds
  change one field of one live page of each of the five trees (a byte, or a child pointer retargeted to a
  dead page) and recompute its checksum, and every lookup, floor, ceiling, ranged scan and
  page-reachability answer must be the reference's or an integrity failure.
* **No decoded buffer outlives its decode unaccounted.** A window keeps its own copy of the 4 KiB
  buffer it is given (a caller's buffer may be a slice of a much larger read) and a probe keeps a
  copy of its key, never a slice of the page; a hot or new node is either a parsed view of a
  window page (accounted as that page) or packed into a buffer of its own; a plan's output pages,
  keys and records are built fresh or decoded into values. The audit is by `grep` of every
  `ByteString` that crosses a window, probe, overlay or plan boundary; the regression is
  `keeps nothing of a page buffer behind a probe...` (500 probes read as slices of one large buffer
  retain less than they account and far less than the pages; a window given one page of a large
  read keeps one page; 513 probes are refused, 512 accepted).

The sites, and what stops a forged record at each (tests are in
`Test.TerrainRuntime.Store.Ownership` unless named):

| Site (record trusted) | Guard | Tamper test |
| --- | --- | --- |
| loose list (root set) | taken pages inside the used space, distinct, not also a free extent; the proof above | loose page is live; loose page is retired; loose list holds a page twice; loose page is also a free extent |
| free extents (allocator tree) | extent inside the used space, ordered, disjoint; the proof above, for a plan and for maintenance | extent offers a live page (every tree root, a page below a root, a list page); a retired page of the oldest or the newest entry with no reader pinned; a page only a pinned reader reaches, and with its index record dropped; wholly past the used space; a garbage page is overwritten, not refused |
| retirement entry version | the list's stamp must equal it; the freed pages are indexed under it; and unreachable from every pinned tree | version lowered past a pinned reader: key only, key and stamp, key and stamp and index |
| retirement entry list page, count, done | list inside the used space, a list page, the stamped version and the counted length | list past the used space, not a list, wrong counts |
| retirement list pages | inside the used space, record pages only, indexed under the entry, unreachable from committed and pinned roots, not already free, loose or claimed | names a bookkeeping page or a page past the used space; names a page another entry retired; `Readers`: a double free; a page the committed trees reach |
| the retired-page index | a commit refuses to index a page twice; reclamation refuses a page the index does not hold under its entry | a page retired twice; the backlog bound (and never for maintenance) |
| a child pointer (which version of the child it means) | the child's checksum is recorded in the entry and compared when the node is loaded (`ChildChecksum`); a cached node is used only for the checksum its pointer records | `Fuzz` / `FuzzTrees`: a pointer retargeted to a stale valid page of the same tree and level answers as corrupt, never from the stale page; `Codec`: `a child's checksum` |
| tree roots and every child reference | used-space bound in every descent; tree, level, bounds (earlier rounds) | a root past the used space; a child past it, for a plan, a committed read and a pinned read; `Codec`: bounds, cycles, levels |
| a reader's pinned roots | pinned used space, proof against pinned trees | the pinned-read half of the child test; the pinned extent and lowered-version tests |
| decoded buffers held past their decode | copies, accounted, bounded | `Bounds`: `keeps nothing of a page buffer behind a probe...` |
| counters (live, retired, free, loose list) | the identity `hw = live + retired + free + loose` and the empty-tree implications are checked at every plan and maintenance transaction (`CorruptCounters`, whatever the sign). A counter forged consistently (a transfer between two) can change only capacity and reporting (`freePool`, the retired backlog bound, the usage report), never which page is overwritten | a re-sealed counter moved up and down (`Ownership`); a consistent transfer writes only dead pages |

### The allowance

`mkStoreConfig` validates the per-arena allowance (default **1 GiB**, at least
**64 MiB**, a multiple of **1 MiB**, inside the native signed file-offset limit, binary
units) and a stated overhead (default 1/256 of it, at least 1 MiB), which counts as
used. **8 MiB inside the allowance is protected** for allocator and reclamation
progress: an ordinary transaction (an edit or a discovery batch) is admitted only if
the free pool beside its worst-case claim (324 pages) leaves the reserve intact, and
that claim is reserved before any work, so a refusal (`DiskFull`) precedes any change
and leaves the prior contents and every discovery obligation intact. The owner maps it
to `storage_full` and the pause. `minimumRemovalFeasible` shows the supported minimum
removal (7 record writes at the tallest height, a list page and the bookkeeping
reserve: 188 pages, 3.0 MiB of RAM) fits any accepted configuration in an empty
workspace; if a configuration could not hold it, the counterexample is returned for a
design decision and no budget is relaxed.

*Growth* is a conservative, serialised, accounted proposal: `proposeGrowth` is pure
(the size rules are checked first and alone: equal size is `GrowthNoOp`, an idempotent success; a well-formed smaller size is
`GrowthNotIncreased` whatever overhead the configuration carries (a replacement configuration is built only for an increase), which the owner maps to `storage_size_not_increased`; a malformed,
misaligned, too small or out-of-range size is `GrowthInvalid`, a validation refusal
before any provider work); `beginGrowth` is refused while a transaction is active;
`growthReserved` records the extra reservation as pending, not spendable;
`commitGrowth` enlarges the allowance only after that and clears **only** the capacity
pause. A failure before commitment keeps the old allowance and records, and an extra
reservation it had obtained stays accounted until its release is reported (a failed
release keeps it, and another growth is refused until it is released). Nothing grows
or deletes history by itself, and an integrity or I/O pause is not cleared by a larger
allowance.

### Edit-bank admission

`Hetoimasia.Terrain.Runtime.Store.Admission` divides the 64 MiB edit bank into 48 MiB
caches, 8 MiB staging (4 MiB protected for a foreground mutation) and 8 MiB control,
shared across arenas, and validates that a worst-case foreground transaction could
always be funded. `reserve` funds all the credits of a request or none. A cached copy
is `Backed` (a copy of a written page) or `RamOnly` (the only copy: a staged page
whose write has not completed, or a baseline authoritative record); eviction releases
only backed, unpinned copies, least recently used first, and `dropEntry` refuses a
`RamOnly` one, so eviction never deletes authoritative history or pending discovery.
Camera work cannot take the protected staging or hold a control record, so a
foreground mutation's credits are protected from camera reads or reclaimable by
evicting backed copies, and no request waits in a circle. The failure classes stay
apart: temporary pressure (`RefusedBusy`), a request that can never fit
(`RefusedInvalid`), disk exhaustion, integrity failure, a plan to redo and a pause an
explicit recovery clears (`classifyPlan`, `classifyAdmit`). The baseline's 64 MiB
edit bank, its lifetime retained-edit charge and its `RetainedEditsExhausted` outcome
are unchanged until TRA-22 (checked in `terrain-tests`).

### Ownership of the store's state

| State | Owner and writers | Readers | Lifetime |
| --- | --- | --- | --- |
| the committed roots, counters, loose pages and header | the terrain owner alone, only through `publish` of an admitted plan | planning and readers (as copies) | the arena's incarnation |
| the staged claim and its buffers | the one active transaction | the owner | `admit` to `publish` or `abortTransaction` after the writes drain |
| reader pins | the owner (`acquireReader`, `releaseReader`) | the reader's token | until released; an arena close drains them before the file closes |
| a window | the caller of one plan or read | that plan or read | one store and one version; a window of another arena, source or version is refused by every read and plan, and never carried across a publication |
| the edit-bank occupancy | the owner | the owner | the service |

### What later slices supply

TRA-21: the temporary file, its descriptor lifecycle, real preallocation and free-space
checks, the I/O workers, short-write loops and filesystem overhead qualification.
TRA-22: opening, the live owner's root publication, write-backed request settlement,
discovery scheduling, pause and retry orchestration and close and reset. TRA-23: the
Lua facade and status. No result of this model is proof of physical preallocation,
durable writes, live settlement or crash recovery.

## Consumers

TRA-5 attaches the Lua request endpoint through the settlement seam. TRA-9 and the
view adapters supply view demand and consume snapshots. The temporary store
(TRA-20–TRA-23) replaces the RAM-only retention. Input, camera and picking
implementation, GPU upload and retirement, arena artwork, disk persistence, general
gameplay state and `api.state` are not part of this package.
