# Test classification

Owner policy, 2026-09-22: routine validation should exercise quick, important
contracts. Long real-time waits, unusual display-server behavior, deliberate
nontermination, and platform feasibility experiments belong in optional local
probes. A relevant source change alone does not request those probes. A direct
request or an explicitly invoked coordinated `$test` run (`$test N` for several) can select
one. Keep fast regressions for serious failure paths: cancellation, cleanup,
ownership, and resource safety remain important even when failures are rare.

## Three selection tiers

| Tier | Current coverage | Selection |
| --- | --- | --- |
| Always-required evidence | Foundation, runtime, headless GLFW, console; warning-clean build and console smoke | Catalog `floor`; CI may reuse compatible passing evidence |
| Required when relevant | Lua bridge/protocol, pure GPU model, workflow tooling, ordinary native GLFW integration | Changed component/dependency inputs, explicit request, policy change, or conservative unknown-input fallback |
| Optional probes | Display-helper quirks/deadlines, Lua nontermination, platform feasibility, manual interaction | Explicit selection only; never promoted by affected inputs or fallback |

These are selection rules, not languages. The registered tests and probes here
use Hspec. Python implements validation and other tooling, which Hspec exercises;
this repository has no Synarchy-style collection of registered Python probes.
Use Hspec where practical; use Python for a boundary Hspec cannot reasonably
exercise, documenting why.

There is no single generic Cabal test executable. Ownership stays with each
package. Local agents run focused examples/suites appropriate to their changes;
the mandatory CI evidence floor is not an instruction to repeat every suite
locally after every edit. `cabal test all` ignores catalog optionality and may
execute every buildable probe. Use named suites and selectors instead.

## Audited routine inventory

