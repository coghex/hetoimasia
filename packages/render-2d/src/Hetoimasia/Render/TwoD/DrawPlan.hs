-- | The draw plan: a validated snapshot turned into ordered draw runs.
--
-- 'planSnapshot' takes a 'ValidSnapshot' and each texture's cutout mark
-- ('CutoutMarks') and answers a 'DrawPlan' that keeps the snapshot's structure:
-- the passes in list order, within each pass the views in order, within each
-- view the layers in order, and within each layer an ordered list of draw runs.
-- Each layer also carries the permutation of its submission indices that is its
-- drawing order, so a recorder can encode instances in drawing order, and each
-- run is a contiguous range of that permutation.
--
-- __Routing__ (decisions D-3, D-22, D-24, D-25). An instance takes the 'Cutout'
-- path only when all of these hold; every other instance takes the 'Ordered'
-- path:
--
-- * it is in a world layer whose depth is enabled (a layer without depth, and
--   every UI layer, draws wholly in the ordered path);
-- * its texture is marked cutout-safe;
-- * its material is cutout-capable;
-- * its tint alpha is 255;
-- * its translucent flag and its additive flag are both clear.
--
-- __Ordering.__ In a layer the cutout runs come first, ordered by material and
-- then by submission sequence; the ordered-path instances follow, sorted back
-- to front, which is by ascending depth key (a larger key is nearer) and then
-- by ascending submission sequence. A layer routed wholly to the ordered path
-- therefore draws in ascending depth key, then submission order. The submission
-- sequence of an instance is its position in its own layer, from zero. The
-- order is total and repeatable: the same snapshot and marks always give the
-- same plan.
--
-- __Equal keys__ (decision D-23). Among cutouts at an equal key the later draw
-- in run order wins, because the recorder draws them less-or-equal; and at an
-- equal key an ordered-path instance draws after, and so over, a cutout. An
-- adapter that needs a guaranteed winner gives distinct keys.
--
-- __Chunks__ (R2D-10, decisions D-1, D-31). A layer may list retained chunks
-- beside its dynamic instances ("Hetoimasia.Render.TwoD.Chunk"). A chunk's
-- routing was fixed when it was built, so planning never routes it again. The
-- /source order/ of a layer's content is: its chunks in the order it lists
-- them, each listing in the chunk's build order, then its dynamic instances in
-- submission order. A chunk listed twice contributes at both places. The order
-- is total and repeatable, and it ties every comparison below:
--
-- * the cutout runs come first, ordered by material and then by source order,
--   so within a material each chunk listing's cutouts draw as one run from the
--   chunk's own buffer ('ChunkRun'), in listing order, and the dynamic cutouts
--   follow as one run from the frame's ring ('RingRun'); a later source
--   therefore wins an equal-depth tie among cutouts;
-- * the ordered-path instances of the chunks and the dynamic instances are merged
--   into the one ordered run, by ascending depth key and then source order,
--   and are written to the ring each frame in that order; and since the ordered
--   instances draw after every cutout, an ordered instance at an equal key draws
--   over a cutout.
--
-- A zero-size viewport plans nothing from chunks either.
--
-- __Culling.__ 'planSnapshotCulled' takes a 'ChunkCuller', which says for a pass
-- and a view whether a chunk of a given kind and bounds lies wholly outside the
-- view ("Hetoimasia.Render.TwoD.Culling" is the rule). A culled listing
-- contributes nothing to the plan, which is otherwise exactly the plan without
-- it, and is named in 'plannedCulled'. 'planSnapshot' culls nothing.
--
-- __Runs.__ Consecutive instances in the drawing order share a run when they
-- share a path and a material. A sampler, tint, flag other than the routing
-- ones, depth key, transform, UV rectangle or material parameter word never
-- splits a run, because each travels in the instance. Until application
-- materials exist every instance uses the built-in 'DefaultMaterial', which is
-- cutout-capable, so a layer holds at most two runs: its cutout run and its
-- ordered run. A view with a zero-size viewport and a layer with no instances
-- hold no runs.
--
-- __Clips.__ A clip index never changes the plan: it does not split a run,
-- route an instance or move it in the drawing order, so instances with
-- different clip indices share one run. A view's plan carries its clip table,
-- resolved ('plannedClips'), for the recorder to write and the oracle to apply;
-- which entry an instance selects stays in the instance's flags word.
--
-- __Marks.__ A texture's cutout mark is an input, not something this module
-- computes or stores: the caller says which complete handles, generation
-- included, are marked cutout-safe, and an absent handle takes the ordered
-- path. A mark for one generation never affects another handle that reuses its
-- lookup index.
--
-- __Cost.__ Planning is pure and total over a validated snapshot. A layer's
-- instances, and the ordered instances of its chunks, are sorted once, in
-- O(n log n) in their count (a chunk's ordered instances are held sorted, so the
-- sort meets presorted runs); the plan keeps per instance only two unboxed
-- arrays of indices, the permutation and where each index points. A chunk's
-- cutout instances are not in them: they are not rewritten.
--
-- __Dependencies.__ @base@, @array@ for the permutation, @containers@ for the
-- chunks of a layer, @hetoimasia-render-api@ for the handle, and this package's
-- clip, snapshot, validation, chunk and routing modules.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.DrawPlan
  ( -- * Planning
    planSnapshot
  , planSnapshotCulled
  , ChunkCuller
  , noCulling

    -- * Marks
  , CutoutMarks
  , cutoutMarks
  , noCutoutMarks
  , isMarkedCutout

    -- * The plan
  , DrawPlan (..)
  , PlannedPass (..)
  , PlannedView (..)
  , PlannedLayer (..)
  , LayerSpace (..)
  , DrawRun (..)
  , DrawPath (..)
  , RunSource (..)
  , InstanceSource (..)
  , Material (..)
  , materialCutoutCapable
  , drawingOrder
  , drawingSources
  , runIndices
  ) where

