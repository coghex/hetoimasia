-- | The sprites sample's drawing (GRS-8): indexed, instanced textured quads
-- through stable texture handles, drawn in the fixed scene of
-- "Hetoimasia.Sample.Sprites.Scene" with premultiplied-alpha blending.
--
-- It is written against the native backend's public vocabulary alone and
-- names nothing of the window integration, so the integration's native suite
-- can depend on it, as the sample's executable does. The constructions it
-- needs arrive as 'Builders', which a host fills from the construction an
-- owner-thread action or a frame lends it; it holds no native handle and
-- makes no GLFW or Vulkan call of its own.
--
-- = Drawing
--
-- 'makeSprites' makes the session's shared ring (for instance data), its
-- texture table, the three fixture textures — the BC7 one only where the
-- device takes BC7, its refusal recorded as the documented skip — and a
-- pipeline layout holding the table. Once the textures' uploads have
-- completed, 'registerSprites' registers each with the table, and
-- 'recordScene' records the whole scene into one batch: the corners, indices
-- and instances written into ring regions the batch claims, both table sets
-- bound, and one indexed, instanced draw per scene draw, each selecting its
-- sampler through the push constants and taking its instances from its own
-- offset in the instance region. Instances carry their texture's handle; no
-- instance is reordered.
--
-- = State
--
-- +-------------------------+--------------+------------------------------+--------+---------------------------------+--------------------------------+
-- | State                   | Owner        | Readers and writers          | Thread | Lifetime                        | Reset or disposal              |
-- +=========================+==============+==============================+========+=================================+================================+
-- | The ring, the texture   | The host     | 'makeSprites' makes them     | Owner  | From 'makeSprites' until the    | Released and destroyed with    |
-- | table, the textures and | session      | through 'Builders'; batches  |        | host session ends               | every managed resource before  |
-- | the pipeline layout     |              | 'recordScene' records read   |        |                                 | the device                     |
-- |                         |              | them                         |        |                                 |                                |
-- +-------------------------+--------------+------------------------------+--------+---------------------------------+--------------------------------+
-- | The pipelines, one per  | A 'Sprites'  | 'pipelineFor', on a format's | Owner  | A format's first scene, until   | As above                       |
-- | colour format           |              | first scene                  |        | the host session ends           |                                |
-- +-------------------------+--------------+------------------------------+--------+---------------------------------+--------------------------------+
-- | The texture handles     | A 'Sprites'  | 'registerSprites' writes     | Owner  | From registration until the     | Never released: the table      |
-- |                         |              | them; 'recordScene' encodes  |        | session ends                    | holds the textures until it is |
-- |                         |              | them into instances          |        |                                 | retired                        |
-- +-------------------------+--------------+------------------------------+--------+---------------------------------+--------------------------------+
module Hetoimasia.Sample.Sprites
  ( -- * Constructions
    Builders (..)
    -- * Making the sample
  , Made (..)
  , makeSprites
  , uploadRequests
  , Sprites
  , registerSprites
  , spritesWithBc7
  , spritesHandle
  , pipelineFor
    -- * Recording
  , SceneTarget (..)
  , sceneInstanceBytes
  , recordScene
    -- * Configuration
  , spritesRingSize
  , spritesTableConfig
  ) where

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Word (Word32)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Vulkan.Native.Recording
  ( BufferSource (..)
  , ClearColor (..)
  , Image
  , ImageDescription (..)
  , ImageKind (..)
  , IndexType (..)
  , PassStart (..)
  , Pipeline
  , PipelineBlend (..)
  , PipelineLayout
  , Readback
  , Recorder
  , Rect (..)
  , Refusal (..)
  , ResourceUse (..)
  , RingSize
  , TransitionSource (..)
  , Viewport (..)
  , beginRendering
  , beginRenderingInto
  , bindIndexBuffer
  , bindPipeline
  , bindVertexBuffer
  , claimRegion
  , copyTargetToReadback
  , drawIndexed
  , endRendering
  , setScissor
  , setViewport
  , transitionResource
  , validateRingSize
  , writeClaim
  )
import Hetoimasia.GPU.Vulkan.Native.Shader (CheckedShaders)
import Hetoimasia.GPU.Vulkan.Native.TextureTable
  ( SwapTicket
  , TableConfig
  , TableView
  , TextureHandle (..)
  , bindTable
  , selectSampler
  , tableSamplerIndex
  , validateTableConfig
  )
