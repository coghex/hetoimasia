-- | The scene3d sample's drawing (GRS-10): two flat-coloured cubes, one in
-- front of the other, drawn indexed with a depth test from the two camera poses
-- of "Hetoimasia.Sample.Scene3d.Scene" into an offscreen colour target and a
-- depth target.
--
-- It is written against the native backend's public vocabulary alone and
-- names nothing of the window integration, so the integration's native suite
-- can depend on it, as the sample's executable does. The constructions it
-- needs arrive as 'Builders', which a host fills from the construction an
-- owner-thread action lends it; it holds no native handle and makes no GLFW
-- or Vulkan call of its own.
--
-- = Drawing
--
-- 'makeScene' asks the backend for the depth-only format it will use
-- ('chooseDepthFormat') and makes the session's shared ring, the RGBA8 colour
-- target, a depth target of the same extent in that format, one readback
-- buffer a pose, the pipeline layout the shaders' push-constant block needs
-- and a pipeline over it that tests and writes depth, less-or-equal
-- ('depthTested'). 'recordPose' records one pose into one batch: both cubes'
-- vertices and the indices written into ring regions the batch claims, a pass
-- into both targets that clears the colour to 'clearColour' and the depth to
-- 1.0, and for each cube in the order the scene draws them — the nearer
-- first — its transform pushed as a matrix this module packs itself
-- ('packMatrix') and one indexed draw. The colour target is then moved to its
-- transfer-source use, copied into the pose's readback and returned to rest;
-- the depth target stays at rest in its depth-attachment use.
--
-- = State
--
-- +-------------------------+--------------+------------------------------+--------+---------------------------------+--------------------------------+
-- | State                   | Owner        | Readers and writers          | Thread | Lifetime                        | Reset or disposal              |
-- +=========================+==============+==============================+========+=================================+================================+
-- | The ring, the targets,  | The host     | 'makeScene' makes them       | Owner  | From 'makeScene' until the host | Released and destroyed with    |
-- | the readbacks, the      | session      | through 'Builders'; batches  |        | session ends                    | every managed resource before  |
-- | layout and the pipeline |              | 'recordPose' records read    |        |                                 | the device                     |
-- |                         |              | them                         |        |                                 |                                |
-- +-------------------------+--------------+------------------------------+--------+---------------------------------+--------------------------------+
module Hetoimasia.Sample.Scene3d
  ( -- * Constructions
    Builders (..)
    -- * Making the sample
  , Made (..)
  , makeScene
  , readbackFor
    -- * Recording
  , recordPose
    -- * Configuration
  , sceneRingSize
  , colourFormat
  ) where

import qualified Data.ByteString as ByteString
import Data.Word (Word32)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Vulkan.Native.Recording
  ( BufferSource (..)
  , ClearColor (..)
  , DepthPass (..)
  , Image
  , ImageDescription (..)
  , ImageFormat (..)
  , ImageKind (..)
  , IndexType (..)
  , PassStart (..)
  , Pipeline
  , PipelineBlend (..)
  , PipelineDepth
  , PipelineLayout
  , PushStage (..)
  , Readback
  , Recorder
  , Rect (..)
  , Refusal (..)
  , ResourceUse (..)
  , RingSize
  , TransitionSource (..)
  , Viewport (..)
  , beginRenderingWithDepth
  , bindIndexBuffer
  , bindPipeline
  , bindVertexBuffer
  , claimRegion
  , copyTargetToReadback
  , defaultDepthClear
  , depthTested
  , drawIndexed
  , endRendering
  , formatCode
  , pushConstants
  , setScissor
  , setViewport
  , transitionResource
  , validateRingSize
  , writeClaim
  )
import Hetoimasia.GPU.Vulkan.Native.Shader (CheckedShaders)
import Hetoimasia.Sample.Scene3d.Camera (packMatrix, transform)
import Hetoimasia.Sample.Scene3d.Scene
  ( PoseName
  , Rgba (..)
  , clearColour
  , cubeIndices
  , cubeNamed
  , cubeVertexBytes
  , drawOrder
  , indexCount
  , poseName
  , poseNamed
  , poses
  , targetBytes
  , targetHeight
  , targetWidth
  )
import Hetoimasia.Sample.Scene3d.Shaders (scene3dShaders)

-- | The constructions the sample needs, as the host lends them inside an
-- owner-thread action. The record's type parameters are the host session's,
-- which only a batch's recorder names.
data Builders q inst msgr phys dev cmd = Builders
  { buildRing ∷ RingSize → IO (Either Refusal ())
  , buildImage ∷ ImageDescription → IO (Either Refusal Image)
  , buildLayout ∷ CheckedShaders → IO (Either Refusal PipelineLayout)
  , buildPipeline ∷ PipelineLayout → CheckedShaders → Word32 → PipelineBlend → PipelineDepth → IO (Either Refusal Pipeline)
  , buildReadback ∷ Natural → IO (Either Refusal Readback)
  , chooseDepthFormat ∷ IO (Either Refusal ImageFormat)
    -- ^ The depth-only format the backend will use, asked of the device.
  }

-- | The session's shared ring: room for both cubes' vertices and indices many
-- times over.
sceneRingSize ∷ RingSize
sceneRingSize = either (error . show) id (validateRingSize (64 * 1024))

