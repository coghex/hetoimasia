-- | Bounded visible-face planning, missing-data demand and ordering
-- candidates for the isometric cutaway.
--
-- == What a plan is
--
-- 'planTerrain' turns one coherent request (a camera, a view, versions) and one
-- 'TerrainFacts' into an immutable 'Plan': the faces that can project into the
-- viewport, each with its exact render-world polygon, its coverage mask and
-- instance quad (derived from the shared terrain solids, so the material
-- adapter and picking read the same geometry), and a 24-bit depth key that
-- orders the faces back to front. A plan is a whole new value; earlier plans
-- are untouched. It carries the arena incarnation, content revision, residency
-- generation, camera revision, material version, facing and cut level it was
-- built from.
--
-- == Which faces
--
-- A cell begins at integer Z; cutaway level @K@ includes the cells with
-- @Z <= K@ and cuts at plane @K + 1@. The visibility band is the clip level
-- and the 'pcDepth' (initially 250) levels below it: a visibility cap, not a
-- floor, and not a promise to load that volume.
--
-- The view looks down along @(1, 1, 3)@, so only a face whose outward normal
-- has a positive component along it can be seen. In the view frame these are
-- every top and sloped surface, the East wall and the South wall. A bottom face
-- and the North and West walls are never emitted, so a ceiling is never drawn:
-- a cavity ceiling is hidden by the cell that forms it, and is gone when the
-- cut removes that cell. Whether a visible face is emitted depends on what it
-- touches, taken from the facts:
--
-- * a sloped top is emitted: it borders the air inside its own cell;
-- * a flat top (plane @z = 1@) is emitted when the cell above is known air;
--   it is also emitted at the clip level, where the cut exposes it, as a
--   'RoleCap' unless the cell above is known air ('RoleSurface'); it is
--   skipped under a known solid;
-- * an East or South wall is emitted when the neighbouring cell on that side
--   is known air or lies outside the supported range, and when it is solid
--   unless the neighbour's opposite wall covers it: the wall polygon is
--   compared with the neighbour's actual wall polygon (the shared solid
--   geometry), so a partial contact exposes exactly the faces a lower or
--   differently shaped neighbour leaves open, and a full-block shortcut is
--   never taken.
--
-- A face that depends on an unavailable fact is not emitted: it is never
-- invented. The plan is then 'Incomplete', 'planDemand' names what to load
-- (chunk keys with explicit level intervals and 32-level region keys) and
-- 'planUnknown' bounds, in render-world pixels, the cells nothing is known
-- about, which picking uses to refuse an authoritative answer.
--
-- == Cost and bounds
--
-- The columns that can project into the viewport are enumerated from the
-- visible rectangle and, per column, only the levels that can project into it
-- inside the band. Each column is read as runs, and a stretch of identical flat
-- solid between two such neighbours is skipped, so cost follows the intervals
-- and exposed faces, not the depth. The caller's 'PlanLimits' bound the
-- columns, the cells evaluated, the faces, the overlap candidates and the
-- demand; a plan that would exceed one is refused with the limit, never
-- truncated, and nothing is retried here.
--
-- == Ordering
--
-- Two faces constrain each other only where their projections overlap with
-- positive area; the one nearer along the viewing direction draws later. A
-- total order is derived from those constraints (see "Ordering" in the package
-- README) and each face's depth key is its position, so keys are distinct,
-- below @2^24@, and independent of enumeration. Faces that cross or cycle
-- cannot be ordered: the plan is refused with a counterexample, the Q-13 path.
-- Keys are valid within one plan.
--
-- State, ownership and lifetime: none. The caller owns the facts and the camera;
-- a plan is an immutable value with no thread or resource.
module Hetoimasia.Terrain.Render2D.Plan
  ( -- * Configuration
    PlanLimits (..)
  , defaultPlanLimits
  , PlanConfig (..)
  , defaultPlanConfig

    -- * Request and result
  , PlanRequest (..)
  , PlanIdentity (..)
  , FaceRole (..)
  , PlannedFace (..)
  , Completeness (..)
  , PlanStats (..)
  , Plan
  , planIdentity
  , planView
  , planFaces
  , planCompleteness
  , planDemand
  , planUnknown
  , planBounds
  , planStats
  , faceInstance

    -- * Refusal
  , Limit (..)
  , FaceRef
  , OrderingFailure (..)
  , PlanError (..)

    -- * Planning
  , planTerrain
  , cameraDemand
  ) where

import Control.Monad (foldM)
import Data.List (sortOn)
import Data.Maybe (isJust)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word32, Word64)
import Hetoimasia.Math.Affine2 (Affine2, fromColumns)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.TwoD.Material (defaultMaterial)
import Hetoimasia.Render.TwoD.Mapping (viewportIsEmpty)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..))
import Hetoimasia.Render.TwoD.Snapshot
  ( Instance (..)
  , Sampler (..)
  , Tint (..)
  , UvRect (..)
  , depthKeyLimit
  )
