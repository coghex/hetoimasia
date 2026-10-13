# Samples

The first console consumer currently lives in root `app/`. Rendering examples
live here: independent consumers that use public interfaces only. They are
architecture checks and runnable examples, not engine dependencies — no engine
library depends on a sample, and nothing routine launches one.

- [`triangle/`](triangle/README.md) — VK-17's consumer: one triangle in each of
  two windows sharing one Vulkan device, through the window integration's
  public host. Its drawing (`triangle/renderer`) is what the integration's
  native suite exercises in its required profile; its executable
  (`triangle/app`) is launched by hand.
- [`sprites/`](sprites/README.md) — GRS-8's 2D scaffolding scene: indexed,
  instanced textured quads through stable texture handles, with
  premultiplied-alpha blending, checked against an independent probe oracle.
  Its drawing and window-free evidence (`sprites/renderer`) are what the native
  suite's `grs8-sprites` case runs; its executable (`sprites/app`,
  `hetoimasia-sprites`) writes the same evidence (`--evidence`) or shows the
  scene in a window (`--windowed`), launched by hand.
- [`image2d/`](image2d/README.md) — R2D-8's 2D renderer consumer: a committed
  PNG decoded with `asset-image` and drawn in a world layer and again in a UI
  layer at a fixed logical size, with a committed RGBA8 KTX2 image beside it,
  through the 2D renderer's recorder, texture registry and per-window host
  adapter. Its drawing, hand-stated probes and window-free evidence
  (`image2d/renderer`) are what the native suite's `r2d8-image` case runs, with
  the texture lifecycle through the production host's per-window scenes; its
  executable (`image2d/app`, `hetoimasia-image2d`) writes the evidence
  (`--evidence`) or shows the images in a window (`--windowed [--ui-scale]`),
  launched by hand.
- [`scene3d/`](scene3d/README.md) — GRS-10's 3D scaffolding scene: two
  flat-coloured cubes, one in front of the other, drawn indexed with a depth
  test from two camera poses built with `hetoimasia-math`, checked against an
  independent ray-cast probe oracle. Its drawing and window-free evidence
  (`scene3d/renderer`) are what the native suite's `grs10-scene3d` case runs;
  its executable (`scene3d/app`, `hetoimasia-scene3d`) writes the same evidence
  (`--evidence`), launched by hand. Its windowed mode arrives with windowed
  depth (GRS-13).
