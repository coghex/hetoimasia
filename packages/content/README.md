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
nothing and builds no inventory: whole-folder inventory (LFE-6) is the layer
above, which uses the traversal and read boundary documented here and the
logical identity policy below. The native roots validate no logical path:
`Hetoimasia.Content.Identity` (LFE-5, below) is the separate pure layer that
turns a literal reference or an observed name into a logical identity, so the
two never depend on one another.

It depends on `hetoimasia-foundation`, on boot libraries (`base`, `bytestring`,
`containers`, `stm`, `text`) and on the pinned Unicode data packages
`unicode-data` and `unicode-transforms` (see
[Pinned Unicode data](#pinned-unicode-data)): no Lua, graphics, console, game
or sample package.

## Layout

| Component | Directory | Role |
|---|---|---|
| `library` | `src/` | The public facades: `Hetoimasia.Content` (native roots) and `Hetoimasia.Content.Identity` (logical identity), each a closed export list: no name constructor, no descriptor, no adapter, no seam, no constructor of a checked identity value. |
| `library internal` (private) | `internal/` | The implementation, shared by the facades and this package's own suite and visible to no client. `Native` holds the adapter record and the test seam; `Root`, `Gate`, `Access`, `Errno` and `Types` hold the rest of the native layer; `Identity.Unicode`, `Identity.Types`, `Identity.Reference` and `Identity.Mapping` hold the identity policy. |
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

The M1 manifest and profile; the Lua library; command-line launch integration;
Lua admission, escalation and exit codes for the identity refusals; whole-folder
inventory policy, numeric M1
accounting, SHA-256 and fingerprint comparison (LFE-6); background file workers,
request and result slots, module caches, textures and VM composition; new
symlink exceptions, hard-link or mount bans, automatic root switching,
snapshots, watchers, hostile-OS confinement and further platforms; privileged
mount or device setup.