import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Coordinate
import Hetoimasia.Terrain.Geometry
import Hetoimasia.Terrain.Query (QueryError, QueryLimits, defaultQueryLimits)
import Hetoimasia.Terrain.Render2D.Camera
import Hetoimasia.Terrain.Render2D.Facts
import Hetoimasia.Terrain.Render2D.Internal.Order
import Hetoimasia.Terrain.Render2D.Internal.Polygon
import Hetoimasia.Terrain.Render2D.Projection
import Hetoimasia.Terrain.Shape

-- | The bounds on one plan. Each is checked before the work or output it
-- limits, and exceeding one refuses the plan.
data PlanLimits = PlanLimits
  { limitColumns ∷ !Int
  -- ^ Columns examined.
  , limitLevels ∷ !Int
  -- ^ Levels examined for exposure.
  , limitFaces ∷ !Int
  -- ^ Faces emitted.
  , limitPairs ∷ !Int
  -- ^ Overlap candidate pairs examined for ordering.
  , limitKeys ∷ !Int
  -- ^ Depth keys a plan may use, at most the 24-bit key space ('depthKeyLimit').
  , limitDemandChunks ∷ !Int
  -- ^ Chunks named in a demand.
  , limitDemandIntervals ∷ !Int
  -- ^ Intervals named in a demand.
  , limitRegionsPerChunk ∷ !Int
  -- ^ Vertical regions named for one chunk, independent of the columns.
  }
  deriving stock (Eq, Show)

-- | Engineering defaults, not measured capacity: 131,072 columns, 1,048,576
-- cells, 65,536 faces, 1,048,576 pairs, 16,777,216 keys (the whole key space), 1,024 chunks, 8,192 intervals and 16
-- regions per chunk.
defaultPlanLimits ∷ PlanLimits
defaultPlanLimits =
  PlanLimits
    { limitColumns = 131072
    , limitLevels = 1048576
    , limitFaces = 65536
    , limitPairs = 1048576
    , limitKeys = 16777216
    , limitDemandChunks = 1024
    , limitDemandIntervals = 8192
    , limitRegionsPerChunk = 16
    }

-- | Plan settings.
data PlanConfig = PlanConfig
  { pcDepth ∷ !Integer
  -- ^ Levels visible below the clip level, initially 250.
  , pcMargin ∷ !Rational
  -- ^ Whole render-world pixels of slack around the viewport.
  , pcChunkMargin ∷ !Integer
  -- ^ Horizontal prefetch margin in chunks, initially 1.
  , pcQueryLimits ∷ !QueryLimits
  , pcLimits ∷ !PlanLimits
  }
  deriving stock (Eq, Show)

defaultPlanConfig ∷ PlanConfig
defaultPlanConfig =
  PlanConfig
    { pcDepth = 250
    , pcMargin = 2
    , pcChunkMargin = 1
    , pcQueryLimits = defaultQueryLimits
    , pcLimits = defaultPlanLimits
    }

-- | One coherent request. The versions must equal the facts' versions.
data PlanRequest = PlanRequest
  { requestVersions ∷ !Versions
  , requestMaterialVersion ∷ !Word64
  -- ^ The caller's material or asset version; carried, never interpreted.
  , requestCamera ∷ !CameraState
  , requestSetup ∷ !ViewSetup
  , requestConfig ∷ !PlanConfig
  }

-- | What a plan was built from; a pick must present the same identity.
data PlanIdentity = PlanIdentity
  { identityVersions ∷ !Versions
  , identityCameraRevision ∷ !Word64
  , identityMaterialVersion ∷ !Word64
  , identityFacing ∷ !ViewFacing
  , identityCut ∷ !AxisCoord
  , identityReference ∷ !Integer
  , identitySetup ∷ !ViewSetup
  -- ^ The target, viewport and settings the plan was built for.
  , identityConfig ∷ !PlanConfig
  -- ^ The depth, margin and limits it was built under.
  }
  deriving stock (Eq, Show)

-- | Why a face is shown.
data FaceRole
  = -- | An ordinary surface exposed to air.
    RoleSurface
  | -- | A top at the cut plane, exposed by the cutaway.
    RoleCap
  deriving stock (Eq, Ord, Show)

-- | One planned face. Polygon and mask list the same vertices in the same
-- order, in positive orientation of the polygon.
data PlannedFace = PlannedFace
  { faceCell ∷ !TileCoord
  -- ^ The authored world tile; exact at any coordinate.
  , faceShape ∷ !ShapeId
  -- ^ The authored world shape identity.
  , faceMaterial ∷ !MaterialId
  , faceViewKind ∷ !FaceKind
  -- ^ The face's kind in the view frame (its walls are named in view sides).
  , faceIndex ∷ !Int
  -- ^ Its index among the faces of the view-frame solid.
  , faceRole ∷ !FaceRole
  , faceCellOrigin ∷ !(Rational, Rational)
  -- ^ The render-world projection of the face's cell's own origin, the corner
  -- @(0, 0, 0)@ of its unit cell (a cell's art sheet is placed from it: see
  -- "Hetoimasia.Terrain.Render2D.Material"). Exact, in the view's frame.
  , facePolygon ∷ ![(Rational, Rational)]
  -- ^ Render-world polygon, exact.
  , faceMask ∷ ![(Rational, Rational)]
  -- ^ Coverage polygon in the unit square of 'faceQuad': a top face uses its
  -- footprint coordinates @(x, y)@; a wall uses the position along the side
  -- and @1 - z@.
  , faceQuad ∷ !Affine2
  -- ^ The instance transform: the unit square's image, in render-world pixels.
  , faceBounds ∷ !Rect
  , faceDepthKey ∷ !Word32
  -- ^ Distinct within the plan; a larger key is nearer.
  }
  deriving stock (Eq, Show)

