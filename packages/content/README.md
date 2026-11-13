# hetoimasia-content

Anchored, no-follow reading of one launcher-selected content folder.

`withContentRoot` resolves a launch path once, opens the directory it names
and keeps that directory for a scope. Every other operation is relative to it:
paths are opened one component at a time without following a symbolic link,
the type of the opened object is checked, and the result is lent to a callback
as a bounded, strict reader. Once the root is open nothing is a pathname and
nothing is cached.

The package only reads. It depends on `hetoimasia-foundation`, boot libraries,
the pinned Unicode data packages and `cryptohash-sha256`: no Lua, graphics,
console, game or sample package.

This is trusted, owner-selected content. It is not containment of a hostile
operating-system actor making arbitrary concurrent changes, and not a promise
of prompt I/O on a network or removable filesystem.

## Layout

| Component | Directory | Role |
|---|---|---|
| `library` | `src/` | The public facades, each a closed export list: `Hetoimasia.Content` (native roots), `.Identity` (logical identity), `.Inventory` (inventory and verified reads), `.ReadPool` (bounded verified-read workers) |
| private library | `internal/` | The implementation, with the native adapter record and its test seam |
| C shim | `cbits/hetoimasia_content.c` | Every raw descriptor operation. Each function returns the negated `errno`, so Haskell never reads `errno` after a safe foreign call |
| `content-tests` | `test/`, `test-cbits/` | The CPU validation group `test.content` |

## The native roots

Every native-backed result is borrowed: a reader exists for its callback and
no longer. A `ByteString` from `readChunk` is a copy the caller may keep.
There is no lazy I/O. A caller walks a tree by enumerating a directory and
opening each entry through the reader that listed it (`withEntryFile`,
`withEntryDirectory`); an entry that is no longer what it was is
`MappingChanged`, never a silent selection of whatever now has that name.

`ContentLimits` bounds path components and traversal depth (`limitPathDepth`,
default 64) and one read (`limitReadChunk`, default 1 MiB).

**Names.** A `NativeName` is one directory-entry name as lossless bytes.
`nativeName` refuses the empty name, NUL, `/`, `.`, `..` and names over 1023
bytes, so an untrusted multi-component string never reaches the operating
system as one component. Bytes that are not valid UTF-8 are accepted. A name
the operating system returns that fails this check is `InvalidComponent`, not
skipped.

### What the root is

`withContentRoot limits path body`:

1. refuses an empty selection, one containing NUL, and one over 4096 bytes;
2. opens `path` with `O_RDONLY | O_DIRECTORY | O_CLOEXEC`. Symbolic links in
   the selection are followed here and only here. No shell syntax is expanded
   and the working directory is never changed;
3. records the device and inode of the descriptor as the root's identity;
4. asks the kernel for the descriptor's pathname, as a diagnostic;
5. qualifies the filesystem by opening `.` beneath the root with the no-follow
   call every later operation uses and requiring the same identity back, or
   refuses as `Unsupported`;
6. runs the body, then drains and closes.

The pathname in `RootReport` is stale as soon as the folder is renamed; the
identity is what names the directory. Renaming the root or retargeting the
selection link changes nothing for an open root. There is no watcher, no
reopening and no snapshot: the directory's contents are live.

### Opening below the root

Every component, the final file included, is opened with
`openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | O_NOCTTY [| O_DIRECTORY])`
relative to a descriptor the operation holds, and the kind of the opened
object is read with `fstat` on its descriptor.

- `O_NOFOLLOW` protects only the final component, so each earlier component is
  opened the same way relative to the one before it.
- `O_NONBLOCK` makes opening a FIFO return at once; the type check then
  refuses it.
- There is no `exists`, `canonicalize`, link check followed by an open, or
  string-prefix test anywhere.
- A no-follow `fstatat` is used only to explain a failed open and to report an
  enumerated entry's kind. It never authorizes an open.

