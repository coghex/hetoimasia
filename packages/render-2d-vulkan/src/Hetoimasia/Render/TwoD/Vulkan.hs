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
-- 'makeRenderer' makes, through the host's constructions, the session's ring,
-- the texture table the draws go through, and a shader-sampled table pipeline
-- layout (R2D-16) over the package's shaders. A pipeline is made per colour
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
-- 1. every layer's instances, written in drawing order into one ring region
--    each, all claimed before the first pass begins; a full ring is a refusal
--    ('RefusedByBackend') with no clear and no draw recorded, and the batch's
--    claims stay the backend's to reclaim or discard;
-- 2. each pass in list order: it begins rendering into its target, cleared to
--    the pass's clear colour (an offscreen target from undefined, the
--    window's frame as the frame's own), and, when a view with a non-empty
--    scissor holds a depth-enabled world layer, with the caller's depth image
--    as its depth attachment, cleared to 1.0 across it. It binds its first
--    run's pipeline, the table and a viewport over the whole attachment,
--    draws, and ends before the next begins;
-- 3. within a pass, each view in order under its scissor, which covers
--    exactly the pixels whose centres the view's viewport contains; a view
--    whose scissor is empty records no clear and no draw;
-- 4. within a view, each layer in order: a depth-enabled world layer clears
--    depth to 1.0 within the scissor ('clearDepthRect'); then the layer's push
--    block, then one instanced draw of six vertices per run, binding the run's
--    pipeline when it is not the bound one, the instance region at the run's
--    first instance and drawing its count.
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
  , pipelineFor
  , pipelineDeclaration
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
import qualified Data.ByteString as ByteString
import Control.Applicative ((<|>))
import Data.List (mapAccumL, nub)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, listToMaybe)
import Data.Word (Word32)
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
  , RingClaim
  , RingSize
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
  , validateRingSize
  , writeClaim
  )
import Hetoimasia.GPU.Vulkan.Native.TextureTable
  ( TableConfig
  , bindTable
  , defaultVersionCount
  , validateTableConfig
  )
import Hetoimasia.Render.TwoD.Snapshot (Pass (..), Snapshot (..), Target (..))
import Hetoimasia.Render.TwoD.Validation (Location (..), validSnapshot)
import Hetoimasia.Render.TwoD.Vulkan.Builders (Builders (..))
import Hetoimasia.Render.TwoD.Vulkan.Frame
import Hetoimasia.Render.TwoD.Vulkan.Layout (instanceStride)
import Hetoimasia.Render.TwoD.Vulkan.Shaders (cutoutShaders, orderedShaders)

-- | What the renderer makes with: the session's ring and its texture table.
data Configuration = Configuration
  { configurationRing ∷ !RingSize
  , configurationTable ∷ !TableConfig
  }

-- | A four-mebibyte ring and a table of 1024 slots, 64 allocated at first,
-- with the default version ring.
defaultConfiguration ∷ Configuration
defaultConfiguration =
  Configuration
    (either (error . show) id (validateRingSize (4 * 1024 * 1024)))
    (either (error . show) id (validateTableConfig 1024 64 (toInteger defaultVersionCount)))

-- | The renderer's state: the table's shader-sampled layout, and the pipeline
-- made for each colour format and kind.
data Renderer = Renderer
  { rendererLayout ∷ !PipelineLayout
  , rendererDepthFormat ∷ !(Maybe ImageFormat)
    -- ^ The session's depth format, if it offers one.
  , rendererPipelines ∷ !(IORef (Map.Map (Word32, PipelineKind) Pipeline))
  }

-- | Make the ring, the texture table and the pipeline layout.
makeRenderer ∷ Builders q inst msgr phys dev cmd → Configuration → IO (Either Refusal Renderer)
makeRenderer builders configuration =
  buildRing builders (configurationRing configuration) >>= \case
    Left refusal → pure (Left refusal)
    Right () →
      buildTable builders (configurationTable configuration) >>= \case
        Left refusal → pure (Left refusal)
        Right () →
          buildTableLayout builders orderedShaders >>= \case
            Left refusal → pure (Left refusal)
            Right layout → do
              -- A session that offers no depth format still renders what has no
              -- depth-enabled world layer.
              depth ← either (const Nothing) Just <$> buildDepthFormat builders
              Right . Renderer layout depth <$> newIORef Map.empty

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
-- layout, made the first time the pair is drawn.
pipelineFor ∷ Builders q inst msgr phys dev cmd → Renderer → PipelineKind → Word32 → IO (Either Refusal Pipeline)
pipelineFor builders renderer kind format =
  (Map.lookup (format, kind) <$> readIORef (rendererPipelines renderer)) >>= \case
    Just pipeline → pure (Right pipeline)
    Nothing →
      build >>= \case
        Left refusal → pure (Left refusal)
        Right pipeline → Right pipeline <$ atomicModifyIORef' (rendererPipelines renderer) (\held → (Map.insert (format, kind) pipeline held, ()))
  where
    layout = rendererLayout renderer
    build = case (kind, pipelineDeclaration kind) of
      (CutoutPipeline, Just depth) → buildDepthPipeline builders layout cutoutShaders format BlendNone depth
      (_, Just depth) → buildDepthPipeline builders layout orderedShaders format BlendPremultipliedAlpha depth
      (_, Nothing) → buildPipeline builders layout orderedShaders format BlendPremultipliedAlpha

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
prepareVerified builders renderer input = case frameWork input of
  Left refusal → pure (Left refusal)
  Right passes → do
    let needed = nub [(attachmentFormat (workAttachment pass), kind) | pass ← passes, kind ← kindsOf pass]
    pipelines ← traverse (\(format, kind) → pipelineFor builders renderer kind format) needed
    pure $ case sequence pipelines of
      Left refusal → Left (RefusedByBackend refusal)
      Right found → Right (recordPrepared (Map.fromList (zip needed found)) passes)

