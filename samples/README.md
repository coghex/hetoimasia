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

A minimal 3D scene using the same infrastructure is still to come.
