# Lua-first engine design

Make Lua the authoring and orchestration surface for games and mods, over a
generic engine that owns state and service lifetimes without knowing a game.
This document carries request `user-het-luafirst-20261021-1435`.

Design state: `exploring`

Owner repository: `coghex/hetoimasia`; publication branch: `master`.
Started 2026-10-21 by `het-designer-1`. Questions and owner-answer relays belong
in `#het-luafirst`. Only owner signoff turns a proposal into a decision.
The current pass records direction and the session-loading checkpoint; it is
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

D-1 through D-3 below are the owner's settled direction; D-5 settles the
standard-library exclusions and D-6 settles content addressing. Game and mod Lua
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

The filtering profile is settled by D-5 (Q-1). The resulting disposition of the previous
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

### D-5. Use profile A, with no exceptions to the listed removals

Owner answer, **2026-10-21 14:51:42 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: smaller (Recommended)

Authenticated relay: `het-manager`, message `bdck3xh3mbqzpyp2ss7bpw8em6`,
posted **2026-10-21 14:51:42.794 UTC** in `#het-luafirst`, replying to Q-1
message `xh6q5jhu8kdhn8j46kj5jyit6s`. The owner was shown these exact
exclusions and told that neither option prevents hanging or memory exhaustion.

| Surface | Approved exclusion for game and mod Lua |
| --- | --- |
| `os`, `io` | Absent in full; no direct filesystem, environment, shell, process or OS-clock access. |
| Standard `package` and its `require` | Absent, including search paths, searchers and C/native loaders. A separately designed engine module loader supplies content imports (Q-2). |
| `load`, `loadfile`, `dofile` | Absent; executable source enters through the engine's content loader, not arbitrary paths, bytecode or runtime strings. |
| `debug` | Absent in full. |
| `string.dump` | Absent; no script-side bytecode export. |
| `collectgarbage` | Absent, including read-only statistics. |

Apply the restrictions before any game/mod module runs. Closing a global name
while leaving an alternate exposed library reference is insufficient. Engine
bindings must not reintroduce an unrestricted OS escape.

The choice keeps the supported surface small; scripts using removed functions
must change. Rejected option B would have allowed text-only in-memory `load`
and read-only GC statistics. No exception for either is approved. This affects
future library-profile, content-loading and boot slices, whose boundaries are
not yet settled. It does not decide whether the existing standalone headless
command changes; that compatibility choice remains Q-3.

Filtering removes ambient OS authority; it is **not hostile-code containment**.
A trusted script can still hang its owner or exhaust process memory.
Cooperative budgets are not hard limits, and protected dependencies remain
held until actual completion. This follows existing Lua D-13/D-14 and is not
an additional guarantee of either option.

### D-6. Address content through explicit roots, without implicit overrides

Owner answer, **2026-10-21 14:54:46 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: explicit roots (Rec.)

Authenticated relay: `het-manager`, message `yk9r4b7x8zw6r85nvywz5zjfps`,
posted **2026-10-21 14:54:46.840 UTC** in `#het-luafirst`, replying to Q-2a
message `2y2yzah4tzqzp3udsp5hswjs9s`.

A relative reference resolves in the caller's own content root. To reference
another root, a script explicitly names the game or a particular enabled mod.
Engine content reads stay inside enabled roots. The same path in two roots
never silently replaces one with the other; deliberate mod replacement remains
a later Q-4 choice. This applies to modules, data and textures. It establishes
addressing and cross-root visibility, not a concrete Lua API spelling.

This preserves predictable provenance and explicit cross-content references.
Rejected: one merged content tree whose file winner depends on mod load order.
The choice affects content loading, boot and mod composition, whose slice
boundaries are still open. Path/symlink rules, module reuse, loading phases and
save/write APIs are not approved by this answer.

### D-7. Load each module once per VM and share its exports there

Owner answer, **2026-10-21 14:58:57 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: load once per VM (Rec.)

Authenticated relay: `het-manager`, message `p7kj8m62k87v4vnj7cmd8x6njs`,
posted **2026-10-21 14:58:57.754 UTC** in `#het-luafirst`, replying to Q-2b
message `gvq9h5gpv3aq3f9fepqe3mawtw`.

Within one VM, a module is identified by content root and path. Its first
import evaluates it and obtains an export table; later imports return that
same table without rerunning top-level code. Importers share its module state
and mutable exports. Fresh local state comes from a factory or script instance.
Other VMs evaluate their own copies: Lua tables, closures and mutable module
state do not cross VM owners. D-3 still places authoritative game state in
the engine, not in these shared module tables.

Cycles are rejected with their root/path chain rather than exposing partly
initialized exports. Failed imports stay failed in that VM, expose no
successful exports and are not automatically retried. Effects already
performed are not undone by the import failure. Allowed top-level effects
and boot/session failure escalation remain separate choices.

Rejected: evaluating a fresh table and module environment on every import,
which repeats top-level effects and dependency loading. Reuse keeps module
dependencies predictable; factories make fresh local state explicit. The
choice affects content-loader and module/instance integration slices, still
undefined. Path normalization/aliases, loading phases, live reload, cache
bounds and data/texture caching are not settled by this answer.

### D-8. Acquire resources through lifecycle hooks, not module top level

Owner answer, **2026-10-21 15:04:11 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: hooks only (Rec.)

Authenticated relay: `het-manager`, message `zi64juxixem8cjdz48zffjh79a`,
posted **2026-10-21 15:04:11.762 UTC** in `#het-luafirst`, replying to Q-2c
message `wwe79m6c9vwsifzesj3rmpdcie`.

