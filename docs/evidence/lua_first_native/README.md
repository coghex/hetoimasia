# LFE-25 evidence: the Lua quad on real windows

Retained evidence for [#540](https://github.com/coghex/hetoimasia/issues/540) (epic #514, LFE-25). It shows what real native
windows presented on the isolated Linux X11 display for the shipped `samples/lua-quad` content: through the actual built command and
through the two-instance harness composed over the public interfaces. **The images are technical test assets (the 8 x 8 technical
fixture of `samples/lua-quad`), not production art.** A capture is what a window presented; it is never evidence of GPU
retirement, which these cases establish only through the host's and the adapter's own readings. The macOS entries are **pending**:
there is no OS capture on macOS, and the owner's visual confirmations are owed ([the pending record](macos-owner-confirmations.md)).
What each completion condition and slice of the epic rests on is in [the coverage document](coverage.md).

## Identities (Linux)

| | |
| --- | --- |
| Producer | the group `test.vulkan-run-native`, command `bash tools/vulkan/run.sh native hetoimasia:test:run-native-tests -- --complete`, prepared by `bash tools/vulkan/run.sh build hetoimasia:exe:hetoimasia hetoimasia:test:run-native-tests` (the `Lua native milestone` subgroup is selectable alone with `--match 'Lua native milestone'`) |
| Receipt | [`receipts/test.vulkan-run-native.json` of the pull request's CI run](https://github.com/coghex/hetoimasia/actions/runs/41328611256/attempts/1), outcome `passed`, 8.732 s of its 30 s budget; 35 examples, 0 failures ([the run's own record](linux/run-native.md)) |
| Code | pull request head `25886dca9444a66ed6b1c0ccfbbba6002f47c872`, executed as the merged candidate commit `c4a88ca8741ab99b6fbd977c0333ddba5e7bf357` (tree `0fb26d68c77dbd659f4078d9b843a83ab92d3363`) |
| Runner | Linux X64, runner class `display`; CI image `sha256:71ef73f2fd6432b1b70bc96dc0ab7ded728091ad76232309c7e4ec58858603cb` |
| Display | an isolated Xvfb (1280 x 1024 x 24) with the Openbox window manager that `tools/display/x11.sh` starts for the one command; no compositor; no colour management |
| Device, loader, layer | software Vulkan `lvp 1.4.318 9d69cae2004b`, loader `1.3.275 e833b010f814`, `VK_LAYER_KHRONOS_validation 1.3.275 1d486283e4ce +synchronization` |
| Validation | harness-composed hosts name `VK_LAYER_KHRONOS_validation` and synchronization validation in the public `VulkanHostConfig` (a layer or feature the loader lacks refuses instance creation), and judge a diagnostic verdict that fails on **any** issue, lost records included; the actual-command cases run `--vulkan-validation`, record `requested=true layer=enabled feature=enabled` once with nothing dropped, require the layer's own `Khronos Validation Layer Active` announcement exactly once with synchronization validation among its enables, and fail on a `diagnostic records were lost` warning |
| Content | an unchanged owned copy of `samples/lua-quad/content` (`quad.png` SHA-256 `96278830b274b41aa7134931a8ebf02aced5fd89ebce36d01c7396d4a425847b`); the logical-failure and Lua-quit cases edit only the copy's `main.lua` |
| Helper | `tools/x11-window/x11_window.py` (no new CI-image package): identifies a window by process id and window id and re-verifies it at each action, refuses when a process owns several viewable windows and is not told which, captures only the named window's client area, delivers a genuine `WM_DELETE_WINDOW` to exactly that window and never signals a process; 26 device-free examples run in `test.workflow` |
| Checksums | [`linux/SHA256SUMS.txt`](linux/SHA256SUMS.txt) covers every retained file |

## How an image was judged

Each capture is the unaltered lossless 8-bit RGB PNG of the window's client area (`XGetImage` of that window, never the root or the
desktop). It is judged against landmarks written from the fixture and the content, **not** from any capture: the centre of a
32 x 32 block of each quadrant (red top left, green top right, blue bottom left, yellow bottom right), the white corner texel at the
quad's top left, the black one at its bottom right, and clear-colour points (24, 24, 24) outside the quad, with the quad drawn at (32, 32)
and 256 x 256 logical pixels. A landmark outside a clipped window is not expected. Per-channel tolerance is **2**: Xvfb applies no
colour management and the quad passes through an sRGB target unchanged, so the expected values are the fixture's own bytes; the
tolerance was never relaxed. There is no first-run golden. Each record (`*.json`) carries the X window, the process id, the client area, the
host's own logical and framebuffer extents and content scale (1.0 on this display), every landmark with its expected and captured colour, the
number of capture attempts and, when the first failed, why. The attempts wait for the external presentation (the X server is not observable
from the suite): they are bounded at 45 attempts and the last image is retained whether or not it passed.

The windows of the harness cases are bound to their instance unambiguously and without matching a title: with the next window creation's outcome
withheld from the provider by an explicit gate, the one new viewable X window of the suite's process is that instance's, and its size is
cross-checked against the geometry the host observed. Two windows share the suite's process id, so the helper refuses a bare process id when
it owns several viewable windows. An X server without a compositor answers a capture with whatever window is on top, so the first instance
is captured **alone**, before the second exists, and the second (created last) is on top.

