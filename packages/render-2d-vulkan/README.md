# hetoimasia-render-2d-vulkan

The 2D renderer's Vulkan recorder for the **ordered path** (R2D-7) and the
**cutout path** (R2D-9), and, with it, what a host needs to show decoded images
in windows (R2D-8): texture registration with cutout marks and the swap rule,
and a per-window host adapter that publishes snapshots, holds what an adopted
revision references and releases textures behind the window host's barrier. The
recorder: a validated [render-2d](../render-2d/README.md) snapshot
recorded into one batch of the
[native backend](../gpu-vulkan/native/README.md), every pass in list order into
an offscreen colour target or the frame's image, every view under its own
scissor, every layer as one instanced draw per run. The ordered path blends
premultiplied alpha; in a depth-enabled world layer, art marked cutout-safe is
drawn first, depth-tested and depth-written, and the ordered path's instances
are depth-tested and not written. It owns the built-in shaders and the wrapping
the engine applies around a material. The decision record is
[the 2D renderer design](../../docs/designs/render_2d_design.md) (D-2, D-3, D-4,
D-5, D-9, D-10, D-12, D-19, D-22, D-23, D-24, D-26, D-27, D-28, D-29; P-6); the backend's
contract is [docs/gpu_backend.md](../../docs/gpu_backend.md).

| Module | Contents |
| --- | --- |
| `Hetoimasia.Render.TwoD.Vulkan` | re-exports `Builders`; `Configuration`, `defaultConfiguration`; `Renderer`, `makeRenderer`, `pipelineFor`, `pipelineDeclaration`; `prepareSnapshot`, `FrameRecording`; re-exports `Hetoimasia.Render.TwoD.Vulkan.Frame`, `orderedShaders` and `cutoutShaders` |
| `Hetoimasia.Render.TwoD.Vulkan.Builders` | `Builders`: the constructions the recorder and the registry need from a host: the ring, the table, the layout, a pipeline, and registering, swapping and releasing an uploaded texture |
| `Hetoimasia.Render.TwoD.Vulkan.Textures` | `Textures`, `newTextures`; `registerTexture` with a `MarkPolicy`; `swapTexture` with a `SwapPolicy`; `TextureRefusal`; the logical release marker (`markReleased`, `isReleased`), `releaseTextureNow`; `registeredMark`, `registeredMarks` |
| `Hetoimasia.Render.TwoD.Vulkan.Window` | the host adapter: `Host`, `Adapter`, `newAdapter`; `Scene2D`, `blankScene`; `publish2DSnapshot`, `PublishRefusal`; `release2DTexture`; `adapterAdopted`, `adapterReleased`; `FrameInfo`, `renderWindowFrame` |
| `Hetoimasia.Render.TwoD.Vulkan.Frame` | `Attachment`, `offscreenAttachment`, `TargetBinding`, `DepthBinding`, `FrameInput`; `depthLayers`, `requireWorldDepth`; `FrameRefusal`; `frameWork` and the work it computes: `PassWork`, `ViewWork`, `LayerWork`, `RunWork`, `PipelineKind`, `runPipeline` |
| `Hetoimasia.Render.TwoD.Vulkan.Layout` | the instance as vertex input (`instanceVertexInput`), the key's depth (`depthFromKey`), the push block (`ViewPush`, `packViewPush`, `pushMembers`), the sampler choice (`shaderSamplerIndex`), the scissor rule (`viewScissor`) |
| `Hetoimasia.Render.TwoD.Vulkan.ShaderInterfaces` | the checked interface descriptions the shaders are compiled against |
| `Hetoimasia.Render.TwoD.Vulkan.Shaders` | `orderedShaders` and `cutoutShaders`: one vertex stage and two fragment stages |

## Boundary

