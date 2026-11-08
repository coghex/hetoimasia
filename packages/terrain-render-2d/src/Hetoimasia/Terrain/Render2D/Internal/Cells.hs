{-# LANGUAGE MultiWayIf #-}

-- | The cell-quad planner's implementation (TRA-16). Hidden from clients: the
-- public face is "Hetoimasia.Terrain.Render2D.Cells", which exports the types
-- abstractly, and "Hetoimasia.Terrain.Render2D.CellPick", which answers from a
-- plan. See those modules for the contract; this one holds the constructors
-- they share.
module Hetoimasia.Terrain.Render2D.Internal.Cells
  ( -- * Configuration
    CellLimits (..)
  , CellConfig (..)
  , CellRequest (..)
  , CellInputs (..)

    -- * Identity
  , CellIdentity (..)

    -- * Quads
  , PartKind (..)
  , CellKey (..)
  , TargetRect (..)
  , CellQuad (..)

    -- * Pending and unresolved
  , PendSpan (..)
  , Envelope (..)
  , Unresolved (..)

    -- * The plan
  , Progress (..)
  , HaltReason (..)
  , CellDemand (..)
  , CellStats (..)
  , CellPlan (..)
  , CellError (..)
  , CellPrep (..)

    -- * Planning
  , startCells
  , stepCells
  , cellPlanOf
  , cellIdentityOf
  , unresolvedAhead
  , cellProgressOf
  , zeroDrawable
  ) where

import Control.Monad (unless, when)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Set as Set
import Data.Word (Word32, Word64)
import Hetoimasia.Math.Affine2 (Affine2, fromColumns)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Mapping (ViewMapping, viewportIsEmpty)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..))
import Hetoimasia.Render.TwoD.Snapshot (depthKeyLimit)
import Hetoimasia.Terrain.Cell (Column (..), MaterialId)
import Hetoimasia.Terrain.Coordinate
  ( AxisCoord
  , TileCoord (..)
  , axisFromInteger
  , axisValue
  )
import Hetoimasia.Terrain.MapBake.Catalog (Lookup (..), MapKey, lookupFor)
import Hetoimasia.Terrain.Query (QueryError, QueryLimits)
import Hetoimasia.Terrain.Render2D.Assets
import Hetoimasia.Terrain.Render2D.Camera
import Hetoimasia.Terrain.Render2D.Facts
import Hetoimasia.Terrain.Render2D.Knowledge
import Hetoimasia.Terrain.Render2D.Projection
import Hetoimasia.Terrain.Shape (ShapeId, ViewFacing, mkShapeId)

-- ---------------------------------------------------------------------------
-- Configuration

-- | The bounds on one plan and on one step. Each is checked before the work or
-- output it limits. Exceeding a plan-wide bound halts preparation with the
-- remainder explicitly unresolved; it never truncates and calls the result
-- complete.
data CellLimits = CellLimits
  { clStepCandidates ∷ !Int
  -- ^ Candidate columns one step examines (a step always examines at least one).
  , clStepLevels ∷ !Int
  -- ^ Cell levels one step evaluates, checked between columns.
  , clColumns ∷ !Int
  -- ^ Candidate columns a plan examines.
  , clLevels ∷ !Int
  -- ^ Cell levels a plan evaluates.
  , clInstances ∷ !Int
  -- ^ Instances a plan may hold, at most the 24-bit key space.
  , clPending ∷ !Int
  -- ^ Pending spans a plan retains.
  , clDemandChunks ∷ !Int
  -- ^ Chunks one demand lists.
  , clDemandIntervals ∷ !Int
  -- ^ Intervals one demand lists.
  , clRegionsPerChunk ∷ !Int
  -- ^ Vertical regions one demand lists for a chunk.
  }
  deriving stock (Eq, Show)

-- | The visibility band, margin, prefetch margin, query bounds and limits.
data CellConfig = CellConfig
  { ccDepth ∷ !Integer
  -- ^ Levels visible below the clip level, at most 250.
  , ccMargin ∷ !Rational
  -- ^ Whole render-world pixels of slack around the viewport.
  , ccChunkMargin ∷ !Integer
  -- ^ Horizontal prefetch margin in chunks.
  , ccQueryLimits ∷ !QueryLimits
  , ccLimits ∷ !CellLimits
  }
  deriving stock (Eq, Show)

-- | One coherent request.
data CellRequest = CellRequest
  { crVersions ∷ !Versions
  , crCamera ∷ !CameraState
  , crSetup ∷ !ViewSetup
  , crConfig ∷ !CellConfig
  }

-- | Everything one plan is a function of: the request, the terrain facts, the
-- supplied knowledge and the adopted assets.
data CellInputs = CellInputs
  { inputsRequest ∷ !CellRequest
  , inputsFacts ∷ !TerrainFacts
  , inputsKnowledge ∷ !Knowledge
  , inputsAssets ∷ !AssetSnapshot
  }

-- ---------------------------------------------------------------------------
-- Identity

-- | What a plan was built from. Constructed only by the planner, so a client
-- cannot forge or edit one; two values are equal exactly when every part is.
data CellIdentity = CellIdentity
  { idVersions ∷ !Versions
  , idKnowledge ∷ !Word64
  , idCameraRevision ∷ !Word64
  , idAnchor ∷ !(AxisCoord, AxisCoord)
  , idFrac ∷ !(Rational, Rational)
  , idReference ∷ !Integer
  , idZoom ∷ !Float
  , idFacing ∷ !ViewFacing
  , idCut ∷ !AxisCoord
  , idSetup ∷ !ViewSetup
  , idAssets ∷ !AssetIdentity
  , idConfig ∷ !CellConfig
  }
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Quads

