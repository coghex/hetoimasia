-- | What recording a snapshot comes to, worked out before anything is
-- recorded (R2D-7): every pass's attachment resolved, every view's mapping
-- and scissor computed, and every layer's instances encoded in drawing order
-- with its push block and its runs. Nothing here touches the backend's
-- recorder, so every refusal a snapshot can meet is decided before the first
-- command or ring claim, and the work is a plain value the recorder only
-- carries out and the tests read.
--
-- The plan is the ordered path's alone: the snapshot is planned with
-- 'noCutoutMarks', so every instance takes the 'Ordered' path (D-22), and a
-- depth-enabled world layer's 'plannedClearsDepth' mark is not acted on
-- until R2D-9.
--
-- = Targets and metrics
--
-- Each pass names a target. An offscreen one resolves through the caller's
-- lookup to a 'TargetBinding': the backend's colour target and the
-- 'Attachment' it presents, which carries the target's format and extent and
-- the 'TargetMetrics' the views map under. Ordinary offscreen targets use
-- 'offscreenAttachment', whose metrics are 'offscreenMetrics' (content scale
-- 1); a caller that needs a window's content scale, as the surface-free
-- content-scale-2 fixture does, supplies its own metrics, shared with the
-- oracle. The window's pass takes the frame's 'Attachment' from the caller.
-- Every set of metrics must be valid and its framebuffer extent must be the
-- attachment's actual extent.
--
-- = Refusals
--
-- A refusal is the first found in snapshot order, and it names where:
--
-- * 'UnknownTarget': an offscreen reference the lookup does not hold, with
--   its pass;
-- * 'NoWindowAttachment': a window pass with no frame context;
-- * 'InvalidMetrics', 'MetricsDisagree': a pass whose metrics are unusable or
--   whose framebuffer extent is not the attachment's;
-- * 'ViewNotMappable': a view 'viewMapping' refuses under the metrics, with
--   its pass and view;
-- * 'PlanDisagrees': the plan and the snapshot's layers do not pair, which
--   planning the same snapshot never produces.
module Hetoimasia.Render.TwoD.Vulkan.Frame
  ( -- * The caller's side
    Attachment (..)
  , offscreenAttachment
  , TargetBinding (..)
  , FrameInput (..)
    -- * Refusals
  , FrameRefusal (..)
    -- * The work
  , PassWork (..)
  , ViewWork (..)
  , LayerWork (..)
  , RunWork (..)
  , passDraws
  , frameWork
  ) where

import Control.Monad (zipWithM)
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Word (Word32)
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( ClearColor (..)
  , Image
  , ImageFormat
  , Rect
  , Refusal
  , formatCode
  )
import Hetoimasia.Render.TwoD.DrawPlan
  ( DrawPlan (..)
  , DrawRun (..)
  , LayerSpace (..)
  , PlannedLayer (..)
  , PlannedPass (..)
  , PlannedView (..)
  , noCutoutMarks
  , planSnapshot
  )
import Hetoimasia.Render.TwoD.Encoding (encodeLayerInDrawingOrder)
import Hetoimasia.Render.TwoD.Mapping (mappingPixelSnap, uiTransform, viewMapping, worldTransform)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..), offscreenMetrics, validMetrics)
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..))
import Hetoimasia.Render.TwoD.Snapshot
  ( ClearColour (..)
  , Pass (..)
  , Snapshot (..)
  , Target (..)
  , View (..)
  )
import Hetoimasia.Render.TwoD.Target (TargetRef)
import Hetoimasia.Render.TwoD.Validation
  ( Location (..)
  , ValidLayer
  , ValidSnapshot
  , validLayerLocation
  , validLayers
  , validSnapshot
  )
import Hetoimasia.Render.TwoD.Vulkan.Layout (ViewPush (..), packViewPush, viewScissor)

-- | What a pass renders into, as the caller knows it: the colour format's
-- @VkFormat@ code, the actual extent, and the metrics views map under.
data Attachment = Attachment
  { attachmentFormat ∷ !Word32
  , attachmentWidth ∷ !Word32
  , attachmentHeight ∷ !Word32
  , attachmentMetrics ∷ !TargetMetrics
    -- ^ Its framebuffer extent must be the attachment's.
  }
  deriving (Eq, Show)

-- | An ordinary offscreen colour target of this format and extent: its metrics
-- are 'offscreenMetrics', so its logical extent is its pixel extent and its
-- content scale 1.
offscreenAttachment ∷ ImageFormat → Word32 → Word32 → Attachment
offscreenAttachment format width height =
  Attachment (formatCode format) width height (offscreenMetrics (PixelExtent (fromIntegral width) (fromIntegral height)))

-- | What an offscreen reference resolves to: the backend's colour target and
-- how it presents.
data TargetBinding = TargetBinding
  { bindingImage ∷ !Image
  , bindingAttachment ∷ !Attachment
  }

-- | One frame: the validated snapshot, the lookup that resolves an offscreen
-- target's reference, and the window's attachment when a host renderer
-- records the frame inside a frame batch.
data FrameInput = FrameInput
  { frameSnapshot ∷ !ValidSnapshot
  , frameTarget ∷ TargetRef → Maybe TargetBinding
  , frameWindow ∷ !(Maybe Attachment)
  }

-- | Why a frame was refused, before anything was recorded.
data FrameRefusal
  = -- | An offscreen pass names a reference the lookup does not hold: the
    -- pass, and the reference.
    UnknownTarget !Int !TargetRef
  | -- | A window pass with no frame context: the pass.
    NoWindowAttachment !Int
  | -- | A pass whose metrics have a negative extent or a content scale that is
    -- not finite and positive: the pass.
    InvalidMetrics !Int
  | -- | A pass whose metrics' framebuffer extent is not the attachment's: the
    -- pass, the metrics' extent and the attachment's.
    MetricsDisagree !Int !PixelExtent !(Word32, Word32)
  | -- | A view whose mapping the metrics refuse: the pass and the view.
    ViewNotMappable !Int !Int
  | -- | The plan's layers and the snapshot's do not pair at this location.
    PlanDisagrees !Location
  | -- | The backend refused a construction, a claim or a command.
    RefusedByBackend !Refusal
  deriving (Eq, Show)

