# Lua-first engine design

Make Lua the authoring and orchestration surface over generic engine services.
**Approved scope (D-43): milestone 1 is a Lua-driven textured
quad in a rendered window, with a real logical runtime running stub content;
mod-aware foundations without mod activation; no ECS/gameplay store.**
This document carries request `user-het-luafirst-20261021-1435`.

Design state: `exploring`

Owner repository: `coghex/hetoimasia`; publication branch: `master`.
Started 2026-10-21 by `het-designer-1`. Questions and owner-answer relays belong
in `#het-luafirst`. Only owner signoff turns a proposal into a decision.
The current checkpoint is P-42/Q-6b: Lua-requested asynchronous window creation.
D-44 resolves Q-6a revision 2 with UI-only graphics; the original broader
Q-6a was not answered. D-43 accepts P-40's scope and delivery tags; D-42
supplies the runtime contract within that M1 boundary.
This document is not authority to implement or file issues.

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Draw a textured quad from Lua over reusable engine services

No delivery slices are defined yet. Their boundaries and order depend on the
owner's answers below. The umbrella's relationship to existing epic #145 also
needs explicit reconciliation; this entry does not request a duplicate epic.

## Epic contract

- **Goal:** a game folder/manifest starts filtered Lua, a real logical runtime
  with stub content, and UI Lua drawing a textured quad in a rendered window.
  Root identity, per-instance ownership, timing, loading and failure behavior
  are reusable foundations; mod activation and gameplay state are later work.
- **Done when:** P-40's acceptance is met: actual textured output with offscreen
  and native-window evidence, real async/lifecycle/error behavior, orderly quit,
  and the two-instance integration test through the new bindings/composition.
  Exact APIs, commands and one-PR slice boundaries remain open. A state call
  reports unavailability and ends the session through protected cleanup.
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
  [Asset decoding](../archive/designs/asset_design.md) consumes bytes; file loading is the caller's
  responsibility. Mod-supplied content was deferred by that older design.
  [The image2d sample](../../samples/README.md) already composes decoded PNG
  and KTX2 images, texture registration and per-window 2D scenes in Haskell.
- [GPU services](../archive/designs/gpu_resource_services_design.md),
  [window/graphics lifetime](../archive/window_graphics_lifetime_design.md) and
  [GLFW integration](../archive/glfw_integration_design.md) retain native ownership:
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

D-41 is the controlling owner scope decision: this milestone has no gameplay
state store and does not design gameplay concepts. D-3 and D-30 through D-40
are preserved for a later arc, with no milestone implementation or verification
obligation. Init/update/shutdown remain; calling a state service prints that it
is unavailable in this milestone and exits. Q-5l/P-37 is withdrawn, not answered.

D-43 further narrows delivery to the textured-quad M1 defined in P-40. Real
boot, filtering, content loading, instance ownership, clocks, failure handling
and window/texture/2D scene integration remain. Mod activation and compatibility,
general input, widgets/fonts, advanced presentation and hot-swap are later work
whose designs do not block M1. Exact M1 bindings, vision/epic reconciliation and
delivery order remain to be settled. D-42's runtime reconciliation applies
within D-43's delivery allocation; earlier broader scope is historical.

This design session changes only this document. Production code, tracker
mutations, changes to the vision or prior design, review and issue processing
are outside this session's authorized work. No subagents are used.

## Decisions

**Scope precedence:** D-41 controls this milestone. Earlier decisions retain
their historical wording/quotes; working-store clauses are not current scope.
D-3 and D-30–D-40 are explicitly deferred. P-38 lists affected clauses in all
other decisions; D-42 accepts its replacement milestone interpretations.
Each D-entry also has a **delivery tag** accepted through D-43/P-40. These tags
do not erase the original decision or decide a later epic's
delivery order. `M1` means the textured-quad milestone; `L-MODS`, `L-STATE`,
`L-RELOAD` and `L-PRESENTATION` identify later work, not numbered commitments.

The quotations below arrived in the owner-supplied manager briefing, not as
answers typed in this designer's pane. The authenticated manager's relay
`nghi5qr7bx34xmdh38fbq72dse` at **2026-10-21 14:41:43.272 UTC** confirms
the direction, trust and state choices. The original answer times, except
the approximate direction time, were not supplied; none are invented here.

### D-1. Lua orchestrates the game without game-specific engine startup

**Delivery (D-43/P-40):** M1 / later arcs.

Owner, **2026-10-21 approximately 14:35 UTC**, in the manager's pane:

> mods are what i want, the engine code should simply start running lua, without any concern for what the game is, then the lua handles everything, orchestrates the game, sets the routines, the data, loads the textures. we need to build as much of the interface in lua as we can

The verified manager status `j6j4qt8pn5mub3txv8miw8df5n` at
**2026-10-21 14:35:49.713 UTC** also records this direction. Concrete API
coverage and the boot protocol remain choices to settle, not implied details.

### D-2. Game and mod scripts are trusted, with OS functionality removed

**Delivery (D-43/P-40):** M1.

Owner, **2026-10-21, exact answer time not supplied**, in the manager's pane;
relayed through the briefing and the 14:41:43.272 UTC message above:

> mods = game, trusted, but we need to filter out the dangerous commands from the library. mods and game lua should not be able to use os functionality

The filtering profile is settled by D-5 (Q-1). The resulting disposition of the previous
confined branch is separately reserved for explicit reconciliation, Q-8.

### D-3. Engine holds, Lua defines

**Delivery (D-43/P-40):** L-STATE.

**Deferred to a later arc by D-41; not a requirement of this milestone.**
The original owner direction is preserved below, not deleted or implemented here.

Owner, **2026-10-21, exact answer time not supplied**, in the manager's pane;
same relay provenance:

> Engine holds, Lua defines

The option offered to the owner was: Lua defines data and rules; the engine
stores state generically and commits Lua's changes per tick, keeping prior Lua D-23 and
V-4 guarantees. The generic representation and transaction API are Q-5.

### D-4. Hold a fresh design session

**Delivery (D-43/P-40):** M1 process.

Owner, **2026-10-21, exact answer time not supplied**, in the manager's pane;
source is the supplied briefing, corroborated by the manager's start relay:

> Fresh design session

The endpoint is owner signoff on this design and dependency-ordered slices.
Review and issue processing come later on the manager's instruction.

### D-5. Use profile A, with no exceptions to the listed removals

**Delivery (D-43/P-40):** M1.

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

**Delivery (D-43/P-40):** M1 root-identity foundation / L-MODS activation.

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

**Delivery (D-43/P-40):** M1.

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

**Delivery (D-43/P-40):** M1.

Owner answer, **2026-10-21 15:04:11 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: hooks only (Rec.)

Authenticated relay: `het-manager`, message `zi64juxixem8cjdz48zffjh79a`,
posted **2026-10-21 15:04:11.762 UTC** in `#het-luafirst`, replying to Q-2c
message `wwe79m6c9vwsifzesj3rmpdcie`.

Before answering, the owner requested a fuller explanation. The manager
contrasted loading a player's texture at `player.lua` top level with doing
so in `init`, explained prior Lua D-27 cleanup ownership, the lack of an owning
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

**Delivery (D-43/P-40):** M1.

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

**Delivery (D-43/P-40):** M1 fingerprint policy / L-RELOAD.

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

**Delivery (D-43/P-40):** M1.

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

**Delivery (D-43/P-40):** M1.

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

**Delivery (D-43/P-40):** M1 game manifest / L-MODS manifests.

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

**Delivery (D-43/P-40):** M1.

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
authoritative gameplay. D-15 through D-17 subsequently settle hook schema,
tick settings and root cadence; startup order and mod mapping remain open.
No delivery readiness is implied.

### D-15. Use optional init/update/shutdown on each root behavior

**Delivery (D-43/P-40):** M1.

**Revised by D-41:** the hooks stay, but no hook gains a working state service
in this milestone. Any state-service call prints an unavailable message and
exits. D-42 accepts P-38's exit integration; the original lifecycle
decision below is preserved, with its state-initialization agenda withdrawn.

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
Tick duration and cadence are subsequently settled by D-16/D-17;
startup/readiness order, state initialization and failure escalation remain
open. This document's D-15 is distinct from the
prior Lua design's D-15 (general VM ownership).

### D-16. Fix an explicitly declared gameplay tick duration for each session

**Delivery (D-43/P-40):** M1.

Owner answer, **2026-10-21 15:41:26 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: fixed in manifest (Rec.)

Authenticated relay: `het-manager`, message `9i4th4sg63dq3zh3dkzzwpd88e`,
posted **2026-10-21 15:41:26.402 UTC** in `#het-luafirst`, replying to Q-3c
message `2u78yvc4amktmvgstv32vigp5a`.

P-12 option A is accepted: a game with a gameplay VM must declare an exact,
positive tick duration in its manifest. Validate it before Lua and keep it
fixed until restart. There is no implicit rate; 10 ms was an example only.
Presentation-only games need no gameplay tick setting. Slow execution or late
required loads delays progress without dropping ticks or stretching their
duration. Rendering remains independent.

The manager's 2x fast-forward example illustrated game-defined speed as Lua
data; it did not approve an engine fast-forward or clock-rate API. D-17 later
settles root cadence and presentation timing; pacing mechanics and
state-transaction suspension rules remain separate. An update's accumulated logical `dt` need not be one
tick, as P-12 explains.

### D-17. Keep root update cadence in Lua beside the behavior

**Delivery (D-43/P-40):** M1.

Owner answer, **2026-10-21 15:46:36 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: in Lua, beside code (Rec.)

Authenticated relay: `het-manager`, message `2nq5bq9c5gahasckv8mtwxzjwe`,
posted **2026-10-21 15:46:36.851 UTC** in `#het-luafirst`, replying to Q-3d
message `fc4ydfdi9uy76sfd6yk6qkjrgn`.

P-13 option A is accepted: root behavior metadata in Lua supplies the update
cadence. Gameplay uses a positive integer tick interval, defaulting to every
tick. Presentation requires an explicit positive elapsed interval when it has
an update; there is no default. Its timer is independent of rendering, merges
late refresh demand and supplies actual elapsed `dt`. There is no frame-rate
guarantee or render-frame callback.

Without update the behavior is event-driven; cadence without update is an
error. Validate before init and fix the cadence for the instance's life,
using the existing scheduler rules. Changing the exported metadata afterward
does not reschedule the instance. The illustrative `every = 2` field shown by
the manager did not settle field names or grammar. Additional routines,
rescheduling and state-transaction waits remain separate choices.

### D-18. Initialize concurrently, with independently starting presentation

**Delivery (D-43/P-40):** M1.

Owner answer, **2026-10-21 15:59:37 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> Approve as proposed

Authenticated relay: `het-manager`, message `mtzmhhh2j6kibwqscp53uiyqe2`,
posted **2026-10-21 15:59:37.792 UTC** in `#het-luafirst`, replying to Q-3e
revision 2 message `j4p8yi8ftca2q2mpw3her2garn`.

All five parts of P-14 revision 2 below are accepted: concurrent root init
after validation, independently starting UI, gameplay gated on both roots,
failure/cancellation with late-success races closed, and per-role startup
ownership with continued main-thread servicing. A one-role session waits only
for its own init. No gameplay time accrues during startup. Pending loads can
continue after init; game-specific readiness remains Lua-owned.

The manager summarized all five parts and the advice to keep init short.
The owner chose "Approve as proposed", not "Approve + progress": the early
loading screen gets starting/root-readiness status, with no detailed progress
channel from gameplay init. The original concurrent-start request remains
quoted under Q-3e. D-19 subsequently settles post-start root failure policy;
exact diagnostics remain open.

### D-19. Keep healthy UI available after a gameplay root failure

**Delivery (D-43/P-40):** M1.

Owner answer, **2026-10-21 16:03:29 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: UI shows the error (Rec.)

Authenticated relay: `het-manager`, message `en3y2uv2mgduvh3d6ug7bnhzi6`,
posted **2026-10-21 16:03:30.012 UTC** in `#het-luafirst`, replying to Q-3f
message `aiittxgyf34n5bkskpgrb2g7re`.

P-15 option A is accepted. After startup, gameplay root failure stops simulation,
refuses new gameplay commands, discards uncommitted work and preserves the last
committed state. Healthy presentation continues with a bounded failure view
and frozen world until exit; Lua authors handle that status to show an error.
Without such handling the screen may remain unchanged until quit. There is
no automatic timeout, restart or retry, and the eventual exit reports failure.
A presentation root failure ends the session, as does failure in a one-role
session. D-18 still governs startup; host/provider/cleanup failures remain
fatal and engine-owned retirement remains mandatory.

The manager described the healthy-UI behavior as matching V-9's rule that an
unsafe authoritative-state failure stops gameplay while UI can report it.
That rule is present in the current vision; this answer does not approve the
separate trust/confinement reconciliation still required by Q-8. Exact error
schema and additional instance/mod failure policy remain open; D-20 later
settles exit codes and console reporting conventions.

### D-20. Use console outcomes and a forced exit on the second stop signal

**Delivery (D-43/P-40):** M1.

Owner answer, **2026-10-21 16:08:09 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: 2nd Ctrl-C forces (Rec.)

Authenticated relay: `het-manager`, message `5xxpq68cbqvph5tms5acikrawa`,
posted **2026-10-21 16:08:09.331 UTC** in `#het-luafirst`, replying to Q-3g
message `adxdaqvf8x56tfaw4vvwktyvja`.

P-16 option A and its shared outcome/reporting contract are accepted: 0 for
clean normal quit, 1 for a failed boot/session or host/cleanup failure, 2 for
bad command-line arguments, and 130 for an orderly signal interruption without
failure. Orderly outcome precedence is failure over interruption over success.
Lua quit tears down the entire session idempotently. Diagnostics use stderr;
authored print uses stdout. Window-close policy remains a later service choice.

The first SIGINT or SIGTERM requests orderly stop. A second signal while
stopping force-exits 130, skipping remaining hooks, cleanup and flushing,
including when a failure had already been recorded. This forced path is the
explicit exception to orderly precedence and cleanup guarantees. Lua receives
no force-exit capability. The manager's Ctrl-C label does not narrow the
approved behavior to SIGINT; the question expressly covered SIGINT/SIGTERM.

### D-21. Select mods explicitly at launch and fix that set for the session

**Delivery (D-43/P-40):** L-MODS.

Owner answer, **2026-10-21 16:10:37 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: explicit list (Rec.)

Authenticated relay: `het-manager`, message `yyckma8k6xffdrczwsy34irc8i`,
posted **2026-10-21 16:10:37.653 UTC** in `#het-luafirst`, replying to Q-4a
message `grnqksdhfi6hcx9rcmiupamauw`.

P-17 option A is accepted: select a game folder and an explicit list of mod
folders; no list means base game only. Nothing is discovered or enabled
automatically. Validate identities before Lua; duplicate roots/IDs, collision
with the game ID, or an unselected required dependency fail boot. The enabled
set is fixed until a new session, while D-9 permits runtime loading inside
those roots. Listing order does not itself decide execution or overrides.

The example `--mod` spelling remains illustrative. Saved profiles and a
mod-selector screen were described as later design possibilities, not an
approved feature or delivery commitment. D-22 subsequently settles dependency
ordering; compatibility, mod activation and override policy remain open.

### D-22. Use required dependencies and deterministic mod activation order

**Delivery (D-43/P-40):** L-MODS.

Owner answer, **2026-10-21 16:28:18 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: requires only (Rec.)

Authenticated relay: `het-manager`, message `m6na7hiduq4ifvx3f8bxaremn2`,
posted **2026-10-21 16:28:18.258 UTC** in `#het-luafirst`, replying to Q-4b
message `c3dyjijbv6xz5he7ynupqvycs2`.

P-18 option A is accepted: manifests declare required mod IDs, all already
selected at launch. Missing/self dependencies or cycles fail before Lua.
Dependencies activate before dependents; exact mod-ID order breaks ties among
eligible mods, never launch-list order, folder enumeration or locale. Startup
diagnostics show the resolved order. There are no optional before/after hints
in this contract; ordering without a requirement is a later extension.

This fixes mod activation order, not cross-VM completion order, module import
evaluation, asset readiness or override precedence. Version compatibility and
activation's relationship to root init remain open. P-18 retains those
boundaries and its evidence.

### D-23. Share role VMs while giving mods separate owned instances

**Delivery (D-43/P-40):** M1 instance foundation / L-MODS activation.

Owner answer, **2026-10-21 16:35:49 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: share the game's VMs (Rec.)

Authenticated relay: `het-manager`, message `pm5v3h9aiirs7ng6ce5dvavxvn`,
posted **2026-10-21 16:35:50.091 UTC** in `#het-luafirst`, replying to Q-7b
message `ak4dt6ajtuevjnzgnu6gpea4we`.

P-19 option A is accepted: gameplay mods share the game's gameplay VM and UI
mods share its presentation VM. Each mod has its own primary engine-owned
instance per contributed role, with the same hooks/cadence contract, separate
`self`, connections and resource leases, and mod/source attribution. Engine
calls enter the owning instance context. Imports and mutable module exports
remain shared within each VM under D-7; a non-yielding mod can block its whole
role VM. Separate instances do not promise shared-state rollback.

D-14's role-VM limit remains unchanged. D-24 later settles role declarations
and absent-role handling; activation relative to game init, cross-role
dependency readiness and failure escalation remain open. This document's D-23 concerns mod ownership; prior
Lua design D-23 remains the separate determinism contract.

### D-24. Require every explicitly declared mod role

**Delivery (D-43/P-40):** L-MODS.

Owner answer, **2026-10-21 16:38:07 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: roles are required (Rec.)

Authenticated relay: `het-manager`, message `mdwfz4rj45qkwt6yeieezvx6fs`,
posted **2026-10-21 16:38:07.503 UTC** in `#het-luafirst`, replying to Q-4c
message `69nteh5dwzydaj3fm9s86v7qd6`.

P-20 option A and the shared contribution contract are accepted. Each mod
explicitly declares gameplay, presentation, both, or no role contributions;
each declared role names its entry. An absent required game role fails boot
before Lua, naming the mod and role. There is no optional-role flag. Authors
can split gameplay and UI contributions into separately selected mods for
gameplay-only use.

An empty contribution set is content/library-only: no automatic instance or
entry execution, while its content remains explicitly importable/loadable.
The normal identity, dependency and content checks still apply. Exact manifest
fields, activation order relative to roots and dependency readiness remain
open; this does not create another VM or alter the game's clocks.

### D-25. Initialize game roots before their ordered role-mod instances

**Delivery (D-43/P-40):** M1 root gates / L-MODS init chains.

Owner answer, **2026-10-21 17:04:22 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: roots first (Rec.)

Authenticated relay: `het-manager`, message `h5jxbapx9ubpbk7j3u2gzf62fa`,
posted **2026-10-21 17:04:22.535 UTC** in `#het-luafirst`, replying to Q-4d
message `d37sh9d9c3rfa5nrajxvfrrrvs`.

All five parts of P-21 option A are accepted: concurrent game-root init,
ordered mod init after the corresponding root, early UI-root execution and
gated UI-mod callbacks, the joint gameplay start gate, role-local dependency
readiness and fail-boot handling for mod-init failures. The detailed protocol
is retained in P-21. A dependency's other-role init need not have completed;
no initializer synchronously waits for another VM.

The manager presented the authoring cost explicitly: game init cannot use
effects of later mod inits. Mod-dependent work such as world generation runs
after startup, while imports can supply plain definitions earlier. Early UI
must tolerate incomplete mod activation. Runtime mod failure escalation and
teardown order remain open. The intervening documentation archive move changed
four evidence links; those current `docs/archive/` targets are preserved.

### D-26. Apply root failure policy to runtime mod-instance failures

**Delivery (D-43/P-40):** M1 instance failure mechanism / L-MODS admission.

Owner answer, **2026-10-21 17:07:18 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: same as the game (Rec.)

Authenticated relay: `het-manager`, message `s5mat8dd22dasy4be78dpy6a52`,
posted **2026-10-21 17:07:18.888 UTC** in `#het-luafirst`, replying to Q-4e
message `6sr92w7jk4h4ragchj4xjqqc9n`.

