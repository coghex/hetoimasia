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
-- __Runs.__ Consecutive instances in the drawing order share a run when they
-- share a path and a material. A sampler, tint, flag other than the routing
-- ones, depth key, transform, UV rectangle or material parameter word never
-- splits a run, because each travels in the instance. Until application
-- materials exist every instance uses the built-in 'DefaultMaterial', which is
-- cutout-capable, so a layer holds at most two runs: its cutout run and its
-- ordered run. A view with a zero-size viewport and a layer with no instances
-- hold no runs.
--
-- __Marks.__ A texture's cutout mark is an input, not something this module
-- computes or stores: the caller says which complete handles, generation
-- included, are marked cutout-safe, and an absent handle takes the ordered
-- path. A mark for one generation never affects another handle that reuses its
-- lookup index.
--
-- __Cost.__ Planning is pure and total over a validated snapshot. A layer's
-- instances are sorted once, in O(n log n) in the layer's instance count; the
-- one structure the plan keeps per instance is the permutation, an unboxed
-- array of that many indices.
--
-- __Dependencies.__ @base@, @array@ for the permutation, @containers@ for the
-- set of marked handles, @hetoimasia-render-api@ for the handle, and this
-- package's snapshot and validation modules.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.DrawPlan
  ( -- * Planning
    planSnapshot

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
  , Material (..)
  , materialCutoutCapable
  , drawingOrder
  , runIndices
  ) where

import Data.Array.Unboxed (UArray, elems, listArray)
import Data.List (partition, sortOn)
import Data.Set (Set)
import qualified Data.Set as Set
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture (TextureHandle)
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
  , Tint (..)
  , View (..)
  , Viewport (..)
  , layerInstances
  )
import Hetoimasia.Render.TwoD.Validation (Location (..), ValidSnapshot, validSnapshot)

-- | The textures marked cutout-safe, each by its complete handle, generation
-- included. A handle that is not in the set is unmarked.
newtype CutoutMarks = CutoutMarks (Set TextureHandle)
  deriving stock (Eq, Show)

-- | The marks naming exactly these handles as cutout-safe.
cutoutMarks ∷ [TextureHandle] → CutoutMarks
cutoutMarks = CutoutMarks . Set.fromList

-- | No texture is marked: every instance takes the ordered path.
noCutoutMarks ∷ CutoutMarks
noCutoutMarks = CutoutMarks Set.empty

-- | Whether this exact handle, generation included, is marked cutout-safe.
isMarkedCutout ∷ CutoutMarks → TextureHandle → Bool
isMarkedCutout (CutoutMarks marked) handle = Set.member handle marked

-- | The path a run draws in.
data DrawPath
  = -- | Depth-tested and depth-written, one run per material.
    Cutout
  | -- | Depth-tested where the layer has depth and never written, drawn in the
    -- order the plan gives.
    Ordered
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The material a run draws with. Application materials, and how an instance
-- names one, arrive later (R2D-11); until then every instance uses the
-- built-in default.
data Material = DefaultMaterial
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Whether a material routes to the cutout path: its output alpha is binary
-- wherever its primary texture's is. The built-in default is.
materialCutoutCapable ∷ Material → Bool
materialCutoutCapable DefaultMaterial = True

-- | The material an instance draws with. Until application materials exist,
-- the built-in default for every instance.
instanceMaterialOf ∷ Instance → Material
instanceMaterialOf _ = DefaultMaterial

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
  -- ^ The permutation of the layer's submission indices that is its drawing
  -- order. Empty in a zero-size viewport.
  , plannedRuns ∷ ![DrawRun]
  -- ^ The runs, in drawing order. They partition 'plannedOrder'.
  }
  deriving stock (Eq, Show)

-- | A contiguous range of a layer's drawing order sharing a path and a
-- material.
data DrawRun = DrawRun
  { runPath ∷ !DrawPath
  , runMaterial ∷ !Material
  , runStart ∷ !Int
  -- ^ The position in 'plannedOrder' of the run's first instance.
  , runCount ∷ !Int
  -- ^ The number of instances; always at least one.
  }
  deriving stock (Eq, Show)

-- | A layer's submission indices in drawing order.
drawingOrder ∷ PlannedLayer → [Int]
drawingOrder = elems . plannedOrder

