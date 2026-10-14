-- | The 2D renderer's Vulkan recorder (R2D-7, R2D-9): a validated snapshot
-- recorded into one batch of the native backend, every pass in list order. The
-- ordered path blends premultiplied alpha; in a depth-enabled world layer the
-- cutout path draws depth-tested and depth-written art before it, and the
-- ordered path's instances are depth-tested and not written.
--
-- It is written against the native backend's public vocabulary alone and
-- names nothing of the window integration. The constructions it needs arrive
-- as 'Builders', which a host fills from the construction an owner-thread
-- action or a frame lends it, as the sprites sample's host does; the package
-- holds no native handle of its own and makes no GLFW or Vulkan call.
--
-- = Making the renderer
--
-- 'makeRenderer' makes, through the host's constructions, the session's ring
-- with the storage-table window the clip tables are bound through (R2D-12),
-- the texture table the draws go through, the storage table (set 2), and a
-- shader-sampled table pipeline layout (R2D-16) that holds set 2, over the
-- package's shaders. A pipeline is made per colour
-- format and per kind ('PipelineKind') the first time a pass into that format
-- draws with it. The textures are registered with the table by their owner; the
-- recorder samples whatever handles the snapshot names, and an unregistered or
-- released handle samples slot 0's transparent placeholder (choice G).
--
-- = Recording a frame
--
-- 'prepareSnapshot' resolves a 'FrameInput' on the owner's thread, before a
-- batch records: every pass's target and metrics, every view's mapping, and
-- the pipelines the passes need ("Hetoimasia.Render.TwoD.Vulkan.Frame"). A
-- refusal there is a 'FrameRefusal' naming where, and nothing has been
-- recorded. What it returns records into the batch's recorder:
--
-- 1. the batch's clip tables, written into one ring region claimed for the
--    storage table, then every layer's ring entries, written in drawing order
--    into one ring region each, all claimed before the first pass begins; a
--    layer none of whose runs reads the ring claims nothing. A full ring is a refusal
--    ('RefusedByBackend') with no clear and no draw recorded, and the batch's
--    claims stay the backend's to reclaim or discard. Then every retained
--    chunk's device buffer that the frame draws from is moved to its
--    vertex-input use (R2D-10), once, before any pass begins, because the
--    backend refuses a buffer's first touch inside rendering;
-- 2. each pass in list order: it begins rendering into its target, cleared to
--    the pass's clear colour (an offscreen target from undefined, the
--    window's frame as the frame's own), and, when a view with a non-empty
--    scissor holds a depth-enabled world layer, with the caller's depth image
--    as its depth attachment, cleared to 1.0 across it. It binds its first
--    run's pipeline, the table, the clip region as the storage table and a
--    viewport over the whole attachment, draws, and ends before the next begins;
-- 3. within a pass, each view in order under its scissor, which covers
--    exactly the pixels whose centres the view's viewport contains; a view
--    whose scissor is empty records no clear and no draw;
-- 4. within a view, each layer in order: a depth-enabled world layer clears
--    depth to 1.0 within the scissor ('clearDepthRect'); then the layer's push
--    block, then one instanced draw of six vertices per run, binding the run's
--    pipeline when it is not the bound one, the instance region at the run's
--    first instance and drawing its count. A run of a retained chunk binds the
--    chunk's own buffer instead, at the run's first instance, and a chunk the
--    view skips is not there at all.
--
-- = Clip tables (R2D-12)
--
-- The resolved clip tables of the views that draw are packed into one region
-- ("Hetoimasia.Render.TwoD.Vulkan.Layout" has the format), claimed with the
-- backend's table alignment before any layer's instances, and bound with
-- 'bindStorageTable' at offset 0 wherever the table is bound. Each layer's push
-- block names its view's first entry. A region larger than the configured clip
-- window is refused before anything is recorded
-- ('Hetoimasia.Render.TwoD.Vulkan.Frame.ClipTablesTooLarge'), naming its size
-- and the window. The fragment stage discards a fragment outside its
-- instance's clip, in the ordered and the cutout variant, so instances of
-- different clips share one draw.
--
-- = Materials (R2D-11)
--
-- 'registerMaterial' registers a material an application defined
-- ("Hetoimasia.Render.TwoD.Vulkan.Material") with the renderer and issues its
-- 'MaterialRef', which carries exactly the facts the splice recorded and an
-- identity of this session's own. A snapshot that names a reference the session
-- did not issue, or one with another material's identity and different facts, is
-- refused before anything is recorded, naming it ('MaterialNotIssued',
-- 'MaterialFactsDisagree'); the built-in default is every session's. A
-- material's pipelines are built per colour format and kind the first time a pass
-- draws with them, as the built-in ones are: the translucent variant for the
-- ordered kinds, the cutout variant for 'CutoutPipeline'.
--
-- Every material's records, for the views and chunks the frame draws, are packed
-- after the clip tables into the batch's one region (the order is
-- "Hetoimasia.Render.TwoD.Vulkan.Frame"'s 'recordRegion'), written with the
-- instances, and bound as the storage table at offset 0 wherever the texture
-- table is. A run that reads records pushes the word of the region its table
-- begins at (@recordBase@) before it draws; a material that has a push block has
-- the view's bytes for it pushed at 'applicationPushOffset' before its first run
-- in the view. Every pipeline of every material shares the one layout, so neither
-- disturbs what is bound.
--
-- = The pipelines
--
-- In a pass with a depth attachment every pipeline declares @D32_SFLOAT@
-- (D-23). A cutout run draws with 'CutoutPipeline': the cutout variant of the
-- shaders, no blending, depth tested less-or-equal and written. An ordered run
-- of a depth-enabled world layer draws with 'OrderedTestedPipeline': the
-- ordered shaders, depth tested less-or-equal and not written. Every other
-- layer of the pass, the world layers without depth and the UI layers, draws
-- with 'UntestedPipeline', which neither tests nor writes. A pass without a
-- depth attachment keeps the ordered path's 'PlainPipeline', which declares
-- none.
--
-- A pass that draws nothing still begins, clears and ends, and binds neither
-- pipeline nor table. The recorder never reads back and never transitions a
-- target for a copy: after it a target is in its colour-attachment use, and a
-- caller that reads it back moves it and copies, as the sprites sample does.
--
-- = State
--
-- +--------------------+--------------+----------------------------+--------+------------------------------+--------------------------+
-- | State              | Owner        | Readers and writers        | Thread | Lifetime                     | Reset or disposal        |
-- +====================+==============+============================+========+==============================+==========================+
-- | The ring, the      | The host     | 'makeRenderer' makes them  | Owner  | From 'makeRenderer' until    | Released and destroyed   |
-- | table and the      | session      | through 'Builders'; the    |        | the host session ends        | with every managed       |
-- | pipeline layout    |              | batches 'prepareSnapshot'  |        |                              | resource before the      |
-- |                    |              | records read them          |        |                              | device                   |
-- +--------------------+--------------+----------------------------+--------+------------------------------+--------------------------+
-- | The pipelines, one | A 'Renderer' | 'prepareSnapshot', on a    | Owner  | A format's first drawing     | As above                 |
-- | per colour format  |              | format's first drawing     |        | pass, until the host session |                          |
-- |                    |              | pass                       |        | ends                         |                          |
-- +--------------------+--------------+----------------------------+--------+------------------------------+--------------------------+
--
-- The frame's work is a value, and the recording a closure over it: neither
-- keeps a native handle past the action that records it.
module Hetoimasia.Render.TwoD.Vulkan
  ( -- * Constructions
    Builders (..)
    -- * Making the renderer
  , Configuration (..)
  , defaultConfiguration
  , Renderer
  , makeRenderer
  , rendererLayout
  , rendererDepthFormat
  , rendererRegionWindow
  , pipelineFor
  , pipelineForMaterial
  , pipelineDeclaration
    -- * Materials
  , registerMaterial
  , issuedMaterials
    -- * Recording
  , module Hetoimasia.Render.TwoD.Vulkan.Frame
  , FrameRecording
  , prepareSnapshot
  , claimAlignment
    -- * The shaders
  , orderedShaders
  , cutoutShaders
  ) where

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import System.IO.Unsafe (unsafePerformIO)
import qualified Data.ByteString as ByteString
import Control.Applicative ((<|>))
import Data.List (mapAccumL, nub)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, listToMaybe)
import Data.Word (Word32, Word64)
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( BufferSource (..)
  , CompareOp (..)
  , ImageFormat (..)
  , PassStart (..)
  , Pipeline
  , PipelineBlend (..)
  , PipelineDepth (..)
  , PipelineLayout
  , PushStage (..)
  , Recorder
  , Refusal (..)
  , ResourceUse (..)
  , RingClaim
  , RingSize
  , StorageWindow
  , TransitionSource (..)
  , Viewport (..)
  , beginFrameRenderingWithDepth
  , beginRendering
  , beginRenderingInto
  , beginRenderingWithDepth
  , bindPipeline
  , bindVertexBuffer
  , claimRegion
  , clearDepthRect
  , clearedDepth
  , depthTested
  , draw
  , endRendering
  , pushConstants
  , setScissor
  , setViewport
  , storageWindowBytes
  , transitionResource
  , validateRingSize
  , validateStorageWindow
  , writeClaim
  )
