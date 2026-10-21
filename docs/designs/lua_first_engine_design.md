# Lua-first engine design

Make Lua the authoring and orchestration surface for games and mods, over a
generic engine that owns state and service lifetimes without knowing a game.
This document carries request `user-het-luafirst-20261021-1435`.

Design state: `exploring`

Owner repository: `coghex/hetoimasia`; publication branch: `master`.
Started 2026-10-21 by `het-designer-1`. Questions and owner-answer relays belong
in `#het-luafirst`. Only owner signoff turns a proposal into a decision.
The current pass records direction and the entry-lifecycle checkpoint; it is
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

### D-9. Allow engine-owned content loading while the game runs

Owner answer, **2026-10-21 15:08:24 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: load while running (Rec.)

Authenticated relay: `het-manager`, message `6hvhxyv22ujd5r7savqihfrifa`,
posted **2026-10-21 15:08:24.498 UTC** in `#het-luafirst`, replying to Q-2d
message `yqjnh8cjcecnjsvhi4ckcmjdea`.

Lua may request modules, data and textures from enabled roots during a running
session, such as loading a room's content when entering it. The engine performs
background loading through bounded requests with explicit pending, success and
failure outcomes. Gameplay receives results at assigned logical ticks. A late
required result holds its tick, without skipped work or increased `dt`, while
rendering/presentation keeps its independent pace.

D-8's hooks-only ownership remains in force and `init` gains no blocking or
yielding wait. This choice requires concrete loader providers and their
cancellation/cleanup contract over the existing request machinery. It does
not select a result/await API, content-version policy, cache/eviction policy
or failure escalation. Hot reload and enabling mods mid-session remain
separate questions.

Rejected: startup-only loading, which requires every future room's content to
be preloaded or a new session to load it. Runtime loading supports ordinary
Lua-authored game progression without that restriction. Loading, boot and
service integration slices are affected; their boundaries remain undefined.

### D-10. Fingerprint content and fail changed loads for now

Owner answer, **2026-10-21 15:13:05 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> fingerprint and fail is fine for now, but hotswapping scripts is something i wanted to look into

Authenticated relay: `het-manager`, message `9szibrd3bzej6rvwmq73nnrx8s`,
posted **2026-10-21 15:13:05.866 UTC** in `#het-luafirst`, replying to Q-2e
message `xr83f6qwknt8vtqmjjre5gnqus`. The options presented were startup
fingerprinting with changed-load failure, versus an immutable content snapshot;
deliberate development hot reload was explicitly left undecided.

For now, pin content paths/fingerprints at startup and verify the bytes used
on each later load. A changed or missing file produces an attributed
content-changed failure instead of silently entering the running session;
new paths cannot silently extend its pinned inventory. Already loaded content
remains original. Restarting establishes the content version for the next run.
This does not undo D-9: loading, decoding and upload remain demand-driven.

The initial contract avoids retaining a private copy of every content byte,
at the cost of inventory/fingerprint work and a failed load if source content
changes. The concrete inventory preparation and bounded storage mechanism,
and how loading failures affect the session, still need specification.
The immutable-snapshot alternative is not selected for this initial contract.

The second part of the owner's answer is **an interest to investigate, not an
approved hot-swapping feature or a permanent exclusion**. Q-10 preserves it
separately. D-7's once-per-VM imports and this version check remain the current
contract until an explicit replacement/reload protocol is designed and approved.

### D-11. Refuse symbolic links inside content roots

Owner answer, **2026-10-21 15:18:24 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: no symlinks (Rec.)

Authenticated relay: `het-manager`, message `rafks3fkpi5q783c4u6yqnqzsw`,
posted **2026-10-21 15:18:24.407 UTC** in `#het-luafirst`, replying to Q-2f
message `2ciabpjhnrqnkvxsdynpi9c72n`.

