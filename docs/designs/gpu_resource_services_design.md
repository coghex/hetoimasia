# GPU resource services design

Give the Vulkan backend the shared resource services that every renderer
beyond the triangle needs — device memory, buffers and images, access and
layout ordering, uploads, bindless texture addressing and depth — once,
beneath both a future `render-2d` and `render-3d`. It carries VKR-3 through
VKR-6 of the [Vulkan capability findings](../vulkan_backend_findings.md) and
the backend prerequisites of FND-3 and FND-4 in the
[renderer findings](../renderer_foundation_findings.md). A 2D application
should get these services without constructing a 3D renderer (foundation
D-2), which is the efficiency and simplicity it lacked when 2D was a 3D
engine with a fixed viewport.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

The epic and seventeen slices, accepted for issue processing under D-25 as
amended by D-28, D-34 and D-37, are filed as the issues below. On 2026-09-30
D-38 chose VMA for production allocation: GRS-1 is superseded rather than
delivered, GRS-11 is rescoped onto VMA (#333 amended), and D-39 adds GRS-18,
filed as #361.

- [x] EPIC. Establish shared GPU resource services for 2D and 3D consumers — [#330]
- [x] GRS-1. Place allocations with a pure block allocator proven against VMA — [#331] (superseded by D-38)
- [x] GRS-18. Qualify the production VMA integration by bounded measurement — [#361]
- [x] GRS-11. Back allocations with device-memory blocks beneath the model's accounting — [#333]
- [x] GRS-2. Create managed buffers and images as retained model subjects — [#334]
- [x] GRS-3. Order access and layout for managed resources through checked operations — [#335]
- [x] GRS-15. Start the device and owner progress without a window — [#336]
- [x] GRS-12. Admit, submit and complete frame-less batches — [#337]
- [x] GRS-5. Render into a managed offscreen color target and read it back — [#338]
- [x] GRS-4. Record from vertex, index and instance buffers with push constants — [#340]
- [x] GRS-16. Check shader interfaces against compiled SPIR-V in the Template Haskell splice — [#341]
- [x] GRS-6. Upload bytes through bounded engine-owned staging with completion — [#342]
- [x] GRS-7. Own the bindless texture table and its completion-safe slot reuse — [#343]
- [x] GRS-14. Grow the texture table to its configured cap — [#344]
- [x] GRS-8. Draw textured quads from table slots in a 2D scaffolding fixture — [#345]
- [x] GRS-9. Swap a texture slot's image under the same handle — [#346]
- [x] GRS-17. Establish `packages/math` with the vectors, matrices and projections the 3D fixture needs — [#348]
- [x] GRS-10. Add depth attachments and a depth-tested 3D scaffolding fixture — [#349]
- [x] GRS-13. Give each target generation a managed depth attachment — [#350]

## Epic contract

- **Goal:** a consumer written against the native backend's public recording
  vocabulary can allocate buffers and images, upload bytes, address textures
  through stable bindless handles, draw instanced and indexed geometry with
  push constants, render depth-tested or into offscreen targets, and read the
  result back, with every resource retained and retired on completion
  evidence.
- **Done when:** every slice has merged; a 2D fixture draws
  textured quads through stable handles and a 3D fixture draws occluding
  geometry, each proven by offscreen readback with clean synchronization
  validation on the macOS profile and the Linux CI profile (or an honestly
  reported limitation under D-7); a slot swap is proven by readback; windowed
  frames render with depth; GRS-18's retained validation shows the VMA
  integration within its accepted bounds (D-39).
- **Users and operators:** the later `render-2d` (FND-4) and `render-3d`
  (FND-3) arcs, the content-loading arc (RTC-4), and maintainers reading
  retained evidence.
- **Arc label:** `vulkan` (existing).

## Current state and evidence

Checked against `master@034990a` on 2026-09-29. No builds or native sessions
ran for this document.

- **Lifetime and accounting exist.** The [GPU model](../gpu_model.md) tracks
  five independent holds on every generation and managed resource (logical
  release, ended CPU use, recorded reference, submitted use, presentation)
  and offers a subject for disposal only when all have ended. Admission
  budgets include 256 MiB of accounted bytes and 4,096 accounted objects by
  default; exhaustion is `Backpressure`, and an allocation attempt must
  reserve bytes or objects (`EmptyAllocation`).
- **Allocation recovery exists.** VK-14's
  `Native/Internal/Reclamation.hs` runs one bounded reclamation pass and at
  most one retry for a no-effect allocation failure.
- **Update 2026-09-30 (D-38).** #331 measured an owned allocator against VMA
  and missed its gates, and the owner chose VMA for production allocation.
  The evidence is [the parity record](../gpu_allocator_parity_record.md).
  The facts below are as of 2026-09-29 and still hold: no allocator exists in
  the engine yet.
- **There is no allocator.** The only device-memory allocation is the
  readback buffer's, one `allocateMemory` per buffer preferring host-visible
  and cached memory (`native/src/.../Recording/Vulkan.hs:224–243`). VKR-3's
  evidence cites the retired proof harness; this is its current location.
- **The recorder is triangle-sized.** `Hetoimasia.GPU.Vulkan.Native.Recording`
  exports pipeline layouts, pipelines, frame storage and readback buffers,
  and records dynamic rendering, pipeline binds, viewport/scissor,
  non-indexed `draw`, image transitions and `copyToReadback`. No buffers for
  drawing, push constants, descriptors, sampled images, depth or offscreen
  images. The design grows it only for actual consumers
  (`docs/vulkan_backend_design.md:1024`), limits barriers to the operations
  supported (`:1071`), and requires advanced descriptors to have their own
  reference/mutation contract (`:1081`); descriptor pools arrive only with a
  command that needs them (`:1452`).
- **Batches belong to acquired frames.** `recordFrame` reserves a batch
  against an acquired swapchain frame, and `copyToReadback` reads only a
  swapchain image made a transfer source by `newGenerationsCapturing`.
  Offscreen rendering has no batch owner today.
- **The device profile** requires Vulkan 1.3 with `dynamicRendering` and
  `synchronization2` (`native/src/.../Profile.hs:12`); no descriptor-indexing
  feature is required.
- **Bindings:** the backend uses the `vulkan` Hackage binding (3.27) and
  `vulkan-utils`; shaders are GLSL compiled to SPIR-V at build time through
  the package's `shader-toolchain` (VK-9, #221).
- **Reference workload (Synarchy, `~/work/synarchy@3b1477a10`).** Its
  `assets/` hold 6,251 PNGs totalling 243 MiB as RGBA8 (about 61 MiB as
  BC7), 93% of it unit animation frames (5,302 images, 226 MiB). 97% of
  images are under 64 KiB (48×48 and 92×92 dominate); the largest assets are
  about 846×470 (1.5 MiB). Atlased per D-1, that content becomes tens to low
  hundreds of sheets of roughly 1–16 MiB each — the allocator's main 2D
  workload — beside small buffers and per-frame data.
- **Findings owned here:** VKR-3, VKR-4, VKR-5 and VKR-6 are unprocessed;
  RTC-4 (content loading) and RTC-3 (bounded jobs) are deferred for want of a
  first content type, which textures now are — but D-3 keeps that loading
  work out of this arc.
- **No overlapping tracker arc.** Open issues are module splits (#317–#325),
  Wayland (#202) and Lua (#145).

## Desired experience

- A fixture creates a texture from raw bytes and gets back a stable handle at
  once; the handle samples placeholder slot 0 until its upload completes, and
  then its own image, with no descriptor work by the fixture.
- A fixture fills an instance buffer with sprite data (slot, UV rectangle,
  transform), pushes per-draw constants, and draws many quads in one call.
- A fixture renders into an offscreen target, reads it back once the GPU has
  finished, and the agent reads that evidence for the owner (D-6).
- Replacing a texture's bytes under the same handle shows the new image in
  later frames while frames already submitted keep sampling the old one,
  which retires only after they complete.

## Scope

### In scope

- Device-memory allocation through VMA beneath the model's accounting
  (VKR-3; D-38).
- Managed buffers and images, including sampled textures, depth attachments
  and offscreen color targets.
- Access and layout ordering for those resources (VKR-5).
- Bounded uploads from engine-owned staging with completion (VKR-4's backend
  endpoint).
- The bindless texture table, its handles, retirement and slot swap (VKR-6
  as overridden by D-1).
- Vertex, index and instance buffers, indexed and instanced draws, push
  constants.
- Offscreen rendering and readback as the evidence path.
- 2D and 3D scaffolding fixtures that exercise the above.

### Out of scope

- `render-2d`, `render-3d` and `render-api` packages (FND-4, FND-3; D-8).
- Content loading: file decoding (PNG, KTX2), the sheet-stitching build
  script, file watching, background decode workers and loader budgets
  (RTC-4, RTC-3; D-3).
- Pipeline caching and hardware qualification (VKR-7, VKR-8).
- Additional queues, async compute, multithreaded recording.
- Defragmentation and memory-budget extensions until measured.
- A render graph.

## Design

Proposals that shaped the decisions below, organized by layer; where a
decision settles one, the decision governs.

- **P-1. Layers.** Memory → resources → access/layout → recording from
  buffers → offscreen targets → uploads → texture table → fixtures. Each
  layer plugs into existing model holds and budgets rather than adding its
  own lifetime rules.
- **P-2. Pure decisions stay testable.** Allocation placement, layout/access
  legality and slot reuse are decided by pure functions beside the model and
  tested in Hspec without a GPU; native layers apply them, following the
  model/native split already used for generations and recording. Allocation
  placement left this list with D-38: VMA places allocations, and the pure
  placement survives only as a test reference.
- **P-3. Checked, explicit barriers.** The recorder refuses an access it
  cannot prove ordered, as it refuses a released handle today; no inferred
  render graph.
- **P-4. Per-frame data rings.** Instance and per-frame data live in
  per-frame-slot ring buffers that reset when the slot is reclaimed, so
  per-frame allocation never reaches the block allocator. Superseded by
  D-33's single shared ring with per-batch regions.

## Decisions

### D-1. Bindless, atlased textures

Owner decision 2026-09-29, previously recorded only in a private artifact;
it overrides VKR-6's "do not assume bindless".

- **Addressing:** one update-after-bind sampled-image array. A texture handle
  is slot plus generation; sprite instances carry a stable texture handle
  plus UV rectangle, resolved to a slot in the shader (clarified by D-23).
  The device profile requires `runtimeDescriptorArray`,
  `descriptorBindingPartiallyBound`,
  `descriptorBindingSampledImageUpdateAfterBind`,
  `shaderSampledImageArrayNonUniformIndexing` and, for a growable table,
  `descriptorBindingVariableDescriptorCount`.
- **Storage:** sprite sheets for animation and atlases for tile, flora and
  font families; no one-image-per-frame content. Sheets are a texture plus an
  optional region table.
- **Retirement:** the texture table is one managed resource held by every
  submission that binds it. A released slot is reused only after every
  submission that could have sampled it completes, per the GPU model's
  evidence; the generation catches stale handles.
- **Handles:** stable logical handles resolve through a shader-read lookup
  table; slot 0 is the placeholder until a texture is ready; handles are
  never persisted.
- **Sampling and alpha:** per-texture filtering with shared samplers chosen
  per draw (UI and SDF fonts always linear, otherwise the game's default);
  premultiplied alpha from the start.
- **Growth:** the table doubles up to a game-configured cap.
- **Evidence at decision time:** MoltenVK 1.4.0 on M3 Max offers all the
  features, 1,000,000 update-after-bind sampled images per stage (256
  without), BC and ASTC, and no `VK_EXT_descriptor_buffer`. Lavapipe was not
  checked (D-7).

Content-side parts of the same decision — PNG plus KTX2/BC7 as the baseline
formats, the stitching build script, background decode, the bounded upload
queue's loader side and hot-reload file watching — belong to the later
content-loading arc under D-3 and are preserved in Source notes.

Amended by D-27 (lookup versions protect recorded references, and a likely
sixth feature).

### D-2. The 2D consumer drives the arc, and 3D follows within it

Owner decision 2026-09-29. Capabilities are ordered by what a 2D textured
fixture needs first; the arc then continues to what 3D needs (depth,
perspective-ready geometry) rather than leaving it to another backend arc.
Buffers, push constants, uploads and the texture table are shared by both.
This reverses the renderer findings' original FND-3-before-FND-4 order for
the backend prerequisites.

### D-3. The arc ends at "texture slot out"

Owner decision 2026-09-29. The arc accepts raw bytes and returns texture
handles; its consumers are scaffolding fixtures, not `render-2d` or
`render-3d`. Decoding, asset build tooling, file watching, loader
concurrency and budgets are a later content-loading arc (RTC-4). Work
proceeds slowly and methodically, one layer at a time.

Revised on 2026-10-05 by the owner's decisions in the
[asset design](asset_design.md) (D-2, D-3): decoding PNG and KTX2/BC7 comes
forward into its own `asset` epic, ahead of `render-2d`. Build tooling, file
watching, loader concurrency and budgets remain the content-loading arc's.

### D-4. Write an owned allocator, proven by measurement

Owner decision 2026-09-29, conditional on performance parity with VMA for
this engine's workload. It suballocates large device-memory blocks, honours
alignment, `bufferImageGranularity` and drivers' dedicated-allocation
preferences, and integrates with the model's accounted bytes and VK-14's
reclamation. Parity is established by D-14's comparison with VMA, not by
targets chosen in advance; a failure to reach it reopens this decision
rather than being waived. D-13 fixes its shape.

Reversed by D-38 on 2026-09-30: parity was not reached
([the parity record](../gpu_allocator_parity_record.md)).

### D-5. Include the hot-reload slot swap if it stays tractable

Owner decision 2026-09-29. The GPU half of hot reload — replacing a slot's
image under the same handle and retiring the old image after the
submissions that sampled it complete — is its own late slice here. If
refinement shows it is easier after the content-loading arc, it moves there
by an explicit revision of this decision.

### D-6. Offscreen readback is the evidence, read by the agent

Owner decision 2026-09-29. Fixtures prove themselves by rendering into
managed offscreen targets and reading them back; no desktop session is
needed for evidence. The owner relies on the agent to interpret captures and
report findings in plain terms until visible output is richer.

### D-7. No Lavapipe contingency in advance

Owner decision 2026-09-29. Whether Lavapipe supports D-1's features is
checked when the arc first requires them. If it does not, the choice between
another Linux driver and an honestly reported macOS-only qualification (V-8)
is made then, with that evidence.

### D-8. Services extend the native backend package

Owner decision 2026-09-29. New services live in
`hetoimasia-gpu-vulkan-native` beside `Recording`; the texture handle is
Vulkan-side. `render-api` is not created until `render-2d` needs a
backend-independent handle, decided in the FND-4 arc.

Answered on 2026-10-05 by the [2D renderer design](render_2d_design.md)'s
D-12: `render-2d` needs one, so `render-api` starts with only the
backend-independent texture handle.

### D-9. Uploads copy into engine-owned staging at admission

Owner decision 2026-09-29. An admitted upload copies the caller's bytes into
engine-owned staging, so ownership transfers exactly once and the caller's
buffer is free on return. A zero-copy handoff is deferred until measured.

### D-10. Documentation lands with its slice and may also land directly

Owner decision 2026-09-29. This document holds the arc's decisions;
`vulkan_backend_design.md` gains a pointer and the D-1 override in the first
slice's pull request, and each slice updates its owning contract document
(`gpu_backend.md`, `gpu_model.md`) in its own pull request. Standalone
documentation may also land directly; reconciling the docs worktree with
`master` is routine.

### D-11. Texture-table cap and upload budget are application configuration

Owner decision 2026-09-29. The table's growth cap and the per-frame upload
byte budget are stated by the application and validated once, before use,
like the GPU model's budgets: zero, negative and unrepresentable values are
rejected, never clamped, and there is no unbounded sentinel.

### D-12. Work without presentation runs in frame-less batches

Owner decision 2026-09-29; resolves Q-4. Offscreen rendering and uploads
record into a new batch kind that belongs to no swapchain frame and carries
its own submission and completion record, so evidence runs need no window
and uploads never wait for an acquisition. Riding inside a window's frame
and a presentation-free virtual swapchain were rejected: the first
contradicts D-6, the second pretends to presentation semantics it does not
have. Verified 2026-09-29: the model admits a batch only against an
acquired frame (`recordBatch`, `docs/gpu_model.md:193`), so frame-less
batches need their own model admission, budget accounting and completion
record (proposed GRS-12).

### D-13. Best-fit block suballocation behind a pure placement interface

Owner decision 2026-09-29; resolves Q-1's allocator shape.

- **Placement** is a pure algorithm behind an interface that admits another
  strategy: best-fit over a free list, coalescing freed neighbours. It suits
  D-1's workload of tens to low hundreds of 1–16 MiB sheets, where the free
  list stays short. TLSF (VMA's default) may replace it if D-14's
  measurements call for it, typically under 3D's many small allocations.
- **Blocks** grow per memory type from 8 MiB, doubling to 64 MiB, both
  application configuration under D-11, so a small consumer never claims a
  large block.
- **Dedicated allocations** serve a resource of at least half the current
  maximum block size, or one the driver prefers or requires dedicated.
- **Rings**, not the block allocator, serve staging and per-frame data.

Rejected: a buddy allocator, whose power-of-two rounding wastes roughly a
third or more on mip-chained textures (about 1.33× a power of two); fixed
64 MiB blocks, which would charge a whole block to a single small buffer;
dedicated-only allocation, adequate for atlased 2D alone but not for 3D's
many small buffers or allocation during streaming and hot reload.

Superseded by D-38 on 2026-09-30. The pure best-fit placement #331 built is
kept only as the model package's test-only `placement-reference` sublibrary,
which no production component depends on.

### D-14. Prove parity with VMA by replaying identical traces

Owner decision 2026-09-29; resolves the measurement half of D-4. An optional
benchmark probe replays identical allocation and free traces through the
Haskell placement algorithm and through VMA's virtual blocks
(`vmaCreateVirtualBlock`, which places allocations without a device), and
compares speed and wasted space. VMA runs each trace entirely inside a
small C shim, so its timings carry no per-call FFI cost (scope narrowed to
placement, and a native comparison added, by D-32); the Hackage
`VulkanMemoryAllocator` binding also exposes virtual blocks but is not the
timing path. Traces are derived from Synarchy's asset set (sheet sizes and
streaming or hot-reload churn), with synthetic traces added for 3D-like
small allocations. VMA exists only in the probe: never an engine
dependency, and its pinned source is a recorded native input (V-11).

Superseded by D-38 and D-39 on 2026-09-30. The probe, its traces and its
three runs are retained as D-38's evidence; the placement comparison gates
nothing further.

### D-15. The byte budget counts device blocks

Owner decision 2026-09-29; resolves Q-2. The model's accounted bytes charge
each device-memory block and dedicated allocation, so the budget bounds
real device memory; growing blocks (D-13) keep small consumers from paying
for large ones. Exceeding the budget to open a block is `Backpressure`.
Blocks take no holds of their own: every suballocation is disposed only on
completion evidence, so a block may be freed once empty. Disposing of a
resource counts as reclamation progress for VK-14's retry, since the retry
may now fit. Rejected: charging each resource's own size, which hides
fragmentation and block slack; charging both, which gives two backpressure
sources for one concern.

Amended by D-38 on 2026-09-30: VMA opens and frees the blocks. The budget
still bounds device memory, and still answers `Backpressure` before memory is
allocated; D-40 decides how its charges follow VMA's blocks.

### D-16. Memory types follow what the data is

Owner decision 2026-09-29; resolves Q-1's memory types.

- **Textures are always staged** into device-local memory on every
  platform: optimal tiling cannot be written by the host, and Apple GPUs
  compress private textures, so the copy is required rather than wasted.
- **Per-frame data** (instances, camera values) lives in host-visible ring
  buffers that the GPU reads directly, with no copy.
- **Static geometry buffers** are staged into device-local memory. Writing
  them directly into device-local host-visible memory on unified-memory
  devices saves one copy and is deferred until measured.
- **Staging and readback** use host-visible memory.

### D-17. Keep one empty block per memory type

Owner decision 2026-09-29; resolves Q-1's retention. One empty block per
memory type is retained so free-then-allocate patterns do not thrash native
allocation, as VMA does. It still counts against the byte budget (D-15), and
a VK-14 reclamation pass may free it, which counts as progress. Amended by
D-29: budget backpressure trims cached empty blocks first.

Superseded by D-38 on 2026-09-30: VMA keeps at most one empty block per
memory type itself and frees any other block that empties. The engine keeps
no block cache of its own.

### D-18. Resources rest in a known layout; transitions within a batch are explicit and checked

Owner decision 2026-09-29; resolves Q-3.

- **Resting-state rule:** every long-lived resource has a resting layout —
  sampled textures ready for shader reads, depth images ready as
  attachments, offscreen color targets ready as attachments. Every batch
  returns what it touched to its resting layout before it ends, and an
  upload leaves its texture resting before the slot is published. No layout
  or access state is tracked across batches, so recording order and
  submission order cannot disagree about it.
- **Within a batch** the consumer records explicit transitions, and the
  recorder refuses illegal ones or a batch that ends with a resource away
  from rest. The legality rules are pure, beside the model, and tested in
  Hspec (P-2).
- **Later convenience:** per-pass declarations of reads and writes, with the
  recorder inserting barriers over the same checks, may be added once
  `render-2d` shows repeated patterns. They are not part of this arc.
- **Between batches:** see D-26, which adds resting scopes and mechanical
  boundary barriers.

Rejected: tracking layouts across batches, which is fragile when batches are
recorded out of submission order; automatic barriers now, which hide costs
before any consumer has shown the patterns worth automating.

### D-19. Shader interfaces are checked against compiled SPIR-V inside the Template Haskell splice

Owner decision 2026-09-29; resolves Q-7. Shaders stay hand-written GLSL,
compiled while the package builds through VK-9's splice
(`$(vertexShader [glsl|…|])`). The splice additionally takes a Haskell
description of the shader's interface — push-constant ranges and member
offsets, vertex and instance input locations and formats, and the texture
table's set and binding — declared in a separately compiled module, as
`${…}` interpolations already are under Template Haskell's stage
restriction. After compiling, the splice reads the SPIR-V's decorations with
a small Haskell reader and fails the build on any mismatch. No new native
tool is introduced. Rejected: generating GLSL declarations from Haskell,
which would constrain how shaders are written; checking only at pipeline
creation, which finds mismatches at runtime. Delivered by GRS-16 rather than
GRS-4 (D-34).

### D-20. Uploads are admitted into bounded staging and publish on completion

Owner decision 2026-09-29; resolves Q-5.

- **Admission:** a bounded queue; admission copies the caller's bytes into
  the staging ring (D-9), and a full ring or queue answers backpressure
  immediately, never waiting implicitly (V-5).
- **Per-frame budget:** D-11's byte budget caps the staged bytes recorded
  into upload batches in each owner turn.
- **Readiness:** a texture handle samples placeholder slot 0 until its
  upload's frame-less submission (D-12) has completed, and only then
  resolves to its own slot. Publishing at submission would be a frame or two
  sooner and is ordered safely on one queue, but readiness stays on the
  model's completion evidence.
- **Cancellation:** permitted until the upload's copy is recorded; after
  that the upload completes and the caller releases the handle normally.
- **Size:** see D-30 for oversized refusal and chunked progress.

### D-21. The upload endpoint accepts RGBA8 and BC7 with caller-supplied mip levels

Owner decision 2026-09-29; resolves Q-8. Formats are RGBA8 (sRGB and
linear) and BC7 (sRGB and linear); BC support is queried from the device and
reported, never assumed. Callers supply every mip level they want; the GPU
generates none. Container decoding such as KTX2 stays in the content arc
(D-3), which then only unpacks into this endpoint. ASTC is deferred.

### D-22. One engine-owned table layout that consumer pipelines attach

Owner decision 2026-09-29; resolves Q-6.

- The engine owns two fixed descriptor-set layouts (D-35). Set 0 is the
  table: a small fixed array of shared samplers (nearest and linear, each
  clamp-to-edge and repeat), then the variable-count, update-after-bind array
  of texture slots (D-1). Set 1 is the lookup: one dynamic storage buffer
  over the version ring (D-27).
- A consumer asks for the table when creating a pipeline layout, which then
  holds both sets; D-19's build-time check verifies each shader declares the
  table's bindings at the expected sets and bindings, and no other.
- A draw chooses its sampler by an index in its push constants; the shader
  combines the slot's image with that sampler.
- Growth to D-11's cap creates a larger set, copies the existing entries,
  and binds the new set in later frames; the old set retires on completion
  evidence like any other managed resource.

Amended by D-27 (lookup versions), D-31 (binding order, declared cap and
growth) and D-35 (the lookup buffer's own set). Reconciled with D-35 on
2026-10-03, as GRS-7 (#343) builds it: the bullets above describe the two
sets.

For `render-2d`, the [2D renderer design](render_2d_design.md)'s D-4
(2026-10-05) moves the sampler choice from the push constants into each
instance's flags word, so mixed filtering stays in one draw. The table and
its samplers are unchanged, but the recorder today refuses a table draw
before a pushed sampler selection; the 2D design's R2D-16 extends the
backend with table pipelines that choose samplers in the shader.

### D-23. Instances carry stable handles, resolved through a per-frame lookup

Owner decision 2026-09-29; clarifies D-1. Instance and baked data carry the
stable texture handle, never a slot. Shaders resolve a handle to its current
slot through a lookup table versioned per frame slot, so data baked into
buffers (a static tilemap, for example) stays valid across hot reload. The
slot swap (D-5, GRS-9) redirects the handle's lookup entry to a new slot in
later frames and retires the old slot on completion evidence, reusing slot
retirement rather than adding a mechanism. Rejected: resolving slots on the
CPU each frame, which forces baked buffers to be rewritten whenever a
texture moves. Versioning is by D-27's lookup versions rather than frame
slots.

### D-24. Depth attachments for offscreen and windowed rendering, in separate slices

Owner decision 2026-09-29; resolves Q-9. Offscreen passes gain depth with
the 3D fixture (GRS-10). Windowed depth follows each swapchain generation
through construction, resize, replacement and VK-14 surface recovery, as
backend work in its own slice (GRS-13) rather than waiting for `render-3d`.

### D-25. Accept fourteen dependency-ordered slices

Owner decision 2026-09-29; resolves Q-10, and the owner declared the design
ready for issue processing. The delivery plan's fourteen slices are the
accepted issue boundaries, in dependency order. GRS-4 follows GRS-12 and
GRS-5 so that its native proof is an offscreen readback (D-6); table growth
is split from GRS-7 into GRS-14 so the first textured draws need only a
fixed-size table. The device-profile feature change lands in GRS-7, where
D-7's Lavapipe outcome surfaces, and the shader-interface check in GRS-4.
Amended by D-28, which adds GRS-15 for window-free startup, making fifteen.
After a review's Q-11–Q-17 were resolved by D-26–D-32, the owner confirmed
readiness again on 2026-09-29. Amended by D-34, which moves the
shader-interface check out of GRS-4 into GRS-16, making sixteen, and by
D-37, which adds GRS-17 for `packages/math`, making seventeen. Amended by
D-38 and D-39, which supersede GRS-1 and add GRS-18 in its place on the
critical path, keeping seventeen live slices.

### D-26. Batches enter and leave a resource's resting scope through boundary barriers

Owner decision 2026-09-29; resolves Q-11 and amends D-18.

- A resting state is a layout plus a resting stage and access scope.
- The recorder emits an entry barrier, from the resting scope to the
  batch's use, at a batch's first touch of a resource, and an exit barrier,
  from that use back to the resting scope, at its last. On the one graphics
  queue a barrier's first scope covers every earlier-submitted command, so
  each entry barrier chains to earlier batches' exit barriers, ordering
  write-after-write, read-after-write and write-after-read between batches
  even when no layout changes. These boundary barriers are mechanical under
  the rule; transitions within a batch stay explicit and checked (D-18).
- A new image is uninitialized until the batch that initializes it (an
  upload, or an attachment pass that clears from undefined) has been
  submitted; the recorder refuses any other batch's use before then.
  Attachments cleared every pass may transition from undefined each time,
  and still take the entry barrier.

### D-27. Batches freeze their texture references in lookup versions

Owner decision 2026-09-29; resolves Q-12 and amends D-1, D-22 and D-23.

- A batch takes a lookup version when it first binds the texture table, and
  that version is fixed from then on. Versions come from a version ring
  independent of frame slots, so frame-less batches (D-12) take them the
  same way.
- The batch retains its version and the table set it bound through the
  model's existing holds — recorded reference, then submitted use until
  completion — and a version keeps every slot it maps.
- A slot is reusable, and its descriptor rewritable, only once no live
  version maps it. Release, replacement (D-5) and growth (D-22) publish new
  versions and never touch an old version's slots, so a descriptor write
  only ever targets a slot no recorded or pending batch can sample.
- This likely requires a sixth device feature,
  `descriptorBindingUpdateUnusedWhilePending`; GRS-7 verifies that against
  the specification and MoltenVK before relying on it.
- Acceptance case: record a batch, then replace or release a texture it
  samples, then submit the earlier batch — it samples the old image, and the
  old slot is not reused until that batch completes.

### D-28. The device can start without a window inside the existing owner

Owner decision 2026-09-29; resolves Q-13. The roots gain a surface-free
bootstrap: the device is selected by its graphics queue and the profile's
features, and any surface admitted later is checked against that queue
family as today (`TargetSurfaceUnsupported`). The existing GLFW-hosted
graphics owner makes progress and retires with zero targets, so offscreen
evidence opens no window; on Linux it still runs under the isolated X11
display. A headless owner independent of GLFW was rejected as a second
owner machinery. Delivered by GRS-15.

### D-29. Cached empty blocks are trimmed before budget backpressure

Owner decision 2026-09-29; resolves Q-14 and amends D-17. Before answering
backpressure for opening a block, the allocator frees every cached empty
block — at most one per memory type — and checks the budget once more. Empty
blocks take no holds (D-15), so trimming is immediate on the owner's thread.
VK-14's reclamation is never entered for budget exhaustion
(`native/src/.../Internal/Reclamation.hs:11`), so it cannot be relied on for
this.

Amended by D-38 on 2026-09-30: there is no engine-owned empty-block cache to
trim, and D-40 decides that backpressure does not release VMA's retained
empty block.

### D-30. Oversized uploads are refused; large uploads progress in chunks

Owner decision 2026-09-29; resolves Q-15 and amends D-20.

- Admission refuses permanently, with its own refusal rather than
  backpressure, an upload larger than the staging ring's capacity or the
  device's image limits. A full ring or queue remains backpressure.
- An admitted upload larger than one turn's budget is recorded in chunks
  across turns, split at mip-level and block-row boundaries.
- While uploading, the unpublished texture rests in the
  transfer-destination layout (D-26); the final chunk moves it to
  shader-read, and readiness follows that chunk's completion (D-20).
- D-11's validation requires the per-turn budget to fit one block row of the
  widest supported level.

### D-31. The table layout declares its cap; growth keeps it compatible

Owner decision 2026-09-29; resolves Q-16 and amends D-22.

- The layouts' bindings are fixed (D-35). Set 0 holds the shared samplers
  at binding 0, then the variable-count texture array at binding 1, the
  highest binding number, as Vulkan requires. Set 1 holds the lookup buffer
  at binding 0.
- Set 0's layout declares D-11's validated cap as the texture array's upper
  bound, checked at configuration against the device's update-after-bind
  limits.
- Each set allocates its current count. Growth allocates a larger set while
  the old one is still retained (D-27), so descriptor pools are sized for
  both, or a fresh pool serves each growth.
- The layouts never change, so every pipeline layout stays compatible, and
  D-19's check covers the lookup binding as well as the array.

Amended by D-35: the lookup buffer moves to its own set. Reconciled with D-35
on 2026-10-03, as GRS-7 (#343) builds it: the bullets above describe the two
sets.

### D-32. Parity with VMA is measured for placement and on the device

Owner decision 2026-09-29; resolves Q-17 and amends D-14. D-14's virtual-block
comparison establishes placement speed and fragmentation only, since VMA's
virtual blocks allocate no device memory. GRS-11 adds a native comparison:
the probe's C shim runs VMA's real allocator on the device over the same
traces as the owned allocator, and the retained results compare native
allocation counts, block-open latency, mapping and end-to-end allocate and
free throughput. Both comparisons stay in optional probes; VMA remains no
engine dependency.

Superseded by D-39 on 2026-09-30: with no owned allocator there is nothing to
compare with VMA's. The native measurement moves to GRS-18 as a validation of
VMA's integration.

### D-33. One shared ring serves per-batch data

Owner decision 2026-09-29, at GRS-4's filing; supersedes P-4. Each session
has one host-visible ring buffer from the allocator, sized by application
configuration under D-11. A batch — frame or frame-less alike — claims
regions of it while recording, and each region is reclaimed only when its
batch completes or is discarded. A full ring answers backpressure. Ring
regions can be bound as vertex, index or instance data, and host writes
into them are made visible at submission (D-26). Rejected: one ring per
frame slot and per frame-less slot, which fixes many small sizes per slot
and has no natural owner for frame-less work.

### D-34. Split the shader-interface check into its own slice

Owner decision 2026-09-29, at GRS-4's filing; amends D-25 and D-19's
placement. GRS-4 as planned bundled drawing from buffers, the first CPU
write path and D-19's build-time interface check, which is too large for
one reviewable pull request. GRS-4 keeps drawing and the shared ring
(D-33); the new GRS-16 delivers D-19's check, depends on GRS-4, and GRS-7
depends on it so the texture table's bindings are checked from the start
(D-31). The owner approved the amended boundaries explicitly, and readiness
stands.

### D-35. The lookup buffer is its own descriptor set

Owner decision 2026-09-29, at GRS-7's filing; amends D-22 and D-31's
binding list. A set created with Vulkan's update-after-bind pool flag may
not contain dynamic buffer descriptors
(`VUID-VkDescriptorSetLayoutCreateInfo-flags-03000`), so the lookup buffer
cannot share the texture table's set and still select a batch's version by
dynamic offset (D-27). Set 0 is the table: the shared samplers, then the
variable-count, update-after-bind texture array as its highest binding. Set 1
is the lookup: one dynamic storage buffer over the version ring, whose
offset, supplied at bind, selects the batch's version. Both layouts are
engine-owned and fixed, so pipeline layouts stay compatible, and D-19's
check covers both sets. Rejected: one set with a plain storage buffer and the
version offset in a reserved push-constant field, which takes push-constant
space from every consumer and complicates interface descriptions.

### D-36. Vulkan clip conventions and standard depth

Owner decision 2026-09-29, at GRS-10's filing. Coordinates follow Vulkan's
own conventions, not OpenGL's: clip space has Y pointing down and depth from
0 to 1, with no Y flip in the viewport. Depth attachments are depth-only —
`D32_SFLOAT` where supported, otherwise the device's other supported
depth-only format, queried and never assumed, with no stencil — cleared to
1.0 and compared less-or-equal. The backend takes the compare operation and
clear value per pass, so the later `render-3d` arc can adopt reversed-Z
without backend changes. Rejected for now: reversed-Z as the fixed default.

### D-37. Create `packages/math` in this arc, as its own slice

Owner decision 2026-09-29, at GRS-10's filing; amends D-25 and delivers
vision V-1's planned package earlier than its original render-3d placement.
`packages/math` is a new Cabal package depending on `base` alone and on no
local or graphics package. Its first API is minimal: 2-, 3- and 4-component
vectors of 32-bit `Float`, 4×4 matrices, translation, rotation about an
axis, scale, perspective and look-at, with strict fields. Conventions:
column vectors multiplied as `M × v`; right-handed world and view space with
the camera looking down −Z. Within `docs/module_conventions.md`'s accepted
boundary (owner clarification at filing):
- math defines matrices mathematically (element access by row and column,
  and a column-major element list as a mathematical view) and promises no
  byte layout; consumers pack matrices for the GPU themselves;
- projections take their depth range and clip-space Y direction as explicit,
  documented parameters, and consumers choose D-36's Vulkan values;
- degenerate operations (normalizing a zero vector, a look-at whose
  direction is zero or parallel to up, a perspective with invalid field of
  view, aspect or planes) return `Maybe` rather than producing NaN or
  infinity; ordinary arithmetic follows IEEE `Float`.

Quaternions, 3×3 matrices and anything else wait for a consumer. It is
delivered by GRS-17, which GRS-10 depends on. Rejected: building the
package inside GRS-10, which would put a new public API and a fixture in
one pull request; a private helper in the sample, which the owner declined
because the package's time had come.

### D-38. Use VMA for device-memory allocation

Owner decision 2026-09-30; reverses D-4, supersedes D-13, D-14 and D-17, and
amends D-15 and D-29. #331 measured the owned allocator D-4 made conditional
on parity. Neither its pure best-fit placement nor a mutable prototype making
the same decisions met the gates. The prototype was still 2.0–4.4× VMA's
median time per operation, and the fragmentation and refused-bytes gates
could not move with speed
([the parity record](../gpu_allocator_parity_record.md)). Performance is the
priority, so production allocation uses VMA.

**VMA owns** how memory is laid out:

- opening, sizing and freeing device-memory blocks, and suballocating them,
  including alignment and `bufferImageGranularity`;
- dedicated allocations: the driver's preferred or required dedication, and
  VMA's size heuristic;
- empty-block retention: at most one empty block per memory type, as VMA does;
- persistent mapping, and atom-aligned flush and invalidate of host-visible
  allocations.

**The engine keeps** everything about when memory may be used and freed, and
who sees it:

- **Resource lifetime.** Every buffer and image, and the VMA allocation behind
  it, belongs to a managed resource that is a model subject. The model's
  holds decide disposal. VMA never decides that memory is free: an allocation
  is freed only when the resource's disposal destroys it, view first, then
  the resource, then its allocation.
- **GPU-completion tracking.** VMA tracks no GPU use. An allocation is freed
  only after the model's completion evidence ends every submitted use, so no
  allocation still named by a pending submission ever reaches VMA's free.
  Device loss follows the backend's existing terminal policy.
- **Threading.** One VMA allocator per device, created, used and destroyed
  only on the graphics owner thread, with
  `VMA_ALLOCATOR_CREATE_EXTERNALLY_SYNCHRONIZED_BIT`. No other thread calls
  VMA, and the design relies on none of VMA's internal locking.
- **Accounting and backpressure.** The model's validated byte and object
  budgets (D-11, D-15) and typed `Backpressure`, checked on the owner's
  thread before memory is allocated, by D-40's mechanism.
- **Recovery.** VK-14's single reclamation pass and single retry for a
  no-effect out-of-memory failure from VMA. An uncertain effect is terminal,
  as today.
- **Memory-type selection.** The engine chooses the one memory type every
  allocation uses:
  - It applies D-16's usage, stated as required and preferred property flags,
    to the resource's `memoryTypeBits`. It may ask VMA's memory-type query to
    rank the candidates, but the engine makes the choice.
  - It pins the choice by passing only that type's bit in the allocation's
    `memoryTypeBits`, so VMA can neither choose nor fall back to another type.
    D-40's reservation depends on this.
  - A usage no memory type can serve is a structured refusal, never a silent
    fallback.
- **Retirement.** Every allocation freed before the allocator is destroyed,
  and the allocator destroyed before the device (the roots'
  child-before-parent order).
- **Naming and diagnostics.** Engine objects are named from model identities
  as today; VMA allocations are named through VMA.
- **The engine-facing abstraction.** Consumers keep the native backend's
  managed resources keyed by model identities. No VMA type crosses the native
  backend's public API: VMA is confined to its internal modules, and the model
  package never depends on it.

VMA becomes a production native input under V-11. Its pinned version, build
flags and binding are recorded in `docs/toolchain.md` when GRS-11 integrates
it. The binding is Q-19. Rejected: continuing to optimise the owned
allocator, which could at best have closed the speed gate on the sheet
workload alone; relaxing the gates after the fact.

### D-39. Qualify the VMA integration by bounded measurement before building on it

Owner decision 2026-09-30; supersedes D-32. The virtual-block probe proves
nothing about the production path: it allocates no device memory and calls
VMA from C. Before GRS-11 builds on VMA, GRS-18 measures the path the engine
will use and retains the results:

- **Haskell↔C cost.** Each call the engine will make — create a buffer or
  image with its allocation, free it, map it, flush it — made through the
  chosen binding from Haskell, against the same calls driven from C, on a real
  device. It reports per-call medians and 95th percentiles, and the overhead
  of the crossing itself.
- **Representative workloads.** The probe's Synarchy sheet and small-buffer
  traces replayed as real buffers and images under D-16's usages. It records
  native allocation counts, per-operation latency and device bytes held.
- **The completion-deferred free.** Frees delayed until a fence signals, as
  the model will defer them, with no cost cliff and no allocation freed early.
- **Ownership.** An externally synchronised allocator used from the owner
  thread alone.

Its acceptance thresholds are set when GRS-18 is filed. It stays an optional,
local probe and gates no CI.

### D-40. The byte budget charges VMA's blocks, reserved before one can open

Owner decision 2026-09-30; resolves Q-18 with its option (a), made precise by
review, and amends D-15 and D-29 for VMA. Keeping D-15's meaning, the model's
accounted bytes charge the device memory VMA holds — each block and each
dedicated allocation — not each resource's own size. VMA reports a block only
after it has opened one, so the budget is enforced by a reservation bounded
before the call and reconciled after it:

1. **One memory type.** The engine chooses the memory type itself from D-16's
   usage flags and the resource's `memoryTypeBits`, and passes only that type
   to VMA. VMA cannot fall back to another type.
2. **Held memory first.** The request is made with
   `VMA_ALLOCATION_CREATE_NEVER_ALLOCATE_BIT`. That succeeds only inside
   memory VMA already holds, and charges nothing new.
3. **Reserve the most VMA could open.** Otherwise the engine reserves an upper
   bound on what the allocating call could open: the larger of that memory
   type's preferred block size and the request's own size. The engine sets
   the preferred block size in the allocator's configuration and computes it
   exactly as VMA does. Under the preconditions below, VMA opens no block
   larger than that, and a dedicated allocation of exactly the request's
   size, and never both in one call. A reservation the budget cannot hold is
   typed `Backpressure`, answered on the owner's thread before any native
   call.
4. **Allocate and reconcile.** VMA's device-memory callbacks run inside the
   allocating call on the owner's thread and record exactly what it opened.
   Afterwards the reservation is replaced by that amount — nothing if it
   opened nothing — and the rest is returned at once.
   - More than was reserved means one of the preconditions below was broken.
     It is never silently carried over budget: the allocation is freed, and
     the request fails as an accounting defect.
5. **Freeing.** The callbacks uncharge a block when VMA frees it. VMA's own
   retained empty block therefore stays charged, like any other block, until
   VMA frees it.

**The bound's preconditions.** Step 3's bound is a property of how the engine
calls VMA, not of VMA in general (#367). It holds only while:

- **the allocating call never asks VMA to map** — no
  `VMA_ALLOCATION_CREATE_MAPPED_BIT`, nor any other mapping inside the call. A
  host-visible allocation is mapped by a separate call after the allocating
  call has been reconciled; and
- **VMA's debug margin is zero** — `VMA_DEBUG_MARGIN` in the VMA
  implementation the engine links, the one the pinned `VulkanMemoryAllocator`
  package compiles. That compilation defines no margin and so keeps the
  header's default of zero; the shim's own include of the header, for
  declarations only, does not decide it.

The reason is one sequence in the pinned VMA 3.3.0.
`VmaBlockVector::AllocatePage` opens a new block, then commits the request
into it. If that commit fails it returns failure without destroying the new
block, and a fresh block at least the request's size fails the commit only
when the request asked for mapping and the mapping failed
(`CommitAllocationRequest`), or under a nonzero debug margin.
`VmaAllocator_T::AllocateMemoryOfType` then falls back to a dedicated
allocation of the request's own size, which can succeed. One call has then
opened a block and a dedicated allocation — more than step 3 reserved — and
the empty block stays retained. Under the preconditions the sequence cannot
occur. In-call mapping under some other, sound bound is not supported; a slice
that needs it amends this decision first.

The bound is conservative. Near the budget, a request may be refused that a
smaller block VMA would have chosen could have served; below it, the charge
is exact. Budget backpressure does not release VMA's retained empty block:
VMA frees extra empty blocks itself, and D-29's trimming has no engine-owned
cache to act on. Whether the callbacks cross into Haskell, needing safe
foreign calls, or count in C is for GRS-18's measurements and GRS-11.
Rejected: charging each allocation's size (Q-18 (b)), which hides block slack
as D-15 said; capping heaps with `pHeapSizeLimit` (Q-18 (c)), which loses the
typed answer; and checking only after `NEVER_ALLOCATE` fails without a
reservation, which cannot bound what VMA then opens.

## Open questions

### Q-1. Allocator shape, memory types and retention

Resolved by D-13, D-14, D-16 and D-17. Shape and retention are resolved again
by D-38; D-16's memory types stand.

### Q-2. How allocation meets the model's accounting and recovery

Resolved by D-15. Its mechanism under VMA is Q-18, resolved by D-40.

### Q-3. Who owns access and layout state

Resolved by D-18.

### Q-4. What owns an offscreen batch

Resolved by D-12.

### Q-5. Upload admission and completion

Resolved by D-20. The queue bound and staging-ring size are D-11
configuration, set when GRS-6 is drafted.

### Q-6. Pipeline layouts and the texture table

Resolved by D-22 and D-23.

### Q-7. Shader-interface checking

Resolved by D-19.

### Q-8. Texture formats in this arc

Resolved by D-21.

### Q-9. Depth attachment ownership

Resolved by D-24.

### Q-10. Slice boundaries

Resolved by D-25.

### Q-11. Synchronization between batches

Raised by review on 2026-09-29; resolved by D-26.

### Q-12. Protecting recorded texture references

Raised by review on 2026-09-29; resolved by D-27.

### Q-13. Window-free device startup

Raised by review on 2026-09-29; resolved by D-28.

### Q-14. Trimming cached empty blocks under a tight budget

Raised by review on 2026-09-29; resolved by D-29.

### Q-15. Uploads larger than one turn's budget

Raised by review on 2026-09-29; resolved by D-30.

### Q-16. Descriptor growth and layout compatibility

Raised by review on 2026-09-29; resolved by D-31.

### Q-17. Scope of the VMA parity claim

Raised by review on 2026-09-29; resolved by D-32, which D-39 supersedes.

### Q-18. How the byte budget charges memory VMA holds

Raised by D-38 on 2026-09-30; resolved the same day by D-40, which chose (a).
D-15 charges device blocks, but VMA opens them. The candidates were:

- **(a) Charge blocks, checked before they open.** First place with
  `VMA_ALLOCATION_CREATE_NEVER_ALLOCATE_BIT`, which only succeeds inside an
  existing block. When that fails, check the budget for the block or
  dedicated allocation VMA would open, then allocate. VMA's device-memory
  callbacks charge and uncharge each block as it opens and frees. This keeps
  D-15's meaning, at the cost of two calls for a request that opens a block.
- **(b) Charge each allocation's own size.** Simple, but it hides block slack.
  D-15 rejected it.
- **(c) Cap each heap with VMA's `pHeapSizeLimit`.** This loses the typed
  `Backpressure` answer, because a refusal becomes out-of-memory.

D-29's trimming question folds in here: whether backpressure should first
release VMA's retained empty block.

### Q-19. Which binding calls VMA in production

Raised by D-38 on 2026-09-30; GRS-18 (#361) measured both candidates. Its
runs recommend the engine-owned shim, imported with unsafe calls, with D-40's
callbacks counting in C: the only configuration that met every accepted
limit, in both binding variants' runs. The Hackage binding missed in both its
variants, and safe calls missed through either
([the VMA qualification record](../gpu_vma_qualification_record.md)).
Resolved by #333 (GRS-11), whose requirement 1 adopts that recommendation: the
production binding is the engine's own shim, recorded in
[the toolchain record](../toolchain.md#vma). The candidates were:

- the Hackage `VulkanMemoryAllocator` binding, which bundles VMA 3.3.0, makes
  unsafe foreign calls unless its `safe-foreign-calls` flag is set, and needs
  Vulkan function pointers from the `vulkan` binding's dispatch;
- a small engine-owned C shim over the same pinned VMA source.

## Verification strategy

- Pure placement, legality and reuse decisions tested in Hspec without a GPU
  (P-2), in the owning package's suites.
- Native layers tested over the recording stand-in for retention, refusal
  and disposal, as `native-tests` does today.
- Native evidence in `test.vulkan-native` with synchronization validation:
  offscreen readbacks checked against expected pixels by the tests, and
  retained for the agent's report (D-6), within the 30-second required
  native budget (V-10).
- The owned allocator's comparison with VMA is retained as D-38's evidence
  ([the parity record](../gpu_allocator_parity_record.md)). GRS-18 retains
  the VMA integration's validation (D-39).
- Linux CI runs the native group on its pinned software stack; a missing
  feature is reported, never hidden (D-7).

## Delivery plan

Accepted by D-25, as amended by D-28, in dependency order; each slice is one issue and one
pull request.

### GRS-1. Place allocations with a pure block allocator proven against VMA

> **Superseded 2026-09-30 by D-38.** Delivered as evidence, not as an
> allocator: the pure placement became the test-only `placement-reference`
> sublibrary, and the probe and its runs are retained in
> [the parity record](../gpu_allocator_parity_record.md). Neither Haskell
> allocator met the gates. GRS-18 replaces this slice on the critical path.

> Filed as #331. Owner clarifications at filing, 2026-09-29: the pure
> placement algorithm lives in `hetoimasia-gpu-vulkan-model`; parity means
> refused bytes and fragmentation each within 2 percentage points of VMA's,
> no more than 2× VMA's median time per operation, and a median placement
> under 5 µs; VMA's source comes from the Hackage `VulkanMemoryAllocator`
> package rather than a new native input.

- **Outcome:** a pure placement algorithm (D-13) decides block, offset,
  growth and dedicated placement, and an optional probe shows it matches
  VMA's virtual blocks on identical traces (D-14).
- **Scope:** the pure allocator and its Hspec properties; trace generation
  from Synarchy-derived and synthetic workloads; the optional VMA shim probe
  with its pinned source and retained results.
- **Phase:** memory.
- **Depends on:** none.
- **Ordering:** critical path; can land first.
- **Relevant decisions:** D-4, D-13, D-14, D-32.
- **Acceptance signals:** property tests for alignment, granularity,
  non-overlap and coalescing; retained placement speed and waste
  comparison with VMA's virtual blocks.
- **Out of scope:** device memory, model accounting.
- **Open questions:** none.

### GRS-18. Qualify the production VMA integration by bounded measurement

> Filed as #361. The owner confirmed its acceptance limits there as final:
> for each measured call, Haskell median minus C median — the total
> binding-path overhead, marshalling and wrappers included — no greater than
> the larger of 25% of the C median or 50 ns; on every gated trace, Haskell
> elapsed time no more than 1.25 × C elapsed time for identical completed
> work; and no completion-deferred free before its batch's fence signals,
> with clean synchronization validation, its cost against immediate frees
> reported with no numeric limit. A miss is retained and reported, never
> waived, and leaves GRS-11's prerequisite unsatisfied. The runs are in
> [the VMA qualification record](../gpu_vma_qualification_record.md).

- **Outcome:** retained measurements (D-39) show the chosen binding's
  Haskell↔C cost, VMA's behaviour on representative workloads on a real
  device, and the completion-deferred free path, each within accepted bounds.
  The measurements answer Q-19.
- **Scope:** an optional local probe in the native package, driving VMA
  through the candidate binding and through C on a windowless device, over
  the retained traces; the retained record; the binding choice.
- **Phase:** memory.
- **Depends on:** none.
- **Ordering:** critical path; replaces GRS-1.
- **Relevant decisions:** D-16, D-38, D-39.
- **Acceptance signals:** the probe's retained report on macOS stating every
  threshold met or missed; a binding recommendation.
- **Out of scope:** engine integration, model accounting (GRS-11).
- **Open questions:** none; the acceptance limits were confirmed in #361.

### GRS-11. Back allocations with device-memory blocks beneath the model's accounting

> **Rescoped 2026-09-30 by D-38: back allocations with VMA beneath the
> model's accounting.**
> - VMA replaces the owned blocks, placement, mapping and empty-block cache.
> - The slice keeps usages and memory-type policy, accounting and
>   backpressure (D-40), recovery, naming, retirement order and the readback
>   buffer's move onto the allocator.
> - It depends on GRS-18 instead of GRS-1, and its native comparison with VMA
>   is dropped (D-39).
>
> #333 was amended to match on 2026-09-30.

> Filed as #333. Owner clarifications at filing, 2026-09-29: the existing
> readback buffer moves onto the allocator as its first consumer; the native
> comparison with VMA gates native allocation count (no more than VMA's) and
> end-to-end time (within 2×), recording latency and mapping cost ungated;
> host-visible blocks are mapped once for their lifetime. #333 also carries
> D-10's `vulkan_backend_design.md` pointer unless #331 lands it first.

- **Outcome:** device memory comes from VMA, allocated and freed only on the
  owner thread. It is charged to the model's accounted bytes by D-40's mechanism, freed
  only once completion evidence allows disposal, and recovered through VK-14.
- **Scope:** VMA's allocator in the native backend (D-38), D-16's usages as
  VMA memory-type flags, D-15's charging, and the readback buffer moving onto
  it.
- **Phase:** memory.
- **Depends on:** GRS-18 (was GRS-1; D-38).
- **Ordering:** critical path.
- **Relevant decisions:** D-11, D-15, D-16, D-29, D-38, D-39, D-40 (D-13, D-17 and
  D-32 superseded).
- **Acceptance signals:** backpressure and reclamation examples over the
  stand-in; native allocation and release through VMA with clean validation
  on both local platforms; no VMA type in the native backend's public API.
- **Out of scope:** defragmentation, memory-budget extension.
- **Open questions:** none; Q-18 is resolved by D-40.

### GRS-2. Create managed buffers and images as retained model subjects

> Filed as #334. Owner clarifications at filing, 2026-09-29: creation names
> engine-defined kinds (texture, depth target, colour target; vertex, index,
> instance or ring, lookup and staging buffers) that fix usage flags and
> memory usage, never raw flags; GRS-2 has no CPU write path (rings arrive in
> GRS-4, uploads in GRS-6); each image owns one full-resource view.

- **Outcome:** buffers and images (sampled, depth, color target) are managed
  handles with the model's five holds, named and disposed like pipelines.
- **Scope:** creation, release, naming, disposal.
- **Phase:** resources.
- **Depends on:** GRS-11.
- **Ordering:** critical path.
- **Relevant decisions:** D-8.
- **Acceptance signals:** stand-in retention and disposal examples; native
  creation and destruction with clean validation.
- **Out of scope:** recording through them.
- **Open questions:** none.

### GRS-3. Order access and layout for managed resources through checked operations

> Filed as #335. Owner clarifications at filing, 2026-09-29: the pure
> legality and initialization rules live in `hetoimasia-gpu-vulkan-model`,
> in engine terms; buffers rest as follows — vertex and index at vertex-input
> read, instance or ring at vertex-input and shader read (host writes visible
> at submission), lookup at vertex and fragment storage read, staging at
> transfer read — beside D-18's image resting states.

- **Outcome:** the recorder orders and transitions managed resources and
  refuses unordered access.
- **Scope:** VKR-5.
- **Phase:** access.
- **Depends on:** GRS-2.
- **Ordering:** critical path.
- **Relevant decisions:** D-18, D-26.
- **Acceptance signals:** pure legality tests, including refusal of a batch
  that ends with a resource away from rest and of use before initialization
  is submitted; two batches writing the same resource without a layout
  change are ordered by boundary barriers; synchronization validation clean
  on native transitions.
- **Out of scope:** render graph, queue-family transfer, per-pass
  declarations.
- **Open questions:** none.

### GRS-15. Start the device and owner progress without a window

> Filed as #336. Owner clarifications at filing, 2026-09-29: the
> surface-free device is an opt-in host setting, leaving windowed
> applications' surface-guided selection unchanged; GRS-15 also adds a
> bounded owner-thread action entry, lent the session's `Construction`, that
> GRS-12 extends with frame-less batch recording.

- **Outcome:** a graphics session selects and creates its device without a
  surface, makes progress and retires with zero targets, and still admits
  later surfaces checked against its queue family.
- **Scope:** D-28's surface-free bootstrap in the roots and the GLFW-hosted
  owner's zero-target progress and protected teardown.
- **Phase:** submission.
- **Depends on:** none.
- **Ordering:** critical path; can land first.
- **Relevant decisions:** D-6, D-28.
- **Acceptance signals:** stand-in examples for surface-free selection,
  zero-target progress and teardown, and a later surface refused when its
  queue family cannot present; a native session creates the device and
  retires with no window opened; clean validation.
- **Out of scope:** a headless owner independent of GLFW; additional queues.
- **Open questions:** none.

### GRS-12. Admit, submit and complete frame-less batches

> Filed as #337. Owner clarifications at filing, 2026-09-29: a dedicated,
> validated budget of frame-less batches in flight (default 4), each slot with
> its own command storage reused only after completion or discard; sealed
> batches are submitted when the owner-thread action returns, in seal order,
> before any later frame; completion reaches callers through tickets that are
> read without blocking or waited on with a deadline, and report lost after
> device loss.

- **Outcome:** the model admits batches that belong to no frame, against its
  budgets, and the backend submits them with their own completion record
  and polls that completion on the owner's schedule.
- **Scope:** D-12's model extension and native submission path.
- **Phase:** submission.
- **Depends on:** GRS-3, GRS-15.
- **Ordering:** critical path.
- **Relevant decisions:** D-12, D-18, D-26, D-28.
- **Acceptance signals:** pure admission, backpressure, discard and
  completion examples in the model suite; native frame-less submission with
  clean validation; device loss fabricates no completion.
- **Out of scope:** additional queues.
- **Open questions:** none.

### GRS-5. Render into a managed offscreen color target and read it back

> Filed as #338. Owner clarifications at filing, 2026-09-29: frame and
> frame-less batches alike may render into a managed colour target; colour
> targets are RGBA8 in sRGB and linear; the slice proves itself by exact 8-bit
> probe pixels away from edges, writing its readback as an uncommitted PNG
> for inspection, with committed captures starting at GRS-8 and GRS-10.

- **Outcome:** a batch renders into an offscreen target and its bytes are
  read back on completion evidence.
- **Scope:** D-6.
- **Phase:** evidence.
- **Depends on:** GRS-12.
- **Ordering:** critical path.
- **Relevant decisions:** D-6, D-12, D-18, D-26, D-28.
- **Acceptance signals:** readback matches expected pixels natively, in a
  session that opens no window.
- **Out of scope:** depth.
- **Open questions:** none.

### GRS-4. Record from vertex, index and instance buffers with push constants

> Filed as #340. At filing the owner split the shader-interface check into
> GRS-16 (D-34) and chose one shared ring with per-batch regions (D-33).

- **Outcome:** indexed and instanced draws from managed buffers and ring
  regions, with push constants declared by pipeline layouts, and the shared
  per-batch ring.
- **Scope:** D-33.
- **Phase:** recording.
- **Depends on:** GRS-3, GRS-5.
- **Ordering:** critical path.
- **Relevant decisions:** D-2, D-16, D-26, D-33, D-34.
- **Acceptance signals:** transitive retention examples; ring regions
  reclaimed only on completion or discard, and backpressure when full; native
  draw proven by offscreen readback.
- **Out of scope:** descriptors; the shader-interface check (GRS-16).
- **Open questions:** none.

### GRS-16. Check shader interfaces against compiled SPIR-V in the Template Haskell splice

> Filed as #341. Owner clarifications at filing, 2026-09-29: checked
> shaders carry their interface description and pipelines take push-constant
> ranges and vertex input from it, refusing stages that disagree; unchecked
> splices remain only for shaders that declare no interface, and fail the
> build otherwise.

- **Outcome:** VK-9's Template Haskell splice checks each shader's compiled
  SPIR-V against a Haskell interface description and fails the build on a
  mismatch.
- **Scope:** D-19: push-constant ranges and member offsets, vertex and
  instance input locations and formats, and the texture table's set and
  binding declarations.
- **Phase:** recording.
- **Depends on:** GRS-4.
- **Ordering:** critical path (GRS-7 depends on it).
- **Relevant decisions:** D-19, D-31, D-34.
- **Acceptance signals:** deliberately mismatched push-constant, vertex and
  binding declarations each fail the build with a message naming the
  mismatch; matching shaders build unchanged; no new native tool.
- **Out of scope:** generating GLSL from Haskell; runtime checks.
- **Open questions:** none.

### GRS-6. Upload bytes through bounded engine-owned staging with completion

> Filed as #342. Owner clarifications at filing, 2026-09-29: uploads are
> admitted from any thread (a caller-thread copy into engine memory, then the
> owner copies into staging); uploads target only fresh, uninitialized
> resources, so replacing a texture is the GRS-9 swap; the texture kind gains
> transfer-source usage so uploads are verified by exact readback.

- **Outcome:** bytes reach buffers and images through bounded staging with
  completion reported and cancellation handled.
- **Scope:** VKR-4's backend endpoint, D-9, D-11.
- **Phase:** transfer.
- **Depends on:** GRS-12.
- **Ordering:** critical path.
- **Relevant decisions:** D-9, D-11, D-16, D-20, D-21, D-26, D-30.
- **Acceptance signals:** backpressure, cancellation and completion
  examples; native RGBA8 and BC7 uploads with mip levels verified by
  readback; unsupported BC reported, not assumed; an upload larger than one
  turn's budget completes in chunks; an oversized upload is refused
  permanently, distinct from backpressure.
- **Out of scope:** decoding, loader concurrency, GPU mip generation.
- **Open questions:** none.

### GRS-7. Own the bindless texture table and its completion-safe slot reuse

> Filed as #343. Owner clarifications at filing, 2026-09-29: four immutable
> samplers (nearest and linear, each clamp-to-edge and repeat; no
> anisotropy); lookup versions are whole-table copies in a version ring of
> configured length (default 8), written only on change; slot 0 is a
> transparent-black placeholder; the lookup buffer is its own set (D-35).

- **Outcome:** the device profile requires D-1's features; textures get
  slot-plus-generation handles, placeholder slot 0, and slot reuse only on
  completion evidence.
- **Scope:** D-1, D-11.
- **Phase:** binding.
- **Depends on:** GRS-6, GRS-16.
- **Ordering:** critical path.
- **Relevant decisions:** D-1, D-7, D-11, D-20, D-22, D-23, D-27, D-31.
- **Acceptance signals:** pure reuse and lookup-version tests; the D-27
  case (record, replace or release, then submit the earlier batch) samples
  the old image and delays slot reuse to its completion; native sampling
  through handles from a fixed-size table; placeholder until upload
  completion; `descriptorBindingUpdateUnusedWhilePending` verified or its
  absence resolved; the Lavapipe outcome reported (D-7).
- **Out of scope:** hot-reload swap, table growth.
- **Open questions:** none.

### GRS-14. Grow the texture table to its configured cap

> Filed as #344. Owner clarifications at filing, 2026-09-29: the table grows
> as soon as registration finds no free slot, even while released slots await
> retirement, doubling to the cap; the lookup version ring is sized for the
> cap from the start, so only set 0 grows; each grown set has its own
> descriptor pool, destroyed with it on completion.
>
> As delivered (#344): a registration that finds no free slot grows set 0 at
> once, doubling to the cap (a cap that is no power of two is reached
> exactly). Each growth makes a pool of its own and a set over the unchanged
> layout, copies every written slot with `vkCopyDescriptorSet`, and makes the
> new set current while releasing the old pool. A batch pins its set and
> version at its first bind and retains that set's pool, so an older set and
> its pool are destroyed together only once no batch holds them. A failed
> growth rolls back, with one reclamation pass and at most one retry of the
> whole growth. #343's lookup entries are eight bytes (slot and generation),
> so the cap-sized ring holds the cap × 8 bytes per version.

- **Outcome:** the table doubles up to D-11's application-configured cap by
  building a larger set, copying existing entries and binding it in later
  frames, with the old set retired on completion evidence.
- **Scope:** D-22's growth rule.
- **Phase:** binding.
- **Depends on:** GRS-7.
- **Ordering:** not on the critical path of the 2D fixture.
- **Relevant decisions:** D-11, D-22, D-27, D-31.
- **Acceptance signals:** growth under load with handles unchanged and
  pipeline layouts still compatible; batches recorded before growth keep
  their set and version; the old set disposed only after completion; a cap
  beyond the device's limits rejected at configuration; growth past the cap refused as
  backpressure; clean validation.
- **Out of scope:** shrinking the table.
- **Open questions:** none.

### GRS-8. Draw textured quads from table slots in a 2D scaffolding fixture

> Filed as #345. Owner clarifications at filing, 2026-09-29: the fixture is a
> `samples/sprites/` package mirroring the triangle, with a windowless
> evidence mode the native suite runs and a windowed mode for the owner;
> evidence is a Markdown record plus one PNG per platform under
> `docs/evidence/gpu_2d/`, the Linux capture uploaded by CI; checks are exact
> at nearest-sampled texel centres and ±1 per channel where filtering or
> blending contributes. The slice also adds premultiplied-alpha pipeline
> blending, its first user.
>
> Owner decision at #345's revision: **per-draw sampler selection is
> retained** under D-1 and D-22, and #343's contract is unchanged. The scene
> uses separate draws for nearest and linear sampling, keeps painter order
> across draws, and keeps one draw of at least 1,000 instances using one
> sampler; instances carry no sampler index. As delivered (#345): a
> 1,032-instance nearest-clamp draw over both RGBA8 fixtures, a separate
> linear-clamp draw whose first instance overlaps the previous draw's last, and
> a nearest-clamp BC7 draw where the device takes BC7. The linear probe samples
> `u = 0.46875 + 1/8192`, whose filter weight every conformant sub-texel
> precision quantizes to within 1/1024 of 0.25, so its ±1 tolerance holds on
> any device. The evidence lives in `docs/evidence/gpu_2d/`.

- **Outcome:** a fixture draws instanced textured quads from several slots
  and proves them by offscreen readback.
- **Scope:** D-2, D-3, D-6.
- **Phase:** 2D proof.
- **Depends on:** GRS-4, GRS-5, GRS-7.
- **Ordering:** critical path.
- **Relevant decisions:** D-2, D-3, D-6.
- **Acceptance signals:** captured quads with correct textures, UV
  rectangles and premultiplied blending.
- **Out of scope:** `render-2d`.
- **Open questions:** none.

### GRS-9. Swap a texture slot's image under the same handle

> Filed as #346. Owner clarifications at filing, 2026-09-29: a swap names the
> replacement's upload and takes effect in the first version after it
> completes, never showing the placeholder, while a failed upload leaves the
> old image; the replacement may change format and size; the handle owns its
> current texture, so the old one is released automatically and retires on
> completion; a second pending swap supersedes the first.
>
> As delivered (#346): `swapTexture` names the replacement image an admitted
> or completed upload fills, and answers a ticket reporting where the swap
> stands. The swap reserves a slot and changes no mapping until the upload
> completes; the first version after that resolves the handle to the
> replacement. The old texture is released when the swap takes effect and
> destroyed once no batch retains it, its slot reused once no live version
> maps it. A superseded or abandoned replacement is released at once; a
> cancelled or lost one, or a failed session, ends the swap as failed with
> the handle unchanged. The sprites sample's swap case is the evidence.

- **Outcome:** a handle's image is replaced; later frames sample the new one
  and the old retires after the submissions that sampled it complete.
- **Scope:** D-5.
- **Phase:** binding.
- **Depends on:** GRS-8.
- **Ordering:** not on the critical path.
- **Relevant decisions:** D-5, D-23, D-27.
- **Acceptance signals:** readback before and after the swap; baked instance
  data unchanged across it; retirement on completion evidence.
- **Out of scope:** file watching.
- **Open questions:** none.

### GRS-17. Establish `packages/math` with the vectors, matrices and projections the 3D fixture needs

> Filed as #348 under D-36 and D-37, within `docs/module_conventions.md`'s
> accepted boundary: no byte-layout promise, explicit clip-convention
> parameters, and `Maybe` for degenerate operations. The PR also updates
> AGENTS.md's and vision V-1's "planned" wording.

- **Outcome:** a new `packages/math` package supplies the vectors,
  matrices and projections the 3D fixture needs, under D-37's conventions.
- **Scope:** D-37's minimal API.
- **Phase:** 3D proof.
- **Depends on:** none.
- **Ordering:** can land first; critical path for GRS-10.
- **Relevant decisions:** D-36, D-37.
- **Acceptance signals:** Hspec properties for the transforms and
  projections, a column-major byte-layout example, and a dependency check
  showing no local or graphics package.
- **Out of scope:** quaternions, 3×3 matrices, SIMD, and geometry types.
- **Open questions:** none.

### GRS-10. Add depth attachments and a depth-tested 3D scaffolding fixture

> Filed as #349: depth per D-36, and a `samples/scene3d/` evidence mode with
> committed captures under `docs/evidence/gpu_3d/`, its camera built from
> `hetoimasia-math` (#348); the windowed mode follows with GRS-13.

- **Outcome:** offscreen passes render with depth; a fixture proves
  occlusion by readback.
- **Scope:** D-2's 3D continuation.
- **Phase:** 3D proof.
- **Depends on:** GRS-4, GRS-5, GRS-17.
- **Ordering:** critical path for the 3D arc.
- **Relevant decisions:** D-2, D-6, D-24, D-26, D-36, D-37.
- **Acceptance signals:** captured occlusion from two camera poses, from a
  `samples/scene3d/` evidence mode, recorded under `docs/evidence/gpu_3d/`.
- **Out of scope:** `render-3d`, camera contract, windowed depth and the
  sample's windowed mode (GRS-13).
- **Open questions:** none.

### GRS-13. Give each target generation a managed depth attachment

> Filed as #350. Owner clarifications at filing, 2026-09-29: one depth image
> per swapchain generation, shared by its frames in flight; windowed depth is
> an opt-in host setting; `samples/scene3d/`'s windowed mode orbits the
> camera around the evidence scene.

- **Outcome:** windowed frames can render with depth images that follow
  their swapchain generation through construction, resize, replacement and
  surface recovery; `samples/scene3d/` gains its windowed mode.
- **Scope:** D-24's windowed half.
- **Phase:** 3D proof.
- **Depends on:** GRS-10.
- **Ordering:** not on the critical path of the evidence; required before
  `render-3d` renders to windows.
- **Relevant decisions:** D-18, D-24, D-26.
- **Acceptance signals:** depth-tested windowed draw; depth images replaced
  with their generation on resize and recovery, disposed on completion;
  clean validation.
- **Out of scope:** multisampling, stencil.
- **Open questions:** none.

## Source notes

Content-side texture decisions of 2026-09-29, preserved for the
content-loading arc (D-3): any texture and sheet layout, with sheets as a
texture plus an optional region table; a build script that stitches changed
sheets; runtime custom textures on the same path; PNG plus KTX2/BC7 as the
baseline; hot reload required; uploads through a bounded queue with decode
on background workers, a per-frame byte budget and a per-handle state
snapshot.