P-22 option A is accepted: an unhandled gameplay mod-instance failure stops
all gameplay, preserves the last committed state and lets healthy UI show
the mod-attributed failure until exit. A presentation mod-instance failure
ends the session. No recoverability flag, disable-and-continue or retry is
introduced. Attribution retains mod, role and available source/traceback;
instance ownership remains with the executing consumer of imported helpers.

The owner was shown that a small UI mod bug can end the session because
cleanup of an instance does not undo shared-VM mutations. Expected optional
content failures and caught Lua errors retain P-22's boundaries. Startup,
fatal host/cleanup behavior and prior Lua failure accounting remain unchanged.
Additional Lua-created instance/task ownership and teardown order remain open.

### D-27. Keep shutdown self-contained without a mod ordering guarantee

**Delivery (D-43/P-40):** M1.

Owner answer, **2026-10-21 17:11:17 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: self-contained (Rec.)

Authenticated relay: `het-manager`, message `683xirne97p9zymsded24s8v92`,
posted **2026-10-21 17:11:17.801 UTC** in `#het-luafirst`, replying to Q-4f
message `3mkpt2477apdbgk5m4fxfirf22`.

P-23 option A is accepted: each root/mod shutdown hook is self-contained,
with no promised relative order and no assumption that another mod is still
alive. Hooks are optional, finite, may fail and are skipped when Lua is unsafe.
Engine-owned cleanup remains authoritative independently of hook success;
resource/provider/GPU dependencies stay held until safe retirement. This does
not require scripts to discover and release everything themselves or promise
immediate release while a provider is still using it.

No reverse-activation shutdown phase is introduced. The existing orderly and
failure paths, D-19/D-26's surviving healthy UI and D-20's forced-exit exception
remain as recorded in P-23. This document's D-27 is the shutdown-order choice;
prior Lua design D-27 is the underlying engine-owned cleanup contract.

### D-28. Use game-exposed extension APIs without engine content remapping

**Delivery (D-43/P-40):** L-MODS.

Owner answer, **2026-10-21 17:14:08 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: game-exposed hooks (Rec.)

Authenticated relay: `het-manager`, message `a3m9a2gd7gs3hdfvmk7nggy4j2`,
posted **2026-10-21 17:14:08.143 UTC** in `#het-luafirst`, replying to Q-4g
message `f2fas8mkxfvuad48ubawza7eze`.

P-24 option A is accepted: the supported way for mods to extend/replace game
definitions is through extension points exposed by the game's Lua. The
player-appearance example supplies a mod texture reference while the original
game path continues naming its original file. Rule/UI changes use game APIs;
authoritative state changes use engine state services. There is no engine-wide
file/module remapping or load-order winner in this arc.

The owner was shown the cost: a game exposing no extension APIs cannot be
generically overridden through this supported mechanism. Trusted scripts can
still mutate shared tables, so this is not an enforced isolation boundary.
The answer does not select new callback signatures or make extension callbacks
identical to lifecycle hooks. Registration/conflict handling, callback ownership
and the separate hot-swap question remain open.

### D-29. Match declared game/mod API revisions exactly

**Delivery (D-43/P-40):** L-MODS.

Owner answer, **2026-10-21 17:18:05 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: exact revision (Rec.)

Authenticated relay: `het-manager`, message `92543pjipmjfvn52x63kpuf32e`,
posted **2026-10-21 17:18:05.622 UTC** in `#het-luafirst`, replying to Q-4h
message `8kk4zg37vzwzkesbxftse74mje`.

P-25 option A and its shared compatibility contract are accepted. Each
game/mod declares a positive whole-number API revision. A mod declares a
target game ID/revision or game-independence; required-mod dependencies name
ID plus exact expected revision. Mismatches fail before Lua with expected
and actual values, without automatic selection/download or accepted ranges.
The author must update and verify a changed expectation before it is accepted.

These are author assertions, not proof of semantic compatibility. API contract
changes, including new API dependents require, advance the revision;
implementation/content-only releases need not. Fingerprints, manifest-format
version, engine binding compatibility and saves remain separate as P-25 states.

### D-30. Use engine-owned entities with Lua-defined components

**Delivery (D-43/P-40):** L-STATE.

**Deferred to a later arc by D-41; preserved owner decision, outside this milestone.**

Owner answer, **2026-10-21 17:25:15 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: entities + components (Rec.)

Authenticated relay: `het-manager`, message `myhqi8zc7gtgqp5i8dkswm3tnw`,
posted **2026-10-21 17:25:15.745 UTC** in `#het-luafirst`, replying to Q-5a
message `6u957ufyvg2ea3pgxry36nr9mw`.

Before choosing, the owner asked, verbatim:

> this sounds like an important decision, can you explain why the recommended option sounds better to you

The manager then gave its own reasoning: mods can attach components without
coordinating changes to a common entity record; engine commit/digest and later
save/tool facilities benefit from a common vocabulary; the entity/version and
ID-ordered digest sample offers a starting point; and a component is a small
change unit. It also explained the costs: opinionated entity organization,
world entities and list/map values for global/document-shaped data, with static
definitions potentially outside the store. It identified document-heavy or
narrative games as a case for B. The manager re-asked after this explanation;
the owner then selected A. The explanation's separate time was not supplied.

P-26 option A is accepted: the engine owns entities with stable identities
and Lua-defined, schema-checked named component data. Lua defines rules;
gameplay changes are committed by the engine and UI consumes coherent views.
No game-specific component types, physical storage layout, parallel-system
scheduler or performance claim is selected. Independent component addition
does not waive schema registration/validation or conflict handling. The
manager's save/tool examples are rationale, not approved scope; exact digest,
identity/version rules and list/map support still need their own contracts.

### D-31. Use bounded nested component data with typed lists and maps

**Delivery (D-43/P-40):** L-STATE.

**Deferred to a later arc by D-41; preserved owner decision, outside this milestone.**

Owner answer, **2026-10-21 17:28:37 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: nested + lists/maps (Rec.)

Authenticated relay: `het-manager`, message `b7nb2v44mexhzmab8zcffch92s`,
posted **2026-10-21 17:28:37.095 UTC** in `#het-luafirst`, replying to Q-5b
message `3nv87fvwnd8napcrfa5r9ux6f2`.

P-27 option A, including its shared base types and exclusions, is accepted:
fixed-field nested records, homogeneous dense lists and typed text-keyed maps,
with absent optional fields, no list holes and non-recursive schemas. String/
container limits plus engine depth/byte/element ceilings bound validation and
storage. Values are copied data; no live Lua object identity, metatables,
cycles, code or native handles enter the state. Integer/float distinctions,
finite floats, UTF-8 checks and atomic rejection remain as stated in P-27.

The manager illustrated an inventory list of `{item, count}` records and a
quest-state map. These are examples, not prescribed game component schemas
or API spelling. Exact limits, reference lifetime, transaction rejection policy
and canonical/query ordering remain open.

### D-32. Register component schemas at gameplay init and freeze for the session

**Delivery (D-43/P-40):** L-STATE.

**Deferred to a later arc by D-41; preserved owner decision, outside this milestone.**

Owner answer, **2026-10-21 17:34:31 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: register at init (Rec.)

Authenticated relay: `het-manager`, message `6pekwzn45z2s2878vx8jahc3g2`,
posted **2026-10-21 17:34:31.873 UTC** in `#het-luafirst`, replying to Q-5c
message `5g3a3ucwjh9qwtdbiaj3uw846a`.

P-28 option A, including its shared rules, is accepted: the game's and mods'
gameplay init hooks register namespaced component types in D-25 order; freeze
the catalog before the first published state. Registration derives its namespace
from the owning instance; duplicate identities and invalid schemas fail boot
without partial registration. Later content uses known types; adding a type
requires a new session. Presentation cannot register authoritative schemas.
Value-write permissions, concrete limits and game-extension conflicts remain
separate decisions.

### D-33. Gameplay reads see earlier staged writes within the tick

**Delivery (D-43/P-40):** L-STATE.

**Deferred to a later arc by D-41; preserved owner decision, outside this milestone.**

Owner answer, **2026-10-21 18:18:50 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: see staged writes (Rec.)

Authenticated relay: `het-manager`, message `yh9kejzwpg4axcrmfue93q5pjs`,
posted **2026-10-21 18:18:50.123 UTC** in `#het-luafirst`, replying to Q-5d
message `gh4upyrtyy338iqzvqxaehtmma`.

P-29 option A is accepted: gameplay shares one engine-owned working state per
tick. Successful writes, creation and removal are visible to subsequent reads,
including other mods' reads. Read 10, write 9, read again returns 9. Reads are
copies, and mutation of a returned Lua table requires an explicit state write.
UI sees only committed snapshots; a failed tick publishes none of its changes.
This does not roll back plain Lua tables or resource effects. The owner was
told that what code observes depends on execution order; its deterministic
contract follows next. No physical storage layout is selected.

### D-34. Fix gameplay to FIFO scheduling with deterministic admission

**Delivery (D-43/P-40):** L-STATE.

**Deferred to a later arc by D-41; preserved owner decision, outside this milestone.**

Owner answer, **2026-10-21 18:24:44 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: fixed FIFO (Rec.)

Authenticated relay: `het-manager`, message `fxkg67gqhvg53eh3gyz64vdhdi`,
posted **2026-10-21 18:24:44.795 UTC** in `#het-luafirst`, replying to Q-5e
message `vw6zn3rfb9cnqzja49qzr7qgge`.

P-30 option A is accepted: fixed FIFO gameplay policy, equal ordinary priority
for game/mod updates and events, stable root-first then dependency/ID instance
admission, and oldest-ready-first execution. Yielding/waking rejoins behind
already-ready work; non-yielding Lua segments are not interleaved on that VM.
Content cannot select priorities or before/after phases. Logical admissions
use assigned tick/sequence positions; real delays do not select effect order.

The manager presented the health 9/8 interleaving example and the cost that
the game or an earlier dependency need not finish its update before a mod runs.
Exact input assignment, tick completion and suspension rules remain separate;
this decision supplies no implicit commit permission at scheduler quiescence.

### D-35. Use explicit checkpoint waits for gameplay spanning ticks

**Delivery (D-43/P-40):** L-STATE.

**Deferred to a later arc by D-41; preserved owner decision, outside this milestone.**

Owner answer, **2026-10-21 18:27:19 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: checkpoint waits (Rec.)

Authenticated relay: `het-manager`, message `k9n9zt25jfvj65iq8yjwxczpd2`,
posted **2026-10-21 18:27:19.659 UTC** in `#het-luafirst`, replying to Q-5f
message `ff2nw75z6fk5n2t5d5khtwazew`.

P-31 option A is accepted: future-tick/result waits explicitly finish the
invocation's contribution to this tick; ordinary cooperative yields do not.
The engine requires positive completion/no-work evidence for all participants
and due work, plus failure accounting, before the whole tick can commit.
Another participant's failure rejects that tick's entire working state.
Resumption uses the later tick's working state; saved copies can be stale.
Earlier committed ticks survive later failure. Existing one-active-invocation
and cadence behavior remains, with no catch-up updates while a hook waits.

The manager used an NPC walking, waiting three ticks and opening a door to
illustrate a multi-tick routine. The question also included the coin example,
the pattern of waiting for data before an atomic purchase, and the authoring
cost of understanding commit boundaries. These are examples, not new APIs or
game-specific engine behavior. Pause/stop dispositions, exact checkpoint
spelling and initial-state construction remain open.

### D-36. A rejected gameplay state mutation fails the tick

**Delivery (D-43/P-40):** L-STATE.

**Deferred to a later arc by D-41; preserved owner decision, outside this milestone.**

Owner answer, **2026-10-21 18:41:59 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: fail the tick (Rec.)

Authenticated relay: `het-manager`, message `52nacc9w84v29zwvg3jbw25bkn`,
posted **2026-10-21 18:41:59.736 UTC** in `#het-luafirst`, replying to Q-5g
message `yfsx2kt72zpu8yegu7ndgt73xe`.

P-32 option A is accepted: a rejected authoritative mutation is a gameplay
failure. The refused operation changes nothing, and no writes from that tick
commit. Catching the error cannot clear the recorded failure. Gameplay stops
with the last good snapshot; a healthy UI shows the attributed error under
D-19/D-26. There is no automatic retry or recoverable try-write exception.

The manager presented the coin/item example and the strict cost: stale targets
and full-container rejections also stop gameplay. Lua handles expected game
conditions such as insufficient coins or a full inventory before attempting
invalid mutations. Exact target validity, permissions, limits and query results
remain separate contracts; this decision chooses rejection escalation.

### D-37. Entity references may outlive their targets

**Delivery (D-43/P-40):** L-STATE.

**Deferred to a later arc by D-41; preserved owner decision, outside this milestone.**

Owner answer, **2026-10-21 18:45:28 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: non-owning refs (Rec.)

Authenticated relay: `het-manager`, message `eviwsh3iq9kvsaa2qf3gurpbmi`,
posted **2026-10-21 18:45:28.980 UTC** in `#het-luafirst`, replying to Q-5h
message `aufvrqzapkcjt4fuqfqsjwkxv6`.

P-33 option A, including its shared identity/read guarantees, is accepted.
Deleting an entity removes it and its components without clearing references
elsewhere or cascading to other entities. A quest may retain the deleted NPC's
reference; Lua checks existence and chooses the game meaning. Such references
remain valid stored data, but using a deleted entity as a mutation target is
tick-fatal under D-36. References never silently retarget a different entity,
are session-scoped, and support ordinary absence checks.

The owner was shown the cost of handling missing targets, and that one mod's
retained reference cannot itself prevent another mod's deletion. This selects
reference lifetime, not cross-mod write permission, exact ID representation
or persistence. No automatic relationship cleanup is introduced.

### D-38. Trusted gameplay instances share state access

**Delivery (D-43/P-40):** L-STATE.

**Deferred to a later arc by D-41; preserved owner decision, outside this milestone.**

Owner answer, **2026-10-21 18:57:21 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: shared access (Rec.)

Authenticated relay: `het-manager`, message `dez3g8k3a6uij2pqwmib4vjgri`,
posted **2026-10-21 18:57:21.377 UTC** in `#het-luafirst`, replying to Q-5i
message `xghikfxgcwzjecwb676sbm47fs`.

P-34 option A is accepted: the game and every gameplay mod share the state
service, with access to all entities and registered components during allowed
phases. They may create entities, attach/change/remove components and delete
entities, including components contributed by other mods. Namespaces govern
schema definition, not value-write permissions. The UI remains snapshot-only;
state checks, D-36 failure behavior, executing-instance attribution and native
resource ownership remain in force.

The manager presented the combat-mod/health and game/weather examples as
matching the owner's trusted game/mod direction, and explained that mods may
bypass conventions, make schema-valid changes that break game logic or delete
entities others need. Neither access model was described as hostile-code
containment. Exact mutations, phase rules and overlapping-write semantics
remain separate checkpoints.

### D-39. Write whole component values

**Delivery (D-43/P-40):** L-STATE.

**Deferred to a later arc by D-41; preserved owner decision, outside this milestone.**

Owner answer, **2026-10-21 19:00:22 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: whole components (Rec.)

Authenticated relay: `het-manager`, message `sgsmh47fxw78gvk6n9n4af3mpn`,
posted **2026-10-21 19:00:23.061 UTC** in `#het-luafirst`, replying to Q-5j
message `79t6ab4zbkhsi778hpxhgtb63w`.

P-35 option A is accepted: read a copy, edit in Lua and explicitly submit a
whole component value. Attachment supplies the full initial value; replacement
validates/copies atomically without merging, diffing or nested setters. Later
complete replacements determine the resulting value in D-34 execution order;
there is no implicit stale-version precondition.

The manager presented the armour 3-to-2 stale-copy example, the need to re-read
after yielding and use an uninterrupted read/edit/write sequence when current
values matter, and the full copy/validation cost for large components. Smaller
components were offered as an authoring option, not a physical storage mandate
or performance guarantee. Exact presence rules and signatures remain open.

### D-40. Queries return copied, ordered lists with fixed membership

**Delivery (D-43/P-40):** L-STATE.

**Deferred to a later arc by D-41; preserved owner decision, outside this milestone.**

Owner answer, **2026-10-21 19:12:41 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: copied ordered list (Rec.)

Authenticated relay: `het-manager`, message `9iyjvzk59gqyj4fk94psvu58ts`,
posted **2026-10-21 19:12:41.614 UTC** in `#het-luafirst`, replying to Q-5k
message `rf42cgc86ypfmyd7hcm67gvk3a`.

P-36 option A is accepted: required component types select a dense copied
list of matching references, once each in stable entity-ID order, with
membership fixed at the call. Empty requirements select all live entities;
Lua performs further filtering. Values are read separately; later creations
do not enter the old list and deleted targets leave dangling references.
An over-budget query is refused in full without failing the tick, never
silently truncated. No cursor or query-expression language is selected.

The manager illustrated requiring position and health, without prescribing
game component types. The owner was told the full-copy cost and that large
queries may be refused. Exact limits, identity encoding, result syntax and
the presentation snapshot-acquisition contract remain open.

### D-41. Defer gameplay state; deliver an engine-service milestone

**Delivery (D-43/P-40):** M1 scope / L-STATE history.

Owner scope decision reported at **2026-10-21 19:21:07 UTC**, in the manager's
pane, replacing Q-5l. The owner's replies, verbatim and in order:

> why should this even be in scope?

The manager explained its reading that D-3/D-15 needed an init-state rule and
offered a designer choice of A, B, or continued questions. The owner replied:

> then i need to change d-3 and d-15, when init calls the state service, it needs to simply print and exit, this is just a milestone, i dont want to touch any gameplay concepts

After the manager clarified three readings, the owner selected, verbatim:

> Defer the state store

The selected option was shown with this text (quoted option wording, not a
separate free-form owner utterance):

> The milestone has NO gameplay state store: D-3 and the state decisions D-30 to D-40 (entities, components, values, schemas, queries, writes) are deferred to a later arc. Any call to a state service just prints a 'not available in this milestone' message and exits. The milestone covers boot, the filtered library, content loading, mods and Lua driving windows, input, rendering and textures. Init/update/shutdown hooks stay.

Authenticated relay: `het-manager`, message `ahptym5v44ee35afe5en96dkmi`,
posted **2026-10-21 19:21:07.738 UTC** in `#het-luafirst`, replying to Q-5l
message `3uzg7vi972ir7qjmi83yb8w9us`. Separate times for the preceding questions
and free-form replies were not supplied.

This revises D-3's scope and D-15's service availability as stated. Preserve
D-30 through D-40 as recorded owner decisions for a later arc, explicitly
deferred in full here, including D-34's scheduling selection and D-35's state
checkpoint protocol. Withdraw Q-5l and its unapproved P-37; neither initial
world option was accepted. Do not implement a substitute Lua gameplay store,
world snapshot, entity/schema/query system or transaction/replay layer to fill
the gap. Ordinary script locals and engine service/lifetime bookkeeping are
not the deferred gameplay store.

The manager asks for an exhaustive dependency audit and proposed milestone
interpretations, especially the gameplay VM/ticks, before the remaining service,
vision/epic and delivery questions. That audit is P-38/Q-11. D-41 approves the
scope change itself, not the designer's subsequent reconciliation choices.

### D-42. Retain logical scheduling and reconcile the service-only runtime

**Delivery (D-43/P-40):** M1 runtime / L-MODS feature implementation.

Owner answer, **2026-10-21 19:28:09 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> Approve all six (Rec.)

Authenticated relay: `het-manager`, message `b9bv8e44kd7w5q3t4jk3asavan`,
posted **2026-10-21 19:28:09.801 UTC** in `#het-luafirst`, replying to Q-11
message `6hx83nmctxvj4jwhkrhxpjjdaw`.

All six parts of P-38, including its exhaustive earlier-decision audit, are
accepted as this milestone's runtime contract: retain the logical-clock VM,
fixed ticks/cadence, assigned content results and host FIFO scheduling without
a world or transactions; use ordinary waits, status-only startup/cross-role
observation and status-only logical-owner failures; terminate the whole session
on a state-service call with an unavailable diagnostic on stderr and orderly
failure exit 1 after protected cleanup; preserve only the stated host/service
guarantees, without adding gameplay-state determinism, digests or replay.

