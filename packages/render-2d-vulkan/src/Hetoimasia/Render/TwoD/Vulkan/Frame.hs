-- | What recording a snapshot comes to, worked out before anything is
-- recorded (R2D-7): every pass's attachment resolved, every view's mapping
-- and scissor computed, and every layer's instances encoded in drawing order
-- with its push block and its runs. Nothing here touches the backend's
-- recorder, so every refusal a snapshot can meet is decided before the first
-- command or ring claim, and the work is a plain value the recorder only
-- carries out and the tests read.
--
-- The snapshot is planned with the marks the caller gives ('frameMarks'): the
-- registered handles' 'CutoutMarks' on a host, 'noCutoutMarks' where nothing is
-- marked, in which case every instance takes the 'Ordered' path (D-22). Every
-- other routing condition is @render-2d@'s, unchanged.
--
-- = Depth (R2D-9)
--
-- A pass whose views hold at least one depth-enabled world layer with a
-- non-empty scissor begins with a depth attachment, and every other pass
-- begins exactly as the ordered path's does, with none. The attachment is the
-- caller's: an offscreen pass's 'bindingDepth', a window pass's
-- 'frameWindowDepth', each a 'DepthBinding' naming the image and its format,
-- which the caller declares and the backend checks against the image when a
-- pipeline is bound. A snapshot's depth-enabled world layer needs
-- @D32_SFLOAT@ (D-23): a pass that needs the attachment and has none is
-- refused ('NoDepthTarget'), and so is a pass holding such a layer whose
-- supplied depth image has another format ('DepthFormatRefused'), each naming
-- the layer. 'requireWorldDepth' is the same rule for a session's depth format,
-- which 'Hetoimasia.Render.TwoD.Vulkan.prepareSnapshot' applies to every snapshot
-- before it looks at a single pass, and a host applies when it publishes one.
-- A 'DepthBinding' names an image and the format its maker declared; the
-- recorder's 'prepareSnapshot' replaces the declaration with the format the
-- backend holds for the image before it works the frame out, so a false
-- declaration is refused, naming the layer, like any other.
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
-- = Clip tables (R2D-12)
--
-- Each view's plan carries its clip table, resolved. The tables of the views
-- that draw (a non-empty scissor and a layer with a run) are packed one after
-- another, in pass and view order, into the batch's one clip region
-- ('clipRegion', in "Hetoimasia.Render.TwoD.Vulkan.Layout"'s format), and each
-- layer's push block carries its view's first entry as its @clipBase@. A frame
-- that draws always has a region, of one zero entry when no view has an entry
-- (the layout holds set 2, so a draw needs it bound); a frame that draws
-- nothing has none. A region larger than the configured window is refused
-- ('ClipTablesTooLarge') by 'requireClipWindow' before anything is recorded.
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
-- * 'NoDepthTarget', 'DepthFormatRefused': a depth-enabled world layer the pass
--   cannot give a @D32_SFLOAT@ attachment, naming the layer;
-- * 'PlanDisagrees': the plan and the snapshot's layers do not pair, which
--   planning the same snapshot never produces;
-- * 'ClipTablesTooLarge': the batch's packed clip tables exceed the window
--   ('requireClipWindow'), naming their size and the window.
module Hetoimasia.Render.TwoD.Vulkan.Frame
  ( -- * The caller's side
    Attachment (..)
  , offscreenAttachment
  , TargetBinding (..)
  , DepthBinding (..)
  , FrameInput (..)
    -- * Depth
  , depthLayers
  , requireWorldDepth
  , worldDepthShortfall
    -- * Refusals
  , FrameRefusal (..)
    -- * The work
  , PassWork (..)
  , ViewWork (..)
  , LayerWork (..)
  , layerPushBytes
  , RunWork (..)
  , PipelineKind (..)
  , runPipeline
  , passDraws
  , frameWork
    -- * Clip tables
  , viewDraws
  , clipRegion
  , requireClipWindow
  ) where

import Control.Monad (zipWithM)
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import qualified Data.ByteString as ByteString
import Data.List (mapAccumL)
import Data.Maybe (catMaybes, fromMaybe, isJust)
import Data.Word (Word32, Word64)
import Hetoimasia.Math.Affine2 (identity)
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( ClearColor (..)
  , Image
  , ImageFormat (..)
  , Rect
  , Refusal
  , formatCode
  )
import Hetoimasia.Render.TwoD.Clip (ResolvedClip)
import Hetoimasia.Render.TwoD.DrawPlan
  ( DrawPlan (..)
  , DrawRun (..)
  , LayerSpace (..)
  , PlannedLayer (..)
  , DrawPath (..)
  , CutoutMarks
  , PlannedPass (..)
  , PlannedView (..)
  , planSnapshot
  )
import Hetoimasia.Render.TwoD.Encoding (encodeLayerInDrawingOrder)
import Hetoimasia.Render.TwoD.Mapping (mappingPixelSnap, uiInverse, uiTransform, viewMapping, worldInverse, worldTransform)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..), offscreenMetrics, validMetrics)
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..))
import Hetoimasia.Render.TwoD.Snapshot
  ( ClearColour (..)
  , Layer (..)
  , LayerDepth (..)
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
import Hetoimasia.Render.TwoD.Vulkan.Layout (ViewPush (..), clipEntryBytes, packClipTable, packViewPush, viewScissor)

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

-- | A depth image the caller supplies for a pass: the backend's depth target
-- and the format the caller made it with. The format is the caller's word; the
-- backend checks it against the image when a pipeline is bound.
data DepthBinding = DepthBinding
  { depthImage ∷ !Image
  , depthFormat ∷ !ImageFormat
  }

-- | What an offscreen reference resolves to: the backend's colour target, how
-- it presents, and the depth target of its extent that a pass holding a
-- depth-enabled world layer needs.
data TargetBinding = TargetBinding
  { bindingImage ∷ !Image
  , bindingAttachment ∷ !Attachment
  , bindingDepth ∷ !(Maybe DepthBinding)
  }

-- | One frame: the validated snapshot, the textures' cutout marks it is planned
-- with, the lookup that resolves an offscreen target's reference, and, when a
-- host renderer records the frame inside a frame batch, the window's attachment
-- and the depth image of its swapchain generation.
data FrameInput = FrameInput
  { frameSnapshot ∷ !ValidSnapshot
  , frameMarks ∷ !CutoutMarks
    -- ^ The registered handles' marks; 'noCutoutMarks' where none is marked.
  , frameTarget ∷ TargetRef → Maybe TargetBinding
  , frameWindow ∷ !(Maybe Attachment)
  , frameWindowDepth ∷ !(Maybe DepthBinding)
    -- ^ The window generation's depth image, if the host enabled windowed depth.
  }

-- | The depth-enabled world layers of a snapshot, in snapshot order.
depthLayers ∷ ValidSnapshot → [Location]
depthLayers valid =
  [ AtLayer passIndex viewIndex layerIndex
  | (passIndex, pass) ← zip [0 ..] (snapshotPasses (validSnapshot valid))
  , (viewIndex, view) ← zip [0 ..] (passViews pass)
  , (layerIndex, WorldLayer DepthEnabled _) ← zip [0 ..] (viewLayers view)
  ]

-- | The rule for a session whose depth format is this one, or that offers none
-- ('Nothing') (D-23): a snapshot holding a depth-enabled world layer, in a view
-- whose scissor may be empty or not, is refused, naming the first, unless the
-- format is @D32_SFLOAT@; a snapshot with none is unaffected on any device.
requireWorldDepth ∷ Maybe ImageFormat → ValidSnapshot → Either FrameRefusal ()
requireWorldDepth format valid = case worldDepthShortfall format valid of
  Nothing → Right ()
  Just (location, Nothing) → Left (NoDepthFormat location)
  Just (location, Just held) → Left (DepthFormatRefused location held)

-- | The first depth-enabled world layer a session of this depth format cannot
-- give a @D32_SFLOAT@ attachment, with the format the session has ('Nothing'
-- when it offers none); 'Nothing' when the snapshot has no such layer or the
-- format is @D32_SFLOAT@. It is 'requireWorldDepth' without the refusal's
-- frame, for a host that publishes snapshots and records none.
worldDepthShortfall ∷ Maybe ImageFormat → ValidSnapshot → Maybe (Location, Maybe ImageFormat)
worldDepthShortfall format valid = case (depthLayers valid, format) of
  (location : _, Nothing) → Just (location, Nothing)
  (location : _, Just held) | held /= Depth32Float → Just (location, Just held)
  _ → Nothing

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
  | -- | A pass that needs a depth attachment, for this depth-enabled world
    -- layer, was given none.
    NoDepthTarget !Location
  | -- | A depth-enabled world layer needs @D32_SFLOAT@ and the depth image
    -- supplied, or the session's depth format, is this one (D-23).
    DepthFormatRefused !Location !ImageFormat
  | -- | A depth-enabled world layer, and the session offers no depth format.
    NoDepthFormat !Location
  | -- | The batch's packed clip tables are this many bytes, and the clip window
    -- is only this many.
    ClipTablesTooLarge !Word64 !Word64
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
  , workDepth ∷ !(Maybe DepthBinding)
    -- ^ The depth attachment the pass begins with: present exactly when some
    -- view's scissor is non-empty and holds a depth-enabled world layer.
  , workViews ∷ ![ViewWork]
  }

