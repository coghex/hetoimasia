# First windowed Vulkan backend design

Carry Synarchy's proven windowing and Vulkan decisions into independently owned
Hetoimasia components, with a visible triangle as the first graphics milestone.

Design state: `exploring`

Owner: `coghex/hetoimasia`; publication target: `master`.
Started 2026-09-12. This is an exploratory design draft, not an implementation or a
ready issue specification. The owner accepted separate GLFW/Vulkan components
and a first main-thread window/render loop. Infrastructure comes first: establish
messaging, runtime initialization/lifecycle, threading, and independent GLFW
windowing before Vulkan work. The triangle is the eventual first graphics
result, not a reason to accelerate past these foundations. See D-6.

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Establish the first windowed Vulkan backend

Child slices remain undrafted until the prerequisite scope and remaining
compatibility/lifecycle choices below are settled. Do not process this document
yet.

## Epic contract

- **Goal:** an independent application renders a triangle in a GLFW/Vulkan
  window on both macOS and Linux, using Hetoimasia's logging and resource scopes.
- **Done when:** the windowed result and its lifecycle are demonstrated on both
  platforms, with explicit completion and teardown behavior. The exact window
  behavior and verification environments remain Q-3.
- **Users and operators:** the owner developing the backend and later 2D/3D
  consumers; agents implementing and testing its bounded parts.
- **Arc label:** none proposed yet.

## Current handoff at `9300962` — 2026-09-17

The CPU runtime, messaging, and independent GLFW implementation are now present.
Logging, resources, runtime, and messaging arcs are complete. GLFW issues
#87–#100 merged through PRs #101–#114, including the main-thread host, dynamic
windows, native input, and shared native fixture. The
[completion review](project_review_114-101.md) produced repairs #115–#118,
now merged through #119–#122. The [repair review](project_review_122-119.md)
found follow-up #123 (the recovery association after a move between live
monitors), now merged in PR #126. Native desktop-test consent #124 merged in
PR #128. Epic #86 is closed; none of these repairs remains an implementation
gate. This design remains exploring.

The owner requested a pre-Vulkan backlog on 2026-09-16. Scheduling now has its
own [design](runtime_scheduling_design.md), with six reviewed slices; CPU-side
graphics lifetime integration has its own
[design](window_graphics_lifetime_design.md), with four reviewed slices.
Both prerequisite documents have now been fully processed: scheduling epic #131
owns #133/#134/#135/#136/#138/#139, and lifetime epic #140 owns #141–#144.
Those approved issues, including their canonical approval amendments, own the
prerequisite implementations. This Vulkan document owns actual surface
integration and GPU completion;
do not draft duplicate TIME or LIFE slices here.

The active work is to settle window/surface borrowing and dynamic retirement,
GPU and presentation completion on every exit path, frame scheduling alongside
the existing owner loop, and the actual platform/toolchain verification baseline.
The present loop decides idleness from command/event dispatch counts; it does
not yet express continuous renderer demand. None of these GPU choices is
settled by the CPU scope or by completing the GLFW arc.

The GLFW arc supersedes the early windowing proposals below. Keep its accepted
multiple-window ownership and capability boundaries; do not reimplement the
runtime, messaging, window binding, or fixture from historical inventory text.
Linux remote CI and local Cocoa verification remain fixed owner decisions.

### Integration review on 2026-09-16

Source and the open tracker were checked again at `5d381cf` (code unchanged
since `727f59a`). The three reported error paths map exactly to existing repairs;
the two integration boundaries have design coverage here but no open delivery
issue. Do not treat completing the repairs as completing these boundaries.