import qualified Data.Array as Array
import Data.Array.Unboxed (UArray, elems, listArray)
import Data.List (partition, sortOn)
import qualified Data.Map.Strict as Map
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Clip (ResolvedClip, resolveClips)
import Hetoimasia.Render.TwoD.Internal.Chunk (Bounds, Chunk (..), ChunkKind, layerChunkKind)
import Hetoimasia.Render.TwoD.Internal.ChunkRef (ChunkRef)
import Hetoimasia.Render.TwoD.Internal.Routing
  ( CutoutMarks
  , Material (..)
  , cutoutMarks
  , instanceMaterialOf
  , isMarkedCutout
  , materialCutoutCapable
  , noCutoutMarks
  , routesToCutout
  )
import Hetoimasia.Render.TwoD.Settings (ViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
  ( Camera
  , ClearColour
  , Instance (..)
  , Layer (..)
  , LayerDepth (..)
  , Pass (..)
  , Snapshot (..)
  , Target
  , View (..)
  , Viewport (..)
  , layerInstances
  )
import Hetoimasia.Render.TwoD.Validation
  ( Location (..)
  , ValidSnapshot
  , validLayerChunks
  , validLayerLocation
  , validLayers
  , validSnapshot
  )

-- | The path a run draws in.
data DrawPath
  = -- | Depth-tested and depth-written, one run per material.
    Cutout
  | -- | Depth-tested where the layer has depth and never written, drawn in the
    -- order the plan gives.
    Ordered
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Where a run's instances are read from.
data RunSource
  = -- | The frame's ring: the run's range of the layer's drawing order, written
    -- each frame.
    RingRun
  | -- | A chunk listing's own device buffer, from the first instance it holds
    -- for the run's range: the position of the listing in the layer's chunk
    -- list.
    ChunkRun !Int
  deriving stock (Eq, Ord, Show)

-- | Where an instance of a layer's drawing order comes from.
data InstanceSource
  = -- | The layer's dynamic instance at this submission index.
    DynamicInstance !Int
  | -- | The instance at this build position of the chunk listed at this position.
    ChunkInstance !Int !Int
  deriving stock (Eq, Ord, Show)

-- | Whether the chunk of this reference, kind, bounds and placement magnitude
-- ('Hetoimasia.Render.TwoD.Chunk.chunkPlacementMagnitude') is skipped for the view
-- at this pass and view index. A backend may skip a chunk for a reason of its own,
-- by reference, as well as by bounds.
type ChunkCuller = Int → Int → ChunkRef → ChunkKind → Bounds → Double → Bool

-- | The culler that skips nothing.
noCulling ∷ ChunkCuller
noCulling _ _ _ _ _ _ = False

-- | A frame's draw plan: the snapshot's passes, in order.
newtype DrawPlan = DrawPlan
  { planPasses ∷ [PlannedPass]
  }
  deriving stock (Eq, Show)

-- | A pass, as the snapshot gave it, with its views planned.
data PlannedPass = PlannedPass
  { plannedTarget ∷ !Target
  , plannedClear ∷ !ClearColour
  , plannedViews ∷ [PlannedView]
  }
  deriving stock (Eq, Show)

-- | A view, as the snapshot gave it, with its layers planned.
data PlannedView = PlannedView
  { plannedCamera ∷ !Camera
  , plannedViewport ∷ !Viewport
  , plannedSettings ∷ !ViewSettings
  , plannedClips ∷ [ResolvedClip]
  -- ^ The view's clip table resolved ('resolveClips'): one rectangle per entry,
  -- each intersected with its parent chain, in table order.
  , plannedLayers ∷ [PlannedLayer]
  }
  deriving stock (Eq, Show)

-- | The space a layer declares.
data LayerSpace
  = -- | A world layer, with its depth enabled or not.
    WorldSpace !LayerDepth
  | -- | A UI layer.
    UiSpace
  deriving stock (Eq, Show)

-- | A layer's draw order and runs.
data PlannedLayer = PlannedLayer
  { plannedLocation ∷ !Location
  -- ^ Where the layer sits in the snapshot: an 'AtLayer'.
  , plannedSpace ∷ !LayerSpace
  , plannedClearsDepth ∷ !Bool
  -- ^ Whether the layer clears depth within its viewport before its runs: every
  -- world layer with depth enabled does, whether or not any of its instances
  -- takes the cutout path.
  , plannedOrder ∷ !(UArray Int Int)
  -- ^ The permutation of the layer's instances that is the order the ring
  -- holds them in: each entry is a submission index of the layer's dynamic
  -- instances or, where 'plannedOrigin' says so, a build position in a chunk.
  -- Empty in a zero-size viewport. For a layer that lists no chunk, the
  -- layer's whole drawing order.
  , plannedOrigin ∷ !(UArray Int Int)
  -- ^ For each entry of 'plannedOrder', @-1@ when it is a dynamic instance's
  -- submission index and otherwise the position in the layer's chunk list of
  -- the listing it is a build position in.
  , plannedCulled ∷ ![Int]
  -- ^ The positions in the layer's chunk list of the listings the culler
  -- skipped for the view, in listing order.
  , plannedRuns ∷ ![DrawRun]
  -- ^ The runs, in drawing order. Those that read the ring ('RingRun')
  -- partition 'plannedOrder', in order; the cutout runs of a chunk read the
  -- chunk's own buffer ('ChunkRun') and are not in it.
  }
  deriving stock (Eq, Show)

-- | A contiguous range of instances sharing a path and a material.
data DrawRun = DrawRun
  { runPath ∷ !DrawPath
  , runMaterial ∷ !Material
  , runStart ∷ !Int
  -- ^ The position in 'plannedOrder' of the run's first instance for a
  -- 'RingRun'; for a 'ChunkRun', the position in the chunk's cutout order
  -- (which its buffer follows) of the first.
  , runCount ∷ !Int
  -- ^ The number of instances; always at least one.
  , runSource ∷ !RunSource
  }
  deriving stock (Eq, Show)

-- | A layer's ring entries in drawing order: for a layer that lists no chunk,
-- its submission indices.
drawingOrder ∷ PlannedLayer → [Int]
drawingOrder = elems . plannedOrder

-- | Where each entry of the layer's drawing order comes from.
drawingSources ∷ PlannedLayer → [InstanceSource]
drawingSources layer = zipWith source (elems (plannedOrigin layer)) (elems (plannedOrder layer))
  where
    source origin index
      | origin < 0 = DynamicInstance index
      | otherwise = ChunkInstance origin index

-- | The entries of 'plannedOrder' a run draws, in drawing order. A chunk's run
-- reads the chunk's buffer and holds none.
runIndices ∷ PlannedLayer → DrawRun → [Int]
runIndices layer run = case runSource run of
  RingRun → take (runCount run) (drop (runStart run) (drawingOrder layer))
  ChunkRun _ → []

-- | Plan a validated snapshot against the textures' cutout marks, culling no
-- chunk.
planSnapshot ∷ CutoutMarks → ValidSnapshot → DrawPlan
planSnapshot = planSnapshotCulled noCulling

-- | Plan a validated snapshot against the textures' cutout marks, leaving out
-- the chunk listings the culler skips for each view.
planSnapshotCulled ∷ ChunkCuller → CutoutMarks → ValidSnapshot → DrawPlan
planSnapshotCulled culls marks valid =
  DrawPlan
    [ planPass culls chunksOf marks passIndex pass
    | (passIndex, pass) ← zip [0 ..] (snapshotPasses (validSnapshot valid))
    ]
  where
    chunksOf = Map.fromList [((pass, view, layer), validLayerChunks held) | held ← validLayers valid, AtLayer pass view layer ← [validLayerLocation held]]

type ChunksOf = Map.Map (Int, Int, Int) [(ChunkRef, Chunk)]

planPass ∷ ChunkCuller → ChunksOf → CutoutMarks → Int → Pass → PlannedPass
planPass culls chunksOf marks passIndex pass =
  PlannedPass
    { plannedTarget = passTarget pass
    , plannedClear = passClear pass
    , plannedViews =
        [planView culls chunksOf marks passIndex viewIndex view | (viewIndex, view) ← zip [0 ..] (passViews pass)]
    }

planView ∷ ChunkCuller → ChunksOf → CutoutMarks → Int → Int → View → PlannedView
planView culls chunksOf marks passIndex viewIndex view =
  PlannedView
    { plannedCamera = viewCamera view
    , plannedViewport = viewViewport view
    , plannedSettings = viewSettings view
    , plannedClips = resolveClips (viewClips view)
    , plannedLayers =
        [ planLayer (culls passIndex viewIndex) marks (viewViewport view) (AtLayer passIndex viewIndex layerIndex) layer (Map.findWithDefault [] (passIndex, viewIndex, layerIndex) chunksOf)
        | (layerIndex, layer) ← zip [0 ..] (viewLayers view)
        ]
    }

planLayer ∷ (ChunkRef → ChunkKind → Bounds → Double → Bool) → CutoutMarks → Viewport → Location → Layer → [(ChunkRef, Chunk)] → PlannedLayer
planLayer culls marks viewport location layer chunks =
  -- Every field that reads the drawing order is evaluated before the layer
  -- exists, and none is a thunk: nothing the plan returns still refers to the
  -- per-instance list, so only the permutation is kept.
  PlannedLayer
    { plannedLocation = location
    , plannedSpace = space
    , plannedClearsDepth = clearsDepth
    , plannedOrder = listArray (0, length ringEntries - 1) [index | (_, index, _) ← ringEntries]
    , plannedOrigin = listArray (0, length ringEntries - 1) [origin | (origin, _, _) ← ringEntries]
    , plannedCulled = spineStrict culled
    , plannedRuns = spineStrict runs
    }
  where
    (space, clearsDepth) = case layer of
      WorldLayerWith depth _ _ → (WorldSpace depth, depth == DepthEnabled)
      UiLayerWith _ _ → (UiSpace, False)
    kind = layerChunkKind layer
    -- A zero-size viewport draws nothing, so it holds no order and no runs.
    drawn = not (emptyViewport viewport)
    listings = zip [0 ..] (map snd chunks)
    (skipped, live)
      | drawn = partition (\(position, held) → culls (fst (chunks !! position)) kind (chunkBoundsField held) (chunkMagnitudeField held)) listings
      | otherwise = ([], [])
    culled = map fst skipped
    (ringEntries, runs)
      | drawn = arrange marks clearsDepth live (layerInstances layer)
      | otherwise = ([], [])

-- | The list with its spine and elements evaluated, so no unevaluated tail
-- keeps what produced it alive.
spineStrict ∷ [a] → [a]
spineStrict items = foldr seq () items `seq` items

emptyViewport ∷ Viewport → Bool
emptyViewport (Viewport _ (V2 width height)) = width == 0 || height == 0

-- | The ring's entries of a layer — each as its origin (@-1@ dynamic, else the
-- chunk listing's position), its index there and the path and material it
-- draws in — and the layer's runs.
--
-- The cutouts come first: by material, and within a material each chunk
-- listing's cutouts as a run of the chunk's own buffer in listing order, then
-- the dynamic cutouts by submission order as a run of the ring. The ordered
-- instances follow, the chunks' and the dynamic ones merged by ascending depth
-- key and then source order, which is a listing's position (a chunk's before
-- any dynamic instance) and then the index.
arrange ∷ CutoutMarks → Bool → [(Int, Chunk)] → [Instance] → ([(Int, Int, (DrawPath, Material))], [DrawRun])
arrange marks depthEnabled live instances = (ringEntries, cutoutRuns <> orderedRuns)
  where
    (dynamicCutouts, dynamicOrdered) = partition (routesToCutout marks depthEnabled . snd) (zip [0 ..] instances)
    sortedCutouts = sortOn (\(index, candidate) → (instanceMaterialOf candidate, index)) dynamicCutouts
    ringCutouts = [(-1, index, (Cutout, instanceMaterialOf candidate)) | (index, candidate) ← sortedCutouts]
    chunkOrdered =
      [ (key, position, index, instanceMaterialOf candidate)
      | (position, held) ← live
      , index ← chunkOrderedOrder held
      , let candidate = chunkInstanceArray held `at` index
      , let key = instanceDepthKey candidate
      ]
    dynamicOrderedKeyed = [(instanceDepthKey candidate, maxBound, index, instanceMaterialOf candidate) | (index, candidate) ← dynamicOrdered]
    mergedOrdered = sortOn (\(key, position, index, _) → (key, position, index)) (chunkOrdered <> dynamicOrderedKeyed)
    ringOrdered = [(if position == maxBound then -1 else position, index, (Ordered, material)) | (_, position, index, material) ← mergedOrdered]
    ringEntries = ringCutouts <> ringOrdered
    ringCutoutRuns = [run {runSource = RingRun} | run ← runsOf 0 [path | (_, _, path) ← ringCutouts]]
    chunkCutoutRuns =
      [ DrawRun Cutout material start count (ChunkRun position)
      | (position, held) ← live
      , (start, count, material) ← materialGroups [instanceMaterialOf (chunkInstanceArray held `at` index) | index ← chunkCutoutOrder held]
      ]
    -- By material, and within one by source order: a chunk's listings in order,
    -- then the ring's.
    cutoutRuns = sortOn (\run → (runMaterial run, sourceRank (runSource run))) (chunkCutoutRuns <> ringCutoutRuns)
    orderedRuns = runsOf (length ringCutouts) [path | (_, _, path) ← ringOrdered]
    sourceRank = \case
      ChunkRun position → position
      RingRun → maxBound
    at array index = array Array.! index

-- | The maximal ranges of consecutive equal materials, as start, count and
-- material.
materialGroups ∷ [Material] → [(Int, Int, Material)]
materialGroups = go 0
  where
    go _ [] = []
    go start (first : rest) =
      let (same, others) = span (== first) rest
          count = 1 + length same
       in (start, count, first) : go (start + count) others

-- | Group consecutive entries sharing a path and a material into ring runs,
-- the first starting at this position of the drawing order.
runsOf ∷ Int → [(DrawPath, Material)] → [DrawRun]
runsOf = go
  where
    go _ [] = []
    go start (first : rest) =
      let (same, others) = span (== first) rest
          count = 1 + length same
          (path, material) = first
       in DrawRun path material start count RingRun : go (start + count) others