The library's `build-depends` names `base`, `bytestring`, `containers`,
`deepseq` and `stm` (the adapter's state), `text`, `hetoimasia-asset` (the decoded
image a mark is computed from), `hetoimasia-gpu-vulkan-native`, `hetoimasia-math`
(the transforms' coefficients), `hetoimasia-render-2d` and
`hetoimasia-render-api`. It names no GLFW,
window-integration, runtime or Lua package, holds no native handle of its own
(its `Renderer` holds the backend's managed, opaque handles to a pipeline layout
and pipelines, as the sprites sample does) and makes no Vulkan call outside the
backend's vocabulary. The constructions it needs arrive as `Builders`, which a
host fills from the construction an owner-thread action or a frame lends it.

The host adapter is written the same way, **generic over the window's identity
and over a `Host` record of plain functions** (publish a scene for a window,
queue an owner-thread release), never over the window integration's own types.
The integration's native suite lives in the integration's package and depends on
this one, so a dependency the other way would be a cycle; the sample's
executable and that suite each fill `Host` from the integration's public
`publishVulkanWindowScene`, `requestVulkanRelease` and `SceneLifecycle`, in a
few lines each (see [samples/image2d](../../samples/image2d/README.md)).

The package is selected only by `cabal.project.vulkan`: it resolves the Vulkan
binding through the native package, so neither `cabal.project` nor
`cabal.project.cpu` lists it, and `tools/vulkan/run.sh` is the one command that
builds it, regenerating the shader toolchain fingerprint its shader splices
check. `render-2d` gains no dependency.

## Making the renderer

`makeRenderer builders configuration` makes, through the host's constructions,
in this order: the session's ring (`configurationRing`), the texture table the
draws go through (`configurationTable`), and a **shader-sampled table pipeline
layout** over the package's shaders (R2D-16): a layout holding the table that
declares no sampler offset, so a draw needs no `selectSampler`, with one
push-constant range for both stages (44 bytes, below). A pipeline is made per
colour format and kind (below) the first time a pass into that format draws
with it, by `pipelineFor`. Textures are registered with the
table by their owner; the recorder samples whatever handles the snapshot names,
and an unregistered or released handle, or one whose generation the table no
longer holds, samples slot 0's transparent placeholder.

## Recording a frame

`prepareSnapshot builders renderer input` runs on the owner's thread before a
batch records, and answers either a `FrameRefusal` or a `FrameRecording`: what
records the frame into the batch's recorder. The `FrameInput` is the validated
snapshot, the `CutoutMarks` it is planned with (`frameMarks`: the registered
handles' marks on a host, `noCutoutMarks` where nothing is marked, in which case
every instance takes the `Ordered` path, D-22), the lookup that resolves an
offscreen `TargetRef` to a `TargetBinding`, and the window's `Attachment` and
depth image when a host renderer records the frame inside a frame batch. Every
other routing condition is `render-2d`'s, unchanged: a texture marked
cutout-safe, a cutout-capable material, a tint alpha of 255 and no translucent
or additive flag, in a depth-enabled world layer.

Everything that can refuse is decided first, in `frameWork`, which is pure:

| `FrameRefusal` | When |
| --- | --- |
| `UnknownTarget pass ref` | an offscreen pass names a reference the lookup does not hold |
| `NoWindowAttachment pass` | a window pass with no frame context |
| `InvalidMetrics pass` | the pass's metrics have a negative extent or a content scale that is not finite and positive |
| `MetricsDisagree pass metrics extent` | the metrics' framebuffer extent is not the attachment's actual extent |
| `ViewNotMappable pass view` | `viewMapping` refuses the view under the metrics |
| `NoDepthTarget location` | a pass needs a depth attachment (below) for this depth-enabled world layer and was given none |
| `DepthFormatRefused location format` | a pass holding this depth-enabled world layer was given a depth image whose format is not `D32_SFLOAT` (D-23) |
| `PlanDisagrees location` | the plan's layers and the snapshot's do not pair (planning the same snapshot never produces it) |
| `RefusedByBackend refusal` | the backend refused a pipeline, a claim or a command |

The first refusal in snapshot order is the answer, and nothing has been recorded.
What `FrameRecording` then does, in the one batch:

1. **Claims.** Every layer that draws has its instances encoded in drawing
   order (`encodeLayerInDrawingOrder`, byte for byte the matching 64-byte
   chunks of `encodeLayer`, permuted by the plan's order) and written into one
   ring region of its own, aligned to 16, in pass, view and layer order. They
   are all claimed before the first pass begins, and the first the ring cannot
   hold is a `RefusedByBackend` that stops the rest: no clear and no draw has
   been recorded, and the claims already granted stay the backend's to reclaim
   when the batch completes or to discard with it.
2. **Passes**, in list order. A pass begins rendering into its target cleared to
   the pass's clear colour (an offscreen target `ClearFromUndefined`, so it may
   be new or hold anything; the window's pass into the frame's own image) and
   ends before the next begins. A pass whose views hold a depth-enabled world
   layer with a non-empty scissor begins with the caller's `D32_SFLOAT` depth
   image as its depth attachment, cleared to 1.0 across it
   (`beginRenderingWithDepth`, or `beginFrameRenderingWithDepth` for the
   window); every other pass begins with none, exactly as the ordered path's
   does. A pass that draws something then binds its first run's pipeline, a
   viewport over the **whole** attachment, and the table. A pass that draws
   nothing begins, clears and ends, and binds neither.
3. **Views**, in order, each under a scissor covering exactly the pixels whose
   centres its viewport contains: per axis `[ceil(x − ½), ceil(x + w − ½))`,
   clamped to the attachment (`viewScissor`; `viewportContains`, pixel by
   pixel). A view whose scissor is empty, or that holds no layer to draw,
   records no draw and no scissor.
4. **Layers**, in order. A depth-enabled world layer first **clears depth to
   1.0 within its view's scissor** with `clearDepthRect` (#425), then binds the
   table again, then pushes its block; a layer whose scissor is empty records no
   clear and no draw, and a depth-enabled layer with no instance records its
   clear and claims no region. A layer then draws **one instanced draw of six
   vertices per run**: it binds the run's pipeline if another is bound, its
   region at the run's first instance (64 bytes a step), and draws the run's
   count. Sampler choices, tints and depth keys never split a run, so a layer is
   at most two draws until application materials exist: its cutout run, which
   the plan puts first, and its ordered run.

The recorder never reads back and never transitions a target for a copy: after
it a target is in its colour-attachment use, and a caller that reads it back
moves it to `TransferRead`, copies and returns it, as the sprites sample does.

## Depth (R2D-9)

**The attachment (choice A).** A pass begins with a depth attachment exactly when
some view of it has a non-empty scissor and holds a depth-enabled world layer
(`PassWork.workDepth`). The image is the caller's, a `DepthBinding` of the
backend's `DepthTarget` image and the format the caller made it with:

- an offscreen pass: `TargetBinding.bindingDepth`, a depth target of the colour
  target's extent, which the backend checks when the pass begins;
- the window's pass: `FrameInput.frameWindowDepth`, the depth image of the frame's
  swapchain generation, which the host enables with `vulkanWindowDepth` and the
  frame's request names.

**The `D32_SFLOAT` requirement (choice B, D-23).** World-layer depth is
`D32_SFLOAT` and nothing else, never degraded to a lower-precision format. The
recorder refuses, before it records anything and naming the layer: a pass that
needs a depth attachment and was given none (`NoDepthTarget`), and a pass holding
a depth-enabled world layer whose supplied image is declared in another format
(`DepthFormatRefused`), whether or not its scissors leave a pixel. The format is the
caller's word about the image; a false one is refused by the backend when the
first pipeline is bound. A snapshot with no depth-enabled world layer is
unaffected on any device. `requireWorldDepth format snapshot` is the same rule
for a session's depth format (`selectDepthFormat`), which a host applies when it
publishes a snapshot, so a snapshot holding a depth-enabled world layer is
refused at publication, naming the layer, on a device whose depth format is
another; `depthLayers` lists the layers.

**The clear.** Each depth-enabled world layer clears depth to 1.0 within its
view's scissor rectangle with `clearDepthRect` before its runs. Because
`vkCmdClearAttachments` is a draw of the implementation's own on some devices, the
recorder then binds the texture table again in a pass that draws: on MoltenVK a
clear recorded after a draw of the same pass left the descriptor bindings
unusable by the draws after it (found by the `r2d9-cutout-depth` case's two
layers), and Vulkan itself leaves them undisturbed.

**The pipelines.** In a pass with a depth attachment every pipeline declares
`D32_SFLOAT` (`pipelineDeclaration`); `runPipeline` says which a run uses:

| `PipelineKind` | Used for | Shaders | Blend | Depth |
| --- | --- | --- | --- | --- |
| `CutoutPipeline` | a cutout run | `cutoutShaders` | none | tested less-or-equal, written |
| `OrderedTestedPipeline` | an ordered-path run of a depth-enabled world layer | `orderedShaders` | premultiplied alpha | tested less-or-equal, not written |
| `UntestedPipeline` | every other layer of the pass: world layers without depth, UI layers | `orderedShaders` | premultiplied alpha | declared, neither tested nor written |
| `PlainPipeline` | every layer of a pass with no depth attachment | `orderedShaders` | premultiplied alpha | none declared |

A cutout instance has an opaque result, so the cutout pipeline does not blend.

**Depth from the key.** The vertex stage writes `(2²⁴ − 1 − k) / 2²⁴` for the
instance's key `k` as the depth of every corner (`depthFromKey`): in [0, 1),
exact in a 32-bit float because the numerator has 24 bits and the denominator is
a power of two, and constant across the quad. Depth is cleared to 1.0 and
compared less-or-equal. Among cutouts of an equal key the later draw in run order
wins; at an equal key a translucent instance is drawn after, and so over, a
cutout. Both are tested, in the oracle and on the device.

## Registering textures and marks

`registerTexture builders textures image decoded policy` registers an uploaded
texture with the table, through `Builders`, and answers a `render-api`
`TextureHandle` made from the backend's index and generation, so a handle from
before a release never aliases a reused index. The **mark** is the texture's
cutout mark (D-19, D-27): by default `decodedBinaryAlpha decoded`, which
`asset-image` computes — whether every alpha of level 0 is 0 or 255 — or an
explicit `OverrideMark` the application states. It is stored with the complete
handle, generation included, for the handle's life, and nothing but its release
changes it. `registeredMark` answers it and `registeredMarks` the `CutoutMarks`
of every registered handle whose mark is set. **Nothing here acts on a mark**:
the host adapter plans with `noCutoutMarks` (R2D-8), so a mark changes nothing it
renders, and a host that wants the cutout path (R2D-9) passes `registeredMarks`
as the frame's marks. A registration is refused as the table refuses it, storing
nothing.

## The swap rule

`swapTexture builders textures handle image decoded policy` gives a registered
handle a replacement through the table's swap (GRS-9), unchanged, under the
mark rule (D-27): a replacement whose computed mark differs from the registered
one is refused as `MarkMismatch registered computed`, naming both, unless the
policy is `KeepRegisteredMark`, the caller's explicit statement that the
rendering semantics did not change; the registered mark then stays. A genuine
change of rendering semantics takes a new handle. The rule is checked **before
the table is asked**, so a refusal of any kind — a mismatch, a handle never
registered (`TextureUnknown`), a handle already released (`TextureReleased`) or
the table's own — leaves the image, the mark and any swap already pending as
they were.

## The host adapter

The adapter makes one host's windows show `render-2d` snapshots: it publishes
them per window, holds what each adopted revision references, releases textures
behind the host's barrier, and renders each window's adopted snapshot into the
frame's image. A host (the window integration in its per-window mode) gives it
`Host window`: `hostPublish`, which publishes a `Scene2D` for a window and
answers the revision or why not, and `hostRequestRelease`, which queues an
owner-thread action behind the revisions the host must have adopted first.
`newAdapter host textures` makes it over the registry; the host's lifecycle
hooks call `adapterAdopted` and `adapterReleased`; the host's renderer calls
`renderWindowFrame`.

**Publishing.** `publish2DSnapshot adapter window snapshot` validates the
snapshot and publishes it for one window, answering the window's revision. It
is refused, checking in this order:

1. `SnapshotInvalid`, with validation's reasons, each naming where;
2. `OffscreenPassHeld`, naming the pass, when the snapshot holds an offscreen
   pass: windowed snapshots hold none until R2D-13 issues target references;
3. `NoWindowPass`, when the snapshot has no window pass — an empty snapshot
   included; removing every layer publishes a window pass with none;
4. `TextureReleasedInSnapshot`, naming the texture, when the snapshot
   references one whose release was requested (any instance of any layer of
   any view, visible or not);
5. what the host answers: `PublishWindowUnknown`, `PublishHostClosed` or
   `PublishHostShared`.

**Holds (D-28).** When the owner adopts a revision of a window, `adapterAdopted`
records a hold on every texture the revision's snapshot references — once for
each texture, however often it is referenced — and when the host reports the
revision released (superseded, or its window ended, and its last recording
over), `adapterReleased` drops it. A texture is held while any adopted revision
of any window holds it: two windows sharing one texture hold it twice, a
superseded revision keeps its hold until its own release, and a closed window's
revisions are released by the host and so drop theirs. Holds are keyed by
window and revision.

**Releasing (D-28).** `release2DTexture adapter handle` marks the texture
released at once, which publication's check reads, adds it to the pending set
and asks the host for the release. The host runs the request on the owner's
thread once every window it held at the request has adopted the revision
current then, and the adapter's release action releases the texture in the
table only if **no adopted revision holds it**; otherwise the texture keeps
rendering wherever an adopted snapshot shows it. When a hold ends,
`adapterReleased` finds each pending texture no hold names and asks again, so
progress is rechecked whenever either condition changes. The request is
refused for a handle never registered or already released.

Publication and release are **serialized by one lock**, with the release
marker and the host's capture of the barrier inside it. So a snapshot accepted
before the marker is published before the request captures the revisions it
waits for: it is adopted, and acquires its holds, before the release can run,
however late the owner takes it. One offered after the marker is refused.

**Metrics (D-29).** `renderWindowFrame builders renderer info scene recorder`
records the scene's window pass into the frame's image, with `TargetMetrics`
built from the frame's own framebuffer extent, the window's logical extent and
its per-axis content scale. The last two arrive in `FrameRequest`
(`requestLogicalExtent`, `requestContentScale`, `Maybe` because the platform
may not have reported them; the host preserves an unavailable observation
rather than inventing one). A frame whose request carries neither, or whose
metrics are not usable (a non-positive or non-finite scale), is refused —
`RefusedIllegal`, naming what was missing — before anything is recorded, which
the host skips and retries at its backoff.

## Targets and metrics

A pass's attachment is described by an `Attachment`: the colour format's
`VkFormat` code, the actual extent and the `TargetMetrics` its views map under.
`offscreenAttachment format width height` is the ordinary offscreen case, with
`offscreenMetrics`: the logical extent is the pixel extent and the content scale
1. A caller that needs a window's content scale supplies its own metrics —
the surface-free content-scale-2 fixture does, for a 32 × 32 attachment of
logical extent 16 × 16 at scale 2, shared with the oracle — and the window's
pass takes its `Attachment` from the host's observation of the frame. The
metrics must be valid and their framebuffer extent must be the attachment's.

## The instance as vertex input

One binding advances per instance at render-2d's 64-byte stride
(`instanceVertexInput`); the vertex stage reads these attributes, in
[#414](../render-2d/README.md#the-instance-encoding)'s layout:

| Location | Offset | Format | Field |
| --- | --- | --- | --- |
| 0 | 0 | four floats | the transform's a, b, c, d |
| 1 | 16 | two floats | tx, ty |
| 2 | 24 | four floats | the UV rectangle (u0, v0, u1, v1) |
| 3 | 40 | uint | the handle's lookup index |
| 4 | 44 | uint | its generation |
| 5 | 52 | four unorm bytes | the tint, red first |
| 6 | 56 | uint | the flags word |
| 7 | 60 | uint | the material parameter word |
| 8 | 48 | uint | the depth key |

The depth key at offset 48 is read as the depth of every corner of the quad
(`depthFromKey`, below); the ordered path still sorts by it on the host, and a
pass with no depth attachment ignores what the vertex stage writes. The unit
square's six vertices are the shader's own.

## The push block

Both stages declare one push block, std430, 44 bytes (`ViewPush`,
`packViewPush`), pushed for each layer under the layer's own space:

| Offset | Size | Member |
| --- | --- | --- |
| 0 | 16 | `vec4 viewLinear`: a, b, c, d of the layer's transform to target pixels |
| 16 | 8 | `vec2 viewTranslation`: tx, ty |
| 24 | 8 | `vec2 extent`: the attachment's width and height in pixels |
| 32 | 4 | `float brightness` |
| 36 | 4 | `uint filtering`: the view's default filter, 1 nearest, 2 linear |
| 40 | 4 | `uint snap`: 1 when the view snaps instance origins |

The transform is `worldTransform` for a world layer and `uiTransform` for a UI
layer, from `viewMapping` for the pass's metrics; it maps `(x, y)` to
`(a·x + c·y + tx, b·x + d·y + ty)`.

## The shaders

Checked shaders (GRS-16), compiled while the package builds and checked against
the descriptions in `Hetoimasia.Render.TwoD.Vulkan.ShaderInterfaces`, under the
shader-sampled layout.

**Vertex stage.** The same for every pipeline. For each of the six corners `(x, y)` of the unit square
[0, 1]² (two triangles), with the instance's transform and the view's:

```text
world  = (a·x + c·y + tx,  b·x + d·y + ty)
target = (va·wx + vc·wy + vtx,  vb·wx + vd·wy + vty)
origin = the view transform applied to (tx, ty)              the mapped (0, 0)
shift  = floor(origin + ½) − origin                           when the view snaps, else 0
clip   = ((target + shift) / extent) · 2 − 1                  Vulkan's Y down
depth  = (2²⁴ − 1 − k) / 2²⁴                                  for the instance's key k
```

With snap on the camera's translation has already been rounded (inside
`worldTransform`, D-9) and this rounds the sprite's origin, moving the quad
rigidly: the arithmetic of `snapPoint`. The rounding is exact half-up, as
`snapPixel` evaluates it: the shader takes `floor(p)` and adds 1 when the exact
fraction `p − floor(p)` is at least ½, because `p + ½` is not exact in single
precision (the largest `Float` below one half would round up to 1.0). UVs interpolate affinely from `(u0, v0)`
at local (0, 0) to `(u1, v1)` at (1, 1). The handle, the tint, the flags and the
parameter word pass on as flat values.

**Fragment stage.** The handle resolves through the batch's lookup version, as
the backend's reference shaders do: an index past the version's entries, or an
entry of another generation, is slot 0's placeholder before any descriptor is
read. The sampler choice is the flags word's low two bits: 0 takes the view's
default filter, 1 nearest, 2 linear (3, which render-2d never produces, takes
the default). Nearest is the table's sampler 0 (nearest, clamp to edge) and
linear its sampler 2 (linear, clamp to edge), clamped to the last sampler and
marked `nonuniformEXT`, because the choice differs between the instances of one
draw. With `t` the sampled texel (sRGB decoded by the hardware on an sRGB image),
`c` the tint and `b` the view's brightness (D-24):

```text
m = material(t)                    the built-in default: m = t
s = m × c;  s.rgb = s.rgb × b      wrapMaterial: tint, then brightness
s.a = 0 for an additive instance   blendOutput
result = s + destination × (1 − s.a)       the pipeline's premultiplied blend
```

**The cutout variant (D-26).** An instance routed to the cutout path, so with a
tint alpha of 255 and no translucent or additive flag, is drawn by
`cutoutShaders`: the same vertex stage and, in the fragment stage, the same
lookup, sampler choice and `material`, and then

```text
s = m × c                          the tint, as wrapMaterial's first step
discard when s.a < ½               no colour, no depth
result = (s.rgb / s.a) × b, alpha 1    un-premultiplied, then brightened
```

so a filtered edge sample `(0.6, 0.6, 0.6, 0.6)` writes white, not grey. Mip
levels of cutout-marked textures preserve coverage at this threshold (asset D-10),
so a minified cutout keeps its shape. The variant shares the material and
wrapping structure below, so R2D-11 substitutes the material alone.

**The material-wrapping structure (P-6).** The engine owns the vertex stage,
the instance format and the table bindings, and wraps whatever material it is
given: `material`, `wrapMaterial` and `blendOutput` are three separate
functions in the fragment stage, so an application material (R2D-11) replaces
`material` alone and cannot omit the tint, the brightness or the blend output.

## Owned state, threads and lifetimes

| State | Owner | Readers and writers | Thread | Lifetime | Reset or disposal |
| --- | --- | --- | --- | --- | --- |
| The ring, the texture table and the pipeline layout | The host session | `makeRenderer` makes them through `Builders`; batches `prepareSnapshot` records read them | Owner | From `makeRenderer` until the host session ends | Released and destroyed with every managed resource before the device |
| The pipelines, one per colour format and kind | A `Renderer` | `pipelineFor`, on the first pass that draws with the pair | Owner | From that first pass until the host session ends | As above |
| Each registered handle's mark and release flag | A `Textures` (a `TVar` ledger keyed by the complete handle) | `registerTexture` adds; `markReleased` flags; `releaseTextureNow` removes the mark; any thread reads in STM | Registration, swap and table release on the owner; marker and reads on any | From the registration until the table release | The flag is never cleared: a released handle stays refused after its index is reused |
| The holds (window and revision to the textures that revision references) and the pending releases | An `Adapter` | `adapterAdopted` and `adapterReleased` on the owner's thread; the release action on the owner's thread; reads on any | Owner writes, any reads | From the adapter's creation until it is dropped | A revision's hold is dropped by its release; a pending texture leaves the set when its release runs |
| The publication lock | An `Adapter` | `publish2DSnapshot` and `release2DTexture`, each for its whole length | Application threads | The adapter's life | None |

A `Renderer` holds an `IORef` of the pipelines and is used on the graphics
owner's thread only, as every backend construction is. The registry and the
adapter's state are read from any thread; publication and release run on
application threads behind the adapter's lock, never on the owner's thread, which
only runs the hooks and the release action and neither raises nor waits.
`frameWork` is pure and
`FrameRecording` is a closure over its result: neither keeps a native handle
past the action that records it. The package starts no thread and keeps no
other state.

## Tests

`render-2d-vulkan-tests` is the headless suite, registered with the validation
group `test.vulkan-headless`:

```bash
bash tools/vulkan/run.sh test hetoimasia-render-2d-vulkan:test:render-2d-vulkan-tests
```

It checks the scissor rule against `viewportContains` pixel by pixel over a
sweep of viewports and against hand-worked rectangles; the push block against
bytes written out by hand; the attribute descriptions against the bytes
render-2d's own encoder wrote; the sampler-choice mapping for every choice and
default; the pure frame work (passes, views, scissors, drawing-order bytes, push
blocks, content scale) and every refusal at its boundary; and the recording
itself, through a stand-in native layer built over the backend's public seam
(its own recording, frames and uploads, with no device): the command order of
passes, views, layers and draws with their scissors and push blocks, the
drawing-order instance bytes at their ring offsets, mixed sampler choices in one
run and one draw, empty scissors recording no draw while the pass keeps its
clear, one pipeline per format and kind, and the refusals of an unknown target in
a later pass, an unmappable view and a full ring after an earlier layer's claim,
none of which records a clear or a draw. For depth it checks which passes begin
with a depth attachment; the clear rectangle of each depth-enabled layer, before
its draws and not in a view with no scissor; the pipeline each path draws with
and the depth each declares; the marks' plan, cutouts first; the key-to-depth
mapping at 0, 1, 2²³ and 2²⁴ − 1; and the `D32_SFLOAT` refusal, at recording and
at publication, on a device that offers only `X8_D24` (where a depth-free
snapshot still publishes and records, since no pipeline is made for a depth it
cannot attach).

The registry and the adapter are checked over a coordinated stand-in for the
window host, which publishes scenes per window with rising revisions and queues
the release actions it is asked for, while the example plays the owner (it adopts
and releases revisions and runs the queue when it says the barrier is met), over
the backend's real table on the stand-in recording: marks stored by default and
by override and keyed by the complete handle after an index is reused; the swap
refusal naming both marks and leaving the mark, the table and the handle as they
were, the keep, and the refusals of an unknown and a released handle before the
table is asked; publication, its revisions and every refusal; holds taken once
however often a texture is named, dropped on release, counted twice for two
windows, kept by a superseded revision and dropped by a closed window; release
marked at once, deferred while an adopted snapshot shows the texture and made
when the last holding revision is released; a snapshot accepted before a
release stays adoptable and holds the texture; and the frame's metrics
refused, with nothing recorded, when the request names no extent, no scale or an
unusable one.

The device's proof is two surface-free native cases of `vulkan-native-tests`
([docs/gpu_backend.md](../../docs/gpu_backend.md#the-native-suite)), which render
fixtures through this recorder and judge every pixel of every target against
[`hetoimasia-render-2d-oracle`](../render-2d-oracle/README.md): `r2d7-ordered-path`
(eleven fixtures, the ordered path) and `r2d9-cutout-depth` (seven fixtures with a
`D32_SFLOAT` depth image: cutouts and translucent instances interleaved, both
equal-key rules, a discarded fragment leaving farther art visible, a filtered edge
writing white, a minified texture sampling its mips, two depth-enabled layers with
independent keys, and a UI layer and a world layer without depth in the same
depth pass). Each writes a lossless PNG of every target and a probe record naming
the depth format and every indeterminate reason.

A third case, `r2d8-image`, runs the [image2d sample](../../samples/image2d/README.md):
registration, the swap rule and the adapter's holds and deferred release through
the production host's per-window scenes.

## Not here

Alpha-to-coverage and MSAA; depth formats other than `D32_SFLOAT` for world
layers; acting on marks (R2D-9: planning here still uses `noCutoutMarks`, and the
adapter publishes and renders whatever snapshot validates, so windowed depth —
enabling it and calling `requireWorldDepth` at publication — is not wired by the
host adapter yet and is not part of R2D-8); application materials and their
capability (R2D-11), clip tables (R2D-12) and per-batch storage tables (R2D-15);
retained content (R2D-10); creating offscreen targets, issuing their references
and their lifetimes, holds and releases, and sampling an offscreen pass's target
in a later pass (R2D-13); per-view culling; and performance claims, which need
retained measurements.