-- | The colour target's format: RGBA8, linear, so the bytes read back are the
-- bytes the shaders wrote, with no conversion.
colourFormat ∷ ImageFormat
colourFormat = Rgba8Linear

-- | What 'makeScene' made.
data Made = Made
  { madeColour ∷ !Image
  , madeDepth ∷ !Image
  , madeDepthFormat ∷ !ImageFormat
    -- ^ The depth format the backend chose, which the depth target and the
    -- pipeline share.
  , madePipeline ∷ !Pipeline
  , madeReadbacks ∷ ![(PoseName, Readback)]
    -- ^ One readback buffer a pose.
  }

-- | Make the ring, the depth format's choice, the targets, the readbacks, the
-- layout and the pipeline.
makeScene ∷ Builders q inst msgr phys dev cmd → IO (Either Refusal Made)
makeScene builders = do
  ring ← buildRing builders sceneRingSize
  case ring of
    Left refusal → pure (Left refusal)
    Right () →
      chooseDepthFormat builders >>= \case
        Left refusal → pure (Left refusal)
        Right depthFormat → do
          let extent kind format = ImageDescription kind format (fromIntegral targetWidth) (fromIntegral targetHeight) 1
          colour ← buildImage builders (extent ColorTarget colourFormat)
          depth ← buildImage builders (extent DepthTarget depthFormat)
          readbacks ← traverse (\pose → fmap ((,) pose) <$> buildReadback builders targetBytes) (map poseName poses)
          layout ← buildLayout builders scene3dShaders
          case (colour, depth, sequence readbacks, layout) of
            (Right colourImage, Right depthImage, Right held, Right made) →
              fmap (\pipeline → Made colourImage depthImage depthFormat pipeline held)
                <$> buildPipeline builders made scene3dShaders (formatCode colourFormat) BlendNone (depthTested depthFormat)
            (Left refusal, _, _, _) → pure (Left refusal)
            (_, Left refusal, _, _) → pure (Left refusal)
            (_, _, Left refusal, _) → pure (Left refusal)
            (_, _, _, Left refusal) → pure (Left refusal)

-- | A pose's readback buffer.
readbackFor ∷ Made → PoseName → Maybe Readback
readbackFor made name = lookup name (madeReadbacks made)

-- | Record one pose: the whole scene from this camera into the colour and
-- depth targets, and the colour target copied into the pose's readback. The
-- pass starts as given — 'ClearFromUndefined' for the first batch to use the
-- targets, which initializes them, and 'ClearTarget' for a later one — for both
-- targets alike.
recordPose ∷ Made → PoseName → PassStart → Recorder q inst msgr phys dev cmd → IO (Either Refusal ())
recordPose made name start recorder = case (readbackFor made name, transforms) of
  (Nothing, _) → pure (Left (RefusedIllegal "a pose with no readback"))
  (_, Nothing) → pure (Left (RefusedIllegal "a camera or a model matrix the math package refuses"))
  (Just readback, Just matrices) → do
    let vertexData = [cubeVertexBytes cube | cube ← drawOrder]
    claims ←
      traverse
        (\bytes → claimRegion recorder (fromIntegral (ByteString.length bytes)) 16 >>= either (pure . Left) (\claim → fmap (const claim) <$> writeClaim recorder claim 0 bytes))
        [ByteString.concat vertexData, cubeIndices]
    case sequence claims of
      Left refusal → pure (Left refusal)
      Right [vertices, indices] →
        inOrder $
          [ beginRenderingWithDepth recorder (madeColour made) start (clearValue clearColour) (DepthPass (madeDepth made) start defaultDepthClear)
          , bindPipeline recorder (madePipeline made)
          , setViewport recorder (Viewport 0 0 (fromIntegral targetWidth) (fromIntegral targetHeight))
          , setScissor recorder (Rect 0 0 (fromIntegral targetWidth) (fromIntegral targetHeight))
          , bindIndexBuffer recorder (FromClaim indices 0) Index16
          ]
            <> concat
              [ [ bindVertexBuffer recorder 0 (FromClaim vertices (fromIntegral offset))
                , pushConstants recorder [PushVertex] 0 (packMatrix matrix)
                , drawIndexed recorder (fromIntegral indexCount) 1
                ]
              | (offset, matrix) ← zip (scanl (+) 0 (map ByteString.length vertexData)) matrices
              ]
            <> [ endRendering recorder
               , transitionResource recorder (madeColour made) (FromUse ColorAttachment) TransferRead
               , copyTargetToReadback recorder (madeColour made) readback
               , transitionResource recorder (madeColour made) (FromUse TransferRead) ColorAttachment
               ]
      Right _ → pure (Left (RefusedIllegal "the scene's two ring regions were not both claimed"))
  where
    -- Each cube's transform, in the order the scene draws them.
    transforms = traverse (transform (poseNamed name) . cubeNamed) drawOrder

-- | The clear colour as the pass clears to it: each channel a multiple of
-- 1/255, so the device's conversion to 8 bits is exact.
clearValue ∷ Rgba → ClearColor
clearValue (Rgba r g b a) = ClearColor (channel r) (channel g) (channel b) (channel a)
  where
    channel byte = fromIntegral byte / 255

-- | Run each command in order, stopping at the first refusal.
inOrder ∷ [IO (Either Refusal ())] → IO (Either Refusal ())
inOrder = \case
  [] → pure (Right ())
  step : rest → step >>= either (pure . Left) (const (inOrder rest))