The manager summarized all six parts and the cost of two clocks and assigned-
result machinery without a store. The owner did not choose the offered
presentation-only milestone alternative. D-14's default pair and one-role
variants therefore remain, including a headless logical-only arrangement.
D-3/D-30–D-40 remain deferred; the reuse of host FIFO is approved here in its
own right and does not reactivate the deferred state/checkpoint design.

Proceed to the available service bindings, vision/#145 reconciliation and
delivery order. Exact service grants, API spelling and acceptance details
remain to be selected; this is not approval to implement or file issues.

### D-43. Deliver M1 as a textured quad over reusable Lua/service foundations

**Delivery (D-43/P-40):** M1 scope; later work allocated explicitly.

Owner answer, **2026-10-21 20:11:20 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> Approve the package

Authenticated relay: `het-manager`, message `2qay5v64gj7e42pnytum6p9z4i`,
posted **2026-10-21 20:11:20.516 UTC** in `#het-luafirst`, replying to Q-12
message `cuekk8re74pbgsacz4egqr9a2s`.

All six parts of P-40 are accepted, including its acceptance evidence,
per-decision delivery allocation and required two-instance integration test.
M1 displays a Lua-authored textured quad in a real window with a real logical
VM running stub content and real UI lifecycle/loading/rendering behavior.
Root/instance identity, clocks, ordering, ownership, failure and cleanup are
built for reuse; mod activation, compatibility and extension features are not
implemented yet. D-23/D-25/D-26's reusable foundations ship now, with their
mod-specific admission/init-chain work later. D-14's accepted VM options stay;
the primary acceptance demonstration uses both roles.

The manager summarized all six parts and the cost of real reusable components
beyond the small visible result. The owner chose approval rather than revision.
General input, widgets/fonts, advanced presentation, 3D/audio, hot-swap and
the ECS remain later work; deeper questions about those areas do not block M1.
Continue deep design for M1-touched contracts, then its APIs, vision/#145
reconciliation and one-PR slices. This scope approval is not implementation
or tracker-mutation authorization. Original Q-6a remains unanswered; re-ask
its applicable M1-only service-grant choice next.

### D-44. M1 graphics belong to the UI VM only

**Delivery:** M1; narrows D-9's texture grants.

Owner answer, **2026-10-21 20:32:12 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: UI VM only (Rec.)

Authenticated relay: `het-manager`, message `88zsk5ymf3v35w8wxykyckq9yi`,
posted **2026-10-21 20:32:12.222 UTC** in `#het-luafirst`, replying to
Q-6a revision 2 message `24m9yw4ptg68rw3q5kzepx4b9n`.

Accept P-41's A: presentation instances request textures, own window/texture
resources and publish scenes. Logical instances load modules/data but cannot
request texture leases in M1, expressly narrowing D-9. There is no forwarding
or cross-VM graphics bridge; logical-only remains headless. Wrong-role graphics
calls are refused before native action as ordinary Lua errors. D-42's terminal
state-service guard remains separate. Both roles retain the approved runtime
services, and Haskell retains native-thread and protected retirement duties.

The manager presented this as matching the owner's UI-VM-draws-the-quad direction;
the owner chose A rather than graphics in both VMs. This selects role grants,
not exact window readiness, scene format, resource-sharing APIs or general input.
Continue with M1 binding/lifetime contracts, starting with P-42/Q-6b.

## Proposals

**Scope precedence:** D-41 supersedes the original state-store agenda. Accepted
proposals P-26 through P-36 are retained only for the later state arc. P-37 is
withdrawn. State-dependent clauses in other historical proposals must be read
with the P-38 audit and its replacements accepted by D-42.
D-43/P-40 then allocates those contracts between M1 and later work; that
delivery boundary supersedes earlier broad mod/input implementation scope.

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
and non-suspending; cleanup still occurs if it is absent or fails (prior Lua D-27).

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

**Option A accepted by D-16.** Whenever the gameplay
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

### P-13. Declare root update cadence alongside the Lua behavior

**Option A accepted by D-17.** A root behavior with an
`update` hook declares its cadence in Lua metadata beside that hook. The
manifest continues to choose the VM role/clock and gameplay tick duration.
Gameplay cadence is a positive integer number of logical ticks, defaulting to
one when omitted. Presentation cadence is an explicit positive, exactly
representable elapsed duration; it has no implicit rate. The metadata grammar
and field names remain to be specified. This is declarative data, so it does
not violate D-8's module-top-level effect restriction.

Validate the selected behavior and cadence before its `init`. A presentation
`update` without an interval, or an invalid/wrong-clock interval, fails startup.
A behavior without `update` is event-driven and declares no periodic cadence;
a cadence with no update is an error, rather than a silently unused setting.
Cadence is captured on instance admission and fixed for that instance's life;
mutating the exported metadata afterward does not reconfigure it. Additional
Lua-created routines and any deliberate rescheduling API remain to be designed.

Presentation updates use the existing monotonic timer, independently of
rendering: a late timer coalesces refresh demand and supplies actual elapsed
`dt`, without a backlog of missed refreshes. This is a target update interval,
not guaranteed frames per second; multiple windows need not share a render
rate. Rendering can reuse the latest published presentation state. Gameplay
uses the existing logical cadence rules from P-12; choosing every tick does
not override a currently active/suspended invocation or establish transaction
commit rules. Event delivery remains independent of periodic update demand.

Alternative B puts these same root cadence settings in the manifest, retaining
the same defaults, validation, fixed admission and independent elapsed timer.
It centralizes launcher configuration but splits a behavior from its routine
schedule. A is recommended because Lua owns the routines; it adds behavior
metadata validation while reusing the delivered scheduler. B instead adds
manifest fields and resolves them against the selected Lua exports. Neither
choice introduces render-frame callbacks or changes the fixed gameplay tick
duration. A render-driven presentation update would be a revision needing its
own multiple-window, minimized/no-window and render-backpressure contract.

Evidence: `packages/scripting-lua/README.md` (Cadence) provides `LogicalTicks`,
`ElapsedEvery`, event-only admission, fixed lifetime intervals, one pending
elapsed refresh and elapsed `dt` between update starts. The launcher/entry
adapter must supply that admission configuration from the chosen source.

### P-14. Start root initializers concurrently and release presentation first

**Revision 2 accepted by D-18.** Retain the five-part contract below. It
revises the original serial-start proposal in response to the owner's variant
preserved under Q-3e; the subsequent explicit signoff is recorded in D-18.

1. **Concurrent admission.** Validate the manifest/content inventory and the
   selected entry exports/cadences, then dispatch both root initializers to
   their separate VM owners without waiting for either to finish first.
   Concurrent means neither completion depends on the other; it does not
   promise simultaneous CPU execution. D-15's finite, non-yielding init remains
   unchanged. Initial scanning and entry/module evaluation still precede this
   phase and have no Lua loading UI under this proposal.
2. **Independent UI start.** As soon as presentation init succeeds, its elapsed
   updates, input/events, content completions and presentation services may
   run. Its cadence begins from its own successful init (D-17). It sees a
   coherent session-starting status and root readiness, with no authoritative
   gameplay snapshot yet. Gameplay-state reads return a structured not-ready
   result, never partial initialization data. UI may load its own content,
   operate its windows/rendering and request session cancellation. Gameplay
   intentions and gameplay lifecycle controls are refused as not-ready during
   startup, not buffered for later or silently dropped. Exact binding names
   and status schema remain to be specified. UI must not depend on gameplay
   init data or synchronously call the gameplay owner; no custom gameplay
   progress-message channel is introduced by this choice.
3. **Gameplay start gate.** If gameplay finishes first it waits. No gameplay
   ticks, updates or event callbacks run until both selected inits succeeded
   and no failure/cancellation is recorded. The transition publishes a coherent
   initial gameplay view and running status before releasing normal gameplay
   delivery; the generic store design must define that initial snapshot and
   its validation. Startup wall time grants no gameplay time or accumulated
   catch-up ticks. Pending content requests need not finish before this gate
   opens: gameplay results keep their assigned-tick delivery, and game-specific
   asset/readiness state remains Lua-owned. A one-role session skips the absent
   role: gameplay-only starts after its own init, presentation-only after its
   own init, with absent-domain calls refused under D-14.
4. **Failure and cancellation.** An init failure on either side, or a failure
   of the already-running presentation root before the gameplay gate opens,
   fails boot. Atomically close the startup gate against late success, stop
   accepting new work, request cancellation on the other owner and pending
   interests, and retire both sides. No failure path waits for the other side
   to become ready before asking it to stop. A failed initializer receives no
   shutdown; a root which successfully initialized follows normal shutdown
   and engine cleanup, including a success racing with cancellation. A late
   completion cannot reopen the gate. Retain concurrent failures and cleanup
   evidence; exact reporting/exit codes and post-start session failure policy
   follow separately. Early UI may disappear on failed boot; a persistent
   custom error screen is not promised. Session cancellation follows the same
   stop/cleanup path without inventing an init failure. Trusted non-yielding
   Lua can keep cancellation pending; do not destroy its VM or release native
   resources while it is still executing (prior Lua D-27).
5. **Startup ownership.** Replace the proposed single execution barrier with
   per-role gates: presentation opens on its own success, gameplay on joint
   success. The coordinator owns the status, transition and cancellation;
   each VM still owns its execution and resources. Callback admission and
   completion queues remain bounded and cannot bypass those gates. The native
   main-thread service loop must continue servicing presentation while the
   coordinator awaits gameplay init; blocking that loop would defeat this
   design. Native effects such as a visible window are cleaned up on failure,
   not retrospectively undone.

**Recommendation.** The owner's variant is a good fit for a loading screen
during gameplay init, and is preferable to the original serial order for that
goal. Keep heavy asset work in engine-owned asynchronous requests and let init
return promptly; then normal updates/events can maintain Lua loading state.
This works with concurrent startup and avoids treating a long or blocking init
as the asset-loading mechanism. Separate owners permit progress but do not
guarantee smooth rendering under CPU/native-service contention. There is no
need for a new yielding setup hook or a gameplay-dependent UI bootstrap.

Cost: explicit starting/not-ready behavior, two admission gates, race-safe
failure/cancellation, and coverage of both completion orders, early UI events,
one-role sessions and failure while the other init is active. The original
alternatives (gameplay then presentation behind one barrier, or presentation
first then gameplay) remain historical proposals, not accepted contracts.
Evidence: the existing VM-owner and instance mechanisms support separate
owners and lifecycle cleanup, but `samples/lua-domains` uses serial startup;
the concurrent launcher protocol is new work, not claimed delivered behavior.

### P-15. Preserve a healthy presentation root after a gameplay root failure

**Option A accepted by D-19.** For ordinary root-script
failures after successful startup: a gameplay root failure ends simulation,
while a healthy presentation root continues to render and receive input so
Lua can show the error. Close gameplay admission and tick grants immediately;
discard uncommitted work and retain the last committed state. Stop/settle
gameplay work and account for its failures before claiming final quiescence,
preserving prior Lua D-47/D-48's attribution and commit boundary. UI may see
failure/ending status with the last good snapshot during settlement, but must
not be told cleanup has finished until it has. This is failure containment,
not rollback of Lua globals, native effects or already committed ticks.

The surviving UI receives a bounded structured failure description, including
source/role, stage and available traceback, alongside the coherent frozen
gameplay view. It may keep using its own presentation/input/content services
and request session exit. Gameplay intentions and lifecycle controls are
refused as ended. There is no automatic restart/retry, no continuation of the
failed simulation and no newly authorized reload/recovery API. Lua authors
must handle failed-session status if they want a useful error screen; the
engine also reports diagnostics independently of that UI. Without such Lua
handling, an unchanged screen may remain until the user quits. No timeout or
automatic exit is imposed while healthy presentation is running.

A presentation root failure ends the whole session: stop gameplay, retain the
last committed state for the final report, and retire both sides. Continuing
gameplay without its failed UI is not the launcher policy in A. Gameplay-only
failure and presentation-only failure both end their one-role session. The
eventual process outcome remains failure even if the user later exits normally
from the surviving UI; precise CLI codes and diagnostic schema follow.

Both A and alternative B preserve D-12: explicitly optional content can return
a structured failure to Lua; a failed required operation cannot silently become
optional. A resulting root failure follows this policy. Host/provider and
cleanup failures remain fatal to the session, not ordinary script errors
which a surviving UI is promised to absorb. D-18 already governs failures
before startup completes. Additional instance/mod failure boundaries remain
part of their own design, rather than being silently classified here.

Alternative B ends the whole session on either root-script failure after
startup, preserving the last committed state and diagnostics while retiring
both sides. B has a smaller terminal-state lifetime contract and needs no
Lua error-screen handling, but offers no continuing in-game explanation.
A is recommended for an interactive Lua-authored engine because the existing
domain separation can keep an error screen responsive without executing any
more failed gameplay. Its cost is a bounded failure view, an explicit
failed-gameplay/live-presentation state and tests of late failures and exit
during retirement. Neither option promises immediate cancellation of trusted
non-yielding code or releases resources before safe retirement.

Evidence: `samples/lua-domains` retains the last good world and accounts for
gameplay settlement before publishing final failure, and lets UI observe the
end. It also isolates UI failure while gameplay continues; that sample policy
is deliberately not assumed for this launcher. Keeping healthy UI alive until
explicit exit is the accepted launcher design, not an existing sample guarantee.

### P-16. Reuse console outcome conventions and the two-signal escape

**Option A accepted by D-20.** The new game-launch path
uses the existing console outcome conventions, with these explicit mappings:

| Exit status | Game-launch outcome |
| --- | --- |
| 0 | Explicit normal session quit/cancellation completes without failure |
| 1 | Content/manifest/entry/boot failure, root-script failure, or host/cleanup failure |
| 2 | Invalid command-line syntax or arguments, diagnosed before game execution |
| 130 | An orderly SIGINT/SIGTERM interruption without failure; also the forced second-signal path below |

A broken game manifest or invalid Lua behavior is a game/boot failure (1),
not command-line misuse (2). During orderly exit, failure outranks interruption,
which outranks success: quitting from D-19's error UI still returns 1. A normal
Lua session-exit request starts orderly teardown of the whole session; it does
not merely pause gameplay or leave the UI running. Repeated requests are
idempotent. Window-close behavior and the exact Lua exit binding remain part
of the service design, not inferred from this choice.

Diagnostics go to stderr independently of the Lua error screen; authored
application output/print uses stdout, and warnings/logging use stderr. Reports
identify component/operation and, where available, role, source content root
and path, lifecycle stage, last committed/failing tick, traceback and retained
cleanup failures. Preserve the primary error when reporting or teardown also
fails. Diagnostics and the UI failure view are bounded with visible truncation;
exact field names/limits and machine-readable formatting remain to be specified.
This does not add a world-save or crash-dump feature.

The first SIGINT or SIGTERM asks the coordinator to stop the entire session
without waiting in the signal handler. Close admission/grants, discard
uncommitted work, request cancellation and complete orderly shutdown and
protected retirement, including startup and D-19's surviving error UI. A
second signal while stopping forces process exit 130, without waiting for
remaining hooks/cleanup or flushing output. This exceptional forced exit
cannot promise cleanup or a complete diagnostic report, and always returns
130 even if failure had already been recorded. Lua gets only the orderly
session-exit request, not a force-exit capability. Handlers are scoped to the
new launch path; existing commands keep their behavior.

Alternative B keeps the same reports, outcome mapping and orderly first-signal
stop, but subsequent signals never force exit. B avoids a launcher escape
which skips cleanup; hung trusted Lua then requires the user to terminate the
process externally. A is recommended because this explicit two-step escape
already exists on the trusted `lua` command and is useful when cooperative
shutdown cannot finish. It is a user-requested process termination, not script
containment or a timeout/retry policy.

Evidence: `packages/scripting-lua/README.md` (The executable, Exit statuses,
Signals) documents 0/1/2/130, failure precedence, stderr/stdout separation and
the second-signal forced exit. The new launch path needs its own outcome
mapping and native-resource/partial-start integration; reuse is a design
choice, not a claim that its lifecycle has already been implemented.

### P-17. Enable mods through an explicit launch-time list of content folders

**Option A accepted by D-21.** The launcher takes the
game folder (D-13) and zero or more explicitly selected mod folders. No mod
selection means the base game alone. The first interface is a repeatable
command-line argument; `--mod ./my-mod` is illustrative until the CLI contract
is approved. Do not search user directories or automatically enable neighboring
folders. An enabled mod is a content root with its own non-executable manifest
and stable ID, under the same filtering and file rules as the game.

Resolve the selected set and validate its manifests before any Lua starts.
Duplicate selected roots or duplicate content IDs, including collision with
the game's ID, fail boot instead of silently choosing a winner. Only selected
roots are enabled; a missing required dependency fails boot rather than
searching for, downloading or automatically enabling it. Dependency declaration
and execution order are the next mod decisions; the order of command-line
selection does not by itself establish an override or execution order.

Freeze the enabled set for this session. Lua may load more modules/data/textures
from those roots at runtime under D-9, but enabling/disabling mods requires a
new session. This does not decide the separate Q-10 script hot-swap proposal.
Selection-path resolution, packaged distributions, saved launch profiles and
a graphical mod selector remain separate scope choices; no mod installer or
automatic dependency resolver is implied.

Alternative B discovers and enables every valid mod folder under a designated
mods directory. B makes adding a folder enough to enable it, but the directory's
contents then determine the session's code set; it needs explicit rules for
unwanted folders and discovery errors. Both still validate identity, pin the
chosen content and refuse undeclared/missing required roots before Lua.
A is recommended for an explicit, reproducible launch set and straightforward
failure attribution; its cost is listing the desired folders at launch, until
a separately designed saved profile or selector supplies that list.

Evidence: the current executable exposes explicit headless script paths and
has no game/mod discovery subsystem (`app/Main.hs`, Lua host README, The command
line). D-6 requires explicit content identities, D-10 pins session content and
D-13 already establishes manifest-bearing folders. Mod selection is new
launcher work; none of those decisions alone chooses automatic discovery.

### P-18. Order mod activation by declared required dependencies

**Option A accepted by D-22.** Each mod manifest may
declare required mod IDs. All must already be in the explicit selection
(D-21); do not automatically expand it. Validate the dependency graph before
Lua: missing dependencies, self-dependencies and cycles fail boot, with the
involved IDs and a dependency chain in the diagnostic. Dependency versions
and game compatibility remain a separate contract; this choice introduces no
version solver or automatic download.

Compute a deterministic order in which dependencies precede dependents. When
several mods are eligible, choose by exact content-ID byte order, independent
of filesystem enumeration, CLI order or locale. For example, if weather
requires calendar, calendar precedes weather; an unrelated mod is placed by
the same deterministic tie rule. Include the resolved order in startup
diagnostics so an author can inspect what the engine will do.

This is the order for explicit mod activation/registration steps once those
are designed. It is not a new cross-VM synchronization rule: D-18 still starts
the selected gameplay/presentation roots concurrently. Module imports retain
D-7's demand evaluation, shared exports and separate import-cycle errors; a
mod ordering edge does not imply every module ran or every asset finished
loading. Hooks still own effects under D-8. How game/root initialization and
mod activation fit together is the next lifecycle contract, not inferred here.
No order makes one mod silently overwrite another; conflicts/overrides remain
explicit decisions under D-6.

Alternative B adds optional ordering edges: a mod may ask to run before/after
another selected mod without requiring that mod to be enabled. An absent
optional target contributes no edge; any cycle among the combined required
and present optional edges fails boot. B handles optional integrations whose
order matters, but adds manifest syntax, conditional graph construction and
diagnostics/tests for conflicts between hard and optional edges.
A is recommended for the initial mod contract's smaller authoring surface.
Its cost is no optional ordering hint: integrations needing guaranteed order
must be modeled as real dependencies, or wait for the optional-order extension.
Do not rename IDs or rely on tie order as a substitute for an explicit
dependency or approved replacement rule.