import Hetoimasia.GPU.Vulkan.Native.Uploads (UploadRequest (..))
import Hetoimasia.Sample.Sprites.Fixtures (Fixture (..), FixtureName (..), fixture)
import Hetoimasia.Sample.Sprites.Scene
  ( Draw (..)
  , encodeInstances
  , instanceStride
  , quadCorners
  , quadIndices
  , sceneDraws
  , targetSide
  )
import Hetoimasia.Sample.Sprites.ShaderInterfaces (samplerOffset)
import Hetoimasia.Sample.Sprites.Shaders (spritesShaders)

import qualified Data.ByteString as ByteString

-- | The constructions the sample needs, as the host lends them inside an
-- owner-thread action or a frame. The record's type parameters are the
-- host session's, which only a batch's recorder names.
data Builders q inst msgr phys dev cmd = Builders
  { buildRing ∷ RingSize → IO (Either Refusal ())
  , buildTable ∷ TableConfig → IO (Either Refusal ())
  , buildImage ∷ ImageDescription → IO (Either Refusal Image)
  , buildTableLayout ∷ CheckedShaders → Word32 → IO (Either Refusal PipelineLayout)
  , buildPipeline ∷ PipelineLayout → CheckedShaders → Word32 → PipelineBlend → IO (Either Refusal Pipeline)
  , buildReadback ∷ Natural → IO (Either Refusal Readback)
  , registerImage ∷ Image → IO (Either Refusal TextureHandle)
  , swapImage ∷ TextureHandle → Image → IO (Either Refusal SwapTicket)
    -- ^ Ask a handle to show a replacement whose upload is admitted or
    -- complete (GRS-9).
  , inspectTable ∷ IO (Maybe TableView)
    -- ^ The texture table as it stands now.
  }

-- | The session's shared ring: room for the scene's instance data many times
-- over.
spritesRingSize ∷ RingSize
spritesRingSize = either (error . show) id (validateRingSize (1024 * 1024))

-- | A table of sixteen slots, eight allocated at first, and the default
-- version ring.
spritesTableConfig ∷ TableConfig
spritesTableConfig = either (error . show) id (validateTableConfig 16 8 8)

-- | What 'makeSprites' made: each fixture's texture — the BC7 one only where
-- the device takes BC7 — and the table's pipeline layout.
data Made = Made
  { madeTextures ∷ !(Map FixtureName Image)
  , madeLayout ∷ !PipelineLayout
  }

-- | Make the ring, the table, the textures and the pipeline layout. A BC7
-- texture the device does not support is refused as
-- 'RefusedImageUnsupported', which is the documented skip, not a failure;
-- any other refusal is answered as it is.
makeSprites ∷ Builders q inst msgr phys dev cmd → IO (Either Refusal Made)
makeSprites builders = do
  ring ← buildRing builders spritesRingSize
  table ← either (pure . Left) (const (buildTable builders spritesTableConfig)) ring
  case table of
    Left refusal → pure (Left refusal)
    Right () → do
      textures ← traverse made [minBound .. maxBound]
      case sequence textures of
        Left refusal → pure (Left refusal)
        Right found →
          fmap (Made (Map.fromList [(name, image) | (name, Just image) ← found]))
            <$> buildTableLayout builders spritesShaders samplerOffset
  where
    made name = do
      let texture = fixture name
      answer ← buildImage builders (ImageDescription TextureImage (fixtureFormat texture) (fixtureWidth texture) (fixtureHeight texture) 1)
      pure $ case answer of
        Right image → Right (name, Just image)
        Left (RefusedImageUnsupported _ _) | name == Bc7Block → Right (name, Nothing)
        Left refusal → Left refusal

-- | Each made texture's one-level upload.
uploadRequests ∷ Made → [UploadRequest]
uploadRequests made = [UploadImage image [fixtureBytes (fixture name)] | (name, image) ← Map.toList (madeTextures made)]

-- | The drawing's state: the layout, each texture's handle, and the
-- pipeline built for each colour format.
data Sprites = Sprites
  { spritesLayout ∷ !PipelineLayout
  , spritesHandles ∷ !(Map FixtureName TextureHandle)
  , spritesPipelines ∷ !(IORef (Map Word32 Pipeline))
  }

-- | Register every made texture with the table, once its upload has
-- completed.
registerSprites ∷ Builders q inst msgr phys dev cmd → Made → IO (Either Refusal Sprites)
registerSprites builders made = do
  handles ← traverse (\(name, image) → fmap ((,) name) <$> registerImage builders image) (Map.toList (madeTextures made))
  case sequence handles of
    Left refusal → pure (Left refusal)
    Right registered → Right . Sprites (madeLayout made) (Map.fromList registered) <$> newIORef Map.empty