import Hetoimasia.GPU.Vulkan.Native.Shader (CheckedShaders)
import Hetoimasia.GPU.Vulkan.Native.TextureTable
  ( TableConfig
  , bindStorageTable
  , bindTable
  , claimTable
  , defaultVersionCount
  , validateTableConfig
  )
import Hetoimasia.Render.TwoD.Material (MaterialRef, defaultMaterial)
import Hetoimasia.Render.TwoD.Material.Backend (materialRef, materialRefIdentity)
import Hetoimasia.Render.TwoD.Snapshot (Pass (..), Snapshot (..), Target (..))
import Hetoimasia.Render.TwoD.Validation (Location (..), validSnapshot)
import Hetoimasia.Render.TwoD.Vulkan.Builders (Builders (..))
import Hetoimasia.Render.TwoD.Vulkan.Frame
import Hetoimasia.Render.TwoD.Vulkan.Layout (applicationPushOffset, instanceStride, packRecordBase, recordBaseOffset)
import Hetoimasia.Render.TwoD.Vulkan.Material (DefinedMaterial (..))
import Hetoimasia.Render.TwoD.Vulkan.Shaders (cutoutShaders, orderedShaders)

-- | What the renderer makes with: the session's ring, its texture table and the
-- storage-table window a batch's clip tables and material records must fit.
data Configuration = Configuration
  { configurationRing ∷ !RingSize
  , configurationTable ∷ !TableConfig
  , configurationRegionWindow ∷ !StorageWindow
    -- ^ The most bytes of storage region one batch may bind: its clip tables,
    -- 16 an entry, then its material records. The window the ring is made with.
    -- A batch whose region is larger is refused ('ClipTablesTooLarge' when its
    -- clip tables alone are, 'RecordsTooLarge' otherwise).
  }

