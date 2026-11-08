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
temporary store of TRA-20–TRA-23 replaces that retention later; nothing here builds
it.

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
| Running-work record (`RunningWork`: each load job's reservation, scratch and slot; the preparation; each handoff duplicate) | The owner thread alone, in the transaction that starts or ends the work, from the values the work holds | Inspection only (`inspectCensusSTM`); no production decision reads it | The owner | One preparation, one job per dispatch, one duplicate per changed region | Each entry ends with the work it describes (a job's report, the owner's safe point, a transfer's outcome); the owner's terminal step empties it |

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
outstanding snapshots, and **the owner's record of the work it runs**. That record
(`RunningWork`, the owner's ruling of 2026-11-08 on the issue, comment 6728512155) is written
by the owner thread, in the transaction that starts or ends the work, from the values the
work itself holds, and no production decision reads it: each load job (what its coverage
can store, 48 bytes a column, 32 a segment and 64 of payload a segment, so 144 for a one-cell
read; its scratch, a 256-byte frame and two bytes a cell, 258; and its one load-job slot) from
its dispatch to its report (completed, failed or acknowledged); the preparation the owner is
running (a removal's resident growth, 62 bytes, staging, 512, and retained edit, 64, and the
command record it reads under) from its start to the owner's safe point; and each handoff
duplicate (the bytes the owner copies, 64 for one removal) from the transfer's admission to
its outcome. Every inspection type (`Census`, `ArenaCensus`, `RequestCensus`, `RunningWork`,
`JobWork`, `PreparationWork`, `HandoffWork`) is abstract with read-only accessors that are
functions, never field labels: an external client cannot construct, forge or update one, and
none carries an authority, a handle or a snapshot. Reading them takes no hold, interest or
reservation and changes no residency, LRU order or scheduling.
The check requires: each region charged at least what its detail
holds, and no region held by the service with no model record (nor charged, unless
evicting, when the service holds none); each arena (live or retiring) charged at least its
own retained changes, and the edit bank at least their sum; a removal's resident growth at
least the worst case of a segment (two bytes a cell for a dense segment, less the two bytes
of a uniform one) and its edit and staging reservations as stated; the staging bank's
request records exactly what the service's requests hold; the command slots exactly the
service's requests that hold a model record; and the snapshot holds exactly the service's
outstanding snapshots. The owner's running work is compared in its own amounts, entity by
entity and bank by bank: each running load job must be charged, in the model, at least its
coverage's resident reservation and its scratch (the model reserves 400 for the one-cell read
above, 144 plus the region's 256-byte metadata, and 258 of scratch), the load-job slots at
least the jobs the owner runs, the resident bank's reservations (counting what still waits for
victims) at least the jobs' reservations plus the removals' growth, the staging bank's
reservations at least the removals' staging plus the jobs' scratch, each handoff duplicate at
least the bytes the owner copied (the staging bank's occupied bytes exactly the request
records, interests, holds, view descriptions and duplicates), and the model must still hold,
with its growth, the request the owner is preparing. Only what exists nowhere but in the model
(interests, hold and view records) is taken from the model's entity lists. These comparisons
run after every step of the property, inside every held borrow, at every job (where the record
must also hold the job, with a slot and non-zero amounts) and, with releases injected, inside
the preparation hook right after each cancellation, lease release or client end, before the
owner resumes. The property ends with every bank, occupied as well as reserved, every slot and
every arena at zero: no charge, a coalescing excess included, outlives its holder.
`Test.TerrainRuntime.Oracle` pins the record's literal amounts at a gated job, handoff and
preparation, and holds the controls that must fail: a model that charges the running job 1
byte of resident and 1 of scratch instead of 400 and 258 (and one byte short of each figure),
a job the model forgot while it runs, a 64-byte handoff duplicate zeroed (or not charged at
all), a preparation whose request the model dropped or for which it reserved no growth, a
model rebuilt without the arena beside the service's real census (every bank disagrees), and
two arenas' retained charges swapped. It also shows that reading the census changes neither the
model, its clock, its requests nor its limits, and that an arena with coalesced edits, charged
more than it holds, returns every account when it retires.
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

## Consumers

TRA-5 attaches the Lua request endpoint through the settlement seam. TRA-9 and the
view adapters supply view demand and consume snapshots. The temporary store
(TRA-20–TRA-23) replaces the RAM-only retention. Input, camera and picking
implementation, GPU upload and retirement, arena artwork, disk persistence, general
gameplay state and `api.state` are not part of this package.
