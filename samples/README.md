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

A minimal 3D scene, then a small 2D scene using the same infrastructure, are
still to come.
