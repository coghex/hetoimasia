# Renderer foundation findings, 2026-09-22

Preserve the two unique renderer-consumer goals from the original foundation
plan after its Vulkan and Lua work moved into focused arcs. This is a report
for individual refinement and disposition, not an approved renderer API or
a new umbrella epic.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]` reviewed and deliberately not tracked separately · `[deferred]` blocked on a concrete precondition

## Methodology

Reviewed the docs-worktree foundation plan, [owner vision](vision.md),
[Vulkan backend design](vulkan_backend_design.md), and
[Vulkan capability report](vulkan_backend_findings.md) against
`master@da81087bb2c81e844588a0fc30197bd99201c6b9` on 2026-09-22.
The original plan is retained in
[history](history/engine_foundation_design_before_2026-09-22.md).

The tracker assigns the production backend and first windowed triangle to
#155, with recording #223, scheduling integration #232 and consumer #233
still open at this baseline. Those slices do not deliver the two consumers
below. These are future capability gaps, not reproduced rendering defects.
No tests or native sessions ran for this conversion.

FND-1 is delivered through resource epic #22; FND-2 belongs to Vulkan #155,
whose proof #158 is delivered and production root #219 remains open; FND-5
belongs to Lua #145 with its confinement gates intact. Their old descriptions
must not become parallel issues. This conversion neither approves nor
completes the original foundation epic.

## Status

- [ ] FND-3. Render and capture a minimal 3D scene through a public contract
- [ ] FND-4. Add an independent 2D consumer over the same GPU infrastructure

---

## Minimal reusable rendering consumers

### FND-3. Render and capture a minimal 3D scene through a public contract

The accepted triangle exercises the backend but does not establish a reusable
contract for camera-driven, depth-tested scene geometry. A small external
consumer should establish that contract through concrete needs, without
drawing game managers into the engine.

**Evidence:**

- Foundation D-2 and [owner vision](vision.md) require independent rendering
  modules over shared infrastructure.
- The [original FND-3](history/engine_foundation_design_before_2026-09-22.md)
  proposed depth-tested geometry, a camera and captured image evidence.
- [#223](https://github.com/coghex/hetoimasia/issues/223) and
  [#233](https://github.com/coghex/hetoimasia/issues/233) own managed triangle
  recording and its consumer, not a general 3D renderer.

**Handoff context:**

- Establish the smallest public scene/presentation contract and an independent
  consumer. Specify state ownership, coherent publication, resource lifetime
  and reset/disposal. Simulation remains application-owned.
- Demonstrate occlusion and camera changes with retained image evidence and
  clean validation. Keep pure preparation separate from native effects.
  Offscreen capture validates this later consumer; it does not replace the
  accepted windowed-triangle milestone.
- Refine only required backend extensions, coordinating with VKR-3 through
  VKR-6 for allocation, uploads, hazards and binding compatibility. A delivered
  model or proof does not supply production interfaces.
- **Gates:** delivery needs the relevant managed backend/recording and completion
  capabilities. Refinement may begin before the entire Vulkan arc closes;
  identify exact dependencies when drafting.
- **Unresolved:** minimal geometry/scene representation, camera conventions,
  resource updates, image-verification tolerances and delivery slices. Do not
  select an ECS, render graph, model importer or universal scene API merely
  to implement this sample.
- PBR, animation, shadows, general asset import and Synarchy migration remain
  outside this concern.

### FND-4. Add an independent 2D consumer over the same GPU infrastructure

A small textured 2D consumer is needed early to check that GPU services are
reusable without constructing a 3D renderer. This was an explicit foundation
goal, not an instruction to add a complete UI system.

**Evidence:**

- Foundation D-2 and [owner vision](vision.md) retain independent 2D and 3D
  modules over shared services.
- The [original FND-4](history/engine_foundation_design_before_2026-09-22.md)
  proposed ordered textured sprites, camera behavior and independent startup.
- [VKR-4/VKR-6](vulkan_backend_findings.md) identify upload and binding
  capabilities beyond the current triangle scope.

**Handoff context:**

- Establish the smallest textured-sprite consumer, explicit draw ordering,
  coordinate/camera behavior, texture ownership and update lifetime.
  Demonstrate overlap and camera behavior with captured evidence, and prove
  startup without constructing the 3D scene renderer.
- Reuse managed allocation, upload, synchronization and descriptor lifetimes.
  Coordinate loading ownership with RTC-4; neither that proposed loader nor a
  full asset pipeline is automatically required for a small fixture.
- The original sequence put FND-3 before FND-4. Preserve that proposed sequence
  for refinement while keeping 2D early; it is not a runtime dependency on the
  3D module. Changing delivery order requires an explicit refinement.
- **Gates:** the selected texture/upload/binding capabilities and shared backend
  must exist for delivery. Name them concretely; do not require unrelated
  Vulkan extensions or a complete advanced 3D renderer.
- **Unresolved:** texture provenance, alpha/blending and sampling conventions,
  ordering/batching contract and focused slice boundaries. Do not claim
  batching performance without measurement.
- A complete UI/font stack, broad input expansion and game migration remain
  outside this concern.

The foundation's original captured-Synarchy-scene then live-scenario proposal
can inform FND-4's interfaces. Refine the concrete migration acceptance target
separately; full text/UI/save/audio compatibility must not silently become
FND-4 acceptance or replace the independent 3D goal.