## Linux captures

| File | What it shows | Client area | Landmarks | Attempts | SHA-256 of the PNG |
| --- | --- | --- | --- | --- | --- |
| [`actual-command--logical-failure-red-clear.png`](linux/actual-command--logical-failure-red-clear.png) | the real command after an ordinary logical failure: the healthy UI is active and shows the exact empty red clear (96, 0, 0), until a native close (exit 1) | 640 x 480 | 4 | 1 | `281151087b216fd0a4a8f13be44061288e73afbb59b5453d7747198d37ab1ecd` |
| [`actual-command--quad.png`](linux/actual-command--quad.png) | the real built `hetoimasia run --vulkan-validation` command's window, before its genuine WM_DELETE_WINDOW close (exit 0) | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`pending-read--b-while-a-stopping.png`](linux/pending-read--b-while-a-stopping.png) | B correct while A is `Stopping` with its texture read held at the pool's reader | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`pending-window--b-while-a-pending.png`](linux/pending-window--b-while-a-pending.png) | B correct while A's window creation outcome is withheld from the provider | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`two-instances--a-quad.png`](linux/two-instances--a-quad.png) | instance A's window alone, before B exists: the shipped quad, unaltered by the second instance | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`two-instances--b-after-a-ended.png`](linux/two-instances--b-after-a-ended.png) | B after A was ended through its public lifecycle control while A's accepted scene referenced its released texture: B's quad is still correct and its texture was never reloaded (one live texture) | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`two-instances--b-quad.png`](linux/two-instances--b-quad.png) | instance B's window with both instances live, requested from the same PNG path as A, loaded independently | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`user-close-0--a-quad.png`](linux/user-close-0--a-quad.png) | first user-close case: A alone before B exists | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`user-close-0--b-quad.png`](linux/user-close-0--b-quad.png) | first user-close case: B with both live, before the genuine close | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`user-close-1--a-quad.png`](linux/user-close-1--a-quad.png) | second user-close case: A alone before B exists | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`user-close-1--b-quad.png`](linux/user-close-1--b-quad.png) | second user-close case: B with both live, before the genuine close | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`view--initial.png`](linux/view--initial.png) | the unchanged scene at the shipped 640 x 480 | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`view--larger.png`](linux/view--larger.png) | the same scene in an 800 x 600 window: same size and top-left position, more clear colour | 800 x 600 | 11 | 1 | `b662e1d9f7df174253f46c28e0c17e1e92659b3a076b8abbf05ba7517550abf0` |
| [`view--restored.png`](linux/view--restored.png) | after minimize and restore: the scene again, at 800 x 600 (the first capture after the restore failed while the window was still unmapped and cleared; see the record's `first_attempt_failures`) | 800 x 600 | 11 | 2 | `b662e1d9f7df174253f46c28e0c17e1e92659b3a076b8abbf05ba7517550abf0` |
| [`view--smaller.png`](linux/view--smaller.png) | the same scene in a 320 x 240 window: clipped at the right and bottom, not stretched or re-centred, top-left position unchanged | 320 x 240 | 9 | 1 | `0df283f1f0710c731756f75aa891894334780f8d2cf540a02cc8be16d088331e` |

## What the cases establish, and what they do not

* The same PNG path requested by two instances is two independent allocations (two live textures), two windows and two scenes; ending A
  through its public lifecycle control closes only A's window, is never a user close, and leaves B updating with its window and texture.
  This holds with A's texture read held at the pool's reader and with A's window creation outcome withheld; the late results are drained,
  nothing is orphaned and a later instance loads the same path.
* A genuine, platform-delivered close (`requestNativeClose`, an X11 `WM_DELETE_WINDOW` that `XSendEvent` accepted; Cocoa `performClose:` on macOS) of
  either live harness window is exactly one whole-session quit request; the windows stay until the instances are ended.
* The published scene's revision stays 1 through resize, minimize and restore: nothing republishes, and no Lua size is read.
* **Native zero-area framebuffer: unexercised.** On this display a minimized window keeps its framebuffer; the controlled zero-metrics coverage
  belongs to LFE-18, LFE-20 and the host's suspended-target cases and is not claimed as native.
* The injected clean refusal of one window's standing is labelled injected; the exit status of a session that meets a real window-creation
  failure is the owning tests' (LFE-23's integrated endings), not observable here. Device loss and out-of-memory are not induced.
* After an iconify and restore the X server has cleared the unmapped window, so a frame presented while it was unmapped is lost; the capture
  asks the target for another frame (a public client demand, no publication) until the window shows its own pixels. The first attempt of
  `view--restored` is recorded as failed for that reason.
* No new Wayland, hardware-support or performance claim.

## macOS

The unattended macOS receipt (the catalog's `--complete` profile under the desktop consent, which never holds) passes all 35 examples; it
records each owner-confirmation checkpoint as pending. The supervised run and the actual command's quad and close are the owner's, once, at the approved head,
through the manager; their record supersedes [the pending file](macos-owner-confirmations.md). The restore case is the
regression check for [#581](https://github.com/coghex/hetoimasia/issues/581): a restored window must report itself drawable with no further sample.
