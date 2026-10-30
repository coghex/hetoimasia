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
  4,096 sprites, within 65,536. `sceneCallElementBound` adds the window handle a
  publishing call carries beside the scene (`sceneCallExtraElements`, one element:
  the reader keeps one counter for all the arguments of a call): 24,583 at 4,096
  sprites. Validation relates the call's count, not the scene's alone, to
  `CopiedValueElements`, and the call's bytes (`SceneInputBytes` plus
  `sceneCallExtraBytes`, 64) to `CopiedValueBytes`, so a profile that validates
  can always carry a publishing call; a profile whose limit is exactly the
  scene-only bound is refused.
- The **six adopted scene revisions per target** are not a limit here. The
  profile records the two frame slots per window; the graphics composition
  derives six from them (`2 * (slots + 1)`, owned by the Vulkan package, which
  this package never imports) and defers adoption when full.

### Smaller injected profiles

A test builds one by changing a copy of `profileSpec fixedM1Profile` and
validating it. `validateProfile` checks, in order, that the derived products fit
64 bits (`DerivedOverflow`), that every limit is positive and **no larger than
its fixed value** (`LimitNotPositive`, `LimitAboveFixed`), that every limit is
**at least the least the engine's own schema, format and crossings need of it**
(`LimitBelowMinimum`, below), and that the relations below hold
(`RelationBroken`). A profile can only shrink; no value is clamped. The 64-per-VM request limit is not "corrected" to fit 16 per instance
times 2 instances: independently bounded maxima need not be simultaneously
attainable.

#### The least each limit may be (`Hetoimasia.LuaEngine.Profile.Minimum`)

Most limits are **caps on what comes in** (a manifest, a module's source, a data file, a PNG, a request, a scene, a window, a native budget): a cap too small to hold any real input refuses content, loudly and early, and breaks nothing the engine makes itself, so the least such a cap may be is the least positive value, one. A few limits are **bounds on what the engine itself writes or hands across**; a bound below the least its own schema, format or crossing needs would be a promise it cannot keep, and validation refuses it (`LimitBelowMinimum LIMIT GIVEN LEAST`, after the ceilings and before the relations), so a profile it accepts is one the engine can use without a second refusal at the point of use:

| Limit | Least | Why |
| --- | --- | --- |
| `RoleFailureRecordBytes` | 37 (`schemaWordsBytes`: the longest code `state_unavailable` 17, stage `shutdown` 8 and role `presentation` 12) | a failure record's schema words cannot be shortened; every text is cut away first, so the whole-record cap holds for every code, stage and role only from here up (round 9's finding: a bound of 2 was accepted) |
| `InstanceIdBytes` | 6 (`minimumInstanceIdBytes`) | the first identity the session issues |
| `PrintWarnBytes` | `minimumPrintWarnBytes` of the identity bound | a warning must be able to name its writer, end in the marker and a line end |
| `CopiedValueBytes` | `minimumCopiedValueBytes` of the identity and print bounds and the most text a failure may hold (`failureTextBytes`) | what the facade itself makes cross the value boundary, the [status record](#the-session-controls-lfe-26) of two failed roles included (565 at the smallest bounds) |
| `CopiedValueElements` | the larger of `sceneFixedElements + sceneElementsPerSprite + sceneCallExtraElements` (13) and `minimumStatusElements` (30) | a publishing call of one sprite and the largest status record must be able to cross |
| `CopiedValueDepth` | `minimumStatusDepth` (3) | the status record nests three deep: the record, a role, a failure |
| `PngPipelineWorkspaceBytes`, `TextureBytesPerUiInstance`, `TextureBytesPerSession` | 4 (`rgba8BytesPerPixel`) | a texture holds at least one RGBA8 pixel |
| every other byte, count and duration limit | 1 (1 ns) | a cap on what comes in, or on a text cut visibly to it; the relations then keep them consistent (the smallest legal profile, every limit at its least, satisfies all of them) |

The facade's own check of the first six (`LimitBelowFormatting`) is a guard that no validated profile reaches; the other bounds the session and its services check (`NotRepresentable`: a value that does not fit a machine integer; the texture pipeline's job capacity and PNG limits; the scene limits) are unreachable for a validated profile because every ceiling is within the machine integers and every least is at least one. The examples (`Profile`, *the least each limit may be*) accept each limit at its least and refuse it one below, for every limit.

