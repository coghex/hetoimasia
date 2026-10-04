# The sprites sample

GRS-8 (#345): the first 2D scene built on the GPU resource services. The sample
draws indexed, instanced textured quads through stable texture handles (#343),
with premultiplied-alpha blending, into a fixed scene. Its probe oracle and
window-free evidence mode show the result is right, not merely that it was
submitted.

It has two packages, in the triangle sample's dependency direction:

- `renderer/` (`hetoimasia-sample-sprites`) depends on the native backend
  alone. It holds the fixtures, the scene, the independent oracle, the checked
  shaders, the recording, a lossless PNG writer and the evidence runner. The
  window integration's native suite depends on it, as the app does.
- `app/` (`hetoimasia-sample-sprites-app`, executable `hetoimasia-sprites`)
  hands the renderer to the window integration's public host.

Neither package holds a native handle or makes a GLFW or Vulkan call of its own.
Both are listed only in `cabal.project.vulkan`, so only `tools/vulkan/run.sh`
builds them.

## Fixtures

These are technical scaffolding fixtures, not production art. They are
generated or embedded bytes (`Hetoimasia.Sample.Sprites.Fixtures`), each with
exactly one caller-supplied mip level, level 0. Nothing is loaded or encoded at
run time.

Texture coordinates follow Vulkan's convention:

- `(0, 0)` is the upper-left corner, with `u` growing rightwards and `v`
  downwards.
- Texel `(x, y)` covers `[x/w, (x+1)/w) × [y/h, (y+1)/h)`.

| Fixture | Format | Extent | Mip levels | Bytes | SHA-256 of the bytes | Contents |
| --- | --- | --- | --- | --- | --- | --- |
| Atlas | `R8G8B8A8_UNORM` (linear) | 8×8 | 1 (level 0) | 256 | `2496743087dc3b2ddf5e528fbe8c91c07b0dcfac38164aeb5cf6990f0bababf5` | Four opaque 4×4 regions: red `(255,0,0,255)` upper-left, green `(0,255,0,255)` upper-right, blue `(0,0,255,255)` lower-left, yellow `(255,255,0,255)` lower-right |
| Translucent | `R8G8B8A8_UNORM` (linear) | 2×2 | 1 (level 0) | 16 | `f66f56c40d57546b15bd8092f1027ac3604ee6e0d0b5928259ab22b1bb796747` | Premultiplied red `(128,0,0,128)` in the left column and premultiplied blue `(0,0,128,128)` in the right, in both rows |
| BC7 block | `BC7_UNORM_BLOCK` (linear) | 4×4 | 1 (level 0) | 16 | `808b350834a573efdd88f3357d5d913f825eea9197867c9cec3111eaea156f19` | One mode-6 block. Its endpoints are `(255,1,1,255)` and `(1,1,255,255)`. Index 0 covers the left two columns and index 15 the right two, so weights 0 and 64 reproduce the endpoints exactly |

The BC7 bytes are
`c0 3f 00 00 00 fc ff ff 01 ff 00 ff 00 ff 00 ff`. Their decoded texels,
`bc7Decoded`, are the oracle: the left two columns are `(255,1,1,255)` and the
right two `(1,1,255,255)`, in every row. These texels were established
independently of any device. The sample's suite decodes the bytes again with a
mode-6 decoder of its own and requires the same texels. Expected BC7 pixels
always come from that oracle, never from a GPU readback.

UV regions:

| Region | UV rectangle |
| --- | --- |
| Atlas red | `(0, 0)`–`(0.5, 0.5)` |
| Atlas green | `(0.5, 0)`–`(1, 0.5)` |
| Atlas blue | `(0, 0.5)`–`(0.5, 1)` |
| Atlas yellow | `(0.5, 0.5)`–`(1, 1)` |
| Translucent red column | `(0, 0)`–`(0.5, 1)` under nearest filtering |
| Translucent blue column | `(0.5, 0)`–`(1, 1)` under nearest filtering, or the column centre `(0.75, 0.5)` under linear filtering |
| BC7 block | `(0, 0)`–`(1, 1)` |
| Red/green boundary | the single coordinate `(0.46875 + 1/8192, 0.25)` |

Shared samplers used:

| Sampler | Index (push constant at offset 0) | Used by |
| --- | --- | --- |
| nearest, clamp-to-edge | 0 | the grid draw and the BC7 draw |
| linear, clamp-to-edge | 2 | the linear draw |

## The scene

The scene is a 256×256 linear `R8G8B8A8_UNORM` target, cleared to transparent
black `(0,0,0,0)`. It uses a fixed orthographic view, where an instance's
rectangle is in target pixels with the origin at the upper-left. Rendering is
single-sample and samples level 0, with no sRGB conversion and no colour grading
(`Hetoimasia.Sample.Sprites.Scene`).

Each instance carries:

- its texture's handle (lookup index and generation);
- a UV rectangle, mapped linearly across the quad;
- its position and size.

The instance data is written into ring regions the batch claims (#340). The
textures are uploaded through #342 and registered with #343's table. Every
draw binds the table and selects one shared sampler through the consumer's
declared push constants; instances carry no sampler. Nothing is sorted: draws
run in this order, and each draw's instances in the order listed.

1. **Grid draw** (nearest-clamp), 1,032 instances using both RGBA8 handles:
   - a 32×32 grid of 4×4-pixel quads over the upper-left quarter. Cell
     `(column, row)` shows atlas region `(column + row) mod 4`, except every
     column `c` with `c mod 8 = 7`, which shows the translucent red column;
   - the four atlas regions at 32×32 pixels, at `(136,8)`, `(176,8)`,
     `(136,48)` and `(176,48)`;
   - the red/green boundary coordinate at `(216,8)`, 32×32;
   - translucent red at `(136,96)`, 48×32, then translucent blue at `(160,96)`,
     48×32, overlapping it;
   - translucent red at `(136,160)`, 48×32, which the next draw overlaps.
2. **Linear draw** (linear-clamp), 2 instances:
   - translucent blue at its column centre at `(160,160)`, 48×32, over the
     previous draw's last red, so painter order across the draw boundary is
     observable;
   - the red/green boundary coordinate at `(216,48)`, 32×32.
3. **BC7 draw** (nearest-clamp), 1 instance, drawn only when the device takes
   BC7 for sampling and transfer: the BC7 block at `(16,208)`, 32×32.

## The probe oracle

`Hetoimasia.Sample.Sprites.Oracle` computes every expected value from the
manifest alone, never from an observed image:

- the fixtures' texels;
- the texture coordinate each probe's pixel centre maps to;
- each draw's filter (nearest takes the containing texel; linear weighs the
  four texels around `coordinate × extent − 0.5`, clamped to the edge);
- the premultiplied blend `result = source + destination × (1 − source alpha)`,
  applied in painter order over the clear.

A probe is **exact** where only nearest samples reached it and no translucent
source was blended over a non-clear destination: opaque nearest samples and
untouched clear pixels. Wherever linear filtering or such a blend contributes,
each channel may differ by **±1**.

The red/green boundary coordinate is chosen to survive any conformant sub-texel
precision. At `u = 0.46875 + 1/8192` the texel coordinate is `3.25 + 1/1024`:

- nearest filtering takes texel 3, so red `(255,0,0,255)`;
- linear filtering weighs green by `0.25 + 1/1024`. Every sub-texel precision
  of four bits or more (Vulkan's minimum is four) quantizes that weight,
  truncated or rounded, to within 1/1024 of 0.25. So the expected
  `(191,64,0,255)` ±1 holds on any device.

The probes, 23 of them plus 2 for BC7, are each a pixel centre away from every
rasterization edge:

| Probe | Pixel | Expected | Tolerance | What it catches |
| --- | --- | --- | --- | --- |
| grid red / green / blue / yellow cells | (1,1) (5,1) (9,1) (13,1) | the region's colour | exact | the large draw, the wrong UV rectangle |
| grid translucent red (7,3) | (29,13) | (128,0,0,128) | exact | the second RGBA8 handle in the large draw |
| grid blue (14,16), green (30,31) | (57,65) (121,125) | the region's colour | exact | the large draw's far cells |
| atlas red / green / blue / yellow regions | (147,19) (187,19) (147,59) (187,59) | the region's colour | exact | atlas selection |
| red/green boundary, nearest | (232,24) | (255,0,0,255) | exact | the filter distinction |
| red/green boundary, linear | (232,64) | (191,64,0,255) | ±1 | the filter distinction |
| translucent red alone, blue alone | (144,112) (196,112) | (128,0,0,128), (0,0,128,128) | exact | alpha |
| red then blue, one draw | (172,112) | (64,0,128,192) | ±1 | painter order within a draw; reversed it would be (128,0,64,192) |
| translucent red alone, before the boundary | (144,176) | (128,0,0,128) | exact | alpha |
| red then blue, across the draw boundary | (172,176) | (64,0,128,192) | ±1 | painter order across draws |
| translucent blue alone, after the boundary | (196,176) | (0,0,128,128) | ±1 | alpha under linear filtering |
| clear (four pixels) | (130,130) (250,250) (100,200) (250,140) | (0,0,0,0) | exact | uncovered pixels |
| BC7 left / right endpoint | (21,224) (43,224) | (255,1,1,255), (1,1,255,255) | exact | the BC7 fixture, against its decoded oracle |

The pure examples (`hetoimasia-sample-sprites:test:sprites-tests`) check these,
with no device:

- the filter distinction, atlas selection, painter order and alpha
  expectations;
- the scene's draw structure;
- the fixtures and the BC7 decode;
- the PNG writer;
- that a readback holding every expectation passes, and that one with the
  overlap reversed, a channel off by two, or a short readback fails.

## Modes and commands

Evidence mode is window-free:

```bash
HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native \
  hetoimasia-sample-sprites-app:exe:hetoimasia-sprites -- --evidence --output-dir DIRECTORY --validation
```

It does the following (`Hetoimasia.Sample.Sprites.Evidence`):

1. Starts a surface-free session and opens no window.
2. Makes the ring, the table, the textures and a pipeline layout holding the
   table, then uploads the textures and waits for each upload to complete.
3. Waits for the table's placeholder to be written, then registers the
   textures.
4. Records the scene in one frame-less batch and reads the target back only
   after that batch's completion is proved.
5. Writes into the directory:
   - `sprites.png`: a lossless 8-bit RGBA PNG of the linear target's bytes,
     unconverted;
   - `sprites-probes.json`: the probe record — target, fixtures with their
     bytes, draws with their samplers, BC7 status, readback size, and every
     probe's coordinates, expected and observed values, tolerance and result.

It exits non-zero on any of these:

- a refused owner-thread action;
- an incomplete upload;
- an incomplete batch;
- a missing or short readback;
- a failed probe;
- an unclean diagnostic verdict.

The BC7 fixture's documented unsupported case is the only optional check, and
the record says when it was skipped.

The native suite runs the same evidence as its `grs8-sprites` private case,
over its own surface-free session, inside `test.vulkan-native`'s 30-second
budget. When the validation runner sets `HETOIMASIA_VALIDATION_EVIDENCE`, the
PNG and record go beneath it in `sprites/`. The runner lists them in the
receipt, and CI's `validation-receipts-vulkan` artifact carries them. Outside
the runner they go into a kept temporary directory, which the case's journal
names.

Windowed mode is the owner-visible acceptance path. It is launched
explicitly, and tests never launch it:

```bash
HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native \
  hetoimasia-sample-sprites-app:exe:hetoimasia-sprites -- --windowed --validation
```

It starts the device without a surface, makes, uploads and registers the
textures, then admits one window. It renders the same scene, scaled to the
window, until the window is closed, and then exits. It shows:

- the four atlas regions;
- the nearest and linear difference at the red/green boundary (red beside an
  orange red-green mix);
- the correctly ordered translucent overlaps, purple where blue lies over red.

The window's swapchain format is the host's, usually sRGB, so its colours are
not the evidence target's linear bytes.

The validation group commands are:

```bash
bash tools/vulkan/run.sh test hetoimasia-sample-sprites:test:sprites-tests
HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --complete
```

## Owned state

| State | Owner | Construction | Readers and writers | Thread | Lifetime | Disposal |
| --- | --- | --- | --- | --- | --- | --- |
| The ring, the texture table, the textures and the pipeline layout | The host session | `makeSprites`, through the `Builders` an owner-thread action lends | Batches `recordScene` records read them | Graphics owner | Until the host session ends | Released and destroyed with every managed resource before the device |
| The pipelines, one per colour format | A `Sprites` | `pipelineFor`, on a format's first scene | `recordScene` binds them | Graphics owner | Until the session ends | As above |
| The texture handles | A `Sprites` | `registerSprites`, once the uploads have completed | `recordScene` encodes them into instances | Graphics owner | Until the session ends | Never released; the table holds the textures until it retires |
| The windowed mode's published drawing | The app (`TVar (Maybe Sprites)`) | Written once after registration | The host's renderer reads it each frame | Written on the main thread, read on the owner's | The app's run | Dropped with the app |
| The evidence directory's files | The caller | `runEvidence` writes them | Validation and people read them | The calling thread | Kept: nothing deletes them | The caller's |