Content roots contain ordinary files and directories only. The startup scan
rejects symbolic links with the offending root/path, and a later link is never
followed. Shared content is copied or referenced through its own enabled root
under D-6. This keeps the initial resolver and module identities straightforward
at the cost of symlink convenience.

Rejected: permitting links whose targets remain inside the same content root.
Launcher resolution of the owner's selected root directory is separate and
remains open, as do the concrete logical path and root-registration rules.
The decision affects content inventory and resolution; no slice is defined yet.

### D-12. Required loads by default, with explicit optional data/textures

Owner answer, **2026-10-21 15:21:13 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: optional loads (Rec.)

Authenticated relay: `het-manager`, message `s7igcu9a4rejrnmjhb23296iua`,
posted **2026-10-21 15:21:13.318 UTC** in `#het-luafirst`, replying to Q-2g
message `eier38txdpppyzm8kqazfu9ehw`.

Loads are required by default. An accepted required load that fails fails the
operation that requested it. Lua can explicitly request optional data files
or textures and receive a structured failure naming the content root, path
and reason, then choose a fallback such as an already loaded default portrait.
Modules remain required. Changed content is still refused under D-10;
optionality does not permit changed bytes to enter the session.

Engine/provider-code and cleanup failures retain their existing fatal
authority, and no automatic placeholder or retry is introduced. Gameplay
results, including optional failures, remain tick-assigned under D-9.
Exact session/UI escalation, result syntax, admission-full and cancellation
behavior remain separate questions.

Rejected: requiring all data and textures with no optional-load API. Explicit
optionality lets Lua distinguish essential content from content for which it
can choose a fallback. Loading, Lua results and failure integration are
affected; delivery slices remain undefined.

### D-13. Launch a game folder with a declarative identity/entry manifest

Owner answer, **2026-10-21 15:23:57 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: folder + manifest (Rec.)

Authenticated relay: `het-manager`, message `brhjnmqp2fdr7kdtym3t6ferv2`,
posted **2026-10-21 15:23:57.221 UTC** in `#het-luafirst`, replying to Q-3a
message `fwbt73n3ivxkimhsrigkvupv2w`.

Launch takes a content folder. A small non-executable manifest inside names
its stable content identity and relative Lua entry path; the engine validates
them before running game Lua. Mods will use the same kind of manifest, with
their discovery, enablement and additional metadata still to be designed.
Game rules and orchestration remain Lua-authored, without game-specific Haskell.

`hetoimasia run ./mygame`, content ID `example_game` and entry `lua/main.lua`
were illustrations, not approved command spelling or a fixed entry convention.
Manifest filename, format/schema and versioning remain open. This decision
does not settle lifecycle hooks, domains, windows or the existing headless
command's compatibility.

Rejected: requiring the content folder and entry script separately on the
command line with no manifest. A self-describing folder keeps entry knowledge
with the content and gives game/mod roots explicit identities. Boot, root
registration and mod metadata are affected; slices remain undefined.

### D-14. Configure supported VM roles in the manifest, with both as the default

Owner answer, **2026-10-21 15:31:39 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> Approve as proposed

Authenticated relay: `het-manager`, message `cb344sy9r3dg5xk9rvjmiek24n`,
posted **2026-10-21 15:31:39.888 UTC** in `#het-luafirst`, replying to Q-7a
revision 2 message `w594czmy428p67k9z3rrew9dhs`.

The owner approves all four parts of P-10 revision 2, retained below as the
accepted contract: an optional manifest VM set; validated role/clock pairs;
the default pair independently loading the common entry and selecting their
role exports, with optional separate entry paths and no bootstrap VM; and
gameplay-only/presentation-only variants with absent-domain calls refused.
There is at most one gameplay and one presentation VM, at least one overall.
Gameplay uses logical time; presentation uses elapsed time. Custom/additional
or dynamically created VMs remain a later design, without restricting the
general VM-owner library.