-- | The kinds of pipeline a pass draws with, in the order it first needs them.
kindsOf ∷ PassWork → [PipelineKind]
kindsOf = nub . map snd . runsOf

-- | Every run of a pass in recording order, with the pipeline kind it draws
-- with.
runsOf ∷ PassWork → [(RunWork, PipelineKind)]
runsOf pass =
  [ (run, runPipeline (isJust (workDepth pass)) layer run)
  | view ← workViews pass
  , layer ← workLayers view
  , run ← layerRunList layer
  ]

-- | Claim and write every layer's region, then record each pass.
recordPrepared ∷ Map.Map (Word32, PipelineKind) Pipeline → [PassWork] → FrameRecording q inst msgr phys dev cmd
recordPrepared pipelines passes recorder = do
  claimed ← claimInOrder recorder layersInOrder
  case claimed of
    Left refusal → pure (Left (RefusedByBackend refusal))
    Right regions → do
      let byLocation = Map.fromList (zip (map layerLocation layersInOrder) regions)
      stopAtFirst [recordPass recorder pipelines byLocation pass | pass ← passes]
  where
    -- A layer that holds no run, a depth-enabled one that only clears, claims
    -- nothing.
    layersInOrder = [layer | pass ← passes, view ← workViews pass, layer ← workLayers view, not (null (layerRunList layer))]

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

-- | Record one pass: begin, bind, draw each view, end.
recordPass
  ∷ Recorder q inst msgr phys dev cmd
  → Map.Map (Word32, PipelineKind) Pipeline
  → Map.Map Location RingClaim
  → PassWork
  → IO (Either FrameRefusal ())
recordPass recorder pipelines regions pass =
  stopAtFirst $
    [backend begin]
      <> bindings
      <> concat (snd (mapAccumL viewSteps (fmap snd (listToMaybe (runsOf pass))) (workViews pass)))
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
    pipelineOf kind = Map.lookup (attachmentFormat attachment, kind) pipelines
    missing = pure (Left (RefusedByBackend (RefusedIllegal "no pipeline was made for the pass's colour format and kind")))
    -- The first run's pipeline, the viewport over the whole attachment and the
    -- table, bound only where something is drawn.
    bindings = case runsOf pass of
      [] → []
      (_, kind) : _ → case pipelineOf kind of
        Nothing → [missing]
        Just pipeline →
          [ backend (bindPipeline recorder pipeline)
          , backend (setViewport recorder (Viewport 0 0 width height))
          , backend (bindTable recorder)
          ]
    viewSteps bound view = case (workRect view, workLayers view) of
      (Just rect, layers@(_ : _)) →
        let (bound', steps) = mapAccumL (layerSteps rect) bound layers
         in (bound', backend (setScissor recorder rect) : concat steps)
      _ → (bound, [])
    layerSteps rect bound layer =
      -- A depth clear is followed by binding the table again, where the pass
      -- draws: on MoltenVK a mid-pass clear leaves the descriptor bindings
      -- unusable by the draws after it, and a draw after one finds the table
      -- gone unless it is bound anew (Vulkan itself leaves them undisturbed).
      let clear = concat [[backend (clearDepthRect recorder rect 1)] <> [backend (bindTable recorder) | drawsHere] | layerClearsDepth layer]
       in case (layerRunList layer, Map.lookup (layerLocation layer) regions) of
            ([], _) → (bound, clear)
            (_, Nothing) → (bound, clear <> [pure (Left (PlanDisagrees (layerLocation layer)))])
            (runs, Just claim) →
              let (bound', steps) = mapAccumL (runSteps layer claim) bound runs
               in (bound', clear <> [backend (pushConstants recorder [PushVertex, PushFragment] 0 (layerPushBytes layer))] <> concat steps)
    runSteps layer claim bound run =
      let kind = runPipeline depthed layer run
          rebind
            | bound == Just kind = []
            | otherwise = [maybe missing (backend . bindPipeline recorder) (pipelineOf kind)]
       in ( Just kind
          , rebind
              <> [ backend (bindVertexBuffer recorder 0 (FromClaim claim (fromIntegral (runFirstInstance run) * fromIntegral instanceStride)))
                 , backend (draw recorder 6 (runInstanceCount run))
                 ]
          )
    backend = fmap (either (Left . RefusedByBackend) Right)

-- | Run each step in order, stopping at the first refusal.
stopAtFirst ∷ [IO (Either FrameRefusal ())] → IO (Either FrameRefusal ())
stopAtFirst = \case
  [] → pure (Right ())
  step : rest → step >>= either (pure . Left) (const (stopAtFirst rest))