-- | Which part of a cell a quad is.
data PartKind
  = -- | A whole known cell: the ordinary shape map and the material colour.
    PartOrdinary
  | -- | The generic blank fog: a whole undiscovered cell, or the cover of a
    -- mixed cell's undiscovered empty component.
    PartFog
  | -- | The known solid of a mixed cell.
    PartKnown
  deriving stock (Eq, Ord, Show)

-- | The exact far-to-near key of a quad: @(viewX + viewY, z, viewX, viewY)@ of
-- its cell in the rotated view frame, then the fixed part order (fog before
-- known material). All integers; no floating key exists anywhere.
data CellKey = CellKey !Integer !Integer !Integer !Integer !Int
  deriving stock (Eq, Ord, Show)

-- | A rectangle of target (framebuffer) pixels: left, top, right, bottom.
data TargetRect = TargetRect !Rational !Rational !Rational !Rational
  deriving stock (Eq, Show)

-- | One planned instance: a full 96 x 64 canvas.
data CellQuad = CellQuad
  { cqPart ∷ !PartKind
  , cqCell ∷ !(Maybe TileCoord)
  -- ^ The exact authored tile of a known part; 'Nothing' for fog, which holds
  -- no coordinate, material or shape.
  , cqMaterial ∷ !(Maybe MaterialId)
  , cqColour ∷ !ColourRef
  , cqMap ∷ !MapKey
  , cqKey ∷ !CellKey
  , cqDepthKey ∷ !Word32
  -- ^ Distinct within the plan, below the key space; larger is nearer.
  , cqOrigin ∷ !(Integer, Integer)
  -- ^ The render-world projection of the cell's own corner @(0, 0, 0)@; the
  -- canvas's top-left is 48 left and 16 above it.
  , cqTransform ∷ !Affine2
  -- ^ The unit square's image in render-world pixels.
  , cqTarget ∷ !TargetRect
  -- ^ The quad as drawn in the target.
  }
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Pending and unresolved

-- | A stretch of one column whose terrain or retained knowledge is not
-- available. 'pendKey' is the exact key of its nearest possible quad and
-- 'pendTarget' a conservative target rectangle of everything it could draw.
data PendSpan = PendSpan
  { pendColumn ∷ !(Maybe Column)
  , pendOffset ∷ !(Integer, Integer)
  , pendLo ∷ !Integer
  , pendHi ∷ !Integer
  , pendKey ∷ !CellKey
  , pendTarget ∷ !TargetRect
  }
  deriving stock (Eq, Show)

-- | The fixed facts of a view's candidate envelope, in the relative frame.
data Envelope = Envelope
  { envURange ∷ !(Integer, Integer)
  , envVRange ∷ !(Integer, Integer)
  , envRect ∷ !Rect
  , envZRel ∷ !(Integer, Integer)
  -- ^ The band, relative to the reference elevation.
  , envRef ∷ !Integer
  , envClip ∷ !Integer
  }
  deriving stock (Eq, Show)

-- | The candidate columns not yet processed: rows @v@ (view @x + y@) descending,
-- then @u@ ascending, from this cursor.
data Unresolved = Unresolved
  { unrEnvelope ∷ !Envelope
  , unrCursor ∷ !(Integer, Integer)
  -- ^ The next @(v, u)@.
  }
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- The plan

-- | How far preparation has come.
data Progress
  = -- | Every candidate was processed: no footprint is unresolved.
    Settled
  | -- | More steps will make progress under the same limits.
    Working
  | -- | A plan-wide bound stopped it; the rest is unresolved and stays so.
    Halted !HaltReason
  deriving stock (Eq, Show)

-- | The plan-wide bound that halted preparation.
data HaltReason
  = HaltColumns
  | HaltLevels
  | HaltInstances
  | HaltPending
  deriving stock (Eq, Show)

-- | What is missing, visible work before prefetch.
data CellDemand = CellDemand
  { cdVisible ∷ !Demand
  -- ^ What the processed part of the projected viewport and band needs.
  , cdPrefetch ∷ !Demand
  -- ^ The horizontal margin around it; empty until the visible work is settled
  -- and always within what the visible demand left of each bound.
  , cdTruncated ∷ !Bool
  -- ^ A demand bound cut a listing short: the plan is not complete.
  }
  deriving stock (Eq, Show)

-- | Counts of the work a plan did.
data CellStats = CellStats
  { cellStatColumns ∷ !Int
  , cellStatLevels ∷ !Int
  , cellStatInstances ∷ !Int
  , cellStatPending ∷ !Int
  , cellStatSteps ∷ !Int
  }
  deriving stock (Eq, Show)

-- | An immutable plan. The constructor is private.
data CellPlan = CellPlan
  { cpIdentity ∷ !CellIdentity
  , cpView ∷ !RenderView
  , cpAssets ∷ !AssetSnapshot
  , cpQuads ∷ ![CellQuad]
  -- ^ Ascending by key: far to near.
  , cpPendings ∷ ![PendSpan]
  , cpUnresolved ∷ !(Maybe Unresolved)
  , cpProgress ∷ !Progress
  , cpDemand ∷ !CellDemand
  , cpBounds ∷ !(Maybe Rect)
  , cpUsed ∷ !(Set.Set AssetKey)
  , cpStats ∷ !CellStats
  }

