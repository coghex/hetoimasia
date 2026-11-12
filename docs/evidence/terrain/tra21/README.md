# TRA-21 evidence: the storage backend on two real platforms

Evidence for [#663](https://github.com/coghex/hetoimasia/issues/663) (own reserved backing files and bounded asynchronous storage I/O). The implementation is in `packages/terrain-runtime` (`storage/`, `probe/`); the contract is its README section "The storage backend (TRA-21)".

**The candidate is P = `1fd7fdf25a1db134720a61eddcbdb5e77e458276`** on branch `issue-663-storage-backend`, and the two platform records below were taken AT P, one run on each host, through the lab. The reviewed head is P plus the merge of the docs-only commit that records them: `git diff P HEAD` shows only `docs/` and `packages/terrain-runtime/README.md`. An earlier probe run at `61cc3fbb` failed in the probe's own free-space helper and is kept below as a failed run with its cause; the earlier records at `69cb8670` and `e2b97419` are kept as history, not as the record.

## What is and is not claimed

Claimed: on APFS (macOS) and on ext4 (Linux), at P, the production native backend obtains a real native reservation and proves it; writes and rewrites throughout the reserved range need no new allocation even with the rest of the volume exhausted; growth under exhaustion is refused with the old data and size intact; a failed release is retained and freed on retry; an unlinked file is kept for its borrowers and its space returns after the last close; an unqualified filesystem is refused; a sparse file of the right length fails the qualification. Not claimed: any other filesystem (the qualified list is `apfs`, `ext4`), durability (`fsync`), crash or power-loss recovery, live terrain publication, a throughput or latency promise, behaviour under allocations by other processes, or a real `EINTR` from `close` (only an injected `EIO` is tested).

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
| macOS at `69cb8670` (same identity as above) | `4f3965bc-f67a-4275-a0f0-96bc158cbf08` | 8 passed (history: the record before rounds 2 and 3 changed `Service.hs`) |
| Linux at `69cb8670` (a fresh ext4 loop image) | `40d69440-4d8a-42ca-8368-0e4f685e197f` | 8 passed (history) |
| macOS at `61cc3fbb`, the first candidate of round 3 | `05aa74b8-e21c-4a85-8b44-57df7b1ceb78` | **7 passed, 1 FAILED: not the record** (below) |
| **macOS at P `1fd7fdf2`**, macOS 26.7.1 (25G313) arm64, Darwin 25.6.0, Apple clang 21.0.0, GHC 9.14.1, a fresh 3 GiB APFS sparse image (device 16777253, block 4096, total 3,011,469,312 bytes) | `29a10a9a-59e3-481b-9c6b-ce9ad8a086b6` | 8 passed: **the macOS record** |
| **Linux at P `1fd7fdf2`**, Ubuntu 24.04.4 LTS aarch64, Linux 6.8.0-142-generic, gcc 13.3.0, GHC 9.14.1, cabal 3.18.1.0 (the guest shim), the Lima guest `hetoimasia-linux`, a fresh 3 GiB sparse image, mke2fs 1.47.0, ext4 `rw,relatime` (features `has_journal ext_attr resize_inode dir_index filetype needs_recovery extent 64bit flex_bg sparse_super large_file huge_file dir_nlink extra_isize metadata_csum`, default mount options `user_xattr acl`), device 1792, block 4096, total 3,094,126,592 bytes | `17e90cd6-769d-4da1-af9c-99f307c51abc` | 8 passed: **the Linux record** |

Both records were made by `quruntul --repo . test --target terrain-storage-probe --ref HEAD`, one run each, on fixtures made by the scripts under `tools/terrain-storage/` and torn down by exact path (the APFS image detached and deleted, the loop mount unmounted and its image removed, the pointer files removed); the Linux guest was started and stopped for the run (posted each time), with guest `sudo` for the one capped loop mount only. The logs and host identities are kept with the run records (`macos-run-P2-29a10a9a.log`, `linux-run-P-17e90cd6.log`, `linux-identity-P.txt` in the run evidence).

### A failed run, and its cause (`05aa74b8-e21c-4a85-8b44-57df7b1ceb78` at `61cc3fbb`)

7 of 8 examples passed, including the new allocation-granularity assertions. The failing example (write, read back and rewrite with the volume exhausted) had passed every service assertion (the volume exhausted by the filler at 2,898,460,672 bytes, the whole reserved range rewritten with no new allocation needed in 0.048 s) and then failed in the probe's own helper: `user error IoFailure {ioOp = IoCreate, ioKind = IoErrno (Errno 28)}` at `ProbeSpec.hs:251`. The helper measured free space by *creating* a private temp file, and was called by the bounded reclamation poll right after the filler was released; APFS gives a closed, unlinked file's blocks back lazily, the volume still reported itself full at the first observation, so the create failed with `ENOSPC` instead of the poll treating it as "not recovered yet". A probe-helper defect (needing free space to measure free space), not a service one: the service is not on the failing path and the earlier macOS runs passed because the first poll found the space back. Fixed at `1fd7fdf2`: **free space is read with `fstat`/`fstatfs` on a descriptor the probe opens before anything is allocated and holds for the example (`Meter`), and no function in the probe measures free space by creating a file.**

The class was walked, not only the instance. The exhausted phase (between "the volume is exhausted" and "the filler is released and its space is seen back") exists in two examples. Inside it nothing creates a file or a name or needs a new allocation: the rewrite writes into pages already allocated (an asserted "no new allocation"), the refused growth is refused at the headroom precheck before any native allocation (an asserted refusal). After it, only the poll created a file (both examples): closed by the `Meter`. The unlink and close example read free space the same way on a non-exhausted volume (the same lag hazard): closed too. A new guard asserts that the backend's own native `create` count is unchanged across the exhausted phase. The record lines and the run log are written to stdout and captured by the lab under the main checkout's `.git/quruntul/runs/`, on the host drive; the probe writes no file of its own; so nothing but the probe's own filler and backing writes touches the fixture volume.

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

## Records (from the run logs of the runs at P)

| Observation | APFS | ext4 |
| --- | --- | --- |
| Reserved 64 MiB: allocated / overhead | 67,108,864 / 0 | 67,108,864 / 0 |
| Reserved 256 MiB | 268,435,456 / 0 | 268,435,456 / 0 |
| Reserved 1 GiB (the default allowance) | 1,073,741,824 / 0 | 1,073,745,920 / 4,096 (an extent block) |
| Growth 64 to 128 MiB | allocated 134,217,728, overhead 0 | allocated 134,217,728, overhead 0 |
| Every page of the allowance written, then read back | passed | passed |
| Allocated size a whole multiple of the reported block size (asserted; block 4,096 on both) | passed (64 MiB, 256 MiB, 1 GiB, the grown 128 MiB) | passed (the same) |
| Volume exhausted by a filler (bytes taken) | 2,898,460,672 | 2,849,153,024 |
| Allowance rewritten with the volume exhausted | passed, no new allocation | passed, no new allocation |
| Growth with the volume exhausted | `reservation_failed`, old data intact | `reservation_failed`, old data intact |
| Failed release then explicit retry: allocated | 67,108,864 | 67,112,960 (one block of bookkeeping stays accounted) |
| Unlinked file held by a borrower; reserved bytes / reclaimed after last close | 67,108,864 / 67,108,864 | 67,108,864 / 67,108,864 |
| Unlisted filesystem name | `storage_unsupported` | `storage_unsupported` |
| `tmpfs` (`/dev/shm`) | not applicable | `storage_unsupported` |
| Sparse-size negative control | `reservation_failed` (`CoverageShort`) | `reservation_failed` (`CoverageShort`) |
| Latency, reserve 64 MiB / 256 MiB / 1 GiB (seconds, one run, no deadline claimed) | 1.1e-4 / 1.3e-4 / 1.9e-4 | 1.0e-4 / 1.4e-4 / 3.6e-4 |
| Latency, write then read back the 64 MiB allowance | 0.045 s and 0.018 s | 0.023 s and 0.015 s |

Model accounting, actual allocation and process RSS are three different figures: the model charges the allowance and its configured overhead; the actual allocation is `st_blocks * 512`, above; RSS was not measured. The worst space peak of a growth is the allocation after it (134,217,728 on both). Growth, release and unlink behaviour found on the way, from the native experiments run before the backend was written (APFS, same image type): preallocation past the end of the file is counted in `st_blocks` and in the volume's free space at once; `ftruncate` to the length the file already has does not release it; raising the length and then shortening it does, which is why a release raises the length first (`releaseExtra`); a failed `F_ALLOCATEALL` leaves nothing allocated and answers `ENOSPC`.

## Causal lifetime and fault traces, buffer, descriptor and queue counts

These are the routine examples, in `terrain-runtime-tests` (`Test.TerrainRuntime.Storage.*`): the seam records every native call, so the traces are the calls themselves. Queue and worker counts: eight queued and two running at saturation, a ninth refused, ten records, control charge 10 times `jobRecordBytes`, staging and cache holding only the two running transfers (Lifetime, "runs two jobs and queues eight"). Offsets: every short-transfer boundary asserted call by call (Io). Descriptors: every failed open ends with none open and no name left. The accounted job record (`jobRecordBytes`, 4,096 bytes) is measured against the live heap by the Memory examples; the measured largest queued open was 1,101 to 1,585 bytes (a 512-byte path included) and a queued read 576 to 1,058, and the largest record with the largest retained outcome 2,388 to 2,413 (the 200-repeat table under "After round 3").

## Routine-suite wall time and repeats

`terrain-runtime-tests` at P: 631 examples, 0 failures, finished in 836.2130 seconds on this Mac (the brief's baseline is about 16 minutes); at `61cc3fbb`, the code head before the probe-only commit, 631 examples in 830.7 s; earlier candidates 613 examples (829 to 832 s), 602 (858.7 s) and 584 (1,042.8 s). The storage examples are a few tens of seconds of it; no capacity, latency or filesystem experiment is in the routine suite, those are the probe. The owned-start guard passes 63 of 63 and `cabal check` is clean. The storage dev loop (`storage-dev`, never committed) runs the 81 storage examples in about 5 seconds.

The memory rows were run 200 times in one process (a repeat runner over `Memory.spec`, `spec2`, `spec3`, never committed): all 200 passed; the table is under "After round 3". Repeats on the platforms: macOS 40 runs of the storage examples at an earlier candidate and 6 at `69cb8670`, Linux 25 runs at an early candidate (2 ext4-accounting failures, since fixed), 10 at `14f9acf4` and 5 at `69cb8670`, 0 failures at the last three; the rounds 2 and 3 changes were not repeated on Linux (portable code; the pull request's Linux CI runs the routine suite).

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

## Round 3 of review, answered

Round 3 (head `05cdb6e2`, Codex) requested changes with seven findings (1 P1, 6 P2); round 2's seven are verified fixed. Two of the seven were the manager's misses and were corrected as such: finding 1 (an earlier statement that a worker ending at the "Backing opened" log is unreachable) and finding 7 (an earlier decision not to re-run the probe). Each finding was repaired as a **class**, with one owner and a table enumerating every member (the package README, "Ownership at every instant").

| # | Finding (P) | What was wrong | The one owner | Example (class) | Control that bites |
| --- | --- | --- | --- | --- | --- |
| 1 (P1) | a worker exits through the "Backing opened" diagnostic with admission still open | the rethrow was outside the failure handler: the worker ended, `stPhase` stayed `Running`, later submissions were accepted and never ran | `workerLoop` runs the one `stopService` for every exit but its stop token; `runJob`'s defect path uses it; the dispatch is masked with no unmasked region; invariants: admission open implies both workers alive, running jobs <= workers alive | the exit points (the diagnostic, the dispatch wait, a defect), the service kept running | A1 (no stop), A2 (stop without closing admission), A3 (workers never counted) |
| 2 (P2) | a closing backing's charges were released before the native close returned | `claim` released the grant and the volume reservation while the descriptor, the allocation and the entry were still live | the closing record `stClosingRecs`: the claim moves the entry whole and releases nothing; `finishClosing` releases in one transaction after the native close; checker: both ledgers equal backings plus closing records | the charge table: one example per charge kind with the native call held and both ledgers asserted during it | B1 (the claim releases early), B2 (a release subtracts before its call) |
| 3 (P2) | failures nobody received were lost | a discarded `Opened`'s close report was thrown away; `closeBackingId` rethrew a remembered cancellation before returning the report | `keepEvidence`: the one keeper (bounded 64, each charged, drops counted and reported); `closeUnwaited`; `closeBackingId` keeps before it rethrows | a discarded open whose close fails; a close that receives a cancellation instead of its report; 64 kept and the rest counted | C1 (no keeper), C2 (rethrow before keeping), C3 (silent drop) |
| 4 (P2) | a prepared growth was unrecoverable when delivery failed | a `withOutcome` callback that raised retired the ticket while the slot stayed `GPrepared` with the token never retained | a delivery has three ends: `jDelivered` and `finishDelivery`; a failed delivery goes through the one disposal; for `Opened` the backing is closed (decision stated) | the matrix events TakeRaises and TakeCancelled, 24 cells each | D1 (retire without disposal), D2 (a raised callback marked delivered), D3 (disposed though delivered) |
| 5 (P2) | a write's result metadata was uncharged | `execWrite` built a report of up to 256 entries with only the fixed record charged | `jobCharge`: the report's bounded metadata is charged at admission (`writeEntryBytes`, `writeFailureBytes`); every retained structure is a measured row | the Memory table: every work variant, every outcome at its largest, 200 repeats | E1 (entry charged below its size), E2 (record charged below the largest outcome) |
| 6 (P2) | the headroom guarantee ignored native overhead | the precheck subtracted only the requested length; ext4 allocates 4,096 bytes more at 1 GiB | the headroom is verified again, under the same volume coordination, with the bytes the file actually gained; refuse and give back | open and growth with exactly the length and the headroom available and a seam that over-allocates 4,096: refused and unwound; with the overhead available: admitted | F1 (the second check removed) |
| 7 (P2) | the probe runs were not at the candidate | the runs at `69cb8670` predate the rounds 2 and 3 changes to `Service.hs`, `File.hs` and `Volume.hs` | one run per host at P through the lab | the runs above; the failed run at `61cc3fbb` is kept with its cause and the helper fix | n/a |

## After round 3

The manager's reads of the repair found three more things and asked for one measurement to be made structural; all are done:

1. **The dispatch window.** `workerLoop` had `restore` around the dispatch transaction, so a cancellation could land after the transaction committed (the job `JRunning`) and before `restore` returned: the handler stopped the service but that job was running for ever with no worker and the service's end hung. The dispatch is now masked with no unmasked region (under `mask`, `atomically` is interruptible exactly while blocked in a retry), and the other three restore sites were walked (nothing is committed inside any unmasked region). The invariant that would have caught it, running jobs <= workers alive, is in the checker. There is **no deterministic example of the window** (the commit and the return of `restore` have nothing between them to hook), so it is held by structure and the invariant (the honest list).
2. **The memory rows are stable.** Every row was run 200 times in one process. The first run found one failure in 80 iterations in an existing row (the backing record measured 12,653 against 4,096); it was a single-sample average with a pending variant whose "measurement" was negative noise. The row is now measured as a value: the entry at its largest variant (`GReleasing (Just prepared)`: the growth slot is the only varying field, `GReleasing` holds a `Maybe` of the six-field `PreparedGrowth`; a pending reservation present; a real control grant; with its backing-map node and its volume-ledger node) against `backingRecordBytes`, with the service-level least-of-15 open and close as a cross-check that must also be at least the standalone entry. The least of several samples is sound only for independent samples (noise only adds); an earlier attempt to take the least of three on three rows under-measured because the samples were not independent and was reverted. The held result charge went from 4,608 to 4,864 a page and the kept failure from 256 to 320 for a margin of at least 10 percent.
3. **`jobCharge` is internal.** It takes `Work`, which the public module does not export; the public list keeps the plain constants. The Opacity examples (clients that import only the public module; the `storage` sublibrary is `visibility: private`; a client importing `Internal.Service` is rejected) prove the constructors that `Internal.Service` now exports for tests are unreachable.
4. **The probe asserts granularity** (allocated bytes a whole multiple of the reported block size, on both hosts), and its free-space helper was repaired (above).

### The lifecycle matrix, as run

lifecycle matrix: 192 cells (6 kinds x 4 phases x 8 events): 127 with an effect, 54 refusals, 11 not applicable (not run)

6 kinds of work by 4 phases by 8 events; E an effect, R a refusal, - not applicable (not run):

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
| CleanupException | Queued | refusal | no outcome yet: the callback never runs |
| CleanupException | Running | refusal | no outcome yet: the callback never runs |
| CleanupException | Done | effect | the take's callback " <> how <> ": the outcome nobody received is disposed of by the one disposal (an opened backing is closed with its report kept, a prepared growth becomes a recoverable pending reservation, the record is retired) |
| CleanupException | Borrowed | effect | a nested take's callback " <> how <> " while another borrower holds the outcome: nothing is disposed of; the borrower's delivery stands (an opened backing stays open, the growth token stays valid) |
| TakeRaises | Queued | refusal | no outcome yet: the callback never runs |
| TakeRaises | Running | refusal | no outcome yet: the callback never runs |
| TakeRaises | Done | effect | the take's callback raises: the outcome nobody received is disposed of by the one disposal (an opened backing is closed with its report kept, a prepared growth becomes a recoverable pending reservation, the record is retired) |
| TakeRaises | Borrowed | effect | a nested take's callback raises while another borrower holds the outcome: nothing is disposed of; the borrower's delivery stands (an opened backing stays open, the growth token stays valid) |
| TakeCancelled | Queued | refusal | no outcome yet: the callback never runs |
| TakeCancelled | Running | refusal | no outcome yet: the callback never runs |
| TakeCancelled | Done | effect | the take's callback is cancelled (an exception of the asynchronous type): the outcome nobody received is disposed of by the one disposal (an opened backing is closed with its report kept, a prepared growth becomes a recoverable pending reservation, the record is retired) |
| TakeCancelled | Borrowed | effect | a nested take's callback is cancelled (an exception of the asynchronous type) while another borrower holds the outcome: nothing is disposed of; the borrower's delivery stands (an opened backing stays open, the growth token stays valid) |

### The memory rows (200 repeats in one process: 0 failures; minimum and maximum measured against the charge)

```
row                                                                                                     n       min       max   charged max/charged
queued queued read record                                                                             200       576      1058      4096        0.26
queued queued open record                                                                             200      1101      1585      4096        0.39
held 256-page read buffer+record                                                                      200   1065336   1065336   1089536        0.98
held 256-page result+record                                                                           200   1096392   1128272   1249280        0.90
backing, service-level cross-check (least of 15 open+close)                                           200      1984      2296      4096        0.56
backing entry, largest variant (GReleasing (Just prepared), a pending reservation), standalone, with  200       324       329      4096        0.08
queued write, 256 pages                                                                               200      1368      5176     33280        0.16
running write, 255 results held                                                                       200     28768     28800     33280        0.87
finished write report, 256 pages written                                                              200     20541     20541     29184        0.70
finished write report, first page failed, 255 not attempted                                           200     20709     20710     29184        0.71
largest open record plus a retained Opened                                                            200      1180      1242      4096        0.30
largest open record plus a retained GrowthPrepared                                                    200      1204      1266      4096        0.31
largest open record plus a retained Released or GrowthNoChange                                        200      1068      1130      4096        0.28
largest open record plus a retained Failed (a defect text of 256 four-byte characters, 4 notes)       200      2388      2413      4096        0.59
largest open record plus a retained Cancelled (4 notes)                                               200      1324      1349      4096        0.33
kept failure (per entry, the list full)                                                               200       196       245       320        0.77
closing record (the entry moved, per backing)                                                         200      1696      1696      4096        0.41
guard (cross-check >= standalone entry): min margin 1570.56
```

The retained-outcome rows are standalone values (the structure itself), the held read buffer is deterministic (minimum equals maximum), the rows with spread keep a margin of at least 10 percent of their charge, and the backing record is the standalone entry (324 to 329) with the service-level cross-check (the least of 15, 1,984 to 2,296) and its guard (the minimum margin of the cross-check over the standalone entry was 1,570 bytes). `backingRecordBytes` (4,096) is conservative, about 12 times the value; over-charging is the safe direction and no example needs the room, so it was not lowered.

### The ownership sweep and the exit points

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

The 63 cases are followed by the startup rows. The three exit points (the diagnostic after a finished job, the dispatch wait, a defect in a job) are separate examples with the service kept running (the package README, item 8).

### The controls of rounds 2 and 3 (each applied once to the committed source, the examples run, then reverted; never committed)

Each was read in its failure output: it fails for the reason named, not by a build error or a hang.

| Id | Mutation | Bites in |
| --- | --- | --- |
| S1, S1b | a queued growth or abandonment withdrawn without reversing its admission | the matrix, Grow and Abandon x Queued |
| S2 | a discarded preparation not made a pending reservation | the matrix, Grow x Done and Running x Discard |
| S2b, M1 | the cleanup notes of an undelivered outcome dropped | the dedicated example and the untaken cleanup cells |
| S3, T2 | the closing record not tracked or the drain not waiting for it | "joins a close another caller claimed" |
| S3b, K2, K3 | a finished open job not linked to its backing; the Open close cell closing the wrong backing | "borrows the opened backing", the Open x Borrowed x Close cell |
| S4, S5, T1, T3, X1 to X5 | the unlink cleanup raising prevents the close; `withOutcome` loses its context; a raising log before the bookkeeping; `quietly` rethrowing an asynchronous exception | the dedicated examples |
| K1, K4, M2 to M6 | the drain not awaiting a held worker; the close claim ignoring borrowers; a taken outcome losing its notes; the injected fault never firing; closing admission or a close not withdrawing queued jobs; a raising release not keeping the extra pending | the matrix, shutdown, Close and cleanup cells |
| A1 | a worker that ends other than by its stop does not stop the service | the exit points |
| A2 | the one stop does not close admission | the exit points |
| A3 | workers are never counted (admission open with no worker alive) | the exit points, through the paired invariants |
| B1 | the claim releases the grant and the reservation before the native close | the charge table (the close held) |
| B2 | a release gives the extra back to the ledger before its set-length returned | the charge table (release and abandon held) |
| C1 | the failing close of an unattended close has no keeper | "keeps the failing close of a finished open that is discarded" |
| C2 | a cancellation is rethrown before the failing report is kept | "keeps the failing report of a close whose caller receives a cancellation instead" |
| C3 | a failure with no room is dropped silently | "counts the failures it has no room to keep" |
| D1 | a failed delivery retires the record without the one disposal | the matrix, TakeRaises and TakeCancelled x Done |
| D2 | a callback that raised is marked delivered | the same |
| D3 | a delivery another borrower received is disposed of anyway | the matrix, the same events x Borrowed |
| E1 | a write report entry charged at 8 bytes | the Memory table (the running write and the reports) |
| E2 | the job record charged at 2,048 (its value before round 3) | the Memory table (the retained Failed) |
| F1 | the headroom not re-verified with the obtained bytes | the open and growth boundary examples |


## Requirement self-audit of #663 (items 1 to 10 and every sentence of Acceptance)

Status is *met*, *met after round 3*, *met by decision*, *limitation* or *not claimed*; every row names its code, example or evidence.

| # | Requirement (issue #663 body, its approving comment, Acceptance) | Status | Met by (code / example / evidence) |
| --- | --- | --- | --- |
| 1a | One private exclusive file per incarnation; close-on-exec; unlink before readiness; no handle before setup/reservation complete | met | `File.createPrivate` (`O_CREAT\|O_EXCL\|O_NOFOLLOW\|O_CLOEXEC`, 0600), `verifyPrivate`, the open job's registration transaction; Open examples (10 stages; child process) |
| 1b | Failure unwinds with retained cleanup evidence; the file's own volume (not the cwd) | met | `execOpen` unwind (independent steps), `Volume.profileOf` on the descriptor; sweep rows; cleanup cells |
| 1c | Opaque scoped authorities tied to the incarnation; descriptor numbers not forgeable | met | `Backing`/`Ticket` (hidden constructors, service `Unique`), Opacity examples (external client) |
| 1d | Owner, users, thread, lifetime, cancellation, release of files/jobs/buffers/records specified | met | README "State, owner, thread and lifetime" table and the charge table |
| 1e | Unlink retains the file until the last close, tested on both targets | met at P | probe "keeps the file after its name is gone" (APFS, ext4) |
| 2a | Allowance 1 GiB default, 64 MiB minimum, MiB alignment, offset limit | met | sizes re-validated at the boundary (`growthSizeError`); `StoreConfig` is #662's |
| 2b | Real reservation: `F_PREALLOCATE`/`F_ALLOCATEALL`, `fallocate`, checked length, allocated coverage; sparse file is not a reservation | met | `File.reserveRange` + `hts_reserve`; sparse control example; probe |
| 2c | 256 MiB headroom after the proposed reservation, growth included; concurrent reservations coordinated | met after round 3 (finding 6) | precheck + a second check with the bytes actually obtained, under `withVolume`; boundary examples for open and growth with a 4,096-byte overhead |
| 2d | `storage_unsupported` vs `reservation_failed`; malformed sizes refused before work; qualified list | met | `Types.StorageFailure`, `qualifies`, Open stage table, probe tmpfs and unlisted name |
| 2e | Physical overhead reported to the model and charged before admission; the 8 MiB reserve stays inside the cap | met | `Reservation` carries the overhead; the open and growth are refused when it exceeds the model's (`OverheadExceedsModel`) |
| 2f | "verified allocated coverage/granularity" | met for coverage and overhead; granularity is reported (`rsBlockSize`), not separately asserted | `Reservation`, probe records (block size 4,096 on both) |
| 3a | Exactly two workers, eight queued descriptors, 1 MiB jobs, shared across arenas | met | `startWorkers`, `maxQueuedJobs`, `maxIoJobBytes`; Lifetime "runs two jobs and queues eight" |
| 3b | Buffer allocated at dispatch; queued writes reference staged pages without copying; shared buffers once, extra records separately | met | `dispatchNext` charges; a write's report metadata is charged at admission (round 3, finding 5) and measured |
| 3c | The shared edit-bank envelope; the 4 MiB foreground staging; no partial job/reservation; accepted work keeps its bookkeeping | met | `admitJob` all-or-nothing, camera limited to the unprotected share, grants held until retirement; Memory rows |
| 3d | One mutating transaction per session; reads beside it; explicit before camera with fair progress | met | mutation slot, `offerOrder`; Lifetime scheduling examples |
| 3e | Native calls off the owner; no forced interruption; cancellation is an ownership protocol | met | every FFI call `safe`, none `unsafe`/`interruptible`; held-call examples; the closing record keeps what a native call pays for until it returns (round 3, finding 2) |
| 3f | Workers never publish roots and never retain Lua values | met | outcomes only; no root type is imported |
| 4 | Exact reads/writes: checked offsets, short transfers, EINTR, zero progress, premature EOF, `storage_io` vs `storage_integrity`, no `fsync` | met | `File.readFully`/`writeFully`; Io examples (every boundary) |
| 5 | Effects separate from publication; late/duplicate/cancelled result cannot target a replacement; uses held until return; old pages survive every prefix | met | tickets/`Backing` identities; Io "preserves every old committed page... after any prefix"; Lifetime cancellation |
| 6 | Serialized checked growth; no-op; refused shrink; prepared not spendable; rollback releases only the new space; failed release retained, charged, blocking; explicit retry/close | met | growth state table; Growth examples; the matrix (queued withdrawal, discard, failed delivery recoverable) |
| 7a | Close admission, withdraw queued jobs, drain, close the file, release; every acquired thing keeps an owner on startup failure, worker failure, exit, cancellation, one arena closing | met after round 3 (finding 1, 2) | `drainService`; the one worker stop; the closing record |
| 7b | "Close the file through `withResource`/the established scoped facilities" | met by decision: the owned-table close protocol is kept (the package README, item 10: neither collection of `docs/resources.md` can own a backing's descriptor; `withStorageService` is the lexical final owner; each guarantee has its example) | the README table of guarantees and examples |
| 7c | Wait in the protected boundary, no timeout/detach; primary and labelled cleanup failures preserved; never blindly retry a close | met after round 3 (finding 3) | `protectedly`; the keeper of every failure; the exactly-once close |
| 7d | Qualify close-error and interrupted-close behaviour on the platforms | limitation, retained and stated: an injected `EIO` and a thrown exception are tested; a real failure or `EINTR` of `close` cannot be induced on the qualified filesystems; the policy (never retry) is in the README, item 11, and the decision is the owner's | evidence README "not claimed" |
| 8 | Deterministic coverage: production backend and seam, gates, no sleeps; the listed cases | met | the storage examples; the matrix, sweep and property; the only timers are two bounded probe polls |
| 9a | `terrain-storage-probe`, cataloged optional, `category: probe`, no CI route, Darwin and Linux | met | catalog `test.terrain-storage-qualification` |
| 9b | Probe qualification on macOS/APFS and a named Linux filesystem (ext4), real evidence, capped fixtures, sparse negative control, rewrite under exhaustion, failed/partial growth | met at P | evidence README, run IDs `4f3965bc…`, `40d69440…` |
| 9c | **"one qualification run on each required host at the candidate revision"** (Acceptance) | **met at P**: one run on each host at the exact candidate, macOS `29a10a9a` and Linux `17e90cd6`, both 8 of 8 (the failed run `05aa74b8` at `61cc3fbb` is kept with its cause) | the runs under "Commands and run identifiers" |
| 10a | README, module contracts, `docs/test_suites.md`, `docs/test_classification.md` (eight to nine), `docs/validation.md` registered-groups row | met | landed docs |
| 10b | Logging injected with bounded context; expected failures are domain results; defects are host failures | met | `terrain.storage` logger; `HostFailure` |
| 10c | Evidence under `docs/evidence/terrain/tra21/`: commands, run IDs, identities, fixture caps, allocation/overhead, traces, counts, latency; model vs actual vs RSS distinguished | met, updated at P | evidence README |
| A1 | Acceptance commands: versions, build, the three suites, `cabal check`, `plan.py --catalog-check` and the plan | met at the head | the PR body's Acceptance table |
| A2 | The planner leaves the optional probe unselected unless requested | met | `plan.py`: `optional-unrequested` |
| A3 | "The old committed pages must survive every injected partial-write/growth failure" | met | Io prefix examples; growth examples |
| A4 | "No state or space is falsely released while a borrower/native call remains" | met after round 3 (finding 2) | the closing record; the charge table with a held native call and both ledgers asserted during it |
| A5 | "Queued/active counts stay at eight/two and all buffers fit #662's limits" | met | Lifetime counts; Memory rows |
| A6 | "Actual reservation and last-close reclamation demonstrated; unsupported profiles refuse" | met at P | probe records |
| A7 | "No live terrain publication, Lua settlement or crash-recovery qualification is claimed" | claimed nowhere | evidence README "Not claimed" |

## What is not reached, and what is policy (the honest list, after round 3)

Not reached by any control or example, with the reason:

* **The dispatch window**: a cancellation landing between the dispatch transaction's commit and the return of the removed unmasked region. There is no seam or gate there (nothing happens between them), so it is held by structure (no unmasked region, the comment says why) and the invariants (running jobs <= workers alive, admission open implies both workers alive).
* **Two paths with no hook**: the remembered cancellation out of an unwaited close inside `runJob`, and the running-discard path of an `Opened` outcome. Both need a discard to land between the open's registration and `finishJob`; they run the same functions as the examples that do run (`closeUnwaited`, the one disposal), covered by structure and the controls of those functions.
* **Three exit rows, not every delivery point**: the exit points enumerated are the diagnostic after a finished job, the dispatch wait and a defect; an asynchronous exception can be delivered at other interruptible points inside a job, where `runJob` catches it as a defect (the third row).
* **Interleavings between two transactions** the gates do not reach (the drain-and-claim atomicity is by construction; its mutations are caught through observed waits); an exception from the kernel after a native side effect (modelled only for `close`); a real `EINTR` or failure of `close` (the limitation below); whether the owner actually drops cache when `svWaitingForCache` is positive (TRA-22's).
* **The matrix** does not combine two events on one job (a cancel racing a close) beyond what the sweep and the property do; a cleanup-exception cell injects one fault, not a cascade (the dedicated examples repeat the unlink fault twice).
* **Heap measurement** is a forced live heap: the margins are stated per row and the table is 200 repeats of one process, not a proof for every future heap state; the held read buffer's margin is 2.2 percent but it is deterministic.
* **The platforms**: one run on one APFS image and one ext4 loop image of 3 GiB each; no other filesystem, kernel or macOS release, no durability (`fsync`), crash or power-loss claim, no throughput or latency deadline. The rounds 2 and 3 changes were not repeated on Linux outside the platform record (portable code; CI runs the routine suite).

Policy, stated as policy and not as a gap:

* **Reversed in round 3:** a worker that ends at any point, including by a cancellation at the "Backing opened" log, **stops the service** (admission closed, queued work settled, the reason recorded). The earlier text, that such a worker does not stop the service because it is unreachable through the public API, was wrong: a `Logger` is a public port.
* A cancellation delivered to a worker inside an open's cleanup step is recorded as one more cleanup failure of that step and is not redelivered; a cancellation at the log of a defect is dropped with the entry because the worker ends with the defect either way.
* A release that raises is a defect (host failure, service stopped, the extra kept as a pending reservation), not a cleanup failure with notes; the worker's defect is what supervision sees.
* A diagnostic never changes the outcome of the work it describes: a logger that raises is dropped, and an asynchronous exception reaching it is delivered after the bookkeeping.
* A failed delivery of an opened backing closes it (nobody can name it); a nested take that raises while another borrower holds the outcome disposes of nothing.
* `backingRecordBytes` is conservative on purpose (4,096 against a 324 to 329 byte value and a 1,984 to 2,296 byte service-level cross-check).
* **A real failure of `close`** cannot be induced on the two qualified filesystems; the exact limitation is retained and the decision is the owner's. Linux documents that a failed close may follow the release of the descriptor and that retrying it is wrong (the issue quotes it and forbids generalising it); the macOS behaviour was not qualified and nothing was observed. The policy is the same on both: the close is made once, a failure is kept and reported, and it is never retried.
