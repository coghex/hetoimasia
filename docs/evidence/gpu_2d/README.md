# GRS-8 2D evidence: the sprites sample

The retained evidence for #345, the sprites sample (`samples/sprites/`). It
covers premultiplied-alpha blending and indexed, instanced textured quads drawn
through stable texture handles. The sample's
[README](../../../samples/sprites/README.md) is the manifest: fixtures, UV
regions, scene, sampler assignments and probe oracle.

## Identities

| | macOS | Linux (CI) |
| --- | --- | --- |
| Capture | [`sprites-macos.png`](sprites-macos.png) | [`sprites-linux.png`](sprites-linux.png) |
| PNG SHA-256 | `b0fc8bbe9c49b504d1f51968878e9e5ad137e1c0c17ed0948808c25d80fec119` | `b0fc8bbe9c49b504d1f51968878e9e5ad137e1c0c17ed0948808c25d80fec119` |
| Producer | `test.vulkan-native` (`--complete`, `grs8-sprites` case), run locally with `HETOIMASIA_VALIDATION_EVIDENCE` set | `test.vulkan-native` in workflow run [37164798768](https://github.com/coghex/hetoimasia/actions/runs/37164798768) (attempt 1), artifact `validation-receipts-vulkan` (id 11289466308), file `evidence/test.vulkan-native/sprites/sprites.png` |
| Revision run | `bf92adacfeb4306b1261d8aafe0a89583bee7c6a` (tree identical to the pull request head `cac6f18d8c44e5d38121e2ecf52e9927d80bface`) | `982cbf8d1dce47dfc8a5e86a75227f14ed90844d`, CI's merge of the pull request head `cac6f18d8c44e5d38121e2ecf52e9927d80bface` (tree `f945e48dd19119af6597c573fc012829dff8aed1`) |
| Native source digest | `f7d30fad98a5a4c18c2defaf15c39f87e384cb8107411d58e0378f03d92f9dad` | `f7d30fad98a5a4c18c2defaf15c39f87e384cb8107411d58e0378f03d92f9dad` |
| Platform | macOS 26.7.1 (25G313), Apple M3 Max, arm64 | GitHub Actions Linux X64, the CI image's isolated X11 display |
| Device and driver | Apple M3 Max; MoltenVK 1.4.2, device API 1.3.357 | `llvmpipe (LLVM 20.1.2, 256 bits)`; pinned Mesa 25.2.8 Lavapipe (`lvp_icd.json`) |
| Loader and layers | The provisioned prefix's loader and `VK_LAYER_KHRONOS_validation`; implicit layers disabled (`VK_LOADER_LAYERS_DISABLE=~implicit~`), no layer settings file | The same configuration from the CI image's prefix |
| Validation | Synchronization validation enabled; clean verdict after the last teardown | Synchronization validation enabled; clean verdict after the last teardown |
| Suite | 134 examples, 0 failures, 2 pending (by design); process ran 5.5 s | 134 examples, 0 failures, 2 pending; `grs8-sprites` exited successfully |
| BC7 | supported and exercised | supported and exercised |
| Readback | 262,144 bytes, complete | 262,144 bytes, complete |

The native source digest covers the native backend, the window integration,
both samples' packages and the runner (`tools/vulkan/run.sh`). Adding this
record changes the Git revision but not that digest, since `docs/` lies outside
it: both captures describe the delivered implementation sources. The pull
request head and the commit CI merged differ only by master's documentation
landings.

CI's `test.vulkan-wayland` group ran the same case under the isolated headless
Wayland compositor. Its capture, `evidence/test.vulkan-wayland/sprites/sprites.png`
in the same artifact, has SHA-256 `b0fc8bbe9c49b504d1f51968878e9e5ad137e1c0c17ed0948808c25d80fec119`, and its 25 probes all passed.

## Fixtures

| Fixture | Format | Extent | Mip levels | Bytes | SHA-256 of the bytes |
| --- | --- | --- | --- | --- | --- |
| Atlas | Rgba8Linear | 8×8 | 1 (level 0) | 256 | `2496743087dc3b2ddf5e528fbe8c91c07b0dcfac38164aeb5cf6990f0bababf5` |
| Translucent | Rgba8Linear | 2×2 | 1 (level 0) | 16 | `f66f56c40d57546b15bd8092f1027ac3604ee6e0d0b5928259ab22b1bb796747` |
| Bc7Block | Bc7Linear | 4×4 | 1 (level 0) | 16 | `808b350834a573efdd88f3357d5d913f825eea9197867c9cec3111eaea156f19` |

## Draws and samplers

| Draw | Sampler | Sampler index | Instances |
| --- | --- | --- | --- |
| GridDraw | NearestClamp | 0 | 1032 |
| LinearDraw | LinearClamp | 2 | 2 |
| Bc7Draw | NearestClamp | 0 | 1 |

The target is 256×256 `R8G8B8A8_UNORM`, linear, cleared to (0,0,0,0),
single-sample, level 0, with no colour conversion.

## Checks

Expected values come from the sample's oracle, computed from the fixtures,
coordinates and blend equation, never from either image. A tolerance is exact
for opaque nearest samples and the clear, and ±1 per channel where linear
filtering or a translucent-over-non-clear blend contributes. The linear probe's
coordinate is chosen to hold its ±1 at any conformant sub-texel precision (see
the README).

| Check | Pixel | Purpose | Expected | Tolerance | macOS observed | Linux observed | Linux Wayland observed |
| --- | --- | --- | --- | --- | --- | --- | --- |
| grid red region (0,0) | (1,1) | LargeDraw | (255,0,0,255) | exact | (255,0,0,255) pass | (255,0,0,255) pass | (255,0,0,255) pass |
| grid green region (1,0) | (5,1) | LargeDraw | (0,255,0,255) | exact | (0,255,0,255) pass | (0,255,0,255) pass | (0,255,0,255) pass |
| grid blue region (2,0) | (9,1) | LargeDraw | (0,0,255,255) | exact | (0,0,255,255) pass | (0,0,255,255) pass | (0,0,255,255) pass |
| grid yellow region (3,0) | (13,1) | LargeDraw | (255,255,0,255) | exact | (255,255,0,255) pass | (255,255,0,255) pass | (255,255,0,255) pass |
| grid translucent red (7,3) | (29,13) | LargeDraw | (128,0,0,128) | exact | (128,0,0,128) pass | (128,0,0,128) pass | (128,0,0,128) pass |
| grid blue region (14,16) | (57,65) | LargeDraw | (0,0,255,255) | exact | (0,0,255,255) pass | (0,0,255,255) pass | (0,0,255,255) pass |
| grid green region (30,31) | (121,125) | LargeDraw | (0,255,0,255) | exact | (0,255,0,255) pass | (0,255,0,255) pass | (0,255,0,255) pass |
| atlas red region | (147,19) | AtlasSelection | (255,0,0,255) | exact | (255,0,0,255) pass | (255,0,0,255) pass | (255,0,0,255) pass |
| atlas green region | (187,19) | AtlasSelection | (0,255,0,255) | exact | (0,255,0,255) pass | (0,255,0,255) pass | (0,255,0,255) pass |
| atlas blue region | (147,59) | AtlasSelection | (0,0,255,255) | exact | (0,0,255,255) pass | (0,0,255,255) pass | (0,0,255,255) pass |
| atlas yellow region | (187,59) | AtlasSelection | (255,255,0,255) | exact | (255,255,0,255) pass | (255,255,0,255) pass | (255,255,0,255) pass |
| red/green boundary, nearest | (232,24) | FilterDistinction | (255,0,0,255) | exact | (255,0,0,255) pass | (255,0,0,255) pass | (255,0,0,255) pass |
| red/green boundary, linear | (232,64) | FilterDistinction | (191,64,0,255) | ±1 | (191,64,0,255) pass | (191,64,0,255) pass | (191,64,0,255) pass |
| translucent red alone | (144,112) | Translucency | (128,0,0,128) | exact | (128,0,0,128) pass | (128,0,0,128) pass | (128,0,0,128) pass |
| red then blue, one draw | (172,112) | PainterOrder | (64,0,128,192) | ±1 | (64,0,128,192) pass | (64,0,128,192) pass | (64,0,128,192) pass |
| translucent blue alone | (196,112) | Translucency | (0,0,128,128) | exact | (0,0,128,128) pass | (0,0,128,128) pass | (0,0,128,128) pass |
| translucent red alone, before the boundary | (144,176) | Translucency | (128,0,0,128) | exact | (128,0,0,128) pass | (128,0,0,128) pass | (128,0,0,128) pass |
| red then blue, across the draw boundary | (172,176) | PainterOrder | (64,0,128,192) | ±1 | (64,0,128,192) pass | (64,0,128,192) pass | (64,0,128,192) pass |
| translucent blue alone, after the boundary | (196,176) | Translucency | (0,0,128,128) | ±1 | (0,0,128,128) pass | (0,0,128,128) pass | (0,0,128,128) pass |
| clear, between the grid and the atlas | (130,130) | Clear | (0,0,0,0) | exact | (0,0,0,0) pass | (0,0,0,0) pass | (0,0,0,0) pass |
| clear, lower right | (250,250) | Clear | (0,0,0,0) | exact | (0,0,0,0) pass | (0,0,0,0) pass | (0,0,0,0) pass |
| clear, lower left | (100,200) | Clear | (0,0,0,0) | exact | (0,0,0,0) pass | (0,0,0,0) pass | (0,0,0,0) pass |
| clear, right edge | (250,140) | Clear | (0,0,0,0) | exact | (0,0,0,0) pass | (0,0,0,0) pass | (0,0,0,0) pass |
| BC7 left endpoint | (21,224) | Bc7Texels | (255,1,1,255) | exact | (255,1,1,255) pass | (255,1,1,255) pass | (255,1,1,255) pass |
| BC7 right endpoint | (43,224) | Bc7Texels | (1,1,255,255) | exact | (1,1,255,255) pass | (1,1,255,255) pass | (1,1,255,255) pass |

Every check passed on every platform: macOS 25/25, Linux 25/25, Linux Wayland 25/25.

## Inspection (D-6)

Both PNGs were opened and inspected. They agree with the intended scene and
with the probe results:

- the 32×32 grid of atlas regions in the upper-left quarter, cycling red,
  green, blue and yellow along each diagonal, with every eighth column the
  translucent red texture;
- the four atlas regions, each in its own colour, at the upper right;
- beside them, the nearest sample of the red/green boundary in red and the
  linear sample of the same coordinate in a red-green mix;
- two rows of translucent red, overlap and blue — once within one draw and
  once across the draw boundary — whose overlaps are the purple premultiplied
  composition of blue over red, not red over blue;
- the BC7 block's red and blue halves at the lower left;
- the transparent clear everywhere else.

An image viewer composites the translucent regions over its own background, so
they appear lighter there than their stored bytes. The two captures are
byte-identical, as is the Wayland capture. Whole-image equality across
platforms is not required, and is recorded here only as observed.
