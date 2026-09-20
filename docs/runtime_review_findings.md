# Low-level runtime review findings, 2026-09-20

Bugs, risks, and design gaps found by a read-and-test review of the foundation,
runtime, GLFW, and Vulkan proof and model layers at `master@5c593e2`, retained
for later disposition. Documentation drift found by the same review landed
directly in `fddcac5` and is not repeated here.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Methodology

The review built `cabal build all` warning-clean with the qualified GHC 9.14.1
and the private GLFW prefix, ran every headless suite (336 foundation, 184
runtime, 454 GLFW, 134 GPU model, 137 Lua host, 11 console examples, all
passing), the native dry run, and the console smoke, then read the resource,
time, logging, worker, application, update-policy, GLFW session, window,
capture, native shim, owner loop, render demand, retirement, GPU model, and
Vulkan proof modules against their contracts. No desktop session and no Vulkan
proof run was started. Findings are ordered from concrete mismatches to design
gaps; none is a failing test today.

## Status

- [ ] RR-1. Correct the proof shim header comments that describe behaviour the shim does not have
- [ ] RR-2. Pin the macOS proof driver and layer paths through stable locations
- [ ] RR-3. Keep a present fence's pre-wait status out of any retirement decision
- [ ] RR-4. Decide how rendering survives the platform's modal resize loop
- [ ] RR-5. Plan the cost of binding-wide safe foreign calls on the command hot path
- [ ] RR-6. Keep synchronous sink writes off the owner thread
- [ ] RR-7. Record Wayland and Windows as explicit platform scope decisions
- [ ] RR-8. Let a worker definition request a bound OS thread
- [ ] RR-9. Extend the native table toward game-grade input
- [ ] RR-10. Add the pre-initialization integration hook the surface bridge needs

---

## Proof harness and environment

### RR-1. Correct the proof shim header comments that describe behaviour the shim does not have

Two declarations in the proof's C header document parameters and return values
the implementation never had. VK-5 is expected to copy from this shim, so a
reader will carry the wrong contract into the production bridge.

**Evidence:**

- `tools/vulkan-proof/cbits/hetoimasia_vulkan_proof.h:24-25` — says `init_vulkan_loader` "Returns 0 when GLFW was already initialized, which would make the call a no-op".
- `tools/vulkan-proof/cbits/hetoimasia_vulkan_proof.c:52-59` — the function calls `glfwInitVulkanLoader` and unconditionally returns 1; nothing checks initialization state.
- `tools/vulkan-proof/cbits/hetoimasia_vulkan_proof.h:28-29` — says `glfw_init` takes a hidden-window hint "when `visible` is zero".
- `tools/vulkan-proof/cbits/hetoimasia_vulkan_proof.c:61-66` — the function takes no parameter, and the window is created visible in `hetoimasia_proof_create_window`.

**Handoff context:**

- **Current behavior:** the comments promise a check and a parameter that do not exist.
- **Expected direction:** the header describes exactly what the C does, or the C gains the documented check.
- **Scope and constraints:** a C header is not Markdown, so this cannot land through the docs lane; it belongs in a code PR, most naturally one of the remaining proof-review repairs or VK-5.
- **Remaining uncertainty:** None at draft time.

### RR-2. Pin the macOS proof driver and layer paths through stable locations

The proof's macOS environment pin names a Homebrew cellar path with the package
version baked in, and a LunarG SDK layer directory. A `brew upgrade molten-vk`
silently breaks the pinned manifest path, and the run then refuses with a
directory listing rather than the driver the record was made against.

**Evidence:**

- `tools/vulkan-proof/environment.pin:16` — `MACOS_VULKAN_DRIVER_MANIFEST=/opt/homebrew/Cellar/molten-vk/1.4.0/etc/vulkan/icd.d/MoltenVK_icd.json`.
- `tools/vulkan-proof/environment.pin:17` — `MACOS_VULKAN_LAYER_PATH=/usr/local/share/vulkan/explicit_layer.d`.
- `tools/vulkan-proof/run-proof.sh` — refuses when the manifest is unreadable, so the failure is loud but unrecoverable without editing the pin.

