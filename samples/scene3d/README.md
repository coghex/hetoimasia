# The scene3d sample

GRS-10 (#349): the first 3D scene built on the GPU resource services. The sample
draws two flat-coloured cubes, one in front of the other, indexed and with a
depth test, from two camera poses, into an offscreen colour target and a depth
target. Its independent probe oracle and window-free evidence mode show the
result is right — that the nearer cube occludes the farther one by depth, and
that the camera moved — not merely that it was submitted.

It has two packages, in the triangle and sprites samples' dependency direction:

- `renderer/` (`hetoimasia-sample-scene3d`) depends on the native backend and
  `hetoimasia-math` alone. It holds the scene, the cameras, the independent
  oracle, the checked shaders, the recording, a lossless PNG writer and the
  evidence runner. The window integration's native suite depends on it, as the
  app does.
- `app/` (`hetoimasia-sample-scene3d-app`, executable `hetoimasia-scene3d`)
  hands the renderer to the window integration's public host.

Neither package holds a native handle or makes a GLFW or Vulkan call of its own.
Both are listed only in `cabal.project.vulkan`, so only `tools/vulkan/run.sh`
builds them, and the repository's `-Werror` policy applies to both.

## Conventions

Coordinates follow Vulkan's, not OpenGL's (D-36): clip-space Y points down, and
depth runs 0 at the near plane to 1 at the far plane. Depth is cleared to 1.0
and compared less-or-equal, which are the backend's defaults; the backend takes
both per use, so `render-3d` can adopt reversed-Z later. The depth attachment is
depth-only, in the format the backend chooses by asking the device:
`D32_SFLOAT` where it is supported as a depth attachment, otherwise
`X8_D24_UNORM_PACK32`, otherwise `D16_UNORM`
([the backend's contract](../../docs/gpu_backend.md#depth-attachments)). The
evidence record names the format it used.

World space is right-handed with +Y up, as `hetoimasia-math`'s. The target is
256×192 pixels, `R8G8B8A8_UNORM` (linear, so the bytes read back are the bytes
the shaders wrote), cleared to `(32,48,64,255)`; `(0, 0)` is its upper-left
corner, `x` rightwards and `y` downwards, and a pixel's centre is at
`(x + ½, y + ½)`.

## The scene

Two cubes of half-extent 1, each yawed about the world's Y axis (a positive
angle turns +X toward −Z, by the right-hand rule):

| Cube | Centre | Yaw |
| --- | --- | --- |
| near | `(0.7, 0, 1.2)` | 25° |
| far | `(−0.9, 0.3, −1.4)` | −18° |

Each face of each cube has one flat colour, with no lighting. The near cube's
colours are warm and the far cube's cool, so a pixel's colour names its cube
and its face. A face is named by the world axis its outward normal lies along
before the cube is yawed.

| Cube | Face | Colour |
| NearCube | PosX | `(230,57,70,255)` |
| NearCube | NegX | `(244,127,40,255)` |
| NearCube | PosY | `(255,214,10,255)` |
| NearCube | NegY | `(200,100,0,255)` |
| NearCube | PosZ | `(255,100,120,255)` |
| NearCube | NegZ | `(150,30,30,255)` |
| FarCube | PosX | `(38,70,200,255)` |
| FarCube | NegX | `(20,140,160,255)` |
| FarCube | PosY | `(60,200,120,255)` |
| FarCube | NegY | `(40,100,60,255)` |
| FarCube | PosZ | `(100,150,255,255)` |
| FarCube | NegZ | `(80,40,160,255)` |

The scene is drawn **nearer cube first**. With depth testing disabled the far
cube, drawn second, would overwrite the near one wherever they overlap; an
overlap that shows the near cube's colour therefore proves occlusion by depth,
not by draw order. The near cube is nearer both cameras.

The two poses, each a 45° vertical field of view with planes at 0.5 and 50 and
`+Y` up:

| Pose | Eye | Target |
| --- | --- | --- |
| front | `(0.2, 2.4, 6.2)` | `(0, 0.2, 0)` |
| side | `(4.6, 2.8, 4.2)` | `(0, 0, 0)` |

## Cameras and push constants

The renderer builds each pose's matrices with `hetoimasia-math`
(`Hetoimasia.Sample.Scene3d.Camera`): `lookAt` for the view, `perspective
ZeroToOne YDown` for the projection, and for each cube a `rotation` about +Y
under a `translation` to its centre. Each draw's transform is the projection
times the view times that cube's model matrix. The math package promises no byte
layout (its README), so the renderer packs the matrix itself, in `packMatrix`:
sixteen little-endian 32-bit floats, column by column, which is how a GLSL
`mat4` in a push-constant block is laid out. The vertex stage's one push-constant
block is that `mat4`, 64 bytes at offset 0, declared in
`Hetoimasia.Sample.Scene3d.ShaderInterfaces` and checked against the compiled
SPIR-V while the package builds (GRS-16).

A cube is 24 vertices, four to a face, of 16 bytes: a position as three floats,
then the face's colour as four normalized bytes (`R8G8B8A8_UNORM`, so a colour
byte reaches the shader exactly). Its 36 indices, two triangles to a face, are
shared by both cubes. A pose's batch claims two regions of the session's shared
ring — both cubes' vertices, and the indices — and, for each cube in draw order,
binds its vertices at its offset, pushes its transform and draws it indexed. The
pipeline culls nothing, so a hidden face is overdrawn by the depth test alone.
The vertex stage passes the colour on `flat`, and the fragment stage writes it:
nothing is interpolated, so a face's colour is the byte it was given.

## Evidence mode

`hetoimasia-scene3d --evidence --output-dir DIRECTORY [--validation]` starts a
surface-free session and opens no window. One owner-thread action asks the
backend for the depth format and makes the ring, the colour and depth targets,
a readback buffer a pose, the layout and the depth-tested pipeline
(`depthTested`). Each pose is then recorded into a frame-less batch: both
targets cleared by one pass (colour to the clear colour, depth to 1.0), the two
cubes drawn, the colour target copied into the pose's readback and returned to
rest. The front pose is the first batch to touch the targets, so it initializes
them (`ClearFromUndefined`); the side pose is recorded only after the front
pose's batch has completed, keeps what that batch initialized (`ClearTarget`) and
clears both again, so nothing of the first pose survives into the second. Each
pose is read back only once its batch's completion is proved.

It writes `scene3d-front.png`, `scene3d-side.png` (lossless: 8-bit RGBA, stored
deflate blocks, no colour space and no conversion) and `scene3d-probes.json` into
the directory. The record lists the target, the depth format and state, the draw
order, the cubes and poses, and every probe with its coordinates, expected and
observed values, the face and the cubes its ray strikes in draw order, and the
cube it would show without depth testing. The run exits 0 only when every probe
of both poses passed and the diagnostic verdict is clean.

The native suite runs the same evidence as its `grs10-scene3d` private case
(`Test.GPU.Vulkan.Native.SurfaceFree`), over its own session, writing beneath
`HETOIMASIA_VALIDATION_EVIDENCE/scene3d/` when the validation runner names an
evidence directory. The retained captures and record are in
[`docs/evidence/gpu_3d/`](../../docs/evidence/gpu_3d/README.md).

```bash
bash tools/vulkan/run.sh build hetoimasia-sample-scene3d-app:exe:hetoimasia-scene3d
bash tools/vulkan/run.sh native hetoimasia-sample-scene3d-app:exe:hetoimasia-scene3d -- \
  --evidence --output-dir /tmp/scene3d-evidence --validation
```

There is no windowed mode yet. It arrives with windowed depth (GRS-13, #350),
which gives each swapchain generation its own depth image; this sample's
windowed mode will then orbit the camera around this scene.

## The probe oracle

`Hetoimasia.Sample.Scene3d.Oracle` finds every expected value by casting a ray
through the probe pixel's centre into the scene, from the pose's eye, along the
direction its field of view and the target's aspect ratio give, and taking the
nearer entry into a cube's box in the cube's own yawed space. It does not use
the math package's `lookAt` or `perspective`, so a mistake in the matrices the
renderer draws with is not one the oracle shares; the sample's suite projects
each struck point back through the renderer's matrices and requires the
probe's pixel and a depth between 0 and 1, with the nearer hit of an overlap
the smaller. A pixel's expected colour is the struck face's flat colour, or the
clear colour where the ray strikes nothing. Every check is **exact**, in all
four 8-bit channels: there is no blending and no filtering, and each colour is a
byte the device converts without rounding.

A probe is only a probe when it is well inside a face: the oracle holds it to
the same face of the same cube, or to a miss of both, on every pixel within
three of it, so no rasterization edge rule and no last bit of a projection can
decide it. The suite requires this of every probe, and of the probes' purposes:

- **Face colour** — a face visible from the pose reads its flat colour.
- **Occlusion** — both cubes cover the pixel, the near one first in draw order:
  the near cube's colour must show, and the far cube's, which a disabled depth
  test would show instead, must not. The suite also builds the image a scene
  drawn without depth testing would give, and requires that it fails exactly
  these probes.
- **Camera moved, face** — a face the other pose cannot see anywhere in its
  image.
- **Camera moved, place** — a pixel the two poses read differently, `(146, 132)`,
  and faces both poses see at different pixels.
- **Clear** — a pixel neither cube covers reads the clear colour.

Probes (expected colours are `(r,g,b,a)`; "covered by" is the cubes whose boxes
the ray enters, in draw order):

| Probe | Pose | Pixel | Purpose | Nearest face | Covered by | Expected |
| --- | --- | --- | --- | --- | --- | --- |
| front: near cube +Z face | front | (175,137) | FaceColour | near PosZ | near | `(255,100,120,255)` |
| front: near cube +Y face | front | (165,83) | FaceColour | near PosY | near | `(255,214,10,255)` |
| front: far cube +Z face, moved from the side pose's pixels | front | (83,82) | CameraMovedPlace | far PosZ | far | `(100,150,255,255)` |
| front: far cube +X face, moved from the side pose's pixels | front | (129,61) | CameraMovedPlace | far PosX | far | `(38,70,200,255)` |
| front: near cube -X face, hidden from the side pose | front | (121,140) | CameraMovedFace | near NegX | near | `(244,127,40,255)` |
| front: pixel (146, 132) shows the near cube's +Z face | front | (146,132) | CameraMovedPlace | near PosZ | near | `(255,100,120,255)` |
| front: near cube -X face over the far cube | front | (115,104) | Occlusion | near NegX | near, far | `(244,127,40,255)` |
| front: near cube +Y face over the far cube | front | (129,82) | Occlusion | near PosY | near, far | `(255,214,10,255)` |
| front: clear, upper left | front | (8,8) | Clear | clear | — | `(32,48,64,255)` |
| front: clear, right | front | (240,60) | Clear | clear | — | `(32,48,64,255)` |
| front: clear, lower left | front | (40,176) | Clear | clear | — | `(32,48,64,255)` |
| side: near cube +Z face | side | (92,136) | FaceColour | near PosZ | near | `(255,100,120,255)` |
| side: near cube +Y face | side | (87,82) | FaceColour | near PosY | near | `(255,214,10,255)` |
| side: far cube +X face, moved from the front pose's pixels | side | (159,64) | CameraMovedPlace | far PosX | far | `(38,70,200,255)` |
| side: far cube +Y face | side | (139,41) | FaceColour | far PosY | far | `(60,200,120,255)` |
| side: far cube +Z face, moved from the front pose's pixels | side | (113,54) | CameraMovedPlace | far PosZ | far | `(100,150,255,255)` |
| side: near cube +X face, hidden from the front pose | side | (144,150) | CameraMovedFace | near PosX | near | `(230,57,70,255)` |
| side: pixel (146, 132) shows the near cube's +X face | side | (146,132) | CameraMovedPlace | near PosX | near | `(230,57,70,255)` |
| side: near cube +X face over the far cube | side | (151,98) | Occlusion | near PosX | near, far | `(230,57,70,255)` |
| side: near cube +Y face over the far cube | side | (125,83) | Occlusion | near PosY | near, far | `(255,214,10,255)` |
| side: clear, upper left | side | (8,8) | Clear | clear | — | `(32,48,64,255)` |
| side: clear, right | side | (240,60) | Clear | clear | — | `(32,48,64,255)` |
| side: clear, lower left | side | (40,176) | Clear | clear | — | `(32,48,64,255)` |

## Tests

`scene3d-tests` is the headless suite, run by `bash tools/vulkan/run.sh test
hetoimasia-sample-scene3d:test:scene3d-tests` as part of the validation group
`test.vulkan-headless`. It needs no device, display or GLFW session. It checks
the scene's data and geometry against the shader interface (24 vertices of 16
bytes, 36 indices within one face a triangle, one flat colour a face, twelve
distinct colours, the near cube drawn first and nearer both cameras); the
cameras against the oracle, including the clip-space conventions (Y down, depth
0 to 1), the yaw convention and the matrix packing; the oracle's probes — every
one interior, every purpose present in both poses, the occlusion probes
discriminating, the camera-moved probes real — and that the oracle tells a right
image from one drawn without depth or with one value wrong; the PNG writer; and
that the probe record is well-formed JSON.
