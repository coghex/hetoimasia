# Engine foundation and architectural boundaries

Hetoimasia is being built as a reusable Haskell engine with Vulkan rendering
and Lua scripting. The current application is a console smoke consumer;
production rendering and the full scripting runtime remain under development.
Applications compose narrow services; reusable libraries never depend on
concrete games or an application-wide environment. The durable owner direction
is [vision.md](vision.md).

This path remains the architectural reference used by AGENTS.md and existing
documents. On 2026-09-22 its broad delivery plan was reconciled with the focused
arcs below. It is an architecture overview, not a document to process into
another foundation epic. The
[original plan](history/engine_foundation_design_before_2026-09-22.md)
preserves its bootstrap evidence, original ledger and proposed sequence.

## Current implementation

Checked against code `master@da81087bb2c81e844588a0fc30197bd99201c6b9` on
2026-09-22, using the docs worktree at the same committed baseline. This is
a source inventory; no builds or native experiments were rerun for this update.
Unmerged implementation branches are not included as delivered capabilities.

| Area | Implemented at this baseline | Remaining boundary |
| --- | --- | --- |
| Foundation | [Logging](logging.md), [CPU resources](resources.md), structured failures, bounded recovery, owned workers, bounded channels, coherent snapshots and monotonic time | Worker drain retains borrowed dependencies until termination; it supplies no forced safe teardown or OS-thread affinity |
| Runtime | Scoped application composition, supervision, inbox services, reporting/logging lifetimes and the optional [asynchronous log adapter](../packages/runtime/src/Hetoimasia/Runtime/AsyncLog.hs) | No general short-job pool, content-loading service or application-owned game simulation is supplied by these services |
| Scheduling | [Fixed-step policy](../packages/runtime/src/Hetoimasia/Runtime/UpdatePolicy.hs), scheduled GLFW owner turns, native wake/fallback and per-window render-demand scheduling | These compose timing and demand; they do not implement a game loop or submit graphics work |
| Windowing and input | [GLFW](glfw.md) sessions, dynamic windows, controls, monitors and keyboard/text/mouse feeds; Cocoa on macOS, X11 by default on Linux and explicit Wayland selection | Full Wayland qualification/connection-loss work remains in #207; broader cursor/gamepad input remains a separate future arc |
| Graphics ownership | [Supervised owner and handoff implementation](../packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal/Owner.hs), exclusive window attachments and protected retirement | Uses injected backend operations and evidence; it does not create production Vulkan roots or establish native rendering progress |
| GPU bookkeeping | [Pure GPU model](gpu_model.md): resource/generation holds, frame ownership, admission budgets and recovery accounting | Performs no Vulkan calls and cannot establish native completion; an owning backend must supply that evidence |
| Vulkan qualification | The [Vulkan native suite](gpu_backend.md#the-native-suite), which carries the retired proof harness's cases, and retained [compatibility results](vulkan_compatibility_record.md) | A separate test harness, not a reusable backend or production triangle application; production surface/root/recording/submission work remains in #155 |
| Lua | [Private bridge behind an opaque public API](../packages/scripting-lua/README.md) for VM construction, chunks, calls and close, plus the pure task/protocol model | Public application capability registration, protected VM ownership and runtime scheduling/IPC are later slices; Linux and macOS confinement verdicts remain inconclusive |
| Rendering contracts, 2D and 3D | Reserved component directories and ownership notes | No Cabal libraries or renderer implementations yet; see the [renderer findings](renderer_foundation_findings.md) |
| Application | [Console entry point](../app/Main.hs) with logging and resource smoke paths | No graphical application or concrete game integration |

The main [Cabal project](../cabal.project) includes the root package, foundation,
runtime, GLFW, Lua host, GPU model and test-support package. The native Vulkan
proof is selected separately by [cabal.project.vulkan](../cabal.project.vulkan).
The reserved [render API](../packages/render-api/README.md),
[2D](../packages/render-2d/README.md) and
[3D](../packages/render-3d/README.md) directories are proposals, not buildable
rendering components.

## Current capability owners

A completed processing ledger means tracker drafting is complete, not that
all implementation has landed. The original foundation concerns now belong
to these focused contracts and work queues:

| Original concern | Current authority and status |
| --- | --- |
| FND-1, CPU resource ownership | [Resource contract](resources.md), delivered through #22; no duplicate slice |
| FND-2, Vulkan initialization and disposal | [Vulkan backend design](vulkan_backend_design.md), epic #155; native proof #158 delivered; production instance, device and target ownership delivered by #219 ([contract](gpu_backend.md)) |
| FND-3, minimal depth-tested 3D consumer | [Renderer foundation findings](renderer_foundation_findings.md), FND-3; needs focused refinement |
| FND-4, independent textured 2D consumer | [Renderer foundation findings](renderer_foundation_findings.md), FND-4; needs focused refinement |
| FND-5, Lua hosting and application bindings | [Lua runtime design](lua_runtime_design.md), epic #145; binding and protocol model delivered, confinement inconclusive and further processing paused |

## Component boundaries

Application composition knows concrete implementations. Lower libraries never
import applications, game managers or game types. Each Cabal component has its
own source directory and declared dependencies.

| Owner | State and lifetime | Public relationship |
| --- | --- | --- |
| Application | process composition and game sessions | creates and connects narrow services |
| Logging sink | caller-owned handle or scoped sink | borrowed logger; optional bounded asynchronous adapter |
| Runtime | lifecycle, reporting and supervision | supplied actions and owned worker drain |
| GLFW | main-thread session, windows, monitors, callbacks and input | command ports and coherent observations |
| Graphics owner | supervised graphics work and window retirement cooperation | explicit target controls and presentation data |
| Game session (application responsibility) | world, rules, simulation and save schema | presentation snapshots and explicit commands; no game is implemented here |
| Native Vulkan backend (planned) | device, GPU allocations, completion and disposal | opaque resources and managed submission; production work remains in #155 |
| 2D and 3D modules (planned) | independent rendering consumers | shared backend infrastructure, no concrete game dependency |
| Lua runtime (partly implemented) | bridge/model exist; protected VM owners and confined mod/domain processes are planned | application-owned capabilities and bounded transport remain design contracts |

The application owns simulation and its commit policy. GLFW remains on the
process main thread; the supervised graphics owner is separate. This does not
promise input or gameplay progress during a Cocoa modal loop.

A CPU scope ending does not prove GPU completion. Establish completion before
reclaiming GPU resources; failure must not manufacture that evidence.
Cross-thread publication defines ownership, consistency, cancellation and
bounded admission. Introduce concurrency for a concrete consumer.

Use the failure-preserving CPU [resource contract](resources.md).
`runScopedApplication` composes scoped dependencies, supervision and pre-drain
quiescence using explicit IO and narrow handles. Ordinary uninterruptible
resource releases must remain bounded under that contract; arbitrary worker
joins, script finalization and GPU waits require their owning protected
lifetime. An application-wide monad remains an open choice and must not
reintroduce a universal environment or mutable registry.

## Accepted decisions

### D-1. Build a fresh modular Haskell/Vulkan/Lua engine

Accepted by the owner. Synarchy remains a separate working project and a source
of experience. Reuse isolated lessons deliberately; do not copy its game
managers or EngineEnv.

### D-2. Support separate 2D and 3D modules over shared infrastructure

Accepted direction. A small 2D consumer arrives early to test reuse before the
architecture becomes deeply 3D-specific. Game compatibility belongs in adapters.
FND-3/FND-4 in the renderer report preserve the remaining consumer work.

The original migration proposal remains captured Synarchy scenes followed by
a bounded live scenario, with full game compatibility in a later focused arc.
Refine concrete acceptance criteria alongside the 2D consumer without turning
the minimal renderer into a full game port.

### D-3. Use Kanban's existing interactive issue/PR workflows

Accepted by the owner. Keep required docs and evidence with code in each PR.
Standalone documentation uses the documentation lane. Consult
[workflow.md](workflow.md) for delivery mechanics; service running state must
be checked when needed rather than inferred from bootstrap records.

### D-4. License the project under GNU GPLv3

Requested explicitly by the owner. Cabal records `GPL-3.0-only`; packages
include the license text.

### D-5. Prefer Hspec for testing

Use Hspec for pure and effectful tests, including resource failure, cancellation
and integrations wherever possible. Python probes require a boundary that
cannot reasonably be exercised through Hspec.

### D-6. Publish the initial baseline on master

Historical authorization: the owner selected `coghex/hetoimasia`, requested
remote setup and the initial commit, and specified `master`. This is not
standing permission to publish later changes outside their delivery lane.

### D-7. Process the dedicated logging and resource designs

The owner requested readiness of the [logging](logging_design.md) and
[resource](resource_ownership_design.md) designs on 2026-09-10. Those arcs are
delivered. Their failure and ownership policies remain authoritative; FND-1's
old entry delegates to #22 rather than creating duplicate work.

### D-8. Complete reusable infrastructure before Vulkan

The owner prioritized methodical infrastructure over rushing another triangle.
Logging, CPU resource ownership, messaging, runtime initialization/lifecycle,
worker supervision and GLFW now have dedicated contracts and implementations.
The [backend design](vulkan_backend_design.md) owns the accepted windowed-triangle
milestone, GPU completion rules, capability profiles and Linux/macOS qualification.
Follow its concrete prerequisites; do not revive the old offscreen-first
Vulkan bootstrap.

## Verification boundaries

Compile components against declared dependencies and keep CPU consumers
headless. Test failure, cancellation and cleanup contracts in their owning
packages. Graphics behavior needs native evidence and captured pixels where
applicable; headless tests alone prove no image. Performance claims require
retained measurements. Native desktop sessions require an explicit
per-command opt-in, given under the owner's standing approval (2026-09-26) for
runs an issue or pull request needs; approved isolated Linux displays need
none.

Game saves and game-specific determinism remain application-owned. A later
Synarchy migration must preserve or explicitly migrate those contracts.