**Handoff context:**

- **Current behavior:** the pin is correct on the machine that recorded it and on no other Homebrew state.
- **Expected direction:** `/opt/homebrew/opt/molten-vk/...` or an explicit version check that says which MoltenVK the record covers, so an upgrade is a recorded decision rather than a broken path.
- **Scope and constraints:** VK-4 promotes these pins into the production native manifest; whatever it chooses should not inherit the cellar path.
- **Remaining uncertainty:** whether the record's MoltenVK 1.4.0 identity should stay pinned exactly, in which case the version check is the right form.

### RR-3. Keep a present fence's pre-wait status out of any retirement decision

The proof reads the present fence's status before waiting on it and reports the
answer. The compatibility record already states that this status before the
wait is not a contract on either platform. The risk is that VK-13 treats a
`SUCCESS` read there as evidence and skips the wait.

**Evidence:**

- `tools/vulkan-proof/proof/Test/Vulkan/Proof/Run.hs:1409` — `before ← getFenceStatus device slot.slotPresentFence` immediately after `vkQueuePresentKHR` returns.
- `docs/vulkan_compatibility_record.md` — records that the pre-wait status is observed only and that the fence is always waited for.

**Handoff context:**

- **Current behavior:** the proof reports the pre-wait status as a curiosity and waits regardless.
- **Expected direction:** the production retirement path in VK-13 must have no code path from `getFenceStatus` to a disposal decision; the injected `CompletionFact` for presentation should come only from a completed wait.
- **Scope and constraints:** the pure GPU model already refuses to prove native completion; this is a constraint on the native boundary that supplies its facts.
- **Remaining uncertainty:** this may be adequately covered by the record's rule and warrant no issue of its own.

## Owner loop and rendering

### RR-4. Decide how rendering survives the platform's modal resize loop

On macOS, and on Windows should it ever be supported, a window drag or resize
runs a nested modal loop inside the native event wait. `glfwWaitEventsTimeout`
and `glfwPollEvents` do not return until the drag ends. During that time GLFW
fires only the size, framebuffer size, and refresh callbacks, and the model's
callbacks only latch captures. No owner turn runs, so no update opportunity and
no render offer is made, and a window being resized shows stale or stretched
content for the whole gesture. Neither `docs/glfw.md` nor the Vulkan design
mentions this.

**Evidence:**

- `packages/glfw/model/Hetoimasia/GLFW/Internal/Window.hs:2274` — the owner turn's native step is one `glfwWaitEventsTimeout` or `glfwPollEvents` call.
- `packages/glfw/native/Hetoimasia/GLFW/Internal/Native.hs:334` — the refresh wrapper only forwards to `onWindowRefresh`, which the window model documents as record-only.
- `packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal.hs:1398-1410` — reconciliation, dispatch, and the update opportunity all follow the native step in the same turn, so nothing runs while the native step is blocked.
- `docs/glfw.md` — no occurrence of "live resize", "modal", or drawing from the refresh callback.

**Handoff context:**

- **Current behavior:** correct for input and lifecycle; rendering stalls for the duration of a resize gesture.
- **Expected direction:** an owner-level decision before VK-16: render from the refresh and size callbacks under a bounded contract, run rendering on a worker fed by the owner, or accept the stall and document it.
- **Scope and constraints:** any choice interacts with "callbacks only record" and "one main-thread owner", both accepted decisions; Synarchy's behaviour here is worth inspecting before choosing.
- **Remaining uncertainty:** X11 does not have this modal loop, so Linux CI cannot observe the stall; evidence needs a local macOS session.

### RR-5. Plan the cost of binding-wide safe foreign calls on the command hot path

