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

## Current handoff at `727f59a`

The CPU runtime, messaging, and independent GLFW implementation are now present.
Logging, resources, runtime, and messaging arcs are complete. GLFW issues
#87–#100 merged through PRs #101–#114, including the main-thread host, dynamic
windows, native input, and shared native fixture. The
[completion review](project_review_114-101.md) produced repairs #115–#118;
verify those before Vulkan implementation. This design remains exploring.

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

## Historical pre-GLFW baseline and evidence

Hetoimasia inspected at `7e92e73d5eed7e564e9752ee49cce0eb5ba150c2`:

- Issue #47 / PR #48 closes public record updates of retained cleanup failures.
  Its three readers remain available; the hidden positional representation
  binds failure identity to unchanged evidence. External-client tests cover
  rejected updates and permitted inspection/reattachment.
- TEST-1, issue #50 / PR #51, composes Logging, Runtime, and Resources without
  changing the resource spec tree. The moved 59 example descriptions and 102
  typed test/helper bindings match their pre-refactor versions.
- Independent review passed all 145 engine and 262 workflow examples, build,
  console smoke, and focused Logging/Runtime/Resources selections (49/10/86).
  An unmatched selection exits unsuccessfully. No current repair was found in
  these two PRs. This verification was local on macOS; the same revision's
  [Linux validation run](https://github.com/coghex/hetoimasia/actions/runs/34727412167)
  also passed. These checks exercised no graphics backend.
- `packages/gpu-vulkan/README.md` reserves ownership only. No GLFW/Vulkan
  implementation or dependency is present. Foundation and runtime are CPU-only.
- The [resource contract](resources.md) now provides CPU scopes, composite
  construction, the continuation facade, and retained cleanup evidence. GPU
  completion is deliberately outside that guarantee.

### Continuation and application-initialization status

Verified against the same revision after the owner's sequencing clarification:

| Piece | Implemented state |
|---|---|
| Resource continuation | `Hetoimasia.Foundation.Resource` defines opaque `Scoped a`, with `Functor`, `Applicative`, `Monad`, and `MonadIO`; `withScoped` is its runner. |
| Scoped initialization building blocks | `allocResource`, `allocComposite`, and `locally` exist over the CPU resource contracts. Hspec covers callback lifetime, normal/failing/cancelled unwinds, skipped later acquisition, and nested scope exit. |
| Integration example | `Hetoimasia.Runtime.Resources.resourceSmoke` composes logging, scoped allocations, and injected work. Its `Channel` is a demonstration using in-memory slots, not the messaging transport. |
| Application runner | `Hetoimasia.Runtime.runApplication` logs around a supplied `IO` action. It constructs no engine context and starts no workers. |
| Application context/state and boot lifecycle | No counterpart of Synarchy's combined Reader/State `EngineM`, `initializeEngine`, or `defaultEngineState` exists. The console assembles its logger and chooses a smoke action. |
| Messaging, threading, GLFW | No reusable production implementation exists yet. These are now work before Vulkan, under D-6. |

Synarchy's `Engine.Core.Monad` combines continuations with a concrete Reader
environment and IORef-backed state. Its `Engine.Core.Init.initializeEngineWith`
constructs queues, references, and subsystems into EngineEnv. Hetoimasia has
implemented the resource-continuation responsibility. The separate
[runtime foundation design](runtime_foundation_design.md) now specifies
application context, component state, and initialization composition under
epic #52. Its eight children and supervision repairs were subsequently merged
and verified; current runtime contracts live in `supervision.md` and related
implementation documents.

This arc refines FND-2/FND-3 of the
[broader foundation design](engine_foundation_design.md). The owner's chosen
window-and-triangle milestone takes precedence over that document's older
offscreen-first sequence. Reuse completed resource work and TEST-1; do not draft
duplicate foundation or test-reorganization issues. Shared graphics fixtures
remain owned by TEST-2 in the [test design](test_architecture_design.md), subject
to its production-interface and owner-decision gate.

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

The exact ordering among runtime, worker, and GLFW slices remains to be designed;
all precede Vulkan implementation. The agreed main-thread GLFW/render ownership
still holds: reusable worker support does not move GLFW operations to a worker.
Remote Linux/local macOS validation and deliberate reuse of Synarchy remain
accepted. Defer the Vulkan-specific questions while this infrastructure is the
active work.

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

Propose an ordinary resizable window with close, minimize/restore, and framebuffer
resize handling, including high-DPI sizes. Keep full-screen mode switching,
game input routing, fonts, textures, and scene rendering outside this first
milestone, while preserving their future extension points. Start with one frame
in flight if that simplifies the initial completion contract; swapchain image
ownership still remains separate from frame slots.

Retain the resize and synchronization lessons above through pure decision tests
and real integration evidence. A failed recording/submission after fence reset
also needs an explicit exit path: the loop must not wait forever for a submission
that never occurred. Recovery policy and full completion behavior remain Q-2.

### P-3. Establish a small message-passing foundation before its GLFW consumer

The owner asked whether Synarchy's queues and command processing should precede
the backend and accepted that prerequisite in D-6. Establish the reusable queue
contract with headless Hspec tests and use it in runtime/GLFW consumers before
Vulkan. The detailed transport contract below remains a proposal to refine;
worker lifecycle is also part of the pre-Vulkan work.

Synarchy has three distinct pieces worth retaining: generic transport in
`Engine.Core.Queue`, component-specific message types and dispatchers, and worker
lifecycle in `Engine.Core.Thread`. Keep those responsibilities separate here:

| Responsibility | Proposed placement and timing |
|---|---|
| Generic queue transport | Foundation: opaque typed queues, the first consumers' send/read/drain operations, explicit ordering and evaluation rules, and useful backlog diagnostics. No window, Vulkan, Lua, or game imports. |
| Window events and commands | GLFW component and its application integration: typed messages, event handling, and owned window state. Add these with the actual window consumer. |
| Background worker ownership | Runtime, in the pre-Vulkan infrastructure phase: startup outcome, stop/wakeup, completion observation, failure propagation, and joining before borrowed resources end. Exercise the contract through headless Hspec workers and component integration. |

Suggested first flow:

```text
GLFW callback -> typed window-event queue -> main-thread window-state/command handling
```

Deferring handling until after callback return is useful even when producer and
consumer run on the same thread. Enqueueing does not automatically create a
worker or invoke subscribers. Let each receiving component own its message
types and draining; give producers only the send capability they need. Avoid a
central message sum that imports every subsystem, or a registry of all queues.

Before implementing this proposal, settle these transport/policy boundaries:

- FIFO preserves the queue's committed ordering; it does not promise a fixed
  ordering between racing producers or broadcast a message to multiple readers.
- A command requesting an action, an event reporting a transition, and a current
  state snapshot have different requirements. Only coalesce messages whose
  component contract permits it. For example, retaining just the latest size
  must not erase a minimize/restore transition or reorder it across a barrier.
- State the capacity and overload policy for each use. Synarchy's underlying
  [TQueue](https://hackage.haskell.org/package/stm-2.5.3.1/docs/Control-Concurrent-STM-TQueue.html)
  is unbounded; [TBQueue](https://hackage.haskell.org/package/stm-2.5.3.1/docs/Control-Concurrent-STM-TBQueue.html)
  blocks writes when full. A callback cannot wait for capacity that only its own
  main-thread consumer can free. A bounded channel needs an explicit
  non-blocking admission/coalescing/failure policy for that use.
- Define how much queued work one loop turn processes and how remaining work
  survives. Queue capacity and the processing budget solve different problems;
  a continuous producer must not starve drawing or exit handling. Taking one
  whole-queue snapshot also does not bound the cost of handling that snapshot.
- Preserve short STM transactions and consistent telemetry. A timed read must
  race its timeout transactionally, following Synarchy's implementation. This
  alone does not make handling reliable after dequeue: cancellation, abandoned
  requests, acknowledgements, and shutdown need the consumer's own contract.

The first transport implementation should test its own observable guarantees
and adaptations with deterministic coordination. Worker supervision gets its
own pre-Vulkan lifecycle contract. Lua scheduling, game commands, and save/load
barriers get separate designs with their consumers. CPU message delivery proves
no GPU completion.

### P-4. Design scoped application composition and component-owned state

Preserve Synarchy's convenient initialization flow and scoped `do` notation.
Define each component's configuration, private state, borrowed services, and
initialization result. The application assembles those constructors under
explicit lifetimes; consumers receive the capabilities they use. An environment
record can group one component's dependencies without collecting every engine
subsystem into it.

The existing `Scoped` supplies the resource-lifetime layer. The runtime design
selects explicit `IO` arguments and narrow opaque handles for component operations.
Do not introduce an application-wide mutable state record
as a prerequisite to writing initialization functions. A constructor should
either establish a usable component or unwind its partial work; lifecycle
states and reinitialization behavior need explicit contracts.

Worker completion is specified by the runtime design: the group owns a protected
drain that retains borrowed dependencies until children and cancellation helpers
finish. Joining does not run as an `allocResource` release. Runtime supervision
uses explicit checkpoints and supervised waits over the raw worker group.
The continuation abstraction alone does not supervise children.

Q-5 is resolved by that accepted runtime design; implement its contracts before
graphics consumes them. This backend draft does not redefine those APIs or the
completed CPU resource primitives.

## Open questions

### Q-1. Accept P-1's component ownership and first thread model?

Resolved by D-5. Separate components and the first main-thread loop are accepted.
Frame work can delay event handling; a future render worker requires its own
handoff and lifetime contract. Exact package names follow the agreed boundaries.

### Q-2. What compatibility and completion contract should the backend require?

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
The remaining implementation gates are the four GLFW review repairs and the
unsettled GPU lifecycle/platform questions above.

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

When production APIs exist, resolve TEST-2's shared-fixture question with the
owner: selected compatible examples share expensive roots; example state stays
private; destructive lifecycle tests use private roots. Discovery and dry runs
must not initialize graphics. Thread ownership must be demonstrated independently
of the Hspec hook name. Reuse TEST-2's issue rather than create a second fixture
framework in this arc.

Real graphics checks should retain triangle pixels, validation output, observed
framebuffer dimensions, and lifecycle results for both platforms. Proposed
window cases include resize, zero area, restore to the same dimensions, close,
and failure during partial setup or submitted work. Exact capture and failure
injection procedures follow the agreed backend contract; none were run here.
Required contracts and evidence belong in each implementation PR.

## Delivery plan

No Vulkan child slice is ready for processing. Q-1 is settled by D-5 and Q-4's
sequencing by D-6. Q-5 is settled in runtime epic #52, whose approved children
are the current implementation queue. Messaging and independent GLFW contracts
still need focused designs and validation before returning to Vulkan-specific
Q-2/Q-3. Do not bury infrastructure implementation under a triangle delivery
issue. Exact Vulkan delivery slices remain undrafted.

When graphics work resumes, derive dependency-ordered, one-PR slices and mirror
them in the processing ledger. Keep TEST-2's existing ownership and external
gates explicit.

The older foundation document supplies architectural context, not a second
tracker for the same work. This design remains exploring until the relevant
choices and delivery slices receive review and explicit readiness.
