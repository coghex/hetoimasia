# LFE-25 evidence: the Lua quad on real windows

Retained evidence for [#540](https://github.com/coghex/hetoimasia/issues/540) (epic #514, LFE-25). It shows what real native
windows presented on the isolated Linux X11 display for the shipped `samples/lua-quad` content: through the actual built command and
through the two-instance harness composed over the public interfaces, with an independent logical owner. **The images are technical
test assets (the 8 x 8 technical fixture of `samples/lua-quad`), not production art.** A capture is what a window presented; it is never
evidence of GPU retirement, which these cases establish only through the host's and the adapter's own records (the lifecycle records
below). The macOS entries are **pending**: there is no OS capture on macOS, and the owner's visual confirmations are owed ([the pending
record](macos-owner-confirmations.md)). What each completion condition and slice of the epic rests on is in [the coverage document](coverage.md).

## Identities (Linux)

| | |
| --- | --- |
| Producer | the group `test.vulkan-run-native`, command `bash tools/vulkan/run.sh native hetoimasia:test:run-native-tests -- --complete`, prepared by `bash tools/vulkan/run.sh build hetoimasia:exe:hetoimasia hetoimasia:test:run-native-tests` (the `Lua native milestone` subgroup is selectable alone with `--match 'Lua native milestone'`) |
| Receipt | [`receipts/test.vulkan-run-native.json` of the pull request's CI run](https://github.com/coghex/hetoimasia/actions/runs/41343138137/attempts/1), outcome `passed`, 16.053 s of its 30 s budget; 54 examples, 0 failures ([the run's own record](linux/run-native.md)) |
| Code | pull request head `8a159fe7b68bc561fe616868dea44fb302fca74e`, executed as the merged candidate commit `6a3963ccde1be4ca7ee6beb0df8b7b1f82428e81` (tree `5a4784e3f1591135103df66fe14505d65d7bc0e2`) |
| Runner | Linux X64, runner class `display`; CI image `sha256:71ef73f2fd6432b1b70bc96dc0ab7ded728091ad76232309c7e4ec58858603cb` |
| Display | an isolated Xvfb (1280 x 1024 x 24) with the Openbox window manager that `tools/display/x11.sh` starts for the one command; no compositor; no colour management |
| Device, loader, layer | software Vulkan `lvp 1.4.318 9d69cae2004b`, loader `1.3.275 e833b010f814`, `VK_LAYER_KHRONOS_validation 1.3.275 1d486283e4ce +synchronization` |
| Validation | harness-composed hosts name `VK_LAYER_KHRONOS_validation` and synchronization validation in the public `VulkanHostConfig` (a layer or feature the loader lacks refuses instance creation), and judge a diagnostic verdict that fails on **any** issue, lost records included (on a failing scenario too: the verdict and cleanup failures attached to the failure are judged); the actual-command cases run `--vulkan-validation`, record `requested=true layer=enabled feature=enabled` once with nothing dropped, require the layer's own `Khronos Validation Layer Active` announcement exactly once with synchronization validation among its enables, and fail on a `diagnostic records were lost` warning |
| Content | an unchanged owned copy of `samples/lua-quad/content` (`quad.png` SHA-256 `96278830b274b41aa7134931a8ebf02aced5fd89ebce36d01c7396d4a425847b`); the logical-failure and Lua-quit cases edit only the copy's `main.lua` |
| Helper | `tools/x11-window/x11_window.py` (no new CI-image package): identifies a window by process id and window id and re-verifies it at each action, refuses when a process owns several viewable windows and is not told which, captures only the named window's client area, delivers a genuine `WM_DELETE_WINDOW` to exactly that window and never signals a process; 26 device-free examples run in `test.workflow` |
| Checksums | [`linux/SHA256SUMS.txt`](linux/SHA256SUMS.txt) covers every retained file |

## How an image was judged

