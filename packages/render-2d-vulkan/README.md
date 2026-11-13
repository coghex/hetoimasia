# hetoimasia-render-2d-vulkan

The 2D renderer's Vulkan recorder and what a host needs to show
[render-2d](../render-2d/README.md) snapshots in windows: the recorder for the
ordered and cutout paths, texture registration with cutout marks and the swap
rule, retained chunks with their device buffers, application materials, and a
per-window host adapter that publishes snapshots, holds what an adopted
revision references and releases textures and chunks behind the window host's
barrier. The backend's contract is
[docs/gpu_backend.md](../../docs/gpu_backend.md).

| Module (under `Hetoimasia.Render.TwoD.Vulkan`) | Contents |
| --- | --- |
| the root module | `Configuration`, `Renderer`, `makeRenderer`, `pipelineFor`, `pipelineForMaterial`, `registerMaterial`, `prepareSnapshot`, `FrameRecording`; re-exports `Builders`, `Frame` and the shaders |
| `Builders` | the constructions the recorder and the registries need from a host |
| `Frame` | the pure frame work (`frameWork`), `FrameInput`, `FrameRefusal`, attachments and bindings, the region computations |
| `Chunks` | the retained-chunk registry |
| `Textures`, `Textures.Ledger` | the texture registry, marks, the swap rule and the release policy |
| `Window` | the host adapter |
| `Material`, `MaterialSources`, `Material.Sample` | `defineMaterial`, what a declaration comes to, and the reference materials |
| `Layout`, `ShaderInterfaces`, `Shaders` | vertex input, push block, clip-table bytes, scissor rule; the checked interface descriptions; the built-in shaders |

## Boundary

- The library names no GLFW, window-integration, runtime or Lua package, holds
  no native handle of its own and makes no Vulkan call outside the backend's
  vocabulary. The constructions it needs arrive as `Builders`, which a host
  fills from the construction an owner-thread action or a frame lends it.
- The host adapter is **generic over the window's identity and over a `Host`
  record of plain functions**, never over the window integration's types. The
  integration's native suite depends on this package, so a dependency the other
  way would be a cycle. See [samples/image2d](../../samples/image2d/README.md)
  for filling `Host`.
- The package is selected only by `cabal.project.vulkan`, and
  `tools/vulkan/run.sh` is the one command that builds it: it regenerates the
  shader toolchain fingerprint the shader splices check.

## Making the renderer

