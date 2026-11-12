# TRA-21 evidence: the storage backend on two real platforms

Evidence for [#663](https://github.com/coghex/hetoimasia/issues/663) (own reserved backing files and bounded asynchronous storage I/O). The implementation is in `packages/terrain-runtime` (`storage/`, `probe/`); the contract is its README section "The storage backend (TRA-21)". Candidate revision of the records: `69cb867061ff9c06715a7c879f42c7a7c042605d` on branch `issue-663-storage-backend` (round 2 of review); the earlier records at `e2b97419` are kept below as history.

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
| **Final head** `69cb8670`, macOS (same identity as above) | `4f3965bc-f67a-4275-a0f0-96bc158cbf08` | 8 passed: **the macOS record** |
| **Final head** `69cb8670`, Linux (same identity as above, a fresh ext4 loop image) | `40d69440-4d8a-42ca-8368-0e4f685e197f` | 8 passed: **the Linux record** |

The two final-head runs were taken after the capacity check moved into the probe's mandatory fixture acquisition (round 1 of review); the probe was run on no machine between that finding and the fix. The numbers in the tables below are the final-head runs' (they equal the earlier runs' except where stated).

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

`terrain-runtime-tests` is 602 examples at the final head `69cb8670`, including the storage examples (66 match "Storage backend"; the class examples among them run in about 3 s). Wall time on this Mac, run directly with other load beside it: 858.7 s of examples (1,123 s with its startup) at the final head; 1,042.8 s (584 examples) at an earlier candidate and 1,114 s at `06bc8415`; the brief's baseline for the suite is about 16 minutes. The storage examples are a few seconds of it; no capacity, latency or filesystem experiment is in the routine suite, those are the probe.

Repeats of the storage examples: macOS, 40 runs at an earlier candidate and 6 at the dev loop of the final head, 0 failures. Linux aarch64: an earlier 25 runs found 2 failures, both in the growth release assertions (ext4 keeps one block of bookkeeping accounted after a release, where the assertion demanded exact equality), since changed to "within one block"; then 10 runs at `14f9acf4` and 5 runs at the final head `69cb8670`, run with `terrain-runtime-tests --match "Storage backend"` (66 examples), 0 failures.

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

All bite: B1 abandon does not revoke commit; B2 publication does not arbitrate cancellation; B3 the token compared without its attempt identity; B4 sizes not validated; C1 an exception in open does not close the descriptor; C2 a failed final query treated as obtaining nothing; C4 the close without its drain check; D1 a running ticket's discard not marked; D2 shutdown does not retire the records; D3 eviction allowed; E1 started workers not stopped or joined on a failed start; E2 a close giving back only the length; E3 a closing backing still takes borrowers; E4 the pressure signal not reported. Earlier controls (round 0) are in the first list above.

### What a control cannot catch (the honest list)

Races between two transactions at interleavings the gates do not reach (the matrix injects at gate points; the drain-and-claim atomicity is by construction, and its mutation is caught through the gated-close example, not through a deterministic interleaving); an exception raised by the kernel after a native side effect (modelled only for `close`, whose call is made and then raises; the others raise before the call); asynchronous exceptions delivered to a worker (workers run masked by design, the cancellation is a request); a real `EINTR` from `close`; that the owner actually drops cache when `svWaitingForCache` is positive (the owner is TRA-22's).

### A bug the sweep found

`protectedly`, the wait the drain and the close use to remember an interruption and deliver it afterwards, recognised asynchronous exceptions with `asyncExceptionFromException` at the wrong type, so an interruption of a closing thread aborted the close and left the descriptor open (and would have aborted a drain). The "cancellation" injection of the close row failed with one descriptor leaked; fixed to `fromException` at `SomeAsyncException`.

