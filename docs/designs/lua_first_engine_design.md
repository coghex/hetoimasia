# Lua-first engine design

Make Lua the authoring and orchestration surface for games and mods, over a
generic engine that owns state and service lifetimes without knowing a game.
This document carries request `user-het-luafirst-20261021-1435`.

Design state: `exploring`

Owner repository: `coghex/hetoimasia`; publication branch: `master`.
Started 2026-10-21 by `het-designer-1`. Questions and owner-answer relays belong
in `#het-luafirst`. Only owner signoff turns a proposal into a decision.
The current pass records direction and the first decision checkpoint; it is
not an approved specification or authority to implement or file issues.

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Run Lua-authored games and mods through a generic engine

No delivery slices are defined yet. Their boundaries and order depend on the
owner's answers below. The umbrella's relationship to existing epic #145 also
needs explicit reconciliation; this entry does not request a duplicate epic.

## Epic contract

- **Goal:** the executable starts Lua without game-specific Haskell; Lua
  defines the game, routines, data and assets while the engine holds state
  and implements protected services.
- **Done when:** not settled. The briefing proposes a first runnable milestone
  that boots Lua, opens a window and draws a texture, followed by input, the
  generic state store, mods and UI. The final observable arc boundary needs
  owner signoff.
- **Users and operators:** game and mod authors, the owner running their
  content, and maintainers of the reusable engine and its Lua interfaces.
- **Arc label:** None proposed.

## Current state and evidence

Inspection baseline: `master@5162e98f6176e07d25b80e88e76cf05f514b79c4`.
No build, probe or desktop session ran for this draft.

- The [Lua host](../../packages/scripting-lua/README.md) exposes explicit
  library selection, opaque protected owners, registered bindings and bounded
  copied values. Each owner receives its own binding policy. Host-supplied
  modules are text-only, have distinct environments and explicit identities,
  and are loaded from supplied bytes; the host searches no filesystem path.
  Module environments separate names, not security boundaries.
- The host currently offers base, package, string, table, math, io, os, debug
  and coroutine libraries. Debug omits `sethook` only. Base still includes
  `loadfile` and `dofile`. See
  `packages/scripting-lua/bridge/Hetoimasia/Scripting/Lua/Internal/Library.hs`
  and `packages/scripting-lua/bridge/cbits/hetoimasia_lua_bridge.c`.
- The existing `lua` command uses a single-VM runner, with base, string, table,
  math and coroutine libraries; it closes io, os, package and debug. The runner
  reads explicit files, owns instances and returns a bounded report. It opens
  no window. Its public configuration is not yet a generic engine service
  composition interface. The existing command is not the proposed filtered
  game runtime merely because some libraries are closed.
- Instances already support `init`, periodic `update`, one-shot `run`, event
  callbacks and optional `shutdown`. Engine-held leases protect acquisitions
  even when init or shutdown fails or Lua loses the handle. These are reusable
  mechanisms, not a settled new boot contract.
- [The two-domain sample](../../samples/lua-domains/README.md) directly
  composes independent UI and gameplay owners. Its Haskell-owned world and
  commit policy are sample-specific. Gameplay stages effects; the driver
  accounts for a tick before an atomic commit of state and publication.
  A failed session retains its last good world. This is evidence to reuse,
  not an already delivered generic engine state store.