-- | Whether every fact the plan needed was available.
data Completeness = Complete | Incomplete
  deriving stock (Eq, Show)

-- | Counts of the work a plan did, for bounds.
data PlanStats = PlanStats
  { statColumns ∷ !Int
  , statLevelsEvaluated ∷ !Int
  , statFaces ∷ !Int
  }
  deriving stock (Eq, Show)

-- | An immutable plan. The constructor is private.
data Plan = Plan
  { plIdentity ∷ !PlanIdentity
  , plView ∷ !RenderView
  , plFaces ∷ ![PlannedFace]
  -- ^ Ascending by depth key: back to front.
  , plCompleteness ∷ !Completeness
  , plDemand ∷ !Demand
  , plUnknown ∷ ![Rect]
  , plBounds ∷ !(Maybe Rect)
  , plStats ∷ !PlanStats
  }
  deriving stock (Eq, Show)

-- Plain functions, not field labels, so a client cannot forge a plan with
-- record-update syntax.

planIdentity ∷ Plan → PlanIdentity
planIdentity = plIdentity

planView ∷ Plan → RenderView
planView = plView

planFaces ∷ Plan → [PlannedFace]
planFaces = plFaces

planCompleteness ∷ Plan → Completeness
planCompleteness = plCompleteness

planDemand ∷ Plan → Demand
planDemand = plDemand

planUnknown ∷ Plan → [Rect]
planUnknown = plUnknown

planBounds ∷ Plan → Maybe Rect
planBounds = plBounds

planStats ∷ Plan → PlanStats
planStats = plStats

-- | A render-2d instance for a face with the default material, a caller texture
-- and the face's quad and depth key. Material and artwork selection belong to
-- the caller.
faceInstance ∷ TextureHandle → PlannedFace → Instance
faceInstance texture face =
  Instance
    { instanceTransform = faceQuad face
    , instanceUv = UvRect 0 0 1 1
    , instanceTexture = texture
    , instanceDepthKey = faceDepthKey face
    , instanceTint = Tint 255 255 255 255
    , instanceSampler = SamplerDefault
    , instanceTranslucent = False
    , instanceAdditive = False
    , instanceClip = 0
    , instanceFrameTable = 0
    , instanceParameter = 0
    , instanceMaterial = defaultMaterial
    }

-- | The limit a plan exceeded.
data Limit
  = LimitColumns
  | LimitLevels
  | LimitFaces
  | LimitPairs
  | LimitDemandChunks
  | LimitDemandIntervals
  | LimitRegionsPerChunk
  | -- | More faces than the 24-bit depth key space.
    LimitDepthKeys
  deriving stock (Eq, Show)

-- | A face named for a counterexample: view-frame cell offsets from the
-- anchor, the cell's level and the face index.
type FaceRef = (Integer, Integer, Integer, Int)

-- | Why faces could not be ordered.
data OrderingFailure
  = -- | The faces of one cycle of the front/back relation.
    OrderingCycle [FaceRef]
  | -- | Two faces whose planes cross inside their overlap.
    OrderingCrossing FaceRef FaceRef
  | -- | Two overlapping faces in one plane.
    OrderingCoincident FaceRef FaceRef
  deriving stock (Eq, Show)

-- | Why a plan was refused. Nothing partial is returned.
data PlanError
  = -- | The request's versions and the facts' versions differ.
    MixedVersions !Versions !Versions
  | -- | The view or camera cannot be built.
    InvalidView !ProjectionError
  | -- | The configuration is unusable.
    InvalidPlanConfig
  | -- | A bound would be exceeded.
    PlanInsufficient !Limit
  | -- | A column query was refused.
    QueryRefused !QueryError
  | -- | The faces cannot be ordered through the renderer's depth keys.
    PlanUnorderable !OrderingFailure
  | -- | The view snaps to the pixel grid at a world scale (zoom, or the scale a
    -- fixed-half-height mode gives it) that is not a whole multiple of 1/8, which
    -- would move adjacent faces apart.
    PixelSnapUnsupported !Float
  | -- | A value could not be represented.
    Unrepresentable !String
  deriving stock (Eq, Show)

-- The columns that can project into the viewport, with their level windows.
data Cand = Cand !Integer !Integer !Integer !Integer

type Offset = (Integer, Integer)

-- Everything a request fixes before any fact is read.
data Prepared = Prepared
  { prView ∷ !RenderView
  , prRef ∷ !Integer
  , prClip ∷ !Integer
  , prCands ∷ ![Cand]
  }