-- | The handle a fixture's texture was registered under, if it was made.
spritesHandle ∷ FixtureName → Sprites → Maybe TextureHandle
spritesHandle name = Map.lookup name . spritesHandles

-- | Whether the BC7 fixture was made, and so is drawn.
spritesWithBc7 ∷ Sprites → Bool
spritesWithBc7 = Map.member Bc7Block . spritesHandles

-- | The scene's pipeline for a colour format: premultiplied-alpha blending
-- over the table's layout, built the first time the format is drawn.
pipelineFor ∷ Builders q inst msgr phys dev cmd → Sprites → Word32 → IO (Either Refusal Pipeline)
pipelineFor builders sprites format =
  (Map.lookup format <$> readIORef (spritesPipelines sprites)) >>= \case
    Just pipeline → pure (Right pipeline)
    Nothing →
      buildPipeline builders (spritesLayout sprites) spritesShaders format BlendPremultipliedAlpha >>= \case
        Left refusal → pure (Left refusal)
        Right pipeline → Right pipeline <$ atomicModifyIORef' (spritesPipelines sprites) (\held → (Map.insert format pipeline held, ()))

-- | Where the scene is drawn: an offscreen colour target, cleared from
-- undefined and copied into a readback afterwards; or the host's frame,
-- cleared, at its extent.
data SceneTarget
  = Offscreen !Image !Readback
  | Frame !Word32 !Word32

-- | Record the scene with this pipeline: every draw, each with its own
-- sampler, in painter order, over the transparent clear.
recordScene ∷ Sprites → Pipeline → SceneTarget → Recorder q inst msgr phys dev cmd → IO (Either Refusal ())
recordScene sprites pipeline target recorder = do
  let draws = sceneDraws (spritesWithBc7 sprites)
      instanceBytes = sceneInstanceBytes sprites
      (width, height) = case target of
        Offscreen _ _ → (fromIntegral targetSide, fromIntegral targetSide)
        Frame w h → (w, h)
  claims ←
    traverse
      (\bytes → claimRegion recorder (fromIntegral (ByteString.length bytes)) 16 >>= either (pure . Left) (\claim → fmap (const claim) <$> writeClaim recorder claim 0 bytes))
      [quadCorners, quadIndices, instanceBytes]
  case sequence claims of
    Left refusal → pure (Left refusal)
    Right [corners, indices, instances] →
      inOrder $
        [ case target of
            Offscreen image _ → beginRenderingInto recorder image ClearFromUndefined (ClearColor 0 0 0 0)
            Frame _ _ → beginRendering recorder (ClearColor 0 0 0 0)
        , bindPipeline recorder pipeline
        , setViewport recorder (Viewport 0 0 (fromIntegral width) (fromIntegral height))
        , setScissor recorder (Rect 0 0 width height)
        , bindVertexBuffer recorder 0 (FromClaim corners 0)
        , bindIndexBuffer recorder (FromClaim indices 0) Index16
        , bindTable recorder
        ]
          <> concat
            [ [ bindVertexBuffer recorder 1 (FromClaim instances (fromIntegral first * instanceStride))
              , selectSampler recorder (tableSamplerIndex (drawFilter draw))
              , drawIndexed recorder 6 (fromIntegral (length (drawInstances draw)))
              ]
            | (first, draw) ← zip (scanl (+) 0 (map (length . drawInstances) draws)) draws
            ]
          <> [endRendering recorder]
          <> case target of
            Offscreen image readback →
              [ transitionResource recorder image (FromUse ColorAttachment) TransferRead
              , copyTargetToReadback recorder image readback
              , transitionResource recorder image (FromUse TransferRead) ColorAttachment
              ]
            Frame _ _ → []
    Right _ → pure (Left (RefusedIllegal "the scene's three ring regions were not all claimed"))

-- | The scene's instance data, every draw's in order, each instance carrying
-- its texture's handle. It depends on the handles alone, so it is the same
-- bytes before and after a swap (GRS-9), which redirects a handle without
-- changing it.
sceneInstanceBytes ∷ Sprites → ByteString.ByteString
sceneInstanceBytes sprites = encodeInstances handleOf (concatMap drawInstances (sceneDraws (spritesWithBc7 sprites)))
  where
    handleOf name = maybe (0, 0) (\handle → (handleIndex handle, handleGeneration handle)) (Map.lookup name (spritesHandles sprites))

-- | Run each command in order, stopping at the first refusal.
inOrder ∷ [IO (Either Refusal ())] → IO (Either Refusal ())
inOrder = \case
  [] → pure (Right ())
  step : rest → step >>= either (pure . Left) (const (inOrder rest))