- [Lua D-23](../lua_runtime_design.md#d-23-deterministic-simulation-is-a-design-requirement)
  qualifies the same build/platform, initial state, content, seed, tick-assigned
  inputs and scheduling configuration. D-47 supplies the accounting wait;
  D-48 attributes late independent failures by the first uncommitted tick when
  recorded. Such unassigned failures do not carry a trace-equality guarantee.
  The [latest guide report](../guide/2026-10-21T140406Z-b7f3b56.md) preserves
  this limit and reports the trusted milestone delivered at `b7f3b56e`.
- The [2D design](render_2d_design.md), especially D-12/D-20, separates pure
  scenes from Vulkan recording and assigns Lua bindings to the Lua arc.
  [Asset decoding](asset_design.md) consumes bytes; file loading is the caller's
  responsibility. Mod-supplied content was deferred by that older design.
  [The image2d sample](../../samples/README.md) already composes decoded PNG
  and KTX2 images, texture registration and per-window 2D scenes in Haskell.
- [GPU services](gpu_resource_services_design.md),
  [window/graphics lifetime](../window_graphics_lifetime_design.md) and
  [GLFW integration](../glfw_integration_design.md) retain native ownership:
  GLFW on the main thread, graphics under its protected owner, resources held
  until actual GPU and presentation retirement. Lua bindings must preserve
  these boundaries.
- Read-only tracker inspection on 2026-10-21 found only two open issues:
  [#145](https://github.com/coghex/hetoimasia/issues/145), the existing Lua
  epic, and deferred rendering extension
  [#446](https://github.com/coghex/hetoimasia/issues/446). #145 now records the
  trusted milestone delivered, but still requires the confined branch and
  successful platform qualification. No separate Lua-first epic was found.
  Recheck overlap at readiness.

## Desired experience and scope

D-1 through D-3 below are the owner's settled direction. Game and mod Lua
orchestrate the game and use engine services without direct OS functionality.
The engine stores the state generically and commits Lua-defined changes per
tick, preserving deterministic simulation and explicit failure handling.

The exact boot interface, mod composition, generic data model, bindings, UI
scope and compatibility promises remain open. The briefing names windows,
input, scenes, layers, sprites, textures and time for discussion, with 3D and
audio later; this is a design agenda, not approved delivery scope.

This design session changes only this document. Production code, tracker
mutations, changes to the vision or prior design, review and issue processing
are outside this session's authorized work. No subagents are used.

## Decisions

The quotations below arrived in the owner-supplied manager briefing, not as
answers typed in this designer's pane. The authenticated manager's relay
`nghi5qr7bx34xmdh38fbq72dse` at **2026-10-21 14:41:43.272 UTC** confirms
the direction, trust and state choices. The original answer times, except
the approximate direction time, were not supplied; none are invented here.

### D-1. Lua orchestrates the game without game-specific engine startup

Owner, **2026-10-21 approximately 14:35 UTC**, in the manager's pane:

> mods are what i want, the engine code should simply start running lua, without any concern for what the game is, then the lua handles everything, orchestrates the game, sets the routines, the data, loads the textures. we need to build as much of the interface in lua as we can

The verified manager status `j6j4qt8pn5mub3txv8miw8df5n` at
**2026-10-21 14:35:49.713 UTC** also records this direction. Concrete API
coverage and the boot protocol remain choices to settle, not implied details.

### D-2. Game and mod scripts are trusted, with OS functionality removed

Owner, **2026-10-21, exact answer time not supplied**, in the manager's pane;
relayed through the briefing and the 14:41:43.272 UTC message above:

> mods = game, trusted, but we need to filter out the dangerous commands from the library. mods and game lua should not be able to use os functionality

The filtering profile is Q-1. The resulting disposition of the previous
confined branch is separately reserved for explicit reconciliation, Q-8.

### D-3. Engine holds, Lua defines

Owner, **2026-10-21, exact answer time not supplied**, in the manager's pane;
same relay provenance:

> Engine holds, Lua defines

The option offered to the owner was: Lua defines data and rules; the engine
stores state generically and commits Lua's changes per tick, keeping D-23 and
V-4 guarantees. The generic representation and transaction API are Q-5.

### D-4. Hold a fresh design session

Owner, **2026-10-21, exact answer time not supplied**, in the manager's pane;
source is the supplied briefing, corroborated by the manager's start relay:

> Fresh design session

The endpoint is owner signoff on this design and dependency-ordered slices.
Review and issue processing come later on the manager's instruction.

## Proposals

### P-1. A common filtered library profile for game and mod content

**Unapproved; first owner checkpoint, Q-1.** Recommended option A:

| Surface | Proposed author-visible contract |
| --- | --- |
| `os`, `io` | Absent in full; no direct filesystem, environment, shell, process or OS-clock access. |
| Standard `package` and its `require` | Absent, including search paths, searchers and C/native loaders. A separately designed engine module loader supplies content imports (Q-2). |
| `load`, `loadfile`, `dofile` | Absent; executable source enters through the engine's content loader, not arbitrary paths, bytecode or runtime strings. |
| `debug` | Absent in full; engine-generated failure reports retain diagnostic context without granting Lua debug access. |
| `string.dump` | Absent; no script-side bytecode export. |
| `collectgarbage` | Absent; GC policy and memory diagnostics remain engine-owned. |
| Base, string, table, math, coroutine | Keep ordinary computation and the existing supported coroutine behavior after the exclusions above. Preserve the logical-domain restriction on `math.random`/`math.randomseed` and the owned seeded stream; presentation randomness remains separate. |
| Output and time | Route script output through engine diagnostics; expose time through the engine's domain-appropriate interface. Exact bindings remain Q-6. |

Apply the restrictions before any game/mod module runs. Closing a global name
while leaving an alternate exposed library reference is insufficient. Engine
bindings must not reintroduce an unrestricted OS escape.

Alternative B keeps the same OS/file/native/debug exclusions but additionally
permits text-only in-memory `load` and read-only GC statistics. It offers dynamic
code generation and script-visible memory measurements at the cost of another
execution-entry contract and nondeterministic observations that must be kept
out of authoritative gameplay. Neither option is approved. No alternative
allows raw file access or native loading.

The recommendation is A: ordinary game authoring can use modules and explicit
engine services, with a smaller supported execution surface. The consequence
is that scripts using these removed functions require changes. This affects
the future library-profile, content-loading and boot slices; those slices have
not yet been decomposed or approved.

Filtering removes ambient OS authority; it is **not hostile-code containment**.
A trusted script can still hang its owner or exhaust process memory.
Cooperative budgets are not hard limits, and protected dependencies remain
held until actual completion. This follows existing Lua D-13/D-14 and is not
an additional guarantee of either option.

## Open questions

### Q-1. Which filtered standard-library profile applies to every script?

Awaiting owner choice between P-1 option A (recommended), option B, or a
specified revision. This is the only active decision checkpoint. Settling
this does not settle file resolution or the old epic's disposition.

### Q-2. How does content loading replace filesystem and package access?

Settle modules, data and textures scoped to game/mod content roots, module
identity/cache/cycles, cross-mod access, root/path and symlink handling,
failure attribution and when loading is allowed. No engine API spelling or
search/override policy is decided yet.

### Q-3. What is the generic executable's boot and session contract?

Settle content root and entry selection, startup validation, init, logical
updates, presentation/UI updates and shutdown; boot/session failure reporting,
exit behavior and compatibility with the existing headless `lua` command.
Keep D-27 cleanup independent of successful Lua shutdown.

### Q-4. How are mods discovered, ordered and combined?

Settle selection, dependency/load order, conflicts, replacement and override
scope, attribution of a mod's failure, and the point at which the content set
is fixed. Trust does not itself define these behaviors.

### Q-5. What generic engine state does Lua define and mutate?

Settle entities/components versus tables/schemas, validation, stable identity,
read visibility while staging, atomic tick commit, bounded capacity and
failure. Carry D-23 and D-47/D-48's exact guarantees into this store. Settle
whether saves, schema migration and hot reload are excluded or included;
game-specific save semantics remain game-owned under the existing rules.

### Q-6. Which services and UI behavior does Lua drive in this arc?

Settle windows, input, 2D scenes/layers/sprites/textures, time and diagnostics;
whether UI is authored in Lua over 2D and what text/widget scope that needs;
what is later for 3D/audio. Haskell retains native threading and GPU lifetime
obligations; the new binding and service boundaries need concrete contracts.

### Q-7. What is the default domain arrangement for games and mods?

Settle the UI/gameplay pair and how mods map to owners/modules/instances.
Lua D-15 supplies general independent owners, not a mandatory hard-coded pair.
Keep coherent publication and no synchronous cross-owner VM entry.

### Q-8. How should the prior vision and Lua epic be reconciled?

The manager proposes that V-9 and Q-5 cease to require confined processes for
trusted mods, and LUA-9–13/16/17 cease to be required for that purpose, while
LUA-14/LUA-15 verdicts remain historical evidence. The manager also reads V-1
as making the Lua game the application with engine-held generic state.
These are proposals to present as exact reconciliation text for owner signoff.
Do not edit `docs/vision.md`, the old design or #145 in this session. Decide
the new arc's relationship to #145 before readiness or tracker processing.

### Q-9. What is the accepted delivery order and final scope?

The briefing proposes the first runnable milestone as Lua boot with the
filtered library, a window and a texture; then input, state, mods and UI.
Confirm this order and split it into one-PR outcomes only after the dependent
choices above are settled. Identify verification, compatibility, persistence,
migration and deliberate deferrals for each affected slice before readiness.

## Verification strategy

Existing constraints to preserve: focused Hspec suites selected by the
validation catalog; coordinated failure/concurrency checks without timing
sleeps; Linux CI and local macOS evidence; native consent scoped to the
qualifying command. A headless success proves no displayed result.

Proposed acceptance families, to refine after owner decisions: forbidden
library and alternate-reference checks; content-root refusal and attribution;
boot/init/shutdown failures with engine-held cleanup; independent UI progress;
generic-store canonical state at logical boundaries under varied execution
delays with fixed inputs; failed-tick discard and the accounting cutoff;
mod ordering/conflicts; Lua-authored rendered output checked by offscreen
pixels and explicit windowed evidence. No new performance, hostile-code
containment or cross-platform determinism claim is proposed.

## Delivery plan

Zero defined slices. Stop before decomposition while material choices remain
unanswered. When choices settle, use stable `LFE-N` IDs, dependencies and
one-PR acceptance signals in exactly the same order as the processing ledger.

## Source notes

The owner explicitly supplied and instructed this session to follow
`~/.local/state/project-manager/hetoimasia/request-user-het-luafirst-20261021-1435-design-prompt.md`.
This document preserves its exact owner quotations and records relay
provenance so the local briefing is not the sole lasting record. Later answers
must record their quotation, date/time and verified relay message ID, or
identify arrival directly in the designer's pane.
