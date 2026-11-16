# Lua-first engine graphics adapter

Buildable package: `hetoimasia-lua-engine-graphics`, in
`packages/lua-engine-graphics`.

The concrete graphics backends of the Lua-first engine: the texture pipeline's
port ([`packages/lua-engine/README.md`](../lua-engine/README.md#the-texture-pipeline-lfe-16)),
[the window provider](#the-window-provider-lfe-18),
[scene publication](#scene-publication-lfe-20),
[the graphics facade](#the-graphics-facade-lfe-21) and
[the Lua input adapter](#the-lua-input-adapter-tra-6). It works on the
protected graphics owner the host lends: the adapter starts no device and no
thread per texture, instance or VM.

It depends on the pipeline's CPU port (`hetoimasia-lua-engine:texture`), the
native backend, the window integration's public host and the 2D renderer's
Vulkan recorder. The CPU Lua-engine, content and codec packages depend on none
of it. The package is named only by `cabal.project.vulkan`.

## Modules

| Module (under `Hetoimasia.LuaEngine.Graphics`) | What it is |
| --- | --- |
| `Texture` | The composition: `withTextureGraphics` over a borrowed host, the session's renderer and texture registry, the backend. |
| `Texture.Configuration` | The native configuration the fixed M1 profile maps to, and the checks of a host built for it. Pure. |
| `Texture.Backend`, `Texture.Port` | The state machine and its one pump thread, over a `Port` of values (the seam the lifecycle suite injects). Nothing in them names Vulkan. Their implementations live in the package's **private** `internal` sub-library; what the suite needs beyond the public modules (`pumpOnce`, observed and unpumped scopes) is reachable by no client. |
| `Texture.Host` | The production `Port`, over a running `VulkanHost`. |
| `Window.*` | The window provider. |
| `Scene.*` | Scene publication, the hold ledger and the frame of an adopted scene. |
| `Facade` | The composition of the CPU facade's graphics operations. |
| `Input` | The Lua input adapter. |

## Composition and ownership

```haskell
withTextureGraphics ∷ SceneSession → TextureGraphicsConfiguration → VulkanHostConfig scene → VulkanHost scene → (TextureGraphics → IO r) → IO r
```

- The **host and its owner** are the assembler's; the scope borrows them and
  unwinds inside them. The host must have been built with `configureHost`,
  `configureWindows` and `configureScenes`. `withTextureGraphics` raises
  `HostConfigurationWrong` before any texture work is admitted: a wrong
  configuration is a structured startup failure, never a per-request
  `UploadOversized` that would look like the content's fault.
- The **renderer and the texture registry** are made once, in one owner
  action, and exposed as the session's own (`graphicsRenderer`,
  `graphicsTextures`). A session has one texture table; a scene adapter
  records through these and registers nothing beside them.
- **Assembly waits**, interruptibly, for the table's placeholder to be bound.
- The **backend** (`textureBackend`) is the value a `withTexturePipeline`
  scope is given. It outlives the pipeline and every texture it delivered.

All native allocation, registration and release run on the owner's thread as
bounded actions. The pump (one worker) admits uploads, reads tickets and
submits the actions. **It waits only in STM**, on the variable the next fact
lives in: a ticket, an action's outcome, the owner's standing, the bounded
action queue, or the owner's recorded progress (`portWatch`). No timer, frame,
Lua poll, window or peer instance drives progress. Sink calls are single
transactions and never enter Lua.

| State | Owner | Thread | Lifetime |
| --- | --- | --- | --- |
| Backend state (jobs, textures, bootstrap, failure) | one `Backend` | STM; written by the decode worker, cancelling and releasing threads, owner actions and the pump | `withBackend`; empty at exit |
| The pump | the backend's worker group | one thread | stopped after the drain |
| Renderer, registry, table | the session | owner thread | the session's managed resources |
| A native image | its job, then the table | owner thread | destroyed by the owner once nothing holds it |
| A decoded level | the pipeline's lane | borrowed by the backend | `sinkBuffersRetired` ends the borrow |

**What a pump step costs.** A step examines the jobs in flight, the textures
being released, held or retired, and the lowest texture waiting for the
release lane. A delivered texture nobody has released is not a candidate, so
the cost never grows with the textures retained. `readBackend` is an observer
that reads every texture's stage.

## The readiness predicate

Success requires, and observes, each of these in order:

1. the checked image exists, recorded in the job by the action that made it;
2. the exact bytes of the one level were admitted and the **upload ticket was
   observed `UploadComplete`**;
3. the table's **placeholder was observed bound**;
4. the image was **registered with the renderer's texture registry**, with the
   decoded alpha classification as its cutout mark, **and the table's
   published mapping resolves the handle's index to the image's own slot at
   the handle's generation**.

An allocated image, an accepted ticket, a queue submission, a table handle or
a placeholder resolution is not success. There is no second decode, mip level,
resize, format fallback or cross-request sharing.

The opaque identity the pipeline carries is the handle's generation above its
index (`textureIdentity`), so a stale index never names a later texture;
`textureHandleOf` is its inverse.

## Budget mapping

`configurationFor` reads a validated profile and refuses, structurally, what
cannot be mapped. Nothing is tunable.

| Native configuration | Source | Fixed M1 value |
| --- | --- | --- |
| target records; frame slots per window; aggregate frame slots | `NativeTargetRecords`; `FrameSlotsPerWindow`; `FrameSlotsAggregate` | 2; 2; 4 |
| frame-less batches; generations per target; tracked images per generation | `FramelessBatches`; `GenerationsPerTarget`; `TrackedImagesPerGeneration` | 4; 2; 16 |
| accounted native bytes; objects | `NativeAccountedBytes`; `NativeObjects` | 2 GiB; 4,096 |
| reclaim pass; progress actions per turn; idle backoff | `ReclaimPassRecords`; `ProgressActionsPerTurn`; `MaximumIdleBackoff` | 64; 32; 100 ms |
| staging buffer | one maximum level (2,048 × 2,048 × 4 = 16 MiB) for each of 2 lanes | 32 MiB |
| upload turn budget | a quarter of a maximum level | 4 MiB |
| upload queue | four for each lane | 8 |
| texture table capacity | the session's texture bytes over the 4 KiB minimum charge, plus slot 0 | 1 GiB / 4 KiB + 1 = 262,145 |
| lookup versions | aggregate frame slots + frame-less batches + 2 | 10 |
| lookup ring | lookup versions × table capacity × 8 bytes | 20,971,600 bytes |
| ring; region window | twice the instance bytes of every batch in flight at 4,096 sprites; 3 × the sprite limit × 16-byte clip entries | 4 MiB; 192 KiB |

`accountingNativeBytes` is the most the configuration asks of the native byte
budget and must fit the profile's accounted bytes. Each cost is charged once:
the decoded level to its lane until `sinkBuffersRetired`, its staging copy
until the upload completes, the image for its lifetime. The pipeline's
nominal-bytes and slot banks are returned only when the table proves a texture
retired.

## Readiness, cancellation, faults, pressure

- **Cancellation** is a flag, not a state: the step in flight finishes, then
  the job is taken apart in dependency order. A cancelled job answers one
  `sinkWithdrawn` and one `sinkBuffersRetired`, never a success. A success
  already handed over is not erased.
- **Faults keep their severity.** Device, allocator, provider and cleanup
  failures are `sinkFailed`, for required and optional requests alike. They
  are never an image error, a cancellation or a retry. `Refusal`s other than
  `RefusedBackpressure` are faults.
- **Pressure retains accepted work.** Native backpressure (an allocation or
  registration answering `RefusedBackpressure`, a full upload queue, staging,
  action or release lane, no free table slot) leaves the job with its
  reservations until the owner's recorded progress moves. The wake is taken
  **before** the attempt, so a relief that lands in between is not lost.

### Invariants of a texture request

| Window | Terminal authority | What makes it hold |
| --- | --- | --- |
| admission → tracking | the job's terminal event | `backendUpload` records the job in the transaction that decides acceptance |
| allocation → tracking | the job, then disposal | the image is recorded in the job inside the same masked owner step that made it; a job already gone discards it on the spot |
| copy into staging → borrow end | `sinkBuffersRetired`, once | `portUpload` copies before it returns; the borrow ends there, or at job end when no copy began |
| registration → tracking | the job, then disposal | recorded in the same masked step; a job gone releases it on the spot |
| registration → lease transfer | `SinkTaken` / `SinkLate` | the record exists before `sinkReady`; `SinkTaken` makes the release the lease's; `SinkLate` leaves the texture the backend's to dispose |
| cancellation | one `sinkWithdrawn` after disposal | one before `SinkTaken` wins and the texture is released; one after erases nothing |
| faults | one `sinkFailed` after disposal | a cleanup failure is appended to the primary and latched; it is never retried |
| owner end, pump failure | `sinkFailed` / `ProviderFailed` | nothing is claimed reclaimed that was not proved |
| backend close | the drain | admission closes, jobs are cancelled, unreleased textures are released; a cancellation delivered meanwhile is raised after the drain |

## Release and retirement

A delivered texture's `textureRelease` marks the logical release in the
registry at once and asks the table to release through `requestVulkanRelease`,
which the owner runs only once every scene target (each window and each
registered offscreen target) has adopted the revision current when it was
asked.

- **That lane, with the scene ledger, is the single hook through which a
  published scene's holds gate the table release.** The release action reads
  the ledger on the owner's thread and releases the handle only when no
  adopted revision holds the texture.
- A held release is neither a failure nor a retirement: the texture stays
  `held` (released for new use, charges kept) and the backend asks again when
  the last hold ends, through the barrier lane, with at most one admitted
  request per texture.
- The release is nonblocking and distinguishes *requested* from *retired*. It
  answers `ProviderComplete` only when the release ran on the owner's thread
  **and** an owner action read the table with the texture's slot no longer
  retiring. A request, an acknowledgement, a dropped reference, a worker exit
  or the end of a CPU scope is none of these.
- Each texture is released by exactly this path, never also through
  `render-2d-vulkan`'s `release2DTexture`.

**Teardown.** `withBackend` exits in dependency order: admission closes; every
unfinished job is cancelled and taken apart; every unreleased texture is
released; the drain waits in STM until every job has answered and every
texture is proved retired or failed; only then does the pump stop. Ending one
instance neither closes the shared owner nor touches a peer's texture.

## Image kinds and format routing (TRA-15)

| Request | `uploadFormat` | Native image |
| --- | --- | --- |
| `kind = "colour"` (the default) | `TexelRgba8Srgb` | `Rgba8Srgb` |
| `kind = "data"` | `TexelRgba8Linear` | `Rgba8Linear`, linear UNORM |

The image keeps its native format for good. A texel format the pipeline never
asks for is a fatal `FaultFatal` of the allocation. Everything else in the
adapter is format-blind. `api.scene.publish` accepts any live texture lease: a
published data texture is sampled as numeric values and is **not**
reinterpreted as sRGB colour, so into an sRGB target a data channel of 128
reads back as 188 and a colour one as 128.

## The window provider (LFE-18)

`Window.*` answers a request for **one instance-owned window** asynchronously.
It is a typed endpoint, not a Lua API: the facade binds
`api.window.open({title = TEXT, width = INTEGER, height = INTEGER})` over
`askWindow`, `windowArgumentCheck` and `startWindow`. Every field is required
and success is the owned window handle itself. M1 offers no independent close,
reopen or release: the window lives until its instance ends or the session
quits.

| Module | What it is |
| --- | --- |
| `Window.Request` | Pure: the title and size rules. |
| `Window.Port` | The boundary to the hosts, as values. Opaque tokens, never reissued. |
| `Window.Provider` | The provider (`withWindowProvider`), the owner slots, the state machine and its one pump, the main-thread step (`windowMainStep`). |
| `Window.Host` | The production `Port`; yields `WindowTarget`, the right to publish a scene to one window's incarnation. |
| `Window.Configuration` | What the fixed two-window profile asks of the host. |
| `Window.Session` | `sessionWindowConfig`: the provider's stop and fatal endpoints as the real coordinator's. |

### Validation before anything is reserved

- **Title**: valid UTF-8, at most **512 encoded bytes**, no Unicode `Cc`
  character, checked in that order. The empty title is allowed.
- **Width and height**: Lua integers `1..4096` in screen-coordinate units,
  checked before any narrowing, so nothing is wrapped or clamped. They are
  preferences, never observations.
- **Role, phase, identity**: acquisition is presentation-instance hook work. A
  logical instance, wrong phase, closed or foreign owner and a stopping
  provider are ordinary Lua errors, decided with no native work.

### Admission

One atomic admission reserves the request and result records, the result
lease capacity, **the instance's one window slot**, and one of the provider's
bounded work records (`windowRecords`; two for the fixed profile).

| Credit | Full means | Returned |
| --- | --- | --- |
| window slot | the instance already has a pending, live or retiring window: a **permanent** error, decided first so a full temporary bank never turns it into busy | by the pump at **actual retirement**, never by a credit's return or a lease's release |
| window records | busy: no command, no partial credit, no hidden retry | when the host returns the request's record |

Once accepted, downstream pressure keeps the work pending and bounded; it is
never a busy refusal.

### The state machine of an acquisition

```
Queued ──issue──▶ Issued ──created──▶ Open ToAttach ──main thread──▶ Open Attached ──standing usable──▶ offered ──▶ adopted by the lease
   │                │                                                       │
   │                └─ refused clean ▶ window_error                         └─ refused clean ▶ window_error, then close
   └─ cancelled before issuance ▶ retired (no native work)
every Open state ──(cancel | instance end | session stop | refusal | fault)──▶ close begun ──▶ graphics retired ∧ native disposed ──▶ retired
```

- **Create and attach.** The window is created by a command on the host's
  bounded queue; the creation token is tracked from the moment the command is
  issued. The graphics handover runs on the process main thread from
  `windowMainStep`, and a deferred announcement is repeated on the **same
  attachment**: no second surface or window is built to retry.
- **Readiness** is the graphics owner's own answer
  (`readTargetStanding == TargetUsable`, still attached) and the capability to
  publish to that incarnation. `WindowCreated`, an attachment, a handover or
  an allocated surface is not success. No texture, scene, frame or
  presentation is required.
- **Publication.** The result is a resource the host builds, on the owner's
  thread, into the lease the request reserved. It carries only the publication
  capability.
- **An offered result nobody builds.** A cancellation that wins before the
  lease builds the resource reaches no `workCancel`. The provider therefore
  reads `submissionSettled` for every offered, unadopted acquisition: settled
  and not adopted means no lease will own it, and the pump ends it.
- **Cancellation** that wins settles `cancelled` with no required-failure
  latch; if success settled first it answers `already_settled` and cannot
  close the window. Native work already issued is allowed to finish far enough
  to retire.
- **Retirement** is two separately observed outcomes: graphics use retired
  (`SlotFree`) and the native window destroyed (`WindowReleased`). A release
  that failed is fatal, never attempted twice and **never frees the slot**.

### Close: user versus cleanup

A **genuine** native close request is the newest `CloseRequest` in the
window's own observations, observed from creation until retirement. It is
routed to the session's idempotent stop endpoint (`windowStop`). Lua cannot
veto it, and the same number is never routed twice. `WindowClosing`,
`WindowEnded` and any close the provider itself begins are **never** a user
close, so ending an instance neither synthesises a session quit nor ends a
healthy peer.

### Error classification

| Outcome | Becomes |
| --- | --- |
| `WindowCreationFailed` after a clean rollback; `VulkanHandoverRolledBack` with `RollbackSafe`; a target rolled back with `TargetUnusable False` and a recorded surface rejection | expected required failure `window_error` (message at most 2 KiB, no root or path), latched even if unread; role failure `required_request` at stage `request` |
| `VulkanRootsNotReady`, `VulkanAnnouncementDeferred` | bounded waiting on the same window and attachment |
| `VulkanOwnerClosed`, `VulkanHandoverSuperseded`, `GraphicsAdmissionEnded`, `GraphicsWindowClosing`, `GraphicsWindowUnavailable`, a creation `NotExecuted`, `StandingEnded` | the cancellation, stop or cleanup path; never `window_error` |
| `RollbackUnsafe`, an interrupted creation ticket, partial or unverified construction, `VulkanSessionFailed`, `VulkanDiagnosticPending`, `VulkanHandoverUnavailable`, `GraphicsSlotUnavailable`, `GraphicsWindowOccupied`, `GraphicsForeignSession`, `WindowCapacityReached`, `WindowCreationPoisoned`, `WindowConfigInvalid` after validation, a failed disposal, a failed owner | **fatal**: latched once, handed to `windowFatal`; never `window_error`, busy or a retry |

A required request's failure ends its instance at the end of the invocation
running when the request settles, read or not. The refusal stays the
instance's primary failure even when the script raises its message uncaught
([the failure precedence](../scripting-lua/README.md#failure-and-escalation)).

### Failed effects and exit

- A synchronous failure of an effect the pump ran is never repeated: the
  acquisition is recorded as unretryable (slot kept) and the fault is handed
  to the session once.
- When the host's command queue refuses an issue or a close, the acquisition
  waits on the queue's **room** (`portQueueRoom`), not on a change of it, so a
  queue that filled and drained in between cannot be missed.
- A pump that itself fails closes admission and leaves every acquisition as
  retained terminal evidence, slot held, so the drain and the host's teardown
  proceed. An interrupted or uncertain creation (`CreateFatal`) is the same.
- `endWindows` is the session-stop action: it ends every window and closes
  admission, idempotently and without waiting.
- `ProviderHooks` (`withWindowProviderWith`) is a test seam; production uses
  none.

### Window provider state and invariants

The provider's state (`PState`) lives in STM for the scope of
`withWindowProvider`. The pump is one thread, never the main thread, and waits
only in STM. `windowMainStep` runs one bounded step per turn on the process
main thread. A window held up in retirement never blocks another.

| Window | What makes it hold |
| --- | --- |
| admission → record | all credits are reserved in the host's one admission transaction or none is |
| accepted → issuance | a request cancelled while `Queued` retires with no native call |
| issuance → tracking | the token is recorded in the masked step that learns it; a full host queue is a recorded wait, never a lost issue |
| announcement → admission | success reads the owner's standing, never the handover |
| admission → publication | the success is claimed in the transaction that reads standing and the capability |
| publication → adoption | a build the host never ran leaves the window with the provider, which takes it apart |
| retirement, slot return | graphics and native observed separately; the slot returns at the transition to retired only |
| provider close | admission closes and every window is taken apart; a cancellation delivered meanwhile is raised after the drain |

## Scene publication (LFE-20)

`Scene.*` publishes a prepared scene to the caller's ready window, keeps the
textures it names alive through adoption and every frame that used them, and
records each frame with that frame's own metrics.

| Module | What it is |
| --- | --- |
| `Scene.Ledger` | `GraphicsScene`, `SceneLedger` and the lifecycle hooks: what the adopted revisions hold, keyed by the host's `SceneTargetKey` (a window or a registered offscreen target). |
| `Scene.Publish` | `publishScene`, its refusals and the binding (`graphicsPublishCheck`, `graphicsPublishBinding`); `offscreenTargetAnswer` for a publication to an offscreen target. |
| `Scene.Render` | The pure frame of an adopted scene (`frameCandidate`) and the `VulkanRenderer` that records it. |
| `Scene.Configuration` | `configureScenes`, `SceneSession`, and the maximum-legal-scene check (`sceneCapacity`). |

### The commit point, authority and lock protocol

`publishScene windowKey prepared` is the one place authority is checked and a
scene becomes the host's. In order, all inside the borrows:

1. the window lease is borrowed;
2. every distinct texture the scene names is borrowed through the instance's
   own lease and compared with the prepared identity and dimensions. **The
   borrow is the pin**: a borrowed member cannot be retired, so no release can
   run between this check and the host holding the scene;
3. one transaction reads the instance's and the provider's admission, the
   window's incarnation and the registry's flag for each texture and, **in the
   same transaction**, makes the scene the window's latest value.

**Acceptance is step 3's write.** Before it the call has changed nothing;
after it the scene is the host's whatever happens to the caller. If a release,
end or closure wins the race, the whole publication is refused and the
previous scene stays.

Lock order: the collection's borrows (window, then each texture in prepared
order) outside, the host's snapshot transaction innermost. No lock of this
package is held across a GPU wait, native teardown or a callback into Lua.

### Accepted, adopted and in-flight

| Stage | Protected by | Ends |
| --- | --- | --- |
| accepted, not adopted | the host's release barrier | the revision is adopted, superseded (then never adopted or held), or its window goes |
| adopted | the ledger, one count per adoption | `sceneReleased`: superseded or its target ended, **and** every frame recorded with it completed |
| released by Lua | both, and the registry's logical release (new publications naming it are refused) | the table release runs once no adoption holds the texture |

### Budget and pressure

- The host allows six unreleased adopted revisions per target
  (`2 × (frame slots + 1)`). At the limit the owner defers adoption and the
  window keeps one latest value. Lua never waits.
- A full release lane refuses a request as pressure (`PortFull`), not a Lua
  error: the pump waits in STM on the lane's room and asks again once.
- `sceneCapacity` shows the largest legal scene (4,096 sprites) fits the
  configured ring for every batch in flight.

### Frames and metrics

A frame is built from the adopted scene and the frame's own `FrameFacts`
(framebuffer extent, logical extent, content scale). The view is the whole
framebuffer; authored rectangles stay fixed top-left logical pixels, with
nearest sampling and ordered alpha blending over the explicit clear. A resize
clips without stretching and needs no new publication. A zero framebuffer
suspends drawing, not the scene or its holds. A window with no reported
metrics skips the frame.

### Refusals are ordinary Lua errors, including the commit's

The binding's **check** (`graphicsPublishCheck`) publishes nothing and refuses
what is knowable before an effect. The **commit is made in the action**,
atomically. A stop, closure, ending instance or ended texture lease that
landed between the check and the action is an expected lifecycle refusal: the
action raises it with `refuseOrdinarily`, which `pcall` catches, with the
previous scene and its revision untouched.

- **Nothing is outstanding when it is raised.** Every pin and borrow has been
  released, and it is raised before the host holds the scene, never after.
- **Only lifecycle changes are ordinary.** A schema or geometry refusal of the
  same copied value the check accepted is a `SceneDefect`, the engine's
  failure.

The reason is at most 160 bytes (`publishRefusalText`). The binding's reader
limits are the scene's own plus the window handle at the reader's exact charge
(one element and `sceneCallWindowBytes` = 21 bytes).

### Exit paths

- Instance, window or session end closes publication first and then withdraws
  normal work. A scene accepted before stays with the host and is released
  through the ledger as its target ends.
- Ending one instance releases its own textures and window; the peer's scene
  stays adopted and held.
- A release failure stays fatal for its texture and is never retried.

## The graphics facade (LFE-21)

`Facade` is the concrete composition of the CPU facade's graphics operations
([the calls](../lua-engine/README.md#the-graphics-calls-lfe-21)).
`graphicsInjection` takes the services it borrows (`GraphicsFacade`: the
profile, the texture pipeline, the window provider, the scene publisher) and
answers the `GraphicsInjection` a session is composed with, once for each
role's VM.

| Call | Built from | Notes |
| --- | --- | --- |
| `api.content.texture` | `textureArgumentCheck`, `startTexture` | required unless `optional=true` |
| `api.window.open` | `askWindow`, `windowArgumentCheck`, `startWindow` | always required; a clean refusal is `window_error` |
| `api.scene.publish` | `graphicsPublishBinding` | the commit is one transaction |
| `api.texture.release` | `releaseTexture` | `done`, `retiring`, `already_released`; a repeated release repeats no cleanup |

**Lease headroom.** Memory is the only bound on the textures a UI instance
holds; there is no texture count. A VM's lease scope has room for
`TextureBytesPerUiInstance ÷ 4 KiB + WindowSlotsPerUiInstance + 1` leases per
instance (`facadeLeaseCapacity`; 131,074 under the fixed profile). The extra
lease is headroom so that the byte bank, which answers `busy`, always refuses
before the lease capacity, which would fault the invocation.

**Checks the facade adds**, each before a provider is asked:

- **Calling instance.** A captured facade, a module's top level and another
  instance's handle are refused before the action.
- **Lifecycle races after the check.** `TextureRefused` and `WindowRefused`
  come back with nothing reserved and are raised with `refuseOrdinarily`. A
  publication reads the session's admission (`gvTakesWork`) in the transaction
  that commits it.
- **Releasing a handle.** A handle another instance was issued, or a lease of
  another kind, is refused as an ordinary error before any provider action.
  The host's own lease record decides while it holds one. After a lease's
  release has ended whole, the facade remembers the issuing instance of the
  most recent issuances (`gfIssuedMemory`, **4,096** per VM by default). A
  retired foreign handle that has left that record answers `already_released`
  with nothing acquired, released or charged; it aliases nothing, because
  lease keys are never reissued.

A UI instance's texture owner and window owner are made when the facade
declares the instance and closed when it forgets it.

## The Lua input adapter (TRA-6)

`Input` is the concrete composition of the CPU facade's optional
`InputServices` ([the facade's rules](../lua-engine/README.md#the-input-calls-tra-6))
over the window's one `InputReader`, `InputControl` and observation snapshot,
reached through the narrow `WindowInput` the production port yields
(`hostPortsInput`). `WindowTarget` still grants scene publication only. A
composition opts in with `gfInput = Just (glfwInputHost (hostPortsInput ports))`;
`Nothing` adds no `api.input` and enables no window's admission.

### Source, consumer, registry

- **`Source ev tok`** is the record of transactions a consumer needs of one
  window's feed. `glfwSource` is the production source. No public API outside
  the GLFW package can produce an input event or a reset token, so the suites
  drive the logic with a controlled source.
- **`Consumer`** is the single logical consumer of one window incarnation's
  feed. It owns no thread and no queue. A poll is one transaction: a bounded
  prefix of the feed, the disposition the read stopped on, the epoch and the
  window's observation. Events of two epochs are never in one packet. Nothing
  is retried or replayed.
- **Reset tokens** are `input_reset` capabilities keyed
  `consumerId * 2^32 + order`. Polling a pending reset again answers the same
  order; an older order acknowledges nothing and answers `stale`; an order
  never issued is refused. A peer instance's token is refused by the registry.
- **`InputRegistry`** is one VM's bookkeeping: at most one consumer per
  declared instance. A consumer for a later window replaces and ends the one
  for an earlier.

### When admission is enabled

A feed starts gated. The adapter enables admission **in the transaction that
registers the consumer**, at the instance's first successful `poll` of that
window incarnation. Input produced before that first poll is dropped by the
host, not replayed. A window whose script never polls is never enabled, so it
never overflows or resets. When the consumer ends, the adapter suspends
admission in the transaction that removes it.

### Closure and disposal

Revoking a window or an instance invalidates input and token authority
**without waiting for an acknowledgement**: `forgetInput` is one transaction.
An acknowledgement is one STM transaction and needs no command or request
capacity. A poll is gated on the instance still taking work; an
acknowledgement is not, because it is cleanup.

## Tests

Neither suite runs through `cabal test`.

**`lua-engine-graphics-tests`** (headless; group `test.vulkan-headless`) runs
the backend, the provider, publication, the facade and the input adapter over
injected ports whose every stage the example holds or lets go, inside the real
composition (real admission, leases, pipeline, Lua owners and `runSession`).
Evidence from the fakes is injected evidence: it proves ordering, ownership
and routing, never texels or a window.

```sh
bash tools/vulkan/run.sh test hetoimasia-lua-engine-graphics:test:lua-engine-graphics-tests
```

**`lua-engine-graphics-native-tests`** (a real device; group
`test.vulkan-lua-engine-native`) runs the production host. It follows the
native-suite rules (main-thread session, cleared ambient environment,
post-teardown verdict, destruction order, consent). A run without consent
refuses and exits non-zero. With `HETOIMASIA_VALIDATION_EVIDENCE` set it
writes `lua-engine-graphics-native.md` and the pixel groups' PNGs and records.

```sh
bash tools/vulkan/run.sh build hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests
bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests          # Linux
HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia-lua-engine-graphics:test:lua-engine-graphics-native-tests   # macOS
```

Select one subgroup with `-- --match '<name>'`; a selection that matches
nothing fails.

| Subgroup | Windows | What it judges |
| --- | --- | --- |
| the texture examples | none | a PNG through the production backend, drawn frame-less and read back against the render-2d oracle; the largest legal level; accounting returning to rest |
| `validated data texture pixels (TRA-15)` | none | the same file as colour and as data (128 reads 128 and 188) |
| `Lua offscreen pixels` | none | what Lua authored, as pixels ([below](#lua-offscreen-pixels-lfe-24)) |
| `window provider` | real | two instances' windows, one ended with the peer usable, a genuine native close. No pixel |
| `scene retention` | real | holds and release through the host's frame events and scene state. No pixel |
| `graphics facade` | real | the quad example and input polling on the production host. No pixel, and **no key, button or scroll is delivered**: real native event delivery through the adapter is not covered here |

## Lua offscreen pixels (LFE-24)

Tests and technical fixtures only: the pixel evidence for the Lua-first quad,
read from a real managed colour target after the work that drew it completed.
It shows no native window, resize or window retirement.

**What runs for real.** The roles of a real `runSession` from content copied
to a temporary root: the Lua VMs, verified reads, the PNG decoder, upload and
registration, `graphicsInjection`, publication, the host's adoption, hold
ledger and release barrier, and `frameCandidate`. The shipped
`samples/lua-quad/content` runs unchanged.

**The one thing replaced** is the display target. The test-only display
adapter (`Test.LuaEngine.Graphics.Native.Display`) answers the window
provider's `Port` with a surface-free offscreen scene target, using only the
host's public interface: `registerVulkanSceneTarget`,
`unregisterVulkanSceneTarget`, `offscreenTargetAnswer` with
`scenePublisherOver`, `recordVulkanTargetBatch` and `readVulkanSceneState`. It
keeps no hold, barrier, ledger or lifecycle of its own.

**A rendering.** Inside `recordVulkanTargetBatch` the adapter takes the
`frameCandidate` output for the adopted scene, retargets it in its pass target
alone to a managed RGBA8 sRGB colour target, records it with the public
`prepareSnapshot`, and copies the target to a readback buffer. The bytes are
read only after the batch's own ticket reports completion.

**Judging an image.** Three judges, none of them the code under test
(`Test.LuaEngine.Graphics.Pixels`): hand-stated expectations worked out from
the committed texel tables; the render-2d oracle over a snapshot written from
the same specification; and the oracle over the published scene, judging every
pixel of the readback. Indeterminate pixels count for no success.

**Pacing without sleeping.** A program's steps are gated on optional texture
requests the example holds at the read pool's reader (`holdReadsOf`). The gate
file is not a PNG, so releasing its read ends the request with an ordinary
decode failure and no upload.

The device-free half is the `Lua offscreen pixels comparator` group of
`lua-engine-graphics-tests`. The committed fixtures, their generator and
SHA-256 are in
[`test-common/fixtures/pixels/`](test-common/fixtures/pixels/README.md):
technical test assets, not production art.

## Limits

- The completion wake is the GPU model's change: the adapter assumes the only
  uploads in the session are its own and the table's placeholder. A completion
  that changes no model state would not wake a waiting job.
- A texture an adopted scene holds retires only when that scene is released.
  The backend's scope drains until every texture is retired, so **the window
  provider's scope must exit before the backend's**.
