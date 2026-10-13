# image2d sample

R2D-8's consumer of the 2D renderer: a committed PNG decoded with
[`hetoimasia-asset-image`](../../packages/asset-image/README.md), uploaded,
registered and drawn in a world layer and again in a UI layer at a fixed logical
size, with a committed RGBA8 KTX2 image drawn beside it, through
[`hetoimasia-render-2d-vulkan`](../../packages/render-2d-vulkan/README.md)'s
recorder, texture registry and per-window host adapter. It is the first thing
that shows a decoded image in a window through the 2D renderer, and the sample
on which that renderer's registration, swap rule, publication and release
contracts are proved. The decision record is
[the 2D renderer design](../../docs/designs/render_2d_design.md) (D-7, D-14,
D-18, D-19, D-27, D-28, D-29).

It follows the [sprites sample](../sprites/README.md)'s pattern. There are two
packages:

| Package | Contents |
| --- | --- |
| `renderer/` (`hetoimasia-sample-image2d`) | the committed images (`assets/`) and their decoding; the scene's snapshot; the expectations stated by hand; the window-free evidence; the headless suite `image2d-tests` |
| `app/` (`hetoimasia-sample-image2d-app`) | the executable `hetoimasia-image2d`: the evidence mode and the explicitly launched windowed mode, over the window integration's public host |

The library depends on the native backend, `render-2d`, its oracle and its
Vulkan recorder, `asset` and `asset-image`, and names nothing of the window
integration, so the integration's native suite runs it unchanged (the case
`r2d8-image`, below). The executable fills the recorder's and the adapter's
host records from the host's public operations. Nothing in the engine depends
on either package, and both are selected only by `cabal.project.vulkan`, so
only `tools/vulkan/run.sh` builds them.

## The scene

One view covers the target, the camera is at the world origin at one pixel per
world unit, and UI scale is the `--ui-scale` option (1 by default). Three
sprites are drawn, in this order:

1. in a **world layer**, the PNG ("quadrants") at world (−80, 0), 64 units
   square: 64 pixels square on any display, left of the target's centre and
   below it;
2. in the same layer, the KTX2 image ("stripes") at world (16, 0), 64 units
   square, beside the PNG;
3. in a **UI layer**, the PNG again at UI (8, 8), **48 logical pixels** square.

UI space is measured in logical pixels, and the view maps it to the target by
the UI scale and the window's content scale, so the UI copy is 48 × UI scale ×
content scale pixels square and has the same physical size on a display of
content scale 1 and on one of content scale 2, while the world copies, which
are in world units, are the same number of pixels on both and so half the
physical size on the second. `--ui-scale` multiplies the UI copy's size: its
range is the view's, 0.5 to 4, and a value outside it is refused.

## The images

Each file is made by [`tools/make_fixtures.py`](tools/make_fixtures.py), which
uses only Python's standard library and writes every texel from the region
tables at its head. Nothing is a third party's work, so no third-party rights
attach to any of them. The output is byte-for-byte deterministic: run
`python3 samples/image2d/tools/make_fixtures.py` and `git status` shows nothing
changed. The library embeds the files when it compiles, so the sample finds them
whatever directory it is launched from.

| File | Extent | Levels | Decoded as | Alpha mark | Bytes | sha256 |
| --- | --- | --- | --- | --- | --- | --- |
| `renderer/assets/quadrants.png` | 64 × 64 | 1 | `decodePng ColourImage` → `TexelRgba8Srgb` (`Rgba8Srgb`) | binary (`True`) | 191 | `a43cce01254501fe7d01bf6a2c51d04dbabfea7198a40ed44e2299657bb76d98` |
| `renderer/assets/fade.png` | 64 × 64 | 1 | `decodePng ColourImage` → `TexelRgba8Srgb` | not binary (`False`) | 164 | `6662b629ea6d70f79984d76bbc5df587b90ab582b116463f46e485a62efd8f26` |
| `renderer/assets/stripes.ktx2` | 32 × 32 | 1 | `decodeKtx2 ColourImage` → `Ktx2Rgba8`, `TexelRgba8Srgb` | binary (`True`) | 4328 | `444286b8587f66d08e1ca091ac63c5ac1355b99398f71550d09264121fb9fc8d` |