-- | A four-mebibyte ring, a table of 1024 slots, 64 allocated at first, with
-- the default version ring, and a region window of 64 kibibytes.
defaultConfiguration ∷ Configuration
defaultConfiguration =
  Configuration
    (either (error . show) id (validateRingSize (4 * 1024 * 1024)))
    (either (error . show) id (validateTableConfig 1024 64 (toInteger defaultVersionCount)))
    (either (error . show) id (validateStorageWindow (64 * 1024)))

-- | The renderer's state: the table's shader-sampled layout, the pipeline made
-- for each colour format, kind and material, and the materials registered.
data Renderer = Renderer
  { rendererLayout ∷ !PipelineLayout
  , rendererRegionWindow ∷ !Word64
    -- ^ The bytes of storage region a batch may bind.
  , rendererDepthFormat ∷ !(Maybe ImageFormat)
    -- ^ The session's depth format, if it offers one.
  , rendererSession ∷ !Word32
    -- ^ The number every reference this renderer issues carries in its identity,
    -- so another session's reference is never taken for one of this session's.
  , rendererMaterials ∷ !(IORef (Map.Map Word64 Registered))
    -- ^ The materials registered, by the identity issued for each.
  , rendererPipelines ∷ !(IORef (Map.Map (Word32, PipelineKind, Word64) Pipeline))
  }

