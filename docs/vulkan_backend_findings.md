# Vulkan backend capability findings, 2026-09-22

Review of the Vulkan foundation and its delivery plan, retaining gaps that matter when moving from the triangle milestone to reusable renderer services. This report is for one-at-a-time processing; it creates no issues and does not approve new architecture or expand an existing issue.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]` reviewed and deliberately never to be filed · `[deferred]` blocked on a concrete precondition

## Methodology

Code baseline: `coghex/hetoimasia@da81087bb2c81e844588a0fc30197bd99201c6b9`. Inspected the GPU model, Vulkan proof, graphics-owner boundary, backend/foundation designs, compatibility evidence, and relevant issue bodies and approval amendments. Checked the open and closed issue inventory on 2026-09-22.

The original review inspected the runtime capability draft at SHA-256 `77d1f94efe132ea82a73cdbe5a9da29f0b6496c2757ab9c767aa8d82bfe37a3f`. On 2026-09-22 the owner converted it to [runtime capability findings](runtime_capabilities_findings.md). That report is the current handoff; its recommendations are not approved implementation issues. The docs worktree is the authoring location, not the reviewed code baseline.

This was a static review. No tests, native sessions, performance experiments, or hardware qualification ran. The production native backend is not implemented at this baseline. Except for verification/tooling omissions, these findings describe future capability gaps rather than reproduced defects in delivered rendering.

External references support engineering recommendations, not a universal mandatory engine checklist.

## Existing coverage and overlap

| Area | Existing owner | Boundary retained in this report |
| --- | --- | --- |
| Shared performance timeline, queue/worker/RTS correlation | Runtime report RTC-1 | No second tracing service. GPU timing is an owner-confirmed planned future capability; refine backend instrumentation and correlation with the shared trace format separately from the first CPU diagnostics effort. Native object names and capture labels are independent here. |
| Content requests, decoding, cancellation, loading budgets | Runtime report RTC-4 | Coordinate with the proposed content loader rather than assuming it exists or creating a second one. VKR-4 concerns the native upload endpoint and its explicit ownership/accounting handoff. |
| Stalled shutdown | Runtime report RTC-2; Vulkan #231 | Reuse drain observations and the existing device-loss policy. Native crash collection is an owner-confirmed planned future capability requiring separate refinement outside the first diagnostics effort. |
| Simulation/input/render composition | RTC-5; #232/#233 | No new simulation driver or duplicate triangle consumer. |
| Native provisioning, root ownership, diagnostics, tests, shaders, managed triangle recording | #208, #219, #217, #220, #221, #223 | Preserve these slices. Process narrow omissions as possible amendments before proposing separate issues. |
| Depth-tested 3D and textured 2D consumers | [Renderer foundation report](renderer_foundation_findings.md), FND-3/FND-4 | No duplicate renderer epic; use those consumers when refining backend extensions. |

The original broad profiling and asynchronous-loading recommendations have therefore been narrowed, not retained as independent workstreams. Allocation recovery is already specified in #229, and lifetime accounting is implemented through #160; reuse that coverage without equating planned native work with delivered code. Recheck current effective specifications during processing; an overlap note is not an issue disposition.

VKR-3 through VKR-8 remain future capability findings, not automatic gates on the accepted triangle milestone. Select a concrete consumer and refine only the capability it requires, with explicit dependencies. The triangle's existing lifetime, synchronization and completion requirements remain mandatory.

## Status

- [ ] VKR-1. Make synchronization-validation coverage explicit
- [ ] VKR-2. Identify native resources and recording regions in graphics captures
- [ ] VKR-3. Define GPU allocation beneath existing lifetime accounting
- [ ] VKR-4. Define managed resource uploads at the content-loader boundary
- [ ] VKR-5. Define access and layout transitions for reusable resources
- [ ] VKR-6. Define descriptor ownership and shader-interface compatibility
- [ ] VKR-7. Manage pipeline reuse and persistent cache compatibility
- [ ] VKR-8. Define deployment and hardware qualification beyond proof profiles

---

## Verification and developer tooling

### VKR-1. Make synchronization-validation coverage explicit

The proof enables the Khronos validation layer, but repository configuration and the native-fixture specification do not explicitly enable and record synchronization validation. A clean ordinary-validation run does not establish that access-hazard checking ran. This is a coverage gap, not evidence that an existing barrier is wrong.

**Evidence:**

- `tools/vulkan-proof/proof/Test/Vulkan/Proof/Run.hs:509` and `:540` — layer selection and the instance-create chain.
- `docs/vulkan_backend_design.md:2260` — evidence identifies the validation binary, but does not specify this setting.
- [#220](https://github.com/coghex/hetoimasia/issues/220), including amendments — owns native validation and receipts without an explicit synchronization-validation requirement.
- [Khronos validation documentation](https://github.com/KhronosGroup/Vulkan-ValidationLayers/blob/main/README.md) distinguishes default core checks from additionally enabled synchronization validation.

**Handoff context:** Prefer a coordinated amendment to #220 and its recording/submission consumers. Require explicit configuration, receipt identity, and a controlled check that demonstrates the configuration is active. Qualify the pinned layers on both platforms; preserve the native execution budget and desktop-consent rules. The actual enablement mechanism and measured cost remain unverified.

### VKR-2. Identify native resources and recording regions in graphics captures

The diagnostic design captures messages and bounded object information, but no inspected implementation or requirement assigns useful Vulkan object names or command-region labels. Validation reports and captures would consequently have less context for identifying the target, resource generation, and operation involved.

**Evidence:**

- [#217](https://github.com/coghex/hetoimasia/issues/217), requirement 2 and its amendment — bounds copied object information; it does not assign native names.
- `docs/vulkan_backend_design.md:1069` — minimal recorder operations omit capture labels.
- [Khronos debug-utils example](https://docs.vulkan.org/samples/latest/samples/extensions/debug_utils/README.html) describes native object names and command/queue labels for debugging tools.

**Handoff context:** Coordinate naming with #219/#223 and consume #217’s bounded diagnostics. Define bounded names using existing identities and balanced labels around meaningful recording regions, including exceptional recording exits. Preserve optional debug capability handling and the FFI audit. This is separate from RTC-1’s performance collector. GPU timing is planned future work and should reuse the shared correlation format where applicable; its implementation and qualification remain outside the first CPU tracing/stalled-drain effort. Tool/platform capture support still needs qualification.

## Resource services beyond the triangle

### VKR-3. Define GPU allocation beneath existing lifetime accounting

Finite byte/object budgets and retirement are implemented, but there is no production device-memory allocation strategy. The proof’s single readback allocation is not a reusable allocator. General buffers and images need allocation requirements and backing-storage reuse to compose with the existing holds.

**Evidence:**

- `docs/gpu_model.md:239` — admission accounting and backpressure, not native allocation.
- `tools/vulkan-proof/proof/Test/Vulkan/Proof/Run.hs:1662` — one buffer allocation using a host-visible, coherent memory type.
- `docs/vulkan_backend_design.md:1452` — reusable pools/arenas are intended, without a device-memory allocator contract.
- [Khronos memory guidance](https://docs.vulkan.org/guide/latest/memory_allocation.html) recommends suballocation and explains discrete/UMA memory differences.

**Handoff context:** Establish memory-type selection, alignment/granularity, required dedicated allocations, mapped-range rules, backing-allocation accounting, and completion-safe reuse before general resource creation. Evaluate a private VMA integration versus a small owned allocator; neither is selected here. Reuse #160/#229 rather than creating competing budgets or recovery. RTC-4 proposes loading-stage accounting; define how future reservations relate to backend storage without assuming that a loader already exists. No fragmentation or performance problem has been measured.

### VKR-4. Define managed resource uploads at the content-loader boundary

The triangle plan provides a readback buffer, but not a reusable native path for uploading vertex/index data or sampled images. RTC-4 already proposes content loading and ownership transfer into GPU resources; the missing backend endpoint should be designed jointly with that work.

**Evidence:**

- [#223](https://github.com/coghex/hetoimasia/issues/223), requirements 1–2 — triangle resources and verification readback; asset streaming is excluded.
- `docs/vulkan_backend_design.md:1014` — grow recording through concrete consumers.
- [Runtime capability report, RTC-4](runtime_capabilities_findings.md) — proposes requests, cancellation, loading budgets, and GPU ownership transfer.
- [Renderer foundation report, FND-4](renderer_foundation_findings.md) — the proposed 2D consumer needs shared textured resources.

**Handoff context:** Refine a native upload capability with owned source/staging bytes, bounded admission, explicit completion, cancellation after submission, and safe reclamation. Identify the exact transfer of accounting responsibility so bytes neither disappear nor acquire conflicting owners. Use the existing graphics queue initially unless a measured consumer justifies another. Do not file a second asynchronous-loader issue; the consumer and division into delivery slices remain open.

### VKR-5. Define access and layout transitions for reusable resources

The existing design explicitly distinguishes lifetime retention from synchronization. Its supported barriers cover triangle rendering and readback; extending to uploads, sampled images, and offscreen targets needs a corresponding access contract. A live resource is not automatically safe to read or overwrite.

**Evidence:**

- `docs/vulkan_backend_design.md:1069` — barriers for the minimal operations.
- `docs/vulkan_backend_design.md:1079` — retention does not resolve hazards or image layouts.
- `packages/gpu-vulkan/model/src/Hetoimasia/GPU/Model.hs:17` — the model tracks holds, not Vulkan access/layout state.

**Handoff context:** Before extending the recorder, assign ownership of image subresource layouts, buffer ranges, access/stage dependencies, and any queue-family transitions actually supported. Start with explicit checked operations; a render graph is not selected. Cover upload-to-use and attachment-to-sampling transitions, overlapping updates, and cancellation/failed recording without manufacturing completion. Coordinate with VKR-4/VKR-6 and #223; the appropriate consumer and API granularity remain design questions.

### VKR-6. Define descriptor ownership and shader-interface compatibility

The managed-retention policy anticipates transitive dependencies, but the first recorder does not supply reusable bindings for textures or per-object data. The shader-build slice preserves source/interpolation identity without establishing a general check that host layouts and bound resources match shader interfaces.

**Evidence:**

- `docs/vulkan_backend_design.md:1079` and `:1453` — descriptor contracts/pools await supported consumers.
- [#223](https://github.com/coghex/hetoimasia/issues/223) — requires exact transitive retention while excluding descriptor indirection.
- [#221](https://github.com/coghex/hetoimasia/issues/221) — reproducible shader compilation; no general host/shader interface-verification contract.
- [Khronos descriptor guidance](https://docs.vulkan.org/samples/latest/samples/performance/descriptor_management/README.html) connects binding reuse with per-frame buffer management.

**Handoff context:** Refine ordinary descriptor bindings, pool ownership/reuse, mutation while recorded or submitted, and exact retention of referenced resources. Establish checks for buffer layouts, descriptor types/counts, and supported push constants through reflection, generated declarations, or another explicit mechanism. Do not assume bindless, hot reload, or a new shader language. Coordinate with #221/#223 and the first textured consumer; the verification mechanism is unresolved.

## Pipeline and deployment readiness

### VKR-7. Manage pipeline reuse and persistent cache compatibility

The plan creates compatible triangle pipelines and reproducible SPIR-V, but does not define pipeline reuse, warmup, or persistent driver-cache handling. Ahead-of-time GLSL compilation does not remove native pipeline-creation work as renderer variants grow.

**Evidence:**

- [#223](https://github.com/coghex/hetoimasia/issues/223), requirement 1 — managed pipeline construction without a reuse/cache contract.
- [#221](https://github.com/coghex/hetoimasia/issues/221) — shader build inputs, not native pipeline caching.
- [Khronos pipeline guidance](https://docs.vulkan.org/samples/latest/samples/performance/pipeline_cache/README.html) describes early pipeline creation, reuse, and persisted cache data.

**Handoff context:** Through a representative renderer, define complete pipeline keys, reuse ownership, compatible cache loading, bounded storage, safe handling of invalid cache data, and warmup scheduling. A cache failure must not corrupt rendering. Test with temporary files and retain measurements before claiming reduced stutter. Background compilation would need explicit graphics/worker ownership; it is not implicitly authorized. This is a future capability gap, not an observed triangle slowdown.

### VKR-8. Define deployment and hardware qualification beyond proof profiles

The retained proof establishes particular Apple/MoltenVK and Lavapipe environments. It does not establish general Linux hardware support or a packaged end-user runtime. The current provisioning work must not be duplicated or mistaken for those broader claims.

**Evidence:**

- `docs/vulkan_compatibility_record.md:46` — exact proved loader, layer, driver, device, and presentation profiles.
- `tools/vulkan-proof/proof/Test/Vulkan/Proof/Run.hs:867` — proof selection takes the first device satisfying its profile.
- [#208](https://github.com/coghex/hetoimasia/issues/208) owns pinned development/CI provisioning; [#219](https://github.com/coghex/hetoimasia/issues/219) owns compatible production device/queue selection.
- `docs/vulkan_backend_design.md:1743` — only evidenced capability profiles may be advertised.

**Handoff context:** Before distribution, select the supported hardware/driver matrix, runtime dependency/discovery contract, and any application adapter preference needed beyond #219. Verify clean-machine startup without a developer SDK or mandatory validation-layer installation. Preserve required Vulkan features and presentation-completion guarantees; do not add silent fallback. Coordinate startup diagnostics with #219 and provisioning with #208; native crash collection is planned future work requiring separate refinement outside RTC-2's first stalled-drain effort. Release targets and available qualification hardware remain owner decisions, so this requires design refinement before implementation issues.
