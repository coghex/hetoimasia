# Native Wayland qualification design

The GLFW session runs on Cocoa and on X11, and that is the whole of what the
repository can claim today: the Linux recipe builds GLFW with Wayland off, the
seam never selects Wayland, and the session model refuses it at entry so no
XWayland run is ever presented as Wayland. This arc plans real native Wayland
support and the evidence that would establish it, in the order the owner
approved on 2026-09-20 through [RR-7](runtime_review_findings.md): provision
the inputs, settle the selection and capability contract, collect headless
native evidence, then rendering evidence once the Vulkan slices that create
surfaces exist. Windows execution is recorded as deferred on a machine being
available; it has no slice here. Engine users on Wayland desktops and the CI
that must keep the X11 and Cocoa profiles honest are who benefit.

Design state: `ready for issue processing`

Readiness review completed on 2026-09-20: D-12 fixes the minimum evidence
matrix, all five questions are resolved, and WL-1 through WL-4 preserve the
agreed ownership and platform boundaries. This signs off the design for issue
processing; native Wayland support remains unqualified until the slices pass.
Amended the same day, after WL-1 and WL-2 were filed, by D-13, which the owner
signed off together with its reconciliation of D-12 and WL-3 and an
instruction to continue processing.

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Qualify native Wayland support for the GLFW session — [#202]
- [x] WL-1. Provision pinned Wayland inputs and an isolated headless compositor — [#204]
- [x] WL-2. Settle Wayland session selection and the capability contract — [#205]
- [x] WL-3. Collect headless native Wayland evidence — [#207]
- [ ] WL-4. Collect Wayland rendering evidence on the pinned software stack — [deferred]: VK-5 and VK-8 in #155 must merge first

## Epic contract

- **Goal:** the GLFW session can be entered on native Wayland with an explicit
  request, its capability model reports what a compositor does and does not
  let a client do, and retained evidence from an isolated headless compositor
  names the pinned compositor, the selected GLFW backend and, for rendering,
  the loader, driver and layers.
- **Done when:** WL-1 through WL-4 have merged; a native example under the
  isolated compositor asserts that GLFW selected `Wayland` rather than an
  XWayland X11 session; window creation, closure, lifecycle and failure
  cleanup, resize and framebuffer observations, supported controls,
  unsupported-operation outcomes, native wake and shutdown are demonstrated
  there; a confirmed compositor connection loss ends the window session under
  an isolated subprocess experiment; the window-only group is required when
  affected; a Wayland surface is created, presented to and retired on the
  pinned Lavapipe stack; the X11 and Cocoa profiles are unchanged; and
  `docs/glfw.md` states the supported Wayland profile and its remaining
  compositor and hardware gaps without a percentage of supported machines.
- **Users and operators:** engine applications running on a Wayland session;
  the Linux CI worker that runs isolated native groups; the human who runs
  local macOS verification and whose desktop is never disturbed by this arc.
- **Arc label:** `glfw`

## Current state and evidence

Checked at `master@af4436d` unless a line says otherwise.

- **Recipe.** `tools/native/native.py:205-208` configures Linux with
  `GLFW_BUILD_WAYLAND=OFF` and `GLFW_BUILD_X11=ON`, and refuses any target
  other than Darwin and Linux. The pinned source is GLFW 3.4 by URL and
  SHA-256 in `tools/native/glfw.pin`; changing any recipe value changes the
  native fingerprint every prefix, manifest and image is keyed on.
- **Image.** `tools/ci-image/provision.sh` installs the X11 development
  libraries, Xvfb, Openbox and `x11-utils` on Ubuntu 24.04 and nothing for
  Wayland. `tools/ci-image/descriptor.json` pins the published digest and the
  native manifest it was built with. The image starts no display.
- **Display helper.** `tools/display/x11.sh` starts a private Xvfb server and
  Openbox for one command, removes `WAYLAND_DISPLAY`, sets
  `XDG_SESSION_TYPE=x11`, and hands the command
  `HETOIMASIA_NATIVE_SESSION=isolated-x11:<display>`, the only scripted consent
  the native suite accepts. `tools/test/Display.hs` proves that helper.
- **Seam.** `packages/glfw/native/Hetoimasia/GLFW/Internal/Native.hs:268-272`
  chooses Cocoa on Darwin and X11 on Linux and no backend elsewhere; the
  platform codes for all three backends exist at `:274-283`. The Linux C shim
  `packages/glfw/native/cbits/hetoimasia_glfw.c:136-193` carries two
  X11-specific check helpers that load `libX11` at run time: the close driver
  that sends `WM_DELETE_WINDOW`, and the `WM_NORMAL_HINTS` reader behind
  `sizeLimitsForCheck`. Both are test-check helpers, not production paths.
- **Model.** `packages/glfw/model/Hetoimasia/GLFW/Internal/Session.hs:857-862`
  rejects Wayland whether the platform reports it or a request names it, and
  `:639-653` already describes the Wayland capability row: no global position
  to set or read, so no placement and no borderless-over-monitor; focus moved
  only by the compositor; no reliable iconified report. That row has never run.
- **Native suite.** `packages/glfw/native-tests/Test/GLFW/Native/Support.hs:230-248`
  requires X11 on Linux and Cocoa on macOS, fails with `DisplayUnavailable`
  when `WAYLAND_DISPLAY` is set, and asserts the selected backend after entry.
  The consent contract in `docs/glfw.md` (native session consent) accepts
  `desktop` from a human and `isolated-x11:<display>` from the helper alone.
- **Validation.** `test.glfw-native` runs on the `display` runner class only,
  is not optional, and lists `tools/display/`, `tools/native/` and
  `tools/ci-image/` among its inputs, so a recipe or helper change already
  selects it (`docs/validation.md`).
- **Prior decision.** The GLFW arc's D-8 in `glfw_integration_design.md`
  verified X11 first and gated Wayland "until a later arc", requiring a clear
  unsupported-backend result rather than silent selection, and keeping
  capability-aware commands so Wayland could be added later without fictional
  positions or iconification state. This is that arc.
- **Vulkan coupling.** VK-4 in `vulkan_backend_design.md` promotes the proof's
  loader, driver and layer recipe into the image and native manifest; VK-5 adds
  the loader-aware surface bridge and VK-8 the package-native fixtures and CI
  evidence. The Linux proof pins Mesa Lavapipe (D-10) as the software driver.
- **Windows.** No document claims Windows support. The seam yields no backend
  there, the recipe refuses the target, and neither compilation nor
  provisioning has been attempted. The earlier assumption that a Windows build
  reliably reaches `UnsupportedBackend` at session entry is withdrawn: nothing
  has been qualified there.
- **Tracker.** The readiness check on 2026-09-20 found no Wayland-titled issue
  and no overlapping open platform-qualification epic. #88 and #93 built the
  X11-only image and native fixture; epic #155 owns Vulkan and not platform
  qualification. Per-child deduplication remains part of issue processing.

## Desired experience

An application that wants Wayland asks for it through the existing session
configuration and either gets native Wayland or an entry failure that
distinguishes an unsupported backend, an unavailable display and failed native
initialization; it never gets XWayland under a Wayland name. On a Wayland
session the capability model tells the application, before any native effect, that placing,
focusing or reading an iconified state is unavailable. Observations retain the
native boundary's documented meaning; a recorded request is not proof that the
compositor applied it. Size, framebuffer extent and content scale are sampled
through that boundary, and suspension and render eligibility account for
information the pinned integration cannot provide. A Linux CI run can prove
this under a private headless compositor exactly as it proves X11 under a
private Xvfb, and a maintainer can read one profile statement in `docs/glfw.md`
to learn what Wayland support means here and what it still does not cover.

## Scope

### In scope

- Enabling Wayland in the pinned native recipe beside X11, with the required
  build inputs pinned and reflected in native identity, and X11 preserved.
- A pinned headless compositor in the Linux image and a display helper that
  isolates it the way `x11.sh` isolates Xvfb, with its own consent token.
- An explicit session-selection contract for Wayland, including the Linux
  default, and an audit of the two X11-only shim helpers.
- Verification of the dormant Wayland capability row and the compositor-driven
  behaviours it does not yet cover.
- Headless native evidence, a validation group for it, and criteria for
  promoting it to a required-when-affected check.
- Rendering evidence on Wayland over the pinned Lavapipe stack once VK-5 and
  VK-8 exist.
- The supported-profile statement in `docs/glfw.md`.

### Out of scope

- Windows execution, compilation or provisioning; recorded as deferred on a
  machine being available, with no slice and no precondition on this arc.
- Qualifying every compositor; a headless compositor qualifies the protocol
  path, and compositor-specific desktop probes stay optional.
- Any change to the X11 or Cocoa profiles, GLFW's main-thread rules, native
  handle privacy or window ownership.
- A hosted macOS job, or any disturbance of the human's desktop.
- Blocking the macOS/X11 rendering milestone in `vulkan_backend_design.md` on
  this arc, or on desktop-platform parity.

## Design

**Ownership stays where it is.** The session model keeps deciding admission,
the seam keeps translating to GLFW, the native suite keeps its consent gate and
lazily acquired shared session, and the validation catalog keeps selecting
groups from inputs. Wayland is added as a third backend inside those owners,
not as a parallel path.

**Provisioning.** The native recipe gains `GLFW_BUILD_WAYLAND=ON` on Linux
beside X11, so one prefix serves both and GLFW's runtime platform selection
chooses between them. The inputs GLFW 3.4 needs for that build (the Wayland
client library, `wayland-protocols`, `wayland-scanner` and `libxkbcommon`
development packages, exact set to be confirmed by WL-1 against the pinned
source) enter the image's package step and the recipe fingerprint, so an old
prefix, manifest or image stops matching. The headless compositor enters the
same package step at the version Ubuntu 24.04 packages (D-7), and a
`tools/display/wayland.sh` helper starts it privately for one command. The
helper's isolation contract: a private `XDG_RUNTIME_DIR` created for the run,
a socket name of its own under it, inherited `WAYLAND_DISPLAY` and
`WAYLAND_SOCKET` both unset before the compositor starts (a leaked
`WAYLAND_SOCKET` file descriptor overrides the socket name and would defeat the
isolation), `DISPLAY` cleared, `XDG_SESSION_TYPE=wayland`, readiness verified
by connecting to the socket the helper named rather than by elapsed time, the
command handed a consent token for that socket alone, and the compositor
stopped and the runtime directory removed on every exit path. A compositor that
is missing, exits or never becomes ready blocks the group rather than passing
it. The retained environment identity records the compositor package version
and the versions of its supporting packages.

**Selection.** The seam reports what the platform can do; the model decides.
Under D-8, X11 stays the Linux default when nothing is requested, `Wayland` is
admitted only on an explicit request, and no request ever falls back to the
other backend. After initialization the session compares `glfwGetPlatform`
with the admitted backend and fails entry if they differ, so an XWayland X11
session cannot be reported as Wayland. Three failures stay distinguishable in
the entry result and its diagnostics: the backend was not compiled into the
prefix, which `glfwPlatformSupported` answers before initialization; no
display or socket is reachable, which only the connection attempt answers; and
native initialization failed on a reachable display, which is GLFW's own
error. A supported answer from `glfwPlatformSupported` proves nothing about a
working compositor connection. The native fixture gains a Wayland platform rule
mirroring its X11 one, entered only when the helper's socket is the one named
and `DISPLAY` is absent; that rule is the fixture's, not the session's, so an
ordinary application on a desktop exposing both `DISPLAY` and
`WAYLAND_DISPLAY` remains usable on either backend it asks for.

**Capability contract.** The existing Wayland capability row is verified rather
than trusted: each unsupported operation and unavailable observation is
asserted against the compositor under WL-3, and the audit under WL-2 extends
the row where compositor control reaches beyond it. Size, framebuffer extent
and content scale retain the native boundary's meaning; D-12 distinguishes
command delivery, observations and demonstrated change propagation. Suspension
and render eligibility must not assume minimization or occlusion information
the pinned integration does not expose. Nothing fabricates X11-equivalent state.

**Check helpers.** The two X11-only helpers have no Wayland analogue: a client
cannot send itself the compositor's close request, and `xdg_toplevel` size
limits are sent to the compositor and not readable back. Under D-9 both are
marked unavailable on Wayland, and no compositor automation is built to
reproduce them. Unavailable means the test convenience is missing, not that
window closure or size constraints are unsupported: the model's coverage of
close-request handling stays, programmatic closure remains its own example,
and the profile statement records that a compositor-generated close request
has not yet been demonstrated on Wayland. The helpers stay test-only and the
seam keeps `GLFW_EXPOSE_NATIVE_*` out of production paths, with one explicit
exception: the private, read-only connection-status probe D-13 permits, which
exposes no native pointer or descriptor beyond the shim.

**Connection-status probe.** GLFW 3.4's Wayland event loop reports a lost
compositor connection through no error at all: when its display flush fails
it cancels the read and issues a close request for every window, then returns
(`src/wl_window.c:1142-1160,1222-1250`), and nothing reaches the error
callback. Close-request patterns are therefore neither necessary nor
sufficient evidence of connection failure. Under D-13 the production native
shim carries a private probe that the session owner thread runs at its
event-processing boundaries, before and after each poll or wait, while the
session is live and whether or not it has windows. The probe reads the
connection's error state and its socket's peer-closure status with a
zero-timeout check, dispatches nothing, and returns a copied typed status
through the existing private seam. GLFW remains the connection owner; the
engine receives a status, applications never a handle.

**Evidence.** Headless native evidence under the isolated compositor is the
first qualification and the promotion candidate; X11 green results are never
Wayland evidence. Rendering evidence waits for VK-5 and VK-8 and reuses their
fixtures over the Lavapipe stack VK-4 pins, adding Wayland surface creation,
presentation and retirement cases beside the X11 ones. Retained records name
the compositor and version, the selected backend, and for rendering the loader,
driver and layer identities.

**Failure handling.** Entry fails as `UnsupportedBackend` when the backend is
not compiled in, as `DisplayUnavailable` when no display or socket for the
selected backend is reachable, or as a native failure attributed to
session entry when GLFW's own initialization fails on a reachable display,
each with its reason named. Omitting the request selects X11 under D-8; it
does not itself produce `UnsupportedBackend`. Compositor disappearance cannot
be assumed to produce an ordinary native failure: GLFW 3.4 has a disconnect
path that generates a close request for every window and reports no error,
and because an application may reject ordinary close requests, that behaviour
alone establishes nothing about correct failure handling. Loss is confirmed
only by the D-13 probe at an event-processing boundary. Under D-10 a confirmed
connection loss is terminal for that window session: no automatic
reconnection, no fabricated graphics-completion evidence for work the
compositor can no longer settle, and retirement under the existing protected
boundary. The failure names its actual cause, transport closure, protocol
failure, or probe failure, and never describes all three as the compositor
having crashed. Loss is primary when it initiates failure; an earlier primary
failure remains primary. The claim is made only after an isolated subprocess
experiment with an external timeout demonstrates it (WL-3); a watchdog that
has to kill a stuck client is failed qualification, because checks around GLFW
cannot promise recovery if GLFW itself never returns.

## Decisions

Decisions D-1 through D-6 are the owner's approvals recorded in RR-7 on
2026-09-20 and restated here without change.

### D-1. Defer Windows execution until a machine is available

Windows is not a current supported build. Compilation and provisioning have not
been qualified there, remote CI stays Linux-only, and the assumption that a
Windows build reliably reaches `UnsupportedBackend` at session entry is
withdrawn. This arc records the deferral and carries no Windows slice; the
macOS/X11 milestone is not blocked on Windows or on platform parity.

### D-2. Plan native Wayland support, not a CI checkbox

Enable and pin the required build inputs, preserve X11, audit the X11-specific
shim helpers, and choose an explicit session-selection contract. Native handles
stay private and every GLFW ownership and main-thread rule stays intact.

### D-3. Make unsupported capabilities explicit

Unsupported positioning, focus and control requests and unavailable
observations are reported as such; no X11-equivalent state is fabricated.
Resize, framebuffer size and content scale, suspension and render eligibility
are audited against compositor-controlled behaviour, reusing the existing
capability model and verifying its assumptions rather than treating the dormant
Wayland row as tested.

### D-4. Collect the first evidence under an isolated headless compositor

Initial evidence runs in Linux under an isolated headless compositor and
asserts that GLFW selected native Wayland rather than XWayland. It verifies
independent window creation and closure, lifecycle and failure cleanup, resize
and framebuffer observations, supported controls, unsupported-operation
outcomes, native wake and shutdown. Unavailable experiments are reported
honestly, and X11 results do not count.

### D-5. Add rendering evidence when the surface slices exist

Real Wayland surface creation, presentation and retirement cases run on the
qualified software Vulkan stack once VK-5 and VK-8 are available. Window-only
qualification does not establish rendering support, and graphics capability
requirements and completion evidence stay intact.

### D-6. Reuse the pinned image, cache and catalog; keep desktop probes optional

The qualification reuses the pinned Linux image, the native cache and the
validation catalog, defines its groups and their promotion to small
required-when-affected checks when support is established, and keeps extensive
desktop and compositor-specific probes optional. Local macOS testing and the
human's explicit consent for desktop disruption are preserved.

Decisions D-7 through D-11 were made by the owner on 2026-09-20 in review of
this document's first draft.

### D-7. Pin packaged Weston in the Linux image

The headless compositor is Weston as Ubuntu 24.04 packages it, `13.0.0-4build3`
at the time of the decision, pinned in the image. The retained environment
identity records the compositor and its supporting package versions. Weston is
built from source only if qualification demonstrates a missing capability;
there is no current reason to maintain another source build. Resolves Q-1.

### D-8. Keep X11 the Linux default; admit Wayland only on explicit request

An unrequested Linux session selects X11, a Wayland request is honoured only
as native Wayland, and no request silently falls back in either direction. The
actual GLFW backend is checked after initialization. The isolated fixture
requires its private Wayland environment, but that is the fixture's rule:
ordinary applications remain usable on desktops that expose both `DISPLAY` and
`WAYLAND_DISPLAY`. Resolves Q-2.

### D-9. Mark the two X11 test helpers unavailable on Wayland

The close driver and the size-limits reader are unavailable on Wayland
initially, and no compositor automation is built to reproduce X11's testing
conveniences. The helpers are unavailable; window closure and size constraints
are not unsupported. Model coverage of close-request handling stays,
programmatic closure is a different example, and the record states explicitly
that a real compositor-generated close request has not yet been demonstrated.
Resolves Q-5.

### D-10. Treat confirmed compositor connection loss as terminal

A confirmed loss of the Wayland connection ends that window session: no
automatic reconnection and no fabricated graphics-completion evidence. GLFW's
disconnect path that emits a close request per window is not sufficient
evidence of correct handling because the application may reject ordinary close requests.
The behaviour is claimed only after an isolated subprocess experiment with an
external timeout demonstrates it.

### D-11. Make the window-only group required when affected once WL-3 lands

The small window-only Wayland group becomes required-when-affected as soon as
WL-3 establishes its required evidence. There is no consecutive-image-digest
requirement: rebuilding an image twice proves neither stability nor
correctness. Rendering coverage is added separately by WL-4, and window
regression protection does not wait for Vulkan. Resolves Q-4.

### D-12. WL-3's minimum evidence matrix

The owner signed off this matrix on 2026-09-20 in its wording below. Each
required case must pass for WL-3 to complete; a required case that cannot run
fails the slice and is never reported as unperformed. Unavailable experiments
are listed in the record and never asserted. Resolves Q-3.

Required cases:

| Case | What it asserts |
| --- | --- |
| Backend selection | Explicit Wayland selection under the private helper enters native Wayland. No request still selects X11 under D-8; with no reachable X11 display, entry fails for that reason, not `UnsupportedBackend` for a missing request. Explicit Wayland selection under an isolated X11-only environment fails for lack of a Wayland connection. Compiled-support rejection is verified separately through the seam. |
| Independent window lifetimes | Close two windows in both orders. Closing either retires only its resources; the shared session and the remaining window stay usable. No live registration or resource belonging to the closed window remains. |
| Supported controls and observations | Supported commands settle correctly; size and visibility observations reflect what the native boundary reports. Size-limit tests verify command delivery and engine-side constraint handling, not unavailable compositor read-back or guaranteed compositor enforcement. Content scale is an observation, not an application request. Sample framebuffer extent and scale; claim change propagation only where the experiment actually induces that change. |
| Explicit unsupported outcomes | Include both global placement and iconified observations, alongside placement, focus and borderless-over-monitor requests. Verify typed unavailable outcomes and that the corresponding unsupported native operations and getters are not invoked. |
| Wake | Establish that the owner has entered a native wait, then issue a production cross-thread wake and verify it releases that wait. Timeout expiration or an unrelated event must not count as wake evidence. Use a generous failure deadline, not a performance threshold. |
| Shutdown | In a private child process, fully leave one session and successfully enter another in that same process. Keep the parent suite's shared session intact. |
| Failure cleanup | Forced initialization and window-construction failures preserve the primary failure and cleanup evidence. Successful rollback leaves no live resources or registrations from the failed acquisition and permits a subsequent valid acquisition. Label injected failures as injected evidence. |
| Connection loss | Use a subprocess with its own compositor, so killing it cannot destroy the suite's shared fixture. Reject ordinary close requests in the test application, then verify that the D-13 probe confirms the loss at an event-processing boundary and the session terminates without reconnecting. Cover four situations: loss with rejected close requests pending, loss with zero windows, loss while the owner is inside a native wait, and an ordinary close request on a healthy connection that the probe does not mistake for loss. The reported cause distinguishes transport closure, protocol failure and probe failure. Loss is primary when it initiates failure; earlier primary failures remain primary. External timeout or forced process termination fails the case, because a watchdog killing a stuck client is failed qualification. GPU completion remains WL-4 evidence. |

Unavailable experiments, listed in the record rather than asserted:

| Experiment | Why it is unavailable |
| --- | --- |
| Compositor-generated close request | No client-side driver exists (D-9); programmatic closure is covered separately. |
| Size-limit read-back | `xdg_toplevel` limits are not readable from the client (D-9). |
| Minimization, suspension and occlusion evidence | Reliable observations are not established through the pinned GLFW 3.4 integration, whose direct `xdg-shell` path binds protocol version 1; newer protocol versions carry a suspended state GLFW 3.4 does not use. Report unavailable information explicitly; do not infer that a window is drawable from an unknown state. Broader compositor-specific qualification remains deferred. |

The controls row matters because GLFW exposes content scale only as a getter
and a callback, and the `xdg-shell` specification lets a compositor disregard
requested size limits.

### D-13. Permit a private, read-only Wayland connection-status probe in the production shim

The owner accepted this exception on 2026-09-20, after WL-3's processing found
that GLFW 3.4 exposes no confirmable disconnect signal (see Connection-status
probe under Design). In the owner's words:

> Permit a private, read-only Wayland connection-status probe in the
> production native shim. It may use `glfwGetWaylandDisplay`,
> `wl_display_get_error`, and `wl_display_get_fd`, together with a
> zero-timeout Linux socket-status check for peer closure. Run it on the
> session owner thread while the session is live. It must not read or dispatch
> protocol messages, flush, create windows, reconnect, or close GLFW's
> connection. Return copied status information through the existing private
> seam; expose no native pointer or descriptor publicly.

Two corrections to the first proposal are part of the decision. The probe runs
at the owner's event-processing boundaries, before and after polling or
waiting, including in sessions with no windows; it is never triggered by
close-request patterns, which are neither necessary nor sufficient evidence.
And `wl_display_get_error` alone is insufficient: in libwayland 1.22 a flush
returning `EPIPE` deliberately does not latch a fatal display error, so the
getter can answer zero on exactly the path in question. Linux `poll` with a
zero timeout reports hangup without consuming protocol data, which is what
makes the check a status read rather than a wait.

Further requirements: the probe's library symbols are resolved once and the
library lifetime is retained through the final query, and missing probe
support fails Wayland initialization explicitly. The failure cause is
preserved, so transport closure, protocol failure and probe failure are
reported as themselves. Connection loss stays a required WL-3 case, covering
rejected close requests, zero windows, loss during a native wait, and an
ordinary close request on a healthy connection. A watchdog killing a stuck
client is failed qualification: checks surrounding GLFW cannot guarantee
recovery if GLFW itself never returns, and the native experiment must
establish the behaviour.

Rejected alternatives: confirming loss by creating another window and
interpreting its error text, a fragile diagnostic side effect; and moving
connection loss out of the required set, which weakens a fundamental lifecycle
requirement unnecessarily. This is an explicit exception in the design and
introduces no public API escape hatch and no new lifetime owner.

## Open questions

### Q-1. Which compositor, at which version, is pinned for the headless runs?

Resolved by D-7. The rejected alternatives were a newer Weston built from
source, which adds a second native recipe, and a different compositor such as
Sway under a headless backend, which adds a dependency with no other use here.

### Q-2. What does an unrequested Linux session select, and is there any fallback?

Resolved by D-8. The rejected alternative was selecting from
`XDG_SESSION_TYPE`, which would make default selection depend on the launching
environment. Explicit selection preserves the X11 baseline; verification of
the actual selected backend prevents an XWayland run being named Wayland.

### Q-3. What is the minimum evidence matrix WL-3 must demonstrate?

Resolved by D-12. The first draft's table kept the same eight categories but
several assertions contradicted the agreed contract: it let an unrequested
session with no X11 display fail as a missing request, reversed the ownership
requirement for independent window lifetimes by asking that no shared state
survive a closure, treated content scale as a request and size limits as
compositor-enforced, left timeout expiry insufficiently distinguished from
wake evidence, and claimed the
protocol universally lacks suspension signals when only GLFW 3.4's bound
`xdg-shell` version lacks them.

### Q-4. When does the Wayland group become required-when-affected?

Resolved by D-11. The rejected proposal required two consecutive image
digests and WL-4 before promotion.

### Q-5. What replaces the two X11-only check helpers under Wayland?

Resolved by D-9. The rejected alternative was a compositor-side driver that
the isolated Weston could run, which would have gained a real close-request
example at the cost of compositor automation.

## Verification strategy

- **Headless model checks** stay first: capability-row behaviour, selection
  refusals and the XWayland guard are provable over the test seam with no
  compositor, in `glfw-tests`.
- **Isolated native evidence** runs in `glfw-native-tests` under
  `tools/display/wayland.sh`, with its own consent token, asserting the
  selected backend before any window example; the run's last line still
  reports one acquisition of the shared session.
- **Workflow checks** in `tools/test/Display.hs` prove the new helper the way
  they prove `x11.sh`: missing compositor, early exit, readiness timeout, the
  private runtime directory and socket, `WAYLAND_SOCKET` and `DISPLAY` unset,
  cleanup on every exit path, and the exact environment handed to the command.
- **Connection loss** is demonstrated only in an isolated subprocess under an
  external timeout with its own compositor, never inside the shared session.
  A hung client fails the example and validation group without hanging the
  suite or destroying its shared compositor, and a watchdog that has to kill
  the client is failed qualification, not a pass. The D-13 probe's own
  behaviour is provable headless over the seam: a scripted status at each
  boundary, the four D-12 situations, the preserved cause, and refusal of
  Wayland initialization when probe support is missing.
- **Rendering evidence** reuses the VK-8 fixtures and the Lavapipe stack, with
  Wayland cases beside the X11 ones and the same completion evidence rules.
- **Identity.** Every retained record names the recipe fingerprint, image
  digest, compositor and version, selected backend and, for rendering, loader,
  driver and layer identities.
- **Constraints.** No desktop disruption on macOS; no timing sleeps for
  coordination; the mandatory floor keeps building without a Wayland session;
  `docs/glfw.md`, `docs/validation.md` and the native fixture documentation
  change in the same PR as the code they describe.

## Delivery plan

### WL-1. Provision pinned Wayland inputs and an isolated headless compositor

- **Outcome:** the Linux native prefix builds GLFW with both Wayland and X11,
  the image carries the pinned compositor, and a display helper isolates it for
  one command with its own consent token.
- **Scope:** recipe options and pinned build inputs, native identity and
  fingerprint, image package step with packaged Weston and the descriptor
  recording its version and its supporting packages, `tools/display/wayland.sh`
  under the isolation contract in Design (private `XDG_RUNTIME_DIR`, own
  socket, `WAYLAND_SOCKET` and `DISPLAY` unset, verified readiness, cleanup on
  every exit) with its workflow examples, and the consent token the native
  suite will accept in WL-2. X11 behaviour unchanged.
- **Phase:** 1, provisioning.
- **Depends on:** `none`. Coordinate image changes with VK-4 so the two do not
  race on the descriptor.
- **Ordering:** can land first.
- **Relevant decisions:** D-2, D-6, D-7.
- **Acceptance signals:** the published image builds from the changed recipe
  with a new fingerprint; the helper starts and stops the compositor around a
  trivial command, blocks when it is missing, and leaves no runtime directory
  or socket behind on any exit; the X11 group still passes on the new image;
  the descriptor names the compositor version.
- **Out of scope:** any session-selection change; native examples on Wayland.
- **Open questions:** None.

### WL-2. Settle Wayland session selection and the capability contract

- **Outcome:** an explicit Wayland request enters a native Wayland session or
  fails with a reason, the XWayland guard holds, the native fixture accepts the
  new consent token, and the capability row is audited and extended.
- **Scope:** `resolveBackend` and the post-initialization platform check, the
  three distinguishable entry failures (backend not compiled, display
  unavailable, native initialization failed), the seam's host backend
  reporting, the fixture's Wayland platform rule and consent token, marking
  the two X11-only helpers unavailable on Wayland, the capability-row audit
  for resize, framebuffer size, content scale, suspension and render
  eligibility, an optional `test.glfw-wayland` catalog group on the `display`
  runner routed through `tools/display/wayland.sh` so the slice's native
  example has an execution path from the start, and the Entry and capability
  sections of `docs/glfw.md`.
- **Phase:** 2, contract.
- **Depends on:** `WL-1`.
- **Ordering:** critical path.
- **Relevant decisions:** D-2, D-3, D-8, D-9.
- **Acceptance signals:** headless examples prove refusals, the default, the
  three failure distinctions and the guard over the test seam; the native
  backend-selection case from D-12 runs through the new group under the helper
  and asserts `Wayland`; the documentation states the contract and records
  that a compositor-generated close request is not yet demonstrated.
- **Out of scope:** the rest of the evidence matrix; rendering; making the
  group required.
- **Open questions:** None.

### WL-3. Collect headless native Wayland evidence

- **Outcome:** the D-4 evidence exists as native examples under the isolated
  compositor, and the window-only group is required when affected.
- **Scope:** the D-13 connection-status probe in the production native shim
  and the seam, run at the owner's event-processing boundaries, with the
  D-10 terminal-session handling it confirms and the preserved failure cause;
  every required case of the D-12 matrix as examples in `glfw-native-tests`,
  the shutdown and connection-loss cases as private child processes, the
  latter with its own compositor and an external timeout that fails the case
  and validation group without hanging the suite; the `test.glfw-wayland`
  group made non-optional with the same input set as `test.glfw-native`;
  retained records naming compositor and backend and listing the unavailable
  experiments; and the profile statement in `docs/glfw.md` with its remaining
  gaps.
- **Phase:** 3, evidence.
- **Depends on:** `WL-2`.
- **Ordering:** critical path.
- **Relevant decisions:** D-3, D-4, D-6, D-10, D-11, D-12, D-13.
- **Acceptance signals:** every required case passes on the published image
  under the helper, and a required case that cannot run fails the slice; the
  unavailable experiments are listed in the record, not asserted; unsupported
  operations and unavailable observations agree between headless and native
  examples; the probe's behaviour is proven headless over the seam and
  natively in the child experiment, a watchdog kill counting as failure;
  failure, connection loss and shutdown preserve ownership; no native pointer
  or descriptor leaves the shim.
- **Out of scope:** rendering; compositor automation for the X11 helpers.
- **Open questions:** None.

### WL-4. Collect Wayland rendering evidence on the pinned software stack

> **Deferred:** the slice adds Wayland cases to VK-8's native fixtures through
> VK-5's surface bridge, and neither is filed yet under #155 — clears when the
> issues filed for VK-5 and VK-8 have merged, at which point the fixture and
> bridge shapes this issue must name exist.

- **Outcome:** Wayland surface creation, presentation and retirement are
  demonstrated on Lavapipe under the isolated compositor with the same
  completion evidence rules as X11.
- **Scope:** Wayland cases in the VK-8 native fixtures, and retained records
  naming loader, driver and layers beside the compositor.
- **Phase:** 4, rendering.
- **Depends on:** `WL-3`. External prerequisites: VK-5 and VK-8 in
  `vulkan_backend_design.md` merged.
- **Ordering:** not on the critical path of the Vulkan arc; last here.
- **Relevant decisions:** D-5, D-6, D-10.
- **Acceptance signals:** a surface is created through the VK-5 bridge on a
  Wayland window, presented to with verified presentation-fence completion, and
  retired under the protected boundary; connection loss during rendering
  fabricates no completion evidence; the required native budget still holds on
  Linux.
- **Out of scope:** desktop compositor probes; macOS changes; Windows.
- **Open questions:** None.
