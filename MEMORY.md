# Hetoimasia project memory

Updated: 2026-09-13. Durable project context for future interactive sessions.
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
- RES-1 added `Hetoimasia.Foundation.Resource`: `withResource` acquires under
  `mask`, lends the value to a body running with the caller's masking state,
  and attempts one release under `uninterruptibleMask_`. It implements the
  accepted failure policy rather than aliasing `bracket` — the body's failure
  stays primary, a cleanup-only failure becomes primary and is retained as
  evidence too, and every cleanup failure is kept as an ordered, labelled
  `CleanupFailure` that `cleanupFailures` reads back, including through a
  caller's `WhileHandling` nesting. Every internal rethrow uses `rethrowIO`
  with the primary's own context. `docs/resources.md` carries the contract.
  RES-2 through RES-4 subsequently added ranked composite construction,
  the `Scoped` continuation facade (`withScoped`, `allocResource`,
  `allocComposite`, `locally`), and the injected runtime resource demonstration.
  All are implemented at `7e92e73`, with the later repairs reviewed. The
  demonstration's `Channel` is an owned pair of slots, not a message queue.
- RT-1 (#53) added `Hetoimasia.Foundation.Failure`: `throwFailure` attaches a
  component, operation, identifiers, and outermost-frame caller site to a typed
  exception's context without wrapping it; `withOperationContext` adds ordered
  outer context to synchronous failures, leaving cancellation unannotated and
  native causes native with an unknown throw site; `failureEvidence` reads it
  back without a logger. `docs/failures.md` carries the contract, and the
  `Failures` Hspec group proves it.
- RT-2 (#54) added `Hetoimasia.Foundation.Recovery`: `recover` runs one
  complete owned `IO` operation under an explicit, validated policy (component
  classifier, one finite budget across retry and named fallback, required or
  optional disposition, injected wait). Cancellation and attempts with cleanup
  evidence propagate before classification; histories ride on the propagated
  failure as an annotation. No logger and no `Scoped` catch instance.
  `docs/recovery.md` carries the contract; the `Recovery` Hspec group proves it.
- RT-3 (#55) added `Hetoimasia.Runtime.Reporting`: `reportOutcome` warns once
  for a recovered or unavailable outcome the caller already holds, and
  `reportTerminalFailure` makes one guarded `Error` attempt, then rethrows
  preservingly with a mark so enclosing boundaries do not report again. Origin
  goes in `origin.*`/`observed.*` fields, separate from the entry's source.
  `DiagnosticFailure` moved into it; `resourceSmoke` is its consumer. The
  contract is in `docs/logging.md`, proven by `Runtime`'s `Outcome reporting`.
- RT-7 (#58) added `Hetoimasia.Runtime.Logging`: `withLoggingLifetime` borrows
  a logger, lends it through a `LoggingLifetime` handle that records managed
  reporting-attempt outcomes (`reportTerminalFailureWith`'s recorder), and makes
  at most one final flush after the callback, outside releases, following P-11's
  matrix; secondary flush failures and known failed reports ride on the failure
  as evidence. Both console paths run inside it, the resource path through
  `managedResourceSmoke`. Contract: `docs/logging.md`, "Logging lifetime".
- RT-8 (#59) added `Hetoimasia.Runtime.Supervision`: `withSupervision` owns one
  worker group inside a logging lifetime and lends `RuntimeControl`;
  `startSupervised` registers a `Service`/`Job` role, `Required`/`Optional`
  disposition, and component classifier before child code runs, with a startup
  wait woken by certainly-fatal outcomes; `checkRuntime` and `awaitSupervised`
  select, classify outside STM, commit, then warn or rethrow; the first fatal
  status is latched and simultaneous failures are ordered by registration.
  Closing reuses `closeWorkerGroup`'s snapshot and drain; a cancelled body
  classifies nothing more. Runtime now depends on `stm`. Contract:
  `docs/supervision.md`; `Runtime`'s `Supervision` Hspec group proves it.
- RT-6 (#60) added `Hetoimasia.Runtime.Application.runScopedApplication` beside
  the unchanged `Hetoimasia.Runtime.runApplication`: it enters a caller-supplied logging lifetime,
  builds application-owned dependencies with `withScoped`, runs supervision,
  startup, and the action on the calling thread with an application-owned
  immutable services value, then closes and drains workers, disposes
  dependencies, makes one managed terminal report, and lets the lifetime flush.
  The console's exit mapping lives in the root package's private `console`
  library (`Hetoimasia.Console.Exit`): failure exits 1, cancellation 130.
  Contract: `docs/resources.md`, "The application runner"; `Runtime`'s
  `Application lifecycle` Hspec group proves it.
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
  artifacts. Review inheritance requires a proven approved revision and an
  identical-tree push or an exact clean merge with a commit already on master;
  CI evidence is assessed independently. See [workflow.md](docs/workflow.md). The
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
  The runtime design uses explicit IO and narrow handles over this facade;
  an application-wide monad is outside the accepted arc. Dynamic ownership transfer and
  GPU retirement are later work. FND-1 reuses the resource epic and its children;
  do not create a second implementation from the broader foundation plan.
- Unicode type syntax is retained; standard Prelude is the bootstrap choice.
  A broader custom operator/prelude policy is undecided.
- The first rendering milestone is a window with a rendered triangle, explicitly
  selected by the owner. On 2026-09-12 the owner selected macOS and Linux
  verification from the start, with Linux-only remote CI and macOS validation
  locally. Do not add hosted macOS jobs. The Vulkan baseline, thread/ownership
  APIs for graphics, Linux graphics test environment, render contract, and Lua integration
  still need bounded design. See [the backend design](docs/vulkan_backend_design.md).
- The owner clarified that reusable infrastructure must come before Vulkan:
  messaging, runtime initialization/lifecycle, threading, and GLFW should be
  developed methodically and validated independently. The triangle is an
  eventual graphics milestone, not a near-term demonstration target. Queues
  with Hspec coverage are accepted as pre-graphics work; include worker
  lifecycle before Vulkan even though a triangle alone would not require it.
- Separate GLFW and Vulkan components and a first main-thread window/render
  loop are accepted. Worker support does not move GLFW's owning-thread
  operations. The resource continuation is implemented. The
  [runtime foundation design](docs/runtime_foundation_design.md) now specifies
  component contexts, scoped construction, recovery, worker ownership,
  supervision, and boot/shutdown composition through explicit IO and narrow
  handles. RT-5 (#57) implements the raw worker contract in foundation's
  `Hetoimasia.Foundation.Worker` ([docs/workers.md](docs/workers.md)): a group
  boundary with a `Scoped` adapter, gated fork/registration, STM startup and
  terminal observation, run-exit ordering, group-owned cancellation helpers,
  retirement, and a protected drain; it adds `stm`, not `async`. Supervision
  (RT-8, #59) is implemented in `Hetoimasia.Runtime.Supervision`; application
  integration (RT-6) still awaits implementation, and
  `runApplication` still only logs around an `IO` action and neither constructs
  services nor supervises workers.
- Runtime epic #52 and all eight children #53–#60 are filed and approved as of
  2026-09-13. Issue-review amendments are part of each implementation spec.
  Solve #53 → #54 → #55, then #56 → #57 alongside #58, then #59 → #60.
  Use normal freshness/claim gates; do not create duplicate runtime issues or
  reopen accepted D-13 through D-18 decisions. Workers keep borrowed dependencies
  alive until completion; supervision uses checkpoints and supervised waits;
  logging finalization has its own IO lifetime outside controlled releases.
  Application services remain application-owned and immutable. Messaging and
  independent GLFW work still need their own designs before Vulkan.
- The owner wants Synarchy's solid GLFW integration preserved deliberately.
  The backend design records its existing window/callback, resize, Vulkan
  synchronization, and shared-scope test decisions as reuse evidence.
- Review at `7e92e73` found no current defect in the cleanup-evidence opacity
  repair (#47 / PR #48) or TEST-1 (#50 / PR #51). Local checks passed 145 engine
  and 262 workflow examples, build, smoke, and the three focused component
  selections; an empty selector fails. Logging, Runtime, and Resources now
  compose through `Test.Engine.Spec`. Graphics fixtures remain deferred TEST-2;
  no backend implementation exists yet. Earlier bootstrap entries above are
  historical snapshots, not the present resource implementation inventory.
- No engine save format or game migration commitment exists yet.
