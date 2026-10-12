-- | The scene3d sample's windowed mode (GRS-13): the same two flat-coloured
-- cubes, drawn indexed with a depth test into the frame's own image with the
-- depth image of the frame's swapchain generation, from a camera that orbits
-- the scene.
--
-- Like "Hetoimasia.Sample.Scene3d" it is written against the native backend's
-- public vocabulary alone and names nothing of the window integration: the
-- host's renderer hands it a frame's extent, color format and depth image
-- ('WindowedFrame') and the constructions it lends ('Builders'), and it holds
-- no native handle. It owns the session's shared ring and one pipeline for
-- each color format it meets, made on the owner's thread the first time a
-- frame needs them, and kept for the host's lifetime.
--
-- = Drawing
--
-- A frame starts a pass into the frame's image and the generation's depth
-- image together ('beginFrameRenderingWithDepth'): the color cleared to the
-- scene's clear color and the depth to 1.0, both from undefined, so a frame
-- needs nothing of the one before it and the depth image, shared by the
-- generation's frames in flight, is ordered by the backend's boundary
-- barriers. The cubes are drawn as the offscreen evidence draws them — nearer
-- first, vertices and indices written into ring regions the batch claims,
-- each cube's transform pushed as a matrix — with the projection built for the
-- window's own aspect ratio.
--
-- = The camera
--
-- 'orbitPose' places the camera on a circle of radius 7 about the scene's
-- vertical axis at height 2.6, looking at the scene's centre, at the angle it
-- is given; the application advances that angle by 'orbitDegreesPerFrame' a
-- frame until the window is closed.
--
-- = Probes
--
-- 'windowedProbes' scales the front pose's probes of
-- "Hetoimasia.Sample.Scene3d.Scene" to a window's framebuffer extent, whose
-- aspect ratio is the evidence target's (4:3), keeping those that are still
-- well inside one face at that size; the oracle
-- ("Hetoimasia.Sample.Scene3d.Oracle") gives each its expected color. The
-- swapchain is sRGB, so a color the shaders write is stored encoded:
-- 'storedChannel' is what a channel of an expected color reads as.
--
-- = State
--
-- +------------------+--------------+------------------------------+--------+-----------------------+----------------------------+
-- | State            | Owner        | Readers and writers          | Thread | Lifetime              | Reset or disposal          |
-- +==================+==============+==============================+========+=======================+============================+
-- | The ring, and a  | The host     | 'drawWindowed' makes them on | Owner  | From the first frame  | Released and destroyed with |
-- | pipeline a color | session      | the first frame that needs   |        | until the host        | every managed resource     |
-- | format           |              | them and reads them after    |        | session ends          | before the device          |
-- +------------------+--------------+------------------------------+--------+-----------------------+----------------------------+
module Hetoimasia.Sample.Scene3d.Windowed
  ( -- * The scene
    WindowedScene
  , newWindowedScene
  , WindowedFrame (..)
  , drawWindowed
    -- * The camera
  , orbitPose
  , orbitRadius
  , orbitHeight
  , orbitDegreesPerFrame
    -- * Probes
  , WindowedProbe (..)
  , windowedProbes
  , scaledPixel
  , storedChannel
  , storedColour
  ) where

import qualified Data.ByteString as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Word (Word32, Word8)

import Hetoimasia.GPU.Vulkan.Native.Recording
  ( BufferSource (..)
  , ClearColor (..)
  , Image
  , IndexType (..)
  , PassStart (..)
  , Pipeline
  , PipelineBlend (..)
  , PushStage (..)
  , Recorder
  , Rect (..)
  , Refusal (..)
  , Viewport (..)
  , beginFrameRenderingWithDepth
  , bindIndexBuffer
  , bindPipeline
  , bindVertexBuffer
  , claimRegion
  , clearedDepth
  , depthTested
  , drawIndexed
  , endRendering
  , pushConstants
  , setScissor
  , setViewport
  , writeClaim
  )