prepare ∷ PlanRequest → Either PlanError Prepared
prepare request = do
  let config = requestConfig request
      limits = pcLimits config
      camera = requestCamera request
  if pcDepth config < 0 || pcDepth config > maxVisibleDepth || pcMargin config < 0 || pcChunkMargin config < 0 || not (validLimits limits)
    then Left InvalidPlanConfig
    else pure ()
  view ←
    either (Left . InvalidView) Right $
      mkRenderView (requestSetup request) (camZoom camera) (camFacing camera) (camFrac camera)
  let ref = camRef camera
      clip = toInteger (axisValue (camClip camera))
      bandLo = clip - pcDepth config
  if zeroDrawable (requestSetup request)
    then pure (Prepared view ref clip [])
    else do
      -- Instance origins must stay on whole pixels when the view snaps, or the
      -- recorder would move adjacent faces apart.
      if settingPixelSnap (setupSettings (requestSetup request)) && not (snapCompatible view)
        then Left (PixelSnapUnsupported (viewScale view))
        else pure ()
      rect ← maybe (Left (Unrepresentable "the visible rectangle")) Right (visibleRect (pcMargin config) view)
      cands ← candidates limits rect ref clip bandLo
      pure (Prepared view ref clip cands)

-- Every bound nonnegative, and the key bound within the 24-bit key space.
validLimits ∷ PlanLimits → Bool
validLimits l =
  all
    (>= 0)
    [ limitColumns l
    , limitLevels l
    , limitFaces l
    , limitPairs l
    , limitKeys l
    , limitDemandChunks l
    , limitDemandIntervals l
    , limitRegionsPerChunk l
    ]
    && limitKeys l <= fromIntegral depthKeyLimit

-- | The greatest configurable visibility depth: the approved cap of 250 levels
-- below the clip level.
maxVisibleDepth ∷ Integer
maxVisibleDepth = 250

-- A target that draws nothing: an empty viewport, or a logical or framebuffer
-- extent with a zero side, whatever the viewport says.
zeroDrawable ∷ ViewSetup → Bool
zeroDrawable setup =
  viewportIsEmpty (setupViewport setup)
    || any (<= 0) [pixelWidth logical, pixelHeight logical, pixelWidth framebuffer, pixelHeight framebuffer]
  where
    logical = metricsLogical (setupMetrics setup)
    framebuffer = metricsFramebuffer (setupMetrics setup)

-- The candidate columns and their absolute level windows.
candidates ∷ PlanLimits → Rect → Integer → Integer → Integer → Either PlanError [Cand]
candidates limits (Rect x1 x2 y1 y2) ref clip bandLo
  | bandLo > clip = Right []
  | width * height > 4 * toInteger (limitColumns limits) + 4 = Left (PlanInsufficient LimitColumns)
  | not (null (drop (limitColumns limits) found)) = Left (PlanInsufficient LimitColumns)
  | otherwise = Right found
  where
    zLoRel = bandLo - ref
    zHiRel = clip - ref
    uLo = ceiling (x1 / 48) - 1 ∷ Integer
    uHi = floor (x2 / 48) + 1 ∷ Integer
    vLo = ceiling ((y1 + 16 * fromInteger zLoRel) / 24) - 1 ∷ Integer
    vHi = floor ((y2 + 16 * fromInteger (zHiRel + 1)) / 24) + 1 ∷ Integer
    width = max 0 (uHi - uLo + 1)
    height = max 0 (vHi - vLo + 1)
    found =
      [ Cand ((u + v) `div` 2) ((v - u) `div` 2) (lo + ref) (hi + ref)
      | u ← [uLo .. uHi]
      , v ← [vLo .. vHi]
      , even (u + v)
      , let lo = max zLoRel (ceiling ((24 * fromInteger (v - 1) - 16 - y2) / 16))
      , let hi = min zHiRel (floor ((24 * fromInteger (v + 1) - y1) / 16))
      , lo <= hi
      ]

-- The world column a view-frame offset names, or nothing outside the range.
worldColumn ∷ CameraState → Offset → Maybe Column
worldColumn camera (rx, ry) = do
  let (dx, dy) = worldOffset (camFacing camera) (rx, ry)
  x ← either (const Nothing) Just (axisFromInteger (toInteger (axisValue (camAnchorX camera)) + dx))
  y ← either (const Nothing) Just (axisFromInteger (toInteger (axisValue (camAnchorY camera)) + dy))
  pure (Column x y)