Evidence: D-21 already requires missing selected dependencies to fail boot,
but neither it nor the existing Lua module loader defines mod activation
ordering. This manifest graph/resolution stage is new launcher work. Actual
activation ownership and the domain mapping still require Q-4/Q-7 decisions.

### P-19. Give each mod its own instances inside the existing role VMs

**Option A accepted by D-23.** Game and mod gameplay
code share the session's gameplay VM; game and mod presentation code share
its presentation VM. A mod contributing to both roles has one primary
engine-owned instance in each, separate from the game's root instance. Those
instances use the same optional init/update/shutdown and Lua cadence contract
as the roots (D-15/D-17). Each has its own `self`, connections and resource
leases, with mod content ID, role and source recorded for diagnostics.
The engine invokes mod hooks in their owning instance context rather than
having the game call them as ordinary functions under the game's root owner.

Keep D-14's at-most-one-VM-per-role launcher arrangement. D-7's module cache
and export sharing apply within each VM: importing the same root/path reuses
its exports, including shared mutable Lua module state. Separate instances
provide cleanup ownership and attribution; they do not promise rollback or
independent module state. D-8 still prohibits top-level resource acquisition.
A mod's gameplay and presentation copies share no Lua object references and
communicate only through approved engine snapshots/intentions/services.

The cost of sharing a VM is a shared execution bottleneck: a non-yielding
mod can hang that role's game and other mods, and shared Lua tables can be
mutated by their users. The other role has its own owner, subject to the
existing trusted-code and native-service limits. This follows the owner's
trusted-mod choice; it does not claim hostile isolation. An ordinary mod
instance failure's escalation still needs an explicit policy because its
shared state may already have changed.

Alternative B gives each mod a separate VM for each role it contributes to.
It separates module/global state and VM execution from the game's VM, but
adds owners, scheduling and snapshot/command boundaries for mod interaction;
imports have separate caches and cannot directly share exports across those
VMs. It still supplies no process-level memory or hostile-code containment.
B would revise D-14's current launcher limit for mod-owned VMs and require a
concrete topology/communication revision before that exception is recorded.
A is recommended for trusted mods, using existing instance ownership inside
the already approved role pair instead of expanding VM topology.

This question chooses ownership/topology only. Mod role/entry declarations,
behavior when a contributed role is absent, exact init order relative to game
roots, dependency readiness across roles, failure escalation and additional
Lua-created instances follow separately. D-18's root concurrency remains the
baseline; mod activation must be integrated explicitly rather than assumed to
fit its gates unchanged.

Evidence: the Lua host already distinguishes a loaded module from engine-owned
instances, gives each instance its own leases/connections and failure identity,
and permits multiple scheduled instances per owner (`packages/scripting-lua/README.md`,
Instances and One invocation at a time). This is a new launcher composition
over those mechanisms, not an already implemented mod system.

### P-20. Declare mod role contributions explicitly and require those roles

**Option A accepted by D-24.** A mod manifest explicitly
declares zero, one or both of `gameplay` and `presentation`, with Lua entry
path(s) for its contributed roles. There is no implicit two-role default for
mods. An entry supplies the corresponding named behavior table, validated
under D-15/D-17; one file can export both tables or the roles can use separate
files. Exact manifest fields remain part of the format design. A mod cannot
create a VM or change the game's clocks through this declaration.

Each declared role is required. If the game's D-14 arrangement lacks it, fail
boot before Lua, naming the mod and missing role. Do not silently skip half of
a selected mod or create an extra VM to accommodate it. For example, a mod
declaring both roles cannot run in a gameplay-only game; an author can split
the gameplay contribution and the UI addition into separately selected mods.
An entry that lacks its declared behavior or has invalid hooks/cadence still
fails boot under the existing validation rules.

An explicit empty contribution set denotes a content/library-only mod: its
root, dependencies and fingerprints are validated normally, but the launcher
creates no behavior instance and automatically executes no entry. Its Lua
modules/data/textures remain available through explicit content references
when imported or requested. It participates in D-22's dependency graph without
an effectful activation hook; schema/data registration, if needed, must be
performed by an owning behavior through a later approved service. This does
not give module top level new capabilities or new resource ownership.

Alternative B adds a per-contribution optional-role flag. Required roles still
fail if absent; optional contributions are skipped only when the game's VM
role is absent. If that VM exists, the declared entry must load and validate
and its failures follow the normal rules; optional-role does not mean optional
code errors or optional module loading. B lets one mod serve full and headless
games, but needs skipped-contribution diagnostics, validation combinations
and rules for dependencies on role-specific activation. Those dependency
readiness rules would need a follow-up contract before implementation.
A is recommended for explicit selection semantics and fewer conditional
activation cases; its authoring cost is separate mods for independently
selectable role contributions. Neither choice settles game/mod init ordering
or implies a cross-VM call can wait for another role to initialize.

Evidence: D-14 lets the game select one or both VM roles; D-21 explicitly
selects whole mod roots; D-23 assigns instances per contributed role. The
missing-role policy and content-only case do not follow automatically from
those decisions. Both are now accepted launcher manifest/admission design,
not implemented behavior.

### P-21. Initialize each game root before its role's ordered mod instances

**Option A accepted by D-25.** Retain this five-part integration of
D-18/D-22/D-23/D-24:

1. Validate all selected role entries before hooks. Start the game gameplay
   and presentation root inits concurrently as D-18 requires. After a root's
   init succeeds, initialize that role's mod instances one at a time in D-22's
   resolved order, filtering out mods without that role. Each runs under its
   own engine-owned instance context, with finite non-yielding init; do not
   add a new configure/setup hook. Content-only mods have no initializer.
2. The presentation root may run as soon as its own init succeeds, while both
   initialization chains continue. Its timer/events may run between finite UI
   mod initializers on the same VM; a long or hung UI mod init still delays
   that VM. UI mod updates/events are held until the UI mod-init chain has
   succeeded, then may run even if gameplay is still starting. Startup UI must
   tolerate incomplete mod activation and cannot depend on gameplay init.
   Keep the existing starting/role-ready status contract, without adding a
   detailed gameplay-init progress channel.
3. Gameplay ticks/updates/events wait for the gameplay root and all gameplay
   mod inits, plus the presentation root and all presentation mod inits when
   that role exists. Publish a coherent initial gameplay view and running
   status at that joint transition. No startup wall time becomes gameplay
   ticks. Pending content still need not finish before init is considered
   successful. One-role sessions omit the other chain.
4. Required dependencies guarantee preceding successful init **within each
   role**, not cross-role readiness. If mod B requires mod A and both have UI
   contributions, A's UI init finishes before B's UI init starts; A's gameplay
   init may still be pending. A dependency without that role contributes no
   initializer there. Its declared content is available under normal import
   rules, but other-role state remains unavailable until the joint gate opens.
   No initializer waits synchronously for another VM. This is the concrete
   role-local interpretation of D-22's activation order, not a promise that
   an entire two-role mod is initialized before its dependent starts anywhere.
5. Any selected mod init failure fails boot, attributably to its mod/role, and
   closes both chains and the gameplay start gate. Stop admitting later inits,
   cancel pending work and tear down successful roots/mod instances through
   their owned lifetimes; a failed or never-started init gets no shutdown.
   Late successes cannot reopen startup. Existing D-18 failure/cancellation
   rules also cover early running UI here. No skip, automatic retry or rollback
   of shared Lua mutations is promised. Runtime mod failure escalation and
   exact teardown ordering remain separate contracts.

Authoring cost: game root init establishes core services/state before mod init
effects exist. It can import pure mod definitions, but cannot consume mutable
registrations or state which mod init has not yet produced. Work depending on
those effects, such as generating a world from mod registrations, belongs in
normal execution after the joint gate opens; the store contract must specify
how initial data and later tick commits are staged. Early UI must tolerate
partially initialized UI mod contributions; there is no atomic rollback of
native or Lua effects while that UI is running.

Alternative B initializes mods before game roots, allowing roots to consume
their completed registration effects. It would delay the game-authored
loading UI behind UI-mod init and require a revised D-18 startup protocol
(and a way for mods to initialize without root-provided services/state).
If preferred, write that concrete revision for signoff instead of silently
changing the concurrent/early-UI contract. A is recommended because it retains
the approved game-root startup and gives mods an initialized core in their
own role, at the explicit authoring and partial-UI costs above.

Evidence: D-18 supplies role gates, D-22 a deterministic mod order and D-23
separate instances inside each VM. The host serializes an owner's execution
and supports init-time queued connections, but does not supply this launcher
protocol. Verification needs both role completion orders, dependencies whose
other role is still initializing, early UI progress, blocked mod callbacks,
one-role/content-only sets and failure/cancellation at each admission boundary.

### P-22. Escalate runtime mod-instance failure through its role's policy

**Option A accepted by D-26.** After successful startup,
an unhandled failure of a mod's primary gameplay instance fails the gameplay
session under D-19, just as a gameplay root failure does. Close gameplay
admission/grants, discard uncommitted work, stop all gameplay instances and
retain the last committed state. Healthy presentation may continue to show
the failure until exit; it receives the mod/role/source attribution as part
of the bounded failure view. Do not merely disable the failed mod and continue
simulation with possibly damaged shared Lua state.

An unhandled failure of a presentation mod instance ends the whole session,
as a presentation root failure does. One-role sessions follow the same rules.
There is no per-mod recoverability/criticality flag in A, no automatic unload
of just the failed mod and its dependents, and no retry/restart. Mod init and
early UI failures before the joint startup gate remain boot failures under
D-25; host/provider/cleanup failures remain session-fatal under D-12/D-19.
Ordinary Lua errors raised by shutdown are retained in the role's failure
evidence; protected release failures cannot be downgraded to script errors.

Attribute failure to the engine-owned instance executing the invocation and
its mod/role, with the failing module/source and traceback where available.
Calling an imported helper does not transfer instance or lease ownership to
the helper's content root. A content-only mod has no independently executing
instance to disable; an unhandled import/helper failure propagates through
the executing consumer's root/mod policy, retaining source provenance.
Handled optional data/texture failures still follow D-12 rather than making
the whole session fail merely because an optional result was unsuccessful.
This policy concerns reported instance failures; it does not turn every caught
Lua exception into a session failure. Ownership/escalation for additional
Lua-created tasks/instances will be explicitly connected to this policy when
that API is designed.

Alternative B would introduce explicitly recoverable mod failures, stopping
the failed mod and affected dependents while keeping the rest running. Before
recording B, design the recoverability declaration, permitted shared-state
effects, dependency shutdown and engine-state commit boundary; the existing
shared-VM/module contract alone cannot establish that continuing is safe.
B may suit optional cosmetic extensions but adds a recovery contract beyond
instance cleanup. A is recommended because D-23 shares mutable module state
and execution, so role-wide failure makes no unproven rollback assumption.
Its cost is that even a small UI mod's unhandled error can end the session;
authors must handle expected errors within their normal behavior.

Evidence: the Lua host reports instance identity, stage and traceback and
leaves escalation to its application because it cannot know whether shared
state was damaged (Lua host README, Failure and escalation). D-19 already
sets the launcher root policy; this proposal applies it to mod instances,
without treating the host's default instance isolation as proven recovery.

### P-23. Make shutdown self-contained, without a mod ordering guarantee

**Option A accepted by D-27.** Root/mod `shutdown`
hooks must not rely on another instance, dependency or role still serving.
The launcher promises no relative order between their hooks. A hook may use
its own still-live handles and local/pure helpers, but cannot depend on another
instance processing a cleanup event, another mod retaining its resources, or
the other VM answering. This is an authoring contract, not a claim that the
engine can prove arbitrary Lua functions pure. A manifest requirement orders
startup; it does not confer access to another instance's leases or guarantee
that dependency survives shutdown.

Reuse ordinary lifecycle stopping and engine-owned resource retirement.
Shutdown remains finite, optional and non-yielding; no hook runs for failed
init, and an unsafe owner exit can skip hooks. Engine cleanup still runs when
hooks are absent, fail or cannot safely execute, and retains provider/GPU
dependencies until actual retirement. Shared engine resources remain alive
for outstanding valid interests, independently of mod hook order. Hooks are
not responsible for discovering every resource or making dependency release
safe. No stopped instance is restarted to satisfy somebody else's cleanup.

For whole-session quit or a fatal presentation failure, close normal admission
and gameplay grants, request stops without waiting for another role to finish,
then account for settlement and protected retirement. The UI-only continuation
after a gameplay script failure remains D-19/D-26: only gameplay is stopped
until exit or a later fatal failure. D-20's deliberate forced process exit
remains the exception that skips remaining cleanup.

Alternative B adds reverse activation order for surviving initialized instances
on an orderly role shutdown: dependent mods first, then dependencies, game
root last. It needs a coordinated phase that first prevents ordinary work
throughout that role, then sequences hook entry/stopping. Already-ended
instances, concurrent failures, cancellation and unsafe owner exits still
cannot obey that order, so it would not make cross-mod cleanup safe on every
path. B is useful if an author needs orderly teardown notifications, but adds
a second ordering contract and failure-path exceptions. A is recommended
because owned lifetimes already provide resource safety on both orderly and
failed exits; authors give up reliance on cross-instance shutdown callbacks.

Evidence: the Lua host's Whole-owner control, Ending and Draining contracts
already skip Lua hooks on unsafe exit, drain instance holdings even after
hook failure and retain asynchronous retirements. The headless runner's
ascending instance-ID shutdown order is its own policy, not a dependency
ordering guarantee for this new launcher.

### P-24. Replace game behavior through explicit game APIs, not content remapping

**Option A accepted by D-28.** In this arc, mods extend
or deliberately replace game definitions through explicit Lua APIs/extension
points which the game exposes, and mutate authoritative state through approved
engine state services. The engine supplies lifecycle, content and generic
services without knowing which game-specific rule, item, sprite definition
or UI feature is replaceable. Games choose those extension contracts; a mod
cannot assume every game exposes the same ones.

For example, a game could expose a named player-appearance definition which
accepts an explicit reference to a texture in a mod's root. The game then
uses that reference; requesting the game's original texture path still names
the game's original content. Likewise a game can expose a rule/behavior
extension instead of redirecting the engine's module loader. These are
illustrations of the approach, not approved API names, object schemas or a
cross-instance callback protocol.

There is no launcher-wide file/module replacement map, merged content tree,
or automatic winner based on activation order. Root/path identity and D-7's
cache keep their existing meaning. This supported extension approach does
not prevent trusted Lua from mutating shared exports (D-7/D-23), and promises
no security boundary or automatic conflict detection for arbitrary table
writes. Exact registration, collision handling and callback ownership must
still be specified with the state/service contract; ordinary mod hooks keep
their engine-owned instance context. Native engine services, VM clocks and
the filtered-library policy are not game definition slots which mods replace.

Alternative B adds explicit engine content remapping: mod declarations name
which root/path to redirect to another selected root/path, including Lua
modules or textures. B supports asset/code replacement without a game-provided
extension point, but requires a conflict rule, remapping-cycle validation,
source/cache identity, fingerprint and provenance rules, and reconciliation
with D-6/D-7. It must never silently become load-order precedence. If chosen,
design that concrete revision before recording a replacement contract.

A is recommended because it retains explicit content identity and keeps
game-specific extension meaning in Lua. Its cost is that the game author
must expose useful APIs; this arc would not promise generic file/module
overrides for games which were not authored to support them. This choice does
not decide Q-10's deliberate development hot-swap protocol or permanent
exclusion of future replacement facilities.

Evidence: D-6 explicitly rejected implicit root overrides and reserved deliberate
replacement; D-7 fixes module identity to root/path; D-1 keeps game rules in Lua.
Neither current host module loading nor the selected mod lifecycle supplies
an engine-wide replacement resolver. This is a supported composition-surface
choice whose remaining API/conflict details must be resolved before readiness.

### P-25. Check exact declared game/mod API revisions before Lua

**Option A accepted by D-29.** Each game and mod manifest
publishes a positive integer API revision for the interfaces/definitions it
offers to mods. Each required-mod dependency names both the selected mod ID
and the exact API revision it expects. A mod also declares either a target
game ID with an exact game API revision, or explicitly that it is game-independent.
The latter accommodates reusable content/libraries and engine-only extensions;
it is an author's compatibility assertion, not automatic detection.

Before Lua, reject an incompatible target game or any required revision
mismatch, naming the consumer, required ID/revision and actual ID/revision.
Do not choose another installed version or expand the launch selection.
D-21's unique IDs and D-22's required-dependency order remain unchanged; adding
the revision check does not add optional ordering edges. All selected mods,
including content-only mods, participate in these manifest checks.

An API revision is not a package release number or content fingerprint. Authors
keep it unchanged when the advertised API contract is unchanged, and advance
it when that contract changes, including new API that dependents need. A
release changing only implementation/content may keep the same revision;
D-10 fingerprints still identify the exact session content. The launcher
verifies the declarations, not the semantic correctness
of an author's compatibility claim. Save schemas, engine binding compatibility
and the manifest format version remain distinct contracts; no save migration
or dependency download/version solver is implied.

Alternative B lets a target/dependency accept an inclusive range of API
revisions, checked against the one explicitly selected version. That helps a
mod which deliberately supports several interface revisions, but needs range
syntax/validation, broader author testing and precise mismatch diagnostics.
A is recommended for a small, strict first contract: authors supporting a
changed API must update the expected revision and verify their mod. Its cost
is no single manifest advertising support for multiple API revisions; even
a compatible implementation is refused if its declared expected revision is
different. Exact field names and integer bounds follow with manifest grammar.

Evidence: D-28 makes game extension APIs the supported integration surface,
and D-21/D-22 validate selected identities and required dependencies before
Lua. They do not yet detect incompatible changes under an unchanged content
ID. This is a proposed additional manifest validation contract, not existing
host behavior or proof that arbitrary shared Lua code is compatible.

### P-26. Store authoritative state as entities with Lua-defined components

**Later arc only: deferred by D-41. The original accepted contract follows.**

**Option A accepted by D-30.** The generic engine state
store owns entities with stable identities and named, schema-checked component
records. Lua game/mod code declares component schemas and game rules; the
engine validates and stores their data and commits changes at logical tick
boundaries. It has no built-in player, enemy, health or other game-specific
component types. This is a narrow state service, not a universal engine service
registry or a place to store native subsystem owners.

Illustratively, one player entity has position and health components; a world
entity has weather and score components. Game-wide/singleton state can use
such an entity rather than requiring a second global-state storage mechanism.
These names/shapes are examples, not approved engine schemas. Entity creation,
deletion, component attachment/removal and field changes are the operations
whose staging/commit contracts follow. Lua can select entities by component
presence; query ordering, bounds and exact API are separate decisions.

Only schema-checked data belongs in authoritative state. Lua functions,
coroutines, mutable VM table identity and live native resource handles stay
outside it; an engine snapshot must not depend on a live Lua object. Exact
value types, identifier/reference representation, schema registration/freeze
rules and rejection behavior are the next contracts. Gameplay submits state
changes; presentation consumes coherent committed views and sends intentions,
preserving the domain boundary rather than mutating gameplay state directly.

This chooses a logical data model. It does not require archetype storage,
parallel systems, a new scheduling framework or a performance claim. Existing
Lua hooks/routines remain the place for game logic. Physical layout should be
chosen for a concrete implementation and measured needs. The engine continues
to own the authoritative data and lifetime; Lua module tables may contain
definitions and local working state but are not the committed world (D-3).

Alternative B is a generic store of named, schema-checked tables/records,
without built-in entity/component identity or component queries. Games model
entities, relationships and lookup indexes in their own data convention.
B suits document-shaped state and avoids requiring entity organization, but
each game must define those common identity/query conventions. Both need
bounded values, schema validation, deterministic transaction ordering and
atomic tick publication; neither is arbitrary live Lua tables in the engine.
A is recommended for a game engine's reusable identity/query foundation;
its cost is entity/component modeling, including world entities for global
state, and implementing their generic operations and validation.

Evidence: `samples/lua-domains` already demonstrates a Haskell-owned entity
world with staged per-tick changes and coherent snapshots, but its entity
fields and transaction are sample-specific. No generic schema/component store
is claimed delivered. D-3 selects engine ownership, while V-1 keeps concrete
game rules out of engine packages; this proposal chooses the missing shape.

