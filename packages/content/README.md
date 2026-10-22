# hetoimasia-content

Anchored, no-follow reading of one launcher-selected content folder (LFE-4 of
[the Lua-first design](../../docs/designs/lua_first_engine_design.md), decisions
D-11, D-63 and D-64).

`withContentRoot` resolves a launch path **once**, opens the directory it
actually names and keeps that directory for the rest of a scope. Every other
operation is relative to it: `withFile` and `withDirectory` open a root-relative
path one component at a time without following a symbolic link, check the type
of the object they actually opened, and lend the result to a callback as a
bounded, strict reader. Once the root is open nothing is a pathname, and nothing
is cached: when a callback returns, every descriptor it used is closed.

The package reads. It creates, truncates, links and mounts nothing. It hashes
nothing, validates no logical path (Unicode, normalization, exact case) and
builds no inventory: those are the layers above it (LFE-5, LFE-6), which use
the traversal and read boundary documented here.

It depends on `hetoimasia-foundation` and on boot libraries (`base`,
`bytestring`, `stm`) only: no Lua, graphics, console, game or sample package.

## Layout

| Component | Directory | Role |
|---|---|---|
| `library` | `src/` | The public facade, `Hetoimasia.Content`. A closed export list: no name constructor, no descriptor, no adapter, no seam. |
| `library internal` (private) | `internal/` | The implementation, shared by the facade and this package's own suite and visible to no client. `Native` holds the adapter record and the test seam; `Root`, `Gate`, `Access`, `Errno` and `Types` hold the rest. |
| C shim | `cbits/hetoimasia_content.c` | Every raw descriptor operation, about 150 lines. Each function returns the negated `errno` on failure, so Haskell never reads `errno` after a safe foreign call. |
| `test-suite content-tests` | `test/`, `test-cbits/` | Registered as the non-optional CPU validation group `test.content`. |

## The public API

```haskell
withContentRoot      ∷ ContentLimits → FilePath → (ContentRoot → IO r) → IO r
withContentRootBytes ∷ ContentLimits → ByteString → (ContentRoot → IO r) → IO r
rootReport           ∷ ContentRoot → RootReport

withFile             ∷ ContentRoot → [NativeName] → (FileReader → IO r) → IO r
readChunk            ∷ FileReader → Int → IO ByteString      -- empty at the end
fileMetadata         ∷ FileReader → IO FileMetadata

withDirectory        ∷ ContentRoot → [NativeName] → (DirectoryReader → IO r) → IO r
readEntry            ∷ DirectoryReader → IO (Maybe DirectoryEntry)
withEntryDirectory   ∷ DirectoryReader → DirectoryEntry → (DirectoryReader → IO r) → IO r
withEntryFile        ∷ DirectoryReader → DirectoryEntry → (FileReader → IO r) → IO r

nativeName           ∷ ByteString → Either NameRefusal NativeName
```

Every result that is native-backed is borrowed: a reader exists for its callback
and no longer. A `ByteString` returned by `readChunk` is copied out of the read
and owns its memory, so it may be kept. There is no lazy I/O.

A caller walks a tree by enumerating a directory, and for each entry opening
the file or subdirectory *through the reader that listed it*. `withEntryFile`
and `withEntryDirectory` open beneath the enumeration's own held directory
descriptor, never by pathname, and take the entry the enumeration reported: if
the entry is no longer what it was (removed, replaced by a link, a directory or
a file) the answer is `MappingChanged`, never a silent selection of whatever
now has that name. Stopping early is returning from the callback.

`ContentLimits` narrows the service: `limitPathDepth` (default 64) bounds the
components of any path and the depth of any traversal, and `limitReadChunk`
(default 1 MiB) bounds one read. The fixed M1 numbers are the later assembly's.

### Names

A `NativeName` is one directory-entry name as lossless bytes. `nativeName`
refuses the empty name, NUL, `/`, `.` and `..`, and a name over 1023 bytes (the
size of the buffer an enumeration copies a name into, which exceeds `NAME_MAX`
on both supported platforms), so a name cannot cross a component boundary and
an untrusted multi-component string is never passed to the operating system as
one component. Bytes that are not valid UTF-8 are accepted and returned
byte for byte. This is the minimal native safety check; the logical path
grammar, normalization and exact-case lookup are LFE-5's.

Enumeration omits the structural `.` and `..`. A name the operating system
returns that fails this check is reported as `InvalidComponent`, not skipped.

## What the root is

`withContentRoot limits path body`:

