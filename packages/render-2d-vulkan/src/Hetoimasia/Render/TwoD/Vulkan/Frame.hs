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
-- = Retained chunks (R2D-10)
--
-- A layer may list retained chunks ("Hetoimasia.Render.TwoD.Chunk"). Its work is
-- then the ring's, the layer's dynamic cutouts and the merged ordered instances
-- of its chunks and its own, written each frame, together with the chunks'
-- cutout runs, which read the chunk's own device buffer ('ReadsChunk') as the
-- caller's 'frameChunks' resolves it and are never rewritten. A view skips a
-- chunk wholly outside it before any of this is worked out, under the view's
-- mapping and the attachment's extent ("Hetoimasia.Render.TwoD.Culling"), and
-- the skipped listings are named in the layer's work ('layerCulled'); nothing of
-- them is encoded, claimed or drawn. A chunk with cutout instances that
-- 'frameChunks' holds no buffer for is refused ('ChunkBufferMissing') before
-- anything is recorded.
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
-- Each view's plan carries its clip table, resolved. For each view that draws
-- (a non-empty scissor and a layer with a run), and each space, world or UI,
-- that one of its layers selects a clip from (some instance has a clip index),
-- the table is written once with its edges taken about the layer-space point
-- under the scissor's centre ('ClipTable'; the reason is in
-- "Hetoimasia.Render.TwoD.Vulkan.Layout"), and each such layer's push block
-- carries that table's first entry as its @clipBase@ and the scissor's centre as
-- its @clipCentre@. The tables are packed one after another, in pass and view
-- order, into the batch's one clip region ('clipRegion'). A frame that draws
-- always has a region, of one zero entry when no table is written (the layout
-- holds set 2, so a draw needs it bound); a frame that draws nothing has none.
-- A region larger than the configured window is refused ('ClipTablesTooLarge')
-- by 'requireClipWindow' before anything is recorded.
--
-- = Materials (R2D-11)
--
-- A run draws with the material its instances name, and the material's records,
-- which its instances' parameter words index, are written into the batch's one
-- region after the clip tables ('recordRegion'): the view's own records for the
-- runs of its dynamic instances, and a chunk's for the runs of that chunk's, each
-- table once however often it is drawn, with the word of the region it begins at
-- as the base its run pushes ('RecordKey', 'RunRecords'). A view's push block for
-- a material is pushed before the material's runs ('workPushBlocks'). A material
-- the session did not issue, or whose facts differ from the ones it was issued
-- with, is refused ('MaterialNotIssued', 'MaterialFactsDisagree'), naming it and
-- where, before anything is recorded, and so is a region larger than the storage
-- window ('RecordsTooLarge').
--
-- = Frame tables (R2D-18)
--
-- Each view that draws writes the frame tables it holds, once, into the batch's
-- one region after the material records ('recordRegion'), however many layers
-- and chunks draw in it: the current frame of each table at the view's time
-- ('Hetoimasia.Render.TwoD.Animation.currentFrame', computed here, on the host,
-- exactly), its count and its rectangles, after a directory
-- ("Hetoimasia.Render.TwoD.Vulkan.Layout"'s @packFrameBlock@ has the format). The
-- word of the region the block begins at is the @frameBase@ every layer of the
-- view pushes, so the retained chunks and the dynamic instances of the view alike
-- read the same tables, and the same chunk drawn in two views reads each view's
-- own. A view with no table writes none, and one that does not draw writes none.
-- A block whose size, or any offset or header value, does not fit its 32-bit word
-- is refused ('FrameTablesNotRepresentable') before anything is recorded, and
-- the whole region, the frame tables with the clip tables and the material
-- records, is held to the window ('RecordsTooLarge').
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
-- * 'ChunkBufferMissing': a chunk drawn with cutout instances, in a view that
--   does not cull it, for which the caller supplied no device buffer, naming the
--   layer and the chunk;
-- * 'PlanDisagrees': the plan and the snapshot's layers do not pair, which
--   planning the same snapshot never produces;
-- * 'ClipNotRepresentable': a drawing view whose layers select clips has a
--   scissor and a transform for which the fragment stage's clip arithmetic is not
--   well conditioned (a layer-space reach that could overflow a float, or a scale
--   beyond 2¹⁰⁰: 'clipRepresentable'), naming the pass and the view;
-- * 'ClipTablesTooLarge': the batch's packed clip tables exceed the window
--   ('requireClipWindow'), naming their size and the window;
-- * 'FrameTablesNotRepresentable': a drawing view whose frame block holds a size,
--   an offset or a header value that does not fit its 32-bit word, naming the
--   pass, the view and the block's size;
-- * 'MaterialNotIssued', 'MaterialFactsDisagree', 'RecordsTooLarge': see above.
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
  , ClipTable (..)
  , ClipSpace (..)
  , LayerWork (..)
  , layerPushBytes
  , RunWork (..)
  , RunReads (..)
  , RunRecords (..)
  , RecordKey (..)
  , RecordRegion (..)
  , PipelineKind (..)
  , runPipeline
  , passDraws
  , frameWork
    -- * Clip tables
  , viewDraws
  , clipRegion
  , requireClipWindow
    -- * Frame tables
  , requireFrameBlocks
    -- * Materials
  , recordRegion
  , requireRegionWindow
  , unissuedMaterial
  ) where

