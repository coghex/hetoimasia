# Removed records

Git history is this project's archive. Finished designs, evidence, verdicts and
tool reports are deleted from the tree when their work is done; this file names
what was removed and the last commit that holds it. Nothing here describes
current behaviour: the subsystem documents and package READMEs do.

Read a removed file with `git show <commit>:<path>`, for example
`git show 19bc8ade:docs/archive/vulkan_milestone_verdict.md`.

## `docs/archive/` — last present at `19bc8ade` (removed 2026-11-13)

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