-- | The submission indices a run draws, in drawing order.
runIndices ∷ PlannedLayer → DrawRun → [Int]
runIndices layer run = take (runCount run) (drop (runStart run) (drawingOrder layer))

-- | Plan a validated snapshot against the textures' cutout marks.
planSnapshot ∷ CutoutMarks → ValidSnapshot → DrawPlan
planSnapshot marks valid =
  DrawPlan
    [ planPass marks passIndex pass
    | (passIndex, pass) ← zip [0 ..] (snapshotPasses (validSnapshot valid))
    ]

planPass ∷ CutoutMarks → Int → Pass → PlannedPass
planPass marks passIndex pass =
  PlannedPass
    { plannedTarget = passTarget pass
    , plannedClear = passClear pass
    , plannedViews =
        [planView marks passIndex viewIndex view | (viewIndex, view) ← zip [0 ..] (passViews pass)]
    }

planView ∷ CutoutMarks → Int → Int → View → PlannedView
planView marks passIndex viewIndex view =
  PlannedView
    { plannedCamera = viewCamera view
    , plannedViewport = viewViewport view
    , plannedSettings = viewSettings view
    , plannedLayers =
        [ planLayer marks (viewViewport view) (AtLayer passIndex viewIndex layerIndex) layer
        | (layerIndex, layer) ← zip [0 ..] (viewLayers view)
        ]
    }

planLayer ∷ CutoutMarks → Viewport → Location → Layer → PlannedLayer
planLayer marks viewport location layer =
  -- Both fields that read the drawing order are evaluated before the layer
  -- exists, and neither is a thunk: nothing the plan returns still refers to the
  -- per-instance list, so only the permutation is kept.
  PlannedLayer
    { plannedLocation = location
    , plannedSpace = space
    , plannedClearsDepth = clearsDepth
    , plannedOrder = listArray (0, length order - 1) (map fst order)
    , plannedRuns = spineStrict (runsOf (map snd order))
    }
  where
    (space, clearsDepth) = case layer of
      WorldLayer depth _ → (WorldSpace depth, depth == DepthEnabled)
      UiLayer _ → (UiSpace, False)
    -- A zero-size viewport draws nothing, so it holds no order and no runs.
    order
      | emptyViewport viewport = []
      | otherwise = drawOrder marks clearsDepth (layerInstances layer)

-- | The list with its spine and elements evaluated, so no unevaluated tail
-- keeps what produced it alive.
spineStrict ∷ [a] → [a]
spineStrict items = foldr seq () items `seq` items

emptyViewport ∷ Viewport → Bool
emptyViewport (Viewport _ (V2 width height)) = width == 0 || height == 0

-- | The layer's drawing order: each submission index with the path and material
-- it draws in. The cutouts come first, by material and then submission
-- sequence; the ordered instances follow, by depth key and then submission
-- sequence. The index is the sequence, so it breaks every tie.
drawOrder ∷ CutoutMarks → Bool → [Instance] → [(Int, (DrawPath, Material))]
drawOrder marks depthEnabled instances =
  map cutoutEntry (sortOn (\(index, candidate) → (instanceMaterialOf candidate, index)) cutouts)
    <> map orderedEntry (sortOn (\(index, candidate) → (instanceDepthKey candidate, index)) ordered)
  where
    (cutouts, ordered) = partition (routesToCutout marks depthEnabled . snd) (zip [0 ..] instances)
    cutoutEntry (index, candidate) = (index, (Cutout, instanceMaterialOf candidate))
    orderedEntry (index, candidate) = (index, (Ordered, instanceMaterialOf candidate))

-- | Whether an instance takes the cutout path in a layer.
routesToCutout ∷ CutoutMarks → Bool → Instance → Bool
routesToCutout marks depthEnabled candidate =
  depthEnabled
    && isMarkedCutout marks (instanceTexture candidate)
    && materialCutoutCapable (instanceMaterialOf candidate)
    && opaque (instanceTint candidate)
    && not (instanceTranslucent candidate)
    && not (instanceAdditive candidate)
  where
    opaque (Tint _ _ _ alpha) = alpha == 255

-- | Group consecutive entries sharing a path and a material into runs.
runsOf ∷ [(DrawPath, Material)] → [DrawRun]
runsOf = go 0
  where
    go _ [] = []
    go start (first : rest) =
      let (same, others) = span (== first) rest
          count = 1 + length same
          (path, material) = first
       in DrawRun path material start count : go (start + count) others
