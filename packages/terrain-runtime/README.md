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
   authority, rebuild the cell's resident segment, and compute the result. Nothing is
   published. The staged work is tagged with the incarnation and revision it was
   built for, and the host is told it is ready.
4. **Commit** (owner, one transaction): read the parent session's admission, the
   request's presence in the table (a cancellation removes it), the arena's
   incarnation and revision, and the host's eligibility. Re-check a supplied
   content precondition. If every check holds, apply the content, the revision, the
   retained bytes and the model's `RemovalCommitted`, delete the request, admit
   again at the new revision every other pending removal and every reader that lost
   its work to the commit, and deliver the success settlement. Any failure before
   the host callback leaves nothing written; a failing callback abandons the whole
   transaction.

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
whose resident detail is restricted to exactly the held regions, so what it keeps
alive is what the hold charges. It is coherent through later edits, eviction and the
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
  non-blocking bookkeeping (close admission, settle what is pending). The wait for the
  owner and for every borrower is in the protected boundary around the body, with no
  deadline, detach or timeout. The owner returns only when the service is closed, no
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
| Column range over 8,192 levels, coordinates outside the extent | `RefusedInvalid` before admission |
| Forged, foreign, released or wrong-service authority | `RefusedAuthority` before admission |
| Bank, slot, arena, lease or view cap; retained edits full | `RefusedBusy`, nothing created |
| An identity or content revision that would wrap | `RefusedExhausted` before admission |
| Preparation failure (unexpected) | `HostFailure` (settled); the previous state is kept |
| Accounting defect after valid admission | `HostFailure`, a recorded `AccountingDefect`, and the owner ends |
| Provider (settlement callback) defect | A recorded `ProviderDefect`, nothing committed, and the owner ends |

An accounting defect or a provider defect ends the owner, which surfaces through
supervision; it is never reported as busy and never as air. Diagnostics carry
bounded arena, request and revision context, never a per-cell stream.

## Bounds

The banks are those of the residency model (`defaultLimits`: 256 MiB resident,
64 MiB retained edits, 128 MiB CPU staging, 128 load jobs, 256 queued commands).
The service adds the approved caps of four arenas, 64 arena leases and eight views,
and uses the source (256 KiB, 8,192 authored runs) and query (1,024 runs, 8,192
levels) limits of `hetoimasia-terrain`. All are configurable through `Config`
within the model's minimum-budget rule.

Identities (clients, leases, requests, arenas, views, holds) and content revisions are
checked 64-bit counters. The last value is never issued, and an admission that would
need it is refused before any work (`RefusedExhausted`).

## Invariants, traced from admission to release

Counts alone do not prove safe ownership. Each item below names where it is
admitted, what holds it, every way it is released and the example that exercises
that exit. `inspectInvariants` checks the structural rules after every example: the
model's own invariants and charge rules, the two-way agreement between the request
table and the model's records, lease and name consistency, no arena both live and
retiring, and the borrower count against the model's holds.

| Item | Admitted by | Held in | Released by | Exercised by |
| --- | --- | --- | --- | --- |
| Reservation (command slot, record, interest, staging, retained-edit and growth credits) | `SubmitQuery` / `SubmitRemoval` in the admission transaction | The model's request record | `Withdraw` on settlement, cancellation, closure or a read being taken; `RemovalCommitted` at a commit | Races, Closure ("returns every credit"), Offload |
| Pending open (arena slot, lease slot, name claim) | `admit` | The request table and the name map | Commit (becomes an arena, a lease and a live name) or termination (cancel, client end, closure, session end) | Closure ("pending open"), Races |
| Arena and lease | The open commit | `stateArenas`, `stateLeases`, the client record | `releaseLease`, `endClient`, `closeArena`, `closeService` | Closure (names, leases and authority; limits) |
| Queued command | `admit` | `stateRequests` (Waiting, then Staged) | Settled by commit or termination in one transaction; a read stays Done until taken | Races, Closure, Lifecycle |
| Staged edit | The owner's staging transaction | The request's `Staged` phase, tagged with incarnation and revision | Commit, or recomputed when superseded, or terminated by cancellation or closure | Races, Revalidation |
| Load job | `Dispatch` | The model's job record and slot | `JobCompleted` (published or discarded), `JobFailed`, or `JobAcknowledged` after its interests are gone | Budgets ("safe point"), Closure |
| Victim | An admission's eviction set | The victim queue and the model | The owner discards the detail, then `VictimReleased` | Offload, Budgets |
| Snapshot hold | `AcquireHold` | The model's hold and the borrower count | `ReleaseHold` on every exit of `withSnapshot`; closure waits for zero | Budgets (snapshot), Lifecycle (borrower) |
| Handoff | `BeginHandoff` (reserves the duplicate in staging) | The region's handoff record | `HandoffConfirmed` or `HandoffFailed` | Offload |
| Defect | Detection | The bounded defect record | Never; read by inspection | Races, Lifecycle |

## Tests

`hetoimasia-terrain-runtime:terrain-runtime-tests` is the non-optional CPU group
`test.terrain-runtime`:

```sh
cabal test --project-file cabal.project.cpu hetoimasia-terrain-runtime:terrain-runtime-tests --test-show-details=direct
```

The examples drive the production service. A **gate** is an `MVar` the owner blocks
on at a named point (`Probe`), so an example decides which side of a race wins by
what it does, not by how long it waits; no example sleeps. Every thread an example
starts is owned through `Test.Support.Owned`, and every wait is bounded
(`Test.Support.Bounded`). Expected cell values come from an independent model that
shares no code with the library. The suite is built `-threaded` and is run at more
than one capability count. `Test.TerrainRuntime.Opacity` compiles clients outside the
package through `Test.Support.ExternalClient`: one composes the public service, and
every attempt to name an authority, snapshot or service constructor, forge one, rewrite
a snapshot with record-update syntax or import a private module is refused for the
specific diagnostic that names the cause. Retained gated traces with before and after
accounting are in
[the TRA-4 evidence](../../docs/evidence/terrain/tra4/service_evidence.md).

## Consumers

TRA-5 attaches the Lua request endpoint through the settlement seam. TRA-9 and the
view adapters supply view demand and consume snapshots. The temporary store
(TRA-20–TRA-23) replaces the RAM-only retention. Input, camera and picking
implementation, GPU upload and retirement, arena artwork, disk persistence, general
gameplay state and `api.state` are not part of this package.
