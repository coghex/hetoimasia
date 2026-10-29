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
withTextureGraphics ∷ TextureGraphicsConfiguration → VulkanHostConfig scene → VulkanHost scene → (TextureGraphics → IO r) → IO r
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
once every window has adopted the scene revision that was current when it was asked. **That lane is the single hook
through which the holds a published scene takes gate the table release**; LFE-20's publication marks and releases
through the same registry. The release is nonblocking and distinguishes *requested* from *retired*: the reading
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

## Limits

* The completion wake is the GPU model's change: the adapter assumes the only uploads in the session are its own and the
  table's placeholder, as in M1. A completion that changes no model state would not wake a waiting job.
* The real-device suite is the one device claim: Linux execution is CI's.