import Control.Monad (zipWithM)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.List (find, mapAccumL, nub, nubBy)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Maybe (catMaybes, fromMaybe, isJust, listToMaybe)
import Data.Word (Word32, Word64)
import Hetoimasia.Math.Affine2 (identity)
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( Buffer
  , ClearColor (..)
  , Image
  , ImageFormat (..)
  , Rect (..)
  , Refusal
  , formatCode
  )
import Hetoimasia.Render.TwoD.Chunk (Chunk, ChunkRef, chunkInstances, chunkRecords)
import Hetoimasia.Render.TwoD.Clip (ResolvedClip)
import Hetoimasia.Render.TwoD.Culling (chunkCulled)
import Hetoimasia.Render.TwoD.DrawPlan
  ( DrawPlan (..)
  , DrawRun (..)
  , LayerSpace (..)
  , PlannedLayer (..)
  , DrawPath (..)
  , CutoutMarks
  , PlannedPass (..)
  , PlannedView (..)
  , RecordSource (..)
  , RunSource (..)
  , planSnapshotCulled
  )
import Hetoimasia.Render.TwoD.Encoding (encodeLayerInDrawingOrder, encodeRecords)
import Hetoimasia.Render.TwoD.Material
  ( MaterialData (..)
  , MaterialRef
  , defaultMaterial
  , materialRecordLayout
  )
import Hetoimasia.Render.TwoD.Material.Backend (materialRefIdentity)
import Hetoimasia.Render.TwoD.Mapping (mappingPixelSnap, uiInverse, uiTransform, viewMapping, worldInverse, worldTransform)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..), offscreenMetrics, validMetrics)
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..))
import Hetoimasia.Render.TwoD.Snapshot
  ( ClearColour (..)
  , FrameTable (..)
  , Instance (..)
  , Layer (..)
  , LayerDepth (..)
  , Pass (..)
  , Snapshot (..)
  , Target (..)
  , View (..)
  , layerInstances
  )
import Hetoimasia.Render.TwoD.Target (TargetRef)
import Hetoimasia.Render.TwoD.Validation
  ( Location (..)
  , ValidLayer
  , ValidSnapshot
  , validLayerChunks
  , validLayerContents
  , validLayerLocation
  , validLayers
  , validSnapshot
  )
import Hetoimasia.Render.TwoD.Vulkan.Layout
  ( FrameBlockLayout (..)
  , ViewPush (..)
  , clipEntryBytes
  , clipReference
  , clipRepresentable
  , frameBlockLayout
  , frameBlockRepresentable
  , packClipTable
  , packFrameBlock
  , packViewPush
  , rebaseClip
  , viewScissor
  )

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
  , frameChunks ∷ ChunkRef → Maybe Buffer
    -- ^ The device buffer of a retained chunk that has cutout instances, as the
    -- registry holds it ('Hetoimasia.Render.TwoD.Vulkan.Chunks.retainedBuffers');
    -- @const Nothing@ where the frame lists no chunk.
  , frameOmitted ∷ !(Set ChunkRef)
    -- ^ The chunks the frame leaves out of every view, whose listings are treated
    -- as skipped ('layerCulled'): those whose upload ended without completing,
    -- which no retry can draw. 'Set.empty' where there are none.
  }