-- | One view: its scissor and the layers it draws, or, for a depth-enabled
-- world layer, clears. A view whose scissor is empty holds no layers, so it
-- records no clear and no draw.
data ViewWork = ViewWork
  { workViewIndex ∷ !Int
  , workRect ∷ !(Maybe Rect)
  , workClips ∷ ![ResolvedClip]
    -- ^ The view's clip table, resolved, which the batch's clip region holds
    -- when the view draws.
  , workLayers ∷ ![LayerWork]
  }

-- | One layer that draws, or clears depth: the push block of its space, its
-- instances in drawing order, and its runs as ranges of them.
data LayerWork = LayerWork
  { layerLocation ∷ !Location
  , layerClearsDepth ∷ !Bool
    -- ^ A depth-enabled world layer: it clears depth to 1.0 within its view's
    -- scissor before its runs, though it holds none.
  , layerPush ∷ !ViewPush
    -- ^ The push block of the layer's space, with its view's clip base.
  , layerBytes ∷ !ByteString
    -- ^ 64 bytes an instance, in drawing order.
  , layerRunList ∷ ![RunWork]
  }
  deriving (Eq, Show)

-- | The layer's push block as the recorder pushes it.
layerPushBytes ∷ LayerWork → ByteString
layerPushBytes = packViewPush . layerPush