- **quadrants.png**: an 8-bit RGBA PNG, no interlacing, every texel opaque.
  Four quadrants of one colour each — red (220, 40, 40) upper left, green
  (40, 200, 60) upper right, blue (50, 70, 220) lower left, yellow
  (240, 220, 50) lower right — with a magenta (255, 0, 255) marker of 8 × 8
  texels at texel (4, 4) and a white one at (52, 52), so a flip, a mirror, a
  rotation or a swapped channel shows.
- **fade.png**: the left half (200, 60, 60) at alpha 128 and the right half
  (60, 60, 200) opaque. Its alpha is not binary, so a swap of the quadrants'
  texture to it changes the computed mark: it is the replacement the swap rule
  is shown with. It is uploaded and never registered or drawn.
- **stripes.ktx2**: an `R8G8B8A8_SRGB` KTX2 file of one level, no
  supercompression, every texel opaque: four horizontal bands of 8 texels —
  cyan (0, 200, 200), orange (255, 140, 0), purple (150, 60, 200) and grey
  (128, 128, 128) — and a white marker of 4 × 4 texels at the upper left. The
  generator writes the file's identifier, header, level index, a basic data
  format descriptor, a `KTXwriter` entry and the level, as the specification's
  layout gives them, and shares no code with the reader.

Decoding a PNG gives its one level: the sample does not generate a mip chain,
and every copy is magnified or drawn at one texel to the pixel, so no draw
minifies. The files follow the asset contract for colour art: texel colour is
sRGB-encoded and premultiplied in linear light. The tests decode each file and
compare its level-0 bytes with the region tables stated in
`Hetoimasia.Sample.Image2d.Fixtures` — which restates the generator's tables in
Haskell — within one step, premultiplication worked out in `Double` with the
sRGB transfer function and never taken from the decoder.

## The evidence mode

```bash
HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native \
  hetoimasia-sample-image2d-app:exe:hetoimasia-image2d -- \
  --evidence --output-dir DIRECTORY [--validation]
```

(`tools/vulkan/run.sh build hetoimasia-sample-image2d-app:exe:hetoimasia-image2d`
first.) It starts a surface-free session, opens no window and takes no
screenshot. It decodes the three images, uploads them, waits for the table's
placeholder, registers the PNG and the KTX2 image with their default marks, and
renders the scene into one offscreen 256 × 256 `R8G8B8A8_SRGB` target of logical
extent 128 × 128 at content scale 2 and UI scale 1. At that extent the PNG's
world copy covers pixels 48–111 across and 128–191 down, the KTX2 copy 144–207
across and 128–191 down (two pixels to the texel), and the UI copy 16–111 on
both axes (1.5 pixels to the texel). The batch is read back once its completion
is proved. The run passes only when:

- **every pixel** the oracle ([`render-2d-oracle`](../../packages/render-2d-oracle/README.md),
  planned with `noCutoutMarks`, which the recorder is given explicitly as the oracle is, and given the decoded images
  the registered handles name) gives a determinate expectation read back within
  its tolerance, and at least one did. The frame has no edge or boundary the
  oracle must decline, so all 65,536 are determinate;
- **every named probe** — 19 positions, each with a colour read off the region
  tables by hand through the frame's geometry and a contrast, listed with their
  arithmetic in `Hetoimasia.Sample.Image2d.Fixtures` — read back within one step
  per channel of the colour stated there; the oracle agreed with that colour
  within its tolerance; and its contrast was a different colour, determinate in
  the oracle. The expectations never come from the decoder, the oracle or the
  readback: the suite checks the hand-stated colours against the region tables
  and the geometry before the device is involved, and that no probe is within a
  sixteenth of a texel of a texel boundary. The probes cover the PNG's world
  copy (each quadrant and both markers, with a flip and a mirror each ruled
  out, and its size independent of the content scale), the PNG's UI copy (each
  quadrant, a marker, and its extent being 48 logical pixels times the content
  scale), the KTX2 copy (each band and its marker) and the clear background;