| Concern | Verified evidence | Disposition |
|---|---|---|
| GPU dependents can outlive a CPU borrow | `Runtime/GLFW/Internal.hs`: `beginClose` and `retireClosing` protect collection borrows, with no graphics-owner retirement acknowledgement. Final host scope exit also releases remaining windows. | Extend the integration lifetime under P-5/Q-2/Q-7 before creating a persistent surface or submitting GPU work; this is outside the delivered GLFW-only contract. |
| Rendering demand does not prevent an idle wait | The same module's `runOwnerLoop` computes the next idle flag from command/event counts only; `Continue` carries no deadline. `defaultHostConfig` sets `hostIdleWait = 0.1`. | P-6/Q-6 must precede a continuously updating/rendering consumer. Native events can end waits early; this is a potential 100 ms delay, not a fixed frame-rate guarantee. |
| Worker command admission does not wake the owner | Public command admission is `IO` around bounded STM admission. It makes no production native wake call. `noteProgressForCheck` calls `glfwPostEmptyEvent` only as a native-test helper. | Design a production wake protocol under P-6, including its session lifetime and admission/cancellation races. The test hook supplies no production guarantee. |
| Creation failure is lost when rollback fails | `createWindow` classifies the native failure as rejection without checking retained cleanup evidence; `testRollbackCleanupPoisons` expects the later cleanup primary. | Covered by [#115](https://github.com/coghex/hetoimasia/issues/115). |
| Observation erases disconnect recovery | `presentationFrom` replaces applied mode; `reconcileWindowMode` derives its pending recovery from that mode. | Covered by [#116](https://github.com/coghex/hetoimasia/issues/116). |
| Partial departure loses the latest windowed placement | `modeAttempt` records `leaving` only on successful completion of all steps. | Covered by [#117](https://github.com/coghex/hetoimasia/issues/117). |

Runtime-host source above is under
`packages/glfw/runtime-glfw-core/Hetoimasia`; window-model source is under
`packages/glfw/model/Hetoimasia/GLFW/Internal/Window.hs`. The independently
filed fixture cancellation repair [#118](https://github.com/coghex/hetoimasia/issues/118)
was also required for reliable native lifecycle evidence. All four repairs in
this historical review subsequently merged; the current handoff above records
their review and the subsequently merged follow-up #123. This table is a dated
historical assessment, not a list of current open defects.

## Completed foundations and prior evidence

The historical pre-GLFW inventory is superseded by implemented contracts:
[CPU resources](resources.md), [runtime/supervision](supervision.md),
[messaging](messaging.md), and [GLFW](glfw.md). The continuation facade,
application composition, component state, worker ownership and failure evidence
are delivered; do not rebuild Synarchy's combined Reader/State EngineEnv.

This arc refines FND-2/FND-3 of the older [foundation design](engine_foundation_design.md).
D-1 supersedes that document's early offscreen-first sequence. TEST-2/#93 and
its repair #118 delivered the GLFW-only shared fixture; actual GPU completion
and GPU fixtures belong here. Prior reviews and Git history retain the original
bootstrap inventories; they are not current prerequisite lists.

### Synarchy behavior to carry forward

Read-only inspection of `~/work/synarchy` at
`91fec430ea5596f497d76eb720de9940aeeb6c39`; no game was launched or code changed.
These are current implementation observations, not a comprehensive Synarchy
audit or a claim that every implementation detail should be copied.

| Synarchy source | Useful behavior and intended adaptation |
|---|---|
| `src/Engine/Graphics/Window/GLFW.hs` and `Window/Types.hs` | Explicit window configuration, `NoAPI`, visibility/focus policy, and live geometry sampled after creation. Preserve the distinction between requested configuration and what the platform actually created. Keep hidden automated windows non-activating where supported. |
| `src/Engine/Input/Callback.hs` | Short callbacks publish typed events. Window/framebuffer/focus state continues updating during startup; user-intent input has a separate lifecycle gate. Preserve this separation when input arrives, and keep teardown out of callbacks. |
| `app/App/Graphical.hs` and `src/Engine/Loop.hs` | Application composition connects window creation, callback installation, Vulkan initialization, and the windowed event/render loop. Keep this coherent owning-thread flow while narrowing each component's dependencies. |
| `src/Engine/Graphics/Vulkan/ResizeRequest.hs` | Pure resize decisions; compare the observed framebuffer state with the state a swapchain was built for. Preserve zero-area handling, minimize/restore history, and the distinction between requested size and clamped extent. A newer resize must survive an earlier rebuild. |
| `src/Engine/Graphics/Vulkan/Instance/Plan.hs` and `Instance.hs` | Separate capability decisions from queries and creation. Obtain required surface extensions through GLFW; distinguish required support from optional diagnostics and portability support. |
| `src/Engine/Graphics/Vulkan/Device.hs` | Select graphics/presentation queues with the real surface; avoid duplicate queue creation when families coincide. Enable advertised portability-subset support when required. Triangle requirements should be stated independently of Synarchy's bindless renderer. |
| `src/Engine/Loop/Frame.hs` and `Vulkan/Sync.hs` | Acquire before resetting the submission fence; consume an image acquired with `SUBOPTIMAL`; index presentation-wait semaphores by swapchain image. Preserve these reasons explicitly in implementation and tests. |
| `test/Spec.hs` and `test/Test/Engine/Graphics/Window/GLFW.hs` | Keep the resource continuation around all borrowers. Test project-owned creation through actual observations, including sentinel initial values that cannot accidentally satisfy postconditions. Distinguish environment preflight from engine assertions. |
| `src/Engine/Core/Queue.hs` and `test-headless/Test/Headless/Core/Queue.hs` | Typed STM FIFO transport, transactional dequeue/timeout choice, atomic depth/high-water telemetry, and careful payload laziness that keeps backlog traversal outside ordinary queue transactions. The queue is explicitly unbounded; telemetry does not supply admission or scheduling policy. |
| `src/Engine/Input/Thread/Dispatch.hs` | Ordered input processing publishes each processed state before later events are handled. Preserve causal ordering when another component observes that state and receives related messages. |
| `src/Engine/Core/Thread.hs` | A reusable worker skeleton already exists independently of EngineEnv: worker-specific actions are supplied through a spec. Preserve the distinction between requesting stop and confirming completion, and establish failure state before attempting diagnostic output. Re-evaluate its masking and shutdown policy against Hetoimasia's resource contract when introducing a worker. |

Additional read-only inspection at Synarchy
`064a255f06b59e2b1f8e881dcf4c747d52967a36` on 2026-09-16:
`src/Engine/Core/Clock.hs` provides an injected monotonic source,
`sanitiseElapsed`, and `sampleElapsed`. Its interruption policy caps an elapsed
step at 0.25 seconds and always replaces the previous raw sample, dropping excess
time instead of accumulating catch-up debt. Preserve the separation of elapsed
time from wall-clock timestamps and the testable clock boundary. The numerical
cap and drop policy are evidence for Q-6, not automatically adopted settings.

Implementation handoffs should identify the precise Synarchy functions being
adapted and retain their relevant regression cases. Do not substitute a generic
tutorial implementation without comparing it to this evidence. Keep any copied
code's provenance and applicable license notices. The integration should accept
narrow services and handles; Lua queues, game managers, and EngineEnv are not
dependencies of these new owners.

## Desired experience and scope

The first graphical consumer opens a window and displays a triangle on both
selected platforms. The existing console and headless foundation remain usable
without installing or initializing graphics dependencies. Windowed launches are
explicit. A build alone cannot demonstrate the displayed result.

This milestone starts the backend; the broader plan still includes independent
2D/3D consumers and Lua. Which adjacent window behaviors belong in this first
milestone is proposed below, pending Q-3. A triangle does not establish a scene,
camera, asset, or game-facing rendering abstraction.

## Decisions accepted by the owner

### D-1. Reach a window with a rendered triangle first

Explicit owner selection in the preceding design conversation. An offscreen
scene is not the first user-visible milestone. Capture can still provide test
evidence for the windowed milestone. D-6 clarifies that this is the first
graphics result after the infrastructure is established, not the immediate
development target.

### D-2. Verify macOS and Linux from the start

Explicit owner selection on 2026-09-12. Both platforms need evidence before
claiming this first graphics milestone complete.

### D-3. Keep remote CI Linux-only and macOS validation local

Explicit owner clarification on 2026-09-12. Do not add hosted macOS jobs.
Describe local macOS commands and retained results alongside the Linux checks.
The exact Linux graphics execution environment still needs Q-3; current hosted
CPU checks alone do not verify Vulkan or presentation.

### D-4. Preserve Synarchy's successful GLFW integration decisions

The owner explicitly requested inspection and retention of the spirit of that
work, calling the GLFW integration solid. Start from the relevant existing
behavior and its rationale. Adapt it to the accepted modular ownership policy.

The existing architecture, logging, resource failure policy, Hspec preference,
and selective validation contracts remain applicable; this arc does not replace
them.

### D-5. Separate GLFW and Vulkan; drive the first loop on the main thread

The owner explicitly accepted the proposed ownership/threading direction:
separate GLFW and Vulkan components, with the triangle application processing
events and rendering on the process main thread, adhering to Synarchy's flow.
The first sample does not require a render worker. This settles Q-1's high-level
choice; concrete APIs and package placement still follow the agreed boundaries.
It does not approve every detail of Synarchy's existing worker implementation.

### D-6. Establish the infrastructure methodically before Vulkan

The owner explicitly accepted a queue foundation before graphics, then clarified
that logging, messaging, runtime initialization, GLFW windowing, and ideally
threading should be solid before touching Vulkan. The owner has built triangle
applications many times; reaching another triangle quickly is not the purpose
of this phase.

Keep the completed logging/resource work. Establish reusable messaging with
Hspec coverage, design application/service initialization and state ownership,
and include worker lifecycle and independent GLFW integration in the pre-Vulkan
plan. Worker behavior can be developed and verified through headless Hspec
consumers before it is needed by rendering. Do not postpone threading solely
because a triangle could run without it.

The runtime, worker, messaging, and GLFW slices subsequently landed, followed by
the four GLFW repairs and follow-up #123. The agreed main-thread
GLFW/render ownership still holds:
reusable worker support does not move GLFW operations to a worker. Remote
Linux/local macOS validation and deliberate reuse of Synarchy remain accepted.

## Design

### P-1. Separate owners; begin with one main-thread window/render loop

High-level direction accepted by D-5; the following responsibility sketch
guides the concrete interface design.

Proposed component responsibilities, not final package or API declarations:

| Owner | Owns and mutates | Borrowers and lifetime |
|---|---|---|
| Application composition | Configuration, connected services, exit request | Assembles scopes and runs the first loop; no game state is required. |
| GLFW component | Process GLFW session, windows, callbacks, observed geometry/events | Windows borrow the session. Callback storage lives until callbacks are detached and window use has ended. Session/window/event operations remain on the process main thread. |
| Vulkan component | Instance/device resources, submission state, swapchain generations | Surface integration borrows the window and instance. A generation owns its dependent images/views and synchronization resources; completion constrains destruction. |
| Triangle consumer | Triangle-specific shaders/pipeline choices and draw commands | Borrows the backend's scoped capabilities. Later rendering modules can replace this consumer. |

Use one explicit interop boundary for GLFW surface creation; the core GLFW
owner should not need the renderer, and Vulkan device machinery should not
query a game or Lua service. Place that boundary once its smallest concrete
API is agreed. Keep Vulkan-specific types inside backend/integration consumers;
do not freeze a universal graphics interface for one triangle.

The first GLFW loop will process events and consume window-state changes on
the process main thread. Drawing joins that loop only after the infrastructure
phase. Reusable workers developed in that phase retain their own explicit
ownership and communication contracts.
GLFW's [thread contract](https://www.glfw.org/docs/latest/intro_guide.html#thread_safety)
requires initialization, termination, window creation/destruction, and event
processing on the thread that calls `main`. A Haskell bound worker is not proof
of that identity. The eventual graphics test runner must preserve it too.

## Design proposals

### P-2. Preserve lifecycle behavior before adding rendering breadth

Use the existing GLFW windows, including their already delivered controls and
mode changes. Define the backend's response to close, minimize/restore, mode
changes, and framebuffer resize, including high-DPI sizes. Fonts, texture
streaming, and scene rendering remain outside this first graphics milestone.
Start with one frame
in flight if that simplifies the initial completion contract; swapchain image
ownership still remains separate from frame slots.

Retain the resize and synchronization lessons above through pure decision tests
and real integration evidence. A failed recording/submission after fence reset
also needs an explicit exit path: the loop must not wait forever for a submission
that never occurred. Recovery policy and full completion behavior remain Q-2.

### P-3. Establish a small message-passing foundation before its GLFW consumer

Completed by messaging epic #73; Q-4 is resolved. Use bounded channels,
prepared payloads, snapshots and supervised inboxes from [messaging.md](messaging.md).
The historical transport proposal is superseded by that implemented contract;
no additional queue abstraction or event-bus delivery belongs in this arc.

### P-4. Design scoped application composition and component-owned state

Completed by runtime epic #52 and its repairs; Q-5 is resolved. Use narrow
services and explicit application composition under the existing failure and
supervision contracts. LIFE-2/#142 adds the managed dependency lifetime needed
by graphics; it is not a reason to rebuild the runtime or add EngineEnv.

### P-5. Integrate graphics retirement with both window close and host exit

The backend-neutral attachment, protected host lifetime, and all-exit drain now
belong to [window_graphics_lifetime_design.md](window_graphics_lifetime_design.md).
Its D-1 records the accepted single graphics owner per window. The sketch below
retains the Vulkan integration obligations; its former unspecified CPU API is
not a second implementation plan.

Proposed boundary, pending Q-2/Q-7; no GPU lifetime API exists yet. A synchronous
`withHostWindow` borrow protects its callback only. Returning from that callback
must not authorize native destruction while a surface or submitted work still
depends on the window.

- Give the graphics integration an opaque, window-specific lifetime attachment.
  Establish it before creating dependent native resources; refuse new
  attachments once closing begins. Define rollback and cancellation protection
  across acquisition and registration, with no unprotected handoff interval.
- Closing ends admission and new rendering for that window, while its existing
  graphics owner retires dependent work. Keep the window alive until dependent
  resources have been disposed under the selected completion contract and the
  attachment acknowledges retirement. Only then may the owner thread perform
  native destruction, also respecting ordinary CPU borrows. Windows without
  graphics attachments retain their current close behavior.
- Bind acknowledgements to the exact attachment and window identity. Repeated,
  foreign, stale, or prematurely released tokens must not free another window;
  keep bookkeeping proportional to live dependents. Other windows must remain
  serviceable while one window retires, subject to the native-call limitations.
- Apply the same lifetime protection on whole-application shutdown, startup
  failure, loop failure, and repeated cancellation. Guarding only `retireClosing`
  is insufficient: collection scope exit currently releases every remaining
  member. Place a protected graphics drain outside uninterruptible foundation
  releases, before dependent CPU scopes can unwind. The existing finite STM
  quiescence hook may signal closure but cannot perform that drain. Specify its
  order relative to worker drain and main-thread progress so no worker awaits
  commands after the event loop has ended.
- The graphics owner must distinguish submission completion from presentation
  retirement. A submission fence alone is insufficient evidence for presentation
  resources, as the [Khronos guide](https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html)
  explains. Cancellation, timeout, and device loss are not interchangeable with
  successful completion. Q-2 must define supported terminal paths and preserved
  failure evidence before any implementation promises safe teardown.

Keep the interop boundary narrow: copy required instance-extension names from
GLFW and create a surface for a verified live window under the attachment. The
integration owns the surface's disposal; GLFW does not dispose it, per the
[GLFW Vulkan guide](https://www.glfw.org/docs/3.4/vulkan_guide.html).
Keep native window pointers private and Vulkan types in the backend/integration
component, with no renderer dependency in the ordinary window host. Package
placement and the exact scoped API remain Q-7.

For later buffers/textures, distinguish logical release, disappearance from
snapshots or pending render work, and completion of the last submitted use.
The GPU owner retains resource generations until both CPU consumers that can
submit them and submitted uses have retired. This establishes the lifetime
rule without adding an asset manager or texture-streaming system to this arc.

### P-6. Schedule owner turns from demand and monotonic deadlines

This prerequisite is now owned by
[runtime_scheduling_design.md](runtime_scheduling_design.md). Its accepted
direction includes all three update styles and per-window render suspension
without automatic simulation pause. The sketch below remains context; use that
document's policy review and delivery ledger for implementation.

Proposed extension, pending Q-6. Keep clock/scheduling decisions independently
testable, the native event pump in GLFW, and simulation/presentation policy in
the application and its rendering integration. No universal engine environment
or mandatory render worker is needed.

- Express immediate work, an absolute monotonic deadline, and no current demand.
  Re-evaluate demand after updates and native waits. Choose polling or a finite
  wait from ready work, the earliest deadline, and the existing checkpoint
  latency bound. `loopUpdate` work must influence this choice without treating
  every update as a reason to spin.
- Separate simulation elapsed time, simulation step policy, render demand, and
  presentation backpressure. Charge time spent working against the next deadline;
  do not add a fixed sleep after each frame. Command/native-event traffic must
  neither starve due updates nor force unnecessary redraws. Keep existing
  bounded dispatch and supervision checkpoints.
- Define per-window suspension for zero framebuffer extent and the selected
  minimized/hidden policy. One suspended window must not pause other windows or
  imply that the application's simulation stops. With no due work, wait rather
  than spin. Resume/rebase after long interruptions with explicit bounded
  catch-up or dropped debt; never replay an unbounded backlog of ticks.
- Add a session-owned wake capability for accepted work or earlier deadlines
  arriving during a native wait. GLFW 3.4 permits
  [posting an empty event from another thread](https://www.glfw.org/docs/3.4/group__window.html#ga02d4e09d1b316b7e6d1cd17f8cae3fa0)
  to end the wait, but callers still need a live session. Prevent wake calls from
  racing termination and retire the wake capability before the session ends.
  Existing retained command ports must remain safe after closure.
- Specify the interval between STM admission and the IO wake: cancellation or
  native wake failure must not strand accepted work, hide its admission, or
  replay it. Notifications are hints; queue/demand state remains authoritative.
  Cover admission before wait entry, during the wait, and while shutting down.
  Retain finite waits as a fallback and preserve failure attribution. Do not
  promote the native-test wake hook into production as a shortcut.

The current 0.1-second bound remains the documented window-host behavior until
this additive extension lands. Reducing that constant alone supplies neither
frame pacing nor a wake protocol. Scheduling gives a chosen wait budget, not a
hard real-time guarantee for arbitrary hooks, native calls, or GPU backpressure.

### P-7. Establish one loader and a narrow surface bridge

Proposal added after the independent readiness review on 2026-09-17; it is not
an approved package/API declaration. Surface integration already had a design
home in P-1/P-5, but has no delivery issue and is excluded from LIFE-4.

Own the Vulkan loader outside both the GLFW session and Vulkan instances. Give
the backend and GLFW the same loader's `vkGetInstanceProcAddr`; do not mix a
direct MoltenVK instance with a different loader's dispatch. Resolve platform
loading and ABI details through the Q-2 compatibility proof first.

An additive session-construction option supplies the loader function before
`glfwInit` on the process main thread, after session exclusivity is established.
Preserve the ordinary window-only entry point. GLFW 3.4 documents that this
setting survives termination and only takes effect at initialization: explicitly
select a loader or the default for every session and clear retained borrowed
configuration before unloading its library, including failed initialization.
The loader remains live through its last GLFW and Vulkan use. No arbitrary
user initialization callback belongs in a bounded release or admission lock.
See [GLFW's loader contract](https://www.glfw.org/docs/3.4/group__init.html).

The bridge copies required instance-extension names while the session is live,
creates a surface only under the protected window attachment, and hands typed
ownership to the backend. Partial construction, cancellation, failed destruction
and instance/window mismatch need explicit outcomes. A borrowed raw window
pointer is never a persistent surface lifetime. The backend disposes the surface
before acknowledging the attachment's retirement and before destroying the
instance; GLFW does not destroy Vulkan surfaces for it.

Use a dedicated public interop sublibrary only if the selected binding needs
that boundary. The ordinary GLFW API stays independent of the Haskell Vulkan
package and of game renderers. Keep ABI representation in a private, verified
adapter; do not invent unchecked `Ptr ()` conversions to avoid headers. Decide
whether the bridge's implementation uses Vulkan headers in its own build once
the binding is chosen. Extend the small GLFW scripted seam for the operations
actually added; do not mirror all Vulkan entry points. Instance proc lookup can
come from the already owned loader/binding rather than a redundant GLFW wrapper.

Device selection may query a real surface without making a shared device's
lifetime a child of the first window. Record the final ownership graph and how
subsequent windows validate presentation support before multi-window rendering.
Closing the bootstrap window must not accidentally release another window's
device. This is distinct from the already accepted first main-thread owner.

### P-8. Retire GPU generations beneath the window attachment

Agree with the missing boundary, but start it inside `gpu-vulkan`. A private
pure retirement model with abstract completion facts is testable without a GPU;
that does not require a new foundation-wide resource framework or public
backend-independent API before a second backend exists.

The model distinguishes logical release, ended CPU uses capable of future
submission, recorded-but-unsubmitted references, and completion of every
submitted use. A queued or executable command buffer can retain a resource even
before a submission fence exists. Key obligations by device/queue and resource
generation; one scalar completed serial is valid only after proving a common
submission order. Presentation obligations remain separate from submission
fences. Resetting/re-recording a command buffer and abandoning an unsubmitted
batch must discharge the right references explicitly.

A successful submission publishes its completion obligation atomically with the
owner's bookkeeping under a protected handoff. Cancellation or failed submission
must not leave an unsignallable fence treated as pending work, nor release a
resource whose native submission outcome is uncertain. Terminal device loss is
a distinct policy path, not a synthetic completed fence. Q-2 must establish
which evidence authorizes which destruction on that path.

Use bounded frame arenas, reusable command/descriptor pools and generation
records owned by a small number of scoped roots. Reclaim a frame slot only after
its CPU and GPU obligations end. Bound retired bytes/objects and apply explicit
backpressure when the bound is reached; an indefinitely unsignalled device must
not produce an unbounded deletion queue. Stop admission, retain parent resources,
and preserve disposal failures without replay when safe release is unknown.

The existing Collection is a single-owner CPU primitive, not inherently limited
to windows: a render owner could own its own collection. Do not share one across
threads or turn it into a concurrent GPU registry. `Scoped` is useful beyond
startup whenever lexical ownership fits; it does not supply deferred completion.
Per-frame native allocations should not be the default strategy. There is no
claim that masks alone have been measured as this engine's bottleneck.

### P-9. Prove the toolchain before building the renderer

The first proposed Vulkan work is a compatibility proof, not a triangle or a
general renderer API. Synarchy's inspected local build plan uses GHC 9.12.2,
`vulkan-3.26.6` and `vulkan-utils-0.5.10.6`; both projects pin the Hackage index
at 2026-08-14. This is a useful candidate baseline, not evidence that Hetoimasia
already builds those components on Linux and macOS. Inspect the binding's actual
loader, callback and FFI modes; potentially blocking calls and Haskell callbacks
must remain compatible with the threaded RTS and the chosen failure boundary.

Record exact compiler/binding, loader, driver, validation-layer and shader-tool
versions. Query real capabilities: advertised Vulkan API version alone does not
establish the presentation-completion extensions Q-2 needs. Evaluate the standard
loader with MoltenVK on local macOS and pinned Mesa Lavapipe in the Linux image;
explicitly select the intended ICD so CI cannot silently run another driver.
Software Vulkan gives useful API and image correctness evidence, not hardware
performance coverage. Preserve portability enumeration/subset requirements from
Synarchy and verify them against the selected versions.

Provisioning is its own code-and-docs delivery: extend the existing image recipe,
publish and verify a new digest, update the native/toolchain evidence identity,
and reuse the existing cache path. Do not rebuild/install Vulkan dependencies in
every test job. CPU-only projects must still build without this SDK. Select one
pinned build-time SPIR-V compiler; track shader sources, target environment,
flags and tool identity, and make generated artifacts reproducible/packageable.
Runtime shader compilation and shader hot reload are outside this first arc.

No native Vulkan proof was run during this review. Q-2/Q-3 stay open until the
chosen profile has evidence on both platforms and its failure path is specified.

### P-10. Test the decisions and the native boundary at different levels

Use pure planning/state tests for capabilities, queue selection, resize, frame
transitions and retirement. Add small injected operation interfaces where they
prove effects that pure tests cannot: partial acquisition, failed submission,
callback containment and disposal ordering. Do not build a second implementation
of hundreds of Vulkan calls for tests, or rely on real-device success to prove
rare failure/cancellation paths.

Real integration groups exercise the selected Vulkan implementation with
validation and image/lifecycle assertions; a small isolated Linux software group
should be required when affected, outside the universal floor (proposal for
Q-3). Lengthy stress, performance and extra-hardware probes remain optional.
Local disruptive macOS evidence needs the human's explicit approval each session.
Use the package-owned suite layout from #129/#130; these moves are useful early
landings, not an excuse to block independent compatibility research.

External-client compilation tests prove important public opacity boundaries;
they are not required for every helper. Contract docs should describe ownership,
failure states and usage once, with implementation detail beside its owner.
Neither a test/code line ratio nor component count alone establishes waste.

### P-11. Contain validation callbacks and measure before RTS tuning

The synchronous logger is behaving as designed. `newHandleSinkWith` can disable
per-entry flush, but writes can still block; buffering that handle alone does
not make the render path nonblocking. Avoid changing the foundation logger's
semantics to accommodate a future consumer.

Before enabling validation, provide component-owned bounded diagnostic capture.
The native callback copies capped data into owned storage, contains every
exception, and never formats to a user sink, waits for queue space or calls back
into Vulkan. Preserve a latched error/overflow indication independently of
successful logging. Saturation is visible through counts/truncation and cannot
be presented by an integration test as complete, clean validation evidence.
[The Vulkan callback contract](https://docs.vulkan.org/refpages/latest/refpages/source/PFN_vkDebugUtilsMessengerCallbackEXT.html)
forbids Vulkan calls from the callback.

Report outside the callback and graphics critical path through a bounded,
component-owned consumer. If that consumer is a worker, its lifetime extends
through backend teardown and the last possible callback; do not put it in an
application worker group that drains before graphics retirement. Detach/quiesce
callbacks, drain or account for captured diagnostics, join the consumer, then
release its logger/storage. Sink failure cannot replace the primary Vulkan
failure or authorize unsafe GPU retirement. This is a Vulkan diagnostic adapter,
not approval of an engine-wide asynchronous logger rewrite.

Record an optional reproducible baseline before optimizing: idle CPU use,
allocations and service latency at increasing window/port counts, deadline
lateness under command bursts, and later frame-time distributions/GC pauses.
Existing resource allocation-cost tests are useful but are not a frame baseline.
Record hardware, revision, native/toolchain identity and RTS flags. Choose
capabilities, nursery size and GC mode from measured representative workloads;
do not guess permanent `-N`, `-A` or nonmoving-GC defaults now. Performance probes
belong outside correctness CI and must not turn timing noise into Hspec failures.

### P-12. Make waits cooperative without promising driver preemption

Prefer finite fence/timeline/acquire timeouts, with explicit Pending/Timeout,
stop checks and owner progress between attempts. Normal owner-loop retirement
uses nonblocking progress opportunities so one closing window does not stall
another. Stop ends new admission; it does not end outstanding GPU use. Protected
shutdown may still retain dependencies while completion cannot be established.

Audit each actual API: queue/device idle have no timeout parameter and are not
the normal frame pacing or blanket retirement mechanism. Some driver calls can
block despite having no explicit wait in their name. Neither a Haskell timeout,
async exception nor safe FFI can promise to interrupt arbitrary foreign code.
Keep GPU waits out of foundation's uninterruptible release callbacks and specify
the behavior of native destroy calls under the chosen backend policy.

The review's claim that device loss necessarily leaves a Vulkan wait stuck is
too strong: [Vulkan requires those waits to return in finite time after device loss](https://docs.vulkan.org/spec/latest/chapters/devsandqueues.html#devsandqueues-lost-device).
A defective driver can violate that guarantee. A caller-selected finite timeout
is also not a hard wall-clock bound. Preserve the accepted retain-and-wait
policy, report a stalled condition without flooding logs, and document external
process termination as the operator escape. Hard in-process shutdown guarantees
or a separately killable renderer process would be a new design, not an implied
change to worker drain. Presentation still needs its own Q-2 completion proof;
queue/device idle alone does not supply it.

## Open questions

### Q-1. Accept P-1's component ownership and first thread model?

Resolved by D-5. Separate components and the first main-thread loop are accepted.
Frame work can delay event handling; a future render worker requires its own
handoff and lifetime contract. Exact package names follow the agreed boundaries.

### Q-2. What compatibility and completion contract should the backend require?

P-7/P-8/P-9/P-12 now identify the loader, ABI, GPU-generation and wait-policy
proofs this answer must include. No SDK/binding/API version or completion
extension has been adopted merely because a source advertises it.

Inspect the actual macOS/MoltenVK and Linux environments before selecting the
minimum Vulkan version, extensions, shader compiler/toolchain, and presentation
completion mechanism. Synarchy currently requests Vulkan 1.2; that is evidence
to evaluate, not an approved Hetoimasia baseline.

CPU scope exit is insufficient. Define how normal close, body failure,
cancellation, submission failure, and device loss stop new work and retain
ownership until eligible destruction. Waiting only at the normal end of a body
does not protect exceptional exits. Foundation releases run uninterruptibly:
no GPU fence/queue/device wait belongs inside them, and every native finalizer's
controlled blocking behavior must be established.

The [Khronos presentation guide](https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html)
also distinguishes submission completion from presentation completion. Per-image
semaphore reuse addresses normal frames; shutdown and old-swapchain disposal
need their own proof. The guide documents a gap in relying on device/queue idle
alone for unextended presentation and describes maintenance-extension fences.
Evaluate supported mechanisms and any compatibility fallback explicitly. Do not
silently promise safe destruction on an unproven timeout or on cancellation.

This is backend lifecycle work, not another repair of the CPU resource library.
Settle it before any slice submits GPU work or promises complete cleanup.

### Q-3. Accept P-2's window scope, and where will Linux graphics execute?

P-10 proposes a small required-when-affected software Vulkan group plus optional
stress/performance/hardware groups. Confirm that policy with the measured native
profile; do not add all graphics work to the mandatory floor by inheritance.

Remote CI remains Linux-only; local macOS validation is settled by D-3. Determine
whether Linux windowed evidence uses an available desktop/GPU, a Linux CI display
with a software Vulkan implementation, or both. State exactly what each proves;
software rendering does not establish hardware-driver coverage. Decide which
graphics groups are optional/requested under the existing catalog and which
evidence is required to complete this milestone. Do not silently enlarge the
mandatory floor or turn an unavailable requested environment into a pass.

GLFW's window manipulation and dynamic-close scope is already implemented.
Define the Vulkan resize/minimize/close behavior and dependent lifetime proof
with this verification choice; do not reopen the GLFW scope decision.

### Q-4. Establish P-3's small queue foundation before GLFW/Vulkan integration?

Resolved and implemented by messaging epic #73, issues #74–#79 and PRs #80–#85.
Use the existing bounded channels, snapshots, and inbox contracts in
[messaging.md](messaging.md). No further queue prerequisite or generic event bus
is authorized by this historical proposal.

### Q-5. What is the runtime composition and initialization contract?

Resolved and implemented by the [runtime foundation design](runtime_foundation_design.md),
including D-13 through D-18 and P-10 through P-13. Epic #52 and children #53–#60,
plus repairs #69/#70, delivered errors, recovery, construction, worker ownership,
logging lifetime, supervision, and application integration. GLFW subsequently
added the pre-drain quiescence hook. Use those contracts; do not reopen them.
The remaining gates are the scheduling and dependent-lifetime implementations
and the GPU lifecycle/platform choices here. Follow-up #123 is satisfied.

### Q-6. What timing, suspension, and wake policy should the first consumer use?

Delegated to [runtime_scheduling_design.md](runtime_scheduling_design.md).
Owner accepted event/deadline/fixed-step support with configurable limits and
per-window render suspension independent of simulation. That document's D-5
records its completed final review and readiness; epic #131 owns delivery.
No fixed 0.25-second cap
or simulation rate has been silently inherited from Synarchy.

### Q-7. What scoped attachment API connects graphics owners to windows?

Delegated to [window_graphics_lifetime_design.md](window_graphics_lifetime_design.md).
The owner accepted one exclusive graphics owner per window. That document's
D-5 records review of its protected IO host lifetime and managed application
composition; epic #140 owns delivery. The attachment API itself is settled
there. Vulkan-specific surface interop remains open under P-7/Q-2, and no
attachment acknowledgement may substitute for real GPU-completion proof.

### Q-8. What diagnostic and measurement policy should the backend adopt?

P-11 proposes bounded callback capture and an off-owner diagnostic consumer,
with visible loss and a lifetime through the final teardown callback. Confirm
its delivery scope and capacity/overflow policy before enabling validation.
Measure optional owner-loop and frame workloads before choosing permanent RTS
settings. This is not a request to reopen the completed synchronous logger.

## Verification strategy

Use Hspec for pure capability/queue/extent decisions, state transitions, and
effectful ownership tests. Preserve independently buildable CPU components and
headless suites. The Cabal/project layout and catalog must explicitly account
for graphics dependencies without making the console depend on them.

Use separate execution groups for graphics requirements. Describe the actual
runner, toolchain, consumed shaders and fixtures, and required environment.
Keep evidence tied to the tested inputs and platform under the existing
[validation contract](validation.md); local macOS evidence cannot substitute
for Linux evidence. Reuse current selection and freshness rules.

TEST-2/#93 delivered the GLFW fixture; #118 repairs its repeated-cancellation
drain. Build any Vulkan fixture on the existing ownership and main-thread
dispatch lessons, with GPU-specific completion proof in this arc's own slice.
Selected compatible examples share expensive roots; example state stays private;
destructive lifecycle tests use private roots. Discovery and dry runs must not
initialize graphics. Demonstrate thread ownership independently of Hspec hook
names; introduce no second generic fixture framework.

Before hardware tests, use scripted completion and clock sources to verify:

- Closing one attached window cannot destroy it before graphics retirement;
  another window continues. Repeated/foreign acknowledgements and attachment
  attempts after close cannot bypass the guard.
- Normal return, startup/body failure, submission failure, and repeated
  cancellation all protect native windows through the graphics drain. Failed
  disposal preserves primary and cleanup evidence; no GPU wait occurs in an
  uninterruptible foundation release. Scripted device-loss handling must match
  the eventual explicit Q-2 contract.
- A replaced snapshot or logically released resource cannot invalidate a still
  retained CPU generation or pending GPU use.
- Continuous demand with quiet queues does not select the old idle wait;
  pending deadlines account for work duration, event floods remain fair, and
  no-demand/suspended windows do not spin or pause other windows.
- Long interruptions obey the selected debt policy. Admission/wake races,
  wake failure, repeated cancellation, and stale ports after termination leave
  neither stranded tickets nor native calls against a dead session.

Use coordinated Hspec seams rather than timing sleeps for correctness. Native
X11/local Cocoa evidence must separately demonstrate the production wake path;
scripted tests cannot prove that a platform event wait actually wakes.

Real graphics checks should retain triangle pixels, validation output, observed
framebuffer dimensions, and lifecycle results for both platforms. Proposed
window cases include resize, zero area, restore to the same dimensions, close,
and failure during partial setup or submitted work. Exact capture and failure
injection procedures follow the agreed backend contract; none were run here.
Required contracts and evidence belong in each implementation PR.

## Delivery plan

No Vulkan child slice is ready for processing. The owner has not signed off
P-7 through P-12 or selected the Q-2/Q-3/Q-8 profiles. Existing TIME/LIFE issues
already own the CPU prerequisites; #123 is merged. The first three pre-Vulkan
documents require no more processing. The older foundation umbrella must not
create duplicate GPU issues beside this document.

Recommended work order for the next design session (candidate boundaries, not
filed issues or approved child specifications):

1. Prove the binding, shared loader and platform capability profile, including
   viable presentation retirement on macOS/MoltenVK and Linux software Vulkan.
   Use bounded research and candidate provisioning; do not claim a renderer.
2. Deliver the pinned native recipe/image and shader build inputs, with cached
   artifacts and accurate CI identity. Keep code, evidence and docs in that PR.
3. Add loader-aware GLFW construction and the narrow surface bridge, staged so
   protected LIFE ownership is in place before a surface outlives a CPU borrow.
4. Deliver backend-local generation/retirement planning and its injected failure
   proofs, then connect concrete submission and presentation completion. Pure
   model work can proceed alongside the bridge; live submissions wait for both.
5. Establish bounded validation capture before enabling validation and real GPU
   fixture checks, then integrate frame/swapchain behavior with TIME scheduling.
6. Add the triangle consumer and both-platform lifecycle/image evidence. Record
   an optional performance baseline and tune only against actual measurements.

Split these into one-PR slices after the compatibility evidence determines their
scope; mirror those IDs in the ledger before readiness. Surfaces, submission,
presentation completion and diagnostics must not disappear into one oversized
triangle issue. No new tracker artifact is created by this review.
