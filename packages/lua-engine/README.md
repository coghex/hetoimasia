# hetoimasia-lua-engine

The Lua-first engine's **configuration boundary and role policy** (LFE-3, LFE-6 and LFE-8 of
[the design](../../docs/designs/lua_first_engine_design.md)): a strict parser for
the format-1 launch manifest `hetoimasia.json`, from supplied bytes to a
resolved role, entry and tick configuration, the **fixed M1 profile** of
limits with validated, smaller test profiles, the **M1 behavior selection**: which
export field each role selects, the exact cadence rules and the export-module ceilings,
and the **boot checkpoint**: the proof, before any authored Lua, that the manifest
parsed is the manifest the content scan pinned and that every declared entry names an
inventoried regular file; and the **session coordinator** (LFE-13), which composes the
selected roles' VMs into one session and owns how they start, advance, fail and stop together.

The library opens no folder, starts no Lua, worker, window or GPU, prints nothing and
exits nowhere. Its manifest, profile and behavior modules perform no IO: every function
is pure and returns a plain value or a bounded refusal. The boot checkpoint reads only
through the verified read the caller passes it (normally the content inventory's), and
imports no module that opens a file itself. The **M1 request adapter**
(LFE-7) is the `request` sublibrary beside it, in a source directory of its own
so that this one stays pure: see [below](#the-m1-request-adapter). The **raw-data provider**
(LFE-10) is the `data` sublibrary, the **module coordinator** (LFE-11) the `modules` sublibrary, the **texture
pipeline** (LFE-16) the `texture` sublibrary, the **authoring facade** (LFE-12) the `facade` sublibrary and the **session
coordinator** (LFE-13) the `session` sublibrary, for the same reason:
see [the data provider](#the-raw-data-provider-lfe-10), [the coordinator](#the-module-coordinator-lfe-11),
[the texture pipeline](#the-texture-pipeline-lfe-16), [the facade](#the-authoring-facade-lfe-12) and
[the session coordinator](#the-session-coordinator-lfe-13).

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
| `Hetoimasia.LuaEngine.Data` (sublibrary `data`) | the raw-data provider over the content package's read pool and the per-VM byte bank: `dataService`, `dataEndpoint`, `dataKey`, `startData`, `dataArgumentCheck`, `newByteBankFor` |
| `Hetoimasia.LuaEngine.Modules` (sublibrary `modules`) | the module-job coordinator over the loader, the request protocol and the read pool: `withModuleCoordinator`, `coordinatorPlan`, `coordinatorEndpoint`, `attachLoader`, `moduleKey`, `startModule`, `moduleArgumentCheck`, `bootModule`, `lookupImmediate`, `coordinatorCounts`, `awaitDrained` |
| `Hetoimasia.LuaEngine.Texture`, `Hetoimasia.LuaEngine.Texture.Backend` (sublibrary `texture`) | the texture pipeline: `textureSpec`, `withTexturePipeline`, `newTextureOwner`, `textureService`, `textureEndpoint`, `textureKey`, `startTexture`, `textureArgumentCheck`, `withTexture`, `releaseTexture`; and the backend port `TextureBackend`, `Upload`, `UploadSink` |
| `Hetoimasia.LuaEngine.Scene` (sublibrary `scene`) | the fixed M1 scene schema: `sceneLimits`, `prepareScene`, `PreparedScene`, `SceneContent`, `textureUses`, `SceneRefusal`, `sceneCandidate`, `initialContent`, `sceneSchema`, `sceneArgumentCheck`, `scenePublishBinding` |
| `Hetoimasia.LuaEngine.Facade` (sublibrary `facade`) | the M1 authoring surface of one VM: `newFacade`, `FacadeSpec`, `FacadeEndpoints`, `installFacade`, `facadeInstanceConfig`, `facadeRequestEndpoints`, `declareInstance`, `forgetInstance`, `inventoryResolver`, `lexicalResolver`, `withOutput`, `writeAuthored`, `newInstanceIds` |
| `Hetoimasia.LuaEngine.Session`, `.Session.Failure`, `.Session.Pacing`, `.Session.State` (sublibrary `session`) | the session coordinator: `runSession`, `SessionSpec`, `Session`, `sessionStatus`, `sessionOutcomeNow`, `requestStop`, `latchTerminalFailure`; the status and outcome vocabulary, the failure schema and its bounds, the pure pacing arithmetic and the pure state machine; `Harness` as an abstract type and `noHarness` |
| `Hetoimasia.LuaEngine.Session.Harness` (private sublibrary `session-harness`) | the session's test seams: the probe, the second instance of a role and the tick counter's base; reachable from this package's own test suite alone |

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
| `exportLimits profile` | the source, identity and chain ceilings of a VM's export modules and of the Lua host's module loader (LFE-9), from the profile: `ModuleSourceBytes` (1 MiB), `ModuleIdentitiesPerVm` (256), failed and in-progress ones counted, and `ModuleChainDepth` (32), the root counted; the loader holds exactly these, and `Test.LuaEngine.Loader` runs a real owner configured from the fixed profile |
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

## The raw-data provider (LFE-10)

`Hetoimasia.LuaEngine.Data` (the `data` sublibrary) answers a request for the exact bytes of an inventoried file. It is a
**composable typed endpoint**, not a Lua API: `api.content.data(path [, options])` of [the facade](#the-authoring-facade-lfe-12)
(LFE-12) parses its arguments with `dataKey`, builds its binding from `startData` and `dataArgumentCheck`, and declares `dataValueSchema`
(a byte string) for the common `take`. Nothing here is installed in a VM; the
examples drive it through a binding of their own. It imports the profile, the [request adapter](#the-m1-request-adapter),
the content package's public modules (`Identity`, `Inventory`, `ReadPool`) and the host's public modules, and nothing of a
game, window, GPU or console.

### What a script receives

A successful `take` yields `{status = "success", value = BYTES}`: the whole file copied to an ordinary Lua string, with NUL,
invalid UTF-8, a byte order mark, line endings and an empty file preserved. No text decoding, normalization, parser,
execution, serialization or Lua resource lease is involved, and the string is ordinary Lua memory after `take`: it stays
usable after the request retires and needs no release. The result and its envelope fit the profile's crossing: 8 MiB of
data plus the record around it is well inside 16 MiB. Nothing is cached: every request of a path repeats the verified
read.

An expected failure carries one of `not_found` (not an inventoried regular file: absent, a directory, another case, or a
file added after the scan), `content_changed` (the content is no longer what the scan pinned, or no longer a permitted
type), `io_error` or `too_large`, with the root and path of the file and a bounded message. A malformed address is a
permanent argument error before any admission (`dataKey` refuses it), never a content failure. The host's required and
optional rules, timing and cancellation apply unchanged: nothing is duplicated in the provider.

### What is reserved, and when

One transaction admits a request (the host's `startAdmitted`) and reserves, before the provider is handed anything:

| Reservation | Owner | For which requests |
|---|---|---|
| Request and result records, per-instance, per-VM and owner places | the host | every request |
| The file's known length in the VM's `ByteBank` (`data bytes`) | this service, one bank per VM: the profile's `RetainedDataBytesPerVm` (64 MiB), made only by `newByteBankFor`; `dataService` refuses a bank whose limit is not the profile's | an eligible file (a zero-byte file reserves none but still a slot) |
| One queue slot of the session's pool (`io queue`) | the pool | an eligible file |

A closure that lands between the argument check and the admission (the owner ended, or the pipeline began closing) is a permanent
refusal, never busy: the liveness credit fails inside the admission, and `startTexture` answers `TextureRefused` with the reason
(`TextureStarted` carries the host's answer otherwise); the facade raises it as the error it is. A bank without room is the host's busy answer, naming the bank, with **no file work and nothing left reserved**
(`catchSTM` undoes a half-made reservation: a request that wins the bytes and loses the slot leaves no byte charged).
Two VMs asking at once for the pool's last slot get exactly one acceptance. A path the inventory does not hold, and a file
over the data ceiling (`DataBytes`, 8 MiB), are **not** busy: they are accepted with only their records and fail as
`not_found` / `too_large` without a worker, a file open or a payload byte, even while the byte bank is full. The inventory
is immutable, so classifying a request when it is asked and when it is handed over cannot disagree.

### The byte bank and the buffer

The bytes charged for a request are the one allocation the verified read produces (see
[the pool](../content/README.md#the-buffer)). They are charged from admission, while the job waits, while a worker reads,
while a finished result is held for its logical tick or waits for `take`, and while a cancelled request's read is
retiring. They are returned only when the host returns the credit: after the result was taken or discarded **and** the
provider's work is retired, at an accounted boundary of the owner, never from a worker's thread. Cancelling, losing the
Lua handle, `ready`, `wait` or the instance ending is not evidence of retirement. The same allocation is never charged
twice, and no separately retained engine payload is left uncharged. The bank bounds the payload this service retains, not
Lua's or the process's memory. One bank belongs to one VM and is shared by its instances; one instance's cleanup discards
only its own results; a VM that ends returns its own bytes and neither stops the pool nor touches another VM's bank.

### Settlement

Both logical and presentation instances may ask. The provider passes the requesting metadata (necessity, source, offset)
to the host and keeps no timing or failure latch of its own: on logical time a finished result is held, hidden from `ready`,
`take` and `wait`, until its assigned position (default offset 1, init at tick 0), a late read holds its tick, and a cancel
before the position wins; on arrival a result settles when it comes. A worker never waits for any of that: it releases its
execution slot when the sink returns.

### Failure and teardown

Failures known at admission use no worker. A reader, pool or sink defect is a `ProviderFailure`, which the host treats as
a provider defect: it fails the owner at its next boundary, required or optional alike, and is never given a code. A pool
that cannot take a job (closed or failed) raises from the endpoint's submit, so the host takes the request back whole
(credits returned unused) and fails the owner. Nothing here retries, restarts, polls or times out; a read that never
returns keeps its owners live. The pool outlives the owners: the session builds it inside the scopes of the root and
inventory and encloses the owners' supervision with it.

### State

| State | Owner | Writers | Readers | Lifetime |
|---|---|---|---|---|
| `ByteBank` charge | one VM's `DataService` | the host's admission (`creditReserve`) and the owner's boundaries (`creditRelease`) | `byteBankCharged` | the VM's service; zero at rest |
| Pool slots and jobs | the session's pool ([content](../content/README.md#the-verified-read-pool-lfe-10)) | the same, and the pool's workers for the jobs | `status`, `retired` | the pool's scope |
| Request records, holds, places | the host | the host | diagnostics | per [admission](../scripting-lua/README.md#atomic-request-admission) |

### What proves it

`Test.LuaEngine.Data.*` (group `test.lua-engine`) run real instances on real supervised owners, a real temporary content
root, inventory and pool, and the production reader behind gates. Real-file evidence: exact bytes for empty, NUL,
non-UTF-8, BOM and line-ending content, taken once and usable after retirement; repeated independent reads; a file at the
ceiling and one byte over; the fixed profile's exact 8 MiB inside the 16 MiB crossing; same-size edit, growth, removal and
replacement by a directory, including edits made after a job was queued; a file that really cannot be opened (mode 000;
reported pending, not passed, where the process can read it anyway). Injected evidence, labelled in the examples: an
`io_error` and a reader defect produced by a replaced reader. Races, each gated rather than slept: busy with zero file
work and nothing leaked; no overbooking by simultaneous VMs; checked bank arithmetic and a bank that is not the profile's refused; at most two reads at once with the
oldest queued read next; a finished result held for a future tick while its worker runs another read and its bytes stay
charged; default and explicit due positions; a late read holding the tick; reversed completion order not changing
delivery order; queued and in-progress cancels; an early held result against a cancel; instance stop waiting for a
read; one instance or VM ending while another carries on; an owner stopped repeatedly; every place held yet completions
still landing; and a pool that is down when a request is handed over.

## The texture pipeline (LFE-16)

`Hetoimasia.LuaEngine.Texture` (the `texture` sublibrary) answers a request for a **usable, instance-owned texture**: one
operation covering a verified read, a static PNG decode, an upload and a registration. It is a composable typed endpoint,
not a Lua API: the eventual graphics facade (LFE-21) parses its arguments with `textureKey`, builds its binding from
`startTexture` beside `textureArgumentCheck`, registers the handle type `texture` over its `Leases`, and binds
`releaseTexture` to `release`. Nothing is installed in a VM. It imports the profile, the [request
adapter](#the-m1-request-adapter), the content package's public modules, the [bounded PNG
decoder](../asset-image/README.md#bounded-png-decode), the foundation's resource and worker modules and the host's public
modules, and nothing of a game, window, GPU, Vulkan, GLFW or console. **It cannot succeed without a backend**:
`TextureBackend` is injected (below), and the concrete implementation is LFE-17's; a fake backend is a test fixture only.

### What a script receives

A successful `take` yields `{status = "success", value = {texture = HANDLE, width = INTEGER, height = INTEGER}}` with the
instance's opaque texture lease and the source dimensions (`textureValueSchema`). Success is made only by the backend's
evidence that the upload completed **and** the registration is usable; a decoded image, an accepted submission or an
allocated native handle is none of that. It promises no displayed frame and no window, and works before any window exists.
An expected failure carries one of `textureCodes` with the root and path: `not_found`, `content_changed`, `io_error`,
`too_large` (a file over 32 MiB, or a decode over a limit, the lane's workspace included), `unsupported_format` (not a PNG,
or animated) and `invalid_image`. A malformed address, a wrong phase and a closed owner are ordinary Lua errors before any
admission. Texture acquisition is **presentation-instance hook work**: each instance's `TextureOwner` carries the role its facade
boundary declared for it (`newTextureOwner pipeline role`, from the instance's immutable metadata, never from Lua), and an owner
for a logical instance is refused before any reservation. Required is the default and optional is explicit; there is no tick
offset. A backend, device, allocator, reader or
cleanup fault is a provider defect: it fails the owner, required or optional alike, is never given a code and never busy.

### What is reserved, and when

One atomic admission (the host's `startAdmitted`) reserves, before the provider is handed anything:

| Reservation | Bank | Returned |
|---|---|---|
| Owner liveness (nothing is reserved) | the texture owner is open and the pipeline is open, read in the admission's own transaction | n/a |
| Request and result records, the owner's places | the host: 16 per instance, 64 per VM | the result taken **and** the work retired |
| Result lease capacity | the instance's lease scope | with the instance's lease |
| One texture slot | `texture slots`: 16 pending/live/retiring per UI instance | the texture proved retired |
| 16 MiB of nominal RGBA8 bytes | `texture bytes`: 128 MiB per instance and 256 MiB per session, taken from both or neither | shrunk to `width * height * 4` once the decode validated the dimensions; the remainder returned when the texture is proved retired |
| One accepted-work record | `texture jobs`: the session's job capacity (`textureSpec`), which bounds every stage queue | the request taken and its work retired |
| One queue slot of the shared read pool | `io queue` | the request taken and its read retired (only for a file that will be read) |

A bank without room is the host's busy answer, naming the bank, with **no file open, no decode, no backend call and nothing
left reserved**; a refusal that races other admissions takes nothing from them, because every reservation is made in one STM
transaction. The 16 MiB is reserved without reading a header, so a small image can be refused busy while larger
reservations are held: accepted behavior. A file the inventory does not hold, or one over 32 MiB, is accepted and fails
without a worker. The slot and the nominal bytes **transfer** to the texture when a lease adopts it: they are not returned
when the request is taken, when the pipeline's CPU buffers retire or when Lua loses its handle, but when the backend proves
the texture itself retired.

### The pieces and who owns them

| State | Owner | Writers | Readers | Lifetime and disposal |
|---|---|---|---|---|
| The pipeline's one state (`PState`: jobs, lanes, orphans, latch) | the pipeline scope, `withTexturePipeline` | the host's admission and credit release, the read workers' sinks, the decode worker, the backend's sink calls, the drain; always STM | `pipelineReading` | the scope; the drain waits for every started stage before it returns |
| A texture owner's banks and role | one instance's bindings, from `newTextureOwner` (no registry) | admission, the decode stage's shrink, the lease and the pipeline's housekeeping | `ownerReading` | until its textures are retired; `closeTextureOwner` only stops new requests |
| A lane and its workspace bank (128 MiB) | the pipeline | the read sink, the decoder's account, the handoff, the backend's buffer retirement | `readingLanes` | a job holds it from the start of its read until the backend stops reading the level |
| A job (stage, buffers, withdrawn/stopping flags) | the pipeline | the same | diagnostics | from admission until the host returns its record; entries exist only for admitted requests |
| A texture's `Cell` | the pipeline until the answer offers it, then the host (adopt or drop), then the lease | the backend's sink, the answer's offer, the adoption recipe, the release | the retirement readings | one transition per decision on the cell (offer, adopt, claim); exactly one party calls the backend's release, once |

There are two session read workers (the shared pool, LFE-10), **one decode worker** and **two lanes**. No thread is made
for a request, an instance or a VM.

### A job

```
Pending --lane--> Reading --sink--> DecodeWait --worker--> Decoding --handoff--> Uploading --> Settled
   (any stage --> Settled when withdrawn, refused or failed)
```

* **Pending**: accepted and waiting for a lane; no workspace, no file. The oldest admitted job starts first (the order is
  fixed inside the admission transaction).
* **Reading**: the lane's workspace is charged the file's known length and the read goes to the shared pool with the
  texture's 32 MiB allowance. Reads use the ordinary class; the pool's priority for an active module dependency is
  untouched. The read worker's execution slot is free as soon as the sink returned.
* **DecodeWait / Decoding**: the one decode worker preflights the PNG (`preflightPng`), shrinks the nominal charge in one
  transaction, and decodes with `decodeBounded` onto the lane's workspace bank. The input is released and dropped at the
  handoff, the one place the pipeline stops holding it.
* **Uploading**: the decoded level is borrowed by the backend and charged to the lane until the backend retires it.
* **Settled**: the job holds no lane, workspace or buffer. **A job is never answered to the host before it is Settled**:
  the host reads an answer as proof the provider's work is over, so answering while a lane still charges the job's buffers
  would end the request's work early.

The lane is released, and the next pending job started, in the transaction that settles a job. Transitions no event drives
(a read cancelled after its worker took it retires without calling its sink; a delivered texture no lease will own) are
driven by the decode worker's loop and, at close, by the drain: both run the same housekeeping step in STM, so nothing
polls and nothing sleeps, and closing never depends on the worker being alive.

### A texture nobody owns yet

On the backend's usable registration the pipeline holds a `Cell` and answers the request with a resource the host builds,
on the owner's thread, into the lease the admission reserved. Until that build runs the texture belongs to the cell and
afterwards to the lease. Three decisions are made on the cell, each one transaction, so a texture is never both published and
released:

* **offer**: the answer that hands the host a resource first moves the cell from delivered to *offered*, in the same
  transaction that reads whether the host still wants the job. A cell something already claimed (a shutdown) cannot be
  offered, and the request is answered a failure; a job the host withdrew is answered nothing, and the withdrawal released the
  cell;
* **adopt**: the host's build moves an offered cell to adopted. The one other state it can find is claimed, and that only
  after the host's own interest ended (the request was cancelled or its instance ended between the answer and the build),
  which the host discovers atomically with the result and answers by releasing the lease it built, so its charges return when
  the release retires;
* **claim**: the pipeline may claim a cell nobody adopted (a failed upload, a withdrawn job, a request the host answered late
  or refused, a build the host dropped); a **shutdown** (a failed pipeline, a closing scope) may claim only a cell nobody
  *offered*; the lease claims an adopted one; exactly one party ever does, and it calls the backend once.

So a shutdown never starts releasing a texture the host holds for adoption: that texture is adopted, and lives until its lease
ends, or it is dropped (the host returns the credit unused) and the pipeline then releases it. The drain waits for an offered
texture to be adopted or dropped. If the host drops the build it does not tell the provider, so the pipeline learns of it where
the host does return a credit: a credit that transfers, returned unused, means no lease owns the texture, and the pipeline's
housekeeping releases it and returns the charge only when the backend proves it retired.

### Release, cancellation and teardown

* `releaseTexture` revokes the instance's authority for new scenes at once, asks the backend to release once and never
  waits. It answers `done` when this first release itself completes retirement, `retiring` for a first or repeated release
  while retirement is pending, and `already_released` after an earlier release actually retired. A release that raised is
  retained, is fatal, runs no native cleanup again and is the answer to every later release. Another instance's handle is
  refused by the existing handle boundary before any backend action. A scene that already holds the texture keeps it: the
  backend's retirement reading is the evidence, and the slot and bytes stay charged until it says so.
* Cancelling withdraws interest. Unstarted work is withdrawn (pending, or queued in the pool before any file is opened);
  started work is retired safely: a read runs to its end with its sink suppressed, a decode finishes and discards, an
  upload is told to cancel and the backend still owes the end of the work. Consuming a cancellation releases nothing that is
  active. A late texture is released once and never reaches the request.
* Closing admission precedes every drain. The scope withdraws what has not started, tells started work to stop, then waits
  in STM, outside any uninterruptible release, for every read, decode and upload to retire and for every texture it still
  holds to be released and proved retired, or, if it is offered, adopted or dropped; a cancellation delivered meanwhile is remembered and raised after. Only then does
  the group stop the worker, and only then may the pool, the inventory and the backend unwind. **The drain always runs**: admission
  closes in a transaction of its own, whatever the close step raised (a callback that raises, a cancellation delivered inside it)
  is retained as the first exception, the drain then meets every outstanding obligation, and the retained exception is raised
  after it with the drain's own beside it. The drain's own effects are protected the same way: an effect that raises
  (synchronously: latched; by cancellation: kept) never stops the drain or the effects after it, and a synchronous fault of the
  drain's own transaction, an engine defect it cannot get past, is latched and raised rather than retried into a hang. No
  teardown effect swallows a cancellation: the pipeline's own release of a texture raises it to its caller, and a handler that
  re-raises a failure latches it before it runs any effect that might raise. Nothing is reported over while
  the backend still holds a buffer.

### The backend port

What a backend returns is evaluated inside the same guard that catches what it raises (the reading `textureRelease` answers, the
work record `backendUpload` answers), and a cell's recorded state is built and forced before it is stored, so a value that throws
when first looked at is the call failing, once, and never an exception loose in whoever inspects the cell later. `TextureSpec`'s numbers are read with accessors (`specLanes` and the rest); its record fields are not exported, so a client
cannot build or update a specification of its own. `TextureBackend` has one operation, `backendUpload upload sink`, which must not block, and a sink with four calls: a usable
registration (`sinkReady`, carrying a `BackendTexture` whose `textureRelease` is called at most once and answers the
backend's own reading of its retirement, which only reads and which the pipeline guards as the host does: a reading that
throws or answers failed is a failed retirement, recorded once as the pipeline's failure, terminal for that texture, with its
charge left held and the drain going on), a failure, a withdrawal, and the retirement of the borrowed level. A backend
delivers exactly one terminal event and one retirement per accepted upload. Ownership changes only at `SinkTaken`: a
`SinkLate` answer took nothing, and what the backend passed stays its own. The backend outlives the pipeline and every
texture it delivered.

### Failure latch

The pipeline's first failure is latched with later ones appended as evidence, by one transaction that reads the current
value (`latchFailure`), so concurrent failures are all kept; the scope raises it, composed with a close failure and the
worker group's report, and `awaitPipelineFailure` lets the assembly's supervisor see it.

### What proves it

`Test.LuaEngine.Texture.*` (group `test.lua-engine`) run real instances on real supervised owners and leases, a real
temporary content root, inventory and pool behind gates, the real bounded decoder over generated PNGs, and an **injected**
backend that holds every upload and every release until the example says otherwise (it proves ownership transitions, not
uploaded texels or GPU readiness: LFE-17 establishes those). Each bank is filled and refused with nothing left reserved,
the fixed values are checked, the stages and cancellation windows are driven by gates and hooks, never by sleeping, and a
separately compiled client composes the pipeline through public modules. `PipelineHooks` are this package's coordination
points for those examples; production uses `noHooks`. Two rules keep the examples from hanging
or racing: an example acts on a result only after the host's own reply (the script waits for it with `wait_take`; the
pipeline settling a job is not the host having the answer), and every exit of an example or of a nested scope, an assertion
failure included, opens every gate and hook it can hold and lets every backend answer what it owes before anything waits for
the pipeline to drain.

## The module coordinator (LFE-11)

`Hetoimasia.LuaEngine.Modules` (the `modules` sublibrary) is the M1 composition of three mechanisms that each know
nothing of the others: the Lua host's [ordered import chains](../scripting-lua/README.md#ordered-import-chains-the-module-loader)
(one chain at a time per VM, depth first, suspending an importer on a dependency's source), the host's
[atomic request admission](../scripting-lua/README.md#atomic-request-admission) (a request and its result reserved together,
assigned positions, the required-failure latch, the cancellation race), and the content package's
[verified-read pool](../content/README.md#the-verified-read-pool-lfe-10). It adds what is M1's alone: the identity cache's
accounting, the source bank, the join of requests onto jobs and the policy for when each thing happens. Like the data provider
it is a **composable typed endpoint**, not a Lua API: `api.content.module(path [, options])` and the module-bound
`import` of [the facade](#the-authoring-facade-lfe-12) (LFE-12) parse their arguments, resolve the address through the content boundary and call `startModule`,
`moduleArgumentCheck` and the loader's own immediate lookup. It installs nothing in a VM, and no production fake provider, ambient filesystem
loader or game-specific code is in it.

```haskell
withModuleCoordinator ∷ ModuleSpec → (Coordinator → IO a) → IO a          -- reserves its pool slots; closes on exit
coordinatorPlan       ∷ Coordinator → LoaderPlan                           -- the owner's scheduledLoader
coordinatorEndpoint   ∷ Coordinator → RequestEndpoint                      -- the grant's "module" endpoint
attachLoader          ∷ Coordinator → LoaderEndpoint → IO ()               -- once, right after the owner starts
startModule           ∷ Coordinator → ModuleRequest → RequestContext → IO () → IO M1Start
moduleArgumentCheck   ∷ Coordinator → ([Value] → ModuleRequest) → ArgumentCheck
bootModule            ∷ Coordinator → ContentKey → IO (Either BootRefusal BootTicket)
lookupImmediate       ∷ Coordinator → ExportIdentity → STM ImmediateLookup
```

One coordinator belongs to one VM and is made before its owner (the owner's configuration is `scheduledLoader = Just
(coordinatorPlan c)`, `scheduledRequests` granting `coordinatorEndpoint c`, and `vmExportLimits` from
`Hetoimasia.LuaEngine.Behavior.exportLimits` so that the loader and the coordinator hold one set of numbers); the owner's
loader endpoint is given to it with `attachLoader` before any instance is admitted. It lives inside the session's pool scope
and outside its owner: stop the owner first.

### A job, and its waiters

A module is one **job** for the VM whoever names it: a request from an instance, a request from another, an `import` a
running module made, a boot load. Concurrent requests join it, including requests from one instance, and the job reads,
compiles and evaluates the module once, publishing a complete export table or a sticky failure, never a partial export. The
job is the loader's own record (`pending` → `evaluating` → `ready` or `failed`) beside the coordinator's job entry, with **no
second cache**: the coordinator's table holds a job's waiters, source stage and position, never its exports. Another VM has its
own coordinator, jobs, source accounting and exports.

Each external request is a **waiter** of the job, with its own request and result record, its instance attribution and its own
assigned position (a logical request's tick and sequence, fixed when it was admitted; a presentation request settles on
arrival). Every module request is required. **Cancelling a request, or ending its instance, withdraws only that
subscription.** The job goes on: with no waiter left it still reads what it needs, evaluates at the earliest position any
request contributed, and caches its outcome until the VM stops; its dependencies, source work, effects and logical delay are
not cancelled by the departure of whoever first asked.

A success is `{status = "success", value = EXPORTS}` where `EXPORTS` is **precisely the table the VM caches**: the reply
carries a reference to the VM's export slot (`VExportTable`, checked against the VM and the slot where it crosses into
Lua), and the owner pushes the very table under the protected boundary. Functions, cyclic tables and shared upvalues
therefore survive; nothing is serialized, and mutating the table is the trusted shared state of D-7. Only the outer record is a
fresh table, so mutating it changes no settlement. No Lua reference is made for a waiter or a result: the VM's cache reference
is never released before the VM, so there is nothing to release per waiter, and a take spends only its own handle.

### Admission, identities and the cache

`startModule` is `startM1` with one credit when the identity is new: its place among the VM's **permanent** identities
(256 under the fixed profile, counting pending, evaluating, ready and failed entries). The credit is reserved in the same
transaction as the request's records, its place among the instance's 16 and the VM's 64, and its result storage, before the
endpoint is handed anything and before a source is asked for; temporary pressure on any of those banks is the host's `busy`
answer with no handle, read or partial reservation. A request that joins a held identity needs no identity slot (a full cache
still answers lookups and joins) but still needs request capacity.

The permanent decision is taken **where the place is actually taken**, by the identity credit of the admission, in the same
transaction; **the argument check only reads and decides nothing about the cache**. `moduleArgumentCheck` is the host's check of
the arguments and of what is visible about the caller (role, phase, offset, ceiling, request numbers), each an ordinary Lua error
before any work; it neither reserves nor refuses on cache state, so a later check of the same binding that rejects leaves nothing
behind and a place that goes to another thread at any moment is still refused as what it is. The credit (`reserveIdentitySTM`) tells
three things apart:

* **room**: the place is held (counted per identity, and taken whole by the job's creation by whatever path: a request, a boot
  load, a dependency the chain found);
* **full for good**: the VM's permanent entries (pending, evaluating, ready and failed jobs) fill the 256, or the coordinator has
  closed (for **every** request, a join of an identity it holds included, so that nothing is accepted that will never be answered;
  a request the coordinator closes under between its admission and its acceptance is answered with the required failure it is, and
  never left pending). The cache never frees a place, so the credit raises `CreditRefused` and the host refuses the request **before any bank is
  asked**, as an ordinary catchable Lua error naming the module limit (a binding opted in to ordinary refusals, which the LFE-12
  binding is: `pcall` catches it and the invocation can go on). No handle, job, read, hold or failed entry remains, it is not a fault of
  the call, not the instance's failure and not busy, and it wins over a full temporary bank in the same transaction;
* **room held only by other admissions' reservations**, which can still be given back: the credit answers `False`, which is the
  host's `busy` with nothing reserved. A boot load meeting the same state is `BootBusy` (ask again); once the place is a permanent
  job it is `BootCacheFull`.

Temporary banks (the instance's 16 and the VM's 64 request places, the owner's places, result storage, the unsettled boot loads) are
`busy`, data, with nothing reserved. The loader's own ask for a source (`acquireSTM`) is answered with a failure once the coordinator has closed, so a chain never waits
for a source that will not come. That failure is an interest like any other (the loader holds one for every failure it is answered and ends it with `supplierRelease`): it is taken on the identity's job, or on a stopped job made for it within the identity bound (else `SourceNoRoom`), so the release the loader makes is always one the coordinator holds. `startModule` is therefore plain `startM1` (accepted or busy); a permanent refusal is the host's
ordinary error, raised from inside the admission, and the facade's binding (LFE-12) owns only the Lua spelling. `Limits` has a gated
example of each of these, in both orders of a boot load and a request racing for the last place.

What can change decides the answer, on every path: a temporary bank is `busy`; what waiting cannot fix is a refusal (a new identity
at a full cache, `BootCacheFull`, a closed coordinator, `BootClosed`), and a dependency the chain discovers at the limit fails the
accepted chain (`module_limit`).

The coordinator's loader plan (`coordinatorPlan`) **opts in to the host's failed-lookup latch**: its `hookObserved` answers the
attributed failure, so a hook (or a helper a hook called) that `pcall`-imports an identity that has failed still fails its instance
with the module's attributed failure, whatever it did with the error, and nothing fails when no instance's code is running (a task's
lookup latches nothing). A plan that does not opt in keeps the ordinary catchable error. `Positions` proves all three through
`coordinatorPlan` on a real scheduled owner.

A new module at a full cache is **refused before any work**, as an ordinary catchable Lua error naming the module limit, with
no failed entry allocated. A dependency that a running module
discovers at the limit, or past the chain depth or the source limit, fails the **accepted** chain (`module_limit`,
`too_large`), with the dependency given no entry and what the chain completed kept. Taking or cancelling a waiter never frees a
permanent identity: nothing is evicted, restarted or retried. The room reserved for an accepted root counts against the
loader's bound until the loader holds its record (`loaderReserved`), so a dependency cannot take it first. That count is a
fast path, not the arbiter: a dependency's room is decided by the coordinator in the same transaction that would take its
interest (`acquireSTM` answers `SourceNoRoom`), so a request or boot load accepted from another thread after the loader read
`loaderReserved` has the room and the dependency is the one refused, as the ordinary limit it is.

### When a job evaluates

A logical job stands at the **earliest position any admitted request contributed**; it is never made later, so it survives the
cancellation of the request that set it, and an earlier waiter that joins moves a queued job up (`promoteSubmitted`) without
duplicating it. Independent roots start in (tick, sequence) order whatever order they were admitted or their sources arrived in;
a presentation VM starts them in request-admission order. A root at position (T, s) starts only when the scheduler stands just
before tick T with every earlier tick finished (`ticksQuiet`), and **holds tick T** (`ticksHold`) until it has an outcome, so
it finishes before any work of tick T begins and a hook of that tick finds the cache complete. Arriving source never starts a
root, never lets a later root overtake an earlier one that waits for its source, and never exposes an outcome early.

A dependency that is also requested for a later position is evaluated **once, within the importing chain, at the importer's
position**; its own request is answered with the existing outcome at its own position (the host holds a logical answer until
then, and settles a presentation request when the outcome is published). A dependency's failure is the importer's at the
importer's position and never the dependency's own request's before its time. Boot loads use the same identity, chain and
reads with no waiter, no result position and no tick.

### The source stage

Source is read by the pool's two workers, which overlap, into a **per-VM bank of 16 MiB uncompiled source with 1 MiB reserved for
the active chain's next source**. A read is charged its inventoried length before it starts. Unrelated prefetch may use only
the bank less the reserve, so ready prefetch can never starve the dependency the chain waits for; the active chain's next source
may use the reserve. A source over the module limit, or a path the inventory does not hold, is an accepted-load failure
(`too_large`, `not_found`) with no read and no byte reserved. A read that does not fit yet waits among the admitted jobs,
bounded by the identity cache, and neither takes the reserve nor turns acceptance into `busy`.

The coordinator holds `specSlots` of the pool's slots for its life (one of them for the active chain alone), so it never waits for
capacity that only finishing the chain could release, and a worker never waits for anything: its sink stores and hands over the
verified buffer, returns the slot and starts the next read that fits, in one transaction. A job is read at the pool's
`OrdinaryRead` class until the chain waits for it; then a queued read is withdrawn and queued again as `DependencyProgress`,
keeping its slot and its charge, and a read a worker holds is left to finish: one read, one charge, however a dependency is
promoted or reused. Released source is returned to the bank the moment the loader has compiled it (`supplierRelease`), before
the parent waits for its next dependency; the loader's copy of the bytes is the one allocation the charge stands for.

### Failures

A module's own failure is data. It fails the requests that wait for it, each at its own eligible settlement and whether or not
its script reads it, with the code of the **cause** (`not_found`, `content_changed`, `io_error`, `too_large`, `module_error`,
`module_cycle`, `module_limit`), a message bounded at 2 KiB, the root and path of the content that failed (the dependency, when
the cause is one) and the chain it was reached through. A failure with **nobody waiting** is one attributed, bounded diagnostic
through the logger the coordinator was given (component `luaengine.modules`), at most once per failed identity and not for a
dependency whose importer in the same advance carries the report; it fails no instance. A defect of the engine, the pool, a
worker, a completion or the diagnostic sink is not a module failure: the first is recorded where it happened and raised on the
owner at its next boundary, fatal whatever the waiter count.

### Stop and lifetime

An owner's exit stops the loader first (every suspended module closed on the owner, every source interest withdrawn) and then
closes the coordinator, which is idempotent and never waits: admission closes; every pending or evaluating job reads `Stopped`;
boot loads are told; reads no worker has taken are withdrawn without a file being opened (`withdrawQueued`) and the bytes that
arrived for nobody are dropped; the slots no read holds go back to the pool. A read a worker holds finishes, and its sink drops
the buffer, returns its charge and its slot; `awaitDrained` is the proof that all of it has happened. The pool's own scope drains
every started read before the root and the inventory it borrows are released, so a late sink touches only the coordinator's own
state, which refuses to republish, resurrect a waiter or reach the closed VM.

### State, owners and lifetimes

| State | Owner and thread | Created / tracked | Bound | Cancellation windows | Terminal / released when | Proved by |
| --- | --- | --- | --- | --- | --- | --- |
| identity reservation (`csPromised`) | the coordinator; the admitting hook's thread | the admission's identity credit (`reserveIdentitySTM`); the argument check reserves nothing | identities less held | the admission taken back before the endpoint is handed anything | consumed whole by the job's creation, whichever path makes the job (a request, a boot load, a dependency the chain found), so an identity is never counted twice; or its own count returned by `CreditUnused` exactly once (reservations of one identity are counted, so one admission taken back never removes another's) | `Limits` (room promised to a boot load; promise turned into the boot load's job; dependency refused after an interleaved acceptance; both orders of a boot load and a request for the last place), `Stages` |
| job entry (`csJobs`) | the coordinator; the owner's thread, with sinks and withdrawals in STM | `acceptRequest`, a boot load, or the loader asking for a dependency's source | 256 per VM, permanent | none: a job is never withdrawn | at the VM's end (`Stopped` if unfinished) | `Basics`, `Positions`, `Lifecycle` |
| waiter | the job; created by the endpoint's submit | `acceptRequest`, atomically with the join | the request banks (16 per instance, 64 per VM) | cancel, instance end and publication, each once | replied or detached, whichever comes first; the host releases the request place after take and retirement | `Positions`, `Lifecycle` |
| evaluation position (`jobDue`) | the job | the earliest contributed position | one per job | never moves later; promotion races cancellation | the job's outcome | `Positions`, `Promotion` |
| tick hold (`lsGate`) | the hosted loader, per owner | the earliest placed root's tick, recomputed in the transaction that changes it | one hold | promotion moves it earlier; the owner's exit gives it back | the root's outcome | the host's `Loading` examples, `Promotion` |
| source reservation (`csCharges`) | the coordinator; reserved by the owner's thread or a sink | the read's start | 16 MiB, 1 MiB reserved | the read's sink, the loader's release and the VM's close | `supplierRelease`, or the sink of a read nobody wants | `Bank`, `Lifecycle` |
| pool slot (`csSlotsFree`, `csPoolHeld`) | the coordinator, holding the pool's reservations | `withModuleCoordinator` | `specSlots`, one for the active chain | a read withdrawn while queued | the read's sink, or the close | `Bank`, `Stages` |
| read ticket | the job; the pool owns the read | `startRead`, `needJob` | one per job | `withdrawQueued` before issuance only | the sink, or withdrawal | `Bank`, `Lifecycle` |
| export reference | the VM's cache | the loader, in one protected call | one per ready identity | none | the VM's end, never earlier | the host's `ExportTable` examples |

### What proves it

`Test.LuaEngine.Modules.*` (group `test.lua-engine`) run real VMs on real supervised scheduled owners over a real temporary
content root, inventory and pool, with the production reader behind gates and nothing slept: two instances joining one pending
identity and receiving the very table after one read and one evaluation, a cached request answered without a read, fresh
envelopes, functions, cycles and shared upvalues, another VM evaluating independently, and the three outcomes of a lookup
(`Basics`); sources arriving in reverse order, hooks and stop served while the loader waits, an independent VM unaffected,
a later ready root unable to overtake, and nothing started or exposed early (`Order`); A due at 10 importing B requested for 12,
for success and failure and for a presentation owner, longer depth-first chains, a shared base evaluated once, a queued
dependency reused, and a cycle (`Promotion`); a position kept when its waiter cancels, roots ordered by tick and sequence with
an earlier request moving a queued job up, a job finishing and caching with no waiter, one bounded diagnostic, required
failures at each request's own position, and boot loads (`Positions`); the reserve, the slots and the pool's workers, with the
most ever held read back (`Bank`); the full cache, request pressure that is busy atomically, and the limits an accepted load
meets (`Limits`); stop, peers, defects of the engine and duplicate or failing completions (`Lifecycle`); a source arriving before
the loader's record, repeated request and cancel, the fixed profile's numbers and the specifications that are refused
(`Stages`); and a separately compiled client composing the root, the pool and the coordinator through public modules
(`Client`). The host's own examples prove the mechanisms the coordinator relies on, in `lua-host-tests` and `lua-runtime-tests`
(see [the loader chapter](../scripting-lua/README.md#placed-roots-lfe-11)).

## The scene schema (LFE-19)

`Hetoimasia.LuaEngine.Scene` (the `scene` sublibrary) turns the table a script hands over into **bounded, immutable CPU data** for the
publication that follows (LFE-20), or refuses it whole. It starts no window, GPU or native action, publishes nothing, acquires no hold
on any texture and installs nothing in a VM. Its dependencies are the profile, the texture sublibrary's authority check, the host's
public modules and the pure renderer packages; the oracle is a test dependency only.

### What a script writes

```lua
{
  clear = {r = 0, g = 0, b = 0},
  sprites = {
    {texture = texture, x = 32, y = 32, width = 256, height = 256}
  }
}
```

Exactly those fields and no others at every level; `sprites` is a dense list (empty allowed) and nothing has a default. A colour channel
is a Lua integer, or a float that is exactly a whole number, from 0 to 255 (sRGB); a coordinate is a finite number from -1,000,000 to
1,000,000; a width or height is finite, greater than zero and at most 1,000,000; `texture` is the calling instance's own texture
handle. A table used in several places is copied at each of them and each sprite keeps its place. Nothing is coerced, clamped,
rounded, snapped or skipped: a numeric string, a boolean, a fractional channel, NaN, an infinity or an out-of-range value is refused.

### How it is read, and the limits

The host reads the table raw under the scene's own limits (`sceneValueLimits`, applied with the binding's
`withArgumentLimits`): **2 MiB** encoded, depth **4**, and the elements of a maximal scene (6 + 6 per sprite, so 4,096 sprites is 24,582),
all inside the common 16 MiB, depth 8 and 65,536. The reader applies the smaller of the owner's and the binding's limit while it
copies and stops at the first one it reaches, so a huge or sparse table is refused at a limit and never copied first and checked after;
a metatable (an empty or protected one included), a cycle, a hole, a non-index key, a wrong type, a nil required value, a missing or
extra field and a handle that is not a live texture handle of this VM are refused by the host's value rules, with no metamethod run. By
the host's accounting a scene of `n` sprites is exactly `82 + 116 n` bytes. A profile can shrink any of these (`validateProfile`), which
is how a limit the fixed schema cannot reach before another one refuses it is exercised. `prepareScene` also checks the sprite count itself,
walking at most one past the limit, for a client that builds the value without the host.

### Colour and geometry

A channel becomes linear light by the sRGB transfer function (byte 128 is about 0.2159, not 0.5; 0 and 255 are exactly 0 and 1) with an
alpha of 1. A rectangle is converted to the renderer's 32-bit floats and checked as the quad the renderer places (the unit square through
the sprite's transform, in the UI's logical space): the origin and the origin plus the width, the height and both must be finite, a
positive extent must not be zero as a 32-bit float, and the far edge of either axis must not round back onto the origin. A tiny
rectangle at a large origin is therefore refused, not made to disappear. Fractions and negative or offscreen positions are kept; how
the renderer later maps the logical space to a target is its own contract and never makes a prepared scene invalid.

### Texture authority

Each distinct texture is borrowed once through the calling instance's own lease (`withTextureOr`: it decides and borrows in one step on
the calling thread) and its complete backend identity and dimensions are copied. A lease that has ended or is retiring, another
instance's (a peer in the same VM included), or of another type is a refusal, not an exception; a defect or a cancellation inside the
borrow is raised as itself. A capability that is not an authentic texture capability of this VM never reaches this check: the host's
boundary refuses it.

**Success is a check of current authority, not a grant.** A `PreparedScene` holds no hold on any texture and cannot extend an
instance's authority. The instance can release a texture, or end, the next moment. The publication (LFE-20) must, in the step that
publishes, revalidate and hold each of `textureUses` through `preparedOwner`'s leases, and publish atomically against release and end;
`useView` is the identity it was checked against, and it never resolves a stale one to a newer texture.

### Refusal

`scenePublishBinding` (and `sceneArgumentCheck` for a binding of one's own) refuses a candidate as **an ordinary Lua error** before the
action: `namespace.name: scene.sprites[3].width: an extent is greater than zero`, at most 160 bytes of fixed words and numbers and never
anything of the authored value. `pcall` catches it and the next valid candidate can be prepared; nothing is latched. Uncaught, it is the
script's own error under the host's existing classification of an ordinary Lua error: the calling instance fails with that bounded
message. The check keeps nothing (a binding's closure is shared by owners), so the action prepares the same copied value again on the same
thread, and a refusal there is a `SceneDefect`, the engine's own failure and fatal. The sink is called only on complete success; a sink
that fails ends the owner, and a later success never clears it.

### The renderer's frame

`sceneCandidate resolve metrics content` builds the existing pure snapshot: one window pass cleared to the opaque colour, one
full-window view of the supplied target metrics (camera at the origin, zoom 1; UI scale 1, pixel snap off, nearest filter, brightness
100%, written out), and one UI layer of the sprites in order. Each sprite places the unit square at its origin with its width and height,
shows the whole image with the neutral tint, the default sampler and material, no clip, frame table, parameter, translucent override or
additive flag. Every sprite has depth key 0, so the renderer's order (ascending depth key, then submission) is the script's list order,
later over earlier through its premultiplied blend. The caller supplies how a backend identity becomes the renderer's handle (it is the
backend's) and the target's metrics; a resize is a new candidate from the same content, a zero framebuffer extent a valid empty viewport,
and nothing in the content knows the window. `initialContent` is the opaque black empty scene a window shows before its first publication.

### Owners, threads and lifetime

| What | Owner | Thread | Lifetime and cleanup |
| --- | --- | --- | --- |
| the copied argument | the host's call | the VM's, inside the binding call | bounded by the scene limits as it is read; dropped when the call returns or raises |
| the draft (accumulating sprites, textures already borrowed) | `prepareScene` | the calling thread | local to the call; dropped on success, refusal or exception; no history, queue or cache |
| a texture's borrow | the instance's lease | the calling thread | for the copy of its identity and dimensions only; nothing is retained |
| the `PreparedScene` | its receiver (the sink) | any | immutable; holds the owner's `Leases`, no hold; ends when dropped |

### What proves it

`Test.LuaEngine.Scene.*` (group `test.lua-engine`) run a real instance that owns a real texture on a real supervised owner, the real
pipeline and decoder with an injected backend, and a controlled sink: the exact example, boundary values and shared tables (`Schema`),
every refusal with the sink and the previous scene untouched and no metamethod run (`Schema`, `Numbers`), the limits at the limit and one
past under the fixed and smaller profiles (`Limits`), texture authority including a peer in the same VM, release, instance end and the
later consumer (`Authority`), pcall, uncaught, copying and a failing sink (`Failure`), the renderer's validation, plan and oracle (`Render`)
and a separately compiled client (`Client`). The host's own examples prove the per-binding limit and the stack and registry balance in
`Test.Lua.Boundary.ArgumentLimits` and the non-throwing lease borrow in `Test.LuaRuntime.Instance.Lease.*`. Oracle evidence proves CPU
semantics, not a displayed pixel.

## The authoring facade (LFE-12)

`Hetoimasia.LuaEngine.Facade` (the `facade` sublibrary) is the M1 Lua authoring surface of one VM: the table an instance's
hooks are handed as `api`, the lexical-root `import`, the role clocks and cooperative waits, and bounded `print` and `warn`,
bound over the [request adapter](#the-m1-request-adapter), the [data provider](#the-raw-data-provider-lfe-10) and the
[module coordinator](#the-module-coordinator-lfe-11) that already exist. It is the first slice that installs anything in a
VM. It adds no service, no provider, no cache, no timer and no queue; it checks what a script asked, calls the service, and
shapes the answer. It imports no texture, scene, graphics, console or game module.

### What the facade gives a script

`init(self, api)`, `update(self, dt_seconds)` and `shutdown(self, reason)` are called as before. `api` is the table `self.api`
holds (the same table, also when the behavior has no `init`): fresh for each instance, ordinary Lua, and holding

| Field | Value |
| --- | --- |
| `api.role`, `api.content_id`, `api.instance_id` | copied strings: `"gameplay"` or `"presentation"`; the content identifier the instance requests under by default; an opaque identity of at most 128 UTF-8 bytes, unique in the session and never reused. It is not a thread, a pointer or an authority |
| `api.content.module(path [, options])` | `options` is `nil`, absent or a plain table with only `root` and `tick_offset` |
| `api.content.data(path [, options])` | `options` is `nil`, absent or a plain table with only `root`, `tick_offset` and `optional` |
| `api.request.ready(r)`, `take(r)`, `wait(r)`, `cancel(r)` | the [common operations](#what-a-script-sees) of the request adapter, for module and data requests alike |
| `api.time.tick()`, `tick_seconds()`, `seconds()`, `wait_ticks(n)`, `wait_seconds(seconds)`, `yield()` | the role clocks and the waits, below |

`print`, `warn` and `import(path [, root_id])` are globals. Nothing else is added: no logger, no file handle, no clock but
these, no session control (`api.session`, `quit` and the unavailable-state `state` are LFE-26).

**Calls and validation.** Every call is a dot call with exactly its declared arguments, counted as Lua counts them (an
explicit `nil` is an argument; `api.content.module(path, nil)` is a call with its options omitted, `api.time.tick(nil)` has
an extra argument). A colon call, a missing or extra argument, a value of the wrong type or subtype (`1.0` is not `1`, a
numeric string is not a number), a table with a missing, unknown or non-text key, with a hole, a cycle or any metatable, a
foreign, spent or wrong-kind handle, the wrong role or phase and a permanent numeric or path limit are all **ordinary Lua
errors**: raised before any provider is asked, any file is looked at, any place is reserved or anything is suspended; `pcall`
catches them, the invocation goes on, and a required failure latched independently is not cleared by catching one. Only `nil`
or absence omits a field: `false` is a value. No authored metamethod runs while a table is read, and no module's export
graph is walked. The error's text begins with the name of the engine binding that refused
(`hetoimasia_engine.content_module: ...`): the reason is the contract and the name is diagnostic. A request that a
temporary bank cannot hold is not an error but data: the call returns exactly `request, nil` when accepted and `nil,
{code = "busy", message = TEXT}` when not; nothing is retried by the engine.

| Call | Module top level | `init` | update | `shutdown` |
| --- | --- | --- | --- | --- |
| `content.module`, `content.data` | refused | yes | yes | refused |
| `request.ready`, `take`, `cancel` | refused | yes | yes | yes |
| `request.wait`, `time.yield` | refused | refused | yes | refused |
| `time.tick`, `tick_seconds` | refused | gameplay | gameplay | gameplay |
| `time.seconds` | refused | presentation | presentation | presentation |
| `time.wait_ticks` | refused | refused | gameplay | refused |
| `time.wait_seconds` | refused | refused | presentation | refused |

"Update" is any serving segment, a callback included. A refused module top level means every call, through a facade a hook
left in a shared export as well. A content request is also refused, as an ordinary error and never as `busy`, when the
session's admission is stopping or closed: busy is a capacity answer, and a stopping session will have no more room later.

### Content roots

Two calls name content, and their default roots are different on purpose.

* `import(path [, root_id])` belongs to a **module**. Its default root is the root of the module whose code makes the call,
  captured when that module was evaluated: a shared helper keeps it whichever instance's hook runs it. A path is from the root,
  never from the source directory or the caller. `import` is installed by the Lua host's loader before any authored code and
  resolved by `lexicalResolver` (made for the coordinator with `inventoryResolver`); the loader's rules apply
  ([import outside module evaluation](../scripting-lua/README.md#import-outside-module-evaluation)). Called in a hook, a ready
  identity returns its cached table; an identity that was never asked for or has not finished raises the string
  `import: module_not_ready: ROOT:PATH` (so `pcall` code tells it from an argument error, which is `import: REASON`), starts no
  work, allocates no identity, joins no job and never waits; a known failed identity raises an ordinary error and latches the
  required failure of the running instance, caught or not. An invalid `import` while a module is evaluated is an ordinary
  error: uncaught, it fails that required load as any error in a module does; caught, it fails nothing.
* `content.module(path [, options])` and `content.data(path [, options])` belong to an **instance**. Their default root is
  the facade's `content_id`.

An explicit root overrides either default. A root is an identifier of 1 to 64 ASCII characters of `[a-z][a-z0-9_-]*`; an
identifier the session does not enable (in M1 only the game's root is enabled) and an enabled one it holds no content for are
both argument errors, decided without looking at a file. A path follows the content layer's identity policy and nothing else:
valid UTF-8, each segment in NFC, exact case, literal `/` separators, no empty, leading or trailing separator, no `.` or `..`
segment, no backslash, colon or control character, no absolute, URL or expansion form, at most 32 segments, 1,024 bytes and
255 bytes a segment on the supplied and the normalized forms. There is no extension fallback, no search of another place and
no native case lookup.

### Requests and their records

`content.module` takes `tick_offset` (a Lua integer from 1 to 2^63 - 1, default 1) from a gameplay instance and refuses the
field from a presentation instance, even as 1; `content.data` also takes `optional` (a boolean, default `false`). A gameplay
request is placed at the tick the instance is at (0 in `init`) plus the offset, checked against the numeric ceiling before
admission. The records are the request adapter's, unchanged: `take` answers `{status = "pending"}`, `{status = "success", value =
VALUE}`, `{status = "failure", error = {code, message, root, path}}` or `{status = "cancelled"}`, with only the fields of the
variant, a fresh table each time. A module's `VALUE` is the very table the VM caches (functions, cycles and all), so the
envelope is a copy and the value is shared state; a data request's is the file's bytes as a Lua string. Failure codes are the
services': `not_found`, `content_changed`, `io_error`, `too_large`, `module_error`, `module_cycle`, `module_limit`.
Because a binding declares one result shape, the operations exist for each kind of request handle (`module_request`,
`data_request`) and the facade's closures pick the right one by the handle they were returned for; any other value is refused by
the host's handle check like any wrong-kind handle.

### Clocks and waits

* **Gameplay** reads the logical tick: `tick()` is a Lua integer, 0 in a root's `init`, read live from the owner's scheduler
  through the injected endpoint, so only a begun tick advances it and no load or native delay can; `tick_seconds()` is the
  fixed tick duration as numeric seconds. A tick no Lua integer holds is never wrapped or clamped: it is an engine failure,
  reported through the injected failure boundary and raised from the call.
* **Presentation** reads `seconds()`, the elapsed time since an origin set when the VM begins its first instance's
  initialization (so that instance's first segment reads `0.0`; a second instance shares the origin). It is **sampled**: the
  facade is told at every hook entry and every resumed segment (`instanceOnSegment`, wired by `facadeInstanceConfig`), and
  every read inside the segment answers that sample however the clock moves meanwhile. A finite `init` or `shutdown` is sampled
  too. A sample is a finite approximation, never an authority for a deadline, and sampling does not redefine the cadence's
  origin or `dt`.
* `wait_ticks(n)` takes a Lua integer from 1 whose target tick is itself a Lua integer; `wait_seconds(seconds)` takes an
  integer or a float that is finite and positive; a string, `NaN`, an infinity, zero and a negative number are errors. The
  exact value the number represents times 1,000,000,000, rounded **upward** (a tiny positive value is one nanosecond, never
  zero; `0.1` is `100000001` ns), must be a positive 64-bit count, and the injected clock now plus that count must be
  representable: otherwise the call is an ordinary error before anything is suspended. The count reaches the scheduler as the
  two 32-bit halves of the number (a wait through 2^64 - 1 ns is accepted though a Lua integer stops at 2^63 - 1). The deadline
  is placed when the wait is requested, not from the segment's sample; an early wake resumes nothing and resumption may be late;
  the update's `dt` is fixed when it begins and is unchanged by its own waits, and a resumed update starts no second one.
  The check reads the clock once and the scheduler places the wait against a later reading: if the clock moved on so that the
  deadline is no longer representable, the scheduler refuses the wait, and that is **the engine's fact and not the script's**:
  the application's `scheduledRefusedWait` (set to `facadeRefusedWait facade`), called the moment the scheduler applies the refused
  segment's report and before anything else runs (before the coroutine's own `__close` handlers, before the boundary, before an
  accounting wait can be answered, before another segment), reports it through the injected failure boundary and
  raises it, ending the owner as a tick no Lua integer holds does, where the generic scheduler would have isolated an instance for a
  refusal no script caused. If the report of an engine failure itself raises, the engine failure stays primary and what the
  report raised is retained beside it (the primary and its cleanup evidence are composed, neither is dropped).
* `yield()` gives control back; all three waits are refused outside an update before anything is suspended.

### Output

`print` converts its arguments with `tostring`, joins them with a tab and writes the line to the stdout sink with no prefix.
`warn` does the same to the stderr sink, each line marked by an engine-made prefix that names the role, the content and the
instance whose hook is running (`lua warning role=ROLE content=CONTENT instance=ID: `), or, while a module is evaluated, the
role and the module (`lua warning role=ROLE module=ROOT:PATH: `): a shared helper called in a hook is attributed to the
executing instance, and a module evaluation invents no instance. The context comes from the engine and never from a field a
script can write. `@on` and `@off` are plain text. One complete call writes at most the profile's `PrintWarnBytes` (4,096)
bytes of UTF-8, prefixes, escapes, line ends and the visible truncation marker included: the Lua side cuts the text before it
crosses, and the Haskell side decodes it (invalid UTF-8 replaced), splits it at its line breaks, escapes the control
characters but a tab, prefixes each line and bounds the whole again (`Hetoimasia.Scripting.Lua.Output`, the runner's own
mechanism, whose output is unchanged). A `tostring` that raises is an ordinary error with nothing written.

**Every line of a warning begins with the whole of its prefix, whatever is cut.** When a `warn` is longer than its bound, the
lines that fit are kept with room beside them for a prefixed marker; the first line that does not fit is cut at a character,
after its prefix, and ends in the marker (`...`); nothing follows it. So the marker is never a line of its own and never follows
a half prefix: a call of 4,027 characters and a second line writes one prefixed line ending in `...`, and no `next`. (`print`
has no prefix and is cut as the runner's own output is, where the marker may stand alone on a line.) A bound too small to hold
one prefix, the marker and a line end, which no validated profile gives, is the first bytes of the prefix and the marker: the
bound wins over the format.

The sinks are the session's `Output` (`withOutput`, one for every VM): a whole call is written under one lock and flushed before
the lock is released, so calls never interleave, a call is in order with the same owner's others and cross-VM order is the order
of execution; there is no queue, drop, retry or rate limit, and a slow sink blocks its writers. A sink that raises is a failure of
the host: the call raises it, so it ends the owner whatever Lua did with the stand-in error, and no later call is written or
retried through a sink that has failed; nothing is reported through it. The failure is checked and recorded **under the lock**: a
writer that was waiting for the lock behind the one whose sink failed finds the failure when it holds the lock and touches
neither sink, so a failed output has exactly one failed write and none after it. The failure is kept whole, with the context
it was raised with, inside the `OutputFailure` that reports it. Returning does not promise the bytes are durable. A call that
the owner's cancellation interrupts inside a sink may have written only some of its lines (the write is not masked, so that a
stuck sink cannot make its writer uninterruptible); the interruption is not a sink failure and is not remembered as one.
Authored output bypasses log filtering and cannot suppress an engine failure's diagnostics.

`withOutput` is a `withResourceLabelled` scope ([resource contract](../../docs/resources.md)): the body's failure is primary and
keeps every cleanup failure the owners and the coordinator inside it retained, the close and drain is its release (uninterruptible,
as every release is), and what the release raises would be retained beside the body's failure and not instead of it. Nothing in
the facade catches an exception and throws it again plainly; a failure is rethrown with the context it was caught with.

### What an assembly does

```haskell
withOutput out err $ \output →                -- the sinks' scope: outermost
  withModuleCoordinator spec{specResolve = inventoryResolver inventory [gameRoot], specPhase = Just phase} $ \coordinator → do
    facade ← newFacade FacadeSpec{..}         -- role, request policy, coordinator, data service, output, endpoints, phase, roots
    config ← installFacade facade [] [] (vmProfileConfig LibraryProfileM1)
    -- grant (facadeRequestEndpoints facade); scheduledInstances = Just (facadeInstanceConfig facade ...);
    -- scheduledRefusedWait = facadeRefusedWait facade
    declared ← declareInstance facade gameRoot -- then admit (behaviorRequest ... (declaredFacade declared) ...)
```

**The bounds the facade formats with are checked when it is made** (`newFacade` answers `LimitBelowFormatting NAME GIVEN LEAST` and
makes nothing over a profile below the least), each against what the facade's own format needs:

| Limit | Least | Why | Boundary examples (`Facade.Limits`) |
| --- | --- | --- | --- |
| `InstanceIdBytes` | 6 (`minimumInstanceIdBytes`: `inst-1`) | the first identity the session issues; a later identity that does not fit is refused when it is declared (`IdTooLong`), never written | 5 refused; 6 makes a facade whose first instance is `inst-1`, and the tenth identity is refused |
| `PrintWarnBytes` | `minimumPrintWarnBytes idBytes`: the longest warning prefix, `...` and a line end (242 + 4 for `InstanceIdBytes` 128; 167 + 4 for 6) | every line of a cut warning keeps the whole prefix and the marker ends the last of them; the longest prefix is an instance's (`lua warning role=presentation content=` + 64 + ` instance=` + `InstanceIdBytes`) or a module's with its label (the host keeps at most 128 bytes of it) | one below refused; the least keeps the format end to end, from a hook and from a module at the longest label |
| `CopiedValueBytes` | `minimumCopiedValueBytes idBytes printBytes`: the largest of everything the facade makes cross, each with the host's header: one `print`/`warn` text (`PrintWarnBytes + 5`), an identity (`InstanceIdBytes + 5`), and the builder's context record (`minimumContextBytes`: 142 for an identity bound of 6, 264 for 128) | a text or record crosses as its payload and a header; the longest `out`/`err` call is the output bound and five bytes | one below refused; the least cuts and writes the longest `print` and `warn`, builds an instance's `api`, and turns a path or `import` too large to cross into an ordinary, catchable error |
| `CopiedValueElements`, `CopiedValueDepth` | 4 and 1 | the same record | not separately checked: the profile's scene relation already keeps the elements at 12 or more and every limit positive, so neither can be below |
| `InstancesPerVm`, `LuaIntegerMaximum`, `MessageBytes` | 1 | positive suffices: a one-instance VM, a tick ceiling of 1 and the message bound the facade does not format with | the profile's own positivity check |

`installFacade` registers the hidden namespace and the two request handle types, adds the initial chunk that rebinds `print`
and `warn` and defines the builder, adds the builder's export module and sets the export and copied-value ceilings from the
profile. The facade's own module takes one place beyond the profile's 256 authored identities in the loader (the coordinator,
not the loader, enforces the 256). The scopes nest as the owners need them: the **owner stops first**, so a `shutdown` that
prints still finds its sink, then the coordinator and pool, then the output. `forgetInstance` removes an instance's record and
sample once its settlement is observed.

### State, owners and lifetimes

| State | Owner and thread | Written by | Read by | Bound | Released when |
| --- | --- | --- | --- | --- | --- |
| `Registry` (declared and bound instances) | the facade; STM | `declareInstance` and `forgetInstance` (the application), the builder's one `bind` call (the owner's thread) | every binding a hook calls | `InstancesPerVm` (2) records | `forgetInstance`, or the facade's scope |
| presentation origin and per-instance samples | the facade; STM | `instanceOnSegment` on the owner's thread | `seconds()` | one origin; one sample per declared instance | `forgetInstance`; the origin with the facade |
| `Output` (sinks' lock, in-flight count, first failure) | `withOutput`'s scope | every authored call, on its owner's thread | the scope's drain | the sinks' own | the scope closes the output to new calls and waits for calls in a sink to return |
| the hidden namespace, the builder and the facade closures | the VM; Lua | the initial chunk, once; the builder, once per instance | the hooks | one builder per VM | the builder takes itself out of the globals when taken; closures and their weak request-kind table are collected with the facade table |
| the module being evaluated (`ModulePhase`) | the Lua host's loader | the loader, around every segment of a module's code | `warn`'s prefix, the facade's module-phase refusals | one | put back as it was however the segment ends |

### What proves it

`Test.LuaEngine.Facade.*` (group `test.lua-engine`) run real instances on real supervised scheduled owners over a real content
root, inventory and read pool, the real data service and module coordinator, an injected clock and fake timer and recording sinks
(no example sleeps): the accepted P-72 example with a forced `busy`, an explicit retry from a later update and one load delivered
at its fixed offset (`Authoring`); every schema of every call table-driven, in every role and phase, with nil against false,
`1` against `1.0`, numeric strings, metatables, consumed and wrong-kind handles and a stopping session (`Validation`); two
instances sharing a VM, a facade or handle passed between them, overwritten metadata and hooks, and a facade kept by a module
(`Ownership`); the lexical resolver over supplied contexts, a shared helper, `module_not_ready` with no work, a latched failed
import, NFC and case, no extension fallback and refusals before any provider (`Imports`); every record and its omissions, a wait
that consumes nothing, cancellation, the shared table in a fresh envelope, bytes kept as they are, busy and stopping
(`Requests`); the clocks, held loads and the shared origin (`Clocks`); wait endpoints, conversions, deadlines, early and late
wakes and exhaustion (`Waits`); print, warn, context, escaping and the exact bound (`Output`); serialization, flushing, slow and
failing sinks, shutdown output and a facade made in part (`Sinks`); and a separately compiled client (`Client`). The Lua host's
own examples prove what it added for this: the caller's instance, the segment notification, the named module phase, the
two-word elapsed wait and the shared bounded output.

## The session coordinator (LFE-13)

`Hetoimasia.LuaEngine.Session` (the `session` sublibrary) composes one or two roles' VMs into one **session**: how the
roles start, advance, fail and stop together. It is the CPU Lua-engine layer's coordinator: it builds each selected role's
VM from the pieces above (a [module coordinator](#the-module-coordinator-lfe-11), the [data service](#the-raw-data-provider-lfe-10),
the [facade](#the-authoring-facade-lfe-12) and a supervised scheduled owner that hosts instances), evaluates the selected entries,
admits the roots, runs the roots' `init`s and the clocks over the Lua host's own scheduler, applies the failure policy and drains
through actual retirement. It adds no scheduling, no world, no progress channel and no event API; it installs no signal handler,
exits no process and writes nothing to a standard stream. The Lua status, quit and unavailable-state bindings are LFE-26's, which
consume the endpoints below; the launcher that opens the content root, makes the checkpoint and maps an outcome to an exit status is LFE-22's.

```haskell
runSession           ∷ SessionSpec → (Session → IO ()) → IO SessionOutcome   -- on the thread that owns the supervision control
sessionStatus        ∷ Session → STM SessionStatus                            -- nonblocking, coherent, bounded
sessionOutcomeNow    ∷ Session → STM SessionOutcome                           -- failure over interruption over success, as it stands
requestStop          ∷ Session → StopKind → IO ()                             -- StopQuit | StopInterrupt: no slot, idempotent
latchTerminalFailure ∷ Session → RoleFailure → IO Bool                        -- the unavailable-state guard's latch; True the first time
```

`runSession` makes the session's state first and hands the `Session` to the callback before any VM exists, so a stop, a status read
or a terminal-failure latch can be wired to whoever needs them without waiting on a VM; the callback must not block. It then runs
the session on the calling thread, which must be the thread that owns the supervision control, because its waits are supervised
ones, and returns only once **every role has actually retired**. The handle's endpoints are safe from any thread, so a native
event loop never waits for an `init` or a tick: the control and progress seam is the handle, not the driver.

### What a composition injects

`SessionSpec` holds, and the coordinator passes on narrowed, the services it is given; it reaches no global, no environment record and no registry.

| Field | What it is |
| --- | --- |
| `sxProfile`, `sxCheckpoint` | the validated profile every bound is read from, and the boot checkpoint: the manifest and the entry each selected role loads, validated against the content scan before any Lua |
| `sxInventory`, `sxPool` | the anchored content and the session's pool of verified reads, which outlives every owner |
| `sxLogger`, `sxOutput` | the coordinator's diagnostics (lifecycle at info, a failure once at error, component `luaengine.session`), and the authored output, the caller's scope |
| `sxClock`, `sxTimer` | the monotonic clock the owners, the facades and the pacing share, and what sleeps (the threaded runtime's timer manager in production, a hand-fired one in a test) |
| `sxRuntime`, `sxControl` | the Lua runtime the owners start on, and the supervision control of the driving thread |
| `sxHarness` | `noHarness` for a real composition; see [the harness](#the-harness) |

The content identifier an instance requests under, and the one root the facades enable, is the inventory's root. The roles are the
checkpoint's: gameplay (with the manifest's exact tick), presentation, or both, whatever order the manifest listed them in.

### What a session does, in order

1. **Preflight, before any Lua.** A harness asking for a second instance of a role the session lacks, and a first logical deadline the clock cannot count (the reading plus one tick), are refused here as an engine failure.
2. **Build each role's VM**, gameplay first, in nested scopes that release in the opposite order and stop each owner (and wait for its worker to have ended) before the coordinator, pool and output it borrows.
3. **Evaluate each selected entry and its imports** in its own VM (a common entry separately in each), running no root. A module that does not evaluate is a boot failure attributed to the module, with no instance and with the traceback the module system recorded. Every entry is asked before any is waited for, and each outcome is applied the moment it arrives, whichever entry that is: a failure is latched and the stop requested while the other entry is still being read.
4. **Admit the roots.** Each admission is *intended* in the session's state, *issued* to the owner and *tracked*; the owner constructs and validates the behavior (the export, hook, captured schema and cadence) and, at the point its `init` would begin, the host asks the session whether to **hold** the instance there (`instanceHoldInit`): the session records the instance as validated and answers yes, and the owner goes on to the instances behind it, so no owner is parked and no authored line has run.
5. **Open the dispatch gate** when *every* admitted instance of every role (a harness's second instance included) has been validated and admission is complete. The driver then releases every held instance together (`releaseHeldInstance`), so both `init`s are dispatched to their own owners without either waiting for the other, and nothing an `init` does can change what another instance captured. A failure or stop before the gate opens aborts it: nothing is released, and a held instance settles as stopped with its owner, its `init` never having run.
6. **Observe the `init`s succeed.** The presentation role is `running` as soon as its own `init` has succeeded (its cadence starts there). The gameplay role is `ready` and waits. The **start gate** opens in the transaction that records the last selected `init`'s success, if no role has failed and no stop was asked; a one-role session needs only its own.
7. **Tick.** The pacing origin is the clock reading when the start gate opened. Tick *n* is due *n* tick durations after it. Each tick is granted by itself, at its own due time or as soon after as the owner is free: none is skipped, merged or shortened, and a slow hook or a late assigned result delays the next grant without advancing time. After each tick the coordinator waits for the owner's *accounting* (the endings the tick began, their shutdowns, escalations and retirements) before granting the next.
8. **End.** A stop, a failure of a policy that ends the session, or an owner that ended each close admission; the owners are asked to stop; the roles drain; each role retires when its owner's worker has ended and its coordinator has been closed and has given back every slot and byte.

### The gates

| Gate | Waits for | Opens | Aborted or shut by |
| --- | --- | --- | --- |
| Dispatch | every admitted instance of every selected role constructed and validated, and admission complete | once, in the transaction that records the last of them | any stop, any failure; an aborted gate never opens, and a late validation cannot reopen it |
| Start | every selected role's own `init` (every admitted instance of it) to have succeeded, the dispatch gate open | once, in the transaction of the last success, when nothing has failed or stopped | any stop, any failure that arrives first (a boot failure); a late success is remembered and cannot reopen it |

### Phases, admission and the status record

`sessionStatus` publishes the facts LFE-26 copies into a UI segment: whole-session `stopping`, each role's presence (an absent role is `Nothing`), `initialized` (its own `init` succeeded, every instance of it; historical, it never becomes false), `phase` and an independent latched `failure`.

| Phase | Meaning | Reached |
| --- | --- | --- |
| `starting` | the role's own `init` has not succeeded | at the start |
| `ready` | gameplay: its `init` succeeded, the start gate is closed | gameplay, on its own success |
| `running` | presentation: at its own success; gameplay: when the start gate opens | never for a failed or stopping role |
| `stopping` | admission closed, by a stop or by the role's own failure | in the transition that closes admission |
| `retired` | the owner's worker has ended (VM closed, every instance settled, every provider's retirement complete), the coordinator is closed and drained and no admission is in flight | by the driver, never by a stop request, a worker's exit or a cancellation acknowledgement |

A role's admission (`endpointAdmission` of its facade) is `open`, `stopping` or `closed`; a content request in a stopping or closed role is an ordinary Lua error before any action, never `busy`. A failure latches once per role and the first stays; a failed role's phase is `stopping` and then `retired`, never `ready` or `running`.

### The failure policy (D-42)

| What failed | Effect |
| --- | --- |
| an `init` of either role, an entry module, or the presentation role before the start gate opened | **boot failure**: both roles' admission closes and both owners are asked to stop in the same transition, without waiting for the other `init` to report; both gates close |
| a logical script, module or required-request failure after the start | the logical role's admission and tick grants close and its owner is asked to stop; the **presentation role goes on** with its own services until the whole session exits; the session is not `stopping` |
| a presentation failure, or the failure of a session's only role | the whole session stops |
| an engine, host, provider, output-sink or cleanup failure of any owner (and an arithmetic limit: a tick past 2^63 − 1, a deadline past the clock) | the whole session stops; the failure is that role's if its owner is known |
| `latchTerminalFailure` | the whole session stops; it is the guard's, not an ordinary role failure |
| `requestStop` | the whole session stops; nothing is a failure |

An eventual stop cannot erase an earlier failure: the outcome ranks **failure over interruption over a normal quit over success**, whatever order they arrive in, and the quit and interruption flags are kept beside it. A required request's failure latches at its eligible position whether or not Lua ever polled the request (the host's rule); the coordinator is told as the failing instance's ending begins and acts then, whatever a provider is slow to retire.

### The failure record and the engine report

A role's failure (`RoleFailure`) is the approved schema: `code` (`lua_error`, `module_error`, `required_request`, `host_failure`, `cleanup_failure`, `state_unavailable`), `message`, `role`, `stage` (`module`, `init`, `update`, `shutdown`, `request`, `cleanup`, `engine`), and, when known, `content_id`, `instance_id`, `path` and `traceback`; an unknown one is absent and no instance is invented for module-only work. Each text is cut at a UTF-8 code point to the profile's bound and a cut ends in a visible `...`: message 2 KiB, traceback 8 KiB, instance identity 128 bytes, the whole record 16 KiB (the traceback is shortened first, then the message, then the path).

The **engine report** accounts for every failure the session was told of: the first failure of any kind is its primary, at most `SecondarySummaries` (16) later ones are kept as summaries of at most `SecondarySummaryBytes` (2 KiB), and the rest are counted in `erOmitted`; the report stays within `EngineReportBytes` (64 KiB) whatever the primary's text. `outFailures` lists each failed role's first failure in the order they latched.

### The clocks

* **Logical.** The pacing arithmetic is checked and pure ("Hetoimasia.LuaEngine.Session.Pacing"): a due time the clock cannot count and a tick past the largest a Lua integer holds (2^63 − 1; the first tick is 1) end the session as an engine failure, never a wrapped value. A first deadline that is already impossible is refused before any Lua. The tick a script reads is the owner's tick plus a base that is zero outside the harness.
* **Elapsed.** The presentation role's cadence, `dt` and coalescing are the host's; its public `seconds()` origin is the root `init`'s start (the point the dispatch gate opened), its cadence starts from its own `init`'s success, and the two are never conflated.

### Stop and drain

`requestStop` is one transaction on the state, then non-blocking requests to the owners: it takes no request, task or result slot, and a second request changes nothing. Admission is closed *before* an owner is asked to stop, so a start or a grant that raced it is refused or lands before it; a grant is either issued before the logical role's stop or not at all (the check and the issue are one step under the lock that stop passes through). Work already inside a Lua segment finishes (nothing is preempted) and its calls to release, cancel and write output still work. Each eligible `shutdown` runs once, with `stopped` for a normal or peer-driven stop and `failed` for the instance's own failure, and is skipped for a failed `init` and where Lua is unsafe; a missing or failing hook never suppresses engine cleanup. A held provider read keeps its role live and unretired until it retires.

### The one commit

Every change to the session is one `Event` committed by one masked primitive, `applyEvent`, and `step` in `Session.State` is the only function that changes a `SessionState`. In one STM transaction the event changes everything it means: the failure latch, the phase, the gates, the marker that an instance's failure was already told, the claim that an owner's completion is accounted, and the historical facts it proves (an `init` that succeeded, recorded with the settlement that proves it, with no clock reading). The same transaction appends to the retained queue of effects owed the stops it closed admission for and the diagnostics it means (built by the pure `diagnostics` from the state before and after). After the commit the queue is run, by the committer and by anyone who runs it next (the driver, stopper registration, every teardown path):

* a stop leaves the queue only after the stopper returned, and is idempotent; a diagnostic leaves it when taken;
* an effect that **raises** is recorded as a failure of the engine (a diagnostic that cannot be written is recorded without a diagnostic of its own, so a sink that always raises cannot loop), the effect is given up and the queue goes on;
* an effect whose performer is **interrupted** leaves a stop owed and puts a diagnostic back at the front, and the interruption is raised after the state is consistent;
* the commit is masked: the only interruptible points are the blocking steps inside an effect.
* **a recovery or cancellation path only commits.** The paths that run when something has already gone wrong or the calling thread is being cancelled (the queue's own recovery, the owner scope's unwind and finalization, the retirement sweep, the recording of a composition failure) commit their event and never run the queue: the next normal step runs it, or the one final drain that `runSession` makes after the cancellation has propagated out of every scope and the retirements are published. Stops run before diagnostics, so a diagnostic that blocks cannot delay an owner's stop, and a stop that failed is settled before its failure is committed, so nothing is retried;
* **a failure and all the cleanup failures attached to it are one event**, committed whole before any effect runs.

So an event is never half applied and nothing it owed is lost: the harness's `Committed` point sits between the commit and its effects, and the examples cancel the committer there, inside a stop and inside a diagnostic.

### Leaving the session by a failure or a cancellation

However the session is left, every role that was built owes the same things, in this order: the gates are closed and its owner is asked to stop (retried, through interruptions, until it has been); its owner's worker has ended and the raw completion is collected; the completion's result and the cleanup it retained are **accounted in the engine report exactly once** (a per-role claim, so the driver's finalization and the scope that leaves the owner cannot both count it) and carried whole beside any exception that is raised; the module coordinator is closed and **drained**, so every read it started has returned what it reserved, before the data bank, the pool and the output it borrows are released; and only then is the role published as `retired`. A role that was never built holds nothing and is swept. A failure of the driver itself (a probe, a defect, a stop that cannot be made) is recorded when it is raised, as the first failure it is, before the scopes unwind and add their own; a cancellation is never swallowed and reaches the caller only when the roles have drained, with the cleanup the owners retained attached to it.

Everything injected that runs during teardown can fail, so none of it is allowed to skip an obligation. A diagnostic that cannot be written (the logger's sink raising) is **recorded as a failure of the engine in the state, never raised** from the transition that tried to say it; a probe, a clock read or a stop that raises is collected where it is called, and each step of finalizing an owner, of leaving its scope and of publishing the retirements runs whatever the one before it raised. Facts only known once an instance has ended are reconciled on **every** path that finalizes an owner, not only in the driver's loop: an `init` that succeeded is read from the host's shutdown disposition when the owner is finalized (the driver's `NextEnded`, or the scope that leaves it after an exception), so a session whose driver was cancelled after it released an instance, before it saw it run, still publishes `initialized`.

### State, owners and lifetimes

The coordinator adds no queue: an admission is at most two per role, one tick is in flight, and nothing is retried.

| State | Owner | Writers | Readers | Thread | Lifetime and disposal |
| --- | --- | --- | --- | --- | --- |
| the session state (`SessionState`, one `TVar`) | the `runSession` call | every event is one transaction: the owners' threads (the dispatch hook, the failure and escalation callbacks, an engine failure), the driving thread (admission, `init` success, retirement, a fault, the unwind), any thread (a stop, the terminal latch) | the status and outcome endpoints, each facade's admission endpoint, the hook waiting at the dispatch gate, the driver | any | the call; none to dispose |
| the stoppers (`TVar (Map Role (IO ()))`) | the call | the driving thread, once per role as its owner appears (a stop owed to the role is performed then) | whoever performs a stop the state says is owed | any | the call |
| the queue of effects owed (`stOwed`, in the session state) | the call | the one commit: the transition that closes a role's admission appends `OweStop role` (once), and every transition appends the diagnostics it means (`OweSay`); `Settled` removes a stop once the stopper returned, claiming a diagnostic removes it, `Requeued` puts an interrupted diagnostic back, `RoleRetired` drops the role's stop | the committer, the driver, stopper registration and every teardown path, which run the queue | any | the call; a stop is idempotent, so one performed twice is one performed |
| the markers (`stEarly`, `stAccounted`, in the session state) | the call | the transition that latches an instance's failure marks it told; the transition that commits an owner's end claims its accounting; both in the same step as the rest of the event | the transitions that decide whether a settlement adds anything, whether an owner is accounted again | any | the call |
| the pacing origin (`stOrigin`, in the session state) | the call | the transition that opens the start gate, once, from the clock reading taken just before it | the driver, which derives the schedule from it | the driving thread | the call |
| the grant lock (`MVar ()`) | the call | the driver, around the issue of one grant | the stop of the logical role, which passes through it | the driving thread and any stopper | the call |
| the seen set, the tracked instances and the early-notice set | the call | the owners' threads (first hook, early notice), the driving thread (tracking) | the owners' hooks and callbacks, the driver | owners, driving | the call; at most two instances per role |
| the driver (mode, schedule, grant in flight, finalized roles, observed instances) and the pacing timer | the driving thread | the driving thread only | the driving thread | the driving thread | the `operate` scope; the timer is disposed on every exit |
| a role's coordinator, data bank, facade and owner | the role's scopes | the driving thread builds and releases; the owner's thread runs in it | the services above | per owner | released in reverse order, the owner stopped and its worker awaited first |

### The order of a turn, a stop and a failure

| Sequence | In order |
| --- | --- |
| an instance's failure | the segment fails and the scheduler marks the task failed (a grant may now be finished) → at the boundary the instance layer begins the ending → **the coordinator is told** (state: failure latched, admission closed, policy applied; stoppers: grant lock, owner asked to stop, coordinator closed) → the `shutdown` hook (`failed`) → release and drain → the retirements providers owe (the ending waits parked) → the instance settles → the escalation (accounts what else failed, never a second failure) → the owner's accounting is acknowledged → the driver's wait for the tick's accounting returns → no further grant |
| a stop | the state transition (flags, every admission closed, gates aborted or shut) → the grant lock (logical role) → every owner asked to stop → a running segment returns → each `shutdown` (`stopped`) → release and drain → providers retire → the owner's worker ends → the driver finalizes it (its outcome and any retained cleanup failure are accounted, the coordinator closed) → the role retires once the coordinator is drained and no admission is in flight |
| a tick | the timer is armed for the due time → the wake → the clock is read → the check of the logical role's admission and the issue of the grant under the lock → the grant in flight → the scheduler finishes it (or the owner ends) → the owner's accounting → the schedule advances (a deadline the clock cannot count ends the session) |
| startup | preflight → the roles built → entries evaluated → admissions intended, issued, tracked → admission complete → each owner constructs and validates each instance and holds it → the dispatch gate opens → the driver releases every held instance → `init`s run → the driver observes the successes (or, for one it did not see run, the host's record of it) → the start gate opens in the transaction of the last success, with the clock reading taken just before it as the origin → the driver derives the schedule from the origin → ticks |

### The host's failure notice

The Lua host settles an instance's ending only after the providers it asked have retired, and tells the application's escalation then, so a failure whose own provider is slow would be unknown until it retired. The host therefore also tells the application, once, as an ending *begins* with a failure (`instanceOnFailing`, default: nothing), with the primary failure alone; the settled record the escalation is told adds what else failed. The coordinator acts on the first and accounts the second.

### The harness

`Hetoimasia.LuaEngine.Session.Harness` is what a test composes. It is in a private sublibrary, `session-harness`, that no public library exposes and no one outside the package can depend on; the public `Hetoimasia.LuaEngine.Session` shows `Harness` as an abstract type and `noHarness`, so a composition outside the package can pass the one and cannot build another or read a field. None of it is reachable from a manifest or from Lua. It names the points of a session's life (`Built`, `Released`, `Intended`, `Issued`, `Tracking`, `Validating`, `Dispatched`, `Resumed`, `GrantIntent`, `GrantIssued`, `StopHandoff`, `OwnerEnded`) so a test can hold the thread that reaches one, or make it raise, to place a stop or a failure in an exact window; it asks for the second instance of a role on the same VM that the design keeps for qualifying reusable bindings (never public spawning), which is admitted, constructed and validated like the first and counts toward its role's gates and status; and it sets the tick counter's base, so the Lua integer ceiling is reached without granting 2^63 ticks.

### What proves it

`Test.LuaEngine.Session.*` (group `test.lua-engine`) run real Lua on real supervised owners the coordinator starts, over a real content root, manifest, boot checkpoint, inventory and read pool, an injected clock and a fake timer, recording sinks and gates, and no sleep: the pure model (every gate, phase, admission and policy transition, and the invariants after every step of every sequence of five events); the startup (both `init` orders, the presentation role starting while a logical `init` is held in Lua and at the dispatch point, the common and per-role entries and either manifest order, each one-role session, a missing `init`, validation of an invalid cadence or module in either role starting neither, a boot failure latched the moment its entry answers in either role while the other entry is held mid-read, a module-only boot failure keeping its traceback, a first `init` that edits the behavior unable to invalidate the second instance, content requested during `init`); a stop or failure on each side of each gate (between intent and issuance, accepted and untracked, at the gate, while an `init` is held, just before the start gate would open, while a role is still being built); the clocks (exact ticks, a slow hook, no debt for the wait, the origin unmoved by a held diagnostic, first in first out with a yield, no overlapping update, the elapsed coalescing and `dt`, the two origins, the Lua ceiling and an impossible deadline before and after the start); the failure policy (a logical failure beside a healthy presentation role with no later grant, a required request nothing polled, a failure published while a provider holds the role, an `init` success the driver did not see kept after its instance failed, a presentation failure, a one-role failure, the terminal latch, a provider fault, a sink fault, a cleanup fault that ends a healthy presentation role, an optional failure and a caught validation error that do not); the evidence (the first failure kept, the multibyte bounds, failure over interruption); the stop and drain (every place taken, shared module jobs, a peer's holdings, the shutdown dispositions, and a stop whose applying thread is cancelled in the middle of the handoff, which the driver finishes); the exits by an exception (a driver failure with a coroutine suspended in a failing close, a cancellation carrying that cleanup, and a cancellation while a boot read is held, which the session does not outlive); construction and cancellation (every step released once, release failures kept beside the failure, the calling thread cancelled at four windows); and a separately compiled client that opens a root, makes the checkpoint and runs a session through public modules alone.

## Deferred, by design

Not here, and not claimed: the CLI `run` dispatch and exit mapping (LFE-22), which will
consume the boot checkpoint and retain the same anchored root;
the concrete GPU upload and registration, native budgets, scene holds and the atomic publication of a prepared scene (LFE-17 to LFE-20), the public Lua graphics binding (LFE-21),
the graphics and status service facades (the content, request, time and output surface is [the facade](#the-authoring-facade-lfe-12);
the texture pipeline's typed endpoint is still its own), `api.session`, `quit` and the
unavailable-state `state` guard (LFE-26), which consume [the session coordinator's](#the-session-coordinator-lfe-13) status, stop and terminal-failure endpoints,
the launcher that opens the content root, makes the checkpoint, installs the signal handlers and maps the outcome to an exit status (LFE-22); live codec, texture and GPU budgets and their
enforcement; real pacing; mods, metadata extensions, alternate manifest formats, defaults or relaxed parsing.

## Tests

`lua-engine-tests` (validation group `test.lua-engine`, the CPU project, Hspec):

```sh
cabal test --project-file cabal.project.cpu hetoimasia-lua-engine:lua-engine-tests --test-show-details=direct
```

The manifest, profile and behavior examples perform no IO and start no Lua; the boot checkpoint's
examples scan real temporary folders through the content package and evaluate nothing (the Lua host's behavior
mechanism is tested in its own suites); the request adapter's examples start real Lua instances on a real
supervised owner, with controlled fake providers, and no window or GPU; the raw-data provider's examples do the same over a real
content root, inventory and read pool (see above), the module coordinator's run real modules through real VMs over the
same (see above), and the texture pipeline's over that and the real bounded PNG decoder with an
injected upload backend (see above). It covers the accepted
examples, every syntax and schema refusal with the limits at their boundary and
one past, the exact tick endpoints and forbidden forms, every fixed value against
an independently written expectation, valid smaller profiles and refused ones,
the behavior selection's cadence rules and numeric boundaries, the boot checkpoint (see above), the request adapter (see above), the raw-data provider (see above), the module coordinator (see above), the texture pipeline (see above), the scene schema (see above), the authoring facade (see above), the session coordinator (see above), and this package's dependency and import boundary.