1. refuses an empty selection, one containing NUL, and one over 4096 bytes;
2. opens `path` as given with `open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)`.
   The operating system resolves the path, so symbolic links in any ancestor and
   in the final component are followed *here and only here*: a relative path
   resolves against the process working directory, which the service never
   changes, and no shell syntax (`~`, `$VAR`) is expanded;
3. reads `fstat` of the descriptor it holds (a directory, or the selection is
   refused) and records its device and inode as the root's native identity;
4. asks the descriptor for the pathname the kernel reports for it
   (`fcntl(F_GETPATH)` on macOS, `readlink` of `/proc/self/fd/N` on Linux);
5. *qualifies* the filesystem: it opens `.` beneath the root descriptor with the
   no-follow, directory-relative call every later operation uses and requires the
   same identity back. A filesystem or platform that cannot do that is refused
   here, as `Unsupported`, rather than part way into a scan;
6. runs the body, then drains and closes (see Lifecycle).

`RootReport` carries what a launcher should report: the selection exactly as
given, the resolved pathname, and the identity. **The pathname is a diagnostic
read from the opened descriptor at open time and is stale as soon as the folder
is renamed; the identity is what names the directory.** Nothing in the service
resolves that pathname again.

Renaming the root, replacing its old pathname or retargeting the selection link
therefore changes nothing for an open root: it keeps reading the directory it
opened, while it remains readable. A root opened afterwards selects whatever the
path names then. There is no watcher, no automatic reopening and no snapshot:
the directory's *contents* are live, and an ordinary missing or changed file is
an ordinary failure.

## Opening below the root

Every component below the root, the final file included, is opened with

```c
openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_NOCTTY
                     [| O_DIRECTORY])
```

relative to a descriptor the operation holds, and the type of the *opened
object* is then read with `fstat` on its descriptor.

| Flag | Why |
|---|---|
| `openat` relative to a held `parent` | Linux documents directory descriptors as stable references across rename, and `O_NOFOLLOW` applies only to the final component, so each earlier component needs its own protection: each is opened the same way, relative to the descriptor of the one before it. |
| `O_NOFOLLOW` | A link in the final component of *this* open is refused (`ELOOP`) instead of followed. |
| `O_DIRECTORY` | For a component that must be a directory. |
| `O_NONBLOCK` | Opening a FIFO read-only returns at once instead of waiting for a writer; the type check then refuses it. Regular files and directories are unaffected. |
| `O_NOCTTY` | Opening a terminal device cannot make it the controlling terminal. |
| `O_CLOEXEC` | No descriptor leaks into a child process. |
| read-only, never `O_CREAT`/`O_TRUNC` | The service creates and modifies nothing. |

There is **no** `exists`, `canonicalize` or link check followed by an
unrestricted open, and no string-prefix test, anywhere. A component swapped for a
link between two steps meets the no-follow open and is refused; a directory
swapped for another after it was opened changes nothing, because the held
descriptor names the object that was opened. The suite checks both, and checks
that a plain check-then-open implementation reads the outside sentinel under
the same swap (see Testing).

One no-follow `fstatat(AT_SYMLINK_NOFOLLOW)` beside the same held parent is used
in two places, and **never authorizes an open**:

* after an `openat` fails, to say *why*: a UNIX-domain socket answers `ENXIO`
  on Linux and `EOPNOTSUPP` on macOS, a link met with `O_DIRECTORY` answers
  `ENOTDIR`, so classifying from the errno alone would call a socket unreadable
  or a link a missing directory;
* during enumeration, to report each entry's own kind (`d_type` can be
  `DT_UNKNOWN`).

The kind of an opened object is always the one read from its descriptor.

### Failure classification

| Situation | Failure |
|---|---|
| Entry absent (`ENOENT`, `ENAMETOOLONG`) | `NotFound` |
| Symbolic link, however it was met | `ForbiddenLink` |
| Entry of the wrong kind (directory for file, file or FIFO or socket or device for directory) | `ForbiddenType found required` |
| `ENOTDIR` that the type query could not explain | `NotDirectory` |
| `EACCES`, `EPERM`, `EIO`, `EMFILE`, any other errno | `Unreadable errno` |
| `EINVAL`, `ENOSYS`, `EOPNOTSUPP` for an entry of the right kind, or a root that fails qualification | `Unsupported errno` |
| A name that fails `nativeName` | `InvalidComponent` |
| An entry observed by an enumeration that is no longer what it was | `MappingChanged expected found` |
| A directory whose identity is on the active ancestor chain | `DirectoryCycle chain depth` |
| Path or traversal deeper than the bound, chunk above the bound | `LimitExceeded` |

