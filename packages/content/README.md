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

The package reads. It creates, truncates, links and mounts nothing. The native
roots hash nothing and build no inventory: whole-folder inventory and verified
reads (LFE-6, [below](#whole-folder-inventory-and-verified-reads-lfe-6)) are the
layer above, which uses the traversal and read boundary documented here and the
logical identity policy. The native roots validate no logical path:
`Hetoimasia.Content.Identity` (LFE-5, below) is the separate pure layer that
turns a literal reference or an observed name into a logical identity, so the
two never depend on one another.

It depends on `hetoimasia-foundation`, on boot libraries (`base`, `bytestring`,
`containers`, `stm`, `text`), on the pinned Unicode data packages
`unicode-data` and `unicode-transforms` (see
[Pinned Unicode data](#pinned-unicode-data)) and, for the inventory's SHA-256, on
`cryptohash-sha256` (see [Hash dependency](#hash-dependency)): no Lua, graphics,
console, game or sample package.

## Layout

| Component | Directory | Role |
|---|---|---|
| `library` | `src/` | The public facades: `Hetoimasia.Content` (native roots), `Hetoimasia.Content.Identity` (logical identity), `Hetoimasia.Content.Inventory` (the inventory and verified reads) and `Hetoimasia.Content.ReadPool` (the owned bounded verified-read workers), each a closed export list: no name constructor, no descriptor, no adapter, no seam, no pool hook, no constructor of a checked identity value, an inventory, a digest, a pool specification or a set of limits. |
| `library internal` (private) | `internal/` | The implementation, shared by the facades and this package's own suite and visible to no client. `Native` holds the adapter record and the test seam; `Root`, `Gate`, `Access`, `Errno` and `Types` hold the rest of the native layer; `Identity.Unicode`, `Identity.Types`, `Identity.Reference` and `Identity.Mapping` hold the identity policy; `Inventory.Types`, `Inventory.Scan`, `Inventory.Read` and `Inventory.Outcome` hold the inventory; `Pool` holds the verified-read pool and its coordination hooks. |
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

`ContentRoot` and `ContentLimits` are abstract, and `rootReport`, `limitPathDepth` and `limitReadChunk` are functions rather than record labels, so a client
cannot rewrite a root's report (its identity is what the cycle rule and failure
attribution compare) or set a limit past what `contentLimits` accepts.

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
3. if the body returned, delivers a cancellation of the exiting thread that is pending; if the body failed, its failure and the cleanup evidence it carries stay primary and the cancellation stays pending (see below);
4. only then lets the resource scope release the root descriptor.

The wait is *before* the final release and outside it, so no release body waits
for a worker, as `docs/resources.md` requires; the one thing each release does is
one `close`. A root is therefore never closed under a borrow, a cancelled
requester releases only what it holds, and a timeout is never permission to
close a live borrow. The wait is the price of sharing a root across threads: an
operation that never returns holds its root's exit, and an operation must not
wait for something the exiting thread would have to provide.

**A cancellation of the exiting thread while it waits** does not shorten the
wait and is not lost. The outcome follows the foundation's failure table:

* the body returned: the cancellation is delivered after the wait as the primary
  failure, the descriptor is then closed exactly once, and a failed close is
  retained as cleanup evidence on the cancellation (`CloseFailure` with kind
  `RootHandle`), where the caller reads it with `cleanupFailures`;
* the body failed (or was itself cancelled): that exception, with every cleanup
  failure it already carries, stays primary and is rethrown as it was captured;
  the cancellation is not consumed and is delivered once the scope has finished,
  as after any foundation scope whose body failed.

Neither is ever reported as missing content.

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

## Logical content identity (LFE-5)

`Hetoimasia.Content.Identity` is the pure naming boundary above the native
roots: the one policy that turns a literal reference or an observed directory
entry into a logical identity, so that a host file system's permissive spelling
rules never choose the engine's. It reads no file, opens nothing, prints
nothing, exits nothing and keeps no registry; it needs no root handle, opener,
Lua VM, worker, graphics or application assembly, and the package still depends
on the foundation and boot libraries plus the pinned Unicode data below. The
M1 assembly (LFE-6) composes it with the roots documented above.

```haskell
identityLimits   ∷ Int → Int → Int → Int → Either LimitsRefusal IdentityLimits
rootKey          ∷ ByteString → Either RootKeyRefusal RootKey

parseReference     ∷ IdentityLimits → RootKey → ByteString → Either ReferenceRefusal ContentKey
parseReferenceText ∷ IdentityLimits → RootKey → Text → Either ReferenceRefusal ContentKey
contentKeyRoot, contentKeyPath ∷ ContentKey → …
logicalPathBytes, logicalPathSegments ∷ LogicalPath → …

buildMapping   ∷ IdentityLimits → RootKey → [ObservedEntry] → Either InventoryRefusal NativeMapping
lookupPath     ∷ NativeMapping → LogicalPath → Maybe MappedEntry
mappingEntries ∷ NativeMapping → [MappedEntry]
mappedNative   ∷ MappedEntry → NonEmpty NativeName     -- exactly what the opener takes
```

`IdentityLimits`, `RootKey`, `LogicalPath`, `NativeMapping` and `MappedEntry`
are abstract: a client builds them only through the check that guards them. No
M1 number is defined here. The caller passes the limits it was configured with
(M1: 1,024 UTF-8 bytes per relative path, 255 per segment, 32 segments, and the
entry allowance the inventory owns); the suite passes those numbers explicitly
as test inputs and also exercises smaller profiles. `identityLimits` requires
the path, segment and segment-count limits to be at least one, the entry
allowance at least zero, and a segment limit no larger than the path limit or
than `NativeName`'s 1023 bytes, so every accepted segment can be a native name.

### The grammar

A reference is non-empty UTF-8 with non-empty segments separated only by `/`,
validated completely from the bytes as supplied before any file system is
consulted. It is refused for a leading, trailing or repeated slash; a `.` or
`..` segment; a backslash, a colon, NUL or any other control character; and
malformed UTF-8, which is never decoded with replacement. Nothing is trimmed,
expanded, completed or searched: no `~` or environment expansion, no URL, drive,
network or absolute-path reading, no relative-to-importer resolution, no
extension and no `init.lua`. Spaces and punctuation stay literal. The launch
root's spelling is outside this grammar, and the selected root is supplied
separately as a `RootKey`.

* **Control characters** are Unicode General_Category Cc: U+0000–U+001F, U+007F
  and U+0080–U+009F (U+0000 is reported as NUL). Format characters (U+200B,
  U+202E, U+FEFF…), U+2028/U+2029 and noncharacters stay literal, and a leading
  U+FEFF is not stripped. The suite covers the boundaries U+001F, U+007F, U+0080
  and U+009F refused and U+0020 and U+00A0 accepted.
* **Malformed UTF-8** is everything RFC 3629 and Unicode Table 3-7 reject:
  overlong forms (`C0 AF`, `E0 80 AE`), encoded surrogates (`ED A0 80`), code
  points above U+10FFFF (`F4 90 80 80`), truncated sequences and stray
  continuation or invalid lead bytes. An overlong `/`, `.`, `\`, `:` or NUL is
  malformed and never becomes that character. The refusal carries the byte
  offset of the first ill-formed sequence.
* **The order of checks** is the order of `ReferenceReason`: empty; total bytes
  against the path limit; segment count (from the separators, before anything
  is split); leading, trailing and repeated slashes; then each segment in turn
  (its bytes against the segment limit, `.`/`..`, UTF-8, forbidden characters,
  its NFC form against the segment limit and against the grammar again); and
  last the NFC path against the path limit. Raw bounds therefore run before any
  decoding or normalization, and an input past the path limit is refused on its
  length alone.

### Identity: NFC, exact case

Each valid segment is normalized to NFC, and the root-relative NFC path is the
logical key within its root. Canonically equivalent composed and decomposed
spellings match; case is significant, so `images/Hero.png` never selects
`images/hero.png`. There is no compatibility normalization and no case folding
in lookup. The policy applies equally to authored references and to observed
inventory names, directories included. A `ContentKey` is the root together with
the path: paths in different roots are different keys and never override each
other. Two distinct legal names for one hard-linked file are distinct path
identities; the mapping sees names, never inodes. File contents, Lua source,
data bytes and display strings are untouched.

The returned identity is itself checked against the grammar, not assumed to
survive normalization: singleton canonical decompositions turn non-ASCII input
into ASCII (U+212A KELVIN SIGN becomes `K`, U+037E becomes `;`), U+0958 expands
from 3 to 6 UTF-8 bytes (composition exclusion) and `e` + U+0301 shrinks from 3
to 2. The suite sweeps every scalar value as a one-character segment and
requires each identity to satisfy the grammar and to be idempotent.

### The checked mapping

`buildMapping` takes caller-supplied observed entries: each is its path below
the root as exact native byte components (never joined, split, trimmed or
re-encoded) and whether it is a file or a directory. Entries of any other
native kind are refused by the enumerator (D-11), not by this policy. It builds
an immutable tree and returns either a complete `NativeMapping` or an
`InventoryRefusal` naming the selected root; nothing partial is ever published,
and the caller owns the result and its lifetime.

* **Sibling collisions.** Distinct siblings that collide after NFC
  (`SameNormalization`) or under Unicode canonical caseless matching
  (`SameCaseless`) are refused with both native names, both kinds and the NFC
  path of their directory: file/file, directory/directory and file/directory.
  Canonical caseless matching is Unicode D145, `NFD(toCasefold(NFD(x)))` with
  default full case folding (`CaseFolding.txt` statuses C and F, never the
  locale-specific T mappings). It is used only to refuse ambiguity, never as a
  lookup identity. The same name in different parent directories is not a
  collision.
* **Ancestors take part.** Every ancestor component of every supplied path is
  a sibling in the check whether or not it was supplied as an entry: native
  `Hero/a` and `hero/b` collide at the root with no directory entry supplied.
  Directories therefore need not be supplied; supplying one marks it supplied
  (`mappedSupplied`), and an empty directory is addressable only if it was.
* **Structural refusals.** Inconsistent entries are refused, never repaired or
  deduplicated: the same exact native path twice (`DuplicateEntry`), a path
  below an entry supplied as a non-directory (`BelowNonDirectory`), a
  non-directory that other paths pass through (`NonDirectoryHasChildren`), a
  `.` or `..` component including the OS self and parent pseudo-entries (their
  exclusion is the LFE-6 enumerator's job), an empty component, an embedded
  `/`, NUL, backslash, colon or control character, and invalid UTF-8. Invalid
  native UTF-8 is bad inventory, not an entry to omit.
* **Lookup is exact.** `lookupPath` walks the NFC names; a path differing only in
  case, or one the inventory does not hold, is `Nothing`. There is no
  case-insensitive fallback and no fallback to a native spelling. `mappedNative`
  returns the observed components byte for byte as `NativeName`s, so the later
  no-follow opener is never asked to guess from a normalized request.

### Bounds

Each supplied/native path and its NFC form must fit the path limit, each
segment its limit, and the path its segment count; the check counts encoded
bytes, separators included, never characters or code units, and neither
normalization's shrinkage nor a native file system's larger limit excuses an
over-limit original. Inventory validation applies to the whole relative native
spelling, not only to its names. Sums are capped at the limit so a long list is
never summed in full. `buildMapping` consumes its entries one at a time and
stops at the first refusal and at one entry past the allowance
(`TooManyEntries`), so an unbounded enumeration is never materialized; the
aggregate 10,000-entry budget including the root is the inventory's (LFE-6).
Derived scratch is bounded by the accepted input: a segment is at most the
segment limit, and its caseless key is at most `maxCaselessExpansion` (four)
code points per code point, a figure the suite sweeps over every scalar value.
There is no cache, no tuning option and no silent truncation.

### Refusal classification

The three outcomes are distinct and carry bounded information, so the later
callers apply the approved policy; this slice implements no Lua admission,
escalation or exit code.

| Outcome | Type | Later handling (D-60, D-61) |
|---|---|---|
| Malformed or over-limit reference | `ReferenceRefusal` with `ReferenceReason` | bad hook arguments are ordinary Lua errors even for optional loads; a bad manifest entry fails boot; a bad top-level import fails its required load |
| Invalid or colliding inventory | `InventoryRefusal` with `InventoryReason` | fails boot |
| Well-formed path, no exact-case match | `lookupPath` returns `Nothing` | missing content under the existing content failure rules; never a fallback |

Every refusal names the root it was for and keeps at most 64 bytes of the
offending input, copied into a buffer of its own (`Excerpt`: the bytes and the
length of the whole), so a refusal never keeps an arbitrarily large rejected
input alive; a name inside a diagnostic is shown escaped and never decoded. File
changes, file types and no-follow races are separate native outcomes, not claims
a valid name makes.

### Pinned Unicode data

The tables come from one recorded Unicode version, independent of the locale,
the OS and the compiler:

| Operation | Source | Unicode data version |
|---|---|---|
| NFC and NFD | `unicode-transforms ==0.4.0.1` | 17.0.0, read at run time from `unicode-data` |
| Full case folding (C and F) | `unicode-data ==0.8.0` (`toCaseFoldString`) | 17.0.0 |

`unicode-transforms`'s own description still says 14.0.0, the version it was
generated for; it holds no table of its own, and consults `unicode-data` for
decompositions, combining classes and Hangul, so the version in effect is
`unicode-data`'s. The suite checks every row of `NormalizationTest-17.0.0` and
every line of `CaseFolding-17.0.0` (both under `test/data/` with their
provenance), so a table that is not 17.0.0 fails there. `text` is used as a
container only: its own case tables are not consulted. Nothing links ICU or an
operating-system Unicode library.

The build holds the version fixed three ways: the cabal file bounds
`unicode-data` and `unicode-transforms` to exactly these versions, the
repository pins the Hackage index (`index-state` in `cabal.project.common`),
and the reference vectors fail on any drift. Moving to another Unicode version
is a deliberate edit of those bounds, the vector files and `unicodeDataVersion`.
Normalization and case folding are separate operations (UAX #15; the Unicode
case-mapping FAQ): the key uses both, `NFD`, fold, `NFD`, and lowercasing alone
would be insufficient.

### State and ownership

| State | Owner | Readers | Writers | Thread | Lifetime |
|---|---|---|---|---|---|
| `IdentityLimits`, `RootKey`, `LogicalPath`, `ContentKey`, refusals | the caller | anyone | none (immutable) | any | until dropped |
| `NativeMapping`, `MappedEntry` | the caller of `buildMapping` | anyone | none (immutable; a build is local to its call) | any | until dropped |
| The caseless key of a segment | the thunk of the one `CheckedSegment` | `buildMapping` | none | the building thread | the build call |

There is no global registry, cache or mutable state, and no teardown. An
enumeration that must be consumed lazily (the entry allowance) is consumed by
`buildMapping` on the calling thread and released with the call.

### Evidence

Collision, grammar, bounds and lookup examples run on pure values and supplied
entries, which stand in wherever a file system cannot hold the names; they are
labelled as such and never claimed to prove native behavior. The "native trees"
examples create real names in a temporary directory the example owns, enumerate
them with the content service above, build the mapping from what the operating
system reported and open the files by the mapped components. A real
case-colliding pair, a real canonically-equivalent pair and a real non-UTF-8
name need a file system that keeps them: Linux CI does; the local macOS APFS
folds the first two, normalizes the second and refuses the third, so those
three examples are reported pending locally with the reason, and the
supplied-entry examples remain the evidence. A separately compiled client proves
the public identity interface hides every constructor, and that the package
names no Lua, console, game or sample dependency.

## Whole-folder inventory and verified reads (LFE-6)

`Hetoimasia.Content.Inventory` is the layer above the native roots and the
identity policy: one bounded scan of the whole folder at startup, and the only
way bytes leave an inventoried file afterwards. It composes the traversal and
read boundary documented above with the logical identity policy, hashes every
regular file with a streaming SHA-256, and returns one immutable `Inventory`.
It knows no manifest schema, role, Lua module or special file name, and imports
neither Lua nor graphics.

```haskell
inventoryLimits ∷ InventorySpec → Either InventoryLimitsRefusal InventoryLimits
scanInventory   ∷ InventoryLimits → RootKey → ContentRoot → IO (Either InventoryFailure Inventory)

inspectEntry    ∷ Inventory → ContentKey → Presence        -- Absent | PresentDirectory | PresentFile length
bytesMatch      ∷ Inventory → ContentKey → ByteString → Bool
listInventory   ∷ Inventory → [InventoryEntry]             -- path, kind, and for a file its length and digest
readVerified    ∷ Inventory → ContentRoot → ContentKey → Int → IO (Either ReadFailure ByteString)
```

This is a content *version for one session*, not an atomic snapshot of the
filesystem and not containment of a hostile one. Authors keep the folder stable
while it boots; neither metadata checks nor a per-file hash establish that the
whole tree was in one state.

### Limits

`InventorySpec` carries seven plain numbers and `inventoryLimits` checks them.
The package holds **no default**: the M1 assembly passes the approved values
(see `hetoimasia-lua-engine`'s `contentConfiguration`), and the suite passes the
same numbers explicitly, plus smaller profiles through the same check.

| Field | Meaning | M1 value |
|---|---|---|
| `specEntries` | Entries, the root and every directory and file path included | 10,000 |
| `specSegments` | Segments of a relative path; the root is depth zero | 32 |
| `specPathBytes` | UTF-8 bytes of a relative path, on the native/supplied and the NFC form | 1,024 |
| `specSegmentBytes` | Bytes of one segment, on both forms | 255 |
| `specFileBytes` | Bytes of one regular file | 64 MiB |
| `specRootBytes` | Bytes summed over every regular-file path of a root, a hard-link alias charged once per name | 1 GiB |
| `specBufferBytes` | The streaming read buffer, the most one read asks for | 64 KiB |

KiB, MiB and GiB are powers of 1024. Every value must be at least one; the
identity policy must accept the path, segment and segment-count limits (a
segment no larger than the path or than a native name, so every accepted segment
can be a native name); and one file may not be allowed more than the whole root.
The identity policy is given an entry allowance one smaller than `specEntries`,
because the root is not an addressable entry. The scan also requires the root it
is given to honour the inventory: the root's read chunk must hold the buffer and
its path depth the segment limit, or the call is refused as misuse
(`InventoryLimitsExceedRoot`).

All arithmetic is checked before anything is retained or allocated: lengths are
compared with the budget by subtraction from what remains, never by an addition
that could wrap. These are service bounds, not a total Lua or process memory cap.

### What the scan does

1. Holds the root through one `withDirectory` for the whole walk, so the root
   cannot close under it. The root is the first entry counted.
2. Reads a directory to its end, charging each entry against the allowance *as it
   is read*. The entry that crosses the allowance is refused and nothing after it
   is read, so an enormous directory is never materialized. At most the
   remaining allowance is ever held across all active levels.
3. Checks the listing as a whole before opening any of it: every entry is a
   regular file or a directory (a symbolic link, FIFO, socket or device refuses
   the scan), every name and path is valid under the identity policy and within
   the path, segment and depth bounds, and no two siblings collide by
   normalization or canonical caseless comparison. A refusal therefore precedes
   any hashing in that directory.
4. Opens the entries in the byte order of their native names, each beneath the
   directory stream that listed it (never by pathname), so a file or directory
   that is no longer what it was listed as is a changed mapping. Directories are
   enumerated depth first, one stream per active level.
5. For a regular file: reads its size from the opened object, refuses it before
   reading anything if the size exceeds the per-file limit or would take the
   root's total past its budget, then reads exactly that many bytes in requests
   of at most the buffer, hashing each chunk as it arrives, and probes **one
   byte** past the end. A byte there means the file grew.
6. After the whole walk, with every handle closed, builds the checked mapping of
   all entries and publishes the inventory. Nothing is returned before then.

There is no extension filter, ignore list, authored asset list, mod discovery or
cross-device skip. Hidden, empty and unused files are scanned like any other.
Nothing is decoded, parsed or evaluated, and no module-cache slot exists.
An unused file that is malformed Lua or a malformed PNG is inventoried; an
unused file that is unreadable, oddly named, linked or oversized refuses the
scan.

### Workspace and handles

All figures follow from the accepted limits:

| Resource | Bound |
|---|---|
| Descriptors | The root's, a stream for the root and for each directory above the deepest entry, and one file: at most `specSegments + 2` |
| Entries retained | At most `specEntries`; the mapping, the record of facts and the observed list are each bounded by it |
| Read workspace | One chunk of at most `specBufferBytes`, plus the single probe byte |
| Digest state | One SHA-256 context per file in flight, a fixed small size independent of the file |
| Bytes read beyond what a file was charged | At most one (the probe) |
| Diagnostic evidence | The root's launch path (at most 4,096 bytes), a path of at most `specSegments + 1` components of at most 1,023 bytes each, and 64-byte excerpts from the identity policy |

### What can change under a scan

Detected, and refused with the path and the reason (`Changed`, or the content
layer's own `MappingChanged`): an entry that is no longer the kind it was listed
as, or is gone; a file whose size at open differs from the bytes read; a read
that ends before the expected length; a byte after it; a size that differs after
the read; an unreadable file or directory; and an unsupported native operation.
Growth is refused after at most one byte beyond the length the file was charged
for. A scan is never retried.

Not detected, by design: an entry added to or removed from a directory *after it
was listed*; a file edited behind the hash after it was read; an edit that keeps
the length and lands after the last read of that file. Each is found when the
affected file is next read through `readVerified`, or by restarting. The
inventory records the bytes observed for each file, not an atomic snapshot of
the tree.

### Outcomes of a scan

`scanInventory` returns an ordinary refusal as a `Left InventoryFailure`: the root
(launch path and native identity), the root-relative path, and the reason.

| Reason | Meaning |
|---|---|
| `Content kind` | The content layer's refusal: `Unreadable`, `ForbiddenLink`, `ForbiddenType`, `Unsupported`, `DirectoryCycle` (with its chain), `MappingChanged`, `LimitExceeded PathDepth` |
| `Identity reason` | The identity policy's: an invalid name or path, a path over a bound, a sibling collision |
| `Exceeded bound observed limit` | The entry allowance, the per-file bytes or the per-root bytes |
| `Changed change` | `LengthChanged`, `Truncated`, `Grew` |

Everything else propagates as an exception: a cancellation, misuse of the API
(`ContentDefect`), a defect of the native provider, and **any ordinary refusal
that carries retained cleanup evidence**, which is rethrown as the exception it
was captured as (`InventoryFailure` or `ContentFailure`) with the failed close
beside it, readable with `cleanupFailures`. A failed close is never reported as
missing or changed content.

The package takes no logger and writes nothing: the evidence above is for the
boundary that handles the refusal (the launcher), which reports a propagated
failure once, as [the logging guide](../../docs/logging.md#module-authoring-guide)
requires.

### The inventory

An `Inventory` is immutable and holds, for the root it was built for: the
checked mapping of every directory and file (logical NFC path to the exact native
components that open it), each regular file's byte length and SHA-256, the entry
and byte totals, and the limits and root key it was built under. It holds no
handle and no copy of any file's bytes. A path added to the folder later is not
in it.

| State | Owner | Readers | Writers | Thread | Lifetime |
|---|---|---|---|---|---|
| Scan state (counters, observed entries, facts) | The `scanInventory` call | The call | The call | The caller's | The call; dropped on return or failure |
| Descriptors of a scan | The content layer's scopes | The walk | None | The caller's | Each closed once when its scope unwinds |
| `Inventory` | The caller | Any thread | None | Any | Until dropped |

There is no registry, cache, descriptor cache, worker pool or queue. The scan
runs on the calling thread.

### Questions asked of an inventory

* `inspectEntry` answers from the inventory alone: `Absent` for a path the scan
  did not see, one that differs in case, or a key of another root;
  `PresentDirectory`; or `PresentFile length`. It returns no handle and no
  pathname and is never a reason to skip hashing.
* `bytesMatch` is true when the supplied bytes have the inventoried length and
  SHA-256 of a regular file. It reads nothing.
* `listInventory` lists every entry with its kind and, for a file, length and
  digest, without native components.

### Verified reads

`readVerified inventory root key ceiling` decides in this order:

1. A negative ceiling, or a root of another native identity than the inventory's,
   is misuse and throws (`BadReadCeiling`, `InventoryRootMismatch`).
2. From the inventory alone, before any open or read: a key that is not an
   inventoried regular file is `ReadNotFound` (an absent path, a case mismatch, a
   path added after startup, another root's key, **and a directory**, which never
   opens or enumerates and never succeeds); an inventoried length above the
   ceiling is `ReadTooLarge length ceiling`.
3. Otherwise it opens the file by its **exact native spelling**: every directory on
   the path, the root's included, is enumerated and the entry whose native name
   equals the recorded one byte for byte is opened beneath the stream that listed
   it, from the root's retained descriptor. A filesystem that folds case or treats
   canonically equivalent names as one would resolve a different spelling to the
   same object; here a file renamed `Hero.png` → `hero.png` is `Missing` however
   the filesystem would have resolved the old name. The cost is one enumeration of
   each directory on the path, stopping at the match; a different entry that vanishes
   while the directory is listed says nothing about this file and is skipped. It then compares the opened
   object's length with the inventoried one, and only then allocates one buffer of
   exactly that length.
4. It reads exactly that many bytes into the buffer in requests of at most the
   buffer bound, hashing each chunk from the same buffer, probes one byte past the
   end, checks the length again, and compares the SHA-256 with the inventory's.
5. Only then does it return the buffer.

| Outcome | When |
|---|---|
| `Right bytes` | The exact bytes, with the inventoried length and digest |
| `ReadNotFound` | See 2 above |
| `ReadTooLarge` | Inventoried length above the ceiling; decided before any I/O |
| `ReadChanged Missing` | The file or a directory above it is gone, or is no longer spelled as it was observed (a case-only rename included) |
| `ReadChanged (Retyped kind)` | The path no longer resolves to a regular file through no-follow opens: a link, a directory, a file where a directory was |
| `ReadChanged (LengthChanged ..)`, `Truncated`, `Grew`, `DigestMismatch` | The content differs; growth past the ceiling is a content change, found at the length check before any buffer is allocated for it, or after at most the probe byte |
| `ReadIoError kind` | An expected access or read error (`Unreadable`, `Unsupported`) |

The delivered bytes are the exact bytes that were verified, from the one open
that was hashed; there is no hash followed by a second open, no stat-only trust
and no partially verified result. A file replaced after it was opened is still
read from the object that was opened; the *next* read opens the path again and
finds what is there. A timestamp-only or permission change, or identical bytes
replacing the file at a legal path, succeeds: native inode, device, mount and
mtime are not content-version keys, and metadata never replaces hashing. Bytes
already delivered are an immutable `ByteString` and do not change if the file is
edited later. There is no watcher, retarget, retry, automatic reload, placeholder
or path addition. Cancellation, misuse, defects and failed cleanup propagate as
exceptions, never as one of these outcomes. A content change found while the file
is open is raised inside the open scope and becomes a value only after cleanup
succeeded: if the close then fails, the `ReadFailure` propagates as the primary
exception with the failed close beside it (`cleanupFailures`); a failed close after a
successful read throws and delivers no bytes.

The result and its buffer belong to the caller. The service keeps no global
content cache; a later provider's byte banks and worker accounting are its own.

### Invariants

| Subject | Owner | Acquired / tracked at | Cancellation window | Release / publication check |
|---|---|---|---|---|
| Traversal entries | The scan state | Charged as each entry is read, before it is retained; refused at the crossing entry | Anywhere; the state is dropped | Count ≤ allowance at every charge; final mapping built under the same allowance |
| Traversal bytes | The scan state | Charged once per file, from the opened object's size, before the first read | Anywhere | Total ≤ root budget by subtraction; actual bytes read equal the charge or the scan is refused |
| Handles | The content layer's scopes | Each acquisition is registered in the same masked step; the walk holds the root for its duration | Anywhere | Each closed once; a failed close is evidence beside the primary failure |
| Digest and read buffer | The file in flight | One chunk and one context per file, one result buffer per read | Anywhere | Dropped with the call; a result buffer is returned only after the digest matched |
| Inventory publication | The caller, after return | Assembled after every handle is closed and every check passed | Before publication nothing exists | The only value returned is the complete one |
| Verified-byte handoff | The caller | The buffer is allocated after the length check, bounded by the ceiling | Before the return nothing is delivered | Returned only after the digest matched and the handles closed |

### Hash dependency

SHA-256 is `cryptohash-sha256 >=0.11.102 && <0.12`, in the private library
alone; the resolved version under the pinned `index-state` is 0.11.102.1. The
native shader toolchain's lazy `sha256File` is evidence for the algorithm only:
this package imports no graphics package, reads no pathname lazily and hashes no
bytes of a file it did not read through its own open.

### Evidence

Native evidence runs on real files in a temporary tree; injected evidence is
named as such and proves the handling of what the adapter reports, never the
operating system.

| Evidence | Native | Injected |
|---|---|---|
| Scan of root, directories, files, empty, hidden and unused files; digests against independently known vectors | yes | |
| Entry, depth, path, segment, file and root bounds at their edges and one past; aliases charged per name | yes (the real 10,000 and 32 included) | NFC growth of a name, an enormous directory |
| Growth, truncation, edits behind the scan, entries swapped between listing and opening | yes (mutations at named boundaries) | an early end of file; a size that disagrees after the read |
| Hard links, outside-name edits | yes | |
| Mounted subtrees, directory cycles | | adapter identity override (no mount is created) |
| Unreadable file | `chmod` where the effective user cannot bypass it, reported pending as root | adapter errno (the variant Linux CI runs, as root) |
| Read errors, close errors, unsupported opens | | adapter |
| Non-UTF-8 and colliding names | where the filesystem holds them | supplied names |
| Root rename, retargeted selection link, independent roots | yes | |
| Cancellation at each scan and read gate, exit waiting, failed cleanup | yes (real descriptors, gated; the failed close is reported after a real close) | |
| Public boundary | separately compiled client | |

Which variant ran is visible in the suite's output: an example that needs a
condition the machine lacks is reported pending with the reason, and the
injected example beside it covers the refusal.

## The verified-read pool (LFE-10)

`Hetoimasia.Content.ReadPool` runs [verified reads](#verified-reads) on owned worker threads, for any number of
consumers, without becoming a general executor. It is the read service the raw-data provider
([`hetoimasia-lua-engine`](../lua-engine/README.md#the-raw-data-provider-lfe-10)) uses now and module and texture sources
use later; it knows no Lua, no request, no data limit and no file family. It reads only through `readVerified`, so a
job's result is the exact buffer whose length and SHA-256 the inventory holds, or a structured refusal and no bytes.
It keeps no cache, copies nothing, deduplicates nothing, retries nothing, polls nothing and starts no thread for a
request.

```haskell
withReadPool      ∷ PoolSpec → Inventory → ContentRoot → (ReadPool → IO a) → IO a
reserveSlot       ∷ ReadPool → STM Bool          -- in the consumer's own admission transaction
releaseSlot       ∷ ReadPool → STM ()            -- after the job has retired
submit            ∷ ReadPool → ReadRequest → STM (Either SubmitRefusal ReadTicket)
cancel            ∷ ReadTicket → STM CancelOutcome
retired           ∷ ReadTicket → STM Bool
status            ∷ ReadPool → STM PoolStatus
awaitFailure      ∷ ReadPool → STM (ExceptionWithContext SomeException)   -- the first failure
poolFailureEvidence ∷ ReadPool → STM [(Text, ExceptionWithContext SomeException)]  -- what was recorded beside it
```

### Ownership and lifetime

The pool is one `withReadPool` scope, entered **inside** the root's scope: it starts `workers` threads in a foundation
worker group, so the group's drain finishes every started read before the root (and the inventory it borrows) can be
released. A consumer's lifetime is separate: the pool does not wait for, call or hold anything of a consumer except the
`requestSink` it was handed with a job. The session owns **one** pool (two workers for M1) shared by every consumer and
VM; nothing creates a pool per request, instance or VM.

On any exit the scope first closes admission (a later `submit` answers `PoolIsClosed`), withdraws every queued job and
tells its sink `ReadAbandoned`, and then drains: every read already started runs to its end and settles its job, with
the root still open. A cancellation of the exiting thread neither shortens the wait nor is lost (the group's contract).
A reader stuck in a blocking call keeps the scope, and so the root, live: there is no deadline.

### Bounded work, reserved first

`PoolSpec` has two numbers, validated by `poolSpec`: the worker count (the most reads in flight) and the slot capacity. A specification is read with the `specWorkers` and `specSlots` functions; it has no public record labels, so a validated specification cannot be rewritten by record update into one `poolSpec` refuses.
A *slot* is one unit of queue capacity. A consumer takes one with `reserveSlot` in the transaction that admits its
request, together with its other reservations, and returns it with `releaseSlot` after the job retired. `submit` is a
non-blocking STM transaction that only enqueues, and it requires a reservation: a job beyond the reservations is a
defect of the caller (`ReadSubmittedWithoutSlot`), as is releasing a slot a live job still needs
(`ReadSlotReleasedWhileLive`), and neither leaves anything behind. So the queue, the active reads and the completions
in flight are bounded by reservations that exist (`queued <= live <= reserved <= capacity`), an accepted job is never
refused or retried for want of room, and a full ordinary request or result queue elsewhere cannot block a completion,
a cancel or a drain.

A job names its key, its **byte allowance** (the consumer's own already-reserved bound; the pool imposes none, so the
data family's 8 MiB is not every consumer's), its `ReadPriority` and its sink. Workers take the oldest job of the
strongest class: `DependencyProgress` (the read an active import chain waits for; assigned by module loading, LFE-11)
before `OrdinaryRead`. Raw data is always `OrdinaryRead`.

### A job

| State | Meaning | Left by |
|---|---|---|
| queued | In the queue; no file touched | issuance (a worker took it) or `cancel` / close (withdrawn): one transaction on the pool state, so exactly one wins |
| issued | A worker took it; interest may be withdrawn | the worker's settlement |
| delivering | The worker decided to call the sink; the job's claim on its slot is over | the sink returning |
| done | The sink returned, or its call was suppressed because interest was withdrawn | terminal |
| notifying | Left the queue unissued because the pool closed or failed, and its sink is yet to be told; the slot claim is over, the job is **not** retired | the sink returning (then withdrawn); `cancel` before the call suppresses it |
| withdrawn | Left the queue unissued with nothing to tell (a `cancel`), or was told after notifying | terminal |

`retired` is true from done or withdrawn on, never while a withdrawn job's sink is still being told. It is the **per-job** evidence a consumer builds its retirement reading
from; a worker's exit or the group's drain is not it. The slot's claim ends when the worker decides to deliver, in the
same transaction, **before** the sink runs: the consumer may account the reply and release its slot as soon as the
sink has run. The job is not retired until the sink has returned, so a consumer that withdrew interest and reads
retirement never sees the work over while a worker still holds the buffer it was about to hand over.

`cancel` answers `CancelWithdrawn` (queued: no file was ever opened and the sink will not be called), `CancelInFlight`
(a worker has it: it runs to its end and its sink is suppressed unless it had begun to deliver) or `CancelTooLate`. An
issued job whose interest is withdrawn before the reader was asked for anything skips the read.

### The buffer

`readVerified` allocates the buffer once, at the inventoried length, which the allowance check has already bounded, and
returns that allocation. The worker passes the same `ByteString` to the sink: **no copy, no second reference**. From the
sink call on the allocation is the consumer's, which charges it against its own bank; the pool charges nothing and keeps
nothing. Streaming and hash workspace is the reader's, bounded by the inventory's buffer limit and the worker count.

### Failure

An expected outcome of a verified read is data for the sink (`ReadFailed`, classified as for `readVerified`). Anything
else that a reader or a sink raises is a defect: the job's sink is told (`ReadDefect`), every queued job is withdrawn
and told, the pool latches the first defect with its context and cleanup evidence (`awaitFailure`, composable into a supervised wait; the evidence recorded beside it is `poolFailureEvidence`), refuses all later jobs
(`PoolHasFailed`), and the worker ends with the defect, which the pool's own worker group reports. Nothing restarts. The assembly
observes the latch with `awaitFailure` in a supervised wait; every consumer sees it as refused submissions and as the
`ReadDefect` its jobs were told; and the scope rethrows the latched failure if its body returned. 

#### The failure latch

The latch is two fields of the one pool state: the **first failure**, set once by the transaction that finds none (it also withdraws the queue in
that transaction), and an **append-only evidence list**. Every later failure and every failure raised while telling a queued job is added by
`appendEvidence`, which reads the current list in its own transaction and appends, so additions made by different workers at once are all kept; nothing
reads the latch in one step and writes it back in another. The scope composes the first failure with the list when it rethrows or reports it. These
are the only writers of the latch: the first-failure branch and the two appends in `latchFailure`.

#### Every way out keeps its failure and its evidence

The scope's own exit is not a defect: it closes the pool before it stops or cancels a worker, and a worker the drain cancels
with nothing retained settles the job it interrupted as `ReadAbandoned`. Every other way a worker or the scope can leave is
accounted, whether the pool is open or draining:

| Exit | What is kept, and where |
|---|---|
| A reader or sink raises, before or after the scope closed the pool | latched with its context and cleanup evidence; the scope rethrows it |
| A worker is terminated by an asynchronous exception the scope did not send, or the drain's cancellation arrives with cleanup evidence retained | latched as `ReadWorkerTerminated` with the exception and every cleanup failure it retained |
| A worker returns, or is asked to stop from outside, while the pool is open | latched as `ReadWorkerEndedOpen`; nothing accepted waits behind a pool that stopped running |
| A second worker fails after the first | appended to the evidence list beside the first, which stays the pool's failure |
| A queued sink raises while the pool is telling it (close or failure) | appended to the evidence list, and kept beside the failure being told in what the worker raises |
| The body fails | its failure is primary; a failure a worker had latched is kept beside it as `content read pool worker failure`, and the group's own report of the workers rides on it |
| The body returns | the latched failure is rethrown; otherwise the group's report is read and any worker that failed, was cancelled or retained a cleanup failure is raised as `ReadWorkerReportedUnclean` with that evidence |
| The scope's thread is killed | the group cancels the workers and drains them; the interrupted job is settled `ReadAbandoned` |

### State

| State | Owner | Writers | Readers | Lifetime |
|---|---|---|---|---|
| Pool state (phase, first failure, evidence list, queue, counters) | the `withReadPool` scope | consumers (`reserveSlot`, `releaseSlot`, `submit`, `cancel`), workers (issuance, settlement), close | anyone, via `status` | one scope; never reused |
| A job's state | the pool | `submit`, `cancel`, the worker that took it, close | the consumer (`retired`), workers | from `submit` to done or withdrawn; the ticket outlives it as a value |
| Workers | the pool's worker group | the group | the group's report | started with the scope, drained at its exit |

### Evidence

`Test.Content.ReadPool.*` (group `test.content`): exact bytes (empty, NUL, non-UTF-8, BOM, line endings) through real
temporary roots; the allowance at, one past and absent; at most the configured reads at once, the oldest queued job next
and the dependency class first; the slot reservations and their defects; a consumer releasing its slot inside the sink;
a queued cancel that opens no file, an in-flight cancel, and cancels between issuance and the read and between the read
and publication (held at the pool's coordination hooks, never slept); closing with a started read finishing and delivering;
a withdrawn job held unretired while its sink is told, on a close and on a failure; a reader defect, a worker terminated by an asynchronous exception under an open pool, and a sink failure latching the pool, with the reader's cleanup evidence and the sink's failure both kept; a partial startup drained; cancellation during a drain, including
a read that cannot be interrupted; and each exit of the table above, with a reader terminated or failing after the scope closed the pool, a worker cancelled
with cleanup evidence, a second worker's failure, a failing body beside a latched failure, and a queued sink raising as the scope closes; the root outliving a started read; and a separately compiled client composing a
root, a scan and a pool from public modules alone, with the hooks, the specification constructor and its record update refused. Real-file evidence and injected evidence (a failing reader, the
hooks) are named as such in the examples.

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

The inventory examples (`--match Inventory`, with the components `Scan`, `Limits`, `Changes`, `Aliases`, `Reading`, `Lifecycle` and `Inventory boundary`) are described under
[Evidence](#evidence-1); they reach the implementation through the private library so a recording seam can count acquisitions and closes, hold a scan or a read at a named boundary, and mutate the folder there.

The pool examples (`--match ReadPool`, with the components `Jobs`, `Lifecycle` and `ReadPool boundary`) are described under [Evidence](#evidence-2); they gate a worker at the pool's coordination hooks and at a wrapped reader, never with a sleep.

The identity examples (`--match Identity`) are described under
[Evidence](#evidence); their reference data, `NormalizationTest-17.0.0` and
`CaseFolding-17.0.0` extracts with their provenance in the header, is under
`test/data/`. They reach the Unicode operations through the private library and
the policy through the public `Hetoimasia.Content.Identity`.

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

The M1 manifest and profile (the boot checkpoint that reads them is
`hetoimasia-lua-engine`'s); the Lua library; command-line launch integration;
Lua admission, escalation and exit codes for the identity, inventory and read
outcomes; background file workers, request and result slots, byte banks, module
caches, textures and VM composition; a persistent trusted hash cache, a watcher
or any background inventory refresh; snapshots of all bytes; new symlink
exceptions, hard-link or mount bans, automatic root switching, hostile-OS
confinement and further platforms; privileged mount or device setup.
