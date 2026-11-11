# TRA-21 evidence: the storage backend on two real platforms

Evidence for [#663](https://github.com/coghex/hetoimasia/issues/663) (own reserved backing files and bounded asynchronous storage I/O). The implementation is in `packages/terrain-runtime` (`storage/`, `probe/`); the contract is its README section "The storage backend (TRA-21)". Candidate revision of both records: `e2b97419bd276401ab58f2cd588090ff1fd4c177` on branch `issue-663-storage-backend`.

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
| Ubuntu 24.04.4 LTS aarch64, Linux 6.8.0-142-generic, gcc 13.3.0, GHC 9.14.1, cabal 3.18.1.0, in the owner's `hetoimasia-linux` Lima VM (guest-local checkout cloned from the read-only worktree mount) | `b932136e-8b6a-4669-97fa-77363abb7e0e` | 8 passed |

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

`terrain-runtime-tests` (584 examples) took 1,042.8 s on this Mac at the candidate before the last probe-only commits; the storage examples are 48 of them and about 4 s of that. macOS, 40 repeats of the storage examples: 0 failures. Linux aarch64, 25 repeats: 2 failures, both in the growth release assertions (ext4 keeps one block of bookkeeping accounted after a release, where the assertion demanded exact equality); the assertion is now "within one block" and the repeats were rerun at the final head (see the pull request).

## Negative controls

Each was applied once locally to the committed source, the affected examples run, then reverted, never committed: the coverage check removed (the sparse example fails), the offset not advanced after a short transfer (the short I/O examples fail), a running job's cancellation releasing its resources early (the cancellation example fails), a failed close retried (the "never closes twice" example fails), a prepared growth made spendable (the "not spendable" example fails), the volume coordination removed (the serialization example fails), the fair-progress rule removed (the scheduling example fails), the close not waiting for the drain (the example's thread blocks forever, a failure). Not exercised as a control: the interrupted-call retry cap (the storm example asserts the bound, but the cap itself was not mutated) and the descriptor-leak check on a child `exec`.
