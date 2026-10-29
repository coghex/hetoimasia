-- | Recording an adopted scene with the frame's own metrics (LFE-20).
--
-- = What a frame is built from
--
-- The scene a window holds is authored in fixed logical pixels from the upper left, with UI scale 1, no
-- snapping, nearest sampling of the whole image and ordered alpha blending over its explicit clear
-- ("Hetoimasia.LuaEngine.Scene"). It carries no viewport. Each frame the owner asks the renderer for names
-- the window's /current/ observations, and the frame is built from those alone: the framebuffer extent of
-- the generation the image belongs to, the window's latest logical extent and its content scale
-- ('FrameFacts'). 'frameCandidate' turns the adopted scene and those facts into the renderer's pure frame
-- (the full-window view of that framebuffer, the sprites at their authored rectangles), and the renderer's
-- own validation judges it. A resize therefore clips and never stretches or recentres, and needs no new
-- publication, revision or Lua call; the scene's texture references are the scene's, unchanged by any
-- frame, so a frame touches no hold.
--
-- A frame is skipped, as a refusal through the host's existing backoff, when the window has reported no
-- logical extent or no content scale, when they are not usable metrics, or when the renderer refuses the
-- frame; nothing is invented. A zero framebuffer extent is a valid empty viewport: nothing is drawn, and
-- the scene, its holds and the window's progress are untouched (a zero-size target is never asked for a
-- frame, and adopts and retires without one).
--
-- = Owned state, threads and lifetime
--
-- 'RenderSlot' holds the session's renderer and texture registry once the bootstrap made them, written
-- once by the composition before any window can exist, and read by the renderer hook on the graphics
-- owner's thread. A frame that finds it empty is a refusal, which skips the frame and loses nothing: the
-- scene's adoption and release do not pass through it. Nothing else is kept between frames.
module Hetoimasia.LuaEngine.Graphics.Scene.Render
  ( -- * The frame
    FrameFacts (..)
  , FrameSkip (..)
  , frameMetrics
  , frameCandidate

    -- * The renderer
  , RenderSession (..)
  , RenderSlot
  , newRenderSlot
  , fillRenderSlot
  , readRenderSlot
  , sceneRenderer
  , renderGraphicsFrame
  ) where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Data.Functor ((<&>))
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Set as Set
import qualified Data.Text as Text
import Data.Word (Word32)
import Hetoimasia.GPU.Vulkan.GLFW (FrameRequest (..), ImageFormat (Depth32Float), TextureHandle (..), VulkanRenderer (..))
import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceExtent (..))
import Hetoimasia.GPU.Vulkan.Native.Recording (Recorder, Refusal (RefusedIllegal))
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene (graphicsContent))
import Hetoimasia.LuaEngine.Graphics.Texture.Host (renderBuilders)
import Hetoimasia.LuaEngine.Graphics.Texture.Port (TextureRef (..), textureRefOf)
import Hetoimasia.LuaEngine.Scene (SnapshotRefusal, sceneCandidate)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..), validMetrics)
import Hetoimasia.Render.TwoD.Snapshot (Snapshot)
import Hetoimasia.Render.TwoD.Validation (ValidSnapshot, validateSnapshot)
import qualified Hetoimasia.Render.TwoD.Validation as Validation
import Hetoimasia.Render.TwoD.Vulkan (Renderer, prepareSnapshot)
import Hetoimasia.Render.TwoD.Vulkan.Builders (Builders)
import Hetoimasia.Render.TwoD.Vulkan.Frame
  ( Attachment (..)
  , DepthBinding (..)
  , FrameInput (..)
  , FrameRefusal (..)
  )
import Hetoimasia.Render.TwoD.Vulkan.Textures (Textures, fromBackendHandle, registeredMarks)

-- | What one frame says of its window: the framebuffer extent of the generation the image belongs to, and
-- the window's own latest observations, which may be absent.
data FrameFacts = FrameFacts
  { factsFramebuffer ∷ !(Word32, Word32)
  , factsLogical ∷ !(Maybe (Word32, Word32))
  , factsScale ∷ !(Maybe (Float, Float))
  }
  deriving (Eq, Show)

-- | Why a frame was skipped rather than recorded.
data FrameSkip
  = -- | The window has reported no logical extent.
    NoLogicalExtent
  | -- | The window has reported no content scale.
    NoContentScale
  | -- | The facts are not usable metrics: they are shown.
    MetricsNotUsable !TargetMetrics
  | -- | The scene's content could not be made a frame (a texture identity the registry cannot resolve).
    CandidateRefused !SnapshotRefusal
  | -- | The renderer's validation refused the candidate: a defect of the adapter, not of a script.
    CandidateInvalid !(NonEmpty Validation.Refusal)
  deriving (Eq, Show)