The owner was shown the validation, entry-routing and three-arrangement test
cost, and chose this over "Approve, both VMs only". The one-role variants are
therefore included, not merely examples. A gameplay-only session has no
presentation owner to keep a UI responsive; presentation-only has no
authoritative gameplay. Hook schema, tick settings, startup order and mod
mapping remain open. No delivery readiness is implied.

### D-15. Use optional init/update/shutdown on each root behavior

Owner answer, **2026-10-21 15:36:57 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: init/update/shutdown (Rec.)

Authenticated relay: `het-manager`, message `6uwmasf229sxuc2q6sm96nnqjw`,
posted **2026-10-21 15:36:57.477 UTC** in `#het-luafirst`, replying to Q-3b
message `hptheckqiw3ufxvbd6f67j9sue`.

P-11 option A is accepted: the selected role export is a behavior table with
optional `init(self, api)`, `update(self, dt)` and `shutdown(self, reason)`.
The engine owns the root instance, its connections and leases. A missing
selected behavior or a non-function hook fails startup; an absent optional
hook does nothing. Without `update`, the behavior can respond through events.
Root behaviors do not select the separate one-shot `run` mode.

`init` and `shutdown` are finite and cannot suspend or wait. Initialization
may request content and return; updates/events may suspend and handle pending
work. Gameplay `dt` uses logical time and presentation `dt` elapsed time.
Engine cleanup remains authoritative even without successful Lua shutdown
(prior Lua design D-27). No extra yielding setup hook is introduced.

The manager illustrated a texture request in `init`, readiness checked in
`update`, and `shutdown(self, reason)`. The illustrative content/readiness API
names, including `api.content.texture`, were not approved by this choice.
Tick duration, cadence, startup/readiness order, state initialization and
failure escalation remain open. This document's D-15 is distinct from the
prior Lua design's D-15 (general VM ownership).

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

Accepted by D-9; retain this proposal ID as history. The current host already
distinguishes arrival-based presentation requests from
tick-assigned requests that hold a grant until the result is available
(`packages/scripting-lua/README.md`, asynchronous requests); those mechanisms
do not yet implement these content services.

### P-6. Pin content versions and refuse changed bytes on a later load

Accepted for now by D-10; retain this proposal ID as history. An author editing
an unvisited room's script must restart before that changed file can load.
Q-10 separately preserves the owner's interest in deliberate script hot-swapping.

### P-7. Refuse symbolic links inside content roots

Accepted by D-11; retain this proposal ID as history. Root registration and
logical path normalization remain to be specified.

### P-8. Make content required by default, with explicit optional data/textures