### P-27. Allow bounded typed records, lists and text-key maps in components

**Later arc only: deferred by D-41. The original accepted contract follows.**

**Option A accepted by D-31.** Component schemas describe
plain copied data using booleans, signed 64-bit integers, finite floats, UTF-8
text, typed entity references and typed content references. Schemas can combine
these into fixed-field records, homogeneous dense lists and homogeneous maps
with UTF-8 text keys. Optional record fields may be absent. These allow, for
example, an inventory list or a map of quest flags without requiring a separate
entity for each list item or flag. They are still schema-checked component
data, not arbitrary VM objects.

Every string/container has declared finite size limits; schema nesting and
total component/value bytes/elements also have engine-enforced ceilings. The
exact limits and aggregate store/transaction budgets follow separately. Record
fields are declared, unknown fields are refused, lists have no holes, and map
values have one declared type. Nil represents an absent optional field, not
a retained list element or map value. Schemas are finite/non-recursive;
relationships between entities use references instead of cyclic value graphs.
References are data identities, not ownership of another entity or a live
native lease; their representation, validity and deletion rules follow.

Copy/validate across the Lua boundary without invoking metamethods. Refuse
metatables, cycles, functions, coroutines and live native handles. Aliased Lua
tables contribute copied values, not retained alias identity. Integers and
floats stay distinct, with no silent coercion; refuse NaN/infinity in stored
float fields. Text must be valid UTF-8; arbitrary binary blobs are not a state
type in this proposal. Out-of-range, wrong-type or over-budget data is rejected
without partial mutation, never truncated or silently clamped. Whether a
reported rejection is recoverable in the enclosing tick follows with the
transaction API; this choice does not settle that failure policy.

Alternative B starts with flat fixed-field component records containing only
those scalar/reference types, no nested records/lists/maps. Games represent
collections and relationships using more entities/components. B has a smaller
validator and mutation surface, but makes inventory, quests and document-like
data less direct. A is recommended for the Lua authoring surface: bounded
containers support those common shapes while preserving copied state and
finite validation. Its cost is recursive schema/value validation, container
limits and deterministic traversal/encoding rules to specify and test.

Evidence: the Lua host already supports bounded copies of typed integers,
floats, UTF-8 text, records and dense lists, refuses metatables/cycles and
distinguishes absent optional fields (Lua host README, Values). Dynamic typed
maps, state-specific finite floats, schema-defined limits and state references
are additional store/binding work, not claimed as existing host features.
Query order, canonical digest encoding, container edit granularity and schema
registration remain later contracts.

### P-28. Register owned component schemas during gameplay init and then freeze

**Later arc only: deferred by D-41. The original accepted contract follows.**

**Option A accepted by D-32.** The game gameplay root
and each gameplay mod instance register component schemas from their finite
init hooks, in D-25's root-first/dependency order. Module top level may define
plain schema-description tables for later use, but cannot register them
(D-8). Presentation cannot register authoritative schemas. Content-only mods
may supply description helpers; an owning gameplay initializer performs any
registration. Presentation-only sessions have no authoritative state catalog.

A component type's identity is the registering game/mod content ID plus a
local type name. For example, `game-id:position` and `weather-mod:temperature`
illustrate the identity, not its final syntax. The engine derives the namespace
from the active instance; callers cannot register in someone else's namespace.
Mod types can be attached alongside game types without editing a central game
entity schema. Other components may be used by their qualified identity
through the eventual state API; registration ownership is not a decision about
who may read/write component values.

Reject duplicate full identities, even with identical descriptions; there is
no schema overwrite or load-order winner. Use lookup for an existing type,
rather than idempotent re-registration. Invalid schemas or duplicate registration
fail boot with declaring instance/type provenance; catching a Lua error does
not turn that invalid configuration into a successful boot. Registration is
atomic: refusal never leaves a partial schema behind. Schema/name/count bounds
and name grammar follow with the budget and API contracts.

After the gameplay initialization chain succeeds, freeze the catalog before
the joint startup transition publishes the initial world. No later addition,
removal, field extension or replacement of a schema is accepted in this
session. Loading new rooms/modules at runtime remains allowed, but their state
must use already declared types. Schema data belongs to the session's state
store and remains available with committed snapshots, including D-19's error
UI; it is not a native resource lease destroyed when its declaring mod ends.
The gameplay owner is the sole registration writer; presentation sees only
the frozen schema/view published through the normal cross-domain boundary.

Alternative B allows new, uniquely named component types to be added at runtime
through an explicit logical-tick operation; existing types still cannot change
or disappear. B supports content which introduces previously unknown types,
but requires schema additions to join transaction accounting, snapshot/catalog
versioning, capacity limits and deterministic replay. A is recommended to
keep the initial state contract stable; its cost is declaring every type needed
by later-loaded content during startup, or starting a new session to add types.
Neither choice permits schema migration or silently expands Q-10's hot-swap
scope. Game extension-definition conflicts remain separate from schema identity
collisions; this is not a universal replacement registry.

Evidence: D-25 supplies ordered gameplay initialization, D-30/D-31 require
engine-owned validated component data, and D-8 reserves effects for hooks.
The current host validates binding schemas separately, but has no generic
state-schema registry. This proposal requires new store registration, phase
checks, bounded validation and immutable schema publication.

### P-29. Gameplay reads see the current tick's staged changes

**Later arc only: deferred by D-41. The original accepted contract follows.**

**Option A accepted by D-33.** One engine-owned working
state for the tick, shared by gameplay instances. Each successful state mutation
updates that working state immediately; later gameplay reads see it, including
reads by the writer and by other game/mod hooks that execute afterward. For
example, reading health 10, writing health 9 and reading again returns 9. A
later mod also reads 9, unless intervening gameplay has changed it again.
Creation, component attachment/removal and deletion follow the same visibility
rule; their identity/reference validity rules still need separate decisions.

The working state remains private to gameplay until the engine accepts the
whole tick. UI reads only the last committed snapshot and cannot see a half
tick. Failure that rejects the tick discards its state changes and retains the
last good published world (D-19/D-26). This does not undo arbitrary Lua table
changes, logging or resource effects; shared Lua state is one reason a failed
gameplay domain stops rather than resuming after state rollback.

Reads return copied values, not writable Lua aliases into engine storage;
editing a returned table changes nothing until an explicit state write. Reads
made later can see newer staged values, but copies already returned do not
change behind the caller's back. This extends D-31's copied-value boundary.
No physical full-world copy per tick or particular storage layout is selected.

Alternative B keeps a fixed gameplay read view for the tick, with writes queued
for commit. In the example, the second read and a later mod still see health
10; the write of 9 remains pending. This resembles the current lua-domains
sample's staged moves. It makes reads independent of earlier staged writes,
but authors must retain pending values themselves, and read/modify/write
operations can unintentionally replace one another at commit. B also needs a
separate rule for using entities created in the pending batch.

A is recommended for ordinary sequential Lua rules and game extension hooks:
an accepted change is visible to the next operation. Its cost is that execution
order becomes part of gameplay behavior, including what a mod observes. Both
choices still need an explicit deterministic execution/input order, mutation
and conflict rules, bounded storage, and the prior Lua D-47/D-48 completion and
failure-accounting fences before publication. This choice does not approve
wall-clock-dependent ordering or treating scheduler quiescence as successful
tick completion. Whether invocations may suspend across future ticks, how
initial state is built, and what a rejected individual write does are subsequent
checkpoints; no per-hook transaction or automatic rollback is implied.

Evidence: `samples/lua-domains/README.md` describes a private candidate, a
staged batch invisible even to gameplay reads, and explicit completion/failure
accounting before commit. A deliberately changes that sample's read visibility
for the new generic store while preserving private staging and atomic external
publication. It requires store read/write bindings and tick ownership work;
it is not claimed as existing Lua host behavior. Delivery slices remain unset.

### P-30. Fix gameplay to the existing FIFO scheduler, with deterministic admission

**Later arc only: deferred by D-41. The original accepted contract follows.**

**Option A accepted by D-34.** Use the existing scheduler's
FIFO policy for the gameplay VM, fixed for the session. Game and mod updates
and event callbacks use the same ordinary service class; content cannot choose
a priority, service class or replacement scheduling policy. Engine control/stop
handling retains its existing boundary rules. This is the launcher's gameplay
contract, not a removal of policy support from the host library.

Create gameplay instances in the same root-first, dependency-first order as
D-25/D-22, with mod-ID ties already fixed by D-22. Stable instance order governs
admission when multiple instances have due work. Within each instance, keep
the existing accepted invocation order and one-active-invocation rule. Among
ready gameplay invocations, run the oldest ready one first. A cooperative
yield or a wake/resume joins behind already-ready work, rather than retaining
priority because it belongs to the game or an earlier dependency.

Consequently, with idle instances, no earlier queued work and all updates due,
the game starts before the mods in their resolved order. If the game writes
health 9 and yields, a ready mod may read 9 and write 8 before the game resumes;
the game's next read then sees 8. D-33 makes that interleaving visible. A mod's
dependency being initialized first does not promise that every update of the
dependency finishes before that mod runs. Hooks that do not yield execute
their Lua segment without another gameplay hook interleaving on the same VM.

Logical events, controls and loader results must enter through assigned tick
and sequence positions, not raw wall-clock arrival. Gameplay cannot use elapsed
waits or elapsed cadence to change readiness; presentation keeps elapsed time.
With the same fixed scheduler configuration, admitted work, assigned inputs,
grants and script behavior, segment durations, provider delays and budget cuts
must not change gameplay effect order. Deterministic input assignment, queue
bounds and the exact boundary ordering still need their concrete contracts;
this choice alone is not a complete replay specification. Prior Lua D-48's
limits for independently arising failures remain explicit.

Alternative B introduces an authored per-tick phase/order system, so, for
example, all game movement can finish before combat mods and then UI-facing
state preparation. It can express dependencies on completed work rather than
just ready-queue order, but requires new phase registration/conflict rules,
completion barriers and a suspension/deadlock contract. It is not merely a
different FIFO sort key. B would need a follow-up design before acceptance of
any particular phases or API.

A is recommended because it reuses the host's tested ordering and gives a
small explicit rule for shared staged state. Its authoring cost is that mods
cannot demand arbitrary before/after update phases, and a yielding hook cannot
assume the working state stays unchanged while suspended. Game-defined direct
Lua orchestration remains possible under D-28; callback ownership still needs
its own contract. Cross-tick suspension/commit eligibility, individual-write
rejection and conflicting writes remain separate checkpoints. Neither A nor B
permits publishing merely because no task is currently runnable.

Evidence: the Lua host README's Policies, Service classes, One invocation at a
time, Cadence, Determinism and assigned-tick request sections define FIFO ready
ordinals, deterministic instance admission and logical delivery. A fixes those
choices in the new launcher; it does not claim that the host already supplies
the game's input-assignment policy or a generic state transaction coordinator.
No delivery slices have been selected yet.

### P-31. Cross-tick waits explicitly finish the current tick's contribution

**Later arc only: deferred by D-41. The original accepted contract follows.**

**Option A accepted by D-35.** A gameplay update/event
may span ticks, but crossing a tick boundary requires an explicit engine
operation meaning **finish my contribution to this tick and wait**. It may
wait for a future logical tick or an engine result assigned to a future tick.
The operation's spelling and result API are not selected here. It is a
successful checkpoint for that invocation's current-tick work, not a request
to keep a transaction open across ticks. Ordinary cooperative yielding keeps
the invocation runnable within the same tick and acknowledges no completion.

1. A successful hook return or accepted checkpoint supplies positive completion
   evidence for that invocation's work in the current tick. The engine must
   account for every invocation that participated and all due work before
   publishing: each contribution finished successfully, or the engine records
   a valid no-work case. An invocation already waiting for a later tick and not
   resumed in this tick is a no-work case. No runnable work, pending admission
   or owed work may disappear merely because the scheduler looks idle.
   Refused waits, faults and unaccounted endings cannot count as checkpoints.
   Prior Lua D-47/D-48 failure accounting and the atomic failure/stop check
   still precede commit. Pause/stop/control dispositions need their own rules;
   they do not acquire completion permission from this proposal.
2. A checkpoint makes the invocation's earlier writes eligible for the shared
   tick commit, alongside other gameplay writes. It does not publish early or
   give that invocation an independent commit. If another participant fails
   before this tick commits, discard the whole working state. The engine then
   stops gameplay under D-19/D-26; it does not resume checkpointed work from a
   rejected tick. Only after successful commit may it grant the next tick.
3. When the invocation resumes, state reads/writes use that later tick's working
   state. No state transaction or live store alias survives the wait. Lua locals
   and copied values do survive and can be stale; authors must re-read/revalidate
   them when needed. FIFO interleaving within a tick remains D-34's rule.
   The existing one-active-invocation/cadence behavior remains: while a hook is
   waiting, that instance's further update cadence points do not queue catch-up
   updates. Other instances can keep advancing.
4. A later failure discards the failing tick, not earlier committed ticks. For
   example, subtracting one coin in tick T, checkpointing for a load assigned
   to T+2, and failing in T+2 leaves the committed coin subtraction intact.
   A game that needs coin removal and item creation to be atomic must do both
   in one tick, after the needed data is available, without a checkpoint between.
5. A missing required provider result holds its assigned future tick as D-9
   requires; it does not hold the tick that requested it. Gameplay still has
   no elapsed-time waits. A result already logically available can be consumed
   without crossing a tick boundary; asking to wait on a future result uses
   the explicit checkpoint contract. No automatic retry or rollback of plain
   Lua data/resource effects is introduced.

Alternative B requires each gameplay update/event to finish within one tick:
cooperative yields within that tick are allowed, but waits requiring a later
tick are refused. Async loading still works by requesting, returning and
checking readiness in a subsequent update/event. Long routines keep their
continuation state explicitly in Lua data rather than a suspended hook. B
makes hook completion the simpler transaction boundary, at the cost of more
author-written state machines; it narrows D-15's permitted gameplay suspension
to same-tick yielding. Presentation's elapsed waits are unaffected by either
choice.

A is recommended to retain useful multi-tick Lua routines while making the
atomicity limit explicit. Its cost is exposing a checkpoint authors must
understand, plus per-invocation completion evidence and tests in the generic
tick coordinator. It is not enough to reuse `awaitTicksComplete` alone. The
host already supports future waits and deterministic resumption; the sample
instead requires its particular `staging.finish()` and idle-instance proof.
This proposal deliberately replaces that sample-specific completion predicate
for the new store while retaining positive success evidence, whole-tick atomic
publication and failure accounting. Neither existing sample nor host is claimed
to implement this new checkpoint protocol. Initial-state construction and
individual-write rejection remain later checkpoints; slices remain unset.

### P-32. A rejected authoritative mutation fails the gameplay tick

**Later arc only: deferred by D-41. The original accepted contract follows.**

**Option A accepted by D-36.** An invalid attempt to
mutate authoritative state during a gameplay tick records a gameplay failure.
Examples include a wrong component value type, an out-of-range value, exceeding
a declared/store capacity limit, an invalid mutation target or a disallowed
state mutation. Exact target/reference validity, write permissions, limits and
operation semantics still need their own contracts; this selects what happens
when one of those checks rejects a mutation, not the checks themselves.

Reject the individual operation atomically, without partial application,
clamping or truncation (D-31). Also mark the tick failed, so none of its earlier
successful writes can commit. Catching the binding error in Lua, returning
normally or reaching a D-35 checkpoint cannot clear that recorded failure.
Stop gameplay under D-19/D-26, retaining its last good committed snapshot for
a healthy UI. Attribute the error to the game/mod instance and state operation,
with bounded entity/component/field information where available. This is a
script/state-contract failure; native engine/cleanup failures retain their
existing stronger handling and are not converted into recoverable write errors.

For example, in a single tick a purchase removes a coin, then adding the item
exceeds a state limit. A rejects the tick, so neither the coin subtraction nor
the item addition is published. It also stops gameplay: it does not roll back
and retry the purchase or silently keep playing. A failure in a later tick
still cannot undo a purchase committed earlier (D-35).

Ordinary game-rule outcomes, such as insufficient coins or a full authored
inventory, should be handled by Lua before attempting invalid state mutations.
They are not automatically engine failures merely because the game declines
an action. Queries and their missing-value/error results need a separate API
contract. A grants no implicit per-hook rollback, recoverable try-write variant,
preflight reservation, multi-operation subtransaction or automatic compensation.
Schema-registration failures remain D-32's boot failures; whether/how state
values are created during init remains the initial-state checkpoint.

Alternative B returns a structured refusal for an invalid mutation and permits
gameplay to continue. The refused operation changes nothing, but earlier
successful writes remain staged and can commit. Thus removing a coin and then
getting an item-add refusal may publish the coin removal unless Lua explicitly
handles it; a caught/ignored refusal alone does not reject the tick. B supports
expected stale targets and capacity failures without ending gameplay, but puts
recovery and consistency between separate writes on game/mod authors. It is
not an automatic rollback of the hook's earlier work, which other hooks may
already have observed under D-33/D-34.

A is recommended for the first generic-store contract: a violated mutation
contract cannot leave a tick looking successful merely because the Lua caller
ignored the error. Its cost is deliberately strict: even a stale-target or
capacity rejection ends gameplay, so authors must validate expected game
conditions and re-read state after suspension instead of using failed writes
as normal branching. Handling these refusals without ending gameplay would
require a later explicit API/atomicity design, not a silent exception to A.

Evidence: D-31 already requires atomic rejection but leaves escalation open;
D-33/D-35 define shared staged writes and tick commits. The lua-domains sample
returns recoverable `false` for its narrow staged-move refusal and leaves the
rest of its batch intact. A deliberately chooses a stricter policy for the new
generic launcher/store, requiring failure recording on rejected mutation paths
and commit/accounting checks even when Lua catches the error. No such generic
store policy is claimed implemented. Delivery slices remain unset.

### P-33. Entity references do not keep their targets alive

**Later arc only: deferred by D-41. The original accepted contract follows.**

**Option A accepted by D-37.** Entity references are
non-owning identities. Deleting an entity removes that entity and its components
from the working state, but does not delete other entities, clear their fields,
edit their lists/maps or refuse deletion because they refer to it. Such fields
can retain a reference whose target no longer exists. For example, an NPC can
be deleted while a quest still records it as its target; Lua decides whether
that means the quest failed, completed or needs a new target.

A valid current-session entity reference remains valid component data after
its target is deleted, so copying a record containing it is allowed. This is
different from using the deleted entity as the target of a mutation: that
mutation is invalid and fails the tick under D-36. Malformed or foreign-session
reference values do not become valid merely because missing targets are allowed.
The concrete representation, allocation bounds and validation encoding follow
separately; this is not a permission to inject arbitrary native handles.

Both options below include these identity/read guarantees:

- A reference never silently starts naming a different entity after deletion.
  A new entity has a distinct identity, even if physical storage is reused.
  References are scoped to the session; they are not stable save-file IDs.
  Allocator/reuse representation and save scope are separate decisions.
- Existence checks and optional component lookup let Lua handle a well-formed
  current-session reference to a deleted entity, or a missing component, as
  ordinary absence without failing gameplay. Exact result spelling is open;
  absence must be distinguishable from malformed input or engine failure.
  No placeholder entity/component is created by a read.
- Gameplay checks observe the current working state (D-33); UI checks observe
  its coherent committed snapshot. A UI snapshot from before deletion can
  still contain the entity. Gameplay must revalidate later UI intentions;
  this is not permission for UI commands to mutate stale state unchecked.
- Checking and acting without yielding avoids another gameplay hook intervening
  between those operations on the same VM (D-34). After any yield/checkpoint,
  Lua must re-check when its action depends on continued existence. Read
  results remain copies, not lifetime locks.

Alternative B enforces live-target relationships in stored component data:
writing a reference to a missing entity is invalid, and deleting an entity
while references from other surviving entities still point to it is refused
(therefore tick-fatal under D-36). Lua must clear/repoint those references
before deletion. B still does not cascade-delete or automatically rewrite
other entities. It requires incoming-reference tracking or bounded scanning
through nested records/lists/maps, and coordination across mods that hold
references. Copies in Lua locals or old UI snapshots cannot be protected by
that stored-state rule and still need existence checks.

