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

## Terrain evidence of closed slices — last present at `21e527cc` (removed 2026-11-15)

Evidence write-ups of the terrain epic's closed children (#636). Each was the
round-by-round record of one pull request; the contracts are the `terrain`,
`terrain-render-2d` and `terrain-runtime` READMEs.

| Path under `docs/evidence/terrain/` | Conclusion |
| --- | --- |
| `tra13/README.md` | #655, PR #667: the corrected catalog of 16 canonical shapes and their exact openings in all four orientations, in exact CPU arithmetic; review found `openingContains` counting the solid's own boundary as air, fixed |
| `tra16/README.md` | #658, PR #674: the pure cell-quad planner and coverage picker agree with independent references on fixed scenes, and under instance pressure a column is admitted whole or not at all; CPU only |
| `tra18/README.md` | #660, PR #670: the bounded symbolic source-connectivity compiler against independent references, with growth, yielding and refusal rows; the oracle found extents such as `2^62 - (-2^62)` overflowing `Int64`, fixed |
| `tra19/README.md` | #661, PR #671: the pure model of compressed knowledge and resumable discovery after removal against an independent oracle; the oracle found a removed cell reported unknown although its void had been known, fixed |

Removed later the same day, last present at `5e536270`:

| Path under `docs/evidence/terrain/` | Conclusion |
| --- | --- |
| `tra2/storage_measurements.md` | #638: payload, metadata and allocation of the layered source and packed resident detail on four fixtures; unrequested depth holds no resident payload; one run, no speed claim |
| `tra3/residency_evidence.md` | #639: gated traces of the pure residency and admission model (shared jobs, pins, vertical turnover under fixed caps, retained-edit handoff, aging) with negative controls; conservative accounted bytes, not process memory |
| `tra4/service_evidence.md`, `tra4/rounds_1_12_followups.md` | #640, PR #664: gated traces and before-and-after accounting of the transactional terrain service, and the families sixteen review rounds found and swept |
| `tra7/q13_cpu_evidence.md` | #643: the per-face planner found no ordering counterexample and every sampled pick matched the oracle; superseded by the cell-quad planner of #658 |