Accepted by D-12; retain this proposal ID as history. The existing request
layer already distinguishes expected provider failure replies from raised
host/cleanup failures (`packages/scripting-lua/README.md`, "The guard, and
what a failure is"); the content result API remains new work.

### P-9. Boot a self-describing game folder

Accepted by D-13; retain this proposal ID as history. The current headless
command takes explicit `--script` paths and does not supply this game-folder
boot contract. Its compatibility remains a separate choice.

### P-10. Declare the VM arrangement in the manifest, defaulting to the pair

**Revision 2 accepted by D-14.** Retain this P-ID and the exact four-part
contract as design history. The initial request to put the default in the
manifest is preserved under Q-7a; D-14 records the subsequent explicit signoff.

Accepted contract:

1. An optional declarative `vms` section lists the supported roles to create:
   `gameplay`, `presentation`, or both. Each declaration names its role,
   relative entry-module path and clock. In this initial contract there is
   at most one of each role, at least one overall, and no additional roles.
2. Gameplay requires a logical clock; presentation requires an elapsed clock.
   Incompatible clocks, duplicate/unknown roles and an explicitly empty set
   are configuration errors, reported before game Lua runs. Exact tick/cadence
   settings and their defaults still need the scheduling/lifecycle contract.
3. When `vms` is absent, create both roles. Each independently loads D-13's
   top-level manifest `entry` and selects the corresponding `gameplay` or
   `presentation` behavior exported by that module. There is no third
   bootstrap VM. A declared VM may override its entry path; it still selects
   that role's behavior from the chosen module. The behavior/hook schema and
   manifest file format remain to be signed off separately.
4. A gameplay-only set is headless gameplay; it has no presentation owner to
   keep a UI available. A presentation-only set has no authoritative gameplay
   session. With both roles present, presentation observes completed snapshots
   and sends bounded intentions while gameplay owns logical progression and
   accesses the generic engine-held state. No synchronous cross-VM entry or
   shared Lua table is introduced. Behavior requiring an absent domain must
   be refused explicitly; exact service errors belong to the binding contract.

Illustrative declarations, not a selected manifest syntax:

| Role | Clock | Entry | Selected export |
| --- | --- | --- | --- |
| gameplay | logical | `lua/game.lua` | `gameplay` |
| presentation | elapsed | `lua/ui.lua` | `presentation` |

With no VM section, both entry cells instead use the manifest's common entry,
for example `lua/main.lua`, whose export table supplies both named behaviors.
Top-level source runs independently in each VM under D-7/D-8; its globals,
exports and module cache are not shared. Separate entry paths avoid loading
the other role's module dependencies where that matters.

The advantage is that the folder declares how it runs without Lua having to
construct owners before its ordinary lifecycle starts. The two-VM default
preserves the proven logical/presentation separation. The cost is manifest
parsing and validation, role-specific entry selection, and qualification of
the pair and both one-role variants, including absent-domain service failures.
An omitted presentation owner supplies no responsive-UI guarantee; normal
process diagnostics still have to report failures. Nothing here makes trusted
Lua preemptible or gives a hard latency or memory guarantee.

This limits only the initial launcher schema: the general VM-owner library
and Lua D-15 remain unchanged. Additional declared or Lua-created owners,
per-mod owner allocation, arbitrary clock/role combinations and dynamically
changing the VM set need a separate approved extension. They are not delivered
merely by allowing this manifest section.

Earlier alternatives were a launcher-supplied pair with no manifest choice,
or a bootstrap VM whose Lua explicitly creates its owners. They remain
historical alternatives, not owner-rejected requirements. The revised contract
affects boot/manifest validation, entry hooks, domain services, state publication
and verification. Startup order, mod mapping and failure escalation remain
open; no delivery slices are approved.

### P-11. Use the existing finite init, paced update and finite shutdown hooks

**Option A accepted by D-15.** Each selected
`gameplay` or `presentation` export is a behavior table with optional
`init(self, api)`, `update(self, dt)` and `shutdown(self, reason)` functions.
An absent selected behavior table, or a present hook that is not a function,
is a startup error. A missing optional hook is a no-op. The root behavior is
an engine-owned instance with its own `self`, connections and leases.

`init` runs once and cannot yield or wait. It may initiate engine-owned loads
and connect callbacks, then return. Loading work and its interest stay owned
by the instance after `init` returns. `update` and event callbacks may suspend
through the existing task/request machinery. Gameplay updates use logical
time; presentation updates use elapsed time. Their cadence defaults and
startup ordering remain separate decisions. `shutdown` is optional, finite
and non-suspending; cleanup still occurs if it is absent or fails (D-27).

For example, `init` requests the player's texture and returns with its pending
request recorded in `self`. An update or callback uses the texture once ready.
The author does not write a blocking texture wait inside `init`. Required
gameplay results retain D-9's tick-assigned delivery; returning from `init`
does not bypass that boundary or establish that all content is already ready.
An update-free behavior may work through connected events; the exact event
and readiness APIs remain part of the service/boot contract.

Alternative B adds a new yielding startup hook between finite `init` and normal
updates. Authors could await startup content sequentially there before entering
the regular update lifecycle. It offers more linear startup scripts, but needs
a new startup phase, completion/readiness semantics, logical-result delivery
during that phase and partial-start cancellation/cleanup rules. It would not
make the existing `init` yielding.

A is recommended because it reuses the delivered instance lifecycle and
request ownership, at the cost of expressing asynchronous setup through pending
requests and later updates/callbacks. Root behaviors do not also select a
one-shot `run` mode in this proposal; the existing general one-shot instance
primitive remains available for a separately designed Lua instance API.
This affects the entry adapter, boot readiness and content-binding examples.
State initialization/commit, failure escalation and the exact async Lua API
remain open. The hook contract above is accepted; the alternative yielding
startup hook is not selected.

### P-12. Fix the gameplay tick duration in the session manifest

**Unapproved; active checkpoint Q-3c.** Recommend A: whenever the gameplay
role exists, the game manifest must declare a positive, exactly representable
tick duration. Validate it before executing Lua and keep it fixed for the
session. There is no implicit production simulation rate. A game might choose
10 ms (100 logical ticks per simulated second); that is an example, not an
approved default. Manifest units/spelling remain part of its format design.
Presentation-only games need no gameplay tick setting.

Real time paces gameplay, but every granted gameplay tick has that same logical
duration. Slow execution or late required content delays progress; it does not
drop simulation ticks or enlarge their duration to catch up. Rendering and
presentation remain independent. This chooses the simulation clock's unit,
not a requirement to finish each tick within a real-time deadline. Pacing and
overload mechanics must preserve those properties.

An instance's `update` cadence is distinct from this tick duration. Existing
scheduler behavior skips an instance's cadence point when its invocation is
already active, including a deliberate logical wait; later `dt` accounts for
the logical time since its previous update finished. Thus this proposal does
not promise every callback receives exactly one tick of `dt`, does not change
the delivered instance scheduler, and does not settle which waits are legal
inside a state transaction. Root cadence, Lua-created routine intervals and
presentation update timing remain subsequent choices.

Alternative B lets Lua establish and change the simulation tick duration while
the session runs. That supports games which alter the simulation step itself,
but needs an ordered change boundary and rules for existing duration-based
intervals, waits, tick-assigned content/input and replay. A is recommended to
keep the engine-held per-tick state contract on one stable time unit. Its cost
is one required game setting and a restart to change that unit; ordinary
game-specific speeds and time-scale values can still be Lua data, without
changing the engine clock.

Evidence: `packages/scripting-lua/README.md` (Cadence) already takes an
application-configured positive tick duration with exact interval conversion,
and separates logical grants from elapsed-time pacing. The 10 ms setting in
`samples/lua-domains` is a sample choice, not a library default. The launcher
would add validation and configuration wiring; this proposal does not add a
new scheduler mode.

## Open questions

### Q-1. Which filtered standard-library profile applies to every script?

Resolved by D-5: profile A, with no exceptions. File resolution and the old
epic's disposition are not settled by this answer.

### Q-2. How does content loading replace filesystem and package access?

Settle modules, data and textures scoped to game/mod content roots, module
identity/cache/cycles, cross-mod access, root/path and symlink handling,
failure attribution and when loading is allowed. D-6 settles explicit root
addressing, D-7 module reuse/cycle/failure behavior, D-8 the top-level
effect boundary, D-9 runtime loading, D-10 content-version checks for now and
D-11 the symlink rule and D-12 required/optional content failure handling.
Root/path grammar, inventory preparation, loader/result API, bounds/cache
policy and detailed failure escalation remain open. These will be revisited
with the boot, state and service contracts; Q-2 as a whole is not marked resolved.

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

Resolved by D-9: background loading during play, with explicit results and
tick-assigned gameplay delivery that waits for required late results. The
result/wait API, content versions, cache policy and escalation of loading
failures remain separate questions.

#### Q-2e. What happens if content files change during a session?

Resolved for now by D-10: fingerprint at startup and fail later changed loads;
restart to use edits. The concrete inventory mechanism and failure escalation
remain open. Script hot-swapping is separately recorded in Q-10, not approved.

#### Q-2f. Should content roots allow internal symbolic links?

Resolved by D-11: no symbolic links inside content roots. Launcher resolution
of the selected root, root registration and logical path grammar remain open.

#### Q-2g. Can Lua explicitly handle an optional data/texture load failure?

Resolved by D-12: loads required by default, with explicit optional data and
textures returning structured failures. Modules stay required; host/cleanup
failure authority and D-10's version checks remain intact.

### Q-3. What is the generic executable's boot and session contract?

Settle content root and entry selection, startup validation, init, logical
updates, presentation/UI updates and shutdown; boot/session failure reporting,
exit behavior and compatibility with the existing headless `lua` command.
Keep D-27 cleanup independent of successful Lua shutdown.

#### Q-3a. Does the game folder declare its entry point?

Resolved by D-13: content folder plus a non-executable identity/entry manifest,
with corresponding mod manifests later. Format and command spelling remain
open, as do launcher compatibility and lifecycle. Q-7a is asked next because
default domain composition affects entry/lifecycle design; D-14 now settles it.

#### Q-3b. Reuse existing hooks or add a yielding startup phase?

Resolved by D-15: P-11 option A, optional finite init/shutdown and updates/events
which may suspend. The manager's content/readiness API spellings remain
illustrations. State initialization, readiness, startup order and failure
escalation still need their own contracts.

#### Q-3c. Is the gameplay tick duration fixed for the session?

The only active checkpoint: P-12 option A (recommended, require an explicit
positive gameplay tick duration in the manifest and keep it fixed until
restart) or B (Lua can establish/change it during the session), or an
owner-specified revision. No numeric default is proposed. Instance cadence,
presentation timing and transaction suspension rules are separate questions.

### Q-4. How are mods discovered, ordered and combined?

Settle selection, dependency/load order, conflicts, replacement and override
scope, attribution of a mod's failure, and the point at which the content set
is fixed. Trust does not itself define these behaviors.

### Q-5. What generic engine state does Lua define and mutate?

Settle entities/components versus tables/schemas, validation, stable identity,
read visibility while staging, atomic tick commit, bounded capacity and
failure. Carry D-23 and D-47/D-48's exact guarantees into this store. Settle
whether saves and schema migration are excluded or included; Q-10 separately
records the owner's interest in script hot-swapping;
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

#### Q-7a. Does the launcher supply the UI/gameplay pair by default?

Owner response, **2026-10-21 15:27:06 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> two vms default is fine, but can this be in the manifest?

Verified relay `gbyui2gk6dj4693izanm543f3s` from `het-manager`, posted
**2026-10-21 15:27:07.008 UTC**, replies to question
`vjgmesg3jfm9v8fnvsdd5jmwba`. The owner accepts the default pair in principle;
the manifest-controlled revision needed its own signoff. That initial answer
was retained without recording a new decision until the explicit revision-2
approval at **2026-10-21 15:31:39 UTC**, relay `cb344sy9r3dg5xk9rvjmiek24n`.

Resolved by D-14: all four parts of P-10 revision 2, including one-role variants.
Additional owners, mod mapping, startup order and lifecycle details remain open.

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

### Q-10. Investigate deliberate script hot-swapping

Owner interest expressed in the **2026-10-21 15:13:05 UTC** answer quoted in
D-10, verified relay `9szibrd3bzej6rvwmq73nnrx8s`: the owner wants to look
into hot-swapping scripts. This is an open design interest, not approval of
implementation, silent reload, automatic file watching or a chosen delivery arc.
Do not erase it by interpreting "for now" as a permanent restart-only policy.

A later focused discussion must settle development-only versus ordinary
runtime use, explicit activation, the safe point for replacement, old closures
and shared exports, instance-state migration, lease/resource ownership,
failure recovery and the deterministic/replay implications. That discussion
must explicitly reconcile D-7/D-10 where it changes them. Its scope and timing
remain an owner decision before the final delivery plan; no slice is created
merely from this interest.

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
