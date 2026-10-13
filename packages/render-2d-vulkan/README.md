# hetoimasia-render-2d-vulkan

The 2D renderer's Vulkan recorder for the **ordered path** (R2D-7) and the
**cutout path** (R2D-9), and, with it, what a host needs to show decoded images
in windows (R2D-8) and to retain static content across frames (R2D-10): texture
registration with cutout marks and the swap rule, retained chunks with their
device buffers and uploads, and a per-window host adapter that publishes
snapshots, holds what an adopted revision references and releases textures and
chunks behind the window host's barrier. The
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
D-5, D-9, D-10, D-12, D-19, D-22, D-23, D-24, D-26, D-27, D-28, D-29, D-31; P-6); the backend's
contract is [docs/gpu_backend.md](../../docs/gpu_backend.md).

| Module | Contents |
| --- | --- |
| `Hetoimasia.Render.TwoD.Vulkan` | re-exports `Builders`; `Configuration`, `defaultConfiguration`; `Renderer`, `makeRenderer`, `rendererDepthFormat`, `pipelineFor`, `pipelineForMaterial`, `pipelineDeclaration`, `registerMaterial`, `issuedMaterials`; `prepareSnapshot`, `FrameRecording`; re-exports `Hetoimasia.Render.TwoD.Vulkan.Frame`, `orderedShaders` and `cutoutShaders` |
| `Hetoimasia.Render.TwoD.Vulkan.Builders` | `Builders`: the constructions the recorder and the registry need from a host: the ring with its storage-table window (the clip tables' and the material records'), the table, the storage table, the layout, a pipeline, and registering, swapping and releasing an uploaded texture; and making, filling (an upload admitted for a ticket) and releasing a device-local vertex buffer |
| `Hetoimasia.Render.TwoD.Vulkan.Chunks` | the chunk registry: `Retained`, `newRetained`; `buildRetainedChunk`, `buildRetainedChunkWith` (a chunk that carries its own records), `BuildRefusal`; `ChunkStanding`, `chunkStanding`; `retainedChunks`, `retainedBuffers`, `chunkBufferOf`, `liveChunks`; the logical release marker (`markChunkReleased`, `isChunkReleased`) and `releaseChunkNow` |
| `Hetoimasia.Render.TwoD.Vulkan.Textures` | `Textures`, `newTextures`; `registerTexture` with a `MarkPolicy`; `swapTexture` with a `SwapPolicy`; `TextureRefusal`; the logical release marker (`markReleased`, `isReleased`), `releaseTextureNow`; `registeredMark`, `registeredMarks` |
| `Hetoimasia.Render.TwoD.Vulkan.Window` | the host adapter: `Host`, `Adapter`, `newAdapter`; `Scene2D`, `blankScene`; `publish2DSnapshot`, `PublishRefusal`; `release2DTexture`, `release2DChunk`; `adapterAdopted`, `adapterReleased`, `retryReleases`, `textureHolds`, `chunkHolds`; `FrameInfo`, `renderWindowFrame`, `pendingChunkUploads` |
| `Hetoimasia.Render.TwoD.Vulkan.Frame` | `Attachment`, `offscreenAttachment`, `TargetBinding`, `DepthBinding`, `FrameInput`; `depthLayers`, `requireWorldDepth`, `worldDepthShortfall`; `FrameRefusal`; `frameWork` and the work it computes: `PassWork`, `ViewWork`, `LayerWork`, `RunWork`, `RunReads`, `RunRecords`, `RecordKey`, `PipelineKind`, `runPipeline`; the clip region: `viewDraws`, `clipRegion`, `requireClipWindow`; the region with the material records: `recordRegion`, `RecordRegion`, `requireRegionWindow`; `unissuedMaterial` |
| `Hetoimasia.Render.TwoD.Vulkan.Material` | `defineMaterial`, the Template Haskell splice; `MaterialDeclaration` (`declaredCutoutCapable`, `declaredRecord`, `declaredPush`, `declaredSource`), `PushField`, `PushType`, `PushOffset`, `RecordLayout`; `DefinedMaterial` (`definedFacts`, `definedPush`, `definedTranslucent`, `definedCutout`), `definedPushBytes`; the limits `applicationPushOffset`, `applicationPushLimit`, `maxRecordHandles`, `maxRecordWords` |
| `Hetoimasia.Render.TwoD.Vulkan.MaterialSources` | what a declaration comes to, pure: `layOut`, `Laid`, `declarationProblems`, and the GLSL and interface descriptions the splice compiles and checks (`materialVertexSource`, `materialFragmentSource`, `materialVertexInterface`, `materialFragmentInterface`) |
| `Hetoimasia.Render.TwoD.Vulkan.Material.Sample` | the reference materials: `mixMaterial` (the sample: a second texture through a record, mixed with the instance's texel; cutout-capable), `translucentMixMaterial` (the same function, not cutout-capable) and `tintOnlyMaterial` (a push block and no record) |
| `Hetoimasia.Render.TwoD.Vulkan.Layout` | the instance as vertex input (`instanceVertexInput`), the key's depth (`depthFromKey`), the push block (`ViewPush`, `packViewPush`, `pushMembers`), the clip table's bytes and reference (`packClipTable`, `clipEntryBytes`, `clipReference`, `rebaseClip`), the sampler choice (`shaderSamplerIndex`), the scissor rule (`viewScissor`) |
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
in this order: the session's ring with its **storage-table window**
(`configurationRing` and `configurationRegionWindow`, the most bytes of storage
region one batch may bind, 64 KiB by default: its clip tables, 16 bytes an
entry, and then its material records), the texture table the
draws go through (`configurationTable`), the **storage table** (set 2, over the
ring's window), and a **shader-sampled table pipeline layout** over the
package's shaders (R2D-16) that also holds set 2: a layout holding the table
that declares no sampler offset, so a draw needs no `selectSampler`, with one
push-constant range for both stages (128 bytes, below). A pipeline is made per
colour format, kind and material (below) the first time a pass into that format
draws with it, by `pipelineFor` (the built-in material) or `pipelineForMaterial`. Textures are registered with the
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
| `ChunkBufferMissing location chunk` | a layer draws a chunk that has cutout instances in a view that does not cull it, and the frame holds no device buffer for it (`frameChunks`) |
| `PlanDisagrees location` | the plan's layers and the snapshot's do not pair (planning the same snapshot never produces it) |
| `ClipNotRepresentable pass view` | a drawing view whose layers select clips has a scissor and an inverse transform for which the clip test's layer-space offsets could overflow a float (below) |
| `ClipTablesTooLarge bytes window` | the batch's packed clip tables (below) are `bytes` long, and the window is only `window` bytes |
| `MaterialNotIssued location material` | an instance, or an instance of a chunk a layer lists, names a material the session did not issue, whether another session's reference or one `materialRef` built (the built-in default is every session's) |
| `MaterialFactsDisagree location named issued` | an instance names a reference with the identity of a material the session issued but other facts than it was issued with |
| `RecordsTooLarge bytes window` | the batch's whole region, its clip tables and its material records, is `bytes` long and the window is only `window` bytes |
| `FrameTablesNotRepresentable pass view bytes` | the frame tables a drawing view holds (R2D-18, [below](#frame-tables-r2d-18)) pack into a block of `bytes` bytes in which a size, an offset or a header value does not fit its 32-bit word |
| `RefusedByBackend refusal` | the backend refused a pipeline, a claim or a command |

The first refusal in snapshot order is the answer, and nothing has been recorded.
What `FrameRecording` then does, in the one batch:

1. **Claims.** The batch's **region** (the clip tables and, after them, the material records, [below](#application-materials-r2d-11)) is claimed first, with the backend's
   table alignment (`claimTable`), and written (below). Every layer that draws through the ring has its ring entries
   encoded in drawing order (`encodeLayerInDrawingOrder`, byte for byte the
   matching 64-byte chunks of `encodeLayer`, permuted by the plan's order) and
   written into one ring region of its own, aligned to 16, in pass, view and
   layer order. They are all claimed before the first pass begins, and the first
   the ring cannot hold is a `RefusedByBackend` that stops the rest: no clear and
   no draw has been recorded, and the claims already granted stay the backend's
   to reclaim when the batch completes or to discard with it. A layer none of
   whose runs reads the ring claims nothing. Then every retained chunk's device
   buffer the frame draws from is moved to its vertex-input use
   (`transitionResource`, `GeometryRead`), once, because the backend refuses a
   buffer's first touch inside rendering; the batch's exit barrier returns it to
   rest.
2. **Passes**, in list order. A pass begins rendering into its target cleared to
   the pass's clear colour (an offscreen target `ClearFromUndefined`, so it may
   be new or hold anything; the window's pass into the frame's own image) and
   ends before the next begins. A pass whose views hold a depth-enabled world
   layer with a non-empty scissor begins with the caller's `D32_SFLOAT` depth
   image as its depth attachment, cleared to 1.0 across it
   (`beginRenderingWithDepth`, or `beginFrameRenderingWithDepth` for the
   window); every other pass begins with none, exactly as the ordered path's
   does. A pass that draws something then binds its first run's pipeline, a
   viewport over the **whole** attachment, the table, and the clip region as the
   storage table (`bindStorageTable` at offset 0, so the dynamic offset is the
   region's own start). A pass that draws nothing begins, clears and ends, and
   binds none of them.
3. **Views**, in order, each under a scissor covering exactly the pixels whose
   centres its viewport contains: per axis `[ceil(x − ½), ceil(x + w − ½))`,
   clamped to the attachment (`viewScissor`; `viewportContains`, pixel by
   pixel). A view whose scissor is empty, or that holds no layer to draw,
   records no draw and no scissor.
4. **Layers**, in order. A depth-enabled world layer first **clears depth to
   1.0 within its view's scissor** with `clearDepthRect` (#425), then binds the
   table and the clip region again, then pushes its block; a layer whose scissor is empty records no
   clear and no draw, and a depth-enabled layer with no instance records its
   clear and claims no region. A layer then draws **one instanced draw of six
   vertices per run**: it binds the run's pipeline if another is bound, its
   region at the run's first instance (64 bytes a step), and draws the run's
   count. A run of a retained chunk binds the chunk's own buffer at the run's
   first instance instead. Sampler choices, tints and depth keys never split a
   run, so a layer that lists no chunk is at most two draws until application
   materials exist: its cutout run, which the plan puts first, and its ordered
   run; one that lists chunks adds a cutout run for each listing that has
   cutouts, before them.

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
  frame's request names (`requestDepth`); the host adapter takes it from
  `FrameInfo.frameDepthImage`.

**The `D32_SFLOAT` requirement (choice B, D-23).** World-layer depth is
`D32_SFLOAT` and nothing else, never degraded to a lower-precision format.
`prepareSnapshot` refuses, before it records or claims anything and naming the
layer, in this order:

1. a snapshot holding a depth-enabled world layer, in a view whose scissor may be
   empty or not, when the **session's depth format** (`Builders.buildDepthFormat`,
   read once by `makeRenderer`) is not `D32_SFLOAT` (`DepthFormatRefused`), or the
   session offers none (`NoDepthFormat`);
2. a pass that needs a depth attachment and was given none (`NoDepthTarget`);
3. a pass holding a depth-enabled world layer whose supplied image is not
   `D32_SFLOAT` (`DepthFormatRefused`), whether or not its scissors leave a pixel.

The format of a supplied image is the **backend's**, not its maker's:
`prepareSnapshot` asks `Builders.buildImageFormat` (`imageFormatOf`) for every
`DepthBinding` and replaces the declared `depthFormat` with the answer, so a
24-bit image declared as `D32_SFLOAT` is refused, naming the layer, even in a
layer that only clears; an image the backend no longer holds is the backend's
refusal. A snapshot with no depth-enabled world layer is unaffected on any
device. `requireWorldDepth format snapshot` is rule 1 on its own, and
`worldDepthShortfall` the same answer without the refusal's frame: the host
adapter's `publish2DSnapshot` applies it at publication (`WorldDepthRefused`,
below), so a snapshot holding a depth-enabled world layer is refused there,
naming the layer, on a session whose depth format is not `D32_SFLOAT`;
`depthLayers` lists the layers.

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

## Retained chunks (R2D-10)

A chunk is static content built once and drawn every frame without republishing
(D-1, D-31). [`render-2d`](../render-2d/README.md) holds its backend-free
description (kinds, routing, bounds, the merge order, culling); this package
makes it a device buffer, draws from it and manages its life.

**Building.** `buildRetainedChunk builders retained marks kind bounds instances`
runs on the owner's thread, inside an action that lends the host's `Builders`:

1. it builds the description with `buildChunk` for one kind of layer, routing the
   instances once against the registered marks, and refuses the instances or
   bounds that do not validate, with every reason (`BuildInvalid`);
2. it encodes the cutout-path instances, 64 bytes each in buffer order
   (`encodeChunkCutouts`);
3. if there are any, it makes a device-local `VertexBuffer` of exactly that size
   (`buildVertexBuffer`) and admits the upload that fills it through the bounded
   staging uploads (`uploadBuffer`: admission copies the bytes before it returns
   and never waits). **An empty cutout partition makes no buffer and no upload**
   — the backend refuses a zero-byte buffer — and so a chunk of a world layer
   without depth or of a UI layer, which routes nothing to the cutout path, has
   no device buffer: its ordered instances are written to the ring each frame,
   never retained on the device;
4. it registers the description, the buffer and the upload's ticket under a fresh
   `ChunkRef`: an index and a generation, the index reused after its chunk's
   release under the next generation, so a stale reference resolves to nothing.

A refusal changes nothing the registry holds, and nothing is left behind by
one. The buffer made for a chunk whose upload was refused is released at once,
and so is one made when an exception or a cancellation interrupts the build after
it (the build runs under `mask_`, the buffer's release on `onException`). The
refusals say what to do: `BuildUploadBackpressure` is the staging buffer or its
queue being full *now* — asking again later can succeed — and
`BuildUploadRefused` is everything else, none of which asking again changes: an
`UploadOversized` chunk (more cutout bytes than the whole staging buffer: build
smaller chunks), an upload target that is not fresh, a closed or failed session.
`BuildBufferRefused` is the backend refusing the buffer;
`BuildReferencesExhausted` is every reference in use.

**Standing.** A chunk is `ChunkUploading` until its ticket reports the upload
complete, `ChunkReady` after, and `ChunkFailed` when the ticket ended without
completing (cancelled, the device lost). A chunk with no cutout instance is
`ChunkReady` at once. `chunkStanding` reads it from any thread without a native
call.

**Pressure (D-28).** An upload that is genuinely pending is pressure, and only
that: `renderWindowFrame` of a scene that lists a chunk whose upload has not
completed records nothing, claims nothing and refuses the frame
(`RefusedIllegal`, naming the chunk), which the host skips and retries at its
backoff with the window's demand kept; nothing of an incomplete chunk is ever
drawn, and publication never waits (`pendingChunkUploads` names the chunks a
frame waits for). A chunk that *failed* is not pressure: no retry will complete its
upload, and the host retries every refused frame, so refusing the frame would retry
it for ever. A snapshot that lists it is not published (`ChunkUploadFailedInSnapshot`),
and a frame of an already adopted scene that lists it is **recorded without it**, as
if every view skipped it (`FrameInput`'s `frameOmitted`; `layerCulled` names it), with
`failedChunkUploads` naming it and how its upload ended, so the application publishes
a snapshot that lists a rebuilt chunk. Nothing of an incomplete chunk is ever drawn.

**Culling.** Before anything is worked out, a view skips every chunk whose
bounds, mapped through its transform, lie wholly outside its viewport within the
target (`chunkCulled`), exactly as the oracle does. The skipped listings are not
encoded, claimed or drawn; `layerCulled` names them in a layer's work, and a
layer that skipped a chunk is kept in the work for that reason even if nothing
else in it draws. A chunk referenced by a snapshot is still **held** whether or
not any view culls it, and so are the textures it names.

**Retention.** After the first frame a chunk's cutout data is neither re-encoded
nor re-uploaded: each frame writes to the ring only the layer's dynamic cutouts
and the merged ordered instances, and draws the chunk's cutouts straight from its
buffer. The recorder tests assert this directly (the mapped writes of three
frames hold the ordered instance's 64 bytes and never the 128 of the cutouts; one
upload was admitted), and the native case records the numbers.

## Application materials (R2D-11)

An application defines a material, registers it with the renderer, and names the
reference it is issued in its instances. Materials come only from the
application's build (D-5); there is no live shader loading.

**Defining.** `defineMaterial` is a Template Haskell splice over a
`MaterialDeclaration`: whether the material is cutout-capable, the layout of its
records, the members of its push block, and the GLSL that defines one function of
a fixed signature,

```glsl
vec4 material(vec4 texel, vec2 uv, uint parameter, MaterialRecord record)
```

which receives the instance's sampled texel (premultiplied, in linear light), the
interpolated texture coordinates, the instance's parameter word and the record
that word indexes, and returns the material's colour, premultiplied, in linear
light. Declared around it: `MaterialRecord`, a struct of `uvec2 handles[H]` and
`uint words[W]` (an empty array of the layout is one never-read, zero element);
`vec4 sampleTexture(uvec2 handle, vec2 uv)`, which samples a full handle through
the table's lookup with its generation check and the instance's sampler choice
(call it unconditionally: its implicit derivatives need uniform control flow); and
`pushed.name` for each member of the push block. A cutout-capable material
promises that its output alpha is binary wherever its primary texture's is.

The splice generates the material's **translucent** variant, for the ordered
path, and, only when it is cutout-capable, its **cutout** variant (D-26). Each
is the engine's vertex stage, the application's function and the engine's own
wrapping and output: the tint, the brightness, the additive flag's lack of
coverage, and the cutout discard; the material replaces the colour alone. It then
**checks both stages of both variants against interface descriptions it
generates from the declaration** (GRS-16, D-19): the push-constant members, the
vertex input and the descriptor bindings, which are the texture table's and the
storage region's. A shader that declares more or less than the declaration, or
differently, or GLSL that does not compile, fails the build, naming the stage, the
splice's position and the mismatch; so does a declaration that is itself wrong: a
push block beyond `applicationPushLimit`, a record beyond `maxRecordHandles`
handles or `maxRecordWords` words, a member name that is not a GLSL identifier or
that the engine's block already has, or a source with no `material`. The splice
needs the shader toolchain fingerprint `tools/vulkan/run.sh` generates, as every
splice here does. A `DefinedMaterial` records the facts registration issues a
reference with, where each push member sits (`definedPush`: std430 offsets from
the start of the application's block, which is where a host packs the bytes), and
the two variants' checked shaders.

**Records in the region.** A record is `2 × handles + words` 32-bit words: each
handle's lookup index then its generation, then the words, no padding
(`Hetoimasia.Render.TwoD.Encoding.encodeRecords`). The batch's one set-2 region
holds the clip tables first and then every records table the frame's runs read:
the view's records for its dynamic instances' runs, a chunk's for that chunk's
runs, each table once however many runs read it, in the order the first reader
appears (`recordRegion`). A run pushes the word of the region its table begins at
as `recordBase` before it draws, unless it is the one already pushed. The shader
loads record `parameter` from `recordBase + parameter × stride` and resolves each
handle through the lookup, so a released and reused index samples the placeholder.
A material that has a push block has the view's bytes for it pushed at
`applicationPushOffset` before its first run in the view, and again after each
depth clear, which on MoltenVK disturbs what was set. A run splits wherever the
plan's record source changes, so a chunk's runs and the view's use their own
bases.

**Registering.** `registerMaterial renderer defined` issues a `MaterialRef`
carrying exactly the facts the splice recorded and an identity of the renderer's
own (its session and an index; a global counter makes a session number never
repeat, so another renderer's reference never matches). Registering an equal
material again answers the reference already issued. Nothing native is made: the
material's pipelines are built **per colour format and depth declaration on first
use**, as the built-in ones are, from the variant the kind draws. A snapshot that
names a reference the renderer did not issue, or one with an issued identity and
other facts, is refused by `prepareSnapshot` before anything is recorded
(`MaterialNotIssued`, `MaterialFactsDisagree`) and by `publish2DSnapshot`
(`MaterialNotIssuedInSnapshot`), naming the instance; a material is never
released, so nothing holds one. A chunk's record handles are among its textures
and a view's among its snapshot's, so an adopted revision holds them and a
snapshot that names a texture whose release was requested in a record is refused,
as it is for an instance's.

**Pipelines.** `pipelineForMaterial` makes the pipeline of a material's variant
for a kind and a colour format on first use: the translucent variant for the
plain, ordered-tested and untested kinds, the cutout variant for the cutout kind.
A material that is not cutout-capable has no cutout variant and the plan never
routes it there. Every pipeline is over the one layout.

The sample materials ("Hetoimasia.Render.TwoD.Vulkan.Material.Sample") are the
reference: `mixMaterial` has a record of one handle and one word and a push block
of two floats, and returns `mix(texel.rgb, second.rgb × texel.a, w)` with alpha
`texel.a`, where `w = clamp(strength × word ÷ 255 + bias, 0, 1)`. Its model in the
oracle is "Hetoimasia.Render.TwoD.Oracle.Material.Sample".

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
of every registered handle whose mark is set. The host adapter plans each window
frame with `registeredMarks` (R2D-9), read when the frame is prepared, so a marked
texture's cutout-capable instances in a depth-enabled world layer take the cutout
path; an offscreen frame passes whatever marks its caller states. A registration is refused as the table refuses it, storing
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
answers the revision or why not; `hostRequestRelease`, which queues an
owner-thread action behind the revisions the host must have adopted first,
naming the windows it holds at the request; and `hostRunOnOwner`, which queues
one that waits for nothing.
`newAdapter host textures renderer` makes it over the registry and the renderer
whose session depth format publication checks; the host's lifecycle hooks call
`adapterAdopted` and `adapterReleased`; the host's renderer calls
`renderWindowFrame adapter`. A host that draws depth-enabled world layers
enables `vulkanWindowDepth` in its `VulkanHostConfig`, which gives each frame's
request its generation's depth image.

**Publishing.** `publish2DSnapshot adapter window snapshot` validates the
snapshot and publishes it for one window, answering the window's revision. It
is refused, checking in this order:

1. `SnapshotInvalid`, with validation's reasons, each naming where;
2. `OffscreenPassHeld`, naming the pass, when the snapshot holds an offscreen
   pass: windowed snapshots hold none until R2D-13 issues target references;
3. `NoWindowPass`, when the snapshot has no window pass — an empty snapshot
   included; removing every layer publishes a window pass with none (a second
   window pass is validation's refusal, in 1);
4. `WorldDepthRefused`, naming the layer and the session's depth format
   (`Nothing` when it offers none), when the snapshot holds a depth-enabled world
   layer and that format is not `D32_SFLOAT` (D-23): a snapshot with no such layer
   is unaffected on any device;
5. `TextureReleasedInSnapshot`, naming the texture, when the snapshot
   references one whose release was requested (any instance of any layer of
   any view, visible or not, and any instance of a chunk the snapshot lists);
6. `ChunkReleasedInSnapshot`, naming the chunk, when the snapshot lists one
   whose release was requested, and `ChunkUploadFailedInSnapshot`, naming the
   chunk and how its upload ended, when it lists one whose upload ended without
   completing (a chunk whose upload is still under way is **not** refused:
   publication never waits, D-28);
7. what the host answers: `PublishWindowUnknown`, `PublishHostClosed` or
   `PublishHostShared`.

Step 1 resolves the chunks the snapshot lists against the registry
(`validateSnapshotWith`), the registry read once as a coherent view
(`retainedViewSTM`: the chunks, each one's release flag and each one's standing, in
one transaction, so a release the owner's thread runs meanwhile cannot be seen by one
check and missed by another), so a reference the registry does not hold, never
issued or stale after the chunk's release, or built for another kind of layer, is
validation's refusal naming the layer and the chunk.

**Holds (D-28).** When the owner adopts a revision of a window, `adapterAdopted`
records a hold on every texture the revision's snapshot references — once for
each texture, however often it is referenced, including the textures only a
chunk names — and on every chunk it lists, culled or not, and when the host reports the
revision released (superseded, or its window ended, and its last recording
over), `adapterReleased` drops it. A texture is held while any adopted revision
of any window holds it: two windows sharing one texture hold it twice, a
superseded revision keeps its hold until its own release — so a chunk's buffer is
never released because a later revision omits it, only when the last recording of
every revision that lists it is over — and a closed window's
revisions are released by the host and so drop theirs. Holds are keyed by
window and revision; a texture and a chunk are held alike (`textureHolds`,
`chunkHolds`).

**Releasing (D-28, D-31).** `release2DChunk adapter reference` does for a chunk
what `release2DTexture` does for a texture, below: the chunk is marked released
(publication refuses a snapshot that lists it), entered in the pending set and
the host asked for the release through `hostRequestRelease`, whose action
releases the chunk's buffer — and forgets the chunk, ending its reference — only
if no adopted revision holds it, so a chunk released while the adopted snapshot
shows it keeps being drawn until a snapshot without it is adopted and the
revisions that listed it are over. A release requested while the upload is
pending cancels it, as the backend's release of an upload target does. Rebuilding
a chunk is building a new one, publishing a snapshot that lists it and releasing
the old; there are no range writes (D-31).

`release2DTexture adapter handle` marks the texture
released, which publication's check reads, and enters it in the pending set —
one transaction, so a cancellation before the host is asked leaves a texture
that asking again recovers — and then asks the host for the release through
`hostRequestRelease`. The host runs that request on the owner's thread once
every window it held at the request has adopted the revision current then, and
the action releases the texture in the table only if **no adopted revision
holds it**; otherwise the texture keeps rendering wherever an adopted snapshot
shows it, and the texture is recorded as having met its barrier. When the last
holding revision is released, `adapterReleased` queues the rest through
`hostRunOnOwner`: an action that waits for nothing, because the barrier has been
met and a window that appeared since is not named by it and delays nothing. The
action rechecks the holds on the owner's thread. If the host's queue is full the
texture stays eligible, and `retryReleases` — which both hooks and the end of
every release action call, and an application whose host may refuse for lack of
room can call from its own loop — queues it again, never blocking. So progress
is rechecked whenever either condition changes. A request the host refused
leaves the texture marked and pending, and releasing the same handle again
repeats it; a handle never registered, or whose release has run, is refused as
`ReleaseUnknown`.

Publication and release are **serialized by one lock**, with the release
marker and the host's capture of the barrier inside it. So a snapshot accepted
before the marker is published before the request captures the revisions it
waits for: it is adopted, and acquires its holds, before the release can run,
however late the owner takes it. One offered after the marker is refused.

**Metrics (D-29).** `renderWindowFrame adapter builders info scene recorder`
records the scene's window pass into the frame's image, with `TargetMetrics`
built from the frame's own framebuffer extent, the window's logical extent and
its per-axis content scale. The last two arrive in `FrameRequest`
(`requestLogicalExtent`, `requestContentScale`, `Maybe` because the platform
may not have reported them; the host preserves an unavailable observation
rather than inventing one). A frame whose request carries neither, or whose
metrics are not usable (a non-positive or non-finite scale), is refused —
`RefusedIllegal`, naming what was missing — before anything is recorded, which
the host skips and retries at its backoff. A scene that lists a chunk whose
upload has not completed is refused the same way, naming the chunk, and so is
one whose chunk failed (see Retained chunks).

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

Both stages declare one push block, std430, 128 bytes, which every device
holds. The engine owns the first 80 (`ViewPush`, `packViewPush`), pushed for each
layer under the layer's own space:

| Offset | Size | Member |
| --- | --- | --- |
| 0 | 16 | `vec4 viewLinear`: a, b, c, d of the layer's transform to target pixels |
| 16 | 8 | `vec2 viewTranslation`: tx, ty |
| 24 | 8 | `vec2 extent`: the attachment's width and height in pixels |
| 32 | 4 | `float brightness` |
| 36 | 4 | `uint filtering`: the view's default filter, 1 nearest, 2 linear |
| 40 | 4 | `uint snap`: 1 when the view snaps instance origins |
| 44 | 4 | `uint clipBase`: the index, in entries, of the layer's clip table's first entry in the batch's clip region |
| 48 | 16 | `vec4 inverseLinear`: a, b, c, d of the transform's inverse |
| 64 | 8 | `vec2 clipCentre`: the target-pixel point the clip test is taken about |
| 72 | 4 | `uint recordBase`: the word of the batch's region where the material records a run's instances index begin; a layer's push sets it to 0 and a run that reads records pushes its own at offset 72 |
| 76 | 4 | `uint frameBase`: the word of the batch's region where the layer's view's frame tables (R2D-18) begin; 0 for a view that has none, which no instance indexes |

The rest is the application's: a material's own push block begins at
`applicationPushOffset`, 80 (a 16-byte boundary, so any std430 member is legal
there), and may hold `applicationPushLimit`, 48 bytes. Every shader declares the
whole 128 bytes, vertex and fragment alike, the built-in ones with all of the
application's bytes reserved and a material's with its own members then the rest
reserved, so **one pipeline layout serves every material** and binding another
material's pipeline never disturbs the descriptor sets or the constants already
set. Checked interface descriptions compare exactly that range.

The transform is `worldTransform` for a world layer and `uiTransform` for a UI
layer, from `viewMapping` for the pass's metrics; it maps `(x, y)` to
`(a·x + c·y + tx, b·x + d·y + ty)`. The inverse is `worldInverse` or
`uiInverse`, the exact inverse of the transform the layer draws with; only its
linear part is pushed, and the fragment stage clips about `clipCentre` (below),
never in absolute coordinates of the layer's space.

## Clip tables (R2D-12)

A batch writes the resolved clip tables ([render-2d](../render-2d/README.md#clip-tables))
of every view that **draws** (a non-empty scissor and a layer with a run) into
one ring region, claimed with the backend's table alignment before any layer's
instances, written with `writeClaim`, and bound as the storage table (set 2,
binding 0, a read-only std430 buffer of `vec4`s) wherever the texture table is
bound. The format is one 16-byte entry per clip (`packClipTable`,
`clipEntryBytes`), little-endian:

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | `float left`: the half-open rectangle about the reference point |
| 4 | 4 | `float top` |
| 8 | 4 | `float right` |
| 12 | 4 | `float bottom`; an empty clip is all zeros |

**The reference point.** An edge is written as its distance, in the layer's
space, from the layer-space point under the centre of the view's scissor
(`clipReference`: the exact inverse of the layer's transform applied to the
centre, over `Rational`s), and the fragment stage tests the fragment's offset
from that centre, carried to the layer's space by the inverse's linear part
(`inverseLinear`). No coordinate it compares is an absolute position in the
layer's space. That keeps the test exact where a view looks at a distant place:
a single-precision absolute coordinate near 65536 is spaced 1/128 apart, which
at a zoom of 100 is most of a pixel, so mapping a fragment back to the world and
comparing it with an edge at 65536.1484375 admits a pixel 0.34 pixel outside it,
whereas the edge about the reference (65536) is the exact 0.1484375, and the
fragment's offset a small number. The difference (`rebaseClip`) is taken
exactly, over `Rational`s, from the resolved floats and the exact reference, and
rounded once: a reference rounded first (to a double, say) loses the low bits an
extreme zoom measures its edges against (at zoom 2⁶⁰ about a camera at world x =
1, the reference 1 + 2⁻⁵⁶ would become 1, and the left edge 0 instead of −2⁻⁵⁶,
discarding pixels 8.5 pixels inside the clip). The reference
depends on the layer's transform, so a view's table is written once for **each
space, world or UI, one of its layers selects a clip from** (some instance has a
clip index), the whole table about that space's reference, and a space no layer
selects a clip from gets none.

The tables follow one another with no padding, in pass and view order (a view's
world table before its UI table when both exist): a 16-byte entry needs none, and
the region's own start is aligned by the claim. A layer's push block names its
table's first entry in `clipBase`, in **entries** (units of 16 bytes), and the
scissor's centre in `clipCentre`, so an instance whose flags word holds clip
index `k > 0` reads entry `clipBase + k − 1`, and one index selects each view's
own entry. Clip index 0 reads nothing, so a layer none of whose instances selects
a clip pushes a base of 0 and a centre of the origin and never looks, including
when the whole region is the single zero entry the next paragraph describes.

**Range.** Every number the fragment stage compares is finite. The table's edges
are clamped to the finite floats when they are taken about the reference (an edge
past the largest float is beyond anything a fragment's offset reaches), and a view
whose clip test could overflow is refused before anything is recorded
(`ClipNotRepresentable pass view`): the layer-space offset of a fragment's centre
from the scissor's centre is at most the inverse's linear part applied to half the
scissor's size, per axis, and that bound, both products of an axis together, must
not exceed half the largest finite float, and the layer's scale, the pixels a
unit spans, must not exceed 2¹⁰⁰ (`clipRepresentable`; beyond that, a device that
flushes denormals to zero would move an edge by a visible amount). Within both,
the test agrees with exact geometry to a few millionths of a pixel: the offset is
an exact difference of small numbers, a product by a coefficient that carries a
relative error of 2⁻²⁴, and a comparison with an edge that carries the same. It
refuses a view whose zoom is so small that its scissor spans more than about
10³⁸ units of the layer, where an overflowed offset would compare as an infinity
and admit a fragment outside its clip, and one whose layer spans more than 2¹⁰⁰
pixels a unit. The recorder's examples sweep the test, as the fragment stage
evaluates it on the tables the recorder writes, against exact geometry at every
pixel more than 0.07 pixel from a clip's edge, over zooms from 2⁻¹⁰⁰ to 2¹⁰⁰,
cameras at the origin and far from it, turns, UI scales and viewport origins.

A frame that draws always has a region: when no table is written, the region is
one zero entry (16 bytes), because a layout that holds set 2 refuses a draw until
set 2 is bound. A frame that draws nothing has none and binds none. The region's
size is the actual packed layout, `clipEntryBytes` times the entries of every
table written (one for each space a drawing view's layers select clips from); a
region larger than the window is a `ClipTablesTooLarge` naming its size and the
window, decided before anything is recorded (a table of exactly the window is
accepted, and the tables of a view that records no draw are not counted). The
backend checks the rest when the region is bound: the bytes from the offset to the
claim's end within the window, and the offset's alignment.

## Frame tables (R2D-18)

A view's frame tables ([render-2d](../render-2d/README.md#animation)) are written
into the batch's one region, the one the clip tables and the material records are
in, with the base of the view's block in the push block. There is no second
mechanism: the region is claimed, written and bound as it always was, and the
frame tables are its last part, after the records.

**What is written.** Each view that **draws** and holds a table writes a block
once, however many layers and chunks draw in it, and each such layer pushes the
block's word as its `frameBase`, so the dynamic instances and the retained chunks
of a view read the same tables, and the same chunk drawn in two views reads each
view's own. A view with no table, and a view that does not draw, write none. Every
table of a view that draws is written, whether or not an instance uses it, since a
chunk's instances carry their indices from the time it was built. The blocks follow
the records in pass and view order, each beginning on a 16-byte boundary of the
region with zero words of padding before it (`frameBlockLayout`, `packFrameBlock`).

**The block**, 32-bit little-endian words, std430, from the block's start:

| Words | Contents |
| --- | --- |
| `0 .. n − 1` | the directory: for table `i`, the word, from the block's start, where its record begins |
| `n .. ` | zero words to the next multiple of four (a 16-byte boundary), so each record is 16-byte aligned |
| a record | `uint frame` (the table's current frame), `uint count`, two reserved zero words, then `count` rectangles of four floats (`u0 v0 u1 v1`) |

A record is `4 + 4 × count` words. The **frame is computed here, on the host, in
`Double`**: `currentFrame` of the view's time and the table
([the formula](../render-2d/README.md#animation)), an exact integer written as a
`uint`; the shader does no time arithmetic, and the oracle evaluates the same
function. A table's `count` is exactly its rectangles; a record never moves another
(a short list is padded with zero rectangles, a long one is cut at the count, though
a validated table has neither).

**The shader's lookup.** The vertex stage declares the region's binding (the
description of both vertex interfaces now names set 2, binding 0, as the fragment
stage's did) and reads the instance's index from the flags, `(flags >> 4) & 0xFFF`.
For an index `k > 0` it reads the record's word from the directory at
`frameBase + k − 1`, then the record's `frame`, then the rectangle at
`record + 4 + 4 × frame`, and interpolates the quad's texture coordinates from that
rectangle instead of the instance's own (`at = mix(rect.xy, rect.zw, corner)`).
For index 0 it uses the instance's own rectangle, so a non-animated instance in the
same draw is unaffected, and the rectangle is chosen once per vertex of a flat quad,
as the instance's own was.

**Window accounting.** The region's size is the clip tables, the material records
and every block with its padding (and the one zero clip entry a drawing batch that
selects no clip still binds), computed exactly. It is held to the configured
window: a region larger than it is refused before anything is recorded
(`RecordsTooLarge`, naming the size and the window; the clip tables alone are
`ClipTablesTooLarge`'s). Every size and offset is computed over `Integer`s and
checked before a byte is made (`frameBlockRepresentable`): each table's count must
fit the header's 32-bit word (and so the frame, which is below it), each record's
offset must fit the directory's, and the block's start, which the push block
carries, and its end must fit; a block where one does not is refused
(`FrameTablesNotRepresentable`, naming the pass, the view and the block's size in
bytes) rather than narrowed or wrapped. A view with more tables than a flags word
can name (4095) writes them all, and no instance reaches the rest.

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
uv     = the instance's own rectangle, or the current frame's      the flags' bits 4–15 name the view's table (R2D-18, above)
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

**Clipping (D-11).** The vertex stage passes the instance's clip index
`flags >> 16` on, flat. Both fragment variants end with the clip test, after the
sample is taken (so a discarded invocation still takes part in its quad's
derivatives): with `k` the clip index, `r = rectangles[clipBase + k − 1]`, `c` the
push block's `clipCentre` and `L` its `inverseLinear`,

```text
k = 0                                             nothing is read
p = L · (gl_FragCoord.xy − c)                     the pixel centre's offset, in the layer's space
discard unless  r.left ≤ p.x < r.right  and  r.top ≤ p.y < r.bottom
```

where the table's edges are measured from the layer-space point under `c` (above),
so the comparison is made between small numbers whatever the camera's position.
A discarded fragment writes neither colour nor depth, in the ordered and the
cutout variant alike (choice C). `L` is the linear part of the exact inverse of
the transform the layer's instances are placed with, and the reference is that
transform's own, so the view's snapped translation, the zoom and the rotation are
in them for a world clip, and the UI scale, the content scale and the viewport's
origin for a UI clip; a sprite's own origin snap neither moves the clip nor is
undone by it. Instances with different clip indices stay in one draw: the index
travels with the instance.

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
| The pipelines, one per colour format, kind and material | A `Renderer` | `pipelineFor` and `pipelineForMaterial`, on the first pass that draws with the triple | Owner | From that first pass until the host session ends | As above |
| Each registered handle's mark and release flag | A `Textures` (a `TVar` ledger keyed by the complete handle) | `registerTexture` adds; `markReleased` flags; `releaseTextureNow` removes the mark; any thread reads in STM | Registration, swap and table release on the owner; marker and reads on any | From the registration until the table release | The flag is never cleared: a released handle stays refused after its index is reused |
| Each chunk's description, device buffer and upload ticket, its release flag, the generation of every index and the indices free to reuse | A `Retained` (a `TVar` ledger keyed by the complete reference) | `buildRetainedChunk` adds (and releases the buffer it made if it refuses or is interrupted); `markChunkReleased` flags; `releaseChunkNow` releases the buffer and forgets the chunk; any thread reads in STM | Build, buffer release and `releaseChunkNow` on the owner; marker and reads on any | From the build until the buffer's release | The flag is never cleared: the reference is forgotten with the chunk and its index reused under the next generation |
| The holds (window and revision to the textures and chunks that revision references), the pending releases with their stage, and the objects whose follow-up action is queued | An `Adapter` | `adapterAdopted` and `adapterReleased` on the owner's thread; the release action on the owner's thread; reads on any | Owner writes, any reads | From the adapter's creation until it is dropped | A revision's hold is dropped by its release; a pending object leaves the set when its release runs |
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

For materials it checks what the splice recorded and checked (the facts, where each
push member sits, the 128-byte block in both stages of every variant, the cutout
variant exactly when cutout-capable, the descriptors), registration (the facts
equal the splice's, the same material answering the same reference, identities
that carry the session), the region and the pushes of a frame of the default and
application materials (the records back to back in the order their first reader
appears, after the clip region, each run's base and each material's push block,
once per view and again after a depth clear), a chunk's records beside the view's
with a chunk listed twice written once, the pipelines per format and kind from the
variant the kind draws, over one layout, the refusals of a reference not issued
(another session's, a forged one, an issued identity with other facts, the default's
identity with other facts, an instance of a chunk), a region beyond the window and
one that fills it exactly, publication and the holds on a record's textures, and,
in separately compiled modules, that a push block beyond the limit, a record member
beyond the layout, an undeclared resource, a wrong signature and an engine member
name each fail to compile with the diagnostic that names it.

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
clear, one pipeline per format and kind, the clip region (the tables of the views
that draw, one for each space a layer selects clips from, their edges taken about
the layer-space point under the scissor's centre — by hand, and for a camera at
(65536, 0) at zoom 100 the exact 0.1484375 — packed in pass and view order, each
layer's first-entry index and centre, the
region claimed first and bound as set 2 where the table is, a region of one zero
entry when nothing is clipped and none when nothing draws, a region exactly the
window accepted and one entry more refused naming its size, the tables of a view
that records no draw uncounted), and the refusals of an unknown target in
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

The device's proof is surface-free native cases of `vulkan-native-tests`
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

A fourth, `r2d12-clip`, renders seven clip fixtures (R2D-12) and judges every pixel
against the oracle's clip model: in **one draw** under a camera turned an eighth
of a turn, an unclipped instance, a clipped one and one under a nested clip; two
views whose one clip index selects each view's own rectangle; a UI clip at content
scale 2 in a viewport away from the origin; a clip under pixel snap and zoom that
neither follows a sprite's origin snap nor ignores the view's snapped translation;
a view of world coordinates near 65536 at a zoom of 100, whose clip edge a coarse
absolute coordinate would misplace by most of a pixel, kept exact by the reference point;
a cutout clipped away, writing no depth, so the farther cutout shows through; and
an empty clip with a clip under one. Each named behaviour is a probe the oracle
must give determinately and that differs from its contrast's.

A fifth, `r2d10-retained`, builds retained chunks once and lists them over eleven
frames of offscreen snapshots beside dynamic content that alone is republished:
retained cutouts and a translucent instance interleaved with dynamic cutouts, a
world chunk without depth and a UI chunk drawn in the ordered path, a texture swap
showing through a chunk and a mark-changing swap refused, a chunk released while
shown and still drawn until a snapshot without it is adopted, and a chunk outside a
view skipped; every pixel is judged against the oracle, and the bytes uploaded once
and written to the ring each frame are recorded in `retained-measurements.json`.
The recorder's headless tests (`Test.Render.TwoD.Vulkan.Retained`) cover building
and upload for each kind (a buffer and one upload only for a chunk with cutout
instances, none and no pressure for an empty partition), pressure while an upload is
pending, queue-full backpressure and an oversized upload and an interrupted build,
each releasing the buffer it made and holding nothing, release while pending and the
reference's reuse under the next generation, a frame that draws a chunk's cutouts
from its own buffer with only the dynamic and merged ordered bytes in the ring, three
frames re-encoding and re-uploading nothing, a chunk listed twice, culling in one view
and not another, publication refusing an unresolved, released or failed chunk, holds
for every revision of every window including a culled chunk and a texture only a chunk
names, and release deferred until the barrier is met and the last holding revision's
recording is over.

A sixth, `r2d11-materials`, defines the three sample materials by the splice,
registers them and renders six frames of offscreen snapshots that name them, every
pixel judged against the oracle given a pure model of each material: the sample
material's second texture through a record in the ordered path (declared not
cutout-capable) and in the cutout path, where the engine's tint wraps the
material's colour; an application push block that changes the colour (one view's
strength against another's); default and application materials in one layer split
into runs by material, with the parameter word selecting a view's record and a
material that has no record taking its push block; two retained chunks that each
carry their own record for the same material and parameter word beside a dynamic
instance of the view's, each showing its own second texture; and a record that
names a texture which is then released, its index reused under the next
generation, the old handle sampling the placeholder and a record naming the new
handle sampling the new texture. Each named behaviour has a contrast the oracle
must give determinately and differently, and the plan's runs (one cutout run for
each material, the sources a chunk's and the view's runs read) fail the frame they
belong to.

A seventh, `r2d18-animation`, renders nine frames (R2D-18) through a strip of four
texels, a pixel's colour naming the texel a frame shows, and judges every pixel
against the oracle, each named colour besides against the frame worked out by hand
in the case's comments (which does not use the formula the recorder and the oracle
share): an animated dynamic sprite and an animated tile of a retained chunk, built
once and never rebuilt (its upload is admitted once for all nine frames), beside a
non-animated instance in the same draw, at the view times 0, 0.75, 1.0 (a boundary),
999999.75, 1000000 (exactly on a boundary) and the double just below it, near 10⁶
seconds; the same chunk drawn in two views with different tables and times showing
different frames; and the two counterexamples to a 32-bit phase, count 2 with
duration 8192 at 991231.9998 s (frame 0) and a duration of 2¹²⁷ at 2.5 times that
(frame 2). Each frame's PNG and the probe record, which names each view's tables,
time and expected frames, are the retained evidence. The recorder's headless tests
cover the frame block against bytes written out by hand (the directory, the padding
to a 16-byte boundary, each record's computed frame, count and rectangles, a short or
long list, a table whose count does not fit), the frame computed at each view's time
against a second evaluation of the formula over a sweep of tables and times (near 10⁶
and beyond 2⁶³), the push offset at bytes 76 to 79, a block written once for a view's
layers and each drawing view's after the last on a 16-byte boundary, no block for a
view that does not draw or holds no table, a retained chunk drawn in two views
reading each view's own block, the aggregate fit of frame tables beside real clip
tables and material records (a region exactly the window accepted, one table more
refused naming the size and the window), and the refusal of a size or an offset that
does not fit its word.

## Not here

Alpha-to-coverage and MSAA; depth formats other than `D32_SFLOAT` for world
layers; live shader loading and mod-supplied materials (D-5), a material that
changes the vertex stage or the instance format, and clip tables in retained content beyond what R2D-12 defines for instances;
stencil-based clipping, hardware clip distances and per-view culling of fully clipped instances;
range writes into a chunk (D-31); creating offscreen targets, issuing their references
and their lifetimes, holds and releases, and sampling an offscreen pass's target
in a later pass (R2D-13); culling dynamic instances; and performance claims
beyond the retained measurements the native case records.
