# Removed records

Git history is this project's archive. Finished designs, evidence, verdicts and
tool reports are deleted from the tree when their work is done; this file names
what was removed and the last commit that holds it. Nothing here describes
current behaviour: the subsystem documents and package READMEs do.

Read a removed file with `git show <commit>:<path>`, for example
`git show 19bc8ade:docs/archive/vulkan_milestone_verdict.md`.

## `docs/archive/` — last present at `19bc8ade` (removed 2026-11-13)

Comments in two Cabal files, `hetoimasia_vma.cpp` and a few Haskell sources still
name some of these paths; they refer to the removed files.

Designs, all delivered:

| Path under `docs/archive/` | What it was |
| --- | --- |
| `designs/lua_first_engine_design.md` | Lua-first engine, milestone 1 (epic #514): Lua-driven textured quad, D-1 to D-48 |
| `designs/lua_runtime_design.md` | Lua scheduled execution domains (epic #145) |
| `designs/gpu_resource_services_design.md` | GPU resource services, GRS/VKR slices; D-1 bindless atlased textures, D-38/D-39 VMA |
| `designs/asset_design.md` | Image decoding packages (PNG, KTX2) |
| `designs/foundation_modules_design.md` | `Base`/`Types` module convention in foundation |
| `vulkan_backend_design.md` | First windowed Vulkan backend, VK-1 to VK-19, P- and Q- decisions |
| `glfw_integration_design.md` | GLFW session, windows and owner loop |
| `window_graphics_lifetime_design.md` | Window attachments and graphics dependents |
| `runtime_foundation_design.md` | Failures, recovery, contexts, initialization, workers (epic #52) |
| `runtime_scheduling_design.md` | Owner-loop demand, deadlines and native wake |
| `messaging_design.md` | Mailboxes and shared snapshots |
| `resource_ownership_design.md` | `withResource` and scoped CPU ownership (FND-1) |
| `logging_design.md` | Logging conventions and service |
| `test_architecture_design.md` | Package-owned Hspec suites and shared fixtures (epic #49) |
| `wayland_qualification_design.md` | Native Wayland qualification, WL-1 to WL-4 |

Verdicts and their evidence:

| Path under `docs/archive/` | Conclusion |
| --- | --- |
| `vulkan_milestone_verdict.md` | Met on macOS and Linux: a triangle in each of two windows sharing one device |
| `owner_loop_interaction_verdict.md`, `owner_loop_interaction_evidence.md` | RR-4: a Cocoa live resize or menu interaction blocks the owner turn's event call (68.92 s and 13.30 s measured); the evidence file is the raw probe trace |
| `graphics_owner_interaction_verdict.md`, `graphics_owner_interaction_evidence.md`, `graphics_owner_interaction_evidence_resize.md` | VK-16: the graphics owner keeps presenting during those interactions (13 ms and 17 ms mean, 21 ms worst); the evidence files are the raw probe traces |
| `macos_confinement_verdict.md` | LUA-15: macOS confinement feasibility, inconclusive |
| `lua_linux_confinement_verdict.md`, `lua_linux_confinement_evidence.md` | Linux confinement feasibility, inconclusive; the candidate profile works unprivileged |
| `gpu_allocator_parity_record.md`, `gpu_allocator_parity/run-*.md` | #331: the owned block allocator did not meet its gates against VMA |
| `gpu_vma_qualification_record.md`, `gpu_vma_qualification/run-*.md` | #361: the production VMA integration measured against the accepted limits |
| `wayland_qualification_record.md` | #207, #327: the headless native Wayland profile and Vulkan rendering on it |
| `release_request_failure_stall_evidence.md` | #438: cause of one Linux CI failure of the release-request example |
| `supervision_startup_status_evidence.md` | #568: a failed worker's status while a sibling's start is held |

Other history:

| Path under `docs/archive/` | What it was |
| --- | --- |
| `foundation_tests_mapping.md`, `runtime_tests_mapping.md`, `glfw_tests_mapping.md` | #127, #129, #130: where each example moved when the root suite was split |
| `tech_debt.md` | Technical-debt findings report, processed |
| `history/memory_before_2026-09-17.md`, `history/memory_before_2026-10-21.md` | Earlier `MEMORY.md` snapshots |
| `history/engine_foundation_design_before_2026-09-22.md` | Earlier foundation plan |
| `history/native_test_approval_issue_draft.md` | The approved draft of #124 |

## Project review — last present at `153d23c4` (removed 2026-11-13)

`docs/project_review/` (the ledger and one report per reviewed pull request) and
`docs/project_review_*.md` (the earlier batch reports and legacy cursor). The
project-review workflow is retired; the guide (`docs/guide/`) replaced it.

## Guide reports — last present at `a9731e06` (removed 2026-11-13)

Every guide report and coverage file before `2026-11-01T234207Z-ef1b9ad`. The
guide keeps only its newest report in the tree; what later runs need from the
older ones is in [guide/earlier.md](guide/earlier.md).

## Evidence of closed issues — last present at `f4e65f49` (removed 2026-11-13)

| Path under `docs/evidence/` | Conclusion |
| --- | --- |
| `lfe13-session-teardown.md` | #527, PR #567: eleven review rounds of site audits and sweep tables for the session coordinator's teardown |
| `lfe18-window-provider.md` | #533: the window provider's native runs on real windows |
| `lfe20-native-retention-diagnosis.md` | #535, PR #572: the two native `scene retention` failures came from a stale test executable still carrying a negative-control mutation; the committed source never retired a held texture |
| `lfe23-integrated-qualification.md` | #538: acceptance map of the headless integrated failure and two-instance ownership groups |
| `latched-supervision-drain-diagnosis.md` | #599: after a latched supervision failure the backend drain cycle is test-side only; the shipped `run` command is not affected |
| `issue-586-glfwinit-diagnosis.md` | #586, PR #591: GLFW 3.4's Cocoa init calls `[NSApp run]` while the application has not finished launching, and that notification is sent once per process, so a later `glfwInit` in the same process can block; diagnosis and batch runs |
| `issue-632-ps-fallback-evidence.md` | #632, PR #633: runs of the ps-fallback no-kill cleanup example |
| `content_native/qualification.md` | #518: native calls and flags of `packages/content`, local and Linux CI |

## Per-issue Vulkan records — last present at `18c3a659` (removed 2026-11-13)

`docs/vulkan/` keeps the nine records `tools/test/VulkanProof.hs` reads. The
177 other files were one local-evidence record per issue, each a receipt of
the Vulkan groups passing at one commit, with copies of the per-scenario
records beside it under `<name>/evidence/`:

- `macos-vk8` to `macos-vk19`, `linux-vk8` to `linux-vk19`, `macos-vkr2`,
  `linux-vkr2`: the VK and VKR slices of the first Vulkan backend. The VKR-2
  records also show the pinned validation layers listing a batch's open label
  region twice.
- `macos-*-split`, `linux-*-split`, `macos-wayland-settle`,
  `macos-zombie-descendant`, `macos-standing-approval`: later issues that
  touched the Vulkan groups' inputs.
- `macos-debug-utils-naming`: naming a `VkDebugUtilsMessengerEXT` segfaults on
  the pinned macOS loader and MoltenVK, which is why the backend never names
  its debug messenger.
- `shader-rebuilds-macos`: one transcript of `tools/vulkan/shader-evidence.sh`.

A pull request that affects the Vulkan groups now puts its receipt summary in
the pull request body; no record is added under `docs/vulkan/`.

## Findings reports and the CI design — last present at `14d1f575` (removed 2026-11-13)

Every processed finding became an issue that has since closed. The items
still open are carried, condensed, in [deferred_work.md](deferred_work.md).

| Path under `docs/` | What it was |
| --- | --- |
| `runtime_review_findings.md` | Low-level runtime review, 2026-09-20: RR-1 to RR-10; RR-8 and RR-9 carried |
| `runtime_capabilities_findings.md` | Runtime capability review, 2026-09-22: RTC-1 to RTC-6; RTC-1, RTC-3, RTC-4, RTC-5 carried, RTC-6 folded into RR-9 |
| `vulkan_backend_findings.md` | Vulkan backend capability review, 2026-09-22: VKR-1 to VKR-8; VKR-7 and VKR-8 carried |
| `renderer_foundation_findings.md` | Renderer foundation goals: FND-3 carried; FND-4 delivered by the 2D renderer |
| `glfw_upgrade_findings.md` | GLFW-UP-1, carried |
| `ci_validation_design.md` | Lean CI, test selection and reusable validation, CI-1 to CI-5; delivered as `validation.md`, CI-5 carried |

## The 2D renderer design — last present at `b51dd60e` (removed 2026-11-13)

`docs/designs/render_2d_design.md`: the independent 2D renderer over the shared
GPU services (epic #413), decisions D-1 to D-32 and slices R2D-1 to R2D-18, all
delivered except R2D-13, sampling an offscreen pass's target in later passes,
which is the deferred #446 (its read-eligibility question is Q-10 there). The
contracts are the `render-2d`, `render-2d-vulkan` and `render-2d-oracle`
READMEs.