A `ContentFailure` carries the launch path, the root's identity, and the full
lossless component list; its `displayException` is bounded (sixteen components,
thirty-two bytes each, escaped) while the value is not.

Three things are deliberately **not** `ContentFailure`: a cancellation (the
asynchronous exception itself), misuse of the API (`ContentDefect`: a reader
used after its callback, from another thread, or a root used after its scope; a
chunk size below one; a provider that returns a count it was not asked for), and
a failed close (`CloseFailure`, retained as cleanup evidence). None is ever
reported as missing content.

## Hard links, mounts and cycles

* A regular file with several hard-link names is content under each name. Each
  path is its own entry, listed and opened separately, and nothing deduplicates
  by inode. `fileMetadata` reports the link count and identity as native evidence.
* A subtree on another device or mount is traversed like any other. No
  device or mount id is a content-version key; they appear only as part of
  `NativeIdentity`, as evidence.
* A traversal compares each directory it opens against the identities of the
  directories *above* it (its active ancestor chain, the root first) and refuses
  one that repeats with `DirectoryCycle`, carrying the root-relative chain to the
  repeating directory and the depth of the ancestor it repeats. The same
  identity on a different, non-cyclic branch is not a cycle: the rule keeps no
  global visited set and merges no paths. If the provider cannot establish an
  identity, the open is refused (`fstat` failed), never skipped.

This is trusted, owner-selected content. It is not containment of a hostile
operating-system actor making arbitrary concurrent changes, and not a promise of
prompt I/O on a network or removable filesystem.

## Lifecycle

### State

| State | Owner | Readers and writers | Thread | Lifetime | Disposal |
|---|---|---|---|---|---|
| Root descriptor | `withContentRoot`'s resource scope | Borrowed by operations as the parent of their first `openat`; closed by the scope's release | Any | The scope | Closed once, after the gate has drained |
| Admission gate (`TVar`: admitting n, draining n, shut) | The root | Admitted and retired by every operation; closed and awaited by the scope's exit | Any | The scope | Ends shut, never reopened |
| Intermediate directory descriptors of one `withFile`/`withDirectory` | That operation's nested resource scopes | The operation | The caller's | One operation | Each closed once when its scope unwinds, innermost first |
| File descriptor of a `FileReader` | `withFile`/`withEntryFile`'s scope | `readChunk`, `fileMetadata` | The thread lent the reader | The callback | Closed once after the reader is marked dead |
| Directory stream of a `DirectoryReader` (owns its descriptor) | `withDirectory`/`withEntryDirectory`'s scope | `readEntry`; `withEntry*` beneath it | The thread lent the reader | The callback | `closedir` once, after the reader is marked dead |
| Reader liveness flag and owner thread | The reader | Set dead by the scope; read by every reader operation | The lent thread | The callback | Never reset |

There is no descriptor cache, no retry queue, no global handle registry and no
ambient content root; two roots share nothing.

### Ownership and the exit

Every native acquisition is owned by a foundation resource scope
(`withResourceLabelled`) whose release is the close. The acquisition is the
native open alone, so the scope registers its release in the same masked step
that obtains the descriptor; the type check and every other step run in the
body, where a failure unwinds the scope and closes the descriptor. A failed
close is cleanup evidence: the primary failure stays primary and every cleanup
failure is retained beside it (read back with `cleanupFailures`), and the other
scopes still run their releases. `close(2)` releases the descriptor even when it
reports an error, an `EINTR` is treated as success (retrying could close a
descriptor another thread has since been given), and a descriptor is never
closed twice.

Operations run on any number of threads at once, so the root keeps its own small
admission gate rather than the foundation's capability-owned collection, which
serializes its users. An operation is *admitted* in the same masked step that
installs its retirement, runs with the caller's masking state restored, and is
retired on every exit, including cancellation.

The scope's exit:

1. closes admission, so an operation started from now on is refused
   (`ContentDefect RootNotAdmitting`);
2. waits **uninterruptibly** until every operation already admitted has retired;
3. delivers a cancellation of the exiting thread, if one is pending;
4. only then lets the resource scope release the root descriptor.

The wait is *before* the final release and outside it, so no release body waits
for a worker, as `docs/resources.md` requires; the one thing each release does is
one `close`. A root is therefore never closed under a borrow, a cancelled
requester releases only what it holds, and a timeout is never permission to
close a live borrow. The wait is the price of sharing a root across threads: an
operation that never returns holds its root's exit, and an operation must not
wait for something the exiting thread would have to provide.

