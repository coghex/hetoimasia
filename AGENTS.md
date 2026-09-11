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
- Publish coherent data across thread boundaries. Add concurrency for a
  concrete need and establish queue/snapshot ownership and cancellation first.
- Use explicit `IO` or a small local context initially. The resource design
  selects a scoped continuation facade; an application-wide monad remains an
  open choice and must not reintroduce application-wide state.
- Keep pure algorithms separate from resource effects. Strict fields and
  packed/mutable arrays are appropriate where measured costs justify them.
- Reuse Synarchy's lessons and isolated code deliberately. Do not copy its
  game managers, environment, giant prelude, or workflow audits wholesale.
  Inspect its existing logging and resource decisions before replacing them;
  the scratch bootstrap is not a decision to discard that design work.

## Language and build

- GHC2024, GHC 9.12.2, Cabal 3.16.1.0. Use Unicode type syntax (`∷`, `→`, `⇒`).
  The bootstrap uses standard Prelude; a custom operator vocabulary remains
  a design choice. Add extensions and dependencies only when used.
- Routine build: `cabal build all`.
- Console smoke: `cabal run exe:hetoimasia -- --smoke`.
- Current focused tests: `cabal test hetoimasia-tests --test-show-details=direct`.
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
- No docs landing helper is installed here. Do not invoke Synarchy's helper or
  claim `$push-docs` is configured. See workflow.md for the current status.
- Follow the selected Kanban workflow's claim and opposite-agent review gates.
  A label alone is not proof of a fresh approval. Do not self-approve or merge
  on your own initiative; the installed drainer or explicitly requested
  supported merge workflow owns that action.
- Preserve unrelated edits and interrupted work. Never reset or clean another
  agent's worktree. Stop only processes you started and tracked.

## Files, launches, and documentation

- The current executable is console-only and safe to run. Future windowed
  launches must be explicit; default automated checks should use headless or
  offscreen modes once implemented. No debug server or port is defined yet.
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
