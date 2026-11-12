# hetoimasia-terrain-runtime

The scoped, transactional terrain service (TRA-4 of epic #636). It executes the
pure residency model of [`hetoimasia-terrain`](../terrain/README.md#residency-and-admission)
against real owned data: one dedicated owner thread, bounded asynchronous loading
and eviction, atomic whole-cell removal that commits together with its successful
settlement, immutable borrowed snapshots, offload and reload from the immutable
source plus canonical retained removals, and an orderly close.

It depends on `hetoimasia-terrain`, `hetoimasia-foundation` and
`hetoimasia-runtime`. It has no Lua, GLFW, graphics or game dependency. Its one native
dependency is the storage backend's small C shim (see
[the storage backend](#the-storage-backend-tra-21)); the baseline service above uses
none. It has no global registry and no universal environment: everything it borrows is
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
| private library `store` (`store/`) | the codec, trees, allocator, planner, state machine and, since TRA-21, the edit bank's admission (`Store.Internal.Admission`, moved here unchanged so the storage backend can charge it without a dependency cycle; the public `Store.Admission` re-exports it); visible to no client; this package's suite reaches it to check them against independent references |
| `Hetoimasia.Terrain.Runtime.Storage` | the storage backend's narrow public interface (TRA-21): the service, opaque handles, jobs, outcomes and typed failures |
| private library `storage` (`storage/`) | the backend's native shim, file layer, volume qualification and service; visible to no client; this package's suite reaches it to drive the production adapter through a seam |

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
one discovery batch), and plans again. The limit counts units of the planner's own work and a planner never does
less than its **atomic unit**: a limit below it means the unit (`windowWorkAtLeast`; `State.hs` defines each unit
once: `maintenanceUnitPages`, one page, and `discoveryUnitWrites`, the three writes of one connection inspection,
which is #661's `worstEdgeWrites`). A standalone removal is one atomic edit and reads no work limit: a window it
outgrows is a hard capacity result, bounded by `removalWindowPages`. The unit needs a bounded window (the discovery
unit holds at most `discoveryUnitWindowPages`, 230 pages at the deepest trees and 16 pinned versions, inside the
removal's 294 and the limit of 305: the edit phase's formula plus the 4 pages of read residue below), so the retry ends in at most six steps with the work done, and never in
`Invalid`, `Integrity` or `Stale`: a driver that follows this protocol exactly succeeds from every starting limit
from 1 to 64 (`Test.TerrainRuntime.Store.Protocol`; the table of the refusals `classifyPlan` maps to `FailInvalid`,
none of which a valid store reaches, is in the evidence); a caller that retries the same window or restarts at the full work gets the same answer for ever (the
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
adds none while the list holds what the plan claims, so neither reaches the cap on a valid store. The whole list
(at most `looseCap` numbers) is validated at every plan and every maintenance transaction before any piece is used:
every page inside the used space and no page listed twice, wherever it sits in the list. A plan that
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
`Facts` are opaque (no constructor reaches a client; the read facts in them are packed when they are created, never typed) and carry the state they were proven against (the store, the
version, the committed roots and the pinned roots with their versions): a window trusts them only for exactly
that state, so a reader acquired in between or a commit costs a proof again and never skips one it should have
made. A checkpoint always carries a new fact (a window that cannot hold the plan's edit and ONE proof is the typed
`WindowExceeded`), so a transaction takes at most as many checkpoints as the pages it writes plus the 64 it
verifies. What a window holds at once is the edit and one proof, `workOneWindowPages` for a unit of one page and
`removalWindowPages` for a standalone removal, which cannot shrink (the edit phase's formula plus `readResiduePages`,
below); both rest on `maxLevel` and `maxReaders`
alone, and both are asserted against `maxWindowBytes / windowPageBytes` (305 pages) for every height 1 to 8 and
every number of pinned readers (the removal's retirement-tree term, at most 17 internal pages, rests on two
checks the store makes: a non-root page below a quarter of a payload is refused when a plan descends to it
(`UnderFull`), and a root set retiring more than `maxRetiredPages` pages is refused at every plan).

**The read phase of a removal and of a discovery step is a checkpoint phase too.** A removal reads logical records
(union-find chains, floor runs, up to `worstEditReads`, 197) before it can say what it writes, and a discovery step up
to `worstEdgeReads` (132) an inspection; every page of every read stays in the caller's window until the plan ends,
which no formula over the write paths can bound. The records a plan has read are therefore facts it carries through
`Checkpoint`, exactly as it carries its proofs: the provider answers from them first. A read phase ends in a
`Checkpoint` of everything read so far when it needs a page the window cannot take (the proof phase's rule, under the
plan's own bounds), and once more when it ends holding more than `readResiduePages` (4) read pages, so that the edit
starts from an empty window; a checkpoint with no new fact is the typed window result. The window holds at once the
phase's own pages: the read phase at most the bound it runs under (every promised bound holds one whole read, at most
`2 * height` pages), the edit phase the edit formula plus the residue. `readResiduePages` is derived from the byte
limit (the worst removal, `removalWindowPages`, 294 pages at the deepest trees and 16 pinned versions, leaves room for
4 more whole pages beside its `removalWorstProbes` probes, at the MEASURED page and probe costs below); the probe figures are counted from the pages written
(`minimumRemovalPages`, 188; the discovery unit's `discoveryUnitPagesWritten`, 120). The facts are RAM, in the plan's
charge as a retained continuation (held PACKED, the encoded key and value as two compact byte arrays, and charged from what is held plus 128 bytes an entry: at most
256 bytes a fact, 50,432 B for a removal's 197 reads and 33,792 B for a unit's 132, under
`maxReadFactBytes`; past it the shrinkable `TxnRamExceeded`), and the feasibility proofs count them. They are for the
retries of ONE plan, and a window of another version drops them. The cost of the rule is one more checkpoint (and one
replay of staging from the facts) when a read phase held more than the residue. The read-only queries (`queryCell`,
`queryObligation`, ...) are not plans and make no at-once claim: #661 bounds each by its own read limits, and the
window a query reads through is the caller's.

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
| retire | `0x00` and the version that replaced the pages(8), or `0xFF` and a retired page number(8): both 9 bytes | list page(8) count(2) done(2), `done` below `count`; or the version of the entry that owns the page(8) |

**The key table: every tree, every kind of key, its length and first byte** (printed by the suite's `Keys` example from the
encoders, never typed here). One key length per tree, except links; the kinds of a tree never share a first byte or a length.

| Tree | Kind | Length | First byte |
| --- | --- | --- | --- |
| runs | run | 24 | `0x80` |
| links | source node | 52 | `0x00` |
| links | run node | 25 | `0x01` |
| todo | sequence | 8 | the number's own first byte |
| free | extent | 8 | the number's own first byte |
| retire | entry (version) | 9 | `0x00` |
| retire | retired page | 9 | `0xFF` |

The retirement tree's two kinds are told apart by that tag byte alone: the 8-byte version key it had before round 19 began with
the high byte of the version, so from version `0xff00000000000000` an entry's key looked like a retired page's marker (a replaced
run was then a retired page that maintenance answered `NoWork` for). The property: over the full range of the 64-bit version and
page number (both edges, every byte boundary), the two kinds are disjoint, and each is ordered by its number.

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
an entry's tag and version or a retired page's tag and number: a separator no decoder accepts would make a
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
least a quarter full; an insertion that overflows splits by bytes. Insertion and deletion leave through ONE exit
(`exitNode` for every node, `exitRoot` for the root): a node that fits is rewritten, an emptied one is dropped, a node
that holds more than a payload is split into two halves (a deletion's repack can install a longer separator in its
parent, so a deletion can split a node as an insertion can), a root that
splits adds a level and a root left with one child gives it back (the collapse walks down one level at a time, checking each child's level and its parent's separator bounds, so a malformed or cyclic subtree is refused, never followed). A tree is at most
**8 levels** (0 to 7); a plan that would need more is refused with a typed
`TreeTooTall`, never truncated. A legitimate tree needs a ninth level only past
about 6.7e7 records (more than 36 GiB of leaves), so the default 1 GiB allowance and
every allowance below 36 GiB can never reach it. One update costs at most
`2 * 8 + 1 = 17` new pages at that height (a copy of the path, a split at every level
and a new root). The bounds of a window and of a plan (`workOneWindowPages`, `removalWindowPages`, `maxRetireInternals`,
`looseGrowthUnit`) count a deletion's pages as rewrite-only: they assume a deletion never splits a node. That holds for
this format's key sizes: every tree has ONE key length, except the links tree (52 and 25 bytes). The retirement tree HAD two, 8 bytes
for an entry and 9 for a retired page, until round 19 (a parent of 18 entries and 167 page children filled 4,052 of 4,052 bytes, and a
deletion split it); its keys are now all 9 bytes, tagged by kind (the key table above), so a parent cannot sit
within a separator difference of full. A tripwire test per tree (`Rebalance`, every tree including both kinds of the retirement
tree) fails if it stops holding; a key size that makes it false must
re-derive the bounds. A page is held to the minimum fill whenever it is reached from its parent, whether it is decoded or
still in the hot cache after it was read as a root. A write that changes nothing (the same value, a deletion of an
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
most **1.25 MiB of validated page buffers** (305 pages at the measured page cost); and a discovery batch performs at most **64 structural
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
accounted at 32,768 bytes each (26,212 measured at the largest); the pages it writes are charged at what its page list retains, 4,288 bytes a page (4,245 measured). The discovery
header is charged at its fixed 128-byte record size: its byte total counts the retained
*history*, which lives in pages, and is not transaction memory, so a history of any size
plans like an empty one. A plan whose window or new pages would hold more is refused
(`WindowBytesExceeded`, `OverlayExceeded`) with nothing changed. Every kind of plan (a candidate, a header-only
candidate whose writes are all no-ops, a reclamation) takes its charge from ONE function, `chargeFor`, which refuses it
(`TxnRamExceeded`, with the plan's total: the figure may be under the limit when a component is past its own worst case)
when its total is past 4 MiB or any component is past the worst case the admission is sized for; that worst case holds at most
three record writes for each of the 64 updates of a batch (192, #661's default), so a candidate with more is the shrinkable
`TxnRamExceeded`. A plan numbers and encodes its new
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
  with. A probe is accounted at `probeBytes` (256; 168 measured, its key held as a compact byte array) and a window may hold at most 512
  (`ProbesExceeded` past that); costs no window page.
* **The retired-page index.** Every retired page is also recorded in the retirement tree under
  `0xFF` and its page number (a 9-byte key, tagged), valued with the version of the entry that owns it; the entries
  (`0x00` and the version, also 9 bytes) sort before them. A commit indexes every page it replaced (a page already indexed is
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
| loose list (root set) | the whole list validated at every plan and maintenance transaction (length, inside the used space, distinct); the pages taken or spilled also not a free extent, and the proof above | loose page is live; loose page is retired; loose list holds a page twice; loose page is also a free extent |
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
reserve: 188 pages, 3,945,392 bytes of RAM at the measured costs, 3.76 MiB) fits any accepted configuration in an empty
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

### Memory is measured, not reasoned

Every constant that says how many bytes something retains is checked by the suite's `Memory` examples against the live heap, on
the LARGEST valid instance of what it stands for. "Largest valid instance" is a claim about a type, so it is checked, not
assumed: a row measures every variant of its type (each constructor; each optional field populated and not; each list at its
cap; numbers near 2^62, so no small `Int` box is shared), asserts that every variant is within its accounted figure, and asserts
that the variant the row names as the largest is the largest measured. No field is an unbounded integer: every coordinate, level
and counter is 64 bits and range-checked by the codec (`axisFromInteger`), so none is a bignum.

The method: build the structure inside the measured step from plain numbers (so nothing is allocated before the first reading),
force it all the way down, hold it, take two major collections and read `gcdetails_live_bytes` before and after, and divide. The
inputs are kept alive to the end, so a buffer that is copied into the structure is counted and not netted out against its own
dying input (the first form of the measurement read a window page as 33 bytes for that reason). A margin is accounted over every
maximum; the thin ones are named in the table.

| Constant | Largest valid instance, and why | Variants measured | Measured B | Accounted B | Margin |
| --- | --- | --- | --- | --- | --- |
| `windowPageBytes` | a 4,096-byte validated buffer whatever the page says | leaf and internal page of every tree | 4,265 | 4,288 | **23 B (thin)** |
| `probeBytes` | the links tree's 52-byte first key (the longest a valid page holds); the bound a page could carry, 64, is measured too | keys of 8, 24, 25, 52, 64 bytes, a retirement list, nothing | 176 (168 at 52) | 256 | 80 B |
| `recordFactBytes` | the longest valid key (52) with the longest valid value (53); encoded, so the typed form's optional coordinates do not matter | 32 valid key and record pairings, a floor answer, an absent answer, the 64 + 64 bound; **each against its OWN charge** (its key length, its value length and 128) | 224 at the largest pairing (own charge 233); 240 at the bound | 256 | 16 B at the bound |
| `factBytes` | the constructor with the most fields | all five `Fact` constructors | 64 (`FactGone`) | 80 | 16 B |
| `pageListCellBytes` | a cons cell and a boxed number | list of page numbers | 40 | 48 | 8 B |
| `pageSetElemBytes` | a set node, the boxed number and the pointers | set of page numbers (the replaced pages of an edit) | 56 | 64 | 8 B |
| `rootRecordBytes` | every root present, the header at its largest, five checksums, the loose list at its cap of 1,024 distinct pages | with and without roots, with and without the loose list | 41,746 | 49,664 (512 + 1,024 cells) | 7,918 B |
| `readerRecordBytes` | all three pinned roots and three checksums | with and without | 481 | 512 | 31 B |
| `writeRetainedBytes` | a source-node key and a source-node child, each with ALL THREE optional coordinates populated, held three times at once (the candidate's list, the planner's map, its canonical list) | every one of the 32 pairings of a key kind and a record kind the planner accepts | 560 (272 with no optional coordinate) | 640 | 80 B |
| `hotNodeBytes` | the densest valid page of any tree: the free tree's 8 + 8 byte extents give 225 entries (a leaf, 25,300 B); the largest is a free or todo INTERNAL page of 192 entries (8-byte separators, boxed references) | the densest leaf and internal page of every tree and kind | 26,212 | 32,768 | 6,556 B |
| `pageStateEntryBytes` | every state is nullary: one cost | the four states | 64 | 80 | 16 B |
| `overlayNodeBytes` | a leaf packs to its page payload; an internal page packs each entry one byte larger (the tag of its reference), so the shortest separator (`minKeyBytes`, 8) gives the most entries: 4,232 bytes packed | leaf and internal page of the free, retirement and runs trees | 4,478 (for its own 4,552) | payload + 320; the worst 4,564 | **74 B (2%)** |
| `writtenPageBytes` | a plan's page list holds a cons cell, a tuple, a page number and a pinned buffer around each 4,096 bytes | tree leaf, tree internal, retirement list at its cap | 4,245 | 4,288 | **43 B (thin)** |
| a `Facts` value | N packed read facts at the largest kind, N proof facts of the largest constructor (a LIST there, not the window's set), the worst fingerprint | reads 224 B each (own charge 233); proof facts 48 B each (80); one fingerprint with 5 root checksums and 16 pinned versions of 3 roots 7,285 B (`fingerprintBytes` 8,192) | a Facts of 4,096 reads and 1,088 proof facts: 1,011,808 | 1,049,600 (`factsRetainedBytes`) | 37,792 B |
| `typedReadBytes` | the same source key and child, as #661's core holds a read: the record, its map entry and the ascending list it is handed over as | the 32 pairings and a floor query (212) | 512 | 576 | 64 B |
| `headerBytes` | an authority and three counters, all at their largest | one | 105 | 128 | 23 B |

The read facts at their ceiling (4,096 of the largest kind) retain 946,336 of `maxReadFactBytes` (1,048,576). The terms of the charge
with no heap structure behind them are LEDGER terms, named as such and not measured: `ramPagePins` (16 a window page), the
continuation's base (1,024 + 8 a window page), the 4,096-byte scratch, and the descriptor records of the admission.

**What the audit found beyond the finding that opened the round.** (1) The replaced pages of an edit are a SET, 56 bytes an
element, not the 40-byte list cell the charge used for them: `pageSetElemBytes`. (2) `overlayWorstBytes` still carried a literal
`+ 160` after the overlay overhead became 320, and the overlay budgets (1,100,000 and 300,000 bytes) were fixed numbers that a dense
256-page plan exceeds: such a plan could have been refused for a promise it keeps. Every overlay figure is now one definition,
`overlayPageWorstBytes = overlayNodeBytes maxPackedPayloadBytes` (a worst packed page of 4,244 bytes, the internal page's tag byte
included, and the key table asserts `minKeyBytes`); the budgets and the worst charge are derived from it. (3) The measurement kept
the inputs alive (above).

**The design change: the overlay worst scales with the pages written.** `worstChargeWith` charges the overlay at `overlayWorstFor
written = written x overlayPageWorstBytes` instead of a constant for 256 pages. It is sound because every overlay page is a written
page (a new page is written), so a plan that writes fewer pages holds fewer overlay pages; it is why the minimum removal got smaller
although the write charge rose.

**What a plan holds that the first measured table did not count** (the manager's read of the table against the charge). (1) The
pages it writes: `ramIoBuffers` charges `writtenPageBytes` (4,288) a written page, not the 4,096 of the buffer. (2) `Facts`
cross the API PACKED: a `Facts` holds the read facts in the form a window holds them, packed when the facts are created
(`factsOf`), so nothing typed leaves the planner; `factsRetainedBytes` counts what the caller keeps between a `Checkpoint` and
`windowCheckpoint` (the fingerprint, the proof facts as a list, the packed reads) and the ceiling on the reads a plan carries is
checked against those bytes. The type is the control: `Facts` has no typed field. (3) The read phase IN FLIGHT: #661 holds the typed
read set while it reads (`typedReadBytes` 576, measured 512). It checks its read allowance only as it reads, so the allowance is
what bounds that memory: `maxTypedReads` is derived to fill a plan's 4 MiB exactly from its seven terms, the typed reads, a full
window (1,310,720), the ownership probes (131,072), the packed facts at their ceiling (1,048,576), the proof facts a replayed read
phase carries (87,040), the writes staging has accumulated (122,880: 192 at `writeRetainedBytes`) and the fixed records (74,880):
**2,463 reads**. Both planners pass it as the read allowance (`bdMaxReads`), so a discovery batch that would read more ENDS EARLY as
progress with the inspections it completed. It is never a refusal: the cap is above what a removal reads (`worstEditReads`, 197) and
what one inspection reads (`worstEdgeReads`, 132), as a property of the suite. #661's own scratch figure (`worstEdgeScratch` and its
kin) is an accounting limit of that package, a bound it checks its own work against, and not a structure counted here.

**Consequences, stated plainly.** (1) A window holds **305 pages** at `maxWindowBytes`. (2) `readResiduePages` is **4**: the promised
removal bound is **294** pages and a discovery unit's **230**. (3) The sum of every component's worst case is an ACCOUNT bound:
**5,663,872** bytes with the read facts at their ceiling (io 1,097,728, decoded 2,697,216, keys 122,880, scratch 613,376, pins 8,192,
root and control 70,784, continuation 1,053,696) and 4,615,296 without them, above the 4 MiB limit. The one gate is `chargeFor`, which
refuses (`TxnRamExceeded`) a plan whose own total is past the limit. The promised extremes are each planned and fit: the minimum
removal needs **3,945,392** bytes and a discovery unit **3,324,256** of 4,194,304 (249 KB of headroom for the removal).

### Edit-bank admission

**The worst case is the charge builder, not a copy of it.** The accounts are sized from `worstTransactionCharge`, which is
`ramFor`, the builder a real plan is charged by, applied to worst-case arguments (`worstChargeWith`, with the read facts at
`maxReadFactBytes`); the minimum removal and the smallest unit of discovery are the same function at their own arguments. A
term the charge gains is therefore in every worst case, and the suite checks, for every plan it commits, that each component
and each account's credit is at most the worst case's. The smallest control account `mkEditBankConfig` accepts is 1,134,208
bytes for one arena and one reader (1,166,464 at four arenas of 16 readers), protected staging 1,833,984 and cache 2,834,432
(11,479,040); the defaults (8 MiB, 4 MiB, 48 MiB) hold them. The component-wise worst total, 5,663,872 bytes (4,615,296 without
read facts), is above 4 MiB: it is a bound for the accounts and not for one plan, which `chargeFor` holds to 4 MiB (see
*Memory is measured* above).

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

TRA-21 (supplied; see [the storage backend](#the-storage-backend-tra-21)): the temporary
file, its descriptor lifecycle, real preallocation and free-space checks, the I/O workers,
short-write loops and filesystem overhead qualification.
TRA-22: opening, the live owner's root publication, write-backed request settlement,
discovery scheduling, pause and retry orchestration and close and reset. TRA-23: the
Lua facade and status. No result of this model is proof of physical preallocation,
durable writes, live settlement or crash recovery.

## The storage backend (TRA-21)

`Hetoimasia.Terrain.Runtime.Storage` performs the effects the pure store above describes: one
private, reserved, unlinked temporary file per arena incarnation, bounded asynchronous page I/O on
two workers, and checked growth. It **publishes nothing**. No outcome changes a root, a revision or
a request's result: the terrain owner (TRA-22) holds the one current `Store`, hands the backend the
pages a transaction staged (`stageWrite`), reports each page's outcome to the model
(`writeOutcomes`) and alone decides publication or abort. A claim that the writes were durable,
that a crash is recoverable or that a live terrain publication works is not made here: a successful
write is the operating system accepting it, never an `fsync`.

```haskell
withStorage config admission group logger $ \svc → do      -- two workers start in the caller's group
  Right t ← submitOpen svc ExplicitWork (OpenSpec dir identity (storeConfig store))
  atomically (awaitTicket svc t)
  Just (Opened backing reservation) ← withOutcome svc t pure   -- reserved, proven, unlinked: only now ready
  Right w ← pure (stageWrite store txn)                        -- the active transaction's staged pages
  Right t2 ← submitWrite svc backing w                         -- at most 256 pages, 1 MiB
  ...
  closeBacking svc backing                                     -- drain, then close the descriptor once
```

The storage location is an explicit input (`osDirectory`): the backend uses no implicit current
directory and has no default; TRA-22 or application assembly chooses and documents the production
default. Space and support are asked of the opened descriptor (`fstat`, `fstatfs`), never of a path.

### State, owner, thread and lifetime

All service state is one record behind one `TVar`, with the shared edit-bank `Admission` the
caller injects: a submission, a dispatch, a completion, a cancellation and a close are each one
transaction on them, so no credit is taken twice or released twice.

| State | Owner and writers | Readers | Thread | Bound | Release |
| --- | --- | --- | --- | --- | --- |
| The descriptor of a backing | The backing entry, from the open job's success to `closeBacking`; only a worker touches it | The two workers | Workers | One per arena (four) | Closed once, by `closeBacking`, after its jobs and borrowers have retired; the entry MOVES into a closing record that keeps every charge it paid for until the native close has returned, and its control grant until the close's diagnostics are done (shutdown joins it); a failed close is reported, never retried |
| The file | The backing; unlinked at creation, so it lives until the last close | Borrowers | Any | The allowance (64 MiB to the configured size, 1 GiB by default) | Reclaimed by the filesystem after the last close |
| A job record (queued, running or finished) | `submit*` creates and charges it; the workers complete it; `withOutcome`, `discardTicket` or the close retires it | The submitter | Callers, workers | 8 queued, 2 running, 32 records in all | Credits released at retirement |
| A read's transfer buffer and result | Charged at dispatch (staging for the buffer, the cache for the result copy); the service owns the bytes until retired | `withOutcome`'s body | Worker, caller | One page to 1 MiB per running read | Staging at the end of the transfer; the cache at retirement |
| A write's pages | The transaction (already accounted); the job only references them | The worker | Worker | 256 pages, 1 MiB | With the transaction |
| The volume's reservation coordination | The service; one holder at a time per volume | Workers | Workers | One per volume | Released on every exit of a reservation |
| A prepared growth and a pending reservation | The backing entry | The owner | Worker, owner | One each | Committed or abandoned by the owner; the pending record until a retry or the close; a preparation nobody received becomes a pending reservation |
| A closing record | The service, from the claim of a backing until its close has ended: the native close and then its diagnostics | Shutdown (joins it, and the seal waits for it) | Closing caller | One per backing being closed, bounded by the control account (it keeps the backing's grant: `backingRecordBytes`) | Charged for as long as it lives: once the native close has returned one transaction releases the volume's reservation and keeps a failing close, and the record (`CrReporting`) CARRIES the backing's grant through the diagnostics until the transaction that deletes it releases it |
| A kept failure (a cleanup nobody received, or a close that failed) | The service's evidence | The scope that ends the service | Any | At most 64, charged `keptEntryBytes` (2,048) each, a cleanup note or the typed failure of a close (the backing, and the errno or the bounded text of the exception); more are counted | Composed into the scope's failure at the end (a close as `BackingCloseFailed` or `BackingCloseRaised`), its charge released in the seal transaction |

**Handles are opaque.** A `Backing` names no descriptor: the service resolves it, so a closed,
foreign or reused handle is refused before any I/O, and a descriptor number reused by a later file
is unreachable through an old handle. A `Ticket` names one job of one service; a late, duplicated
or cancelled outcome cannot target a replacement arena. The constructors are hidden and the suite
compiles a client outside the package to show it.

**A worker's exit is one thing.** The cooperative stop its token carries is the only normal way a worker leaves; every other way (a cancellation delivered to its dispatch wait, a defect or cancellation out of a job, a remembered cancellation delivered after a finished job) runs the one `stopService` first: admission closes, queued work settles as cancelled, running work is asked to stop, the reason is recorded, and then the exception propagates. Admission never stays open over a worker that is gone, and running jobs never outnumber the workers alive (both are invariants the suite checks).

**Cancellation is an ownership protocol.** A cancel before dispatch withdraws the job at once. A
cancel of a running job releases nothing: the job stops at its next safe point (before the next
page), and its buffer, record and descriptor use stay charged and held until the native call has
returned. A cancel after completion changes nothing. Closing waits, with no deadline, no detach and
no timeout, for the running calls and the borrowers of that backing, in the caller's protected
boundary and not in an uninterruptibly masked release; an interruption delivered while it waits is
remembered and delivered afterwards. The close itself is one bounded, uninterruptible native call.

### Foreign calls

Every call is `safe`: a call may block in the kernel as long as the filesystem takes, and a `safe`
call releases its capability so the terrain owner and the other worker keep running. None is
`unsafe` (an unsafe call holds its capability for the whole call, and even an `fstat` on a network
filesystem is not guaranteed to be quick) and none is `interruptible` (an asynchronous exception
never interrupts a call in progress, and a descriptor is never closed under one). This needs the
threaded runtime; the service refuses to start without it (`NotThreaded`).

### The reservation, and what is proved

`reserveRange` obtains a real native reservation and then proves it: (1) the filesystem the
descriptor is on is on the qualified list (`apfs`, `ext4`; anything else, tmpfs, ramfs, network and
copy-on-write configurations included, is `storage_unsupported` even if the native call would
succeed); (2) the free space the unprivileged process sees leaves at least 256 MiB after the
request (`f_bavail`, never root-reserved blocks), the check and the allocation being one step under
the volume's coordination so two arenas cannot spend the same observed headroom; (3) the native
allocation, `F_PREALLOCATE` with `F_ALLOCATEALL` on macOS and `fallocate` mode 0 on Linux (never
`posix_fallocate`, never a write loop), whose own count of allocated bytes must equal the request;
(4) the checked file length; (5) the filesystem's own report of allocated bytes covers the whole
length, so a sparse file of the right length fails. The physical overhead (allocated beyond the
length) is reported to the model in `Reservation` and must not exceed the overhead the store
configuration charges; a larger one refuses the open. **A check uses what was obtained, not what was
asked:** the precheck (2) subtracts the requested length, but the allocation may occupy more (an extent
block on ext4), so, after the allocation and under the same volume coordination, the headroom is
verified again with the bytes the file actually gained (its allocated bytes after minus before); if it
is no longer left the reservation is refused (`InsufficientHeadroom` with the available, obtained and
required bytes) and given back, for an open and for a growth.

| Where a size is used | Requested | Obtained | What counts |
| --- | --- | --- | --- |
| Headroom, precheck | the length | | the request (early refusal, kept) |
| Headroom, after the allocation | | the file's allocated bytes after minus before, overhead included | **the obtained bytes** |
| Allocation count | the length | the count the platform reports | the request: a short allocation is refused |
| Allocated coverage | the end of the range | the file's allocated bytes | the obtained bytes (a sparse file fails) |
| Overhead | the model's charge (`cfgOverheadBytes`) | allocated minus the length | an obtained overhead above the model's refuses the open and the growth |
| The volume's reserved figure | | | the length plus a pending extra; overhead is not in it, the model charged it |
| A release | the range [from, to) | the freed extent (overhead included) | the request: the figure never held the overhead |

| Platform | Filesystem | Reservation | Rewrite inside the reservation, volume exhausted (measured, below) | Release |
| --- | --- | --- | --- | --- |
| macOS 26 (arm64) | APFS, 3 GiB disk image | exact (overhead 0) at 64 MiB, 256 MiB, 1 GiB | the backing's allocated bytes 67,108,864 before and after, 0 bytes of the volume's space consumed | Preallocation beyond the end of the file is released only by raising the length and shortening it; the last close reclaimed the space within the first observation |
| Linux 6.8 (aarch64) | ext4, 3 GiB loop image | exact at 64 MiB and 256 MiB; 4,096 bytes over at 1 GiB (an extent block, inside the model overhead) | the same: 67,108,864 before and after, 0 consumed | one block of ext4 bookkeeping stays accounted after a release; the space returned at the last close |

The qualification is a probe, not a claim of universal support; the table is what was run, and the
records, the commands and the run identifiers are in the evidence.

**The probe measures each claim it makes; it does not assume one.** "The volume is exhausted" is the platform's own
statement, not an inference from the fill: the filler (`fillWith`) reserves in halving chunks until the platform answers
its out-of-space result for one block, and **only** that result ends it (`ENOSPC`, errno 28, on both hosts: macOS
`F_PREALLOCATE` with `F_ALLOCATEALL` and Linux `fallocate`; `EIO`, `EINVAL`, `EDQUOT`, an unsupported allocation and a
length that cannot be established all FAIL the example); then ONE more reservation of a single block is asked through
the same adapter and must be refused with that result (`exhaustionVerdict`); the volume's residue is read through the
probe's meter (`fstatfs` on a descriptor opened before anything was allocated), recorded
(`exhausted.available.bytes`) and asserted below 64 MiB, which is the bound the refused growth (a 64 MiB request) relies
on and **not** a proof about a rewrite. The two claims are then measured on their own: "the rewrite needs no NEW
allocation" is the backing's allocated bytes (`fstat`) not growing across the rewrite and still covering the allowance,
and the volume's available bytes not going down by more than the probe's 4 MiB tolerance (`rewriteVerdict`: a decrease
that still covers the allowance passes, because a filesystem may give a metadata block back); "growth is refused under
exhaustion" is the refusal plus the file's length and allocated bytes unchanged (`growthVerdict`). **Observed and not
explained:** after the fill APFS reports 33,681,408 bytes (32.12 MiB) available that a native all-or-none allocation of
one block is refused for (ext4 reports 0); a first version of the probe asserted less than 4 MiB, an invented bound, and
failed on APFS before reaching the service (run `bb26a88a`, in the evidence). No claim rests on the cause. The pure
verdict functions and the routine controls that feed them values are in the suite (the probe's filler class), and the
probe examples themselves run only on a real fixture.

### Failures

Expected failures are values (`StorageFailure`, `failureCode`): `storage_unsupported`,
`reservation_failed`, `storage_io` (a transfer or setup error with its operation, page, file offset
and bytes moved) and `storage_integrity` (a page that decoded with a failure, or a file that ended
inside an expected page: never absent history, empty terrain or regenerated source), and the
refusals made before any work (`invalid_request`, `busy`, a closed or foreign handle). A defect
(an exception that is not a storage result) is `host_failure`: it is recorded, completes its job as
a host failure, stops the service and ends the worker, which supervision sees.

A native allocation the platform answers as unsupported is `storage_unsupported` with the step that was refused
(`NativeUnsupported StepAllocate errno`: the allocation is the only step with an unsupported form, so `ReservationOp` has
that one member; an error from the length or a release is a reservation or I/O failure, never "unsupported"), and the
refusal to start on a runtime that is not threaded is `StartFailure`'s `NotThreaded`. No constructor of these types is
unused.

A transfer advances the checked offset and the buffer by what was moved; an interrupted call is
retried without repeating moved bytes, at most 64 times in a row; a write that makes no progress is
`storage_io` and is not retried; a read that reaches the end of the file inside a page is
`storage_integrity`. Nothing is retried automatically after a failure, and a successful scratch
write or a larger allowance does not clear an integrity failure.

### Scheduling and accounting

Explicit work precedes camera prefetch; maintenance (accepted work and reclamation) is served after
at most three explicit jobs while it waits, camera after at most seven jobs of the other classes.
There is one mutating job (a transaction's write or a growth step) in the session at a time; reads
proceed beside it. Camera reads cannot take the protected 4 MiB of staging. A refusal creates
nothing. The 8 MiB protected allocator allowance of the model stays inside the allowance; the backend
neither enlarges it nor bypasses the model.

Every thing the service holds is charged at what it holds, through one gate each, and every figure is measured against
the live heap (`Test.TerrainRuntime.Storage.Memory`), never reasoned from an encoded size.

**How a row is measured (rewritten in round 5).** The difference of two readings of the live heap (two major
collections each) is a measurement only above a **noise floor**, which the suite measures in the process: two readings with
nothing between them, and two around a change that leaves nothing behind (300 samples each after a discarded warm-up);
1,080 to 1,208 bytes on both hosts (one spike of 8,768 in 60,000 samples on Linux). The first version of these rows
measured a handful of structures in the service and took the least of fifteen samples ("noise only adds"): on the CI
runner (Linux) the difference was negative, in one run the least sample was -6,792, a running write measured -2,184 and
a closing record 0 (a `max 0` clamp), and all of them *passed* as "at most the charge". The rule now:

* **Every asserted row has a signal at least 50 times the floor** (`checkSignal`, printed as `memory signal | row | instances |
  signal | floor`): a structure built **standalone, N at a time**, with N raised until the total added reaches the signal (up
  to 60,000), or a structure that is already large (a transfer buffer, 1 MB; a result, 1.1 MB). The standalone rows rebuild what
  the service holds per element with the constructors the service uses: the job table node, the queue element and the
  admission's own entry for the grant (a job); the backing map's node, the volume ledger's node and the grant's entry (an entry,
  a closing record, **a reporting record**); the list cell and the grant (a kept failure). The built value is held live across
  the second reading through a cell (an evaluated thunk drops what it was built from: a closure over a structure measured
  zero, and the rule caught it).
* **No row passes vacuously**: a measured value of zero or below fails (`max 0` and the least-of-N are gone), and a signal below
  the multiple fails; both are shown on values (`rulesSpec`).
* **The service itself is held against the model** where its own bounds give the signal: K = 24 finished, **untaken** write
  reports held at once, produced by real jobs, the test's own pages and the harness's log of native calls dropped before the
  second reading; asserted at most the charge and within 15 percent of the standalone row for the same structure, for the
  all-written and the first-page-failed variants. A service-level reading that cannot reach the signal (eight queued records,
  one backing, a running write) is **printed as an observation and never asserted**.

| Held thing | Charged to, and when | Figure | Standalone row, 200 repeats, both hosts (minimum to maximum) | In the service, held at once |
| --- | --- | --- | --- | --- |
| A job record (queued, running or finished), per ticket | control, from submission to retirement (`admitJob`, `jobCharge`, kept as `jCharge`) | `jobRecordBytes` 4,096 | a queued read 537 to 538; a queued open, a 512-byte path of its own, 1,118 to 1,137; with the largest retained outcome: `Opened` 1,255 to 1,276, `GrowthPrepared` 1,280 to 1,300, `Released` or `GrowthNoChange` 1,142 to 1,163, `Cancelled` with 4 notes 1,353 to 1,373, `Failed` (a 256 four-byte-character text, 4 notes) 2,452 to 2,472 | an observation only |
| A write's report | control, at admission, with the record: `writeEntryBytes` 112 a staged page and `writeFailureBytes` 512 for the one failure | 29,184 + 4,096 at 256 pages: 33,280 | the report of 256 pages written 16,496 to 16,501; with its first page failed 16,649 to 16,654; a queued write job 322 to 481; a running write (record and 255 results) 16,611 to 16,616 | **24 finished untaken reports: 15,410 to 16,739 a job (all written), 15,684 to 17,786 (first page failed)**, at most 17,136 modelled (ratio 0.91 to 1.04) |
| A read's transfer buffer while it runs | staging (camera work the unprotected share only), at dispatch (`dispatchNext`) | `transferBufferBytes n` | n/a: 1 MB, above the floor in the service | two held 256-page reads, per read with its record: 1,055,868 to 1,067,300 of 1,089,536 |
| A read's result until it is taken or discarded | cache, pinned, at dispatch | `resultPageBytes` 4,864 a page | n/a | a finished, untaken 256-page result with its record: 1,077,816 to 1,132,048 of 1,249,280 |
| A backing's record (per arena) | control, from the open's success to `endClosing` (`register`, then the closing record) | `backingRecordBytes` 4,096 | the entry at its largest variant (`GReleasing (Just prepared)`, a pending reservation) with its backing-map node, its volume-ledger node and its grant's entry 388 to 505 | an observation only (one backing is below the floor) |
| A closing record | control, the same grant | `backingRecordBytes` 4,096 | native close pending (the entry moved, per backing) 402 to 502; **reporting (the carried grant, per record) 217 to 275** | the pressure example (below) |
| A kept failure (a cleanup nobody received, or a close that failed) | control, while kept | `keptEntryBytes` 2,048 | the largest instance, a close that RAISED with a 256-character text of four-byte characters, with its list cell and its grant's entry: 1,517 (constant) | 64 asserted kept |
| A write's pages | nothing while the job is queued or running: the transaction's own, already accounted in its reservation, referenced and never copied; **nothing once the job has finished** (`scrubWork`) | n/a | n/a | the finished-report row above |

Two figures moved or were corrected in round 5. `keptEntryBytes` is **2,048** (it was 320, then 1,536): the largest instance now
includes the admission's entry for the grant (1,517 where 1,326 left it out), which would have been 1.2 percent under 1,536. The
write report's standalone row is **16.5 KB, not 20.6 KB**: the old model was itself lazy (a page-number thunk per entry) and
overstated; the standalone instances now go through the same `forceOutcome` the service applies.

**The old running-write reading, explained.** The first rows read a running write held at its last page at 25 to 29 KB in the
service where the standalone model says 16.6 KB. The difference of the same job held at its last page and at its first page is
24,496 bytes; the harness's own log of the 255 native writes (the probe records every call) is 12,361 of them (measured as a
standalone value), and the rest, 12,135, is the 255 results at 48 bytes each (a cons cell and a pair: while the job runs the
results share the page number with the owner's staged page; the model's 64 bytes include the page-number box a *retained* report
owns once the transaction has ended, so it is the right figure for the retained report). **The same state read twenty times is
stable in 191 of 200 repeats (12,984) and steps by 31.5 to 31.9 KB to 44.5 to 44.9 KB in 9 repeats on macOS and 3 on Linux: one
32 KiB stack chunk of the worker.** That step is what made the in-service differences negative on the CI runner: a blocked
worker's stack is present in one reading and not the other. The running-write reading is therefore an observation, and its bound is
carried by the standalone row and by the finished report against the 33,280 charge. The Linux validation host (the Lima guest) is
**aarch64**; the CI runner is **x86_64**: the failure of the old rows reproduced on the guest, but the x86_64 figures were not
measured here.

A read's buffer and its result are two physical copies at the moment of completion, so both are
charged from dispatch. A job whose dispatch would need an **eviction** is not dispatched: `A.reserve`
may choose to evict backed, unpinned copies, and those copies belong to the terrain owner's caches, so
the service never takes that choice. The job stays queued, and the owner sees it:
`ServiceView.svWaitingForCache` counts the queued jobs refused for want of an eviction. **The owner
must drop (release) backed, unpinned cached copies when it is greater than zero**; the job runs the
next time the dispatch fits, and nothing else is signalled or retried.

The **volume ledger** (`svReserved`, per volume) has one definition: a backing contributes its file's
length plus any extra reservation still pending (`backingContribution`), the open adds it, a prepared
growth adds its extra, an abandon or a successful release subtracts the extra **after its set-length
has returned**, and a close subtracts exactly the backing's contribution **after its native close has
returned** (the closing record holds it until then); once every backing is closed every volume's figure
is zero. The
suite asserts both ledgers, the admission's and the volume's, after every sweep case, every close and
every random sequence.

### Growth

`submitGrowth` executes a growth the model proposed, against the committed allowance. Sizes are
validated here again (the minimum, the 1 MiB grid, the native offset limit) before any native work. An
**equal size is an idempotent no-op** (`GrowthNoChange`: nothing reserved, nothing changed); a smaller
size is refused. It reserves the extra range under the same proof and answers a `PreparedGrowth`,
which carries the service's identity and a fresh identity of this preparation, so a token of another
service, or of an earlier, abandoned or committed preparation, is refused. A prepared growth is **not
spendable**: a request naming the larger allowance is refused until the owner commits the model's
growth and then `commitBackingGrowth`. Old contents and the old allowance are authoritative throughout.

Every event is one transaction on the backing's growth slot; this is the table (the comment on
`GrowthSlot` in `Service.hs` is its source):

| State | submit growth | prepare finishes | cancel | commit p | abandon p | release finishes / fails | close |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `GIdle` | to `GRunning`, in the admission's transaction | n/a | n/a | refused | refused | n/a | closes |
| `GRunning` | refused (busy) | one transaction checks cancellation: published as `GPrepared`, or cancelled: the extra is released (a failed release leaves a charged pending record) and the slot is idle | the job stops at its next safe point and the same arbitration decides | refused | refused | n/a | waits for the job |
| `GPrepared p` | refused (busy) | n/a | n/a | the token must match: `GIdle` and the cap rises | to `GReleasing`, in the admission's transaction: the commit authority is gone from then on | n/a | released with the file |
| `GReleasing` | refused (busy) | n/a | not applicable | refused | refused | `GIdle`; a failed release is `GIdle` with the extra pending and charged | waits for the job |

A queued growth, abandonment or pending release that leaves the queue (a cancel, a discard, the closing of admission, the close of its backing) goes through the one withdrawal, which reverses what its admission installed (`GRunning` back to `GIdle`; `GReleasing (Just p)` back to `GPrepared p` with the token valid; `GReleasing Nothing` back to pending), so a cancelled queued job never leaves the slot stuck. An undelivered `GrowthPrepared` outcome that is discarded, or whose delivery failed (the callback raised or was cancelled and no other borrower received it), becomes a pending reservation `submitReleasePending` recovers.

A release that fails keeps a bounded **pending reservation**, charged on the volume and blocking
another growth, until `submitReleasePending` succeeds or the close releases it with the file.

### Ownership at every instant, exceptions included

A typed failure is not the only way out. Rounds 2, 3, 4 and 5 of review found one class under nineteen findings:
*an exit, a release or a failure taken between a state change and the bookkeeping that completes it*. Each
exit of a thing the service holds now has **one mechanism that owns it**, and every table below enumerates
every member of its class (the ones generated from code are marked, and the suite fails to compile when a
member is added without a row).

**1. One withdrawal for a queued job** (`withdrawQueued`, `undoAdmission`). A queued job leaves the queue by
this one transaction whatever sends it away (`cancelTicket`, `discardTicket`, the closing of admission, the
close of its backing). It dequeues, reverses what admission of that kind installed (a growth gives its slot
back, an abandonment returns to `GPrepared` with its token valid, a pending release returns to pending), and
settles the job as cancelled. The case is total over the work kinds.

**2. One disposal for an outcome nobody received** (`disposeUndelivered`, total over every `Outcome`
constructor, no wildcard). A discard of a finished job, the end of a discarded running job, the close of the
backing a job names, the shutdown sweep and a **failed delivery** all call it: `Opened` closes the backing it
created; `GrowthPrepared` becomes an explicit pending reservation `submitReleasePending` recovers, the volume
figure unchanged; `Failed` and `Cancelled` keep their cleanup notes as evidence; `Pages` releases the cache
charge; the others own nothing.

**3. A charge ends when what it pays for is gone.** A backing claimed for close MOVES whole into a closing
record (`stClosingRecs`): its grant, its volume contribution, its pending reservation and its descriptor, and
nothing is released by the claim. One transaction after the native close has returned (`finishClosing`)
subtracts the reservation and keeps a failing close, and the record (reporting) CARRIES the grant until the
transaction that deletes it (`endClosing`) releases it; the drain joins the records. The same
question was asked of every other release (below) and none releases before the native call that frees the
thing has returned. The table is `Lifecycle.chargeRow` (total over `ChargeKind`) and the suite holds each
native call and asserts both ledgers *during* it:

| Charge | What it pays for | The one release site | Why the thing is gone there |
| --- | --- | --- | --- |
| JobRecord | the job's record (and a write's report metadata) | retireJob, after the outcome is taken or disposed of | the record is deleted in the same transaction; no native thing is behind it |
| DispatchStaging | a read's transfer buffer | finishJob, when the job ends | execute has returned: the native read is over and the buffer is released |
| ResultBytes | a finished read's result copy (cache, pinned) | retireJob | the bytes are dropped with the record when the outcome is taken or discarded |
| BackingRecord | a backing's entry, descriptor and file | endClosing, the one transaction that deletes the closing record, after the native close has returned and the close's diagnostics are done | the descriptor is closed and nothing of the close is left: the closing record, reporting or not, carried the grant until then |
| VolumeReserved | the file's length and any pending extra on the volume | finishClosing (a close), execRelease (a release) | the native close, or the release's set-length, has returned |
| PendingReservation | an extra range a failed release left allocated | execRelease on success, finishClosing | the retried release's set-length has returned |
| GrowthExtra | an abandoned or failed growth's extra range | execRelease and giveBack on success | the set-length that frees it has returned: until then the extra stays counted |

**4. Every cleanup step runs independently**, whatever the step before it did; an exception from a step is a
cleanup failure of that step and never an exit that skips the next:

| Scope | Steps, each attempted whatever the others do | What an exception from a step becomes |
| --- | --- | --- |
| `execOpen` unwind | unlink retry; the one close of the descriptor (recorded as attempted before it is made) | a cleanup note of the step (errno -1); the close is never repeated |
| `giveBack` (a growth that did not publish) | the release of the extra range | a release that failed: the extra stays pending and charged |
| `execRelease` | the release | the same; the exception propagates with its context after the pending record is made |
| `closeBackingCore` | the claim (the entry moves into the closing record, `CrNative`); the one native close; `finishClosing` (ONE transaction: subtract the volume reservation, carry the grant on the reporting record, KEEP a failing close, mark the record `CrReporting`); three diagnostics; `endClosing` (ONE transaction deleting the record) | the close's exception is recorded, never retried, and kept like any failure; `finishClosing` precedes the diagnostics, and the record outlives them |
| `drainService` | closing admission; stopping the workers; joining them; closing every backing; joining the closing records (and saying so before it waits); disposing of every record; the SEAL (one transaction: every closing record has ended, the kept failures are read and their charges released, the phase becomes `Sealed`); composing the evidence | each wait is in the protected boundary; a cancellation is remembered (first wins) and delivered after the drain |
| start sequence | stop every started worker; join every started worker | a cancellation of either is remembered; the primary failure propagates |

**5. Every catch keeps its context.** The complete list of sites that catch an exception:

| Site | What happens to the exception |
| --- | --- |
| `withStorageService` (the body) | composed with the drain's cleanup evidence and rethrown with its context |
| `startWorkers` | the abort sequence runs, then rethrown with its context; the fresh throws (`NotThreaded`, `WorkerNotStarted`) have no cause to keep |
| `workerLoop` | anything out of the loop runs the one `stopService`, then is rethrown with its context |
| `quietly` | a diagnostic: a synchronous exception is dropped, an asynchronous one is returned to the caller |
| `evidenceOf`, `protectedly` | evidence carries the context of what it describes; an asynchronous exception is remembered and delivered after the wait, any other is rethrown |
| `withOutcome`, `withUse` | the borrow is released, the delivery counted (delivered or failed), then rethrown with its context |
| `runJob` | a defect finishes the job as a host failure (text bounded), stops the service, then rethrows; remembered cancellations of the close and the log are rethrown after the job finished |
| `execOpen` and its steps | an exception closes the descriptor once, unlinks again, and is rethrown composed with the cleanup failures |
| `execGrow` | the extra range is rolled back or left pending, then rethrown composed with the cleanup failures |
| `giveBack`, `execRelease` | a release that raised is a release that failed: kept as a pending reservation; `giveBack` keeps a cleanup note (errno -1) and not the exception itself |
| `closeBackingCore` (native close) | recorded as the close's exception in the report; never retried |
| `closeBackingId`, `closeUnwaited` | a remembered cancellation is delivered after the record has ended; the failing close was already kept inside `closeBackingCore`, so neither keeps anything itself |
| `Volume.linuxFilesystemName` | a failed read of the mount table is an unnamed filesystem, which is never qualified: a deliberate conversion to a typed result, not a rethrow |

**6. No failure without a keeper** (`keepEvidence`, the one keeper). Every cleanup note and every failed close has
exactly one keeper, and a failed close's is **always the service**: `closeBackingCore` keeps it inside the transaction
that releases the close's charges (`finishClosing`), whoever asked for the close. The `CloseReport` a caller receives
is a **copy**: receiving it does not discharge the failure, and a failed close always ends the service's scope with its
labelled typed failure (`BackingCloseFailed backing errno`, or `BackingCloseRaised backing text` for a close that raised,
the text bounded by `maxHostFailureChars`). The service's evidence holds at most 64 failures, charges each `keptEntryBytes`,
**counts** one that does not fit (or whose charge is refused) and reports the count at the end as one more labelled
failure; every kept entry is evaluated when it is kept. Every site that closes a backing, and every discarded result
that can carry a failure:

| Call site | What it can carry | Keeper |
| --- | --- | --- |
| `closeBackingCore`, for every close: `closeBacking` (public, through `closeBackingId`), `discardTicket` of a finished `Opened`, `runJob` after `finishJob`, a failed delivery of an `Opened`, and the drain | the failing close, typed (`KeptClose`) | the service, inside the core: `finishClosing` keeps it in the same transaction that releases the close's charges and marks the record; the caller's `CloseReport` is a copy |
| `disposeUndelivered` of `Failed` or `Cancelled` | cleanup notes | `keepEvidence` |
| `withdrawQueued`, `finishJob` of `Cancelled []` | nothing (no notes) | none needed |
| `runJob` defect, `finishJob` of `Failed HostFailure` | the defect's bounded text (a copy) | the outcome, `stDefect` and the rethrown exception |
| `startWorkers` abort, `protectedly` waits | a remembered cancellation | subsumed by the primary failure that is rethrown |
| `drainService` waits | a remembered cancellation | the late value delivered after the drain |
| `closeBackingCore`'s claim, `disposeUndelivered` | the `Opened` of the backing being closed | the close itself (no second close) |
| `quietly` | a log's cancellation | folded into the caller's remembered one |
| `keepEvidence` on a sealed service | (nothing may be kept after the seal) | a defect: `SealedMutation` is thrown, nothing is kept or charged |

**7. A delivery has three ends.** *Delivered*: a `withOutcome` callback returned normally, the caller owns what
the outcome carries (a token, an opened backing), the record is retired. *Failed*: the callback raised or was
cancelled and no borrower received it: nobody owns it, and it goes through the one disposal (a preparation
becomes a pending reservation, an opened backing is closed with its report kept, notes go to the evidence).
*Undelivered*: the discard. A nested take that raises while another borrower holds the outcome disposes of
nothing; the borrower's delivery stands. For an `Opened` outcome a failed delivery **closes** the backing:
nobody can name it, so leaving it open until shutdown would be a descriptor and a volume charge nobody can
reach. A cancellation delivered after the callback returned is counted as a failed delivery (the caller sees
the exception).

**8. One worker exit** (`stopService`). The worker's loop is masked with **no unmasked region** around the
dispatch: under `mask`, `atomically` is interruptible exactly while it is blocked in a retry, so the wait for
work or for the stop can still be cancelled, and a transaction that committed (the job is running) is always
followed by `runJob`. Every exit but the stop token runs `stopService` (admission closed, queued work settled,
the reason recorded) and then propagates. Of the other restore sites, `withStorageService`'s body, `withOutcome`'s
callback and `withUse`'s action, nothing is committed inside the unmasked region (a borrow is committed before
and released after, both masked). The suite enumerates the exit points (`ExitPoint`) with the service kept
running: a later submission is refused with `ServiceStopped`, work queued before settles, the other worker's
held job finishes, and the invariants hold (admission open implies both workers alive, running jobs do not
exceed workers alive):

| Exit point | How it is reached | Asserted after it |
| --- | --- | --- |
| the diagnostic after a finished job | a sink that cancels the "Backing opened" log | stop reason recorded and admission closed (observed); typed refusal; queued work settled; the other worker's held read finished; service ends normally |
| the dispatch wait | `throwTo` the worker threads the seam noted at start | the same |
| a defect in a job | an injected exception in a read | the same |

Not a row: the cancellation window between the dispatch commit and the return of the (now removed) unmasked
region, and a remembered cancellation out of an unwaited close inside `runJob`: there is no seam or gate to
hook (the first is closed by structure and the invariant, the second runs the same function as the closes the
examples hold).

**9. A diagnostic is never an exit.** Every log call goes through `quietly`: a synchronous exception from a
logger is dropped, an *asynchronous* one reaching a log (a cancellation at the interruptible point of a sink
that blocks) is **returned** to the caller, which finishes its bookkeeping and delivers it after. **Policy,
reversed in round 3:** a worker that ends at any point, a cancellation at the "Backing opened" log included,
**stops the service** (the one stop above): a `Logger` is a public port, so a cancellation at the log is
reachable through the public API.

**10. Why a backing's descriptor is owned by a table (requirement 7), and the lexical final owner.**
[`docs/resources.md`](../../docs/resources.md) makes every lifetime lexical except two collections, and both are
single-operation structures: the thread-owned collection refuses every thread but its owner
(`NotOwnerThread`) and does not support concurrent member operations, the capability-owned collection is
"not a concurrent data structure" and refuses a second thread, and both answer `RetirementInUse` for a
borrowed member and never wait. This backend needs two workers inside native calls on the same descriptor at
once and a close that **waits** for its running calls and borrowers with no deadline, so neither collection
can own a backing's descriptor. `withStorageService` is the lexical final owner: it starts the two workers in
the caller's group (`allocResource`), runs the body, and, in its protected final step, closes admission, stops and
joins the workers, closes every backing, joins the closes in flight, disposes of every record and composes the
failures with `composeCleanup`; nothing outlives it. The guarantees of the failure table and the mask
discipline, each with its proof:

| Guarantee | Mechanism | Example |
| --- | --- | --- |
| Closed exactly once | the claim removes the entry and the close is recorded as attempted before it is made | Lifetime "never closes twice... descriptor number reused"; the sweep's close rows; the matrix's Close cells; control: a failed close retried |
| The close is a bounded call made uninterruptibly | `uninterruptibleMask_` around the one native call, the hand-off masked | the sweep's close row with a cancellation injected while the closing thread waits for a held call |
| The wait is outside any masked release, interruptions remembered | `protectedly` in the caller's boundary | "joins a close another caller claimed" (the drain observed blocked, no timer); "still waits for a close in flight when a cancellation reaches the log of that wait" |
| The primary failure and the labelled cleanup failures are composed | `composeCleanup`, `cleanupFailuresInContext` | Lifetime "keeps the primary failure and the cleanup failure of a close, and a defect stops the service"; "attempts the descriptor's close even when the unlink cleanup throws (twice)"; the cleanup-exception cells |
| Nothing is dropped | the one keeper, counted drops | the keeper examples (a discarded open whose close fails; a close with a cancellation instead of its report; 64 kept and the rest counted; a close that RAISED keeps its typed identity) |
| A failed close always ends the scope with its typed failure | `finishClosing` keeps it inside the core; the report is a copy | Lifetime "never closes twice" and the sweep's close rows end with the labelled failure; the discard and `closeBacking` examples with a cancellation pending during a held failing close; "keeps a close that RAISED as its own typed failure" |
| The service cannot end, nor its logger be used, while a close is in its diagnostics, and the records a held logger can leave are bounded | the closing record lives through them (`CrReporting`) CARRYING the grant; the drain and the seal join it | "keeps a close tracked through its post-native diagnostics" (the diagnostic held, the drain observed waiting by its own log, then released); "charges a closing record for as long as it lives" (repeated open, take and close against a held logger meets pressure) |
| Nothing commits to a service after its scope ended | the seal transaction and `SealedMutation` | the sealed-service example over every public mutator (the table in item 14) |

**11. A real failure of `close` cannot be induced, and the policy that follows.** On the two qualified
filesystems a `close` of a regular file does not fail in practice (no network or delayed-write filesystem is
qualified), so only an injected `EIO` and an exception after the call are exercised; the exact limitation is
kept and the decision is the owner's. What the platforms document: Linux `close(2)` documents that an error
can be reported after the descriptor has been released and that retrying is the wrong thing to do, since it
may close a descriptor another thread has been given (the issue quotes this and forbids generalising it to an
unqualified native path); the macOS `close(2)` behaviour was not qualified here and nothing was observed.
**The policy is the same on both and does not depend on what they document: the close is made once, a failure
or an exception from it is kept and reported, and it is never retried** (nor is an `EINTR`: the close is a
bounded call made uninterruptibly).

**12. An effect is owned before its after-hook runs** (`around`, `Owns`; round 4, finding 1). A native effect runs
through ONE function, `around seam op owns act`: the before-hook, the effect, **the recorder of what the effect
obtained**, and only then the after-hook. `Owns a = NothingAcquired | Acquires (a → IO ())` makes every site say what
it acquires. For an `Acquires` site the effect and its recorder run together under `mask_` **inside `around`**: a
`safe` foreign call is not interruptible, so the mask delays nothing, and `around` does not depend on its caller
being masked (the worker is, by `workerLoop`; the probe and the fixture call `createPrivate` unmasked); the hooks stay
outside the mask, where a cancellation can reach a blocked one. The mask is structure, not an example: the window it
closes is between two instructions, with no seam and no gate to hook (stated in the evidence's honest list). Every
`around` site, with what it acquired or released and who owns it when the after-hook raises:

| Site, native op | What the call acquired or released | Who owns it if the after-hook raises | Example |
| --- | --- | --- | --- |
| `createPrivate`, `OpCreateFile` | a descriptor and a name (**acquired**) | the recorder, run before the hook: `execOpen`'s reference to the created file; its handler unwinds (one close, the unlink retried) whatever the hook did | the sweep, open/create after the effect (thrown, asynchronous); "a worker blocked in the after-hook of a create, cancelled while blocked, leaves no descriptor and no name" |
| `unlinkFile`, `OpUnlinkFile` | releases the name | a lost `Right ()` is an exception; the unwind retries the unlink (ENOENT on the retry is success) | the sweep, open/unlink, after the effect |
| `verifyPrivate`, `OpCloexecFlag`, `OpStatFile` | nothing | n/a: the open unwinds as for any failure | the sweep, open/cloexec and stat (verify private) |
| `reserveRange`, `OpReserveRange` | allocated space (the extra range) | the descriptor's file: an open closes its descriptor, a growth's `giveBack` rolls the extra back on any exception | the sweep, open/reserve and grow/reserve, after the effect |
| `reserveRange`, `OpSetFileLength` (establish) | the length | the same | the sweep, set length rows |
| `reserveRange`, `OpStatFile` (verify) | nothing | n/a | the sweep, stat rows |
| `releaseExtra`, `OpStatFile` and `OpSetFileLength` (up, down) | frees space | a lost result is a release that FAILED: the extra stays a pending reservation, accounted (never less than physical) | the sweep, grow/set length (rollback) and release rows: "reported covers physical, and a larger figure is a pending reservation" |
| `readFully`, `OpReadAt` | bytes in the transfer buffer | nothing to release; the job fails as a defect (`runJob`) and the service stops | the sweep, read |
| `writeFully`, `OpWriteAt` | bytes in the file (nothing to release) | the same | the sweep, write |
| `closeFile`, `OpCloseFile` | releases the descriptor | recorded as RAISED, never repeated; `closeBackingCore` keeps it (item 13); one native close is asserted | the sweep, close and the cleanup-close rows, after the effect |
| `Volume.profileOf`, `OpStatFile`, `OpStatFilesystem` | nothing | n/a | the sweep, stat (profile) and statfs |
| `Service`: `OpWorkerStart`, `OpWorkerStop`, `OpVolumeWait` | before-hooks only (`seamBefore`; no after-hook) | nothing is acquired before them | the startup rows; "still waits for a close in flight" |

The ownership sweep has an **after dimension**: each of its 21 native calls at its stage is injected five ways (a typed
failure, a thrown exception, a cancellation, and, **after the effect has happened**, a thrown exception and an
asynchronous-typed one) = **105 cases**, each ending with the descriptors and names gone, the tracked backings equal to
the open descriptors, both ledgers and the volume figure right, the invariants holding, and (for a close) exactly one
native close made. The sweep found one real state: after a rollback's set-length happened and its after-hook raised,
the result is lost, so the service keeps the extra as a pending reservation although the file is already freed: an
**over-count, never an under-count**, recoverable by an explicit release (the sweep asserts the figure covers what is
physical, and that a larger one is a pending reservation).

**13. The close core owns everything until it returns, and a record is charged for as long as it lives**
(`closeBackingCore`; round 4 finding 2, reversed in part by round 5). In order, masked end to end: the claim moves the entry
whole into `stClosingRecs` as `CrNative` (every charge stays paid); the **one** native close (uninterruptible, its hooks
inside); ONE transaction, `finishClosing`, subtracts the volume reservation (the space is free; the node leaves the ledger at
zero), **keeps a failing close in the evidence** and marks the record `CrReporting`, **which carries the backing's control
grant**; the diagnostics, through `quietly`; ONE transaction, `endClosing`, releases that grant and deletes the record;
return. **Round 4 had released the grant at `finishClosing` ("a reporting record no longer pays"): that was wrong.** With a
logger held on the log "Backing closed", a caller could open, take and close again and again: each native close freed its
credits for the next open and left one more uncharged reporting record and blocked close behind, bounded by nothing. The
records are now bounded by the control account like every other record: a held logger meets pressure (a typed
`BusyNow (AccountPressure _)` for the next open), asserted by a test that narrows the account to three backing records,
holds the log, repeats open, take and close until the refusal, and checks the account and the invariants at every step. Shutdown joins the records
in its explicit wait and again in the seal, so the service cannot end, and its logger cannot be used after its scope,
while a close is in its diagnostics. The keeping is inside the core (item 6): a failed close always ends the service's
scope with its typed failure, whoever asked, and the `CloseReport` a caller receives is a copy. `discardTicket` is masked
end to end too (it was the one public function that was not).

**14. The service seals** (`Phase = Running | Closing | Stopped | Sealed`; round 4, finding 4(iii)). The last
transaction of the drain waits for every closing record to end, reads the kept failures, releases their charges, clears
them and sets `Sealed`; `closeAdmission` keeps a sealed service sealed (it could have downgraded it). After it nothing
can commit to the service or charge it: every public mutator, on a drained service whose handle escaped, is asserted
(table generated from the example's own rows) to refuse or find nothing, to leave the snapshot unchanged (compared whole)
and the admission ledger at zero:

| Function | On a sealed service |
| --- | --- |
| `submitOpen` | refused: ServiceStopped |
| `submitRead` | refused: BackingClosed (the backing is gone) |
| `submitWrite` | refused: BackingClosed |
| `submitGrowth` | refused: BackingClosed |
| `submitAbandon` | refused: BackingClosed |
| `submitReleasePending` | refused: BackingClosed |
| `commitBackingGrowth` | refused: BackingClosed |
| `withUse` | refused: BackingClosed, the action never runs |
| `withOutcome` | answers Nothing: the ticket names nothing, the callback never runs |
| `discardTicket` | finds nothing: no effect |
| `cancelTicket` | answers CancelUnknown |
| `closeBacking` | finds no backing: nothing closed, no native call |
| `keepEvidence` | a defect: SealedMutation is thrown, nothing is kept or charged |

The borrow releases of `withOutcome` and `withUse` and `finishDelivery` cannot run after the drain (it waits for
borrowers), so the entry points above are the complete set.

**15. Public functions: masking, and every effect-then-record pair** (round 4, finding 4(i)):

| Function | Masked? | Effect-then-record pairs | Unmasked point between them |
| --- | --- | --- | --- |
| `withStorageService` | workers started under `mask`, body unmasked, the drain masked | workers started then counted in `startWorkers`'s own handler | none |
| `submitOpen`, `submitRead`, `submitWrite`, `submitGrowth`, `submitAbandon`, `submitReleasePending`, `commitBackingGrowth`, `cancelTicket` | one STM transaction each | none (the effect is the record) | none |
| `awaitTicket`, `pollTicket`, `backingView`, `serviceView`, `snapshotOf` | STM reads | none | none |
| `withOutcome` | `mask`: the borrow committed in one transaction, the body unmasked, release and `finishDelivery` in one transaction, the disposal's close masked | the borrow, then the release | none unmasked between an effect and its record |
| `withUse` | the same | the same | none |
| `discardTicket` | **`mask_` end to end (it was unmasked between the transaction that retires the record and the close of the backing nobody can name: found in round 4)** | the retiring transaction, then the close | none |
| `closeBacking` | `closeBackingCore` is `mask_` end to end; the late cancellation is rethrown only after the record ended | the claim, the close, the keeping, the record's end | none |

**16. Every log call** (round 4, finding 4(ii)): seven sites, all through `quietly`, none able to be an exit.

| Log | Thread | What makes shutdown wait for it |
| --- | --- | --- |
| "Drain waits for closes in flight" | the drain's own | it is the drain |
| "Backing close failed", "Backing close raised", "Backing closed" | the closing caller (a caller, a worker or the drain) | the closing record stays `CrReporting` until `endClosing`; the drain and the seal join it |
| "Backing opened", "Storage worker defect", "Open cleanup step raised" | worker threads | the drain joins the workers |

No log runs on a caller's thread outside a tracked record.

**17. Hooks that can block, not only raise** (round 4, finding 4(iv)): a before-hook gate was covered (a cancellation
delivered while blocked: the effect has not happened). An after-hook gate: "a worker blocked in the after-hook of a
create, cancelled while blocked" (observed blocked after the create succeeded, `throwTo`, then no descriptor, no name,
the job finished as a failure, the service stopped, the invariants hold). The close's hooks run inside its
`uninterruptibleMask_` by design: a blocked hook holds the bounded close and a cancellation is **pending until it
returns**; the examples hold exactly that (a failing native close held, a cancellation pending, the close returning its
error, the cancellation delivered after, the failure kept and the record gone).

**18. The service retains only evaluated values** (`forceOutcome`, `scrubWork`, `forceSpine`; round 5). A thunk is a hidden
reference to what it was built from, and a record that keeps one keeps all of it, uncharged. The round 4 write report was the
instance: `execWrite` ended a failed or cancelled write with `reverse acc <> [(q, NotAttempted) | (q, _) <- (p, bytes) : rest]`,
and a strict field forces only the first cell, so the finished job retained a thunk that held `rest`, **the staged pages with
their bytes** (about 1 MiB a job, measured: 1,034,851 bytes a job with 24 held untaken), for as long as the outcome was untaken
and after the transaction that owned those buffers had ended. Looking for it found a second retention: the finished job's own
work (`WWrite sw`) kept the staged pages (1,050,673 bytes a job), and a first scrub that replaced the bytes still kept a 256-cell
list of pairs (12 KB a job). Now: `finishJob` stores an outcome only after a total walk of it (`forceOutcome`: every list to its
end and each element, the pages of a read, the report's pages and results, the notes, a failure through its derived `Show`,
which reaches the `Maybe` contents and `String`s the strict fields do not), `execWrite` builds its report completely, a finished
job drops its work to its shape (`scrubWork`: no pages, no list; the record keeps what it paid as the number `jCharge`).
Every other retained record, the fields that could hold a thunk and what forces them:

| Record | Fields that could hold a thunk | What forces them |
| --- | --- | --- |
| a job at admission | `jBacking` (it was `Just` of a lazy selection of the id from the `Backing`); the work (the staged pages are the owner's list, shared) | `jBacking` is forced; the owner's list is shared and is dropped at finish |
| a finished job | the outcome; the work | `forceOutcome`, in the strict `jPhase` that the strict map insert evaluates inside the transaction; `scrubWork` |
| a backing's entry | `ePending` (`Just (to - from)`, built lazily at three sites: growth commit, abandon, rollback) | forced at each site; every other field is a strict scalar or record, and the growth slot's `PreparedGrowth` is strict |
| a kept failure | the evidence list's spine (a lazy `<>` chain); the close's text | `forceSpine`; an evaluated copy forced when kept |
| a closing record | none | `CrNative !Entry`, `CrReporting !Grant` |
| the stop reason, the defect text | the text | evaluated copies (`T.copy`) forced when stored |
| the shared admission | not this module's | not changed |

The measurement that found it is a test, not a reading: the standalone model of the report, **validated against real jobs held
untaken** (the row table above), with two controls: the outcome not walked and the report built lazily makes the first-page-failed
row read 1,034,851 bytes a job and fail, and a finished write that keeps its pages makes the all-written row read 1,050,673 and fail.
The validation found three flaws in the test itself, each of which would have hidden the finding: the standalone model was lazy
(it overstated by 4 KB), `bigWrite` took no argument so the compiler floated its page list out as ONE shared constant (every write
shared the same pages), and the harness's log of native calls keeps 256 entries a write (the test's memory, not the service's).

**19. Every container the service holds is bounded and charged, and so is every thread it can be asked to hold** (round 5).
Each container and counter of the service's state, what bounds it, what pays for each element, where the charge is taken and
released, and the proof (the invariant checker asserts the bound at every checkpoint of the matrix, the sweep, the property, the
exits and shutdown):

| Container | Bounded by | Charge per element | Taken by | Released by | No element outlives its charge: |
| --- | --- | --- | --- | --- | --- |
| jobs | `maxJobRecords` (32) and the control account | `jobCharge` in `jControl` (4,096; a write adds its report metadata) | `admitJob`, with the insertion | `retireJob`, with the deletion | the control equation (the sum of the records' charges) |
| queue | `maxQueuedJobs` (8); its elements are live jobs' ids | inside the job's record | `admitJob` | `withdrawQueued`, `dispatchNext` | queued <= 8 and equals the queued jobs |
| backings | the control account | `backingRecordBytes` in `eGrant` | the open's registering transaction | not at the close claim (the entry MOVES); `endClosing` | the control equation |
| closing records, native | the same account | the same grant | the claim (the move) | `endClosing` | the control equation; the descriptor bounds |
| closing records, **reporting** | the same account | **the same grant, carried** | `finishClosing` | **`endClosing`, with the deletion** | the control equation; the pressure example |
| evidence | `maxKept` (64), drops counted | `keptEntryBytes` in the `Kept` | `keepEvidence`, with the insertion | the seal transaction | evidence <= 64; the equation; the sealed example |
| the volume ledger | one node per volume with a contribution | inside `backingRecordBytes` (a node per backing, conservatively) | the open's registration | `subReserved`: **the node leaves the map at zero** | no node at zero (round 5 found one that stayed after the last close); the reserved-figure equation |
| busy volumes | one per worker (2) | none: at most the two workers | `withVolume`'s acquire | its bracket | busy <= workers |
| counters and words (`stNextJob`, `stNextBacking`, `svNames`, `stFair`, `stRunning`, `stWorkers`, `stMutation`, `stEvidenceDropped`) | one machine word each | none | n/a | n/a | not collections |
| `stDefect`, `stStopReason` | one bounded text each (an evaluated copy), per service | none: a constant of the service | the first reason, the latest defect | the service's end | one value |

The dual: every place a thread of a caller or a worker can be held by something the service does not control (a logger sink, a
seam hook, a callback body), the record that exists while it is held, and what that record is charged:

| A thread held in | The record while it is held | Charged |
| --- | --- | --- |
| a log sink after the native close (a closing caller: `closeBacking`, `discardTicket`, `runJob`'s discarded open, a failed delivery, the drain) | the reporting closing record | `backingRecordBytes`, carried (it was **uncharged** in round 4: the finding) |
| a seam hook inside the native close | the native closing record | `backingRecordBytes` |
| the claim, waiting for jobs and borrowers | the entry in the backing map (closing); the waiter is a blocked retry with no record | `backingRecordBytes` |
| a worker in a seam hook inside a job's native call | the running job | `jobCharge` (and the buffer and result of a read) |
| a worker in "Backing opened", "Storage worker defect" or "Open cleanup step raised" | the finished job's outcome until it is taken | the job record; the worker is one of two |
| a caller inside a `withOutcome` or `withUse` body | counters on the job and the entry | their own |
| an open in a hook before its registration | the running job, and the file owned by `execOpen` (at most one per worker) | `jobCharge` (the backing record is charged at registration, all or nothing) |
| the drain in a log or a protected wait | none (the phase is closing) | n/a |
| `startWorkers` in the start hook | the worker counter | n/a (at most 2) |
| `withVolume`'s wait | the busy-volume set | none |

Round 5 found two members unbounded or outliving their charge: the reporting closing record and the volume ledger's node.

Smaller rules that hold the same class:

* **Open.** From the moment the file exists until the one transaction that registers it, `execOpen` owns the
  descriptor on every exit; cancellation is arbitrated in the registering transaction.
* **Reservation progress is explicit.** `reserveRange` says whether the native allocation was attempted when
  it stopped; every stop after it rolls the extra back or leaves a charged pending reservation.
* **Close.** The drain check and the claim are one transaction, the wait is in the caller's boundary, the
  hand-off to the native close is masked, and a closing backing takes no new borrower.
* **Discard.** A ticket discarded while its job runs is retired when the job finishes; a discard of a
  borrowed outcome is refused (the borrower retires it).
* **Startup and shutdown.** Every started worker is stopped and joined on every exit; the admission and the
  volume figures are exactly as they were once the service has ended.

### Tests

`terrain-runtime-tests` (`Test.TerrainRuntime.Storage.*`) owns the deterministic safety cases (see
[the suites](../../docs/test_suites.md)); `terrain-storage-probe` is the optional local real-platform
qualification, which fills a disposable volume the scripts under `tools/terrain-storage/` make and refuses to
run anywhere else. The storage examples hold the class of defect, not the instance:

* **The invariants** (`Lifecycle.invariantProblems`, one pure function over `snapshotOf`, the admission's ledger
  and the descriptors the seam sees open), checked after every cell of the matrix, every case of the sweep, every
  step of the random property and mid-state in the exit and shutdown examples: a growth slot is `GRunning` iff
  exactly one live growth job exists and `GReleasing` iff exactly one live release job; an untaken
  `GrowthPrepared` outcome implies a `GPrepared` slot; the open descriptors lie between the tracked backings and
  the tracked plus the closing plus the running opens; every volume's reserved figure equals the contributions of
  its backings **and closing records**; the control charge equals the jobs' charges plus the backing and closing
  records (**reporting ones included**) plus the kept failures; no volume node at zero, at most `maxJobRecords` job records, at
  most `maxQueuedJobs` queued and no more busy volumes than workers; the staging and cache charges equal exactly the running and held reads'; the
  borrow counts equal the live borrowers; the queue, running and mutation counts equal the table's; admission
  open implies both workers alive; running jobs do not exceed workers alive; the evidence holds at most 64.
* **The lifecycle matrix** (`Lifecycle`): 6 kinds of work (open, read, write, grow, abandon, release a pending
  reservation) by 4 phases (queued behind busy workers, running held at its native call, finished and untaken,
  finished and borrowed) by 8 events (cancel, discard, take, close its backing, service shutdown, an exception
  in a cleanup step, a take whose callback raises, a take whose callback is cancelled) = **192 cells: 127 with an
  effect, 54 refusals, 11 not applicable (not run, not counted)**. `declared` is the one declaration of what
  each cell is; the cells run from it and this grid is generated from it (E effect, R refusal, - not
  applicable):

| kind / phase | Cancel | Discard | Take | Close | Shutdown | CleanupException | TakeRaises | TakeCancelled |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Open / Queued | E | E | R | - | E | E | R | R |
| Open / Running | E | E | R | - | E | E | R | R |
| Open / Done | R | E | E | - | E | E | E | E |
| Open / Borrowed | R | R | E | E | E | E | E | E |
| Read / Queued | E | E | R | E | E | - | R | R |
| Read / Running | E | E | R | E | E | - | R | R |
| Read / Done | R | E | E | E | E | - | E | E |
| Read / Borrowed | R | R | E | E | E | - | E | E |
| Write / Queued | E | E | R | E | E | - | R | R |
| Write / Running | E | E | R | E | E | - | R | R |
| Write / Done | R | E | E | E | E | - | E | E |
| Write / Borrowed | R | R | E | E | E | - | E | E |
| Grow / Queued | E | E | R | E | E | E | R | R |
| Grow / Running | E | E | R | E | E | E | R | R |
| Grow / Done | R | E | E | E | E | E | E | E |
| Grow / Borrowed | R | R | E | E | E | E | E | E |
| Abandon / Queued | E | E | R | E | E | E | R | R |
| Abandon / Running | E | E | R | E | E | E | R | R |
| Abandon / Done | R | E | E | E | E | E | E | E |
| Abandon / Borrowed | R | R | E | E | E | E | E | E |
| ReleasePending / Queued | E | E | R | E | E | E | R | R |
| ReleasePending / Running | E | E | R | E | E | E | R | R |
| ReleasePending / Done | R | E | E | E | E | E | E | E |
| ReleasePending / Borrowed | R | R | E | E | E | E | E | E |

| Event | When | Declared | What it does (and is asserted to do) |
| --- | --- | --- | --- |
| Cancel | Queued | effect | the job is withdrawn at once (CancelledBeforeDispatch; nothing queued, observed) and what its admission installed is reversed |
| Cancel | Running | effect | stop requested (CancelRequested); the job keeps running until its held call returns (observed) |
| Cancel | Done, Borrowed | refusal | CancelTooLate: the outcome stands |
| Discard | Queued | effect | withdrawn at once and retired (nothing queued, observed); the admission is reversed |
| Discard | Running | effect | marked: it keeps running until its held call returns (observed), then is disposed of |
| Discard | Done | effect | disposed of at once (an opened backing is closed, a prepared growth becomes a pending reservation) |
| Discard | Borrowed | refusal | nothing: the borrower holds the outcome and retires it |
| Take | Queued | refusal | no outcome yet: answers Nothing |
| Take | Running | refusal | no outcome yet: answers Nothing |
| Take | Done | effect | borrowed and retired; a second take answers Nothing |
| Take | Borrowed | effect | a second borrower of the same outcome (two borrows, observed) |
| Close | Open, Borrowed | effect | closes the backing the open job created: waits for the borrower (observed blocked), then closes |
| Close | Open, Done | not applicable | the created backing's handle is inside the untaken outcome: its discard and the shutdown cell close it |
| Close | Open, any other phase | not applicable | the backing does not exist yet |
| Close | other kinds, Queued | effect | the queued job is withdrawn at once (nothing queued, observed); the close waits (observed blocked) for the running work, then closes |
| Close | other kinds, Running | effect | the close waits (observed blocked) for the held call, then closes |
| Close | other kinds, Done | effect | retires the untaken outcome and closes |
| Close | other kinds, Borrowed | effect | waits for the borrower (observed blocked), then closes |
| Shutdown | Queued | effect | the queued job is withdrawn at once (observed mid-drain: nothing queued, the two busy workers still held); the drain waits (observed blocked) for them |
| Shutdown | Running | effect | the drain waits (observed blocked) for the held call; the job is still running mid-drain, not detached |
| Shutdown | Done | effect | the untaken outcome is disposed of and every backing closed: nothing is left |
| Shutdown | Borrowed | effect | the drain waits (observed blocked) for the borrower; the job is still borrowed mid-drain |
| CleanupException | Open, Grow | effect | an exception in the cleanup step (injected, observed to fire): a taken outcome carries the cleanup note; an untaken one ends the service with the labelled cleanup failure (a normal end is a failure) |
| CleanupException | Abandon, ReleasePending | effect | the release raises (injected, observed to fire): a defect: the job finishes as HostFailure, the defect is recorded, the extra stays accounted as a pending reservation |
| CleanupException | the other kinds | not applicable | the kind has no cleanup step to fail |
| TakeRaises | Queued | refusal | no outcome yet: the callback never runs |
| TakeRaises | Running | refusal | no outcome yet: the callback never runs |
| TakeRaises | Done | effect | the take's callback raises: the outcome nobody received is disposed of by the one disposal (an opened backing is closed with its report kept, a prepared growth becomes a recoverable pending reservation, the record is retired) |
| TakeRaises | Borrowed | effect | a nested take's callback raises while another borrower holds the outcome: nothing is disposed of; the borrower's delivery stands (an opened backing stays open, the growth token stays valid) |
| TakeCancelled | Queued | refusal | no outcome yet: the callback never runs |
| TakeCancelled | Running | refusal | no outcome yet: the callback never runs |
| TakeCancelled | Done | effect | the take's callback is cancelled (an exception of the asynchronous type): the outcome nobody received is disposed of by the one disposal (an opened backing is closed with its report kept, a prepared growth becomes a recoverable pending reservation, the record is retired) |
| TakeCancelled | Borrowed | effect | a nested take's callback is cancelled (an exception of the asynchronous type) while another borrower holds the outcome: nothing is disposed of; the borrower's delivery stands (an opened backing stays open, the growth token stays valid) |

  Every cell ends with the invariants holding after the work has settled and asserts what its declaration says
  (a refusal asserts the refusal; an effect asserts what it did while the work is still held and what it left
  behind: a queued growth, abandonment or pending release that was cancelled or discarded can be submitted,
  committed or released again; a discarded or failed-delivery growth is recoverable as a pending reservation; a
  closed or failed-delivery open leaves only the first backing and its one descriptor; a nested take that raises
  disposes of nothing). A shutdown cell ends the service with the phase held and observes the drain **blocked**
  (`threadStatus`, no timer) where it must wait. A cleanup-exception cell asserts that the injected fault
  **fired** (the probe's rules are all used up) and where the evidence went: for an open or a growth a taken
  outcome carries the cleanup note and an untaken one ends the service with the labelled cleanup failure (a
  normal end is a failure); for a release the exception is a defect (host failure, defect recorded, the extra
  stays accounted as pending).
* **The sweep** (`Classes`): 21 native calls at their stages by 5 injections (a typed failure, a thrown
  exception, a cancellation, and after the effect a thrown and an asynchronous-typed exception) = 105 cases, each ending with the descriptors back to the baseline, the tracked
  backings equal to the open descriptors, the reported reservation equal to the physical allocation, the
  invariants holding, every backing closed and every volume's figure zero:

| Stage | Native call | Occurrence | Set up first |
| --- | --- | --- | --- |
| open | create | 1st matching call | - |
| open | unlink | 1st matching call | - |
| open | cloexec | 1st matching call | - |
| open | stat (verify private) | 1st matching call | - |
| open | stat (profile) | 2nd matching call | - |
| open | statfs | 1st matching call | - |
| open | reserve | 1st matching call | - |
| open | set length | 1st matching call | - |
| open | stat (verify reservation) | 3rd matching call | - |
| open | close (cleanup after a failure) | 1st matching call | an injected allocation refusal |
| grow | stat (profile) | 1st matching call | - |
| grow | statfs | 1st matching call | - |
| grow | reserve | 1st matching call | - |
| grow | set length | 1st matching call | - |
| grow | stat (verify) | 2nd matching call | - |
| grow | set length (rollback after a failure) | 1st matching call | an injected over-allocation |
| release | stat | 1st matching call | - |
| release | set length | 1st matching call | - |
| read | pread | 1st matching call | - |
| write | pwrite | 1st matching call | - |
| close | close | 1st matching call | - |

  The startup rows follow: the first start refused, the second start failing, and a cancellation during the first
  start, during the second start and during the abort's join. The table of what each call acquired and who owns it
  when its after-hook raises is item 12.
* **The exit points, the charge table, the keepers and the headroom boundary** (`Lifecycle`, `Open`, `Growth`):
  the tables above, each with its examples: three exit rows with the service kept running; one example per charge
  kind with the native call held; a discarded open whose close fails, a close that receives a cancellation instead
  of its report (each with the failing close held and a cancellation pending), a close that raised and keeps its typed
  identity, a close held in its diagnostics while the drain waits, and 64 kept failures plus a counted drop; open and growth with exactly the length and the headroom
  available and a seam that over-allocates 4,096 bytes (refused and unwound), and with the overhead available
  (admitted).
* **The probe's own checks** (`Classes`, "the probe's filler"): the filler ends only on out-of-space (six other
  errnos and a failing length each end it as a failure); a filler refused at once on a volume with plenty free fails
  with `ResidueTooLarge` before the action runs; a platform that would still grant one more block fails the
  precondition (`OneMoreBlockGranted`); a filler failing for another reason cannot yield a passing example and leaves no
  descriptor held; the pure verdicts are fed values (`exhaustionVerdict`, `rewriteVerdict`, `growthVerdict`: the
  observed 33,681,408-byte residue passes, new allocation fails, lost coverage fails, a consumed residue fails, a
  decrease that still covers passes, a refused growth that changed the file fails). Not routine-testable, and stated:
  that the probe examples call the verdicts at the right points (they run only on a real fixture).
* **The memory rows** (`Memory`): the noise floor, then every retained structure at its largest measured standalone or amplified
  with a signal 50 times the floor, no vacuous pass, the finished write reports held untaken against the model, run 200 times
  in one process on both hosts (the table and the method under Scheduling and accounting).
* **A reporting record is charged** (`Lifecycle`): the control account narrowed to three backing records, the log "Backing
  closed" held, repeated open, take and close until a typed `BusyNow (AccountPressure _)`, then released: the records end and the
  account returns to what the test holds.
* **The property** (`Classes`): 40 seeds by 36 operations over submit, cancel, discard, take, close and shutdown,
  the invariants checked after every step, the admission exactly zero at the end.
* **Waits are observed, not timed.** A negative ("the close has not returned") is shown by observing the waiting
  thread blocked in its transaction (`awaitBlockedInStm`), never by sampling early or by a timeout. The only
  timers in the storage examples are the two bounded polls (50 ms, at most 200) in the probe's `ProbeSpec` for
  APFS's lazy reclamation of freed space, a positive wait for a volume figure; the probe reads free space only
  through a descriptor it opened before anything was allocated, never by creating a file.

## Consumers

TRA-5 attaches the Lua request endpoint through the settlement seam. TRA-9 and the
view adapters supply view demand and consume snapshots. The temporary store
(TRA-20–TRA-23) replaces the RAM-only retention. Input, camera and picking
implementation, GPU upload and retirement, arena artwork, disk persistence, general
gameplay state and `api.state` are not part of this package.
