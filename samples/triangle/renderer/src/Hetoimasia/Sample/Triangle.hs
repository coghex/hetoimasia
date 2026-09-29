-- | The triangle sample's drawing: one triangle over a clear, recorded into
-- whatever frame the host lends it.
--
-- It is written against the native backend's public recording vocabulary
-- alone — the recorder, the managed pipeline handles, the embedded shaders —
-- and names nothing of the window integration, so the integration's native
-- suite can depend on it without depending on a package that depends on the
-- integration. A consumer turns it into the host's renderer in one line,
-- handing it the frame's format and extent and the two constructions it needs
-- from the host's 'Hetoimasia.GPU.Vulkan.GLFW.Construction':
--
-- > triangleRenderer ∷ Triangle → VulkanRenderer scene
-- > triangleRenderer triangle = VulkanRenderer $ \_ request construction recorder →
-- >   drawTriangle triangle
-- >     (Builders (constructPipelineLayout construction) (constructPipeline construction))
-- >     (requestFormat request) (requestExtent request) recorder
--
-- The sample's executable does exactly that, and so does the native suite's
-- required profile. It holds no native handle and makes no GLFW or Vulkan
-- call of its own: the host calls the renderer on the graphics owner's thread,
-- once per frame.
--
-- = State
--
-- +--------------------+---------------+--------------------------------+--------+-------------------------------+------------------------------+
-- | State              | Owner         | Readers and writers            | Thread | Lifetime                      | Reset or disposal            |
-- +====================+===============+================================+========+===============================+==============================+
-- | The pipelines, one | A 'Triangle'  | 'drawTriangle', inside the     | Owner  | Its first frame of a format   | Released and destroyed by    |
-- | per color format   |               | host's frame                   |        | until the host's session ends | the host before the device   |
-- +--------------------+---------------+--------------------------------+--------+-------------------------------+------------------------------+
--
-- The handles themselves are the host session's managed resources: the host
-- destroys whatever was built, pipeline before layout, on its normal and
-- terminal exits alike.
module Hetoimasia.Sample.Triangle
  ( -- * Drawing
    Triangle
  , newTriangle
  , Builders (..)
  , drawTriangle
  , triangleFormats

    -- * The shaders
  , triangleShaders
  ) where

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word32)

import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceExtent (..))
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( ClearColor (..)
  , Pipeline
  , PipelineLayout
  , PipelineShaders
  , Recorder
  , Rect (..)
  , Refusal
  , Viewport (..)
  , beginRendering
  , bindPipeline
  , draw
  , endRendering
  , setScissor
  , setViewport
  )
import Hetoimasia.Sample.Triangle.Geometry (clearColour)
import Hetoimasia.Sample.Triangle.Shaders (triangleShaders)

-- | The two managed constructions drawing needs, as the host lends them with
-- each frame.
data Builders = Builders
  { buildLayout ∷ IO (Either Refusal PipelineLayout)
    -- ^ A pipeline layout with no descriptor sets and no push constants.
  , buildPipeline ∷ PipelineLayout → PipelineShaders → Word32 → IO (Either Refusal Pipeline)
    -- ^ A graphics pipeline over a layout, for a color format.
  }

-- | The drawing's own state: the pipeline built for each color format it has
-- been asked to draw into.
newtype Triangle = Triangle (IORef (Map Word32 Pipeline))

newTriangle ∷ IO Triangle
newTriangle = Triangle <$> newIORef Map.empty

-- | The color formats a pipeline has been built for so far.
triangleFormats ∷ Triangle → IO [Word32]
triangleFormats (Triangle pipelines) = Map.keys <$> readIORef pipelines

-- | Clear a frame of this color format and extent and draw the triangle
-- across it, inside the dynamic rendering this begins and ends, building a
-- pipeline layout and a pipeline for the format the first time it meets it. A
-- refusal is answered as it is, which skips the frame under the host's
-- renderer contract; the next frame tries again.
drawTriangle ∷ Triangle → Builders → Word32 → SurfaceExtent → Recorder q inst msgr phys dev cmd → IO (Either Refusal ())
drawTriangle (Triangle pipelines) builders format (SurfaceExtent width height) recorder = do
  held ← Map.lookup format <$> readIORef pipelines
  built ← case held of
    Just pipeline → pure (Right pipeline)
    Nothing →
      buildLayout builders >>= \case
        Left refusal → pure (Left refusal)
        Right layout →
          buildPipeline builders layout triangleShaders format >>= \case
            Left refusal → pure (Left refusal)
            Right pipeline → Right pipeline <$ atomicModifyIORef' pipelines (\known → (Map.insert format pipeline known, ()))
  case built of
    Left refusal → pure (Left refusal)
    Right pipeline →
      inOrder
        [ beginRendering recorder (let (red, green, blue) = clearColour in ClearColor red green blue 1)
        , bindPipeline recorder pipeline
        , setViewport recorder (Viewport 0 0 (fromIntegral width) (fromIntegral height))
        , setScissor recorder (Rect 0 0 width height)
        , draw recorder 3 1
        , endRendering recorder
        ]

-- | Run each command in order, stopping at the first refusal.
inOrder ∷ [IO (Either Refusal ())] → IO (Either Refusal ())
inOrder = \case
  [] → pure (Right ())
  step : rest → step >>= either (pure . Left) (const (inOrder rest))