Condensed in place on the same day, with the full write-up at the same commit:
`tra20/README.md` (#662, twenty review rounds of the temporary store's pure
model) and `tra21/README.md` (#663, ten review rounds of the storage backend). `suite-budget/README.md`
(#681, the terrain-runtime suite's time budget: every measurement window, the
per-example times and all 64 store controls) was condensed the same way; its
full write-up is at `218ba408`.

Removed 2026-11-16, last present at `a30fe096`:

| Path under `docs/evidence/terrain/` | Conclusion |
| --- | --- |
| `tra22/README.md` | #665, PR #683: edits and discovery commit through the temporary store; 2,945 buried removals fill a 64 MiB allowance under a pinned old version until `storage_full`, growth to 128 MiB clears it, and the edit bank's accounts stay within their limits throughout; no RSS or throughput claim |
| `tra23/README.md` | #666, PR #691: storage status, growth and recovery through Lua over the production backed service, with faults injected at the native storage seam: every new error code in both roles, pause and recovery, the growth windows |
| `regional-snapshots/README.md` | #690, PR #694: regional snapshots equal an every-cell oracle (81,920 cells at full depth); footprint 400 accounted bytes for a pristine region, 672 with one removal, always an upper bound of a heap walk; admission reserves 128 + 25,872 n + 747,520 bytes |

Removed 2026-11-19, last present at `d0cd45e8`: the records of running the
terrain suites on several capabilities, and of the three product defects that
found.

| Path under `docs/evidence/terrain/` | Conclusion |
| --- | --- |
| `capability-pass/README.md` | #685, PR #693: `terrain-runtime-tests` runs its 32 concurrent modules a second time on 2 capabilities; every failure the pass first showed was test code (waits on momentary rest instead of quiescence); it costs 35 to 55 s locally, within the 240 s budget |
| `commit-preparation/README.md` | #695, PR #698: the Lua host's per-update STM writes restarted the terrain owner's commit transaction for as long as a script ran (15,202 attempts in 10 s); the size-dependent work is now prepared before staging and each example commits at its first attempt |
| `catchstm-composition/README.md` | #700, PR #701: GHC 9.14.1's `catchSTM` reruns only its guarded action when the nested commit fails, so an allocation-free action against a stale enclosing transaction loops forever; the repair is `catchSTMRestarting` in `Hetoimasia.Foundation.Failure` |
| `reclaim-after-release/README.md` | #703, PR #704: an idle mark stamped at the store's state when the transaction ended, not at the store the plan was given, left retired pages unreclaimed after the last reader pin was released; the repair is `slotBasis` |
| `lua-capability-pass/README.md` | #692, PR #707: `lua-engine-tests` runs its terrain set again on 2 capabilities behind a pump that wakes one update at a time; six test mechanisms repaired, the three defects above found; the lab trials were dropped by the owner and no lab result is claimed |
| `tra9/` (`README.md` and the `full/` captures) | #645, PR closed unmerged 2026-11-23 (terrain views v1 moved to the consumer): the judged results of the terrain-view adapter on a real device and the headless examples, with the full-matrix pixel and pick captures; the code was never merged and the branch `issue-645-terrain-views` stays on GitHub; last commit `acebd223` |
| `tra9-v2-a.md` | #714, PR closed unmerged 2026-11-23 after sixteen review rounds (terrain views v2 slice A moved to the consumer): native, headless and planning-time results at code head `e34edcf7`; the code was never merged and the branch `issue-714-terrain-views-v2` stays on GitHub; last commit `8e479480` |

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

## Game-side designs — removed 2026-11-23

Owner decision 2026-11-23: the engine is a generic library and games are
separate projects, so the designs of game-side work leave the engine's tree.
The terrain work they planned continues in the consumer project, Widdershins;
the hand-off is recorded on epic #636, and the engine keeps the merged terrain
packages, whose READMEs are the contracts.

| Path under `docs/designs/` | Conclusion | Last present at |
| --- | --- | --- |
| `terrain_arena_design.md` | Epic #636: flat terrain with on-demand chunk loading for a procedural arena, decisions D-1 to D-61 and slices TRA-1 to TRA-23. Delivered in the engine: TRA-1 to TRA-8 and TRA-13 to TRA-23 (geometry, storage, residency, the runtime service, the 2D terrain renderer, the Lua terrain calls). Moved to the consumer unbuilt: TRA-9 to TRA-12 (retained views #645, view and camera controls in Lua #646, the authored arena #647, its qualification #648) | `cef6921d` |
| `terrain_view_service_design.md` | Terrain views v2, approved 2026-11-20: a session-owned view of retained chunks with six ordering guarantees, in two slices (#714 publish retained terrain in the graphics session; #715 pick the drawn frame and reject stale edits). #714 reached seventeen review rounds unmerged; its branch `issue-714-terrain-views-v2` and the v1 branch `issue-645-terrain-views` stay on GitHub as reference. Its ownership-transaction amendment was delivered in the foundation by #721 | `cef6921d` |
| `gameplay_state_design.md` | One small visible example of Lua-defined state over an engine-held store. Superseded by the owner on 2026-11-06 before any slice was drafted; its questions Q-3 to Q-9 (which state facilities ship, initial publication, what completes a tick, snapshots, ownership through reset, determinism, persistence) were never settled | `cef6921d` |

## Delivered engine designs

| Path under `docs/designs/` | Conclusion | Last present at |
| --- | --- | --- |
| `corner_terrain_solids_design.md` | Epic #752: corner-defined terrain solids (corner masks NW=1, NE=2, SE=4, SW=8 beside the 16 side keys), decisions D-1 to D-5 and slices COR-1 to COR-5 (#753 geometry, #754 portals, #755 packed family, #756 source, discovery and reads, #757 Lua authoring), all merged by 2026-11-26. The terrain, terrain-runtime, terrain-render-2d and lua-engine READMEs are the contracts | `92dcf371` |