-- | A registered material and the reference issued for it.
data Registered = Registered
  { registeredMaterial ∷ !DefinedMaterial
  , registeredRef ∷ !MaterialRef
  }

-- | The next session number: every renderer made takes one, so references of
-- different renderers never share an identity.
sessionCounter ∷ IORef Word32
sessionCounter = unsafePerformIO (newIORef 0)
{-# NOINLINE sessionCounter #-}

-- | Make the ring with its region window, the texture table, the storage table
-- and the pipeline layout.
makeRenderer ∷ Builders q inst msgr phys dev cmd → Configuration → IO (Either Refusal Renderer)
makeRenderer builders configuration =
  buildRing builders (configurationRing configuration) (configurationRegionWindow configuration) >>= \case
    Left refusal → pure (Left refusal)
    Right () →
      buildTable builders (configurationTable configuration) >>= \case
        Left refusal → pure (Left refusal)
        Right () →
          buildStorageTable builders >>= \case
            Left refusal → pure (Left refusal)
            Right () →
              buildTableLayout builders orderedShaders >>= \case
                Left refusal → pure (Left refusal)
                Right layout → do
                  -- A session that offers no depth format still renders what has no
                  -- depth-enabled world layer.
                  depth ← either (const Nothing) Just <$> buildDepthFormat builders
                  session ← atomicModifyIORef' sessionCounter (\held → (held + 1, held + 1))
                  materials ← newIORef Map.empty
                  pipelines ← newIORef Map.empty
                  pure (Right (Renderer layout (fromIntegral (storageWindowBytes (configurationRegionWindow configuration))) depth session materials pipelines))

-- | Register a material an application defined, and issue its reference. The
-- reference carries exactly the facts the material was defined with and an
-- identity that is this renderer's own: it is the only kind of reference
-- ("Hetoimasia.Render.TwoD.Material.Backend"'s @materialRef@ builds others, which
-- the recorder refuses) the renderer records. Registering a material equal to one
-- already registered answers the reference already issued. No native call is
-- made: the material's pipelines are built when a pass first draws with them.
registerMaterial ∷ Renderer → DefinedMaterial → IO MaterialRef
registerMaterial renderer defined =
  atomicModifyIORef' (rendererMaterials renderer) $ \held ->
    case [registeredRef each | each ← Map.elems held, registeredMaterial each == defined] of
      issued : _ → (held, issued)
      [] →
        let identity = (fromIntegral (rendererSession renderer) * 4294967296) + fromIntegral (Map.size held + 1)
            issued = materialRef identity (definedFacts defined)
         in (Map.insert identity (Registered defined issued) held, issued)

-- | What the renderer issued, by identity: the reference issued under it, for
-- 'Hetoimasia.Render.TwoD.Vulkan.Frame.unissuedMaterial' to compare a snapshot's
-- references with. The built-in default is every renderer's.
issuedMaterials ∷ Renderer → IO (Word64 → Maybe MaterialRef)
issuedMaterials renderer = do
  held ← readIORef (rendererMaterials renderer)
  pure $ \identity ->
    if identity == materialRefIdentity defaultMaterial
      then Just defaultMaterial
      else registeredRef <$> Map.lookup identity held

-- | The depth a kind of pipeline declares: none for 'PlainPipeline', otherwise
-- @D32_SFLOAT@ (D-23), tested less-or-equal, and written only by the cutout
-- pipeline.
pipelineDeclaration ∷ PipelineKind → Maybe PipelineDepth
pipelineDeclaration = \case
  PlainPipeline → Nothing
  CutoutPipeline → Just (depthTested Depth32Float)
  OrderedTestedPipeline → Just (PipelineDepth Depth32Float True False CompareLessOrEqual)
  UntestedPipeline → Just (PipelineDepth Depth32Float False False CompareLessOrEqual)

-- | The renderer's pipeline of a kind for a colour format, over the table's
-- layout, made the first time the pair is drawn: the built-in default
-- material's.
pipelineFor ∷ Builders q inst msgr phys dev cmd → Renderer → PipelineKind → Word32 → IO (Either Refusal Pipeline)
pipelineFor builders renderer = pipelineForMaterial builders renderer defaultMaterial

-- | The pipeline of a material's variant for a kind and a colour format, made
-- the first time the triple is drawn. A kind that draws the cutout variant needs
-- a material that has one, and a reference the renderer did not issue has none:
-- both are refused as 'RefusedIllegal'.
pipelineForMaterial ∷ Builders q inst msgr phys dev cmd → Renderer → MaterialRef → PipelineKind → Word32 → IO (Either Refusal Pipeline)
pipelineForMaterial builders renderer material kind format =
  (Map.lookup (format, kind, materialRefIdentity material) <$> readIORef (rendererPipelines renderer)) >>= \case
    Just pipeline → pure (Right pipeline)
    Nothing →
      shadersFor >>= \case
        Left refusal → pure (Left refusal)
        Right shaders →
          build shaders >>= \case
            Left refusal → pure (Left refusal)
            Right pipeline → Right pipeline <$ atomicModifyIORef' (rendererPipelines renderer) (\held → (Map.insert (format, kind, materialRefIdentity material) pipeline held, ()))
  where
    layout = rendererLayout renderer
    shadersFor
      | material == defaultMaterial = pure (Right (if kind == CutoutPipeline then cutoutShaders else orderedShaders))
      | otherwise =
          (Map.lookup (materialRefIdentity material) <$> readIORef (rendererMaterials renderer)) >>= \case
            Nothing → pure (Left (RefusedIllegal "a pipeline for a material this renderer did not issue"))
            Just registered
              | kind == CutoutPipeline → pure (maybe (Left (RefusedIllegal "a cutout pipeline for a material that is not cutout-capable and has no cutout variant")) Right (definedCutout (registeredMaterial registered)))
              | otherwise → pure (Right (definedTranslucent (registeredMaterial registered)))
    build ∷ CheckedShaders → IO (Either Refusal Pipeline)
    build shaders = case (kind, pipelineDeclaration kind) of
      (CutoutPipeline, Just depth) → buildDepthPipeline builders layout shaders format BlendNone depth
      (_, Just depth) → buildDepthPipeline builders layout shaders format BlendPremultipliedAlpha depth
      (_, Nothing) → buildPipeline builders layout shaders format BlendPremultipliedAlpha

-- | What records a prepared frame into a batch's recorder.
type FrameRecording q inst msgr phys dev cmd = Recorder q inst msgr phys dev cmd → IO (Either FrameRefusal ())

-- | The alignment each layer's ring region is claimed with, a multiple of
-- every attribute's size.
claimAlignment ∷ Word
claimAlignment = 16

-- | Resolve a frame, and make the pipelines its drawing passes need, before a
-- batch records. A refusal names where and records nothing; otherwise what is
-- returned records the frame.
prepareSnapshot ∷ Builders q inst msgr phys dev cmd → Renderer → FrameInput → IO (Either FrameRefusal (FrameRecording q inst msgr phys dev cmd))
prepareSnapshot builders renderer declared =
  case requireWorldDepth (rendererDepthFormat renderer) (frameSnapshot declared) of
    Left refusal → pure (Left refusal)
    Right () →
      verifiedDepth builders declared >>= \case
        Left refusal → pure (Left refusal)
        Right input → prepareVerified builders renderer input

-- | The frame with the format of every depth image it supplies replaced by the
-- one the backend holds for it, so what the work is decided on is the image's,
-- not its maker's word. A depth image the backend no longer holds is the
-- backend's refusal.
verifiedDepth ∷ Builders q inst msgr phys dev cmd → FrameInput → IO (Either FrameRefusal FrameInput)
verifiedDepth builders input = do
  let references = nub [reference | Pass (OffscreenTarget reference) _ _ ← snapshotPasses (validSnapshot (frameSnapshot input))]
      supplied = [(reference, depth) | reference ← references, Just binding ← [frameTarget input reference], Just depth ← [bindingDepth binding]]
  checked ← traverse (\(reference, depth) → fmap ((,) reference) <$> actually depth) supplied
  window ← traverse actually (frameWindowDepth input)
  pure $ do
    found ← either (Left . RefusedByBackend) Right (sequence checked)
    windowed ← either (Left . RefusedByBackend) Right (sequence window)
    let byReference = Map.fromList found
    Right
      input
        { frameTarget = \reference → (\binding → binding {bindingDepth = Map.lookup reference byReference <|> bindingDepth binding}) <$> frameTarget input reference
        , frameWindowDepth = windowed
        }
  where
    actually depth = fmap (\format → depth {depthFormat = format}) <$> buildImageFormat builders (depthImage depth)

prepareVerified ∷ Builders q inst msgr phys dev cmd → Renderer → FrameInput → IO (Either FrameRefusal (FrameRecording q inst msgr phys dev cmd))
prepareVerified builders renderer input = do
  issued ← issuedMaterials renderer
  case unissuedMaterial issued (frameSnapshot input) of
    Just refusal → pure (Left refusal)
    Nothing → case checked of
      Left refusal → pure (Left refusal)
      Right passes → do
        let needed = nub [(attachmentFormat (workAttachment pass), kind, material) | pass ← passes, (kind, material) ← kindsOf pass]
        pipelines ← traverse (\(format, kind, material) → pipelineForMaterial builders renderer material kind format) needed
        pure $ case sequence pipelines of
          Left refusal → Left (RefusedByBackend refusal)
          Right found → Right (recordPrepared (Map.fromList (zip [(format, kind, materialRefIdentity material) | (format, kind, material) ← needed] found)) (recordRegion passes) passes)
  where
    -- The work, its clip tables within the window, and its whole region within it.
    checked = do
      passes ← frameWork input
      requireClipWindow (rendererRegionWindow renderer) passes
      requireRegionWindow (rendererRegionWindow renderer) passes
      pure passes

-- | The kinds of pipeline a pass draws with, and the material of each, in the
-- order it first needs them.
kindsOf ∷ PassWork → [(PipelineKind, MaterialRef)]
kindsOf = nub . map snd . runsOf

-- | Every run of a pass in recording order, with the pipeline kind and the
-- material it draws with.
runsOf ∷ PassWork → [(RunWork, (PipelineKind, MaterialRef))]
runsOf pass =
  [ (run, (runPipeline (isJust (workDepth pass)) layer run, runWorkMaterial run))
  | view ← workViews pass
  , layer ← workLayers view
  , run ← layerRunList layer
  ]

-- | Claim and write the batch's region (the clip tables, then the material
-- records) and every layer's region, move the chunk buffers the frame draws from
-- to their vertex-input use, then record each pass.
recordPrepared ∷ Map.Map (Word32, PipelineKind, Word64) Pipeline → Maybe RecordRegion → [PassWork] → FrameRecording q inst msgr phys dev cmd
recordPrepared pipelines region passes recorder =
  claimRegionFor recorder region >>= \case
    Left refusal → pure (Left (RefusedByBackend refusal))
    Right records →
      claimInOrder recorder layersInOrder >>= \case
        Left refusal → pure (Left (RefusedByBackend refusal))
        Right regions → do
          let byLocation = Map.fromList (zip (map layerLocation layersInOrder) regions)
          stopAtFirst
            ( [backend (transitionResource recorder buffer (FromUse GeometryRead) GeometryRead) | buffer ← chunkBuffers]
                <> [recordPass recorder pipelines records byLocation pass | pass ← passes]
            )
  where
    -- A layer whose runs all read a chunk's buffer, or that holds none, only
    -- clears or draws from elsewhere: it claims nothing.
    layersInOrder = [layer | pass ← passes, view ← workViews pass, layer ← workLayers view, not (ByteString.null (layerBytes layer))]
    -- The buffers of the chunks drawn from, once each, in the order first drawn.
    chunkBuffers =
      nub
        [ buffer
        | pass ← passes
        , view ← workViews pass
        , layer ← workLayers view
        , run ← layerRunList layer
        , ReadsChunk _ buffer ← [runReads run]
        ]
    backend = fmap (either (Left . RefusedByBackend) Right)

