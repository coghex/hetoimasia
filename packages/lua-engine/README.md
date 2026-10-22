# hetoimasia-lua-engine

The Lua-first engine's **configuration boundary and role policy** (LFE-3, LFE-6 and LFE-8 of
[the design](../../docs/designs/lua_first_engine_design.md)): a strict parser for
the format-1 launch manifest `hetoimasia.json`, from supplied bytes to a
resolved role, entry and tick configuration, the **fixed M1 profile** of
limits with validated, smaller test profiles, the **M1 behavior selection**: which
export field each role selects, the exact cadence rules and the export-module ceilings,
and the **boot checkpoint**: the proof, before any authored Lua, that the manifest
parsed is the manifest the content scan pinned and that every declared entry names an
inventoried regular file.

The library opens no folder, starts no Lua, worker, window or GPU, prints nothing and
exits nowhere. Its manifest, profile and behavior modules perform no IO: every function
is pure and returns a plain value or a bounded refusal. The boot checkpoint reads only
through the verified read the caller passes it (normally the content inventory's), and
imports no module that opens a file itself. The **M1 request adapter**
(LFE-7) is the `request` sublibrary beside it, in a source directory of its own
so that this one stays pure: see [below](#the-m1-request-adapter).

The library depends on `hetoimasia-foundation` (its `Duration`, checked
nanoseconds from 1 to 2^64 − 1), on the Lua host and its runtime
(`hetoimasia-scripting-lua` and its `runtime-lua` sublibrary, for the behavior
selection only: the manifest and the profile import nothing of them) and on `array`,
`base`, `bytestring`, `containers` and `text`; and, for the boot checkpoint only, on the
public modules of `hetoimasia-content` (the anchored root, the logical identity policy
and the inventory). It depends on no GLFW, Vulkan, console, sample or game package, and it
imports no module that performs IO of its own. Later slices add the rest of the role
composition to this package; they are not here.

| Module | Contents |
| --- | --- |
| `Hetoimasia.LuaEngine.Manifest` | `parseManifest`, `parseManifestWith`; `Manifest`, `RoleSelection`, `declaredEntries`; every refusal type |
| `Hetoimasia.LuaEngine.Profile` | `fixedM1Profile`, `validateProfile`; the limit types and their accessors; the derived values |
| `Hetoimasia.LuaEngine.Behavior` | `behaviorField`, `exportLimits`, `cadenceOf`, `behaviorRequest`; `CadenceRefusal` |
| `Hetoimasia.LuaEngine.Boot` | `contentConfiguration`, `bootCheckpoint`, `bootCheckpointFrom`, `checkManifestPinned`; `Checkpoint`, `ResolvedEntry`, `BootRefusal` |
| `Hetoimasia.LuaEngine.Request` (sublibrary `request`) | the M1 request policy over a validated profile and the exact common result adapter: `m1Requests`, `startM1`, `m1ArgumentCheck`, `m1RequestBindings` |

Every other module is hidden. A client of the pure boundary imports the manifest, the profile and the behavior modules.

## The manifest

`parseManifest bytes` takes the bytes of exactly one root manifest and returns
a `Manifest` or the first `ManifestError`. The caller reads the file and names
the root; this package never learns a path.

```haskell
parseManifest ∷ ByteString → Either ManifestError Manifest
parseManifestWith ∷ Profile → ByteString → Either ManifestError Manifest
```

### What a `Manifest` holds, and what it does not claim

- `manifestBytes` are the exact bytes that were parsed (the caller's buffer, not
  a reserialization), so later anchored inventory and fingerprint work checks
  what was actually parsed.
- `manifestId` is the validated stable content identifier, exactly as written.
- `manifestRoles` is `GameplayOnly`, `PresentationOnly` or `BothRoles`. A
  gameplay role carries its tick `Duration` and a presentation role carries no
  tick, so a tick without gameplay, or gameplay without a tick, cannot be
  represented. Each role records its selected entry text and whether it came from
  the role's own `entry` (`ExplicitEntry`) or from the common one
  (`CommonEntry`). A text both roles share is one authored input that each VM
  will still load independently.
- `manifestCommonEntry` and `declaredEntries` keep **every declared entry
  text**, including a common `entry` that every role overrides. The later
  inventory check must cover all of them, not only the selected ones.
- Array order in `vms` is not startup or dependency order and is not recorded.
  No bootstrap VM is invented and no role is created to satisfy an entry.

The result claims nothing about the filesystem. Entry texts are kept exactly as
decoded: the root-relative literal-path grammar, NFC and case identity (LFE-5),
inventory regular-file presence (LFE-6) and hash verification are the content
layer's, and run before any Lua. The parser has no path normalization of its own
that could disagree with that layer.

### Syntax

A non-executable UTF-8 JSON object. RFC 8259 is the grammar; this profile is
stricter in these ways, all refused as `ManifestSyntax`:

- at most **65,536 bytes**, whitespace included (`ManifestTooLarge`, decided
  first and without reading the bytes);
- well-formed UTF-8 (`InvalidUtf8`) and no byte order mark (`ByteOrderMark`);
- no comments, trailing commas, `NaN`, `Infinity`, single quotes, unescaped
  control characters U+0000–U+001F, invalid escapes, or unpaired surrogate
  `\u` escapes; whitespace is only space, tab, line feed and carriage return;
- nesting of at most **eight containers**, the outer object counting
  (`NestingTooDeep`), enforced as containers open;
- no duplicate object key **after JSON escape decoding**, at every object
  (`DuplicateKey`, with the path). Duplicates are looked for before any object is
  collapsed into a map, so there is no last-key-wins behavior;
- nothing but whitespace after the object (`TrailingData`), and the root is an
  object (`RootNotObject`).

No includes, interpolation or execution exist.

**Bounds.** The byte and depth limits come from the profile and are enforced
during parsing, not after a tree exists. A number is kept as slices of the input
and examined by digit counts: no value, `Integer`, power of ten or allocation
grows with an exponent's size, so `1e999999999` costs no more than its nine
digits. Strings and arrays are bounded by the input.

### Schema

| Field | Contract |
| --- | --- |
| `format` | Required JSON number whose **exact decimal value is 1**: `1`, `1.0`, `1e0`, `10E-1` and `0.1e1` are accepted; `1.00000000000000000001`, `0.99999999999999999999`, `-1` and `1e999999999` are refused (`UnsupportedFormat`). Never converted to binary floating point. A string is refused. |
| `id` | Required, 1–64 ASCII characters matching `[a-z][a-z0-9_-]*` (`InvalidId`). Exact case, never derived from a folder. |
| `entry` | Optional common entry text; the fallback for a selected role without its own. |
| `tick_seconds` | Decimal text, required exactly when gameplay is selected (`TickRequired`) and forbidden for presentation only (`TickForbidden`). No default. |
| `vms` | Optional array of one or two role declarations (`EmptyVms`, `TooManyVms`). Absent selects both roles. |

A role declaration is an object with required `role` and `clock` strings and
optional `entry`, and no other field. Only `gameplay`/`logical` and
`presentation`/`elapsed` pair (`UnknownRole`, `UnknownClock`, `ClockMismatch`),
and a role appears once (`DuplicateRole`). An explicit per-role `entry` overrides
the common one; a role with neither is `MissingEntry`.

No `mods`, dependency, compatibility, asset-list, window, cadence or metadata
field is accepted (`UnknownField`). `null` is `NullValue` and a wrong type is
`WrongType`; nothing is ignored or coerced.

### `tick_seconds`

ASCII digits, optionally followed by a decimal point and one to nine digits, with
at least one digit before the point. No sign, exponent, whitespace, fraction
expression, JSON number substitution or default. Leading zeros and trailing
fraction zeros are harmless. The value converts **exactly** to whole nanoseconds
and must be at least 1 and at most 2^64 − 1 (the profile's maximum):
`"0.000000001"` and `"18446744073.709551615"` are the endpoints, and `"0"`,
`"18446744073.709551616"` and a tenth fraction digit are refused with a
`TickProblem`. A whole part too large to matter is refused before it is
converted. There is no rounding.

The `lua` command's own `parseSeconds` accepts the same text for its options. It
is console code and the engine never imports the console, so this package has
its own implementation of the same contract; the console is unchanged.

### Which refusal comes first

The order is fixed, and for a syntactically valid document it never depends on
member order:

1. the byte limit;
2. syntax, on the whole document: UTF-8, byte order mark, grammar and nesting
   (at the first offending byte), duplicate keys (the first object in document
   order that has one, then its first repeated key), trailing data;
3. the schema: unknown fields (the least key by code point, never the first
   written), then `format`, `id`, `entry`, `vms` (elements by index) and
   `tick_seconds`.

A refusal cites a location, never unbounded text: every offending string is an
`Excerpt` cut to 64 code points, and a `FieldPath` is at most eight segments.
Reordering the elements of a valid `vms` array resolves to the same
configuration; a refusal may cite an element's index.

## The fixed M1 profile

`fixedM1Profile` holds the production values, **defined once** and selected by
the future assembly. Nothing reads them from Lua, a manifest, the environment or
the command line, and there is no tuning API. Each limit is one constructor of a
closed type whose unit is the type: `ByteLimit` (`Bytes`), `CountLimit` (`Count`)
and `DurationLimit` (`Duration`). Read one with `bytesLimit`, `countLimit` or
`durationLimit`. KiB, MiB and GiB are powers of 1024.

| Family | Fixed M1 values |
| --- | --- |
| Manifest and content | 64 KiB manifest; depth 8 containers; 10,000 inventory entries including root; 32 path segments; 1,024 UTF-8 path bytes and 255 per segment, on the native/supplied and NFC forms |
| Hashing | 64 MiB per file; 1 GiB per root, summed by path; 64 KiB streaming buffer |
| Modules | 1 MiB source; 256 identities per VM including pending and failed; chain depth 32 including the root; 16 MiB uncompiled source bank per VM with 1 MiB reserved for the active chain's progress |
| Instances and requests | 2 instances per VM; the normal launcher creates one root per role; 16 accepted, unretired requests per instance and 64 per VM |
| Data and copied values | 8 MiB data or result; 64 MiB retained data bytes per VM; a copied crossing of 16 MiB, depth 8 and 65,536 elements |
| Scenes | 4,096 sprites; 2 MiB encoded input; depth 4; one latest scene and one bounded publication draft per window; no publication FIFO |
| Diagnostics | message 2 KiB; traceback 8 KiB; complete role-failure record 16 KiB; opaque instance ID 128 UTF-8 bytes; engine report 64 KiB with at most 16 secondary summaries of 2 KiB each; print and warn 4 KiB per call |
| PNG | 32 MiB encoded; 4,096 chunks; axes 1–2,048; 4,194,304 pixels; 40 MiB of inflated scanlines; 128 MiB accounted payload and workspace per texture pipeline |
| Textures | 16 pending, live and retiring leases and 128 MiB nominal bytes per UI instance; 256 MiB per session |
| Windows and sprites | 1 pending, live and retiring window slot per UI instance; title 512 UTF-8 bytes; requested width and height 1–4,096; x and y in [−1,000,000, 1,000,000]; width and height in (0, 1,000,000] |
| Native budget selection | 2 target records; 2 frame slots per window and 4 aggregate; 4 frameless batches; 2 generations per target; 16 tracked images per generation; 2 GiB accounted native bytes; 4,096 objects; reclaim pass of 64 records; 32 progress actions per turn; 100 ms maximum idle backoff |
| Workers | 2 I/O workers, 1 decode worker, 2 texture pipeline lanes |
| Numeric ranges | Lua logical tick, cadence, offset and wait counts and generated public counters through 2^63 − 1 (init tick 0, positive counts from 1); manifest duration through the full positive Word64 nanosecond range |

These are **configuration values**, not proof of live accounting, codec
allocation safety, GPU availability or a total Lua or process memory cap. The
slices that own admission and retirement enforce them, along with Float32
geometry, elapsed conversion and scheduling. They bound engine service payloads,
not Lua or process memory. The native budget values stay CPU data here; mapping
them into the backend's validated model belongs to the graphics composition.

### Derived, not stored

- `pngOutputBytes` is `rgba8BytesPerPixel` (4) times the pixel limit: 16 MiB.
  The same value is reserved at texture admission.
- `sceneElementBound` is 6 fixed elements plus 6 per sprite under the
  copied-value element counting (a table is one element, a key none): 24,582 at
  4,096 sprites, within 65,536.
- The **six adopted scene revisions per target** are not a limit here. The
  profile records the two frame slots per window; the graphics composition
  derives six from them (`2 * (slots + 1)`, owned by the Vulkan package, which
  this package never imports) and defers adoption when full.

### Smaller injected profiles

A test builds one by changing a copy of `profileSpec fixedM1Profile` and
validating it. `validateProfile` checks, in order, that the derived products fit
64 bits (`DerivedOverflow`), that every limit is positive and **no larger than
its fixed value** (`LimitNotPositive`, `LimitAboveFixed`), and that the
relations below hold (`RelationBroken`). A profile can only shrink; no value is
clamped. The 64-per-VM request limit is not "corrected" to fit 16 per instance
times 2 instances: independently bounded maxima need not be simultaneously
attainable.

| Relation | Meaning |
| --- | --- |
| `ManifestWithinHashFile`, `ModuleSourceWithinHashFile`, `HashFileWithinHashRoot` | the manifest and a module are files the hashing limit admits, and a file fits its root |
| `ActiveChainReserveHoldsModuleSource`, `ActiveChainReserveWithinSourceBank` | the active-chain reservation can hold one module's source and fits the bank |
| `ChainDepthWithinIdentities`, `RequestsPerInstanceWithinVm` | an active chain is among the cache identities; an instance's requests are among its VM's |
| `DataWithinRetainedBank`, `DataWithinCopiedValue` | a data result fits the VM's retained bytes and the crossing |
| `SceneInputWithinCopiedValue`, `SceneDepthWithinCopiedDepth`, `SceneElementsWithinCopiedElements` | scene limits fit the copied-value ceilings |
| `FailureRecordHoldsMessageAndTraceback`, `FailureRecordHoldsInstanceId`, `SecondarySummariesWithinReport` | a failure record holds its parts; the secondary summaries fit the engine report |
| `SegmentWithinPath`, `PathSegmentsWithinPathBytes` | a segment fits the path; each segment takes at least a byte |
| `PixelsWithinAxes` | the pixel limit does not exceed the axis limit squared |
| `OutputWithinTextureBytesPerUi`, `TextureBytesPerUiWithinSession`, `OutputWithinPipelineWorkspace`, `InflatedScanlinesWithinPipelineWorkspace` | one image's output fits a UI instance's bytes, which fit the session's, and fits the pipeline workspace with the inflated scanlines |
| `FrameSlotsAggregateHoldsWindow`, `FrameSlotsAggregateWithinTargets` | the aggregate holds one window's slots and no more than all targets could use |

## The M1 behavior selection

LFE-8 adds the policy that sits over the Lua runtime's generic behavior mechanism
([`hetoimasia-scripting-lua`](../scripting-lua/README.md#export-modules-and-captured-behaviors)).
That mechanism evaluates an export module, keeps its returned table in the VM, validates a behavior's
fixed schema and captures its hooks for an instance; it knows no role. This module is the M1 choice made
over it, and it is as pure as the rest: it evaluates nothing and starts no VM. It imports only the
Lua host's and runtime's public modules, which a boundary example checks.

| Function | What it decides |
| --- | --- |
| `behaviorField role` | the export field a role selects: `gameplay` or `presentation`, read by raw access; nothing else in the table is looked at |
| `exportLimits profile` | the source and identity ceilings of a VM's export modules, from the profile: `ModuleSourceBytes` (1 MiB) and `ModuleIdentitiesPerVm` (256), failed and in-progress ones counted |
| `cadenceOf role shape` | the interval a behavior's `update` falls due on, from what its table read as, or the first `CadenceRefusal` |
| `behaviorRequest role identity label facade name class` | the request that admits an instance of a role's behavior: the field, the injected facade and the role's rule |

The role and the facade are the caller's: the assembly supplies the role, and the facade is the narrow
per-instance value the later service package builds. Nothing a module's returned table says chooses
either. The manifest's tick duration keeps its full positive 64-bit range: gameplay's cadence is a whole
number of ticks of whatever tick duration the owner was configured with, and nothing here defaults or
changes one.

### Cadence

Applied to a behavior that has an `update` hook. A behavior without one has no cadence, stays alive until
it is stopped, and has neither cadence field: either is an error (`CadenceWithoutUpdate`).

| Role | `every_ticks` | `every_seconds` |
| --- | --- | --- |
| gameplay | optional, default 1; a Lua **integer** from 1 through 2^63 − 1 | refused (`FieldNotAllowed`) |
| presentation | refused (`FieldNotAllowed`) | **required**; a Lua integer or float, finite and positive |

* A tick count must be an integer. An integer-valued float such as `1.0`, a numeric string, zero, a negative
  number and a table are refused (`TicksNotInteger`, `TicksNotPositive`); nothing is coerced. 2^63 is not an
  integer (Lua reads it as a float), so overflow is refused too.
* Seconds convert **exactly**: the value the Lua number represents (an integer's, or the exact rational a
  double is) times 1,000,000,000, rounded **upward**, must be a positive 64-bit count of nanoseconds
  (`SecondsTooLarge` otherwise). The conversion is `Integer` arithmetic, never a floating product that could
  overflow or round down, and never the source literal: `0.1` is the nearest double to a tenth, which is
  slightly above it, so it converts to `100000001` ns. A positive input below a nanosecond is one nanosecond,
  never zero. There is no default interval for a UI.
* The result is an `Interval` (`LogicalTicks`, or `ElapsedEvery`) the runtime resolves exactly or not at all
  through its existing scheduler; there is no new timer and no change to `dt`.

### What proves it

`Test.LuaEngine.Behavior`: the field of each role; the limits from the fixed profile and a smaller validated
one; the gameplay endpoints (1 and 2^63 − 1), the refusals of zero, negatives, floats of any value, strings and
tables, and of seconds; presentation's mandatory interval, finite and positive checks, sub-nanosecond input
rounded upward, `0.1`, the largest accepted count and the first refused one, checked against an independently
written integer oracle over the doubles on both sides of the boundary and across a spread of magnitudes; the
no-update behaviors; and the request carrying the role's rule.

## The boot checkpoint

`Hetoimasia.LuaEngine.Boot` is the small manifest-to-inventory check that runs after
the content scan and before any authored Lua (LFE-6). It starts no VM, worker, pool,
window or launcher command, parses and compiles no Lua, and claims nothing about the
behavior of an entry. The launcher opens the content root once, scans it into an
`Inventory` ([the content package](../content/README.md#whole-folder-inventory-and-verified-reads-lfe-6)),
keeps the same anchored root for the session, and asks this module for the result.

```haskell
contentConfiguration ∷ Profile → Either ConfigurationRefusal ContentConfiguration
bootCheckpoint       ∷ Profile → Inventory → VerifiedReader → IO (Either BootRefusal Checkpoint)
bootCheckpointFrom   ∷ Profile → ContentRoot → Inventory → IO (Either BootRefusal Checkpoint)
checkManifestPinned  ∷ Inventory → Manifest → Either BootRefusal ()
```

`contentConfiguration` is the only place the content layer's numbers come from: the
fixed M1 profile gives 10,000 entries including the root, 32 segments, 1,024 path bytes
and 255 per segment, 64 MiB per file, 1 GiB per root and a 64 KiB buffer, and a validated
smaller profile gives smaller ones through the same check. The content package holds no
default.

A `VerifiedReader` is the narrow service the checkpoint reads the manifest through
(`bootCheckpointFrom` passes the inventory's own `readVerified` over the open root). The
checkpoint, in order:

1. names `hetoimasia.json` exactly (a name the limits in force cannot hold is
   `ManifestNameRefused`);
2. asks the inventory alone: no such entry (including a root that holds only
   `Hetoimasia.json`, and a valid manifest in the parent folder) is `ManifestAbsent`; a
   directory at that name is `ManifestNotAFile`; an inventoried length above the 64 KiB
   manifest limit is `ManifestOverLimit`, decided before a byte is read. No other
   spelling and no other folder is searched;
3. reads the pinned bytes through the verified reader within that limit (a refused read
   is `ManifestReadRefused`, with the read's own outcome), compares them once more with
   the inventoried length and digest (`ManifestNotPinned`), and **parses the manifest
   from those bytes**, so the bytes parsed are the bytes pinned and nothing is ever
   reserialized or compared as JSON (`ManifestRefused` carries the parser's refusal,
   whose schema and depth behavior is unchanged);
4. validates every declared entry text, in `declaredEntries` order, as a literal
   root-relative reference under the content identity policy and requires it to name an
   inventoried regular file: `EntryReferenceRefused`, `EntryAbsent` (including a case
   mismatch) or `EntryNotAFile`. A common `entry` that every selected role overrides is
   checked like any other.

A `Checkpoint` carries the manifest, the manifest's content key, a `ResolvedEntry` (slot,
text, key and inventoried length) for every declared entry, and the content key each
selected role will load, gameplay before presentation. The later launcher consumes it
under the root it already holds; this package neither starts those roles nor wires the
`run` command.

`checkManifestPinned` answers the other order: a `Manifest` parsed from revision A while
the scan pinned revision B is refused with `ManifestNotPinned` however alike the two
documents parse, because it compares the parsed manifest's exact bytes with the
inventoried length and SHA-256.

Ordinary refusals are values. Cancellation, misuse and a failing reader propagate as the
exceptions they are; the checkpoint holds no handle and no buffer beyond the manifest
bytes it was handed, which it keeps only inside the `Manifest` it returns, so there is
nothing to release.

### What proves it

`Test.LuaEngine.Boot`, over real temporary folders and the packages' public interfaces
only: the content configuration from the fixed profile (the approved numbers, read back)
and from a validated smaller one; a common entry, separate entries with a fully overridden
common entry, and both one-role arrangements; the manifest at exactly 65,536 bytes and one
past it (refused before the reader is called), under the fixed and a smaller profile; a
missing manifest, a case-mismatched one, one in the parent folder, a directory at its name;
the A/B cases (a replaced manifest of the same or another length, valid or not, refused at
the read; a manifest parsed from A beside a scan that pinned a valid or an equivalent B
refused; the same bytes accepted; a reader that returns other bytes refused); every
declared entry refused when it is an invalid reference, absent, a case mismatch or a
directory; cancellation while the checkpoint holds the read, after which the root still
closes and a fresh checkpoint is whole; a failing reader propagating; two folders booting
independently; and a separately compiled client composing the root, the scan and the
checkpoint through public modules.

## The M1 request adapter

`Hetoimasia.LuaEngine.Request` (LFE-7, sublibrary `request`) is M1's policy and result adaptation over the host's
opt-in admission, [`Hetoimasia.Scripting.Lua.Admission`](../scripting-lua/README.md#atomic-request-admission). The
host supplies the mechanism: one transaction that reserves a request's places, result lease and provider credits
together or answers busy with nothing reserved, the timing assignment, the required-failure latch, the one-shot
settlement and the cancellation race. This module supplies what is M1's. It depends on the profile, on `scripting-lua`
and its `runtime-lua` and on base libraries, imports no private module of the host, and imports nothing of a game, a
window, a GPU, the console or the content layer. It implements **no service**: a texture, data, module or window
service builds its own request-producing binding from `startM1`, with its own endpoint, expected failure codes,
credits and lease, and assembles the four operations under `api.request`.

### Policy from the profile

`m1Requests profile handles` reads, once, from a validated `Profile`: 16 accepted, unretired requests per instance
and 64 per VM (`RequestsPerInstance`, `RequestsPerVm`; the 64 is **not** reduced to the 32 two instance slots reach, so
the aggregate refusal is exercised with a validated smaller profile), the copied-value ceilings (`CopiedValueBytes`,
`CopiedValueDepth`, `CopiedValueElements`), the 2 KiB message (`MessageBytes`), the path bound (`PathBytes`) and the
numeric ceiling (`LuaIntegerMaximum`, 2^63 − 1: the largest tick, offset and request number). A smaller injected
profile reaches the adapter only through `validateProfile`.

### What a script sees

A request-producing call, written by a service, is a dot call and answers two values: `request, nil` when accepted,
or `nil, {code = "busy", message = TEXT}` when a temporary bank had no room (`m1StartResults`, `m1StartSchemas`). Busy
is data: not an error, not the instance's failure, with no handle, provider action or partial reservation; a later
call may succeed, nothing retries it, and the message is bounded by `MessageBytes`.

The request is an opaque handle owned by the instance that made it, including across two instances of one VM
(`m1HandleType`, over the `RequestHandles` the owner is given). The four operations (`m1RequestBindings`):

| Operation | Answers |
| --- | --- |
| `ready(r)` | a Boolean; consumes nothing |
| `take(r)` | `{status="pending"}`, consuming nothing; otherwise exactly one fresh record, and the handle is spent: `{status="success", value=VALUE}`, `{status="failure", error={code=CODE, message=TEXT, root=ID, path=PATH}}` or `{status="cancelled"}` |
| `cancel(r)` | `"cancelled"` when this call won the settlement, `"already_settled"` when the request had settled |
| `wait(r)` | no values; suspends cooperatively without blocking the VM thread and consumes nothing; refused in `init` and `shutdown` before waiting |

Only the fields of the variant are present. A content failure carries `root` and `path`; a window failure omits them.
The message is bounded diagnostic detail, cut at a character with a visible `...` to the profile's bound, and the whole
envelope is measured against the owner's limits when the reply is accepted, so a settlement that is retained is one
that can be delivered. Wrong arity, wrong type, wrong kind of handle, another instance's or a spent handle, and a wrong
phase are ordinary Lua errors raised before any provider action (`recoverableRefusals`, and a precondition for the
phase); an invocation that catches one can still succeed, and it cannot clear a required failure that was latched.
Cancellation is itself a terminal result to take. The codes of a service's failures are the service's
(`askCodes`); this module does not classify filesystem or image failures.

### Permanent refusals

Wrong role, phase or ownership, a malformed or unrepresentable offset and exhausted request numbers are permanent:
ordinary Lua errors with no handle and no work, never busy. A service composes `m1ArgumentCheck` into its
request-producing binding with `withArgumentCheck`, which decides them from the copied argument values and the
engine's own state, before the action. A permanent refusal of the service's own (a second window while one is held, say)
is a check of its own beside it, and stays distinguishable from a bank that is merely full. Exhaustion or arithmetic
that fails after a valid admission is an engine failure, never a retroactive busy.

### What is not here

The content, data, module and texture services and their providers, the window service, the two-role startup and
failure coordinator, session and role escalation, time and output APIs, native resource banks and retirement, real
pacing and any claim of replay or cross-platform determinism. Fake providers prove the reservation and runtime
boundary here, not later real-provider accounting.

### What proves it

`Test.LuaEngine.Request.*`, in `lua-engine-tests`, run real instances on a real supervised scheduled owner with a
controlled fake provider, fake credit banks and fake lease resources, bindings written the way a facade writes them,
and validated smaller profiles: the busy record and its bound; 16 per instance at the fixed profile and the VM bound
through a profile whose instance bound is below it; every variant of the four operations; wrong phase, handle and
kind; the texture lease built and kept live after a take; the numeric ceiling and the request numbers from the
profile; the message, path and copied-value bounds, where a reply that breaks them is a provider defect and never an
envelope; a service's own permanent refusal said apart from busy; and required and optional failure through the
adapter. They build every fixture beside the suite from public host modules; none is imported from the host's suites.

## Deferred, by design

Not here, and not claimed: the CLI `run` dispatch and exit mapping (LFE-22), which will
consume the boot checkpoint and retain the same anchored root;
the loader and import resolution (LFE-9), the concrete content, time, graphics and status
service facades (only the request adapter's common operations are here) and their metadata and grant policy (LFE-12), workers and session startup; live codec, texture and GPU budgets and their
enforcement; time sampling and scheduling; mods, metadata extensions, alternate
manifest formats, defaults or relaxed parsing.

## Tests

`lua-engine-tests` (validation group `test.lua-engine`, the CPU project, Hspec):

```sh
cabal test --project-file cabal.project.cpu hetoimasia-lua-engine:lua-engine-tests --test-show-details=direct
```

The manifest, profile and behavior examples perform no IO and start no Lua; the boot checkpoint's
examples scan real temporary folders through the content package and evaluate nothing (the Lua host's behavior
mechanism is tested in its own suites); the request adapter's examples start real Lua instances on a real
supervised owner, with controlled fake providers, and no window or GPU. It covers the accepted
examples, every syntax and schema refusal with the limits at their boundary and
one past, the exact tick endpoints and forbidden forms, every fixed value against
an independently written expectation, valid smaller profiles and refused ones,
the behavior selection's cadence rules and numeric boundaries, the boot checkpoint (see above), the request adapter (see above), and this package's dependency and import boundary.
