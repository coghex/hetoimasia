# TRA-21 evidence: the storage backend on two real platforms

Issue #663, PR #682. The record is one passing run of the local probe on each
host at the candidate `ef998aa3`; the contract is the "storage backend" section
of [the terrain-runtime README](../../../../packages/terrain-runtime/README.md).

The round-by-round write-up (ten review rounds, the sweep and lifecycle
matrices, every control, four failed probe runs and three CI failures with
their causes) is in git history:
`git show 21e527cc:docs/evidence/terrain/tra21/README.md`.

## What is and is not claimed

Claimed, on APFS (macOS) and ext4 (Linux): the production native backend
obtains a real reservation and proves it; writes and rewrites throughout the
reserved range need no new allocation even with the rest of the volume
exhausted; growth under exhaustion is refused with the old data and size
intact; a failed release is retained and freed on retry; an unlinked file is
kept for its borrowers and its space returns after the last close; an
unqualified filesystem is refused; a sparse file of the right length fails the
qualification.

Not claimed: any other filesystem, durability (`fsync`), crash or power-loss
recovery, a throughput or latency promise, behaviour under allocations by other
processes, or a real failure of `close`.

## Commands

```sh
tools/terrain-storage/macos-fixture.sh up <scratch>     # 3 GiB APFS sparse image, attached -nobrowse, no sudo
tools/terrain-storage/linux-fixture.sh up <scratch>     # Linux guest: 3 GiB sparse image, mkfs.ext4, sudo loop mount
quruntul --repo . test --target terrain-storage-probe --ref HEAD
tools/terrain-storage/{macos,linux}-fixture.sh down <scratch>
```

The probe refuses to run without its fixture, and checks before consuming any
space that the fixture is a device distinct from the working and home
directories, owned by the running user and within the 4 GiB cap.

| | macOS | Linux |
| --- | --- | --- |
| Lab run at `ef998aa3` | `5799527a-b7c1-4ddd-9d60-d304a147c4e0`, 8 passed | `e28c7187-4b9b-400f-963a-7f434cfedb25`, 8 passed |
| Host | macOS 26.7.1 (25G313), arm64, Apple M3 Max, GHC 9.14.1 | Ubuntu 24.04.4 aarch64, Linux 6.8.0-142, gcc 13.3.0, GHC 9.14.1, the `hetoimasia-linux` Lima guest |
| Filesystem | `apfs` on a 3 GiB sparse image, block 4,096, 3,011,469,312 B | `ext4` (`rw,relatime`, `extent`, `metadata_csum`, journal) on a 3 GiB loop image, block 4,096, 3,094,126,592 B |
| Reservation call | `fcntl(F_PREALLOCATE)` with `F_ALLOCATEALL` and `F_PEOFPOSMODE` from the end of file, then `ftruncate` | `fallocate(fd, 0, off, len)` |
| Allocated bytes; available bytes | `fstat` `st_blocks * 512`; `fstatfs` `f_bavail * f_bsize` | `st_blocks * 512`; `f_bavail * f_frsize`; the filesystem name from `/proc/self/mountinfo` by device |

## Records

| Observation | APFS | ext4 |
| --- | --- | --- |
| Reserved 64 MiB, 256 MiB: allocated / overhead | exact / 0 | exact / 0 |
| Reserved 1 GiB (the default allowance) | 1,073,741,824 / 0 | 1,073,745,920 / 4,096 (an extent block) |
| Growth 64 to 128 MiB | 134,217,728, overhead 0 | the same |
| Every page of the allowance written, then read back | passed | passed |
| Volume exhausted by a filler (ended on `ENOSPC`) | 2,898,460,672 B taken | 2,849,153,024 B taken |
| After the fill: one more single-block reservation | refused, errno 28 | refused, errno 28 |
| After the fill: available bytes through the meter | **33,681,408** (observed, not explained) | 0 |
| Allowance rewritten with the volume exhausted | allocated 67,108,864 before and after; 0 B of the volume consumed | the same |
| Growth with the volume exhausted | `reservation_failed`; length and allocation unchanged | the same |
| Failed release, then explicit retry: allocated | 67,108,864 | 67,112,960 (one bookkeeping block stays) |
| Unlinked file held by a borrower: reserved / reclaimed after the last close | 67,108,864 / 67,108,864 | the same |
| Unlisted filesystem name | `storage_unsupported` | `storage_unsupported`; `tmpfs` (`/dev/shm`) refused by name with zero reserve calls |
| Sparse file of the right length | `reservation_failed` (`CoverageShort`) | the same |
| Reserve 64 MiB / 256 MiB / 1 GiB, seconds (one run, no deadline claimed) | 1.2e-4 / 1.4e-4 / 1.6e-4 | 9.7e-5 / 1.4e-4 / 3.2e-4 |
| Write, then read back, the 64 MiB allowance | 0.038 s, 0.018 s | 0.022 s, 0.017 s |

Model accounting, actual allocation and process RSS are three different
figures; RSS was not measured. Native behaviour found on APFS before the
backend was written: preallocation past the end of the file is counted in
`st_blocks` and in the volume's free space at once; `ftruncate` to the length
the file already has does not release it, while raising the length and then
shortening it does, which is why a release raises the length first; a failed
`F_ALLOCATEALL` leaves nothing allocated and answers `ENOSPC`.

## The routine suite

The memory rows passed 200 of 200 repeats in one process on each host. Their
method (settled readings, a majority of samples, a noise floor, one needed
signal of the larger of 50 times the floor and 40,000 bytes) is the README's
"Scheduling and accounting". Queue and worker counts at saturation: two
running, eight queued, a ninth refused. The suite's time is in
[the suite-budget record](../suite-budget/README.md).

## Known limits

- **The macOS close-error ownership is not qualified, by the owner's
  decision** (issue #663): a real failure of `close` cannot be induced on
  either filesystem inside the approved fixtures. Only an injected `EIO` and a
  raised close are tested. On macOS a failed close keeps the reservation
  counted and charged until the service ends.
- One run on one image of 3 GiB on each of one macOS release and one Linux
  kernel. The Linux figures are from an aarch64 guest; the CI runner is x86_64
  and runs only the routine suite.
- The cause of one memory-measurement spike on the CI runner (two adjacent
  readings 497,536 B apart) is not known and did not reproduce locally. The
  measurement was rebuilt so that one bad reading or batch cannot move a row.
- The APFS residue after the fill (32.12 MiB reported available, one more
  block refused) is measured and not explained; no claim rests on it.
- Under heavy machine load (load average above 20) the noise-floor example can
  exceed its 10-second bounded wait; it is a failure of the wait, not of an
  assertion.
- The probe's wiring (that its examples call the verdict functions at the
  right points) runs only on a real fixture, so it is checked by the lab runs
  and by reading, not by the routine suite.