-- | A run: a contiguous range of its layer's drawn instances, and the path the
-- plan gave it.
data RunWork = RunWork
  { runFirstInstance ∷ !Word32
  , runInstanceCount ∷ !Word32
  , runWorkPath ∷ !DrawPath
  }
  deriving (Eq, Show)

-- | The pipelines the recorder draws with. Each declares what its pass has: the
-- first, which declares no depth, is for passes with no depth attachment, and
-- the others declare @D32_SFLOAT@.
data PipelineKind
  = -- | The ordered path's own: premultiplied-alpha blending, no depth declared.
    PlainPipeline
  | -- | Cutout runs: the cutout variant, no blending, depth tested
    -- less-or-equal and written.
    CutoutPipeline
  | -- | Ordered-path instances of a depth-enabled world layer: depth tested
    -- less-or-equal and not written.
    OrderedTestedPipeline
  | -- | Every other layer of a pass with depth, the world layers without it and
    -- the UI layers: neither tested nor written.
    UntestedPipeline
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The pipeline a run of a layer draws with in a pass that does or does not
-- begin with a depth attachment.
runPipeline ∷ Bool → LayerWork → RunWork → PipelineKind
runPipeline passHasDepth layer run
  | not passHasDepth = PlainPipeline
  | not (layerClearsDepth layer) = UntestedPipeline
  | runWorkPath run == Cutout = CutoutPipeline
  | otherwise = OrderedTestedPipeline

-- | Whether the pass draws anything: some view holds a layer with a run.
passDraws ∷ PassWork → Bool
passDraws = any (any (not . null . layerRunList) . workLayers) . workViews

-- | Work out a frame, or the first refusal in snapshot order.
frameWork ∷ FrameInput → Either FrameRefusal [PassWork]
frameWork input =
  assignClipBases
    <$> zipWithM
      (passWork input layers)
      [0 ..]
      (zip (snapshotPasses (validSnapshot valid)) (planPasses (planSnapshot (frameMarks input) valid)))
  where
    valid = frameSnapshot input
    layers = Map.fromList [((pass, view, layer), held) | held ← validLayers valid, AtLayer pass view layer ← [validLayerLocation held]]

passWork ∷ FrameInput → Map.Map (Int, Int, Int) ValidLayer → Int → (Pass, PlannedPass) → Either FrameRefusal PassWork
passWork input layers index (pass, planned) = do
  (image, attachment, supplied) ← case passTarget pass of
    WindowTarget → maybe (Left (NoWindowAttachment index)) (\held → Right (Nothing, held, frameWindowDepth input)) (frameWindow input)
    OffscreenTarget reference →
      maybe
        (Left (UnknownTarget index reference))
        (\binding → Right (Just (bindingImage binding), bindingAttachment binding, bindingDepth binding))
        (frameTarget input reference)
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
          depth ← depthFor index (passViews pass) views supplied
          let ClearColour red green blue alpha = passClear pass
          Right (PassWork index image attachment (ClearColor red green blue alpha) depth views)