import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceExtent (..))
import Hetoimasia.Sample.Scene3d (Builders (..), sceneRingSize)
import Hetoimasia.Sample.Scene3d.Camera (packMatrix, transformFor)
import Hetoimasia.Sample.Scene3d.Oracle (expectedColourIn, interiorIn)
import Hetoimasia.Sample.Scene3d.Scene
  ( Pose (..)
  , PoseName (..)
  , Probe (..)
  , Rgba (..)
  , clearColour
  , cubeIndices
  , cubeNamed
  , cubeVertexBytes
  , drawOrder
  , indexCount
  , poseNamed
  , sceneProbes
  , targetHeight
  , targetWidth
  )
import Hetoimasia.Sample.Scene3d.Shaders (scene3dShaders)

-- | What a frame needs of the scene: the ring is made once, and a pipeline for
-- each color format.
data WindowedScene = WindowedScene
  { windowedRing ∷ !(IORef Bool)
  , windowedPipelines ∷ !(IORef (Map.Map Word32 Pipeline))
  }

newWindowedScene ∷ IO WindowedScene
newWindowedScene = WindowedScene <$> newIORef False <*> newIORef Map.empty

-- | What one frame is drawn into: the extent of the frame's image in pixels,
-- its color format, and the depth image of the frame's generation.
data WindowedFrame = WindowedFrame
  { frameExtent ∷ !SurfaceExtent
  , frameColourFormat ∷ !Word32
  , frameDepth ∷ !Image
  }

-- | Draw the scene from this camera into the frame, making the ring and the
-- format's pipeline first if the session has none yet. The frame's image is
-- already in the color-attachment layout and is returned to presentation by
-- the host.
drawWindowed
  ∷ WindowedScene
  → Builders q inst msgr phys dev cmd
  → Pose
  → WindowedFrame
  → Recorder q inst msgr phys dev cmd
  → IO (Either Refusal ())
drawWindowed scene builders pose frame recorder =
  ensureRing >>= \case
    Left refusal → pure (Left refusal)
    Right () →
      ensurePipeline >>= \case
        Left refusal → pure (Left refusal)
        Right pipeline → record pipeline
  where
    SurfaceExtent width height = frameExtent frame
    aspect = fromIntegral width / fromIntegral height
    ensureRing =
      readIORef (windowedRing scene) >>= \case
        True → pure (Right ())
        False →
          buildRing builders sceneRingSize >>= \case
            Left refusal → pure (Left refusal)
            Right () → Right () <$ writeIORef (windowedRing scene) True
    ensurePipeline =
      Map.lookup (frameColourFormat frame) <$> readIORef (windowedPipelines scene) >>= \case
        Just pipeline → pure (Right pipeline)
        Nothing →
          chooseDepthFormat builders >>= \case
            Left refusal → pure (Left refusal)
            Right depthFormat →
              buildLayout builders scene3dShaders >>= \case
                Left refusal → pure (Left refusal)
                Right layout →
                  buildPipeline builders layout scene3dShaders (frameColourFormat frame) BlendNone (depthTested depthFormat) >>= \case
                    Left refusal → pure (Left refusal)
                    Right pipeline → Right pipeline <$ modifyIORef' (windowedPipelines scene) (Map.insert (frameColourFormat frame) pipeline)
    record pipeline = case traverse (fmap packMatrix . transformFor aspect pose . cubeNamed) drawOrder of
      Nothing → pure (Left (RefusedIllegal "a camera or a model matrix the math package refuses"))
      Just matrices → do
        let vertexData = [cubeVertexBytes name | name ← drawOrder]
        claims ←
          traverse
            (\bytes → claimRegion recorder (fromIntegral (ByteString.length bytes)) 16 >>= either (pure . Left) (\claim → fmap (const claim) <$> writeClaim recorder claim 0 bytes))
            [ByteString.concat vertexData, cubeIndices]
        case sequence claims of
          Left refusal → pure (Left refusal)
          Right [vertices, indices] →
            inOrder $
              [ beginFrameRenderingWithDepth recorder (clearValue clearColour) (clearedDepth (frameDepth frame) ClearFromUndefined)
              , bindPipeline recorder pipeline
              , setViewport recorder (Viewport 0 0 (fromIntegral width) (fromIntegral height))
              , setScissor recorder (Rect 0 0 width height)
              , bindIndexBuffer recorder (FromClaim indices 0) Index16
              ]
                <> concat
                  [ [ bindVertexBuffer recorder 0 (FromClaim vertices (fromIntegral offset))
                    , pushConstants recorder [PushVertex] 0 matrix
                    , drawIndexed recorder (fromIntegral indexCount) 1
                    ]
                  | (offset, matrix) ← zip (scanl (+) 0 (map ByteString.length vertexData)) matrices
                  ]
                <> [endRendering recorder]
          Right _ → pure (Left (RefusedIllegal "the scene's two ring regions were not both claimed"))

