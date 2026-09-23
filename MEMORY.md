# Hetoimasia project memory

Implementation notes below were last reconciled on 2026-09-19 against code
`master@38388f8`; they are dated context, not the latest tracker inventory.
The architectural review entry point was added on 2026-09-20. Recheck Git and
the tracker before relying on status.
Working rules live in [AGENTS.md](AGENTS.md); historical context is preserved in
[the memory archive](docs/history/memory_before_2026-09-17.md). Read only the
owning subsystem's contract/design when continuing its work.

For a fresh architectural review, start with [the vision guide](docs/vision.md)
and run `$guide`. Its reports in `docs/guide/` record the exact code and tracker
versions checked, findings and pending concurrent work. The skill is installed
at `~/.codex/skills/guide/SKILL.md`; it is advisory and does not replace Kanban
approval or project-review records.

The [first guide review](docs/guide/2026-09-20T183233Z-d40c387-6e92.md) covers
seven later merged PRs through `d40c387`, the current issue specifications,
743 passing headless examples and the remaining amendments/housekeeping.
The owner accepted legacy coverage through `a89d419`; together these complete
the guide's historical review queue through `d40c387`. Those five findings are
now processed; implementation remains tracked in #201, #208, #211 and #212,
and qualification gates remain in force. The [next guide review](docs/guide/2026-09-20T201612Z-8b2fcfd-ff7e.md)
extends coverage through `8b2fcfd` (PR #210). Its two findings are now processed:
graphics-owner design under #155 and the wording repair #224. The
[latest guide review](docs/guide/2026-09-21T035017Z-9f72b04-768f.md) extends coverage
through `9f72b04` (PRs #213/#214), checks the newly approved Vulkan and repair
issues, and records the owner-approved amendments now posted to #216/#220, with
coordination on #229/#221. GUIDE-3 remains unprocessed: the reproduced X11 helper
diagnostic flake needs a repair issue. Posting the amendments does not claim
their implementations are complete or replace canonical readiness review.
`$guide continue` handles one follow-up at a time without repeating old audits.

## Direction and owner preferences

- Build a modular Haskell/Vulkan engine with Lua, then separate 2D and 3D
  renderers. Synarchy (`~/work/synarchy`) is valuable prior work and a possible
  future game client; migration is not automatic compatibility.
- The application assembles game state, runtime services, graphics and scripting
  through narrow interfaces. No universal `EngineEnv`, global service locator,
  engine import of concrete game code, or new all-purpose application monad.
- Develop infrastructure methodically before Vulkan. A rendered triangle is the
  first eventual graphics result; it is not a reason to skip lifecycle work.
  GLFW stays on the process main thread; accepted Vulkan D-29–D-33 place rendering
  on a separate supervised graphics owner with protected retirement and bounded
  handoffs. Native evidence must still establish progress during Cocoa modal loops.
- Preserve Synarchy's useful behavior and rationale deliberately: inspect its
  windowing, monotonic time, Vulkan ownership, Lua and rendering code before
  replacing concepts. Do not copy its central environment or game managers.
- GitHub: `coghex/hetoimasia`, public, default `master`; license `GPL-3.0-only`.
  GHC 9.14.1, Cabal 3.18.1.0, `index-state: 2026-09-18T00:00:00Z`, GHC2024,
  Unicode type syntax, standard Prelude. `docs/toolchain.md` records that
  qualification, the candidates rejected, and the pinned `vulkan-3.27` /
  `vulkan-utils-0.5.11.0` pair VK-2 inherits. The
  [#171 review](docs/project_review/171.md) records a provenance-documentation
  correction; preserve the receipts' exact historical revisions rather than
  claiming all subsequent changes through `HEAD` were documentation-only.
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
- Seven Cabal packages are active: root, foundation, runtime, GLFW, the Lua host
  `hetoimasia-scripting-lua`, the test-only `hetoimasia-test-support`, and
  `hetoimasia-gpu-vulkan-model` (VK-3). The native Vulkan backend package,
  fonts and renderers are still plans/ownership notes, not implemented
  packages.
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
  Those four findings became #166–#169 and merged as PRs #170, #172, #178,
  and #180. The [review ledger](docs/project_review/ledger.md) records the
  follow-up batch through #180 and links its current findings. No desktop
  session ran in either audit. Counts above are historical evidence.
- Foundation owns `packages/foundation/test/` (`test.foundation`) and runtime
  owns `packages/runtime/test/` (`test.runtime`, 143 examples at #129, with the
  per-example map in docs/runtime_tests_mapping.md). GLFW owns
  `packages/glfw/test/` (`test.glfw`, 234 examples at #130, including the 180
  former window-executable examples, mapped in docs/glfw_tests_mapping.md);
  `glfw-native-tests` stays separate. Root tests keep only `Console` and depend
  on no GLFW package. Shared neutral helpers are test-only; no production
  dependency on test support. CPU-only foundation, runtime, and root builds use
  `cabal.project.cpu`, sharing canonical settings in `cabal.project.common`.

- LUA-1 (#146) is the Lua binding and foreign-call boundary. The selected pair
  is `lua-2.3.4`, bundling Lua 5.4.8, on the #157 baseline merged as `3af4cb2`;
  `hslua-core` was rejected because its `LuaE` hands out the raw state and its
  `run` masks cancellation across the whole computation. The bridge is private:
  the state, trampoline, and registry references live in the package's `bridge`
  sublibrary, and the public module offers construct / load / call / close and
  nothing else. `cabal.project.common` sets `lua` to
  `-system-lua -pkg-config -allow-unsafe-gc`; the last is a correctness setting,
  because every VM that has held a Haskell callback re-enters the RTS from its
  collector. The suite is `lua-host-tests`, the group `test.scripting-lua`, and
  the audit is in the package README. Open follow-ups it records, all for later
  slices: cancelling a thread that is inside Lua cannot work with an
  asynchronous exception, so a supervisor that must reclaim a running task needs
  a Lua-consulted hook or a process boundary (LUA-4 onward); the `safe`-call
  cost of disabling `allow-unsafe-gc` is unmeasured and belongs with the first
  workload that has a budget to weigh it against. **Cancellation targets a VM's execution
  owner**, decided by the owner on 2026-09-18: a callback thread is the
  runtime's machinery, not an endpoint, and a trusted callback must not publish
  its `ThreadId` or outlive its own return. Owner cancellation stays observable
  after the native call and the bookkeeping; a callback's failure keeps its type
  and context; nothing promises to interrupt arbitrary Lua, so callbacks stay
  short and limits on untrusted code belong to LUA-14/LUA-15's processes. The
  package performs state creation, publication, global reads, and library
  opening through its own C — each one protected call — because the binding's
  wrappers allocate their arguments before their own protection; it owns the
  callback path and its error protocol for the same reason plus the export
  window. A budget-walking allocator in the hazard runner proves every
  allocation on the publication path reports rather than panics, that a failed
  publication leaves the state usable, and that carriers are finalized exactly
  once.
- LUA-14 (#147) is the Linux confinement and resource-limit feasibility proof,
  and **its verdict is `inconclusive`** — recorded in
  [the Linux confinement verdict](docs/lua_linux_confinement_verdict.md), whose
  three runs are kept verbatim in
  [the retained runs](docs/lua_linux_confinement_evidence.md). The
  candidate profile works: on an ordinary unprivileged Linux machine (Ubuntu
  24.04, kernel 6.8, aarch64, non-root, no capability) every row of Q-5's proof
  matrix was demonstrated. It works only where the distribution gives an
  unprivileged process a *usable* user namespace, and neither required
  environment does. Ubuntu 24.04 ships
  `kernel.apparmor_restrict_unprivileged_userns=1`, which lets the `unshare`
  succeed and then denies `CAP_SYS_ADMIN` inside the namespace it created; the
  Linux CI container refuses the `unshare` outright. So the mechanism is proven
  and the deployment baseline is not, which returns the Lua design to
  `exploring` under D-11. The obstacle is the owner's to resolve: relaxing that
  restriction, shipping an AppArmor profile, a file-capability helper, and
  **Landlock instead of namespaces** (unprivileged, no namespace needed, TCP
  rules since kernel 6.7) are the alternatives, the last being the one worth
  evaluating next. No CI image or container option was changed.
- The probe's own shape is the reusable part. It is private to
  `packages/scripting-lua/linux/`, Linux-only, admits no mod source, and its
  group is `test.lua-confinement-linux`; a green run is evidence and never a
  verdict, because each example either proves its property or prints that the
  machine could not install the profile. Facts it fixed: an unprivileged user
  namespace must be entered from a freshly `fork`ed child, because
  `unshare(CLONE_NEWUSER)` is refused to a threaded process; asking whether one
  can be *created* is the wrong question, and the whole sequence through the
  identity maps must be attempted; a bind mount remounted read-only inside a
  user namespace must carry the source's locked flags forward or the remount is
  `EPERM`; `RLIMIT_AS` is a whole-process ceiling but counts the runtime's
  address-space reservation, so the child needs `-xr256m` and enough headroom
  for eight megabytes of stack per runtime thread; a `dlopen` fixture must be a
  module the program does not already link; a PID namespace needs a second fork
  and leaves the caller holding a supervisor rather than the confined process,
  so that supervisor reproduces the confined exit status and forwards the
  cooperative stop; and lowering `RLIMIT_NOFILE` closes nothing already open,
  so every descriptor above the four the child is given must be swept before
  the exec. Registering the group needed
  the validation planner to accept `buildable` inside an `if os(...)`
  conditional, which it now does without reading the body, so a platform
  component's sources select their group on every platform rather than only the
  one that builds them.

## Contracts to preserve

- [GPU model](docs/gpu_model.md) (VK-3, `packages/gpu-vulkan/model`): the pure
  retention and frame-ownership model, a separate package whose only project
  dependency is the foundation, listed in both project files so it and its suite
  build with no Vulkan SDK permanently. It proves no native completion: a
  submitted use, a presentation obligation and an unpresented frame's
  synchronization end only on a fact the boundary injects. Five holds are tracked
  separately per generation and per managed resource, and nothing is disposed of
  until every one has ended. Budget exhaustion is typed backpressure, never
  failure, and never takes a cleanup record reserved for admitted work. Recovery
  is three attempts at 100 ms and 500 ms, replenished only by a retirement cycle
  plus a healthy second; an `oldSwapchain` retirement is irreversible; a failed
  disposal is preserved, not replayed, and escalates the session. Its suite is
  the non-floor CPU group `test.vulkan`, which runs through `cabal.project.cpu`.

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
  `withGraphicsOwnerHost` is the additive constructor beside it: the same host
  with one supervised graphics owner alive across that drain, taking the
  backend's operations as an injected record. The owner makes no GLFW call —
  its one cross-thread reach is the session's existing wake — and the exit
  retires each target, then the owner, then destroys it, then joins, and only
  then releases the windows. Nothing but the injected evidence is permission:
  an owner that ends without whole-owner destruction evidence retains the
  windows, the session and every parent until independent evidence arrives.
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
  RR-4 (#200) is measured, not assumed: on macOS 26.6 with the pinned Cocoa
  GLFW 3.4, a live resize and a menu-bar interaction each block the owner turn's
  native event call for as long as the person interacts — 68.92 s and 13.30 s
  observed, with no owner turn and no update opportunity in either — while a
  window move does not block it at all. Cocoa keeps requesting a redraw about
  111 times a second throughout a resize; a menu tracking loop delivers nothing.
  Resolved by Vulkan D-29–D-33: the separate graphics owner's machinery is
  delivered by VK-18/#218 inside the GLFW package's runtime integration
  (`Hetoimasia.Runtime.GLFW.Internal.Owner`, contract in
  [glfw.md](docs/glfw.md#the-supervised-graphics-owner)), with its backend
  operations injected and proved through fakes; VK-7/#219 supplies the Vulkan
  ones and VK-16/#232 owes the Cocoa progress evidence. The owner removes the
  stale or stretched surface, not the stall: window commands and observations
  still wait for the pump, and a rendered latest snapshot does not mean
  gameplay or input continued. The [verdict](docs/owner_loop_interaction_verdict.md) is historical
  measurement, not a later policy decision. Its probe stays selectable, never
  routine. Simulation remains application-owned; scene snapshots can originate
  on any application thread without introducing a simulation driver in this arc.
- [Window/graphics lifetime](docs/window_graphics_lifetime_design.md), epic #140:
  #141, #142, #143, and #144 are merged. The current review report records
  follow-up repairs; #166–#169 have now merged. The review ledger records their
  verification separately from new Lua/GPU findings. One exclusive
  graphics owner per window, attached through `attachWindowGraphics` and held as
  an opaque `GraphicsService`. Protected main-thread retirement follows worker
  drain and precedes dependency release on every exit; in-run retirement
  progresses on owner turns under `hostRetirementBudget`, rotating across pending
  attachments, and publishes `hostRetirementDemand` for the scheduled loop.
  Unknown safety retains resources. Completed #123 no longer blocks this work.
  `attachHostWindow` and the rest of the #143 seam stay private to
  `runtime-glfw-core` beneath that contract. Still open: no surface, GPU
  submission, or device wait exists anywhere here — evidence that GPU work has
  completed is the backend's. Vulkan compatibility proof #158 has qualified
  present-fence retirement and image release on both selected profiles; its
  proof harness is separate from the still-planned production backend.
- [Lua](docs/lua_runtime_design.md) has returned to `exploring` under D-11.
  Independent UI/gameplay execution domains; stop unsafe authoritative gameplay
  while keeping UI available. Untrusted mods require separate processes per mod/domain,
  explicit capabilities, and enforced whole-process resource/execution limits.
  Epic #145's children #146–#149 are merged: the binding uses #157's qualified
  toolchain, both platform proofs have retained verdicts, and the pure protocol
  model exists. The [#179 review](docs/project_review/179.md) records
  failure-settlement and bounded failure-detail defects; the
  [#173 review](docs/project_review/173.md) records stale binding comments.
  Repair them before dependent integration relies on those contracts. #148
  added bounded OS-conditional `buildable`
  parser support, reused by #147; conservative source hashing is intentional,
  but [the #177 review](docs/project_review/177.md) records the separate defect
  in routing a mandatory Linux-only group on Darwin.
  Both confinement verdicts remain inconclusive. LUA-9 through LUA-13 and
  dependent integration slices stay blocked until the owner resolves the
  deployment constraints and both required profiles have successful evidence.
  Signed bundled macOS helpers may be evaluated while preserving headless CLI
  operation; no assumed privileged install or paid signing account. Never weaken
  isolation to convert an inconclusive proof into support.
- **LUA-15's macOS verdict (#148) is `inconclusive`**, recorded in
  [docs/macos_confinement_verdict.md](docs/macos_confinement_verdict.md) with
  its probe at `packages/scripting-lua/macos/`. The retained experiments ran
  on macOS 26.6 (`25G5065a`, arm64, Command Line Tools, linker ad-hoc signature,
  no entitlement or privilege) — per-instance SBPL confinement, all four denied
  accesses natively (three of them again from Lua; Lua has no socket API, and
  that gap is named in the verdict rather than counted as a pass),
  two-instance isolation including inherited descriptors, a fatal whole-process
  footprint cap, an enforced execution budget, and the three lifetime endings.
  It is not `supported` because both load-bearing mechanisms are unsupported:
  `sandbox_init_with_parameters` (undeclared; the family its header does declare
  is marked "No longer supported") and `posix_spawnattr_setjetsam_ext`
  (undeclared SPI). Four measurements worth not rediscovering: a spawn-time
  jetsam memory limit is **cleared by any later `exec`**, so an exec-based
  wrapper such as `sandbox-exec` silently drops it and the helper must confine
  itself; the cap is on **physical footprint**, so the threaded RTS's ~1.44 TiB
  virtual reservation does not count against it; `RLIMIT_AS`/`RLIMIT_DATA`
  cannot be installed below ~1.44 TiB in that helper (~415 GiB even in a trivial
  C process) and so cannot express any mod budget; and App Sandbox — the
  supported alternative — permits `exec`, shares one container per bundle
  identifier, and leaves a `~/Library/Containers/<id>` an unprivileged process
  **cannot delete**. A fifth, found in review: a confinement profile bounds what
  a process may reach *by name* and says nothing about descriptors it was
  *handed* — the parent's listening endpoints were inherited across the spawn
  until `FD_CLOEXEC` and `POSIX_SPAWN_CLOEXEC_DEFAULT` closed them. Q-5's macOS
  row is the owner's: accept the unsupported-SPI profile, accept a weaker App Sandbox contract, or drop macOS from this arc's
  untrusted-mod targets. Until then the design stays `exploring` and LUA-9
  through LUA-13 stay undrafted, whatever #147 concludes. The
  [#176 review](docs/project_review/176.md) additionally found that optimization removes the intended native-buffer
  growth; repair that experiment and refresh its evidence before relying on
  its claimed mixed-allocation workload.
- [Vulkan](docs/vulkan_backend_design.md) is ready for staged processing,
  tracked by epic #155. Shared toolchain #157, native compatibility proof #158,
  pure ownership model #160, and native provisioning #208 have merged. The model is implemented; the
  production native backend is still planned. Vulkan 1.3 minimum, a shared
  loader, managed retention, present-fence retirement, and default two frame
  slots are accepted design choices. #158 proved the native profile on both platforms and recorded it in
  [docs/vulkan_compatibility_record.md](docs/vulkan_compatibility_record.md):
  Vulkan 1.3 with dynamic rendering and synchronization2, one shared standard
  loader, `VK_EXT_swapchain_maintenance1` present fences and image release, and
  a transfer-source capture. Two things that record leaves unproved are easy to
  assume wrongly later: the KHR maintenance spelling is an alias neither
  MoltenVK nor Lavapipe resolves, and no device loss was induced, so those rows
  are specification evidence. VK-4/#208 then promoted that profile into the
  recipe: `tools/native/vulkan.pin` names the loader, driver, validation layer
  and glslang compiler per platform, `tools/native/vulkan.py` provisions them
  into `<native prefix>/vulkan`, and their identities reach the image
  descriptor and the plan's toolchain map, so a changed input is an explicit
  requalification rather than a silent drift. Both prefixes are **natively
  qualified against the provisioned inputs**, by a second pair of records
  retained beside the VK-2 pair: `docs/vulkan/linux-provisioned.md` from inside
  the published image, and `docs/vulkan/macos-provisioned.md` from a local run
  under the human's explicit approval for that one session. Reusing the VK-2
  macOS record could not have done it — that record names versions and paths but
  no binary or manifest digests, so it cannot establish that the identities the
  prefix now records are the ones it consumed — which is why the consented run
  was needed. The provisioned pair carries one source digest computed
  independently on both platforms, as the VK-2 pair does. A third thing the
  VK-2 record leaves unproved is a rule rather than an observation: a present fence's status before it is waited on is not a
  contract on either platform, so the fence is waited for and nothing is read
  into whether it happened to be signalled already. Later
  native slices' #158 prerequisite is satisfied by PR #174. Host-retirement
  repairs #166–#169 are also merged. Address the new model findings recorded
  in the review ledger before the native backend depends on those contracts.
  The [#174 review](docs/project_review/174.md) also identifies unsafe proof
  cleanup after a presentation-fence timeout and missing rollback for partial
  native construction. Device idle alone is not presentation retirement. Repair
  these failure paths before reusing the harness as a native-lifetime template;
  the retained successful profile evidence remains useful.
- Test selection follows [the owner policy](docs/test_classification.md): quick
  core contracts in the floor, relevant integration/tooling contracts selected
  by changes, and optional local display-deadline/nontermination/confinement
  probes. The [local lab](tools/flake/README.md) supplies shared `$test`/`$flake`
  selection, `$autotest` integration and durable evidence; broader CI-5
  receipt/scheduler work remains deferred. The old foundation umbrella is
  architectural context, not another queue for duplicating completed arcs.
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