-- | The depth-enabled world layers of a snapshot, in snapshot order.
depthLayers ∷ ValidSnapshot → [Location]
depthLayers valid =
  [ AtLayer passIndex viewIndex layerIndex
  | (passIndex, pass) ← zip [0 ..] (snapshotPasses (validSnapshot valid))
  , (viewIndex, view) ← zip [0 ..] (passViews pass)
  , (layerIndex, WorldLayerWith DepthEnabled _ _) ← zip [0 ..] (viewLayers view)
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
  | -- | A layer draws a chunk with cutout instances for which the frame holds no
    -- device buffer: the layer, and the chunk.
    ChunkBufferMissing !Location !ChunkRef
  | -- | A view whose layers select clips draws where the fragment stage's
    -- layer-space offsets could overflow a float: the pass and the view. A
    -- scissor that spans more than about 10³⁸ units of the layer, whose clip test
    -- would compare infinities and admit a fragment outside its clip, or a layer
    -- that spans more than 2¹⁰⁰ pixels a unit.
    ClipNotRepresentable !Int !Int
  | -- | The batch's packed clip tables are this many bytes, and the clip window
    -- is only this many.
    ClipTablesTooLarge !Word64 !Word64
  | -- | An instance, or an instance of a chunk a layer lists, names a material
    -- the session did not issue (R2D-11): where, and the reference.
    MaterialNotIssued !Location !MaterialRef
  | -- | An instance names a reference with the identity of a material the session
    -- issued, but facts that differ from the ones it was issued with: where, the
    -- reference named and the reference issued.
    MaterialFactsDisagree !Location !MaterialRef !MaterialRef
  | -- | The batch's clip tables and material records are this many bytes, and
    -- the storage window is only this many.
    RecordsTooLarge !Word64 !Word64
  | -- | The frame tables a drawing view holds pack into a block of this many
    -- bytes (padding included) in which a size, an offset or a header value does
    -- not fit its 32-bit word: the pass, the view, and the size.
    FrameTablesNotRepresentable !Int !Int !Integer
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
    -- ^ The view's clip table, resolved, in the layer's space as the plan
    -- gives it.
  , workTables ∷ ![ClipTable]
    -- ^ The tables the batch's clip region holds for this view: one for each
    -- space a layer selects a clip from, empty for a view that draws nothing.
  , workPushBlocks ∷ !(Map.Map MaterialRef ByteString)
    -- ^ The bytes of the push block the view holds for each material that has
    -- one, pushed before the material's runs.
  , workFrameTables ∷ ![FrameTable]
    -- ^ The view's frame tables (R2D-18), which the batch's region holds when the
    -- view draws.
  , workAnimationTime ∷ !Double
    -- ^ The view's animation time, at which each table's current frame is taken.
  , workLayers ∷ ![LayerWork]
  }

-- | The space a layer's clips are in.
data ClipSpace = ClipWorld | ClipUi
  deriving (Eq, Ord, Show)

-- | One table of the batch's clip region: a view's resolved entries for one
-- space, with each edge taken about the layer-space point under the scissor's
-- centre ('Hetoimasia.Render.TwoD.Vulkan.Layout.clipReference'), where the
-- table begins in the region, in entries, and the centre.
data ClipTable = ClipTable
  { tableSpace ∷ !ClipSpace
  , tableBase ∷ !Word32
  , tableCentre ∷ !(Float, Float)
    -- ^ The centre of the view's scissor, in target pixels.
  , tableEntries ∷ ![ResolvedClip]
  }
  deriving (Eq, Show)