-- | The depth attachment a pass begins with. A pass needs one when a view with
-- a non-empty scissor holds a depth-enabled world layer; it is refused, naming
-- the first such layer, when none was supplied, and a pass holding a
-- depth-enabled world layer is refused too when the image supplied is not
-- @D32_SFLOAT@ (D-23), whether or not its scissors leave it any pixel.
depthFor ∷ Int → [View] → [ViewWork] → Maybe DepthBinding → Either FrameRefusal (Maybe DepthBinding)
depthFor passIndex views works supplied = case (supplied, needing, holding) of
  (Just binding, _, location : _) | depthFormat binding /= Depth32Float → Left (DepthFormatRefused location (depthFormat binding))
  (Nothing, location : _, _) → Left (NoDepthTarget location)
  (_, _ : _, _) → Right supplied
  _ → Right Nothing
  where
    needing = [layerLocation layer | work ← works, layer ← workLayers work, layerClearsDepth layer]
    holding =
      [ AtLayer passIndex viewIndex layerIndex
      | (viewIndex, view) ← zip [0 ..] views
      , (layerIndex, WorldLayer DepthEnabled _) ← zip [0 ..] (viewLayers view)
      ]

viewWork ∷ Map.Map (Int, Int, Int) ValidLayer → Attachment → Int → Int → (View, PlannedView) → Either FrameRefusal ViewWork
viewWork layers attachment passNumber index (view, planned) = do
  mapping ← maybe (Left (ViewNotMappable passNumber index)) Right (viewMapping (attachmentMetrics attachment) view)
  let rect = viewScissor (viewViewport view) (attachmentWidth attachment, attachmentHeight attachment)
      settings = viewSettings view
      pushFor space =
          ViewPush
            { pushTransform = case space of
                WorldSpace _ → worldTransform mapping
                UiSpace → uiTransform mapping
            , pushInverse = fromMaybe identity $ case space of
                WorldSpace _ → worldInverse mapping
                UiSpace → uiInverse mapping
            , pushClipBase = 0
            , pushExtent = (attachmentWidth attachment, attachmentHeight attachment)
            , pushBrightness = settingBrightness settings
            , pushFilter = settingFilter settings
            , pushSnap = mappingPixelSnap mapping
            }
  drawn ← case rect of
    Nothing → Right []
    Just _ → catMaybes <$> mapM (layerWork layers pushFor) (plannedLayers planned)
  Right (ViewWork index rect (plannedClips planned) drawn)

layerWork ∷ Map.Map (Int, Int, Int) ValidLayer → (LayerSpace → ViewPush) → PlannedLayer → Either FrameRefusal (Maybe LayerWork)
layerWork layers pushFor planned
  | null (plannedRuns planned) && not (plannedClearsDepth planned) = Right Nothing
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
              , layerClearsDepth = plannedClearsDepth planned
              , layerPush = pushFor (plannedSpace planned)
              , layerBytes = bytes
              , layerRunList = [RunWork (fromIntegral (runStart run)) (fromIntegral (runCount run)) (runPath run) | run ← plannedRuns planned]
              }
        )

-- | Whether a view records a draw: a non-empty scissor and a layer with a run.
-- Only such a view's clip table is written to the batch's clip region.
viewDraws ∷ ViewWork → Bool
viewDraws view = isJust (workRect view) && any (not . null . layerRunList) (workLayers view)

-- | Give each drawing view's layers the index of its table's first entry in the
-- batch's clip region, the tables following one another in pass and view order.
assignClipBases ∷ [PassWork] → [PassWork]
assignClipBases = snd . mapAccumL pass 0
  where
    pass base work =
      let (base', views) = mapAccumL view base (workViews work)
       in (base', work {workViews = views})
    view base work
      | viewDraws work = (base + fromIntegral (length (workClips work)), work {workLayers = map (withBase base) (workLayers work)})
      | otherwise = (base, work)
    withBase base layer = layer {layerPush = (layerPush layer) {pushClipBase = base}}

-- | The bytes of the batch's clip region: the resolved tables of the views that
-- draw, one after another in pass and view order, 'clipEntryBytes' an entry. A
-- frame that draws but has no entry gets a single zero entry, since set 2 must
-- be bound for any draw; a frame that draws nothing has none ('Nothing').
clipRegion ∷ [PassWork] → Maybe ByteString
clipRegion passes
  | not (any passDraws passes) = Nothing
  | null entries = Just (ByteString.replicate clipEntryBytes 0)
  | otherwise = Just (packClipTable entries)
  where
    entries = [entry | pass ← passes, view ← workViews pass, viewDraws view, entry ← workClips view]

-- | Refuse a frame whose clip region is larger than the window: the region's
-- size and the window, in bytes. The window is the storage-table window the
-- ring was made with.
requireClipWindow ∷ Word64 → [PassWork] → Either FrameRefusal ()
requireClipWindow window passes = case clipRegion passes of
  Just bytes | toInteger (ByteString.length bytes) > toInteger window → Left (ClipTablesTooLarge (fromIntegral (ByteString.length bytes)) window)
  _ → Right ()
