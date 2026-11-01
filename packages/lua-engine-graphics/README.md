# Lua-first engine graphics adapter

Buildable package: `hetoimasia-lua-engine-graphics`, in `packages/lua-engine-graphics`
(LFE-17, [#532](https://github.com/coghex/hetoimasia/issues/532); the window provider, LFE-18,
[#533](https://github.com/coghex/hetoimasia/issues/533), [below](#the-window-provider-lfe-18)).

The concrete backend of the texture pipeline's port
([`packages/lua-engine/README.md`](../lua-engine/README.md#the-texture-pipeline-lfe-16)). A texture request
finishes only when its decoded level has been **uploaded and observed complete** and its **registration has been
observed to resolve to its own slot of a bound table**; only then does the backend answer
`sinkReady`, and the instance receives its opaque texture and the source dimensions. It works with no window and no
frame, on the protected graphics owner the host lends: the adapter starts no device, no window and no thread per
texture, instance or VM.

It depends on the pipeline's CPU port (`hetoimasia-lua-engine:texture`), the native backend, the window integration's
public host and the 2D renderer's Vulkan recorder. The CPU Lua-engine, content and codec packages depend on none of
it: this package is named only by `cabal.project.vulkan`, which also lists the CPU closure it implements a port of
(`packages/lua-engine`, `packages/scripting-lua`, `packages/content`). No sample, game, executable or other
component's test module is imported.

## Modules

| Module | What it is |
| --- | --- |
| `Hetoimasia.LuaEngine.Graphics.Texture` | The composition: `withTextureGraphics` over a borrowed host, the session's renderer and texture registry, the backend, identities. |
| `…Texture.Configuration` | The native configuration the fixed M1 profile maps to, and the checks of a host built for it. Pure. |
| `…Texture.Backend` | The state machine and its one pump thread, over a `Port`. Nothing in it names Vulkan. |
| `…Texture.Port` | The boundary to the graphics owner, as values: the seam the lifecycle suite injects. |
| `…Texture.Host` | The production `Port`, over a running `VulkanHost`. |

## Composition and ownership

```haskell
withTextureGraphics ∷ SceneSession → TextureGraphicsConfiguration → VulkanHostConfig scene → VulkanHost scene → (TextureGraphics → IO r) → IO r
```

* The **host and its owner** are the assembler's; the scope borrows them and unwinds inside them. The host must have
  been built with the configuration `configurationFor` maps from the profile (`configureHost`): the budgets, the uploads
  and `DeviceSurfaceFree`. `checkHostConfig` names what is wrong with one that was not, and `withTextureGraphics` raises
  `HostConfigurationWrong` before any texture work is admitted: a missing or undersized configuration is a structured
  startup failure, never a per-request `UploadOversized` that would look like the content's fault.
* The **renderer and the texture registry** are made once, in one owner action, by the bootstrap
  (`Render.makeRenderer`, `newTextures`) and exposed as the session's own (`graphicsRenderer`, `graphicsTextures`). A
  session has one texture table; a later scene adapter (LFE-20) must record through these and register nothing beside
  them. `Render.defaultConfiguration` is unchanged: this module selects its own `Configuration`
  ([budget mapping](#budget-mapping)).
* **Assembly waits** for the table's placeholder to be bound (`awaitBound`), interruptibly, so a failed owner ends
  composition. `HostSession` is the bootstrap's result; `graphicsPort` is the adapter seam, for a client that composes a
  further backend over the same session (the real-device suite gates one).
* The **backend** is `textureBackend`, the value a `withTexturePipeline` scope is given. The backend outlives the
  pipeline and every texture it delivered; `withBackend` is that scope.

### Owners, threads, lifetimes

| State | Owner | Writers | Readers | Thread | Lifetime / disposal |
| --- | --- | --- | --- | --- | --- |
| Backend state (`State`: jobs, textures, bootstrap, failure) | one `Backend` | the pipeline's decode worker (add a job), any thread that cancels or releases (one transaction each), the owner-thread actions (track what they made), the pump | any thread | STM | `withBackend`; empty at exit |
| The pump | the backend's worker group | — | — | one thread | started by `withBackend`; stopped after the drain |
| Renderer, registry, table | the session | the bootstrap action; later scene adapters | any (registry reads) | owner thread (constructions) | the session's managed resources |
| A native image | its job, then the table | the owner action that made it (records it in the job) | the pump | owner thread | destroyed by the owner once nothing holds it |
| A decoded level | the pipeline's lane | — | the backend until the copy ended | — | `sinkBuffersRetired` ends the borrow |

All native allocation, registration and release run on the owner's thread as bounded actions. The pump (one worker of
the backend's `Hetoimasia.Foundation.Worker` group) admits uploads (a copy into bounded staging, permitted from any
thread), reads tickets, and submits the actions. It waits **only in STM**, on the variable the next fact lives in: a
ticket, an action's outcome, the owner's standing, the bounded action queue itself (a refusal read in a transaction that
retries wakes when the queue changes), or the owner's recorded progress (`portWatch`: the GPU model changes when a
completion is recorded or a resource disposed). No timer, frame, Lua result poll, window or peer instance drives
progress. Sink calls are single transactions and never enter Lua.

## The readiness predicate

Success requires, in order, and observes each: (1) the checked image exists, recorded in the job by the action that
made it; (2) the exact bytes of the one RGBA8 sRGB premultiplied level were admitted and the **upload ticket was
observed `UploadComplete`**; (3) the table's **placeholder was observed bound** (read by an owner action, at the start of
an owner step, after the previous step's table refresh); (4) the image was **registered with the renderer's texture
registry with the decoded alpha classification as its cutout mark, and the table's published mapping resolves the
handle's index to the image's own non-placeholder slot at the handle's generation**. An allocated image, an accepted
ticket, a queue submission, a table handle or a placeholder resolution is not success. No second decode, mip level,
resize, format fallback or cross-request sharing exists.

The alpha classification is read from the borrowed level while it is borrowed (premultiplication never changes alpha, so it
is the decoded image's own `decodedBinaryAlpha`).

The opaque identity the pipeline carries is the handle's generation above its index (`textureIdentity`), so a stale
renderer index never names a later texture; `textureHandleOf` is its inverse for a scene adapter.

## Budget mapping

`configurationFor` reads a validated profile and refuses, structurally, what cannot be mapped. Nothing is tunable.

| Native configuration | Source | Fixed M1 value |
| --- | --- | --- |
| target records; frame slots per window; aggregate frame slots | `NativeTargetRecords`; `FrameSlotsPerWindow`; `FrameSlotsAggregate` | 2; 2; 4 |
| frame-less batches; generations per target; tracked images per generation | `FramelessBatches`; `GenerationsPerTarget`; `TrackedImagesPerGeneration` | 4; 2; 16 |
| accounted native bytes; objects | `NativeAccountedBytes`; `NativeObjects` | 2 GiB; 4,096 |
| reclaim pass; progress actions per turn; idle backoff | `ReclaimPassRecords`; `ProgressActionsPerTurn`; `MaximumIdleBackoff` | 64; 32; 100 ms |
| staging buffer | one maximum level for each lane (the largest legal RGBA8 level, 2,048 × 2,048 × 4 = 16 MiB, times 2 lanes) | 32 MiB |
| upload turn budget | a quarter of a maximum level; at least four bytes a texel of the widest image any device allows (128 KiB) | 4 MiB |
| upload queue | four for each lane | 8 |
| texture table capacity (initial = capacity) | instances × texture leases of one instance + slot 0's placeholder | 2 × 16 + 1 = 33 |
| lookup versions | aggregate frame slots + frame-less batches + 2 | 10 |
| ring; region window | twice the instance bytes (64 each) of every batch that can be in flight at 4,096 sprites; 3 × the scene sprite limit × 16-byte clip entries | 4 MiB; 192 KiB |

The sample's smaller configuration (a 1 MiB staging buffer, a 16-slot table) is not the engine's: it cannot admit the
approved 16 MiB level. `accountingNativeBytes` is the sum the configuration asks of the native byte budget at its most
— staging, ring, lookup versions and the nominal bytes of every texture a session may hold — and must fit the profile's
accounted native bytes. These are charged once each: the decoded level is the pipeline's CPU payload (charged to its
lane until `sinkBuffersRetired`); its staging copy is the native accounting's until the upload completes; the texture's
image is charged for its lifetime; a view of a level is never charged again; the pipeline's nominal-bytes and slot banks
are separate obligations returned only when the table proves a texture retired. A constrained device is not promised
every maximum allocation at once: a native budget that answers backpressure is retained work, below.

## Invariants (the D-80 table)

Every site that reserves, tracks, transfers, settles or publishes, and what makes the invariant hold there.

| Window | Owner / resource | Terminal authority | What makes it hold |
| --- | --- | --- | --- |
| admission → tracking | the job (borrowed level) | the job's terminal event | `backendUpload` records the job in the same transaction that decides acceptance; cancellation finds it from then on. |
| intent → issuance (allocation) | nothing native yet | — | a job cancelled before issuance is settled with no native call. |
| allocation → tracking | the new image | the job, then disposal | `allocateAction` records the image in the job **inside the same masked owner step** that made it; a job already gone discards it on the spot. |
| copy into staging → borrow end | the pipeline's level | `sinkBuffersRetired`, once | `portUpload` copies before it returns; the ticket is recorded in the same masked step; the borrow ends there, or at job end when no copy began. |
| registration → tracking | the table's handle | the job, then disposal | `registerAction` records the registration in the same masked step; a job gone releases it on the spot. |
| registration → lease transfer | the texture record | `SinkTaken` / `SinkLate` | the record exists before `sinkReady`; `SinkTaken` makes the release the lease's (once); `SinkLate` leaves the texture the backend's, disposed like any undelivered one; a release that arrives while the answer is in flight is recorded and applied on `SinkTaken`. |
| final success publication | the pipeline's texture | the pipeline | a cancellation after `SinkTaken` erases nothing; one before it wins and the texture is released. |
| cancellation | any phase | one `sinkWithdrawn` after disposal | the flag finishes the step in flight (issued work cannot be recalled), then the job is taken apart in dependency order: registration through the table, else image discard; an unstarted upload is cancelled. |
| faults | any phase | one `sinkFailed` after disposal | a fatal fault (`FaultFatal`, `AdmissionFault`, raised action, device loss) is `sinkFailed`; a cleanup failure is appended to the primary and latched as evidence; pressure (`FaultPressure`, `AdmissionPressure`, a full queue) retains the job. |
| release | a delivered texture | `ProviderComplete` / `ProviderFailed` | the logical release is marked at once; the table release is queued through the hold-gated lane; the retirement reading is the table's, read by an owner action; a repeated release repeats nothing; a failed cleanup is not retried. |
| owner end | every job and texture | `sinkFailed` / `ProviderFailed` | nothing is claimed reclaimed that was not proved: the owner's own teardown retires what it made. |
| backend close | outstanding work | the drain | admission closes; jobs are cancelled; unreleased textures are released; the drain waits in STM, remembers a cancellation delivered meanwhile and raises it after. |
| pump failure | outstanding work | `sinkFailed` / `ProviderFailed` | every job is told once; textures are reported failed to retire. |

## Readiness, cancellation, faults, pressure

* **Cancellation** is a flag, not a state: the step in flight finishes, then the job is taken apart in dependency order.
  A cancelled job answers one `sinkWithdrawn` and one `sinkBuffersRetired`, never a success, and leaves no image,
  registration or upload. A success that was handed over is not erased; a cancellation that wins suppresses delivery.
* **Faults keep their severity.** Device, allocator, provider and cleanup failures are `sinkFailed`; the pipeline
  latches them as its failure for required and optional requests alike. They are never an image error, a
  cancellation or a retry. `Refusal`s other than `RefusedBackpressure` are faults; a late `SinkLate` is counted, not
  fatal.
* **Pressure retains accepted work.** Native backpressure (an allocation or registration that answers
  `RefusedBackpressure`, a full upload queue or staging, a full action or release lane, no free table slot) leaves the
  job, with its reservations, until the owner's recorded progress moves: no re-read, no re-decode, no restart, no
  busy answer, no extra thread. The wake for a pressure answer is taken **before** the attempt, so a relief that lands
  between the attempt and the reading of its answer is not lost.

## Release and retirement

A delivered texture's `textureRelease` (called at most once by the lease) marks the logical release in the registry at
once, for a publication's check, and asks the table to release through `requestVulkanRelease`: the owner runs it only
once every scene target — each window, and each offscreen target registered with the host (LFE-27) — has adopted the scene revision that was current when it was asked. **That lane, with the scene
ledger, is the single hook through which the holds a published scene takes gate the table release**: the release action
reads the ledger on the owner's thread (`deviceHeld`), where the lifecycle hooks that write it run, and releases the
table's handle only when no adopted revision holds the texture. A held release is not a failure and not a retirement:
the texture stays `held` (released for new use, charges kept) and the backend asks again, through the ordinary action
lane, when the last hold ends (`portHeld`, read in the transaction that decides, so the end of the last hold wakes the
pump). The ask goes through the barrier lane again, not the ordinary one: the last adoption can end with its window still
retaining the revision it adopted (a replaced target leaves the published scene for the next attachment), and a request's
barrier waits for a live target of every window that has published. The release is nonblocking and distinguishes *requested* from *retired*: the reading
answers `ProviderComplete` only when the release ran on the owner's thread **and** an owner action read the table with the
texture's slot no longer retiring (no live version a batch holds maps it). A request, an acknowledgement, a dropped
reference, a worker exit or the end of a CPU scope is none of these.

## Teardown

`withBackend` exits in dependency order: admission closes; every unfinished job is cancelled and taken apart (registration
released through the table, else image discarded) and answers its terminal event; every texture nobody released is
released; the drain waits (in STM, outside any uninterruptible release) until every job has answered and every texture is
proved retired or failed; only then does the pump stop, and only then may the pool, the inventory and the host unwind. A
cancellation delivered meanwhile is remembered and raised after the drain. Ending one instance neither closes the shared
owner nor touches a peer's independent texture.

## Tests

* **`lua-engine-graphics-tests`** (headless; group `test.vulkan-headless`): the backend over an injected owner whose
  action execution, upload start and completion, table binding and slot reclamation are each held or let go by the
  example — every stage of a request withheld in turn, cancellation at each boundary, faults, pressure, release and
  retirement, teardown, the budget mapping, and the composition with the real read pool, decoder, pipeline and a real Lua
  owner. Evidence from the fake owner is injected evidence and says so; it proves ordering and ownership, not texels.
  `cabal test` is not the command: `bash tools/vulkan/run.sh test hetoimasia-lua-engine-graphics:test:lua-engine-graphics-tests`.
* **`lua-engine-graphics-native-tests`** (a real device, no window; group `test.vulkan-lua-engine-native`): the production
  host started without a surface; a small asymmetric PNG loaded through verified reading, bounded decoding and the
  production backend and, after success, drawn through the session's one table and renderer in a frame-less offscreen
  batch and read back (the render-2d oracle's every determinate pixel and four hand-stated corner probes for orientation
  and alpha); the largest legal level, 2,048 × 2,048; two instances' independent textures with one ended; a delayed
  completion and a cancellation through a gated port; and the model's accounting returning to rest. It reimplements the
  native-suite rules (main-thread session, cleared ambient environment, post-teardown verdict, destruction order,
  consent, qualified loader). Build and run:

  ```sh
  bash tools/vulkan/run.sh build hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests
  bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests          # Linux
  HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests   # macOS
  ```

  The run writes `lua-engine-graphics-native.md` into `HETOIMASIA_VALIDATION_EVIDENCE` when set: revision, source
  digest, command, platform and driver manifest, validation outcome and the accounting each example measured. A run
  without consent refuses and exits non-zero; a skipped run is not a pass.

  Its `Lua offscreen pixels` group (LFE-24) draws what Lua authored into a managed offscreen colour target with no window and
  judges every pixel; see [Lua offscreen pixels (LFE-24)](#lua-offscreen-pixels-lfe-24). Its device-free half, the `Lua
  offscreen pixels comparator` group, is in `lua-engine-graphics-tests`.

## The window provider (LFE-18)

`Hetoimasia.LuaEngine.Graphics.Window.*` answers a request for **one instance-owned window** asynchronously. It is a
composable typed endpoint, not a Lua API: the eventual graphics facade (LFE-21) validates the Lua table with
`askWindow`, builds its binding from `startWindow` beside `windowArgumentCheck`, registers the handle type `window` over
its `Leases`, and binds nothing to release (M1 offers no independent close, reopen or release: the window lives until
its instance ends or the session quits). The agreed call is `api.window.open({title = TEXT, width = INTEGER, height =
INTEGER})`; every field is required; success is **the owned window handle itself**, not a table. The CPU Lua-engine and
content packages stay free of GLFW and Vulkan: everything here is this package's, over the host's public modules.

| Module | What it is |
| --- | --- |
| `…Window.Request` | Pure: the title and size rules (`windowRequest`) and their refusals. |
| `…Window.Port` | The boundary to the hosts, as values: the seam the lifecycle suite injects. Opaque tokens, never reissued. |
| `…Window.Provider` | The provider (`withWindowProvider`), the owner slots, the service, the endpoint, the state machine and its one pump, the main-thread step. |
| `…Window.Host` | The production `Port`, over a running `VulkanHost`; yields `WindowTarget`, the right to publish a scene to one window's incarnation. |
| `…Window.Configuration` | What the fixed two-window profile asks of the host (`configureWindows`, `checkWindowHost`). |
| `…Window.Session` | `sessionWindowConfig`: the provider's stop and fatal endpoints as the real coordinator's (`requestStop … StopQuit`; `latchTerminalFailure` with `cleanup_failure` for a failure of retirement and `host_failure` otherwise, presentation role, engine stage). |

### Validation before anything is reserved

* **Title**: valid UTF-8, at most **512 encoded bytes**, and no Unicode general category `Cc` character (U+0000–U+001F,
  U+007F, U+0080–U+009F), checked in that order. The empty title is allowed. The host itself refuses only NUL; the stricter
  rule is the adapter's.
* **Width and height**: whole values `1..4096` in native window screen-coordinate units, taken as the Lua integer subtype
  (`Int64`; an integral float is refused by the binding). They are preferences, never observations of an actual logical
  or framebuffer size. The range is checked before any narrowing to the host's `Int`, so a value beyond Int32 or Int64 is
  refused whole, never wrapped or clamped.
* **Role, phase, identity**: acquisition is presentation-instance hook work. A logical instance, a wrong phase, a
  closed owner, a foreign owner and a stopping provider are ordinary Lua errors (`windowArgumentCheck`, then the
  admission's own checks), decided before any bank is asked and with no native work.

### Admission

One atomic admission reserves, before the provider is handed anything: the request and result records and places (16
per instance, 64 per VM, the host's), the result lease capacity, **the instance's one window slot**, and **one of the
provider's bounded work records** (`windowRecords`; two for the fixed profile).

| Credit | Full means | Returned |
| --- | --- | --- |
| window owner (nothing is reserved) | the owner or provider has ended: permanent refusal | n/a |
| window slot | the instance already has a pending, live or retiring window: **permanent** error, decided first so a full temporary bank never turns it into busy | by the pump, at **actual retirement** (graphics and native), never by the host's return of a credit and never by a lease's release |
| window records | busy (the host's answer, naming the bank): no command, no partial credit, no hidden retry | when the host returns the request's record |

An already occupied slot stays the permanent second-window error even when the records bank is full; a busy answer
leaves no latent failure and nothing issued. Once accepted, downstream pressure (the host's bounded command queue, a
deferred announcement) keeps the accepted work pending and bounded: it is never a busy refusal and never an unbounded
queue.

### The state machine of an acquisition

```
Queued ──issue──▶ Issued ──created──▶ Open ToAttach ──main thread──▶ Open Attached ──standing usable──▶ offered ──▶ adopted by the lease
   │                │                                                       │
   │                └─ refused clean ▶ window_error                         └─ refused clean ▶ window_error, then close
   └─ cancelled before issuance ▶ retired (no native work)
every Open state ──(cancel | instance end | session stop | refusal | fault)──▶ close begun ──▶ graphics retired ∧ native disposed ──▶ retired
```

* **Create and attach before publishing readiness.** A visible, decorated, resizable, no-client-API window is created by a
  command on the host's bounded queue (executed on the main thread by its owner loop). The creation token is tracked from
  the moment the command is issued, so an uncollected ticket never makes an untracked window. The graphics handover
  runs on the process main thread, from `windowMainStep` (the owner loop's turn), and a deferred announcement is repeated
  on the **same attachment** by the same step: no second surface or window is ever built to retry an accepted stage.
* **Readiness** is the graphics owner's own answer for the attachment (`readTargetStanding == TargetUsable`, with the
  attachment still attached) and the capability to publish a scene to **that window's incarnation**
  (`WindowTarget`), read in the transaction that decides to offer the result. `WindowCreated`, an attachment, a handover,
  a deferred announcement and an allocated surface are not success. No texture, authored scene, acquired frame or
  presentation is required; a minimized window may be ready while drawing is suspended.
* **Publication.** The result is offered as a resource the host builds, on the owner's thread, into the lease the request
  reserved: the reserved capacity becomes real lease tracking in the same step that publishes the result. The resource is
  opaque and the instance's alone; it carries only the publication capability, no native control, input reader or
  disposal authority. It is valid whether or not Lua ever takes the request.
* **An offered result nobody builds.** The host reports a provider's work over when it accepts a resource reply, so a
  cancellation (or any end of the request) that wins before the lease builds the resource reaches no `workCancel`, and the
  settled result may stay unread. The provider therefore reads `submissionSettled` (a narrow read-only STM field of the host's
  `Submission`) for every acquisition it has offered and that no lease has adopted: settled and not adopted means no lease will
  ever own it, so the pump ends it (close, retire, slot), independent of the result being taken or discarded. The adoption
  marks the acquisition adopted before the request settles, so a window the lease took is never mistaken for one it did not.
* **Cancellation** that wins withdraws interest and settles `cancelled` with no required-failure latch. If success settled
  first, `cancel` answers `already_settled` and cannot close the window. A late success is suppressed and every partial
  acquisition is retired safely; native work already issued is allowed to finish far enough to retire (a command ticket
  cannot be retracted, and its future client capability is not discarded). A cancelled request's final result still
  follows take-once consumption.
* **Retirement** is two separately observed outcomes: graphics use and the attachment retired (`SlotFree`), and the native
  window destroyed (`WindowReleased`). A close ticket, a cancellation acknowledgement, a worker exit, CPU scope exit or a
  timeout is neither. A release that failed is recorded, fatal, never attempted twice and **never frees the slot**.

### Close: user versus cleanup

A **genuine** native close request is the newest `CloseRequest` in the window's **own** observations (a per-window
increasing number latched only by the native close callback), observed from the window's creation until it retires: while
the request is pending, before root `init` returns, with the startup gate closed, and while a cleanup close is racing it.
It is routed to the session's idempotent, slot-free stop endpoint (`windowStop`), which closes admission before further
work can escape. Lua cannot veto it. Per-window state is the newest number routed; the provider never clears a request
(`rejectHostCloseRequest`) and never routes the same number twice. `WindowClosing`, `WindowEnded`, a native destruction
notice and any close the provider itself begins (cancellation, instance end, a refusal, session stop) are **never** a user
close, so ending an instance neither synthesises a session quit nor ends a healthy peer. Signals and exit codes are not here.

### Error classification

| Outcome | Becomes |
| --- | --- |
| `WindowCreationFailed` after a clean rollback; `VulkanHandoverRolledBack` with `RollbackSafe`; a target the owner rolled back with `TargetUnusable False` and a recorded surface rejection (`TargetSurfaceUnsupported`, a surface not created or unusable) | expected required failure `window_error` (message bounded to 2 KiB, no root or path), latched even if unread, at the next safe scheduler boundary; the session policy (#527) applies it. Its role failure is `required_request` at stage `request`. |
| `VulkanRootsNotReady`, `VulkanAnnouncementDeferred` | bounded waiting on the same window and attachment |
| `VulkanOwnerClosed`, `VulkanHandoverSuperseded`, `GraphicsAdmissionEnded`, `GraphicsWindowClosing`/`GraphicsWindowUnavailable`, a creation `NotExecuted`, `StandingEnded` | the cancellation, stop or cleanup path; never `window_error` |
| `RollbackUnsafe`, an interrupted creation ticket, partial or unverified construction, `VulkanSessionFailed`, `VulkanDiagnosticPending`, `VulkanHandoverUnavailable`, `GraphicsSlotUnavailable`, `GraphicsWindowOccupied`, `GraphicsForeignSession`, `WindowCapacityReached`, `WindowCreationPoisoned`, `WindowConfigInvalid` after the adapter's validation, a failed disposal, a failed owner | **fatal**: latched once, handed to `windowFatal` (the session's terminal failure); never `window_error`, busy or a retry |

An outcome that fits none of these returns to the manager rather than being classified ad hoc.

### Test seams (production uses none)

`ProviderHooks` (`withWindowProviderWith`) holds a step at a precise place: `hookBeforeAdopt` runs inside the adoption recipe after
the host claimed it, which is how the examples settle a request by a real epoch change while its claimed recipe is held. The
recipe itself tolerates a window already taken apart and forgotten (the host may run a claimed recipe after the request
settled): that is ordinary cancellation, built over the same window and released at once by the host, never a host failure.
The window request is required, and the examples run it that way. A required request's failure ends its instance at the end of
the invocation that is running when the request settles, whether the script read it or not. A script already inside that
invocation can still take the result: the example holds one invocation at a gate of its own (`fx.block`), lets the provider
settle a clean refusal meanwhile, then resumes, finds the request ready and takes the exact record
(`{status = "failure", error = {code = "window_error", message ≤ 2 KiB}}`, no root or path), and the instance then fails,
attributed to the `window` endpoint. M1 offers no optional window to Lua.

### Failed effects and exit

A synchronous failure of an effect the pump ran (an issue, a close, a stop routing, an answer) is never repeated: that
acquisition is recorded as unretryable, exactly as a failed retirement is (evidence kept once, slot kept, drained through the
protected host), and the fault is handed to the session once. An acquisition in that state is terminal for the pump, so the
worker can stop; a fault latched during an otherwise orderly run is still raised by the scope's exit. When the host's command
queue refuses an issue or a close, the acquisition waits on the queue's **room** (`portQueueRoom`, the capacity itself:
`pending < capacity`), not on a change of it, so a queue that filled and drained between the refusal and the wait cannot be
missed. A pump that itself fails (an observation that raises, an asynchronous interruption) closes admission and leaves every
acquisition as retained terminal evidence, slot held and no retirement claimed, so the drain and the protected host's teardown
proceed instead of waiting for a thread that is gone. An **interrupted or otherwise uncertain creation** (`CreateFatal`) is the
same terminal evidence, never a retirement: it may have registered a window or failed its rollback. `endWindows` is the session-stop action: it ends every window (adopted or not) and closes
admission, idempotently and without waiting; the scope exit runs it before its drain.

### Owners, threads, lifetimes

| State | Owner | Writers | Readers | Thread | Lifetime / disposal |
| --- | --- | --- | --- | --- | --- |
| Provider state (`PState`: acquisitions, prepared requests, records count, fatal latch) | the provider scope (`withWindowProvider`) | admission and credit returns (STM), the host's `workCancel`, the pump, the main step, the lease's adopt and release | any | STM | the scope; the drain waits until every window retired or failed to |
| An acquisition | the provider | the same | the pump; the lease's retirement reading | STM | admission to the pump's return of its slot, which is its removal |
| The window slot (`WindowOwner`) | one UI instance's bindings | admission (reserve), the pump (return) | admission, the argument check | STM | until the window's actual retirement |
| The pump | the provider's worker group | — | — | one thread, never the main thread | started by the scope, stopped after the drain |
| The main step (`windowMainStep`) | the application's owner loop | — | — | the process main thread | one bounded step per turn |
| The production port's tables (creation tickets, windows, services, close tickets) | the port | the pump and the main step, by transactions | the pump | STM | a ticket is consumed by the transaction that reads its outcome; a window's record by the one that reports its retirement whole (a failed one is kept as evidence); identities are never reissued |
| The window resource in the lease | the requesting instance | the adoption recipe | the later scene adapter, through the lease | owner's thread | until the lease releases it (instance end) |

The pump waits only in STM, on the variables the next fact lives in (a creation ticket, a standing, a window's own close
observation, a retirement reading, the host command queue's statistics for pressure). No timer, frame, Lua poll or peer
drives progress; a window held up in retirement never blocks the service of another.

### Invariants (the D-80 table)

| Window | Owner / resource | Terminal authority | What makes it hold |
| --- | --- | --- | --- |
| admission → record | the credits | the pump (slot), the host (record) | all three credits are reserved in the host's one admission transaction or none is; a request the endpoint never received returns its slot in the credit release (no acquisition exists) |
| accepted → issuance | nothing native | — | a request cancelled while `Queued` retires with no native call |
| issuance → tracking | the creation token | the acquisition | the token is recorded in the same masked step that learns it; a full host queue is recorded as a wait on the queue's progress and re-issued, never lost |
| creation → handover | the native window | the acquisition | the host registers the window before its ticket settles; the ticket's outcome is read and the window token recorded in one pump transaction |
| handover → announcement | the attachment, its surface | the host (`announceVulkanTarget`) | a deferred announcement stays attached under bounded progress and is repeated on the same attachment |
| announcement → admission | the owner's target | the owner | success reads the owner's standing, never the handover |
| admission → publication | the target capability | the lease | the success is claimed in the transaction that reads standing and the capability; a cancellation after it suppresses nothing the lease owns, one before it wins and the window is taken apart |
| publication → adoption | the offered resource | the lease or the provider | a build the host never ran leaves the window with the provider (`workCancel`, or the credit's release), which takes it apart |
| cancellation | any phase | the acquisition | interest is withdrawn; the step in flight finishes; the window is closed once and retired |
| close request | the window's observation | the stop endpoint | read in the transaction that decides what else the window needs; routed before cleanup continues; the newest number routed is remembered |
| retirement | graphics, native | the pump | both observed separately; a failure is fatal and keeps the slot |
| slot return | the owner's slot | the pump | at the transition to retired only, idempotent, never by a credit or a lease's release |
| provider close | every acquisition | the drain | admission closes; every window, adopted or not, is taken apart; the drain waits in STM outside any uninterruptible release; a cancellation delivered meanwhile is remembered and raised after |

### Tests

* **`lua-engine-graphics-tests`** (group `test.vulkan-headless`), `window provider`: the pure rules, the host
  configuration, the provider's endpoints on a **real** `runSession` coordinator (a genuine close during pending setup with the
  records bank full ends the session as a quit; a failed destruction and a fatal creation latch `cleanup_failure` and
  `host_failure`; the roles run an empty behavior, because the Lua binding that opens a window is LFE-21's), and the provider
  over a gated fake port inside the real composition (real admission, real leases, a real
  supervised Lua owner): admission and its banks, every stage held separately, cancellation at each stage and both
  settlement orders, instance end, retirement gated on graphics and native independently, close routing and its races,
  failures and pressure. The fake is injected evidence: it proves ordering, ownership and routing, never a window.
* **`lua-engine-graphics-native-tests`** (group `test.vulkan-lua-engine-native`), subgroup **`window provider`**: two real
  windows for two instances on one protected host, each success followed by the owner's admission and an empty scene, one
  instance ended with the peer usable, a cancelled real creation with its late native result closed, and a genuine native
  close made through the test-only driver `Hetoimasia.GLFW.NativeCheck`. Run it alone with
  `bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:lua-engine-graphics-native-tests -- --match 'window provider'`
  (on macOS `HETOIMASIA_NATIVE_SESSION=desktop` on that command; on Linux the runner starts its own X11 display). It
  claims no visual pixel and no completed GPU frame.

## Scene publication (LFE-20)

`Hetoimasia.LuaEngine.Graphics.Scene.*` publishes a prepared scene (LFE-19) to the caller's ready window, keeps the
textures it names alive through the owner's adoption and every frame that used them, and records each frame with that
frame's own metrics. It adds no Lua API: the facade (LFE-21) installs `api.scene.publish` over `graphicsPublishBinding`.

| Module | What it is |
| --- | --- |
| `…Scene.Ledger` | `GraphicsScene` (the host's per-window scene), `SceneLedger` and the lifecycle hooks (`ledgerLifecycle`): what the adopted revisions hold, with the adoption count of each scene target and revision. The ledger is keyed by the host's `SceneTargetKey` (LFE-27): a window, or an offscreen target registered with the host, in one key space. |
| `…Scene.Publish` | The publication boundary (`publishScene`), its refusals, and the binding (`graphicsPublishCheck`, `graphicsPublishBinding`). `offscreenTargetAnswer` is the host's answer to a publication to a registered surface-free offscreen target, for a target-side port to compose with `scenePublisherOver` (LFE-27). |
| `…Scene.Render` | The pure frame of an adopted scene for a frame's own metrics (`frameCandidate`) and the `VulkanRenderer` that records it. |
| `…Scene.Configuration` | The scene part of the host's configuration (`configureScenes`), `SceneSession`, and the maximum-legal-scene check (`sceneCapacity`). |

`withTextureGraphics` takes the `SceneSession` (made before the host is built) and fills the renderer's slot with the
session's renderer and registry. The assembler builds the host with `configureHost`, `configureWindows` and
`configureScenes`; none reads the others' fields.

### The commit point, authority and lock protocol

`publishScene windowKey prepared` is the one place authority is checked and a scene becomes the host's. In order, all
inside the borrows:

1. the window lease is borrowed (`withWindowOr`): ended, another instance's or another kind of handle is refused;
2. every distinct texture the scene names is borrowed through the instance's own lease (`withTextureOr`) and its
   identity and dimensions compared with the prepared ones. **The borrow is the pin**: a borrowed member cannot be
   retired (the collection answers a retirement as in use), so no release of a texture the scene names can run between
   this check and the host holding the scene. A prepared identity of a released texture, even one whose index was reused
   under a newer generation, is not that texture;
3. one transaction reads the instance's and the provider's admission, the window's incarnation (`targetUsable`) and the
   renderer registry's own flag for each texture's exact handle and, **in the same transaction**, makes the scene the
   window's latest value (`targetPublishSTM`; it never waits). A stop, closure or ending instance that lands before
   that transaction refuses the whole publication; one that lands after it finds the scene already the host's.

**Acceptance is step 3's write.** Before it the call has changed nothing; after it the scene is the window's, owned by the host
until it is adopted and then by the ledger until it is released, whatever happens to the caller. The two valid race
outcomes are the specification's: if the publication wins, the whole scene is accepted and a later release or end honors
its uses; if a release, end or closure wins, the whole new publication is refused and the previous scene stays. A
released handle is never usable again because an older scene holds its image.

Lock order: the collection's borrows (window, then each texture in prepared order) outside, the host's snapshot
transaction innermost. No lock of this package is held across a GPU wait, native teardown or a callback into Lua.

### Accepted, adopted and in-flight

| Stage | Protected by | Ends |
| --- | --- | --- |
| accepted, not adopted | the host's release barrier: a release request waits until every window has adopted the revision published before it | the revision is adopted, or superseded (then it is never adopted and never held), or its window goes |
| adopted | the ledger: the lifecycle hooks record the exact adopted scene, one count per adoption; each distinct texture once per adoption however many sprites name it | `sceneReleased`: the revision is superseded or its target ended, **and** every frame recorded with it completed (never a frame's submission, abandonment, a refused presentation, a timeout or a CPU return) |
| released by Lua | the same two, and the registry's logical release (new publications naming the lease are refused) | the table release runs once no adoption holds the texture; retirement is then the table's reading |

The same window revision can be adopted under more than one attachment; the hooks carry no attachment, so the ledger
counts adoptions of each window and revision and drops the revision's holds on the last release.

### Budget and pressure

* Six unreleased adopted revisions for each target (`2 * (frame slots + 1)`) is the host's. At the limit the owner defers
  adoption and the window keeps one latest value; nothing here grows an overflow queue, drops a live hold or makes Lua
  wait. Each window has one latest snapshot and one draft (the call's own value); there is no FIFO of scene copies.
* The release lane and the action lane are separate banks. A full release lane refuses a request as pressure
  (`PortFull`), which is not a Lua error or a cleanup failure: the backend's pump keeps the texture released and
  pending, waits in STM on the lane's room, and asks again, **once**: it asks only when no request of its own is
  admitted (`TexReleaseRequested`), so re-admission never queues a duplicate. That wake is the lane's change; no Lua call,
  publication, adoption or frame is needed, and the assembly (LFE-22) calls nothing for it.
* `sceneCapacity` shows the largest legal scene (4,096 sprites, 64 encoded bytes each, claimed in 16-byte steps) fits the
  configured 4 MiB ring for every batch that can be in flight, twice over; transient in-flight pressure is the native
  backend's backpressure (the frame is skipped and retried) and is distinguishable from this fixed size.

### Frames and metrics

A frame is built from the adopted scene and the frame's own observations (`FrameFacts`: the generation's framebuffer
extent and the window's latest logical extent and content scale). The view is the whole framebuffer; authored rectangles
stay fixed top-left logical pixels, UI scale 1, no snapping, nearest full-image sampling, ordered alpha blending over the
explicit clear. A resize clips without stretching or recentring and needs no new publication; a zero framebuffer suspends
drawing, not the scene, its holds or retirement. A window that has reported no logical extent or content scale, or
unusable metrics, skips the frame; nothing is invented.

### Exit paths

* Instance, window or session end closes publication first (the owner's `ownerOpen`, the provider's admission) and then
  withdraws normal work. A scene accepted before stays with the host and is released through the ledger as its target ends.
* Ending one instance releases its own textures and window; the peer's latest scene stays adopted, held and recorded, and
  nothing synthesises a session quit.
* A genuine release failure stays fatal for its texture and is never retried; a hold ending does not retry a failed
  cleanup.

### Owners, threads, lifetimes

| State | Owner | Writers | Readers | Thread | Lifetime / disposal |
| --- | --- | --- | --- | --- | --- |
| The ledger's records | the `SceneSession` | the two lifecycle hooks | the backend's release (`portHeld`, `deviceHeld`), tests | owner's thread (hooks); STM | made before the host; a record goes with its last release |
| A window's latest scene | the host | `targetPublish` | the owner's step | STM | until replaced or the window ends |
| The call's draft | the calling instance | the call | the call | the instance's thread | the call |
| The renderer slot | the `SceneSession` | `withTextureGraphics`, once | the renderer hook | owner's thread | the session |
| A held texture's release | the backend | the pump | the pump | one pump thread | until retired or failed |

### Invariants (the D-80 table)

The D-80 table covering every reservation, publication, settlement and cancellation window of this slice is in the pull
request body of [#535](https://github.com/coghex/hetoimasia/issues/535)'s change.

### Refusals are ordinary Lua errors, including the commit's

The binding's **check** (`graphicsPublishCheck`) publishes nothing and refuses what is knowable before an effect as an
ordinary error. The **commit is made in the action**, atomically (one transaction reads the authority and writes the host's
snapshot). A stop, closure, ending instance or ended texture lease that landed between the check and the action is an
expected lifecycle refusal: the action raises it with `refuseOrdinarily` (`Hetoimasia.Scripting.Lua.Registration`, D-88),
which `pcall` catches, with the previous scene and its revision untouched. Two rules keep that sound:

* **Nothing is outstanding when it is raised.** `publishSceneWith` returns only after every pin and borrow it took has been
  released, and the refusal is raised after that and before the host holds the scene. It is never raised after the host
  holds the scene: a failure after the commit is the application's own and the scene stays the window's, with no rollback
  claimed.
* **Only lifecycle changes are ordinary.** A texture-authority refusal, a window or instance refusal is expected. A schema or
  geometry refusal of the same copied value the check accepted cannot be explained by a lifecycle change and is a
  `SceneDefect`, the engine's failure.

The reason is at most 160 bytes (`publishRefusalText`), inside the export's 256-byte bound. The binding is built from the
scene package's public pieces (`prepareScene`, `textureUses`, `sceneSchema`, `sceneLimits`), not from `scenePublishBinding`,
which takes one argument. Its reader limits are the scene's own plus **the window handle at the reader's exact charge**
(one element and `sceneCallWindowBytes` = 21 bytes), because the reader keeps one counter across all of a call's arguments;
the scene therefore keeps exactly its element and byte bounds. (The profile's validation reserves a larger 64-byte
allowance for the call; that reserve is never added to the binding's limits.)

### One release path

Each M1 texture is released by exactly one path: this package's texture backend (`Texture.Backend`), never also through
`render-2d-vulkan`'s `release2DTexture`. Its logical release (the registry mark, one STM write) is ordered with the
publication by the same transaction that publishes: the publication's final authority check reads the registry flag and
writes the host's snapshot together, and the mark can only be made after the lease release, which the publication's pin
prevents while it is in flight. A release asked after the publication therefore asks for a barrier that names the
publication; one asked before refuses it. The release action reads the adoption holds on the owner's thread; a held
texture stays pending (`held`), neither failed nor retired, and is asked again through the barrier lane when the last hold
ends, with at most one admitted request per texture.

### Tests

* `lua-engine-graphics-tests` (group `test.vulkan-headless`): `scene retention` (the production ledger and backend over
  the fake owner and a model of the host's ledger rules), `scene publication` (real Lua instances, leases, pipeline
  and window provider with the library's binding), and `the frame of an adopted scene` (the pure adaptation against the
  render-2d oracle, the host configuration, the maximum legal scene). The model is injected evidence and says so.
* `lua-engine-graphics-native-tests` (group `test.vulkan-lua-engine-native`), subgroup **`scene retention`**: the
  production host with real windows and uploads. Run it alone with
  `bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:lua-engine-graphics-native-tests -- --match 'scene retention'`
  (on macOS `HETOIMASIA_NATIVE_SESSION=desktop` on that command). It reads the host's own frame events and scene state; it
  captures and reads back no pixel.

## The graphics facade (LFE-21)

`Hetoimasia.LuaEngine.Graphics.Facade` is the concrete composition of the CPU facade's graphics operations
([the calls](../lua-engine/README.md#the-graphics-calls-lfe-21)) over this package's providers. `graphicsInjection` takes the session's
services it borrows (`GraphicsFacade`: the validated profile, the texture pipeline, the window provider and the scene publisher) and
answers the `GraphicsInjection` a session is composed with (`sxGraphics`); the session calls it once for each role's VM. Nothing here
enters Lua, waits or keeps a registry that outlives the VM it was made for.

| What | Built from | Notes |
| --- | --- | --- |
| `api.content.texture` | `textureArgumentCheck`, `startTexture` | required unless `optional=true`; a content failure keeps its root and path |
| `api.window.open` | `askWindow`, `windowArgumentCheck`, `startWindow` | always required; a clean refusal is `window_error`, latched even if unread (`required_request` at the `request` stage) |
| `api.scene.publish` | `graphicsPublishBinding` | the facade's precondition first; the commit is one transaction |
| `api.texture.release` | `releaseTexture` over the host's special release path | `done`, `retiring`, `already_released`; repeated release repeats no cleanup |

**Lease headroom (the derivation).** A VM's lease scope has room for `TextureLeasesPerUiInstance + WindowSlotsPerUiInstance` leases for
each instance: 16 + 1 = 17 under the fixed M1 profile (`facadeLeaseCapacity`). Every texture a UI instance can hold, pending, live or
retiring, takes one of its 16 texture slots, and its window takes the one window slot; both are charged by the providers' banks in the
same atomic admission as the host's lease charge, and answer `busy` when full. The most leases that can coexist are therefore 17, and the
host's lease capacity, which would fault the invocation, cannot be the first bank to answer. No authored M1 ceiling is increased.

**Owners.** A UI instance's texture owner and window owner are made when the facade declares the instance and closed when it forgets the
instance (its settlement observed). They are held in one STM map per VM, written by the declaring thread and read by the instance's owner
thread. The pipeline, the provider and the publisher are the assembly's and outlive the session; a session that stops closes new work first
(the request policy's gate and the facade's admission read), and the lease releases and the providers' own retirements run as before.

### Invariants (the D-80 table)

The table covering every reservation, publication, settlement and cancellation window of this slice is in the pull request body of
[#536](https://github.com/coghex/hetoimasia/issues/536)'s change; the providers' own tables above are unchanged and this slice adds no
reservation of its own: it composes theirs. What it adds are four checks, each made before the provider is asked, and one routing.

| Window | What makes it hold |
| --- | --- |
| calling instance | the facade asks the host which instance is running and the registry for its record; a captured facade, a module's top level and another instance's handle are refused before the action |
| role, phase and admission | decided once, in the CPU facade, for acquisition and publication; release reads only the instance and its role |
| owners | looked up by the instance identity the facade issued; an instance with none declared is an engine defect, not a Lua error |
| lifecycle races after the check | `TextureRefused` and `WindowRefused` come back from the admission with nothing reserved and are raised with `refuseOrdinarily`; a publication reads the session's admission (`gvTakesWork`, folded into the publisher's own authority by `publisherGatedBy`) in the very transaction that commits it, so a stop that lands between the binding's check and the commit refuses the whole scene and leaves the previous one |
| releasing a handle | the binding's argument check (`gsReleaseCheck`) refuses, as an ordinary error before the release path and so before any provider action, a handle another instance was issued and a lease of another kind. The host's own record of the lease decides whenever the host still holds one (live, released but still retiring because an adopted scene holds the texture, or failed): its `NotTheOwner` answer is turned into the ordinary error, so a peer's texture is refused however many later textures the VM has issued. The host deletes a lease's slot only when its release has ended whole, and from then on can no longer say whose handle it was; for that case alone the facade remembers the issuing instance of the most recent texture issuances (`gsIssued`, when the texture is taken), up to `gfIssuedMemory` per VM (**4,096** by default; two instances of one VM share the record; lease keys rise and are never reused, so the oldest issuance is forgotten first). A retired foreign handle still in the record is refused. A retired foreign handle that has **left** the record (more than the bound of later issuances in the VM) answers `already_released`: nothing is acquired, released or charged, and it aliases no newer resource, because its key is never reissued and a script cannot forge a handle. That is the only exception (owner decision, [#536 comment](https://github.com/coghex/hetoimasia/issues/536#issuecomment-6523304300)); the owner's own release answers `done`, `retiring` and `already_released` exactly as before, inside and outside the record |
| lease headroom | derived above; the capacity is a function of the profile, not a constant |

### Tests

* `lua-engine-graphics-tests` (`test.vulkan-headless`), `graphics facade`: a real `runSession` with `noHarness` and the production
  injection, over a real content root, manifest, checkpoint, read pool, supervised owners, request admission, leases, pipeline and window
  provider. The texture owner and the windows are the fakes' and the host's ledger a model (injected evidence). It runs the accepted
  common-entry example in both completion orders; the unread and the caught clean window-creation refusal (`required_request`, `request`);
  a genuine native close with the startup gate closed; a full bank answering busy; an occupied window slot; a repeated release; the
  segment after a quit; and an optional and a required missing texture.
* `lua-engine-graphics-tests`, `graphics facade, two instances of one VM`: two presentation instances of one VM composed directly (the session harness's second instance is private) through `graphicsInjection`: one ends through Haskell and is forgotten, and only then (the example's word reaches the survivor through the fake session's status) the survivor publishes again with its own window and texture, and the ended one's handle, completely retired, and facade are refused to it. Two more examples exceed the issuance record through the same injection with a smaller `gfIssuedMemory` (3; a separate example checks the default is 4,096 and the record's size at the default): a peer's retired handle is refused while remembered and answers `already_released` once forgotten, with no provider action and no effect on a live texture; a peer's live texture and its texture released but held by an adopted scene are refused after their issuance left the record; and the owner's releases answer as before on both sides of the bound, the first one outside the record being a real release (`retiring` under the scene, its authority for new scenes revoked). A fourth example invalidates the host's own request while the provider holds its window's adoption (the production injection composed directly with the provider's `hookBeforeAdopt`, and the public scheduled endpoint's `advanceRequestEpoch`): the provider closes the window it never handed over, the example holds the native window's retirement, and the acquisition stays charged until that retirement is released; no success reaches the script, and the window is closed once.
* `lua-engine-graphics-tests`, `M1 integrated texture, window and scene ownership across two instances` (LFE-23): the same composition as the
  two-instance examples, with the stand-in owner's uploads held one at a time: two instances loading the same PNG as two independent
  obligations completing in the reverse of their start order, an instance ended with its upload open or after it published and
  released (its native use held at the device), a publication on a released lease refused, a texture bank answering busy and
  freeing a place only when the work has retired, and another instance's reads served beside open texture work. The acceptance map is in
  [the evidence record](../../docs/evidence/lfe23-integrated-qualification.md); it is controlled completion, not pixels or GPU behavior.
* `lua-engine-tests` (`test.lua-engine`), `graphics calls`: the CPU facade's rules over gated services.
* `lua-engine-graphics-native-tests` (`test.vulkan-lua-engine-native`), subgroup `graphics facade`: the quad example and a failing-logical
  variant on the production host with real PNG decoding, GPU-ready textures, windows and publication, judged by the host's frame events and
  scene state, with no pixel captured. Run it with
  `HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:lua-engine-graphics-native-tests -- --match 'graphics facade'`
  (on Linux the runner starts its own display).

## Lua offscreen pixels (LFE-24)

LFE-24 supplies the pixel evidence for the Lua-first quad: what Lua authored, as pixels read from a real managed colour
target after the work that drew it completed. It adds no production code, no Lua API and no capture API (VK-19 window
capture stays private to the Vulkan GLFW package); it is tests and technical fixtures. It does not show a native window,
resize, zero-framebuffer behaviour or independent window retirement (LFE-25), and it makes no performance claim.

### What runs for real, and the one thing that is replaced

Run as the roles of a real `runSession`, from content copied to an owned temporary root before boot: the filtered Lua VMs,
the manifest checkpoint, the anchored inventory and verified reads, module evaluation, instance and role construction
(the logical stub runs beside the UI Lua), request ready/take, the bounded PNG decoder, texture upload and registration
through the session's one table, the graphics facade (`graphicsInjection`), scene preparation and publication through the
production publisher, the host's adoption, hold ledger and release barrier, and `frameCandidate`. The shipped
`samples/lua-quad/content` runs unchanged.

Only the display target is replaced. The test-only display adapter (`Test.LuaEngine.Graphics.Native.Display`) answers the
window provider's `Port` with a surface-free offscreen scene target registered through LFE-27's public interface. The
interfaces that form the boundary:

| Interface | What the display does with it |
| --- | --- |
| `registerVulkanSceneTarget` | **The substitution.** A creation the provider issues becomes a registered target; no window exists or opens. |
| `unregisterVulkanSceneTarget` | The port's close. |
| `offscreenTargetAnswer` (over `publishVulkanTargetScene`) with `scenePublisherOver` | Lua's publication: the host's transaction, composed with the publisher's authority check and lease binding as a window's is. |
| `recordVulkanTargetBatch` | The only way the adapter records an adopted scene: the batch is bound to the host's adopted scene and to its own ticket before anything is recorded. |
| `readVulkanSceneState`, `SceneTargetKey` (`KeyOffscreen`) | Observation only: the revision published and adopted, the requests waiting behind the target's barrier. |
| `withWindowProvider`, the window `Port target`, `GraphicsFacade` | Already polymorphic in the target; they carry the offscreen target through unchanged. |

The adapter keeps no hold, no barrier, no ledger and no lifecycle of its own, and never calls the ledger's adopt or release
hooks. What it stores is the identity bookkeeping the provider's port needs: which creation issued which target and which
it has closed.

### A rendering

The production renderer builds a frame with `frameCandidate` and records it into a window's swapchain image, which a
frame-less batch cannot supply. So, inside `recordVulkanTargetBatch` on the graphics owner, the adapter takes the
`frameCandidate` output for the scene the host adopted and the target's own `FrameFacts` (the framebuffer extent, the
logical extent and the content scale; this is the delivered operation that adapts an unchanged scene to a target's
metrics), retargets it **in its pass target alone** to an offscreen reference that `frameTarget` resolves to the managed
RGBA8 sRGB colour target, records it with the public `prepareSnapshot`, and copies the target to a managed readback buffer
through checked transfer transitions. Each rendering asserts, through `validSnapshot`, that the copy equals the
production candidate in every other value. The bytes are read only after the batch's own ticket reports completion; the
target and the readback are released after that ticket has settled, on every way out.

### Judging an image

Three judges, none of them the code under test (`Test.LuaEngine.Graphics.Pixels`):

1. **Hand-stated expectations**: named positions and the colours the fixture's specification puts there, worked out by hand
   from the committed texel tables and the rectangles the case authors, with the arithmetic in a comment.
2. **The render-2d oracle over the specification**: a snapshot written out from the same specification, with the texture
   tables premultiplied in linear light by the test's own transfer function, not by the decoder.
3. **The render-2d oracle over the published window-pass scene** (the `frameCandidate` output), with the managed target's
   own `TargetSpec` as its window, judging every pixel of the readback. Indeterminate pixels are counted by reason and
   count for no success; an unevaluable pixel or an image with no determinate pixel fails.

The published scene is also compared with the specification's snapshot, ignoring only which texture handle each sprite
names, and the oracle's expectation is required to agree with every hand-stated one. A readback that matches all of them
cannot have come from a translator or decoder that is wrong in the ways those expectations are sensitive to (a flipped Y,
a reversed list order, linear sampling, straight alpha, a byte 128 taken as linear light).

### Pacing without sleeping

A program's steps are gated on texture requests the example holds at the read pool's reader (`holdReadsOf`). The gate
file is not a PNG and its request is optional, so letting its read go ends the request with an ordinary decode failure
and **no upload**: Lua is paced by the example even while the example holds the graphics owner, which a texture that has
to be uploaded could not be. The example learns that a publication was accepted from the host's own scene state.

### Cases

Each case is one session and one or more images; `retain` writes a lossless PNG and a machine-readable record per image
when `HETOIMASIA_VALIDATION_EVIDENCE` names a directory.

| Case | What it shows |
| --- | --- |
| shipped Lua quad | the unchanged content's PNG at its declared rectangle over its clear (304 × 304 target) |
| top-left, full image, nearest | the initial scene read opaque black first; then twelve distinct texels, eight pixels to a texel, every texel at its place, nothing between neighbours |
| ordered transparency | two partly transparent sprites over opaque black, in both list orders (separate publications), with the premultiplied overlap |
| sRGB byte clear | a clear of byte 128 reads 128 (not 188), an opaque 128 texel reads 128, the output is opaque |
| fractional, negative, clipping | no snapping at 0.25 and 0.75; rectangles across the left, top, right and bottom edges; a texture cropped by the top edge, neither recentred nor stretched |
| target metrics | one accepted revision viewed at 64 × 48, 128 × 96 (scale 2), 80 × 60 and 40 × 30, with no new publication |
| empty scene | an empty sprite list clears the earlier grid to the authored opaque colour |
| copied scene | the script changes its table after publishing; the pixels do not change until it publishes again |
| refused publication | a malformed scene and a publication naming a released texture are refused; the revision and the pixels are the last accepted |
| release after publish | the owner held on a gate; the texture released straight after acceptance and before adoption; adopted, drawn twice after the release, refused for a new publication, freed only after the old batches completed |

### Invariants (the D-80 table)

| State | Owner | Resource | Admission and tracking | Final authority | Cancellation window | Terminal evidence | Cleanup |
| --- | --- | --- | --- | --- | --- | --- | --- |
| The display's scene target | the host (registry, ledger, barrier); the display holds its identity | one of `vulkanTargetCapacity` slots | `registerVulkanSceneTarget` and the display's record in one transaction | the host's `publishVulkanTargetScene`, composed with the publisher's authority | none between registration and record (one transaction); a close racing a publication is answered `TargetSceneUnknown` | the target's record absent from `readVulkanSceneState` | the port's close unregisters; the owner releases the records as their tickets complete |
| A scene revision | the host | the textures it names, held in the ledger | accepted by the transaction, adopted by the owner | the release request's barrier, then the ticket of every batch recorded with it | a release before adoption waits behind the barrier | `readingLiveTextures` and the ledger's holds at zero | released only on tickets complete or discarded |
| The managed target and readback, one pair per rendering | the graphics owner | an image and a buffer | an owner-thread action | `releaseConstructed` | between making and recording: released in `finally` | the release's result | after the batch's ticket settled |
| The recording batch | the host's boundary | a frame-less batch | `recordVulkanTargetBatch`: bound to the revision and the ticket before recording | the ticket | the example's timeout | `TicketComplete` | the cleanup waits for the ticket to settle |
| The readback bytes | the example | host-visible memory | read once | completion | not read unless complete | the bytes' SHA-256 in the record | released with the target |
| The owner gate (release case) | the example | the owner's thread | an owner-thread action | the example's `tryPutMVar` | the surrounding `finally` | the host's scene state | opened on every exit |
| Held reads | the composition | pool workers | `holdReadsOf` | `releaseReadsOf` | the thread handler and the composition's `finally` release all | the request's result | none left held |
| The scenario thread | the example | a thread | `forkFinally` | its outcome | killed and waited on every exit | the outcome | the stop and the outcome are put under a masked `finally` |

### Tests and evidence

* The device-free half is the `Lua offscreen pixels comparator` group of `lua-engine-graphics-tests`: the committed
  fixtures against their SHA-256 and the production decoder's texels, every hand-stated number against the oracle, the
  comparator rejecting the defects above on synthetic readbacks (which say so), and the retargeted copy.
* The real-device half is the `Lua offscreen pixels` group of `lua-engine-graphics-native-tests`, selected by
  `-- --match 'Lua offscreen pixels'`; a selection that matches nothing fails.
* Why the native lane: the design's wording is "the Vulkan headless runner", but `tools/vulkan/run.sh test` creates no
  device by contract, so a group that draws real pixels belongs to the native lane (as R2D-7's offscreen pixels do). The
  group opens no window and reports `windows: 0`.
* The committed fixtures, their generator, texel tables and SHA-256 are in
  [`test-common/fixtures/pixels/`](test-common/fixtures/pixels/README.md): technical test assets, not production art.

## Limits

* The completion wake is the GPU model's change: the adapter assumes the only uploads in the session are its own and the
  table's placeholder, as in M1. A completion that changes no model state would not wake a waiting job.
* The real-device suite is the one device claim: Linux execution is CI's.
* A texture an adopted scene holds retires only when that scene is released, which for a static scene is its window's
  end or a replacement. The backend's scope drains until every texture is retired, so the window provider's scope (which
  ends every window) must exit before the backend's; the assembly (LFE-22) nests them that way.