-- | One pass: its target, its clear and its views.
data PassWork = PassWork
  { workIndex ∷ !Int
  , workImage ∷ !(Maybe Image)
    -- ^ The offscreen colour target; 'Nothing' for the window's frame.
  , workAttachment ∷ !Attachment
  , workClear ∷ !ClearColor
  , workViews ∷ ![ViewWork]
  }

-- | One view: its scissor and the layers it draws. A view whose scissor is
-- empty holds no layers, so it records no draw.
data ViewWork = ViewWork
  { workViewIndex ∷ !Int
  , workRect ∷ !(Maybe Rect)
  , workLayers ∷ ![LayerWork]
  }

-- | One layer that draws: the push block of its space, its instances in drawing
-- order, and its runs as ranges of them.
data LayerWork = LayerWork
  { layerLocation ∷ !Location
  , layerPushBytes ∷ !ByteString
  , layerBytes ∷ !ByteString
    -- ^ 64 bytes an instance, in drawing order.
  , layerRunList ∷ ![RunWork]
  }
  deriving (Eq, Show)

-- | A run: a contiguous range of its layer's drawn instances.
data RunWork = RunWork
  { runFirstInstance ∷ !Word32
  , runInstanceCount ∷ !Word32
  }
  deriving (Eq, Show)

-- | Whether the pass draws anything: some view holds a layer.
passDraws ∷ PassWork → Bool
passDraws = any (not . null . workLayers) . workViews

-- | Work out a frame, or the first refusal in snapshot order.
frameWork ∷ FrameInput → Either FrameRefusal [PassWork]
frameWork input =
  zipWithM
    (passWork input layers)
    [0 ..]
    (zip (snapshotPasses (validSnapshot valid)) (planPasses (planSnapshot noCutoutMarks valid)))
  where
    valid = frameSnapshot input
    layers = Map.fromList [((pass, view, layer), held) | held ← validLayers valid, AtLayer pass view layer ← [validLayerLocation held]]

passWork ∷ FrameInput → Map.Map (Int, Int, Int) ValidLayer → Int → (Pass, PlannedPass) → Either FrameRefusal PassWork
passWork input layers index (pass, planned) = do
  (image, attachment) ← case passTarget pass of
    WindowTarget → maybe (Left (NoWindowAttachment index)) (\held → Right (Nothing, held)) (frameWindow input)
    OffscreenTarget reference →
      maybe (Left (UnknownTarget index reference)) (\binding → Right (Just (bindingImage binding), bindingAttachment binding)) (frameTarget input reference)
  let metrics = attachmentMetrics attachment
      PixelExtent framebufferWidth framebufferHeight = metricsFramebuffer metrics
      extent = (attachmentWidth attachment, attachmentHeight attachment)
  if not (validMetrics metrics)
    then Left (InvalidMetrics index)
    else
      if (toInteger framebufferWidth, toInteger framebufferHeight) /= (toInteger (fst extent), toInteger (snd extent))
        then Left (MetricsDisagree index (metricsFramebuffer metrics) extent)
        else do
          views ← zipWithM (viewWork layers attachment index) [0 ..] (zip (passViews pass) (plannedViews planned))
          let ClearColour red green blue alpha = passClear pass
          Right (PassWork index image attachment (ClearColor red green blue alpha) views)

viewWork ∷ Map.Map (Int, Int, Int) ValidLayer → Attachment → Int → Int → (View, PlannedView) → Either FrameRefusal ViewWork
viewWork layers attachment passNumber index (view, planned) = do
  mapping ← maybe (Left (ViewNotMappable passNumber index)) Right (viewMapping (attachmentMetrics attachment) view)
  let rect = viewScissor (viewViewport view) (attachmentWidth attachment, attachmentHeight attachment)
      settings = viewSettings view
      pushFor space =
        packViewPush
          ViewPush
            { pushTransform = case space of
                WorldSpace _ → worldTransform mapping
                UiSpace → uiTransform mapping
            , pushExtent = (attachmentWidth attachment, attachmentHeight attachment)
            , pushBrightness = settingBrightness settings
            , pushFilter = settingFilter settings
            , pushSnap = mappingPixelSnap mapping
            }
  drawn ← case rect of
    Nothing → Right []
    Just _ → catMaybes <$> mapM (layerWork layers pushFor) (plannedLayers planned)
  Right (ViewWork index rect drawn)

layerWork ∷ Map.Map (Int, Int, Int) ValidLayer → (LayerSpace → ByteString) → PlannedLayer → Either FrameRefusal (Maybe LayerWork)
layerWork layers pushFor planned
  | null (plannedRuns planned) = Right Nothing
  | otherwise = do
      let location = plannedLocation planned
      valid ← case location of
        AtLayer pass view layer → maybe (Left (PlanDisagrees location)) Right (Map.lookup (pass, view, layer) layers)
        _ → Left (PlanDisagrees location)
      bytes ← maybe (Left (PlanDisagrees location)) Right (encodeLayerInDrawingOrder planned valid)
      Right
        ( Just
            LayerWork
              { layerLocation = location
              , layerPushBytes = pushFor (plannedSpace planned)
              , layerBytes = bytes
              , layerRunList = [RunWork (fromIntegral (runStart run)) (fromIntegral (runCount run)) | run ← plannedRuns planned]
              }
        )
