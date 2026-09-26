# Native Wayland qualification: the retained run

The record WL-3 (#207) requires: the run that established the headless native
Wayland profile [glfw.md](glfw.md#wayland) states, kept verbatim because a
run's own output is the evidence and a CI log that expires is not a record. It
names what ran, where, and on what, and lists the experiments the Wayland
qualification design's D-12 declares unavailable, which are listed here and
never asserted.

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
