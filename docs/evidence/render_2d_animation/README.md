# R2D-18 animation evidence: GPU frame selection

The retained evidence for #431 (epic #413, child R2D-18). It covers instances
that name a frame table of their view, which carries the view's animation time:
the recorder computes each table's current frame exactly (`floor (t / duration)
mod count`, the `Double` quotient and an unbounded integer floor), writes the
tables into the batch's storage region, and the vertex stage takes the
instance's rectangle from the frame. The case is `r2d18-animation`
(`packages/gpu-vulkan/glfw/native-test/Test/GPU/Vulkan/Native/AnimationPath.hs`);
the contract is in the [render-2d](../../../packages/render-2d/README.md#animation),
[render-2d-vulkan](../../../packages/render-2d-vulkan/README.md#frame-tables-r2d-18)
and [render-2d-oracle](../../../packages/render-2d-oracle/README.md#animation-r2d-18-d-32)
READMEs.

## Identities

| | macOS | Linux (CI) |
| --- | --- | --- |
| Producer | `test.vulkan-native` (`--complete`, `r2d18-animation`), run locally with `HETOIMASIA_VALIDATION_EVIDENCE` set | `test.vulkan-native` and `test.vulkan-wayland` in workflow run [38463054849](https://github.com/coghex/hetoimasia/actions/runs/38463054849) (attempt 2), artifact `validation-receipts-vulkan` (id 11847870970), files `evidence/test.vulkan-native/animation/` and `evidence/test.vulkan-wayland/animation/` |
| Revision run | `c20f32defb47ecb82a044df83252fe387e4666c7`, the pull request's head | `f9b07596f205d8ef63c25e493143fb5fc28d27b8`, CI's merge of that head (tree `a39135f84b669472f3ef294a4a631d11f9d7ce65`) |
| Native source digest | `73d77b07276505bf7105810feca5aa44107f66f5f63ff20b0e01f04f113d7812` | (CI's receipt) |
| Platform | macOS 26.7.1 (25G313), Apple M3 Max, arm64 | GitHub Actions Linux X64, the CI image's isolated X11 display and headless Wayland compositor |
| Device and driver | Apple M3 Max through MoltenVK (`VK_DRIVER_FILES` the provisioned prefix's `MoltenVK_icd.json`) | `llvmpipe (LLVM 20.1.2, 256 bits)`, the pinned Mesa Lavapipe (`lvp_icd.json`) |
| Validation | the provisioned loader and `VK_LAYER_KHRONOS_validation`, synchronization validation enabled; clean verdict after the last teardown | the same configuration from the CI image's prefix |
| Suite | 169 examples, 0 failures, 2 pending (by design); `r2d18-animation` exited successfully in 0.65 s; the process ran 18.3 s | `r2d18-animation` exited successfully in both groups |
| Readback | 4096 bytes a frame (32 × 32 × 4), complete | the same |

All nine PNGs are **byte-identical** between the two platforms and the Wayland
run (same SHA-256 below). The captures were taken at the pull request's head
`c20f32de`; the pull request's later heads differ from it only by master's
documentation landings (these READMEs and this record), which `docs/` keeps
outside the native source digest.

## The case

One strip texture of four opaque texels in a row, red, green, blue and yellow
(texels 0 to 3), sampled nearest; the target is a 32 × 32 `R8G8B8A8_UNORM` with a
`D32_SFLOAT` depth image, and every instance is cutout-eligible in a
depth-enabled world layer, so the retained tile is drawn from its chunk's own device buffer.
The chunk is built **once** (its upload is admitted once for all nine frames) and
never rebuilt; only the views' times and tables change between frames. A *forward*
table of `n` frames shows texel `k mod 4` in frame `k`, a *backward* one texel
`3 − (k mod 4)`.

Each frame is one fixture of the [probe record](animation-probes.json), which holds
every probe, the named probes and their contrasts, and each target's PNG (its
`png` fields name the capturing run's scratch directory). Every pixel of every
frame is judged against the render-2d oracle; besides, the case checks the colour
of each named probe against the frame **worked out here by hand**, which does not
use the formula the recorder and the oracle share.

### Frames 1 to 6: one view, tables 1 (forward) and 2 (backward), four frames of 0.5 s

Three 8 × 8 tiles: **D**, dynamic, animated by table 1, probed at (8, 8); **N**,
dynamic, not animated, showing texel 2 through its own rectangle, probed at
(24, 8); **C**, the retained chunk's tile, animated by table 2, probed at (8, 24).
With the view's time `t`, `q = t / 0.5` and the frame `floor q mod 4`:

| Frame (PNG) | `t` | `q` | Frame | D | N | C |
| --- | --- | --- | --- | --- | --- | --- |
| `dynamic-t0` | 0 | 0 | 0 | red | blue | yellow |
| `dynamic-t0.75` | 0.75 | 1.5 | 1 | green | blue | blue |
| `dynamic-boundary` | 1.0 | 2 | 2 | blue | blue | green |
| `dynamic-1e6-mid` | 999999.75 | 1999999.5 | 3 (1999999 mod 4) | yellow | blue | red |
| `dynamic-1e6-boundary` | 1000000 | 2000000, exactly | 0 | red | blue | yellow |
| `dynamic-1e6-before` | 999999.9999999999 (the double below 10⁶) | 1999999.9999999998 | 3 | yellow | blue | red |

### Frame 7, `two-views`: one chunk in two views with their own tables and times

The retained tile is drawn in the left half (viewport (0, 0) 16 × 32, camera
(8, 16)) and the right half (viewport (16, 0) 16 × 32, camera (8, 16)) of the
target; world (4, 20) lands on pixels 4..11 × 20..27 on the left and 20..27 × 20..27 on
the right. Each view has two tables and its own time; a dynamic animated tile
(table 1) and a non-animated tile (texel 2) are in the same draw.

| View | Tables (1, 2) | `t` | Frame | Retained tile (table 2) | Dynamic tile (table 1) | Non-animated tile |
| --- | --- | --- | --- | --- | --- | --- |
| left | forward, backward, four frames of 0.5 s | 0.75 | 1 | blue at (8, 24) | green at (8, 8) | blue at (8, 16) |
| right | backward, forward, four frames of 0.25 s | 999999.75 | 3999999 mod 4 = 3 | yellow at (24, 24) | red at (24, 8) | blue at (24, 16) |

### Frames 8 and 9: the review's counterexamples to a 32-bit phase

* `counterexample-8192`: tables of two frames of 8192 s at `t = 991231.9998`; the
  quotient 120.99999997558594 floors to 120, frame 0 (a 32-bit phase rounds
  8191.9997999999905 up to 8192 and selects frame 1). D (table 1: red, green) is
  red and C (table 2: yellow, green) is yellow.
* `huge-duration`: tables of three frames of 2¹²⁷ s at `t = 2.5 × 2¹²⁷`; the
  quotient 2.5, frame 2 (a 32-bit phase of 4.25 × 10³⁸ does not exist). D (table 1:
  red, green, blue) is blue and C (table 2: yellow, red, green) is green.

## Captures

| Frame | PNG | SHA-256 |
| --- | --- | --- |
| `dynamic-t0` | [`animation-dynamic-t0-0.png`](animation-dynamic-t0-0.png) | `eb743cfe15eb8380ab5ad4e6ed609e9c8d000add64e9e1faf93b179c762212b5` |
| `dynamic-t0.75` | [`animation-dynamic-t0.75-0.png`](animation-dynamic-t0.75-0.png) | `5ce4ee38392e0aeb89e06405a4a0d3e827f8ddb3fb25bae2527e5949fa6b5a8d` |
| `dynamic-boundary` | [`animation-dynamic-boundary-0.png`](animation-dynamic-boundary-0.png) | `c58d132113518ff3f5b450556e7871724401de71576da569d07b13537eaf3190` |
| `dynamic-1e6-mid` | [`animation-dynamic-1e6-mid-0.png`](animation-dynamic-1e6-mid-0.png) | `0c000b74b58af29a1ad85f6acaaf1f09f28787818f5e05b5a26296953102fd47` |
| `dynamic-1e6-boundary` | [`animation-dynamic-1e6-boundary-0.png`](animation-dynamic-1e6-boundary-0.png) | `eb743cfe15eb8380ab5ad4e6ed609e9c8d000add64e9e1faf93b179c762212b5` |
| `dynamic-1e6-before` | [`animation-dynamic-1e6-before-0.png`](animation-dynamic-1e6-before-0.png) | `0c000b74b58af29a1ad85f6acaaf1f09f28787818f5e05b5a26296953102fd47` |
| `two-views` | [`animation-two-views-0.png`](animation-two-views-0.png) | `044fc47515e414decc0f446ae6fbdc783b3491e6dd2425be515551808bb29811` |
| `counterexample-8192` | [`animation-counterexample-8192-0.png`](animation-counterexample-8192-0.png) | `4671551e801ba01fb48b4f0ed886f7530a273acf1ff6041490833d6b0373b4e5` |
| `huge-duration` | [`animation-huge-duration-0.png`](animation-huge-duration-0.png) | `7ea3a71f15e8369b549ac76c94f1408685b8f46fd141c889de3c30050b7a083f` |

`animation-probes.json` has SHA-256 `b7e8cd5ba5c1f25f09bee6aec1509bc222251ec197adce41c0bc953bf9c01366`.

The pairs `dynamic-t0` / `dynamic-1e6-boundary` and `dynamic-1e6-mid` /
`dynamic-1e6-before` are the same picture, as they must be: a time exactly on the
boundary `10⁶` (quotient 2000000) is frame 0, as the time 0 is, and the double
just below it is frame 3, as 999999.75 is. Per frame, 944 to 1008 of the 1024
probes are determinate. Every other one is `NearTexelBoundary`: a pixel of a tile's
edge column or row, whose nearest sample the oracle declines to guess because a
frame's rectangle ends on a boundary between two texels that differ. That holds
for any nearest-sampled quad with such a rectangle; no probe is indeterminate
because of animation, and the record's `indeterminate` list names no other reason.