- **the swap rule held**: a swap of the quadrants' handle to the fade image is
  refused with the registered mark `True` and the replacement's `False`, the
  registered mark is still `True`, and the same swap with the registered mark
  explicitly kept is accepted and leaves the mark `True`.

The target is written as a lossless PNG, `image2d.png`, and the probes,
the oracle's findings, the swap demonstration and the target's metrics as
`image2d-probes.json`, into the directory named. The exit status is 0 only when
every check passed and the diagnostic verdict is clean.

## The native case

The private-roots case `r2d8-image` of `vulkan-native-tests`
([docs/gpu_backend.md](../../docs/gpu_backend.md#the-native-suite)) runs the
evidence over the suite's own host and then shows the texture lifecycle through
the production host's per-window scenes, in a child process under the 20-second
deadline, with one test-owned window and the actual host adapter and adoption
callbacks — not the windowed mode:

1. a snapshot showing both images is published and adopted;
2. the KTX2 image's release is requested while it is adopted. The adapter marks
   the texture released at once and asks the host for the release; the release
   runs on the owner's thread once the host's barrier is met, finds the
   adopted snapshot holding the texture, and the real table still maps the
   handle; the window renders that snapshot, showing the texture, afterwards;
3. publishing a snapshot that names the released texture is refused, naming it;
4. a snapshot without it is published and adopted, the first snapshot is
   released by the host, and only then does the release take effect: the table
   no longer maps the handle.

It keeps the PNG and the probe record under
`HETOIMASIA_VALIDATION_EVIDENCE/image2d/` when the runner names an evidence
directory.

## The windowed mode

```bash
HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native \
  hetoimasia-sample-image2d-app:exe:hetoimasia-image2d -- \
  --windowed --validation [--ui-scale SCALE]
```

This is the owner-visible path: launched explicitly, never by a test. It opens
one window of 640 × 480 logical pixels and renders until it is closed.
`--validation` enables the validation layer with synchronization validation.
The device starts without a surface. The executable then makes, uploads and
registers the textures, makes the host adapter over the host's
`publishVulkanWindowScene` and `requestVulkanRelease`, hands the window over,
and publishes the scene through `publish2DSnapshot`. The viewport must span the
framebuffer, and no frame has said what the framebuffer is until one has been
rendered, so the first snapshot is built for a guessed extent; the renderer
remembers each frame's extent, logical extent and content scale, and the loop
publishes again whenever the extent changed — on the first frame, and on every
resize. The window's frames come from the adapter's `renderWindowFrame`, which
builds the metrics from those and the frame image's extent. The loop also
asks for a frame whenever the last was presented.

What to see: the PNG's four coloured quadrants with their magenta and white
markers, twice — in the middle of the window, 64 pixels square, and at the
upper left, 48 logical pixels square — and the KTX2 image's four horizontal
bands beside the first, on a black background. The upper-left copy has the same
physical size on a Retina display (content scale 2) as on an ordinary one,
twice as many pixels across, while the middle copy is half the physical size
on the Retina display; `--ui-scale 2` doubles the upper-left copy on either.

## Owned state, threads and lifetimes

| State | Owner | Readers and writers | Thread | Lifetime | Reset or disposal |
| --- | --- | --- | --- | --- | --- |
| The decoded images, the textures, the renderer and the texture registry (`Prepared`) | The executable's run | Made by `prepare` through owner-thread actions and uploads; read by the renderer and the application thread | Owner for the constructions, any for reads | From the host's startup to its exit | Released with the host's managed resources |
| The adapter (holds, pending releases, lock) | The executable's run | The lifecycle hooks and the release actions on the owner's thread; publication and release on the application thread | Owner and application, serialized by the adapter's lock where it must be | Until the run ends | Dropped with the run; each closed window's revisions are released by the host |
| The last frame's extent, logical extent and content scale | The executable's renderer | Written by the renderer on the owner's thread, read by the application thread | Owner writes, application reads | Until the run ends | Overwritten each frame |

The sample starts no thread of its own.

## Not here

Depth, the cutout path and acting on marks (R2D-17, R2D-9); retained content,
materials, clipping and storage tables; offscreen targets in a windowed
snapshot (R2D-13); BC7 images; Lua; text; and background loading or hot reload.
