# TRA-21 evidence: the storage backend on two real platforms

Evidence for [#663](https://github.com/coghex/hetoimasia/issues/663) (own reserved backing files and bounded asynchronous storage I/O). The implementation is in `packages/terrain-runtime` (`storage/`, `probe/`); the contract is its README section "The storage backend (TRA-21)". The two platform records are of revision `69cb867061ff9c06715a7c879f42c7a7c042605d` on branch `issue-663-storage-backend`. **Since then the only file changed under `packages/terrain-runtime/storage` and `tools/terrain-storage` is `Internal/Service.hs`** (the service's bookkeeping, exception, cancellation and shutdown discipline): no native call, C shim, fixture or probe code has changed (`git diff 69cb8670..HEAD` shows only `Service.hs` under those paths and nothing under `packages/terrain-runtime/probe`), so the platform records stand for the head under review. The probe was not re-run for rounds 2 and 3 and the `hetoimasia-linux` VM stayed stopped. The sections "Round 2 of review, answered" and "After round 2" below are about the service and test changes. The earlier records at `e2b97419` are kept below as history.

## What is and is not claimed

Claimed: on APFS (macOS) and on ext4 (Linux), at the revision above, the production native backend obtains a real native reservation and proves it; writes and rewrites throughout the reserved range need no new allocation even with the rest of the volume exhausted; growth under exhaustion is refused with the old data and size intact; a failed release is retained and freed on retry; an unlinked file is kept for its borrowers and its space returns after the last close; an unqualified filesystem is refused; a sparse file of the right length fails the qualification. Not claimed: any other filesystem (the qualified list is `apfs`, `ext4`), durability (`fsync`), crash or power-loss recovery, live terrain publication, a throughput or latency promise, behaviour under allocations by other processes, or a real `EINTR` from `close` (only an injected `EIO` is tested).

## Commands and run identifiers

Fixture setup, then the lab command in each candidate checkout (the probe refuses to run without its fixture):

```sh
tools/terrain-storage/macos-fixture.sh up   <scratch>      # macOS: 3 GiB APFS sparse image, attached -nobrowse, no sudo
tools/terrain-storage/linux-fixture.sh up   <scratch>      # Linux guest: 3 GiB sparse image, mkfs.ext4, sudo mount -o loop + chown
quruntul --repo . test --target terrain-storage-probe --ref HEAD
tools/terrain-storage/{macos,linux}-fixture.sh down <scratch>
```

| Platform | Run id | Outcome |
| --- | --- | --- |
| macOS 26.7.1 (25G313), arm64, Darwin 25.6.0, Apple clang 21.0.0, GHC 9.14.1 | `f02cccc9-095a-4bbb-be60-f707913ed6e5` | 8 passed |
| macOS, the same fixture, one revision earlier (`50595926`) | `f4179231-939f-4723-b369-8c5a166c83b8` | 7 passed, 1 failed (below); kept as evidence, not as the record |
| Ubuntu 24.04.4 LTS aarch64, Linux 6.8.0-142-generic, gcc 13.3.0, GHC 9.14.1, cabal 3.18.1.0, in the owner's `hetoimasia-linux` Lima VM (guest-local checkout cloned from the read-only worktree mount) | `b932136e-8b6a-4669-97fa-77363abb7e0e` (`e2b97419`) | 8 passed |
| **Platform record** at `69cb8670`, macOS (same identity as above) | `4f3965bc-f67a-4275-a0f0-96bc158cbf08` | 8 passed: **the macOS record** |
| **Platform record** at `69cb8670`, Linux (same identity as above, a fresh ext4 loop image) | `40d69440-4d8a-42ca-8368-0e4f685e197f` | 8 passed: **the Linux record** |

The two platform runs (at `69cb8670`) were taken after the capacity check moved into the probe's mandatory fixture acquisition (round 1 of review); the probe was run on no machine between that finding and the fix. The numbers in the tables below are those runs' (they equal the earlier runs' except where stated).

The first macOS run failed in the growth example: the probe released its own filler file and grew at once, and APFS had not yet given the closed, unlinked file's blocks back (33,681,408 bytes reported available), so the headroom refusal was correct for what the volume reported. The probe now observes the volume with a bounded, spaced poll before growing (200 observations of 50 ms at most); the rerun saw the space at once (0 observations). The lag is real and nondeterministic; a consumer must not assume space returns at the moment of the close.

## Platform and filesystem identities

| | macOS | Linux |
| --- | --- | --- |
| Filesystem | `apfs`, mounted `local, nodev, nosuid, journaled, noowners, nobrowse` from a 3 GiB sparse disk image (`hdiutil create -type SPARSE -fs APFS -size 3g`) | `ext4` (`rw,relatime`), features `has_journal ext_attr resize_inode dir_index filetype needs_recovery extent 64bit flex_bg sparse_super large_file huge_file dir_nlink extra_isize metadata_csum`, default mount options `user_xattr acl`, loop-mounted from a sparse 3 GiB file (`mke2fs 1.47.0`) |
| Block size | 4096 | 4096 |
| Volume total | 3,011,469,312 bytes | 3,094,126,592 bytes |
| Fixture checks | a device distinct from the working directory and the home directory, owned by the running user, within the 4 GiB cap, all verified by the probe before any space was consumed | the same |
| Native ABI | `fcntl(F_PREALLOCATE, fstore_t{F_ALLOCATEALL, F_PEOFPOSMODE, 0, len})` from the end of file, then `ftruncate`; `fstat` `st_blocks * 512` for allocated bytes; `fstatfs` `f_bavail * f_bsize` | `fallocate(fd, 0, off, len)`, which extends the file; `fstat` `st_blocks * 512`; `fstatfs` `f_bavail * f_frsize`, filesystem name from `/proc/self/mountinfo` matched on the device |
| Cleanup | image detached and deleted, pointer file removed, by `macos-fixture.sh down` | `umount`, image and pointer file removed, by `linux-fixture.sh down` |

## Records (from the run logs)

| Observation | APFS | ext4 |
| --- | --- | --- |
| Reserved 64 MiB: allocated / overhead | 67,108,864 / 0 | 67,108,864 / 0 |
| Reserved 256 MiB | 268,435,456 / 0 | 268,435,456 / 0 |
| Reserved 1 GiB (the default allowance) | 1,073,741,824 / 0 | 1,073,745,920 / 4,096 (an extent block) |
| Growth 64 to 128 MiB | allocated 134,217,728, overhead 0 | allocated 134,217,728, overhead 0 |
| Every page of the allowance written, then read back | passed | passed |
| Volume exhausted by a filler (bytes taken) | 2.9e9 | 2.85e9 |
| Allowance rewritten with the volume exhausted | passed, no new allocation | passed, no new allocation |
| Growth with the volume exhausted | `reservation_failed`, old data intact | `reservation_failed`, old data intact |
| Failed release then explicit retry: allocated | 67,108,864 | 67,112,960 (one block of bookkeeping stays accounted) |
| Unlinked file held by a borrower; reserved bytes / reclaimed after last close | 67,108,864 / 67,108,864 | 67,108,864 / 67,108,864 |
| Unlisted filesystem name | `storage_unsupported` | `storage_unsupported` |
| `tmpfs` (`/dev/shm`) | not applicable | `storage_unsupported` |
| Sparse-size negative control | `reservation_failed` (`CoverageShort`) | `reservation_failed` (`CoverageShort`) |
| Latency, reserve 64 MiB / 256 MiB / 1 GiB (seconds, one run, no deadline claimed) | 1.4e-4 / 6.3e-3 / 2.3e-4 | 3.8e-4 / 4.0e-4 / 1.0e-3 |
| Latency, write then read back the 64 MiB allowance | see the run log (about 0.06 s and 0.05 s) | 0.13 s and 0.026 s |

Model accounting, actual allocation and process RSS are three different figures: the model charges the allowance and its configured overhead; the actual allocation is `st_blocks * 512`, above; RSS was not measured. The worst space peak of a growth is the allocation after it (134,217,728 on both). Growth, release and unlink behaviour found on the way, from the native experiments run before the backend was written (APFS, same image type): preallocation past the end of the file is counted in `st_blocks` and in the volume's free space at once; `ftruncate` to the length the file already has does not release it; raising the length and then shortening it does, which is why a release raises the length first (`releaseExtra`); a failed `F_ALLOCATEALL` leaves nothing allocated and answers `ENOSPC`.

## Causal lifetime and fault traces, buffer, descriptor and queue counts

These are the routine examples, in `terrain-runtime-tests` (`Test.TerrainRuntime.Storage.*`): the seam records every native call, so the traces are the calls themselves. Queue and worker counts: eight queued and two running at saturation, a ninth refused, ten records, control charge 10 times `jobRecordBytes`, staging and cache holding only the two running transfers (Lifetime, "runs two jobs and queues eight"). Offsets: every short-transfer boundary asserted call by call (Io). Descriptors: every failed open ends with none open and no name left. The accounted job record (2,048 bytes) is measured against the live heap by the Memory examples; the measured largest queued open was 1,571 bytes (a 512-byte path included) and a queued read 559 to 1,071.

## Routine-suite wall time and repeats

`terrain-runtime-tests` is 613 examples at the head the round-3 review was asked about (service and test code of local commit `278b9058`, which the pull request carries merged with master), including the storage examples; the full suite ran in 829 s of examples on this Mac (the brief's baseline is about 16 minutes), the earlier candidates at 858.7 s (602 examples, `69cb8670`) and 1,042.8 s (584 examples). The storage examples are a few tens of seconds of it, now that the lifecycle matrix runs 133 cells of real service work; no capacity, latency or filesystem experiment is in the routine suite, those are the probe.

Repeats of the storage examples: macOS, 40 runs at an earlier candidate and 6 at the dev loop of `69cb8670`, 0 failures; the dev loop of the final head (`storage-dev`, not committed) was run to completion repeatedly while the matrix was built. Linux aarch64: 25 runs at an early candidate found 2 failures, both in the growth release assertions (ext4 keeps one block of bookkeeping accounted after a release, where the assertion demanded exact equality), since changed to "within one block"; then 10 runs at `14f9acf4` and 5 runs at `69cb8670`, 0 failures. The round 2 and 3 changes were not run on Linux: they are in portable Haskell and the pull request's Linux CI runs the routine suite.

## Negative controls

Each was applied once locally to the committed source, the affected examples run, then reverted, never committed: the coverage check removed (the sparse example fails), the offset not advanced after a short transfer (the short I/O examples fail), a running job's cancellation releasing its resources early (the cancellation example fails), a failed close retried (the "never closes twice" example fails), a prepared growth made spendable (the "not spendable" example fails), the volume coordination removed (the serialization example fails), the fair-progress rule removed (the scheduling example fails), the close not waiting for the drain (the example's thread blocks forever, a failure). Not exercised as a control: the interrupted-call retry cap (the storm example asserts the bound, but the cap itself was not mutated) and the descriptor-leak check on a child `exec`.

## Round 1 of review, answered

Round 1 (head `06bc8415`, Codex) requested changes with eleven findings. Fixed as four classes plus the owner's reads of the sites; the evidence for each is the example named.

| Finding | Class | Fix | Example |
| --- | --- | --- | --- |
| Probe capacity checked only in the first example | A | one mandatory acquisition (`Fixture`): exists, owned, distinct device, capacity from an opened descriptor, before any allocation; the constructor is hidden and every filler and reservation takes a `Fixture` | `Classes` (A): every probe case, handed a refused fixture, fails at the acquisition with nothing created |
| Abandon left commit authority open | B | `GReleasing` is entered in the admission's transaction | "revokes the commit authority in the step that accepts an abandon" |
| Failed final `fstat` treated as obtaining nothing | C | `reserveRange` reports whether the allocation was attempted; every later stop rolls back or leaves a charged pending | sweep row "stat (verify)" |
| Exception left the opened descriptor open | C | `execOpen` owns the descriptor until the registering transaction on every exit | sweep rows "create" to "stat (verify reservation)" |
| Drain and claim were two steps; unmasked close | C | one transaction; masked hand-off; one close | "closes only after a gated native call has returned", sweep "close" rows |
| Discarded running ticket kept its charges | D | marked and retired when the job finishes | "retires a ticket discarded while its job runs" |
| Open outcomes not drained at shutdown | D | shutdown retires every record and closes the backings they named | "retires an opened backing's outcome nobody took" |
| `grantEvicted` dropped | D | dispatch refuses a reservation that would evict; `svWaitingForCache` tells the owner | "never drops an eviction" |
| Growth sizes unvalidated at the boundary | B | minimum, 1 MiB grid and offset limit re-checked | "refuses a token of another service and sizes off the grid" |
| `PreparedGrowth` not unique | B | carries the service and a fresh attempt identity | "revokes the commit authority" (stale token), foreign token |
| Cancellation not arbitrated at publication | B | checked in the transaction that publishes `GPrepared` | gate-point matrix, three gate points by six events |

The owner's reads then found three more, each fixed with a control: the second worker's start failing (or being cancelled) left the first without an owner and the abort's join was interruptible; after a failed give-back of a never-published growth the close left `to - from` in the volume's reserved figure; and `withOutcome` took borrowers of a closing backing. A fourth point was answered in the contract, with the signal `svWaitingForCache`.

### (B) the growth state machine, state by event

The table is in the package README ("Growth"). The suite injects every event at three gate points of a growth (before the allocation, before the length, before the final verification) and in the prepared and releasing states: 3 gate points by 6 events (none, cancel, a stale token's commit, a stale token's abandon, a second growth, a release of a pending reservation), each outcome one the table allows, the reported reservation equal to the file's physical allocation within one filesystem block, plus the abandon-in-flight, stale-token, foreign-token and size examples.

### (C) the sweep matrix

21 rows of (stage, native call, which occurrence) by 3 injections (a typed failure, a thrown exception, a cancellation) = 63 cases, after each of which: the process's open descriptors are back to the baseline (counted from `/dev/fd` or `/proc/self/fd`), the backings the service tracks equal the descriptors open, the reported reservation equals the physical allocation (growth, release), every backing closes and every volume's reserved figure is zero. Rows: open (create, unlink, close-on-exec, the three stats, statfs, reserve, set length, and the cleanup close after a failure), growth (profile stat, statfs, reserve, set length, verification stat, and the rollback's set length after a failure), release (stat, set length), read (pread), write (pwrite), close. The cancellation of the close is an interruption delivered to the closing thread while it waits for a held call. The startup rows: the first start refused, the second start fails, a cancellation during the first start, during the second start, and during the abort's join (held at the worker's end); each leaves no live worker (the group's report) and keeps the primary failure.

### (D) the property

40 seeds by 36 operations = 1,440 operations over three work classes of read, cancel, discard, take, close, open and the gate, then every backing is closed and the service shuts down: the admission is exactly zero (the environment's end checks it) and the volume's figures are zero.

### Controls (each applied once to the committed source, the affected examples run, then reverted; never committed)

All bite: B1 abandon does not revoke commit; B2 publication does not arbitrate cancellation; B3 the token compared without its attempt identity; B4 sizes not validated; C1 an exception in open does not close the descriptor; C2 a failed final query treated as obtaining nothing; C4 the close without its drain check; D1 a running ticket's discard not marked; D2 shutdown does not retire the records; D3 eviction allowed; E1 started workers not stopped or joined on a failed start; E2 a close giving back only the length; E3 a closing backing still takes borrowers; E4 the pressure signal not reported. Earlier controls (round 0) are in the first list above. The controls of rounds 2 and 3 are listed under "After round 2".

### What a control cannot catch (the honest list of round 1; the current one is at the end)

Races between two transactions at interleavings the gates do not reach (the matrix injects at gate points; the drain-and-claim atomicity is by construction, and its mutation is caught through the gated-close example, not through a deterministic interleaving); an exception raised by the kernel after a native side effect (modelled only for `close`, whose call is made and then raises; the others raise before the call); asynchronous exceptions delivered to a worker (workers run masked by design, the cancellation is a request); a real `EINTR` from `close`; that the owner actually drops cache when `svWaitingForCache` is positive (the owner is TRA-22's).

### A bug the sweep found

`protectedly`, the wait the drain and the close use to remember an interruption and deliver it afterwards, recognised asynchronous exceptions with `asyncExceptionFromException` at the wrong type, so an interruption of a closing thread aborted the close and left the descriptor open (and would have aborted a drain). The "cancellation" injection of the close row failed with one descriptor leaked; fixed to `fromException` at `SomeAsyncException`.

## Round 2 of review, answered

Round 2 (head `d9b57063`, Codex) requested changes with seven findings (3 P1, 4 P2); round 1's eleven were verified fixed. They were one class: *an exit between a state change and the bookkeeping that completes it*. Each now has one mechanism that owns it (the package README, "Ownership at every instant"), and the evidence is a class (a cell of the lifecycle matrix), not the reviewer's instance.

| # | Finding (P) | What was wrong | The one mechanism now | Example (cell or dedicated) | Control that bites |
| --- | --- | --- | --- | --- | --- |
| 1 | Queued cancellation did not reverse the slot (P1) | a cancelled or discarded queued growth left `GRunning`, an abandonment left `GReleasing`: growth refused for ever, the token and the pending release lost | `withdrawQueued` / `undoAdmission`: the one withdrawal, called by cancel, discard, closing admission and a backing's close | cells Grow, Abandon, ReleasePending x Queued x Cancel, Discard (next growth admitted, token commits, release admitted) | S1 growth undo removed; S1b abandon restoration removed |
| 2 | A discarded `GrowthPrepared` was retired with its reservation held (P2) | the extra stayed charged and unrecoverable | `disposeUndelivered` (total over `Outcome`): a pending reservation `submitReleasePending` recovers | cells Grow x Done x Discard and Grow x Running x Discard (a discard racing the preparation) | S2 prepared growth not made recoverable |
| 3 | `unwind` ran the unlink retry before the close (P1) | an exception from the unlink leaked the descriptor | every cleanup step independent; the one close always attempted, recorded before it is made | "attempts the descriptor's close even when the unlink cleanup throws (twice)"; the cleanup-exception cells | S4 a cleanup raise stops the close |
| 4 | `claim` released accounting before the native close (P1) | shutdown could return with another caller's close in flight | a closing record (`stClosing`) from the claim until the native close has returned, joined by the drain; exactly-once close kept | "joins a close another caller claimed" (observed blocked, no timer); the shutdown cells | S3 closing record removed; T2/K1 drain not waiting |
| 5 | A successful open job was not linked to its backing (P2) | `withOutcome` on `Opened` neither borrowed nor checked closing | `finishJob` links the job to the backing it created | "borrows the opened backing..."; cell Open x Borrowed x Close (closes the created backing, observed waiting) | S3b not linked; K2; K3 closes the wrong backing |
| 6 | `runJob` lost the exception context (P2) | plain `try` / `throwIO` dropped the cleanup failures | every catch is `tryWithContext` and `rethrowIO` (the sites table in the README) | "keeps the cleanup failures through the worker's failure boundary"; "keeps a callback's failure and its cleanup failures..." | S5 context lost |
| 7 | Shutdown did not collect the cleanup failures of untaken outcomes (P2) | evidence of an untaken failed open was lost | `disposeUndelivered` keeps `Failed` and `Cancelled` notes (at most 64); the drain composes them with the scope's primary failure, or reports them when the body succeeded | "surfaces the cleanup failure of an open nobody took"; cleanup cells (an untaken outcome must end the service with the failure) | S2b notes dropped; M1 |

## After round 2

The manager's reads of the repair found four further things, each fixed as a class:

1. **The closing record is decremented first.** `closeBackingCore` decremented `stClosing` after two log calls; a logger that raised left the drain waiting for ever. It is decremented the moment the native close returns. Control: moving it after the unprotected logs bites.
2. **Waits are observed, not timed.** The example "joins a close another caller claimed" proved its negative with a 300 ms timeout (every pass slept; a slow machine passed a broken build). It, and the two close examples in `Lifetime`, and every matrix cell that says a close or a drain *waits*, now observe the waiting thread **blocked in its transaction** (`GHC.Conc.threadStatus`, `awaitBlockedInStm`); a build that does not wait finishes, which fails at once. The only timers left in the storage examples are the two bounded polls in `ProbeSpec` (50 ms, at most 200 observations) for APFS's lazy reclamation of freed space, which are positive waits for a volume figure. Gates a failing example leaves closed are opened by the owned thread's own release, so a failure is a failure, not a hang. Controls: the drain's wait made vacuous (T2), the close claim without the drain check (C4, both close examples), the drain not awaiting a held worker (K1).
3. **Invariants after every step.** The pure checker runs after every cell, every sweep case and *every* step of the random property (it ran after every sixth step in the first version).
4. **A diagnostic is never an exit.** `quietly` swallowed a synchronous exception but rethrew an asynchronous one; every caller is masked and a sink may block, so a cancellation lands at the log. Found by a new example whose sink raises on every entry (it hung before). Now `quietly` *returns* the asynchronous exception, never rethrows: `closeBackingCore` folds it into its remembered cancellation (the drain goes on to close every other backing), the drain adds it to its late list, `runJob` does its bookkeeping first and logs after (and logs "Backing opened" after the job finished). Examples: a sink that cancels every entry (two backings opened, the service ends, both descriptors closed, the exception delivered after the drain); a sink that cancels only the defect log (the ticket wakes, the record and charge are released); a sink that cancels only the drain's wait log (the drain still waits, observed). Controls: `quietly` rethrowing bites; the open-success log before the job finishes, the drain-wait log rethrown and the defect log before the bookkeeping each bite. A rethrowing `quietly` alone does not bite the defect example once the bookkeeping precedes the log (the worker ends with the defect either way); the ordering mutation is that site's control, and it bites.
5. **The lifecycle matrix was made honest.** A first version counted "96 of 144 exercised an effect", which was only the count of events that *can* have one. Now `declared` states, per cell, an effect, a refusal or not applicable; the cells run from it, a not-applicable cell is not run and not counted, the grid and the three numbers below are generated from it, and every effect is asserted (the shutdown column shuts down with the phase held; the open close cell closes the backing the open job created; the cleanup cells observe their injected fault fire and assert where the evidence went). Controls: the notes of an untaken outcome dropped (M1), of a taken outcome dropped (M2), the injected rule never firing (M3), closing admission not withdrawing the queued jobs (M4), a close not withdrawing its backing's queued jobs (M5), a release that raised not keeping the extra pending (M6), and K1 to K4 of the shutdown and close cells; each is read in the failure output.

### The lifecycle matrix, as run

lifecycle matrix: 144 cells (6 kinds x 4 phases x 6 events): 103 with an effect, 30 refusals, 11 not applicable (not run)

6 kinds of work (open, read, write, grow, abandon, release a pending reservation) by 4 phases (queued behind two busy workers, running held at its characteristic native call, finished untaken, finished and borrowed) by 6 events; E an effect, R a refusal, - not applicable (not run):

| kind / phase | Cancel | Discard | Take | Close | Shutdown | CleanupException |
| --- | --- | --- | --- | --- | --- | --- |
| Open / Queued | E | E | R | - | E | E |
| Open / Running | E | E | R | - | E | E |
| Open / Done | R | E | E | - | E | E |
| Open / Borrowed | R | R | E | E | E | E |
| Read / Queued | E | E | R | E | E | - |
| Read / Running | E | E | R | E | E | - |
| Read / Done | R | E | E | E | E | - |
| Read / Borrowed | R | R | E | E | E | - |
| Write / Queued | E | E | R | E | E | - |
| Write / Running | E | E | R | E | E | - |
| Write / Done | R | E | E | E | E | - |
| Write / Borrowed | R | R | E | E | E | - |
| Grow / Queued | E | E | R | E | E | E |
| Grow / Running | E | E | R | E | E | E |
| Grow / Done | R | E | E | E | E | E |
| Grow / Borrowed | R | R | E | E | E | E |
| Abandon / Queued | E | E | R | E | E | E |
| Abandon / Running | E | E | R | E | E | E |
| Abandon / Done | R | E | E | E | E | E |
| Abandon / Borrowed | R | R | E | E | E | E |
| ReleasePending / Queued | E | E | R | E | E | E |
| ReleasePending / Running | E | E | R | E | E | E |
| ReleasePending / Done | R | E | E | E | E | E |
| ReleasePending / Borrowed | R | R | E | E | E | E |

What each declared cell does, and is asserted to do:

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

### The ownership sweep, as run

21 native calls at their stages by 3 injections (a typed failure, an exception, a cancellation) = 63 cases, each ending with the descriptors at the baseline, the tracked backings equal to the open descriptors, the reported reservation equal to the physical allocation, the invariants holding, every backing closed and every volume figure zero:

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

The random property is 40 seeds by 36 operations with the invariants checked after every step.

### The controls of rounds 2 and 3 (each applied once to the committed source, the examples run, then reverted; never committed)

Each was read in its failure output: it fails for the reason named, not by a build error or a hang.

| Id | Mutation | Bites in |
| --- | --- | --- |
| S1 | a queued growth withdrawn without reversing its admission | the matrix, Grow x Queued x Cancel and Discard |
| S1b | a queued abandonment withdrawn without restoring its token | the matrix, Abandon x Queued |
| S2 | a discarded preparation not made a pending reservation | the matrix, Grow x Done and Running x Discard |
| S2b, M1 | the cleanup notes of an undelivered outcome dropped | the dedicated example and the untaken cleanup cells |
| S3, T2 | the closing record not tracked / the drain not waiting for it | "joins a close another caller claimed" |
| S3b, K2 | a finished open job not linked to its backing | "borrows the opened backing", the Open x Borrowed x Close cell |
| S4 | the unlink cleanup raising prevents the close | "attempts the descriptor's close even when the unlink cleanup throws" |
| S5 | `withOutcome` rethrowing without its context | "keeps a callback's failure and its cleanup failures" |
| T1 | the closing record ended after logs that may raise | the raising-logger example |
| T3 | a raising log in the open success path fails the open | the raising-logger example |
| X1 to X5 | a cancellation at a close log, at the drain-wait log, the defect log before its bookkeeping, the open-success log before the job finishes, or every asynchronous exception rethrown by `quietly` | the three asynchronous-sink examples |
| K1 | the drain does not await a held worker | the matrix, shutdown cells |
| K3 | the Open close cell closes the wrong backing | the matrix, Open x Borrowed x Close |
| K4 | the close claim ignores borrowers | the matrix, Borrowed close cells |
| M2 | a taken outcome loses its cleanup notes | the matrix, Borrowed cleanup cells |
| M3 | the injected fault never fires | the matrix, every cleanup cell |
| M4 | closing admission does not withdraw queued jobs | the matrix, Shutdown x Queued |
| M5 | a close does not withdraw its backing's queued jobs | the matrix, Close x Queued |
| M6 | a raising release does not keep the extra pending | the matrix, Abandon and ReleasePending cleanup cells |

### What is not reached, and what is policy (the honest list, after round 3)

Not reached by any control or example: interleavings between two transactions that the gates do not reach (the drain-and-claim atomicity is by construction; its mutations are caught through observed waits, not through a deterministic interleaving); an exception from the kernel after a native side effect (modelled only for `close`; the others raise before the call); asynchronous exceptions delivered to a worker at arbitrary points (workers run masked by design; the cancellation is cooperative, and the cases that reach a log are the examples above); a real `EINTR` from `close`; whether the owner actually drops cache when `svWaitingForCache` is positive (TRA-22's); the matrix does not combine two events on one job (a cancel racing a close) beyond what the sweep and the property do; the matrix runs each kind through the one characteristic native call, not through every call (the sweep does that); a cleanup-exception cell injects one fault, not a cascade (the dedicated examples repeat the unlink fault twice); the Linux platform was not re-run for rounds 2 and 3 (portable code, same suite in CI).

Policy, stated as policy and not as a gap:

* A cancellation delivered to a worker inside an open's cleanup step is recorded as one more cleanup failure of that step and is not redelivered: the worker ends at the cooperative stop its group has already requested.
* A cancellation at the log of a defect is dropped with the entry, because the worker ends with the defect either way.
* A worker ended by a cancellation at the "Backing opened" log does not stop the service. That is not reachable through the public API: no caller holds the worker handles, and the group cancels a worker only when its owner is failing, after the service has drained.
* A release that raises is a defect (host failure, service stopped, the extra kept as a pending reservation), not a cleanup failure with notes; the worker's defect is what supervision sees.
* A diagnostic never changes the outcome of the work it describes: a logger that raises is dropped, and an asynchronous exception reaching it is delivered after the bookkeeping.