| Relation | Meaning |
| --- | --- |
| `ManifestWithinHashFile`, `ModuleSourceWithinHashFile`, `HashFileWithinHashRoot` | the manifest and a module are files the hashing limit admits, and a file fits its root |
| `ActiveChainReserveHoldsModuleSource`, `ActiveChainReserveWithinSourceBank` | the active-chain reservation can hold one module's source and fits the bank |
| `ChainDepthWithinIdentities`, `RequestsPerInstanceWithinVm` | an active chain is among the cache identities; an instance's requests are among its VM's |
| `DataWithinRetainedBank`, `DataWithinCopiedValue` | a data result fits the VM's retained bytes and the crossing |
| `SceneInputWithinCopiedValue`, `SceneDepthWithinCopiedDepth`, `SceneElementsWithinCopiedElements` | scene limits fit the copied-value ceilings, the publishing call's window handle (one element, 64 bytes) included |
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
all inside the common 16 MiB, depth 8 and 65,536. A binding that takes a window handle beside the scene reads its arguments under `scenePublishLimits`: the same, plus the handle's one element and 64 bytes. The reader applies the smaller of the owner's and the binding's limit while it
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
| `api.session.status()`, `api.session.quit()`, `api.state(...)` | the [session controls](#the-session-controls-lfe-26) (LFE-26) |

`print`, `warn`, `import(path [, root_id])` and `state(...)` are globals. Nothing else is added: no logger, no file handle, no
clock but these, no global `quit` or `status`, no session control beyond the [two functions and the guard](#the-session-controls-lfe-26).

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

### The graphics calls (LFE-21)

A composition that injects graphics (`FacadeSpec.fsGraphics`, made by a `GraphicsInjection`; see
[the session](#what-a-composition-injects)) adds four calls and one request kind to the facade. The CPU facade owns every
Lua-visible rule of them and imports no texture, scene, window, GPU, GLFW or Vulkan module: it is handed `GraphicsServices`,
abstract operations, and the concrete composition over the real providers is
[the graphics adapter's](../lua-engine-graphics/README.md#the-graphics-facade-lfe-21). A facade with no graphics has none of the
fields below, no handle type and no request kind, exactly as before. The layout is the same in both roles: a logical
instance's call is an ordinary error of the binding, never a missing field.

| Call | Arguments | Successful result |
| --- | --- | --- |
| `api.content.texture(path [, options])` | `options` is `nil`, absent or a plain table with only `root` and `optional` (a boolean, default `false`; `nil` omits, `false` is a value). `tick_offset` is refused, `1` included | `request, nil`; the taken value is `{texture=HANDLE, width=INTEGER, height=INTEGER}` |
| `api.window.open({title=TEXT, width=INTEGER, height=INTEGER})` | exactly the three fields, all required; `width` and `height` are Lua integers (`1.0` and `"1"` are refused) | `request, nil`; the taken value is the window handle itself |
| `api.scene.publish(window, scene)` | the instance's own ready window and a scene of [the scene schema](#the-scene-schema-lfe-19) | no results, once the whole publication is accepted |
| `api.texture.release(texture)` | the instance's own texture, including one already released | `"done"`, `"retiring"` or `"already_released"` |

Every call is a dot call with its exact arity (an explicit `nil` is an argument), a plain record and the host's raw reading: a
colon call, a metatable, an unknown or missing field, a wrong type or subtype and a table that is not a plain record are
ordinary errors before any provider is asked, and no authored metamethod runs. The root defaults to the requesting instance's
content identifier, not the defining module's; a root the session does not enable and an invalid path are refused with no
filesystem action. The title is UTF-8, at most 512 bytes, with no control character (empty is allowed); the dimensions are
`1..4096`; those rules, and the occupied window slot, are the adapter's checks, run after the facade's own.

**Busy.** `content.texture` and `window.open` return `nil, {code="busy", message=TEXT}` when a temporary bank (the request
places, the texture slots and bytes, the provider's records) has no room: two Lua values, no handle, no provider or native action.
Busy comes only from the atomic M1 reservations the admission makes before it acquires a lease or starts a request. A second window
while the instance already has a pending, live or retiring one is the permanent ordinary error `this instance already has a window`,
decided before any temporary bank, so a full bank never turns it into busy. The host's own lease and request capacity refusals are
faults; the lease scope of a VM is therefore made with room above every texture and window the instance's reservations can hold
(16 + 1, see the adapter's derivation), so no accepted M1 admission can reach them.

| Call | Module top level | `init` | update | `shutdown` | After the stop latch |
| --- | --- | --- | --- | --- | --- |
| `content.texture`, `window.open`, `scene.publish` | refused | presentation | presentation | refused | refused (an ordinary error, never busy) |
| `texture.release` | refused | presentation | presentation | presentation | allowed |
| `request.ready`, `take`, `cancel` | refused | yes | yes | yes | yes |
| `request.wait` | refused | refused | yes | refused | yes |

The stop latch is the session's admission, read through the endpoint the facade already has; `quit()` closes it before it returns,
so later statements of the same segment can release, cancel, print and warn but cannot open, load or publish. A module evaluated as
part of a hook-started load is a module: it does not borrow the hook's authority. The window and texture requests are read, taken,
cancelled and waited for through the common `api.request` operations; a window failure is `{status="failure",
error={code="window_error", message=TEXT}}` with no root or path, a texture failure carries both.

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

**The bounds the facade formats with are refused by the profile's own validation** (`LimitBelowMinimum`; the facade's `newFacade` keeps `LimitBelowFormatting NAME GIVEN LEAST` as a guard that no validated profile reaches), each against what the facade's own format needs:

| Limit | Least | Why | Boundary examples (`Facade.Limits`) |
| --- | --- | --- | --- |
| `InstanceIdBytes` | 6 (`minimumInstanceIdBytes`: `inst-1`) | the first identity the session issues; a later identity that does not fit is refused when it is declared (`IdTooLong`), never written | 5 refused; 6 makes a facade whose first instance is `inst-1`, and the tenth identity is refused |
| `PrintWarnBytes` | `minimumPrintWarnBytes idBytes`: the longest warning prefix, `...` and a line end (242 + 4 for `InstanceIdBytes` 128; 167 + 4 for 6) | every line of a cut warning keeps the whole prefix and the marker ends the last of them; the longest prefix is an instance's (`lua warning role=presentation content=` + 64 + ` instance=` + `InstanceIdBytes`) or a module's with its label (the host keeps at most 128 bytes of it) | one below refused; the least keeps the format end to end, from a hook and from a module at the longest label |
| `CopiedValueBytes` | `minimumCopiedValueBytes idBytes printBytes failureTexts`: the largest of everything the facade makes cross, each with the host's header: one `print`/`warn` text (`PrintWarnBytes + 5`), an identity (`InstanceIdBytes + 5`), the builder's context record (`minimumContextBytes`: 142 for an identity bound of 6, 264 for 128) and the largest status record (`minimumStatusBytes failureTexts`: 491 bytes and two failures' texts, where `failureTexts` is `failureTextBytes` of the message, traceback, identity, path and record bounds, at most the record bound) | a text or record crosses as its payload and a header; the longest `out`/`err` call is the output bound and five bytes | one below refused; the least cuts and writes the longest `print` and `warn`, builds an instance's `api`, and turns a path or `import` too large to cross into an ordinary, catchable error |
| `CopiedValueElements`, `CopiedValueDepth` | `minimumStatusElements` (30) and `minimumStatusDepth` (3), the status record's (the elements are at least a scene of one sprite's 12 as well) | the largest status record: a record, `stopping`, and for each role its table, four fields and a failure of eight | one below each refused (`Facade.Limits`); at all three least values the host copies the largest status record the profile's bounds admit, whole |
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
admits the roots, runs the roots' `init`s and the clocks over the Lua host's own scheduler, applies the failure policy and tears
down through one protected protocol that ends in actual retirement. It adds no scheduling, no world, no progress channel and no event API; it installs no signal handler,
exits no process and writes nothing to a standard stream. The Lua status, quit and unavailable-state bindings are [LFE-26's](#the-session-controls-lfe-26), which
consume the endpoints below (`sessionEndpoints` hands a facade exactly three of them); the launcher that opens the content root, makes the checkpoint and maps an outcome to an exit status is LFE-22's.
[D-82](../../docs/designs/lua_first_engine_design.md) (the teardown protocol), D-83 (the first two host seams), D-84 (the third), D-85 (the fourth), D-86 (the fifth) and D-87 (diagnostics go through a session-owned writer that the session abandons, without waiting for it, once every role has retired) are normative for this section.

```haskell
runSession           ∷ SessionSpec → (Session → IO ()) → IO SessionOutcome   -- on the thread that owns the supervision control
sessionStatus        ∷ Session → STM SessionStatus                            -- nonblocking, coherent, bounded
sessionOutcomeNow    ∷ Session → STM SessionOutcome                           -- failure over interruption over success, as it stands
sessionHistory       ∷ Session → STM History                                  -- what each settlement proved, and the stop receipts
requestStop          ∷ Session → StopKind → IO ()                             -- StopQuit | StopInterrupt: no slot, idempotent
latchTerminalFailure ∷ Session → RoleFailure → IO Bool                        -- the unavailable-state guard's latch; True the first time
```

`runSession` makes the session's **lifecycle record** first and hands the `Session` to the callback before any VM exists, so a stop, a status read
or a terminal-failure latch can be wired to whoever needs them without waiting on a VM; the callback must not block. It then runs
the session on the calling thread, which must be the thread that owns the supervision control, because its waits are supervised
ones, and returns only once **every role has actually retired** (or, when a release failed, stays `stopping` and says so). The handle's endpoints are safe from any thread, so a native
event loop never waits for an `init` or a tick: the control and progress seam is the handle, not the driver. The record is fresh for each session, is never reset,
outlives every role's scope and stays readable through an already published handle after the call returns or throws. An entry that is
uninterruptibly masked is refused before anything is acquired: the protocol's waits must stay interruptible, and no mask can be undone from inside one.

### What a composition injects

`SessionSpec` holds, and the coordinator passes on narrowed, the services it is given; it reaches no global, no environment record and no registry.

| Field | What it is |
| --- | --- |
| `sxProfile`, `sxCheckpoint` | the validated profile every bound is read from, and the boot checkpoint: the manifest and the entry each selected role loads, validated against the content scan before any Lua |
| `sxInventory`, `sxPool` | the anchored content and the session's pool of verified reads, which outlives every owner and is **borrowed**: `runSession` awaits its own outstanding interests and the read pool's sink deliveries (not the diagnostics writer's, which it never waits for) and never closes the pool, the root or the output |
| `sxLogger`, `sxOutput` | the coordinator's diagnostics (lifecycle at info, a failure once at error, component `luaengine.session`), and the authored output, the caller's scope. The logger is **borrowed**, and the session's own **writer thread** is the only caller of it, until that writer ends, which can be after the call returned (`sessionDiagnosticsEnded`; whoever owns the logger, the assembly after the producers have stopped, joins it before releasing the logger). No step of the driver, no stop pass and no step of the teardown calls it: so a logger that holds a write holds that thread and nothing else, and a writer still in the sink when the roles have retired is abandoned and its undelivered diagnostics recorded in the outcome (the module coordinator's own warning for a failure nobody waits for goes through the same logger on the owner's thread, as an owner's authored `print` goes to the output) |
| `sxClock`, `sxTimer` | the monotonic clock the owners, the facades and the pacing share, and what sleeps (the threaded runtime's timer manager in production, a hand-fired one in a test). The backend's arm and cancel run under the repository's uninterruptible discipline, so they must be finite and non-waiting, like a release; what either raises, of whatever type, is raised by the timer as a failure of that cleanup (or of the host, for an arm) and never mistaken for a cancellation of the caller |
| `sxRuntime`, `sxControl` | the Lua runtime the owners start on, and the supervision control of the driving thread |
| `sxHarness` | `noHarness` for a real composition; see [the harness](#the-harness) |
| `sxGraphics` | the graphics a composition injects (LFE-21): `Nothing` for every CPU-only caller, whose facades are exactly as before, or a `GraphicsInjection`, the abstract function the session calls once for each role's VM, over that VM's own request policy (already gated on the session's admission) and a transaction that says whether the role still takes new work (the authority a publication commits with), to make its `GraphicsServices` (its lending and lease scope, its handle types, its request endpoints and the four operations). The pipeline, the window provider and everything under them are the assembly's, made before the session and closed after it; the session never closes them. The concrete injection is [the graphics adapter's](../lua-engine-graphics/README.md#the-graphics-facade-lfe-21) |

The pool, the anchored root and the output belong to the assembly outside `runSession`, which closes and drains the actual pool before it releases the inventory and the root, and closes the output last, after the producers have stopped. A pool shutdown failure after `runSession` returns is the assembly's evidence and makes the eventual exit fail. A session-local `retired` does not claim that these shared services were destroyed.

The content identifier an instance requests under, and the one root the facades enable, is the inventory's root. The roles are the
checkpoint's: gameplay (with the manifest's exact tick), presentation, or both, whatever order the manifest listed them in.

### What a session does, in order

1. **Preflight, before any Lua.** A harness asking for a second instance of a role the session lacks, and a first logical deadline the clock cannot count (the reading plus one tick), are refused here as an engine failure.
2. **Build each role's VM**, gameplay first. Each component (the module coordinator, the data bank, the facade, the scheduled owner) is acquired and **registered with the lifecycle record in the same masked step**, with its finite stop or drain proof and its finite release, before any probe, callback or further acquisition. The scopes still nest, outermost first, so that what a component borrows outlives it; they hold nothing the protocol below depends on.
3. **Evaluate each selected entry and its imports** in its own VM (a common entry separately in each), running no root. A module that does not evaluate is a boot failure attributed to the module, with no instance and with the traceback the module system recorded. Every entry is asked before any is waited for, and each outcome is applied the moment it arrives, whichever entry that is: a failure is latched and the stops owed while the other entry is still being read.
4. **Admit the roots.** Each admission is *intended* in the session's state (a commit with no probe inside it, resolved exactly once, by being tracked or abandoned, whatever follows it, the probe beside it included), *issued* to the owner and *tracked*; the owner constructs and validates the behavior (the export, hook, captured schema and cadence) and, at the point its `init` would begin, the host asks the session whether to **hold** the instance there (`instanceHoldInit`): the session records the instance as validated and answers yes, and the owner goes on to the instances behind it, so no owner is parked and no authored line has run.
5. **Open the dispatch gate** when *every* admitted instance of every role (a harness's second instance included) has been validated and admission is complete. The driver then releases every held instance together (`releaseHeldInstance`), so both `init`s are dispatched to their own owners without either waiting for the other, and nothing an `init` does can change what another instance captured. A failure or stop before the gate opens aborts it: nothing is released, and a held instance settles as stopped with its owner, its `init` never having run.
6. **Observe the `init`s succeed.** The presentation role is `running` as soon as its own `init` has succeeded (its cadence starts there). The gameplay role is `ready` and waits. The **start gate** opens in the transaction that records the last selected `init`'s success, if no role has failed and no stop was asked; a one-role session needs only its own.
7. **Tick.** The pacing origin is the clock reading when the start gate opened. Tick *n* is due *n* tick durations after it. Each tick is granted by itself, at its own due time or as soon after as the owner is free: none is skipped, merged or shortened, and a slow hook or a late assigned result delays the next grant without advancing time. After each tick the coordinator watches for the owner's *accounting* (the endings the tick began, their shutdowns, escalations and retirements) before granting the next, as one more alternative of the driver's single lifecycle wait (D-86): the driver takes the snapshot when the tick finishes (`watchScheduledAccounting`), and `scheduledAccountingStep` is read in the same transaction as every stop owed, role step and instance event, after all of them, so a retirement a provider owes that extends the accounting delays only the next grant and never another role's accounting or retirement. No wait of the driver's loop is a call that such a retirement can extend. The check that the logical role takes ticks (its admission is open, the session is not stopping, the start gate is open) and the scheduler's acceptance of the grant (`grantScheduledStepSTM`, D-85) are one transaction, so no tick is granted once the closure has committed, whether or not the logical stop has been handed to the owner; the transaction runs no IO, probe, clock, logger or sink, holds no lock and never retries, and a closed role grants nothing and returns at once. A grant accepted before a closure that the owner then discards when it stops is accounted as the owner ending, never as a completed tick.
8. **End.** A stop, a failure of a policy that ends the session, an owner that ended, or an exception on the driving thread each close admission and owe the owners their stops; the [teardown protocol](#the-teardown-protocol-d-82) then runs, for every way out, and each role retires when retirement is proven.

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
| `retired` | retirement is **proven** (below): no admission intent outstanding, the owner's raw completion and every settlement accounted, the coordinator drained of every read it started, and every release the role registered attempted without one failing | by the protocol, in one commit, never by a stop request, a worker's exit, a cancellation acknowledgement or an exited scope |

A role whose release failed stays `stopping`: retirement is unproven, the failure is accounted, and `outRetired` says false. A role's admission (`endpointAdmission` of its facade) is `open`, `stopping` or `closed`; a content request in a stopping or closed role is an ordinary Lua error before any action, never `busy`. A failure latches once per role and the first stays; a failed role's phase is `stopping` and then `retired`, never `ready` or `running`.

### The failure policy (D-42)

| What failed | Effect |
| --- | --- |
| an `init` of either role, an entry module, or the presentation role before the start gate opened | **boot failure**: both roles' admission closes and both owners are owed their stops in the same transition, without waiting for the other `init` to report; both gates close |
| a logical script, module or required-request failure after the start | the logical role's admission and tick grants close and every instance of its owner is stopped; the logical role retires through the protocol **while the presentation role goes on** with its own services until the whole session exits; the session is not `stopping` |
| a presentation failure, or the failure of a session's only role | the whole session stops |
| an engine, host, provider, output-sink or cleanup failure of any owner (and an arithmetic limit: a tick past 2^63 − 1, a deadline past the clock) | the whole session stops, and the stop set widens to every owner not yet asked before the next wait; the failure is that role's if its owner is known |
| an owner that ended and nothing asked it to (an external stop) | the whole session stops; it is neither a failure nor a quit. An unexpected cancellation of an owner is a failure of the host |
| `latchTerminalFailure` | the whole session stops; it is the guard's, not an ordinary role failure |
| `requestStop` | the whole session stops; nothing is a failure |

An eventual stop cannot erase an earlier failure: the outcome ranks **failure over interruption over a normal quit over success**, whatever order they arrive in, and the quit and interruption flags are kept beside it. A required request's failure latches at its eligible position whether or not Lua ever polled the request (the host's rule); the coordinator is told as the failing instance's ending begins and acts then, whatever a provider is slow to retire.

### The failure record and the engine report

A role's failure (`RoleFailure`) is the approved schema: `code` (`lua_error`, `module_error`, `required_request`, `host_failure`, `cleanup_failure`, `state_unavailable`), `message`, `role`, `stage` (`module`, `init`, `update`, `shutdown`, `request`, `cleanup`, `engine`), and, when known, `content_id`, `instance_id`, `path` and `traceback`; an unknown one is absent and no instance is invented for module-only work. Every text is cut at a UTF-8 code point to its own bound and a cut ends in a visible `...`: message 2 KiB, traceback 8 KiB, instance identity 128 bytes, path `PathBytes`, and content identifier 64 bytes (the longest the manifest admits; it is the manifest's number and not a profile one). The whole record, which counts the UTF-8 bytes of **every** text it holds, the schema's words (`code`, `stage`, `role`) included, is held to 16 KiB by shortening the traceback first, then the message, then the path, then the instance identity, then the content identifier; only a record bound smaller than the schema's own words cannot be met. The state bounds the failure that **any** event carries when it takes the event in (`boundEvent`, idempotent), so no caller owes the bound: the public terminal-failure endpoint, a latched role failure and an instance's early notice publish, store and say only a bounded record, whatever built it.

The **engine report** accounts for every failure the session was told of: the first failure of any kind is its primary, at most `SecondarySummaries` (16) later ones are kept as summaries of at most `SecondarySummaryBytes` (2 KiB), and the rest are counted in `erOmitted`; the report stays within `EngineReportBytes` (64 KiB) whatever the primary's text. `outFailures` lists each failed role's first failure in the order they latched. These bound what is rendered and published; the foundation's structured exception context and the raw evidence the session keeps for the exception it raises are not copied into the status or the effect queues.

### The clocks

* **Logical.** The pacing arithmetic is checked and pure ("Hetoimasia.LuaEngine.Session.Pacing"): a due time the clock cannot count and a tick past the largest a Lua integer holds (2^63 − 1; the first tick is 1) end the session as an engine failure, never a wrapped value. A first deadline that is already impossible is refused before any Lua. The tick a script reads is the owner's tick plus a base that is zero outside the harness. The origin is committed in the transaction that opens the start gate, from a reading taken just before it, before any diagnostic; teardown reads no clock.
* **Elapsed.** The presentation role's cadence, `dt` and coalescing are the host's; its public `seconds()` origin is the root `init`'s start (the point the dispatch gate opened), its cadence starts from its own `init`'s success, and the two are never conflated.

### The teardown protocol (D-82)

There is one protocol, for every way out; it does not depend on which scope an exception was caught in, and the record it works from outlives them all.

**Own the unwind before exposing anything.** The outer masked continuation is installed before the handle is given to the callback and before any diagnostic, clock or construction. A component is registered with the record in the masked step that acquires it (the registration and the fact `Acquired` are one transaction), so a stop or a failure that follows finds it; an owner that is registered late is handed any stop that was owed, at once. A construction or an admission is *intended*, *accepted and tracked* or *abandoned*; closure forbids a new intent, an earlier one resolves, and an accepted ticket is not forgotten before its settlement is accounted. If an owner's own start fails or is cancelled while it is made ready, the starter's protected obligation is to stop that one worker and wait for it to end before it raises. The session's D-84 callback (`scheduledOnStartAbandoned`) runs on the starter's thread after the starter's own stop request and before its wait: it commits the closure and runs the finite stop pass for every already registered owner and coordinator, then tells the point `StartAbandoned`, and nothing it does can raise into the host (its own failure is accounted as a failure of the host; a cancellation that lands in it is retained for the end). So a worker held in its initialization delays nothing the barrier owes, and a stop requested at the same time finds the pass done.

**Select the stop set, then complete the barrier.**

| Trigger | Stop set and continuation |
| --- | --- |
| a normal quit, an interrupt, an external owner stop, or the body finishing | the whole session closes; every constructed owner is stopped, even a completed one; the protocol below runs and returns the ranked outcome |
| an ordinary logical failure after the start gate, with a healthy presentation role | the failure latches; the logical role's admission and grants close and all its owner's instances stop; the logical role retires through the protocol while the presentation role is still serviced; nothing the presentation role needs is closed |
| a boot, validation or init failure; a presentation or one-role failure; an engine, host, provider, output-sink or cleanup fault (a failure of the diagnostics sink is evidence, not one of these) | the whole session closes at once; a fault during the logical role's retirement widens the stop set to every role before the next wait |
| the driver, the callback, a probe or the clock throws, including before or during construction | the exception is captured with its context, the session closes, the protocol runs for everything actually acquired, and the exception is raised at the end |
| the driving thread is cancelled at any step | the first cancellation and its context are retained, the session closes and the protocol resumes from the recorded obligations; the cancellation is not itself a failure of the engine |

**The barrier order.** (1) The affected admission, tick grants and unopened gates close, and each stop is *owed*, in one commit. (2) Every constructed owner in the stop set is asked to stop, in stable role order (logical, then presentation), including those of outer or nested scopes: the owner's request to stop, the close of its module coordinator's admission and the withdrawal of the reads no worker took, all finite and non-waiting. (3) Each handoff is committed. Only then does anything wait for any owner, provider or coordinator. Between the first and last stop there is no logging, clock, probe, Lua, waiting lock, `throwTo`, callback or drain, and the pass has no hook inside it; a test observes it through the stop receipts (`historyStopped`) at the first wait. The pass is repeated for an owner constructed late, after a wait ended and after a new fatal entry widens the set, and repeating it is harmless. A stop primitive that raises is recorded once and the pass still attempts every other stop; that stop stays owed, is not retried and is never declared handed. Every scope a body leaves runs the whole protocol for every registered owner, first, so the order of the scopes does not decide it.

**Drain, account, release, publish.** Each role proceeds as its own steps become possible, so a slow role never holds back accounting a peer already terminal, and the driver of a surviving role is never blocked on a retiring one:

1. *Observe and account.* The owner's **raw completion** (never a supervised wait, which redelivers a latched fault) and the settlement of every tracked instance are read, and one recovery commit records the claim that the completion is accounted, how the owner ended, every cleanup failure it retained (by the identity it already had), a settlement that is missing as a fault of the host's contract, and the historical facts the settlements prove. No clock, sink or probe is needed to derive or commit it.
2. *Prove the drain.* The coordinator's own drained predicate (no outstanding slot or charged byte, including VM-lifetime module work with no waiter left) is awaited; the owner's completion alone is not this proof.
3. *Release.* The role's registered finite releases (the last acquired first) run once each, uninterruptibly, and never wait; each that raises is retained and accounted and the others still run. The pacing timer's disposal and the outermost scope's release are session-level releases run once after every role has finished.
4. *Publish.* `retired` is committed, with these facts, only if retirement is proven (`retirable`); a release that failed leaves it unproven and the role `stopping`.

Waits run through the enclosing `restore` with a handler installed: an interruption is retained with its context, the barrier pass is made again and the one outstanding wait is resumed, never turned into a receipt. No drain, probe or arbitrary backend wait sits inside an uninterruptible release.

**Masks.** `mask` covers ownership transfer, exception capture, each complete evidence bundle, the outer continuation and every finite pass; the commit itself uses no `retry`, lock or injected IO. `restore` restores the incoming mask rather than guaranteeing `Unmasked`, and no `uninterruptibleMask` surrounds a session, an owner wait or a coordinator drain, and nothing waits for the diagnostics writer. This removes teardown-induced uninterruptible hangs; it promises no termination of trusted non-yielding Lua, a stuck native provider or a release that breaks its contract, and a timeout would prove neither completion nor permission to destroy a resource.

**What is raised.** The first committed role failure is that role's primary failure, and the session's first failure is the primary of the engine report, whatever cleanup fails afterwards. The exception record keeps `ExceptionWithContext`: on **every** caught exit, a cancellation included, the cleanup failures in its context are accounted before anything else, once each by their identity, so the same cleanup seen on a worker's completion and in a propagated scope context is one entry, and two distinct failures with the same text are two. An exception thrown *by a release* is a cleanup failure whatever its type, and so is one the timer's backend raises, which the timer raises as a failure of that backend's call; only an exception delivered to the driving thread is a cancellation. Wherever the session catches a failure of its own cleanup, a stop, a sink or a settlement, the cleanup failures that failure carries are accounted with it, each by its identity. If a cancellation arrived, the first one is raised as itself with every other retained exception and cleanup failure not already in its context beside it (kept raw, at most a bounded number of whole exceptions); otherwise the driver's or the construction's own exception is raised the same way; a normal exit returns the ranked outcome after accounting. A failure after a quit or an interrupt wins the outcome. An uninterruptible second stop that forces process exit is D-20's, outside this suite.

### The one commit

Every change to the session is one `Event` committed by one masked, non-retrying primitive (`commit`), and `step` in `Session.State` is the only function that changes a `SessionState`. In one STM transaction the event changes everything it means: the failure latch, the phase, the gates, the marker that an instance's failure was already told, the claim that an owner's completion is accounted, the evidence it carries and the identities that evidence already had, and the historical facts it proves (an `init` that succeeded, how a shutdown ended). The same transaction appends to the state the effects it owes: the stop of an owner whose admission it closed (`stStops`, coalesced by role) and the diagnostics it means (`stDiags`, each under a stable identity and *pending*, *in flight* or *interrupted*). Nothing the event means is left to a step after it, so a claim never precedes its payload.

* A **recovery or cancellation path only commits.** Completion accounting, unwind, captured cleanup, historical reconciliation and retirement use the primitive and run no effect: no probe inside it, no logger, no clock, no stop wrapper and no queue runner. The harness's probes sit beside the commit in protected boundary wrappers; what one raises or blocks with is retained, and the next mandatory step runs. A probe is never told again to retry the cleanup it observed.
* A **stop** is owed until its handoff succeeded or the owner's completion made it unnecessary; the finite stop pass (above) pays it, on whichever thread commits (a callback on an owner's thread, `requestStop`, the driver), and never waits for itself or writes anything.
* **Diagnostics never gate the lifecycle** (D-82/T4 as D-87 decides it). A diagnostic is *data* in the lifecycle record, under a stable identity and *pending*, *in flight* or *interrupted*, and the session's **writer** is the only caller of the sink: it claims a pending diagnostic (so no other caller issues the same attempt), writes it, acknowledges it.
  * **The start.** The writer is started in a masked step after the outer continuation is installed and before the first diagnostic. If it cannot be started that is a failure of the composition (a driver, caller or probe that throws, under T2), not of a sink, and a writer that was never started is never cancelled. It is not in the stop set and nothing in the stop pass touches it.
  * **While the session runs, and the forwarding point.** The driver, the callbacks, the stop pass, `requestStop`, `latchTerminalFailure` and the recovery commits only commit entries to the queue; none writes to the sink or waits for the writer. The writer drains the queue **continuously, including during the teardown**: this replaces the earlier rule that the driver writes, holds the queue from the first stop or failure to a final path and makes one final attempt. So a logger that holds a write holds the writer and nothing else: a stop is handed, an owner's end accounted, its drain proven, its releases run and its retirement published while it is held, ticks and updates go on, and the bounded failure record is available at once through `sessionOutcomeNow`.
  * **The writer is a state machine with one handler.** *idle* (waits for a pending diagnostic or for the cut-off) → *writing* (claims it, calls the sink; the only call in a session) → *delivered* (the sink returned and the write was acknowledged: not counted) and back to *idle*; or → *failed-undelivered* (the sink raised: one commit marks the diagnostic failed, which keeps it for the undelivered accounting, and records the failure; the writer ends); or → *cancelled-undelivered* (the sink's own cancellation, not the session's: the diagnostic is kept, interrupted, the cancellation is evidence, the writer ends); and from any of *idle*, *writing* or between two writes → *abandoned* (the cut-off): one handler at the thread's boundary wraps the whole loop, so the abandonment is caught wherever it lands and never escapes the thread to the process's uncaught-exception handler (which would write to a standard stream); an exception that is not the abandonment is evidence. Every non-success outcome (a synchronous failure, the sink's cancellation, an abandonment mid-write, an entry never claimed) is counted in the undelivered record, once.
  * **A failing sink is evidence.** A sink that raises, or whose write is cancelled, is counted in the outcome's `outDiagnostics` (`deSinkFailures`, the exact count, and `deSinkFirst`, the first entries, with the cleanup failures its exception carried; the texts are paid for out of the budget below). It is not a role failure: it never becomes the engine report's primary, never displaces or precedes another failure, takes no secondary-summary slot and no part of `erOmitted`, makes no diagnostic of its own (so a sink that always raises cannot loop), and neither closes the session nor ranks the outcome as failure. After it the writer makes **no further write to that sink**: what is meant later stays in the queue and is counted as undelivered at the cut-off. (The authored `print`/`warn` output sink, `sxOutput`, is another sink and is unchanged: its fault still ends the owner and the whole session.)
  * **The cut-off.** Once every role's retirement is published, or its unproven retirement committed as `stopping`, and before the outcome is read or an exception raised, the call commits the "session ended" note (unless it was cancelled), gives the writer the scheduler a bounded number of times (1000 yields and no clock: a poll that always ends, so that a writer that is not blocked can write the last notes; nothing depends on it), and then makes **one recovery commit** (`DiagCutOff`, with its cause) that closes the queue and records every entry not yet acknowledged (pending, claimed or in the sink) in the undelivered-diagnostics entry. After it a diagnostic the session produces is counted there directly (none is dropped), and a late acknowledgement or sink failure from the writer changes no outcome, status or history field. Each entry ends as exactly one of delivered or undelivered; an undelivered one may still have written bytes (no exactly-once output and no replay are promised). The entry is `deUndelivered` (the exact count), `deUndeliveredFirst` (the first messages, each cut visibly at a UTF-8 boundary) and `deCause`, all paid for out of the budget below, on every outcome kind (success and interruption included), through `sessionOutcomeNow` and after `runSession` returns.
  * **The cancellation.** The writer is cut off, never waited for: the cancellation is delivered from a helper thread (as the foundation's `requestCancel` delivers it), because delivery can block for as long as the writer is inside an uninterruptible region or a foreign call, so it never runs on the requesting thread; the session never uses `throwTo` or `killThread` on the driver for it, never cancels and waits, never uses a `withAsync`-style scope exit and never drains a worker group. An interruptible write is cancelled where it is; one inside an uninterruptible region finishes by itself and the writer ends then. On a cancellation of the caller the same steps run, at once, and the original cancellation then escapes (T5).
  * **After the call returns.** The writer can outlive the call, and so can the helper that cancels it, so the logger stays borrowed until they end: `sessionDiagnosticsEnded` says when, and whoever owns the logger (the assembly, which closes it after the producers have stopped) joins it before releasing it; a sink stuck for good is then the application quit watchdog's case, not the engine's (V-3). The writer's end, failure or cancellation never reaches the driver as a supervision delivery or an unexpected-exit failure, never becomes the exception that propagates and never causes a report on the driver's thread (it is not a supervised worker).
* The queues are bounded by the fixed set of roles, instances and transitions, and by the report limits, however long a writer stays stuck: no per-tick or per-update entry exists, repeated stop, repeated notice, sink failure or repeated cancellation cannot grow them, and an exception kept raw for the end is capped. **One bound, `EngineReportBytes`, for every text of the report and the evidence, for every validated profile.** The engine report keeps at most a first entry (cut to what is left of the bound once the secondary summaries are paid for, and never more than a record) and `SecondarySummaries` secondary summaries of `SecondarySummaryBytes` each; whatever is left of the bound, the evidence budget, is divided evenly between every text the diagnostics' evidence can keep (at most `SecondarySummaries` undelivered messages, half as many failed writes, and the cause), so the whole is within `EngineReportBytes` whatever order and mix the texts arrive in. A text is cut visibly to its share (at most `SecondarySummaryBytes`, the cause at most 256 bytes), or not kept at all when the share is nothing, as for a profile whose summaries fill the report; the counts are exact in every case. The smallest legal profile (a report of one byte, one summary of one byte) keeps the counts and no text. The evidence takes no secondary-summary slot and no part of `erOmitted`.

### Evidence and history

* **Evidence is counted by identity.** A cleanup failure the foundation retained carries an identity, issued once; the session accounts it once however many routes reach it (a worker's completion, a scope's context, the exception that carried it), and a distinct failure with identical text is a distinct entry. No exception is stringified to deduplicate it. The mark an exception carries (`Accounted`) tells the scopes of the run that made it not to account it again, and carries that run's own identity (never a counter that every run restarts): an exception another run raised, which this one catches and raises again from a callback or a nesting, is not one this run has accounted, and is accounted and raised as its own. The same holds for what the timer's backend raised (`BackendRaised`), which names the run whose timer it was: from another run it is an exception like any other.
* **History does not depend on the driver having seen it.** For every admitted instance the actual shutdown disposition and how it ended are kept once, and `initialized` is derived from the host's settlement that proves it (including an absent optional `init`), even if the instance went on to fail, was stopped or the driver was cancelled before it saw it run. `ShutdownSkippedNoInit` means no successful init; `ShutdownSkippedUnsafe` after a successful init does not undo it. A role is `initialized` only when every expected instance's init is proven. Facts are monotone, and teardown reads no clock, opens no gate and admits no tick.

### Stop and drain

`requestStop` is one commit and then the finite stop pass: it takes no request, task or result slot, and a second request changes nothing. Admission is closed *before* an owner is asked to stop, so a grant that raced it is refused or was accepted before it, and a content request is admitted only while the session takes new work, decided by a gate on the request policy in the transaction that admits it (a closure that commits between the facade's early read and the admission refuses the request for good, as an ordinary error a script may catch, never as busy). Work already inside a Lua segment finishes (nothing is preempted) and its calls to release, cancel and write output still work. Each eligible `shutdown` runs once, with `stopped` for a normal or peer-driven stop and `failed` for the instance's own failure, and is skipped for a failed `init` and where Lua is unsafe; a missing or failing hook never suppresses engine cleanup. A held provider read, a shared module job or a sink delivery keeps its role live and unretired until it retires, and the provider's guards, the anchored root and the sinks stay alive through that use.

### State, owners and lifetimes

| State | Owner | Writers | Readers | Thread | Lifetime and disposal |
| --- | --- | --- | --- | --- | --- |
| the session state (`SessionState`, one `TVar`) | the `runSession` call | every event is one transaction: the owners' threads (the dispatch hook, the failure and escalation callbacks, an engine failure), the driving thread (admission, `init` success, accounting, retirement, a fault, the unwind), any thread (a stop, the terminal latch) | the status, outcome and history endpoints, each facade's admission endpoint, the hook waiting at the dispatch gate, the driver | any | the call; none to dispose |
| the registry (`TVar Registry`) | the call | the driving thread, in the masked step that acquires a component, in the same transaction as `Acquired` | the stop pass, the retirement protocol | any, driving | the call; each component's finite release is run once by the protocol |
| the stops owed, the diagnostics and their states, the evidence identities, the markers (`stStops`, `stStopDefects`, `stDiags`, `stEvidence`, `stEarly`; in the session state) | the call | the one commit, the transition that means them; the writer (claim, acknowledge, interrupt, a sink failure) until the cut-off | the stop pass; the writer; the transitions that decide whether a settlement adds anything | any | the call; bounded by roles, instances and transitions |
| the diagnostics' evidence and the queue's cut-off (`stDiagEvidence`, `stDiagClosed`; in the session state) | the call | `DiagSinkFailed` (the writer), `DiagCutOff` (the call, once), and every diagnostic meant after the cut-off | the outcome (`outDiagnostics`), `sessionOutcomeNow`, the status and history endpoints (unchanged by anything after the cut-off) | any | the call; bounded as above |
| the diagnostics writer (its phase *open* or *closed*, its thread, whether it and the helper that cancels it have ended) | the `runSession` call, which starts it in a masked step before the first diagnostic and cuts it off after the last role has retired (or at once if the caller is cancelled) | the call (phase, cancellation), the writer's own thread and the helper (ended) | the writer; the call (`sessionDiagnosticsEnded`) | the writer's own thread; the helper's; any thread reads the end | the call, and then past it: **it can outlive the call**, which never waits for it. Its end is observable through `sessionDiagnosticsEnded`, and whoever owns the logger it borrows joins it before releasing the logger. It finishes the write in hand by itself only if the sink cannot be cancelled, and writes nothing more. It is not supervised, so its end never reaches the driver |
| the retained exceptions and raw evidence | the call | the thread that caught an exception on a protected path | the end of `runSession`, which composes what it raises | the driving thread | the call; capped |
| the pacing origin (`stOrigin`, in the session state) | the call | the transition that opens the start gate, once, from the clock reading taken just before it | the driver, which derives the schedule from it | the driving thread | the call |
| the seen set, the tracked instances | the call | the owners' threads (first hook), the driving thread (tracking) | the owners' hooks and callbacks, the driver | owners, driving | the call; at most two instances per role |
| the driver (mode, schedule, grant in flight, observed instances) and the pacing timer | the driving thread | the driving thread only | the driving thread | the driving thread | the `operate` scope; the timer's disposal is a registered session release |
| a role's coordinator, data bank, facade and owner | the role's scopes | the driving thread builds; the owner's thread runs in it | the services above | per owner | registered at acquisition; the owner's end and the coordinator's drain proved before any release |

### The order of a turn, a stop and a failure

| Sequence | In order |
| --- | --- |
| an instance's failure | the segment fails and the scheduler marks the task failed → at the boundary the instance layer begins the ending → **the coordinator is told** (one commit: failure latched, admission closed, the stops owed; the finite stop pass hands them over) → the `shutdown` hook (`failed`) → release and drain → the retirements providers owe (the ending waits parked) → the instance settles → the escalation (accounts what else failed, never a second failure) → the owner's accounting is acknowledged → the driver's wait for the tick's accounting returns → no further grant |
| a stop | one commit (flags, every admission closed, gates aborted or shut, every stop owed) → the stop pass (every owner asked to stop, every coordinator closed) → a running segment returns → each `shutdown` (`stopped`) → release and drain → providers retire → the owner's worker ends → the completion and settlements are accounted in one commit → the coordinator is proved drained → the role's releases run → `retired` |
| a tick | the timer is armed for the due time → the wake → the clock is read → the check of the logical role's admission and the acceptance of the grant, in one transaction → the grant in flight → the scheduler finishes it (or the owner ends) → the owner's accounting → the schedule advances (a deadline the clock cannot count ends the session) |
| startup | preflight → the roles built and registered → entries evaluated → admissions intended, issued, tracked → admission complete → each owner constructs and validates each instance and holds it → the dispatch gate opens → the driver releases every held instance → `init`s run → the driver observes the successes (or, for one it did not see run, the host's record of it) → the start gate opens in the transaction of the last success, with the clock reading taken just before it as the origin → the driver derives the schedule from the origin → ticks |
| an exit by an exception | the exception is accounted whole (the first failure the session knows) → the session closes → the stop pass → each role: completion and settlements accounted, drain proved, releases run, retirement published → the session-level releases → the cut-off: the "session ended" note (unless cancelled), a bounded poll of the writer, one commit that closes the queue and records what was not acknowledged with its cause, and the non-waiting cancellation of the writer from a helper thread (a cancellation of the caller does the same at once) → the exception raised |

### The host's seams (D-83, D-84, D-85, D-86)

Three of the five are hooks and opt-in, with a default of no notice and no hold (`instanceOnFailing`, `instanceHoldInit` with `releaseHeldInstance`, and `scheduledOnStartAbandoned`); the other two are additive exports with no default, no callback and no hold (`grantScheduledStepSTM` and the three parts of `awaitScheduledAccounting`), and every existing caller of either is unchanged. All are documented where they live, in [the Lua host](../scripting-lua/README.md). `instanceOnFailing` tells the application once, as an ending begins with a failure, with the primary failure alone, before the `shutdown`, the release and the retirements the instance's providers owe; the settled record `instanceEscalate` is told adds what else failed. The coordinator acts on the first (a finite commit and the stop pass, never a sink) and accounts the second. `instanceHoldInit` and `releaseHeldInstance` let the session validate every instance it admitted before any of them runs: the rest of the start is registered before the application is asked, a release is idempotent and coalesced into at most one resume job, and a stop wins over a late release. `scheduledOnStartAbandoned` (D-84) is told once on the starter's thread when a start that has not handed out an owner is abandoned, after its worker was asked to stop and before the starter waits for it; the session answers it with the closure and the stop pass, then the point `StartAbandoned`. `watchScheduledAccounting`, `scheduledAccountingStep` and `unwatchScheduledAccounting` (D-86) are the three parts of `awaitScheduledAccounting` as transactions, which is a wrapper over them with its behaviour unchanged; the driver observes the accounting of a finished tick in its one wait instead of blocking in that call. `grantScheduledStepSTM` (D-85) is an additive export, the scheduler's tick grant as a transaction (`grantScheduledStep` is `atomically` of it); it has no default and no callback. The driver reads whether the logical role takes ticks and grants in one transaction, so a closure committed before it is seen and a grant it accepts was accepted before a closure, whatever the closing thread has or has not yet handed its owner; no lock is held and the stop owed is not deferred.

### The harness

`Hetoimasia.LuaEngine.Session.Harness` is what a test composes. It is in a private sublibrary, `session-harness`, that no public library exposes and no one outside the package can depend on; the public `Hetoimasia.LuaEngine.Session` shows `Harness` as an abstract type and `noHarness`, so a composition outside the package can pass the one and cannot build another or read a field. None of it is reachable from a manifest or from Lua, and no real composition sets any of it. It names the points of a session's life (`Acquiring`, `Built`, `StartAbandoned`, `Intended`, `Issued`, `Tracking`, `Validating`, `Dispatched`, `Resumed`, `GrantIntent`, `GrantChecked`, `RequestChecked`, `GrantIssued`, `AccountingWait`, `WriterStarting`, `WriterStarted`, `WriterBetween`, `CuttingOff`, `WriterCutOff`, `WriterWait`, `Unwinding`, `Awaiting`, `OwnerEnded`, `Draining`, `Committed`, `Released`) so a test can hold the thread that reaches one, or make it raise, to place a stop or a failure in an exact window; a probe is never called with a lock held that a stop needs and never inside a commit, a release, the stop pass or a transaction: the points `GrantChecked` (told only with `ProtectGrantAtomic` removed) and `GrantIssued` lie outside the single transaction that checks and grants, and `RequestChecked` outside the admission of a request. A release (`harnessRelease`) is finite and may raise but must not block: it is how a test injects a failure of a registered release. It asks for the second instance of a role on the same VM that the design keeps for qualifying reusable bindings (never public spawning), which is admitted, constructed and validated like the first and counts toward its role's gates and status; it sets the tick counter's base, so the Lua integer ceiling is reached without granting 2^63 ticks; it hands the test what another party could do to an owner (stop it, cancel it); it can inject the loss of a settlement; it can run a chunk of Lua in a role's VM initialization, after the facade rebinds `print`, so that a test holds that role's start in its readiness wait by holding the authored output; and it can **remove one protection** (`harnessRemoved`; `ProtectOffDriver` puts the diagnostics back on the driver, `ProtectAbandon` makes the call wait for the writer, and `ProtectAcknowledge`, `ProtectKeepFailed`, `ProtectCancelEvidence`, `ProtectWriterCatch` and `ProtectWriterRegistration` each break one transition of the writer once), at one production site each, so that a negative control shows its proof detects the absence of that protection.

### What proves it

`Test.LuaEngine.Session.*` (group `test.lua-engine`) run real Lua on real supervised owners the coordinator starts, over a real content root, manifest, boot checkpoint, inventory and read pool, an injected clock and a fake timer, recording sinks and gates, and no sleep. The T9 families of D-82:

| Family | What it proves | Control |
| --- | --- | --- |
| `Model` | every gate, phase, admission, stop, evidence and retirement transition and the invariants after every step of every sequence of five events (atomic facts and claims, monotone history, no reopening, a stop owed until handed over or unnecessary, bounded effects, retirement eligibility, identities counted once); each text field of the failure record alone beyond its bound, every record bound from the schema's words up, the content identifier shortened last, and the failure each of the four events that carries one stores bounded; the diagnostics' evidence kept as a count and the first sixteen within the report's bound, and never a failure | each protection removed in a mutant of the transition, which the same checks detect; the content identifier left uncut, out of the record's count, or the events left unbounded, each detected |
| `Construction` | a throw or a cancellation before and after every acquisition of every role, the callback and the first diagnostic (a sink that fails it is evidence and the session goes on; a sink that holds it is cancelled, once, and the note recorded undelivered, when the caller is cancelled; D-87), and the diagnostics writer's own start (a failure at `WriterStarting` is a failure of the composition with the sink unasked and nothing built; a cancellation right after `WriterStarted` escapes with the writer cut off): every constructed owner found and stopped, every release run once and none for what was never acquired; an owner registered in the step that starts it; the peer stopped from inside an abandoned start while the starter's wait is held; the intent of an admission resolved when the probe beside its commit throws or is cancelled; a held module read, data read or sink keeping a role unretired | the registration put after the probe; the abandonment not told |
| `Startup` | validation before either init (an invalid second instance runs no init), a boot failure latched the moment its entry answers with its traceback, stop and failure on each side of every gate, a late success unable to reopen | (the host hold model, below) |
| `Stop` | every owner has its stop before the first wait, in either nesting, with either role slow (each barrier example holds the owner it observes outstanding, so the wait it names is certain to begin); waits stay interruptible through repeated cancellation; an entry refused when uninterruptibly masked | the barrier and the interruptible wait each removed |
| `Failures` | the other workers' failures a delivery carries, each accounted by its own worker's identity beside a failing owner of the session that supervision committed in the same batch (the primary's and the retained ones, once each); a provider's retirement held (the second instance's read, not returned by the pool) after a logical tick has finished: no further tick granted, the presentation role updating, every owner's stop receipt and the presentation role's history and retirement published without the gate opened, the logical role unretired, and a cancellation of the driver unwinding through the watched accounting; a logical failure retiring while the presentation role updates; a cleanup fault during that retirement stopping it; boot, presentation, one-role and provider failures, and a sink that raises for each of the lifecycle's diagnostics (D-87: evidence in `outDiagnostics`, never an entry of the engine report, beside the driver's failure and every retained cleanup); the terminal failure the guard latches, with each of its texts built far beyond its bound and with all of them, published within the record's bound; independently failing timer, local and outermost releases; quit, interrupt, an owner stopped or cancelled by someone else and a throwing driver in every arrangement of roles | the first-failure release attempts, and the release-source classification, each removed |
| `Evidence` | the first failure and attribution kept, bounds, ranking, the cleanup a cancellation carries counted by identity and once (equal text twice), the cleanup a failed release or the timer's backend carries accounted with it, and the cleanup a failing sink's exception carries kept in the diagnostics evidence (D-87), a release's asynchronous-typed exception as that cleanup, more than sixteen failures, a missing settlement as a fault of the host, the shutdown dispositions | the accounting of a cancellation's cleanup, and the raw completion, each removed |
| `Commit` | an owner's end, its evidence and its facts committed together, observed right after the commit; a composition failure with its cleanup; the stop cancelled right after its commit and paid by the driver; a probe that always fails not recursing or repeating; a sink that raises (D-87) written once, then no more, with the later diagnostics undelivered and the session going on; a diagnostic the writer holds when the caller is cancelled cancelled once and recorded as not delivered, not written again, with the unwinding stopping and retiring the owners meanwhile | the bundle split, and the recovery path allowed to write, each by removing the protection |
| `Diagnostics` | D-87's gated proofs, with the logger held at a gate the example owns and the facts read before it is let go: **a sink blocked during the teardown**, from before a stop, as an interruptible block and as an uninterruptible region (every owner's stop receipt, accounting, drain proof, retirement and the call's return complete with the gate shut; the outcome has the exact undelivered record, its first entries in order and its cause; opening the gate after the return lets the writer end, observed through `sessionDiagnosticsEnded`, and changes nothing the outcome, status or history show); from before a failure (latched, published, retired, the call returned); **a sink blocked while the session is healthy** (ticks and the presentation role's updates go on); **a sink that raises** (the session goes on and ends as it would have, the failure never primary and absent from the engine report, no write after it, the later diagnostics counted); **a free sink** (what was acknowledged before the cut-off is not counted); the first note, the diagnostic the start gate opened with a stop from another thread and no cancellation, a role's failure, an engine failure, the final note, the closure when the caller is cancelled (the write cancelled once, the cause recorded), each with the call returned; **the writer's start** (a failure before it exists is a failure of the composition, the sink unasked; a cancellation right after it is registered cuts it off); the module coordinator's warning and an owner's authored `print`, on the owner's own thread (both stops handed at once; the roles retire when the write returns); the authored output sink's fault still ends the session (`Failures`, *ends the session when the host fails while the entries are still being evaluated*); the logger is called in one place of the session sublibrary (`Boundary`); the writer transition by transition (*writing → failed-undelivered*, *→ cancelled-undelivered*, *→ delivered*, *idle → abandoned*, *delivered → abandoned*, each with the sink held or failed at a gate and synchronized on its entry or exit, the driver held at the cut-off, `CuttingOff`, until the writer is where the example means it to be); the smallest legal profile (counts exact, no text kept, the record within the one byte); the pure cut-off, the failed write kept, the report-and-evidence bound over five validated profiles down to the smallest, one example for each kind of text (the undelivered diagnostics and their cause before and after the cut-off, the sink failures, the cause alone, the report's first entry, the cleanup entries, the secondary summaries, all together), the undelivered record and its bounds in `Model` | the writer removed (`ProtectOffDriver`, the driver writes where it did): the whole session held at its first note, before anything is built, and both roles unretired though their owners ended; the abandonment removed (`ProtectAbandon`, point `WriterWait`): the call has not returned, though every role has retired, while the sink holds a write; each transition of the writer broken once (`ProtectAcknowledge`: what was written is counted as not delivered; `ProtectKeepFailed`: the diagnostic the sink raised for is missing from the record; `ProtectCancelEvidence`: the sink's own cancellation leaves no evidence; `ProtectWriterCatch`: the abandonment of a writer parked between two writes escapes its thread; `ProtectWriterRegistration`: the cut-off finds no thread to cancel, told by `WriterCutOff`) and, in `Model`, a cut-off that forgets the entries nobody had claimed; the cancellation delivered on the requesting thread (checked by hand): the uninterruptible examples fail |
| `Clocks` | exact ticks, the origin taken from the gate's opening and no tick delayed by a logger held at it, first in first out, no overlap, coalescing, the two origins, the Lua ceiling; no tick granted and no content request admitted once the closure has committed, even while nothing has handed an owner its stop (the closing thread held after its commit, the driver held while the tick runs) | the near-limit arithmetic in the model; the grant check and the acceptance made in two transactions (`ProtectGrantAtomic`); the request policy with no session gate (`ProtectRequestGate`); the driver waiting for the accounting by itself (`ProtectAccountingEvent`, point `AccountingWait`) |
| `Client` | a separately compiled client composes a session through public modules alone; the harness and its fields are out of its reach | the clients that must fail to compile |

and the host's `Instance.Behavior` and `Instance.Failure` examples (group `test.scripting-lua-runtime`) for the first two seams: every instance validated before any runs, a release that races the callback's return, repeated releases coalesced into one resume, a stop that wins over a late release or a late success, a callback that throws as a failure of the host, the early notice once and before the shutdown, and defaults that change nothing; with a model of the hold's three protections removed one at a time. The lua-runtime-tests examples `Scheduled.Creation` prove the D-84 field (the callback told once, after the stop request and before the starter's wait; a raising or asynchronous-typed callback kept beside the start's failure; the worker's own terminal failure kept beside it; nothing told when the start is not abandoned; the default unchanged), and `Accounting.Waits` the D-86 parts (the step is the completion the wait returns, composes with a caller's own state in one supervised wait, and clearing the watch is harmless when repeated), and `Scheduled.Settlement` the D-85 export (it answers what the grant answers, composes with a caller's own state in one atomic step, undoes the caller's write with a refused grant, and serializes a closure with grants decided from it).

## The session controls (LFE-26)

The facade binds three things to the [session coordinator](#the-session-coordinator-lfe-13), over narrow endpoints the coordinator
hands it and nothing wider: a copied status for the presentation role, a request for a normal whole-session stop, and the terminal
unavailable-state guard. They add no coordinator, no store, no queue, no event and no alias: there is no global `quit` or `status`, no
public lifecycle grant, restart, pause, per-instance stop, reason or exit code, and no change to the generic host or the runner.
D-70 (status), D-72 (quit), D-76 and P-73 sections 4 and 5 are normative.

```haskell
data SessionEndpoints = SessionEndpoints
  { endpointStatus   ∷ STM StatusSample                    -- one coherent, bounded, nonblocking read of the status
  , endpointQuit     ∷ IO ()                               -- a normal stop: idempotent, no slot, no result, never waits
  , endpointTerminal ∷ TerminalContext → IO Bool           -- the guard's latch; True the first time, which is when it writes
  }
sessionEndpoints ∷ Session → SessionEndpoints              -- requestStop session StopQuit, latchTerminalFailure, sessionStatus
```

A facade is given them in its `FacadeSpec` (`fsSession`); `Hetoimasia.LuaEngine.Session.Control` (pure) converts the coordinator's own
records into the plain samples the facade marshals, so a record the running Lua might never read (a fatal one, a module's, a final phase)
is converted and checked without a VM.

### What a script sees

| Spelling | Caller | Result |
| --- | --- | --- |
| `api.session.status()` | a **presentation** instance's `init`, update (any serving segment, a callback included) and `shutdown` | a fresh plain table, below |
| `api.session.quit()` | either role's instance, in `init`, update and `shutdown` | no results |
| `state(...)` and `api.state(...)` | anything, anywhere: a module's top level, every hook of both roles, after a quit, through any captured facade | raises the one fixed error, after latching the whole session's failure |

`status` and `quit` are exact zero-argument dot calls. An extra argument (an explicit `nil` included), a mistaken colon call, the wrong
role, a module's top level, and another instance's captured facade are **ordinary Lua errors** raised before the coordinator is observed
or a stop is requested (`pcall` catches them, and a healthy session stays healthy); what the facade checks is the running instance the
host names, never `api.role`, `api.content_id` or any field a script can overwrite. `state` is the explicit exception: it takes any
arguments, inspects none (no `tostring`, no traversal, no metamethod of theirs runs; the closure drops them unread), and no role, phase or
arity check stands before it. It is a global before any authored module is evaluated (the engine's initial chunk installs it) and the same
closure is every facade's `api.state`. Rebinding a global (`state`, `print`, `warn`) changes nothing a retained closure does.

### The status record

```lua
{
  stopping = false,
  gameplay = {present=true, initialized=true, phase="running", failed=false},
  presentation = {present=true, initialized=true, phase="running", failed=false}
}
```

| Field | Meaning |
| --- | --- |
| `stopping` | the whole session is stopping (a quit, an interrupt, a boot failure, a presentation or engine failure, the guard): **not** a failed logical role |
| `gameplay`, `presentation` | an absent role is exactly `{present=false}`; a present role always has `present=true`, `initialized`, `phase`, `failed` |
| `initialized` | the role's own `init` succeeded (every instance of it); historical, it stays true through stopping and retirement |
| `phase` | `"starting"`, `"ready"` (gameplay's `init` succeeded, the start gate is closed; **not** assets or game work), `"running"`, `"stopping"` or `"retired"` (published only after actual retirement under LFE-13) |
| `failed`, `failure` | `failed` is true exactly when the role has a latched failure, and then `failure` is present: `code`, `message`, `role`, `stage` always; `content_id`, `instance_id`, `path`, `traceback` only when known |

`code` is `lua_error`, `module_error`, `required_request`, `host_failure`, `cleanup_failure` or `state_unavailable`; `stage` is `module`,
`init`, `update`, `shutdown`, `request`, `cleanup` or `engine`; `role` is `gameplay` or `presentation`. A failed role is never `ready` or `running`.
No stack locals, authored payload, world, progress counter or recursive error graph is ever shown, and no instance is invented for module-only
work. Every text is the coordinator's, already bounded when its state took the failure in (message 2 KiB, traceback 8 KiB, opaque instance
identity 128 UTF-8 bytes, the whole record 16 KiB, each cut at a code point and ending in a visible `...`); the adapter rebuilds none of it, so
the copied status stays within the 16 MiB, depth 8 and 65,536-element ceilings (three levels deep, a few dozen elements). The **first** failure
of a role stays as the phase advances; a later cleanup error is in the engine report and can end the session, and the status shows no history.
The guard's own terminal failure is the session's, not a role's: it shows as `stopping=true` and in the outcome (`outTerminal`).

**The bounds the status needs are in the profile's own validation.** The status crosses to Lua under the profile's copied-value bounds like every
result, so a bound below the largest status record the profile's other bounds admit would be a promise the engine cannot keep. The derived
minimums count it (`minimumStatusBytes`, `minimumStatusDepth`, `minimumStatusElements`; see [the least each limit may be](#the-least-each-limit-may-be-hetoimasialuaengineprofileminimum)):
at least 3 levels, 30 values, and the bytes of two failed roles (491 and two failures' texts, `failureTextBytes` of the message, traceback, identity,
path and record bounds, never more than the record bound: 565 at the smallest bounds, 23,477 at the fixed profile's), so a validated profile refuses
a copied-value bound below them (`LimitBelowMinimum`) and the facade keeps `LimitBelowFormatting` as a guard that none reaches. The fixed M1
profile's numbers are unchanged (16 MiB, depth 8, 65,536 values).

### Sample timing

A presentation facade reads the status **once at the entry of every hook and every resumed segment**, in the same transaction that stores it
(`captureStatus`, wired by `facadeInstanceConfig` beside the presentation clock's sample, so a finite `init` and `shutdown` have captures of
their own, and a resumed update after a wait, a request wait or a yield has a new one, with its `dt` unchanged). A call to `status` never reads
the coordinator: it returns a fresh Lua copy of the stored capture. So every read inside a segment describes the same moment however the
coordinator changes meanwhile (**including a read after `quit()` in the same segment, which shows the entry's `stopping=false`**), editing
a returned table, nested ones included, changes nothing another read or another instance sees, and a long segment may keep an old capture.
Polling creates no subscription, wake, history or cross-VM synchronous call: an event-driven instance with no scheduled hook is not run
because the status changed, intermediate phases may be missed, and nothing waits for a request, a readiness, a retirement or the logical
owner. The gameplay facade never captures (logical Lua cannot read this wall-time-sensitive cross-role status).

### Quit

`quit()` calls the coordinator's idempotent normal-stop endpoint directly (`requestStop session StopQuit`): no task, request or result
reservation, no handle, no busy answer, no hidden queue. The endpoint closes the whole session's admission and every future logical tick grant
before the call returns, so a content request after it is an ordinary error (never `busy`) and a tick is never granted; release, cancel and
authored output stay available under their existing rules. Statements after `quit()` still run until the segment returns or yields, nothing
resumes after the stop is applied, a Lua error caught afterwards cannot cancel it, an uncaught error after it (or a shutdown or cleanup failure)
still makes the outcome a failure, an `init` that quits cannot open the startup gate even if it succeeds, repeated calls (shutdown's included)
reopen nothing and run no `shutdown` twice, and the caller never waits for the other role's owner, a held provider or any retirement.
Either role's request ends the entire session; an individual instance is ended through Haskell, not this operation.

### The unavailable-state guard

`state(...)` and `api.state(...)` are one terminal boundary, not an ordinary role failure. In this order, on the calling owner's thread:

1. **Latch.** `endpointTerminal` latches the whole session's failure and orderly stop (`latchTerminalFailure`): code `state_unavailable`,
   message `state service not available in this milestone`, the executing role, and the stage of the context that was running: `module` for
   any authored module's top level (evaluation resumed from an import chain included; no instance, and the content and **path** of the module whose code is running,
   read from the loader's canonical identity for it, so a dependency's guard names the dependency's path and not the entry that imported it), otherwise the running hook's
   `init`, `update` or `shutdown` with that instance's content and identity, and attributed to the executing instance even through another
   instance's captured facade. Nothing is latched before this, and a failure here is the host's.
2. **Claim and write, once.** Only the call whose latch answered *first* writes, through the session's own `Output` stderr sink (not the Lua
   `print`/`warn`, which a script may have rebound): **exactly one line, the phrase and nothing else** (no engine prefix; the sink supplies the line
   terminator), flushed under the output's lock like any authored call. The claim is the session's: one diagnostic across both VMs and both
   spellings, no retry loop. A sink that fails is the output's failure, fatal to the owner and not retried, and cannot lose the latch, which
   was committed first, or displace an earlier primary failure (an earlier failure stays the engine report's primary; the guard's is secondary). The authored write is interruptible, as every authored write is (a stuck sink must not make its writer uninterruptible): a hard
   cancellation of the owner that lands between the latch and the write loses the line and nothing else, because the failure and the stop are the
   session's and the outcome (`outTerminal`, the engine report) carries them.
3. **Raise.** The Lua closure raises the **string** `state service not available in this milestone`, with no position, as an ordinary
   catchable error. `pcall`/`xpcall` can catch it but cannot clear the latch, reopen admission, start a closed gate or turn the eventual
   failure into success. It is the same text whichever VM, phase or spelling.

A stronger host failure (the latch or the sink failing) takes the place of the Lua error. Signal installation, exit status 1 and the
second-signal force exit remain LFE-22's assembly work; this slice proves the outcome (`VerdictFailure`, `outTerminal`) consumed there. No
`state.create`, query, schema or store function exists.

### State, owners and lifetimes

| State | Owner and thread | Written by | Read by | Bound | Released when |
| --- | --- | --- | --- | --- | --- |
| a presentation instance's status capture (`StatusState`, one `TVar` map by host instance number) | the facade; STM | `captureStatus` on the owner's thread, at a hook's or resumed segment's entry, in the transaction that reads the coordinator | `status` on the owner's thread | one immutable sample per declared presentation instance | `forgetInstance`, or the facade's scope; a returned table is ordinary Lua with no obligation |
| the session-control endpoints (`SessionEndpoints`) | the facade, from `fsSession`; closures over one session | the session (`sessionEndpoints`), once per role's VM | the bindings | three closures | the facade's scope; they own nothing |
| the unavailable-state latch and its claim | the session's state (`stTerminal`) | `latchTerminalFailure` on any thread | the outcome, the report | one record, bounded by the state | the session; never reset |
| the hidden namespace's three bindings and the closures built over them | the VM; Lua | the initial chunk (once), the builder (once per instance) | the hooks | one set per VM | the builder takes itself out of the globals when taken; the closures are collected with the facade table |

### What proves it

`Test.LuaEngine.Facade.Control` (group `test.lua-engine`) runs the bindings over **injected** endpoints on real Lua in real instances: the exact
example and every phase, history fact, absent role and failure field and omission; the capture taken at entry (a change while the init is parked
in its output is seen by no read of it, and shutdown has its own); a returned table edited without effect; every misuse refused before the
coordinator is asked; the same refused for the wrong role, another instance's captured facade and a module's top level; quit from either role's
every hook; the guard from a module's top level, every hook of both roles, through a kept facade and after a quit, attributed exactly, with
cyclic and metatable-bearing arguments that no metamethod touches, with a rebound `print`/`warn`/`state`, with a failing sink (the latch is
asked for first and the line handed once) and with a failing latch (no line); the surface (`api` has exactly the added fields; no helper
namespace or global alias) and the bounds (`Facade.Limits`: the status record's least bytes, depth and values written out by hand and equal to the host's own
count of the largest record the fixed profile admits, each refused one below by the profile's validation, and the largest record read whole at all three
least values). `Test.LuaEngine.Session.Api` runs them over the **real coordinator**: the status at each hook of a session of the
presentation role alone, with the logical init held, and when `ready`; an ordinary logical failure shown with `stopping=false` while a held
provider keeps the role unretired and unchanged once it retires; a failure message cut at its bound; reads stable while a gated peer stops the
session; a refresh on resumption with an unchanged `dt`; an event-driven instance that is not run; two instances' captures; quit from both roles'
init, update and shutdown with every place taken, a held provider and a held peer (neither waited for nor falsely retired); and the guard caught
at a module's top level and in an imported dependency (both VMs claim one line, the path is the running module's), an update, both inits, a shutdown and an update after a quit, preserving an earlier failure,
with a held diagnostic (the latch precedes the write, and survives a cancelled caller) and a failing sink. `Test.LuaEngine.Session.Control`
checks the pure conversions with no VM, with the bounds. The Boundary and Client examples keep the package and its public clients in step.

## Deferred, by design

Not here, and not claimed: the CLI `run` dispatch and exit mapping (LFE-22), which will
consume the boot checkpoint and retain the same anchored root;
the concrete GPU upload and registration, native budgets, scene holds and the atomic publication of a prepared scene (LFE-17 to LFE-20), the public Lua graphics binding (LFE-21, [the graphics calls](#the-graphics-calls-lfe-21)),
the graphics service facades (the content, request, time and output surface is [the facade](#the-authoring-facade-lfe-12), the status,
quit and unavailable-state guard are [the session controls](#the-session-controls-lfe-26); the texture pipeline's typed endpoint is still its own),
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
the behavior selection's cadence rules and numeric boundaries, the boot checkpoint (see above), the request adapter (see above), the raw-data provider (see above), the module coordinator (see above), the texture pipeline (see above), the scene schema (see above), the authoring facade (see above), the session coordinator (see above), the session controls (see above), and this package's dependency and import boundary.