-- | Claim the batch's region, for the storage table, and write it: the claim, and
-- where each table of material records begins. A frame that draws nothing has
-- none.
claimRegionFor ∷ Recorder q inst msgr phys dev cmd → Maybe RecordRegion → IO (Either Refusal (Maybe (RingClaim, Map.Map RecordKey Word32)))
claimRegionFor recorder = \case
  Nothing → pure (Right Nothing)
  Just region →
    claimTable recorder (fromIntegral (ByteString.length (regionBytes region))) >>= \case
      Left refusal → pure (Left refusal)
      Right claim → fmap (const (Just (claim, regionBases region))) <$> writeClaim recorder claim 0 (regionBytes region)

-- | Claim every layer's region in order, stopping at the first the backend
-- refuses, so a full ring is met once and nothing later is claimed.
claimInOrder ∷ Recorder q inst msgr phys dev cmd → [LayerWork] → IO (Either Refusal [RingClaim])
claimInOrder recorder = \case
  [] → pure (Right [])
  layer : rest →
    claimLayer recorder layer >>= \case
      Left refusal → pure (Left refusal)
      Right claim → fmap (claim :) <$> claimInOrder recorder rest

-- | Claim one layer's region and write its instances into it.
claimLayer ∷ Recorder q inst msgr phys dev cmd → LayerWork → IO (Either Refusal RingClaim)
claimLayer recorder layer =
  claimRegion recorder (fromIntegral (ByteString.length (layerBytes layer))) (fromIntegral claimAlignment) >>= \case
    Left refusal → pure (Left refusal)
    Right claim → fmap (const claim) <$> writeClaim recorder claim 0 (layerBytes layer)

