# Lua-first engine design

Make Lua the authoring and orchestration surface over generic engine services.
**Approved scope (D-43): milestone 1 is a Lua-driven textured
quad in a rendered window, with a real logical runtime running stub content;
mod-aware foundations without mod activation; no ECS/gameplay store.**
This document carries request `user-het-luafirst-20261021-1435`.

Design state: `ready for issue processing`

Owner repository: `coghex/hetoimasia`; publication branch: `master`.
Started 2026-10-21 by `het-designer-1`. Questions and owner-answer relays belong
in `#het-luafirst`. Only owner signoff turns a proposal into a decision.
D-81 records explicit manager readiness signoff under D-78's owner grant.
P-76/Q-9 is approved with D-80's LFE-13/LFE-26 split and lifecycle-review
requirements. Processing begins with the M1-only epic, then one child per
invocation in ledger order; each complete artifact needs manager approval.
D-79 confirms P-75/Q-8's wording and authorizes the narrow vision/prior-design
publication; the manager owns #145 and MEMORY follow-up.
D-77 accepts the six-part fixed M1 ceilings and worker-accounting package.
D-76 accepts the six-part remaining service API and record-schema package.
D-75 accepts the five-part core Lua module/behavior/request API package.
D-74 accepts the five-part concrete launch-command and JSON manifest package.
D-73 defers Lua window-size reads and resize callbacks from M1.
D-72 accepts an idempotent whole-session quit request that returns normally.
D-71 accepts bounded print/warn output without a separate Lua logging API.
D-70 accepts UI-only polling of copied session status sampled per segment.
D-69 defers engine randomness and removes standard RNG calls in both M1 VMs.
D-68 accepts role-specific clocks and cooperative waits with sampled UI time.
D-67 accepts logical request tick offsets and earliest shared-module evaluation.
D-66 accepts opaque sRGB byte backgrounds and checked fractional rectangles.
D-65 accepts static PNG colour textures with one level and no animation/options.
D-64 accepts hard-linked files and mounted subtrees with per-path identity.
D-63 accepts resolving the launch path once and retaining the actual root owner.
D-62 accepts whole-folder startup hashing and exact-byte verification on loads.
D-61 accepts Unicode NFC filename identity, exact case and collision rejection.
D-60 accepts literal root-relative paths without shortcuts or filename search.
D-59 accepts pre-admission module-limit refusal and required dependency-limit failure.
D-58 accepts one import chain per VM and queued-dependency evaluation timing.
D-57 accepts VM-owned shared module jobs with per-instance waiters.
D-56 accepts resumable module-level imports and explicit loading from hooks.
D-55 accepts bounded byte-for-byte data-file results.
D-54 accepts one-shot request results with explicit terminal consumption.
D-53 accepts recoverable busy admission with atomic reservations.
D-52 accepts required failure escalation at eligible settlement.
D-51 accepts one window slot per UI instance and the M1 close/control policy.
D-50 accepts the clear-colour and ordered texture-rectangle scene surface.
D-49 accepts independent texture loads without a shared texture cache.
D-48 accepts explicit texture release and pending-load cancellation.
D-47 accepts one texture request through usable GPU readiness.
D-46 accepts copied scenes and protected texture retention.
D-45 accepts Lua-requested asynchronous window creation.
D-44 resolves Q-6a revision 2 with UI-only graphics; the original broader
Q-6a was not answered. D-43 accepts P-40's scope and delivery tags; D-42
supplies the runtime contract within that M1 boundary.
This document is not authority to implement or file issues.

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Draw a textured quad from Lua over reusable engine services — [#514]
- [x] LFE-1. Install the explicit filtered M1 library profile — [#515]
- [x] LFE-2. Add opt-in recoverable binding validation and refusal — [#516]
- [x] LFE-3. Parse the strict manifest and validate the fixed M1 profile — [#517]
- [x] LFE-4. Own anchored native content roots and no-follow reads — [#518]
- [x] LFE-5. Validate literal Unicode content identities — [#519]
- [x] LFE-6. Build and verify the bounded whole-folder inventory — [#520]
- [x] LFE-7. Reserve M1 requests and results atomically — [#521]
- [x] LFE-8. Retain VM-local module exports and captured behaviors — [#522]
- [x] LFE-9. Resume ordered module import chains on their VM owner — [#523]
- [x] LFE-10. Load raw data through owned bounded file workers — [#524]
- [x] LFE-11. Join shared module jobs and deliver them at assigned positions — [#525]
- [x] LFE-12. Bind per-instance content, request, time and output APIs — [#526]
- [x] LFE-13. Coordinate role startup gates, failure policy and session stop — [#527]
- [x] LFE-26. Expose UI status, quit and the unavailable-state guard — [#528]
- [x] LFE-14. Preflight static PNG structure and bounded inflation — [#529]
- [x] LFE-15. Decode the approved PNG variants within accounted workspace — [#530]
- [x] LFE-16. Own texture pipeline lanes, leases and byte reservations — [#531]
- [x] LFE-17. Finish texture requests through real GPU readiness — [#532]
- [x] LFE-18. Create and retire instance-owned windows asynchronously — [#533]
- [ ] LFE-19. Validate and copy the fixed M1 scene schema
- [ ] LFE-20. Publish scenes with completion-safe texture retention
- [ ] LFE-21. Expose the complete UI-only graphics facade
- [ ] LFE-22. Assemble the generic run command and Lua quad content
- [ ] LFE-23. Qualify integrated failure and two-instance ownership headlessly
- [ ] LFE-24. Verify Lua-authored output through offscreen pixels
- [ ] LFE-25. Qualify native windows, independent retirement and quit

The twenty-six LFE slices below have manager process signoff under D-80;
they are not approved issues or implementation authorization. Q-8 is confirmed
by D-79; the manager owns the #145 tracker mutation. Ledger revision D-80
inserts new LFE-26 after LFE-13, preserving LFE-14–LFE-25 IDs and their order.

## Epic contract

- **Goal:** a game folder/manifest starts filtered Lua, a real logical runtime
  with stub content, and UI Lua drawing a textured quad in a rendered window.
  Root identity, per-instance ownership, timing, loading and failure behavior
  are reusable foundations; mod activation and gameplay state are later work.
- **Done when:** P-40's acceptance is met: actual textured output with offscreen
  and native-window evidence, real async/lifecycle/error behavior, orderly quit,
  and the two-instance integration test through the new bindings/composition.
  D-74–D-77 settle commands, APIs and bounds; D-80 settles one-PR boundaries.
  A state call reports unavailability and ends the session through protected
  cleanup.
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
- Read-only reconciliation refresh on **2026-10-22**: #145 remains open,
  titled "Establish isolated UI and gameplay Lua execution", last updated
  2026-10-21 14:28:03 UTC. Its body records LUA-8/#500 delivered and accepted
  but still says all thirty-one children and successful confinement on both
  platforms are required. Its seven unfiled process-branch slices remain
  unchecked. #500 is closed; the only open issues remain #145 and #446.
  P-75 proposes an explicit scope revision, not a claim that the old completion
  condition has been met. No new overlapping Lua-first epic was found.
- Final read-only readiness refresh, **2026-10-22**, after publication
  `7c3a67caef`: #145 is closed under the confirmed title "Establish trusted UI
  and gameplay Lua execution" (closed 05:32:13 UTC); its body preserves the
  completed/deferred split and no longer requires all thirty-one deliveries.
  The manager also completed the separate MEMORY reconciliation, PR #513,
  merged at `aa378b04d38298320121a2a56751dcca4e511e85` (05:36:41 UTC).
  The only open issue is #446; there is no overlapping open M1 epic. The
  designer made neither tracker nor MEMORY mutation. Vision and prior-design
  reconciliation, this plan and D-79/D-80 are published at `7c3a67caef`.

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
whose designs do not block M1. D-74–D-77 settle the concrete M1 interface and
bounds; D-79/D-80 settle vision/epic reconciliation and delivery order.
D-42's runtime reconciliation applies
within D-43's delivery allocation; earlier broader scope is historical.

This session normally changes only this design. D-79 grants one narrow
exception: apply the confirmed P-75 wording/status reconciliation to vision
and the prior Lua design and land those documents. Production code, tracker
mutations, MEMORY changes, review and issue processing remain outside this
designer's authorized work. The manager owns those separately. No subagents
are used.

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

### D-45. Lua requests its window without waiting in init

**Delivery:** M1.

Owner answer, **2026-10-21 20:35:57 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: Lua requests it (Rec.)

Authenticated relay: `het-manager`, message `85rqwhtvh547qbimeeu5k6pzrn`,
posted **2026-10-21 20:35:57.477 UTC** in `#het-luafirst`, replying to Q-6b
message `yaigtrzxnueepz5q75c325864i`.

Accept P-42's A: a UI hook requests a window with title and initial logical
size and receives a pending request. A later update observes success/failure;
success supplies that instance's window lease after native/graphics setup can
accept scenes, not after a frame is displayed. An empty window may be visible
while a texture loads. Creation is required, without optional fallback or
automatic retry. Cancellation, partial/late acquisition and instance/session
ending use protected cleanup with no false retirement claim. Existing
per-instance lease ownership applies; the demo window's close requests orderly
session quit under D-43.

The manager presented the pending-window machinery and race-test cost. The
owner chose A rather than manifest/launcher-created windows. Exact API spelling,
limits, window counts and the remaining scene/texture contracts remain open.

### D-46. Publish copied scenes with atomic replacement and protected holds

**Delivery:** M1.

Owner answer, **2026-10-21 22:09:12 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: copied scenes (Rec.)

Authenticated relay: `het-manager`, message `m4wbgg9uvpve3ftwhfr73z953i`,
posted **2026-10-21 22:09:12.667 UTC** in `#het-luafirst`, replying to Q-6c
message `4gxisg374bz7by7cprxs5jnhma`.

Accept P-43's A: Lua publishes a plain scene table to its own ready window.
The binding copies and validates the whole bounded scene before atomic
replacement; editing the source table afterwards has no effect until another
publication. A static quad is published once, and independent rendering uses
the latest complete scene without promising every publication is displayed.
Invalid scenes or unavailable texture references refuse the whole call and
preserve the previous published scene, with the error/failure distinction in
P-43. Protected publication/release barriers and revision holds keep textures
alive through actual rendering/GPU use without extending released Lua handles.

The manager presented the whole-scene copy cost. The owner chose A rather than
engine-owned mutable scene objects. Scene fields, numeric limits and the
remaining texture/request APIs are not selected by this answer.

### D-47. One texture request succeeds with a usable GPU resource

**Delivery:** M1.

Owner answer, **2026-10-22 00:04:31 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: one ready request (Rec.)

Authenticated relay: `het-manager`, message `quyia79czkkka7f6e3zmfu8vua`,
posted **2026-10-22 00:04:31.441 UTC** in `#het-luafirst`, replying to Q-6d
message `vcm8cygnnkbv5kc5deh6tsvz7a`.

Accept P-44's A: one pending request covers fingerprint-checked reading,
decoding, completed GPU upload and renderer registration. Success delivers a
usable per-instance texture lease and image dimensions. Loading can progress
before any window exists, so init requests window and texture independently
and Lua publishes after both succeed. The required/optional rules cover the
whole request; cancellation suppresses delivery and retains safe cleanup,
including actual retirement after an already-started upload.

The manager presented the cost: success waits for GPU readiness, without a
separate decoded image or Lua-selected upload timing. The owner chose A rather
than separate decode/upload operations. This does not choose format/options,
cache sharing, explicit release or exact request API spelling.

### D-48. Lua may release its textures and cancel its pending texture loads

**Delivery:** M1.

Owner answer, **2026-10-22 00:10:37 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: explicit release (Rec.)

Authenticated relay: `het-manager`, message `f4rjxykas9bjpazypfjbfyetje`,
posted **2026-10-22 00:10:37.857 UTC** in `#het-luafirst`, replying to Q-6e
message `ti5rpmk3gztru4kfny79x5vur6`.

Accept P-45's A: Lua may relinquish its own texture lease or cancel its pending
texture load while the instance runs. A released handle cannot enter new scenes;
an already-published scene keeps its texture until replaced or its window ends.
Release does not wait for the GPU and distinguishes completed retirement,
retirement pending and already released. Repetition never runs cleanup twice;
engine-owned automatic cleanup and retained capacity/retirement remain mandatory.

Cancellation withdraws interest without itself becoming a required-load failure.
Presentation's first settlement wins: an already settled result remains, and
cancellation cannot erase a required failure. Partial/late work still retires
safely. The manager presented the race-machinery cost and the need for authors
to replace a scene to let go of its holds. The owner chose A rather than no
early release in M1. This does not select shared backing, public window-close
controls, module cancellation or exact API spelling.

### D-49. M1 texture requests load independent resources

**Delivery:** M1; shared texture backing deferred.

Owner answer, **2026-10-22 00:14:50 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: independent (Rec.)

Authenticated relay: `het-manager`, message `u7rcyesfjkkg6kn93p9gngt9n2`,
posted **2026-10-22 00:14:50.351 UTC** in `#het-luafirst`, replying to Q-6f
message `v4ifgav754ibeb95a36qksssda`.

Accept P-46's A: each new request reads/verifies, decodes and uploads its own
texture resource, even for the same path. An instance reuses a live lease
across sprites/publications without loading per quad. Requests and resources
remain independent across instances; there is no content-keyed resident or
in-flight texture cache. Shared renderer/device infrastructure is unchanged.
Every new load checks its bytes against the startup fingerprint, while an
already-loaded texture remains original.

The manager presented the duplicate-work/memory cost and preserving interfaces
for later sharing. The owner chose independent loads rather than shared backing.
The two-instance integration test loads the same path for both instances and
proves ending one leaves the other's resource usable, subject to the approved
role-failure policy. This does not change D-7's separate module-cache contract.

### D-50. M1 scenes contain a clear colour and ordered texture rectangles

**Delivery:** M1; richer Lua rendering controls deferred.

Owner answer, **2026-10-22 00:20:21 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: texture rectangles (Rec.)

Authenticated relay: `het-manager`, message `n9up9bwtak3asnsbp69rwr7fie`,
posted **2026-10-22 00:20:21.504 UTC** in `#het-luafirst`, replying to Q-6g
message `xkjjkq8vqf5najdjphvpk4md26`.

Accept P-47's A: a clear colour and ordered sprite list, each sprite naming a
ready texture and destination rectangle, showing its whole image. Later sprites
draw over earlier ones with the existing alpha-blending contract; an empty
list clears. UI logical pixels start at the top left, with content scale applied
and the full-window view adapting to resize without stretching authored layout.
Zero framebuffer size suspends drawing safely. Use full-image UVs, white tint,
nearest filtering and P-47's other fixed settings; the richer Lua camera,
transform, crop, tint/filter, animation/material and target controls stay out
of M1. Existing Haskell renderer capabilities remain intact.

The owner chose A rather than a broader renderer subset. The manager presented
overlap, clearing and resizing qualification in addition to the quad demo.
Exact field spelling, colour encoding and numeric budgets remain API work.

### D-51. M1 gives each UI instance one window slot

**Delivery:** M1; independent window close/reopen and broader controls deferred.

Owner answer, **2026-10-22 00:22:47 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: one per instance (Rec.)

Authenticated relay: `het-manager`, message `mxfacka4eux3xmdg7dpjp8itp2`,
posted **2026-10-22 00:22:47.710 UTC** in `#het-luafirst`, replying to Q-6h
message `8ssuyqtgfhsi9iuusdkdiqsgxw`.

Accept P-48's A and shared rules: one pending/live/retiring window slot per UI
instance, not one global window. A second request is a Lua error before native
work. Pending creation is cancellable, first settlement wins, and the slot is
reusable only after actual retirement. A successful window remains until
instance end or session quit; M1 has no independent close/reopen operation.
The visible/decorated/resizable window and limited Lua controls follow P-48.
Native user close requests orderly whole-session quit, including during startup;
cleanup destruction does not itself synthesize a quit for a healthy peer.

The manager presented the shared rules, no-second-preview/tool-window cost and
listed qualification. The owner chose A rather than several windows per
instance. The reusable Haskell host retains its broader capabilities.

### D-52. A required asynchronous failure takes effect without a result read

**Delivery:** M1.

Owner answer, **2026-10-22 00:25:28 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: fail when settled (Rec.)

Authenticated relay: `het-manager`, message `4et2a2k94yscdyw2sd3gch6vq2`,
posted **2026-10-22 00:25:28.304 UTC** in `#het-luafirst`, replying to Q-6i
message `rgjnxp479s88y669ddpevewds6`.

Accept P-49's A: a failed required request latches attributed instance failure
at eligible settlement even if Lua never reads it. Ignoring the handle or
catching an inspection error cannot clear it. Apply it at the next safe
scheduler boundary, not by preempting a non-yielding Lua segment. Presentation
settles on arrival; logical results remain held until their assigned tick and
sequence. The existing role/boot escalation and protected cleanup apply.

Cancellation that wins prevents required failure; a later cancellation cannot
erase an already settled failure. Optional content failures retain their
separate result behavior. The manager presented the cost: speculative work
must be optional or cancelled before failure settles. The owner chose A rather
than failure only when Lua reads the result. Pre-admission capacity refusal
and exact result APIs remain separate contracts.

### D-53. Full admission capacity returns busy without accepting work

**Delivery:** M1; new safe admission facility required.

Owner answer, **2026-10-22 00:29:45 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: return busy (Rec.)

Authenticated relay: `het-manager`, message `ihrfmmas8726shkrqsvm46rpri`,
posted **2026-10-22 00:29:45.444 UTC** in `#het-luafirst`, replying to Q-6j
message `ja2n5udw5yg7v8np3iamq9szi6`.

Accept P-50's A: reserve request and necessary result-lease capacity atomically
before acceptance. If full, return a bounded busy reason with no handle, no
provider/native work and no partial reservation. This does not fail the
instance, even for a required load, because no request was accepted. Lua may
pace requests in later updates; there is no hidden retry queue. Retiring work
continues to count, and D-52 applies to failures after acceptance.

The manager presented the extra result to handle and atomic-reservation cost.
The owner chose A rather than current-host fault-on-full behavior. P-50's
distinction from permanent invalid requests and native/engine/cleanup failures
remains; this is not a blanket conversion of host faults to busy. Numeric
budgets and the exact public result shape remain API work.

### D-54. Consume each accepted request result once

**Delivery:** M1.

Owner answer, **2026-10-22 00:56:04 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: take once (Rec.)

Authenticated relay: `het-manager`, message `2p4yvv5bptcvdzmq3f8q7xd2kw`,
posted **2026-10-22 00:56:04.216 UTC** in `#het-luafirst`, replying to Q-6k
message `f6jg35gjwt3c6k7w2xieneekkn`.

Accept P-51's A: ready checks without consuming; take reports pending without
consuming, then returns a terminal result once and ends the request handle.
Wait suspends cooperatively without taking and is forbidden in init/shutdown.
Only the requesting instance uses the request; consumed/foreign-handle use
retains the host call-fault behavior. Taking a successful result does not
release its resource lease. Capacity frees only after terminal consumption
and provider retirement, with automatic cleanup of uncollected results at
instance/session end. Required-failure timing and busy admission stay as decided.

The manager presented the authoring cost of taking every terminal result,
including cancellations. The owner chose A rather than a repeat-readable
result object with a dispose lifetime. Module exports are not one-shot request
results; their import/cache contract remains separate.

### D-55. Data requests return the complete file as raw bytes

**Delivery:** M1.

Owner answer, **2026-10-22 01:07:29 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: raw bytes (Rec.)

Authenticated relay: `het-manager`, message `c4fgs7znbngtniwmkthk2fwgbw`,
posted **2026-10-22 01:07:29.856 UTC** in `#het-luafirst`, replying to Q-6l
message `gv3t6dxq7ncarze6qibve7j5w2`.

Accept P-52's A: the whole file as a bounded Lua byte string, without decoding,
normalization, parsing or execution. Each request reads and fingerprint-checks
its own bytes; no data cache, stream or open-file handle is exposed. Oversized
content fails under required/optional rules instead of truncating. Returned
strings have ordinary Lua lifetime; native files/buffers retire through the
provider, preserving request accounting and cleanup.

The manager presented the own-parser/repeated-I/O cost and illustrated parsing
with a shipped Lua JSON/CSV library. That example does not select a library or
add an engine-shipped parser deliverable. The owner chose raw bytes rather
than engine-parsed data. Script loading remains a separate controlled path.

### D-56. Module dependencies are imported in Lua through a resumable loader

**Delivery:** M1; new protected module-loader integration required.

Owner answer, **2026-10-22 01:12:14 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: import() in Lua (Rec.)

Authenticated relay: `het-manager`, message `zhh9gu5dvr35qwehaezfc55yxe`,
posted **2026-10-22 01:12:14.896 UTC** in `#het-luafirst`, replying to Q-2h
message `aarj3fyhazh9iu5z6b48r8fsiw`.

Accept P-53's A: dependencies are discovered through imports in Lua, without
a separate dependency list. During engine-managed module evaluation an import
may suspend the loader and resume with completed exports. Entries and their
dependencies finish before init under the boot gate. Hooks can get already-
loaded modules immediately; uncached modules require an explicit asynchronous
request and later use. Init may request but never wait; an immediate uncached
hook lookup is refused.

Logical runtime evaluation respects its assigned service position, holding
progress there when dependencies are late; protected VM-owner evaluation,
D-7's once/cache/cycle/failure rules and D-8's top-level effect limits remain.
The manager presented the resumable-loader/scheduling cost and the fact that
a non-yielding module may still hang its VM. The owner chose imports in Lua
rather than a declared dependency list. D-57 subsequently settles shared-load
ownership/cancellation and D-58 evaluation order; limits and exact module API remain open.

### D-57. A module job belongs to its VM and outlives cancelled waiters

**Delivery:** M1; bounded per-VM loader ownership and per-instance subscriptions.

Owner answer, **2026-10-22 01:19:19 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: VM finishes it (Rec.)

Authenticated relay: `het-manager`, message `ey9cchg738u6df4s5tgrgf2fzn`,
posted **2026-10-22 01:19:19.578 UTC** in `#het-luafirst`, replying to Q-2i
message `pxqdpe764z7n4r3gqaj8pnxemi`.

Accept P-54's A: one shared module job per root/path per VM, with per-instance
waiters. Cancelling a request or ending an instance removes only its waiter.
Even with no waiters, the VM continues the load into its ready/failed cache;
one instance cannot poison, restart or cancel another's shared module work.
Ordinary failures fail active required requests at their eligible settlements;
without waiters they are attributed, logged and cached, without retry or an
invented instance failure. Engine/cleanup failures remain fatal.

The job retains its logical evaluation obligation even with no waiters. Its
work and cache have VM-owned bounds; a detached waiter's retirement does not
claim the job has retired. VM/session stop drains actual provider work without
requiring further ordinary module execution. D-8's top-level acquisition ban
and the non-preemptible trusted-script limit remain unchanged.

The manager presented the cost: unwanted loading, effects and tick delay may
continue until completion or VM stop. The owner chose this over stopping at
the last dependent's departure. D-58 subsequently settles evaluation order,
including a dependency that already has a later queued job.

### D-58. Evaluate one import chain per VM, reusing queued dependencies

**Delivery:** M1; qualifies D-56/D-57's assigned evaluation timing.

Owner answer, **2026-10-22 01:28:15 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: one import chain (Rec.)

Authenticated relay: `het-manager`, message `jzs7v3cvthmm7q9y5fq98up626`,
posted **2026-10-22 01:28:16.097 UTC** in `#het-luafirst`, replying to Q-2j
message `62yjdxh32u3nzqc5gk6y9ksmis`.

Accept P-55's A: one module evaluation chain at a time per VM, independent
roots in logical tick/sequence order or UI request-admission order, imports
depth-first in Lua call order. Reads may overlap, but a later ready file
cannot overtake an earlier root. Reuse a queued dependency within the active
chain exactly once; reject cycles with their path and expose no partial exports.

The manager's relay abbreviated UI ordering as "arrival order". On checking
that wording, authenticated clarification `nhngg4fwmmtw7eyucmf9vp9zd2`, posted
**2026-10-22 01:29:12.946 UTC**, confirmed it meant request-admission order,
not file-read completion order. The owner had also been told, verbatim,
"files may be read in parallel, but a later file that's ready can't jump ahead."
This clarifies the presentation of the approved option; no new choice was asked.

The owner accepted the timing refinement: A due at tick 10 may import and
evaluate B already requested for tick 12. B's separate request still settles
at tick 12, while its ready/failed cache entry exists from the dependency
evaluation; failure of A's dependency affects A at A's position. This does not
permit execution driven early by native arrival or duplicate evaluation.

Eligible UI hooks and stop/control still run while the UI loader waits for
source bytes. A due unfinished logical chain holds its tick, with the other
VM independent. The manager explained the cost: a slow dependency delays
unrelated module evaluation in that VM. The owner chose this over interleaved
module loads. D-59 subsequently settles capacity failure behavior; exact bounds
remain to be settled.

### D-59. Refuse a full module cache before admission; fail accepted over-limit loads

**Delivery:** M1; permanent module limits are distinct from temporary request pressure.

Owner answer, **2026-10-22 01:45:58 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: refuse up front (Rec.)

Authenticated relay: `het-manager`, message `8cwn9fqr4645y6h4cwifkw3vt6`,
posted **2026-10-22 01:45:58.274 UTC** in `#het-luafirst`, replying to Q-2k
message `hu475cjqaprwewihes8uuvwh4w`.

Accept P-56's A: a new module requested with no cache capacity is refused
before admission by an ordinary catchable Lua error naming the limit. It starts
no work and creates no handle or cache entry. Existing cached modules and
joining existing loads remain available subject to request capacity. Temporary
request pressure still returns `busy` with atomic reservations.

An accepted load can later fail on a discovered dependency's cache, source-size
or depth limit. That is a required-load failure under the established timing,
attribution and boot/runtime rules, with admitted failed entries retained.
There is no waiting for cache space, eviction or retry. Completed dependencies
stay cached; a never-admitted dependency gets no extra cache entry. Catching a
failed required import cannot make its containing failed load succeed.

The manager explained the cost: a permanent-limit error as well as `busy`,
failed entries consuming the session budget, and accepted loads failing on
later dependencies. The owner chose refusal up front over failing the VM for
pre-admission cache exhaustion. Concrete numbers and configuration remain open;
the existing host's limits were evidence, not selected defaults for this loader.

### D-60. Content paths are literal filenames relative to their content root

**Delivery:** M1; common module/data/texture path grammar.

Owner answer, **2026-10-22 01:51:49 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: literal root paths (Rec.)

Authenticated relay: `het-manager`, message `nzxh26nypgkrtcsf47i2pun2xi`,
posted **2026-10-22 01:51:49.403 UTC** in `#het-luafirst`, replying to Q-2l
message `jcr2zzcnb9rb4q8tvwqfxu3b4w`.

Accept P-57's A: paths such as `lua/util.lua` start at the selected content
root, never the importing script's directory, and use `/` only. Empty paths,
leading/trailing/repeated slashes, dot/parent segments, backslashes, colons,
control characters and invalid UTF-8 are refused before filesystem work.
There is no expansion, URL/absolute-path interpretation, working-directory
search, extension insertion or directory-entry fallback.

Bad hook arguments are ordinary Lua errors, including for optional loads;
invalid manifest entries fail boot before Lua. Invalid module-level imports
fail the required load. Valid but missing/changed files retain their content
failure classification. The manager presented the cost of always writing
from the root without shortcuts. The owner chose literal paths over accepting
and normalizing shortcuts. D-61 subsequently settles filename case/Unicode
rules; numeric limits and race-safe filesystem opening remain separate.

### D-61. Unicode filenames share canonical identity but require exact case

**Delivery:** M1; checked filename identity for every content service.

Owner answer, **2026-10-22 01:58:39 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: Unicode names (Rec.)

Authenticated relay: `het-manager`, message `hgmzif33mzxfvifszpjtwfhpv6`,
posted **2026-10-22 01:58:39.080 UTC** in `#het-luafirst`, replying to Q-2m
message `xjcvrcw9gytkahyu56qjmxh6js`.

Accept P-58's A: UTF-8 filename segments normalize to NFC, so composed and
decomposed forms share an identity, while lookup requires exact case.
`Hero.png` never finds `hero.png`. Startup rejects sibling names colliding by
normalization or canonical caseless comparison, naming both entries. A valid
case-mismatched request is missing content under the existing failure rules.

The checked inventory maps logical names to observed native entries; native
lookup cannot override the logical identity. Module caches, fingerprints and
content requests use the same keys, with fixed documented Unicode tables.
File bytes are untouched. D-60's grammar and D-10/D-11's version/no-link rules
remain. The manager presented normalization, collision checking, mappings and
platform tests as the cost. The owner chose Unicode names over ASCII-only
content filenames. D-63 subsequently settles launcher-root resolution;
numeric limits remain open.

### D-62. Hash every regular content file before Lua and verify later loaded bytes

**Delivery:** M1; bounded startup inventory without a private content snapshot.

Owner answer, **2026-10-22 02:04:19 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: hash whole folder (Rec.)

Authenticated relay: `het-manager`, message `wg2mqd7fw73akfhmhcxqakykcw`,
posted **2026-10-22 02:04:20.019 UTC** in `#het-luafirst`, replying to Q-2n
message `g5u4pchgkssqejs2mryysxvpia`.

Accept P-59's A: before Lua, validate the selected content tree and SHA-256-hash
every regular file, including hidden and unused files. Retain bounded paths,
native mappings, lengths and digests, not a private byte snapshot. No ignore
list, extension filter or authored asset list. Invalid, unreadable or detectably
changing files and exceeded inventory limits fail boot even for unused files.

Later loads verify the exact bytes delivered; metadata cannot replace hashing.
Same-length edits fail, while timestamp-only changes or identical-byte
replacement are acceptable when the path remains legal. Manifest bytes used
for launch must match the pinned version. Missing/changed/new paths retain
D-10's rules; already-loaded objects remain original. Scan timing is not an
atomic snapshot of the entire filesystem, and safe native opening is separate.

The manager presented the cost as reading every file twice, the absence of
a Lua loading screen during the initial scan, and keeping junk outside the
game folder. Precisely, every file is read during the scan; requested files
are read again on each uncached load, while an unused file needs no second
read. This records P-59's approved behavior without turning the cost shorthand
into a mandatory extra read. The owner chose this over a manifest file list.

### D-63. Resolve the launch path once and anchor the session to its actual directory

**Delivery:** M1; native root ownership and no-follow content operations.

Owner answer, **2026-10-22 02:08:27 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: resolve once (Rec.)

Authenticated relay: `het-manager`, message `yk5r4wk2ynerqaa4fxsmfik8ie`,
posted **2026-10-22 02:08:27.639 UTC** in `#het-luafirst`, replying to Q-2o
message `is8vmftsqsr9esaheyukec4g4s`.

Accept P-60's A: a native relative or absolute launch path may pass through
symlinks; resolve and open the actual directory once before manifest/inventory
work, report it and retain its protected directory owner for the session.
Renaming the selected folder, replacing its old pathname or retargeting a
selection symlink never switches the running session. Restart to select a new
target. The original root remains usable if readable and its content checks pass.

Internal operations remain anchored to that root, refuse symlinks at every
component during opening, check opened object types, and verify the exact
opened bytes. A prior pathname check followed by an unrestricted open is not
the contract. Root/operation handles outlive their actual workers through
cancellation and partial-boot cleanup; unsupported behavior refuses startup.

The manager presented native adapters, handle ownership, race and cleanup tests
as the cost. The owner chose this over banning symlinks in the launch path.
D-64 subsequently settles hard-link/mount policy; numeric handle limits remain
open. No immutable snapshot or hostile-filesystem containment is claimed.

### D-64. Hard-linked files and mounted subfolders are allowed content

**Delivery:** M1; path identity with verified bytes, not exclusive storage.

Owner answer, **2026-10-22 02:13:22 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: allow them (Rec.)

Authenticated relay: `het-manager`, message `kpvfkcfa9rh68kg7wg82wk3cis`,
posted **2026-10-22 02:13:22.171 UTC** in `#het-luafirst`, replying to Q-2p
message `xvtvr9htcg5rm4snkadpg5x4ds`.

Accept P-61's A: hard-linked regular files and mounted subfolders are allowed
under the anchored, no-symlink content rules. The engine creates neither.
Each path has its own identity and counts separately: two hard-link names
for one Lua file are two modules, not an inode-deduplicated module. An outside
edit to the shared bytes can fail a later inside fingerprint check.

Scan mounted content, reject directory traversal cycles with a path chain,
and retain the inventory bounds. Mount/device identity is not an extra content
version key; no new path or changed bytes are admitted by a topology change.
The selected root remains anchored. D-11's non-regular-entry and symbolic-link
refusals remain, with no hostile-OS containment claim.

The manager presented outside aliases, scan time and repeated work as the
cost. The owner chose this over rejecting hard links and mount crossings.
Native qualification and numerical bounds remain delivery work.

### D-65. M1 Lua textures accept static PNG colour images only

**Delivery:** M1; narrow Lua profile over the real image/upload services.

Owner answer, **2026-10-22 02:17:12 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: static PNG (Rec.)

Authenticated relay: `het-manager`, message `pqsdzx9m3tmdcjsan8zups66ta`,
posted **2026-10-22 02:17:12.713 UTC** in `#het-luafirst`, replying to Q-6m
message `fajw2wqpz59cir8chyguugrfn6`.

Accept P-62's A: recognize static PNG by its verified bytes and use the existing
colour decoder to produce one RGBA8 sRGB level with linear-light premultiplied
alpha. Refuse animation-marked PNGs; non-PNG, malformed and oversized images
follow the required/optional content-failure rules. No generated mipmaps,
HDR/data-texture/colour options or animation playback are exposed in M1 Lua.

Readiness, ownership, cancellation and provider bounds remain as specified in
P-62 and D-47/D-48/D-50. The manager presented PNG export, uncompressed storage
and no mip-assisted downscaling as costs. The owner chose PNG alone over PNG
plus KTX2. Existing Haskell KTX2/BC7/mip features remain available; this is a
Lua-surface restriction, not their removal.

### D-66. Scenes use opaque sRGB byte colours and finite fractional rectangles

**Delivery:** M1; scene value and validation contract.

Owner answer, **2026-10-22 02:25:51 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: sRGB 0..255 (Rec.)

Authenticated relay: `het-manager`, message `mhj3tixr859x3w7axxnd363bis`,
posted **2026-10-22 02:25:51.416 UTC** in `#het-luafirst`, replying to Q-6n
message `q2xvm444c263qkjw4iiygpw75a`.

Accept P-63's A and its full shared proposal: each scene supplies three whole
sRGB colour values in `0..255`, converted to linear light with clear alpha 1.
The manager illustrated that sRGB mid-grey corresponds to about 0.22 linear;
the binding uses the defined transfer conversion, not that rounded example.
Backgrounds are opaque, PNG transparency blends over them, and engine-drawn
windows use black before their first scene. An empty sprite list just clears.

Finite integer/fractional logical-pixel coordinates are allowed, including
negative/offscreen positions clipped by the view. Sizes are strictly positive;
there is no snapping, clamping or mirror-by-negative-size behavior. Checked
single-precision conversion and bounds refuse invalid/collapsed geometry.
Invalid values, unknown fields or invalid textures refuse the entire scene
and keep the old one under D-46's error policy.

The owner chose familiar sRGB byte colours over linear-light fractions, with
the conversion/8-bit precision cost and the opaque-background restriction.
Exact table shapes and numeric geometry bounds remain for the API package.

### D-67. Logical requests choose a tick offset, defaulting to one

**Delivery:** M1; explicit result assignment and shared-module scheduling.

Owner answer, **2026-10-22 02:30:11 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: choose a tick offset (Rec.)

Authenticated relay: `het-manager`, message `8c6jivzuvakbnirzd6bjwbihjn`,
posted **2026-10-22 02:30:11.397 UTC** in `#het-luafirst`, replying to Q-6o
message `c8kxtbzcfcbfe372i6fmpizha6`.

Accept P-64's A: logical data/module requests may select a positive tick offset,
default 1, fixed at admission with an engine-assigned sequence. Init uses
origin 0; tick 10 plus offset 30 means tick 40. Background source work may begin
after admission, but ordinary results remain hidden until the assigned position.
Late required or optional results hold that position under the established
clock policy; cancellation retains its existing exception. No retiming.

The shared VM module job uses the earliest evaluation position contributed by
an admitted request or dependency. An earlier joining waiter can advance queued
evaluation without duplicating it; cancellation does not move it later. Each
waiter retains its own result position, with D-58's immediate cache lookup
remaining available. UI remains arrival-settled and refuses tick offsets.

The manager presented prefetching, the init/10+30 examples and earliest shared
module work, with lead-time planning and held capacity as costs. The owner
chose explicit offsets over always-next-tick delivery. Exact names, ranges,
sequence exhaustion and narrow assignment integration remain delivery work.

### D-68. Each role exposes its own clock and cooperative duration waits

**Delivery:** M1; scheduler-backed time access without ambient OS clocks.

Owner answer, **2026-10-22 02:35:19 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: own clock + waits (Rec.)

Authenticated relay: `het-manager`, message `tba8rc9q6ev8wzfud42wwsirba`,
posted **2026-10-22 02:35:19.881 UTC** in `#het-luafirst`, replying to Q-6p
message `zvruky5s9uuajjdfqx5b85cby6`.

Accept P-65's A: logical Lua reads its current tick and fixed tick length and
waits a positive number of ticks; loading delays never advance logical time.
UI Lua reads monotonic seconds from its VM's root-init origin, shared between
instances, sampled once per hook/resumed segment, and may wait a positive
duration in seconds. First root init reads zero; a due wait may resume late.
The existing cadence/`dt` contract remains unchanged.

Logical Lua has no elapsed-time API; neither role gets wall/calendar/CPU time.
Clock reads belong to lifecycle hooks, not module top level. Engine-scheduled
waits/yield remain forbidden in finite init/shutdown. Wrong-role, invalid and
wrong-phase operations are Lua errors; waits resume the same invocation under
existing scheduling/cleanup rather than creating updates or native Lua sleeps.

The manager presented origins/units and stale time samples in long UI segments
as costs. The owner chose clock reads and waits over the smaller `dt`/yield
surface. P-65 also preserves request waits in that alternative; the manager's
short option label did not propose removing the accepted D-54 request API.
Exact names, numeric limits and integration remain delivery work.

### D-69. Defer randomness services and remove both standard RNG functions in M1

**Delivery:** M1 library profile; engine RNG design belongs to a later arc.

Owner answer, **2026-10-22 02:40:03 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: defer randomness (Rec.)

Authenticated relay: `het-manager`, message `eei6bg2pvjz3ndc5khct6ypak2`,
posted **2026-10-22 02:40:03.132 UTC** in `#het-luafirst`, replying to Q-6q
message `hffzinq884pyzcbw4vvs8gzura`.

Accept P-66's A: remove `math.random` and `math.randomseed` from both M1
VMs before authored modules run, in addition to D-5's exclusions. Other
permitted math remains. Calling a removed function is an ordinary Lua error,
not the terminal unavailable-state-service guard. M1 adds no engine RNG,
seed setting or replay guarantee; the quad and logical stub require none.

Authors may write or import their own explicitly seeded pure-Lua generator
with ordinary Lua-owned state. This promises neither a shipped helper nor an
engine algorithm; shared module state still follows D-7. It does not make
trusted Lua deterministic. Existing sample contracts remain in their own scope;
P-1's earlier seeded-stream wording does not require an M1 engine stream.

The manager presented the cost that cosmetic UI scripts using the standard
RNG must change or bring their own generator. The owner chose deferral over
retaining UI randomness. Future engine seeding/streams remain undecided.

### D-70. UI hooks poll copied session status without status-change callbacks

**Delivery:** M1 loading/failure observation; no gameplay-state channel.

Owner answer, **2026-10-22 03:12:39 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: UI polls (Rec.)

Authenticated relay: `het-manager`, message `ctf5698qnashwmy5exx7gdpmf2`,
posted **2026-10-22 03:12:39.490 UTC** in `#het-luafirst`, replying to Q-6r
message `exsvbk36ehrfvp69sq9rrjpga2`.

Accept P-67's A: a UI lifecycle hook reads a plain copied status sampled once
per hook/resumed segment. It describes present VMs, readiness, running/failure/
stopping/actual retirement and stop requests. A logical failure remains latched
with source, executing instance, role, stage, explanation and available bounded
traceback. Copies do not mutate engine status; cleanup completion is reported
only after actual retirement. Early UI receives starting/ready information,
not detailed progress or a world. Existing startup/stop/failure policies remain.

The read is UI-only, including finite init/shutdown; logical-VM and module-top
calls are ordinary Lua errors. This narrows P-41's earlier role-neutral runtime
status wording. No callbacks, history, acknowledgement or status-triggered wake
is added. Intermediate changes may be missed and long segments see stale
samples; independent stderr diagnostics still report failures.

The manager presented polling and no wakeup for event-driven instances as the
cost. The owner chose polling over status callbacks. Exact record fields and
numeric bounds remain part of the API package.

### D-71. Use bounded print/warn output without a separate Lua logger in M1

**Delivery:** M1 authored output and warning bridge.

Owner answer, **2026-10-22 03:16:07 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: print/warn only (Rec.)

Authenticated relay: `het-manager`, message `eh3s29hkuckqgv377t9resdime`,
posted **2026-10-22 03:16:07.915 UTC** in `#het-luafirst`, replying to Q-6s
message `3wypxkwhxjrqbbhf87w272x8ww`.

Accept P-68's A: engine-rebound print writes plain authored text to stdout;
warn writes stderr with engine-owned VM/content/instance attribution, or
module attribution during evaluation. Both are available in both VMs and
all authored phases. Arguments are converted and tab-joined; each complete
call has a 4096-byte written cap including formatting and visible truncation,
with invalid UTF-8 replacement and control escaping.

Calls use synchronous serialized writes and flushing, with no queue, drop or
retry mechanism. A write/sink/flush failure is fatal host failure. Authored
output bypasses engine log filters; warnings do not themselves fail an instance.
P-68 retains independent engine failure reports and the protected sink lifetime.

The manager presented the lack of levels/structured fields, truncation and
blocking on slow output as costs. The owner chose the small print/warn surface
over a structured Lua logging service. Existing Haskell logging remains;
its Lua service is deferred, not removed from the engine.

### D-72. Lua requests orderly whole-session quit, then returns to its hook

**Delivery:** M1 session control; no Lua force-exit or per-instance control API.

Owner answer, **2026-10-22 03:19:38 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: request, then return (Rec.)

Authenticated relay: `het-manager`, message `iyc3ugrwnjbwyyqstuj3erc7ma`,
posted **2026-10-22 03:19:38.792 UTC** in `#het-luafirst`, replying to Q-6t
message `nmib65b8m349kuivk2r9ctgtt2`.

Accept P-69's A: a no-argument/no-result operation in either VM's lifecycle
hooks, including init/shutdown, latches normal whole-session stop and returns.
It uses no request slot, cannot return busy and is harmless when repeated.
Module-top-level calls remain ordinary Lua errors. The manager's `quit()`
spelling describes the operation; its final namespace remains for the API
package, as the proposal stated.

After the latch, new content/window/texture requests and scene publications
are Lua errors before native action; release, cancel, print and warn retain
their existing rules. The current hook continues until return or a scheduler
boundary. Catching cannot undo the stop, no further ordinary continuation
resumes after stop applies, and init success cannot reopen the startup gate.
Existing failure precedence, safe shutdown eligibility and actual resource
retirement remain mandatory. This is no synchronous completion receipt.

The manager presented the need to return promptly and the second Ctrl-C
escape for a hang. The owner chose a returning request over immediate hook
termination. D-20 still covers both SIGINT and SIGTERM, and failure after a
quit request can still make the orderly process outcome fail.

### D-73. Defer Lua window-size observation and responsive layout from M1

**Delivery:** M1 boundary; later presentation observation API.

Owner answer, **2026-10-22 03:25:35 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> A: defer size reads (Rec.)

Authenticated relay: `het-manager`, message `8uemyzhbbeauhccfkezx9ahwp2`,
posted **2026-10-22 03:25:35.796 UTC** in `#het-luafirst`, replying to Q-6u
message `ewiidsbqpxxuecmdcngkecbs7s`.

Accept P-70's A: M1 has no Lua size query or resize callback. Rectangles keep
their authored logical-pixel positions and sizes while the engine updates the
view, clips and suspends drawing at zero framebuffer extent. It does not
stretch or recenter the scene; static scenes continue without republishing.
The requested initial size is only a preference, never an actual-size report.
Texture dimensions remain part of successful texture loading under D-47.

The manager presented the lack of automatic centering or fitting on resize
as the cost. The owner chose deferral over a UI-only size poll and directed
the design onward to concrete API/manifest/bounds, vision/#145 reconciliation
and one-PR delivery slices. Native resize/retirement qualification remains.

### D-74. Use the approved run command and strict format-1 JSON manifest

**Delivery:** M1 concrete launcher contract.

Owner answer, **2026-10-22 03:30:12 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> Approve all five (Rec.)

Authenticated relay: `het-manager`, message `cj72dswwkm9h684q8i5pgj6gwi`,
posted **2026-10-22 03:30:12.443 UTC** in `#het-luafirst`, replying to Q-13
message `ysx9eiayd4gnpd8r6npuy9p99w`.

Accept all five P-71 parts: `hetoimasia run [--] GAME_ROOT` and compatibility
with existing commands; bounded strict root `hetoimasia.json`; the format-1
schema/stable ASCII ID; optional role/clock/entry declarations with the default
pair and common-entry fallback; and quoted exact decimal `tick_seconds` with
nanosecond range and no default. The examples, invalid-input rules and absence
of M1 mod declarations are part of that concrete contract.

The manager summarized all five parts, the minimal JSON example and the costs:
no comments, unknown fields fail, quoted time without an exact `1/60` fraction,
and strict parser work. The offered revision route mentioned TOML/YAML, command
spelling and a rate in Hz; the owner selected none and approved the package.
This does not yet approve the Lua function/result schemas or remaining bounds.

### D-75. Use the approved core Lua module, behavior and request API

**Delivery:** M1 authoring, instance facade and asynchronous result contract.

Owner answer, **2026-10-22 03:38:56 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> Approve all five (Rec.)

Authenticated relay: `het-manager`, message `wfj63ze8d5zqnh9sqka7pi459n`,
posted **2026-10-22 03:38:57.080 UTC** in `#het-luafirst`, replying to Q-14
message `7upneqwp4vaim2v44djmfyk6ke`.

Accept all five P-72 parts: plain module exports and captured strict behavior
tables; fresh self with the instance-bound API facade; module-root imports
versus instance-root asynchronous module requests; common dot-call admission
and one-shot result records; and VM-local shared exports inside fresh result
envelopes. These spellings and semantics are selected, including ordinary
not-ready refusal versus latched required failure for a known failed import.

The manager summarized all five parts with the room.lua busy-retry example
and costs. The alternative revision route suggested method-call style or
optional modules; the owner chose neither. Service-specific records/functions
and remaining numeric/resource bounds still require their own approval.

### D-76. Use the approved remaining service APIs and records

**Delivery:** M1 content/graphics/time/status/control binding schemas.

Owner answer, **2026-10-22 04:14:58 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> Approve all six (Rec.)

Authenticated relay: `het-manager`, message `qkwkkkxxm9xpmmfm7wnrg2is8e`,
posted **2026-10-22 04:14:58.260 UTC** in `#het-luafirst`, replying to Q-15
message `94ijx9tyijyjx936fbvmzi6vva`.

Before asking, the manager showed the owner P-73's quad example in abridged
form: behavior tables, begin/collect, status checking with a red clear on
logical failure, and publication followed by texture release. It then
summarized all six parts. The owner approved the package rather than Revise.

Accept all six P-73 parts: data/texture functions/values; window, scene and
release schemas; time/wait functions; UI status/shutdown records; quit and the
single unavailable-state guard; strict validation/expected failure codes.
The quad composition was shown before signoff, not added as an unexplained
implementation interpretation afterwards. Numeric ceilings and worker/resource
accounting remain the next explicit contract.

### D-77. Use the approved fixed M1 ceilings and worker accounting

**Delivery:** M1 limits, admission, provider workers and retirement accounting.

Owner answer, **2026-10-22 05:20:41 UTC**, through AskUserQuestion in the
manager's pane, verbatim:

> Approve all six (Rec.)

Authenticated relay: `het-manager`, message `euwd2egbtsck5d4c6p4v56b53w`,
posted **2026-10-22 05:20:41.618 UTC** in `#het-luafirst`, replying to Q-16
message `tpduukyenxg49hcb2y94qzhfpn`.

All six parts of P-74 are accepted: inventory/module limits; instance,
request, value and diagnostic limits; graphics/PNG/native budgets; owned
workers and stage queues; numeric/time/exhaustion rules; and refusal/failure
classification with qualification obligations. The tables and accounting
rules in P-74 are the normative numeric profile. These are fixed M1 assembly
limits, not Lua configuration or a hard process-memory/preemption guarantee.

Before asking, the manager showed the owner a summary table covering folder,
module, instance/request, data, copied-value/scene, PNG, texture, window,
sprite and failure-text limits; two I/O workers, one decode worker and two
texture lanes, with active dependencies ahead of prefetch; and the practical
costs. Those included unused oversized files failing boot, resizing PNGs above
2048, splitting data at 8 MiB, early busy refusal from conservative texture
reservations, and the absence of a total Lua memory cap. The alternative
"Revise limits" was not chosen. No runtime, allocation or native evidence is
claimed by this signoff; implementation must establish P-74's proof obligations.

### D-78. Draft both remaining pieces; delegate slice process signoff

**Delivery:** design completion and publication coordination, not new M1 behavior.

Owner answer, **2026-10-22 05:22:06 UTC**, in the manager's pane, verbatim:

> yes, i sign off on all of that

Authenticated relay: `het-manager`, message `64zimzpdu6jiigicdy9d5tmapi`,
posted **2026-10-22 05:22:06.247 UTC** in `#het-luafirst`. The relay identifies
this request and says it replies to the designer's latest status; it has no
reply_to field. The manager states that the owner had just been shown the two
remaining pieces: vision/#145 reconciliation and one-PR delivery slices.
This is not represented as approval of text or slice rows shown afterwards.

The manager explicitly directs both drafts now. Slice splitting and ordering
are process work under the owner's standing grant, quoted in that relay:

> as long as its process work, i dont care how things are split, or ordered ... just stop if there is a design gap or ambiguity

For this request, `het-manager` reviews and signs off the proposed slice plan;
only design gaps return to the owner. This supersedes the earlier requirement
to wait for Q-8 before decomposition and the earlier owner-only slice signoff.
It grants no new behavior, tracker mutation, review verdict or implementation.
No expiry was stated; the grant applies to this design's delivery-plan process,
not authority over unrelated work or trust/security decisions.

The owner has approved the trust/scope substance through D-2/D-41/D-43. The
manager nevertheless requires the exact vision and #145 wording to receive
one-line owner confirmation before publication. Keep Q-8 pending for that
wording; do not edit vision or #145. This round's design edits remain local
until the publication confirmation, conservatively applying "before anything
lands". P-75's prior publication at 9fb6af1a00 predates this relay's delivery
to the designer; it did not mutate vision or the tracker.

### D-79. Confirm the exact vision and prior-epic reconciliation

**Delivery:** P-75 wording/status reconciliation; no new implementation behavior.

Owner confirmation, reported **2026-10-22 05:31:42 UTC**, through
AskUserQuestion in the manager's pane, verbatim:

> Confirm all five (Rec.)

Authenticated relay: `het-manager`, message `hjejzmnk7ify3p9s62kpkq47sn`,
posted **2026-10-22 05:31:42.929 UTC** in `#het-luafirst`, replying to the
exact-wording message `3h2k5kcsskvymgttc2ga7ifvt6` (with continued text ending
at `uqgv5zmdjkptta2zrnew6n7mqi`). All five P-75 parts are confirmed.

Before confirming, the owner saw the V-1 opening and V-9 title/trust/filtering/
confinement paragraphs verbatim from P-75, plus summaries of the D-23 note,
V-4/V-5, old-design status, #145 rename/revised closure and separate M1 epic,
and MEMORY follow-up. The manager explicitly verified that the exact vision
message matched P-75 and that the full #145 replacement body implemented
part 4; the relay says the confirmation covers that text. This records what
was actually shown, not a claim that every remaining line was read aloud.

The manager now authorizes this designer to apply only the confirmed V-1/V-9/
V-4/V-5 wording in `docs/vision.md` and part-3 status/deferral reconciliation
in `docs/lua_runtime_design.md`, then land both with docs-push and report the
commit. This supersedes D-78's publication hold and the original design-only
file restriction for these exact edits. Change nothing else in those files.
The manager applies #145's title/body and closure and arranges MEMORY.md as
a separate PR; this designer does neither. Q-9 proceeds to manager process
review under D-78. No issue creation or implementation is authorized here.

### D-80. Approve the slice plan with a lifecycle split and review invariants

**Delivery:** process-only plan signoff under D-78's owner grant.

Authenticated manager signoff at **2026-10-22 05:36:07 UTC**:
`het-manager`, message `9pcc2j4u78ytq2sfr3s2xtaumw`, posted
**2026-10-22 05:36:07.755 UTC**, replying to Q-9/P-76 message
`nje4nbtgfkafwtjjztvyf8ebnw`. This is manager process authority delegated by
the owner, not an invented owner quotation or new behavior decision.

The manager approved coverage/dependency order with two explicit changes:

1. Split LFE-13 into **LFE-13: Coordinate role startup gates, failure policy
   and session stop**, and new **LFE-26: Expose UI status, quit and the
   unavailable-state guard**. LFE-26 depends on LFE-12 and LFE-13; LFE-21 and
   LFE-22 also depend on LFE-26. Insert LFE-26 immediately after LFE-13 in both
   ledger and delivery plan without renumbering the other slices. There are
   twenty-six slices. The manager cites #499/#502's thirteen review rounds as
   the reason for a smaller startup/failure/stop boundary.
2. Lifecycle-heavy issues require a PR-body invariant table covering every
   reservation, settlement/publication site and cancellation window, including
   admission-to-tracking, intent-to-issuance and pre-final-publication gaps.
   Sweep every site of a fixed shape before review round 1. This applies at
   least to LFE-7, LFE-9, LFE-10, LFE-11, LFE-13, LFE-16, LFE-17, LFE-18,
   LFE-20 and LFE-26, and wherever later specifications expose the same risks.

Record/apply the split, publish the draft with docs-push, then finish the
readiness audit. These requirements change process boundaries/evidence, not
the accepted Lua contract, budgets, failure authority or deferred scope.

### D-81. Mark the design ready and authorize one-artifact-at-a-time processing

**Delivery:** readiness and tracker-processing authority; solving remains unauthorized.

Authenticated manager signoff at **2026-10-22 05:43:10 UTC**:
`het-manager`, message `aag5b9fcfmqkbdff2h26zqb7ni`, posted
**2026-10-22 05:43:10.472 UTC**, replying to the completed audit/readiness
request `dde6j7s7tz96tu63rf74hz3rbw`. Under D-78 and the owner's standing
grant, the manager explicitly states:

> the Lua-first M1 design is 'ready for issue processing'

The manager cites the 26-slice audit, consistent ledger/dependencies, complete
M1 contract coverage, landed reconciliation, closed #145, merged #513 and
clean links/diff, with every behavioral decision owner-signed. Record this
state and land it through docs-push.

The manager also explicitly invokes process-design-doc in this same session:
the new M1-only epic first, #145 as its delivered predecessor, then one child
per invocation in ledger order. Post each complete draft in `#het-luafirst`
and obtain `het-manager` signoff before creating it. The manager has the
owner's standing issue-approval grant for these artifacts; escalate only design
gaps. No blanket artifact approval is inferred. Child specs include acceptance,
boundaries and D-80's lifecycle invariant/sweep requirements where applicable.
The manager arranges canonical approve-issue review of filed children. Solving
is not authorized; the manager will ask the owner separately. This explicitly
supersedes the original no-tracker-mutation restriction only for approved
artifacts in this request, not other issues, labels or implementation work.

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
authoring. D-69 defers engine randomness from M1 and removes both standard RNG
functions in both roles. The earlier sample's seeded gameplay stream and
separate presentation randomness remain its own contract and later-arc context,
not an M1 engine-service requirement. D-68 settles time semantics; exact API
spellings, output and diagnostic bindings still belong to Q-6.

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
logging/print, their own clocks/waits and orderly session quit. Runtime status
is UI-only under the later D-70 refinement.
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

**A accepted by D-45 through Q-6b. Delivery: M1.** Recommend A: a presentation
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

### P-43. Publish a copied complete scene for one window

**A accepted by D-46 through Q-6c. Delivery: M1.** Recommend A: a UI hook
constructs a plain Lua scene value and publishes it to its ready window. The
binding copies and validates the complete bounded value and the instance's
ready texture leases before atomically replacing that window's published scene.
Mutating the original table afterwards does nothing until another publication.
The quad is scene data, not an ECS entity. Exact fields and the M1 subset of the
existing 2D renderer are the next API contract, not approval of every renderer
feature or of a separate mutable scene-object system.

The accepted scene remains available for independent rendering until replaced
or the window ends. A static quad needs one publication, not one call per
rendered frame. Publication does not wait for GPU work or a displayed frame.
Rendering may skip intermediate publications and adopt the latest complete
scene; it never observes half a Lua edit. This is presentation coalescing, not
permission to drop logical ticks or assigned logical results. Multiple calls
from the owning instance replace in their actual execution order. No other
instance can publish through its window lease.

Invalid/over-budget scene values or unavailable, retired or wrong-instance
texture references refuse the entire publication as an ordinary Lua error,
leaving the previous published scene intact. No partial update, automatic
placeholder or silent omission is introduced. If uncaught, the script error
follows the approved UI/boot failure policy; a healthy session is not promised
to survive an uncaught error merely because an old scene exists. Engine/provider
or cleanup failures remain fatal rather than becoming recoverable validation
errors. Exact numeric budgets and error representation remain API details.

Acceptance establishes protected resource obligations before publication is
exposed to the graphics owner. Reuse the adapter's publication/release barrier
and per-revision holds: a Lua lease ending cannot destroy a texture still
needed by an accepted/adopted scene or in-flight GPU work. A replaced scene's
resources retire only after its actual use completes. Existing scene holds do
not keep a released Lua handle usable for a later publication. Instance ending
closes its window/publications and drains its holdings through protected native
retirement; Lua cleanup hooks and Lua garbage collection are not the lifetime
proof. This does not select a public early-release API or texture-sharing API.

Alternative B: Lua creates engine-owned mutable scene/sprite objects and sends
individual edits, with a separate rule for when a complete edited scene becomes
visible. This can avoid copying a large scene for small changes, but requires
object identities, ownership, edit validation, publication boundaries and
teardown beyond the quad's needs. Existing Haskell retained-rendering mechanisms
can still be used internally or exposed in a later binding extension; A does
not remove them or require rebuilding static content every rendered frame.

A is recommended because it uses the delivered renderer's per-window snapshot
model and makes cross-thread publication/retirement concrete. Its cost is full
copy/validation on each publication; larger or frequently changing scenes may
later need retained content or smaller update surfaces. M1 must qualify rejected
publication preserving the prior scene, table mutation after publication,
coalescing, and replacement/ending while GPU work still references a texture.

Evidence: the [2D host adapter](../../packages/render-2d-vulkan/README.md)
validates `publish2DSnapshot`, serializes publication with texture release, and
holds objects by adopted window/revision until released. The
[per-window host](../gpu_backend.md#a-scene-for-each-window) uses latest-value
publication without waiting for adoption. The new Lua conversion and ready-lease
validation are proposed integration work, not existing bindings.

### P-44. One texture request ends with a usable GPU texture lease

**A accepted by D-47 through Q-6d. Delivery: M1.** Recommend A: a UI hook
requests a texture by scoped content path, and one pending request covers
fingerprint-checked reading, decoding, upload and renderer registration. Success
delivers an instance-owned texture lease plus its image dimensions only after
the upload has actually completed and the renderer's texture mapping is ready
for subsequent scene use. Decoded bytes, an admitted upload or an early native
texture handle are not success. This makes D-46's ready-texture check concrete;
it does not reopen its refusal of unavailable textures or add placeholders.

The provider progresses without waiting in a Lua hook or on a rendered frame.
It can load a texture before a window is ready, or with no window yet; GPU
service setup/upload progress must therefore not depend on a window's first
frame. Success does not mean any window has displayed the texture. Lua can
request window and texture in init, then publish the scene when both have
succeeded. Presentation result delivery uses D-44's elapsed/arrival runtime;
this does not grant texture loading to the logical role.

D-12's required-by-default and explicit optional-texture behavior applies to
the whole request: an ordinary content/decoding failure fails required work or
returns the optional structured root/path/reason failure. Changed content is
still refused under D-10. Optional does not hide fatal engine/provider or
cleanup failures. The request is bounded, has no automatic retry, and every
intermediate CPU/GPU holding has engine-owned cleanup even if the result is
never collected. Stopping/cancelling suppresses delivery and initiates cleanup;
an already-started native upload may have to finish before safe retirement.
No Lua reference loss or cancellation acknowledgement proves GPU completion.

Alternative B exposes two Lua operations: load/decode to an owned CPU-image
result, then explicitly request upload/registration to a texture lease. The
texture still cannot enter a scene until GPU readiness. This gives Lua a
separate CPU-image lifetime and upload decision, but adds a public result type,
two-stage orchestration, budgets and cancellation/cleanup cases. It does not
by itself authorize pixel editing, streaming or other advanced asset features.

A is recommended for the approved quad and runtime texture loading: one
observable pending/success/failure result corresponds to a usable resource.
Its cost is that the provider coordinates every stage and delays success until
GPU readiness; Lua cannot retain a decoded image separately or choose its
upload time. Exact format/options, request syntax, caching/sharing and explicit
release APIs remain subsequent M1 contracts, not silently selected here.

Evidence: [asset-image](../../packages/asset-image/README.md) decodes bytes;
the [GPU upload and texture-table contracts](../gpu_backend.md) distinguish
completed upload from mere admission and from descriptor/lookup publication.
Registration of an already completed texture refreshes the table before
returning. The image2d sample composes upload completion and registration in
Haskell. The new asynchronous Lua provider must qualify these same stages,
including cancellation during upload and progress before any window exists.

### P-45. Let an instance release textures and cancel pending texture loads

**A accepted by D-48 through Q-6e. Delivery: M1.** Recommend A: expose
explicit early release of an instance's texture lease and cancellation of its
pending texture request. Automatic cleanup at instance/session end remains
mandatory; Lua need not call either for cleanup to be correct. These are ways
to relinquish work/resources while the instance keeps running, not transfers
to another instance or dependence on Lua garbage collection.

Releasing a texture revokes its Lua lease immediately. New scene publications
using it are refused. A previously accepted scene may keep showing it until a
scene without it replaces it or its window ends; release does not secretly
edit or blank that scene. Existing barriers, revision holds and GPU completion
still determine actual retirement (D-46). Thus dropping a Lua reference, asking
for release, and freeing GPU memory are distinct events. Authors who want to
reclaim a displayed texture must also stop referencing it in the published
scene. The release operation never waits in a hook for those holds to drain.

Expose the host's distinction between release completed, retirement pending,
and already released; exact Lua names remain open. Repeating release of one's
own lease starts no second cleanup. It may observe retirement still pending or
already complete. Wrong-instance/invalid handles are refused. A real cleanup
failure remains fatal and recorded, never retried or reported as successful.
Retiring resources keep their capacity charge until the provider proves them
retired, so repeated acquire/release cannot evade the resource bounds.

Cancelling a pending texture request intentionally withdraws interest; it is
not a required-load failure. Presentation's existing first-settlement-wins
rule applies: if cancellation wins, Lua receives a cancelled settlement and
no texture lease; if success/failure settled first, cancellation reports that
it was already settled and does not erase that result or a required failure.
A successful lease is then handled through normal result consumption and
release. Late provider completion cannot resurrect a cancelled request; all
partial/undelivered resources remain engine-owned through retirement. Request
capacity stays charged until its settlement is consumed/discarded and its
provider retires. No busy wait or automatic retry is introduced.

Alternative B exposes neither early texture release nor manual texture-load
cancellation in M1: each acquired texture or admitted request is retained until
its normal completion and instance/session cleanup. Internal shutdown
cancellation remains real. This has fewer public operations but can accumulate
resources in a long-lived instance during D-9's runtime loading, eventually
hitting its bounds. It cannot be described as automatic reclamation when Lua
merely drops a reference.

A is recommended because resource lifetime must remain practical beyond the
one static quad. Its cost is explicit cancellation races and retirement status
in the binding contract, and the author must replace a scene to release its
holds. This question covers textures only; public window-close controls,
module-import cancellation/cache semantics and the common request API remain
separate details. It does not add mod activation or texture-sharing features.

Evidence: [instance leases and requests](../../packages/scripting-lua/README.md)
already distinguish revoked leases from retained retirement and implement
first-settlement-wins for elapsed requests. The
[2D adapter](../../packages/render-2d-vulkan/README.md) keeps a released texture
rendering while an adopted scene holds it and releases it behind the native
barrier. New bindings must preserve those mechanisms and test both orders of
cancel/completion, repeated release, and scene-held retirement.

### P-46. Keep each M1 texture load independent, with shared backing deferred

**A accepted by D-49 through Q-6f. Delivery: M1.** Recommend A: each new
texture request is a separate load with its own fingerprint-checked read,
decode/upload work and resulting instance-owned lease/native texture identity.
Two requests for the same root/path do not coalesce or reuse a resident GPU
texture. Cancelling one request or releasing one lease cannot cancel/revoke the
other's work or resource. D-48's scene holds and actual-retirement accounting
remain unchanged. Shared renderer infrastructure is still shared; this choice
concerns the loaded textures, not a device/renderer per request.

An instance may reuse its own live lease in multiple sprites/publications;
it does not load again for each quad. Repeatedly asking to load is an explicit
new resource request and consumes capacity again. Another instance loads its
own lease rather than using a handle placed in shared module exports. Resource
loss still triggers no Lua-GC-dependent reclamation: explicit release and
automatic instance cleanup remain the ownership contract.

This preserves D-10 without a new cache-hit interpretation: a new request
verifies the bytes it reads against the session fingerprint, while previously
loaded textures remain their original content. A changed file can fail a new
request even while an older texture is displayed. There is no idle texture
cache, implicit reload or automatic retry. A deliberate later request remains
subject to the same content rules; this does not change D-7's module cache.

Alternative B adds engine sharing for the same content identity/options in M1:
distinct instance leases may share resident texture backing and potentially
in-flight loading. It saves duplicate decoding, uploads and GPU memory. It also
needs an explicit shared-work owner and bounds, per-request cancellation and
required/optional failure attribution, cache-hit fingerprint semantics, and a
definition of when each lease's retirement/capacity completes while peers or
scenes still retain the backing. If B is chosen, propose that concrete contract
for signoff before treating any of these details as decided; never share Lua
handles directly or let one instance revoke another's lease.

A is recommended for M1 because independent requests fully exercise real
instance ownership and cleanup without introducing a shared-cache lifetime in
this milestone. The cost is deliberate: repeated requests duplicate CPU/GPU
work and memory, so this is not a memory/performance optimization. A later
sharing layer must preserve the approved request/lease behavior or explicitly
revise it. Keep provider construction and ownership interfaces suitable for
that extension, without claiming sharing is already implemented. The required
two-instance test should request the same path, then cancel/end/release one
owner and prove the peer's work/lease remains usable, subject to role-level
failure escalation.

Evidence: [instance leases](../../packages/scripting-lua/README.md#instance-leases)
already support both owned and shared acquisitions, with different lifetime
meanings. Neither that mechanism nor a shared module export supplies a content-
keyed texture cache. This proposal selects the M1 provider policy; the native
renderer and host remain reusable for later shared resources.

### P-47. Expose a clear colour and an ordered list of UI texture rectangles

**A accepted by D-50 through Q-6g. Delivery: M1.** Recommend A: the Lua
scene has a clear colour and a bounded ordered list of sprites. Each sprite
names its ready texture lease and a finite destination rectangle (position
and positive width/height). It draws that texture's entire image without
stretching the scene itself to fit the window. A list of any supported size,
including empty, is real scene data; the engine does not hard-code a particular
quad, asset, position or count. An empty list clears the window and removes
its published texture references, subject to D-46's retirement holds.

Use the renderer's UI logical-pixel space: origin at the upper left, X right,
Y down; UI scale fixed to 1 in M1. The current per-axis content scale converts
those units to framebuffer pixels. These are not raw framebuffer pixels and
are not promised to equal window-coordinate units on every platform; the
existing renderer's distinction is retained. The engine supplies one view
covering the current framebuffer and adjusts its extent/metrics on resize or
content-scale changes without Lua republishing an unchanged scene. Sprite
coordinates/sizes stay as authored; there is no automatic centering, stretching
or layout. Zero framebuffer extent suspends drawing safely until drawable.

The list draws in order, later sprites over earlier ones, using the existing
texture-alpha blending contract. Map it to one window pass, one UI layer with
equal depth keys, full-image UVs, white tint, the default textured material,
nearest filtering, brightness 1 and pixel snap off. Clear colour follows the
existing renderer's colour contract; exact field names/encoding and numeric
limits are fixed in the API specification. No world camera, depth ordering,
rotation/shear, UV cropping, authored tint/filter settings, clipping tables,
animation tables, retained chunks, custom materials or offscreen-target Lua
bindings are exposed in this M1 surface.

These are limits on the new Lua interface, not removals from the Haskell
renderer. Keep the conversion to its ordinary validated snapshot explicit and
reusable, with D-46's copied whole-scene publication, ready/owned texture checks
and whole-call refusal. Pixel/offscreen qualification can use that same scene
conversion without adding a public Lua offscreen API. This is a window scene
description, not a gameplay store or widget toolkit.

Alternative B exposes a broader selection of the renderer's existing passes,
views, cameras, layers and sprite options now. It offers richer authored scenes
but expands the Lua schema, bounds, validation, defaults and rendering evidence
needed for M1. If chosen, ask which additions are needed and present the revised
surface for signoff; do not silently expose the entire native API.

A is recommended because it is a useful, data-driven texture-rectangle surface
over the real renderer and completes the approved visible milestone. Its cost
is deliberate authoring limits: Lua cannot yet rotate/crop/tint sprites, choose
world coordinates, or lay out through an exposed camera. Later extensions can
add those capabilities through further design. Qualification needs more than
the one-quad demo: two overlapping sprites for order, an empty scene for
clearing/retirement, and resize/content-scale behavior without scene mutation.

Evidence: [render-2d snapshots and mapping](../../packages/render-2d/README.md)
already define UI layers in logical pixels, per-frame target metrics, nearest
default sampling and painter order for equal depth keys. The
[image2d sample](../../samples/image2d/README.md) demonstrates UI content scaling.
The proposed Lua schema and its automatic full-window view adaptation remain
M1 integration work, not delivered bindings.

### P-48. One window slot per presentation instance, with session-level close

**A accepted by D-51 through Q-6h. Delivery: M1.** Recommend A: each
presentation instance may have at most one outstanding window creation/live
window. The limit belongs to the instance, not a global current-window variable;
the integration/test harness can host separate windows for separate instances.
The pending, live and retiring phases all occupy that instance's slot until
native/graphics retirement is proven. A second request while occupied is
refused before native work as an ordinary Lua error. No hidden queue waits for
the first window to disappear.

Lua requests an ordinary visible, decorated, resizable window with title and
initial positive logical size (D-45). Desktop move/resize/minimize/maximize and
D-50's framebuffer/content-scale handling remain real. M1 exposes no Lua
fullscreen, positioning, hide/show, title/size mutation or independent close
control. Lua uses the existing whole-session quit operation to exit. This is
the launcher's Lua binding policy, not a reduction of the reusable Haskell
window host's capabilities.

A native user close request for an M1 window requests orderly whole-session
quit, including if it arrives during window creation or startup. Lua cannot
veto it; D-20's exit precedence and protected teardown apply. This makes D-43's
demonstration close rule concrete. Cleanup-induced destruction when an instance
ends is not a new user close request: normal harness-controlled ending of one
instance closes only its window/resources and does not itself stop its peer.
Actual UI failure still follows the already approved whole-session policy.

Expose cancellation of a pending window request with the same elapsed first-
settlement rule as texture requests: a winning cancellation withdraws interest
without a required-load failure; a prior success/failure remains settled and
cannot be erased. Cancellation retains the slot until actual retirement.
After it retires, that instance may request a new window. If success won first,
there is no M1 independent close/reopen API: keep the window until instance end
or quit the session. Losing the result/handle never frees the slot or leaks the
native window; engine-owned cleanup remains responsible.

Alternative B allows multiple windows per presentation instance under an
explicit finite bound, keeping the same simple native-close-means-session-quit
rule and limited controls. It supports extra views now but requires additional
Lua admission/accounting, per-window scene/texture lifetime and native evidence.
If chosen, settle the bound and revise this contract before recording it.

A is recommended for the textured-quad milestone because it exercises real
per-instance window ownership without adding multi-window authoring yet. Its
cost is explicit: one script instance cannot make a tool palette or second
preview window, nor close/reopen a successful window while continuing. Later
window-management work may extend that surface. Qualification covers duplicate
admission, cancellation/completion order, close during startup, teardown that
does not synthesize a peer's quit, and retained retirement before slot reuse.

Evidence: the [GLFW host](../glfw.md) already has bounded multi-window ownership
and surfaces native close requests to application policy; a native close
callback neither destroys a window nor exits the process by itself. The new
composition must implement the policy above while preserving the delivered
protected native/graphics lifetime, not add Lua to native callbacks.

### P-49. Escalate a required asynchronous failure when its result settles

**A accepted by D-52 through Q-6i. Delivery: M1.** D-12 says a required
load failure fails its requesting operation, but does not settle whether Lua
must first read the asynchronous result. Recommend A: a required request's
failure latches an attributed failure of its requesting instance when the
failure becomes eligible to settle. The scheduler applies the failure at its
next safe boundary, before further ordinary Lua work for the failed owner.
Ignoring the request, discarding its handle, or catching a result-inspection
error cannot clear the latch. It does not interrupt a currently running
non-yielding Lua segment or undo its earlier resource/plain-Lua effects.

For presentation, eligibility is the existing arrival/first-settlement rule;
for logical requests it is the assigned tick/sequence, never early provider
arrival. A held early failure therefore does not leak into logical execution
before its assigned position. Once effective, use D-42's role policy: logical
failure stops logical work while healthy UI may report it; UI failure ends
the session. A failure that closes the startup gate still uses D-18/D-42's
boot-failure rules. This adds no world transaction, rollback or deferred
state-store fault semantics.

This covers accepted asynchronous required data/texture/window work. Modules
remain required under D-12; their exact import/evaluation API is separate, but
any required request stage owned by a runtime instance follows the same rule.
Pre-instance bootstrap/entry-loading failure is a boot failure, not an
unattributed request attached to a nonexistent instance.

An explicitly optional data/texture content failure remains a bounded failure
result Lua may inspect and handle; it does not latch instance failure. Optional
does not admit changed bytes, hide provider-code/engine/cleanup failures or
turn a window/module into an optional load. Successful results, optional
failures and winning intentional cancellations remain under ordinary request
accounting even if Lua never collects them. Capacity is not freed merely by
losing a Lua reference.

D-48/D-51 cancellation still uses first settlement: if cancellation wins, there
is no required failure to escalate; if failure wins, cancelling later cannot
erase it. Native/provider cleanup continues through its actual retirement and
retains failures. The terminal failure outcome remains even if another stop
reason arrives afterwards, subject to D-20's explicit second-signal exception.

Alternative B makes failure depend on Lua observing the result: an unobserved
required failure can remain stored while the instance keeps running. It gives
authors more control over when to confront an error but makes required loads
possible to ignore indefinitely. If selected, revise the required-load/failure
contract explicitly before accepting it; do not disguise it as mere API syntax.

A is recommended because 'required' then has a reliable meaning independent
of whether an author remembers to poll. Its cost is deliberate: speculative
data/texture work must be marked optional up front or cancelled before failure
settles; an unobserved required failure can stop the role/session. Qualification
must cover failure with no waiter or result read, optional failure, both cancel/
failure orders, and early logical failure held until its assigned tick.

Evidence: the [host request service](../../packages/scripting-lua/README.md)
already returns provider failure as result data and distinguishes arrival from
assigned-tick settlement. It does not itself establish this launcher's required-
content policy. Required-failure latching/supervision is additional M1 integration
work and must preserve the existing safe-boundary and retirement guarantees.

### P-50. Refuse capacity-full admission with a bounded busy result

**A accepted by D-53 through Q-6j. Delivery: M1.** Recommend A: before
accepting a new asynchronous data/texture/window request, reserve its request
slot and any required result-lease slot together. If a declared admission
capacity is full, return a bounded `busy` refusal identifying the exhausted
capacity (spelling still illustrative). Create no request handle, start no
provider/native work and leave no reservation behind. Busy is not an instance
failure, for required or optional requests: no load was accepted, so D-52's
required-result failure latch does not apply.

Lua must handle the refusal explicitly: consume settled results, relinquish
unused textures, wait for actual retirement or try again in a later update.
There is no hidden retry queue, automatic retry, busy-wait binding or promise
that capacity will become free. Losing references does not reclaim resources;
D-48/D-51 and the existing request accounting remain in force. An accepted
request has its result capacity reserved, including a successful texture/window
lease even if Lua never collects it. Settlement is not allowed to overbook
capacity reserved by another accepted request.

This distinction applies only to declared request/lease admission capacity.
Wrong arguments, wrong role/ownership and D-51's second-window request remain
their already specified errors; a request whose value exceeds a permanent
supported bound is not labelled temporarily busy. Engine/provider-code failures,
native allocation failure and cleanup faults are not converted to busy. Errors
after acceptance retain the approved required/optional/fatal classification;
an already accepted request never becomes an unaccepted admission refusal.
Numeric budgets and internal loader-stage pressure remain explicit API/provider
specification work, not an unbounded resource promise.

Check/reservation must be atomic under the owning admission mechanism, with
rollback of every reservation if admission cannot complete. A query-then-start
race or catching a fatal host refusal after the fact is not this contract.
Logical admission uses capacity released at the host's accounted scheduler
boundaries, preserving D-42's conditional ordering rules rather than reading
native completion timing through an unsynchronised side channel.

Alternative B retains fault-on-full admission: exhausting request/lease slots
fails the calling instance even if Lua catches the error, then the normal role
policy applies. This matches the current generic host's refusal behavior and
requires less new admission machinery, but a burst of loads or slowly retiring
textures can stop a session instead of allowing Lua to pace its requests.

A is recommended for real runtime loading with bounded resources. Its cost is
a distinct admission result authors must handle and an atomic reservation path
to qualify; it does not weaken the engine's existing fault semantics globally.
The new integration must use an explicit safe admission facility, extending a
narrow host interface if necessary. Qualification covers full capacity with
zero provider calls, no partial reservation, eventual reuse after real
retirement, and unchanged required-failure escalation after admission.

Evidence: [host request admission and lease capacity](../../packages/scripting-lua/README.md)
currently refuse full capacity as invocation faults, including a caught lease
capacity error. They already retain slots through settlement consumption and
provider retirement. The proposed non-fatal busy path is new M1 work, not a
behavior the existing API can be assumed to provide.

### P-51. Consume each accepted request's terminal result once

**A accepted by D-54 through Q-6k. Delivery: M1.** Recommend A: reuse the
host's `ready`, `take`, `wait` and `cancel` behavior for accepted data/texture/
window requests, under the new integration's namespace/result schemas. D-53's
busy response contains no request handle and is not a pending request. A
request belongs to its requesting instance; sharing its handle through a
module does not grant another instance permission to inspect or consume it.

- `ready` reports whether a settlement is available without consuming it.
- `take` on a pending request reports pending and consumes nothing. On a
  terminal success, optional failure or cancellation it returns the bounded
  settlement once and invalidates the request handle.
- `wait` cooperatively suspends an eligible update/event invocation until
  settlement; it does not consume the result. Call `take` afterwards. It never
  blocks the VM's owner thread and is forbidden in finite init/shutdown hooks.
- `cancel` retains the already approved first-settlement rules. Cancellation
  is a terminal result to consume, not a way to skip result accounting.

Logical `ready`/`take`/`wait` obey assigned-tick visibility; early native
completion is not visible. Presentation uses its elapsed/arrival settlement.
D-52's required failure stops the owner at the eligible safe boundary rather
than waiting for `take`; optional failure remains data for Lua. Request
consumption does not erase an already latched failure.

A successful texture/window result supplies its already engine-owned lease.
Taking the result does not release that lease; it stays owned by the instance
under D-48/D-51. Lua may retain the copied data/result and reuse its own live
resource handle as permitted, but may not take the same request again. Reusing
a consumed/foreign request handle is the host's call fault, not another copy
of the result or a silent no-op. Store the returned result and stop using the
request handle after consumption.

Request capacity is reclaimed only after terminal consumption (or internal
discard on instance/session end) and actual provider retirement. A result or
cancelled request never consumed still occupies its slot; `ready` and `wait`
alone do not free it. No public discard/forget operation is added in A. Lua
takes a cancelled/optional-failure result to clear its interest; takes and
explicitly releases a successful texture if no longer wanted; a successful
window retains D-51's no-independent-close rule. Automatic cleanup handles
every uncollected result at instance/session end, without relying on Lua GC.

Alternative B retains a terminal request object whose result can be read
repeatedly, with a separate explicit forget/dispose operation and a defined
relationship to any resource lease it carries. It may be more convenient for
polling authors but adds a second public lifetime to end, retained result
storage and more sharing/disposal cases. If chosen, specify that lifecycle
before approval; it must not become an unbounded cache or let forgetting a
successful window bypass D-51.

A is recommended because it fits the existing host's bounded result model
and separates a short-lived request from the resulting data/resource lifetime.
Its authoring cost is explicit consumption: polling-only code can fill its
slots, and a second take is misuse. Qualification covers pending takes,
one-time terminal consumption, wait without consumption, cancellation cleanup,
capacity held after consumption while a provider retires, and request ownership
across two real instances. Module-import/cache behavior remains a separate
contract; this does not turn shared module exports into one-shot values.

Evidence: [host requests](../../packages/scripting-lua/README.md#what-a-script-sees)
and `Hetoimasia.Scripting.Lua.Request.requestBindings` implement these four
operations, including pending takes and terminal handle retirement. D-52/D-53's
required-failure and busy-admission policies still require new integration work;
reusing result operations does not claim those changes already exist.

### P-52. Data loading returns a bounded copy of the file's bytes

**A accepted by D-55 through Q-6l. Delivery: M1.** Recommend A: a data-file
request reads one scoped content file and succeeds with its complete bytes as
a Lua string. Preserve bytes exactly, including embedded zero bytes, invalid
UTF-8, byte-order marks and line endings; do not decode, normalize, parse or
execute the file. Paths/IDs remain validated text. Both logical and presentation
instances use this data service under their existing result timing and grants.

Use D-10/D-11's startup identity/fingerprint and no-link path rules on the
actual bytes read. Enforce the data-file/result size bound while reading and
before exposing the result, including the request envelope's overhead. An
oversized file fails as a bounded content result under D-12/D-52, not as a
truncated success or a temporary admission-busy response. Exact limits belong
to the common budgets/API specification. D-53 admission and D-54 consumption,
cancel/wait rules remain unchanged.

Each request reads/verifies its own bytes; M1 introduces no engine data-file
cache or open-file/stream handle for Lua. On take, Lua receives an ordinary
copied string, with no native resource lease to release. Native file handles,
buffers and request accounting retire through the provider's cleanup. The
string Lua retains afterwards has ordinary Lua memory lifetime; per-result
limits are not a bound on all memory a trusted script may retain. Authors may
cache or parse their own data using pure Lua and the already approved module
mechanism, without granting ambient filesystem access.

This is data input, not another script-loading route. D-5's removed `load`,
`loadfile`, `dofile` and package mechanisms stay removed; Lua source evaluation
uses the separate engine module loader with D-7/D-8's identity/effect rules.
No JSON schema, serialization framework, gameplay state store, saved-data
writer or general file I/O is added by this result type.

Alternative B provides an engine-parsed structured format, such as JSON,
alongside or instead of raw bytes. It gives authors ready-to-use tables but
requires a chosen format and contracts for null, integer/float range, duplicate
keys, nesting/size bounds and failure locations. If chosen, present that exact
format/value contract for signoff rather than inferring it from the deferred
state-store decisions. Byte loading alone does not rule out a later parser
service or authored pure-Lua parser.

A is recommended because it completes reusable scoped data access without
coupling the engine to a game's data format. Its cost is explicit: Lua authors
must validate text encoding and parse structured data themselves, and repeated
requests repeat I/O/copying. Qualification covers byte-for-byte results with
NUL/non-UTF-8 content, empty files, exact/over-limit sizes, changed content,
required/optional failures and provider cleanup on cancellation.

Evidence: the [Lua value boundary](../../packages/scripting-lua/README.md)
already distinguishes byte-string and UTF-8-text schemas over Lua's string
type and bounds copied values. The scoped filesystem provider and result-size
accounting are new M1 integration work; no existing ambient Lua I/O is reused.

### P-53. Discover dependencies through resumable module-level imports

**A accepted by D-56 through Q-2h. Delivery: M1.** D-7/D-8 allow a module
to import dependencies at top level, while D-9 requires real runtime loading
and D-15 forbids waiting in init. The missing choice is how dependency reads
and evaluation fit those boundaries. Recommend A: a module-level engine import
can suspend that module's loader continuation while a missing dependency's
verified source is read/evaluated, then resume with its completed export table.
An illustrative `local util = import("lua/util.lua")` therefore needs no second
dependency list. Names may be computed by permitted Lua code; all references
still obey the explicit content-root/path rules. Exact API spelling is open.

This suspension belongs to an engine-managed module evaluation, not to an
instance's init hook. Only the module-import mechanism may suspend that loader
for dependency work; general clock/request waits and effectful service calls
remain unavailable at module top level under D-8. The VM owner stays available
to make required progress rather than blocking inside a filesystem binding.
All Lua evaluation/resumption happens through the VM's protected owner; no
native binding re-enters its own VM or runs Lua on a provider thread.

Before root init, the launcher finishes loading/evaluating that role's entry
and its discovered dependencies and validates the behavior as already required.
Within lifecycle hooks, already-loaded exports can be obtained without waiting.
An uncached runtime module is requested explicitly and becomes available later;
init may start that request but cannot synchronously import-and-wait for it.
An attempted uncached immediate lookup from a hook is refused, not a blocking
shortcut. A later update/event can observe or cooperatively await completion
and then use the cached exports. The module-request result/lookup API is still
to be specified; it must keep Lua tables/functions inside their VM rather than
send them through copied provider-value schemas.

D-7 remains: one evaluation per root/path per VM, the same successful exports,
cycles rejected with their path chain, failures retained without retry, and no
partly initialized exports. D-8 still grants no acquiring instance's resource
authority to a dependency. Top-level logs or mutations of already shared Lua
tables are not rolled back. This makes evaluation timing observable: a logical
runtime load must not execute new module top-level code before its assigned
service position. If discovering/fetching dependencies then takes longer, hold
logical progress there while the separate UI can continue; do not leak early
effects or stretch/drop ticks. Presentation evaluates through its own safe
arrival/scheduler boundaries. A trusted non-yielding module can still hang its
VM; resumable I/O is not preemption or hostile-code containment.

Alternative B requires a non-executable dependency declaration for each module,
loaded before evaluating it. Top-level imports only look up those completed
declared dependencies; undeclared imports are refused. This avoids suspension
inside module evaluation but makes authors maintain dependency metadata beside
their Lua and prevents discovering an unlisted dependency from executing code.
It must still provide genuine runtime loading of the declared graph, preserve
D-7 cache/failure rules and keep init finite. Its metadata format would need
separate signoff if selected.

A is recommended for the Lua-first direction because dependencies stay beside
the code that uses them, with demand loading and once-per-VM exports intact.
Its cost is substantial and explicit: a protected resumable loader, per-VM
dependency/cache state, cycle detection and integration with logical service
positions. It is not a wrapper around synchronous file reads. Shared in-flight
imports, cancellation when callers go away, exact limits and the module API
need subsequent concrete contracts whichever route is chosen; those are not
silently decided by selecting this dependency mechanism.

Evidence: the [current Lua host](../../packages/scripting-lua/README.md#modules-and-entry-points)
loads application-supplied text into distinct module environments and exposes
declared entry points, not this Lua-to-Lua export-table/import protocol. Its
callback boundary refuses VM re-entry. The new loader must extend a narrow
owner-controlled path and qualify suspension, effect eligibility, cycles,
logical visibility and independent UI progress before being called delivered.

### P-54. The VM owns an admitted module load; instances own their waiters

**A accepted by D-57 through Q-2i. Delivery: M1.** Recommend A: maintain
one bounded loader/cache entry per `(content root, path)` in each VM. Requests
for the same pending module join that load; they never evaluate it twice or
receive partial exports. Each instance has its own request/waiter, but the VM
owns the source/dependency work and evaluation continuation from admission.
This implements D-7's shared module identity, distinct from D-49's intentionally
independent texture loads.

Cancelling a module request, or ending its requesting instance, withdraws only
that waiter. It cannot cancel a peer's request or the admitted module job.
**Even the last waiter leaving does not stop the module load while the VM
continues.** It completes into the ready/failed cache for later importers.
Cancellation still obeys settlement ordering and cannot erase a failure that
already settled for that waiter. A cancelled waiter never receives exports.
No implicit retry or rollback of top-level logs/shared-table changes occurs.

An admitted logical module job retains its assigned evaluation obligation even
if all external waiters leave. It can still hold logical progress at that
position until dependencies/evaluation finish, while UI runs independently.
Cancelling the waiter is therefore not a promise to eliminate its loader work
or tick delay. New top-level execution never moves early because of cancellation.
Pending imports from another module also remain dependencies of that module's
load, with D-7's cycle-chain rejection; an external waiter leaving cannot break
that internal dependency.

On ordinary source/evaluation failure, keep D-7's failed cache entry. Every
still-active required waiter fails through its own eligible settlement under
D-52. If none remain, retain an attributed loader diagnostic and failed entry
without inventing a new instance failure; a later request encounters that cached
failure and fails normally. A boot entry/dependency failure still fails boot.
Actual engine/provider-code/cleanup failure remains fatal regardless of waiter
count. A successful job publishes its complete exports into the VM cache,
shared by later importers as already decided.

Keep ownership/accounting explicit: the VM's load-job and module-cache bounds
account for the continuing shared work and cached outcome. A waiter's request
slot may retire after its settlement is consumed/discarded and its subscription
is detached safely; that means only the subscription ended, not the module job.
The job's reads, callbacks and continuation remain charged to their VM owner
until genuinely settled/retired. Do not leave them attached to a dead instance,
silently transfer an instance's native obligation at cancellation, or hide them
in an unbounded background queue. Exact bounds and admission/result API follow.

When the VM/session itself stops, stop admitting or resuming ordinary module
evaluation, cancel pending provider interest and retire all actual source work
through protected cleanup. There is no requirement to finish executing modules
for a VM that is ending. A currently non-yielding trusted chunk remains the
existing non-preemptible case; never claim it stopped or cleaned up early.
This VM-owned loader state is not a new module-lifetime resource-acquisition
scope: D-8 still prohibits textures/windows/data-service acquisition at top level.

Alternative B abandons a module load when its last dependent/waiter leaves.
It can save work but requires cancellation states for partly evaluated modules,
the disposition of their failed/abandoned cache entries and already-completed
dependencies, and a rule consistent with once-per-VM evaluation and no rollback.
If chosen, design that revision explicitly before adopting it.

A is recommended because one instance's lifetime should not poison or restart
the shared module another instance may import later. Its cost is deliberate:
cancelled interest can leave work, logs/shared-table effects and logical tick
delay until the module finishes or the VM stops, consuming bounded VM capacity.
Qualification covers joining one evaluation from two instances, ending one or
all waiters, cached success/failure afterwards, assigned-position execution with
no waiters, cycle detection and shutdown while dependency reads are outstanding.

Evidence: the [host request service](../../packages/scripting-lua/README.md)
distinguishes cancellation of interest from provider retirement, but it does
not supply this shared module-job owner. D-7 and D-56 require new per-VM loader
state; the subscription-versus-job accounting proposed here must be implemented
and qualified explicitly, not inferred from existing request cleanup.

### P-55. Evaluate one module dependency chain at a time in each VM

**A accepted by D-58 through Q-2j. Delivery: M1.** Recommend A: serialize
module evaluation within each VM. Independent root jobs start in assigned
tick/sequence order for the logical VM, and admission order for the UI VM.
An earlier root waiting for source bytes holds its place; faster I/O for a
later root does not let that root's top-level code overtake it. Source reads
may overlap within the eventual provider bounds, but evaluation follows this
order. Each active module evaluates its imports depth-first, in Lua call order,
resuming its own code only after each imported module has complete exports.

An import reuses a ready cache entry or a failed entry under D-7. A missing
dependency is loaded as part of the active chain. If that dependency already
has a queued job, reuse that job and evaluate it now as a dependency, rather
than waiting behind the importing root or creating a second evaluation. An
import of a module already on the active chain is a cycle: reject it with the
root/path chain, never expose partial exports or wait for the module itself.

**This requires an explicit timing refinement to D-56/D-57.** For example,
module A is due at logical tick 10 and imports B, which was independently
requested for tick 12. B executes once as A's dependency at tick 10, and A can
then finish. B's independent request still settles only at its own assigned
tick/sequence position; it does not deliver a success or escalate its failure
early. The ready/failed cache entry exists from the dependency evaluation, so
an immediate cache lookup can encounter it before that separate request is
due. A dependency failure affects A at A's position. B's later job obligation
becomes delivery of the already computed outcome, not another evaluation or
another wait for source bytes. Cancellation still removes only a waiter.

Thus the earliest actual evaluation is at an eligible importing chain's
position, or at the module's own scheduled root position if reached first;
native arrival alone never starts logical top-level execution early. The
owner approved this qualification in D-58; D-56's original timing sentence
alone did not cover dependency promotion.

Serialization applies to module evaluation, not every task in the VM. While
the UI loader waits for I/O, eligible UI instance hooks and stop/control work
can run through the existing scheduler. The loader resumes through that
protected owner and obeys its service policy; no new hook priorities, authored
phases or re-entrant Lua calls are introduced. Logical progress still waits
when a due module chain is unfinished, while the separate UI VM can continue.
The two VMs do not share an evaluation queue. D-8's effect limits, D-57's
job ownership, and the absence of rollback for logs/shared Lua tables remain.

Alternative B allows independent module evaluations to interleave while one
waits for dependencies. This can reduce delay behind slow reads, especially
in the UI VM, but requires rules for cross-job dependency waits, cycle
detection and observable top-level effect order. Logical assigned positions
would still constrain execution. If selected, design that contract explicitly.

A is recommended for M1 because it gives authors a clear dependency order and
avoids two suspended roots waiting on each other through separate jobs. Its
cost is that one slow dependency delays unrelated module evaluation in that
VM, even when the unrelated file is ready; it does not guarantee module
completion time. Limits and capacity refusal inside a dependency chain are
still open, and must not introduce a wait for capacity that only finishing
that same chain could free.

Qualification covers reversed source-completion order, nested imports, reuse
of a later queued dependency without duplicate execution, separate ticket
visibility/failure timing, cycle paths, cancellation of all external waiters,
UI hook progress during source waits and VM stop. The existing host's FIFO
ready ordinals govern scheduling (see the
[host scheduler](../../packages/scripting-lua/README.md#policies)); they do not
already provide this module queue or dependency-promotion protocol.

### P-56. Refuse permanent module limits without waiting for cache space

**A accepted by D-59 through Q-2k. Delivery: M1.** D-7/D-57 retain module
identity and ready/failed outcomes until VM end. Unlike request slots, those
entries do not become free after taking a result, cancelling a waiter or
releasing a texture. Recommend A: use a bounded per-VM identity cache counting
pending, evaluating, successful and failed modules, including entries and
dependencies. No eviction, unloading or re-evaluation is introduced in M1.
The numeric limit, source-byte limit and dependency-depth limit belong to the
forthcoming concrete bounds/API package; this checkpoint selects their failure
semantics, not unmentioned numbers or a configuration mechanism.

For a hook requesting a new, uncached identity when that permanent cache is
full, refuse before admission with an ordinary Lua error identifying the
module limit. No request handle, job, source read or failed-cache entry for
that refused identity is created. Lua may catch this pre-admission error and
continue using already-known modules; uncaught errors use the normal instance
failure policy. It is not a temporary `busy` result, and waiting or cancelling
other requests will not free a module identity. Existing cached modules and
joining already-admitted jobs do not require another identity slot, although
a new instance request still needs its own request/result capacity.

Reserve a root's needed request/result and new identity/job metadata together
before accepting it. Temporary exhaustion of reclaimable request capacity
uses D-53's nonfatal `busy` semantics: no half-reservation or hidden retry.
Successful root admission does not promise room for every dependency the Lua
code might later discover. There is no speculative dependency declaration or
unbounded reservation of an unknown graph.

If an admitted chain discovers a new dependency with no identity space, or
exceeds its source-byte or dependency-depth bound, fail that module load with
an attributed limit reason and import chain. Do not wait for cache space or
retry the evaluation. Retain the failed outcome for each already-admitted
module whose required dependency fails; allocate no extra cache entry for a
dependency refused before admission. Already-completed dependencies stay
cached. Catching the failed required import inside module code cannot turn
the containing failed load into a successful cache entry. Partial Lua effects
are not undone. Existing D-52/D-57 rules govern required waiters, eligible
logical settlement, diagnostics without waiters and boot failure.

This prevents an active chain from waiting for space that only its own
completion could release. Bounded source workers/buffers must likewise make
progress or refuse explicitly, not deadlock behind the suspended chain. Their
exact concurrency and reservation arrangement is part of provider design;
this is not a promise that admission pre-reserves all native resources.

Alternative B makes permanent module-capacity exhaustion a VM failure even
when detected before a new root request is admitted. That gives every such
limit violation the same terminal treatment, but a speculative extra module
request would stop its role/session despite all existing modules remaining
usable. Accepted-load failure behavior otherwise stays the same.

A is recommended because it distinguishes work never admitted from a required
load that has failed after acceptance, consistent with D-53. Its cost is an
explicit permanent-limit error alongside `busy`, plus the possibility that
an accepted root later fails on a discovered dependency limit. Failed entries
consume the lifetime budget too; authors must fit the session's module set,
and cannot recover slots by dropping Lua references. This bounds loader
bookkeeping and source inputs, not arbitrary allocations or execution in
trusted Lua.

Qualification covers full-cache root refusal with no work/reservation leak,
cached access and joining at the limit, temporary request saturation, a
dependency hitting the last slot, depth/source failures, caught required-import
failure, retained completed dependencies, cancelled waiters and logical timing.
Evidence: the current host's `Internal/Module.hs` bounds modules at 256 and
each source at 1 MiB, and refuses before loading; those are existing facts,
not automatically the new loader's selected numbers. Its loaded-handle map
does not supply this pending/failed cache or dependency-limit supervision.

### P-57. Require literal root-relative paths instead of normalizing shortcuts

**A accepted by D-60 through Q-2l. Delivery: M1.** Recommend A: every
module, data and texture reference names an explicit file relative to its
selected content root, using `/` between nonempty path segments. For example,
`lua/util.lua` names that file from the root, not from the importing script's
directory. D-6 still determines the selected content root; concrete syntax
for explicitly naming a root remains part of the API package.

Reject an empty path, leading or trailing slash, repeated slash, a segment
equal to `.` or `..`, backslash, colon, NUL or other control characters.
Paths are valid UTF-8 text, never native byte paths. Do not trim whitespace,
expand `~` or environment variables, interpret URLs, or search the process's
working directory. Absolute paths, drive paths and network paths are not
content references. Do not add an extension, search an `init.lua`, or try
alternate filenames: `lua/util` names precisely a file called `util`, not
`util.lua` or `util/init.lua`. File type/decoder eligibility is separate.

This choice is about separator/dot-segment grammar and explicit file selection.
Filename character repertoire beyond these exclusions, case matching,
Unicode normalization/collision handling and numeric path limits still need
their own concrete naming contract. In particular, accepting UTF-8 at this
boundary is not a promise that every Unicode filename is portable across
supported filesystems. The startup inventory and later opens must use the
same eventual identity rules; no implementation may silently inherit a host
filesystem's alias behavior as the Lua module-cache contract.

Validate syntax before request admission or filesystem work. An invalid hook
argument is an ordinary Lua error, including for optional loads; it is not
`busy` or an optional missing-file result. Invalid entry references in the
manifest fail validation before Lua. An invalid import inside engine-managed
module evaluation fails that required import/load under D-59, without opening
the path. A syntactically valid but unavailable file follows existing content
failure rules; this grammar does not hide missing or changed files.

Alternative B accepts convenient relative spellings such as `./lua/util.lua`,
repeated separators, backslashes and `lua/helpers/../util.lua`, normalizes them
to one root-relative key, and rejects any escape beyond the root. Root selection,
explicit filenames and no ambient filesystem access remain the same. B needs
precise normalization and diagnostic rules so aliases cannot create duplicate
module evaluations, cache entries or fingerprint identities.

A is recommended because authored references have an explicit spelling and
one separator convention without a path-rewriting layer. Its cost is that
authors must write the full path from the content root and change scripts
using native separators or dot-segment shortcuts; imports do not become
relative to their source file. This is a validation contract, not a substitute
for D-11's actual no-symlink opening/retirement rules or proof against races.

Qualification covers each refused spelling before native work, explicit
root-relative resolution from nested scripts, no extension/directory fallback,
manifest validation and required/optional failure classification. The current
Lua host accepts application-supplied module bytes and has no scoped content
path resolver; this is new content-service behavior, not an existing host API.

### P-58. Use case-sensitive Unicode filenames with canonical identity

**A accepted by D-61 through Q-2m. Delivery: M1.** Recommend A: permit
Unicode filenames satisfying D-60, normalize each filename segment to Unicode
NFC for logical identity, and require case-sensitive matching of that identity.
Apply the same conversion to manifest paths, Lua references and names found
by the startup inventory. `images/Hero.png` does not match `images/hero.png`,
even when the native filesystem would accept that spelling. The two canonical
Unicode encodings of an accented name, such as a composed `é` and `e` plus
combining acute, do name the same inventory entry. This answers the Unicode
question left open by D-60; it does not permit dot-segment/path shortcuts.

The inventory maps each logical name to its observed native directory entry;
later opens use that mapping with D-10/D-11's checks. Never simply pass a
normalized user string to a permissive native lookup and let it select another
spelling. Do not rename files on disk. Every path segment, including directory
names, participates. Shared module identity and all fingerprint/request keys
use the same normalized root-relative path. This changes names only, never
file contents, data-file bytes, Lua source text or authored display strings.

Before Lua, reject distinct sibling entries that collide after NFC conversion
or Unicode canonical caseless comparison, naming both entries and their root.
For example, a root containing both `Hero.png` and `hero.png` is refused;
case folding detects a collision, but never provides case-insensitive lookup.
The same applies to file/directory collisions. Use a fixed, documented Unicode
table version for the engine build, independent of locale; its concrete library
and version belong to implementation qualification, not ambient OS settings.
Reject non-UTF-8 or D-60-invalid inventory names rather than silently hiding
them. This is a conservative unambiguous namespace, not a guarantee that every
legal name can be copied to every possible filesystem. Native alias behavior
must not bypass the checked inventory; platforms unable to address a root
unambiguously must refuse it, not guess an entry.

A well-formed reference whose case does not match is a missing-content result
under the existing required/optional rules, not an alternate spelling that
opens the file anyway. Cached module lookups use the same keys. All existing
startup fingerprint, later changed-file refusal and no-symlink rules remain;
the launcher spelling of the selected root folder is separate from names
inside that root. Content IDs and numeric path limits remain in the forthcoming
manifest/bounds contract, not inferred from filename rules.

Alternative B restricts filenames inside registered content roots to printable
ASCII satisfying D-60, with exact case lookup and rejection of ASCII-case
collisions. Non-ASCII inventory names fail startup and non-ASCII references
are invalid arguments. It needs no Unicode normalization/case-folding layer;
authors rename accented and non-Latin filenames. Both profiles preserve spaces
and other permitted characters literally, without trimming or expansion, and
neither promises names unsupported by the destination filesystem will work.

A is recommended so author-chosen international filenames need not be renamed
for this milestone, while module identity is explicit across encodings. Its
cost is Unicode normalization and collision checking, bounded mappings to
native names, and platform qualification; ambiguous roots fail boot even if a
particular filesystem can distinguish their entries. B is smaller if that
authoring restriction is preferable for M1.

Qualification covers composed/decomposed names sharing one module evaluation,
case mismatch without native fallback, normalization/case collisions in files
and directories, spaces preserved, invalid native names, and unchanged raw
data results. The meaning of NFC and canonical equivalence comes from
[Unicode UAX #15](https://www.unicode.org/reports/tr15/); case folding is a
separate operation described in the
[Unicode case-mapping FAQ](https://www.unicode.org/faq/casemap_charprop.html).
These standards supply algorithms, not an already implemented content provider.

### P-59. Inventory and hash the selected content tree before starting Lua

**A accepted by D-62 through Q-2n. Delivery: M1.** D-10 chose startup
fingerprints rather than a private content snapshot. Recommend A: walk the
entire selected game content root before Lua, apply D-11/D-60/D-61's entry and
name checks, and fingerprint every regular file, including hidden files and
files the scripts may never request. No automatic extension filter, ignore
list or separate authored asset list is introduced. M1 still enables only the
one explicitly selected game root, not discovered mod folders.

Stream each file through a SHA-256 digest with a bounded read buffer; retain
its root-relative identity, native-entry mapping, byte length and digest in
a bounded inventory. Do not retain a private copy of the tree or decode images,
parse data or evaluate modules during this pass. Fingerprinting a Lua file
does not allocate a module-cache slot. The manifest used for launch must be
the same bytes pinned for it, not a preliminary parse of one revision followed
by fingerprinting another. Exact entry/path/per-file/total-byte limits belong
to the bounds package; exceeding any inventory limit fails boot explicitly.

An unreadable file, invalid entry, naming collision, detected change during
the scan or inability to complete within those bounds fails boot with an
attributed diagnostic, even for a file the game would not have requested.
Do not silently omit it or automatically retry the scan. This pass precedes
the root-init gate and the Lua loading screen under D-18; large trees can
therefore delay any authored window. A content folder should contain the files
the author intends to ship, rather than unrelated development/build output.

On each later uncached byte load, open the inventoried path under the eventual
race-safe no-link protocol, bound the read and verify its length and digest
against the inventory. Only the exact verified bytes may be passed to Lua,
the module evaluator or the image decoder; never hash one open and consume
another unchecked read. Keep only that request's bounded buffers/resources,
then retire them under their provider owner. Metadata alone never permits
skipping byte verification. Same-length edits are detected; a timestamp-only
change or replacement by identical bytes is acceptable if the checked path
still resolves legally. This is content identity, not a promise to preserve
the original file's native inode identity.

A missing/changed inventoried file is refused under D-10 and required/optional
load rules. A new path cannot join the session inventory. Already-cached
modules and already-loaded textures remain their original objects, as decided;
new data/texture requests read and verify again. No watcher, automatic reload,
background inventory refresh or persistent trusted hash cache is added.

The initial scan records the bytes observed for each file, not an atomic
snapshot of the whole directory tree. Authors must leave the content stable
during boot; detected concurrent changes fail boot, and later loads still
verify their bytes. This is not hostile-filesystem containment. Root anchoring,
link/race handling and native opening must be qualified separately; hashing
alone does not prove that the read stayed inside its enabled root.

Alternative B adds an explicit manifest list of content files and fingerprints
only those files; unlisted files are unavailable even if present in the folder.
It reduces hashing of unrelated files but requires authors to maintain the
complete list, including runtime-discovered module dependencies, data and
textures. It would need a concrete manifest/list and directory-validation
contract before adoption; it does not allow a first-use fingerprint that
silently accepts edits made after startup.

A is recommended for the folder-based launch contract because runtime loading
needs no duplicate authored asset/dependency list. Its cost is reading every
file before Lua and again when requested, retaining bounded metadata, and
failing boot for unusable unused files. Qualification covers hidden/unrequested
files, scan failures and bounds, same-size edits, metadata-only changes,
identical replacement, missing/new paths, matching manifest bytes, and delivery
from the exact verified buffer. The repository already uses SHA-256 for native
shader-toolchain fingerprints (`packages/gpu-vulkan/native/README.md`); that is
algorithm/dependency evidence, not a content-provider implementation or a reason
for the content service to depend on the graphics toolchain.

### P-60. Resolve the launcher-selected folder once and retain its directory owner

**A accepted by D-63 through Q-2o. Delivery: M1.** D-11 explicitly left
launcher root selection separate from its ban on internal symbolic links.
Recommend A: the owner may give the launcher a native relative or absolute
directory path, including symlinks in that selection path. Resolve it once,
open the actual directory and establish its identity before reading the manifest
or inventory. Relative launcher paths use the launch working directory;
Lua content paths never do. The launcher does not itself expand shell syntax
or change the process working directory. Report the selected/resolved root
in startup diagnostics so the launch target is reviewable.

The session owns a protected directory handle to that actual root, not merely
a canonical pathname string. A later rename of the root, replacement of its
old pathname or retargeting of the selection symlink does not select a new
root. Continue against the originally opened directory if it remains readable;
ordinary missing/changed-content failures still apply to its contents. There
is no path watcher or automatic reopening of another root. This is a pinned
directory identity, not a snapshot of the directory's mutable contents.

All inventory and later content opens are anchored to this owner. Apply the
checked native-name mapping and refuse symbolic links at every component below
the root, including the final file, during the actual open. Establish directory
and regular-file types on opened objects; do not rely on a prior `exists`,
`canonicalize` or link check followed by an unrestricted pathname read.
Hold each operation's intermediate/native handles until the read no longer
needs them, verify the same opened file's bytes under D-62, then retire them.
Observed path/type/name changes that invalidate a mapped entry fail that scan
or load; they are not silently normalized into a new session identity.

Use qualified native directory-relative/no-follow operations on each supported
platform. No string-prefix containment test or weaker ordinary-open fallback
counts as this implementation. A platform/filesystem that cannot supply the
required behavior refuses the root at startup with a clear unsupported-root
diagnostic. The exact native adapter and flags require implementation evidence;
this proposal does not declare an untested Haskell helper race-safe.

Root and operation handles have explicit resource ownership. A root may close
only after its scan/load workers have actually retired, including cancellation
and late completions; asking them to stop is not sufficient. Partial boot
failure closes all acquired handles through protected cleanup. Failed cleanup
retains the established fatal/reporting policy. Lua receives content identities
and service results, never native directory handles or ambient path access.

Alternative B uses the same anchored internal-read protocol but rejects any
symlink in the launcher selection path as well. The owner must supply a fully
resolved path without symlinked ancestors. It removes that launch convenience,
but does not eliminate the native ownership/no-follow work inside the root.

A is recommended because selecting a root is an explicit owner/launcher action;
it need not have the same spelling restrictions as script-supplied path arguments
inside Lua. Its cost is stable directory ownership, platform-specific opening
and race/cancellation tests. A renamed selected folder can remain active until
restart, and retargeting a launch symlink deliberately has no live effect.
This preserves D-2's trusted-content model; it does not claim containment of a
hostile OS actor performing arbitrary concurrent filesystem/mount changes.
Hard-link/mount policy and numerical open-handle limits remain separate.

Qualification covers a symlink-selected root, root rename and symlink retarget,
replacement of an internal directory or final file by a link during controlled
open boundaries, rejected non-regular entries, exact-name mapping, read failure,
and cancellation/boot failure with live handles. Coordinate races explicitly,
not with timing sleeps. The
[POSIX open/openat specification](https://pubs.opengroup.org/onlinepubs/9799919799/functions/open.html)
provides directory-relative and no-follow primitives; using them safely for
every component and qualifying the platform adapter is additional work. The
current runner's `Runner/Source.hs` reads explicit files with `withBinaryFile`;
it is not this scoped provider and must not be treated as one.

### P-61. Treat hard-linked files and mounted directories as selected-root content

**A accepted by D-64 through Q-2p. Delivery: M1.** Recommend A: the
selected root defines a content namespace, not exclusive ownership of the
underlying storage. A regular file reached through a legal inventoried path
may have other hard-link names, inside or outside the root. A directory below
the root may be a mounted filesystem or a bind-mounted subtree, provided the
native provider can uphold D-63's opening and ownership contract there.
The launcher/Lua service creates no links or mounts; these are arrangements
the owner has already made. Internal symbolic links remain refused under D-11.

Each root-relative path remains its own content identity. Two hard-link names
for one Lua file are two modules under D-7, each evaluated once per VM; do not
silently coalesce them by native file identity. Inventory entries, byte budgets
and fingerprints count each path, even when storage is shared. Texture requests
remain independent under D-49. An outside hard-link name is never a Lua lookup
path, but editing the shared file through it can cause the next inside load
to fail D-62's byte check. This is an explicit consequence of allowing hard links.

Whole-root scanning includes reachable mounted content; it is not silently
skipped as another device. Detect directory traversal cycles through native
directory identity on the active ancestor chain and fail boot with the path
chain, rather than recurring indefinitely. Reaching the same directory through
separate non-cyclic paths does not merge their logical identities; ordinary
inventory depth/count/byte limits still bound expansion. Native providers unable
to establish the necessary identity or opening behavior refuse that root.

No device or mount identifier becomes an additional content-version key under
A. A later topology change grants no new logical paths and no exception to
name/type/no-link checks or byte fingerprints. Missing or different content
fails normally; identical-byte replacement through a still-legal inventoried
path remains permitted by D-62. The root itself stays anchored under D-63.
This is not a promise that mounted content remains available or that an
external filesystem operation can be interrupted promptly.

Alternative B rejects multiply linked regular files and refuses mount crossings
below the selected root, at startup and later opens. Authors copy those files
and place content directly in the selected tree. The selected root may itself
live on another volume; B concerns crossings beneath it. It needs qualified
native link-count and mount-boundary checks, including bind mounts rather than
only a device-number comparison. It still does not establish containment
against arbitrary hostile OS changes or make the content immutable.

A is recommended for trusted owner-selected content: path identity and verified
bytes already define what the session consumes, without requiring exclusive
physical storage. Its cost is external aliases affecting those bytes, mounted
storage affecting availability/scan duration, and duplicate work for aliased
paths. B provides a stricter packaging restriction with extra native checks.
Neither alternative changes D-11's rejection of symlinks, devices, sockets,
pipes and other non-regular content entries.

Qualification covers two hard-linked Lua paths keeping separate module caches,
outside-name edits being refused on later reads, per-path inventory accounting,
mounted subtree inclusion or refusal as selected, traversal cycles, and existing
root/read cleanup. Qualify mount behavior in isolated supported-platform
fixtures; classification/identity boundaries also need controlled tests without
sleeps.
For terminology, [POSIX link](https://pubs.opengroup.org/onlinepubs/9699919799/functions/link.html)
defines another directory entry for an existing file, while the
[Linux mount documentation](https://cdn.kernel.org/doc/html/latest/filesystems/sharedsubtree.html)
describes mounted subtree relationships. Neither is a symbolic-link traversal.

### P-62. Expose static PNG colour textures for M1

**A accepted by D-65 through Q-6m. Delivery: M1.** Recommend A: the Lua
texture request accepts static PNG images through the existing `asset-image`
PNG decoder, always as `ColourImage`. Select by the verified bytes' PNG
signature, not the filename extension. There is no format hint, extension
search or trial of unrelated codecs. Non-PNG bytes, malformed PNGs and
animation-marked PNGs are refused as content failures under the request's
required/optional policy. No first-frame-only fallback for animation is added.

Reuse the existing PNG profile: greyscale, palette, RGB/RGBA, supported bit
depths and interlacing become one tightly packed RGBA8 level, top row first.
The decoder's colour contract interprets colour channels as sRGB and
premultiplies in linear light; alpha is retained, with opaque alpha supplied
when absent. Its existing 16-to-8-bit conversion and transparency rules remain.
Embedded colour-space/profile chunks do not change decoded texels. There is
no M1 Lua switch for data textures, linear/HDR colour, premultiplication or
colour-profile processing. This is the existing engine colour convention,
not an additional conversion for Lua on top of the decoded result.

Upload that one level and return D-47's ready owned texture plus its dimensions
only after upload/registration readiness. Generate no mip chain. D-50's full
image, fixed nearest filtering and alpha-blended ordered rectangles remain;
do not infer new sampler, UV, animation or material controls. Missing/bad/over-
limit content has no placeholder or implicit format conversion fallback.
An unsupported texture file may still be loaded as raw data under D-55.

The provider must enforce source-byte, dimension, pixel-count and decoded/work
memory bounds before the corresponding large allocation/work, with checked
arithmetic. A small compressed file is not permission for unlimited decoded
storage. Preflight and decoder integration must be qualified; the current
decoder's format checks alone are not proof of the new provider's resource
budget. Numeric limits follow in the bounds package. Cancellation may suppress
delivery while an already-started decode finishes; buffers and upload work
remain owned and charged until actual retirement, as in D-47/D-48.

Alternative B exposes PNG plus the existing KTX2 colour profile now: sRGB
RGBA8 or BC7, supported 2D/single-layer/single-face files, their stored mip
levels, and the existing BC7 software fallback when required by the device.
That adds no new codec, but requires format dispatch, compressed/fallback
budgeting and additional integration evidence. Existing KTX2 alpha/orientation/
format restrictions would remain; choosing B is not approval for arbitrary
KTX2, Basis/supercompression, data textures or new Lua rendering controls.

A is recommended for the one-quad milestone because it gives authors a common
image format and uses the real image/upload services with a single Lua-facing
profile. Its cost is exporting authored images as PNG, one uncompressed RGBA8
GPU level, decode work on each independent request, and no mip-assisted
minification. KTX2/BC7/mip-generation remain available to Haskell consumers;
exposing them through Lua is a later extension if A is selected.

Qualification covers nontrivial opaque/transparent PNG output, top-row
orientation, non-8-bit/palette conversion through existing decoder tests,
invalid and animation-marked inputs, oversized declarations/decoded work,
optional versus required failures, readiness and cancellation ownership. The
existing [image codec contract](../../packages/asset-image/README.md) and
[image2d sample](../../samples/image2d/README.md) establish decoder behaviour
and composed rendering evidence. The new signature dispatch, animation refusal,
provider bounds and Lua lifecycle still need their own integration evidence;
this design turn ran no decoder, GPU or native tests.

### P-63. Use opaque sRGB byte colours and fractional logical-pixel rectangles

**A accepted by D-66 through Q-6n. Delivery: M1.** Recommend A: an authored
scene supplies an explicit opaque background colour as three whole numeric
RGB values in `0..255`, interpreted as sRGB. Both Lua integer values and
exactly integral floats in range are accepted; strings and fractional colour
values are not coerced. For example, `(128, 128, 128)` is the familiar sRGB
mid-grey value, not linear-light `0.5`. The binding converts those channels to
linear light for the renderer's clear value and supplies alpha 1. The actual
table keys/shape remain part of the consolidated API package.

No authored background alpha or transparent-window feature is exposed in M1.
PNG alpha still blends correctly over the opaque background under D-50/D-65.
An empty sprite list is a valid background-only scene. Each published scene
must provide its colour; there is no implicit inheritance from an older scene.
Before the first publication, a window that is ready to draw uses opaque black
and no sprites. This specifies engine-produced content, not an assurance that
the OS has already displayed a frame when window creation reports ready.

Shared rectangle proposal for either colour option: `x`, `y`, width and height
are finite Lua numbers in D-50's logical-pixel units. Integers and fractions
are accepted; positions may be negative or outside the window, and width and
height must be strictly positive. Offscreen parts are clipped by the window's
view rather than clamped, moved or resized by the Lua binding. A fully
offscreen valid sprite is harmless. Zero/negative extents are errors, not a
hide or mirror command. Remove a sprite from the next scene to hide it.

Convert geometry to the renderer's single-precision representation with
checked ranges and arithmetic; reject non-finite, out-of-bounds or collapsed
geometry after conversion instead of silently accepting overflow/underflow.
Fractional positions are not rounded to whole pixels and D-50's no-snap policy
remains. Single-precision rounding and nearest sampling still affect rasterized
edges; no exact arbitrary-precision positioning is promised. Concrete numeric
coordinate/extent bounds join the forthcoming bounds package.

Bad colour, geometry, unknown fields or invalid texture ownership/readiness
refuse the entire publication as an ordinary Lua error under D-46, preserving
the previous complete scene. No clamping, ignored bad sprite or partial update.
The API package will enumerate the supported fields; this checkpoint establishes
strict validation, not an open-ended scene table. A caught publication error
leaves the instance usable; an uncaught error follows the normal UI failure
policy. Engine/cleanup failures retain their existing authority.

Alternative B uses three finite linear-light RGB values in `0..1` directly,
still with fixed alpha 1 and the same geometry/validation/default-black rules.
It matches the renderer's numerical clear input without conversion and allows
finer authored background precision, but authors must convert ordinary sRGB
colour-picker values themselves. Neither option adds HDR, tint controls or
desktop transparency.

A is recommended for Lua UI authors because common image-editor colours can
be used directly and PNG/clear colour interpretation is explicit. Its cost is
one defined conversion and 8-bit authored background precision; opaque-only
backgrounds are the shared M1 restriction. Fractional rectangles support smooth
authored motion but do not guarantee pixel-perfect edges at every scale.

Qualification covers byte-grey clear against matching opaque PNG colour,
transparent PNG over the background, initial black and empty scenes, fractional
and negative positions, viewport clipping, zero/negative/NaN/infinite/overflow
values, and whole-publication refusal retaining the old scene. The renderer's
`ClearColour` contains four floats in `[0,1]`; its Vulkan adapter forwards them
to the backend's linear clear (`Snapshot.hs`, `Vulkan/Frame.hs`, native
`Recording/Layer.hs`). The binding's byte-colour conversion, opaque restriction
and geometry preflight are new API behavior, not existing Lua features.

### P-64. Let logical loads choose a future tick offset, defaulting to the next tick

**A accepted by D-67 through Q-6o. Delivery: M1.** D-9/D-42 require assigned
logical content results but have not selected the Lua-facing assignment rule.
Recommend A: a logical data/module request may supply a positive whole-number
tick offset; omission means 1. At admission the engine fixes the target as the
current logical tick plus that offset, and assigns a unique increasing sequence
position. Lua chooses the offset, never the sequence or native completion order.
Exact argument spelling and integer/range limits follow in the API package.

Logical init is before tick 1, with assignment origin 0, so its default request
is due at tick 1. A request made at tick 10 with offset 30 is due at tick 40.
This is a scheduled visibility point, not a timeout or a number of wall-clock
seconds. Requests begin their eligible background source work after admission;
data verification can finish early, while new module top-level evaluation waits
for its assigned chain position under D-58. Boot entry/dependency evaluation
before init remains the separate boot phase and needs no synthetic result tick.

Before the assigned position, ordinary success/failure is held and readiness
is pending. At that position, an unfinished result holds logical progress,
without skipped ticks, larger `dt`, placeholder results or automatic timeout;
UI continues independently. Optional data changes failure handling, not this
timing rule: a still-pending optional result also holds its assigned position.
Early cancellation remains the existing winning cancellation exception; it
does not erase D-57's continuing shared module job or its evaluation obligation.
Accepted requests cannot be retimed; a later retry is a new admission, with
normal cancellation, result-consumption and retirement obligations.

**Shared module timing refinement:** a VM-owned job has the earliest evaluation
position contributed by any admitted external request or eligible dependency
chain. A new waiter with an earlier future target can advance a queued job;
it never duplicates evaluation. Once contributed, that position is not moved
later by cancelling the waiter. Every external request retains its own assigned
result position, even if the shared job completes earlier. D-58's earlier
dependency promotion and immediate lookup of already-cached exports still apply.
This extension of D-57/D-58 must be approved explicitly with the timing policy.

Reject zero, negative, fractional, overflowing or over-limit offsets before
admission with an ordinary Lua error; allocate no request or provider work.
Sequence capacity/overflow must likewise never wrap into a reused position;
exact finite bounds and refusal classification belong to the bounds package.
UI requests remain arrival-settled; supplying a logical offset to one is an
ordinary Lua error, not an ignored option. D-44 still prohibits logical texture
requests. No cross-role result bus, world state or replay product is added.

Alternative B gives every logical request offset 1 with no override. It reuses
the default host assignment with less API surface, but even a room prefetch
must hold the very next tick if its work is late; authors cannot schedule a
later visibility point. Module dependency promotion and shared-job lifetime
still need their approved ordering, not duplicate loads.

A is recommended to make logical background loading useful before content is
needed. Its cost is explicit lead-time planning and retaining request slots
until their scheduled results can be taken; a far-future target cannot reveal
an early result just because the source finished. The late-result stall remains
deliberate, and scheduling farther ahead never guarantees timely native work.

Qualification covers default/explicit offsets from init and updates, held early
success/failure, late required/optional results, unique sequence ordering,
invalid offsets, both cancellation orders, UI-option refusal and joining a
later queued module with an earlier target without duplicate evaluation. The
[host request contract](../../packages/scripting-lua/README.md#settling-on-arrival-and-at-an-assigned-tick)
already has application-assigned `DueSlot` and defaults to the next tick.
Its current assignment callback receives `RequestInfo`, not the request's Lua
arguments. The new binding must carry validated assignment metadata through a
narrow owner-controlled admission path; exposing this option is integration
work, not a claim that the existing callback already accepts it.

### P-65. Expose each role's own clock and cooperative duration waits

**A accepted by D-68 through Q-6p. Delivery: M1.** Recommend A: expose
role-specific clock reads and waits through the existing scheduler. A logical
instance reads its current integer tick and the fixed tick duration in seconds,
and may wait a positive whole number of logical ticks. Init observes tick 0;
later reads reflect the most recent begun tick. Real delays while a future
tick is held do not advance that clock. A logical instance cannot read elapsed,
wall/calendar or CPU time, or request an elapsed-duration wait.

A UI instance reads elapsed seconds from an engine-owned monotonic origin set
when that VM starts root initialization. All instances in that VM share the
origin; creating the second test instance does not reset it. At each hook or
resumed coroutine segment's entry, sample elapsed time once and hold that value
for reads throughout the segment. The first root-init segment sees zero;
later samples include actual elapsed initialization/loader/native delays.
This does not redefine D-17's cadence origin or update `dt`: those retain their
approved scheduling meaning. No wall clock, date, timezone or CPU timer is added.

UI may wait a positive finite duration in seconds. Convert it to the host's
duration representation by rounding upward to its unit, with checked range;
do not turn a tiny positive duration into a zero wait. The deadline starts at
the actual scheduler wait request, not an earlier segment-entry clock sample.
Becoming due makes the continuation eligible; it may resume later because of
other work. A logical tick wait similarly becomes eligible at its future
tick and obeys FIFO service, without promising an exact wall-clock wake time.

Both roles retain cooperative yield and D-54's request wait. Engine-scheduled
yield/duration/request waits are available only in suspendable update/event
execution, never init or shutdown. Clock reads are allowed in lifecycle hooks,
including finite init/shutdown, but neither clock access nor general engine
waits are allowed during module top-level evaluation under D-8. The special
resumable import protocol remains separate. Wrong-role calls, invalid values
and forbidden-phase calls are ordinary Lua errors before starting a wait;
an uncaught error still follows the existing role/boot failure policy.

A wait suspends the current invocation; it does not create another update,
rewrite the invocation's original `dt` on resume or run a nested event loop.
Existing one-active-invocation/cadence coalescing and owner cleanup remain.
Yield rejoins the eligible FIFO queue under D-42; it is not a render-frame
callback, a guaranteed next tick or preemption of a non-yielding script.
Engine stop cancels ordinary continuations through established cleanup; no
script-owned timer thread or independent timer-resource lifetime is exposed.

Alternative B exposes only the existing update `dt`, cooperative yield and
request readiness/wait in M1, with no explicit clock query or duration wait.
Authors maintain elapsed/tick counters in their own updates and implement
delayed actions there. It reduces the Lua API surface but makes short transient
sequences less direct despite the scheduler already supporting timed waits.

A is recommended because the two real clocks accepted in D-42 can support
ordinary Lua routines without new gameplay-state concepts. Its cost is a
precise origin/sample/unit contract and role/phase validation; a long UI segment
reads a stale sample until it yields or ends, and a due timer can resume late.
The logical tick/duration pair gives logical time without floating-point tick
accumulation. Numeric limits and concrete function names follow in the API
package. This does not add a cross-VM clock/data bus or deterministic UI replay.

Qualification uses injected clocks and explicit scheduler gates for init zero,
shared origin, stable within-segment reads, refreshed reads after resume,
held logical ticks, early timer wakes, late resumes, role/phase refusal and
shutdown. The [host scheduler contract](../../packages/scripting-lua/README.md)
already provides logical/elapsed waits and owner-thread observation; its public
wait operation takes integer ticks or nanoseconds. Seconds conversion, sampled
Lua clock reads and M1 eligibility checks are new integration work over those
services, not new native sleep calls from Lua.

### P-66. Defer engine randomness and remove ambient Lua RNG entry points in M1

**A accepted by D-69 through Q-6q. Delivery: M1 scope / later RNG design.**
P-1 carried forward the earlier two-domain sample's seeded-stream/separate-UI
constraints, while D-42 explicitly deferred a new world RNG/replay subsystem
and left randomness bindings open. This checkpoint reconciles that gap without
designing gameplay state. Recommend A: remove `math.random` and `math.randomseed`
from both M1 VMs before any authored module executes, in addition to D-5's
selected library exclusions. Keep the other permitted math operations.

M1 adds no engine RNG namespace, seed manifest/CLI field, automatic seed source,
stream construction/splitting API or state-save/replay machinery. A script
calling a removed function encounters an ordinary Lua error; it does not invoke
D-42's special unavailable-state-service terminal guard. Normal caught/uncaught
hook and module-load failure policies apply. The quad/logical-stub demo and
two-instance qualification require no engine random source.

Authors may implement or import a pure-Lua pseudorandom helper with an explicit
seed and ordinary Lua-owned state, subject to the existing module/phase rules.
This is permission for authored computation, not a shipped RNG library,
algorithm choice or engine reproducibility guarantee. Sharing such a helper's
mutable module state shares its sequence under D-7; authors who need separate
sequences can use factories/instance-local state. No native entropy/time access
is added for it. M1 does not enforce a prohibition on computing pseudorandom
numbers in trusted Lua.

The existing `lua-domains` sample and prior Lua D-23/D-44 remain unchanged as
their own delivered contracts. Their application-owned seeded gameplay stream
belongs with the later gameplay/state arc, and UI draws must not consume that
stream when that arc is designed. This proposal specifically replaces P-1's
possible reading as a requirement to deliver that engine stream in M1. It does
not decide future stream ownership, algorithm, seeding or rollback semantics.

Alternative B removes the standard RNG from logical Lua but retains UI
`math.random`/`math.randomseed`, as in the earlier sample's role split. It gives
UI authors an immediate conventional random source while still deferring the
logical engine RNG. Its automatic/explicit seed policy and top-level eligibility
would need a concrete follow-up contract, including any qualification of D-8's
pure-helper module phase; choosing B is not silent approval of those details.

A is recommended for the small service-driven milestone and a common filtered
math surface without a new seeding service. Its cost is that existing scripts
using either standard RNG function must change or wait for a later extension,
even for cosmetic UI variation. Authors needing it now supply their own helper
and seed rather than receiving one from the engine. This restriction does not
make trusted Lua deterministic or contain a hostile script.

Qualification checks removal before entry/dependency evaluation in both roles,
normal math availability, ordinary error classification and continued module
and instance isolation; no world digest/replay acceptance is added. Evidence:
the [two-domain sample](../../samples/lua-domains/README.md) owns a SplitMix64
stream in its committed/candidate world, strips the gameplay math RNG and leaves
the UI math library's RNG available. That is sample-specific implementation,
not an existing standalone generic service to wire into the no-store M1.

### P-67. Let UI hooks poll a coherent copied session-status record

**A accepted by D-70 through Q-6r. Delivery: M1.** D-18/D-19/D-42 already
require startup and failure information for a Lua loading/error screen. They
do not select a Lua delivery API. Recommend A: a synchronous, non-waiting
status read in UI lifecycle hooks returns a plain copied record, sampled at
the start of that hook or resumed segment. Repeated reads within the same
segment see the same record; modifying a returned table cannot affect engine
status or another reader. No status subscription, callback, event history or
new cross-VM message bus is added.

The record describes which roles are present, their initialization readiness
and running/failed/stopping/actually-retired status, and whether whole-session
stop has been requested. Absence of a logical role is explicit. During early
UI execution the logical role can be starting or ready; ready means that its
own initialization has succeeded, not that every requested asset has loaded
or that game-specific work is complete. D-18's joint gate still controls
the first logical tick. There is no detailed init progress, world data or
arbitrary authored payload. Exact field names/enums and report limits belong
to the consolidated API package, not the illustrative vocabulary here.

After an ordinary post-boot logical failure, the surviving UI can read a
latched bounded failure description with source/content and executing-instance
attribution, role, stage, short explanation and available traceback, preserving
D-19. It contains no stack locals or live Lua objects. The first failure is
retained while retirement status advances; cleanup is not reported complete
until actual retirement. A later fatal engine/cleanup failure still ends the
session under existing policy. Independent stderr diagnostics remain required;
UI status is not their replacement or an unlimited diagnostic log.

The session supervisor owns and coherently publishes this bounded record;
each UI segment captures a value from that publication without waiting for
the logical VM, a request result or resource retirement. Readers may miss
intermediate phases between polls. A latched logical failure remains visible
while the healthy UI continues, but there is no promise of one observation
per transition, a final hook or a final displayed frame on session exit.
Stopping either owner never waits for Lua to acknowledge status. The record
lives for the session; segment copies are ordinary Lua data and carry no
native resource ownership.

This cross-role status read is UI-only, including finite UI init/shutdown
hooks. Module-top-level and logical-VM calls are ordinary Lua errors before
reading the supervisor. This explicitly keeps UI arrival and wall-time-sensitive
session observations out of logical Lua; it does not remove the logical role's
own D-68 clock or the existing whole-session quit policy. Whether any further
own-instance metadata is needed belongs to the API package. No synchronous
cross-owner call is introduced.

Alternative B delivers status-change callbacks to UI instances. That would
let an otherwise event-driven UI react without an update cadence, but requires
a separate bounded delivery, coalescing, ordering and instance-lifetime
contract before implementation. Neither choice promises a callback from a
failed UI or before fatal shutdown. B is not approval of an unbounded event
queue or of detailed progress.

A is recommended because M1 already has UI updates and only needs a latest
loading/failure view. Its cost is that authors must poll from an update or
other scheduled hook to notice a change; an event-driven UI with no such work
will not be awakened by status alone. Long non-yielding segments see a stale
sample, and brief intermediate phases may never be observed. Qualification
checks coherent copied reads, stable per-segment sampling, absent-role and
startup gates, sticky failure during unfinished retirement, independent UI
continuation, forbidden-role/phase errors and teardown without acknowledgement.

Evidence: P-14/P-15/P-38 record the accepted launcher policies. The
[two-domain sample](../../samples/lua-domains/README.md) already separates
supervision's failure/stop latch from task completion, but its world/status
publication is not a ready-made no-store M1 API. The
[Lua host](../../packages/scripting-lua/README.md) reports scheduled segment
observations on the owner thread (`scheduledObserve`); exposing this new
bounded launcher status still requires explicit supervisor publication and
binding integration.

### P-68. Reuse bounded print/warn output and defer a separate Lua logging API

**A accepted by D-71 through Q-6s. Delivery: M1.** D-20 already places
authored output on stdout and diagnostics on stderr; D-8 permits module-level
diagnostics. Recommend A: expose engine-rebound `print(...)` and `warn(...)`
in both roles, during module evaluation and lifecycle hooks including finite
init/shutdown. Keep the original C-stream functions unreachable before authored
code runs. Add no Lua logger constructor, level/field API, sink choice, file
writer or logging-configuration control in M1.

Both calls convert arguments with Lua `tostring`, join them with tabs and
emit bounded text through injected Haskell sinks. `print` is unprefixed
application output on stdout. `warn` is a diagnostic on stderr with an
engine-generated warning prefix and context: role and content ID, plus the
executing instance during hooks or the evaluating module path during loading.
Shared-module hook code retains the executing instance's attribution; this
does not promise an exact helper-function call site. Module evaluation does
not invent an instance owner. Attribution comes from the engine, not a
script-supplied identity. The final prefix spelling belongs to the API package.

Reuse the runner's 4096-byte total written limit per authored call, counting
prefixes, escaping, line endings and a visible truncation marker. No silent
unbounded print path remains. Invalid UTF-8 bytes are replaced, line breaks
are split into output lines, and other controls are escaped except tabs;
each warning line is marked as authored warning output. Bound text before
crossing into the host and again after formatting, since replacement/escaping
can expand it. Oversized output is visibly truncated, not a required-request
failure. Lua conversion/metamethod failures are ordinary Lua errors with no
partial output from that call. Conversion may run authored code and still has
the trusted-script hang/memory limitations; this is an output bound, not an
execution quota.

Authored print/warn calls bypass engine log filtering, as in the existing
runner; `warn` does not fail the instance merely because it emits a warning.
Lua warning-control strings such as `@off` are ordinary text in this rebound
function, not controls over engine diagnostics. Engine lifecycle/failure
diagnostics remain separately attributed under the existing logging/reporting
contract, and script output does not suppress failure reports. M1 adds no
mandatory runner instance tables to stdout; that remains the authored-output
stream for the new launcher, apart from explicit help output.

Output is synchronous, serialized for a complete authored call/report through
session-owned sink coordination, and flushed on emission. It adds no hidden
queue, drop policy, rate limiter or asynchronous delivery receipt. Per-owner
call order is preserved; interleaving between independent VMs follows actual
execution and is not a deterministic transcript. A successful return does not
promise durable storage. The application owns sinks through protected session
cleanup so shutdown hooks can still write. A sink/write/flush failure is a
host failure under existing fatal-session policy, not a catchable content-load
refusal; do not recursively retry output through a failed sink. Forced exit
retains D-20's exception to cleanup/flushing guarantees.

Alternative B also exposes a Lua diagnostic logging service with levels and
structured fields through the existing Haskell logger. It enables filtered
debug/info diagnostics without authors formatting them into warning strings,
but requires selecting the Lua schema, allowed fields/components, attribution
and filtering behavior next. It does not expose OS logging configuration or
file handles implicitly. Both options retain D-20's stream split.

A is recommended for the quad milestone because the runner already supplies
the bounded output bridge and Lua can distinguish ordinary output from a
warning. Costs: no authored debug/info levels or structured log fields yet;
long messages truncate, and a slow terminal/pipe can block the calling VM
and other writers waiting on the shared output lock. There is no promise that
printing is nonblocking or can be preempted by cooperative Lua cancellation.

Qualification covers both roles and module/hook phases, stream separation,
engine-owned warning attribution including shared-module calls, conversion
failure before emission, invalid bytes/control escaping and the final byte
bound, concurrent complete-call serialization, sink failures and output during
shutdown. Tests use injected sinks rather than timing sleeps. Evidence:
[Lua runner output and stream rules](../../packages/scripting-lua/README.md#output-and-the-stream-rules)
already rebind print/warn, cap each call at 4096 bytes and serialize writes;
[the logger](../logging.md) has synchronous injected sinks and propagates sink
exceptions. M1 warning context and launcher-wide coordination are integration
work, not a claim that the current runner already implements this proposal.

### P-69. Make Lua quit an idempotent stop request that returns normally

**A accepted by D-72 through Q-6t. Delivery: M1.** D-20 already requires
orderly whole-session quit, failure-dominant exit status and no Lua force-exit.
Recommend A: a no-argument, no-result quit operation latches the session's
normal-stop request and returns to the current Lua hook. The spelling belongs
to the API package. It is available to either role from lifecycle hooks,
including finite init and shutdown; module-top-level calls are ordinary Lua
errors under D-8. No exit-code argument, arbitrary reason payload, stop-other-
instance operation, pause/resume, restart or public instance-spawn API is added.

The operation records stop directly in the existing session coordinator,
without consuming a request/result slot or returning busy. Repeated calls,
including calls from shutdown, are idempotent and cannot reopen admission,
replace an existing failure or run shutdown twice. It requests the entire
session's end even if called by only one instance. D-43's two-instance test
therefore ends one instance through its Haskell harness, not through this
whole-session Lua operation.

Latching stop closes new work admission and future tick grants. New content/
window/texture requests and scene publications after that latch are refused
before new native action as ordinary Lua errors, not busy retries. Cleanup
operations such as releasing an owned texture or cancelling a request, and
print/warn, remain usable subject to their existing handle/phase rules. Pending
work is cancelled and retired through its actual owners; required failures
already latched still count, and existing settlement/cancellation ordering
continues to decide races. Quit does not undo a scene, an output line or Lua
table changes already made, nor claim that GPU/provider work has retired.

The current hook is not unwound at the call: local statements after quit can
still run until the hook returns or reaches a scheduler boundary. Authors
should return after requesting quit. No further ordinary continuation is
resumed after stop is applied; each VM observes stop at its safe boundary,
without preempting a segment already running on the other owner. A caught Lua
error cannot withdraw the stop request. An uncaught error after requesting
quit, or a shutdown/cleanup failure, still makes the orderly exit fail under
D-20. Returning from quit is neither a successful-cleanup receipt nor a
guarantee of a final displayed frame. D-70 status remains the segment's earlier
sample, so an immediate status read need not yet show the just-requested stop.

During init, stop prevents the joint startup gate from opening. An init that
returns normally remains eligible for the normal shutdown policy, but its
success cannot restart the session; failed/incomplete init and unsafe-Lua
shutdown skipping still follow D-18/D-27. Shutdown runs at most once where
safe, engine cleanup remains mandatory, and the caller never synchronously
waits for the other VM, native cleanup or GPU completion. A hook that keeps
running forever after quit can still prevent orderly completion; D-20's
second-signal forced exit remains the owner's escape.

Alternative B makes quit terminate the current invocation immediately as a
distinguished orderly-stop outcome, so ordinary statements after the call do
not run. That requires a protected terminal control mechanism, distinct from
Lua errors and robust against pcall/coroutine wrappers, plus an explicit rule
for interrupted init and shutdown. It cannot merely throw a catchable Lua
error, skip native cleanup or terminate an independently executing VM. Both
choices retain whole-session scope and existing exit-status precedence.

A is recommended because a returning stop request fits the existing
cooperative supervisor and keeps native retirement outside Lua. Its authoring
cost is the need to return promptly and avoid new service work after quit;
an error on that later work can turn a requested clean exit into failure.
B is more convenient for authors expecting a terminal exit statement but
adds a new control-flow contract to this milestone.

Qualification checks quit from either role, init and shutdown, repeated calls
with full request capacity, module-phase refusal, admission/grant closure,
code executing after the call, cancellation/required-failure races, failure
precedence and actual retirement. Injected barriers coordinate simultaneous
owners and stop; no hanging-script or desktop probe is required to establish
these state transitions. Evidence: the
[Lua host's control and runner rules](../../packages/scripting-lua/README.md)
already apply controls at safe boundaries, stop future grants, retire pending
requests and distinguish stop from cleanup completion. The no-store launcher
must wire a narrow whole-session binding and admission gate; this proposal
does not expose the existing runner's wider instance-control namespace.

### P-70. Defer Lua window-size observation while retaining native resize handling

**A accepted by D-73 through Q-6u. Delivery: M1 boundary / later presentation.**
D-45 lets Lua request a title and initial size; D-50 keeps the renderer's
full-window view current as native geometry changes. Neither decision yet
grants Lua a read of current window/view geometry. Recommend A: no window-size
or render-view-metrics read in M1, and no resize callback/subscription. The
window request's success returns the owned ready window resource, not a
continuously updated metrics table. Texture dimensions remain available under
D-47; this does not remove that accepted result.

Lua publishes rectangles at explicit logical-pixel coordinates and dimensions.
The engine continues to update its viewport and framebuffer/content-scale
mapping on resize, clips out-of-view rectangles and suspends drawing at zero
framebuffer extent. It neither stretches the scene to fill the window nor
recenters or relays out sprites. An unchanged static scene needs no republish
to keep rendering with the current native metrics. Close still requests session
quit under D-51; general input/window controls remain deferred.

The requested initial window size is an authored preference, not a report of
the actual current viewport. Native platforms may choose a different extent,
and D-50 already distinguishes renderer logical pixels from window screen
coordinates. A does not permit a fabricated current-size field copied from the
request. A future metrics read can be added without changing scene ownership,
texture lifetime or these coordinate rules.

Alternative B adds a narrow UI-only read of the owned ready window's current
render-view extent in the same logical units as its sprites, without general
input, resize callbacks or window mutation controls. It allows Lua to center
or fit a quad by polling and republishing. Its coherent sampling, unavailable/
zero-extent representation, ready-resource/phase validation and exact schema
would be settled in the API package; it must derive from renderer metrics,
not assume GLFW's window size is the same unit on every platform.

A is recommended for the explicitly scoped textured-quad milestone. Cost:
Lua cannot automatically recenter, fill or otherwise adapt authored layout
to the actual window size; authors choose fixed rectangles, and resizing may
expose more background or clip more of the scene. This is a deliberate M1
authoring limit, not a claim that responsive layout is unnecessary later.
Choosing B buys that immediate ability at the cost of another observation
binding and platform/resize qualification.

The existing M1 evidence still checks automatic viewport adaptation, content
scale, zero-size suspension and restoration without mutating the Lua scene.
No test may infer current size from the requested initial size. Evidence:
[GLFW observations](../glfw.md#observations) publish sampled logical extent,
framebuffer extent and content scale with explicit unavailable values;
P-47/D-50 preserve the renderer's distinct coordinate mapping. These native
facilities remain available to the engine whichever Lua boundary is chosen.
After this scope choice, proceed to the consolidated M1 API/manifest/bounds
contracts, then Q-8 vision/#145 reconciliation and Q-9 delivery slices.

### P-71. Fix the M1 launch command and strict declarative JSON manifest

**All five parts accepted by D-74 through Q-13. Delivery: M1.** This is one
five-part contract for explicit package signoff, not five inferred decisions.
It makes D-13/D-14/D-16 concrete without implementing L-MODS or moving cadence
out of Lua. Recommend approving all five parts below, or revising the named
part before recording a decision.

#### 1. Command and compatibility

Add `hetoimasia run GAME_ROOT`, with exactly one positional folder.
`hetoimasia run -- GAME_ROOT` treats the following argument literally, including
a leading hyphen; without `--`, a leading-hyphen argument is an unknown option.
`hetoimasia run --help` alone prints help to stdout and exits 0. Missing/extra
arguments and every other option fail as usage errors (2) before opening a
root. No default folder, entry override, mod flag, seed, cadence override,
window option or script-argument forwarding is introduced.

Existing `lua`, `--smoke`, help and no-argument console behavior stay unchanged;
the new window-capable path requires the explicit `run` command. Resolve the
selected folder once under D-63, then use anchored reads for its manifest and
inventory. Root/content/manifest failures are boot failures (1), not usage
errors; existing fatal logging-configuration failure behavior stays unchanged.
No directory traversal search for a manifest in parent folders is performed.

#### 2. File, syntax and bounded parsing

Read exactly `hetoimasia.json` at the root, with D-60/D-61's case/path rules.
It is a non-executable UTF-8 JSON object, at most 65,536 bytes including
whitespace, parsed before Lua. Reject BOM, malformed UTF-8, unpaired surrogate
escapes, comments, trailing commas/data, duplicate object keys after JSON
escape decoding, and nesting deeper than eight containers. Unknown fields,
nulls and wrong types fail schema validation rather than being ignored or
coerced. Object-member order is not a configuration precedence mechanism.

Use [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259) as the JSON syntax basis;
the duplicate-key, Unicode and size/depth refusals above are this manifest's
explicit stricter profile. Select a maintained parser and qualify duplicate
detection before collapsing objects into maps; the choice of Haskell parser
dependency is implementation work, not a claim of existing support. Retain
the fingerprint of the exact parsed bytes under D-62; later scanning must not
quietly substitute a changed manifest. No includes, interpolation or execution.

#### 3. Root schema and stable identity

The only top-level fields are:

| Field | Contract |
| --- | --- |
| `format` | Required JSON number with exact integer value `1`; no string coercion. Other revisions fail boot. |
| `id` | Required stable content ID: 1–64 ASCII characters matching `[a-z][a-z0-9_-]*`. Exact identity, no case folding or derivation from the folder name. |
| `entry` | Optional common entry path, required wherever a selected role lacks an explicit entry. D-60/D-61 root-relative path grammar and normalization apply. |
| `tick_seconds` | Required exactly when gameplay is present; decimal text as specified in part 5. Refused for presentation-only content. |
| `vms` | Optional nonempty array of role declarations as specified in part 4. Omission selects both roles. |

This `format` is the launcher manifest schema revision, not D-29's deferred
game/mod API compatibility revision. No `mods`, dependencies, compatibility,
asset list, window settings or arbitrary metadata fields are accepted in M1.
Unicode file paths remain allowed; restricting the stable ID does not restrict
those paths. All declared entry paths must name inventoried regular files,
even if a common entry is overridden by every role; only selected entries are
evaluated. Path syntax, presence and the whole-folder scan are checked before
authored Lua, without pre-executing or pretending to validate Lua behavior.

#### 4. Role declarations and entry selection

Each `vms` element is an object with required `role` and `clock` strings and
optional `entry`. Only `gameplay`/`logical` and `presentation`/`elapsed` pairs
are accepted. Unknown/duplicate roles, mismatched clocks, extra fields and an
explicit empty array fail boot. There are one or two declarations. Array order
does not change D-18's concurrent startup or establish a dependency order.

A role's explicit `entry` overrides the common entry; otherwise it uses the
common entry. Missing both fails boot. When `vms` is absent, both fixed role/
clock pairs use the required common entry. Each VM independently loads its
selected module, which returns exports containing that role's named behavior
(`gameplay` or `presentation`). Separate files still use named role exports;
there is no bare-behavior shortcut or bootstrap VM. The selected behavior's
hook/cadence validation remains D-15/D-17 and the forthcoming Lua API package.
No other role is implicitly created to satisfy an entry's content.

#### 5. Exact tick encoding and examples

`tick_seconds` is a string of ASCII digits with an optional decimal point
followed by 1–9 digits, e.g. `"0.01"`. No sign, exponent, spaces, fraction
expression, JSON-number substitution or rounding is accepted. Require a
positive exact number of nanoseconds no larger than `2^64 - 1`, matching the
foundation duration representation; leading/trailing zero digits are harmless.
There is no default duration. Later time/counter arithmetic must remain
checked rather than wrapping; the remaining API bounds package covers those
operations. Presentation cadence stays in its Lua behavior, not this file.

Default two-VM example; the 10 ms value is authored example data, not a default:

```json
{
  "format": 1,
  "id": "example_game",
  "entry": "lua/main.lua",
  "tick_seconds": "0.01"
}
```

Explicit pair with separate entries and no common entry:

```json
{
  "format": 1,
  "id": "example_game",
  "tick_seconds": "0.01",
  "vms": [
    {"role": "gameplay", "clock": "logical", "entry": "lua/game.lua"},
    {"role": "presentation", "clock": "elapsed", "entry": "lua/ui.lua"}
  ]
}
```

A presentation-only file has just the presentation declaration and omits
`tick_seconds`; a gameplay-only file has just gameplay and retains the required
tick text. Both may use a common `entry` fallback. All three arrangements and
the omitted-`vms` default must be qualified before delivery.

**Recommendation and costs.** This is a small machine-readable launch contract
with exact time conversion and obvious failures for misspellings. Costs:
JSON has no comments/trailing commas in this profile; authors quote decimal
time and cannot request sub-nanosecond ticks or an exact `1/60` fraction;
unknown future fields fail on older engines rather than being ignored. The
bounded parser/root validation and existing-command compatibility need tests.
An alternative format such as TOML, different command spelling or broader
metadata is a revision of this package, not a second simultaneously accepted
format. The owner may revise any of the five parts before signoff.

**Evidence and qualification.** The current console dependency list does not
already provide this JSON manifest loader. Its existing
[`parseSeconds`](../../console/Hetoimasia/Console/Lua/Options.hs) validates
positive decimal text to exact nanoseconds, and foundation `Duration` uses
Word64 nanoseconds; reuse the pure contract through an appropriate dependency
boundary rather than importing console internals into an engine library.
Tests cover bounded parsing/duplicates/Unicode, all role arrangements and
fallbacks, unsupported fields/revisions/mod declarations, anchored manifest
fingerprinting, path/ID refusals, exact time endpoints and unchanged old commands.
No game-specific Haskell, new tracker artifact or execution probe is required
to approve this authored-data contract.

### P-72. Fix module exports, behavior authoring and the shared request protocol

**All five parts accepted by D-75 through Q-14. Delivery: M1.** Recommend approving the
following five-part core Lua API contract as a package, or revising named
parts. These names become actual API spellings only on approval. The next
package fills in data/texture/window/scene/time/status function schemas using
this protocol, then fixes remaining bounds and provides the full quad example.

#### 1. Modules and behavior tables

Each source chunk runs in its own filtered module environment and returns
exactly one plain export table with no metatable. Global assignments are
private to that module; shared exports and mutable standard-library tables
remain subject to the trusted same-VM model. This is not hostile-code isolation.
Exports may contain ordinary Lua functions/tables, including Lua table cycles;
they are not serialized, deeply copied or constrained to the deferred state
store's value schema. D-7's rejected cycles are import dependency cycles, not
ordinary Lua table graphs. A missing/non-table/multiple return or metatable on
the export table is a sticky required-module failure.

The selected `gameplay` or `presentation` export must itself be a plain table.
Its only permitted fields are `init`, `update`, `shutdown`, `every_ticks` and
`every_seconds`, read without invoking metamethods. Hook fields are absent or
functions. Gameplay with update allows `every_ticks`, a positive whole number
defaulting to 1, and refuses `every_seconds`; presentation with update requires
positive finite `every_seconds` and refuses `every_ticks`. Without update,
either cadence field is an error. The existing exact cadence/elapsed rounding
and numeric-range details are finalized in the bounds package, not inferred
from this naming choice. No `run`, setup, resize or event-subscription hook is
introduced. An update-free behavior remains valid but M1 supplies no public
event subscription API to wake it.

Validate/capture the selected hook references and cadence before init, once
for the instance's life. Later mutation of the exported behavior table cannot
replace a running instance's hooks or cadence; mutable upvalues and ordinary
module/self state remain Lua-owned. Other export keys are unrestricted library
exports and unselected role exports are not treated as active behaviors.
Put helper functions outside the behavior table and per-instance data in self.

#### 2. Instance self and API access

Create a fresh ordinary `self` table for each instance, initially containing
`self.api`. Call `init(self, api)`, `update(self, dt_seconds)` and
`shutdown(self, reason)`; the init argument is the same facade initially stored
in `self.api`. This makes API access possible even when init is omitted. The
facade includes copied `role`, `content_id` and opaque session-scoped
`instance_id` strings plus the narrow service namespaces. It is not a native
pointer, public registry or general instance-control handle.

Each facade's service closures remain bound to its instance, checking the
active execution phase/instance on every call. Passing another instance's
facade or handles through a shared export does not grant authority; such calls
are ordinary Lua errors before native action. Metadata and Lua table mutation
cannot change engine attribution, grants or stored hook references. Scripts
may overwrite their own `self.api` or facade fields as ordinary Lua data but
must retain needed references themselves. That does not mutate the facade of
another instance or any private Haskell service registration.

The facade is supplied by the entry adapter; Haskell still injects narrow
services, with no application-wide EngineEnv/service locator. General module
top level receives only the filtered library/import/output surface and the
unavailable-state boundary whose exact spelling follows in the service package.
Keeping a facade in a module does not waive D-8's module-phase restrictions.
`dt_seconds` keeps D-17's logical/elapsed meaning. Shutdown reason spelling and
failure/status records are finalized with the service package.

#### 3. Content addresses and module calls

Expose `import(path [, root_id])` in each module environment. The default root
is captured from that module, even when its helper function later calls import
inside another instance's hook; it is never relative to the source directory.
Explicit root IDs override it. This avoids a helper importing a different
module merely because a different instance called the helper. Only the game's
root is enabled in M1; a syntactically valid but unknown/disabled root ID is an
ordinary argument error, without filesystem work. Paths and IDs keep D-60/
D-61/D-74 validation and normalization. No native path or search fallback.

During engine-managed module evaluation, import may suspend the loader until
the dependency exports are ready. In hooks it returns the same already-loaded
export table immediately. A valid uncached or still-loading hook lookup raises
an ordinary `module_not_ready` Lua error, starts no work and never waits. A
known failed module remains failed: importing it is a required-module failure,
latched for the active instance or enclosing module evaluation even if caught;
it cannot become a successful retry or optional lookup.

Expose `api.content.module(path [, options])` for hook-requested loading.
Options is an absent-or-plain table accepting only `root` and `tick_offset`.
Here default root means the facade's instance content ID, because this is an
instance-owned request. A shared library needing its own different root must
name it explicitly; this distinction from the module-bound import is part of
the contract. The logical offset defaults to 1 under D-67; presentation refuses
the field. Modules accept no `optional` option. New loads, joins and cached
success/failure follow D-7/D-57–D-59; even a cached request's result uses its
assigned logical position. Immediate successful import remains separate from
the request's later settlement. Bad arguments and pre-admission permanent
module limits raise ordinary Lua errors; accepted dependency failures remain
required failures under D-52.

#### 4. Common admission and one-shot result schema

All new request-producing functions use dot calls, returning two values:
`request, nil` on acceptance, or `nil, {code="busy", message=TEXT}` for D-53's
recoverable capacity refusal. No work/handle exists in the busy case. The
request is an opaque instance-owned handle, not a numeric ID, forged table or
resource whose GC triggers native release. Retain it until its terminal result
is consumed; losing the Lua reference does not reclaim capacity early.

Use the following common operations for module/data/texture/window requests:

| Operation | Return and effect |
| --- | --- |
| `api.request.ready(request)` | Boolean settlement readiness; consumes nothing. |
| `api.request.take(request)` | One of the records below; terminal take invalidates the request handle. |
| `api.request.wait(request)` | No results; cooperatively resumes when settled, without consuming. Update-only in the exposed M1 lifecycle; init/shutdown refused. |
| `api.request.cancel(request)` | `"cancelled"` when this call wins settlement, otherwise `"already_settled"`; terminal cancellation still needs take. |

Exact take records:

```lua
{status = "pending"}
{status = "success", value = VALUE}
{status = "failure", error = {code = CODE, message = TEXT, root = ID, path = PATH}}
{status = "cancelled"}
```

Fields absent from a variant are absent, not false or empty placeholders.
Failure root/path are present for content requests and omitted for window
creation; service-specific value shapes and error-code vocabulary follow in
the next package. Message text is bounded diagnostic context, not a string
authors should parse. The record/envelope is a fresh Lua table. Mutating it
does not alter request settlement; resource handles inside retain their owners.
`take` on pending consumes nothing; consuming any terminal variant ends the
handle. Foreign/consumed/wrong-kind handles and wrong phases are ordinary Lua
errors before work. Catching does not clear D-52's independently latched
required failure; ordinary running Lua is not promised a chance to inspect a
required failure before its owner stops. Cancellation after failure cannot
erase it. Capacity remains held until consumption plus actual retirement.

#### 5. Module values stay inside their VM

For a successful module request, `value` is precisely the cached export table,
the same table that import returns in that VM. Mutating that table is shared
module state under D-7; only the outer take record is a copy. Do not serialize
functions/tables through the host's copied provider-value channel. Native
workers deliver verified source/results to the owner; the VM-owned loader and
waiter machinery retain/retrieve exports on that owner thread and release
their own references on consumption/end. The VM cache keeps its approved
VM-lifetime reference; another VM receives its separately evaluated exports.
Cancellation consumes no exports and never poisons the shared job/cache.

Core authoring example (no rendering yet):

```lua
local util = import("lua/util.lua")
local function start_room(self)
  local request, refusal = self.api.content.module(
    "lua/room.lua", {tick_offset = 3})
  if not request then
    assert(refusal.code == "busy")
    return -- self.want_room stays true for a later update
  end
  self.request, self.want_room = request, false
end
return {
  gameplay = {
    every_ticks = 1,
    init = function(self, api)
      self.util = util
      self.want_room = true
      start_room(self)
    end,
    update = function(self, dt_seconds)
      local api = self.api
      if self.want_room then start_room(self) end
      if self.request and api.request.ready(self.request) then
        local result = api.request.take(self.request)
        self.request = nil
        if result.status == "success" then self.room = result.value end
      end
    end
  },
  presentation = {} -- valid idle behavior; the full quad follows next package
}
```

The example shows module/result identity, role exports and an authored busy
retry in later updates. Once accepted, the request's assigned position stays
fixed; it is not retimed on subsequent updates. This is not the complete demo
and adds no engine-side retry mechanism.

**Recommendation and costs.** One consistent request protocol makes data and
graphics calls predictable while preserving module identity. Costs: strict
behavior fields, dot-call conventions and explicit take/ownership accounting;
two explicit default-root rules for lexical imports versus instance requests;
known failed imports are fatal rather than a probing API; and new VM-side
export retention beyond the current copied-value provider interface. The
owner may revise any part, including names, before approval.

**Evidence/qualification.** The [Lua host](../../packages/scripting-lua/README.md)
already has private module environments, fresh self, per-instance request
ownership and ready/take/wait/cancel, but does not already expose this return-
table loader or facade/result schema. Tests must distinguish fresh envelopes
from shared exports, captured hooks from mutable tables, module-root import
from instance-root requests, failed-cache from not-ready lookup, wrong owners,
phase errors and the two-instance/shared-VM path. No new native/GPU probe is
needed to qualify these Lua-facing ownership and value contracts.

### P-73. Complete the M1 service function and record schemas

**All six parts accepted by D-76 through Q-15. Delivery: M1.** Recommend all six parts
below as the next API package. They use D-75's dot calls, per-instance facade,
busy admission and request records. Numeric ceilings/accounting follow as a
separate bounds package; no omitted limit means unlimited. This introduces no
new service family beyond the already selected M1 surface.

#### 1. Data and texture requests

| Function | Options | Successful take's `value` |
| --- | --- | --- |
| `api.content.data(path [, options])` | `root`, `optional`, logical-only `tick_offset` | Complete file bytes as a Lua string. |
| `api.content.texture(path [, options])` | `root`, `optional`; UI only | `{texture=HANDLE, width=INTEGER, height=INTEGER}` for a usable texture. |

Omitted options means an empty plain table. `root` defaults to the requesting
instance's content ID, `optional` is a boolean defaulting to false, and logical
`tick_offset` defaults to 1. Presentation refuses `tick_offset`, even if its
value is 1. Module requests retain D-75's narrower options without `optional`.
Paths/roots follow D-75; dimensions are positive source texel counts, not a
window extent. No decode/colour/filter/format options, data parser or cache.
Request readiness still includes GPU upload/registration for textures and
assigned delivery for logical data/modules.

#### 2. Windows, copied scenes and texture release

| Function | Contract |
| --- | --- |
| `api.window.open({title=TEXT, width=INTEGER, height=INTEGER})` | UI-only required request; its successful value is the owned window handle itself. All three fields required; initial dimensions are positive native window screen-coordinate units, not a current-size observation. |
| `api.scene.publish(window, scene)` | UI-only; validate/copy/swap the whole scene to the caller's ready window, then return no results. No frame-display receipt. |
| `api.texture.release(texture)` | UI-only non-waiting release: `"done"` if this first release completes retirement, `"retiring"` while retirement remains pending, `"already_released"` once a previously released texture is retired. |

Window title is valid UTF-8 text without NUL or control characters; empty is
allowed. Window requests have no optional flag, resize/close/reopen method or
second slot. D-51/D-73 native close/resize policy remains. Scene shape:

```lua
{
  clear = {r=0, g=0, b=0},
  sprites = {
    {texture=texture, x=32, y=32, width=256, height=256}
  }
}
```

Both top-level fields are required. Clear channels are whole numeric values
0–255 under D-66, and sprites is a dense 1-based array (empty allowed).
Each sprite requires exactly texture/x/y/width/height. Coordinates/dimensions
retain D-50/D-66's logical-pixel, finite, checked Float32 conversion and
positive-size rules. List order is painter order. There are no per-sprite
defaults, opacity, tint, UVs or transform fields. Repeating a valid sprite
table/texture in the array is allowed and copied at each position; Lua aliases
do not become shared mutable scene nodes. Unknown fields, metatables, holes,
wrong/released/foreign resources and invalid geometry refuse the whole call
with an ordinary Lua error and leave the old scene intact.

Release revokes the handle for new publication immediately; existing scenes
and GPU work keep their approved holds. Repeat release never repeats cleanup,
and can still report retiring. Wrong-kind/foreign/never-issued handles are
ordinary errors; a genuine cleanup fault stays fatal. No window-release or
independent close operation is added.

#### 3. Time and cooperative waits

| Function | Role/result |
| --- | --- |
| `api.time.tick()` | Gameplay only: current integer logical tick, init 0. |
| `api.time.tick_seconds()` | Gameplay only: the fixed tick duration as Lua numeric seconds. |
| `api.time.seconds()` | Presentation only: seconds since root-init origin, sampled per hook/resumed segment. |
| `api.time.wait_ticks(n)` | Gameplay update only: positive whole future-tick wait, no results. |
| `api.time.wait_seconds(seconds)` | Presentation update only: positive finite duration wait, no results. |
| `api.time.yield()` | Either role's update: ordinary cooperative yield, no results. |

Clock reads are valid in finite init/shutdown; waits/yield are not. All are
refused during module evaluation, including through a captured facade. No
wall/calendar/CPU time is exposed. Native waits never block the VM thread.
Logical duration is exact nanoseconds internally; seconds and dt exposed to
Lua are floating numeric approximations, not an alternate authoritative clock.
Elapsed wait/cadence conversion rounds upward to a nanosecond with checked
range, never to zero; deadlines, late resumption, sampled time and coalesced
updates retain D-17/D-68. Numeric endpoints and overflow handling follow in
the bounds package. No sleep, render callback or retiming API is added.

#### 4. UI status and shutdown reason schema

`api.session.status()` is the D-70 UI-only per-segment copied observation:

```lua
{
  stopping = false,
  gameplay = {present=true, initialized=true, phase="running", failed=false},
  presentation = {present=true, initialized=true, phase="running", failed=false}
}
```

An absent role is exactly `{present=false}`. A present role always has
`initialized`, `phase` and `failed`; `initialized` means its own init succeeded,
and remains a historical fact through stop/retirement. Phase is `"starting"`,
`"ready"`, `"running"`, `"stopping"` or `"retired"`. Failure is a separate
latched `failed=true` plus `failure` record, so it stays visible as phase
advances from stopping to actually retired. A failed role cannot be ready or
running. UI can be running while gameplay is starting/ready. Whole-session
`stopping` does not become true solely because logical failure leaves healthy
UI running; failure and session stop are distinct facts.

Failure record has required `code`, `message`, `role`, `stage`; known
`content_id`, `instance_id`, `path` and available `traceback` are present, absent
otherwise. Do not fabricate an instance for module-only work. Role is gameplay
or presentation. Stage is `"module"`, `"init"`, `"update"`, `"shutdown"`,
`"request"`, `"cleanup"` or `"engine"`. Code is `"lua_error"`,
`"module_error"`, `"required_request"`, `"host_failure"`,
`"cleanup_failure"` or `"state_unavailable"`. Preserve the first role failure;
later cleanup failures still appear in engine reporting and can end the session.
No guarantee exists that Lua runs to observe a fatal engine failure or final
phase. Messages/tracebacks are bounded text, without stack locals or history.

`shutdown(self, reason)` uses the existing host's strings `"stopped"`,
`"failed"`, `"completed"`. Normal session quit/signal/peer-driven retirement
uses stopped; an instance's own failure uses failed when Lua cleanup is safe.
Completed remains the host's natural-completion case, not a new public one-shot
mode or a promise that an update-free M1 behavior completes automatically.
Failed init/unsafe Lua still skip shutdown under the approved rules.

#### 5. Quit and the unavailable-state boundary

`api.session.quit()` is D-72's no-argument/no-result returning stop request,
valid from either role's lifecycle hooks. There is no global quit alias,
custom exit status/reason, per-instance stop, restart or pause binding.

Expose a single global function `state(...)`, also available as `api.state(...)`,
as the explicit unavailable-service boundary. Any call, with any arguments
and in any phase, latches whole-session failure and orderly stop, with the
first call reporting `state service not available in this milestone` to
stderr, then raises a Lua
error to end ordinary execution unless caught. Catching cannot clear the latch;
the existing safe-boundary/cleanup and second-signal rules still apply. This
special guard takes precedence over normal role/phase checks and repeats
idempotently. It is not a fake table store or a declaration of future entity/
schema functions; no `state.create` or other deferred state API is implemented.
The global spelling makes the guard available during module evaluation without
handing that phase an acquiring instance's full facade.

Print/warn remain the global functions selected by D-71, not duplicated as
API logger methods. The filtered standard library and pure authored helpers
otherwise retain their approved surface. These aliases/names add no OS access.

#### 6. Validation and expected failure vocabulary

Service input records/options must be plain tables with exactly the documented
keys, no metatables or coercion. Only nil/absence means an omitted optional
field; false is valid where a boolean is declared, and empty text only where
the text contract allows it. Numeric strings are not numbers. Arrays have
exact contiguous integer keys and no named extras. Validate argument count,
role/phase, ownership, input shape and permanent limits before admitting work.
Too many arguments, mistaken colon calls, unsupported options and wrong types
are ordinary Lua errors. No validation runs arbitrary authored metamethods.
The state guard is the explicitly documented exception to ordinary validation.

P-72's accepted-request `error.code` vocabulary is:

| Code | Expected content/request failure |
| --- | --- |
| `not_found` | Requested path is absent from the startup inventory; newly added files do not become eligible. |
| `content_changed` | Inventoried content is missing, changed, or no longer has a permitted no-follow type/mapping. |
| `io_error` | Expected file-read/access failure. |
| `too_large` | Source/data/image exceeds its applicable size/work limits. |
| `unsupported_format` | Not the selected static PNG profile, including animated PNG. |
| `invalid_image` | Malformed supported image input. |
| `module_error` | Lua syntax/evaluation/exports failure. |
| `module_cycle` | Rejected dependency cycle. |
| `module_limit` | Accepted load discovers a cache/dependency-depth limit. |
| `window_error` | Expected native window-creation refusal. |

Content failure root/path identifies the failing content, including a dependency
when known; otherwise retain the requested root/path. Message gives bounded
detail such as a dependency chain, without a recursive arbitrary error graph.
Before-admission permanent module-limit errors remain ordinary Lua errors
without a request under D-59; they are not this accepted-failure record.
Engine/provider defects, device/allocator faults and cleanup failures remain
fatal host failures rather than being converted to optional content failures.
Required requests still latch failure even if unread; optional data/texture
failures are records for Lua. Cancellation uses its own take variant, and busy
is an admission refusal, never a terminal accepted-request code.

#### Complete common-entry quad example for this proposed API

Use D-74's common-entry manifest, store this as `lua/main.lua`, and provide a
static `images/quad.png`. The PNG is authored/test content, not approved art.
Init starts both requests without waiting. Busy is retried by Lua in later
updates; no accepted request is restarted. This example deliberately uses a
fixed 256-by-256 rectangle and a 20 ms UI update cadence, neither an engine
default nor a render-rate guarantee.

```lua
local function remember(self, key, request, refusal)
  if request then self[key] = request
  else assert(refusal.code == "busy") end
end

local function begin(self)
  local api = self.api
  if not self.window and not self.window_request then
    remember(self, "window_request", api.window.open({
      title="Lua quad", width=640, height=480
    }))
  end
  if not self.image and not self.texture_request then
    remember(self, "texture_request",
      api.content.texture("images/quad.png"))
  end
end

local function collect(self, request_key, value_key)
  local api, request = self.api, self[request_key]
  if not request or not api.request.ready(request) then return true end
  local result = api.request.take(request)
  self[request_key] = nil
  if result.status == "success" then
    self[value_key] = result.value
    return true
  elseif result.status == "cancelled" then
    api.session.quit()
    return false
  else
    -- These demo requests are required; their failure is already latched.
    error(result.error.message)
  end
end

return {
  gameplay = {
    every_ticks=1,
    update=function(self, dt_seconds) end -- real logical owner, stub content
  },
  presentation = {
    every_seconds=0.02,
    init=function(self, api) begin(self) end,
    update=function(self, dt_seconds)
      local api = self.api
      begin(self)
      if not collect(self, "window_request", "window") then return end
      if not collect(self, "texture_request", "image") then return end
      local status = api.session.status()
      if status.gameplay.present and status.gameplay.failed then
        if self.window and not self.error_shown then
          warn(status.gameplay.failure.message)
          api.scene.publish(self.window, {
            clear={r=96, g=0, b=0}, sprites={}
          })
          self.error_shown = true
        end
        return
      end
      if self.window and self.image and not self.drawn then
        api.scene.publish(self.window, {
          clear={r=24, g=24, b=24},
          sprites={{texture=self.image.texture,
                    x=32, y=32, width=256, height=256}}
        })
        self.drawn = true
        api.texture.release(self.image.texture)
        -- The published scene retains it through actual GPU use.
      end
    end
  }
}
```

Window close performs orderly whole-session quit through the engine. Optional
shutdown is omitted: protected engine cleanup is still required. The error
branch is a colour-only indication plus a warning, not a font/widget promise.
An optional-data fallback uses the same result protocol with
`api.content.data(path, {optional=true})` and inspects a failure record; it
does not use pcall to undo required failure. Additional qualification fixtures
must cover explicit quit, waits, failed loads and independent instances.

**Recommendation/costs and evidence.** These functions directly expose the
selected M1 services through the existing [Lua host](../../packages/scripting-lua/README.md),
[window host](../glfw.md) and [renderer](../../packages/render-2d/README.md)
contracts without claiming the new bindings already exist. Cost: strict
record shapes and explicit asynchronous steps; floating Lua seconds versus
exact engine duration; separate failure/retirement facts in status; and the
deliberate unavailable-state function rather than an ECS-shaped stub.
Qualification checks schema/phase/owner errors before action, copied scenes,
readiness/results, time origins/waits, status/quit/guard precedence, and real
offscreen/native quad evidence in the delivery slices. Remaining numeric
ceilings and worker/resource accounting need the next explicit package.

### P-74. Fix a bounded M1 profile and account for work through actual retirement

**All six parts accepted by D-77 through Q-16. Delivery: M1.** The following
six-part profile fixes engineering limits, not measured performance
promises. They are fixed by the M1 assembly, without Lua/manifest/environment
overrides. Smaller injected test profiles must pass the same consistency
validation. Existing commands/general-library configurations stay unchanged.
KiB/MiB/GiB mean powers of 1024; arithmetic is checked before allocation/admission.

#### 1. Inventory, paths and modules

| Item | M1 ceiling |
| --- | --- |
| Manifest | D-74: 64 KiB and eight nested containers. |
| Inventory | 10,000 entries including root, directories and every file path; depth 32 path segments. |
| Content path | 1,024 UTF-8 bytes total; 255 per segment, checked on supplied/native and NFC forms. Native launch-root spelling is separate. |
| Startup hashing | 64 MiB per regular file; 1 GiB summed file bytes per root, counting aliases per path; 64 KiB streaming buffer. |
| Modules | 1 MiB source each; 256 cache identities per VM, pending/failed included; active import chain at most 32 modules. |
| Uncompiled source buffers | 16 MiB per VM, including 1 MiB reserved for the active chain's next source rather than unrelated prefetch. |

Unused/hidden entries participate; inventory/file/total/path excess fails boot
before Lua. Later overlong path arguments are ordinary Lua errors before file
work. Oversized module source fails an accepted load as too_large; cache/depth
failure preserves D-59's pre-admission versus accepted-failure split. Chain
depth includes its root; a closing cycle edge is reported without allocating
another live module frame. Release source buffers after compilation/transfer
when no longer needed. Compiled Lua objects/exports are VM memory, not claimed
to fit the uncompiled-source bank; no private snapshot of all content is added.

#### 2. Instances, requests, copied values and reports

| Item | M1 ceiling |
| --- | --- |
| Assembly instances | Two per VM; the normal launcher still creates one root per declared role. Second slot qualifies reusable bindings in the Haskell harness, not public spawning/mod activation. |
| Requests | 16 accepted/unretired per instance, 64 per VM, including unconsumed results and retiring providers. |
| Data | 8 MiB per file/result; 64 MiB retained data-provider/result bytes per VM. |
| Copied value crossing | 16 MiB encoded bytes, depth 8, 65,536 elements; family limits apply within that ceiling. |
| Scene input | 4,096 sprites; 2 MiB encoded input; depth 4 and the exact fixed schema. |
| Failure/status text | Message 2 KiB; traceback 8 KiB; complete role-failure record 16 KiB; opaque instance ID 128 UTF-8 bytes. |
| Engine failure report | 64 KiB; retain at most 16 secondary cleanup summaries, each at most 2 KiB, plus omitted-count. First failure remains primary. |

Reserve request/result bookkeeping atomically before acceptance. For data,
reserve the inventoried size up to 8 MiB in the VM byte bank before reading;
known missing/oversized content can become an accepted failure without an
impossible payload reservation. Slot/record limits bound metadata separately.
Take/discard plus actual provider retirement releases remaining native buffers
and the request slot. A Lua string retained after take has ordinary Lua memory
lifetime outside this bank. Module exports remain VM references, not serialized
payloads charged according to arbitrary export-table contents. Logical-owner
capacity credits become reusable at accounted scheduler boundaries under D-53,
not directly from an unsynchronized native completion callback.

Diagnostics truncate visibly at UTF-8 boundaries, keeping required codes and
identity where present. A native cycle diagnostic can retain the bounded path
chain; prioritize it and the first failure before secondary cleanup text.
D-71's 4 KiB print/warn cap remains. Omitted report detail never erases failure
accounting, and no unbounded diagnostic history is retained. Limits bound
engine service payloads, not all Lua/process memory.

#### 3. Texture, window, scene and GPU accounting

| Item | M1 ceiling |
| --- | --- |
| PNG source | 32 MiB encoded bytes; 4,096 chunks. |
| PNG geometry | Each axis 1–2,048 texels; 4,194,304 pixels; one RGBA8 output at most 16 MiB. |
| Decode work | 40 MiB decompressed scanline bytes; 128 MiB accounted CPU payload/workspace per active texture pipeline. |
| Textures | 16 pending/live/retiring textures and 128 MiB nominal RGBA8 bytes per UI instance; 256 MiB nominal bytes across the session. |
| Windows | D-51's one pending/live/retiring slot per UI instance; title 512 UTF-8 bytes; requested width/height integers 1–4,096. |
| Sprites | x/y in [-1,000,000, 1,000,000]; width/height in (0, 1,000,000], plus D-66 finite/Float32/non-collapse checks. |

Reserve a texture slot and the maximum 16 MiB nominal output charge before
acceptance; reduce the charge to its actual validated size at an accounted
stage boundary. This may return busy even for an eventually small image.
Do not read an unverified header early to evade reservation. Released-but-
displayed and in-flight textures remain charged until actual retirement;
D-49's independent loads each pay separately.

The 128 MiB CPU workspace covers live engine payload buffers for that pipeline:
encoded bytes, inflation/decoder intermediates, conversion output and staging
copies while owned. It excludes allocator overhead, GC-retained garbage and
driver memory. Validate dimensions, chunk count, scanline sizes and arithmetic
before size-derived allocation; bound inflation while streaming, not after
unbounded inflate. Do not decompress ignored metadata. Establish a conservative
live-buffer bound for every approved PNG variant, including 16-bit/interlaced
images. Extend the bounded decoder adapter if necessary; measured RSS or
catching allocation failure afterwards is not proof. Do not silently remove
an approved PNG variant to avoid this work.

Select the existing validated GPU budget model with 2 target records, 2 frame
slots per window/4 aggregate, 4 frameless batches, 2 generations per target,
16 tracked images per generation, 2 GiB accounted native GPU bytes and 4,096
accounted objects. Retain its 64-record reclaim pass, 32 progress actions per
turn and 100 ms maximum idle backoff. These native budgets are separate from
nominal texture bytes: staging/alignment/swapchain allocations also consume
native resources. Preserve backend backpressure, completion and cleanup;
budget exhaustion is not a successful allocation. Actual device/allocator/
cleanup faults remain fatal.

Native actual extents must meet device/backend limits; requested size is not
an observation or guarantee of allocation. Unsupported native geometry cannot
be silently clamped or reported as successful resizing. Zero extent still
suspends drawing; unusable targets retain the native failure/retirement policy.
Not every device is promised the maximum window or every resource at once.

Keep one latest Lua scene per window, no publication FIFO. Use the existing
derived adopted-revision limit: six per target with two frame slots, with
deferred adoption when full. Intermediate publications may be superseded;
adopted/in-flight revisions keep their holds. The latest copy and one bounded
publication draft are separately accounted. Repeated publication must neither
create an unbounded revision queue nor free references before retirement.

#### 4. Worker ownership and bounded accepted-work queues

The session owns two file-I/O workers, one CPU decode worker and two texture
pipeline lanes spanning read/decode/upload/retirement. A lane retains its
workspace reservation until its relevant buffers actually retire. Accepted
requests may wait in bounded stage queues derived from existing reservations;
there is no hidden retry queue for a request refused busy. GPU work stays on
the graphics owner and window work on GLFW's owner; neither executes Lua.

I/O workers return bounded verified buffers and release their execution slots
before waiting on Lua evaluation, decoding or a logical due tick. Decode
releases its execution slot at handoff; pipeline/buffer ownership persists
through GPU completion. Never hold a worker while waiting for another job on
the same pool. Module evaluation follows D-58 on its VM. Reserve the active
chain's source lane so unrelated ready buffers cannot starve its dependency;
lacking prefetch budget delays prefetch, not that chain.

Within each stage use oldest eligible admitted work first, with active-chain
dependency progress ahead of unrelated prefetch. This does not reorder Lua
evaluation or logical result positions by file completion. Shared module jobs
remain VM-owned even after every waiter leaves. Cache/request bounds cap all
queued jobs; auxiliary lists/maps cannot grow without a corresponding admitted
owner. Shared workers still offer no hard latency/preemption guarantee for
filesystem/decoder calls or a non-yielding script.

Reserve completion/cancellation/retirement bookkeeping on admission, so drain
does not need a free ordinary request slot. Keep sinks, anchored roots, provider
guards and native owners alive through actual use. Partial boot/stop withdraws
queued work where possible and drains started work through protected cleanup
before releasing providers/root handles. A cancellation acknowledgement or
worker exit alone is not evidence that all native/GPU dependencies retired.

#### 5. Numeric types, time and exhaustion

Logical tick/cadence/offset/wait counts and generated public counter values
use Lua integers through `2^63 - 1`; tick 0 is init and positive counts start
at 1. Window and texture dimensions also use the integer subtype: `1.0` is
refused where an integer is declared. D-66 clear channels retain their explicit
integral-float allowance. Coordinates/elapsed seconds accept either numeric
subtype but not strings, NaN or infinity.

Keep D-74's full positive Word64 nanosecond range for manifest tick duration.
Lua elapsed wait/cadence must be finite/positive and its exact represented
value times 1,000,000,000, rounded upward, must fit that duration range.
Convert with checked arithmetic, without overflow or accidentally rounding
down. Check tick+offset, tick+wait and clock+duration before accepting calls;
invalid/unrepresentable input is an ordinary Lua error before work. Seconds/dt
are finite approximations, not a replacement for exact logical tick identity.

Sequences and instance identities never wrap/reuse. Exhaustion before admission
is an ordinary permanent-limit Lua error with no handle/work, not busy.
Autonomous tick/clock exhaustion or internal checked-arithmetic failure after
valid admission ends the session as an engine failure (1), without publishing
wrapped time. Validate already-impossible initial pacing deadlines before Lua.
Use injected near-limit clocks/counters, not long-running or hanging probes.

#### 6. Classification, qualification and costs

Temporary request/result/lease/byte reservation pressure is busy before
acceptance, with no partial reservation/native work. Permanent malformed
arguments and numeric/path/scene/pre-admission cache/sequence limits are
ordinary Lua errors. Oversized/invalid content discovered for an accepted
request uses too_large/module_limit/other expected-failure records under the
required/optional policy. Stage backpressure never turns acceptance into busy.
Engine/provider/cleanup faults remain fatal; these limits do not convert
arbitrary Lua CPU/heap exhaustion into recoverable content errors.

Qualify limit-and-one-past cases, failed multi-reservations with zero provider
calls, cancellation/completion races, held logical results, full prefetch
buffers with an active dependency, and full ordinary queues while cleanup
drains. Prove one instance's cleanup preserves the other's resources and that
released displayed textures remain charged. Use small injected limits plus
real codec/offscreen/native paths; fake providers alone cannot qualify the arc.

Evidence: the [Lua value boundary](../../packages/scripting-lua/README.md)
supports crossings up to 16 MiB/depth 64/1,048,576 elements; an 8 MiB data
result leaves envelope space inside its existing byte ceiling. Its module
baseline is 256 identities/1 MiB source. Current
[PNG checks](../../packages/asset-image/README.md) establish structural safety,
not this allocation/inflation budget. The GPU budget model and scene ledger
already derive bounded frame/generation/adoption state; image2d selects a
2 GiB byte budget. These are starting points, not proof that M1 reservations
and pools already exist.

Recommend this fixed profile so implementation/verification have concrete
limits without a tuning API. Costs: unused large files can fail boot; PNGs over
2,048 per axis must be resized; large data split; at most two harness instances
per VM; worst-case texture reservation can return busy early; displayed released
textures hold capacity; maximum native geometry is not guaranteed allocatable;
and worker/decoder accounting requires real work. These are not hostile-code
containment or whole-Lua/process/driver memory caps. Changed limits or tunability
need a package revision, not silent relaxation during implementation.

### P-75. Reconcile the vision and close the delivered trusted arc explicitly

**All five parts confirmed by D-79 through Q-8.** The five parts below contain
the confirmed reconciliation text and dispositions. D-79 authorizes this
designer's narrow vision/old-design edit; the manager owns tracker and MEMORY
follow-up. The design remains the wording record. Stable principle,
decision and slice IDs, prior quotations and qualification evidence survive.

#### 1. V-1: the Lua game is the application; the engine remains generic

Replace V-1's opening paragraph with:

> Build a modular Haskell engine using Lua for game authoring and Vulkan for
> the first graphics backend, with independent 2D and 3D renderers. The generic
> executable assembles services and starts a game's Lua content without
> game-specific Haskell. The Lua game is the application: it defines game
> rules, authored data, assets and orchestration through narrow engine services.
> Engine packages never import concrete games. Use narrow services and opaque
> handles, not a universal EngineEnv, service locator or mutable global
> registry. An application-wide monad must not conceal dependency ownership.

Append to that paragraph:

> Owner direction of 2026-10-21: the later gameplay-state arc is engine-held
> and Lua-defined. The Lua-first textured-quad milestone deliberately has no
> gameplay state store; state-service calls report unavailability and stop
> the session. This deferral does not assign an authoritative world to Lua
> tables or promise rollback of Lua mutations. The milestone's scope and
> service contracts are in the Lua-first engine design, D-41–D-43.

The rest of V-1, including math and subsystem boundaries, stays applicable.
Haskell still owns native threads, protected lifetimes, resource accounting,
graphics completion and service construction. A Lua-facing facade is an
instance-bound collection of granted functions, not an engine-wide Haskell
environment. No sample's concrete game schema migrates into engine packages.

#### 2. V-9 and related principles: trusted filtered Lua, with honest M1 limits

Change V-9's title to **Responsive trusted Lua domains with filtered services**.
Replace its first four paragraphs (through the confinement-verdict paragraph,
before the D-23 determinism paragraph) with:

> Own independent logical and UI/presentation execution domains with bounded
> scheduling and communication. Owner direction of 2026-10-21 treats game and
> mod Lua alike as trusted, in-process code. Both use the same filtered
> standard-library policy and engine-provided content services. Scripts receive
> no ambient OS, filesystem, network, process-launching or native-loader API.
> The Lua-first design specifies the removed functions, content-root access
> and phase/instance checks; mod activation is later work, not part of M1.
>
> Filtering is not hostile-code containment. A trusted script can hang its VM
> or exhaust application memory. Cooperative budgets, provider accounting,
> distinct VMs and module environments are not hard execution or memory limits.
> Direct bindings cannot synchronously enter another VM owner. Dependencies
> remain held until actual completion; cancellation is not proof of retirement.
>
> Confined processes are no longer a requirement for trusted game/mod delivery
> or completion of the delivered trusted Lua arc. LUA-9–LUA-13, LUA-16 and
> LUA-17 are deferred outside the active roadmap by the revised trust decision.
> LUA-14/LUA-15 remain delivered feasibility investigations with inconclusive
> verdicts, not qualified containment. If hostile-code support is requested
> later, it needs an explicit new scope/readiness decision and successful
> platform qualification before dependent confinement work; there is no
> unconfined fallback for content admitted as untrusted.
>
> An ordinary logical-role failure stops that role while a healthy UI can
> report it until exit. In M1 the UI receives lifecycle/failure status, not
> a world snapshot: there is no engine-held gameplay state to freeze or roll
> back. UI-role failure, engine/provider/cleanup failure, or a call to the
> unavailable state service ends the session. The Lua-first startup gate and
> one-role rules define the cases where no healthy UI can continue. Callback
> threads remain runtime machinery, not cancellation endpoints.

Keep the existing D-23 paragraph as the **later authoritative-simulation
direction and existing sample's qualified contract**, with this explicit
paragraph immediately after it:

> For Lua-first M1, retain exact fixed logical tick duration, stable scheduled
> effect positions and assigned result delivery; late work delays progress
> without skipping ticks or stretching dt. The logical VM runs ordinary Lua
> hooks and module/data loads with Lua-local state, while the UI has its own
> elapsed clock. M1 has no state store, committed-world/digest/replay API,
> engine RNG or seeded-stream guarantee; math.random and math.randomseed are
> removed in both roles. It claims no whole-session or cross-run gameplay
> determinism. The existing lua-domains sample retains its own D-23/D-48
> qualification, including the limit on late independent failures. Its state
> transactions, replay and seeded streams are not M1 services.

Keep the D-27 cleanup paragraph unchanged: failed init, lost handles, absent
or throwing shutdown cannot bypass engine-owned retirement. Preserve the
historical D-12–D-14 and D-23 decisions in the old design, with links to the
new scope qualification rather than rewritten old quotes.

For V-4, append this scoped clarification:

> Lua-first M1 distinguishes pre-admission busy refusal with no work started,
> ordinary Lua validation/phase/ownership errors, accepted optional content
> failure, and latched required failure. Catching or ignoring a required
> failure does not clear it. Whole-scene refusal keeps the previous complete
> scene; it does not roll back arbitrary Lua or resource effects. Engine and
> cleanup failures retain fatal authority and primary/secondary evidence.

For V-5, qualify the old "a simulation driver is deferred" sentence with:

> Lua-first M1 introduces a logical Lua tick driver, not a gameplay-state
> simulation/commit service. UI publishes copied latest scenes independently
> of logical completion. Service workers, results and retirement bookkeeping
> have explicit finite ownership and admission budgets.

V-2/V-3/V-6/V-8/V-10 retain their boundaries. In particular, Lua release does
not retire GPU use, a window's native close requests whole-session quit by
D-51, and ending one test instance must not invalidate its peer. That session
quit policy does not weaken independent resource ownership. Headless tests
do not establish the rendered result; Linux and local macOS need their own
evidence. No new hard latency or platform support claim is added.

#### 3. Preserve the old Lua design as a completed trusted foundation

Proposed current-status wording for `docs/lua_runtime_design.md`:

> Trusted milestone delivered and owner-accepted at b7f3b56e on 2026-10-21.
> The owner's later trust decision treats game and mod Lua alike as trusted.
> LUA-9–LUA-13, LUA-16 and LUA-17 are deferred outside this completed trusted
> milestone; they are not implemented or qualified. Q-5 remains unresolved
> technical evidence for any future hostile-code arc, not a prerequisite for
> Lua-first M1 or later trusted-mod activation. The new Lua-first design is
> the named consumer of this delivered foundation and governs its M1 profile.

Reconcile the old design's current status, seven deferred ledger annotations,
epic completion wording and next-session handoff consistently with that text.
Preserve all thirty-one LUA IDs, dependencies as historical/later-arc material,
accepted historical decisions and delivered receipts. Do not mark the seven
as done, erase the original threat model, or rename an inconclusive verdict
successful. Add dated supersession notes to conflicting current requirements.
Any later revival requires owner scope/readiness signoff and renewed assessment
of then-current platform evidence; old unsuccessful proofs never unlock it.

Existing Lua host/runner/sample contracts continue to describe implemented
behavior. M1 may add narrow profile and admission facilities, but does not
silently change the existing `lua` command's library policy, general host's
failure semantics, sample's state contract or existing configurable limits.

#### 4. Revise #145's scope, close that arc, and use a separate M1 epic

Proposed exact title: **Establish trusted UI and gameplay Lua execution**.
Proposed disposition after applying the confirmed scope revision: **closed,
completed under the revised trusted scope**. The full proposed replacement body
is below. The original issue-origin marker is retained as historical authorship
of #145; this revision is recorded by its dated scope note and design link.

```markdown
## Owner scope revision — 2026-10-22

Trusted UI/gameplay Lua delivery is complete through LUA-8, #500 / PR #509,
b7f3b56e, accepted by the owner on 2026-10-21. The owner's subsequent direction
treats game and mod Lua alike as trusted in-process code with a filtered
library. The Lua-first engine design records that direction and its M1 scope.

The seven unfiled confinement slices LUA-9–LUA-13, LUA-16 and LUA-17 are
deferred outside this epic's required scope. Their code was not delivered;
the Linux and macOS feasibility verdicts remain inconclusive. Closing this
revised epic records the trusted foundation's completion, not completion of
the original all-thirty-one-slice confinement contract.

The Lua-first textured-quad M1 is a separate consumer arc with its own design,
future epic and acceptance. It reuses the delivered host/runtime; it does not
recreate this epic, admit untrusted code, or implement a gameplay state store.

## Delivered goal and qualification

A reusable trusted Lua host and runtime adapter run independent UI and
gameplay VM owners without a concrete game, window or renderer in the engine
host. Application-owned bindings, modules, instances, scheduling, asynchronous
requests and resource leases preserve explicit admission, failure and cleanup.
The headless lua-domains consumer proves the integrated trusted milestone.

Its deterministic gameplay qualification is limited to the same build,
supported platform, initial state, content, seed, tick-assigned inputs and
scheduling configuration. D-48 limits failures that begin after a tick's
accounting cutoff. The sample owns its world, commit, snapshot and replay
policy; it is not a delivered generic engine state store.

Trusted Lua may hang its VM or exhaust process memory. Cooperative budgets
and separate VMs do not establish hostile-code containment. Host/provider/
cleanup failures preserve fatal authority; dependencies remain protected
until actual retirement. The Lua-first profile's added filtering, content
services and graphics bindings belong to its new consumer arc.

## Completed deliveries

- [x] LUA-1. Lua binding and foreign-call boundary — #146
- [x] LUA-14. Linux confinement feasibility investigation — #147; inconclusive
- [x] LUA-15. macOS confinement feasibility investigation — #148; inconclusive
- [x] LUA-2. Protected VM lifetime — #460
- [x] LUA-3. Application-owned modules and bounded value bindings — #462
- [x] LUA-4. Bounded task and protocol model — #149
- [x] LUA-5. Runtime-supervised trusted VM owners — #464
- [x] LUA-20. VM-owned task coroutines — #466
- [x] LUA-21. Scheduling policies, logical time and owned timer — #467
- [x] LUA-6. Cooperative tasks and bounded service turns — #468
- [x] LUA-18. Instances, hooks and lifecycle controls — #472
- [x] LUA-25. Resource-collection loans to synchronous callbacks — #476
- [x] LUA-22. Engine-held instance leases — #473
- [x] LUA-23. Granted lifecycle controls across owners — #474
- [x] LUA-24. Logical and elapsed update cadences — #475
- [x] LUA-7. Asynchronous requests with reserved results — #482
- [x] LUA-26. Owned provider-event subscriptions — #483
- [x] LUA-27. Reusable Lua runner — #492
- [x] LUA-28. Logical runner and instance events — #493
- [x] LUA-19. Headless command-line entry — #494
- [x] LUA-29. Two-domain headless consumer — #498
- [x] LUA-31. Wait for accepted-tick accounting — #503
- [x] LUA-30. Explicit failure, overload and stop — #499
- [x] LUA-8. Integrated trusted two-domain acceptance — #500

The checked feasibility investigations delivered evidence, not successful
containment qualification. Completed implementation children retain their
original issues, PRs, receipts and contracts.

## Deferred outside this revised epic

- [ ] LUA-9. Child-process transport and lifetime — deferred, not implemented
- [ ] LUA-10. Linux confinement — deferred, not implemented
- [ ] LUA-11. macOS confinement — deferred, not implemented
- [ ] LUA-12. Parent-enforced execution/resource budgets — deferred, not implemented
- [ ] LUA-13. Parent-brokered mod capabilities — deferred, not implemented
- [ ] LUA-16. Confined runtime integration — deferred, not implemented
- [ ] LUA-17. Confined/adversarial acceptance — deferred, not implemented

These are preserved historical slice IDs, not outstanding requirements for
closing the revised trusted epic. They are not automatically scheduled or
filed as placeholder issues. Any future hostile-code product needs new owner
scope/readiness signoff and successful Linux/macOS qualification before the
dependent confinement work; Q-5's inconclusive evidence does not unlock it.
Content admitted as untrusted must never fall back to in-process execution.

## Revised completion and successor

This epic is complete under its revised scope: the required trusted host,
runtime, lifecycle, request and integrated headless deliveries above are
merged and the owner accepted LUA-8. No claim is made that the superseded
confinement completion criteria were met. The historical contract and slice
dependencies remain in docs/lua_runtime_design.md, with supersession notes.

The successor M1 is defined in docs/designs/lua_first_engine_design.md. It
requires a real logical runtime with stub content and a Lua-driven textured
quad in a rendered window, including asynchronous loading, protected cleanup,
offscreen/native evidence and independent-instance qualification. It excludes
mod activation, gameplay state, replay, hot-swap and general input. Its epic
and children are filed only through the separately authorized design-processing
workflow after readiness. Existing #446 remains separately deferred.

## Evidence and related work

- Trusted acceptance: #500 / PR #509 / b7f3b56e.
- Owning host contract: packages/scripting-lua/README.md.
- Sample contract: samples/lua-domains/README.md.
- Design/history: docs/lua_runtime_design.md.
- Alignment evidence: docs/guide/2026-10-21T140406Z-b7f3b56.md (snapshot-scoped).
- Inconclusive platform evidence: docs/archive/lua_linux_confinement_verdict.md
  and docs/archive/macos_confinement_verdict.md.
- Clock/scheduling predecessor: #131/#133; window/graphics lifetime: #140.
- Foundation FND-5 overlaps delivered LUA-2/LUA-3 and must be reconciled by
  reference, not filed again as another Lua host.

<!-- issue-origin:claude -->
```

Keep the completed child references and seven explicitly deferred entries.
Replace the live "all thirty-one required" and process-acceptance obligations
with the revised required trusted scope; retain the original contract through
the dated history/design record. Do not check deferred boxes, create placeholder
confinement issues, or reinterpret the two feasibility deliveries as successful
deployment. #145's old no-graphics acceptance remains true of its delivered
foundation; it does not prohibit the separate Lua-first consumer.

After M1 readiness, process this document's EPIC as a **new M1-only tracker**
with #145 as its delivered predecessor, not as a new Lua host/confinement epic.
Existing #446 remains separately deferred and is not a prerequisite for a
full-image textured rectangle. Trusted mod activation, the generic state store,
hot-swap and broader presentation/input remain later arcs; this does not create
or order them. Recheck for overlapping work again during readiness/processing.

Alternative considered: keep #145 open as a combined future confinement and
M1 umbrella. It retains a misleading required-scope mixture and makes M1
completion depend on work the owner explicitly deferred. Reusing #145 for M1
would also mix delivered foundational acceptance with a new graphics consumer.
Recommend the explicit revised closure and separate epic for clear completion.

#### 5. Reconciliation handoff, costs and next checkpoint

The manager's follow-up should apply approved wording to vision/old-design
current sections and reconcile #145 before the M1 epic is filed. It should
also arrange a narrowly scoped, owner-authorized standalone MEMORY.md update:
that file is test/tool-read and cannot be landed by this document's docs-push.
Proposed replacement meaning for its Lua status/trust/Q-5 entries:

> The trusted Lua foundation is delivered and owner-accepted. Game and mod Lua
> now share a trusted in-process, filtered-library policy. Confinement is
> deferred outside active trusted delivery; its inconclusive platform findings
> remain preserved for any later hostile-code investigation. Lua-first M1
> designs a textured quad with a real logical VM and no gameplay state store
> or mod activation. Its design records current readiness and next steps.

Preserve MEMORY's expensive platform facts and "never weaken isolation to turn
an inconclusive proof into support" rule. Do not fold unrelated memory or
vision cleanup into this reconciliation. The old vision's documentation-lane
sentence is already superseded by AGENTS; that is not a new design decision.
Historical guide reports remain snapshot-scoped evidence, not rewritten to
claim they reviewed this later scope.

Costs and limits for signoff: trusted mods no longer have a mandatory planned
hostile-code boundary; they may hang their VM or exhaust memory. A future
untrusted product would need a newly authorized qualification arc. #145 closes
only after an explicit scope reduction, not because its original seven missing
deliveries somehow happened. M1 will have a new epic, and documentation/tracker
bookkeeping must be reconciled before filing it. None of this adds a state
store, replay system or mod activation back into the quad milestone.

Under D-78, Q-9 proceeds alongside the wording confirmation. The manager reviews
and signs off the process-only slice decomposition; design gaps return to the
owner. This package grants no implementation or automatic publication authority
outside this document. Final readiness remains a separately recorded checkpoint.

### P-76. Deliver M1 through bounded implementation slices

**Accepted by D-80 through Q-9 under D-78's process grant.** The Processing
status and Delivery plan contain the same twenty-six stable IDs in dependency-
valid order. The initial twenty-five-slice draft is revised by inserting
LFE-26 after LFE-13; later IDs stay stable. These implement approved behavior
only, not twenty-six filed issues or a time estimate.

The first executable end-to-end quad is LFE-22, after its reusable providers
and bindings work; LFE-23–LFE-25 complete the cross-service and visual/native
evidence required for M1. Earlier slices each deliver a working, tested public
or subsystem boundary. No skeleton-only placeholder PR, temporary game-specific
Haskell launcher, fake production loader, or later replacement of ownership is
planned. Existing host/scheduler/renderer mechanisms are extended narrowly.

The manager may change process boundaries/order without returning to the owner
so long as behavior, scope, evidence and ownership remain the approved ones.
Retain stable IDs once referenced; subsequent splits get new IDs and an explicit
dependency/ledger revision. A change to a limit, format, VM/failure policy,
supported content, lifetime or acceptance is a design revision and stops the
affected work for owner resolution. A hard implementation problem alone is
not permission to relax the contract.

D-79 releases the wording/publication hold. D-80 supplies manager Q-9 signoff;
finish the readiness audit after publication. No tracker creation occurs here.

## Readiness audit

**2026-10-22, audit of the D-79/D-80 plan at `7c3a67caef`: passes.** The audit
landed at `8612044b22`; D-81 records explicit manager readiness signoff under
the owner's D-78 process grant. No behavior gap remains. A future material
design revision resets readiness and returns the changed choice to the owner.

| Requirement | Evidence and disposition |
| --- | --- |
| Observable goal/completion | P-40/D-43: actual Lua quad with a real logical stub, async services, protected cleanup, offscreen/native output and two-instance qualification; LFE-22–LFE-25 complete integration evidence. |
| Scope and exclusions | D-41–D-43 and delivery tags preserve later state/mod/hot-swap/input/presentation work; state guard is terminal, not an M1 store. |
| Settled M1 behavior | D-5–D-77 plus accepted P-38/P-40 and scope precedence cover filtering, roots, modules, lifecycle, clocks, services, schemas, numeric limits and accounting. Historical "later question" references resolve through these later decisions; they are not new active choices. |
| Approved process decomposition | D-80 records manager signoff under D-78, LFE-13/LFE-26 split and review-invariant requirements. All 26 titles match the ledger; every dependency precedes its consumer, including LFE-26 inserted after LFE-13. |
| Compatibility and migration | Existing host/runner/sample contracts and CPU floor remain; new M1 profile/API is explicit. No save schema, data migration, replay guarantee or compatibility range is invented for deferred arcs. |
| Ownership/failure/evidence | Each slice names its consumer boundary, owner/test family and observable acceptance. D-80 requires invariant tables and same-shape sweeps on lifecycle work. Pixel/native evidence is required, not inferred from headless success. |
| Vision and prior arc | D-79 text landed in vision and old Lua design at 7c3a67caef. Confirmed blocks match P-75 verbatim; old D-23/D-27 paragraphs and seven unfinished confinement IDs remain preserved. |
| Tracker deduplication | Live #145 is closed under revised trusted scope; only #446 remains open and is unrelated to full-image quad delivery. New M1 epic uses the completed foundation and awaits authorized processing. |
| Durable record and checks | No missing local Markdown link targets; git diff whitespace check passed; ledger/dependency and #145 24-delivered/7-deferred counts checked. No runtime, build, native, memory-bound or performance proof is claimed by this documentation audit. |

Remaining engineering obligations are assigned to slices, not unanswered
product decisions: choose pinned compatible parser/Unicode/codec mechanisms,
prove no-follow native adapters and bounded decode allocations, extend narrow
Lua admission/evaluation interfaces, and qualify the actual runtime/graphics
composition. A failed proof that requires changing behavior returns to the
owner; process signoff cannot silently relax an accepted requirement.

Q-10 and the L-STATE/L-MODS/L-RELOAD/L-PRESENTATION entries remain deliberately
deferred. They do not block M1 readiness and create no future issues now.
D-81 now authorizes the manager-directed process-design-doc workflow. Its epic
and each child still require separate tracker approval; readiness authorizes
neither implementation nor automatic issue creation.

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
D-56 through D-59 settle resumable imports, shared-job ownership, ordering and
module-limit failure policy. D-60 through D-64 settle path grammar, Unicode
identity, inventory/hash policy, anchored root selection and hard links/mounts.
Exact loader/result APIs, provider scheduling/accounting and numeric bounds
remain open within M1; Q-2 as a whole is not marked resolved. State-store
questions remain deferred under D-41/D-43.

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

#### Q-2h. Discover module dependencies through imports or declare them before evaluation?

Resolved by D-56: P-53's A, protected resumable module-level imports and explicit
asynchronous requests for uncached modules from hooks. No separate dependency
list. Finite init, cache/cycle/failure rules and logical effect timing remain.

#### Q-2i. Does a shared module load continue after its last requester leaves?

Resolved by D-57: P-54's A, VM-owned jobs continue into the cache even without
waiters. Cancellation ends only the requesting instance's subscription;
continuing work/effects and logical delay remain possible until completion or
VM stop. Queued-dependency evaluation order is a separate checkpoint.

#### Q-2j. Serialize module evaluation chains or interleave independent loads?

Resolved by D-58: P-55's A, one chain per VM with ordered roots, depth-first
imports and reuse of queued dependencies. D-56/D-57 are explicitly qualified:
a dependency may evaluate at its importer's earlier logical position while
its independent request still settles at its own assigned position. UI order
is request-admission order, as clarified by the manager's authenticated record.

#### Q-2k. How does a full module cache or a dependency limit fail?

Resolved by D-59: P-56's A, a catchable pre-admission error for permanent module
cache exhaustion, required-load failure for accepted dependency/source/depth
limits, and no waiting, eviction or retry. Temporary request pressure remains
`busy`. Concrete numeric bounds remain open.

#### Q-2l. Require literal root-relative paths or normalize relative shortcuts?

Resolved by D-60: P-57's A, literal root-relative filenames, `/` separators,
no dot/parent/native-path shortcuts and no extension/directory search. Case,
Unicode and numeric path limits were explicitly left open.

#### Q-2m. Unicode filename identity or an ASCII-only content namespace?

Resolved by D-61: P-58's A, Unicode NFC identity, exact case lookup and startup
rejection of normalized/caseless collisions through a checked inventory mapping.
Raw file bytes remain unchanged. Numeric path limits remain open.

#### Q-2n. Fingerprint the whole selected content tree or an explicit file list?

Resolved by D-62: P-59's A, hash every regular file before Lua into a bounded
inventory and verify exact bytes on later loads. Hidden/unused files count;
initial scan failures/cost precede the Lua loading screen. No authored file
list, first-use fingerprinting or private byte snapshot.

#### Q-2o. May launcher root selection resolve symlinks before anchoring the session?

Resolved by D-63: P-60's A, resolve the native launch path once, including
selection-path symlinks, retain the actual directory owner, and anchor internal
no-follow reads to it. Renames/retargeting do not select another root.

#### Q-2p. Permit hard links/mounted subtrees or require a stricter content layout?

Resolved by D-64: P-61's A, hard-linked regular files and mounted directories
are permitted through the anchored namespace. Identities/budgets remain per
path, bytes are verified, traversal cycles rejected, and internal symlinks and
non-regular content entries refused.

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

Resolved for M1 by D-44–D-77, including exact schemas and numeric bounds.
General input, text/widgets, advanced presentation, 3D/audio are later work.
Haskell retains native threading and GPU lifetime obligations. The following
subquestions preserve each individual answer and its original scope.

#### Q-6a. Are graphics/input services presentation-only or available to both roles?

The original P-39 question was held at 19:38:08 UTC and remains unanswered.
Revision 2/P-41 is resolved by D-44: UI VM only, expressly narrowing D-9's
texture grants. Both roles retain module/data/runtime services. No general
input or mod API is included; B (graphics in both VMs) was not chosen.

#### Q-6b. Does Lua request its window asynchronously or receive one from the launcher?

Resolved by D-45: P-42's A, Lua-requested asynchronous creation with required
failure and protected cancellation. The launcher-created alternative was not
chosen. Exact API/counts and advanced window features were not selected here.

#### Q-6c. Publish copied scenes or mutate engine-owned scene objects?

Resolved by D-46: P-43's A, copied/validated complete scenes, atomic per-window
replacement, latest-scene rendering, whole-call refusal and protected texture
retention. The mutable-scene-object alternative was not chosen. No ECS is added.

#### Q-6d. Does one texture request cover reading through GPU readiness?

Resolved by D-47: P-44's A, one request through verified reading, decoding,
completed upload and registration to a usable texture lease. Separate CPU-image
and GPU-texture requests were not chosen. D-46's publication rule still applies.

#### Q-6e. Can Lua relinquish textures and pending texture loads before instance end?

Resolved by D-48: P-45's A, explicit texture release and pending-load cancellation
with protected retirement, truthful status and first-settlement-wins. Automatic
cleanup stays mandatory, and release does not edit a scene that holds a texture.

#### Q-6f. Do repeated texture loads share backing in M1?

Resolved by D-49: P-46's A, independent load/resource per request. Shared backing
is deferred, with its duplicate-work/memory cost acknowledged. The two-instance
test uses the same content path while proving separate ownership/lifetime.

#### Q-6g. What scene surface does M1 expose to Lua?

Resolved by D-50: P-47's A, clear colour plus ordered full-texture rectangles
in UI logical pixels, mapped to a full-window view with fixed M1 settings.
The broader-renderer alternative was not chosen; D-46 publication still applies.

#### Q-6h. How many windows and which window controls does M1 expose?

Resolved by D-51: P-48's A and shared rules, one slot per UI instance,
cancellable creation, native-close-means-session-quit, no independent close/
reopen or broader Lua controls. Several windows per instance were not chosen.

#### Q-6i. Does a required asynchronous failure stop its owner without a result read?

Resolved by D-52: P-49's A, failure at eligible settlement and safe-boundary
escalation without requiring a result read. Optional results and winning
cancellation remain distinct. Failure-on-read was not chosen.

#### Q-6j. Is full admission capacity recoverable or instance-fatal?

Resolved by D-53: P-50's A, atomic admission or bounded busy refusal with no
provider work or instance failure. Accepted required requests still follow
D-52; native/engine/cleanup failures are not relabelled busy.

#### Q-6k. Consume a request result once or keep a repeat-readable request object?

Resolved by D-54: P-51's A, `ready`/`take`/`wait`/`cancel` with one terminal
consumption, retaining returned data/resources under their own lifetimes.
Repeat-readable request objects with a dispose lifetime were not chosen.

#### Q-6l. Does a data-file request return bytes or engine-parsed structured data?

Resolved by D-55: P-52's A, bounded byte-for-byte strings without parsing,
execution, data caching or open-file handles. Engine-parsed data was not chosen;
the manager's parser-library example adds no selected library deliverable.

#### Q-6m. Static PNG colour textures alone or the existing KTX2 profile too?

Resolved by D-65: P-62's A, static PNG with fixed colour decoding to one RGBA8
sRGB level, no generated mips/options/animation, signature dispatch, bounds and
normal content-failure handling. Existing Haskell codec features remain available.

#### Q-6n. Author background colours as sRGB bytes or linear-light fractions?

Resolved by D-66: P-63's A and shared proposal, sRGB whole values `0..255`,
opaque clear, initial black, finite fractional/negative logical-pixel positions,
positive sizes and checked whole-scene refusal. Exact table shapes and numeric
geometry bounds remain in the API package.

#### Q-6o. May Lua select a logical load's future result tick?

Resolved by D-67: P-64's A, positive tick offset defaulting to 1, fixed assigned
positions and late-result holds. Shared module jobs use the earliest contributed
evaluation position while each waiter retains its result position. UI remains
arrival-settled; exact bounds and assignment integration remain open.

#### Q-6p. Expose role-specific clock reads and duration waits in M1?

Resolved by D-68: P-65's A, logical tick/duration reads and tick waits, sampled
UI monotonic seconds and duration waits, strict role/phase checks, and existing
cooperative yield/request waits. No init/shutdown waits or wall/CPU clocks.

#### Q-6q. Defer all engine/standard RNG access or retain standard UI randomness?

Resolved by D-69: P-66's A, remove `math.random` and `math.randomseed` in both
M1 roles, with no engine RNG/seed service or replay guarantee. Authored seeded
pure-Lua helpers remain possible. Prior sample/gameplay-stream contracts stay
in their own scope and the later arc.

#### Q-6r. Should UI Lua poll session status or receive status-change callbacks?

Resolved by D-70: P-67's A, UI-only lifecycle polling of coherent copied
status sampled per hook/resumed segment, with bounded latched failure detail
and actual retirement. No status callbacks/wakeup, progress or world channel;
logical/module-top reads are ordinary Lua errors.

#### Q-6s. Use bounded print/warn only or add structured Lua logging in M1?

Resolved by D-71: P-68's A, bounded rebound print/warn with attributed
warnings, both roles and every authored phase, synchronous serialized writes,
fatal sink failure and no separate structured Lua logger in M1.

#### Q-6t. Does orderly session quit return or terminate the invocation?

Resolved by D-72: P-69's A, either role's lifecycle hook requests whole-session
stop without a slot/busy result and returns normally. Repeats are harmless;
module-top calls are refused. Authors must return promptly; failure precedence
and safe-boundary/actual-retirement rules remain.

#### Q-6u. Defer Lua window-size reads or expose a narrow view-extent query?

Resolved by D-73: P-70's A, no M1 Lua size reads or resize callbacks. Fixed
authored rectangles retain automatic native viewport adaptation and zero-size
safety; requested geometry is never reported as actual. Responsive Lua layout
waits for later presentation work.

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

Resolved by D-79: all five P-75 parts and their exact wording confirmed.
Historical evidence and seven unfinished confinement slices remain preserved.
The designer's narrow vision/prior-design publication is authorized; the
manager owns #145 and MEMORY follow-up. Q-9 proceeds under the manager's
process authority; readiness is not implied by this wording confirmation alone.

### Q-9. What is the accepted delivery order and final scope?

Resolved by D-80 under D-78's manager process authority: the plan is accepted
with LFE-13 split, new LFE-26 and explicit lifecycle invariant/sweep requirements.
Mod activation, state, general input and hot-swap remain outside M1. No new
persistence/migration behavior is introduced. This is plan signoff, not issue
creation or PR approval; the readiness audit above records the final checks.

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

### Q-13. Approve the concrete M1 launch command and manifest package?

Resolved by D-74: all five P-71 parts approved, including the command,
strict JSON schema, role/entry selection and exact decimal-text tick duration.
The Lua API and remaining bounds are not implicitly approved by that answer.

### Q-14. Approve the core Lua module, behavior and request API package?

Resolved by D-75: all five P-72 parts approved, including the module/behavior,
facade, import/request root contexts and shared request/result schemas. The
service-specific functions/records and remaining bounds continue in Q-15.

### Q-15. Approve the remaining service functions and record schemas?

Resolved by D-76: all six P-73 parts approved after the owner saw the quad
example. Numeric ceilings and worker/resource accounting continue in Q-16.

### Q-16. Approve the fixed M1 limits and worker/accounting profile?

Resolved by D-77: all six P-74 parts approved after the numeric/worker summary
and costs were presented. These are fixed M1 assembly limits, not a tuning API
or hard whole-process containment. Next are Q-8 vision/#145 reconciliation
and Q-9 dependency-ordered one-PR delivery slices.

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

**Accepted under P-76/D-80; readiness audit recorded above.** Each section below
is one issue/worktree/reviewable code PR, including its own focused tests.
Documentation lands through docs-push and is linked from that PR before review;
it is not a separate implementation slice or a reason to rerun CI. No slice
edits MEMORY.md. Exact issue specs, final deduplication and approval belong to
the later process-design-doc workflow.

### Component and validation boundaries

These are proposed implementation locations for review, not new public Lua
behavior. Use `packages/content` for the generic CPU content-root, inventory
and verified-read service; it imports neither Lua nor graphics. Use
`packages/lua-engine` for the M1 profile, manifest, service adapters and role
composition over the existing Lua runtime, without GLFW/Vulkan dependencies.
Use `packages/lua-engine-graphics` for adapters from those narrow services to
the existing asset/GLFW/graphics interfaces. Core Lua mechanisms remain in
`packages/scripting-lua`; PNG mechanisms remain in `packages/asset-image`.
The executable assembles the concrete services. No engine package imports a
sample or concrete game, and no universal mutable environment is introduced.
Components have separate source directories and small exposed interfaces;
these locations can be refined as process work while preserving dependency
direction. A new public Haskell operation is justified by its named consumer
in this plan, not speculative future mods.

Preserve `cabal.project.cpu` and the mandatory floor without Vulkan headers or
loader dependencies. The complete rendered product builds through the explicit
Vulkan project, adding the root application/Lua/new-component dependency closure
there. Wire the full executable at LFE-22 without making routine CPU checks
open windows or claim graphics support. Build-flag/component wiring is process
work; inventing a second user command, silently degrading `run` to fake graphics,
or changing the approved `run` behavior is not. Existing `lua`, smoke, help and
default console behavior keep their compatibility coverage in both applicable
build profiles. No graphics-only dependency flows into the reusable host.

Validation names below are families, not claims that future suites already
exist. Existing targets are `hetoimasia-scripting-lua:lua-host-tests`,
`hetoimasia-scripting-lua:lua-runtime-tests`,
`hetoimasia-asset-image:asset-image-tests` and root `hetoimasia-tests`.
New content/profile/adapter suites belong to their new packages and enter
`tools/validation/catalog.json` with the first implementing slice; the full
product's console composition tests belong at root. Do not postpone registration
or failure-path tests to the final acceptance slices.

- CPU host/runtime/content/profile tests use the CPU project with focused Hspec
  selectors; e.g. `cabal test --project-file cabal.project.cpu
  hetoimasia-scripting-lua:lua-runtime-tests --test-show-details=direct` for
  runtime changes. The issue names the actual new target/selector once defined.
- Codec tests use `cabal test --project-file cabal.project.cpu
  hetoimasia-asset-image:asset-image-tests --test-show-details=direct`.
- GPU/offscreen tests use the existing `bash tools/vulkan/run.sh test` path and
  the owning registered targets. Main-thread/window tests use that runner's
  native path, with isolated Linux X11 or per-command local macOS desktop
  opt-in. New suites obey the same routing, not a parallel native harness.
- Each PR asks `python3 tools/validation/plan.py --base origin/master --head HEAD`
  for its actual required groups. This design does not invent CI receipts or
  bypass the mandatory floor. No `cabal test all` or optional hang probe is
  required merely because this arc touches Lua.

Use explicit gates, injected clocks and small validated test budgets for
ordering, cancellation and saturation; no timing sleeps as correctness proof.
Every slice preserves primary and cleanup failures, and documents owners,
threads, readers/writers, lifetime and disposal/reset behavior where introduced.
Under D-80, lifecycle-heavy issues require a PR-body invariant table for every
reservation, settlement/publication site and cancellation window: admission
before tracking, intent before issuance, and checks before final publication.
List the owner, reserved/borrowed resource, terminal authority and cleanup
action on each outcome. Before review round 1, sweep every other site of the
same shape for the same invariant, recording the searched surface and result.
Apply this at least to LFE-7/9/10/11/13/16/17/18/20/26; a later issue adds any
other slice with those risks. This is reviewable evidence, not a test count or
permission to replace race coverage with a checklist.
Retained evidence includes exact code revision, command, platform/profile and
limitations. Offscreen and native suites supplement model tests; they do not
replace boundary tests, prove performance or establish confinement.

### Proposed slices

#### LFE-1. Install the explicit filtered M1 library profile

- **Depends on:** delivered Lua host; no new LFE dependency.
- **Boundary:** an opt-in host profile installed before any authored module;
  remove D-5's complete list and D-69's RNG functions, including alternate
  references through accessible library tables. Keep other host profiles and
  the existing `lua` command unchanged. No filesystem service or launcher yet.
- **Acceptance:** real-interpreter tests enumerate forbidden names/aliases,
  preserve permitted computation/coroutines, and show separate owners cannot
  acquire an omitted library through the profile. Calls fail as ordinary Lua
  operations where specified; this makes no hang/memory containment claim.
- **Owner/tests:** Lua bridge/profile, `lua-host-tests`; document the exact
  profile and trusted-code limitation.

#### LFE-2. Add opt-in recoverable binding validation and refusal

- **Depends on:** delivered registration/runtime machinery; no new LFE dependency.
- **Boundary:** narrow opt-in pre-action validation/refusal support for M1's
  catchable errors and no-work busy return. Keep old generic binding failure
  authority unchanged. Expose only the hook needed by the M1 adapter, with
  no exception-swallowing wrapper around a fatal action.
- **Acceptance:** pcall can catch malformed/phase/owner refusals, action counters
  stay zero, and the same VM can make a valid next call. Uncaught Lua faults
  and deliberately latched required/provider/cleanup failures still stop the
  appropriate owner even when Lua catches their immediate error.
- **Owner/tests:** registration/bridge and runtime error classification;
  host/runtime tests include legacy-client compatibility and callback cleanup.

#### LFE-3. Parse the strict manifest and validate the fixed M1 profile

- **Depends on:** none; consumes approved D-74/D-77 contracts.
- **Boundary:** strict byte-oriented JSON manifest parsing and pure validation
  into role/entry/clock configuration; fixed production budget values with
  validated smaller test configurations. No filesystem traversal or VM startup.
  Parser/dependency selection is implementation work under the pinned toolchain.
- **Acceptance:** duplicate decoded keys, invalid UTF-8/surrogates, unknown
  fields, wrong types, null, size/depth limits and role/entry/tick combinations
  fail before Lua; exact decimal nanoseconds and boundary arithmetic match
  D-74/D-77. No default tick, hidden extension fields or numeric coercion.
- **Owner/tests:** CPU profile component; fixtures cover accepted manifest
  examples and limit/one-past cases without adding a Lua tuning API.

#### LFE-4. Own anchored native content roots and no-follow reads

- **Depends on:** none; generic content service independent of manifest/Lua.
- **Boundary:** native Linux/macOS root ownership resolves the launch path once,
  anchors the actual directory and opens descendants without following internal
  links, checking types on actual handles. Enumeration/read handles remain
  borrowed from a protected root lifetime; no string-prefix confinement substitute.
- **Acceptance:** temporary-directory tests exercise root rename/retarget,
  internal links, component swaps, unsupported types and partial-open failure;
  actual readers drain before root close. Preserve hard-link/mount policy and
  detect ancestor directory cycles using native identity, not path spelling.
- **Owner/tests:** new content service/native adapters, CPU platform-owned
  tests on Linux and local macOS. No real personal folder is mutated; mounting
  privileged test filesystems is not required or silently attempted.

#### LFE-5. Validate literal Unicode content identities

- **Depends on:** LFE-3's profile values, without making generic content depend
  on the Lua profile package; pass narrow limit values from the caller.
- **Boundary:** literal root-relative path grammar, UTF-8/NFC identity, exact
  case lookup and sibling caseless/normalization collision detection with a
  logical-to-native mapping. Pin the normalization/case data used; no host
  filesystem's case behavior becomes the logical lookup policy.
- **Acceptance:** composed/decomposed matches, exact-case mismatch, collisions,
  invalid encoding, forbidden separators/segments and both pre/post-normalized
  byte limits; distinct hard-link names remain distinct identities. Pure and
  native-name fixtures distinguish argument refusal from bad inventory.
- **Owner/tests:** generic content identity module and its focused CPU tests.
  No normalization shortcut, extension search or path overlay is introduced.

#### LFE-6. Build and verify the bounded whole-folder inventory

- **Depends on:** LFE-4, LFE-5; assembly limits from LFE-3.
- **Boundary:** startup traversal hashes every regular file with streaming
  SHA-256 and retains identity/path/size/digest, not all bytes. Later reads
  validate the exact returned buffer through the anchored root. Include the
  manifest bytes and every declared entry path in boot verification.
- **Acceptance:** hidden/unused files, aliases, total/individual limits,
  changing/unreadable files, directory cycles and missing/type-changed paths;
  later content edits fail, newly added paths stay absent, and parse/compile/
  decode consume only verified bytes. No hash-then-reopen race or byte snapshot.
- **Owner/tests:** content inventory/read boundary, CPU tests with controlled
  mutations and bounded buffers; no claim of an atomic filesystem snapshot.

#### LFE-7. Reserve M1 requests and results atomically

- **Depends on:** LFE-2, LFE-3; existing instance/request owners.
- **Boundary:** opt-in admission metadata carries required/optional policy and
  validated logical offset. Reserve request/result/provider credits as one
  operation or return busy with no handle/work. Supply terminal take-once,
  non-consuming ready/wait and cancel race semantics through the narrow adapter.
- **Acceptance:** full/multi-bank refusal leaves zero reservations/actions;
  due-tick versus UI delivery, required failure without polling, caught-error
  latching, cancel-first/settle-first, take-invalidates and actual-retirement
  capacity release. Inject counter exhaustion; preserve existing generic host
  semantics outside this opt-in path.
- **Owner/tests:** request/runtime internals plus M1 adapter tests with fake
  providers. No native provider or hidden retry queue is added in this slice.

#### LFE-8. Retain VM-local module exports and captured behaviors

- **Depends on:** LFE-1, LFE-2; behavior schema/limits from LFE-3.
- **Boundary:** text-module evaluation yields exactly one plain export table
  held by the VM; retain functions/graphs without copied-value serialization.
  Validate selected role behavior and capture hooks/cadence for each instance;
  fresh self remains separate from shared exports. No filesystem/import waiting.
- **Acceptance:** shared table identity within one VM, independence across VMs,
  sticky evaluation/return-shape failure, missing/non-function hooks, wrong
  cadence, private module globals, and reference cleanup on VM close. Later
  behavior-table edits do not replace captured hooks; mutable upvalues remain Lua.
- **Owner/tests:** host export references and runtime instance construction;
  real-interpreter host/runtime tests, including old module API compatibility.

#### LFE-9. Resume ordered module import chains on their VM owner

- **Depends on:** LFE-8; existing coroutine/scheduling boundary.
- **Boundary:** resumable engine-managed evaluation, one active chain per VM,
  depth-first imports in Lua call order, root/path cache and sticky cycle/failure
  results. Source suppliers are narrow injected verified-byte operations;
  production filesystem/job wiring comes later. Top level cannot acquire services.
- **Acceptance:** import suspends for source and resumes only on its VM owner;
  chain errors include paths, limits count failed/pending entries, a non-yielding
  module remains trusted code. UI hooks/stop progress while a source is held,
  and module exceptions/stop safely release loader references. No C require,
  Lua binary loader, new thread entering Lua or cross-VM direct call.
- **Owner/tests:** generic loader/runtime boundary; gated real-interpreter tests.

#### LFE-10. Load raw data through owned bounded file workers

- **Depends on:** LFE-3, LFE-6, LFE-7.
- **Boundary:** two owned I/O workers and bounded queues for accepted verified
  byte reads; data requests reserve known length, return the complete byte
  string, and account held/unconsumed/retiring payloads. Reuse the read service
  for later module and texture sources; worker slots are not waiter slots.
- **Acceptance:** raw NUL/non-text bytes, size/content errors, optional fallback,
  required failure, busy without I/O, cancellation during read and late logical
  delivery. Full normal queues cannot block reserved completion/cleanup work;
  root/sink/provider dependencies outlive every started reader.
- **Owner/tests:** content worker service and M1 data adapter; focused CPU
  tests with explicitly gated reads, no sleep-based ordering or cache.

#### LFE-11. Join shared module jobs and deliver them at assigned positions

- **Depends on:** LFE-7, LFE-9, LFE-10.
- **Boundary:** one VM-owned load job per root/path, per-instance waiter handles,
  ordered evaluation roots and independent waiter due positions. Cancel removes
  only interest; no-waiter jobs still finish/cache until VM stop. Reserve source
  space for the active dependency ahead of unrelated prefetch.
- **Acceptance:** A due at 10 importing B requested for 12 evaluates B once at
  10 while B's ticket settles at 12; UI admission order cannot be overtaken by
  faster I/O. Failed cache/join/full-cache rules and earliest-obligation-after-
  cancel match D-57–D-59/D-67. Full prefetch cannot deadlock the active chain;
  no worker waits for work that needs its own occupied pool slot.
- **Owner/tests:** M1 loader coordinator over generic Lua loader; real VMs and
  gated providers, including instance end, module failure and stop/drain races.

#### LFE-12. Bind per-instance content, request, time and output APIs

- **Depends on:** LFE-3, LFE-7, LFE-8, LFE-11.
- **Boundary:** fresh self/api with captured metadata and instance-bound dot
  calls for module/data/request/clock/wait/yield. Install lexical-root import
  semantics and rebounded print/warn before module evaluation. Inject narrow
  session-control endpoints for the following slice; no graphics dependency.
- **Acceptance:** the P-72 busy-retry example runs on real Lua; shared-module
  helpers retain lexical import roots while service requests use instance roots.
  Foreign/consumed handles, colon/extra arguments, wrong phase/VM, exact integer
  versus numeric seconds, sampled UI time and round-up/overflow cases obey
  schemas. Bounded escaped output, attribution, sink failure and serialization
  are tested without exposing original streams or logger configuration.
- **Owner/tests:** CPU Lua-engine facade/clock/output adapters; public-consumer
  tests use no internal VM handles and keep the general host unchanged.

#### LFE-13. Coordinate role startup gates, failure policy and session stop

- **Depends on:** LFE-3, LFE-12.
- **Boundary:** generic one/two-role session composition, concurrent root inits,
  UI starts on own readiness, logical ticks wait for the joint gate; fixed
  FIFO cadence over the existing scheduler. Internal narrow stop/failure/status
  endpoints support LFE-26, without adding its Lua status/control bindings here.
- **Acceptance:** both init completion orders, UI during blocked logical init,
  either init failure, no late gate reopen, logical failure with healthy UI,
  UI/one-role/engine failure, shutdown eligibility, stop and drain. Late starts
  and issued work cannot escape closure of admission. Inject overflow, partial
  startup and secondary cleanup failures; prove no reopening or false retirement.
  No world, progress channel or new event API. D-80's invariant table and
  same-shape cancellation/publication sweep precede review round 1.
- **Owner/tests:** CPU session coordinator and composed real-VM tests; protected
  provider/VM ordering remains engine-owned rather than shutdown-hook order.

#### LFE-26. Expose UI status, quit and the unavailable-state guard

- **Depends on:** LFE-12, LFE-13.
- **Boundary:** bind the copied, per-hook/resumed-segment UI status record and
  its latched failure fields; expose session quit and global/api state() guard
  through LFE-13's narrow coordinator endpoints. State guard prints once and
  latches whole-session failure; it is not a store or an ordinary role failure.
- **Acceptance:** repeated status reads within a segment agree, later segments
  see transitions, copying/mutating a result cannot mutate the engine, wrong-VM
  reads are ordinary errors. Quit returns normally, closes new work immediately,
  is idempotent and cannot be caught away; state guard stays terminal even when
  caught at module or hook scope. Failure/status publication cannot race past
  stop or erase the first failure. Test all D-76 record fields and omissions.
- **Owner/tests:** CPU session facade and real-VM tests over the coordinator;
  D-80's reservation/publication/cancellation invariant table and whole-shape
  sweep are required before first review. No new session-control features.

#### LFE-14. Preflight static PNG structure and bounded inflation

- **Depends on:** approved D-65/D-77 limits; no graphics/Lua dependency.
- **Boundary:** a bounded decoder entry/preflight path checks signature, static
  PNG profile, chunk count, dimensions, checked scanline sizes and inflation
  limit before size-derived allocation. Ignored metadata is not decompressed.
  Existing broad Haskell decode entry points remain compatible.
- **Acceptance:** APNG/non-PNG/malformed/oversized distinctions, limit-and-one-
  past fixtures, excessive compressed scanline output and arithmetic failures
  stop at the bounded operation. Prove incremental inflation obeys the cap;
  post-decode size checks or catching an out-of-memory failure are insufficient.
- **Owner/tests:** asset-image decoder boundary and codec tests; supply the
  bounded input needed by LFE-15, without claiming full workspace proof yet.

#### LFE-15. Decode the approved PNG variants within accounted workspace

- **Depends on:** LFE-14.
- **Boundary:** complete the bounded decode/conversion path for the existing
  approved PNG color/depth/interlace variants, one RGBA8 sRGB premultiplied
  level, with explicit live-buffer/workspace accounting. Reuse audited decoder
  mechanisms or extend the adapter; do not silently narrow the accepted formats.
- **Acceptance:** palette/transparency/16-bit/interlaced fixtures preserve texels
  and orientation; peak accounted encoded/inflate/intermediate/convert/staging
  payload stays within D-77's bank. Release retained buffers on refusal and
  cancellation. Document the allocation argument and excluded runtime overhead;
  RSS observation alone is not proof. Keep KTX2/BC7/mip APIs unchanged.
- **Owner/tests:** asset-image codec tests and focused allocation/retention
  assertions; unsupported library internals cannot be assumed bounded.

#### LFE-16. Own texture pipeline lanes, leases and byte reservations

- **Depends on:** LFE-3, LFE-7, LFE-10, LFE-15.
- **Boundary:** one decode worker and two texture lanes share the existing file
  workers. Reserve texture/request/result credits and worst-case nominal bytes
  atomically; shrink safely after validated dimensions. Model per-instance
  ownership and explicit release/cancel while injecting the upload backend.
- **Acceptance:** two independent loads of the same path, pipeline-stage and
  cancellation races, release while displayed/in-flight, repeated release,
  retained capacity until actual retirement, and no worker-slot deadlock.
  Full normal queues leave drain capacity. No texture cache, early CPU-scope
  disposal, module-lifetime lease or global instance resource registry.
- **Owner/tests:** CPU adapter ownership/queue model with real bounded decoder
  and gated fake GPU completion; later GPU proofs cannot replace these races.

#### LFE-17. Finish texture requests through real GPU readiness

- **Depends on:** LFE-16; delivered GPU upload/registry services.
- **Boundary:** concrete graphics adapter allocates/uploads/registers the texture
  before settling success with an instance handle and dimensions. Works before
  any window exists and borrows the protected graphics owner. Use the existing
  validated native budget and completion accounting, not an independent allocator.
- **Acceptance:** actual uploaded texels, usable registration at success,
  cancellation/instance-end at allocation/upload/registration stages and
  failure cleanup; retained dependencies survive until completion. Device/
  provider/cleanup faults remain fatal rather than optional image errors.
- **Owner/tests:** graphics adapter, existing headless GPU runner and focused
  integration tests. No presentation or window requirement for this slice.

#### LFE-18. Create and retire instance-owned windows asynchronously

- **Depends on:** LFE-7, LFE-13; delivered GLFW/graphics host.
- **Boundary:** UI window provider dispatches on the main-thread host, with one
  pending/live/retiring slot per instance, required creation and readiness once
  scene publication is accepted. Native close requests session quit; instance
  retirement closes its own window without generating a peer-ending user quit.
- **Acceptance:** concurrent create/cancel/stop, partial attachment and delayed
  actual retirement, invalid second request, slot release, title/size checks,
  no ready-before-publish capability and no displayed-frame promise. Another
  instance's target remains valid after owner retirement.
- **Owner/tests:** graphics window adapter with headless protocol tests and
  explicit native checks for actual creation/retirement; no Lua close/reopen.

#### LFE-19. Validate and copy the fixed M1 scene schema

- **Depends on:** LFE-2, LFE-3, LFE-16's neutral texture authority boundary.
- **Boundary:** exact plain table clear/sprite schema, whole-copy preparation,
  finite/Float32 checked rectangles, sRGB byte conversion and ordered full-image
  nearest sprites. Resolve ownership/readiness through narrow texture checks;
  translate to existing pure render-2d snapshots without native work.
- **Acceptance:** whole-call refusal for holes, unknown fields/metatables,
  released/foreign/not-ready textures, bad numerics or oversized scenes;
  later Lua edits do not change a prepared snapshot. Verify ordering, alpha,
  empty clear and coordinate conversion with the existing renderer oracle.
- **Owner/tests:** scene preparation adapter with CPU Lua/renderer tests;
  no rotation/crop/camera/tint/material or mutable scene-object API.

#### LFE-20. Publish scenes with completion-safe texture retention

- **Depends on:** LFE-17, LFE-18, LFE-19.
- **Boundary:** atomically publish a complete snapshot to the instance's ready
  window; reuse the latest-scene slot and bounded adopted-revision ledger.
  Publication owns texture interests through real frame/presentation use,
  including a Lua release immediately after publish.
- **Acceptance:** refusal keeps the previous scene, release prevents new scene
  use without invalidating an old one, replacement/close eventually retires
  interests, and full adopted capacity defers safely. Resize/content-scale/
  zero-size behavior remains the renderer's existing view contract. No final
  frame or GPU completion is inferred from a CPU function returning.
- **Owner/tests:** headless GPU/scene tests and focused native retention checks;
  preserve the six-revision policy and no unbounded publication FIFO.

#### LFE-21. Expose the complete UI-only graphics facade

- **Depends on:** LFE-12, LFE-13, LFE-26, LFE-20.
- **Boundary:** bind D-76's texture/window/scene/release functions to the real
  providers with per-instance capabilities, complete request values and the
  UI-only/phase/quit checks. The CPU facade receives narrow service operations;
  it does not import the concrete graphics package or share another VM's API.
- **Acceptance:** Lua init can request texture and window together; update
  collects once, publishes and releases. Wrong VM/owner/phase has zero native
  action; optional image failures return structured data, required failures
  latch without polling, late cancel cannot erase failure, and post-quit calls
  follow the exact allowed/refused split. Engine-owned cleanup survives absent
  shutdown, lost handles and throwing init/shutdown.
- **Owner/tests:** real-Lua graphics adapter tests using both gated providers
  and real GPU paths; no Haskell game rules or special-case quad binding.

#### LFE-22. Assemble the generic run command and Lua quad content

- **Depends on:** LFE-6, LFE-11, LFE-13, LFE-26, LFE-21.
- **Boundary:** `hetoimasia run GAME_ROOT` / `run -- GAME_ROOT` composes the
  protected root/inventory, profile, roles, providers, main-thread GLFW and
  graphics owner. Add the explicit full-product build wiring while preserving
  CPU-only compatibility. Ship a small content folder containing the accepted
  manifest, logical stub, Lua UI and clearly identified technical PNG fixture.
- **Acceptance:** actual P-73 flow runs without game-specific Haskell; invalid
  arguments exit 2 before filesystem work, manifest/content boot failures exit
  1 before Lua, clean stop 0, orderly signal 130 unless failure, second signal
  forces 130. Existing help/smoke/lua commands keep behavior. Common/separate
  entry and each accepted role selection use the same assembly contract.
- **Owner/tests:** executable composition and root CLI tests; real graphics
  smoke through the explicit runner. Protected stop owns all services; no
  test-only provider is substituted in the production command.

#### LFE-23. Qualify integrated failure and two-instance ownership headlessly

- **Depends on:** LFE-22.
- **Boundary:** integrated public-consumer qualification covers combinations
  that local provider tests cannot: two engine-owned instances in one VM plus
  independent role owners, shared module exports, distinct resource attribution,
  early/late failure and full-queue stop. Test composition may create the second
  instance; no Lua spawn/mod API is added.
- **Acceptance:** same-path textures remain separate interests, ending one
  instance leaves the peer operating, no lost terminal result or double cleanup,
  both init orders and role failures match status/exit, unavailable state is
  terminal even when caught, and assigned logical results are not retimed by
  I/O delay. No replay or world-transaction assertion enters this suite.
- **Owner/tests:** package/root composition Hspec tests with explicit gates
  and production loader/VM paths; fake native edges isolate races, while the
  following two slices establish pixels and desktop resource use.

#### LFE-24. Verify Lua-authored output through offscreen pixels

- **Depends on:** LFE-22, LFE-23.
- **Boundary:** drive real content/module/PNG/request/scene bindings into managed
  offscreen rendering using the existing capture/oracle facilities. The test
  adapter replaces only the display target, not decoder, scene preparation,
  texture upload, Lua API or ownership. No new Lua offscreen API is exposed.
- **Acceptance:** expected textured quad, top-left coordinates, nearest full
  image, transparent overlap/draw order, sRGB mid-grey, clipping and empty
  clear; rejected publication keeps old pixels and release-after-publish
  preserves output through completion. Retain selected evidence with checksums,
  exact source/command/profile and explicitly labeled technical assets.
- **Owner/tests:** graphics acceptance suite through the Vulkan headless runner.
  This establishes pixel semantics, not native window behavior or performance.

#### LFE-25. Qualify native windows, independent retirement and quit

- **Depends on:** LFE-24.
- **Boundary:** final full-product Linux X11 and local macOS qualification using
  the approved native harness/consent rules. Exercise the actual command and
  a public-composition two-instance harness with the same content path. Existing
  Wayland/platform rules remain; this slice adds no platform qualification claim.
- **Acceptance:** visible textured output; initial empty window allowed; resize
  clips without stretching, zero framebuffer pauses drawing and restores;
  one instance retires with pending/displayed work while the other's window
  and texture continue. Native user close requests session quit; Lua quit,
  signal stop, creation failure and cleanup retain exit/ownership rules.
  Retain platform-specific evidence; no GPU retirement inferred from a timeout.
- **Owner/tests:** root/full-product native composition and graphics native
  suites, narrowly routed by the validation catalog. Final arc accounting
  links all required receipts and deferrals; completion needs the actual quad
  and independent-instance evidence, not only green headless tests.

### Coverage and handoff checks

| Approved contract family | Owning delivery slices |
| --- | --- |
| Filtered trusted library, no RNG/ambient OS | LFE-1, LFE-2, LFE-12 |
| Manifest, exact clocks, fixed limits | LFE-3, LFE-7, LFE-12, LFE-13 |
| Root anchoring, Unicode, fingerprinted bytes | LFE-4–LFE-6, LFE-10 |
| VM-local exports, resumable imports, shared jobs | LFE-8, LFE-9, LFE-11 |
| Request schemas, required failure, busy/cancel/take | LFE-7, LFE-10–LFE-13, LFE-21 |
| Workers, payload banks, no false retirement | LFE-10, LFE-11, LFE-16–LFE-18, LFE-20 |
| PNG profile and pre-allocation/workspace bounds | LFE-14, LFE-15, LFE-16 |
| Window/texture/scene calls and per-instance ownership | LFE-16–LFE-21 |
| Concurrent boot, role status, guard/quit/output/exit | LFE-12, LFE-13, LFE-26, LFE-22, LFE-23 |
| Two-instance qualification, actual pixel/native output | LFE-23–LFE-25 |

The plan has twenty-six slices and no unassigned approved M1 service family.
That coverage statement is a design mapping, not proof that implementation
is feasible without further engineering. Concrete dependency/codec/native
obstacles must be investigated within the owning slice; if resolution would
change approved behavior or qualification, stop that slice and escalate.
Implementers may refine modules and test selectors, not weaken P-74 limits or
replace protected work with fake production providers. No later-arc decision
is silently implemented to make a current slice easier.

Before readiness: Q-8 exact wording is confirmed by D-79 and Q-9 process
boundaries by D-80; reconcile any design gaps, recheck tracker overlap and
record the final readiness authorization. Before filing
the new epic, the manager's separately authorized reconciliation must resolve
#145's current required-scope wording. The process-design-doc workflow then
handles the epic and exactly one child per invocation with its own tracker
approval. This design session creates none of them.

## Source notes

The owner explicitly supplied and instructed this session to follow
`~/.local/state/project-manager/hetoimasia/request-user-het-luafirst-20261021-1435-design-prompt.md`.
This document preserves its exact owner quotations and records relay
provenance so the local briefing is not the sole lasting record. Later answers
must record their quotation, date/time and verified relay message ID, or
identify arrival directly in the designer's pane.