A is recommended because game-defined relationships need different deletion
policies, and one mod retaining a reference should not automatically prevent
another from deleting an entity. Its cost is that schema-valid state can
contain missing targets: game/mod authors must handle absence and deliberately
clean up relationships when appropriate. The engine cannot infer ownership or
quest semantics from a reference field. This adds no implicit entity garbage
collection, native-resource ownership or cross-session persistence. Value-write
permissions and entity/component query ordering remain open.

Evidence: D-31 already distinguishes reference data from native leases but
leaves validity/deletion open. The lua-domains sample has a fixed entity set
and does not implement generic deletion or relationship tracking. Either
choice requires new store operations and read validation; no implementation
or delivery slice is claimed here.

### P-34. Trusted gameplay instances share state-write authority

**Later arc only: deferred by D-41. The original accepted contract follows.**

**Option A accepted by D-38.** The game's gameplay root
and every enabled gameplay mod instance receive the same generic state service.
During phases where state operations are allowed, they may read any entity/
component, create entities, attach/change/remove any registered component type,
and delete any entity, regardless of which game/mod declared the type or created
the entity. Deletion can therefore remove components contributed by other mods.
This selects authority, not exact operation spelling, mutation granularity or
the still-open initial-state/shutdown phase rules.

D-32's schema namespace identifies who defines the type and prevents foreign
registration, duplicate identities and schema replacement. It is not a private
data namespace or a runtime write lock. For example, a combat mod may update
the game's health component directly through the state service; the game may
read or change a weather mod's registered state. No per-entity creator ACL,
component-owner grant registry or foreign-type permission handshake is added.

The existing boundaries still apply: only gameplay mutates authoritative state;
presentation gets committed views and sends intentions. Module top level has
no world access (D-8). Content-only modules act through the calling gameplay
instance rather than acquiring their own state authority. Values must satisfy
the frozen schemas, reference/phase rules and limits; rejected writes still
fail the tick under D-36. Attribute effects/failures to the executing instance,
not automatically to the component's schema author. Native resources retain
their own instance ownership and capability rules; shared state authority does
not grant another instance's texture/window handles or OS functionality.

This makes the runtime-state consequence explicit alongside D-28: authored
definition/rule/UI extension points remain game-exposed Lua APIs, and content
paths/modules are not remapped. Runtime component data, however, is directly
modifiable through the common engine service without an extra game-provided
setter. The store enforces its data contract, not every game invariant. A
schema-valid write can still break the game's logic; a mod can bypass the
game's preferred helper convention or delete something another mod needs.
Trust, documentation and cooperative game APIs carry that responsibility.
Shared VM tables already preclude treating this as hostile-code isolation.

Alternative B adds engine-enforced state authority: creation/ownership and
schema namespaces determine default rights, and explicit grants or mediated
operations allow cross-owner changes. It can catch accidental edits outside
a mod's intended scope, but requires a separate design for grant/delegation
identity, deletion of entities carrying several owners' components, revocation
and game-extension callback authority. Choosing B would start that design;
it would not approve an unspecified ACL or claim to contain hostile Lua.

A is recommended for D-2's equally trusted game/mod scripts and the shared
gameplay VM. It keeps state access a narrow service without building a second
ownership/permission system around every record. Its cost is broad authority:
one gameplay mod can alter or delete another's valid state, and validation
cannot detect all semantic mistakes. D-34 supplies execution order but does
not resolve authors' competing intentions; exact overlapping-write semantics
and cooperative extension registration remain separate checkpoints.

Evidence: D-28 reserves state mutation to approved engine services; D-32
explicitly left value-write permissions open. The host has capability/grant
mechanisms for native services, but no generic entity/component ACL is claimed
implemented. This proposal selects the new store's access policy; delivery
slices remain unset.

### P-35. Write complete component values rather than nested mutation paths

**Later arc only: deferred by D-41. The original accepted contract follows.**

**Option A accepted by D-39.** Attaching a component
supplies its complete initial value; replacing an existing component supplies
its complete new value. Lua reads a copied component, edits that local copy
and submits it explicitly. The engine validates/copies the whole submitted
value and applies the individual operation atomically to the working state.
No field-path setters, list splice/append operations or map-entry mutation
bindings are included in the first store API. Those changes are expressed by
building and submitting the desired complete component value in Lua.

Replacement is not a merge. Omitted optional fields become absent; required
fields must still be present, and lists/maps have exactly the submitted
contents. There is no implicit deep merge, numeric accumulation or combination
of two authors' intentions. Schema/size/reference checks apply to the entire
replacement, and rejection fails the tick under D-36. Entity creation/deletion,
component removal and reads remain separate operations; exact signatures and
presence/duplicate rules are not selected by this granularity choice.

D-33/D-34 already make accepted writes visible in execution order, including
the health 9/8 example. A applies that existing rule to the whole component:
the later complete replacement is the resulting component value. An old copy
does not carry an implicit version precondition. For example, Lua reads
`{health = 10, armour = 2}` and yields; another mod writes armour 3. Resuming
and writing the old copy with health changed to 9 produces
`{health = 9, armour = 2}`. Both writes can be schema-valid; no automatic
conflict error restores armour 3. Re-read after suspension and perform the
read/edit/write sequence without yielding when it must use current values.
This is an authoring rule, not a lock on the whole tick or a guarantee of
game-rule correctness. Versions for UI intentions/digests and any explicit
conditional-write API still need separate scope decisions.

Alternative B includes typed field and container mutation operations from the
start: set a declared field, update a map entry or edit a list without replacing
unrelated values. Setting health would preserve armour without resubmitting it.
Overlapping writes still follow D-34's order; targeted writes do not magically
detect an outdated computed health value or give an entire hook a transaction.
B needs exact path validation, optional-record creation rules, list indexing/
insertion/removal semantics, map edits and budget accounting. It is more
convenient for large components and frequent small edits but expands the
binding and validation contract. Choosing B requires that follow-up design.

A is recommended for a small, explicit first API and D-31's bounded copied
values. Its costs are whole-value copy/validation work and the risk of stale
copies overwriting unrelated changes. Large inventories may be expensive to
rewrite; there is no performance claim or implied free copy. Authors can
choose smaller components where that fits their data. This choice concerns
Lua-facing operations, not the engine's physical storage layout or a full-world
copy each tick. There is no automatic diffing of Lua tables.

Evidence: the host supports typed copied records/lists but has no generic
component mutation interface. D-31 establishes bounded nested values and
D-33 establishes copied reads and explicit writes. Either option adds store
bindings; B adds a path/edit language beyond whole-value validation. No
delivery slices are selected yet.

### P-36. Queries return bounded, ordered copies of matching entity references

**Later arc only: deferred by D-41. The original accepted contract follows.**

**Option A accepted by D-40.** A query names a set of
required component types and returns a dense copied list of entity references
that have all of them when the call executes. An empty required set selects
all live entities. Return each matching entity once, in the engine's stable
total order of entity identities, never hash/storage traversal order. The
concrete ID representation and ordering encoding remain to be specified with
identity allocation. Query syntax is illustrative here; no Lua predicate
callback, joins, field-value expression language or sorted-by-field API is
included. Lua can read values and apply further game-specific filtering.

The list fixes membership at the query call; it does not freeze component
values or keep entities alive. New matches are absent until a new query.
Removed entities/components do not rewrite an already-returned list. For
example, querying two NPCs yields their two references; creating a third does
not add it, and deleting the second leaves its now-missing reference in that
list. Before acting on an entry whose existence/components may have changed,
Lua uses D-37's absence checks. Component reads observe the then-current
working state under D-33, and copies kept across yields can be stale.

Gameplay queries run against the current working state. Presentation queries
use its coherent committed view; they do not mix gameplay's staged values into
UI reads. How a presentation invocation acquires/refreshes that view remains
part of the snapshot API contract. The returned list is ordinary copied Lua
data, not a live iterator, store lock or engine resource that needs closing.

Query input/output and scanning work must be bounded by configured store/read
limits, whose values follow with the budget contract. These are deterministic
count/size/work bounds, not elapsed-time cutoffs. If the complete result
cannot fit the allowed query/read budget, return a structured read refusal
with no partial list; never silently truncate, choose an arbitrary subset or
pretend there were no matches. A valid query with no matches returns an empty
list. A read-budget refusal alone does not fail a gameplay tick: Lua may handle
it without any state having changed. This does not weaken D-36 for mutations
or turn engine failures into ordinary absence. Exact malformed-query errors
and result spelling remain part of the binding contract.

Alternative B adds a paged query cursor that freezes the matching ID set/order
and returns it in bounded pages. Like A, this need not freeze component values
or prevent deletion, and later additions do not join that existing result.
B reduces the Lua allocation needed at once for a large result, but still must
bound and retain engine-side query state, define cursor ownership/expiry and
cleanup, and settle resumption across ticks. It does not make arbitrarily large
queries free. Choosing B requires those cursor contracts before approval of
an API; neither option selects a live, mutation-sensitive traversal.

A is recommended as the first query surface because fixed ordered membership
is easy to reason about while modifying entities, and requires no new retained
cursor lifetime. Its costs are collecting/copying the entire matching reference
list and refusing results beyond the read budget. Component values are read
separately, so this does not copy every matching component into the query result.
Entity indexes and physical query implementation remain implementation choices;
there is no performance claim. Canonical map iteration and digest encoding are
separate deterministic-data contracts.

Evidence: D-30 selected entity/component presence queries but left order/bounds
open. The lua-domains sample enumerates its fixed entity world by index; it has
no generic schema query or paged cursor. This proposal adds that missing store
surface while using D-33/D-37's copied reads and non-owning identity rules.
Delivery slices remain unset.

### P-37. Build a private initial world during gameplay init

**Withdrawn by D-41; neither option accepted. Retained as design history only.**
The former recommendation was A: start gameplay initialization
with an empty, engine-owned initial working state. The game root and gameplay
mods may use the ordinary state read/query/mutation service in their finite
init hooks, alongside schema registration. They execute in D-25's existing
root-first/dependency order, and later initializers see earlier successful
writes. A component type must already have been registered before values of
that type can be attached. This does not reorder init or add a separate pass
that registers every schema before the game's root init.

For example, the game registers its health type and creates a player; a later
mod registers its own type and attaches it to that player. The game's init
cannot depend on that later mod's registration or initialization effects.
Work requiring all mods' effects still belongs after the startup gate, as
D-25 already requires. Whole-value replacement, non-owning references,
shared authority and bounded copied queries have their normal meanings in
this private initial state.

After gameplay initialization succeeds, freeze its schema catalog (D-32).
Only when D-18/D-25's joint startup gate succeeds for all required roots/mods
does the engine publish the complete initial world and frozen catalog together,
as state at **tick 0**, and allow gameplay ticks to begin. This publication
grants no logical duration and runs no update; the first normal grant is tick 1.
There is no partial publication after each initializer. The concurrently
running UI keeps the existing starting/not-ready view until this publication;
it cannot inspect or send gameplay work into the initial candidate.

Any rejected initial-state mutation records boot failure, even if Lua catches
the binding error, and prevents publication. A later gameplay or presentation
init failure, early UI failure or stop likewise discards the initial candidate
under the existing startup failure/gate rules. There is no previously committed
world to preserve on that path; stop/clean up both roles as D-18/D-25 require,
rather than switching to D-19's post-startup frozen-world error mode. Schema
and state validation must be accounted for before the atomic gate/publication
decision; late init success cannot reopen a failed gate. Lua tables and native
effects are not rolled back; engine-owned resources still require cleanup.

Init remains finite and cannot yield, checkpoint or wait for content. Assigned-
tick content results do not become visible early merely because their provider
finished during init. Use init for small starting records and request content
there when useful; build content-dependent or expensive worlds during normal
ticks, using D-35 checkpoints if appropriate. Tick 0 can therefore describe a
game-authored loading phase rather than a fully populated level. No detailed
gameplay-init progress channel is added to D-18. The game decides what its own
loading state means; engine startup readiness does not certify a playable level.
All initial state remains subject to the configured state/read limits.

Alternative B permits schema registration but no state-value mutation in init.
After the same startup gate, publish an empty tick-0 world; game/mod updates or
events then create entities using normal tick transactions. B keeps all value
mutation under one recurring tick path, but even a small starting world needs
post-startup orchestration and the UI must handle an initially empty world.
It does not remove ordered init or permit waiting in init.

A is recommended so small starting state can be assembled naturally in the
existing initialization chain while the first public world is coherent. Its
cost is an explicit boot transaction/failure path in addition to recurring
tick commits, plus the temptation for authors to put too much work in finite
init. Keep init short; the runtime-loading/checkpoint design is the better
place for substantial asynchronous generation. Shutdown state access remains
a separate lifecycle decision. Presentation-only sessions still have no
authoritative store, and gameplay-only sessions use their own startup gate.

Evidence: D-18/D-25 already require a coherent initial publication after the
startup gate, D-32 freezes schemas before it, and D-8/D-15 allow finite
effectful init. Those decisions left initial value construction open. The
sample starts with a Haskell-created world; this proposal adds generic Lua
initial-state construction without changing the host's non-yielding init.
Delivery slices remain unset.

### P-38. Reconcile the runtime with the service-only milestone

**All six parts accepted by D-42.** D-41 selects no state store. The following
package and audit specify the approved milestone interpretation of the earlier
runtime decisions. The original recommendation and its tradeoffs are retained.

1. **A logical Lua owner, not a simulation store.** Keep D-14's manifest roles,
   default pair and one-role variants. The existing `gameplay` role name means
   the logical-clock Lua VM in this milestone: it runs the game's/mods' hooks,
   ordinary Lua code and the non-state services later explicitly granted to
   that role. Its ticks advance scheduler time, determine update cadence/`dt`,
   wake logical waits and deliver assigned content results. They do not create,
   validate, commit or publish game data. Keep D-16's required fixed positive
   tick duration and D-17's cadence rules. No logical time accrues during boot.
   The presentation role remains elapsed-time based; gameplay-only remains
   headless, presentation-only is sufficient for a service/graphics example.
   No substitute gameplay data model, game rules or Lua-state persistence is
   designed. Ordinary locals/`self`/module tables remain ordinary Lua data.
2. **Scheduling and content, without transactions.** Keep D-9/D-12's async
   providers, pending/success/failure results and assigned delivery for the
   logical owner; a late required result holds its due tick while presentation
   progresses. Presentation uses its existing arrival/elapsed delivery. Use
   the host's fixed FIFO policy, equal ordinary class for root/mod hooks and
   stable root/dependency/ID admission; D-42 approves reuse of that mechanism
   for this milestone without reactivating deferred D-34. Use ordinary
   host yielding and future-tick/result waits, with the existing one-active-
   invocation/cadence rules. No D-35 checkpoint acknowledgement or per-hook
   transaction proof exists. A tick's scheduler completion does not claim
   successful world commit; there is no world commit. Supervision still
   accounts for task/instance failures and resource retirement, and stops
   grants when failure/stop is recorded; runtime completion is not cleanup
   completion. No input-command/replay queue is added under this wording.
3. **Status-only startup and cross-role observation.** Keep D-18/D-25's
   concurrent roots, role-local mod-init order, early UI and joint logical-
   owner start gate. Publish starting/role-ready/running/failure/ending status,
   not an initial world, catalog or tick-0 state snapshot. Remove not-ready
   world reads: state calls use D-41's unavailable exit before and after boot.
   No gameplay intentions, authoritative snapshot channel or arbitrary Lua
   data/message bus replaces the store in this milestone. Runtime status and
   session stop are sufficient for the loading/error screen; detailed init
   progress remains excluded. Generic runtime control bindings, if any beyond
   quit, need explicit service-scope approval and may not smuggle game commands
   back in. No direct cross-VM calls/shared Lua tables are introduced.
4. **Failure means stop the owner, not restore state.** For ordinary post-boot
   logical-root/mod failures, keep D-19/D-26's healthy UI continuation, bounded
   role/mod-attributed error, refused new logical work, no retry and failure
   exit outcome. Remove promises of a last committed/frozen world, discarded
   state transaction or rollback. Effects already performed are not undone;
   the UI renders using its own still-valid resources and state, with no
   guarantee that the engine freezes the last picture. UI failures, boot
   failures and fatal engine/provider/cleanup failures retain their existing
   session-ending policies. Resource teardown remains protected, and status
   must not claim it is finished while work/GPU retirement is outstanding.
5. **Unavailable-state call: report and end the whole session.** Honor D-41
   from either VM and any call context, including init/module evaluation,
   update/events or shutdown: report `state service not available in this
   milestone` and request terminal whole-session shutdown. Recommend stderr
   (D-20 diagnostic convention) and orderly exit code 1 after engine-owned
   cleanup. Catching a Lua error cannot cancel the terminal request. Unlike an
   ordinary logical script error, this ends even a healthy UI because the
   owner explicitly said exit. Do not call an immediate process-exit primitive
   that bypasses protected native cleanup; D-20's second-signal force exit stays
   the explicit exception. Make repeated calls while stopping idempotent and
   retain the first diagnostic, without recursively restarting shutdown.
   This is a small unavailable-service boundary, not implementation of the
   deferred entity/schema/query API. Its exact exposed spelling belongs to
   the service API decision; there is no fake empty store or successful no-op.
6. **Narrow guarantees and remaining work.** Preserve the existing host's
   conditional logical scheduling/result-order guarantees and failure/resource
   accounting. Do not claim deterministic game-state evolution, canonical
   world digests, saved initial worlds, transaction checkpoints or a replay
   product. Prior Lua D-23/D-47/D-48 and the sample remain intact as repository
   contracts/evidence; their state-commit applications belong to the later arc.
   Time/randomness binding details remain Q-6; this proposal adds no new seeded
   world RNG/replay subsystem. Renderer scene data, coherent service messages
   and native resource bookkeeping remain service responsibilities; removing
   the gameplay store does not remove those safety boundaries. Move straight
   to the milestone's service surface,
   exact vision/#145 reconciliation, outstanding boot/content/mod API choices,
   hot-swap scope and dependency-ordered delivery after this signoff. No more
   gameplay-state design checkpoints or state acceptance tests in this arc.

The tradeoff in retaining the logical owner is explicit: the milestone still
has two clock kinds, manifest tick validation and assigned-result scheduling,
even though it has no simulated world or cross-VM gameplay data. That preserves
earlier boot/mod decisions and uses delivered host mechanisms. If the owner
wants a presentation-only milestone instead, revise parts 1–3 and the dependent
manifest/mod contracts before recording a new decision; do not guess that the
scope cut implicitly removed the logical VM. The default pair is a recommendation
here, accepted by D-42 rather than derived from the absence of a store. The
presentation-only milestone alternative was offered and not chosen.

#### Exhaustive earlier-decision audit

All D-1 through D-40 were checked, including the proposals they accepted. The
table identifies direct store dependencies and adjacent contracts whose meaning
could otherwise be misleading. **D-42 accepts every replacement below;
D-41's deferrals and unavailable-state behavior remain in force.**