| Situation | Failure |
|---|---|
| Entry absent | `NotFound` |
| Symbolic link, however met | `ForbiddenLink` |
| Wrong kind | `ForbiddenType found required` |
| `ENOTDIR` the type query could not explain | `NotDirectory` |
| `EACCES`, `EPERM`, `EIO`, `EMFILE`, other errno | `Unreadable errno` |
| `EINVAL`, `ENOSYS`, `EOPNOTSUPP` for the right kind, or a root that fails qualification | `Unsupported errno` |
| A name that fails `nativeName` | `InvalidComponent` |
| An enumerated entry that changed | `MappingChanged expected found` |
| A directory whose identity is on its own ancestor chain | `DirectoryCycle chain depth` |
| Path or traversal past the bound | `LimitExceeded` |

A `ContentFailure` carries the launch path, the root's identity and the full
component list; its display is bounded. Three things are never
`ContentFailure` and never reported as missing content: a cancellation, API
misuse (`ContentDefect`), and a failed close (`CloseFailure`, retained as
cleanup evidence).

**Hard links, mounts, cycles.** Each hard-link name is its own entry; nothing
deduplicates by inode. A subtree on another device is traversed like any
other. The cycle rule compares only against the active ancestor chain and
keeps no global visited set.

### Lifecycle

Every native acquisition is owned by a foundation resource scope whose release
is one `close`. A failed close is cleanup evidence beside the primary failure.
`EINTR` from `close` is treated as success, and a descriptor is never closed
twice.

Operations run on any number of threads, so the root keeps its own admission
gate. The scope's exit:

1. closes admission (`ContentDefect RootNotAdmitting` afterwards);
2. waits uninterruptibly until every admitted operation has retired;
3. delivers a pending cancellation of the exiting thread if the body returned;
   if the body failed, its failure stays primary;
4. only then releases the root descriptor.

A root is never closed under a borrow, and a timeout is never permission to
close one. An operation that never returns holds its root's exit.

A reader is usable only inside its callback and on the thread it was lent to.
A path of `n` components holds at most `n` descriptors plus the root's; a
traversal holds one stream per active level. Nothing accumulates between
operations, and two roots share nothing.

## Logical content identity (LFE-5)

`Hetoimasia.Content.Identity` is the pure policy that turns a literal
reference or an observed directory entry into a logical identity, so a host
filesystem's spelling rules never choose the engine's. It reads no file and
keeps no registry. The caller passes the limits; no default is defined here.

### The grammar

A reference is non-empty UTF-8 with non-empty segments separated only by `/`,
validated from the bytes as supplied before any filesystem is consulted.
Refused: a leading, trailing or repeated slash; a `.` or `..` segment; a
backslash, colon, NUL or any control character (General_Category Cc); and
malformed UTF-8, which is never decoded with replacement. Nothing is trimmed,
expanded, completed or searched: no `~`, no URL or drive reading, no
relative-to-importer resolution, no extension, no `init.lua`. Raw length
bounds are checked before any decoding or normalization.

### Identity: NFC, exact case

Each segment is normalized to NFC, and the root-relative NFC path is the
logical key within its root. Canonically equivalent spellings match. Case is
significant: `images/Hero.png` never selects `images/hero.png`. There is no
compatibility normalization and no case folding in lookup. A `ContentKey` is
the root with the path, so paths in different roots never override each
other. The normalized identity is itself re-checked against the grammar and
the bounds.

### The checked mapping

`buildMapping` takes observed entries (exact native byte components plus file
or directory) and returns a complete `NativeMapping` or an `InventoryRefusal`;
nothing partial is published.

- **Sibling collisions** after NFC (`SameNormalization`) or under Unicode
  canonical caseless matching (`SameCaseless`) are refused. Caseless matching
  is used only to refuse ambiguity, never as a lookup identity.
- **Ancestors take part** whether or not they were supplied as entries.
- **Structural refusals**: a duplicate path, a path below a non-directory,
  `.` or `..`, an empty component, forbidden characters, invalid UTF-8.
  Invalid native UTF-8 is bad inventory, not an entry to omit.