-- | The clear color as the pass clears to it: each channel a multiple of 1/255.
clearValue ∷ Rgba → ClearColor
clearValue (Rgba r g b a) = ClearColor (channel r) (channel g) (channel b) (channel a)
  where
    channel byte = fromIntegral byte / 255

-- | Run each command in order, stopping at the first refusal.
inOrder ∷ [IO (Either Refusal ())] → IO (Either Refusal ())
inOrder = \case
  [] → pure (Right ())
  step : rest → step >>= either (pure . Left) (const (inOrder rest))

-- ---------------------------------------------------------------------------
-- The camera

-- | How far the camera is from the scene's vertical axis, and how high.
orbitRadius, orbitHeight ∷ Double
orbitRadius = 7
orbitHeight = 2.6

-- | How far the application turns the camera each frame it draws: slowly,
-- about fifteen degrees a second at sixty frames a second.
orbitDegreesPerFrame ∷ Double
orbitDegreesPerFrame = 0.25

-- | The camera at this angle, in degrees, of its orbit: on a circle about the
-- scene's vertical axis, looking at the scene's centre. At zero it is on the
-- +Z axis, as the front pose is, nearly.
orbitPose ∷ Double → Pose
orbitPose degrees =
  Pose
    { poseName = FrontPose
    , poseEye = (orbitRadius * sin radians, orbitHeight, orbitRadius * cos radians)
    , poseTarget = (0, 0.2, 0)
    , poseUp = (0, 1, 0)
    , poseFovDegrees = 45
    , poseNear = 0.5
    , poseFar = 50
    }
  where
    radians = degrees * pi / 180

-- ---------------------------------------------------------------------------
-- Probes

-- | A probe of the front pose at a window's framebuffer extent: the scene's
-- probe, the pixel it falls on there, and what the oracle says that pixel is.
data WindowedProbe = WindowedProbe
  { windowedProbe ∷ !Probe
  , windowedPixel ∷ !(Int, Int)
  , windowedExpected ∷ !Rgba
  }
  deriving (Eq, Show)

-- | The pixel of a target of this extent that a pixel of the evidence target
-- falls on: the same place in the picture, which has the same aspect ratio.
scaledPixel ∷ (Int, Int) → (Int, Int) → (Int, Int)
scaledPixel (width, height) (x, y) = ((x * width) `div` targetWidth, (y * height) `div` targetHeight)

-- | The front pose's probes at a framebuffer of this extent, those that are
-- well inside one face (or outside both cubes) there only.
windowedProbes ∷ (Int, Int) → [WindowedProbe]
windowedProbes extent =
  [ WindowedProbe probe pixel (expectedColourIn extent pose pixel)
  | probe ← sceneProbes
  , probePose probe == FrontPose
  , let pixel = scaledPixel extent (probePixel probe)
  , interiorIn extent pose pixel
  ]
  where
    pose = poseNamed FrontPose

-- | What a channel of a color the shaders wrote reads as in an sRGB image: the
-- 8-bit sRGB encoding of the linear value the byte stands for.
storedChannel ∷ Word8 → Word8
storedChannel byte = round (255 * max 0 (min 1 encodedValue))
  where
    linear = fromIntegral byte / 255 ∷ Double
    encodedValue
      | linear <= 0.0031308 = 12.92 * linear
      | otherwise = 1.055 * linear ** (1 / 2.4) - 0.055

-- | A color as it reads in an sRGB image, alpha unencoded.
storedColour ∷ Rgba → Rgba
storedColour (Rgba r g b a) = Rgba (storedChannel r) (storedChannel g) (storedChannel b) a