| Decisions | Store dependency or affected wording | Proposed milestone interpretation |
| --- | --- | --- |
| D-1, D-3 | Broad Lua game orchestration and engine-held authoritative data. | D-1 motivates the service interface; D-3's store/commit application is deferred. No gameplay system is a milestone deliverable. |
| D-8 | World/state access described as an allowed hook effect. | Hooks remain the ownership boundary for available services; they never make state available. The unavailable guard applies at top level too (part 5). |
| D-9, D-12 | Runtime loads described as gameplay/room work with tick-assigned results. | Content loads are service requests. Retain logical result scheduling and optional data/texture failures without a transaction or room model (parts 1–2). |
| D-14 / P-10 | Logical gameplay role; UI snapshots/intentions; one-role variants. | Keep role/clock/default choices as scheduling only; remove store views/intentions, retain runtime status, no replacement message bus (parts 1, 3). |
| D-15 | State initialization left open under lifecycle hooks. | D-41 keeps hooks and makes every state call unavailable/terminal. Ordinary yielding hooks can orchestrate available services; no state checkpoint (parts 2, 5). |
| D-16, D-17 | Tick duration/cadence justified partly by simulation and commit semantics; rendering consumes presentation data. | Keep scheduler time and `dt`, not a simulation contract; remove state-transaction rationale. Existing busy-instance cadence and renderer-owned scene publication remain (parts 1–2, 6). |
| D-18 / P-14 | Not-ready gameplay reads, initial coherent world, intentions/controls at startup. | Status-only early UI/joint gate; no initial world and state calls exit at all phases. No gameplay-intention API (part 3). |
| D-19 / P-15 | Last committed state, frozen UI world, discard/commit cutoff. | Healthy UI handles a logical-owner error status with its own resources; no state rollback/frozen-world promise. Account for shutdown without inventing a commit (part 4). |
| D-20 | Error/quit/forced-exit outcomes; state failure was one diagnostic case. | Keep existing codes/streams/signals; propose unavailable-state stderr + terminal orderly exit 1, including healthy UI (part 5). |
| D-23, D-24 | Mods contribute gameplay/presentation roles and share role VMs. | Keep owned instances and role validation against the retained clocks; a gameplay contribution runs logical hooks, not a game-state system (parts 1–2). |
| D-25 / P-21 | Joint gate publishes initial gameplay view; world generation after mod init. | Retain activation gates/order and partial UI initialization; publish runtime status only. Remove world-generation/store obligations and examples as milestone work (part 3). |
| D-26 / P-22 | Gameplay-mod failure preserves last good state. | Same status-only logical failure policy as root; preserve mod attribution, remove state restoration (part 4). |
| D-27 / P-23 | Shutdown may outlive/observe failure; could imply state cleanup. | Keep self-contained native/resource cleanup and UI continuation for ordinary logical failure. No state-read/write teardown service; calls invoke part 5. |
| D-28 / P-24 | Game extension APIs plus authoritative state services. | Retain explicit Lua extension points/no file remapping for service-facing content; remove working state service. No generic game-rule framework is added. |
| D-29 | API revisions, with save/state compatibility mentioned as separate work. | Keep manifest API revision checks; no state/save schema versioning in this milestone. |
| D-30, D-31, D-32 | Entities, component values and init-time schema registration. | Deferred in full by D-41; no empty catalog, schema-registration-only substitute or generic store. |
| D-33 | Shared staged state and atomic public snapshots. | Deferred in full; runtime/native effects are not a transaction (parts 3–4). |
| D-34 | FIFO policy selected in the shared-store discussion. | Deferred in full as instructed; part 2 explicitly proposes reusing only host FIFO/admission for this milestone. |
| D-35 | Future waits acknowledge per-tick state contribution/commit eligibility. | Deferred in full; use host waits with no checkpoint, commit or rollback implication (part 2). |
| D-36 | Rejected mutation poisons tick even if caught. | Deferred in full; no mutation API. Part 5's terminal unavailable-service rule is a separate scope guard, not a failed transaction. |
| D-37, D-38, D-39, D-40 | Entity references, shared write authority, whole components, queries. | Deferred in full, including their read/refusal APIs; no placeholder reference/query surface. |
| Prior Lua D-23/D-47/D-48; current evidence/verification | Deterministic state, commit fences/cutoff and sample digests/replay. | Keep delivered host guarantees/accounting; no new world/replay/commit acceptance. Exact narrower validation follows approved services (part 6). |
| D-2, D-4–D-7, D-10, D-11, D-13, D-21, D-22 | No working-store dependency. | Trust/filtering, session/design process, roots/imports, fingerprints/no links, folder manifest, explicit mods and dependency order remain. D-10's hot-swap interest stays open; state migration is not silently brought into scope. |

P-37 and Q-5l are withdrawn; no tick-0 initial-state protocol survives from
that proposal. Q-5a–Q-5k and P-26–P-36 are later-arc history. Q-8/Q-9 and the
verification/goal text above now reflect D-41's scope; their remaining exact
reconciliation and acceptance choices still need approval. This audit changes
only this design document, not the old Lua design, vision, sample or tracker.

### P-39. Presentation owns window, input and 2D graphics bindings

**On hold by the 19:38:08 owner rescope relay; no answer recorded.**
The former recommendation was A: expose the milestone's
window, native input, 2D scene/layer/sprite and GPU texture services to presentation
root/mod instances. Both VM roles get scoped module/data loading, diagnostics/
authored output, their own clock/waits, session status and orderly session quit.
The state-service boundary exists only to report unavailability and exit under
D-42. No game-state/input-intention service is added.

| Service family | Logical (`gameplay`) role | Presentation role |
| --- | --- | --- |
| Scoped Lua module imports and data-file requests | Available; logical assigned results where asynchronous | Available; arrival/elapsed result delivery |
| Logging/print, role-appropriate time/waits, session status/quit | Available | Available |
| Windows and window controls | Refused | Available |
| Native keyboard/pointer/text/window input | Refused | Available through bounded copied feeds/events |
| 2D scenes, layers, sprites and scene publication | Refused | Available |
| Texture loading/registration and texture leases | Refused | Available through scoped content loading and protected GPU services |
| Gameplay state | Unavailable diagnostic and terminal exit | Unavailable diagnostic and terminal exit |

This intentionally narrows D-9's earlier role-neutral texture-load wording:
logical hooks can load modules and data, but cannot request texture leases in
this milestone. D-12's optional texture loads remain available to presentation.
The logical-only arrangement stays headless. There is no implicit forwarding
of input, textures or scene commands between VMs, and D-42 adds no message bus.
Logical code therefore cannot preload a texture for UI or drive a window by
proxy. Presentation Lua itself orchestrates those services, including during
logical-owner startup or after an ordinary logical-owner failure.

Role grants are checked before a native action. A wrong-role call is a refused
capability/script error, not a successful no-op or a route through the other
VM; ordinary caught/uncaught Lua error rules apply. Only the state-service
stub has D-42's unconditional terminal behavior. Namespace/function spelling,
precise errors, service limits and individual controls follow with their API
contracts; this proposal selects available families and ownership boundaries.

Lua initiates work through narrow bindings; Haskell retains the process main-
thread GLFW loop, native callback capture, graphics owner, validation and
protected lifetime/retirement. Native callbacks never call arbitrary Lua on
the GLFW thread. GPU completion remains distinct from CPU hook return, and
texture/window leases belong to the acquiring presentation instance. Same-VM
module tables do not transfer ownership merely by retaining a handle. Sharing
resources between presentation instances still needs an explicit binding
contract. The engine does not expose raw native pointers or a universal engine
environment. These are service and resource boundaries, not gameplay concepts.

Alternative B allows logical hooks to acquire/use graphics and native input
too, with commands routed to the appropriate Haskell owner. That would require
an explicit revision of D-42's headless logical-only arrangement, logical input
assignment and graphics-result timing, plus rules for competing role writers.
It does not require Lua to run on the native thread, but it expands the role/
ordering contract. Choosing B would trigger that concrete revision before
recording a new decision; it is not already authorized by the earlier generic
word "services".

A is recommended to keep graphics/input on the responsive presentation side
and preserve the approved headless variant without a new cross-VM protocol.
Its authoring cost is role-specific scripts: logical modules/data examples
cannot also act as window/input/texture examples. It limits where services
are available, not what game rules Lua may express privately. Exact window
controls/close policy, input consumption, scene/texture sharing and Lua UI
scope follow next; 3D/audio are not introduced here.

Evidence: the delivered GLFW service uses main-thread ownership, bounded
input feeds and narrow command ports; the 2D renderer consumes published
per-window scenes on its graphics owner. The image2d sample composes these
services in Haskell. This proposal selects their new Lua-role grants, not a
claim that these bindings already exist. Delivery slices remain unset.

### P-40. Milestone 1: a textured quad over durable Lua/service components

**All six parts accepted by D-43.** The original owner direction and manager
suggestions are preserved below, followed by the now-approved scope package,
per-decision delivery tags and acceptance requirements.

#### Owner direction and provenance

Owner rescope direction reported at **2026-10-21 19:38:08 UTC** in the manager's
pane, verbatim:

> ok, to me the milestone 1 that i had in my head was the one i dot for all my graphics projects, that is, a textured quad in a rendered window. here what i was thinking was that the game vm would be a stub, and the ui vm would draw the quad. so there are also a bunch of other things we would need to design for this milestone, but we dont need to do it yet, just finish the epic, then move on to the next, adding design as we go. right? do you have any suggestions for me here?

After the manager suggested tagging decisions by milestone and limiting current
questions to milestone 1, the owner replied, verbatim:

> ok yes, help me rescope, i was happy with the way we were digging in depth into the lua, i dont want it to just be 'only what the milestone 1 needs', it should be structured to be as complex as it needs to be to accomplish the limited task, but not so simple as to not capture behavior that we need in the component to build upon, that's why i was concerned when you were getting into gameplay, but i still wanted the ecs, we could use it to define the quad, but then you convinced me out of that idea and i think youre right, we can omit that, but the mods? our system needs to be designed with the mod model in mind, but not implement mods yet, just make sure we remember the ownership and timing requrements of the different lua scripts. what do you think?

Authenticated relay: `het-manager`, message `p4h88gp8yi6mxmgn5bkygzufg2`,
posted **2026-10-21 19:38:08.399 UTC** in `#het-luafirst`, replying to held Q-6a
message `69mzs6as8k7gaxfmuwtyuz2rue`. Separate times for the two owner replies
were not supplied. The relay is also retained at
`~/.local/state/project-manager/hetoimasia/request-user-het-luafirst-20261021-1435-rescope-relay.txt`.

The manager proposed a game folder/manifest, real filtered dual-VM runtime,
UI texture loading and quad submission, root/instance identity, real clocks,
ownership/failure rules, deferred mod features and a two-instance test. These
are proposals incorporated into the package below, not additional owner
decisions. The earlier ECS recommendation and its later deferral remain in
the record; this revision neither reintroduces the ECS for scene data nor
rewrites who recommended it.

#### 1. Concrete milestone and observable acceptance

Milestone 1 is complete when a supplied game content folder and declarative
manifest launch filtered Lua, a **real logical VM running stub content**, and
a UI VM which displays a visibly textured quad in a real rendered window.
Lua specifies the texture reference and quad/scene; Haskell does not hard-code
that demonstration in the executable or import its game content. The quad is
renderer scene data, not an ECS entity or substitute gameplay store.

The UI initializer **requests** a texture through the real scoped loader and
returns without waiting; an update handles readiness and submits the textured
quad through the existing 2D renderer's scene-publication boundary. The engine
renders on its independent cadence, not by calling Lua per render frame.
Window/texture readiness and failure must be real, not a sleep or a successful
placeholder. Exact window/scene bindings are remaining M1 design, not silently
fixed by this example. The UI can use a labeled test texture; no production
art approval is implied.

The logical content has no gameplay rules, world or application data model.
It may use no-op hooks; qualification fixtures exercise its fixed ticks,
cadence, ordinary waits and assigned module/data result delivery. The logical
VM/owner is not a dummy object, fake timer, skipped lifecycle or mocked result
provider in the shipped composition. Keep D-14's accepted role-aware manifest
and one-role capabilities; the primary milestone demonstration uses both roles.
Keeping those capabilities does not change the two-VM acceptance into a
presentation-only milestone or invent additional/custom VM support.

Acceptance includes observable rendering evidence (an offscreen pixel check
through the corresponding production texture/scene path, plus an explicit
native-window demonstration/capture), orderly quit and failure behavior,
and the two-instance qualification in part 4. A console-only success cannot
prove the quad. Closing the demonstration's window requests orderly session
quit; keep native resize/framebuffer handling safe. Broader multi-window close
policy and generalized keyboard/pointer/text bindings are later presentation
work, not prerequisites to this quad. Exact commands/evidence and the bounded
window API are fixed with the M1 slices, using existing native qualification
and protected retirement rules.

#### 2. Real components, with the mod model built into their boundaries

Build and qualify these as reusable service components, not demo-specific
shortcuts:

- Content identity is `(content root, relative module/asset path)` with stable
  game ID and diagnostics. M1 enables the game root only; the registry/resolver
  and interfaces take explicit root identities rather than assuming every
  resource belongs to one global folder. Relative and explicitly game-qualified
  references work; unknown/not-enabled roots are refused. No mod discovery,
  second enabled mod root or implicit search/override tree is shipped.
- Filter libraries before Lua evaluation; preserve D-7 module identity/cache,
  hooks-only acquisition, fingerprint/change refusal, no-symlink confinement
  to the content root, async pending/result delivery, optional data/texture
  failures, bounds and cancellation. M1 uses real providers and real data
  validation/cleanup paths. It need not preload every future resource at boot.
- Instances are the unit of hook context, request/lease ownership, source/role
  attribution and cleanup. The game root is one instance per role, not a
  privileged implementation shortcut. No singleton "current game script"
  resource bucket or root-only failure path. Adding a mod later must reuse
  these boundaries; its admission/manifest/dependency features are still real
  future work, not claimed to be solved merely by having instances.
- Retain D-42's genuine logical/elapsed clocks, manifest tick validation,
  cadence, FIFO ready ordering, stable instance admission, ordinary waits,
  concurrent root startup, early UI and the status-only joint gate. There is
  no mod-init chain to execute yet; no state commit/checkpoint or message bus.
- Apply failure policy by role and executing instance: ordinary logical
  failures stop logical work while healthy UI can report failure; UI/boot/
  fatal engine failures end the session. Preserve finite hooks, self-contained
  shutdown, engine-owned request/lease cleanup, native main-thread ownership,
  GPU-safe retirement, diagnostic attribution, exit outcomes and forced-signal
  exception. A state-service call retains D-42's diagnostic and terminal exit.

The presentation/error fixture can indicate status with its quad and console
diagnostics. M1 does not require a font renderer or widget toolkit to prove
that a healthy UI can observe a logical failure.

#### 3. Designed later, not implemented or continually questioned now

Do not implement mod launch selection, mod manifests, dependency resolution,
mod role admission/compatibility, game/mod API revision matching, extension
registration or replacement hooks in M1. Preserve D-21/D-22/D-24/D-28/D-29 and
the mod-specific halves of D-23/D-25/D-26 as later-arc design decisions. They
remain owner-approved inputs to that arc, not erased choices or a claim that
the later design is finished. Its still-open API/conflict questions are asked
when that milestone is designed. M1 rejects unsupported mod declarations/options
rather than silently accepting them or pretending to activate a mod.

The game manifest still carries content identity, entry/role routing and timing
needed by M1; it does not need game/mod compatibility machinery merely because
D-29 described it. Manifest-format validation is still real M1 work. Lua module
imports and shared exports are available, without an engine extension registry.

Hot-swap is `L-RELOAD`: retain the owner's interest and D-10's restart-to-use-edits
policy, without a watcher, migration or replacement implementation. No hot-swap
scope question blocks M1 readiness. The ECS/store decisions remain `L-STATE`
under D-41; no gameplay concepts, save system, world digest or replay product
are a prerequisite. General input, text/widgets, advanced presentation controls,
3D and audio belong to later presentation/service arcs unless an explicit M1
component requirement is identified and approved. Do not expand this milestone
just to exhaust every feature of the existing Haskell libraries.

#### 4. Required two-instance test through the new composition

Use **two real Lua instances from the one game root in the same VM**, admitted
by a test harness through the same instance construction, content attribution
and binding/ownership layer used by the launcher. This is not a public Lua
spawn API or a hidden mod loader. It must exercise the new integration, not
merely rerun an existing scheduler unit test and infer that the bindings work.

Prove independent `self`/holdings, shared module behavior where promised,
stable admission and FIFO yield/resume ordering, and instance-specific request,
resource and diagnostic attribution. Each instance acquires its own resource
or pending request. A normal test-controlled ending cancels/releases only its
own holdings and waits for actual provider retirement; the peer's live holdings
remain usable unless the role-level failure policy intentionally ends it too.
An injected failure names the correct root/module/role/instance, triggers the
approved role escalation, and cleans up every affected instance's holdings
without double release or false completion.

Use controlled providers/leases at native boundaries and explicit gates to
vary completion order, with real Lua and the real integration code; no timing
sleeps to prove order. Separate native graphics evidence still proves actual
texture/GPU retirement and rendered output. A same-root test proves multiple
script owners, not mod discovery, multi-root activation, dependency graphs or
all future resource-sharing semantics. Those remain honest later obligations.

#### 5. Per-decision delivery allocation (accepted by D-43)

`M1` is the textured-quad milestone. `L-MODS`, `L-STATE`, `L-RELOAD` and
`L-PRESENTATION` name future work areas; they do not assign milestone numbers,
epics or ordering. Split tags identify the exact part built now. The same
approved tag is attached to every D-entry for readers arriving directly there.

| Decision | Approved delivery | What delivers now / what stays later |
| --- | --- | --- |
| D-1 | M1 + later arcs | Lua authors the quad/service orchestration now; broad game features later. |
| D-2 | M1 | Same trusted script model and its limits. |
| D-3 | L-STATE | Engine-held gameplay state remains deferred. |
| D-4 | M1 process | Finish this design to M1 readiness; later arcs get later design passes. |
| D-5 | M1 | Complete approved filtered-library profile. |
| D-6 | M1 foundation / L-MODS activation | Real root-qualified identity and one enabled game root; enabling mod roots later. |
| D-7 | M1 | Once-per-VM module loading, shared exports and failed-import/cycle contract. |
| D-8 | M1 | Hooks-only acquisition and instance context; no working state service. |
| D-9 | M1 | Real async runtime content providers and result timing; D-44 narrows texture grants to presentation. |
| D-10 | M1 / L-RELOAD | Fingerprint/refuse/restart now; deliberate hot-swap later. |
| D-11 | M1 | Root/file validation and no symlinks. |
| D-12 | M1 | Required/optional result policy, bounded failures and cancellation. |
| D-13 | M1 / L-MODS | Game folder/manifest/content ID now; mod manifests later. |
| D-14 | M1 | Real dual-role default, role/entry/clock validation and accepted one-role capabilities; demo uses the pair. |
| D-15 | M1 | Real instance hooks and unavailable-state boundary. |
| D-16 | M1 | Exact fixed manifest logical tick duration. |
| D-17 | M1 | Real logical/elapsed cadence, independent renderer. |
| D-18 | M1 | Concurrent roots, early UI, status-only joint gate and races. |
| D-19 | M1 | Logical failure/healthy-UI behavior as revised by D-42, no frozen world. |
| D-20 | M1 | Quit, exit codes, diagnostic streams and signal policy. |
| D-21 | L-MODS | Explicit mod-list activation; M1 enables base game only. |
| D-22 | L-MODS | Dependency graph/ID tie-breaking; no fake empty graph feature now. |
| D-23 | M1 foundation / L-MODS activation | Per-instance ownership/role attribution and two-instance test now; mod admission later. |
| D-24 | L-MODS | Mod role declarations/required-role checks, not game VM configuration. |
| D-25 | M1 root gates / L-MODS chains | Root startup sequencing now; dependency-ordered mod init and its mixed-role cases later. |
| D-26 | M1 failure mechanism / L-MODS admission | Generic instance/role escalation and attribution tested now; actual mod launch/failure fixture later. |
| D-27 | M1 | Independent ownership/cleanup without shutdown-order reliance. |
| D-28 | L-MODS | Mod extension registration/replacement APIs later; no content remapping is introduced now. |
| D-29 | L-MODS | Game/mod API revision compatibility; M1 still validates its manifest format. |
| D-30 | L-STATE | Entities/components. |
| D-31 | L-STATE | Component schema/value types. |
| D-32 | L-STATE | State schema registration. |
| D-33 | L-STATE | Shared staged state. |
| D-34 | L-STATE | Stored-state scheduling decision remains deferred; host FIFO is separately approved by D-42 for M1. |
| D-35 | L-STATE | State checkpoint waits, not ordinary host waits. |
| D-36 | L-STATE | Rejected state mutations. |
| D-37 | L-STATE | Entity references. |
| D-38 | L-STATE | State-write authority. |
| D-39 | L-STATE | Component replacements. |
| D-40 | L-STATE | Entity queries. |
| D-41 | M1 scope / L-STATE history | No store; unavailable guard in M1; preserve future state decisions. |
| D-42 | M1 runtime / L-MODS features | Real clocks/status/failures/exit now; previous mod implementation breadth narrows as above. |