-- | One layer that draws, clears depth, or skipped a chunk: the push block of
-- its space, its instances in drawing order, and its runs as ranges of them.
data LayerWork = LayerWork
  { layerLocation ∷ !Location
  , layerCulled ∷ ![ChunkRef]
    -- ^ The chunks the layer lists that its view skips, in listed order, a chunk
    -- listed twice named twice.
  , layerClearsDepth ∷ !Bool
    -- ^ A depth-enabled world layer: it clears depth to 1.0 within its view's
    -- scissor before its runs, though it holds none.
  , layerPush ∷ !ViewPush
    -- ^ The push block of the layer's space, with its clip table's base and
    -- centre.
  , layerClipSpace ∷ !(Maybe ClipSpace)
    -- ^ The space the layer's clips are in when some dynamic instance has a clip
    -- index; 'Nothing' when none does, so the layer reads no table.
  , layerBytes ∷ !ByteString
    -- ^ 64 bytes an instance, in drawing order: the ring entries, which are empty
    -- for a layer whose every run reads a chunk's buffer.
  , layerRunList ∷ ![RunWork]
  }
  deriving (Eq, Show)

-- | The layer's push block as the recorder pushes it.
layerPushBytes ∷ LayerWork → ByteString
layerPushBytes = packViewPush . layerPush

-- | A run: a contiguous range of instances, where they are read from, and the
-- path the plan gave it.
data RunWork = RunWork
  { runFirstInstance ∷ !Word32
  -- ^ The first instance, among the layer's ring entries or among the chunk
  -- buffer's.
  , runInstanceCount ∷ !Word32
  , runWorkPath ∷ !DrawPath
  , runReads ∷ !RunReads
  , runWorkMaterial ∷ !MaterialRef
  -- ^ The material the run's instances name.
  , runWorkRecords ∷ !RunRecords
  -- ^ The records the run's instances index, which the recorder writes into the
  -- batch's region and whose base the run pushes.
  }
  deriving (Eq, Show)

-- | Which table of records a run reads, and its bytes.
data RunRecords
  = -- | The material has none.
    NoRunRecords
  | -- | This table, encoded.
    RunRecords !RecordKey !ByteString
  deriving (Eq, Show)

-- | A table of one material's records in the batch's region. A table is written
-- once however many runs read it.
data RecordKey
  = -- | The records the view holds: pass, view and material.
    ViewTable !Int !Int !MaterialRef
  | -- | The records a chunk carries.
    ChunkTable !ChunkRef !MaterialRef
  deriving (Eq, Ord, Show)

-- | The batch's storage region: the clip tables, then the material records, then
-- the frame tables.
data RecordRegion = RecordRegion
  { regionBytes ∷ !ByteString
  -- ^ The clip region ('clipRegion'), then every records table once, in the order
  -- first read, back to back, then the frame block of every view that draws and
  -- holds a table, in pass and view order.
  , regionBases ∷ !(Map.Map RecordKey Word32)
  -- ^ The word of 'regionBytes' where each table begins: the base its runs push.
  , regionFrameBases ∷ !(Map.Map (Int, Int) Word32)
  -- ^ The word of 'regionBytes' where each view's frame block begins, by pass and
  -- view: the base its layers push. A view with no block has no entry.
  }
  deriving (Eq, Show)

-- | The batch's region, or 'Nothing' when no pass draws, which then needs none.
-- A frame that draws has the clip region ('clipRegion', one zero entry when no
-- clip is selected), after it the material records its runs read, and after
-- those the frame tables of its views that draw ('drawingFrames'), each block on
-- a 16-byte boundary. A block that does not fit its 32-bit words, which
-- 'requireFrameBlocks' refuses before the region is used, is left out.
recordRegion ∷ [PassWork] → Maybe RecordRegion
recordRegion passes = build <$> clipRegion passes
  where
    build clips =
      let tables =
            nubBy
              (\(left, _) (right, _) → left == right)
              [ (key, encoded)
              | pass ← passes
              , view ← workViews pass
              , layer ← workLayers view
              , run ← layerRunList layer
              , RunRecords key encoded ← [runWorkRecords run]
              ]
          start = fromIntegral (ByteString.length clips `div` 4)
          recordsEnd = toInteger (ByteString.length clips `div` 4) + sum [toInteger (ByteString.length encoded `div` 4) | (_, encoded) ← tables]
          (_, blocks) = mapAccumL packed recordsEnd (drawingFrames passes)
          packed at (key, view) = case packFrameBlock at (workAnimationTime view) (workFrameTables view) of
            Just bytes → (at + toInteger (ByteString.length bytes `div` 4), Just (key, 4 * ((at + 3) `div` 4), bytes))
            Nothing → (at, Nothing)
          found = catMaybes blocks
       in RecordRegion
            (ByteString.concat (clips : map snd tables <> [bytes | (_, _, bytes) ← found]))
            (Map.fromList (zip (map fst tables) (scanl (\at (_, encoded) → at + fromIntegral (ByteString.length encoded `div` 4)) start tables)))
            (Map.fromList [(key, fromInteger base) | (key, base, _) ← found])