-- | Why a plan, a step or a continuation was refused.
data CellError
  = -- | The request's versions and the facts' versions differ.
    CellMixedVersions !Versions !Versions
  | -- | The knowledge or the assets are not the ones the continuation was
    -- started with, or the request changed: obsolete work is never resumed.
    CellStaleContinuation
  | -- | The view or camera cannot be built.
    CellInvalidView !ProjectionError
  | -- | The configuration is unusable.
    CellInvalidConfig
  | -- | The snap view's scale would move adjacent quads apart.
    CellPixelSnapUnsupported !Float
  | -- | A column query was refused.
    CellQueryRefused !QueryError
  | -- | A material the terrain shows has no colour in the adopted assets.
    CellMissingMaterialColour !MaterialId
  | -- | Knowledge says a solid is known where the terrain holds air.
    CellInconsistentKnowledge !Column !Integer
  | -- | A value could not be represented in the target.
    CellUnrepresentable !String
  deriving stock (Eq, Show)

-- | The resumable state of preparation. The constructor is private.
data CellPrep = CellPrep
  { prIdentity ∷ !CellIdentity
  , prView ∷ !RenderView
  , prEnvelope ∷ !(Maybe Envelope)
  , prCursor ∷ !(Maybe (Integer, Integer))
  , prHalt ∷ !(Maybe HaltReason)
  , prRaw ∷ ![RawQuad]
  , prPending ∷ ![PendSpan]
  , prColumns ∷ !Int
  , prLevels ∷ !Int
  , prCount ∷ !Int
  , prPendCount ∷ !Int
  , prSteps ∷ !Int
  , prChunks ∷ !(Map.Map ChunkKey (Integer, Integer))
  , prUsed ∷ !(Set.Set AssetKey)
  }

-- A quad before it is ranked.
data RawQuad = RawQuad
  { rawPart ∷ !PartKind
  , rawTile ∷ !(Maybe TileCoord)
  , rawMaterial ∷ !(Maybe MaterialId)
  , rawColour ∷ !ColourRef
  , rawMap ∷ !MapKey
  , rawKey ∷ !CellKey
  , rawOrigin ∷ !(Integer, Integer)
  , rawTransform ∷ !Affine2
  , rawTarget ∷ !TargetRect
  }

-- ---------------------------------------------------------------------------
-- Starting

type Offset = (Integer, Integer)

-- | The identity the inputs would give a plan, or why they are unusable.
cellIdentityOf ∷ CellInputs → Either CellError CellIdentity
cellIdentityOf inputs = do
  let request = inputsRequest inputs
      camera = crCamera request
      config = crConfig request
  when (crVersions request /= factsVersions (inputsFacts inputs)) $
    Left (CellMixedVersions (crVersions request) (factsVersions (inputsFacts inputs)))
  unless (validConfig config) (Left CellInvalidConfig)
  pure
    CellIdentity
      { idVersions = crVersions request
      , idKnowledge = knowledgeRevision (inputsKnowledge inputs)
      , idCameraRevision = camRevision camera
      , idAnchor = (camAnchorX camera, camAnchorY camera)
      , idFrac = camFrac camera
      , idReference = camRef camera
      , idZoom = camZoom camera
      , idFacing = camFacing camera
      , idCut = camClip camera
      , idSetup = crSetup request
      , idAssets = assetIdentity (inputsAssets inputs)
      , idConfig = config
      }

validConfig ∷ CellConfig → Bool
validConfig config =
  ccDepth config >= 0
    && ccDepth config <= maxVisibleDepth
    && ccMargin config >= 0
    && ccChunkMargin config >= 0
    && all
      (>= 0)
      [ clStepCandidates l
      , clStepLevels l
      , clColumns l
      , clLevels l
      , clInstances l
      , clPending l
      , clDemandChunks l
      , clDemandIntervals l
      , clRegionsPerChunk l
      ]
    && clInstances l <= fromIntegral depthKeyLimit
  where
    l = ccLimits config

-- The approved cap of levels visible below the clip level.
maxVisibleDepth ∷ Integer
maxVisibleDepth = 250

-- | A target that draws nothing: an empty viewport, or a logical or framebuffer
-- extent with a zero side.
zeroDrawable ∷ ViewSetup → Bool
zeroDrawable setup =
  viewportIsEmpty (setupViewport setup)
    || any (<= 0) [pixelWidth logical, pixelHeight logical, pixelWidth framebuffer, pixelHeight framebuffer]
  where
    logical = metricsLogical (setupMetrics setup)
    framebuffer = metricsFramebuffer (setupMetrics setup)

