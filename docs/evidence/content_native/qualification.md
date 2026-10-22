# hetoimasia-content native qualification record (#518, LFE-4)

Retained evidence for the native calls and flags of `packages/content`
([its contract](../../../packages/content/README.md)). The contract is in the
README; this record is what was observed, on which platform, and which evidence
is native and which is injected. It claims nothing about hashing, logical names
or the launcher, which are not delivered by #518.

## Platforms

| | Local | Linux CI |
|---|---|---|
| OS | macOS 26.7.1 (Darwin 25.6.0, arm64) | the validation container (`.github/workflows/validation.yml`) |
| Filesystem of the fixtures | APFS (`/var/folders/...`, itself reached through the `/var → /private/var` link) | the container's temporary filesystem |
| Effective user | non-root (uid 501) | root (the validation container runs as root) |
| Toolchain | GHC 9.14.1, Cabal 3.18.1.0, Apple clang 21 | the qualified image |
| Group | `test.content` run locally, `cabal.project.cpu` | `test.content` on the `haskell-engine` worker |

The local column is what the author ran. The Linux column is the pull request's
CI run on the validation container (head `4a0537fb`, the `haskell-engine` job):
`content-tests` ran **114 examples, 0 failures, 2 pending**. The two pending are
the real `chmod` cases, which a root user cannot exercise (their injected
counterparts ran); every other example ran natively, including the real
non-UTF-8 file name, which Linux accepts and APFS refuses.

## What the native calls did (macOS, observed)

A throwaway C probe (not part of the repository) opened each kind of entry
beneath a directory descriptor with the service's exact flags,
`O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_NOCTTY`, with and without
`O_DIRECTORY`:

| Entry and flags | Result |
|---|---|
| regular file | descriptor |
| directory, no `O_DIRECTORY` | descriptor (so the type check on the opened object is the gate) |
| directory, `O_DIRECTORY` | descriptor |
| regular file, `O_DIRECTORY` | `ENOTDIR` |
| symbolic link to a file, final component | `ELOOP` (62) |
| symbolic link to a directory, final component, no `O_DIRECTORY` | `ELOOP` (62) |
| symbolic link to a directory, final component, `O_DIRECTORY` | **`ENOTDIR`**, not `ELOOP` |
| FIFO, read-only, `O_NONBLOCK`, no writer | descriptor, immediately |
| FIFO, `O_DIRECTORY` | `ENOTDIR` |
| UNIX-domain socket node | **`EOPNOTSUPP` (102)** |
| socket node, `O_DIRECTORY` | `ENOTDIR` |
| absent entry | `ENOENT` |
| `link-to-dir/x`, one multi-component `openat` | `ENOENT`: the intermediate link **was followed** |
| `fstatat(AT_SYMLINK_NOFOLLOW)` on the socket node | mode `S_IFSOCK` (0140000) |

Three consequences are built into the design and exercised by the suite:

1. `O_NOFOLLOW` covers only the final component of one `openat`; a multi-component
   path follows intermediate links. Every component is therefore opened by its own
   `openat` relative to the previous component's descriptor.
2. Errno alone cannot classify a refusal: a link met with `O_DIRECTORY` answers
   `ENOTDIR`, a socket answers `EOPNOTSUPP` here (documented `ENXIO` on Linux).
   After a failed open, a no-follow `fstatat` beside the same held parent says
   what the entry is; the kind of an *opened* object always comes from `fstat`.
3. `O_NONBLOCK` makes a FIFO open return at once, so it is refused by its type
   without waiting for a writer.

## Evidence classes in `test.content`

| Case | Evidence |
|---|---|
| Relative, absolute and symlink-selected root; root rename, replacement of the old path, retargeted link; fresh root selects the new target; working directory unchanged | native |
| Internal intermediate and final links, dangling links, links back inside the root, links to outside | native |
| A component or the final file swapped for a link at `BeforeOpen`; a swap after the open | native, gated at named boundaries; a check-then-open control reads the sentinel under the same swap |
| FIFO (no wait), socket (both errno values), directory/file mismatches | native |
| Device, block device, other kinds | injected (adapter kind override) |
| Permission denied | native where the effective user lacks the override (pending as root); injected otherwise |
| Hard links under both names, link count, shared identity | native |
| Mount crossing (another device), directory cycle on the active ancestor chain, the same identity on another branch | **injected** native identities: no mount is created |
| Non-UTF-8 entry name | native where the filesystem accepts one (pending on APFS); supplied raw name elsewhere |
| Short reads, read errors, close errors, failed handover | injected (adapter) |
| Cancellation at each boundary and with a cancellation pending as an open returns; exit waits; exit cancelled while waiting; ownership transfer to a stream | native descriptors, gated |
| Exact acquisition/close accounting, loops of success, refusal and cancellation | adapter-seam log, native descriptors |
| Public boundary | a separately compiled client |

No privileged mount or device was set up, and none is claimed.

## Negative controls

Each change below was applied once to the tree, the suite built and run
under a hard limit, and the source restored; none is committed. "Failed" counts
the examples that went red (the headless suite has 114 examples; 111 and 1
pending locally on APFS when the first sixteen were run, before the two
rounds-1 regressions below were added). Every control was caught.

| Control | Change | Failed |
|---|---|---|
| M1 | `O_NOFOLLOW` removed from the directory-relative open | 10: every link refusal and every swap at an open boundary |
| M2 | no type check on the opened object | 5: FIFO, directory/file mismatches, device kinds, a changed entry, the wrong-type close |
| M3 | the exit does not wait for borrowers | 4: every exit example |
| M4 | a stream's descriptor closed separately as well as by the stream | 17: every example that opens a stream, by the accounting |
| M5 | a failed handover to a stream leaks its descriptor | 2 |
| M6 | a reader is never marked dead | 1 |
| M7 | no cycle rule | 3 |
| M8 | the exit does not close admission | 5 |
| M9 | no classifying `fstatat` after a failed open | 19 |
| M10 | no qualification of the root | 9 |
| M11 | an enumerated entry's kind is not checked before opening | 2 |
| M12 | no depth bound | 2 |
| M13 | an operation that failed or was cancelled does not give its borrow back | every example that runs a failing operation stalls at the scope's exit, which waits uninterruptibly by design, and fails when its 10 s bound ends; six had failed when the 60 s limit on the whole run ended it |
| M14 | an enumerated file is opened as a plain path, not as the entry observed | 1 |
| M15 | an intermediate component is not checked against the ancestor chain | 1 |
| M16 | the exit closes admission after announcing the wait and does not wait | 4 |
| M17 | a cancellation delivered after the wait replaces a failed body's exception (review round 1, P1) | 1: the failed body with cleanup evidence and a cancellation during the wait |
| M18 | `rootReport`, `limitPathDepth` and `limitReadChunk` exported as record labels (review round 1, P2) | 2: the record-update clients |

M13 is the control that matters for cleanup bounds: the exit's wait cannot be
interrupted, so the suite runs each root scope on a child it waits for within a
bound. A leaked borrow therefore fails the example instead of holding the
process.