-- | The views that draw and hold a frame table, with their pass and view
-- indices, in pass and view order: the views whose frame tables the batch's
-- region holds.
drawingFrames ∷ [PassWork] → [((Int, Int), ViewWork)]
drawingFrames passes =
  [ ((workIndex pass, workViewIndex view), view)
  | pass ← passes
  , view ← workViews pass
  , viewDraws view
  , not (null (workFrameTables view))
  ]

-- | Refuse a frame holding a drawing view whose frame block does not fit: where
-- the region's frame blocks begin is the end of its clip tables and material
-- records, and each block, in order, must have every size, offset and header
-- value representable in its 32-bit word ('frameBlockRepresentable'), computed
-- exactly. The first such view in snapshot order is the refusal, naming the
-- block's size in bytes.
requireFrameBlocks ∷ [PassWork] → Either FrameRefusal ()
requireFrameBlocks passes = case clipRegion passes of
  Nothing → Right ()
  Just clips →
    let recordsEnd =
          toInteger (ByteString.length clips `div` 4)
            + sum [toInteger (ByteString.length encoded `div` 4) | (_, encoded) ← nubBy (\(left, _) (right, _) → left == right) [(key, encoded) | pass ← passes, view ← workViews pass, layer ← workLayers view, run ← layerRunList layer, RunRecords key encoded ← [runWorkRecords run]]]
     in go recordsEnd (drawingFrames passes)
  where
    go _ [] = Right ()
    go at (((passIndex, viewIndex), view) : rest)
      | frameBlockRepresentable at counts = go (blockStart layout + blockWords layout) rest
      | otherwise = Left (FrameTablesNotRepresentable passIndex viewIndex (4 * (blockPadding layout + blockWords layout)))
      where
        counts = map (toInteger . frameTableCount) (workFrameTables view)
        layout = frameBlockLayout at counts

-- | Give each layer of a view whose frame block the region holds the word it
-- begins at, as the base its push block names.
assignFrameBases ∷ [PassWork] → [PassWork]
assignFrameBases passes = case recordRegion passes of
  Nothing → passes
  Just region →
    [ pass {workViews = [assign (Map.lookup (workIndex pass, workViewIndex view) (regionFrameBases region)) view | view ← workViews pass]}
    | pass ← passes
    ]
  where
    assign Nothing view = view
    assign (Just base) view = view {workLayers = [layer {layerPush = (layerPush layer) {pushFrameBase = base}} | layer ← workLayers view]}

-- | Refuse a frame whose whole region, the clip tables and the material records,
-- is larger than the window: the region's size and the window, in bytes. (The
-- clip tables alone are 'requireClipWindow''s.)
requireRegionWindow ∷ Word64 → [PassWork] → Either FrameRefusal ()
requireRegionWindow window passes = case recordRegion passes of
  Just region | toInteger (ByteString.length (regionBytes region)) > toInteger window → Left (RecordsTooLarge (fromIntegral (ByteString.length (regionBytes region))) window)
  _ → Right ()

-- | Where a run's instances are read from.
data RunReads
  = -- | The layer's region of the frame's ring.
    ReadsRing
  | -- | A retained chunk's own device buffer, which is not rewritten.
    ReadsChunk !ChunkRef !Buffer
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

