# Hetoimasia project memory

Updated 2026-09-18 against code `master@8e4eb6e`. This is the active handoff,
not an exhaustive changelog. Recheck Git and the tracker before relying on status.
Working rules live in [AGENTS.md](AGENTS.md); historical context is preserved in
[the memory archive](docs/history/memory_before_2026-09-17.md). Read only the
owning subsystem's contract/design when continuing its work.

## Direction and owner preferences

- Build a modular Haskell/Vulkan engine with Lua, then separate 2D and 3D
  renderers. Synarchy (`~/work/synarchy`) is valuable prior work and a possible
  future game client; migration is not automatic compatibility.
- The application assembles game state, runtime services, graphics and scripting
  through narrow interfaces. No universal `EngineEnv`, global service locator,
  engine import of concrete game code, or new all-purpose application monad.
- Develop infrastructure methodically before Vulkan. A rendered triangle is the
  first eventual graphics result; it is not a reason to skip lifecycle work.
  The first GLFW/render owner runs on the process main thread. Concurrency needs
  a concrete purpose, explicit ownership and bounded communication.
- Preserve Synarchy's useful behavior and rationale deliberately: inspect its
  windowing, monotonic time, Vulkan ownership, Lua and rendering code before
  replacing concepts. Do not copy its central environment or game managers.
- GitHub: `coghex/hetoimasia`, public, default `master`; license `GPL-3.0-only`.
  GHC 9.14.1, Cabal 3.18.1.0, `index-state: 2026-09-18T00:00:00Z`, GHC2024,
  Unicode type syntax, standard Prelude. `docs/toolchain.md` records that
  qualification, the candidates rejected, and the pinned `vulkan-3.27` /
  `vulkan-utils-0.5.11.0` pair VK-2 inherits.
  Preserve `semaphore: False` for the multi-worktree build.
- Use Kanban skills and `~/work/kanban` for issue/PR workflow. This repository
  is the target. Code and its required documentation/evidence ship in the same
  PR; standalone docs use the docs worktree and docs landing helper.
- Prefer Hspec. Python probes need a boundary Hspec cannot reasonably exercise.
  Use coordinated concurrency tests, not sleeps; preserve fail-on-empty and
  meaningful external-client opacity checks. Scope tests to changed contracts.
- Remote CI is Linux-only; macOS native evidence is local. Before any test
  disrupts the human's desktop, **ask for the human user's explicit approval**,
  explain the disruption, and wait. Approval covers only that agreed session.
  Issue/PR approval and acceptance commands do not authorize desktop use.
  Supply `HETOIMASIA_NATIVE_SESSION=desktop` only on the approved command.
  Isolated X11 through `tools/display/x11.sh` and approval-free native selectors
  need no desktop approval. The environment flag is a guard, not proof of consent.

## Implemented and reviewed

- Logging, CPU scopes/collections, structured failures and bounded recovery,
  application composition, workers/supervision, bounded channels/snapshots,
  supervised inboxes, and GLFW dynamic windows/controls/monitors/input exist.
- Five Cabal packages are active: root, foundation, runtime, GLFW, and the
  test-only `hetoimasia-test-support`. Vulkan, Lua, fonts and renderers are
  still plans/ownership notes, not implemented packages.
- GLFW #87–#100 merged through PRs #101–#114. Repairs #115–#118 merged through
  #119–#122; monitor follow-up #123 merged in #126; native consent #124 merged
  in #128. Epic #86 is closed after checklist reconciliation on 2026-09-17.
- Test-support extraction #125/#132, foundation migration #127/#137, and
  runtime migration #129/#150, and GLFW headless migration #130/#151 are
  complete. All children of epic #49 are merged; its checklist still needs
  reconciliation.
- Audit at `8e4eb6e`: the latest twelve merged PRs (#150–#165, exact list in
  [the report](docs/project_review_165-150.md)) cover every merge since the
  previous review through #137. Build and 1,289 existing Hspec examples passed;
  five added headless examples reproduced four follow-ups: completion-policy
  evaluation escaping protected retirement (P1), direct-versus-queued evidence
  revival, retirement budget busy polling, and diagnostic-failure propagation.
  These are not filed yet. Repair the lifetime escape before attaching native
  GPU dependents. No desktop session ran. Counts are dated evidence.
- Foundation owns `packages/foundation/test/` (`test.foundation`) and runtime
  owns `packages/runtime/test/` (`test.runtime`, 143 examples at #129, with the
  per-example map in docs/runtime_tests_mapping.md). GLFW owns
  `packages/glfw/test/` (`test.glfw`, 234 examples at #130, including the 180
  former window-executable examples, mapped in docs/glfw_tests_mapping.md);
  `glfw-native-tests` stays separate. Root tests keep only `Console` and depend
  on no GLFW package. Shared neutral helpers are test-only; no production
  dependency on test support. CPU-only foundation, runtime, and root builds use
  `cabal.project.cpu`, sharing canonical settings in `cabal.project.common`.

## Contracts to preserve

- [Resources](docs/resources.md): scoped continuation over CPU ownership;
  construction rollback and once-only consumer; original failure/cancellation
  stays primary and cleanup evidence survives. Foundation releases are bounded
  and uninterruptible. CPU scope exit is never GPU completion.
- [Supervision](docs/supervision.md) and [workers](docs/workers.md): explicit
  checkpoints and supervised waits; distinguish services/jobs and required/
  optional failures. Keep borrowed resources alive while a worker cannot stop.
  No unsafe detachment or cleanup error used as permission to release parents.
  Logging finalization has its own IO lifetime outside bounded finalizers.