-- The planner. See the module header.
planTerrain ∷ PlanRequest → TerrainFacts → Either PlanError Plan
planTerrain request facts = do
  checkVersions request facts
  prepared ← prepare request
  let camera = requestCamera request
      config = requestConfig request
      limits = pcLimits config
      facing = camFacing camera
      view = prView prepared
      ref = prRef prepared
      clip = prClip prepared
      identity =
        PlanIdentity
          { identityVersions = requestVersions request
          , identityCameraRevision = camRevision camera
          , identityMaterialVersion = requestMaterialVersion request
          , identityFacing = facing
          , identityCut = camClip camera
          , identityReference = ref
          , identitySetup = requestSetup request
          , identityConfig = config
          }
      cands = prCands prepared
  runs ← fetchRuns config facts camera cands
  layer ← foldM (evaluateCandidate camera clip limits runs) emptyLayer cands
  rawFaces ← traverse (buildFace ref) (reverse (layerCells layer))
  let built = [face | Just face ← rawFaces]
  -- Every face must be placeable in the target by the view's own mapping.
  if all (\b → isJust (drawnOutline (rvMapping view) (builtQuad b) (builtMask b))) built
    then pure ()
    else Left (Unrepresentable "a face in the target")
  if length built > limitFaces limits then Left (PlanInsufficient LimitFaces) else pure ()
  if length built > min (limitKeys limits) (fromIntegral depthKeyLimit) then Left (PlanInsufficient LimitDepthKeys) else pure ()
  order ← either (Left . fromOrderError limits) Right (orderFaces (limitPairs limits) (map builtOrder built))
  let byIndex = Map.fromList (zip [0 ∷ Int ..] built)
      keyed = [(position, byIndex Map.! index) | (position, index) ← zip [0 ∷ Int ..] order]
      faces = [finish (fromIntegral position) face | (position, face) ← keyed]
      (unknownIntervals, wants) = wantsOf camera layer
  demand ← boundedDemand limits wants
  let bounds = case faces of
        [] → Nothing
        _ →
          Just
            ( Rect
                (minimum (map (rectMinX . faceBounds) faces))
                (maximum (map (rectMaxX . faceBounds) faces))
                (minimum (map (rectMinY . faceBounds) faces))
                (maximum (map (rectMaxY . faceBounds) faces))
            )
      unknownRects = [cellsRect ref off lo hi | (off, lo, hi) ← unknownIntervals]
  pure
    Plan
      { plIdentity = identity
      , plView = view
      , plFaces = faces
      , plCompleteness = if null unknownIntervals then Complete else Incomplete
      , plDemand = demand
      , plUnknown = unknownRects
      , plBounds = bounds
      , plStats =
          PlanStats
            { statColumns = length cands
            , statLevelsEvaluated = layerLevels layer
            , statFaces = length faces
            }
      }

checkVersions ∷ PlanRequest → TerrainFacts → Either PlanError ()
checkVersions request facts
  | requestVersions request == factsVersions facts = Right ()
  | otherwise = Left (MixedVersions (requestVersions request) (factsVersions facts))

fromOrderError ∷ PlanLimits → OrderError → PlanError
fromOrderError _ (OrderCycle faces) = PlanUnorderable (OrderingCycle faces)
fromOrderError _ (OrderCrossing a b) = PlanUnorderable (OrderingCrossing a b)
fromOrderError _ (OrderCoincident a b) = PlanUnorderable (OrderingCoincident a b)
fromOrderError _ (OrderTooManyPairs _) = PlanInsufficient LimitPairs

-- Column runs for every offset the candidates read, over the union window of
-- the cells read from it: a candidate's own column one level either side, the
-- columns East and South over its window.
fetchRuns ∷ PlanConfig → TerrainFacts → CameraState → [Cand] → Either PlanError (Map.Map Offset [FRun])
fetchRuns config facts camera cands = Map.traverseWithKey fetch wants
  where
    wants = foldl' add Map.empty cands
    add acc (Cand x y lo hi) =
      hull (x, y + 1) (lo, hi + 1) (hull (x + 1, y) (lo, hi + 1) (hull (x, y) (lo, hi + 2) acc))
    hull key (lo, hi) = Map.insertWith (\(a, b) (c, d) → (min a c, max b d)) key (lo, hi)
    fetch offset (lo, hi) = case worldColumn camera offset of
      Nothing → Right [FRun lo hi FAir]
      Just column → either (Left . QueryRefused) Right (columnFacts (pcQueryLimits config) facts column lo hi)

-- What evaluation accumulates: the faces to build, the cells evaluated and the
-- unavailable cells met.
data Layer = Layer
  { layerCells ∷ ![RawFace]
  , layerFaceCount ∷ !Int
  , layerLevels ∷ !Int
  , layerUnknownOwn ∷ ![(Offset, Integer, Integer)]
  , layerUnknownNear ∷ !(Map.Map Offset (Set.Set Integer))
  }

emptyLayer ∷ Layer
emptyLayer = Layer [] 0 0 [] Map.empty

-- A face selected for building, before its geometry is projected.
data RawFace = RawFace
  { rawOffset ∷ !Offset
  , rawLevel ∷ !Integer
  , rawTile ∷ !TileCoord
  , rawShape ∷ !ShapeId
  , rawMaterial ∷ !MaterialId
  , rawIndex ∷ !Int
  , rawFace ∷ !Face
  , rawRole ∷ !FaceRole
  }

isFlatShape ∷ ShapeId → Bool
isFlatShape shape = shapeIdValue shape == 0 || shapeIdValue shape == 15

