# Test classification

Owner policy, 2026-09-22: routine validation should exercise quick, important
contracts. Long real-time waits, unusual display-server behavior, deliberate
nontermination, and platform feasibility experiments belong in optional local
probes. A relevant source change alone does not request those probes. A direct
request or an explicitly invoked coordinated `$test`/`$autotest` run can select
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
| `gpu-model-tests` / `test.vulkan` | Conditional: pure retention/frame model with scripted time; no Vulkan device |
| `diagnostics-tests` / `test.vulkan-diagnostics` | Conditional: the production C validation capture and its diagnostic lifetime, with injected sinks and explicit coordination; no Vulkan device |
| `workflow-tests` / `test.workflow` | Conditional: planner, receipts, review gate, image/toolchain/native recipes, packaging, and documentation workflow contracts |
| `glfw-native-tests` / `test.glfw-native` | Conditional: real session, event wake, window, control, modes, monitors, host, input, and private lifetime integration on isolated X11 in CI |
| Native Wayland selector / `test.glfw-wayland` | Optional explicit-request CI integration; excluded from coordinated local testing because CI owns that signal |

The workflow suite retains two short runner contracts using one-second test
deadlines: timeout kills descendants, including a child ignoring TERM. These
protect CI's execution boundary and are in the conditional tooling tier. They
are distinct from the display-helper experiments exhausting production startup
deadlines. Sleeping stub processes are killed by their fixtures; `sleep 300`
in a stub is not by itself a 300-second passing-test duration.

The native suite's physical monitor hotplug and owner-loop interaction examples
remain inactive unless their dedicated environment variables request them.
Ordinary native integration returns when the observed condition occurs; a
timeout is failure, not the intended successful path. Local desktop execution
still requires fresh per-session human consent under AGENTS.md.

At baseline `da81087bb2c81e844588a0fc30197bd99201c6b9`, the local audit measured
passing execution at approximately 13 seconds for
foundation, 5 for runtime, 13 for headless GLFW, 8 for Lua (including the then
embedded five-second hazard), 4 for the GPU model, and 0.5 for console. These
exclude compilation and Cabal startup and are observations, not time budgets.
External-client compiler checks explain much of the core suite time and protect
real package boundaries; they remain required. Splitting probes does not solve
an ordinary example hanging during protected cleanup.

## Local probe inventory

All five catalog groups below have `optional: true`, `category: probe`, and no
CI worker assignment. They remain in the catalog so their commands, ownership,
inputs, and platform constraints have one authority. They must not be named in
a PR `validation-request` block; a hosted plan cannot route them. `all-hspec`
also includes them and must not be used in a PR request.

| Stable local test ID / catalog group | Command | Cost and question |
| --- | --- | --- |
| `probe:x11-helper` / `test.x11-helper` | `cabal test x11-helper-tests --test-show-details=direct` | 19 stub-based examples, approximately 3.7 minutes; startup failures, deadline exhaustion, and cleanup; no desktop |
| `probe:wayland-helper` / `test.wayland-helper` | `cabal test wayland-helper-tests --test-show-details=direct` | 11 stub-based examples, including a ten-second readiness deadline; isolated socket environment and cleanup; no desktop |
| `probe:lua-nontermination` / `test.lua-hazard` | `cabal test hetoimasia-scripting-lua:lua-hazard-probes --test-show-details=direct` | Five-second cancellation observation of deliberately nonterminating Lua in a child that the probe terminates |
| `probe:lua-confinement-linux` / `test.lua-confinement-linux` | `cabal test hetoimasia-scripting-lua:linux-confinement-probe --test-show-details=direct` | Linux only; confinement, limits, isolation, and lifetime feasibility; missing prerequisites can leave evidence unproven |
| `probe:lua-confinement-macos` / `test.macos-confinement` | `cabal test hetoimasia-scripting-lua:macos-confinement-probe --test-show-details=direct` | Darwin only; confinement and resource-limit feasibility using unsupported interfaces |

Use `--project-file cabal.project.cpu` with these commands when the GLFW SDK
is unavailable. The catalog command deadlines include compilation overhead;
they are not the probes' expected execution times.

Both confinement verdicts remain inconclusive. Read
[Linux's verdict](lua_linux_confinement_verdict.md) or
[macOS's verdict](macos_confinement_verdict.md) before selecting or interpreting
the corresponding experiment. Optionality does not turn an inconclusive result
into a supported security boundary.

Other existing apparatus is already outside routine automation:

- Native owner-loop interaction and physical monitor hotplug: select only when
  a human will perform the interaction and has approved the desktop session;
  see [GLFW's native suite](glfw.md#the-native-suite).
- `lua-hazard callback-cancellation`: unsupported-path manual diagnostic with
  potentially variable/crashing outcomes; not a pass/fail regression.
- The separate [Vulkan compatibility proof](../tools/vulkan-proof/README.md)
  project and [toolchain qualification](toolchain.md): deliberate qualification
  work, outside the routine catalog; follow their own platform and consent rules.

## Coordinated local selection

The Codex `$test` and `$autotest` routes installed by
`tools/flake/install_skills.py` select optional probes through the repository's
[local lab](../tools/flake/README.md). Its `$flake` route uses that coordinator and can
also repeatedly investigate CI-covered Hspec examples. Ordinary CI regressions
remain where they are; the stress measurement is optional. The coordinator owns
claims, deferrals, source/build provenance, all attempts, and new-probe proposals.
It records results locally and produces a readable `coordinator.md` under the
common Git directory's `flake-lab/`. No daemon or CI receipt import is involved.
Other agents may use the same CLI to participate. Their legacy generic
`codex-test` registries receive no lab claims or results; route their Hetoimasia
probes through this CLI before relying on shared exclusion or freshness.

A skill invocation selects one eligible workload. If useful existing work is
exhausted, the skill records and presents one missing-probe proposal for approval.
No-candidate because of platform constraints, deferrals or active ownership is
not permission to duplicate work or invent a coverage gap. Native desktop runs
still require fresh human consent. See the lab's README for exact commands and
state ownership; it is the authority for this repository's skill integration.

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