#### 6. Process, remaining decisions and recommendation

Keep the depth of design where M1 components need it: file safety and identity,
module/instance boundaries, async readiness/cancellation, window/texture/scene
ownership, clocks, startup/failure races, shutdown and error reporting. Do not
equate a small visible result with weak error/lifetime contracts. Reuse the
delivered host/GLFW/renderer mechanisms rather than build parallel schedulers
or a demo-only global environment.

With scope approved, reframe/re-ask Q-6a for **M1 service grants only** if needed;
its original proposal was not accepted by these owner remarks. Then settle the
M1 manifest/entry and binding details, window/texture/scene lifecycle, close/
failure behavior and acceptance, followed by exact vision/#145 reconciliation
and dependency-ordered one-PR slices. Do not wait to finish mod/gameplay/UI-
toolkit/hot-swap design before marking this epic ready. Do not file or implement
anything during this design session; process-design-doc and reviews remain
separate on manager instruction.

Recommend this allocation. It proves the owner's intended quad milestone with
real reusable boundaries, while preserving the decisions needed for later mod
work. Its cost is more than a graphics demo: real async loaders, dual-clock
failure/cleanup behavior, instance-safe bindings and integration tests must be
delivered. Its limit is equally explicit: the two-instance test and root-aware
types do not mean mod support is implemented, and successful rendering does not
prove a gameplay store. A more limited throwaway launcher would postpone the
very ownership/timing problems the owner wants solved; implementing all mod
features now would exceed the requested milestone. Neither is recommended.

### P-41. M1 graphics bindings belong to presentation instances

**A accepted by D-44 through Q-6a revision 2. Delivery: M1.**
This replaces the held P-39 question with the scope D-43 actually approved.
Recommend A: presentation instances get the M1 window, texture-load/lease and
2D scene-publication bindings. Both roles get scoped module/data loading,
logging/print, their own clocks/waits, runtime status and orderly session quit.
Native close/resize handling needed by the quad remains engine-serviced.
No general keyboard/pointer/text input API, widget system, advanced window
controls or mod-activation API is part of this selection.

The demonstration's logical script is a stub, but the role's services are
real and qualified: logical module/data requests use assigned result ticks,
and ordinary waits/cadence/FIFO work as D-42 requires. Presentation texture
requests settle through its arrival/elapsed runtime; Lua submits a scene only
after required resources are ready. This does not give init permission to wait
or turn an update into a render-frame callback. Exact readiness/result syntax,
window/scene shape and safe sharing between instances are subsequent M1 API
contracts, not an invitation to design gameplay or mods now.

A expressly narrows D-9's original role-neutral texture loading: logical
instances cannot request texture leases in M1, even in a two-role session.
They can load modules/data. There is no implicit forwarding, cross-VM texture
handle sharing or new message bus. The UI owns its texture/window work; a
logical-only launch remains headless. This role grant applies to any instance
constructed by the integration, including P-40's two-instance test, rather
than special-casing the one demonstration root.

Wrong-role graphics calls are refused before native action under ordinary
Lua capability/error rules; they are not silent no-ops. D-42's state-service
boundary remains the separate unconditional diagnostic-and-exit case. Available
service handles keep their acquiring instance's ownership; retaining a handle
in a shared module table alone does not grant ownership or transfer lifetime.
Haskell retains the GLFW main thread, graphics owner, bounded command/result
paths and protected CPU/GPU retirement. Lua receives narrow service bindings,
not native pointers or a universal engine environment.

Alternative B grants the M1 window/texture/scene surface to logical instances
as well. It would require explicitly revising the accepted headless logical-
only contract and designing logical graphics command/result timing and role
writer coordination. It adds no general input or mod scope, but broadens the
M1 binding contract beyond the UI-driven quad. If chosen, present that revised
contract for signoff before recording it; original Q-6a did not approve it.

A is recommended because the approved demonstration and independent-UI failure
path already put visible services in presentation. Its cost is deliberate
role separation: a logical script cannot preload a UI texture or drive its
window by proxy, and no such bridge is promised in M1. The two-instance test
can exercise separate presentation resource owners without granting graphics
to the logical role. Existing native services remain reusable independently
of these launcher-specific Lua grants.

Evidence remains the delivered GLFW/2D/texture service boundaries described
under P-39 and the image2d sample. This is a role-grant proposal, not a claim
that the M1 bindings are delivered. General input/advanced presentation parts
of P-39 are later work under D-43, not carried into this revised question.

### P-42. Lua requests a window asynchronously and owns the resulting lease

**Unapproved; active checkpoint Q-6b. Delivery: M1.** Recommend A: a presentation
hook requests a window with a title and initial logical dimensions. The engine
validates the request and reserves bounded per-instance capacity before queuing
native work. The call returns a pending request without waiting for GLFW or GPU
setup; `init` can return, and a later update can observe success or failure.
Exact names, limits and the request/result API are subsequent binding details.
This is real Lua-driven creation, not a Haskell demo window opened unconditionally.

The main thread creates the native window, and the graphics owner establishes
its protected attachment. Success exposes an opaque, instance-owned window
lease only after that setup is complete and scene publication can be accepted.
It does not promise that a frame has been presented or that a minimized/zero-
framebuffer window can currently draw. Rendering and native resize handling
remain independent; readiness is not a render-frame callback. An empty window
may be visible while the texture loads. Texture readiness and scene contents
are separate contracts, not extra prerequisites for window success.

Window creation is required in M1: failure fails the requesting operation under
the approved role/boot failure policy, with instance attribution. There is no
optional-window fallback or automatic retry. Invalid arguments are refused
before native work. A pending request and any partial native acquisition remain
engine-owned even if Lua loses the request, the instance ends or the session
stops. Cancellation prevents delivery of a new usable lease; any late creation
is retired through the protected path. It must never leak a window or report
cleanup complete merely because cancellation was requested. CPU scope exit
does not establish GPU retirement.

The resulting lease follows the existing host rule: it belongs to the acquiring
instance, and a shared module table cannot transfer it to another instance or
extend its lifetime. Closing the demonstration window requests orderly session
quit as D-43 already requires. This question does not add multiple-window
policy, advanced window controls, general input, a public instance-spawn API or
cross-instance window borrowing; exact supported window counts/control surface
remain to be fixed in the M1 API contract.

Alternative B: the launcher creates a window from manifest settings before
presentation hooks and gives the UI instance its lease; Lua loads the texture
and publishes scenes but does not request creation in M1. This reduces the new
asynchronous window-request surface, at the cost of moving window orchestration
into the launcher and requiring a later API extension for Lua-created windows.
A is recommended because it exercises the ownership, cancellation and readiness
boundary needed by the reusable Lua integration. Its cost is real pending-window
machinery and testing stop/failure races, beyond the small visible quad.

Evidence: [instance leases](../../packages/scripting-lua/README.md#instance-leases)
already refuse use/release through another instance and retain cleanup without
Lua cooperation. [Window lifetime](../archive/window_graphics_lifetime_design.md)
requires main-thread native handling and verified graphics retirement. The
[image2d sample](../../samples/image2d/README.md#the-windowed-mode) composes window
adoption and scene publication in Haskell. These are mechanisms to reuse;
the asynchronous Lua window binding proposed here is not already delivered.

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
Keep prior Lua D-27 cleanup independent of successful Lua shutdown.

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

Resolved by D-16: require an explicit positive gameplay tick duration in the
manifest and keep it fixed until restart, with no numeric default. Instance
cadence, presentation timing and transaction suspension rules are separate.

#### Q-3d. Does root update cadence live with the Lua behavior or in the manifest?

Resolved by D-17: P-13 option A, Lua behavior metadata, with the shared rules
recorded there. `every` is an illustrative name only. Additional routines,
state-transaction waits and exact field spellings remain separate choices.

#### Q-3e. How do concurrently initializing roots enter normal execution?

Owner response, **2026-10-21 15:52:01 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> both start at the same time, if game finishes first, then we wait, if ui finishes first, then we start ui. we write ui not to rely on any game init work. i want this so that we can set up the loading screen and run game init during that, unless you think i should do this someother way

Authenticated relay: `het-manager`, message `jekfp3ijixjajaqrmnfm56ux2s`,
posted **2026-10-21 15:52:02.047 UTC** in `#het-luafirst`, replying to original
Q-3e message `acx2n5b76r2gcnc4are4buuh8e`. The owner selected neither serial
option and invited advice. Preserve this as direction for the revision, not
approval of the added startup/error protocol.

Resolved by D-18: all five parts of P-14 revision 2 approved at
**2026-10-21 15:59:37 UTC**, relay `mtzmhhh2j6kibwqscp53uiyqe2`.
The owner did not select the extra progress-channel alternative.

#### Q-3f. May healthy UI continue after a gameplay root fails at runtime?

Resolved by D-19: keep healthy presentation after gameplay failure until exit;
presentation failure ends the session. Exact diagnostics/exit codes and
child/mod policy follow.

#### Q-3g. Reuse console outcomes with a second-signal forced-exit escape?

Resolved by D-20: P-16 option A, console outcomes/reporting and a forced
second-signal exit. Manifest/CLI spelling, native close requests and diagnostic
field spellings remain separate.

### Q-4. How are mods discovered, ordered and combined?

**L-MODS under D-43.** Preserve these decisions and open details for that arc;
mod activation/compatibility/extension design does not block M1. M1 implements
the root/instance/clock/failure foundations identified in P-40, not a mod loader.

Settle selection, dependency/load order, conflicts, replacement and override
scope, attribution of a mod's failure, and the point at which the content set
is fixed. Trust does not itself define these behaviors.

#### Q-4a. Explicitly enable selected mod folders or automatically discover them?

Resolved by D-21: an explicit launch-time list, no mods by default, validated
identities and a fixed session set. CLI field spellings remain illustrative;
profiles and a selector are later design possibilities.

#### Q-4b. Required-dependency ordering alone or optional before/after hints too?

Resolved by D-22: required dependency IDs only, deterministic dependency-first
order, stable ID ties and pre-Lua cycle refusal. Compatibility, activation
lifecycle, cross-VM composition and overrides remain separate decisions.
Q-7b is next because activation needs an instance/VM ownership model first.

#### Q-4c. Must every declared mod role exist in the game's VM arrangement?

Resolved by D-24: explicit contributions, all declared roles required, and
explicit content-only mods. Entry/format details and activation/dependency
readiness follow.

#### Q-4d. How do root and mod initialization compose with early UI?

Resolved by D-25: all five parts of P-21 option A and its authoring costs.
Cross-role dependency readiness is not promised. Runtime mod failure escalation
and teardown ordering follow separately.

#### Q-4e. Does an unhandled mod-instance failure fail its role like a root?

Resolved by D-26: apply D-19's role failure policy to mod instances, with no
recoverability flag or automatic disable-and-continue.

#### Q-4f. May shutdown depend on a particular mod/root teardown order?

Resolved by D-27: self-contained hooks with no relative ordering guarantee.
Engine-owned lifetime/retirement guarantees apply independently of hook order.

#### Q-4g. Game-defined replacement APIs or an engine content-remapping facility?

Resolved by D-28: explicit Lua game extension APIs, without engine file/module
remapping in this arc. Registration/conflict handling and callback ownership
remain further design work; arbitrary shared-table mutations are not policed.

#### Q-4h. Exact game/mod API revisions or accepted revision ranges?

Resolved by D-29: exact declared game/mod API revisions and the shared
target-game/game-independent compatibility contract. Extension registration,
conflicts and callback ownership will be revisited with the state/service
design, rather than treating Q-4 as fully resolved.

### Q-5. What generic engine state does Lua define and mutate?

**Deferred in full by D-41.** Q-5a through Q-5k preserve the later arc's decision
history below; they are not current milestone requirements or active questions.
The following original agenda is retained only for that future arc.

Settle entities/components versus tables/schemas, validation, stable identity,
read visibility while staging, atomic tick commit, bounded capacity and
failure. Carry prior Lua D-23 and D-47/D-48's exact guarantees into this store. Settle
whether saves and schema migration are excluded or included; Q-10 separately
records the owner's interest in script hot-swapping;
game-specific save semantics remain game-owned under the existing rules.

#### Q-5a. Entity/component state or generic named records?

Resolved by D-30 after the manager's explanation and the owner's explicit
choice. Exact values, schema registration, identity/query rules and transaction
behavior remain separate decisions; no physical storage layout is selected.

#### Q-5b. Bounded nested data or flat scalar/reference components only?

Resolved by D-31: bounded typed records/lists/text-key maps and P-27's base
types/exclusions. Exact budgets, reference lifetime, transaction rejection
handling and digest/query ordering follow separately.

#### Q-5c. Freeze the schema catalog after init or permit runtime additions?

Resolved by D-32: register namespaced schemas during gameplay init, then freeze.
Runtime loads use existing types; a new type needs a new session. Value-write
permissions and extension conflicts remain separate from schema ownership.

#### Q-5d. Do gameplay reads see earlier writes in the same tick?

Resolved by D-33: shared working state with immediate visibility to later
gameplay reads; UI sees committed snapshots only. Exact execution/conflict
order, cross-tick suspension, initial state construction and individual-write
rejection policy follow separately.

#### Q-5e. Fixed FIFO gameplay scheduling or authored per-tick phases?

Resolved by D-34: fixed FIFO gameplay policy, stable root/mod admission and
yielding to already-ready work. This does not guarantee whole-hook completion
order. Input assignment and transaction completion follow separately.

#### Q-5f. Explicit cross-tick checkpoints or hooks completed within one tick?

Resolved by D-35: explicit successful contribution checkpoints before future-
tick waits. Earlier writes may commit while the hook remains suspended; a later
failure cannot undo earlier committed ticks. Whole-tick publication and positive
completion/failure accounting remain required.

#### Q-5g. Does a rejected state mutation fail the tick or permit recovery?

Resolved by D-36: record a gameplay failure and discard the tick even if Lua
catches the rejected mutation's error. Invalid/stale targets and capacity
rejections are included; exact validation and query APIs follow.

#### Q-5h. May stored entity references outlive their targets?

Resolved by D-37: non-owning references may remain after deletion, with Lua
handling absence. No silent identity retargeting, automatic clearing or cascade.
Exact representation, access permissions and persistence remain separate.

#### Q-5i. Shared gameplay state authority or engine-enforced owner permissions?

Resolved by D-38: all trusted gameplay instances share state authority,
including entity deletion across component authors. Schema namespaces do not
restrict value writes; schema validity does not prove game-rule correctness.

#### Q-5j. Whole-component replacement or typed field/container edits?

Resolved by D-39: complete component values with no implicit merge/version
check or nested edits. Authors bear whole-value copy/validation costs and must
avoid writing stale copies over intervening changes.

#### Q-5k. Copied entity-query lists or retained paged query cursors?

Resolved by D-40: complete bounded lists with fixed membership and stable
identity order. Component values are read separately; targets are not retained.
Read-budget refusals return no partial result and do not by themselves fail a tick.

#### Q-5l. May gameplay init populate the initial world?

Withdrawn by D-41. The owner chose to defer the entire store rather than either
initial-world option. Do not continue this question in the current milestone.

### Q-6. Which services and UI behavior does Lua drive in this arc?

Under D-43, settle M1 window/texture/2D scene bindings, time, diagnostics,
readiness, lifecycle and native close/resize behavior. General input, text/
widgets, advanced presentation, 3D/audio are later work. Haskell retains native
threading and GPU lifetime obligations; M1 needs concrete safe boundaries.

#### Q-6a. Are graphics/input services presentation-only or available to both roles?

The original P-39 question was held at 19:38:08 UTC and remains unanswered.
Revision 2/P-41 is resolved by D-44: UI VM only, expressly narrowing D-9's
texture grants. Both roles retain module/data/runtime services. No general
input or mod API is included; B (graphics in both VMs) was not chosen.

#### Q-6b. Does Lua request its window asynchronously or receive one from the launcher?

**Active checkpoint, P-42.** A (recommended): a presentation hook requests a
window, returns without waiting, and later receives its instance-owned lease
after native/graphics setup; required failure and protected cancellation apply.
B: manifest/launcher-created window handed to UI, with Lua creation deferred.
This selects creation/readiness/ownership behavior, not advanced window features.

### Q-7. What is the default domain arrangement for games and mods?

D-14's game VM options and D-42's real clocks are M1. Actual mod-role admission
is L-MODS under D-43; the two-instance M1 qualification proves reusable ownership,
not mod activation. No new/custom owner topology is required by the quad.

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
Startup order is now settled by D-18. Additional owners, mod mapping and
remaining lifecycle details stay open.

#### Q-7b. Do mods use separate instances in the existing role VMs?

Resolved by D-23: primary instances per contributed mod role in the existing
gameplay/presentation VMs. Shared-module state and execution are explicit
costs. Q-4c now addresses role declarations; startup integration and mod failure
escalation follow.

### Q-8. How should the prior vision and Lua epic be reconciled?

The manager proposes that V-9 and Q-5 cease to require confined processes for
trusted mods, and LUA-9–13/16/17 cease to be required for that purpose, while
LUA-14/LUA-15 verdicts remain historical evidence. The manager also reads V-1
as making the Lua game the application with engine-held generic state. D-41 now
defers that store: propose milestone wording about Lua consuming engine services
without gameplay-state implementation, preserving the later-arc direction.
These are proposals to present as exact reconciliation text for owner signoff.
Do not edit `docs/vision.md`, the old design or #145 in this session. Decide
the new arc's relationship to #145 before readiness or tracker processing.

### Q-9. What is the accepted delivery order and final scope?

D-43/P-40 settles M1's quad outcome, evidence and deferred areas. Fix remaining
M1 API contracts, exact acceptance commands and prerequisite order, then split
into one-PR outcomes. Mod features, state, generalized input and hot-swap do not
block this epic. Identify verification, compatibility and explicit deferrals
for each M1 slice; do not invent persistence/migration work outside its scope.

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
must explicitly reconcile D-7/D-10 where it changes them. D-43 places that
discussion and implementation in L-RELOAD; neither blocks the M1 delivery plan.
No later milestone number or hot-swap implementation is selected merely from
this interest, and D-10 remains M1's restart-to-use-edits policy.

### Q-11. Approve the service-only runtime reconciliation?

Resolved by D-42: all six parts of P-38 and its audit are accepted. The owner
was offered a presentation-only milestone and did not choose it. Continue
Q-6, Q-8, Q-9 and remaining milestone APIs, not the deferred Q-5 state agenda.

### Q-12. Approve the milestone-1 scope, delivery tags and acceptance?

Resolved by D-43: all six P-40 parts, acceptance and delivery tags approved.
The original Q-6a remains unanswered; its M1-only revision 2/P-41 is resolved
by D-44.

## Verification strategy

D-43 accepts P-40's M1 acceptance boundary and two-instance qualification.
Mod features and general input are not acceptance requirements for the quad.

Existing constraints to preserve: focused Hspec suites selected by the
validation catalog; coordinated failure/concurrency checks without timing
sleeps; Linux CI and local macOS evidence; native consent scoped to the
qualifying command. A headless success proves no displayed result.

Proposed acceptance families, to refine after owner decisions: forbidden
library and alternate-reference checks; content-root refusal and attribution;
boot/init/shutdown failures with engine-held cleanup; independent UI progress;
two-instance ownership/ordering/attribution; Lua-authored rendered output checked by offscreen
pixels and explicit windowed evidence. No new performance, hostile-code
containment or cross-platform determinism claim is proposed.

D-41 removes generic-store canonical-state, commit/discard, checkpoint and
state-replay acceptance from this milestone. D-42 accepts P-38's narrower scheduler/
result-order checks, status-only failure handling and the unavailable-state
exit probe. Exact acceptance commands follow the service/slice decisions.
Existing sample tests/contracts
remain historical/current repository behavior, not new milestone deliverables.

## Delivery plan

D-43 makes this document's eventual epic and `LFE-N` slices M1-only.
Later design areas remain recorded here for continuity, without blocking the
M1 epic or being silently scheduled inside it. P-40 records the approved allocation.

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