The `vulkan` binding is pinned with `+safe-foreign-calls`, which marks every
import `safe`. That is required for the debug-utils callback and for calls that
block, but it also applies to every `vkCmd*` recording call, each of which then
releases and reacquires the capability. A frame records thousands of these.
Common practice is `unsafe` for recording calls and `safe` only for submit,
wait, acquire, present, create, and destroy. The binding's flag is package-wide,
so a mixed policy needs a deliberate mechanism.

**Evidence:**

- `cabal.project.vulkan:25` — `vulkan +safe-foreign-calls`.
- `tools/toolchain/binding.pin:13` — explains the flag is for callback re-entry.
- `docs/vulkan_backend_design.md`, P-11 — "measure before RTS tuning" names the general concern but not this specific per-call cost.

**Handoff context:**

- **Current behavior:** correct and slow by an unmeasured factor on the recording path.
- **Expected direction:** a measured figure for safe versus unsafe `vkCmd*` cost on both platforms, then a decision: accept, a thin unsafe re-import of the recording subset, or a batching design that reduces call count.
- **Scope and constraints:** any unsafe import must be provably unable to re-enter Haskell or block; validation layers can call the messenger from inside `vkCmd*`, so the unsafe subset may have to exclude validation builds.
- **Remaining uncertainty:** the real per-call overhead on the pinned GHC and the frame budget it should be weighed against.

### RR-6. Keep synchronous sink writes off the owner thread

The handle sink writes and flushes under an MVar on the calling thread. The
owner loop calls the logger from inside a turn for the input overflow warning
and the wake degradation report, so any such entry is a blocking write and
flush to stderr on the thread that will also drive rendering. D-19 already
routes backend diagnostics through a backend-owned worker; engine-level
logging from the owner thread has no equivalent.

**Evidence:**

- `packages/foundation/src/Hetoimasia/Foundation/Log.hs:553-561` — `newHandleSinkWith` serializes `hPutStr` and, with the default options, `hFlush` per entry.
- `packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal.hs:1438-1447` — `turnWork` calls `recoverFeeds` and the degradation attempt, both of which may emit through the injected logger on the owner thread.
- `docs/vulkan_backend_design.md`, D-19 — the bounded-queue worker design exists for backend diagnostics only.

**Handoff context:**

- **Current behavior:** correct; a warning costs one synchronous write on the render thread.
- **Expected direction:** a non-blocking sink option for the owner thread (bounded queue plus writer thread, loss counted, flush at lifetime end), or a documented policy that owner-thread entries are rare enough to accept.
- **Scope and constraints:** the logging lifetime's final-flush and reporting matrix must keep their guarantees; loss must be observable.
- **Remaining uncertainty:** whether owner-thread emission frequency ever matters in practice before a renderer exists.

## Platform and runtime scope

### RR-7. Record Wayland and Windows as explicit platform scope decisions

The native table supports Cocoa on macOS and X11 on Linux, and refuses Wayland
by construction. Windows is not a backend at all. Both are consistent with the
accepted macOS and Linux verification decision, but neither is written down as
a roadmap item, and a game client will eventually need Windows and modern
Linux desktops are Wayland-first.

**Evidence:**

- `packages/glfw/native/Hetoimasia/GLFW/Internal/Native.hs:268-272` — `hostBackend` answers `Cocoa`, `X11`, or `Nothing`.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Session.hs:857-862` — `resolveBackend` refuses any Wayland request.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Session.hs:639-653` — Wayland's capability restrictions are already described so they are not emulated.
- `packages/glfw/native/cbits/hetoimasia_glfw.c` — the Linux shim is compiled with `GLFW_EXPOSE_NATIVE_X11` only.

**Handoff context:**

- **Current behavior:** X11 through XWayland works on Wayland desktops with the usual scaling caveats; Windows fails at session entry with `UnsupportedBackend`.
- **Expected direction:** a recorded decision in the GLFW or foundation design naming when, if ever, Wayland and Win32 are in scope, so later slices are not designed around an unstated assumption.
- **Scope and constraints:** the shim's close-request and size-limit helpers, the process-main-thread check, and the wait observation are all platform-conditional and would each need a third branch.
- **Remaining uncertainty:** the owner's intended target platforms for the eventual Synarchy client.