-- Evaluate the cells of one candidate column.
evaluateCandidate ∷ CameraState → Integer → PlanLimits → Map.Map Offset [FRun] → Layer → Cand → Either PlanError Layer
evaluateCandidate camera clip limits runs layer (Cand x y lo hi)
  -- The levels this column would examine are known before any is examined.
  | layerLevels layer + Set.size levels > limitLevels limits = Left (PlanInsufficient LimitLevels)
  | otherwise =
      foldM cell layer {layerUnknownOwn = unknownOwn <> layerUnknownOwn layer, layerLevels = layerLevels layer + Set.size levels} (Set.toAscList levels)
  where
    facing = camFacing camera
    own = Map.findWithDefault [] (x, y) runs
    east = Map.findWithDefault [] (x + 1, y) runs
    south = Map.findWithDefault [] (x, y + 1) runs
    ownClipped = [r | r@(FRun a b _) ← own, b > lo, a <= hi]
    unknownOwn = [((x, y), max a lo, min b (hi + 1)) | FRun a b FUnknown ← ownClipped]
    levels = interesting lo hi own east south
    cell acc z = case (kindAt own z, tileOf z) of
      (FSolid material shape, Just tile) →
        let kindE = kindAt east z
            kindS = kindAt south z
            kindU = kindAt own (z + 1)
            (picked, wantE, wantS, wantU) = exposures facing clip z shape (kindE, kindS, kindU)
            raws =
              [ RawFace (x, y) z tile shape material index face role
              | (index, face, role) ← picked
              ]
            near =
              [((x + 1, y), z) | wantE]
                <> [((x, y + 1), z) | wantS]
                <> [((x, y), z + 1) | wantU]
         in if layerFaceCount acc + length raws > limitFaces limits
              then Left (PlanInsufficient LimitFaces)
              else
                Right
                  acc
                    { layerCells = reverse raws <> layerCells acc
                    , layerFaceCount = layerFaceCount acc + length raws
                    , layerUnknownNear = foldl' (\m (k, l) → Map.insertWith Set.union k (Set.singleton l) m) (layerUnknownNear acc) near
                    }
      _ → Right acc
    tileOf z = do
      column ← worldColumn camera (x, y)
      level ← either (const Nothing) Just (axisFromInteger z)
      pure (TileCoord (columnX column) (columnY column) level)

-- The levels of a window whose faces can differ from those of their
-- neighbours: run boundaries, and every level where a solid cell meets a
-- neighbour that is not an identical flat solid.
interesting ∷ Integer → Integer → [FRun] → [FRun] → [FRun] → Set.Set Integer
interesting lo hi own east south = Set.filter inside (Set.fromList (lo : hi : boundaries <> overlaps))
  where
    inside z = lo <= z && z <= hi
    boundaries = concat [[a - 1, a, b - 1, b] | runs ← [own, east, south], FRun a b _ ← runs, b > lo - 1, a <= hi + 1]
    overlaps =
      concat
        [ [max a c .. min b d - 1]
        | FRun a b (FSolid _ ownShape) ← own
        , b > lo
        , a <= hi
        , neighbour ← [east, south]
        , FRun c d nk ← neighbour
        , d > lo
        , c <= hi
        , not (isFlatShape ownShape && flatSolid nk)
        ]
        <> concat
          [ [max a lo .. min b (hi + 1) - 1]
          | FRun a b (FSolid _ ownShape) ← own
          , b > lo
          , a <= hi
          , not (isFlatShape ownShape)
          ]
    flatSolid (FSolid _ s) = isFlatShape s
    flatSolid _ = False

-- The faces of one cell that are exposed, and which neighbours were unavailable.
exposures ∷ ViewFacing → Integer → Integer → ShapeId → (FKind, FKind, FKind) → ([(Int, Face, FaceRole)], Bool, Bool, Bool)
exposures facing clip z shape (kindE, kindS, kindU) = (picked, wantE, wantS, wantU)
  where
    viewSolid = shapeSolid (viewShape facing shape)
    faces = zip [0 ∷ Int ..] (solidFaces viewSolid)
    visible face = nx + ny + 3 * nz > 0 where V3 nx ny nz = planeNormal (facePlane face)
    decisions = [(i, f, decide f) | (i, f) ← faces, visible f]
    picked = [(i, f, role) | (i, f, (Just role, _)) ← decisions]
    wantE = or [want | (_, f, (_, want)) ← decisions, faceKind f == WallFace East]
    wantS = or [want | (_, f, (_, want)) ← decisions, faceKind f == WallFace South]
    wantU = or [want | (_, f, (_, want)) ← decisions, faceKind f == TopFace]
    decide face = case faceKind face of
      TopFace
        | flatTop face →
            if z == clip
              then (Just (if kindU == FAir then RoleSurface else RoleCap), False)
              else case kindU of
                FAir → (Just RoleSurface, False)
                FSolid _ _ → (Nothing, False)
                FUnknown → (Nothing, True)
        | otherwise → (Just RoleSurface, False)
      WallFace East → wall face kindE West
      WallFace South → wall face kindS North
      _ → (Nothing, False)
    flatTop face = planeNormal (facePlane face) == V3 0 0 1 && planeOffset (facePlane face) == 1
    wall face neighbour opposite = case neighbour of
      FAir → (Just RoleSurface, False)
      FUnknown → (Nothing, True)
      FSolid _ other →
        let shown = not (covers face (opposingWalls (viewShape facing other) opposite))
         in (if shown then Just RoleSurface else Nothing, False)
    opposingWalls s side = [f | f ← solidFaces (shapeSolid s), faceKind f == WallFace side]