- **Lookup is exact.** `lookupPath` walks the NFC names with no
  case-insensitive fallback. `mappedNative` returns the observed components
  byte for byte, so the opener never guesses from a normalized request.

`buildMapping` consumes entries one at a time and stops at the first refusal
or one entry past the allowance (`TooManyEntries`). Every refusal names its
root and keeps at most 64 bytes of the offending input.

| Outcome | Type |
|---|---|
| Malformed or over-limit reference | `ReferenceRefusal` |
| Invalid or colliding inventory | `InventoryRefusal` |
| Well-formed path with no exact-case match | `lookupPath` returns `Nothing` |

### Pinned Unicode data

| Operation | Source | Unicode version |
|---|---|---|
| NFC and NFD | `unicode-transforms ==0.4.0.1` | 17.0.0, read from `unicode-data` |
| Full case folding (C and F) | `unicode-data ==0.8.0` | 17.0.0 |

The version is held three ways: exact cabal bounds, the pinned Hackage index,
and the suite checking every row of `NormalizationTest-17.0.0` and
`CaseFolding-17.0.0` under `test/data/`. Moving to another Unicode version is
a deliberate edit of the bounds, the vector files and `unicodeDataVersion`.
`text`'s own case tables are not consulted and nothing links ICU.

## Whole-folder inventory and verified reads (LFE-6)

`Hetoimasia.Content.Inventory` makes one bounded scan of the whole folder at
startup and is the only way bytes leave an inventoried file afterwards. It
hashes every regular file with a streaming SHA-256 and returns one immutable
`Inventory`. It knows no manifest schema, role or special file name.

This is a content version for one session, not an atomic snapshot of the
filesystem.

### Limits

`InventorySpec` carries seven numbers that `inventoryLimits` checks. The
package holds no default; the M1 assembly passes these:

| Field | Meaning | M1 value |
|---|---|---|
| `specEntries` | Entries, the root included | 10,000 |
| `specSegments` | Segments of a relative path | 32 |
| `specPathBytes` | UTF-8 bytes of a relative path, native and NFC forms | 1,024 |
| `specSegmentBytes` | Bytes of one segment | 255 |
| `specFileBytes` | Bytes of one regular file | 64 MiB |
| `specRootBytes` | Bytes over every file path of a root, a hard-link alias charged per name | 1 GiB |
| `specBufferBytes` | The streaming read buffer | 64 KiB |

All arithmetic is checked before anything is retained or allocated. The root
must honour the inventory's buffer and depth, or the scan is refused as misuse
(`InventoryLimitsExceedRoot`).

### What the scan does

1. Holds the root through one `withDirectory` for the whole walk.
2. Reads a directory to its end, charging each entry against the allowance as
   it is read; the entry that crosses the allowance is refused.
3. Checks the whole listing before opening any of it: only regular files and
   directories, valid names and paths within bounds, no sibling collisions.
4. Opens entries in the byte order of their native names, each beneath the
   stream that listed it, depth first.
5. For a file: reads its size from the opened object, refuses it before
   reading if over the per-file or remaining root budget, reads exactly that
   many bytes while hashing, and probes one byte past the end.
6. After the walk, with every handle closed, builds the checked mapping and
   publishes the inventory. Nothing is returned before then.

There is no extension filter, ignore list or cross-device skip. An unused file
that is malformed content is inventoried; one that is unreadable, oddly named,
linked or oversized refuses the scan. A scan is never retried. It holds at
most `specSegments + 2` descriptors.

**Detected and refused:** an entry that changed kind or vanished; a size that
differs from the bytes read; a truncated or grown file; an unreadable entry.

**Not detected, by design:** an entry added or removed after its directory was
listed; a file edited after it was read. Each is found when the file is next
read through `readVerified`, or by restarting.

`scanInventory` returns an ordinary refusal as `Left InventoryFailure` with the
root, the path and the reason (`Content`, `Identity`, `Exceeded`, `Changed`).
A cancellation, misuse, a provider defect, and any refusal that carries
retained cleanup evidence propagate as exceptions. The package takes no logger.