| Suite / group | Classification and reason |
| --- | --- |
| `foundation-tests` / `test.foundation` | Floor: logging, resources, failures, recovery, workers, messaging, and time contracts |
| `runtime-tests` / `test.runtime` | Floor: runner, lifetime, reporting, supervision, inbox, resource smoke, messaging waits, and API boundaries |
| `glfw-tests` / `test.glfw` | Floor: headless session/window/host/graphics-owner models, native linkage declarations, and API boundaries; no desktop |
| `hetoimasia-tests` / `test.engine` | Floor: console child-process startup and exit mapping |
| `lua-host-tests` / `test.scripting-lua` | Conditional: bridge and protocol contracts; quick allocation-failure and foreign-call progress checks remain here |
| `lua-runtime-tests` / `test.scripting-lua-runtime` | Conditional: the runtime adapter's supervised owners, readiness, bounded submission, settlement, host failures, stop and refused callback waits, with real VMs under a real supervision boundary; and the scheduling machinery's policies, quanta, logical and elapsed time, owned timer, budgets, control and diagnostics, against scripted segments with an injected clock and a fake timer wake and no VM; and the scheduled owners' creation, settlement, idle, stop, failures and determinism with real Lua tasks on real VMs; and the script instances' state, hooks, events, failure and escalation, control, termination, bounds and determinism on those owners; and the asynchronous requests' admission and refusals, exactly-once settlement, waits, teardown, provider failures, settlement at the assigned tick and epochs, against a fake provider with real instances and tasks on real owners; the dependency checks need no VM |
| `lua-domains-tests` / `test.lua-domains` | Conditional: the two-domain Lua sample (LUA-29): its package and import boundary, both owners' exit records and retirement on every way out, exposure per owner, the staged commit and one snapshot per completed tick, the intention contract with its facade, admissions raced against grants, conservation of intentions, the per-segment view, both UI-progress proofs (a barrier, and a pure-Lua CPU-bound computation with the threaded runtime and a tenfold margin), the seeded stream, and the sample's executable run as a child process for its report, `--help` and exit statuses; and (LUA-30) the failure of the gameplay session with every failure/commit ordering forced by gates, the intentions' ledger on every path with overload counted by cause, delivered events, the stop and cancellation paths with the cleanup evidence, the workspace leases on every path including a failing release, the UI's isolated failure, and pause/resume as serialized lifecycle controls; and (LUA-8) the canonical state digest and trace, the tick-assigned input log and its parser and writer, the replay through the admission seam, D-23's qualification with its negative controls and the executable's record, replay and digest options, with the optional profiling probe listed under the local probes; real VMs under real supervision, no sleeps |
| `gpu-model-tests` / `test.vulkan` | Conditional: pure retention/frame model with scripted time; no Vulkan device |
| `diagnostics-tests` / `test.vulkan-diagnostics` | Conditional: the production C validation capture and its diagnostic lifetime, with injected sinks and explicit coordination; no Vulkan device |
| `lua-engine-tests` / `test.lua-engine` | Conditional: the Lua-first engine's pure configuration boundary (LFE-3): the strict manifest parser's accepted examples, byte and nesting limits at the limit and one past, syntax refusals, duplicate keys after escape decoding, the exact numeric reading of `format`, schema refusals and their fixed precedence, exact decimal tick nanoseconds; the fixed M1 profile's every value against an independent expectation, smaller validated profiles and refused ones; the manifest and entry boot checkpoint (LFE-6) over real temporary folders through the content package (the manifest bytes parsed are the bytes the scan pinned, every declared entry names an inventoried regular file, the 65,536-byte edge, cancellation while the read is held); and the package's dependency and import boundary; no Lua, no window, no GPU |
| `math-tests` / `test.math` | Conditional: pure vector, matrix, transform and projection contracts, with generated inputs and every degenerate case; no native prerequisite |
| `content-tests` / `test.content` | Conditional: anchored native roots over temporary trees (root rename and link retarget, no-follow opens with the type checked on the opened object, swaps at controlled open boundaries, FIFO and socket refusal, strict bounded reads, enumeration, hard links, ancestor cycles and the lifecycle with exact descriptor accounting at an adapter seam), plus the bounded whole-folder inventory and verified reads (LFE-6: every file hashed against known vectors, each bound at its edge and one past, growth, truncation and swaps at named boundaries, exact verified bytes or nothing, cancellation at each scan and read gate, a failed close kept beside the primary failure), plus the logical identity policy on pure values and supplied entries (literal reference grammar, NFC identity with exact case, sibling collision refusal, Unicode 17.0.0 reference vectors); headless, no display, no sleeps, injected evidence where no mount or privileged device is created |
| `asset-image-tests` / `test.asset-image` | Conditional: PNG decoding of committed fixtures to hand-stated texels, linear-light premultiplication over every (channel, alpha) pair, the cutout mark, and every refusal; pure, no native prerequisite |
| `render-api-tests` / `test.render-api` | Conditional: the texture handle's construction and access at every `Word32` edge, its instances, and the external-client boundary (no constructor, field reader or record update from the public module); pure, no native prerequisite |
| `render-2d-tests` / `test.render-2d` | Conditional: snapshot validation with every refusal, location and boundary, the zoom-step list and its stepping, the view mapping's equations, round trips, snapping and degenerate and numeric refusals over every combination of pixel snap, zoom mode and content scale, the 64-byte instance layout against hand-written bytes and an independent reference, the flags word for every combination, and the external-client opacity of validated values, target references and view mappings; pure, no native prerequisite |
| `render-2d-oracle-tests` / `test.render-2d-oracle` | Conditional: expected pixels for hand-written fixtures (camera, zoom in both modes, rotation, UI scale, snap, filtering, sRGB against UNORM, tint, brightness, additive, overlap order, minified levels, BC7), every indeterminate case, every refusal of a defective target, index, image or readback, the readback reader, and rejection of reversed overlap, an off-by-two channel and a wrong snap in synthetic readbacks; pure, no native prerequisite |
| `render-2d-vulkan-tests` / `test.vulkan-headless` | Conditional: the 2D recorder's scissor rule against `viewportContains`, push block, attribute descriptions against the 64-byte layout, sampler-choice mapping and pure frame work, and its recording through a stand-in native layer (command order, drawing-order instance bytes at their ring offsets, mixed samplers in one draw, empty scissors, pipelines per format, and the refusals of an unknown target, invalid metrics, an unmappable view and a full ring), texture registration with its marks, the swap rule, and the host adapter's publication and refusals, holds, deferred releases and frame metrics over a coordinated stand-in host; links the Vulkan loader but opens no window or device |
| `image2d-tests` / `test.vulkan-headless` | Conditional: the image2d sample's committed PNG and KTX2 images decoded and compared with the region tables that restate them (extent, format, levels, alpha mark, premultiplied texels), its scene's layers, sizes and settings, the evidence frame's hand-stated probe colours against the tables and the frame's geometry, and the probe record's shape; links the Vulkan loader but opens no window or device |
| `workflow-tests` / `test.workflow` | Conditional: planner, receipts, review gate, image/toolchain/native recipes, packaging, and documentation workflow contracts |
| `glfw-native-tests` / `test.glfw-native` | Conditional: real session, event wake, window, control, modes, monitors, host, input, and private lifetime integration on isolated X11 in CI |
| Native Wayland selection / `test.glfw-wayland` | Required-when-affected CI integration on the isolated headless compositor since WL-3 (#207); excluded from coordinated local testing because CI owns that signal |

The workflow suite retains two short runner contracts using one-second test
deadlines: timeout kills descendants, including a child ignoring TERM. These
protect CI's execution boundary and are in the conditional tooling tier. They
are distinct from the display-helper experiments exhausting production startup
deadlines. Sleeping stub processes are killed by their fixtures; `sleep 300`
in a stub is not by itself a 300-second passing-test duration.

The native suite retains one deliberately non-exiting child for the same
reason (#207): the private-session launcher's deadline contract, that a child
still running at its deadline is terminated with its process group, reaped, and
failed whatever success it printed first. It runs with its own five-second
deadline rather than the 120-second one every other private child has, so it
costs a routine `test.glfw-native` run seconds, not minutes.

The native suite's physical monitor hotplug and owner-loop interaction examples
remain inactive unless their dedicated environment variables request them.
Ordinary native integration returns when the observed condition occurs; a
timeout is failure, not the intended successful path. Local desktop execution
takes the per-command opt-in: the owner's standing approval covers runs an issue
or pull request needs (AGENTS.md), and these optional probes run only when the
owner asks for them.

At baseline `da81087bb2c81e844588a0fc30197bd99201c6b9`, the local audit measured
passing execution at approximately 13 seconds for
foundation, 5 for runtime, 13 for headless GLFW, 8 for Lua (including the then
embedded five-second hazard), 4 for the GPU model, and 0.5 for console. These
exclude compilation and Cabal startup and are observations, not time budgets.
External-client compiler checks explain much of the core suite time and protect
real package boundaries; they remain required. Splitting probes does not solve
an ordinary example hanging during protected cleanup.

## Local probe inventory

All seven catalog groups below have `optional: true`, `category: probe`, and no
CI worker assignment. They remain in the catalog so their commands, ownership,
inputs, and platform constraints have one authority. They must not be named in
a PR `validation-request` block; a hosted plan cannot route them. `all-hspec`
also includes them and must not be used in a PR request.

| Stable local test ID / catalog group | Command | Cost and question |
| --- | --- | --- |
| `probe:x11-helper` / `test.x11-helper` | `cabal test x11-helper-tests --test-show-details=direct` | 19 stub-based examples, approximately 3.7 minutes; startup failures, deadline exhaustion, and cleanup; no desktop |
| `probe:wayland-helper` / `test.wayland-helper` | `cabal test wayland-helper-tests --test-show-details=direct` | 11 stub-based examples, including a ten-second readiness deadline; isolated socket environment and cleanup; no desktop |
| `probe:lua-nontermination` / `test.lua-hazard` | `cabal test hetoimasia-scripting-lua:lua-hazard-probes --test-show-details=direct` | Five-second cancellation observation of deliberately nonterminating Lua in a child that the probe terminates |
| `probe:lua-forced-exit` / `test.lua-forced-exit` | `cabal test hetoimasia:lua-forced-exit-probe --test-show-details=direct` | Four examples; the `lua` subcommand's second SIGINT or SIGTERM during an orderly stop that never returns exits 130 promptly, in a child the probe kills and reaps itself |
| `probe:lua-domains-profile` / `test.lua-domains-profile` | `cabal test hetoimasia-sample-lua-domains:lua-domains-profile --test-show-details=direct` | Eight examples, a few seconds; bounded workloads of the two-domain sample print one record each and assert no number (P-11): the UI's update cadence while gameplay is idle, held and CPU-bound, gameplay's throughput with the UI idle and busy, the scheduler's counters, the RTS statistics (`-T`), and requirement 5's qualification runs repeated fifty times each with how many matched the baseline's digest trace |
| `probe:lua-confinement-linux` / `test.lua-confinement-linux` | `cabal test hetoimasia-scripting-lua:linux-confinement-probe --test-show-details=direct` | Linux only; confinement, limits, isolation, and lifetime feasibility; missing prerequisites can leave evidence unproven |
| `probe:lua-confinement-macos` / `test.macos-confinement` | `cabal test hetoimasia-scripting-lua:macos-confinement-probe --test-show-details=direct` | Darwin only; confinement and resource-limit feasibility using unsupported interfaces |

Use `--project-file cabal.project.cpu` with the `cabal test` commands when the GLFW SDK
is unavailable. The catalog command deadlines include compilation overhead;
they are not the probes' expected execution times.

Both confinement verdicts remain inconclusive. Read
[Linux's verdict](archive/lua_linux_confinement_verdict.md) or
[macOS's verdict](archive/macos_confinement_verdict.md) before selecting or interpreting
the corresponding experiment. Optionality does not turn an inconclusive result
into a supported security boundary.

Other existing apparatus is already outside routine automation:

- Native owner-loop interaction and physical monitor hotplug: select only when
  a human will perform the interaction and has approved the desktop session;
  see [GLFW's native suite](glfw.md#the-native-suite).
- `lua-hazard callback-cancellation`: unsupported-path manual diagnostic with
  potentially variable/crashing outcomes; not a pass/fail regression.
- The allocator probe,
  `bash tools/vulkan/run.sh test hetoimasia-gpu-vulkan-native:test:allocator-parity-probe`:
  by default GRS-18's qualification of the production VMA integration on a
  windowless device (#361, [its record](archive/gpu_vma_qualification_record.md)),
  run once per binding variant with `HETOIMASIA_VMA_FOREIGN_CALLS` unset or
  `safe`; with `-- --virtual-block-parity`, #331's measurement of an owned
  allocator against VMA, kept as the evidence for the resource services
  design's D-38 ([its record](archive/gpu_allocator_parity_record.md)). It is
  deliberately not a catalog group: only the three required Vulkan groups may
  run a Vulkan-project command, and it reports figures rather than Hspec
  examples. It opens no window. Run it on request, on a quiet machine; each
  mode takes a few minutes after the build.
- The [toolchain qualification](toolchain.md): deliberate qualification work,
  outside the routine catalog; follow its own platform and consent rules. The
  retired Vulkan compatibility proof's cases are now the required group
  `test.vulkan-native`, and its records stay in
  [the compatibility record](vulkan_compatibility_record.md).

## Coordinated local selection

Local test and flake work runs through the external
[quruntul](https://github.com/coghex/quruntul) lab. This repository describes
itself to it in [`.quruntul/adapter.py`](../.quruntul/adapter.py), which derives
every suite from `tools/validation/catalog.json`: each Hspec test component a
group runs is one suite, a probe when its group is optional, `category: probe`
and routed to no CI worker, and a CI suite otherwise. A group that narrows a
shared executable with `--match` is its own suite — `test.glfw-wayland` becomes
`glfw-native-tests:glfw-wayland`, run with its selector under
`tools/display/wayland.sh` as CI runs it, Linux only — and the executable's
unnarrowed suite skips those examples, so each example is measured in exactly
one profile. The adapter builds each suite the way its group does, and launches
`vulkan-native-tests` through `tools/vulkan/run.sh native` as `test.vulkan-native`
does, so the runner's source-digest and revision provenance reach the suite. A
group whose own command starts the compositor around the whole executable is a
profile of its own too: `test.vulkan-wayland` becomes
`vulkan-native-tests:vulkan-wayland`, launched through `tools/vulkan/run.sh
native` inside `tools/display/wayland.sh` as CI runs it, Linux only.
Builds and trials run on the pinned toolchain: when the `ghc` or `cabal` on
`PATH` is not [the pin](toolchain.md), the adapter puts a cached directory of
links to ghcup's versioned binaries (`ghc-9.14.1` and its siblings) first on
that run's `PATH`, and refuses when they are not installed. The `workflow-tests` examples under
`Quruntul adapter` check that it still agrees with the catalog.

A suite counts as "changed since it last ran" when its identity differs from
the one its last observation recorded. That identity covers the suite's
sources (the adapter, the component's and group's declared inputs, and its
selector options) and how the suite runs, as the catalog and
`.github/workflows/validation.yml` decide it: its trial deadline (the group's
`timeout_seconds`, held between 60 and 3600 seconds), its `preparation`
command, its display (a Wayland compositor from the workflow or the group's own
command, an isolated desktop display from a `display` runner, or none) and with
it whether the suite needs the desktop, its launch path (direct or through
`tools/vulkan/run.sh native`), its platforms, and whether it is a probe or a CI
suite. A change to any of those for a group changes the identity of every
suite derived from it, so `$test` runs the probe again however recently it last
ran. Only the effective values count: a timeout edit that leaves the trial
deadline where it was, or a routing edit that leaves the suite's kind, changes
nothing, and neither does an edit to another group or to text the adapter does
not read. `test.workflow` still reads the catalog and workflow as inputs, so
any edit to them changes its own suite.

- **`$test`** runs one due probe: never run, changed since it last ran, or last
  observed more than a week ago. It never runs a CI suite. `$test N` runs N in
  sequence (this replaces `$autotest`). Each run leaves a report whose
  observations `$assess-tests` verifies and turns into issues on approval. When
  nothing is due, the skill proposes one missing probe for approval rather than
  inventing work.
- **`$flake`** measures every test, CI suites included, **once**: a new
  example runs in a batch of fresh-seeded trials and becomes `stable` or
  `flaky`. A stable test is not re-measured unless the owner marks it flaky after
  a real failure. `$deflake` fixes flaky tests through ordinary pull requests
  carrying before/after batches.

quruntul's ledger, claims, run evidence and readable `ledger.md` live under the
common Git directory's `quruntul/`. It is local evidence, never a CI receipt.
Native desktop suites follow AGENTS.md's desktop rules; the owner's 2026-09-29
decision lets a `$flake` batch run them, one window-opening batch at a time.

## Remaining harness improvement

An ordinary failing example should not hold a local agent for minutes. The
recommended follow-up is process isolation for cancellation-sensitive examples,
with compilation outside the execution deadline, live example identification,
a short watchdog, bounded TERM grace, and KILL of only the owned process group.
No automatic retry. Validate deliberate hangs and escalation in a separately
selected optional probe. Do not weaken production retirement or resource
cleanup guarantees to let a test return. This harness is a recommendation;
the existing in-process timeout ceilings have not been replaced. The lab now
provides an external guardian for its selected child executions, including
parent-death cleanup; ordinary direct Cabal test commands do not use it.
