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
- [`lua-quad/`](lua-quad/README.md) — LFE-22's shipped content for `hetoimasia run`: the accepted P-73
  textured-quad example as a plain folder (a manifest, a Lua entry and a technical PNG), with no Haskell of its own. The
  generic command in the root application runs it and any other folder; see
  [the run command](../docs/run_command.md). It is launched by hand and is no engine dependency.
- [`lua-domains/`](lua-domains/README.md) — LUA-29's two-domain Lua consumer: a UI
  VM owner and a gameplay VM owner composed side by side from the Lua package's
  public modules, headless. Gameplay's Haskell-owned world is committed once per
  completed tick and published as a snapshot; the UI reads a coherent latest
  snapshot and sends intentions that reach gameplay exactly once. One package
  (`hetoimasia-sample-lua-domains`) holds the library, the executable
  (`hetoimasia-lua-domains`, launched by hand) and the suite (`lua-domains-tests`,
  the group `test.lua-domains`). Unlike the graphics samples it needs no GLFW or
  Vulkan, so both `cabal.project` and `cabal.project.cpu` build it.
  It also fails, overloads and stops explicitly (LUA-30): `--scenario` runs the
  normal, pause, failure, flood and stop sessions, and the failure scenario exits 1.
