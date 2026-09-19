# Working agreements

Hetoimasia is a modular Haskell game-engine project. Read [MEMORY.md](MEMORY.md)
for continuity, [the foundation design](docs/engine_foundation_design.md) for
boundaries, and [workflow.md](docs/workflow.md) for Kanban delivery.
These instructions are also the authority for Claude sessions through CLAUDE.md.

## Architecture

- Dependency direction is part of correctness. Game code and integrations may
  depend on engine interfaces; engine libraries never import concrete games.
- Keep Cabal components in separate source directories. Expose small public
  interfaces; hide implementation modules. Do not share root `app/` sources
  with libraries to evade a component boundary.
- The application entry point assembles services. Pass narrow services or
  abstract handles to consumers; do not introduce a universal `EngineEnv`,
  service locator, or global mutable registry.
- Subsystems own construction, mutation, and teardown. Before adding state,
  document its owner, readers/writers, thread, lifetime, and reset/disposal
  behavior in its owning module or design. GPU completion is distinct from
  CPU scope exit.
- New subsystems follow the
  [module authoring guide](docs/logging.md#module-authoring-guide) for logger
  injection, component naming, scoped context, level meaning, and which output
  is a diagnostic rather than application output.
- Publish coherent data across thread boundaries. Add concurrency for a
  concrete need and establish queue/snapshot ownership and cancellation first.
- Use explicit `IO` or a small local context initially. The resource design
  selects a scoped continuation facade; an application-wide monad remains an
  open choice and must not reintroduce application-wide state.
- Own CPU resources through `withResource`. The
  [resource contract](docs/resources.md) fixes the argument order, the failure
  table, the mask discipline a release must respect, and how a caller inspects
  or discards the cleanup failures a scope retains. Do not hand-roll an
  acquire/release pair that drops one of two failures.
- Keep pure algorithms separate from resource effects. Strict fields and
  packed/mutable arrays are appropriate where measured costs justify them.
- Reuse Synarchy's lessons and isolated code deliberately. Do not copy its
  game managers, environment, giant prelude, or workflow audits wholesale.
  Inspect its existing logging and resource decisions before replacing them;
  the scratch bootstrap is not a decision to discard that design work.

## Language and build

- GHC2024, GHC 9.14.1, Cabal 3.18.1.0, `index-state: 2026-09-18T00:00:00Z`.
  [toolchain.md](docs/toolchain.md) is the qualification record and the
  authority for those versions; activate that toolchain on `PATH` before
  building, because the external-client examples require the `ghc` on `PATH`
  to be the one they were built with. Use Unicode type syntax (`∷`, `→`, `⇒`).
  The bootstrap uses standard Prelude; a custom operator vocabulary remains
  a design choice. Add extensions and dependencies only when used.
- Routine build: `cabal build all`.
- Console smoke: `cabal run exe:hetoimasia -- --smoke`.
- Current focused tests:
  `cabal test hetoimasia-foundation:foundation-tests --test-show-details=direct`,
  `cabal test hetoimasia-runtime:runtime-tests --test-show-details=direct`,
  `cabal test hetoimasia-glfw:glfw-tests --test-show-details=direct`,
  `cabal test hetoimasia-scripting-lua:lua-host-tests --test-show-details=direct`,
  and `cabal test hetoimasia-tests --test-show-details=direct`.
- On Linux only,
  `cabal test hetoimasia-scripting-lua:linux-confinement-probe --test-show-details=direct`
  runs LUA-14's confinement probe. Its validation group
  `test.lua-confinement-linux` is mandatory and CI runs it, but a green run is
  evidence rather than a verdict: where the machine cannot install the profile
  every experiment reports itself unproven. Its components are not built off
  Linux. Read [its verdict](docs/lua_linux_confinement_verdict.md) before
  building on it — the answer is `inconclusive`.
- On macOS only,
  `cabal test hetoimasia-scripting-lua:macos-confinement-probe --test-show-details=direct`
  runs LUA-15's confinement probe. It is local evidence, not a routine check:
  its validation group `test.macos-confinement` is optional, no CI runs it, and
  its components are not built off Darwin. A pull-request request block must
  name neither it nor `all-hspec`. Read
  [its verdict](docs/macos_confinement_verdict.md) before building on it — the
  answer is `inconclusive`.
- Tests belong to the package whose contract they assert. `foundation-tests`
  (`packages/foundation/test/`) owns the `Logging`, `Resources`, `Failures`,
  `Recovery`, `Workers`, `Messaging`, and `Time` components, composed by
  `Test.Foundation.Spec`; it depends on no runtime, GLFW, or console code.
  `runtime-tests` (`packages/runtime/test/`) owns the `Runtime` group, composed
  by `Test.Runtime.Spec`: the runner and application lifecycle, logging
  lifetime, reporting, supervision, inbox services, runtime opacity, the
  resource smoke, and the supervised channel and snapshot waits, against real
  foundation services; it depends on no GLFW or console code. `glfw-tests`
  (`packages/glfw/test/`) owns the headless `GLFW` group, composed by
  `Test.GLFW.Spec`: the session, window, command, control, host, dynamic
  window, monitor, input, and mode examples over the test seam, the link
  declarations, and the external-client opacity examples; it initializes no
  GLFW and needs no display. Root `hetoimasia-tests` (`test/`) owns only
  `Console` (the executable's startup and exit mapping, run as a child
  process), composed by `Test.Engine.Spec`, and depends on no GLFW package. A
  new runtime example belongs in `runtime-tests`, beside that component's own
  helpers; a headless GLFW example belongs in `glfw-tests`, and one that needs a
  real native session in `glfw-native-tests`; a console example belongs in root
  `Console`;
  in general a new example belongs in the component spec that owns the
  behaviour it asserts. `lua-host-tests`
  (`packages/scripting-lua/test/`) owns two components: the bridge's own
  examples, and `Protocol` (`Test.Lua.Protocol.Spec`), the pure task,
  admission, request, subscription, epoch, failure, and stop model in the
  package's private `model` sublibrary. Select the model's examples with
  `--test-options='--match Protocol'`; they construct no interpreter, and the
  group's last example reports that they acquired none. Every VM the suite
  constructs goes through `Test.Lua.Support.acquireVm`, which is what makes
  that report the suite's whole construction record. Run one component with
  `--test-options='--match <Component>'` on the suite that owns it; a selector
  that matches no example fails the suite rather than reporting a silent pass.
  Selectors moved with their examples: on the root suite, `--match Runtime`,
  `Resources`, `Recovery`, `Workers`, `Messaging`, `Logging`, `Failures`, and
  `GLFW` now select nothing and fail; on `runtime-tests`, `--match Supervision`
  or `--match 'Logging lifetime'` select runtime subgroups as they did at root,
  and on `glfw-tests` the GLFW group names, such as `--match 'GLFW session'`,
  select what they selected at root or in the removed window-examples executable.
- Without the GLFW SDK, build and run the foundation, runtime, Lua host, and
  root suites with `--project-file cabal.project.cpu`, which shares
  `cabal.project.common` with `cabal.project` and leaves out `hetoimasia-glfw`,
  the package that needs GLFW.
- The Lua host's binding settings live in `cabal.project.common`, not in
  `packages/scripting-lua/`: the bundled interpreter, and whether Lua's
  collection may run under unsafe calls. Read
  [its contract](packages/scripting-lua/README.md) before changing them; a
  second Lua on the machine must never reach the build.
- Never import a helper from another component's spec module. Neutral
  utilities shared by more than one suite, currently the external-client
  compiler harness (`Test.Support.ExternalClient`) and the bounded test wait
  (`Test.Support.Bounded`), live in the test-only `hetoimasia-test-support`
  library at `tools/test-support/`; only test suites depend on it. Domain
  fixtures stay beside their owning suite, built through public APIs; see
  [its README](tools/test-support/README.md) for what belongs there.
- Every validation group is declared once in `tools/validation/catalog.json`.
  Ask `python3 tools/validation/plan.py --base origin/master --head HEAD` which
  groups a change requires and why; see [validation.md](docs/validation.md) for
  the schema, the mandatory floor, and the pull-request request block.
- Keep builds warning-clean. `cabal.project` applies `-Werror` only to local
  packages and pins the Hackage index. Maintain bounds with dependency changes.
- Preserve `semaphore: False` for this multi-worktree GHC/Cabal baseline.
  Do not modify other repositories' build locks or stop their builds.
- Choose checks by changed behavior. Test failure paths and contracts rather
  than duplicating implementation details. Once suites grow, run focused
  checks locally; full sweeps require a request or an applicable project gate.
- Use Hspec wherever possible, including effectful, exception, integration,
  and resource-lifecycle tests. Use Python probes only for boundaries that
  cannot reasonably be exercised through Hspec, and document why. Keep pure
  ownership/retirement decisions testable without a GPU. No timing sleeps for
  concurrency correctness: coordinate tests explicitly.
- Headless success proves no visual result. Once rendering exists, capture
  offscreen evidence for rendering changes and measure performance claims.

## Delivery and worktrees

- This empty-repository bootstrap is explicitly authorized in the primary
  directory. After its initial commit, implementation belongs in isolated
  worktrees and the primary checkout should stay clean for Kanban integration.
- Use the installed Kanban plugin skills for issue drafting, readiness review,
  solving, PR review, and the user-selected merge workflow. Resolve the actual
  target repository; never mistake `~/work/kanban` for this project's tracker.
- Existing authorization carries across turns. Complete authorized local work
  before asking for any additional decision needed to publish it.
- Keep each issue's implementation, required docs, evidence, and validation in
  the same worktree and PR. Use `Closes #N` when that PR completes the issue.
- Standalone documentation may use a `docs-wip` worktree, resolved by branch.
  This is separate from documentation accompanying implementation.
- User-requested standalone documentation lands through the vendored
  `tools/docs_land.sh` and the installed `kanban:push-docs` skill. Inventory and
  dry-run the selection first; stop on warnings or refusals. Never use this
  lane for documentation required by a code change. See workflow.md.
- Follow the selected Kanban workflow's claim and opposite-agent review gates.
  A label alone is not proof of a fresh approval. Do not self-approve or merge
  on your own initiative; the installed drainer or explicitly requested
  supported merge workflow owns that action.
- Preserve unrelated edits and interrupted work. Never reset or clean another
  agent's worktree. Stop only processes you started and tracked.

## Files, launches, and documentation

- The current executable is console-only and safe to run. Routine local
  checks must stay headless; future windowed launches must be explicit. No debug server or port is defined yet.
- `glfw-native-tests` shows, focuses, resizes, minimizes, maximizes, and takes
  fullscreen windows on the desktop it runs on, and refuses to enter a session
  without per-run consent. Before starting a native session on a person's
  desktop, describe that disruption, ask the human user for explicit approval,
  and wait for acceptance; then supply `HETOIMASIA_NATIVE_SESSION=desktop` on
  that one command, as [docs/glfw.md](docs/glfw.md#the-native-suite) shows.
  Approval covers only the agreed session: do not reprompt during it, and do
  not carry it forward. An issue acceptance command, a PR approval, a
  persistent shell setting, or a periodic testing request is not permission
  for later desktop disruption, and the opt-in is an operational guard, never
  proof that the conversation happened. Never set the variable in a profile
  or in a script an agent runs on its own. On Linux,
  `bash tools/display/x11.sh -- <command>` runs the suite on an isolated X11
  display, supplies its own consent for that display alone, and needs no
  approval. Dry runs and the approval-free selections need none either.
- Keep build output, captures, profiling output, local configuration, secrets,
  and scratch data untracked. Retain requested evidence deliberately with its
  issue; an ignored capture alone is not a delivered artifact.
- Tests that write files use temporary locations and must not mutate personal
  configuration. Preserve authored asset and saved-content identifiers when
  migrating game content; game save schemas remain game-owned.
- Asset placeholders used for an explicit technical experiment must be labeled
  as such. Do not present them as approved production art.
- MEMORY.md records durable context and open decisions. Implementation docs
  describe current behavior; designs label proposals and unresolved choices.
  Update the relevant document with the change, without inventing completion.
- Keep instructions short. Add subsystem contracts where the subsystem lives,
  rather than growing a central inventory of every field and function.