- [Messaging](docs/messaging.md): bounded FIFO and latest snapshots; prepared
  NFData payloads; immediate Full with explicit waiting; close drains and abort
  discards; no automatic replay of in-flight effects. Graceful inbox finish is
  explicit. Escaping handler failures terminate the worker under normal policy.
- [GLFW](docs/glfw.md): one main-thread owner, opaque capabilities, independently
  closing windows, bounded commands with persistent tickets, coherent state and
  explicit input resets. A close acknowledgement is not native destruction. The
  owner has two loops: `runOwnerLoop`, unchanged and paced by the turn before
  it, and the additive `runScheduledOwnerLoop`, paced by absolute deadlines from
  the host's injected monotonic clock and bounded by the same finite fallback.
  `renderTurn` is the pure helper that maps the runtime's simulation demand and
  each window's captured demand onto that schedule; it knows no GPU, and
  retirement is never gated by render eligibility.
  `withProtectedWindowHost` builds the same host inside an IO continuation
  boundary that owns attachment retirement; the `Scoped` constructors keep their
  behaviour and accept no attachment. On every exit that boundary ends new
  graphics use, retires attachments on the main thread with the windows, the
  session, and the parents live, and retains them all when it cannot.
- [Validation](docs/validation.md): mandatory floor plus affected non-optional
  and PR-requested groups. Optional probes remain opt-in. CI evidence and review
  approval have independent freshness rules; approved clean merges may retain
  review while changed inputs require CI. Docs-only reuse compares actual inputs.

## Active backlog and next design

- All three pre-Vulkan documents are fully processed into tracker artifacts;
  processing completion does not mean implementation completion. Their canonical
  approval comments amend the issue bodies and must be included by solvers.
- [Test ownership](docs/test_architecture_design.md), epic #49: all children
  have merged. Package suites and the root/tools separation are implemented.
- [Scheduling](docs/runtime_scheduling_design.md), epic #131: #133, #134, #135,
  #136, #138, #139 are all merged. Accepted: event/deadline/fixed-step updates
  with bounded catch-up; render suspension per window while simulation remains application-
  owned; committed demand retained across cancellation; expected wake failure
  keeps accepted work, reports once under logging policy and degrades to polling.
- [Window/graphics lifetime](docs/window_graphics_lifetime_design.md), epic #140:
  #141, #142, #143, and #144 are merged. The current review report records
  follow-up repairs, so merged children do not establish a clean arc. One exclusive
  graphics owner per window, attached through `attachWindowGraphics` and held as
  an opaque `GraphicsService`. Protected main-thread retirement follows worker
  drain and precedes dependency release on every exit; in-run retirement
  progresses on owner turns under `hostRetirementBudget`, rotating across pending
  attachments, and publishes `hostRetirementDemand` for the scheduled loop.
  Unknown safety retains resources. Completed #123 no longer blocks this work.
  `attachHostWindow` and the rest of the #143 seam stay private to
  `runtime-glfw-core` beneath that contract. Still open: no surface, GPU
  submission, or device wait exists anywhere here — evidence that GPU work has
  completed is the backend's, and which mechanism proves it is the Vulkan
  compatibility proof #158.
- [Lua](docs/lua_runtime_design.md) is ready for staged processing. Independent
  UI/gameplay execution domains; stop unsafe authoritative gameplay while keeping
  UI available. Untrusted mods require separate processes per mod/domain,
  explicit capabilities, and enforced whole-process resource/execution limits.
  Epic #145 has approved children #146–#149. #146 (LUA-1) consumes the shared
  toolchain qualification from #157; it must wait for that merge. #147/#148
  (platform proofs) and #149 (pure protocol model) follow #146 and can then run
  in parallel. The backlog review identified one amendment for #147: it needs
  the same bounded Cabal OS/buildable parser support already specified in #148,
  or must reuse that support if #148 lands first. No tracker edit has been made.
  LUA-14/LUA-15 must prove viable Linux and macOS confinement before dependent
  process/integration slices are drafted.
  Signed bundled macOS helpers may be evaluated while preserving headless CLI
  operation; no assumed privileged install or paid signing account. A failed or
  inconclusive proof returns the design to exploring; never weaken isolation.
- [Vulkan](docs/vulkan_backend_design.md) is ready for staged processing,
  tracked by epic #155. Approved #157 qualifies the shared toolchain first;
  after #157 merges, native proof #158, pure ownership model #160, and Lua
  #146 can run in parallel. Vulkan 1.3 minimum, a shared loader,
  managed retention, present-fence retirement, and default two frame slots are
  accepted design choices; native compatibility remains unproven until #158.
  Later native slices remain gated on that proof. Host-retirement repairs must
  precede real GPU attachment integration; the current three Vulkan issues do
  not depend on the defective host paths.
- CI-5 (`test`/`autotest` adapter integration) remains explicitly deferred.
  The old foundation umbrella is architectural context, not another queue for
  duplicating completed resources/runtime/GLFW or the newer TIME/LIFE arcs.
- No game save schema, full Synarchy port, permanent RTS tuning, or general
  engine-wide rendering abstraction is committed yet.

## Where to look

- [Logging/module authoring](docs/logging.md), [failures](docs/failures.md),
  [recovery](docs/recovery.md), and the subsystem contracts above.
- [Workflow](docs/workflow.md) for publication and [review cursor](docs/project_review_boundaries.md)
  for exact audited PR coverage. Historical reports keep their original baselines.
- [Historical memory](docs/history/memory_before_2026-09-17.md) for prior rationale
  and delivery history; do not load it automatically or use its old open-issue
  claims as a new work queue.