-- | What a pass's recording has bound so far, which it keeps from step to step so
-- that it pushes and binds only what a run changes.
data Walk = Walk
  { walkBound ∷ !(Maybe (PipelineKind, MaterialRef))
    -- ^ The bound pipeline's kind and material.
  , walkBase ∷ !(Maybe Word32)
    -- ^ The record base pushed last.
  , walkApplication ∷ !(Maybe (Int, MaterialRef))
    -- ^ The view and material whose application push block was pushed last.
  }

-- | Record one pass: begin, bind, draw each view, end.
recordPass
  ∷ Recorder q inst msgr phys dev cmd
  → Map.Map (Word32, PipelineKind, Word64) Pipeline
  → Maybe (RingClaim, Map.Map RecordKey Word32)
  → Map.Map Location RingClaim
  → PassWork
  → IO (Either FrameRefusal ())
recordPass recorder pipelines records regions pass =
  stopAtFirst $
    [backend begin]
      <> bindings
      <> concat (snd (mapAccumL viewSteps (Walk (fmap snd (listToMaybe (runsOf pass))) Nothing Nothing) (workViews pass)))
      <> [backend (endRendering recorder)]
  where
    attachment = workAttachment pass
    width = fromIntegral (attachmentWidth attachment)
    height = fromIntegral (attachmentHeight attachment)
    depthed = isJust (workDepth pass)
    drawsHere = passDraws pass
    begin = case (workImage pass, workDepth pass) of
      (Just image, Nothing) → beginRenderingInto recorder image ClearFromUndefined (workClear pass)
      (Just image, Just depth) → beginRenderingWithDepth recorder image ClearFromUndefined (workClear pass) (clearedDepth (depthImage depth) ClearFromUndefined)
      (Nothing, Nothing) → beginRendering recorder (workClear pass)
      (Nothing, Just depth) → beginFrameRenderingWithDepth recorder (workClear pass) (clearedDepth (depthImage depth) ClearFromUndefined)
    pipelineOf kind material = Map.lookup (attachmentFormat attachment, kind, materialRefIdentity material) pipelines
    missing = pure (Left (RefusedByBackend (RefusedIllegal "no pipeline was made for the pass's colour format, kind and material")))
    -- The table and the batch's region, as the draws after them need them: the
    -- region (the clip tables, then the material records) is bound at its own
    -- start, where the batch wrote it.
    tables =
      backend (bindTable recorder)
        : maybe [pure (Left (RefusedByBackend (RefusedIllegal "a pass that draws has no storage region")))] (\(claim, _) → [backend (bindStorageTable recorder claim 0)]) records
    -- The first run's pipeline, the viewport over the whole attachment and the
    -- tables, bound only where something is drawn.
    bindings = case runsOf pass of
      [] → []
      (_, (kind, material)) : _ → case pipelineOf kind material of
        Nothing → [missing]
        Just pipeline →
          [ backend (bindPipeline recorder pipeline)
          , backend (setViewport recorder (Viewport 0 0 width height))
          ]
            <> tables
    -- A layer that only skipped a chunk has nothing to record: a view holding no
    -- other records no scissor.
    recordsSomething layer = layerClearsDepth layer || not (null (layerRunList layer))
    viewSteps walk view = case (workRect view, filter recordsSomething (workLayers view)) of
      (Just rect, layers@(_ : _)) →
        let (walk', steps) = mapAccumL (layerSteps rect (workViewIndex view) (workPushBlocks view)) walk layers
         in (walk', backend (setScissor recorder rect) : concat steps)
      _ → (walk, [])
    layerSteps rect viewIndex pushBlocks walk layer =
      -- A depth clear is followed by binding the table and the region again,
      -- where the pass draws: on MoltenVK a mid-pass clear leaves the descriptor
      -- bindings unusable by the draws after it, and a draw after one finds the
      -- table gone unless it is bound anew (Vulkan itself leaves them
      -- undisturbed). The material's push block is pushed again for the same
      -- reason.
      let clear = concat [[backend (clearDepthRect recorder rect 1)] <> (if drawsHere then tables else []) | layerClearsDepth layer]
          cleared = if layerClearsDepth layer then walk {walkApplication = Nothing} else walk
       in case layerRunList layer of
            [] → (cleared, clear)
            runs →
              -- The layer's block sets the record base to zero.
              let (walk', steps) = mapAccumL (runSteps layer (Map.lookup (layerLocation layer) regions) viewIndex pushBlocks) cleared {walkBase = Just 0} runs
               in (walk', clear <> [backend (pushConstants recorder [PushVertex, PushFragment] 0 (layerPushBytes layer))] <> concat steps)
    runSteps layer claim viewIndex pushBlocks walk run =
      let kind = runPipeline depthed layer run
          material = runWorkMaterial run
          rebind
            | walkBound walk == Just (kind, material) = []
            | otherwise = [maybe missing (backend . bindPipeline recorder) (pipelineOf kind material)]
          -- A run that reads records pushes the word its table begins at, unless
          -- it is the one already pushed.
          (basePushes, base') = case runWorkRecords run of
            NoRunRecords → ([], walkBase walk)
            RunRecords key _ → case records >>= Map.lookup key . snd of
              Nothing → ([pure (Left (PlanDisagrees (layerLocation layer)))], walkBase walk)
              Just base
                | walkBase walk == Just base → ([], walkBase walk)
                | otherwise → ([backend (pushConstants recorder [PushVertex, PushFragment] recordBaseOffset (packRecordBase base))], Just base)
          -- A material that has a push block has the view's bytes pushed before
          -- its first run in the view.
          (applicationPushes, application') = case Map.lookup material pushBlocks of
            Just block
              | walkApplication walk /= Just (viewIndex, material) →
                  ([backend (pushConstants recorder [PushVertex, PushFragment] applicationPushOffset block)], Just (viewIndex, material))
            _ → ([], walkApplication walk)
          offset = fromIntegral (runFirstInstance run) * fromIntegral instanceStride
          -- A ring run reads the layer's region; a chunk's run, the chunk's buffer.
          source = case (runReads run, claim) of
            (ReadsRing, Just region) → backend (bindVertexBuffer recorder 0 (FromClaim region offset))
            (ReadsRing, Nothing) → pure (Left (PlanDisagrees (layerLocation layer)))
            (ReadsChunk _ buffer, _) → backend (bindVertexBuffer recorder 0 (FromBuffer buffer offset))
       in ( Walk (Just (kind, material)) base' application'
          , rebind
              <> basePushes
              <> applicationPushes
              <> [ source
                 , backend (draw recorder 6 (runInstanceCount run))
                 ]
          )
    backend = fmap (either (Left . RefusedByBackend) Right)

-- | Run each step in order, stopping at the first refusal.
stopAtFirst ∷ [IO (Either FrameRefusal ())] → IO (Either FrameRefusal ())
stopAtFirst = \case
  [] → pure (Right ())
  step : rest → step >>= either (pure . Left) (const (stopAtFirst rest))
