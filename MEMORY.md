# Hetoimasia project memory

Updated: 2026-09-10. Durable project context for future interactive sessions.
Working rules live in [AGENTS.md](AGENTS.md); design proposals live in
[the foundation design](docs/engine_foundation_design.md).

## User intent and accepted direction

- Build a fresh modular Haskell/Vulkan game engine with Lua scripting.
- The owner already develops `~/work/synarchy`, a mature 2D engine and colony
  simulation using Haskell, Vulkan, and Lua, and knows their integration well.
- Develop 3D support here, with separate 2D and 3D modules sharing appropriate
  runtime/GPU services. Introduce a small 2D consumer early to test boundaries.
- Synarchy's game may eventually migrate through an application-owned adapter.
  This is a substantial future port, not automatic compatibility from a sprite
  renderer. Preserve useful assets, algorithms, and Lua behavior where practical.
- Keep game rules/state, game presentation, runtime services, rendering APIs,
  and Vulkan implementation separate. The application assembles them.
- Avoid repeating Synarchy's central `EngineEnv` ownership and dependency
  problem. Smaller records alone do not remove that problem.
- Use `~/work/kanban` and installed Kanban skills in interactive CLI sessions
  for issue/PR development. This repository is the target project; Kanban is
  the workflow application. Existing worktree and review habits carry over.
- Mixed implementation and documentation always travel in the same PR.
- Use Hspec wherever possible; Python probes are the fallback only where Hspec
  cannot reasonably exercise the boundary. This applies to future resource,
  concurrency, and Vulkan integration tests as well as pure code.
- GitHub target: `coghex/hetiomasia` (public), deliberately spelled differently
  from the local `hetoimasia` directory/packages. Use `master`, not `main`.
  The owner explicitly requested the initial commit and remote setup.
- License: GNU GPLv3, requested explicitly by the owner; recorded as
  `GPL-3.0-only` in every Cabal package with the full license text included.

## Relevant Synarchy evidence

Inspection during the design conversation found a 92-field EngineEnv, game
manager initialization under Engine.Core, and Vulkan helpers using an EngineM
whose environment is fixed to that application-wide record. Game-specific Lua
registrations also live under Engine. Verify current code before migrating it.

Useful existing ideas include stable bindless texture handles, shader/host
layout agreement, packed sprite buffers, and coherent render-data publication.
The main sprite path expands sorted quads into six vertices; text uses GPU
instancing. The sprite shader fixes Z to zero and the render pass has no depth
attachment. Preserve the lessons without importing game-specific ownership.

The owner values Synarchy's carefully considered, pre-AI logging/resource design.
The current logger has early filtering before timestamp/thread/context collection,
per-category controls, structured context, and injectable output backends.
`Engine.Core.Resource` expresses cleanup through continuations; `allocResource'`
can position cleanup separately from allocation order (used for buffers/memory).
These ideas deserve deliberate evaluation. A continuation abstraction does not
require a universal EngineEnv. Shared mutable logging context and broad environment
access should not be ported automatically. The scratch logger here is a bootstrap,
not a verdict that Synarchy's design should be discarded.

## Implemented bootstrap

- Three Cabal packages: root console/tests, `hetoimasia-foundation` logging,
  and `hetoimasia-runtime` application entry point. Separate source roots.
- Logger accepts an injected sink, filters by level, and borrows output handles.
  It is synchronous. Runtime invokes a supplied action and propagates failures.
  Both were written from scratch; no Synarchy implementation was copied.
- Console `--smoke` needs no GPU, Lua, window, network, or Synarchy process.
- Planned component directories contain ownership notes, not implementations.
- Local Git initialized on `master`, with `origin` pointing to
  `https://github.com/coghex/hetiomasia.git` for the authorized initial baseline.
- GHC 9.12.2 / Cabal 3.16.1.0 verified locally. Hackage index baseline copied
  deliberately from Synarchy: 2026-08-14T00:00:00Z.

## Bootstrap verification — 2026-09-10

- `cabal build all`: passed for all three packages with local warnings as errors.
- `cabal test hetoimasia-tests --test-show-details=direct`: passed four Hspec
  checks covering filtering, sink failures, action ordering/results, and failure
  propagation without a false completion entry.
- `cabal run exe:hetoimasia -- --smoke`: passed with the three expected log lines.
- `cabal check` in all three package directories: exit 0 with no warnings.
  All packages declare the confirmed GitHub source repository.
- Local documentation links resolve; all package copies of GPLv3 match the
  full text retrieved from `https://www.gnu.org/licenses/gpl-3.0.txt`.

## Open choices and next work

- CI and Kanban per-repository services remain unset. The selected GitHub repo
  was verified empty with zero issues and PRs before the initial publication on
  2026-09-10; repeat deduplication when turning designs into tracker artifacts.
- The custom continuation monad is undecided. Start with explicit dependencies
  and scoped resource ownership; introduce a monad only for a concrete benefit.
  [Resource ownership](docs/resource_ownership.md) proposes CPU scopes, private
  subsystem owners, and GPU completion-aware retirement. It is not implemented.
- Unicode type syntax is retained; standard Prelude is the bootstrap choice.
  A broader custom operator/prelude policy is undecided.
- First rendering milestone, threading needs, Vulkan baseline, window library,
  render contract, and Lua integration need bounded design and implementation.
- No engine save format or game migration commitment exists yet.
