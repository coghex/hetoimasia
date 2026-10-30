# The Lua quad

The shipped content of `hetoimasia run` (LFE-22): the accepted Lua-authored textured quad of the Lua-first engine's design (P-73),
as a plain folder. There is no game-specific Haskell: the executable runs whatever folder it is given.

```sh
bash tools/vulkan/run.sh build hetoimasia:exe:hetoimasia
HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia:exe:hetoimasia -- run samples/lua-quad/content
```

It opens a 640 x 480 window on the desktop with the picture below on a dark background, until the window is closed (exit 0) or the
process is sent SIGINT or SIGTERM (exit 130). Copy the folder anywhere and run the copy: nothing depends on its location in this
repository or on its identity.

## Layout

| Path | What it is |
| --- | --- |
| `content/hetoimasia.json` | P-71's common-entry example: `format 1`, id `example_game`, `entry lua/main.lua`, `tick_seconds "0.01"` |
| `content/lua/main.lua` | the accepted P-73 example: a real gameplay update stub, and a presentation behavior at an explicit 0.02-second cadence that starts the window and texture requests in `init`, retries only busy admissions, takes each result once, publishes the quad once and releases the texture; on a logical failure it warns and publishes the red empty scene |
| `content/images/quad.png` | a small static technical fixture, below |
| `tools/generate_quad_png.py` | regenerates the PNG, byte for byte; outside the launched folder |

The 10 ms tick and the 640 x 480 window are authored example values, not engine defaults. There is no frame callback, no general
input and no native Lua loader.

## The folder is scanned whole

The command scans **every** file under the folder at start, hidden and unused ones included, hashes it and refuses the run on a
symbolic link, an unsupported file type or any limit exceeded (10,000 entries, 64 MiB a file, 1 GiB in all). So the README and the
generator are kept *beside* `content/`, never in it, and any edit of the content takes effect at the next start only.

## `quad.png`: technical evidence, not production art

An 8 x 8 RGBA8 static PNG generated in this repository by `tools/generate_quad_png.py` (standard library only; filter 0, one IDAT chunk
at zlib level 9, no ancillary chunk), so it is wholly owned. Four 4 x 4 quadrants (top left red, top right green, bottom left blue,
bottom right yellow), a white texel at the top left corner and a black one at the bottom right, so orientation and every channel can
be told apart. Run without an argument the generator reproduces it exactly.

* size: 87 bytes
* SHA-256: `96278830b274b41aa7134931a8ebf02aced5fd89ebce36d01c7396d4a425847b`

It is a fixture for the launcher and the graphics adapter, labelled as such; it is not approved production art.

## What is and is not shown

The native suite shows, on a real device, that this content's scene is adopted, kept and recorded, and that everything retires when it ends
([`run_command.md`](../../docs/run_command.md)). It captures no pixel and reads no window back: whether the quad is *seen* is
LFE-25's platform qualification.
