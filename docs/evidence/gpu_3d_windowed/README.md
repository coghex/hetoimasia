# GRS-13 windowed depth evidence: the scene3d sample in a window

The retained evidence for #350, windowed depth: the scene3d sample's two flat-coloured
cubes (`samples/scene3d/`, the nearer drawn first) drawn with a depth test into a
window's own image with the depth image of the window's swapchain generation, a
frame captured, the window resized, and a frame of the generation built at the new
size captured, each checked against the sample's independent oracle. The sample's
[README](../../../samples/scene3d/README.md) is the manifest of the scene, the camera
and the probes; the backend's contract is
[Windowed depth](../../gpu_backend.md#windowed-depth).

## Identities

| | macOS |
| --- | --- |
| Capture before the resize | [`scene3d-windowed-before-macos.png`](scene3d-windowed-before-macos.png), 320×240 |
| Before PNG SHA-256 | `c84e3fa88921af6d9b95a6630f615014f95faa467d3be18cae71e995804440c2` |
| Capture after the resize | [`scene3d-windowed-after-macos.png`](scene3d-windowed-after-macos.png), 400×300 |
| After PNG SHA-256 | `5fec13c16332f5f25da12da76b7f02c626f337d5f13a9b31e6b5e26e43541714` |
| Probe record | [`scene3d-windowed-probes-macos.json`](scene3d-windowed-probes-macos.json), the case's own output |
| Producer | `test.vulkan-native` (`--complete`, `grs13-window-depth` case), run locally with `HETOIMASIA_NATIVE_SESSION=desktop` and `HETOIMASIA_VALIDATION_EVIDENCE` set |
| Revision run | `8b553fdb23af6782fd799d8ccd6d6b2ce8b80af4`, the pull request's head when the run was made (the captures and every probe value are byte-identical to the run at `772e4071`, before the review's lifecycle changes) |
| Platform | macOS 26.7.1 (25G313), Apple M3 Max, arm64 |
| Device and driver | Apple M3 Max; MoltenVK (`DRIVER_ID_MOLTENVK`), as the provisioned prefix pins it |
| Loader and layers | The provisioned prefix's loader and `VK_LAYER_KHRONOS_validation`; implicit layers disabled, no layer settings file |
| Validation | Synchronization validation enabled; clean verdict after the last teardown, no error report |
| Depth format used | `D32_SFLOAT` (`Depth32Float`), the device's first choice |
| Suite | 158 examples, 0 failures, 2 pending (by design); the process ran 6.8 s; `grs13-window-depth` exited successfully, its own run 0.7 s |
| Frames | 29 frame requests, each naming its generation's depth image, all presented; 23 were submitted while an earlier submission had not completed, so frames in flight shared each generation's depth image and cleared it in turn; two captured frames of 307,200 and 480,000 bytes, complete |

The window is 160×120 points, resized to 200×150 through its command port, and the
display's content scale of two makes its framebuffers 320×240 and 400×300: the
case reads each captured frame's own extent, so it holds on a display of another
scale as long as the aspect ratio is the window's, 4:3. Linux's capture is not
retained here: CI's `test.vulkan-native` and `test.vulkan-wayland` groups run the
same case, and write its captures and probe record under their evidence
directories.

## The depth state

The window was asked for frames continuously for twelve presentations before each
capture, so that frames overlapped in flight, each clearing the generation's one
depth image after the one before, under synchronization validation. The pass was the sample's windowed pass: the frame's image cleared to
`(32,48,64,255)` (written as the sRGB swapchain stores it) and the generation's depth
image cleared to 1.0, both from undefined, then the two cubes drawn nearer first
with a pipeline that tests and writes depth, less-or-equal, in the format the
backend chose. The camera was the sample's front pose, held still — the sample's
`--windowed` mode orbits it, and a camera that moves has no fixed probes. Each
generation, the one built at the window's size and the one built after the resize,
owned a depth image of its own, of its own extent, named by the request of every
frame of it; the case asserts it, and that the old one was not destroyed before
the batches that recorded it had completed is the stand-in suite's
(`Test.GPU.Vulkan.Native.WindowDepth`).

## Checks

Expected values come from the sample's oracle, a ray cast through each probe
pixel's centre into the scene without the math package's camera, never from either
image, at the framebuffer's own extent. Each probe is one of the sample's front
pose's probes, scaled to the framebuffer and kept only where it is still well
inside one face, or outside both cubes: the oracle requires the same result on
every pixel within three of it. The swapchain is sRGB, so a colour the shaders
write reads back encoded; the expected value is the oracle's colour as the image
stores it (`storedColour`), and every channel must be within 6 of it. All 11
probes of each frame passed, and each read **exactly** the expected value. The
occlusion probes are where both cubes are struck: the nearer cube, drawn first, is
what shows, and a scene drawn without depth testing would show the farther one.

| Check | Purpose | Pixel before | Expected before | Observed before | Pixel after | Expected after | Observed after |
| --- | --- | --- | --- | --- | --- | --- | --- |
| front: near cube +Z face | FaceColour | (218, 171) | (255,168,182,255) | (255,168,182,255) pass | (273, 214) | (255,168,182,255) | (255,168,182,255) pass |
| front: near cube +Y face | FaceColour | (206, 103) | (255,236,56,255) | (255,236,56,255) pass | (257, 129) | (255,236,56,255) | (255,236,56,255) pass |
| front: far cube +Z face, moved from the side pose's pixels | CameraMovedPlace | (103, 102) | (168,202,255,255) | (168,202,255,255) pass | (129, 128) | (168,202,255,255) | (168,202,255,255) pass |
| front: far cube +X face, moved from the side pose's pixels | CameraMovedPlace | (161, 76) | (108,143,229,255) | (108,143,229,255) pass | (201, 95) | (108,143,229,255) | (108,143,229,255) pass |
| front: near cube -X face, hidden from the side pose | CameraMovedFace | (151, 175) | (250,187,110,255) | (250,187,110,255) pass | (189, 218) | (250,187,110,255) | (250,187,110,255) pass |
| front: pixel (146, 132) shows the near cube's +Z face | CameraMovedPlace | (182, 165) | (255,168,182,255) | (255,168,182,255) pass | (228, 206) | (255,168,182,255) | (255,168,182,255) pass |
| front: near cube -X face over the far cube | Occlusion | (143, 130) | (250,187,110,255) | (250,187,110,255) pass | (179, 162) | (250,187,110,255) | (250,187,110,255) pass |
| front: near cube +Y face over the far cube | Occlusion | (161, 102) | (255,236,56,255) | (255,236,56,255) pass | (201, 128) | (255,236,56,255) | (255,236,56,255) pass |
| front: clear, upper left | Clear | (10, 10) | (99,120,137,255) | (99,120,137,255) pass | (12, 12) | (99,120,137,255) | (99,120,137,255) pass |
| front: clear, right | Clear | (300, 75) | (99,120,137,255) | (99,120,137,255) pass | (375, 93) | (99,120,137,255) | (99,120,137,255) pass |
| front: clear, lower left | Clear | (50, 220) | (99,120,137,255) | (99,120,137,255) pass | (62, 275) | (99,120,137,255) | (99,120,137,255) pass |