-- | The metrics a frame maps its views with, from the frame's own observations. Nothing is invented:
-- missing facts are a skip.
frameMetrics ∷ FrameFacts → Either FrameSkip TargetMetrics
frameMetrics facts = case (factsLogical facts, factsScale facts) of
  (Nothing, _) → Left NoLogicalExtent
  (_, Nothing) → Left NoContentScale
  (Just (logicalWidth, logicalHeight), Just (scaleX, scaleY)) →
    let (width, height) = factsFramebuffer facts
        metrics = TargetMetrics (PixelExtent (fromIntegral logicalWidth) (fromIntegral logicalHeight)) (PixelExtent (fromIntegral width) (fromIntegral height)) scaleX scaleY
     in Right metrics

-- | The renderer's frame of an adopted scene for a frame's facts: the scene's content under those metrics,
-- validated. The same scene under other facts is the same sprites at the same authored rectangles in
-- another full-window view.
frameCandidate ∷ GraphicsScene → FrameFacts → Either FrameSkip (Snapshot, ValidSnapshot)
frameCandidate scene facts = do
  metrics ← frameMetrics facts
  candidate ← either (\refusal → Left (refusedFor metrics refusal)) Right (sceneCandidate (Just . handleOf) metrics (graphicsContent scene))
  valid ← either (Left . CandidateInvalid) Right (validateSnapshot candidate)
  Right (candidate, valid)
  where
    refusedFor metrics refusal = case refusal of
      _ | not (usable metrics) → MetricsNotUsable metrics
      other → CandidateRefused other
    usable = validMetrics
    handleOf identity =
      let TextureRef index generation = textureRefOf identity
       in fromBackendHandle (TextureHandle index generation)

-- The renderer -----------------------------------------------------------------------------------------

-- | The session's renderer and texture registry, as the bootstrap made them.
data RenderSession = RenderSession
  { renderRenderer ∷ !Renderer
  , renderTextures ∷ !Textures
  }

-- | Where the renderer hook finds the session's renderer: filled once, by the composition, before any
-- window exists.
newtype RenderSlot = RenderSlot (TVar (Maybe RenderSession))

newRenderSlot ∷ IO RenderSlot
newRenderSlot = RenderSlot <$> newTVarIO Nothing

fillRenderSlot ∷ RenderSlot → RenderSession → IO ()
fillRenderSlot (RenderSlot var) session = atomically (writeTVar var (Just session))

readRenderSlot ∷ RenderSlot → IO (Maybe RenderSession)
readRenderSlot (RenderSlot var) = readTVarIO var

-- | The 'VulkanRenderer' the host is configured with: each frame of a window's adopted scene, recorded with
-- that frame's own metrics. It reads the slot, builds the frame, and records it; an empty slot is a skipped
-- frame.
sceneRenderer ∷ RenderSlot → VulkanRenderer GraphicsScene
sceneRenderer slot = VulkanRenderer $ \scene request construction recorder →
  readRenderSlot slot >>= \case
    Nothing → pure (Left (RefusedIllegal "the scene renderer has no session yet, so the frame is skipped"))
    Just session → renderGraphicsFrame session (renderBuilders construction) scene request recorder

-- | Record one frame of an adopted scene.
renderGraphicsFrame
  ∷ RenderSession
  → Builders q inst msgr phys dev cmd
  → GraphicsScene
  → FrameRequest
  → Recorder q inst msgr phys dev cmd
  → IO (Either Refusal ())
renderGraphicsFrame session builders scene request recorder =
  case frameCandidate scene facts of
    Left skip → pure (Left (RefusedIllegal (Text.pack ("the frame is skipped: " <> show skip))))
    Right (_, valid) → do
      marks ← registeredMarks (renderTextures session)
      prepareSnapshot
        builders
        (renderRenderer session)
        FrameInput
          { frameSnapshot = valid
          , frameMarks = marks
          , frameTarget = const Nothing
          , frameWindow = Just (Attachment (requestFormat request) width height metrics)
          , frameWindowDepth = (`DepthBinding` Depth32Float) <$> requestDepth request
          , frameChunks = const Nothing
          , frameOmitted = Set.empty
          }
        >>= \case
          Left refusal → pure (Left (refused refusal))
          Right recording → recording recorder <&> either (Left . refused) Right
  where
    SurfaceExtent width height = requestExtent request
    facts = FrameFacts (width, height) (requestLogicalExtent request) (requestContentScale request)
    metrics = either (const (TargetMetrics (PixelExtent 0 0) (PixelExtent 0 0) 1 1)) id (frameMetrics facts)
    refused = \case
      RefusedByBackend refusal → refusal
      other → RefusedIllegal (Text.pack (show other))