An `Inventory` holds the checked mapping, each file's length and SHA-256, the
totals and the limits. It holds no handle and no file bytes. `inspectEntry`,
`bytesMatch` and `listInventory` answer from it alone.

### Verified reads

`readVerified inventory root key ceiling` decides in this order:

1. A negative ceiling, or a root with another identity than the inventory's,
   is misuse and throws.
2. From the inventory alone: a key that is not an inventoried regular file
   (absent, case mismatch, added later, another root's, or a directory) is
   `ReadNotFound`; a length above the ceiling is `ReadTooLarge`.
3. It opens the file by its exact native spelling: each directory on the path
   is enumerated and the entry whose native name matches byte for byte is
   opened beneath that stream. A case-only rename is therefore `Missing` even
   on a case-folding filesystem. It then compares the opened object's length
   with the inventory's and allocates one buffer of exactly that length.
4. It reads exactly that many bytes while hashing, probes one byte past the
   end, checks the length again and compares the SHA-256.
5. Only then does it return the buffer.

| Outcome | When |
|---|---|
| `Right bytes` | The exact bytes, with the inventoried length and digest |
| `ReadNotFound`, `ReadTooLarge` | Decided before any I/O |
| `ReadChanged Missing` | The file or a directory above it is gone or respelled |
| `ReadChanged (Retyped kind)` | The path no longer resolves to a regular file through no-follow opens |
| `ReadChanged` with `LengthChanged`, `Truncated`, `Grew`, `DigestMismatch` | The content differs |
| `ReadIoError kind` | An expected access or read error |

The delivered bytes are the bytes that were verified, from the one open that
was hashed. A timestamp or permission change, or identical bytes replacing the
file, succeeds: inode, device and mtime are not content-version keys. There is
no watcher, retry, reload or placeholder. If the close fails, the failure
propagates and no bytes are delivered.

### Hash dependency

SHA-256 is `cryptohash-sha256 >=0.11.102 && <0.12`, in the private library
alone.

## The verified-read pool (LFE-10)

`Hetoimasia.Content.ReadPool` runs [verified reads](#verified-reads) on owned
worker threads for any number of consumers, without becoming a general
executor. It reads only through `readVerified`, keeps no cache, copies,
deduplicates, retries and polls nothing, and starts no thread per request.

### Ownership and lifetime

The pool is one `withReadPool` scope entered inside the root's scope. Its
workers are a foundation worker group, so the group's drain finishes every
started read before the root can be released. The session owns one pool (two
workers for M1) shared by every consumer and VM.

On any exit the scope closes admission (`PoolIsClosed`), withdraws every
queued job and tells its sink `ReadAbandoned`, then drains started reads with
the root still open. A reader stuck in a blocking call keeps the scope and the
root live: there is no deadline.

### Bounded work, reserved first

`PoolSpec` has a worker count and a slot capacity. A consumer takes a slot
with `reserveSlot` in the transaction that admits its own request and returns
it with `releaseSlot` after the job retired. `submit` only enqueues and
requires a reservation. So `queued <= live <= reserved <= capacity`, an
accepted job is never refused for want of room, and a full queue elsewhere
cannot block a completion, a cancel or a drain. Submitting without a slot or
releasing one a live job needs is a caller defect.

A job names its key, its byte allowance (the consumer's own bound; the pool
imposes none), its priority and its sink. Workers take the oldest job of the
strongest class: `DependencyProgress` before `OrdinaryRead`.

### A job

| State | Meaning | Left by |
|---|---|---|
| queued | No file touched | issuance, or `cancel` or close; one transaction, so exactly one wins |
| issued | A worker took it | the worker's settlement |
| delivering | The worker decided to call the sink; the slot claim is over | the sink returning |
| done | The sink returned, or was suppressed because interest was withdrawn | terminal |
| notifying | Left the queue unissued because the pool closed or failed; its sink is yet to be told | the sink returning |
| withdrawn | Left the queue unissued | terminal |

- `retired` is true from done or withdrawn on, never while a sink is still
  being told. It is the per-job evidence a consumer builds retirement from; a
  worker's exit or the group's drain is not.
- The slot's claim ends when the worker decides to deliver, before the sink
  runs, so the consumer may release its slot inside the sink.
- `cancel` answers `CancelWithdrawn` (no file opened, sink not called),
  `CancelInFlight` (runs to its end; sink suppressed unless delivery began) or
  `CancelTooLate`.
- `withdrawQueued` cancels only a job no worker has taken. A consumer that
  promotes a queued read withdraws and resubmits it in one transaction,
  keeping its slot.

### The buffer

`readVerified` allocates the buffer once at the inventoried length. The worker
passes the same `ByteString` to the sink: no copy and no second reference.
From the sink call on, the allocation is the consumer's to account.

### Failure

An expected outcome of a read is data for the sink (`ReadFailed`). Anything
else a reader or sink raises is a defect: the job's sink is told
(`ReadDefect`), every queued job is withdrawn and told, the pool latches the
first defect with its context and cleanup evidence, refuses later jobs
(`PoolHasFailed`), and the worker ends. Nothing restarts. The assembly
observes the latch with `awaitFailure` in a supervised wait, and
`poolFailureEvidence` reads what was recorded beside it.

| Exit | What is kept |
|---|---|
| A reader or sink raises | Latched; the scope rethrows it |
| A worker is terminated by an exception the scope did not send | Latched as `ReadWorkerTerminated` |
| A worker returns or is stopped from outside while the pool is open | Latched as `ReadWorkerEndedOpen` |
| A later failure, or a queued sink raising while being told | Appended to the evidence list |
| The body fails | Its failure is primary; a latched failure is kept beside it |
| The body returns | The latched failure is rethrown; otherwise an unclean worker report raises `ReadWorkerReportedUnclean` |
| The scope's thread is killed | Workers are cancelled and drained; the interrupted job settles `ReadAbandoned` |

## State

| State | Owner | Lifetime and disposal |
|---|---|---|
| Root descriptor and admission gate | `withContentRoot`'s scope | The scope. The gate ends shut; the descriptor is closed once after the drain |
| Descriptors and streams of one operation | That operation's nested scopes | One operation or callback; each closed once |
| Identity values, mappings, inventories | The caller | Immutable, until dropped |
| Scan state | The `scanInventory` call | The call |
| Pool state and job states | The `withReadPool` scope | One scope; a ticket outlives its job as a value |
| Pool workers | The pool's worker group | Started with the scope, drained at its exit |

There is no descriptor cache, registry, ambient root or content cache.

## Platforms and testing

Linux and macOS. The foreign calls are `safe`, so the threaded runtime is
required. I/O on a filesystem that can stall can stall as long as it does.

```bash
cabal test --project-file cabal.project.cpu hetoimasia-content:content-tests --test-show-details=direct
```

`--match Identity`, `--match Inventory` and `--match ReadPool` select the
layers. The suite is headless, uses temporary trees it owns, and coordinates
with explicit gates, never a sleep. It reaches the implementation through the
private library so a recording seam can wrap the adapter and account for every
acquisition and close.

Some cases cannot exist natively everywhere and are then reported pending,
with an injected example beside them:

- Linux CI runs as root, which ignores permission bits, so permission denial
  is injected there and uses a real `chmod` only for an unprivileged user.
- APFS folds case, normalizes names and refuses non-UTF-8 names, so real
  case-colliding, canonically equivalent and non-UTF-8 names exist only on
  Linux CI.
- Mount crossings, directory cycles, devices, short reads and close errors are
  injected through the adapter; no mount is created.

Because the root's exit wait is uninterruptible, the suite runs each root
scope on a child it waits for within a bound, so a leaked borrow fails the
example instead of holding the process.

## Out of scope

The M1 manifest and profile, the Lua library, launch integration, Lua
admission and exit codes for these outcomes, byte banks, module caches,
textures, a persistent hash cache, a watcher or background refresh, and
hostile-OS containment.