-- Whether the walls of the neighbour cover a wall: every vertex of the wall,
-- in the coordinates of the shared plane, lies in a neighbouring wall polygon.
covers ∷ Face → [Face] → Bool
covers face opposing = case opposing of
  [] → False
  (other : _) → case orient (map plane (faceVertices other)) of
    Nothing → False
    Just polygon → all (containsClosed polygon . plane) (faceVertices face)
  where
    plane (V3 a b c) = case faceKind face of
      WallFace East → (b, c)
      WallFace South → (a, c)
      _ → (a, b)

-- The geometry of a raw face in the relative frame.
data Built = Built
  { builtRaw ∷ !RawFace
  , builtPolygon ∷ ![P2]
  , builtMask ∷ ![P2]
  , builtQuad ∷ !Affine2
  , builtNormal ∷ !(Rational, Rational, Rational)
  , builtOffset ∷ !Rational
  , builtCanon ∷ !FaceRef
  }

builtOrder ∷ Built → OFace
builtOrder b = OFace (builtCanon b) (builtPolygon b) (builtNormal b) (builtOffset b)

buildFace ∷ Integer → RawFace → Either PlanError (Maybe Built)
buildFace ref raw = case faceKind face of
  TopFace → assemble (\(V3 a b _) → (a, b)) topPoint
  WallFace East → assemble (\(V3 _ b c) → (b, 1 - c)) (\(u, v) → V3 1 u (1 - v))
  WallFace South → assemble (\(V3 a _ c) → (a, 1 - c)) (\(u, v) → V3 u 1 (1 - v))
  _ → Right Nothing
  where
    face = rawFace raw
    (rx, ry) = rawOffset raw
    zrel = rawLevel raw - ref
    offsetOf (V3 a b c) = (fromInteger rx + a - 1 / 2, fromInteger ry + b - 1 / 2, fromInteger zrel + c)
    Plane (V3 nx ny nz) planeD = facePlane face
    topPoint (u, v) = V3 u v ((planeD - nx * u - ny * v) / nz)
    assemble maskOf point = do
      let screen = [isoProject (offsetOf v) | v ← faceVertices face]
          mask = map maskOf (faceVertices face)
          area = signedArea screen
      if area == 0
        then Right Nothing
        else do
          let (polygon, masked) = if area > 0 then (screen, mask) else (reverse screen, reverse mask)
              origin = isoProject (offsetOf (point (0, 0)))
              (ox, oy) = origin
              (ax, ay) = isoProject (offsetOf (point (1, 0)))
              (bx, by) = isoProject (offsetOf (point (0, 1)))
          quad ← quadOf (ax - ox) (ay - oy) (bx - ox) (by - oy) ox oy
          let relOffset = planeD + (nx * (fromInteger rx - 1 / 2) + ny * (fromInteger ry - 1 / 2) + nz * fromInteger zrel)
          pure
            ( Just
                Built
                  { builtRaw = raw
                  , builtPolygon = polygon
                  , builtMask = masked
                  , builtQuad = quad
                  , builtNormal = (nx, ny, nz)
                  , builtOffset = relOffset
                  , builtCanon = (rx, ry, zrel, rawIndex raw)
                  }
            )
    quadOf a b c d tx ty = do
      let floats = map rationalToFloat [a, b, c, d, tx, ty]
      case sequence floats of
        Just [fa, fb, fc, fd, ftx, fty] → Right (fromColumns (V2 fa fb) (V2 fc fd) (V2 ftx fty))
        _ → Left (Unrepresentable "a face transform")

-- Finish a built face into its output form.
finish ∷ Word32 → Built → PlannedFace
finish key built =
  PlannedFace
    { faceCell = rawTile raw
    , faceShape = rawShape raw
    , faceMaterial = rawMaterial raw
    , faceViewKind = faceKind (rawFace raw)
    , faceIndex = rawIndex raw
    , faceRole = rawRole raw
    , faceCellOrigin = isoProject (fromInteger cx - 1 / 2, fromInteger cy - 1 / 2, fromInteger cz)
    , facePolygon = builtPolygon built
    , faceMask = builtMask built
    , faceQuad = builtQuad built
    , faceBounds = let (a, b, c, d) = boundingBox (builtPolygon built) in Rect a b c d
    , faceDepthKey = key
    }
  where
    raw = builtRaw built
    (cx, cy, cz, _) = builtCanon built

-- The unavailable cells of a layer as intervals per offset, and as wants.
wantsOf ∷ CameraState → Layer → ([(Offset, Integer, Integer)], [(Column, Integer, Integer)])
wantsOf camera layer = (intervals, [(column, lo, hi) | (off, lo, hi) ← intervals, Just column ← [worldColumn camera off]])
  where
    near = [(off, lo, hi) | (off, levels) ← Map.toAscList (layerUnknownNear layer), (lo, hi) ← runsOf (Set.toAscList levels)]
    intervals = mergeIntervals (layerUnknownOwn layer <> near)
    runsOf [] = []
    runsOf (l : ls) = go l l ls
      where
        go a b (n : rest) | n == b + 1 = go a n rest
        go a b rest = (a, b + 1) : runsOf rest

