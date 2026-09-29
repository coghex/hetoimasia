# The triangle sample

VK-17's consumer of the Vulkan backend: one triangle in each of two GLFW
windows that share one Vulkan device, drawn through the window integration's
public host (`Hetoimasia.GPU.Vulkan.GLFW`). It is two packages, both listed
only in `cabal.project.vulkan`:

- **`renderer/` — `hetoimasia-sample-triangle`**, the drawing. `drawTriangle`
  clears a frame and draws the triangle across it inside the dynamic rendering
  it begins and ends, building a pipeline layout and a graphics pipeline for
  each color format the first time it meets it. Its shaders
  (`Hetoimasia.Sample.Triangle.Shaders`) are GLSL compiled to SPIR-V while it
  builds, through the native backend's shader adapter, with the corners and
  the colour interpolated from `Hetoimasia.Sample.Triangle.Geometry`. It is
  written against the native backend's public recording vocabulary alone and
  names nothing of the window integration, so the integration's native suite
  can depend on it — which is what makes it an input of `test.vulkan-native` —
  without a cycle. It is the one package here whose shader splices need
  `tools/vulkan/run.sh` to generate `renderer/shaders/toolchain.fingerprint`
  first, which the runner does.
- **`app/` — `hetoimasia-sample-triangle-app`**, the executable
  `hetoimasia-triangle`. It hands the drawing to the host as its renderer —
  one line: the frame's format and extent, and the two constructions the host
  lends — opens two windows, hands each to the host's graphics owner, and asks
  each for a new frame as soon as its last one was presented.

Neither holds a native handle or calls GLFW or Vulkan itself: the host creates
each window's surface on the main thread and calls the renderer on the
graphics owner's thread, and every pipeline the drawing builds is the host
session's managed resource, destroyed before the device when the session ends.

## Building and launching it

Build it against the provisioned native prefix, which needs no display or
consent:

```bash
bash tools/vulkan/run.sh build hetoimasia-sample-triangle-app:exe:hetoimasia-triangle
```

`test.vulkan-native`'s preparation builds it the same way on every run of that
group, so a sample that no longer builds against the host fails the group.
Nothing runs it: launching it is explicit. It opens two windows on the desktop
it is started on and renders until both are closed. The same runner launches
it with the provisioned loader, driver and layer:

```bash
bash tools/vulkan/run.sh native hetoimasia-sample-triangle-app:exe:hetoimasia-triangle -- [--frame-slots 1|2] [--seconds N] [--validation]
```

On macOS that is the desktop. On Linux the runner starts an isolated X11
display for a command that carries no session of its own, so the windows are
not visible; put `HETOIMASIA_NATIVE_SESSION=desktop` on that one command to
open them on your own display instead. `--frame-slots` chooses the model's
frame budget, one or two (two by default); `--seconds` ends it after that
long; `--validation` enables the Khronos validation layer with
synchronization validation, which the prefix supplies.

## What it shows, and what it does not claim

Each window shows an orange triangle on a dark blue clear, filling its
framebuffer. Resize either and it is rebuilt at its new size; minimize one and
it suspends rendering until it is restored; close the first-created one and
the other keeps rendering; close both, or reach `--seconds`, and it exits,
printing each window's presented frames and the diagnostic verdict, and exits
0 only when that verdict is clean.

It is an architecture check and an example, not a benchmark or a renderer. Its
frame counts measure nothing about refresh cadence, vertical blank or pacing,
and it claims no visual result beyond what the native suite's required profile
checks in captured frames. It has no scene, camera, assets or input handling.
