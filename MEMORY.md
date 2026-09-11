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
- GitHub target: `coghex/hetoimasia` (public). Use `master`, not `main`.
  The owner corrected the original repository-name typo on 2026-09-10 and
  created the correctly named empty repository. Preserve the local bootstrap
  history when republishing; local directory/package names already match.
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
- Logger accepts an injected sink and injectable clock/thread metadata, applies
  a pure filter (master switch, global and per-component thresholds, independent
  Debug selection, source switch), carries immutable derived fields and
  breadcrumbs, and validates dotted component names. It is synchronous; see
  [docs/logging.md](docs/logging.md). Runtime invokes a supplied action and
  propagates failures. Both were written from scratch; no Synarchy
  implementation was copied.
- LOG-2 settled the record layout: one line per entry, UTC to the millisecond,
  quoted text that cannot split a record, and fields sorted by key. Handle sinks
  serialize writes and flushes across the loggers sharing them and release that
  state on failure or interruption; callback sinks carry their own flush.
  Borrowed handles stay the caller's, unclosed and with their buffering intact.
- LOG-3 completed the arc: foundation parses the three configurable parts of a
  filter purely, `resolveLogFilter` assembles them over caller-supplied variable
  names and a caller-supplied lookup, and the console reads
  `HETOIMASIA_LOG_LEVEL`, `HETOIMASIA_LOG_LEVELS`, and `HETOIMASIA_DEBUG` once at
  startup, failing non-zero on an invalid value before any entry. The master and
  source switches stay programmatic. `docs/logging.md` now carries the startup
  contract and the module authoring guide AGENTS.md points new subsystems to.
- Console `--smoke` needs no GPU, Lua, window, network, or Synarchy process.
- Planned component directories contain ownership notes, not implementations.
- Local Git initialized on `master`, with `origin` pointing to
  `https://github.com/coghex/hetoimasia.git` for the authorized initial baseline.
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

## Kanban integration — 2026-09-10

- Kanban's read-only doctor passed all issue/PR actions for this checkout.
  Shared review backend, Codex plugin, and Claude plugin setup plans all reported
  unchanged. These dependencies are user-installed outside the repository.
- The repository vendors the docs landing helper and checker from Kanban,
  with its MIT notice retained under `tools/`. The local adaptation supports
  the regular authoritative `AGENTS.md`; no instruction-file migration is needed.
  Provenance and checks are recorded in [tools/README.md](tools/README.md).
- Use `kanban:push-docs` for user-requested standalone documentation batches.
  Mixed code/docs remain in the same PR. Plugin-owned design/report helpers
  come from the installed bundle, not this repository's `tools/` directory.
- The owner then supplied Kanban's missing-service screenshot. Installed the
  issue-approval and PR-drainer jobs for `coghex/hetoimasia` using Kanban's
  installer/controller. Both are loaded in launchd and have not been started;
  the approval controller has no run-status document yet. Board keys `a` and
  `d` control them.
- The owner explicitly approved publishing this tested tooling setup directly
  to `master` as a bootstrap exception. Subsequent implementation still follows
  the normal PR lane. The ready designs were separately published in `0d9be37`.

## Open choices and next work

- CI runs the validation pipeline and the review gate described in
  [validation.md](docs/validation.md). `build-test` and `review-approved` are
  the checks the installed drainer reads. A prose-only update now inherits an
  earlier run's code evidence through candidate input identity and receipt
  artifacts; clean-merge review inheritance is still unimplemented. The
  selected GitHub repo was verified empty with zero issues and PRs before the
  initial publication on 2026-09-10; repeat deduplication when turning designs
  into tracker artifacts.
- On 2026-09-10 the owner requested review and readiness of both discussed
  designs. [Logging](docs/logging_design.md) has three slices;
  [resource ownership](docs/resource_ownership_design.md) has four. Both were
  published to `master` on 2026-09-10 as `ready for issue processing`. Logging
  is now implemented (#1 through #4). On 2026-09-11 the owner accepted a review
  of the resource design and re-granted readiness: it records the satisfied
  logging gate, the catalog and test-grouping obligations, and D-6 through D-9
  (uninterruptible bounded release, exception-annotation evidence with rethrow
  rules, bracket argument order with `withScoped` as the only runner, and a
  staged composite constructor). No `smoke.resource` catalog group. The
  original resource proposal path is now a navigation stub.
- The logging-first gate is satisfied: LOG-3 (#4) merged in `cb2a25d`.
  Resource primitives themselves remain independent of the logging module.
- Accepted resource failure policy: retain the original action/cancellation
  failure, preserve secondary cleanup failures independently of logging, and
  attempt remaining eligible cleanup. Cleanup-only failure fails the operation.
  Preserve typed catch behavior and inspectable structured evidence.
- The resource design selects a small scoped continuation facade for
  `allocResource`/`locally`, over safe CPU ownership and composite constructors.
  An application-wide monad remains undecided. Dynamic ownership transfer and
  GPU retirement are later work. FND-1 reuses the resource epic and its children;
  do not create a second implementation from the broader foundation plan.
- Unicode type syntax is retained; standard Prelude is the bootstrap choice.
  A broader custom operator/prelude policy is undecided.
- First rendering milestone, threading needs, Vulkan baseline, window library,
  render contract, and Lua integration need bounded design and implementation.
- No engine save format or game migration commitment exists yet.