-- | A pass's target as the caller resolves it, checked: the offscreen colour
-- image if any, the attachment, and the depth image supplied.
data Resolved = Resolved !(Maybe Image) !Attachment !(Maybe DepthBinding)

resolvedAttachment ∷ Resolved → Attachment
resolvedAttachment (Resolved _ attachment _) = attachment

-- | Resolve a pass's target and check its metrics against it.
resolvePass ∷ FrameInput → Int → Pass → Either FrameRefusal Resolved
resolvePass input index pass = do
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
        else Right (Resolved image attachment supplied)

-- | Work out a frame, or the first refusal in snapshot order.
frameWork ∷ FrameInput → Either FrameRefusal [PassWork]
frameWork input = do
  works ←
    zipWithM
      (passWork input layers)
      [0 ..]
      (zip3 passes resolved (planPasses plan))
  let assigned = assignClipBases works
  requireClipArithmetic assigned
  requireFrameBlocks assigned
  pure (assignFrameBases assigned)
  where
    valid = frameSnapshot input
    passes = snapshotPasses (validSnapshot valid)
    layers = Map.fromList [((pass, view, layer), held) | held ← validLayers valid, AtLayer pass view layer ← [validLayerLocation held]]
    -- Resolved lazily, in snapshot order, so the first refusal is still the
    -- first found: planning needs a pass's view mappings only for its culling.
    resolved = zipWith (resolvePass input) [0 ..] passes
    plan = planSnapshotCulled culler (frameMarks input) valid
    culler passIndex viewIndex reference kind bounds placement
      | Set.member reference (frameOmitted input) = True
      | otherwise = case Map.lookup (passIndex, viewIndex) cullable of
          Just (mapping, extent, viewport) → chunkCulled mapping extent viewport kind bounds placement
          Nothing → False
    cullable =
      Map.fromList
        [ ((passIndex, viewIndex), (mapping, (attachmentWidth attachment, attachmentHeight attachment), viewViewport view))
        | (passIndex, pass, Right found) ← zip3 [0 ..] passes resolved
        , let attachment = resolvedAttachment found
        , (viewIndex, view) ← zip [0 ..] (passViews pass)
        , Just mapping ← [viewMapping (attachmentMetrics attachment) view]
        ]

passWork ∷ FrameInput → Map.Map (Int, Int, Int) ValidLayer → Int → (Pass, Either FrameRefusal Resolved, PlannedPass) → Either FrameRefusal PassWork
passWork input layers index (pass, resolved, planned) = do
  Resolved image attachment supplied ← resolved
  views ← zipWithM (viewWork input layers attachment index) [0 ..] (zip (passViews pass) (plannedViews planned))
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
      , (layerIndex, WorldLayerWith DepthEnabled _ _) ← zip [0 ..] (viewLayers view)
      ]

viewWork ∷ FrameInput → Map.Map (Int, Int, Int) ValidLayer → Attachment → Int → Int → (View, PlannedView) → Either FrameRefusal ViewWork
viewWork input layers attachment passNumber index (view, planned) = do
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
            , pushClipCentre = (0, 0)
            , pushFrameBase = 0
            , pushExtent = (attachmentWidth attachment, attachmentHeight attachment)
            , pushBrightness = settingBrightness settings
            , pushFilter = settingFilter settings
            , pushSnap = mappingPixelSnap mapping
            }
      held = viewMaterials view
  drawn ← case rect of
    Nothing → Right []
    Just _ → catMaybes <$> mapM (layerWork input layers held passNumber index pushFor) (plannedLayers planned)
  Right (ViewWork index rect (plannedClips planned) [] (Map.filter (not . ByteString.null) (Map.map materialPushBlock held)) (viewFrameTables view) (viewAnimationTime view) drawn)

layerWork
  ∷ FrameInput
  → Map.Map (Int, Int, Int) ValidLayer
  → Map.Map MaterialRef MaterialData
  → Int
  → Int
  → (LayerSpace → ViewPush)
  → PlannedLayer
  → Either FrameRefusal (Maybe LayerWork)