Before answering, the owner requested a fuller explanation. The manager
contrasted loading a player's texture at `player.lua` top level with doing
so in `init`, explained D-27 cleanup ownership, the lack of an owning
instance for a shared module, and failure halfway through an import. The
owner then selected A after it was presented again.

Module top level defines tables/functions, imports dependencies, uses pure
helpers and emits diagnostics. Texture/window acquisition, data reads, input
subscriptions, starting instances and world access/mutation happen in
lifecycle hooks or functions executing within their permitted lifecycle
context, with engine-held cleanup ownership and the proper tick context.
Importing a new dependency from a hook does not grant that dependency's
top-level code the hook's effectful engine authority.

This restricts engine bindings, not arbitrary Lua table mutation, and promises
no purity or rollback of Lua state. Authors move top-level resource work into
hooks. Rejected: new per-module resource scopes lasting within the VM lifetime,
with their additional shared ownership and failed-import cleanup contract.
The decision affects module loading, boot and service bindings; it does not
change the existing finite, non-suspending `init`/`shutdown` hook contract or
decide when a running session may request new content.

## Proposals

### P-1. A common filtered library profile for game and mod content

The exclusion choice is accepted by D-5; retain this proposal ID as its history.
Ordinary computation and supported coroutine behavior remain the basis for
authoring. The existing logical-domain seeded stream and separation from
presentation randomness remain constraints. Exact output, diagnostic and time
bindings still belong to Q-6; Q-1's answer does not settle their API.

### P-2. Address content by an explicit root and a relative path

The addressing choice is accepted by D-6; retain this proposal ID as history.
For illustration only: `(game-id, images/title.png)` and
`(mod-id, lua/rules.lua)`; concrete Lua syntax is not selected.

### P-3. Evaluate an imported module once per VM and reuse its exports

Accepted by D-7; retain this proposal ID as history.
The current host already separates a loaded module from its instances and
refuses duplicate loads under one identity; it exposes host-declared entry
points, not the new Lua-to-Lua export-table interface. This is new loader
behavior, not a claim that the present API supplies it.

### P-4. Import modules without starting engine services or acquiring resources

Accepted by D-8; retain this proposal ID as history. Exact binding eligibility
and loading times remain to be designed within the approved boundary.

### P-5. Permit demand loading during a running session

**Unapproved; active checkpoint Q-2d.** Recommend option A: hooks may request
previously unloaded modules, data and textures from enabled content roots
both during startup and during play. For example, entering a new room can
request its textures then, instead of loading every room before the game starts.
Native file reads, decoding and upload progress are engine-owned work, with
bounded request admission and explicit pending/completed/failed results rather
than an unbounded blocking native call on a Lua owner.

Gameplay-visible results must enter at assigned logical positions under
Lua D-23/D-36/D-39. A required result not ready at its assigned tick holds that
tick; it cannot skip work or enlarge gameplay `dt`. Independently paced
presentation can continue showing already available content and handle its
own load results without advancing authoritative state by wall-clock timing.
The later binding and boot designs must settle the exact request/await API,
what counts as presentation-only, and failure policy. A finite `init` may
initiate work but cannot gain a yielding wait merely from this choice.

Alternative B restricts first acquisition/import of content to startup for
this arc. A running session can use only what was loaded before it started;
new room content needs preloading or a new session. It reduces runtime-loader
scope but forces larger startup loads and constrains game authoring.

A is recommended for the Lua-authored game's ordinary content needs. Its
cost is concrete loading providers, bounds, cancellation/retirement and
logical result placement, building on the existing request machinery. The
current host already distinguishes arrival-based presentation requests from
tick-assigned requests that hold a grant until the result is available
(`packages/scripting-lua/README.md`, asynchronous requests); those mechanisms
do not yet implement these content services.

This choice affects loading, boot and service integration slices, still
undefined. It grants no live reload or mid-session mod enablement, which
remain separate scope choices, and settles neither content immutability nor
cache/eviction policy. All module evaluation still obeys D-7/D-8.

## Open questions

### Q-1. Which filtered standard-library profile applies to every script?

Resolved by D-5: profile A, with no exceptions. File resolution and the old
epic's disposition are not settled by this answer.

### Q-2. How does content loading replace filesystem and package access?

Settle modules, data and textures scoped to game/mod content roots, module
identity/cache/cycles, cross-mod access, root/path and symlink handling,
failure attribution and when loading is allowed. D-6 settles explicit root
addressing, D-7 module reuse/cycle/failure behavior and D-8 the top-level
effect boundary; engine API spelling and remaining loader behavior are open.

#### Q-2a. Explicit content-root references or one merged override namespace?

Resolved by D-6: explicit content roots, with explicit cross-root references
and no silent path overrides. Cache, lifecycle and path-resolution details
remain open.

#### Q-2b. Reuse a module's exports within a VM or evaluate afresh per import?

Resolved by D-7: shared exports from one evaluation per VM, cycle rejection,
failed imports retained as failures and no automatic retry or undo of effects.
Loading phases and failure escalation remain open.

#### Q-2c. May module top-level code acquire engine resources?

Resolved by D-8: effectful engine access belongs to lifecycle execution;
module evaluation permits definitions/imports, pure helpers and diagnostics.
This does not decide when new content may load during a session.

#### Q-2d. May a running session load new content on demand?

The only active checkpoint: P-5 option A (recommended, engine-owned runtime
loading with bounded requests and deterministic gameplay result placement)
or B (startup-only loading for this arc), or an owner-specified revision.
The result/wait API, content immutability, cache policy and escalation of
loading failures remain separate questions.

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