**A cancellation of the exiting thread while it waits** does not shorten the
wait and is not lost: it is delivered after the wait, the descriptor is then
closed exactly once, and a failed close is retained as cleanup evidence on the
cancellation (`CloseFailure` with kind `RootHandle`), where the caller reads it
with `cleanupFailures`. It is never reported as missing content.

### Bounds

* Descriptors per operation: a path of `n ≤ limitPathDepth` components holds at
  most `n` (the `n − 1` intermediate directories and the file, or the final
  directory stream) plus the root's, borrowed.
* Descriptors per traversal: one stream for each active level plus the root's
  stream, at most `limitPathDepth + 1`, plus one file below the deepest.
* Memory per read: at most `limitReadChunk` bytes in flight; a short chunk is
  copied to its own size.
* Nothing accumulates between operations. The suite checks the exact
  acquisition and close counts, not process-wide totals.

## Platforms

Linux and macOS: the suite runs locally on macOS and on Linux CI, and
[the qualification record](../../docs/evidence/content_native/qualification.md)
states which evidence is native and which is injected. The adapter uses only POSIX.1-2008
calls plus `fcntl(F_GETPATH)` on macOS and `/proc/self/fd` on Linux for the
diagnostic pathname; if that diagnostic is unavailable the report carries
`Nothing` and nothing else changes.

* **Network and removable filesystems.** A `close`, `read` or `openat` on a
  filesystem that can stall can stall as long as the filesystem does. The
  release is one `close`, which has a controlled duration on the local
  filesystems this service is qualified for, but the service cannot interrupt
  foreign code and claims no prompt I/O elsewhere.
* **Threaded runtime.** The foreign calls are `safe`; an unthreaded runtime
  blocks every Haskell thread for the duration of one.
* **Permission bits.** Linux CI runs as root, which ignores them, so the
  permission-denied cases are injected through the adapter seam; a real
  `chmod`-based case runs only when the effective user lacks that override, and
  is reported pending otherwise.
* **File names.** APFS accepts only valid UTF-8 names, so a real non-UTF-8 entry
  can exist only where the filesystem allows it (Linux CI); elsewhere the case
  is reported pending and a seam-supplied raw name carries the same API
  guarantee. The API is byte-lossless on both.

## Testing

`test.content` (`hetoimasia-content:content-tests`) is headless, runs through
`cabal.project.cpu`, and uses temporary trees the fixture owns; it changes no
global file-descriptor limit and no process working directory and uses no sleep.
Concurrency is coordinated with explicit gates at named boundaries.

The suite reaches the implementation through the private library so a recording
*seam* can wrap the adapter. It logs every acquisition, close and boundary in one
ordered list; `accounting` decides from that list whether each descriptor was
closed exactly once, never closed while its stream owned it, and never used after
its close. The injection helpers close the real descriptor and then report the
failure, because the production close releases the descriptor even when it
errors.

Evidence classes, by what exercises them:

| Evidence | Native | Injected |
|---|---|---|
| Root selection, symlinked ancestors, rename, retarget, replacement | yes | |
| Internal links, dangling links, links to the same root, swaps at open boundaries | yes | |
| FIFO (no wait), socket, directory-for-file | yes | |
| Device, block and other kinds | | adapter kind override |
| Permission denial | `chmod` when not root | adapter errno |
| Hard links under both names | yes | |
| Mount crossing, directory cycle | | adapter identity override (no mount is created) |
| Non-UTF-8 name | where the filesystem accepts one | supplied raw name |
| Short reads, read errors, close errors | | adapter |
| Cancellation, drain, exit-cancel, ownership transfer | yes (real descriptors, gated) | |
| Public boundary | separately compiled client | |

Each negative control that matters (removing `O_NOFOLLOW`, the post-open type
check, the exit's wait, the cycle rule, the close of a failed handover, the
marking of a reader dead, a gate count leaked by a failed operation, and others)
was broken once locally to show that an example fails and that its cleanup
unwinds within its bound; the pull request records which examples caught which.
Because the exit's wait is uninterruptible by design, the suite runs each root
scope on a child it waits for within a bound, so a leaked borrow fails the
example instead of holding the process. The standalone Lua runner
(`Runner/Source.hs`) is unchanged and is not this provider.

## Out of scope

The M1 manifest and profile; the Lua library; command-line launch integration;
logical path validation (LFE-5); whole-folder inventory policy, numeric M1
accounting, SHA-256 and fingerprint comparison (LFE-6); background file workers,
request and result slots, module caches, textures and VM composition; new
symlink exceptions, hard-link or mount bans, automatic root switching,
snapshots, watchers, hostile-OS confinement and further platforms; privileged
mount or device setup.
