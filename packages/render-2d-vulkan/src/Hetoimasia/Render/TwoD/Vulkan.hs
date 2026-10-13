-- | The 2D renderer's Vulkan recorder for the ordered path (R2D-7): a
-- validated snapshot recorded into one batch of the native backend, every
-- pass in list order, with premultiplied-alpha blending.
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
-- format the first time a pass into that format draws, with premultiplied-alpha
-- blending. The textures are registered with the table by their owner; the
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
--    window's frame as the frame's own), binds its format's pipeline, the
--    table and a viewport over the whole attachment, draws, and ends before
--    the next begins;
-- 3. within a pass, each view in order under its scissor, which covers
--    exactly the pixels whose centres the view's viewport contains; a view
--    whose scissor is empty records no draw;
-- 4. within a view, each layer in order: its push block, then one instanced
--    draw of six vertices per run, binding the instance region at the run's
--    first instance and drawing its count.
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
  , pipelineFor
    -- * Recording
  , module Hetoimasia.Render.TwoD.Vulkan.Frame
  , FrameRecording
  , prepareSnapshot
  , claimAlignment
    -- * The shaders
  , orderedShaders
  ) where

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import Data.Word (Word32)
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( BufferSource (..)
  , PassStart (..)
  , Pipeline
  , PipelineBlend (..)
  , PipelineLayout
  , PushStage (..)
  , Recorder
  , Refusal (..)
  , RingClaim
  , RingSize
  , Viewport (..)
  , beginRendering
  , beginRenderingInto
  , bindPipeline
  , bindVertexBuffer
  , claimRegion
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
import Hetoimasia.Render.TwoD.Validation (Location)
import Hetoimasia.Render.TwoD.Vulkan.Builders (Builders (..))
import Hetoimasia.Render.TwoD.Vulkan.Frame
import Hetoimasia.Render.TwoD.Vulkan.Layout (instanceStride)
import Hetoimasia.Render.TwoD.Vulkan.Shaders (orderedShaders)

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
-- made for each colour format.
data Renderer = Renderer
  { rendererLayout ∷ !PipelineLayout
  , rendererPipelines ∷ !(IORef (Map.Map Word32 Pipeline))
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
            Right layout → Right . Renderer layout <$> newIORef Map.empty

-- | The renderer's pipeline for a colour format: premultiplied-alpha blending
-- over the table's layout, made the first time the format is drawn.
pipelineFor ∷ Builders q inst msgr phys dev cmd → Renderer → Word32 → IO (Either Refusal Pipeline)
pipelineFor builders renderer format =
  (Map.lookup format <$> readIORef (rendererPipelines renderer)) >>= \case
    Just pipeline → pure (Right pipeline)
    Nothing →
      buildPipeline builders (rendererLayout renderer) orderedShaders format BlendPremultipliedAlpha >>= \case
        Left refusal → pure (Left refusal)
        Right pipeline → Right pipeline <$ atomicModifyIORef' (rendererPipelines renderer) (\held → (Map.insert format pipeline held, ()))

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
prepareSnapshot builders renderer input = case frameWork input of
  Left refusal → pure (Left refusal)
  Right passes → do
    pipelines ← traverse (pipelineOf . attachmentFormat . workAttachment) [pass | pass ← passes, passDraws pass]
    pure $ case sequence pipelines of
      Left refusal → Left (RefusedByBackend refusal)
      Right found →
        let byFormat = Map.fromList [(attachmentFormat (workAttachment pass), pipeline) | (pass, pipeline) ← zip [pass | pass ← passes, passDraws pass] found]
         in Right (recordPrepared byFormat passes)
  where
    pipelineOf = pipelineFor builders renderer

-- | Claim and write every layer's region, then record each pass.
recordPrepared ∷ Map.Map Word32 Pipeline → [PassWork] → FrameRecording q inst msgr phys dev cmd
recordPrepared pipelines passes recorder = do
  claimed ← claimInOrder recorder layersInOrder
  case claimed of
    Left refusal → pure (Left (RefusedByBackend refusal))
    Right regions → do
      let byLocation = Map.fromList (zip (map layerLocation layersInOrder) regions)
      stopAtFirst [recordPass recorder pipelines byLocation pass | pass ← passes]
  where
    layersInOrder = [layer | pass ← passes, view ← workViews pass, layer ← workLayers view]

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
  → Map.Map Word32 Pipeline
  → Map.Map Location RingClaim
  → PassWork
  → IO (Either FrameRefusal ())
recordPass recorder pipelines regions pass =
  stopAtFirst $
    [ backend $ case workImage pass of
        Just image → beginRenderingInto recorder image ClearFromUndefined (workClear pass)
        Nothing → beginRendering recorder (workClear pass)
    ]
      <> bindings
      <> concatMap viewSteps (workViews pass)
      <> [backend (endRendering recorder)]
  where
    attachment = workAttachment pass
    width = fromIntegral (attachmentWidth attachment)
    height = fromIntegral (attachmentHeight attachment)
    -- The pipeline, the viewport over the whole attachment and the table,
    -- bound only where something is drawn.
    bindings
      | not (passDraws pass) = []
      | otherwise = case Map.lookup (attachmentFormat attachment) pipelines of
          Nothing → [pure (Left (RefusedByBackend (RefusedIllegal "no pipeline was made for the pass's colour format")))]
          Just pipeline →
            [ backend (bindPipeline recorder pipeline)
            , backend (setViewport recorder (Viewport 0 0 width height))
            , backend (bindTable recorder)
            ]
    viewSteps view = case (workRect view, workLayers view) of
      (Just rect, layers@(_ : _)) → backend (setScissor recorder rect) : concatMap (layerSteps regions) layers
      _ → []
    layerSteps held layer = case Map.lookup (layerLocation layer) held of
      Nothing → [pure (Left (PlanDisagrees (layerLocation layer)))]
      Just claim →
        backend (pushConstants recorder [PushVertex, PushFragment] 0 (layerPushBytes layer))
          : concat
            [ [ backend (bindVertexBuffer recorder 0 (FromClaim claim (fromIntegral (runFirstInstance run) * fromIntegral instanceStride)))
              , backend (draw recorder 6 (runInstanceCount run))
              ]
            | run ← layerRunList layer
            ]
    backend = fmap (either (Left . RefusedByBackend) Right)

-- | Run each step in order, stopping at the first refusal.
stopAtFirst ∷ [IO (Either FrameRefusal ())] → IO (Either FrameRefusal ())
stopAtFirst = \case
  [] → pure (Right ())
  step : rest → step >>= either (pure . Left) (const (stopAtFirst rest))