mergeIntervals ∷ [(Offset, Integer, Integer)] → [(Offset, Integer, Integer)]
mergeIntervals items = concatMap collapse (Map.toAscList grouped)
  where
    grouped = Map.fromListWith (<>) [(off, [(lo, hi)]) | (off, lo, hi) ← items, lo < hi]
    collapse (off, ranges) = [(off, lo, hi) | (lo, hi) ← merge (sortOn fst ranges)]
    merge ((a, b) : (c, d) : rest)
      | c <= b = merge ((a, max b d) : rest)
    merge (x : rest) = x : merge rest
    merge [] = []

-- The render-world rectangle bounding the cells of a column interval.
cellsRect ∷ Integer → Offset → Integer → Integer → Rect
cellsRect ref (cx, cy) lo hi =
  Rect
    (48 * fromInteger (cx - cy - 1))
    (48 * fromInteger (cx - cy + 1))
    (24 * fromInteger (cx + cy - 1) - 16 * fromInteger (hi - ref))
    (24 * fromInteger (cx + cy + 1) - 16 * fromInteger (lo - ref))

-- The demand of the wants, within its bounds.
boundedDemand ∷ PlanLimits → [(Column, Integer, Integer)] → Either PlanError Demand
boundedDemand limits wants
  | length (demandChunks demand) > limitDemandChunks limits = Left (PlanInsufficient LimitDemandChunks)
  | demandIntervalCount demand > limitDemandIntervals limits = Left (PlanInsufficient LimitDemandIntervals)
  | any ((> limitRegionsPerChunk limits) . length . demandRegions) (demandChunks demand) = Left (PlanInsufficient LimitRegionsPerChunk)
  | otherwise = Right demand
  where
    demand = demandFrom [(chunkOfColumn column, lo, hi) | (column, lo, hi) ← wants]

-- | The demand for the bounded visible region and a horizontal margin of
-- chunks around it: the levels of the visible windows, within the band, that
-- the facts do not yet make ready. The region keys per chunk are bounded
-- independently of the number of columns. This is latest-value state; later
-- integration coalesces and admits it.
cameraDemand ∷ PlanRequest → TerrainFacts → Either PlanError Demand
cameraDemand request facts = do
  checkVersions request facts
  prepared ← prepare request
  let camera = requestCamera request
      config = requestConfig request
      limits = pcLimits config
      cands = prCands prepared
      windows =
        [ (chunkOfColumn column, lo, hi + 2)
        | Cand x y lo hi ← cands
        , Just column ← [worldColumn camera (x, y)]
        ]
      byChunk = Map.fromListWith hull [(key, (lo, hi)) | (key, lo, hi) ← windows]
      hull (a, b) (c, d) = (min a c, max b d)
      overall = case Map.elems byChunk of
        [] → Nothing
        ranges → Just (foldr1 hull ranges)
      margin = pcChunkMargin config
      -- Chunk coordinates are floor quotients of the supported axis range by 16:
      -- from -2^58 up to 2^58 - 1. The offsets are clipped to that range before
      -- they are generated, so no iteration is spent on a chunk that cannot exist.
      chunkLo = negate (2 ^ (58 ∷ Int)) ∷ Integer
      chunkHi = 2 ^ (58 ∷ Int) - 1 ∷ Integer
      ring (ChunkKey cx cy) =
        [ ChunkKey (fromInteger nx) (fromInteger ny)
        | nx ← [max chunkLo (toInteger cx - margin) .. min chunkHi (toInteger cx + margin)]
        , ny ← [max chunkLo (toInteger cy - margin) .. min chunkHi (toInteger cy + margin)]
        ]
      wantedFor keys = Map.fromList [(k, r) | k ← keys, Just r ← [Map.lookup k byChunk `orElse` overall]]
      orElse a b = maybe b Just a
  ringKeys ← collectRing (limitDemandChunks limits) (Map.keysSet byChunk) (concatMap ring (Map.keys byChunk))
  let wanted = wantedFor (Set.toAscList ringKeys)
      -- Levels outside the supported range hold nothing and are known air: they
      -- are never asked for.
      worldLo = negate (2 ^ (62 ∷ Int)) ∷ Integer
      worldHi = 2 ^ (62 ∷ Int) ∷ Integer
      unmet = [(key, a, b) | (key, (lo, hi)) ← Map.toAscList wanted, (a, b) ← unknownPieces (factsAvailability facts) key (max lo worldLo) (min hi worldHi)]
  let demand = demandFrom unmet
  if demandIntervalCount demand > limitDemandIntervals limits then Left (PlanInsufficient LimitDemandIntervals) else pure ()
  if any ((> limitRegionsPerChunk limits) . length . demandRegions) (demandChunks demand)
    then Left (PlanInsufficient LimitRegionsPerChunk)
    else pure demand

-- The visible chunks and the chunks of their margin, never more than the bound:
-- the first key past it is a refusal, found before the rest of a large margin is
-- generated.
collectRing ∷ Int → Set.Set ChunkKey → [ChunkKey] → Either PlanError (Set.Set ChunkKey)
collectRing limit visible = go visible'
  where
    visible' = visible
    go acc keys
      | Set.size acc > limit = Left (PlanInsufficient LimitDemandChunks)
      | otherwise = case keys of
          [] → Right acc
          (k : rest)
            | k `Set.member` acc → go acc rest
            | Set.size acc >= limit → Left (PlanInsufficient LimitDemandChunks)
            | otherwise → go (Set.insert k acc) rest
