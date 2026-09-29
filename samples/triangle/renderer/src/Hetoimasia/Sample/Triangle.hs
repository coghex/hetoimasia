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
-- | The pipeline       | A 'Triangle'  | 'drawTriangle', inside the     | Owner  | The first frame of a format   | Released and destroyed by    |
-- | layouts, one per   |               | host's frame                   |        | that built one, whether or    | the host before the device,  |
-- | color format       |               |                                |        | not its pipeline was refused, | after every pipeline over it |
-- |                    |               |                                |        | until the host's session ends |                              |
-- +--------------------+---------------+--------------------------------+--------+-------------------------------+------------------------------+
-- | The pipelines, one | A 'Triangle'  | 'drawTriangle', inside the     | Owner  | The first frame of a format   | Released and destroyed by    |
-- | per color format   |               | host's frame                   |        | whose pipeline was built,     | the host before the device   |
-- |                    |               |                                |        | until the host's session ends |                              |
-- +--------------------+---------------+--------------------------------+--------+-------------------------------+------------------------------+
--
-- A format's layout is built once: a refused pipeline leaves it held for the
-- next frame's attempt ("Hetoimasia.Sample.Triangle.Pipelines"), never built
-- again. The handles themselves are the host session's managed resources: the
-- host destroys whatever was built, pipeline before layout, on its normal and
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

import Data.Word (Word32)

import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceExtent (..))
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( ClearColor (..)
  , Pipeline
  , PipelineLayout
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
import Hetoimasia.Sample.Triangle.Pipelines (Builders (..), Pipelines, newPipelines, pipelineFor, pipelineFormats)
import Hetoimasia.Sample.Triangle.Shaders (triangleShaders)

-- | The drawing's own state: the pipeline layout and the pipeline held for
-- each color format it has been asked to draw into.
newtype Triangle = Triangle (Pipelines PipelineLayout Pipeline)

newTriangle ∷ IO Triangle
newTriangle = Triangle <$> newPipelines

-- | The color formats a pipeline has been built for so far.
triangleFormats ∷ Triangle → IO [Word32]
triangleFormats (Triangle pipelines) = pipelineFormats pipelines

-- | Clear a frame of this color format and extent and draw the triangle
-- across it, inside the dynamic rendering this begins and ends, building a
-- pipeline layout and a pipeline for the format the first time it meets it. A
-- refusal is answered as it is, which skips the frame under the host's
-- renderer contract; the next frame tries again, over the layout already
-- built when only the pipeline was refused.
drawTriangle ∷ Triangle → Builders PipelineLayout Pipeline → Word32 → SurfaceExtent → Recorder q inst msgr phys dev cmd → IO (Either Refusal ())
drawTriangle (Triangle pipelines) builders format (SurfaceExtent width height) recorder = do
  built ← pipelineFor pipelines builders format
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
