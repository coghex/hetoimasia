# Native Wayland qualification: the retained runs

The records WL-3 (#207) and WL-4 (#327) require: the run that established the
headless native Wayland profile [glfw.md](glfw.md#wayland) states, and the run
that established Vulkan rendering on it ([Rendering](#rendering)), each kept
verbatim because a run's own output is the evidence and a CI log that expires
is not a record. A third, #357's, qualifies hiding a presenting window, which
WL-4's run left unqualified ([Hiding a presenting window](#hiding-a-presenting-window));
the earlier runs are kept as they were. Each names what ran, where, and on what. The first lists the
experiments the Wayland qualification design's D-12 declares unavailable, which
are listed here and never asserted; the second names what stays unqualified.

## The run

Workflow run [36274457569](https://github.com/coghex/hetoimasia/actions/runs/36274457569),
job `glfw-native`, group `test.glfw-wayland`, for pull request
[#278](https://github.com/coghex/hetoimasia/pull/278) at commit `22e966a`, executed on
GitHub's merge candidate `305d7ff`. The
plan step resolved that candidate's input identity as
`bba4281597797e82c96f326173ab8ac7d0861eea4ddbc684f52c2df829faf773`. The group's
receipt is in that run's `validation-receipts-glfw-native` artifact as
`test.glfw-wayland.json`; the same job's `test.glfw-native` passed beside it
under `tools/display/x11.sh`, with 113 examples, 0 failures, and 23 pending —
this tree's 21 examples and the two optional probes.

Only this record, which is Markdown no group consumes, changes after that
commit, so the run stays input-equivalent to the head it ships with:
`plan.py --base 22e966a --head HEAD` reports `test.glfw-wayland` unaffected.
That has to be rechecked whenever the head moves for any other reason.

## Identity

| What | Value |
| --- | --- |
| Image recipe fingerprint | `f4ff7abee54affa5ea2e6429269213e232b022e23fd2ad93024ab55ffceb3324` (`tools/ci-image/descriptor.json`; `ci_image.py fingerprint --revision HEAD` agrees) |
| Image digest | `ghcr.io/coghex/hetoimasia-ci@sha256:74c08dc539d2364b640a9560edc4560ce0e5e55a70db82b8ddbf906c9feab612`, verified by the job before it ran anything |
| Native manifest | `8c6860a3616749bf1d3f0af52d6dda7f70b69ef82fb2f4095ab1641ac3da86fd`: GLFW 3.4 built with Wayland and X11, carrying `0001-wayland-fix-segfault-when-there-is-no-seat.patch` |
| Compositor package | Ubuntu 24.04's `weston` `13.0.0-4build3` (D-7), which reports itself as `weston 13.0.0`, headless backend |
| Selected backend | `Wayland`, as `glfwGetPlatform` answered for the shared session the consent `isolated-wayland:hetoimasia-758` authorized |
| Toolchain | GHC 9.14.1, Cabal 3.18.1.0, `x86_64-linux` |

The exact command, as the display worker ran it, with its `--toolchain`
arguments expanded from the run's verified toolchain file, which lists them in
name order — the same map the group's receipt declares:

```bash
bash tools/display/wayland.sh --summary "$GITHUB_STEP_SUMMARY" -- \
  python3 -I tools/validation/run.py test.glfw-wayland --plan plan.json --receipts receipts \
  --worker glfw-native --runner-class display \
  --toolchain 'cabal=3.18.1.0' \
  --toolchain 'ci-image=sha256:74c08dc539d2364b640a9560edc4560ce0e5e55a70db82b8ddbf906c9feab612' \
  --toolchain 'ghc=9.14.1' \
  --toolchain 'glslang=15.1.0 96ea85d4228d' \
  --toolchain 'native-manifest=8c6860a3616749bf1d3f0af52d6dda7f70b69ef82fb2f4095ab1641ac3da86fd' \
  --toolchain 'vulkan=0a53afbd93d705f228556e9c4bbcacd4c1e0e79b1216b2c8f68458668d384a71' \
  --toolchain 'vulkan-driver=lvp 1.4.318 9d69cae2004b' \
  --toolchain 'vulkan-layers=VK_LAYER_KHRONOS_validation 1.3.275 1d486283e4ce +synchronization' \
  --toolchain 'vulkan-loader=1.3.275 e833b010f814' \
  --toolchain 'weston=13.0.0-4build3'
```

which runs the group's catalog command:

```bash
cabal test glfw-native-tests --test-show-details=direct \
  --test-option=--match --test-option='/GLFW native/on an isolated Wayland session/'
```

## Required cases and outcomes

Every required case of D-12 ran under the compositor's consent and passed;
none was skipped or reported as unperformed.

| Case | Examples | Outcome |
| --- | --- | --- |
| Backend selection | The shared session requesting Wayland; a child requesting nothing; a child requesting Wayland under `tools/display/x11.sh` | Passed. The shared session selected Wayland on `hetoimasia-758` with `DISPLAY` unset. The unrequested child resolved to X11 and failed `glfwInit` with `X11: The DISPLAY environment variable is missing`, not `UnsupportedBackend`. With X11 display `:0` reachable and no Wayland socket, the Wayland child failed `glfwInit` with `Wayland: Failed to connect to display`. Compiled-support rejection is proven over the seam in `glfw-tests`. |
| Independent window lifetimes | Two windows closed first-then-second and second-then-first through the real owner loop | Passed. Each close released only its own window; the other still observed and executed through its own port. |
| Supported controls and observations | Title and size; show and hide; size limits; framebuffer and content scale | Passed. Title and size settled and matched `glfwGetWindowTitle` and `glfwGetWindowSize`; visibility followed show and hide; limits were delivered and an out-of-constraint size refused engine-side, with nothing read back; framebuffer 320×240 at scale 1.0 followed the induced resize to 280×210. |
| Explicit unsupported outcomes | A child over a traced production table | Passed. Placement, focus, and borderless requests settled unsupported with reasons; placement and iconified observations were `Unavailable`; no call was made to `glfwSetWindowPos`, `glfwGetWindowPos`, `glfwFocusWindow`, `glfwSetWindowMonitor`, or `glfwGetWindowAttrib(GLFW_ICONIFIED)`. |
| Wake | The four session wake examples | Passed. Every wake ended a wait observed blocked inside GLFW, in well under a millisecond of a 60 s bound; the spurious-wake example returned one wait early, within its limit. |
| Shutdown | The `session-lifecycle` child | Passed. It entered and fully left two Wayland sessions, observed a forced initialization failure, and entered again; the parent's shared session then still served, with one acquisition. |
| Failure cleanup | The `wayland-failure-cleanup` child | Passed. The forced initialization failure (labelled injected) stayed primary with no cleanup failure and freed 1 of 1 error callback storage, and a later session entered. The injected construction failure stayed primary beside the injected release failure, every input callback was cleared before the one real window was destroyed, and a later window was created: 2 windows and 2 storages created and released in all. |
| Connection loss | Four children, each ending a Weston of its own | Passed. With injected close requests rejected and one pending, and with no window, the probe confirmed `TransportClosed` before event processing. With the owner blocked inside a 30 s wait, the wait returned after 1.6 ms and the probe after it confirmed `TransportClosed` with `errno` 32 (`EPIPE`) latched; GLFW's own close request surfaced and was rejected. Each then raised the same failure with no probe and no pump. The healthy control kept its compositor running, rejected an injected close request, and the probe answered healthy at all 6 boundaries of 3 pumps. No child needed its deadline. |

The D-9 test-check helpers answered unavailable, leaving no GLFW report. They
are not Wayland pass evidence.

## Unavailable experiments

Listed from D-12, verbatim, and not asserted:

| Experiment | Why it is unavailable |
| --- | --- |
| Compositor-generated close request | No client-side driver exists (D-9); programmatic closure is covered separately. |
| Size-limit read-back | `xdg_toplevel` limits are not readable from the client (D-9). |
| Minimization, suspension and occlusion evidence | Reliable observations are not established through the pinned GLFW 3.4 integration, whose direct `xdg-shell` path binds protocol version 1; newer protocol versions carry a suspended state GLFW 3.4 does not use. Report unavailable information explicitly; do not infer that a window is drawable from an unknown state. Broader compositor-specific qualification remains deferred. |

## The output

What the job printed for the group, from the helper's report to the suite's
last line, with the log's timestamps and colour codes removed and Cabal's build
lines omitted:

```text
wayland.sh: compositor weston 13.0.0 on socket hetoimasia-758 in runtime directory /tmp/hetoimasia-wayland.ljcAKq/runtime, DISPLAY and WAYLAND_SOCKET unset
validation: running test.glfw-wayland (affected) under a 1800s budget: cabal test glfw-native-tests --test-show-details=direct --test-option=--match --test-option=/GLFW native/on an isolated Wayland session/
Test suite glfw-native-tests: RUNNING...
GLFW native
  on an isolated Wayland session
    backend selection
      enters native Wayland when a session requests it, on the isolated compositor's own socket [✔]
ok   a session requesting nothing still selects X11, and with no X11 display reachable GLFW's initialization fails for that reason: an unrequested session was resolved to X11 and glfw initialize failed: X11: The DISPLAY environment variable is missing
glfw-native-tests wayland-default-x11: every check passed
      still selects X11 for a session that requests nothing, whose initialization then fails for want of an X11 display [✔]
x11.sh: display :0 on X server The X.Org Foundation, window manager "Openbox" (0x40000e), WAYLAND_DISPLAY unset
ok   a session requesting Wayland in an X11-only environment fails GLFW's initialization for lack of a Wayland connection: with X11 display :0 reachable and no Wayland socket, a Wayland request failed glfw initialize: Wayland: Failed to connect to display
glfw-native-tests wayland-without-compositor: every check passed
      fails a Wayland request under the isolated X11 helper for want of a Wayland connection [✔]
    independent window lifetimes
      closes the first of two windows and then the second, each closure retiring only its own window while the session and the other stay usable [✔]
      closes the second of two windows and then the first, each closure retiring only its own window while the session and the other stay usable [✔]
    supported controls and observations
      settles a title and a size, each observed as the native boundary reports it [✔]
      reflects showing and then hiding a window in its visibility observations [✔]
      delivers size limits and refuses an out-of-constraint size engine-side, reading nothing back from the compositor [✔]
glfw-native-tests wayland observations: before logical Observed (Extent {extentWidth = 320, extentHeight = 240}), framebuffer Observed (Extent {extentWidth = 320, extentHeight = 240}), content scale Observed (ContentScale {scaleX = 1.0, scaleY = 1.0}); after the induced resize logical Observed (Extent {extentWidth = 280, extentHeight = 210}), framebuffer Observed (Extent {extentWidth = 280, extentHeight = 210}), content scale Observed (ContentScale {scaleX = 1.0, scaleY = 1.0})
      samples framebuffer extent and content scale as observations, and the framebuffer follows a resize the example induced [✔]
    explicit unsupported outcomes
ok   answers placement, focus, and borderless requests unsupported and placement and iconified observations unavailable, invoking none of their native operations or getters: unsupported with reasons [(SetPositionOperation,"Wayland gives clients no global window position"),(FocusOperation,"Wayland lets only the compositor move input focus"),(BorderlessOperation,"Wayland gives clients no global window position")]; placement and iconified observations Unavailable; no native call among glfwSetWindowPos, glfwGetWindowPos, glfwFocusWindow, glfwSetWindowMonitor, or glfwGetWindowAttrib(GLFW_ICONIFIED)
glfw-native-tests wayland-unsupported: every check passed
      answers placement, focus, and borderless requests unsupported and placement and iconified observations unavailable, invoking none of their native operations or getters [✔]
    session wake
glfw-native-tests wake evidence: worker wake: wait 3 observed blocked before the worker's [WakePosted]; wait 3 returned woken after 0 spurious return(s), in 1.2351399999488422e-4s of a 60.0s bound
      ends a wait the owner thread entered and was blocked inside, with a worker's production wake [✔]
glfw-native-tests wake evidence: repeated wakes: wait 5 observed blocked before the worker's [WakePosted,WakePosted,WakePosted]; wait 5 returned woken after 0 spurious return(s), in 8.003899998243469e-5s of a 60.0s bound
glfw-native-tests wake evidence: next wait: wait 7 observed blocked before the worker's [WakePosted]; wait 7 returned woken after 0 spurious return(s), in 7.185600000525483e-5s of a 60.0s bound
      returns an entered wait once for repeated wakes, and leaves at most one spurious return before the next wait blocks [✔]
glfw-native-tests wake evidence: admission wake: wait 9 observed blocked before the worker's SubmitAccepted (CompletionTicket (RequestId 1)); wait 9 returned woken after 0 spurious return(s), in 1.0479100001248298e-4s of a 60.0s bound
      ends an entered wait through the production admission path, with a command a worker submitted [✔]
glfw-native-tests wake evidence: spurious wakes: wait 13 observed blocked before the worker's [WakePosted]; wait 13 returned woken after 1 spurious return(s), in 7.748499999138403e-5s of a 60.0s bound
      returns at most one wait early for spurious wakes posted while no wait was in progress [✔]
    shutdown
ok   enters and leaves a real session: backend Wayland, asynchronous reports Reports {reportedErrors = [], reportsLost = 0, callbackFaults = 0}
ok   enters a second session after a complete teardown: backend Wayland, asynchronous reports Reports {reportedErrors = [], reportsLost = 0, callbackFaults = 0}
ok   observes an initialization error before any event polling: glfw initialize failed before polling: The requested platform is not supported
ok   enters a session after the failed initialization rolled back: backend Wayland, asynchronous reports Reports {reportedErrors = [], reportsLost = 0, callbackFaults = 0}
glfw-native-tests session-lifecycle: every check passed
      fully leaves one Wayland session and enters another in a private child, while the parent's shared session serves on [✔]
    failure cleanup
ok   keeps a forced initialization failure primary, leaves no registration behind, and enters a later session: injected: a Cocoa request forced past the model's refusal failed glfw initialize with ["The requested platform is not supported"]; the rollback retained no cleanup failure and freed 1 of 1 error callback storage; a later session entered Wayland
ok   keeps an injected window-construction failure primary beside an injected cleanup failure, releases the real window and its callbacks, and creates a later window: injected construction failure primary, injected release failure retained beside it; the rollback cleared every input callback before destroying 1 of 1 real window and freed 1 of 1 callback storage; a later window was created and released, (2,2,2,2) in all
glfw-native-tests wayland-failure-cleanup: every check passed
      keeps forced and injected failures primary with their cleanup evidence, leaves nothing registered, and acquires again [✔]
    connection loss, each in a child that ends a compositor of its own
ok   confirms the loss while rejected close requests are pending, and the session is terminal: injected close requests: one rejected, one pending; compositor weston 13.0.0 ended (ExitSuccess); confirmed TransportClosed Nothing BeforeEvents: the Wayland connection's transport closed: its socket reports the peer gone, found before event processing; the session is terminal and does not reconnect; probe statuses [ConnectionHealthy,ConnectionHealthy,ConnectionEnded (TransportClosed Nothing)]; a later processing raised the same failure with no probe and no pump; the teardown after the loss reported nothing
glfw-native-tests connection-loss-pending-close: every check passed
      confirms the loss at an event boundary while injected close requests are rejected and pending, and the session is terminal [✔]
ok   confirms the loss of a session with no window, and the session is terminal: no window; compositor weston 13.0.0 ended (ExitSuccess); confirmed TransportClosed Nothing BeforeEvents: the Wayland connection's transport closed: its socket reports the peer gone, found before event processing; the session is terminal and does not reconnect; probe statuses [ConnectionHealthy,ConnectionHealthy,ConnectionEnded (TransportClosed Nothing)]; a later processing raised the same failure with no probe and no pump; the teardown after the loss reported nothing
glfw-native-tests connection-loss-no-windows: every check passed
      confirms the loss of a session with no window at an event boundary, and the session is terminal [✔]
ok   confirms a loss that happens while the owner is inside a native wait, and the session is terminal: compositor weston 13.0.0 ended (ExitSuccess) once wait 1 was observed blocked; the wait returned after 1.6067580000083126e-3s of a 30.0s bound; confirmed TransportClosed (Just 32) AfterEvents: the Wayland connection's transport closed: the display latched errno 32, found after event processing; the session is terminal and does not reconnect; GLFW's own close request surfaced and was rejected; probe statuses [ConnectionHealthy,ConnectionHealthy,ConnectionHealthy,ConnectionEnded (TransportClosed (Just 32))]; a later processing raised the same failure with no probe and no pump; the teardown after the loss reported nothing
glfw-native-tests connection-loss-in-wait: every check passed
      confirms a loss that happens while the owner is inside a native wait, after that wait returns, and the session is terminal [✔]
ok   does not mistake an injected close request on a healthy connection for loss, and the session stays live: injected close request rejected by the application; compositor weston 13.0.0 kept running; the probe answered healthy at all 6 boundaries of 3 pumps; the session stayed live and ended cleanly. This is not evidence of a compositor-generated close request.
glfw-native-tests connection-healthy-close: every check passed
      does not mistake an injected close request on a healthy connection for loss, keeping the compositor and the session [✔]
    test-check helpers
      answers both X11 test-check helpers unavailable, leaving no GLFW report [✔]
Finished in 0.7080 seconds
21 examples, 0 failures
glfw-native-tests: shared session acquired 1 time(s); owner served 13 operation(s) and declined 0; native thread checks: SetupCheck 1/1 on the process main thread, OperationCheck 13/13 on the process main thread, BeforeReleaseCheck 1/1 on the process main thread, AfterReleaseCheck 1/1 on the process main thread
Test suite glfw-native-tests: PASS
```

## Rendering

WL-4's evidence (#327, pull request
[#356](https://github.com/coghex/hetoimasia/pull/356)): the Vulkan native
suite's whole `--complete` profile on native Wayland, as the required group
`test.vulkan-wayland` ([gpu_backend.md](gpu_backend.md#the-native-suite)),
with the Wayland qualification design's D-5, D-6 and D-10.

### The run

Workflow run [36724607198, attempt 2](https://github.com/coghex/hetoimasia/actions/runs/36724607198/attempts/2),
job `vulkan`, group `test.vulkan-wayland`, for pull request #356 at commit
`a629bcb`, executed on GitHub's merge candidate `9fb8c37`. The plan step
resolved that candidate's input identity as
`a9289558af2bf4615bd590f1ea6449abc511115d1ef6f3fe8ba8bf5507350e8f`. The group's
receipt is in that attempt's `validation-receipts-vulkan` artifact as
`test.vulkan-wayland.json`, beside each private scenario's record and output
under `evidence/test.vulkan-wayland/`. It passed in 4.473 s of its 30-second
budget, the compositor's startup and teardown included, after a 1.166 s
preparation. The same job's `test.vulkan-native` passed unchanged under
`tools/display/x11.sh`, in 4.273 s of its 30. The same run's `glfw-native` job
passed `test.glfw-wayland`. Attempt 1 of the same run, at the same candidate,
had passed all three as well.

Only this record, which is Markdown no group consumes, changes after that
commit, so the run stays input-equivalent to the head it ships with:
`plan.py --base a629bcb --head HEAD` reports `test.vulkan-wayland` unaffected.
That has to be rechecked whenever the head moves for any other reason.

### Identity

| What | Value |
| --- | --- |
| Image recipe fingerprint | `ec577e83e83b888caa92189be9e727b02899a4fc95c35b72eeab1b371c34b894` (`tools/ci-image/descriptor.json`; `ci_image.py fingerprint --revision HEAD` agrees) |
| Image digest | `sha256:71ef73f2fd6432b1b70bc96dc0ab7ded728091ad76232309c7e4ec58858603cb`, verified by the job before it ran anything |
| Native manifest | `c074c480471ad2e58ccd309f18d24da736b7c61e6cf0ce92872f5b5c15287965` |
| Compositor package | Ubuntu 24.04's `weston` `13.0.0-4build3`, which reports itself as `weston 13.0.0`, headless backend |
| Selected backend | `Wayland`: the shared session's `glfwGetPlatform` answered `wayland` under the consent `isolated-wayland:hetoimasia-1910` before any example rendered, and each of the nine records whose child initializes GLFW itself notes `GLFW selected the wayland platform; the session requested Wayland` |
| Vulkan loader | `vulkan-loader` `1.3.275 e833b010f814`: `/usr/lib/x86_64-linux-gnu/libvulkan.so.1.3.275`, the address the binding and GLFW both resolve (VK-5's record) |
| Vulkan driver | `vulkan-driver` `lvp 1.4.318 9d69cae2004b`: packaged Lavapipe, `llvmpipe (LLVM 20.1.2, 256 bits)`, selected by `VK_DRIVER_FILES=/opt/hetoimasia/native/glfw/vulkan/share/vulkan/icd.d/lvp_icd.json` |
| Validation layer | `vulkan-layers` `VK_LAYER_KHRONOS_validation 1.3.275 1d486283e4ce +synchronization`, with synchronization validation |
| Toolchain | GHC 9.14.1, Cabal 3.18.1.0, `x86_64-linux`; `glslang` `15.1.0 96ea85d4228d`; `vulkan` `0a53afbd93d705f228556e9c4bbcacd4c1e0e79b1216b2c8f68458668d384a71` |
| Sources | repository revision `9fb8c37a33537dd27dafe39fc5f228ec5b6d9055`, source digest `c796580fa8835e6d26b6844919e408369e576f465376cb9bdbf4fabf5f61b102`, as the runner printed them |

The exact command, as the Vulkan worker ran it, with its `--toolchain`
arguments expanded from the run's verified toolchain file:

```bash
python3 -I tools/validation/run.py test.vulkan-wayland --plan plan.json --receipts receipts \
  --worker vulkan --runner-class cpu --runner-class display \
  --toolchain 'cabal=3.18.1.0' \
  --toolchain 'ci-image=sha256:71ef73f2fd6432b1b70bc96dc0ab7ded728091ad76232309c7e4ec58858603cb' \
  --toolchain 'ghc=9.14.1' \
  --toolchain 'glslang=15.1.0 96ea85d4228d' \
  --toolchain 'native-manifest=c074c480471ad2e58ccd309f18d24da736b7c61e6cf0ce92872f5b5c15287965' \
  --toolchain 'vulkan=0a53afbd93d705f228556e9c4bbcacd4c1e0e79b1216b2c8f68458668d384a71' \
  --toolchain 'vulkan-driver=lvp 1.4.318 9d69cae2004b' \
  --toolchain 'vulkan-layers=VK_LAYER_KHRONOS_validation 1.3.275 1d486283e4ce +synchronization' \
  --toolchain 'vulkan-loader=1.3.275 e833b010f814' \
  --toolchain 'weston=13.0.0-4build3'
```

which ran the group's preparation and then its catalog command:

```bash
bash tools/vulkan/run.sh build hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests hetoimasia-sample-triangle-app:exe:hetoimasia-triangle
bash tools/display/wayland.sh -- bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --complete
```

### Cases and outcomes

125 examples, 0 failures, 2 pending. The complete profile held: one
shared-session acquisition, every private scenario this consent requires run
and passed, and a clean verdict after the last teardown callback. No case was
skipped or reported unperformed; the two pending examples name their reasons
below.

| Case | Outcome |
| --- | --- |
| Consent | Passed, without a session. `isolated-wayland:<socket>` was accepted on Linux with a matching `WAYLAND_DISPLAY` and no `DISPLAY`. It was refused on macOS, beside a `DISPLAY` (set or empty), and for a socket `WAYLAND_DISPLAY` does not name. Under it every session requests Wayland by name. |
| Shared roots | Passed, 8 examples. GLFW selected Wayland before any example rendered. The instance, messenger, one device and every surface's destruction ran on the graphics owner's thread, and every surface's creation on the main thread. VK-10's generation was 160×120 with 5 images of format 50; a resize replaced it, and a lost surface was replaced through the bridge. The session made 193 native calls, destroyed everything surface, device, messenger, instance, and its verdict was clean with 89 records delivered. |
| VK-2 | Passed. Compatibility profile, presentation completion, safe abandonment and capture. |
| VK-5 | Passed. The loader-aware session copied `VK_KHR_surface, VK_KHR_wayland_surface`, created a surface on a Wayland window through the bridge, and discharged it off the owner thread. The failed initialization requested Wayland against an absent socket and failed with `Wayland: Failed to connect to display`, restoring the shim's default. |
| VK-6, VK-7 | Passed. The C-only capture, and the roots under the graphics owner through their destruction at the host's exit. |
| VK-11, VK-12 | Passed. Recording and discarding a batch; frames acquired, submitted and awaited without presenting. |
| VK-13 | Passed. Presentations to two Wayland windows, each retired on its own present fence. A resized generation was held by its presentation and destroyed at the first generation step after that retirement was observed; the first window was retired while the second presented. |
| VK-14 | Passed. A lost surface was replaced on its live window while the other presented, with 12 frames in all, and an allocation was recovered by reclaiming a retired generation. |
| VK-15 | Passed. The validation stop, and the deliberate retention ending by process termination, under their documented contracts. |
| VK-16 | **Pending, not qualified on Wayland**; see below. |
| VK-17, one and two frame slots | Passed. The triangle sample in two windows, each captured: background `(63,63,124,255)` and triangle `(243,203,89,255)`. The first window was captured again at 200×150 after its resize, and the second after the first closed. |
| VK-19 | Passed. A consumer-built triangle captured from two targets, each beside its frame's verified presentation: background `(0,0,255,255)`, triangle `(255,187,0,255)`. |
| Synchronization control, debug names | Passed. `SYNC-HAZARD-WRITE-AFTER-WRITE` observed as provoked, and the named resource and label carried into the capture. |
| Connection loss | Passed, in a child with a Weston of its own. A presentation retired on its present fence before the compositor was ended; the compositor exited `ExitSuccess`. The application ended with `TransportClosed Nothing` found before event processing, and no surface was created afterwards. The one presentation the owner made after the loss retired on a genuine present fence, which is kept, not discarded. Every retirement and completion belonged to a presentation or submission the owner made. The one swapchain was destroyed and the verdict was clean, with no error. |
| Interaction probe | Pending, as everywhere: it is optional and needs a person at the desktop. |

### What stays unqualified

- **Hiding a presenting window.** VK-16's `vk16-composed` is pending under this
  consent, by the owner's decision on #327. It hides one of two presenting
  windows, and in three runs of three the graphics owner then blocked. Weston
  13 offers no `wp_fifo_v1`, so Mesa 25.2.8's Wayland WSI throttles FIFO with
  frame callbacks: each present waits, with no timeout, for the previous one's
  callback. Weston sends a frame callback only for a surface on an output, so
  the present after GLFW unmaps the hidden window never returns. The loop's own
  notes stopped at `both targets presented three frames (3,3); hiding the first
  window`. This is an engine gap on Wayland, tracked as
  [#357](https://github.com/coghex/hetoimasia/issues/357); it passes under
  `test.vulkan-native`. *Since closed: [Hiding a presenting
  window](#hiding-a-presenting-window) retains the run that qualifies it. This
  run's results above are unchanged.*
- **Hardware drivers, desktop compositors and macOS.** Only packaged Lavapipe
  under packaged headless Weston was exercised. No hardware driver, no other
  compositor, and no macOS path was involved, and macOS has no Wayland.

One earlier run of the connection-loss case, at `4b2207a` (workflow run
36687300253), latched one validation error. Its verdict was `[ErrorLatched]`
with one error report; its other checks passed. That loss had been reported as
`TransportClosed (Just 32)`, with `EPIPE` latched, rather than as a bare
hangup. That revision did not record the error's text, and the case's path has
not changed since. The four later runs whose verdicts were read, this one among
them, were clean. The record now names every error the case sees, so a
recurrence says what it was.

### The output

What the job printed for the group, from the runner's first line to its last,
with the log's timestamps and colour codes removed:

```text
validation: running test.vulkan-wayland (affected) under a 30s budget: bash tools/display/wayland.sh -- bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --complete
wayland.sh: compositor weston 13.0.0 on socket hetoimasia-1910 in runtime directory /tmp/hetoimasia-wayland.IABeKo/runtime, DISPLAY and WAYLAND_SOCKET unset
vulkan: ghc 9.14.1, cabal 3.18.1.0
vulkan: native prefix /opt/hetoimasia/native/glfw
vulkan: VK_DRIVER_FILES=/opt/hetoimasia/native/glfw/vulkan/share/vulkan/icd.d/lvp_icd.json
vulkan: VK_LAYER_PATH=/opt/hetoimasia/native/glfw/vulkan/share/vulkan/explicit_layer.d
vulkan: validation features synchronization
vulkan: repository revision 9fb8c37a33537dd27dafe39fc5f228ec5b6d9055
vulkan: source digest c796580fa8835e6d26b6844919e408369e576f465376cb9bdbf4fabf5f61b102
vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates

Vulkan native
  the native opt-in
    accepts the desktop opt-in for one run, on either platform [✔]
    accepts an isolated X11 display only on Linux, and only for the display it names [✔]
    accepts an isolated Wayland socket only on Linux, only for the socket WAYLAND_DISPLAY names, and never beside a DISPLAY [✔]
    requests Wayland by name under the isolated compositor's consent, and nothing under any other [✔]
    takes nothing else as consent: an unset or empty variable, another value, a bare DISPLAY or WAYLAND_DISPLAY, or CI [✔]
  without a native session
    A whole run
      releases the same ten entries, in the same order [✔]
      retains nothing and destroys every handle in plan order [✔]
      counts the boundary as an entry that ran and not as a handle destroyed [✔]
      reports the ordinary destruction rules, not device loss [✔]
    A present fence that times out
      retains that slot's present fence and presentation semaphore, the swapchain, and every parent above them [✔]
      destroys only what does not depend on the unretired present [✔]
      names the reason on each retained handle [✔]
      is not device loss, however long the wait went unsatisfied [✔]
    A teardown boundary that fails without device loss
      prohibits every release whose safety the boundary was to establish [✔]
      reports the boundary failure as the reason rather than a presentation [✔]
      is not discharged by a later valid present fence [✔]
    Later valid present-fence evidence
      permits ordered release once the fence signals during teardown [✔]
    Device loss
      permits destruction under the specification's own rule [✔]
      is never reached by promoting a timeout to it [✔]
      is established by the boundary alone as readily as by a fence [✔]
    A present rejected out-of-date or surface-lost
      counts its enqueued operations and holds the slot [✔]
      releases the slot only on the fence, never on the error result [✔]
      creates no obligation for the specified no-effect results [✔]
    An exception in place of a result
      classifies a thrown Vulkan result as that result [✔]
      treats an exception carrying no result as evidence of nothing [✔]
      treats a boundary that threw as a boundary that failed [✔]
    A run that stopped before the boundary was registered
      releases what it registered [✔]
      still withholds when a registered boundary reached no result at all [✔]
    A recycled slot
      is not discharged by the completion of the present before it [✔]
    The record a stopped run renders
      keeps the failing step and the failed verdict [✔]
      renders the retained handles, their reasons, and the disposition [✔]
      still claims nothing the run did not establish [✔]
    A frame slot whose construction stops
      releases every child it created when step 0 fails [✔]
      releases every child it created when step 1 fails [✔]
      releases every child it created when step 2 fails [✔]
      releases every child it created when step 3 fails [✔]
      releases every child it created when step 4 fails [✔]
      releases every child it created when step 5 fails [✔]
      releases every child it created when step 6 fails [✔]
      releases every child it created when step 7 fails [✔]
      releases every child it created when step 8 fails [✔]
      releases every child it created when step 9 fails [✔]
      releases every child it created when step 10 fails [✔]
      releases every child it created when step 11 fails [✔]
      creates exactly the prefix of children the failing step allows [✔]
      destroys a slot's children in dependency order [✔]
      owns a command buffer through its command pool rather than separately [✔]
      never destroys a handle the failing step never created [✔]
    A cleanup entry that holds nothing
      is neither destroyed nor retained when the construction created nothing [✔]
      names only the children a partial construction actually created [✔]
      does not claim a capture handle a stopped capture never created [✔]
      does not retain an empty place when the boundary failed [✔]
    A release that fails under device loss
      still withholds the parents that must outlive what may have survived [✔]
    A cleanup entry that owns several children
      records every failure, not only the first [✔]
      still names the sibling that was destroyed [✔]
      is not reported as an entry that released [✔]
    The capture freeing its own handles
      leaves a failed self-release visible to teardown [✔]
      withholds the device over what may have survived [✔]
      does not retry the destroy that failed, and finishes the buffer [✔]
    A swapchain whose construction stops after it exists
      releases it before the device when the step after its creation fails [✔]
    A cancellation at the acquisition-to-registration handoff
      leaves the handle owned rather than orphaned [✔]
    A release that fails while a construction failure is being handled
      keeps the primary failure and records the release failure beside it [✔]
      continues the independent releases and retries none of them [✔]
      withholds the parents that must outlive what may have survived [✔]
      renders both failures in the record a stopped run writes [✔]
    The capture path
      owns both handles when it stops while creating the buffer [✔]
      owns both handles when it stops while allocating the memory [✔]
      owns both handles when it stops while binding the memory [✔]
      owns both handles when it stops while acquiring the image [✔]
      owns both handles when it stops while submitting the copy [✔]
      owns both handles when it stops while waiting for the copy to complete [✔]
      owns both handles when it stops while mapping the memory [✔]
      owns both handles when it stops while presenting [✔]
      frees the memory before the buffer, as the successful path does [✔]
      destroys neither handle when it never created it [✔]
      reports both handles as destroyed rather than only as entries [✔]
      retains both when the boundary established no completion for the copy [✔]
      is not held by an unretired present, which touches neither handle [✔]
    A run that completes
      frees the capture's two handles itself, exactly once [✔]
      arrives at teardown holding neither of them [✔]
      builds both whole slots and releases each child once [✔]
      releases the same ten entries, in the same order [✔]
      destroys every object it created, exactly once and before its device [✔]
    A cancellation taken at the present handoff
      records the presentation the enqueue created before it is taken [✔]
      preserves the result the present reported rather than the exception that stopped the run [✔]
      stops the run at the presentation step, carrying the cancellation's own failure [✔]
      keeps teardown's own boundary and fence-wait observations beside it [✔]
      retains the slot's present fence and presentation semaphore, the swapchain, and every parent [✔]
      names each retained handle and why it was retained [✔]
    A cancellation at the handoff of a recycled slot
      records the new present rather than carrying the retired one forward [✔]
      reopens the obligation the earlier present's completion had closed [✔]
      retains exactly what the fresh slot's cancellation retains [✔]
    A present handoff no cancellation reaches
      records the result and returns, exactly as it did before [✔]
      leaves the caller unmasked, so the waits after it are as interruptible as ever [✔]
      keeps the classification of a call that threw [✔]
    The loaded Vulkan loader
      accepts the recorded loader [✔]
      refuses an alternate loader found ahead of it on the search path, naming both [✔]
      refuses a run whose runner named no recorded loader [✔]
      refuses an entry point attributed to no image [✔]
  the shared roots
    entered GLFW on the backend the run's consent names, before any example renders [✔]
    runs every dispatched operation on the process main thread that entered the session [✔]
    creates the instance and its explicit messenger on the graphics owner's thread, never the main thread [✔]
    hands two windows over as required targets on one shared device, and keeps the roots live when the first-created closes [✔]
    VK-10 generation: 160x120 from ExtentFromObservation, window 160x120 at content scale 1.0, 5 images of format 50
    builds a generation on the owner's thread from the surface's extent and the profile's format, the framebuffer's pixels rather than the window's size [✔]
    replaces a generation after a resize through the main-thread dispatch, retiring the old one only after its hold ends [✔]
    replaces a lost surface through the bridge on the main thread under the same attachment, leaving another window's target presenting [✔]
    serves a later example's target from the same device [✔]
  with private roots in a child process
    proves the VK-2 compatibility profile, presentation completion, safe abandonment and capture [✔]
    proves VK-6's C-only validation capture on an instance of its own [✔]
    proves VK-5's loader-aware surface bridge in a session of its own [✔]
    proves VK-7's roots under the graphics owner, through their destruction at the host's exit [✔]
    records and discards a triangle batch through VK-11's managed resources, with validation reporting nothing [✔]
    acquires, submits and awaits a triangle batch with its capture, and returns images without presenting, with validation reporting nothing [✔]
    presents to two windows on verified present fences, retires a resized generation and the first window on that evidence, with validation reporting nothing [✔]
    replaces a lost surface on its live window while another presents, and recovers an allocation by reclaiming a retired generation, with validation reporting nothing [✔]
    stops rendering at the checkpoint after an injected validation error, tearing down under the ordinary rules with the error as the primary and the final callbacks in the verdict [✔]
    reports a deliberately retained unverified generation and its parents rather than releasing them, and ends by process termination [✔]
    renders two targets through the composed loop, suspending and resuming one while the other presents, and exits through D-33 with validation reporting nothing [‐]
      # PENDING: not qualified on Wayland: hiding a window whose target is presenting blocks the graphics owner, because Mesa's legacy FIFO waits for a frame callback the compositor never sends an unmapped surface (Weston 13 has no wp_fifo_v1); an engine gap tracked apart from #327
    renders the triangle sample in two windows with one frame slot, capturing each, the first again after its resize, and the second after the first closes, with validation reporting nothing [✔]
    renders the triangle sample in two windows with two frame slots, capturing each, the first again after its resize, and the second after the first closes, with validation reporting nothing [✔]
    captures a consumer-built triangle from two targets through the production host, each beside its frame's verified presentation, with validation reporting nothing [✔]
    observes a deliberate synchronization hazard, proving synchronization validation active [✔]
    carries a provoked validation report's named managed resource, and its batch's label, into the capture [✔]
    ends its own compositor while the production host renders to a Wayland surface, and the session ends terminally with the loss, retired under the protected boundary with no completion recorded for interrupted work [✔]
  graphics-owner progress during window interactions
    records the native pump, the callbacks inside it, owner turns, and the graphics owner's present requests and present-fence completions while a person moves, resizes, and uses the menu bar [‐]
      # PENDING: the graphics-owner interaction probe runs only when HETOIMASIA_INTERACTION_PROBE_SECONDS names the seconds each phase lasts, and it needs a person at the desktop

Finished in 3.3358 seconds
125 examples, 0 failures, 2 pending
vulkan-native-tests: shared session acquisitions: 1
vulkan-native-tests: shared session native calls: 193
vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan-native-tests: shared session verdict: clean, 89 records delivered
vulkan-native-tests: private debug-names: ExitSuccess in 0.110879348s
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 0.10481257s
vulkan-native-tests: private vk11-recording: ExitSuccess in 0.111094091s
vulkan-native-tests: private vk12-frames: ExitSuccess in 0.111089203s
vulkan-native-tests: private vk13-presentation: ExitSuccess in 0.32218164s
vulkan-native-tests: private vk14-recovery: ExitSuccess in 0.332254755s
vulkan-native-tests: private vk15-retention: ExitSuccess in 9.9936223e-2s
vulkan-native-tests: private vk15-validation-stop: ExitSuccess in 0.119149569s
vulkan-native-tests: private vk17-one-slot: ExitSuccess in 0.174498783s
vulkan-native-tests: private vk17-two-slots: ExitSuccess in 0.177396712s
vulkan-native-tests: private vk19-capture: ExitSuccess in 0.14352958s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.265676445s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 3.5835783e-2s
vulkan-native-tests: private vk6-capture: ExitSuccess in 0.10714835s
vulkan-native-tests: private vk7-roots: ExitSuccess in 0.119826386s
vulkan-native-tests: private wayland-connection-loss: ExitSuccess in 0.32821068s
vulkan-native-tests: the process ran for 3.364540535s, fixtures, examples and teardown included
validation: test.vulkan-wayland passed after 4.5s (exit 0); receipt receipts/test.vulkan-wayland.json
```

## Hiding a presenting window

The run [#357](https://github.com/coghex/hetoimasia/issues/357) requires:
VK-16's `vk16-composed`, which hides one of two presenting windows and shows it
again, run and passed under the isolated compositor's consent, where WL-4's run
left it pending. The engine change it qualifies is the presentation hold a hide
takes before its native call and the replacement a resumed target is given
([gpu_backend.md](gpu_backend.md#pacing-suspension-and-fairness),
[glfw.md](glfw.md#hiding-an-attached-window)). The same run's
`test.vulkan-native` is the X11 regression; the Cocoa one was run on the
owner's machine.

### The run

Workflow run [36747611445](https://github.com/coghex/hetoimasia/actions/runs/36747611445),
attempt 1, job `vulkan`, group `test.vulkan-wayland`, for pull request
[#359](https://github.com/coghex/hetoimasia/pull/359) at commit `1cd3c3f`,
executed on GitHub's merge candidate `a6642f4`. The plan resolved the
candidate's input identity as
`24e84bd58a620fbc0a1956545c001d787ce492a193dc7afd9d23758436007564`, under
catalog policy version 23. The group passed in 4.473 s of its 30-second budget;
its receipt, `test.vulkan-wayland.json`, and every private case's record are in
that run's `validation-receipts-vulkan` artifact. An earlier run of the same
case at `ac0b65c`, before review narrowed which step a hide waits for
(run 36742775061), passed with the same VK-16 counts.

Only this record, which is Markdown no group consumes, changes after that
commit, so the run stays input-equivalent to the head it ships with:
`plan.py --base 1cd3c3f --head HEAD` reports `test.vulkan-wayland` unaffected.
That has to be rechecked whenever the head moves for any other reason.

### Identity

| What | Value |
| --- | --- |
| Image recipe fingerprint | `ec577e83e83b888caa92189be9e727b02899a4fc95c35b72eeab1b371c34b894` (`tools/ci-image/descriptor.json`, unchanged since WL-4's run) |
| Image digest | `sha256:71ef73f2fd6432b1b70bc96dc0ab7ded728091ad76232309c7e4ec58858603cb`, verified by the job before it ran anything |
| Native manifest | `c074c480471ad2e58ccd309f18d24da736b7c61e6cf0ce92872f5b5c15287965` |
| Compositor package | Ubuntu 24.04's `weston` `13.0.0-4build3`, which reports itself as `weston 13.0.0`, headless backend, offering no `wp_fifo_v1` |
| Selected backend | `Wayland`, under the consent `isolated-wayland:hetoimasia-2177`, asserted by the shared session before any example rendered |
| Vulkan loader | `vulkan-loader` `1.3.275 e833b010f814` |
| Vulkan driver | `vulkan-driver` `lvp 1.4.318 9d69cae2004b`: packaged Lavapipe, whose Wayland WSI throttles FIFO with frame callbacks there |
| Validation layer | `vulkan-layers` `VK_LAYER_KHRONOS_validation 1.3.275 1d486283e4ce +synchronization`, with synchronization validation |
| Toolchain | GHC 9.14.1, Cabal 3.18.1.0, `x86_64-linux`; `glslang` `15.1.0 96ea85d4228d`; `vulkan` `0a53afbd93d705f228556e9c4bbcacd4c1e0e79b1216b2c8f68458668d384a71` |
| Sources | repository revision `a6642f482e8466f000cc82b463fda6c20b353413`, source digest `574f82589dae94bca81af78dd15c98cd7b5ff338e5c074030bff9daef4f71f4c`, as the runner printed them |

The group's preparation and command were WL-4's, under the same `--toolchain`
arguments:

```bash
bash tools/vulkan/run.sh build hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests hetoimasia-sample-triangle-app:exe:hetoimasia-triangle
bash tools/display/wayland.sh -- bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --complete
```

### Cases and outcomes

125 examples, 0 failures, 1 pending: the optional interaction probe, as
everywhere. Every private scenario this consent requires ran and passed,
`vk16-composed` now among them, and every other case passed as in WL-4's run.

VK-16's own record, from each run's evidence, beside the two regressions:

| | Wayland (`test.vulkan-wayland`) | X11 (`test.vulkan-native`, same run) | Cocoa (owner's machine) |
| --- | --- | --- | --- |
| Revision | candidate `a6642f4` | candidate `a6642f4` | `1cd3c3f` |
| Group outcome | 125 examples, 0 failures, 1 pending | 125 examples, 0 failures, 2 pending | 125 examples, 0 failures, 2 pending |
| Frames before the hide (first, second) | (4, 4) | (3, 4) | (4, 4) |
| Hide settled as attempted, window observed hidden, target suspended | yes | yes | yes |
| Frames while hidden (first, second) | (0, 3) | (0, 3) | (0, 3) |
| First target's frames from the hide's settlement until the show | 0 | 0 | 0 |
| First target's frames once shown again, after the show settled and the window was observed visible | 1 | 1 | 1 |
| Swapchains created: one per window and the shown window's replacement | 3 | 3 | 3 |
| Presentations made / retired on their own present fences | 16 / 16 | 13 / 13 | 16 / 16 |
| Vulkan calls, and the threads they ran on | 295, one | 253, one | 328, one |
| Verdict issues, error reports | none, 0 | none, 0 | none, 0 |

X11's and Cocoa's second pending example is `wayland-connection-loss`, which
runs only under this consent. The Cocoa run was
`HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --complete`
on macOS with MoltenVK, under the owner's standing approval.

The Wayland case's transcript, from its record:

```text
## VK-16: two targets rendered through the composed loop, one suspended and resumed while the other presents
both targets presented three frames (3,3); hiding the first window
the hide settled as attempted at (4,4)
the first window is observed hidden and its target suspended at (4,4)
the second target presented three more frames (4,7); showing the first window
the show settled as attempted and the first window is observed visible at (4,7)
the first target presented again (5,9)
presented 16 frames; 16 presentations retired on their present fences
```

### The output

What the job printed for the group, from the runner's first line to its last,
with the log's timestamps and colour codes removed:

```text
validation: running test.vulkan-wayland (affected) under a 30s budget: bash tools/display/wayland.sh -- bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --complete
wayland.sh: compositor weston 13.0.0 on socket hetoimasia-2177 in runtime directory /tmp/hetoimasia-wayland.8gmp53/runtime, DISPLAY and WAYLAND_SOCKET unset
vulkan: ghc 9.14.1, cabal 3.18.1.0
vulkan: native prefix /opt/hetoimasia/native/glfw
vulkan: VK_DRIVER_FILES=/opt/hetoimasia/native/glfw/vulkan/share/vulkan/icd.d/lvp_icd.json
vulkan: VK_LAYER_PATH=/opt/hetoimasia/native/glfw/vulkan/share/vulkan/explicit_layer.d
vulkan: validation features synchronization
vulkan: repository revision a6642f482e8466f000cc82b463fda6c20b353413
vulkan: source digest 574f82589dae94bca81af78dd15c98cd7b5ff338e5c074030bff9daef4f71f4c
vulkan-native-tests: implicit-layer policy: VK_LOADER_LAYERS_DISABLE=~implicit~, so no implicit layer joins the chain and the explicit layers below are all of it
vulkan-native-tests: layer settings: VK_LAYER_SETTINGS_PATH=/dev/null, so no settings file decides what the layer validates

Vulkan native
  the native opt-in
    accepts the desktop opt-in for one run, on either platform [✔]
    accepts an isolated X11 display only on Linux, and only for the display it names [✔]
    accepts an isolated Wayland socket only on Linux, only for the socket WAYLAND_DISPLAY names, and never beside a DISPLAY [✔]
    requests Wayland by name under the isolated compositor's consent, and nothing under any other [✔]
    takes nothing else as consent: an unset or empty variable, another value, a bare DISPLAY or WAYLAND_DISPLAY, or CI [✔]
  without a native session
    A whole run
      releases the same ten entries, in the same order [✔]
      retains nothing and destroys every handle in plan order [✔]
      counts the boundary as an entry that ran and not as a handle destroyed [✔]
      reports the ordinary destruction rules, not device loss [✔]
    A present fence that times out
      retains that slot's present fence and presentation semaphore, the swapchain, and every parent above them [✔]
      destroys only what does not depend on the unretired present [✔]
      names the reason on each retained handle [✔]
      is not device loss, however long the wait went unsatisfied [✔]
    A teardown boundary that fails without device loss
      prohibits every release whose safety the boundary was to establish [✔]
      reports the boundary failure as the reason rather than a presentation [✔]
      is not discharged by a later valid present fence [✔]
    Later valid present-fence evidence
      permits ordered release once the fence signals during teardown [✔]
    Device loss
      permits destruction under the specification's own rule [✔]
      is never reached by promoting a timeout to it [✔]
      is established by the boundary alone as readily as by a fence [✔]
    A present rejected out-of-date or surface-lost
      counts its enqueued operations and holds the slot [✔]
      releases the slot only on the fence, never on the error result [✔]
      creates no obligation for the specified no-effect results [✔]
    An exception in place of a result
      classifies a thrown Vulkan result as that result [✔]
      treats an exception carrying no result as evidence of nothing [✔]
      treats a boundary that threw as a boundary that failed [✔]
    A run that stopped before the boundary was registered
      releases what it registered [✔]
      still withholds when a registered boundary reached no result at all [✔]
    A recycled slot
      is not discharged by the completion of the present before it [✔]
    The record a stopped run renders
      keeps the failing step and the failed verdict [✔]
      renders the retained handles, their reasons, and the disposition [✔]
      still claims nothing the run did not establish [✔]
    A frame slot whose construction stops
      releases every child it created when step 0 fails [✔]
      releases every child it created when step 1 fails [✔]
      releases every child it created when step 2 fails [✔]
      releases every child it created when step 3 fails [✔]
      releases every child it created when step 4 fails [✔]
      releases every child it created when step 5 fails [✔]
      releases every child it created when step 6 fails [✔]
      releases every child it created when step 7 fails [✔]
      releases every child it created when step 8 fails [✔]
      releases every child it created when step 9 fails [✔]
      releases every child it created when step 10 fails [✔]
      releases every child it created when step 11 fails [✔]
      creates exactly the prefix of children the failing step allows [✔]
      destroys a slot's children in dependency order [✔]
      owns a command buffer through its command pool rather than separately [✔]
      never destroys a handle the failing step never created [✔]
    A cleanup entry that holds nothing
      is neither destroyed nor retained when the construction created nothing [✔]
      names only the children a partial construction actually created [✔]
      does not claim a capture handle a stopped capture never created [✔]
      does not retain an empty place when the boundary failed [✔]
    A release that fails under device loss
      still withholds the parents that must outlive what may have survived [✔]
    A cleanup entry that owns several children
      records every failure, not only the first [✔]
      still names the sibling that was destroyed [✔]
      is not reported as an entry that released [✔]
    The capture freeing its own handles
      leaves a failed self-release visible to teardown [✔]
      withholds the device over what may have survived [✔]
      does not retry the destroy that failed, and finishes the buffer [✔]
    A swapchain whose construction stops after it exists
      releases it before the device when the step after its creation fails [✔]
    A cancellation at the acquisition-to-registration handoff
      leaves the handle owned rather than orphaned [✔]
    A release that fails while a construction failure is being handled
      keeps the primary failure and records the release failure beside it [✔]
      continues the independent releases and retries none of them [✔]
      withholds the parents that must outlive what may have survived [✔]
      renders both failures in the record a stopped run writes [✔]
    The capture path
      owns both handles when it stops while creating the buffer [✔]
      owns both handles when it stops while allocating the memory [✔]
      owns both handles when it stops while binding the memory [✔]
      owns both handles when it stops while acquiring the image [✔]
      owns both handles when it stops while submitting the copy [✔]
      owns both handles when it stops while waiting for the copy to complete [✔]
      owns both handles when it stops while mapping the memory [✔]
      owns both handles when it stops while presenting [✔]
      frees the memory before the buffer, as the successful path does [✔]
      destroys neither handle when it never created it [✔]
      reports both handles as destroyed rather than only as entries [✔]
      retains both when the boundary established no completion for the copy [✔]
      is not held by an unretired present, which touches neither handle [✔]
    A run that completes
      frees the capture's two handles itself, exactly once [✔]
      arrives at teardown holding neither of them [✔]
      builds both whole slots and releases each child once [✔]
      releases the same ten entries, in the same order [✔]
      destroys every object it created, exactly once and before its device [✔]
    A cancellation taken at the present handoff
      records the presentation the enqueue created before it is taken [✔]
      preserves the result the present reported rather than the exception that stopped the run [✔]
      stops the run at the presentation step, carrying the cancellation's own failure [✔]
      keeps teardown's own boundary and fence-wait observations beside it [✔]
      retains the slot's present fence and presentation semaphore, the swapchain, and every parent [✔]
      names each retained handle and why it was retained [✔]
    A cancellation at the handoff of a recycled slot
      records the new present rather than carrying the retired one forward [✔]
      reopens the obligation the earlier present's completion had closed [✔]
      retains exactly what the fresh slot's cancellation retains [✔]
    A present handoff no cancellation reaches
      records the result and returns, exactly as it did before [✔]
      leaves the caller unmasked, so the waits after it are as interruptible as ever [✔]
      keeps the classification of a call that threw [✔]
    The loaded Vulkan loader
      accepts the recorded loader [✔]
      refuses an alternate loader found ahead of it on the search path, naming both [✔]
      refuses a run whose runner named no recorded loader [✔]
      refuses an entry point attributed to no image [✔]
  the shared roots
    entered GLFW on the backend the run's consent names, before any example renders [✔]
    runs every dispatched operation on the process main thread that entered the session [✔]
    creates the instance and its explicit messenger on the graphics owner's thread, never the main thread [✔]
    hands two windows over as required targets on one shared device, and keeps the roots live when the first-created closes [✔]
    VK-10 generation: 160x120 from ExtentFromObservation, window 160x120 at content scale 1.0, 5 images of format 50
    builds a generation on the owner's thread from the surface's extent and the profile's format, the framebuffer's pixels rather than the window's size [✔]
    replaces a generation after a resize through the main-thread dispatch, retiring the old one only after its hold ends [✔]
    replaces a lost surface through the bridge on the main thread under the same attachment, leaving another window's target presenting [✔]
    serves a later example's target from the same device [✔]
  with private roots in a child process
    proves the VK-2 compatibility profile, presentation completion, safe abandonment and capture [✔]
    proves VK-6's C-only validation capture on an instance of its own [✔]
    proves VK-5's loader-aware surface bridge in a session of its own [✔]
    proves VK-7's roots under the graphics owner, through their destruction at the host's exit [✔]
    records and discards a triangle batch through VK-11's managed resources, with validation reporting nothing [✔]
    acquires, submits and awaits a triangle batch with its capture, and returns images without presenting, with validation reporting nothing [✔]
    presents to two windows on verified present fences, retires a resized generation and the first window on that evidence, with validation reporting nothing [✔]
    replaces a lost surface on its live window while another presents, and recovers an allocation by reclaiming a retired generation, with validation reporting nothing [✔]
    stops rendering at the checkpoint after an injected validation error, tearing down under the ordinary rules with the error as the primary and the final callbacks in the verdict [✔]
    reports a deliberately retained unverified generation and its parents rather than releasing them, and ends by process termination [✔]
    renders two targets through the composed loop, suspending and resuming one while the other presents, and exits through D-33 with validation reporting nothing [✔]
    renders the triangle sample in two windows with one frame slot, capturing each, the first again after its resize, and the second after the first closes, with validation reporting nothing [✔]
    renders the triangle sample in two windows with two frame slots, capturing each, the first again after its resize, and the second after the first closes, with validation reporting nothing [✔]
    captures a consumer-built triangle from two targets through the production host, each beside its frame's verified presentation, with validation reporting nothing [✔]
    observes a deliberate synchronization hazard, proving synchronization validation active [✔]
    carries a provoked validation report's named managed resource, and its batch's label, into the capture [✔]
    ends its own compositor while the production host renders to a Wayland surface, and the session ends terminally with the loss, retired under the protected boundary with no completion recorded for interrupted work [✔]
  graphics-owner progress during window interactions
    records the native pump, the callbacks inside it, owner turns, and the graphics owner's present requests and present-fence completions while a person moves, resizes, and uses the menu bar [‐]
      # PENDING: the graphics-owner interaction probe runs only when HETOIMASIA_INTERACTION_PROBE_SECONDS names the seconds each phase lasts, and it needs a person at the desktop

Finished in 3.4027 seconds
125 examples, 0 failures, 1 pending
vulkan-native-tests: shared session acquisitions: 1
vulkan-native-tests: shared session native calls: 193
vulkan-native-tests: shared session destruction: vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroyImageView, vkDestroySwapchainKHR, vkDestroySurfaceKHR, vkDestroySurfaceKHR, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
vulkan-native-tests: shared session verdict: clean, 89 records delivered
vulkan-native-tests: private debug-names: ExitSuccess in 9.3892314e-2s
vulkan-native-tests: private synchronization-hazard: ExitSuccess in 8.7871116e-2s
vulkan-native-tests: private vk11-recording: ExitSuccess in 9.5278589e-2s
vulkan-native-tests: private vk12-frames: ExitSuccess in 9.4116912e-2s
vulkan-native-tests: private vk13-presentation: ExitSuccess in 0.304684684s
vulkan-native-tests: private vk14-recovery: ExitSuccess in 0.305319399s
vulkan-native-tests: private vk15-retention: ExitSuccess in 8.0869606e-2s
vulkan-native-tests: private vk15-validation-stop: ExitSuccess in 9.4009019e-2s
vulkan-native-tests: private vk16-composed: ExitSuccess in 0.319354051s
vulkan-native-tests: private vk17-one-slot: ExitSuccess in 0.150402995s
vulkan-native-tests: private vk17-two-slots: ExitSuccess in 0.179391506s
vulkan-native-tests: private vk19-capture: ExitSuccess in 0.115500093s
vulkan-native-tests: private vk2-compatibility: ExitSuccess in 0.253164305s
vulkan-native-tests: private vk5-bridge: ExitSuccess in 2.7538035e-2s
vulkan-native-tests: private vk6-capture: ExitSuccess in 8.8852647e-2s
vulkan-native-tests: private vk7-roots: ExitSuccess in 9.8298647e-2s
vulkan-native-tests: private wayland-connection-loss: ExitSuccess in 0.312794804s
vulkan-native-tests: the process ran for 3.428806328s, fixtures, examples and teardown included
validation: test.vulkan-wayland passed after 4.5s (exit 0); receipt receipts/test.vulkan-wayland.json
```