Each capture is the unaltered lossless 8-bit RGB PNG of the window's client area (`XGetImage` of that window, never the root or the
desktop). It is judged against landmarks written from the fixture and the content, **not** from any capture: the centre of a
32 x 32 block of each quadrant (red top left, green top right, blue bottom left, yellow bottom right), the white corner texel at the
quad's top left, the black one at its bottom right, and clear-colour points (24, 24, 24) outside the quad, with the quad drawn at (32, 32)
and 256 x 256 logical pixels. A landmark outside a clipped window is not expected. The initial scene (opaque black) and the logical-failure scene (the
exact red clear 96, 0, 0) have their own landmarks. Per-channel tolerance is **2**: Xvfb applies no colour management and the quad passes through an
sRGB target unchanged, so the expected values are the fixture's own bytes; the tolerance was never relaxed. There is no first-run golden. Each record
(`*.json`) carries the X window, the process id, the client area, the host's own logical and framebuffer extents and content scale (1.0 on this
display), every landmark with its expected and captured colour, the number of capture attempts and, when the first failed, why. The attempts wait for the
external presentation (the X server is not observable from the suite): they are bounded at 45 attempts and the last image is retained whether or not it
passed.

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
| [`initial-empty--a-black.png`](linux/initial-empty--a-black.png) | the initial empty window: only the initial (opaque black) scene is adopted while the instance's texture read is held at the pool's reader | 640 x 480 | 4 | 1 | `33806e3d5c67f100a92295c93044bbb67d6cea90060327b69d682ebd283c87d2` |
| [`initial-empty--a-quad.png`](linux/initial-empty--a-quad.png) | the same window after the gate was released and the instance had not ended: the textured quad | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`pending-read--b-while-a-stopping.png`](linux/pending-read--b-while-a-stopping.png) | B correct while A is `Stopping` with its texture read held at the pool's reader | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`pending-window--b-while-a-pending.png`](linux/pending-window--b-while-a-pending.png) | B correct while A's window creation outcome is withheld from the provider | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`two-instances--a-quad.png`](linux/two-instances--a-quad.png) | instance A's window alone, before B exists: the shipped quad, unaltered by the second instance | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`two-instances--b-after-a-ended.png`](linux/two-instances--b-after-a-ended.png) | B after A was ended through its public lifecycle control while A's accepted scene referenced its released texture: B's quad is still correct and it holds the same texture identity (nothing reloaded) | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`two-instances--b-quad.png`](linux/two-instances--b-quad.png) | instance B's window with both instances live, requested from the same PNG path as A, loaded independently | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`user-close-0--a-quad.png`](linux/user-close-0--a-quad.png) | first user-close case: A alone before B exists | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`user-close-0--b-quad.png`](linux/user-close-0--b-quad.png) | first user-close case: B with both live, before the genuine close | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`user-close-1--a-quad.png`](linux/user-close-1--a-quad.png) | second user-close case: A alone before B exists | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`user-close-1--b-quad.png`](linux/user-close-1--b-quad.png) | second user-close case: B with both live, before the genuine close | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`view--initial.png`](linux/view--initial.png) | the unchanged scene at the shipped 640 x 480 | 640 x 480 | 11 | 1 | `e126502934a1d6edd7f44d58d549ed4a27dddf4e6479c6339d0028d42c81e794` |
| [`view--larger.png`](linux/view--larger.png) | the same scene in an 800 x 600 window: same size and top-left position, more clear colour | 800 x 600 | 11 | 1 | `b662e1d9f7df174253f46c28e0c17e1e92659b3a076b8abbf05ba7517550abf0` |
| [`view--restored.png`](linux/view--restored.png) | after minimize and restore: the scene again, at 800 x 600 (the first capture after the restore failed while the window was still unmapped and cleared; see the record's `first_attempt_failures`) | 800 x 600 | 11 | 2 | `b662e1d9f7df174253f46c28e0c17e1e92659b3a076b8abbf05ba7517550abf0` |
| [`view--smaller.png`](linux/view--smaller.png) | the same scene in a 320 x 240 window: clipped at the right and bottom, not stretched or re-centred, top-left position unchanged | 320 x 240 | 9 | 1 | `0df283f1f0710c731756f75aa891894334780f8d2cf540a02cc8be16d088331e` |

## Lifecycle records

Each record states what the host's own records said about a window's disposal, read where it was made. The host's native-call observer reports each
disposal of a window's graphics (`vkDestroySwapchainKHR`, `vkDestroyImageView`, `vkDestroySurfaceKHR`) on the graphics owner's thread, the thread that also
reports the frame events; the harness takes each call's place among those events as it begins. For every such disposal the record lists the window's
attachments, the submissions its frames had made and which had a `SubmissionCompleted`, the presentations and which had a `PresentationRetired`, **among the
events before that place**: the cases assert nothing is outstanding there, so a disposal that preceded its completions fails the case, and a completion
that arrives afterwards does not rescue it. A window that never attached (an instance ended before its window presented, as in the two pending-work cases)
has no graphics to dispose and the record says so (`"attached": false`). The records also carry the texture identities the scene ledger held where the
case reads them: a texture is the same texture across time when the same identity is held, and a reload would show as a new one.

| File | What it records |
| --- | --- |
| [`lifecycle--initial-empty.json`](linux/lifecycle--initial-empty.json) | no texture identity held while the read was held, one after it was released, the instance never ended, the window's ordered disposal after its ended instance |
| [`lifecycle--pending-read.json`](linux/lifecycle--pending-read.json) | A ended with its read held: the peer's identity unchanged after the late result was discarded; A's window never attached, so it had nothing to dispose |
| [`lifecycle--pending-window.json`](linux/lifecycle--pending-window.json) | A ended with its creation outcome withheld: the peer's identity unchanged after the late result was retired; A's window never attached |
| [`lifecycle--two-instances.json`](linux/lifecycle--two-instances.json) | two instances, one path: the two texture identities the scene ledger held, A's ordered disposal and B's, B holding the same identity after A ended and after a further frame, the logical owner's tick from the middle to the end of the case (it advanced), no user close |

## What the cases establish, and what they do not

* The same PNG path requested by two instances is two independent allocations (two texture identities in the ledger), two windows and two scenes; ending A
  through its public lifecycle control closes only A's window, is never a user close, and leaves B updating with its window and the **same** texture identity.
  This holds with A's texture read held at the pool's reader and with A's window creation outcome withheld; the late results are drained, nothing is
  orphaned and a later instance loads the same path.
* An **independent logical owner** (its own VM, an owned exact-tick pump, the shipped gameplay behavior) is admitted first, ticks while both UI
  instances are live, supplies the UI's status through its real instance, and retires in order after the UI instances and windows.
* The initial empty window is observed while the instance's texture read is held; the same window then shows the quad once the gate is released and the instance is
  still live.
* A genuine, platform-delivered close (`requestNativeClose`, an X11 `WM_DELETE_WINDOW` that `XSendEvent` accepted; Cocoa `performClose:` on macOS) of
  either live harness window is exactly one whole-session quit request; the windows stay until the instances are ended.
* The published scene's revision stays 1 through resize, minimize and restore: nothing republishes, and no Lua size is read.
* A failing scenario, and a caller cancelled with gates held, unwind completely (gates released, windows and textures retired, the borrowed folder kept) and
  keep the capture's verdict and the cleanup failures; the teardown judge has device-free negative controls.
* **Native zero-area framebuffer: unexercised.** On this display a minimized window keeps its framebuffer; the controlled zero-metrics coverage
  belongs to LFE-18, LFE-20 and the host's suspended-target cases and is not claimed as native.
* **A real native window-creation failure is unexercised** (nondeterministic): the injected clean refusal of one window's standing is labelled injected, the exit
  status of a session that meets a real failure is the owning tests' (LFE-23's integrated endings), and a UI or cleanup failure's exit 1 is theirs too. Device loss and out-of-memory
  are not induced.
* After an iconify and restore the X server has cleared the unmapped window, so a frame presented while it was unmapped is lost; the capture
  asks the target for another frame (a public client demand, no publication) until the window shows its own pixels. The first attempt of
  `view--restored` is recorded as failed for that reason.
* No new Wayland, hardware-support or performance claim.

## macOS

The unattended macOS receipt (the catalog's `--complete` profile under the desktop consent, which never holds) passes all 54 examples; it
records each owner-confirmation checkpoint as pending. The supervised run and the actual command's quad and close are the owner's, once, at the approved head,
through the manager; their record supersedes [the pending file](macos-owner-confirmations.md). The restore case is the
regression check for [#581](https://github.com/coghex/hetoimasia/issues/581): a restored window must report itself drawable with no further sample.