`makeRenderer builders configuration` makes, in order: the session's ring with
its **storage-table window** (`configurationRegionWindow`, the most bytes of
storage region one batch may bind, 64 KiB by default), the texture table, the
storage table (set 2, over the ring's window), and one shader-sampled table
pipeline layout that also holds set 2, with one 128-byte push-constant range
for both stages. A pipeline is made per colour format, kind and material the
first time a pass draws with it. An unregistered, released or stale handle
samples slot 0's transparent placeholder.

## Recording a frame

`prepareSnapshot builders renderer input` runs on the owner's thread before a
batch records and answers a `FrameRefusal` or a `FrameRecording`. The
`FrameInput` is the validated snapshot, the `CutoutMarks` it is planned with
(`noCutoutMarks` sends every instance down the ordered path), the lookup from
an offscreen `TargetRef` to a `TargetBinding`, and the window's `Attachment`
and depth image when recording inside a frame batch.

Everything that can refuse is decided first, in the pure `frameWork`. The first
refusal in snapshot order is the answer, and nothing has been recorded.

| `FrameRefusal` | When |
| --- | --- |
| `UnknownTarget` | an offscreen pass names a reference the lookup does not hold |
| `NoWindowAttachment` | a window pass with no frame context |
| `InvalidMetrics`, `MetricsDisagree` | the pass's metrics are unusable, or their framebuffer extent is not the attachment's |
| `ViewNotMappable` | `viewMapping` refuses the view under the metrics |
| `NoDepthFormat`, `NoDepthTarget`, `DepthFormatRefused` | see [Depth](#depth-r2d-9) |
| `ChunkBufferMissing` | a layer draws a chunk with cutout instances and the frame holds no device buffer for it |
| `ClipNotRepresentable` | a view's clip test could overflow a float ([Clip tables](#clip-tables-r2d-12)) |
| `ClipTablesTooLarge`, `RecordsTooLarge` | the batch's clip tables, or its whole region, exceed the storage window |
| `FrameTablesNotRepresentable` | a view's frame tables do not fit their 32-bit words |
| `MaterialNotIssued`, `MaterialFactsDisagree` | an instance names a material this session did not issue, or an issued identity with other facts |
| `PlanDisagrees` | the plan's layers and the snapshot's do not pair (never produced by planning the same snapshot) |
| `RefusedByBackend` | the backend refused a pipeline, a claim or a command |

What `FrameRecording` then does, in the one batch:

1. **Claims.** The batch's region (clip tables, then material records, then
   frame tables) is claimed first with the table alignment and written. Every
   layer that draws through the ring has its entries encoded in drawing order
   and written into a ring region of its own. All are claimed before the first
   pass begins; the first the ring cannot hold is a `RefusedByBackend` with no
   clear and no draw recorded. Every retained chunk's buffer the frame draws
   from is then moved to its vertex-input use once, because the backend
   refuses a buffer's first touch inside rendering.
2. **Passes**, in list order, each cleared to its clear colour. A pass whose
   views hold a depth-enabled world layer with a non-empty scissor begins with
   the caller's depth image, cleared to 1.0. A pass that draws binds its first
   pipeline, a viewport over the whole attachment, the texture table and the
   region as the storage table.
3. **Views**, in order, each under a scissor covering exactly the pixels whose
   centres its viewport contains: per axis `[ceil(x − ½), ceil(x + w − ½))`,
   clamped to the attachment (`viewScissor`).
4. **Layers**, in order. A depth-enabled world layer first clears depth within
   its view's scissor, then binds the tables again and pushes its block. A
   layer draws **one instanced draw of six vertices per run**. A run of a
   retained chunk binds the chunk's own buffer. Sampler choices, tints and
   depth keys never split a run.

The recorder never reads back and never transitions a target for a copy: after
it a target is in its colour-attachment use.

## Depth (R2D-9)

**The attachment.** A pass begins with a depth attachment exactly when some
view of it has a non-empty scissor and holds a depth-enabled world layer. The
image is the caller's, a `DepthBinding`:

- an offscreen pass: `TargetBinding.bindingDepth`, a depth target of the colour
  target's extent;
- the window's pass: `FrameInput.frameWindowDepth`, the depth image of the
  frame's swapchain generation, which the host enables with `vulkanWindowDepth`
  and the frame's request names (`requestDepth`).

**The `D32_SFLOAT` requirement.** World-layer depth is `D32_SFLOAT` and nothing
else, never degraded to a lower-precision format. `prepareSnapshot` refuses,
before it records or claims anything and naming the layer, in this order:

1. a snapshot holding a depth-enabled world layer when the **session's depth
   format** (`Builders.buildDepthFormat`, read once by `makeRenderer`) is not
   `D32_SFLOAT` (`DepthFormatRefused`), or the session offers none
   (`NoDepthFormat`);
2. a pass that needs a depth attachment and was given none (`NoDepthTarget`);
3. a pass holding a depth-enabled world layer whose supplied image is not
   `D32_SFLOAT` (`DepthFormatRefused`), whether or not its scissors leave a
   pixel.

The format of a supplied image is the **backend's**, not its maker's:
`prepareSnapshot` asks `Builders.buildImageFormat` for every `DepthBinding`, so
a 24-bit image declared as `D32_SFLOAT` is refused. A snapshot with no
depth-enabled world layer is unaffected on any device. `requireWorldDepth` is
rule 1 on its own, which `publish2DSnapshot` applies at publication
(`WorldDepthRefused`).

**The clear.** Each depth-enabled world layer clears depth to 1.0 within its
view's scissor with `clearDepthRect` before its runs. **The recorder then binds
the texture table, the region and any material push block again:** on MoltenVK
a clear recorded after a draw of the same pass left the descriptor bindings and
push constants unusable by the draws after it.

**The pipelines.** In a pass with a depth attachment every pipeline declares
`D32_SFLOAT`:

| `PipelineKind` | Used for | Blend | Depth |
| --- | --- | --- | --- |
| `CutoutPipeline` | a cutout run | none | tested less-or-equal, written |
| `OrderedTestedPipeline` | an ordered-path run of a depth-enabled world layer | premultiplied alpha | tested, not written |
| `UntestedPipeline` | every other layer of the pass | premultiplied alpha | declared, neither tested nor written |
| `PlainPipeline` | every layer of a pass with no depth attachment | premultiplied alpha | none declared |

**Depth from the key.** The vertex stage writes `(2²⁴ − 1 − k) / 2²⁴` for the
instance's key `k` (`depthFromKey`): exact in a 32-bit float and constant
across the quad. Among cutouts of an equal key the later draw in run order
wins; at an equal key a translucent instance is drawn after, and so over, a
cutout.

## Retained chunks (R2D-10)

A chunk is static content built once and drawn every frame without
republishing. [`render-2d`](../render-2d/README.md) holds its backend-free
description; this package makes it a device buffer, draws from it and manages
its life.

**Building.** `buildRetainedChunk builders retained marks kind bounds
instances` runs on the owner's thread inside an action that lends `Builders`.
It builds and validates the description (`BuildInvalid`), encodes the
cutout-path instances, makes a device-local vertex buffer of exactly that size
and admits the upload that fills it, and registers everything under a fresh
`ChunkRef` (an index and a generation, so a stale reference resolves to
nothing).

- **An empty cutout partition makes no buffer and no upload.** A chunk of a
  world layer without depth, or of a UI layer, has no device buffer: its
  ordered instances are written to the ring each frame.
- A refusal changes nothing the registry holds; a buffer made before a refusal
  or an interruption is released at once.
- `BuildUploadBackpressure` is the staging buffer or its queue being full now,
  so asking again later can succeed. `BuildUploadRefused` is everything else
  (for `UploadOversized`, build smaller chunks). `BuildBufferRefused` and
  `BuildReferencesExhausted` are the remaining refusals.

**Standing.** `chunkStanding` reads, from any thread, `ChunkUploading`,
`ChunkReady` (at once for a chunk with no cutout instance) or `ChunkFailed`
(the ticket ended without completing).

**Pressure.** `renderWindowFrame` of a scene that lists a chunk whose upload is
still pending records nothing and refuses the frame (`RefusedIllegal`, naming
the chunk), which the host retries at its backoff. Publication never waits. A
chunk that *failed* is not pressure, because no retry will complete it: a
snapshot that lists it is not published (`ChunkUploadFailedInSnapshot`), and a
frame of an already adopted scene that lists it is recorded without it, with
`failedChunkUploads` naming it, so the application publishes a snapshot that
lists a rebuilt chunk. Nothing of an incomplete chunk is ever drawn.

**Culling.** A view skips every chunk whose bounds, mapped through its
transform, lie wholly outside its viewport. A chunk referenced by a snapshot is
still held whether or not any view culls it, and so are the textures it names.

**Retention.** After the first frame a chunk's cutout data is neither
re-encoded nor re-uploaded: each frame writes to the ring only the layer's
dynamic cutouts and the merged ordered instances.

## Application materials (R2D-11)

An application defines a material, registers it with the renderer, and names
the reference it is issued in its instances. Materials come only from the
application's build; there is no live shader loading.

**Defining.** `defineMaterial` is a Template Haskell splice over a
`MaterialDeclaration`: whether the material is cutout-capable, the layout of
its records, the members of its push block, and GLSL that defines one function
of a fixed signature:

```glsl
vec4 material(vec4 texel, vec2 uv, uint parameter, MaterialRecord record)
```

It receives the instance's sampled texel (premultiplied, linear light), the
interpolated texture coordinates, the instance's parameter word and the record
that word indexes, and returns the material's colour, premultiplied, in linear
light. Declared around it:

- `MaterialRecord`, a struct of `uvec2 handles[H]` and `uint words[W]`;
- `vec4 sampleTexture(uvec2 handle, vec2 uv)`, which samples a full handle with
  its generation check and the instance's sampler choice. Call it
  unconditionally: its implicit derivatives need uniform control flow;
- `pushed.name` for each member of the push block.

A cutout-capable material promises that its output alpha is binary wherever
its primary texture's is.

The splice generates the material's translucent variant and, only when it is
cutout-capable, its cutout variant. Each is the engine's vertex stage, the
application's function and the engine's own wrapping; the material replaces
the colour alone. It checks both stages of both variants against interface
descriptions it generates from the declaration. A mismatch, GLSL that does not
compile, or a wrong declaration (a push block beyond `applicationPushLimit`, a
record beyond `maxRecordHandles` or `maxRecordWords`, a member name the
engine's block already has, a source with no `material`) fails the build.

**Records in the region.** A record is `2 × handles + words` 32-bit words:
each handle's lookup index then its generation, then the words, no padding.
The region holds every records table the frame's runs read, each once, in the
order its first reader appears: the view's for its dynamic instances, a
chunk's for that chunk's runs. A run pushes its table's start as `recordBase`,
and the shader loads record `parameter` from `recordBase + parameter × stride`.
A run splits wherever the record source changes.

**Registering.** `registerMaterial renderer defined` issues a `MaterialRef`
with the splice's facts and an identity of the renderer's own session, so
another renderer's reference never matches. Registering an equal material again
answers the same reference. Nothing native is made until first use. A snapshot
naming a reference the renderer did not issue is refused by `prepareSnapshot`
and by `publish2DSnapshot` (`MaterialNotIssuedInSnapshot`). A material is never
released. A record's handles count among its snapshot's or chunk's textures, so
an adopted revision holds them.

The sample materials (`Material.Sample`) are the reference; their oracle model
is `Hetoimasia.Render.TwoD.Oracle.Material.Sample`.

## Registering textures and marks

`registerTexture builders textures image decoded policy` registers an uploaded
texture with the table and answers a `TextureHandle` made from the backend's
index and generation. The **mark** is the texture's cutout mark: by default
`decodedBinaryAlpha decoded` (whether every alpha of level 0 is 0 or 255), or
an explicit `OverrideMark`. It is stored with the complete handle for the
handle's life. The host adapter plans each window frame with
`registeredMarks`, so a marked texture's cutout-capable instances in a
depth-enabled world layer take the cutout path.

## The swap rule

`swapTexture builders textures handle image decoded policy` gives a registered
handle a replacement through the table's swap. A replacement whose computed
mark differs from the registered one is refused as `MarkMismatch` unless the
policy is `KeepRegisteredMark`, the caller's statement that the rendering
semantics did not change. A genuine change takes a new handle. The rule is
checked before the table is asked, so any refusal leaves the image, the mark
and a pending swap as they were. Precedence: `TextureUnknown`, then
`TextureReleased`, then `MarkMismatch`, then the table's answer.

## What is reported released

The registry keeps one entry per lookup index, never a set of released
handles. `isReleased` and publication's `TextureReleasedInSnapshot` follow
these rules:

- **A stale handle is refused**: a handle at a registered index whose
  generation is not the one registered there last is reported released,
  whether or not its release was marked. "Last" is the order of registration,
  not a numeric comparison, so it holds when the generation wraps.
- **The current generation keeps its marker** until a later generation is
  registered at the index. An unmarked current handle is not reported
  released.
- **An index never registered here** reports nothing released.
- **A reissued handle** (the same index and generation, after a wrap) is the
  new live handle until marked again.

## The host adapter

The adapter makes one host's windows show `render-2d` snapshots. A host gives
it `Host window`: `hostPublish` (publish a `Scene2D` for a window),
`hostRequestRelease` (queue an owner-thread action behind the revisions the
host must have adopted first), `hostRunOnOwner` (queue one that waits for
nothing) and `hostWindowDepth`. **The host fills `hostWindowDepth` from the
same setting that configures `vulkanWindowDepth`**; the adapter cannot see that
setting. The host's lifecycle hooks call `adapterAdopted` and
`adapterReleased`, and its renderer calls `renderWindowFrame`.

**Publishing.** `publish2DSnapshot adapter window snapshot` validates and
publishes for one window. It is refused, checking in this order:

1. `SnapshotInvalid`, including a chunk reference the registry does not hold or
   that was built for another kind of layer;
2. `OffscreenPassHeld`: windowed snapshots hold no offscreen pass;
3. `NoWindowPass`: an empty snapshot included. Removing every layer publishes a
   window pass with none;
4. `WorldDepthRefused`: a depth-enabled world layer and a session depth format
   that is not `D32_SFLOAT`;
5. `TextureReleasedInSnapshot`: any instance, visible or not, or any chunk's
   instance, references a texture reported released;
6. `ChunkReleasedInSnapshot` and `ChunkUploadFailedInSnapshot`. A chunk whose
   upload is still under way is not refused;
7. `WindowDepthMissing`: a depth-enabled world layer and `hostWindowDepth` is
   `False`;
8. `FrameTablesNotRepresentableInSnapshot` and `TablesTooLarge`: the
   snapshot's own tables exceed their words or the storage window;
9. what the host answers: `PublishWindowUnknown`, `PublishHostClosed` or
   `PublishHostShared`.

Steps 7 and 8 are conditions that would make every frame of the snapshot refuse
at recording. The host retries every refused frame, so they are refused at
publication instead of retried for ever. Step 8's bound (`snapshotTablesBound`)
counts the clip tables, the views' material records and the frame tables as if
every view with a run drew; it is never less than what a frame writes for those
parts.

**A frame whose region is too large.** Which chunks a view culls depends on the
frame's metrics, so a published scene can still have a frame whose region
outgrows the window. That frame records nothing and is retried, and
`regionOverflow adapter window` answers the revision, the region's size and the
window. The observation is cleared only when a later frame of that window
records. The application's way out is a snapshot that culls or lists fewer
chunks.

**Holds.** `adapterAdopted` records a hold on every texture the revision's
snapshot references (including those only a chunk names) and on every chunk it
lists, culled or not; `adapterReleased` drops it. A superseded revision keeps
its hold until its own release, so a chunk's buffer is released only when the
last recording of every revision that lists it is over.

**Releasing.** `release2DTexture` and `release2DChunk` mark the object released
(publication then refuses a snapshot that names it), enter it in the pending
set, and ask the host through `hostRequestRelease`.

- The host runs the request once every window it held at the request has
  adopted the revision current then. The action releases the object only if
  **no adopted revision holds it**; otherwise it keeps rendering, and when the
  last holding revision is released `adapterReleased` queues the rest through
  `hostRunOnOwner`.
- A window that has published and has no live target holds the request until a
  target of it adopts that revision or the window is closed, which is the
  application's to resolve.
- If the host's release queue is full (`ReleaseQueueFull`) the object stays
  eligible, and `retryReleases` queues it again without blocking. Both hooks
  and every release action call it; an application may call it from its loop.
- A request the host refused leaves the object marked and pending, and
  releasing the same handle again repeats it. A handle never registered, or
  whose release has run, is `ReleaseUnknown`.
- A chunk released while its upload is pending cancels the upload. Rebuilding a
  chunk is building a new one, publishing a snapshot that lists it and
  releasing the old; there are no range writes.

Publication and release are **serialized by one lock**, with the release marker
and the host's capture of the barrier inside it. A snapshot accepted before the
marker is adopted, and acquires its holds, before the release can run; one
offered after the marker is refused.

**Metrics.** `renderWindowFrame` records the scene's window pass with
`TargetMetrics` built from the frame's framebuffer extent, the window's logical
extent and its content scale. A frame whose request carries no logical extent
or content scale, or unusable ones, is refused (`RefusedIllegal`) before
anything is recorded, and the host retries it.

## Targets and metrics

A pass's attachment is described by an `Attachment`: the colour format's
`VkFormat` code, the actual extent and the `TargetMetrics` its views map under.
`offscreenAttachment format width height` is the ordinary offscreen case:
logical extent equal to the pixel extent, content scale 1. The metrics'
framebuffer extent must be the attachment's.

## The instance as vertex input

One binding advances per instance at render-2d's 64-byte stride
(`instanceVertexInput`), in [render-2d's layout](../render-2d/README.md#the-instance-encoding):

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

## The push block

Both stages declare one push block, std430, 128 bytes. The engine owns the
first 80 (`ViewPush`, `packViewPush`), pushed for each layer:

| Offset | Size | Member |
| --- | --- | --- |
| 0 | 16 | `vec4 viewLinear`: a, b, c, d of the layer's transform to target pixels |
| 16 | 8 | `vec2 viewTranslation`: tx, ty |
| 24 | 8 | `vec2 extent`: the attachment's width and height in pixels |
| 32 | 4 | `float brightness` |
| 36 | 4 | `uint filtering`: the view's default filter, 1 nearest, 2 linear |
| 40 | 4 | `uint snap`: 1 when the view snaps instance origins |
| 44 | 4 | `uint clipBase`: the layer's clip table's first entry, in entries |
| 48 | 16 | `vec4 inverseLinear`: a, b, c, d of the transform's inverse |
| 64 | 8 | `vec2 clipCentre`: the target-pixel point the clip test is taken about |
| 72 | 4 | `uint recordBase`: the word where a run's material records begin |
| 76 | 4 | `uint frameBase`: the word where the view's frame tables begin; 0 for none |

A material's own push block begins at `applicationPushOffset`, 80, and may hold
`applicationPushLimit`, 48 bytes. Every shader declares the whole 128 bytes, so
**one pipeline layout serves every material** and binding another material's
pipeline never disturbs the descriptor sets or constants already set.

The transform maps `(x, y)` to `(a·x + c·y + tx, b·x + d·y + ty)`; it is
`worldTransform` or `uiTransform` from `viewMapping`.

## Clip tables (R2D-12)

A batch writes the resolved clip tables
([render-2d](../render-2d/README.md#clip-tables)) of every view that draws into
the region, bound as the storage table (set 2, binding 0, a read-only std430
buffer of `vec4`s). One 16-byte little-endian entry per clip: `float left`,
`top`, `right`, `bottom`, a half-open rectangle; an empty clip is all zeros.

- **The reference point.** An edge is written as its distance, in the layer's
  space, from the layer-space point under the centre of the view's scissor
  (`clipReference`), and the fragment stage tests the fragment's offset from
  that centre carried through `inverseLinear`. No coordinate it compares is an
  absolute position, which keeps the test exact for a view of a distant place.
  The difference is taken exactly over `Rational`s and rounded once.
- A view's table is written once for each space, world or UI, one of its
  layers selects a clip from. Tables follow one another with no padding, in
  pass and view order, world before UI.
- An instance whose flags hold clip index `k > 0` reads entry
  `clipBase + k − 1`. Index 0 reads nothing.
- **Range.** A view whose clip test could overflow is refused before anything
  is recorded (`ClipNotRepresentable`): the fragment's largest layer-space
  offset must not exceed half the largest finite float, and the layer's scale
  must not exceed 2¹⁰⁰ pixels a unit (`clipRepresentable`).
- **A frame that draws always has a region**: when no table is written it is
  one zero entry, because a layout that holds set 2 refuses a draw until set 2
  is bound.

## Frame tables (R2D-18)

A view's frame tables ([render-2d](../render-2d/README.md#animation)) are the
last part of the batch's region, after the records.

- Each view that draws and holds a table writes one block, however many layers
  and chunks draw in it, and each such layer pushes the block's word as its
  `frameBase`. So a view's dynamic instances and retained chunks read the same
  tables, and the same chunk drawn in two views reads each view's own. Every
  table is written whether or not an instance uses it.
- Blocks follow the records in pass and view order, each on a 16-byte boundary
  (`frameBlockLayout`, `packFrameBlock`).

**The block**, 32-bit little-endian words from the block's start:

| Words | Contents |
| --- | --- |
| `0 .. n − 1` | the directory: for table `i`, the word where its record begins |
| `n ..` | zero words to the next multiple of four |
| a record | `uint frame` (the table's current frame), `uint count`, two reserved zero words, then `count` rectangles of four floats (`u0 v0 u1 v1`) |

**The frame is computed on the host, in `Double`** (`currentFrame`,
[the formula](../render-2d/README.md#animation)); the shader does no time
arithmetic, and the oracle evaluates the same function.

**The shader's lookup.** The vertex stage reads the instance's index from the
flags, `(flags >> 4) & 0xFFF`. For `k > 0` it reads the record's word from the
directory at `frameBase + k − 1`, then the record's `frame`, then the rectangle
at `record + 4 + 4 × frame`, and interpolates the quad's texture coordinates
from it. For index 0 it uses the instance's own rectangle.

Every size and offset is computed over `Integer`s and checked before a byte is
made (`frameBlockRepresentable`); one that does not fit its 32-bit word is
refused, never narrowed.

## The shaders

Checked shaders, compiled while the package builds against the descriptions in
`ShaderInterfaces`.

**Vertex stage**, the same for every pipeline. For each corner `(x, y)` of the
unit square:

```text
world  = (a·x + c·y + tx,  b·x + d·y + ty)
target = (va·wx + vc·wy + vtx,  vb·wx + vd·wy + vty)
origin = the view transform applied to (tx, ty)
shift  = floor(origin + ½) − origin          when the view snaps, else 0
clip   = ((target + shift) / extent) · 2 − 1  Vulkan's Y down
depth  = (2²⁴ − 1 − k) / 2²⁴
uv     = the instance's own rectangle, or the current frame's
```

The snap rounds exactly half-up: the shader takes `floor(p)` and adds 1 when
the fraction is at least ½, because `p + ½` is not exact in single precision.

**Fragment stage.** The handle resolves through the batch's lookup version; a
stale or out-of-range one is slot 0's placeholder. The sampler choice is the
flags word's low two bits: 0 the view's default, 1 nearest, 2 linear. With `t`
the sampled texel, `c` the tint and `b` the view's brightness:

```text
m = material(t)                    the built-in default: m = t
s = m × c;  s.rgb = s.rgb × b      wrapMaterial: tint, then brightness
s.a = 0 for an additive instance   blendOutput
result = s + destination × (1 − s.a)
```

**Clipping.** Both fragment variants end with the clip test, after the sample
is taken so a discarded invocation still takes part in its quad's derivatives.
With `k = flags >> 16`, `r = rectangles[clipBase + k − 1]`, `c = clipCentre`
and `L = inverseLinear`:

```text
k = 0                                  nothing is read
p = L · (gl_FragCoord.xy − c)
discard unless  r.left ≤ p.x < r.right  and  r.top ≤ p.y < r.bottom
```

A discarded fragment writes neither colour nor depth. A sprite's own origin
snap neither moves the clip nor is undone by it.

**The cutout variant** has the same vertex stage, lookup, sampler choice and
`material`, and then:

```text
s = m × c
discard when s.a < ½               no colour, no depth
result = (s.rgb / s.a) × b, alpha 1
```

**The material-wrapping structure.** The engine owns the vertex stage, the
instance format and the table bindings. `material`, `wrapMaterial` and
`blendOutput` are three separate functions in the fragment stage, so an
application material replaces `material` alone and cannot omit the tint, the
brightness or the blend output.

## Owned state, threads and lifetimes

| State | Owner | Threads | Lifetime and disposal |
| --- | --- | --- | --- |
| The ring, the texture table, the pipeline layout and the pipelines | The host session (made through `Builders`); pipelines cached by a `Renderer` | Owner | Until the host session ends; destroyed with every managed resource before the device |
| Per lookup index: the generation registered last, its mark and its release marker | A `Textures` (`TVar` ledger) | Registration, swap and table release on the owner; marker and reads on any | One entry per index for the life of the `Textures`; the marker is cleared only by registering a later generation |
| Each chunk's description, buffer, upload ticket and release flag; index generations and free indices | A `Retained` (`TVar` ledger) | Build and release on the owner; marker and reads on any | From the build until the buffer's release; the index is reused under the next generation |
| The holds, the pending releases, and each window's latest region overflow | An `Adapter` | Owner writes, any reads | A hold is dropped by its revision's release; an overflow by the window's next recorded frame or its last revision's release |
| The publication lock | An `Adapter` | Application threads | The adapter's life |

Publication and release run on application threads behind the adapter's lock,
never on the owner's thread, which only runs the hooks and the release action
and neither raises nor waits. `frameWork` is pure. The package starts no
thread.

## Tests

`render-2d-vulkan-tests` is the headless suite, in the group
`test.vulkan-headless`. It records through a stand-in native layer with no
device:

```bash
bash tools/vulkan/run.sh test hetoimasia-render-2d-vulkan:test:render-2d-vulkan-tests
```

The device's proof is the surface-free native cases of `vulkan-native-tests`
([docs/gpu_backend.md](../../docs/gpu_backend.md#the-native-suite)), which
render fixtures through this recorder and judge every pixel against
[`hetoimasia-render-2d-oracle`](../render-2d-oracle/README.md):
`r2d7-ordered-path`, `r2d9-cutout-depth`, `r2d8-image` (the
[image2d sample](../../samples/image2d/README.md)), `r2d12-clip`,
`r2d10-retained`, `r2d11-materials` and `r2d18-animation`.

## Not here

Alpha-to-coverage and MSAA; depth formats other than `D32_SFLOAT` for world
layers; live shader loading and mod-supplied materials; a material that changes
the vertex stage or the instance format; stencil-based clipping and per-view
culling of clipped instances; range writes into a chunk; creating offscreen
targets and sampling an offscreen pass's target in a later pass; culling
dynamic instances.
