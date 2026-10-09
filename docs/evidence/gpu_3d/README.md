# GRS-10 3D evidence: the scene3d sample

The retained evidence for #349, the scene3d sample (`samples/scene3d/`): two
flat-coloured cubes, the nearer drawn first, rendered with a depth test from two
camera poses into a 256×192 `R8G8B8A8_UNORM` colour target and a depth target,
each pose read back after its batch completed. The sample's
[README](../../../samples/scene3d/README.md) is the manifest: the scene, the
poses, the colours, the camera construction and the probe oracle; the
backend's contract is [Depth attachments](../../gpu_backend.md#depth-attachments).

## Identities

| | macOS | Linux (CI) |
| --- | --- | --- |
| Front capture | [`scene3d-front-macos.png`](scene3d-front-macos.png) | [`scene3d-front-linux.png`](scene3d-front-linux.png) |
| Front PNG SHA-256 | `70e5340dfa15c640a00ef889555475a942aec75c3a6a7e38a2c52d5d4cf77593` | `70e5340dfa15c640a00ef889555475a942aec75c3a6a7e38a2c52d5d4cf77593` |
| Side capture | [`scene3d-side-macos.png`](scene3d-side-macos.png) | [`scene3d-side-linux.png`](scene3d-side-linux.png) |
| Side PNG SHA-256 | `78b2f54cde2751c93cef97cdc69f1e6d436b3c97ab945d340647e452daa721ed` | `78b2f54cde2751c93cef97cdc69f1e6d436b3c97ab945d340647e452daa721ed` |
| Producer | `test.vulkan-native` (`--complete`, `grs10-scene3d` case), run locally with `HETOIMASIA_NATIVE_SESSION=desktop` and `HETOIMASIA_VALIDATION_EVIDENCE` set | `test.vulkan-native` in workflow run [37960063584](https://github.com/coghex/hetoimasia/actions/runs/37960063584) (attempt 1), artifact `validation-receipts-vulkan` (id 11630828513), files `evidence/test.vulkan-native/scene3d/` |
| Revision run | `a9ea2143502cafe7300ed023e37f26ae32ae4713`, the pull request's head when the run was made | `3d998ed3ae53bc6e5892385d2144fafac50b5267`, CI's merge of the head `a9ea2143502cafe7300ed023e37f26ae32ae4713` |
| Native source digest | `8f765edf3e4f55a0740637faadd7232e81a12b80cf2033ba61be6e2a546f3107` | `8f765edf3e4f55a0740637faadd7232e81a12b80cf2033ba61be6e2a546f3107` |
| Platform | macOS 26.7.1 (25G313), Apple M3 Max, arm64 | GitHub Actions Linux X64, the CI image's isolated X11 display |
| Device and driver | Apple M3 Max; MoltenVK 1.4.2 (`DRIVER_ID_MOLTENVK`) | `llvmpipe (LLVM 20.1.2, 256 bits)`; pinned Mesa Lavapipe 1.4.318 (`lvp_icd.json`) |
| Loader and layers | The provisioned prefix's loader and `VK_LAYER_KHRONOS_validation`; implicit layers disabled, no layer settings file | The same configuration from the CI image's prefix (`VK_LAYER_KHRONOS_validation 1.3.275`) |
| Validation | Synchronization validation enabled; clean verdict after the last teardown | Synchronization validation enabled; clean verdict after the last teardown |
| Depth format used | `D32_SFLOAT` (`Depth32Float`) | `D32_SFLOAT` (`Depth32Float`) |
| Suite | 157 examples, 0 failures, 2 pending (by design); the process ran 6.2 s | 157 examples, 0 failures, 2 pending; the process ran 4.4 s; `grs10-scene3d` exited successfully |
| Readbacks | two of 196,608 bytes, complete | two of 196,608 bytes, complete |

The native source digest covers the native backend, the window integration, the
three samples' packages, the math package and the runner (`tools/vulkan/run.sh`).
It is the same on both platforms, so both captures describe the same
implementation sources; adding this record changes the Git revision but not the
digest, since `docs/` lies outside it. The pull request head and the commit CI
merged differ only by master's documentation landings.

CI's `test.vulkan-wayland` group ran the same case under the isolated headless
Wayland compositor. Its captures, `evidence/test.vulkan-wayland/scene3d/` in the
same artifact, have the same SHA-256 digests as above, and all 23 probes passed.

## The depth state

Every pipeline of the scene declared depth testing and depth writing with the
comparison less-or-equal (`depthTested`); each pass cleared depth to 1.0 and the
colour target to `(32,48,64,255)`; the depth target was the colour target's extent,
256×192. The cubes were drawn **nearer first**, so wherever both cover a pixel the
farther cube, drawn second, would overwrite the nearer one if the depth test did
not reject it. The front pose was the first batch to touch the targets and
initialized them from undefined; the side pose was recorded after the front
pose's batch completed, kept them and cleared them again.

## Checks

Expected values come from the sample's oracle, a ray cast through each probe
pixel's centre into the scene without the math package's camera, never from
either image. Every check is **exact** in all four 8-bit channels. Each probe is
well inside one face, or outside both cubes: the oracle requires the same result
on every pixel within three of it. "Covered by" is the cubes whose boxes the
ray enters, in draw order, and "without depth" the cube a scene drawn with the
depth test disabled would show there — for each overlap, the farther one, whose
colour differs from the expected nearer one.

| Check | Pixel | Purpose | Nearest face | Covered by | Without depth | Expected | macOS observed | Linux observed | Linux Wayland observed |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| front: near cube +Z face | (175,137) | FaceColour | near PosZ | near | near | (255,100,120,255) | (255,100,120,255) pass | (255,100,120,255) pass | (255,100,120,255) pass |
| front: near cube +Y face | (165,83) | FaceColour | near PosY | near | near | (255,214,10,255) | (255,214,10,255) pass | (255,214,10,255) pass | (255,214,10,255) pass |
| front: far cube +Z face, moved from the side pose's pixels | (83,82) | CameraMovedPlace | far PosZ | far | far | (100,150,255,255) | (100,150,255,255) pass | (100,150,255,255) pass | (100,150,255,255) pass |
| front: far cube +X face, moved from the side pose's pixels | (129,61) | CameraMovedPlace | far PosX | far | far | (38,70,200,255) | (38,70,200,255) pass | (38,70,200,255) pass | (38,70,200,255) pass |
| front: near cube -X face, hidden from the side pose | (121,140) | CameraMovedFace | near NegX | near | near | (244,127,40,255) | (244,127,40,255) pass | (244,127,40,255) pass | (244,127,40,255) pass |
| front: pixel (146, 132) shows the near cube's +Z face | (146,132) | CameraMovedPlace | near PosZ | near | near | (255,100,120,255) | (255,100,120,255) pass | (255,100,120,255) pass | (255,100,120,255) pass |
| front: near cube -X face over the far cube | (115,104) | Occlusion | near NegX | near then far | far | (244,127,40,255) | (244,127,40,255) pass | (244,127,40,255) pass | (244,127,40,255) pass |
| front: near cube +Y face over the far cube | (129,82) | Occlusion | near PosY | near then far | far | (255,214,10,255) | (255,214,10,255) pass | (255,214,10,255) pass | (255,214,10,255) pass |
| front: clear, upper left | (8,8) | Clear | clear | — | — | (32,48,64,255) | (32,48,64,255) pass | (32,48,64,255) pass | (32,48,64,255) pass |
| front: clear, right | (240,60) | Clear | clear | — | — | (32,48,64,255) | (32,48,64,255) pass | (32,48,64,255) pass | (32,48,64,255) pass |
| front: clear, lower left | (40,176) | Clear | clear | — | — | (32,48,64,255) | (32,48,64,255) pass | (32,48,64,255) pass | (32,48,64,255) pass |
| side: near cube +Z face | (92,136) | FaceColour | near PosZ | near | near | (255,100,120,255) | (255,100,120,255) pass | (255,100,120,255) pass | (255,100,120,255) pass |
| side: near cube +Y face | (87,82) | FaceColour | near PosY | near | near | (255,214,10,255) | (255,214,10,255) pass | (255,214,10,255) pass | (255,214,10,255) pass |
| side: far cube +X face, moved from the front pose's pixels | (159,64) | CameraMovedPlace | far PosX | far | far | (38,70,200,255) | (38,70,200,255) pass | (38,70,200,255) pass | (38,70,200,255) pass |
| side: far cube +Y face | (139,41) | FaceColour | far PosY | far | far | (60,200,120,255) | (60,200,120,255) pass | (60,200,120,255) pass | (60,200,120,255) pass |
| side: far cube +Z face, moved from the front pose's pixels | (113,54) | CameraMovedPlace | far PosZ | far | far | (100,150,255,255) | (100,150,255,255) pass | (100,150,255,255) pass | (100,150,255,255) pass |
| side: near cube +X face, hidden from the front pose | (144,150) | CameraMovedFace | near PosX | near | near | (230,57,70,255) | (230,57,70,255) pass | (230,57,70,255) pass | (230,57,70,255) pass |
| side: pixel (146, 132) shows the near cube's +X face | (146,132) | CameraMovedPlace | near PosX | near | near | (230,57,70,255) | (230,57,70,255) pass | (230,57,70,255) pass | (230,57,70,255) pass |
| side: near cube +X face over the far cube | (151,98) | Occlusion | near PosX | near then far | far | (230,57,70,255) | (230,57,70,255) pass | (230,57,70,255) pass | (230,57,70,255) pass |
| side: near cube +Y face over the far cube | (125,83) | Occlusion | near PosY | near then far | far | (255,214,10,255) | (255,214,10,255) pass | (255,214,10,255) pass | (255,214,10,255) pass |
| side: clear, upper left | (8,8) | Clear | clear | — | — | (32,48,64,255) | (32,48,64,255) pass | (32,48,64,255) pass | (32,48,64,255) pass |
| side: clear, right | (240,60) | Clear | clear | — | — | (32,48,64,255) | (32,48,64,255) pass | (32,48,64,255) pass | (32,48,64,255) pass |
| side: clear, lower left | (40,176) | Clear | clear | — | — | (32,48,64,255) | (32,48,64,255) pass | (32,48,64,255) pass | (32,48,64,255) pass |

Every check passed on every platform: macOS 23/23, Linux 23/23, Linux Wayland 23/23.

What the checks prove:

- **Occlusion.** At each of the four overlap pixels the nearer cube's colour
  shows although the farther cube is drawn after it: the depth test, not the draw
  order, decided the pixel.
- **The camera moved.** The near cube's −X face is read only in the front pose
  and its +X face only in the side pose; neither face is visible anywhere in the
  other capture. The pixel `(146,132)` reads the near cube's +Z face in the front
  capture and its +X face in the side capture, and the far cube's +X and +Z faces
  are read at different pixels in the two.
- **The clear.** Pixels outside both cubes read the clear colour in both poses.

## Inspection (D-6)

Both PNGs were opened and inspected. They agree with the intended scene and with
the probe results:

- the front pose looks at the pair from a little above and in front: the near cube
  at the lower right shows its pink +Z face, yellow +Y face and orange −X face,
  and covers the far cube's lower right; the far cube at the upper left shows
  its light-blue +Z face, green +Y face and dark-blue +X face;
- the side pose looks from the right: the near cube at the lower left shows its
  pink +Z face, yellow +Y face and red +X face and covers the lower left of the
  far cube, which shows its light-blue +Z face, green +Y face and dark-blue +X
  face above and behind it;
- the dark slate clear colour fills everywhere else.

The captures from macOS, Linux's isolated X11 display and the Wayland compositor
are byte-identical. Whole-image equality across platforms is not required, and
is recorded here only as observed.