-- | Fix everything the request determines before any fact is read, and begin
-- preparation. Nothing is read from the terrain here.
startCells ∷ CellInputs → Either CellError CellPrep
startCells inputs = do
  identity ← cellIdentityOf inputs
  let request = inputsRequest inputs
      camera = crCamera request
      config = crConfig request
  view ←
    either (Left . CellInvalidView) Right $
      mkRenderView (crSetup request) (camZoom camera) (camFacing camera) (camFrac camera)
  let ref = camRef camera
      clip = toInteger (axisValue (camClip camera))
      bandLo = clip - ccDepth config
  envelope ←
    if zeroDrawable (crSetup request) || bandLo > clip
      then pure Nothing
      else do
        when (settingPixelSnap (setupSettings (crSetup request)) && not (snapCompatible view)) $
          Left (CellPixelSnapUnsupported (viewScale view))
        rect ← maybe (Left (CellUnrepresentable "the visible rectangle")) Right (visibleRect (ccMargin config) view)
        pure (Just (envelopeOf rect ref clip bandLo))
  pure
    CellPrep
      { prIdentity = identity
      , prView = view
      , prEnvelope = envelope
      , prCursor = envelope >>= firstCursor
      , prHalt = Nothing
      , prRaw = []
      , prPending = []
      , prColumns = 0
      , prLevels = 0
      , prCount = 0
      , prPendCount = 0
      , prSteps = 0
      , prChunks = Map.empty
      , prUsed = Set.empty
      }

-- The envelope of candidate columns. The column of view offset @(rx, ry)@ has
-- @u = rx - ry@ and @v = rx + ry@; the full 96 x 64 canvas of its level @z@
-- (relative to the reference) spans x in @[48u - 48, 48u + 48]@ and y in
-- @[24v - 40 - 16z, 24v + 24 - 16z]@, so the ranges below enclose every canvas
-- that can touch the padded visible rectangle.
envelopeOf ∷ Rect → Integer → Integer → Integer → Envelope
envelopeOf rect@(Rect x1 x2 y1 y2) ref clip bandLo =
  Envelope
    { envURange = (uLo, uHi)
    , envVRange = (vLo, vHi)
    , envRect = rect
    , envZRel = (zLoRel, zHiRel)
    , envRef = ref
    , envClip = clip
    }
  where
    zLoRel = bandLo - ref
    zHiRel = clip - ref
    uLo = ceiling (x1 / 48) - 1
    uHi = floor (x2 / 48) + 1
    vLo = ceiling ((y1 + 16 * fromInteger zLoRel) / 24) - 1
    vHi = floor ((y2 + 16 * fromInteger (zHiRel + 1)) / 24) + 1

-- The first cursor: the greatest row, its first column of matching parity.
firstCursor ∷ Envelope → Maybe (Integer, Integer)
firstCursor env
  | vHi < vLo || uHi < uLo = Nothing
  | otherwise = settle (vHi, uLo)
  where
    (uLo, uHi) = envURange env
    (vLo, vHi) = envVRange env
    settle (v, u)
      | v < vLo = Nothing
      | u > uHi = settle (v - 1, uLo)
      | even (u + v) = Just (v, u)
      | otherwise = settle (v, u + 1)

-- The cursor after one examined column.
nextCursor ∷ Envelope → (Integer, Integer) → Maybe (Integer, Integer)
nextCursor env (v, u)
  | u + 2 <= uHi = Just (v, u + 2)
  | v - 1 < vLo = Nothing
  | otherwise = settle (v - 1, uLo)
  where
    (uLo, uHi) = envURange env
    (vLo, _) = envVRange env
    settle (v', u')
      | v' < vLo = Nothing
      | even (u' + v') = if u' <= uHi then Just (v', u') else settle (v' - 1, uLo)
      | otherwise = settle (v', u' + 1)

-- ---------------------------------------------------------------------------
-- Stepping

