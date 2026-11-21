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
-- = World scenes (TRA-9)
--
-- A terrain view's revision ("Hetoimasia.LuaEngine.Graphics.Scene.World") is drawn as published, under the frame's
-- own metrics, over the retained chunks it lists and the frame's @D32_SFLOAT@ depth image. Nothing of a revision is
-- drawn unless all of it can be: a frame whose request carries no depth image, or whose revision lists a chunk still
-- uploading or one whose upload failed, records nothing and is refused, so the target keeps what it last showed and
-- the host asks again at its backoff. Before a world frame records, the frame's attachment and slot are noted with
-- what it will have drawn ("Hetoimasia.LuaEngine.Graphics.Scene.Receipts"); any other frame clears the note, so only
-- a presentation of that frame advances the view's receipt. A registered offscreen target's frames are recorded by
-- whoever records its batches ('renderWorldTarget'), under the host's recording boundary.
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
  , renderWorldTarget
  ) where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import qualified Data.Map.Strict as Map
import Data.Functor ((<&>))
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Set as Set
import qualified Data.Text as Text
import Data.Word (Word32)
import Hetoimasia.GPU.Vulkan.GLFW (FrameRequest (..), Image, ImageFormat (Depth32Float), TextureHandle (..), VulkanRenderer (..))
import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceExtent (..))
import Hetoimasia.GPU.Vulkan.Native.Recording (Buffer, Recorder, Refusal (RefusedIllegal))
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene (graphicsContent, graphicsWorld))
import Hetoimasia.LuaEngine.Graphics.Scene.Receipts (DrawReceipts, noteFrameMetrics, noteRecorded, noteUnrecorded)
import Hetoimasia.LuaEngine.Graphics.Scene.World (SceneWorld (..), worldSnapshot)
import Hetoimasia.LuaEngine.Graphics.Texture.Host (renderBuilders)
import Hetoimasia.LuaEngine.Graphics.Texture.Port (TextureRef (..), textureRefOf)
import Hetoimasia.LuaEngine.Scene (SnapshotRefusal, sceneCandidate)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..), validMetrics)
import Hetoimasia.Render.TwoD.Chunk (ChunkRef)
import Hetoimasia.Render.TwoD.DrawPlan (CutoutMarks)
import Hetoimasia.Render.TwoD.Snapshot (Pass (..), Snapshot (..), Target (OffscreenTarget))
import Hetoimasia.Render.TwoD.Target.Backend (targetRef)
import Hetoimasia.Render.TwoD.Validation (ValidSnapshot, validateSnapshot, validateSnapshotWith)
import qualified Hetoimasia.Render.TwoD.Validation as Validation
import Hetoimasia.Render.TwoD.Vulkan (Renderer, prepareSnapshot)
import Hetoimasia.Render.TwoD.Vulkan.Builders (Builders)
import Hetoimasia.Render.TwoD.Vulkan.Chunks (ChunkStanding (..), Retained, RetainedView (..), retainedBuffers, retainedViewSTM)
import Hetoimasia.Render.TwoD.Vulkan.Frame
  ( Attachment (..)
  , DepthBinding (..)
  , FrameInput (..)
  , FrameRefusal (..)
  , TargetBinding (..)
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
  , renderRetained ∷ !Retained
    -- ^ The session's retained chunks, which a world scene's view lists.
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
-- frame. A world frame's attachment and slot are noted in the receipts before it records; any other frame's are
-- cleared.
sceneRenderer ∷ DrawReceipts → RenderSlot → VulkanRenderer GraphicsScene
sceneRenderer receipts slot = VulkanRenderer $ \scene request construction recorder → do
  let SurfaceExtent width height = requestExtent request
  atomically $ do
    noteUnrecorded receipts (requestAttachment request) (requestFrame request)
    either (const (pure ())) (noteFrameMetrics receipts (requestAttachment request)) (frameMetrics (FrameFacts (width, height) (requestLogicalExtent request) (requestContentScale request)))
  readRenderSlot slot >>= \case
    Nothing → pure (Left (RefusedIllegal "the scene renderer has no session yet, so the frame is skipped"))
    Just session → case graphicsWorld scene of
      Just world → renderWorldFrame session receipts (renderBuilders construction) world request recorder
      Nothing → renderGraphicsFrame session (renderBuilders construction) scene request recorder

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


-- | Record one frame of an adopted world scene into a window: the view as published, under the frame's own metrics,
-- over the retained chunks it lists and the frame's depth image. A frame that cannot draw the whole revision is
-- refused before anything is recorded.
renderWorldFrame
  ∷ RenderSession
  → DrawReceipts
  → Builders q inst msgr phys dev cmd
  → SceneWorld
  → FrameRequest
  → Recorder q inst msgr phys dev cmd
  → IO (Either Refusal ())
renderWorldFrame session receipts builders world request recorder =
  case (frameMetrics facts, requestDepth request) of
    (Left skip, _) → pure (Left (RefusedIllegal (Text.pack ("the frame is skipped: " <> show skip))))
    (_, Nothing) → pure (Left (RefusedIllegal "the world frame is skipped: the target supplied no depth image"))
    (Right metrics, Just depth) → do
      atomically (noteRecorded receipts (requestAttachment request) (requestFrame request) (worldTag world) metrics)
      recordWorld session builders (worldSnapshot world) world recorder $ \valid marks buffers →
        FrameInput
          { frameSnapshot = valid
          , frameMarks = marks
          , frameTarget = const Nothing
          , frameWindow = Just (Attachment (requestFormat request) width height metrics)
          , frameWindowDepth = Just (DepthBinding depth Depth32Float)
          , frameChunks = buffers
          , frameOmitted = Set.empty
          }
  where
    SurfaceExtent width height = requestExtent request
    facts = FrameFacts (width, height) (requestLogicalExtent request) (requestContentScale request)

-- | Record one frame of an adopted world scene into a registered offscreen target, inside the host's recording
-- boundary for it ('Hetoimasia.GPU.Vulkan.GLFW.recordVulkanTargetBatch'), which binds the batch to the revision the
-- host adopted: the same view, chunks and checks as a window's frame, drawing into the caller's colour image with
-- the caller's @D32_SFLOAT@ depth image of the same extent. The caller advances the view's receipt once the batch
-- is submitted ('Hetoimasia.LuaEngine.Graphics.Scene.Receipts.noteSubmitted').
renderWorldTarget
  ∷ RenderSession
  → Builders q inst msgr phys dev cmd
  → SceneWorld
  → TargetMetrics
  → Image
    -- ^ The colour image.
  → Word32
    -- ^ Its format code.
  → Image
    -- ^ The depth image.
  → Recorder q inst msgr phys dev cmd
  → IO (Either Refusal ())
renderWorldTarget session builders world metrics image format depth recorder =
  recordWorld session builders snapshot world recorder $ \valid marks buffers →
    FrameInput
      { frameSnapshot = valid
      , frameMarks = marks
      , frameTarget = \found →
          if found == reference
            then Just (TargetBinding image (Attachment format (fromIntegral width) (fromIntegral height) metrics) (Just (DepthBinding depth Depth32Float)))
            else Nothing
      , frameWindow = Nothing
      , frameWindowDepth = Nothing
      , frameChunks = buffers
      , frameOmitted = Set.empty
      }
  where
    reference = targetRef 1 1
    snapshot = Snapshot [Pass (OffscreenTarget reference) (worldClear world) [worldView world]]
    PixelExtent width height = metricsFramebuffer metrics

-- The checks every world frame makes, then the recording: a chunk still uploading, or one whose upload failed, refuses
-- the frame, and the snapshot is validated against the chunks the registry holds.
recordWorld
  ∷ RenderSession
  → Builders q inst msgr phys dev cmd
  → Snapshot
  → SceneWorld
  → Recorder q inst msgr phys dev cmd
  → (ValidSnapshot → CutoutMarks → (ChunkRef → Maybe Buffer) → FrameInput)
  → IO (Either Refusal ())
recordWorld session builders snapshot world recorder input = do
  registry ← atomically (retainedViewSTM (renderRetained session))
  let standings = [(chunk, Map.lookup chunk (viewStandings registry)) | chunk ← Set.toList (worldChunks world)]
      unready = [(chunk, standing) | (chunk, standing) ← standings, standing /= Just ChunkReady]
  case (unready, validateSnapshotWith (viewChunks registry) snapshot) of
    (_ : _, _) → pure (Left (RefusedIllegal (Text.pack ("the world frame is skipped: a chunk is not ready: " <> show unready))))
    (_, Left invalid) → pure (Left (RefusedIllegal (Text.pack ("the world frame is skipped: " <> show (CandidateInvalid invalid)))))
    ([], Right valid) → do
      marks ← registeredMarks (renderTextures session)
      buffers ← retainedBuffers (renderRetained session)
      prepareSnapshot builders (renderRenderer session) (input valid marks buffers) >>= \case
        Left refusal → pure (Left (refused refusal))
        Right recording → recording recorder <&> either (Left . refused) Right
  where
    refused = \case
      RefusedByBackend refusal → refusal
      other → RefusedIllegal (Text.pack (show other))