layerWork input layers held passNumber viewNumber pushFor planned
  | null (plannedRuns planned) && not (plannedClearsDepth planned) && null (plannedCulled planned) = Right Nothing
  | otherwise = do
      let location = plannedLocation planned
      valid ← case location of
        AtLayer pass view layer → maybe (Left (PlanDisagrees location)) Right (Map.lookup (pass, view, layer) layers)
        _ → Left (PlanDisagrees location)
      bytes ← maybe (Left (PlanDisagrees location)) Right (encodeLayerInDrawingOrder planned valid)
      let listed = validLayerChunks valid
          chunkAt position = case drop position listed of
            entry : _ → Right entry
            [] → Left (PlanDisagrees location)
      culled ← traverse (fmap fst . chunkAt) (plannedCulled planned)
      runs ← traverse (runWork location chunkAt) (plannedRuns planned)
      Right
        ( Just
            LayerWork
              { layerLocation = location
              , layerCulled = culled
              , layerClearsDepth = plannedClearsDepth planned
              , layerPush = pushFor (plannedSpace planned)
              , layerClipSpace = clipSpaceOf (plannedSpace planned) valid
              , layerBytes = bytes
              , layerRunList = runs
              }
        )
  where
    runWork location chunkAt run = do
      records ← recordsOf chunkAt (runMaterial run) (runRecords run)
      case runSource run of
        RingRun → Right (RunWork (fromIntegral (runStart run)) (fromIntegral (runCount run)) (runPath run) ReadsRing (runMaterial run) records)
        ChunkRun position → do
          (reference, _) ← chunkAt position
          buffer ← maybe (Left (ChunkBufferMissing location reference)) Right (frameChunks input reference)
          Right (RunWork (fromIntegral (runStart run)) (fromIntegral (runCount run)) (runPath run) (ReadsChunk reference buffer) (runMaterial run) records)
    -- The records a run's instances index: the view's for its dynamic instances,
    -- the chunk's for the chunk's.
    recordsOf chunkAt material = \case
      NoRecords → Right NoRunRecords
      ViewRecords → Right (RunRecords (ViewTable passNumber viewNumber material) (encodeRecords (materialRecordLayout material) (maybe [] materialRecords (Map.lookup material held))))
      ChunkRecords position → do
        (reference, built) ← chunkAt position
        Right (RunRecords (ChunkTable reference material) (encodeRecords (materialRecordLayout material) (Map.findWithDefault [] material (chunkRecords built))))

-- | The first instance of the snapshot, dynamic or in a chunk a layer lists, that
-- names a material the session did not issue, or names one with the facts of
-- another: the lookup answers, for an identity, the reference the session issued
-- under it. The built-in default is issued to every session, as a constant.
unissuedMaterial ∷ (Word64 → Maybe MaterialRef) → ValidSnapshot → Maybe FrameRefusal
unissuedMaterial issued valid = case concatMap refusalsOfLayer (validLayers valid) of
  refusal : _ → Just refusal
  [] → Nothing
  where
    refusalsOfLayer layer =
      [ refusal
      | (index, candidate) ← zip [0 ..] (layerInstances (validLayerContents layer))
      , Just refusal ← [check (atLayer layer (\pass view held → AtInstance pass view held index)) (instanceMaterial candidate)]
      ]
        <> [ refusal
           | (position, (_, built)) ← zip [0 ..] (validLayerChunks layer)
           , (index, candidate) ← zip [0 ..] (chunkInstances (built ∷ Chunk))
           , Just refusal ← [check (atLayer layer (\pass view held → AtChunkInstance pass view held position index)) (instanceMaterial candidate)]
           ]
    atLayer layer build = case validLayerLocation layer of
      AtLayer pass view held → build pass view held
      other → other
    check location material
      | material == defaultMaterial = Nothing
      | otherwise = case issued (materialRefIdentity material) of
          Nothing → Just (MaterialNotIssued location material)
          Just held
            | held == material → Nothing
            | otherwise → Just (MaterialFactsDisagree location material held)