### RR-8. Let a worker definition request a bound OS thread

Every worker is started with `forkIOWithUnmask`, so it is unbound and may
migrate between OS threads. Audio callbacks, some native libraries with
thread-local state, and any future subsystem that pins itself to an OS thread
cannot be hosted by the worker group as it stands. The module says so honestly
but offers no path.

**Evidence:**

- `packages/foundation/src/Hetoimasia/Foundation/Worker.hs:576` — `forkIOWithUnmask (runChild worker startup)`.
- `packages/foundation/src/Hetoimasia/Foundation/Worker.hs:40` — "It makes no OS-thread-affinity guarantee".

**Handoff context:**

- **Current behavior:** unbound workers only; the GLFW owner is the process main thread and is not a worker.
- **Expected direction:** an additive `WorkerDefinition` option that starts the child with `forkOS`-equivalent semantics, with the drain and cancellation contract unchanged.
- **Scope and constraints:** bound threads are more expensive to switch to; the option should be opt-in and documented in `docs/workers.md`.
- **Remaining uncertainty:** no current subsystem needs it; this is a gap for later arcs.

## Input surface

### RR-9. Extend the native table toward game-grade input

The bound GLFW surface covers window control, monitors, and keyboard, mouse
button, cursor position, cursor enter, scroll, and focus callbacks. It binds no
cursor mode or raw mouse motion, no joystick or gamepad, no clipboard, no file
drop, and no window icon. A UI works; mouse-look, controllers, and text paste
do not.

**Evidence:**

- `packages/glfw/native/Hetoimasia/GLFW/Internal/Native.hs` — no import of `glfwSetInputMode`, `glfwRawMouseMotionSupported`, `glfwGetGamepadState`, `glfwSetJoystickCallback`, `glfwGetClipboardString`, `glfwSetDropCallback`, or `glfwSetWindowIcon`.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Session.hs:392-411` — `WindowCallbacks` enumerates the fifteen bound callbacks.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Input.hs` — the feed carries key, character, button, scroll, and focus payloads only; cursor position coalesces into the observation.

**Handoff context:**

- **Current behavior:** every listed feature is absent rather than wrong.
- **Expected direction:** additive native operations and feed payloads, each under the same containment and owner-thread rules, prioritized by what the first game consumer needs.
- **Scope and constraints:** cursor-disabled mode and raw motion change what the cursor position means, so the observation and feed contracts need a stated rule; gamepads are polled, not callback-driven, and belong to the owner turn.
- **Remaining uncertainty:** which of these the Synarchy client needs first.

## Vulkan bridge prerequisites

### RR-10. Add the pre-initialization integration hook the surface bridge needs

P-7 requires the session to run a checked integration step, loader selection,
after taking ownership and before `glfwInit`, and to reset it after termination
or failed initialization. The session assembly currently has no such seam:
hints and initialization are one stage with nothing between them, and the
`Native` table has no operation for a loader.

**Evidence:**

- `packages/glfw/model/Hetoimasia/GLFW/Internal/Session.hs:895-901` — `initialize` calls `nativeSetInitHints` then `nativeInitialize` with no injectable step between them.
- `packages/glfw/model/Hetoimasia/GLFW/Internal/Session.hs:418-502` — `Native` declares no loader, surface, or Vulkan-support operation.
- `docs/vulkan_backend_design.md`, P-7 — specifies the additive capability, its ordering, and the reset on every exit.

**Handoff context:**

- **Current behavior:** the window-only session is complete; the Vulkan-aware session cannot yet be composed.
- **Expected direction:** exactly what P-7 describes, as an additive constructor beside `sessionAssembly`, with the seam examples covering ordering, failure before native effects, and the reset on both exits.
- **Scope and constraints:** the header-free native library must keep `GLFW_INCLUDE_NONE`; the Vulkan-typed calls live in the interop component.
- **Remaining uncertainty:** None at draft time; this is the VK-5 slice's first task rather than a defect.