-- | Examine at most the step bounds' worth of candidate columns and levels,
-- nearest row first. A continuation made under other inputs is refused, so
-- superseded work can never become current. Stepping a settled or halted
-- preparation changes nothing.
stepCells ∷ CellInputs → CellPrep → Either CellError CellPrep
stepCells inputs prep = do
  identity ← cellIdentityOf inputs
  when (identity /= prIdentity prep) (Left CellStaleContinuation)
  case (prHalt prep, prCursor prep, prEnvelope prep) of
    (Nothing, Just cursor, Just env) →
      loop (ccLimits (idConfig identity)) env cursor (0 ∷ Int) (0 ∷ Int) prep {prSteps = prSteps prep + 1}
    _ → Right prep
  where
    loop limits env cursor scanned levelsDone st
      | scanned >= max 1 (clStepCandidates limits) = Right st {prCursor = Just cursor}
      | scanned > 0 && levelsDone >= clStepLevels limits = Right st {prCursor = Just cursor}
      | otherwise = do
          result ← evaluateColumn inputs st env cursor
          case result of
            Left halted → Right st {prCursor = Just cursor, prHalt = Just halted}
            Right (st', levels) → case nextCursor env cursor of
              Nothing → Right st' {prCursor = Nothing}
              Just next → loop limits env next (scanned + 1) (levelsDone + levels) st'

-- ---------------------------------------------------------------------------
-- One column

data CState
  = SAir
  | SFog
  | SPend
  | SOrd !MaterialId !ShapeId
  | SMix !MaterialId !ShapeId
  deriving stock (Eq, Show)

data SRun = SRun !Integer !Integer !CState
  deriving stock (Eq, Show)

-- Evaluate the column at a cursor into the state, or report the bound it hit.
-- A column is atomic: it is taken whole or not at all, so the parts of a mixed
-- cell are never split by a bound.
evaluateColumn ∷ CellInputs → CellPrep → Envelope → (Integer, Integer) → Either CellError (Either HaltReason (CellPrep, Int))
evaluateColumn inputs st env (v, u)
  | lo > hi = Right (Right (st, 0))
  | prColumns st + 1 > clColumns limits = Right (Left HaltColumns)
  | otherwise = do
      -- Own states one level above the window (what covers its top), the
      -- columns nearer to the camera over the window itself.
      own ← statesOf inputs camera (rx, ry) lo (min (hi + 2) (clip + 1))
      east ← statesOf inputs camera (rx + 1, ry) lo (min (hi + 1) (clip + 1))
      south ← statesOf inputs camera (rx, ry + 1) lo (min (hi + 1) (clip + 1))
      let opaque = opaqueState (inputsAssets inputs) facing
          ownWindow = [SRun a (min b (hi + 1)) s | SRun a b s ← own, a <= hi]
          hidden =
            intersectI
              (opaqueIntervals opaque east)
              ( intersectI
                  (opaqueIntervals opaque south)
                  [(a - 1, b - 1) | (a, b) ← opaqueIntervals opaque own]
              )
          visible = [(z, s) | SRun a b s ← ownWindow, emits s, (x, y) ← subtractI [(a, b)] hidden, z ← [x .. y - 1]]
          pendings = [(a, b) | SRun a b SPend ← ownWindow]
          levelsHere = length visible + length ownWindow
      quads ← concat <$> traverse (partsOf inputs st env (rx, ry)) visible
      spans ← traverse (uncurry (pendSpanOf (prView st) env column (rx, ry))) pendings
      pure $
        if
          | prLevels st + levelsHere > clLevels limits → Left HaltLevels
          | prCount st + length quads > clInstances limits → Left HaltInstances
          | prPendCount st + length spans > clPending limits → Left HaltPending
          | otherwise →
              Right
                ( st
                    { prRaw = reverse quads <> prRaw st
                    , prPending = reverse spans <> prPending st
                    , prColumns = prColumns st + 1
                    , prLevels = prLevels st + levelsHere
                    , prCount = prCount st + length quads
                    , prPendCount = prPendCount st + length spans
                    , prChunks = case column of
                        Just c → Map.insertWith (\(a, b) (c', d) → (min a c', max b d)) (chunkOfColumn c) (lo, hi + 2) (prChunks st)
                        Nothing → prChunks st
                    , prUsed = Set.union (Set.fromList (concat [[AssetColour (rawColour q), AssetMap (rawMap q)] | q ← quads])) (prUsed st)
                    }
                , levelsHere
                )
  where
    rx = (u + v) `div` 2
    ry = (v - u) `div` 2
    request = inputsRequest inputs
    camera = crCamera request
    facing = camFacing camera
    limits = ccLimits (crConfig request)
    (zLoRel, zHiRel) = envZRel env
    ref = envRef env
    clip = envClip env
    y1 = rectMinY (envRect env)
    y2 = rectMaxY (envRect env)
    lo = max zLoRel (ceiling ((24 * fromInteger (v - 1) - 16 - y2) / 16)) + ref
    hi = min zHiRel (floor ((24 * fromInteger (v + 1) - y1) / 16)) + ref
    column = worldColumn camera (rx, ry)

emits ∷ CState → Bool
emits SFog = True
emits (SOrd _ _) = True
emits (SMix _ _) = True
emits _ = False

-- Whether a state's drawn coverage is proved to be the whole hexagon, so that
-- the cells behind it are hidden. A colour with a hole proves nothing, and a
-- mixed cell is conservatively not a proof.
opaqueState ∷ AssetSnapshot → ViewFacing → CState → Bool
opaqueState assets _ SFog = colourCoversHexagon assets ColourBlank
opaqueState assets facing (SOrd material shape) =
  mapCoversHexagon assets (lookupOrdinary (lookupFor facing shape)) && colourCoversHexagon assets (ColourMaterial material)
opaqueState _ _ _ = False

opaqueIntervals ∷ (CState → Bool) → [SRun] → [(Integer, Integer)]
opaqueIntervals opaque runs = mergeI [(a, b) | SRun a b s ← runs, opaque s]

-- Sorted, disjoint, half-open interval lists.
mergeI ∷ [(Integer, Integer)] → [(Integer, Integer)]
mergeI = go . sortOn fst . filter (\(a, b) → a < b)
  where
    go ((a, b) : (c, d) : rest)
      | c <= b = go ((a, max b d) : rest)
    go (x : rest) = x : go rest
    go [] = []

intersectI ∷ [(Integer, Integer)] → [(Integer, Integer)] → [(Integer, Integer)]
intersectI xs@((a, b) : xs') ys@((c, d) : ys')
  | lo < hi = (lo, hi) : rest
  | otherwise = rest
  where
    lo = max a c
    hi = min b d
    rest = if b < d then intersectI xs' ys else intersectI xs ys'
    _ = (xs, ys)
intersectI _ _ = []

subtractI ∷ [(Integer, Integer)] → [(Integer, Integer)] → [(Integer, Integer)]
subtractI = foldl' cut
  where
    cut intervals (c, d) = concat [piece a b | (a, b) ← intervals]
      where
        piece a b
          | d <= a || b <= c = [(a, b)]
          | otherwise = [(a, c) | a < c] <> [(d, b) | d < b]

-- The view-frame offset's world column, or nothing outside the range.
worldColumn ∷ CameraState → Offset → Maybe Column
worldColumn camera (rx, ry) = do
  let (dx, dy) = worldOffset (camFacing camera) (rx, ry)
  x ← either (const Nothing) Just (axisFromInteger (toInteger (axisValue (camAnchorX camera)) + dx))
  y ← either (const Nothing) Just (axisFromInteger (toInteger (axisValue (camAnchorY camera)) + dy))
  pure (Column x y)

-- The states of one column over @[lo, hi)@, covering it exactly. Knowledge
-- decides first; terrain is read only where knowledge does not conceal it.
statesOf ∷ CellInputs → CameraState → Offset → Integer → Integer → Either CellError [SRun]
statesOf inputs camera offset lo hi
  | lo >= hi = Right []
  | otherwise = case worldColumn camera offset of
      Nothing → Right [SRun lo hi SAir]
      Just column → coalesceStates . concat <$> traverse (inWorld column) bounded
  where
    facing = camFacing camera
    config = crConfig (inputsRequest inputs)
    worldLo = negate (2 ^ (62 ∷ Int))
    worldHi = 2 ^ (62 ∷ Int)
    -- Levels outside the supported range hold nothing: known air, whatever
    -- knowledge says.
    bounded =
      [(lo, min hi worldLo, False) | lo < worldLo]
        <> [(max lo worldLo, min hi worldHi, True) | max lo worldLo < min hi worldHi]
        <> [(max lo worldHi, hi, False) | hi > worldHi]
    inWorld _ (a, b, False) = Right [SRun a b SAir | a < b]
    inWorld column (a, b, True) = concat <$> traverse (known column) (knowledgeRuns (inputsKnowledge inputs) column a b)
    known _ (KnowRun a b CellUndiscovered) = Right [SRun a b SFog]
    known _ (KnowRun a b CellPending) = Right [SRun a b SPend]
    known column (KnowRun a b state) = do
      runs ← either (Left . CellQueryRefused) Right (columnFacts (ccQueryLimits config) (inputsFacts inputs) column a b)
      traverse (classify column state) runs
    classify _ _ (FRun a b FUnknown) = Right (SRun a b SPend)
    classify _ CellDiscovered (FRun a b FAir) = Right (SRun a b SAir)
    classify column _ (FRun a _ FAir) = Left (CellInconsistentKnowledge column a)
    classify _ CellDiscovered (FRun a b (FSolid m s)) = Right (SRun a b (SOrd m s))
    classify _ _ (FRun a b (FSolid m s)) =
      Right (SRun a b (if isJust (lookupMixed (lookupFor facing s)) then SMix m s else SOrd m s))

coalesceStates ∷ [SRun] → [SRun]
coalesceStates (SRun a b s : SRun c d t : rest)
  | b == c && s == t = coalesceStates (SRun a d s : rest)
coalesceStates (x : rest) = x : coalesceStates rest
coalesceStates [] = []

-- ---------------------------------------------------------------------------
-- Quads

-- The shape whose ordinary map is the generic full-cell fog: identity 0.
fogShape ∷ ShapeId
fogShape = either (error . ("Hetoimasia.Terrain.Render2D.Cells: " <>) . show) id (mkShapeId 0)

-- The quads of one cell level.
partsOf ∷ CellInputs → CellPrep → Envelope → Offset → (Integer, CState) → Either CellError [RawQuad]
partsOf inputs st env (rx, ry) (z, state) = case state of
  SFog → one PartFog Nothing ColourBlank (lookupFullFog (lookupFor facing fogShape)) 0
  SOrd m shape → do
    needColour m
    one PartOrdinary (Just m) (ColourMaterial m) (lookupOrdinary (lookupFor facing shape)) 1
  SMix m shape → do
    needColour m
    case lookupMixed (lookupFor facing shape) of
      Nothing → one PartOrdinary (Just m) (ColourMaterial m) (lookupOrdinary (lookupFor facing shape)) 1
      Just (knownKey, coverKey) → do
        cover ← quad PartFog Nothing ColourBlank coverKey 0
        known ← quad PartKnown (Just m) (ColourMaterial m) knownKey 1
        -- Fog first, then the known material, in the fixed part order.
        pure [cover, known]
  _ → Right []
  where
    camera = crCamera (inputsRequest inputs)
    facing = camFacing camera
    one part material colour mapKey order = (: []) <$> quad part material colour mapKey order
    origin = (48 * (rx - ry), 24 * (rx + ry - 1) - 16 * (z - envRef env))
    needColour m = unless (isJust (colourCoverage (inputsAssets inputs) (ColourMaterial m))) (Left (CellMissingMaterialColour m))
    tile = do
      column ← worldColumn camera (rx, ry)
      level ← either (const Nothing) Just (axisFromInteger z)
      pure (TileCoord (columnX column) (columnY column) level)
    quad part material colour mapKey order = do
      let (ox, oy) = origin
      transform ← transformOf (ox - 48) (oy - 16) 96 64
      target ← targetOf (rvMapping (prView st)) transform
      pure
        RawQuad
          { rawPart = part
          , rawTile = if part == PartFog then Nothing else tile
          , rawMaterial = if part == PartFog then Nothing else material
          , rawColour = colour
          , rawMap = mapKey
          , rawKey = CellKey (rx + ry) z rx ry order
          , rawOrigin = origin
          , rawTransform = transform
          , rawTarget = target
          }

-- The instance transform of an axis-aligned rectangle of render-world pixels,
-- rounded once to 32 bits as the planner's other quads are.
transformOf ∷ Integer → Integer → Integer → Integer → Either CellError Affine2
transformOf x y w h = case traverse (rationalToFloat . fromInteger) [w, h, x, y] of
  Just [fw, fh, fx, fy] → Right (fromColumns (V2 fw 0) (V2 0 fh) (V2 fx fy))
  _ → Left (CellUnrepresentable "a cell transform")

-- The rectangle a transform covers in the target, as drawing places it.
targetOf ∷ ViewMapping → Affine2 → Either CellError TargetRect
targetOf mapping transform = case drawnOutline mapping transform [(0, 0), (1, 0), (1, 1), (0, 1)] of
  Nothing → Left (CellUnrepresentable "a cell in the target")
  Just corners →
    let xs = map fst corners
        ys = map snd corners
     in if aligned corners
          then Right (TargetRect (minimum xs) (minimum ys) (maximum xs) (maximum ys))
          else Left (CellUnrepresentable "a cell that is not axis-aligned in the target")
  where
    aligned [(ax, ay), (bx, by), (cx, cy), (dx, dy)] = ay == by && bx == cx && cy == dy && dx == ax
    aligned _ = False

-- The pending span of a window of one column.
pendSpanOf ∷ RenderView → Envelope → Maybe Column → Offset → Integer → Integer → Either CellError PendSpan
pendSpanOf view env column (rx, ry) lo hi = do
  let ref = envRef env
      x0 = 48 * (rx - ry) - 48
      top = 24 * (rx + ry - 1) - 16 * (hi - 1 - ref) - 16
      height = 64 + 16 * (hi - 1 - lo)
  transform ← transformOf x0 top 96 height
  TargetRect l t r b ← targetOf (rvMapping view) transform
  -- One device pixel of slack: a span is a conservative footprint, and a
  -- snapped view moves the quad's origin by up to half a pixel.
  pure
    PendSpan
      { pendColumn = column
      , pendOffset = (rx, ry)
      , pendLo = lo
      , pendHi = hi
      , pendKey = CellKey (rx + ry) (hi - 1) rx ry 1
      , pendTarget = TargetRect (l - 1) (t - 1) (r + 1) (b + 1)
      }

-- ---------------------------------------------------------------------------
-- The plan

-- | The plan the preparation has reached, publishable at any point: the
-- processed part exactly, and everything else pending or unresolved.
cellPlanOf ∷ CellInputs → CellPrep → Either CellError CellPlan
cellPlanOf inputs prep = do
  identity ← cellIdentityOf inputs
  when (identity /= prIdentity prep) (Left CellStaleContinuation)
  let request = inputsRequest inputs
      config = crConfig request
      limits = ccLimits config
      raw = sortOn rawKey (prRaw prep)
      quads =
        [ CellQuad
            { cqPart = rawPart r
            , cqCell = rawTile r
            , cqMaterial = rawMaterial r
            , cqColour = rawColour r
            , cqMap = rawMap r
            , cqKey = rawKey r
            , cqDepthKey = fromIntegral rank
            , cqOrigin = rawOrigin r
            , cqTransform = rawTransform r
            , cqTarget = rawTarget r
            }
        | (rank, r) ← zip [0 ∷ Int ..] raw
        ]
      unresolved = case (prEnvelope prep, prCursor prep) of
        (Just env, Just cursor) → Just (Unresolved env cursor)
        _ → Nothing
      progress = case (prHalt prep, unresolved) of
        (Just reason, _) → Halted reason
        (Nothing, Nothing) → Settled
        (Nothing, Just _) → Working
      pendings = sortOn pendKey (prPending prep)
      (visible, visibleCut) = boundedDemand limits [(c, pendLo s, pendHi s) | s ← pendings, Just c ← [pendColumn s]]
      (prefetch, prefetchCut) =
        if progress == Settled && not visibleCut
          then prefetchDemand config (factsAvailability (inputsFacts inputs)) visible (prChunks prep)
          else (emptyDemand, False)
      bounds = case raw of
        [] → Nothing
        _ →
          Just
            ( Rect
                (fromInteger (minimum [ox - 48 | r ← raw, let (ox, _) = rawOrigin r]))
                (fromInteger (maximum [ox + 48 | r ← raw, let (ox, _) = rawOrigin r]))
                (fromInteger (minimum [oy - 16 | r ← raw, let (_, oy) = rawOrigin r]))
                (fromInteger (maximum [oy + 48 | r ← raw, let (_, oy) = rawOrigin r]))
            )
  pure
    CellPlan
      { cpIdentity = identity
      , cpView = prView prep
      , cpAssets = inputsAssets inputs
      , cpQuads = quads
      , cpPendings = pendings
      , cpUnresolved = unresolved
      , cpProgress = progress
      , cpDemand = CellDemand {cdVisible = visible, cdPrefetch = prefetch, cdTruncated = visibleCut || prefetchCut}
      , cpBounds = bounds
      , cpUsed = prUsed prep
      , cpStats =
          CellStats
            { cellStatColumns = prColumns prep
            , cellStatLevels = prLevels prep
            , cellStatInstances = length quads
            , cellStatPending = length pendings
            , cellStatSteps = prSteps prep
            }
      }

-- The demand of the wants within the demand bounds, in ascending chunk order,
-- and whether a bound cut anything.
boundedDemand ∷ CellLimits → [(Column, Integer, Integer)] → (Demand, Bool)
boundedDemand limits wants = fitDemand limits (demandChunks (demandFrom [(chunkOfColumn c, lo, hi) | (c, lo, hi) ← wants]))

fitDemand ∷ CellLimits → [ChunkDemand] → (Demand, Bool)
fitDemand limits = go [] (0 ∷ Int) False
  where
    go acc _ cut [] = (Demand (reverse acc), cut)
    go acc intervals cut (chunk : rest)
      | length acc >= clDemandChunks limits = (Demand (reverse acc), True)
      | length (demandRegions chunk) > clRegionsPerChunk limits = go acc intervals True rest
      | intervals + length (demandIntervals chunk) > clDemandIntervals limits = go acc intervals True rest
      | otherwise = go (chunk : acc) (intervals + length (demandIntervals chunk)) cut rest

-- The horizontal margin around the processed chunks: the levels of their
-- windows the facts do not make ready, in the chunks that are not themselves
-- visible. It is bounded by what the visible demand left of each bound, so it
-- can never take capacity visible work needs.
prefetchDemand ∷ CellConfig → Availability → Demand → Map.Map ChunkKey (Integer, Integer) → (Demand, Bool)
prefetchDemand config availability visible windows
  | ccChunkMargin config == 0 = (emptyDemand, False)
  | otherwise = case collectRing room (Map.keysSet windows) (concatMap ring (Map.keys windows)) of
      Nothing → (emptyDemand, True)
      Just keys →
        let unmet =
              [ (key, a, b)
              | key ← Set.toAscList keys
              , (a, b) ← unknownPieces availability key (max lo worldLo) (min hi worldHi)
              ]
            (demand, cut) = fitDemand limits {clDemandChunks = room, clDemandIntervals = clDemandIntervals limits - demandIntervalCount visible} (demandChunks (demandFrom unmet))
         in (demand, cut)
  where
    limits = ccLimits config
    room = max 0 (clDemandChunks limits - length (demandChunks visible))
    margin = ccChunkMargin config
    (lo, hi) = case Map.elems windows of
      [] → (0, 0)
      ranges → (minimum (map fst ranges), maximum (map snd ranges))
    worldLo = negate (2 ^ (62 ∷ Int))
    worldHi = 2 ^ (62 ∷ Int)
    chunkLo = negate (2 ^ (58 ∷ Int)) ∷ Integer
    chunkHi = 2 ^ (58 ∷ Int) - 1 ∷ Integer
    ring (ChunkKey cx cy) =
      [ ChunkKey (fromInteger nx) (fromInteger ny)
      | nx ← [max chunkLo (toInteger cx - margin) .. min chunkHi (toInteger cx + margin)]
      , ny ← [max chunkLo (toInteger cy - margin) .. min chunkHi (toInteger cy + margin)]
      ]

-- The ring chunks that are not already visible, never more than the room: the
-- first key past it is a refusal found before the rest of a large margin is
-- generated.
collectRing ∷ Int → Set.Set ChunkKey → [ChunkKey] → Maybe (Set.Set ChunkKey)
collectRing room visible = go Set.empty
  where
    go acc [] = Just acc
    go acc (k : rest)
      | k `Set.member` visible || k `Set.member` acc = go acc rest
      | Set.size acc >= room = Nothing
      | otherwise = go (Set.insert k acc) rest

-- | Whether a render-world point (grown by the margin) could lie under the
-- sprite of a candidate column that is still unresolved, and, when a row is
-- given, is no farther than that row. Rows are @x + y@ of the view frame; a
-- column in a farther row can never be nearer to the camera than a cell of a
-- nearer row.
unresolvedAhead ∷ Unresolved → Rational → (Rational, Rational) → Maybe Integer → Bool
unresolvedAhead (Unresolved env (cv, cu)) margin (px, py) minRow = or
  [ True
  | u ← [ceiling ((px - 48 - margin) / 48) .. floor ((px + 48 + margin) / 48)]
  , u >= uLo
  , u <= uHi
  , v ← [vFrom .. vTo]
  , even (u + v)
  , v >= vLo
  , v <= vHi
  , v < cv || (v == cv && u >= cu)
  , maybe True (v >=) minRow
  , let a = py - 24 - margin
  , let b = py + 40 + margin
  , let zFrom = max zLoRel (ceiling ((24 * fromInteger v - b) / 16))
  , let zTo = min zHiRel (floor ((24 * fromInteger v - a) / 16))
  , zFrom <= zTo
  ]
  where
    (uLo, uHi) = envURange env
    (vLo, vHi) = envVRange env
    (zLoRel, zHiRel) = envZRel env
    vFrom = max vLo (ceiling ((py - 24 - margin + 16 * fromInteger zLoRel) / 24))
    vTo = min (min vHi cv) (floor ((py + 40 + margin + 16 * fromInteger zHiRel) / 24))

-- | Where a preparation stands.
cellProgressOf ∷ CellPrep → Progress
cellProgressOf prep = case (prHalt prep, prCursor prep) of
  (Just reason, _) → Halted reason
  (Nothing, Nothing) → Settled
  (Nothing, Just _) → Working