-- | The space a layer's clips are in, when some instance selects one.
clipSpaceOf ∷ LayerSpace → ValidLayer → Maybe ClipSpace
clipSpaceOf space valid
  | any ((/= 0) . instanceClip) (layerInstances (validLayerContents valid)) = Just (case space of WorldSpace _ → ClipWorld; UiSpace → ClipUi)
  | otherwise = Nothing

-- | Whether a view records a draw: a non-empty scissor and a layer with a run.
-- Only such a view's clip table is written to the batch's clip region.
viewDraws ∷ ViewWork → Bool
viewDraws view = isJust (workRect view) && any (not . null . layerRunList) (workLayers view)

-- | Write each drawing view's clip tables, one for each space a layer selects a
-- clip from, one after another in pass and view order, and give each such layer
-- its table's first entry and the scissor's centre. A table's edges are taken
-- about the layer-space point under that centre, from the transform of the
-- space's first layer.
assignClipBases ∷ [PassWork] → [PassWork]
assignClipBases = snd . mapAccumL pass 0
  where
    pass base work =
      let (base', views) = mapAccumL view base (workViews work)
       in (base', work {workViews = views})
    view base work = case workRect work of
      Just rect
        | viewDraws work →
            let centre = (fromIntegral (rectX rect) + fromIntegral (rectWidth rect) / 2, fromIntegral (rectY rect) + fromIntegral (rectHeight rect) / 2)
                spaces = nub [space | layer ← workLayers work, Just space ← [layerClipSpace layer]]
                (base', tables) = mapAccumL (table work centre) base spaces
                assign layer = case layerClipSpace layer of
                  Just space | Just held ← find ((== space) . tableSpace) tables → layer {layerPush = (layerPush layer) {pushClipBase = tableBase held, pushClipCentre = centre}}
                  _ → layer
             in (base', work {workTables = tables, workLayers = map assign (workLayers work)})
      _ → (base, work)
    table work centre base space =
      let transform = fromMaybe identity (listToMaybe [pushTransform (layerPush layer) | layer ← workLayers work, layerClipSpace layer == Just space])
          reference = clipReference transform centre
          entries = map (rebaseClip reference) (workClips work)
       in (base + fromIntegral (length entries), ClipTable space base centre entries)

-- | Refuse a frame holding a drawing view whose clip test could overflow: for
-- each table written, the layer's inverse and the view's scissor must satisfy
-- 'clipRepresentable'. The first such view in snapshot order is the refusal.
requireClipArithmetic ∷ [PassWork] → Either FrameRefusal ()
requireClipArithmetic passes =
  case [ClipNotRepresentable (workIndex pass) (workViewIndex view) | pass ← passes, view ← workViews pass, unrepresentable view] of
    refusal : _ → Left refusal
    [] → Right ()
  where
    unrepresentable view = case workRect view of
      Just rect | viewDraws view → any (selectsUnrepresentably rect) (workLayers view)
      _ → False
    selectsUnrepresentably rect layer =
      isJust (layerClipSpace layer) && not (clipRepresentable (pushTransform (layerPush layer)) (pushInverse (layerPush layer)) (rectWidth rect, rectHeight rect))

-- | The bytes of the batch's clip region: the tables of the views that draw, one
-- after another in pass and view order, 'clipEntryBytes' an entry. A frame that
-- draws but writes no table gets a single zero entry, since set 2 must be bound
-- for any draw; a frame that draws nothing has none ('Nothing').
clipRegion ∷ [PassWork] → Maybe ByteString
clipRegion passes
  | not (any passDraws passes) = Nothing
  | null entries = Just (ByteString.replicate clipEntryBytes 0)
  | otherwise = Just (packClipTable entries)
  where
    entries = [entry | pass ← passes, view ← workViews pass, table ← workTables view, entry ← tableEntries table]

-- | Refuse a frame whose clip region is larger than the window: the region's
-- size and the window, in bytes. The window is the storage-table window the
-- ring was made with.
requireClipWindow ∷ Word64 → [PassWork] → Either FrameRefusal ()
requireClipWindow window passes = case clipRegion passes of
  Just bytes | toInteger (ByteString.length bytes) > toInteger window → Left (ClipTablesTooLarge (fromIntegral (ByteString.length bytes)) window)
  _ → Right ()
