-- | Pure cell-quad planning for the terrain arena's 2D view (TRA-16).
--
-- == What a plan is
--
-- The old per-face plan of "Hetoimasia.Terrain.Render2D.Plan" draws the
-- visible faces of each solid. This module plans the approved replacement: one
-- or two /whole-cell/ quads per potentially visible cell, each a full 96 x 64
-- canvas with UV @[0,1]@, drawn through catalog cutout and normal maps. It is
-- added beside the old path with its own tests (TRA-17 switches every consumer
-- and removes the old route, after actual renderer qualification); until then
-- the old per-face route is the temporary migration baseline and this is not a
-- second final player-facing contract.
--
-- A plan reads one coherent immutable snapshot: the terrain facts
-- ("Hetoimasia.Terrain.Render2D.Facts"), the supplied discovery knowledge
-- ("Hetoimasia.Terrain.Render2D.Knowledge"), the adopted assets' coverage
-- ("Hetoimasia.Terrain.Render2D.Assets") and the camera and target. It reads
-- nothing else, performs no I/O, takes no lease, starts no thread, and
-- mutates neither knowledge, terrain nor residency.
--
-- == Which representation a cell has
--
-- > confirmed undiscovered cell           generic full-cell fog (identity-0 map, blank colour);
-- >                                       its terrain is not read for display
-- > discovered whole air                  no quad
-- > known solid, void discovered/absent   one quad: the view-turned shape's ordinary map
-- > known shaped solid, void undiscovered a fog part then a known part (complementary masks)
-- > terrain or knowledge unavailable      pending: neither air nor fog nor a target
--
-- At cut level @k@ every cell above @k@ is omitted; the remaining known shapes
-- keep their forms and materials, with no flat cap added. A cell more than
-- the configured depth (at most 250) below the cut is outside the viewing band.
--
-- == Exact order and the 24-bit keys
--
-- Cells are ordered far to near by the exact integer key
-- @(viewX + viewY, z, viewX, viewY)@ of the rotated view frame, then fog before
-- known material within a cell. Two cells that share a view ray occur with
-- nondecreasing X, Y and Z toward the camera, so X + Y orders them, and Z when X
-- and Y agree. The admitted quads are ranked by that total order into
-- @[0, 2^24)@, larger nearer: ranks are distinct, never wrap, and do not
-- depend on enumeration order. No floating key is used anywhere.
--
-- == Hidden cells
--
-- A quad is omitted only with a coverage proof: the cell's east, south and
-- upper neighbours are each drawn with coverage that is proved, from the
-- adopted planes themselves, to be the whole hexagon (fog, or a full block
-- whose colour and map both cover it). An unavailable neighbour is neither air
-- nor a proof, a mixed neighbour is not a proof, and a colour with a hole
-- proves nothing. Long buried or aerial spans are runs from compressed
-- summaries, never dense prisms.
--
-- == Bounded progress
--
-- 'startCells' reads nothing from the terrain. 'stepCells' processes a bounded
-- number of candidate columns, nearest row first; 'cellPlanOf' returns the plan
-- reached so far at any point. The columns not yet processed are the plan's
-- 'planUnresolved' region and stay unresolved for picking and demand; a column
-- is atomic, so a mixed cell's fog and known parts are admitted or left
-- unprocessed together. A plan-wide bound halts preparation with the remainder
-- unresolved ('Halted'), never truncated as complete. A continuation made under
-- other inputs is refused ('StaleContinuation'). With sufficient capacity and
-- unchanged inputs, repeated steps reach 'Settled' with no footprint hole.
--
-- == Demand
--
-- 'planDemand' names what the processed part needs: first the visible
-- demand, from the pending spans of the projected viewport and band (whose
-- candidate envelope encloses every full sprite, so distant and lower
-- background outside any camera radius is requested), then, only once the
-- visible work is settled and within what it left of each bound, the existing
-- horizontal chunk margin as prefetch. Admission, queueing and priority belong
-- to the runtime.
--
-- State, ownership and lifetime: none. A plan and a preparation are immutable
-- values; the caller owns every input.
module Hetoimasia.Terrain.Render2D.Cells
  ( -- * Configuration
    CellLimits (..)
  , defaultCellLimits
  , CellConfig (..)
  , defaultCellConfig
  , CellRequest (..)
  , CellInputs (..)

    -- * Identity
  , CellIdentity
  , cellIdentityVersions
  , cellIdentityKnowledge
  , cellIdentityCameraRevision
  , cellIdentityFacing
  , cellIdentityCut
  , cellIdentityAssets
  , cellIdentityZoom

    -- * Quads
  , PartKind (..)
  , CellKey (..)
  , TargetRect (..)
  , CellQuad
  , quadPart
  , quadCell
  , quadMaterial
  , quadColour
  , quadMap
  , quadKey
  , quadDepthKey
  , quadOrigin
  , quadTransform
  , quadTarget
  , cellQuadInstance

    -- * Pending and unresolved
  , PendSpan
  , pendingColumn
  , pendingLevels
  , pendingKey
  , Unresolved
  , unresolvedCursor

    -- * The plan
  , Progress (..)
  , HaltReason (..)
  , CellDemand (..)
  , CellStats (..)
  , CellPlan
  , cellPlanIdentity
  , cellPlanView
  , cellPlanQuads
  , cellPlanPending
  , cellPlanUnresolved
  , cellPlanProgress
  , cellPlanDemand
  , cellPlanBounds
  , cellPlanAssets
  , cellPlanStats

    -- * Preparation
  , CellError (..)
  , CellPrep
  , startCells
  , stepCells
  , cellPlanOf
  , planCells
  ) where

import qualified Data.Set as Set
import Data.Word (Word32, Word64)
import Hetoimasia.Math.Affine2 (Affine2)
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.TwoD.Material (defaultMaterial)
import Hetoimasia.Render.TwoD.Snapshot
  ( Instance (..)
  , Sampler (..)
  , Tint (..)
  , UvRect (..)
  )
import Hetoimasia.Terrain.Cell (Column, MaterialId)
import Hetoimasia.Terrain.Coordinate (AxisCoord, TileCoord)
import Hetoimasia.Terrain.MapBake.Catalog (MapKey)
import Hetoimasia.Terrain.Query (defaultQueryLimits)
import Hetoimasia.Terrain.Render2D.Assets (AssetIdentity, AssetKey, ColourRef)
import Hetoimasia.Terrain.Render2D.Facts (Versions)
import Hetoimasia.Terrain.Render2D.Internal.Cells
import Hetoimasia.Terrain.Render2D.Projection (Rect, RenderView)
import Hetoimasia.Terrain.Shape (ViewFacing)

-- | Engineering defaults, not measured capacity: a step examines 4,096
-- candidate columns and 65,536 levels; a plan examines 1,048,576 columns and
-- 16,777,216 levels, holds 1,048,576 instances (the whole key space is
-- 16,777,216) and 65,536 pending spans, and a demand lists 1,024 chunks,
-- 8,192 intervals and 16 regions per chunk.
defaultCellLimits ∷ CellLimits
defaultCellLimits =
  CellLimits
    { clStepCandidates = 4096
    , clStepLevels = 65536
    , clColumns = 1048576
    , clLevels = 16777216
    , clInstances = 1048576
    , clPending = 65536
    , clDemandChunks = 1024
    , clDemandIntervals = 8192
    , clRegionsPerChunk = 16
    }

-- | The approved defaults: a 250-level band, two pixels of slack, a
-- one-chunk prefetch margin and the default limits.
defaultCellConfig ∷ CellConfig
defaultCellConfig =
  CellConfig
    { ccDepth = 250
    , ccMargin = 2
    , ccChunkMargin = 1
    , ccQueryLimits = defaultQueryLimits
    , ccLimits = defaultCellLimits
    }

cellIdentityVersions ∷ CellIdentity → Versions
cellIdentityVersions = idVersions

cellIdentityKnowledge ∷ CellIdentity → Word64
cellIdentityKnowledge = idKnowledge

cellIdentityCameraRevision ∷ CellIdentity → Word64
cellIdentityCameraRevision = idCameraRevision

cellIdentityFacing ∷ CellIdentity → ViewFacing
cellIdentityFacing = idFacing

cellIdentityCut ∷ CellIdentity → AxisCoord
cellIdentityCut = idCut

cellIdentityAssets ∷ CellIdentity → AssetIdentity
cellIdentityAssets = idAssets

cellIdentityZoom ∷ CellIdentity → Float
cellIdentityZoom = idZoom

-- Plain functions, not field labels, so a client cannot forge a quad or a plan
-- with record-update syntax.

quadPart ∷ CellQuad → PartKind
quadPart = cqPart

-- | The exact authored tile of a known part. 'Nothing' for fog: a fog quad
-- holds no coordinate, material or shape, so the plan leaks none.
quadCell ∷ CellQuad → Maybe TileCoord
quadCell = cqCell

quadMaterial ∷ CellQuad → Maybe MaterialId
quadMaterial = cqMaterial

quadColour ∷ CellQuad → ColourRef
quadColour = cqColour

quadMap ∷ CellQuad → MapKey
quadMap = cqMap

quadKey ∷ CellQuad → CellKey
quadKey = cqKey

quadDepthKey ∷ CellQuad → Word32
quadDepthKey = cqDepthKey

quadOrigin ∷ CellQuad → (Integer, Integer)
quadOrigin = cqOrigin

quadTransform ∷ CellQuad → Affine2
quadTransform = cqTransform

quadTarget ∷ CellQuad → TargetRect
quadTarget = cqTarget

-- | A render-2d instance for a quad with the default material, a caller
-- texture (the colour artwork the caller registered for 'quadColour') and the
-- quad's transform and depth key. Material, normal-map and lighting wiring
-- belong to the later material slice.
cellQuadInstance ∷ TextureHandle → CellQuad → Instance
cellQuadInstance texture quad =
  Instance
    { instanceTransform = cqTransform quad
    , instanceUv = UvRect 0 0 1 1
    , instanceTexture = texture
    , instanceDepthKey = cqDepthKey quad
    , instanceTint = Tint 255 255 255 255
    , instanceSampler = SamplerDefault
    , instanceTranslucent = False
    , instanceAdditive = False
    , instanceClip = 0
    , instanceFrameTable = 0
    , instanceParameter = 0
    , instanceMaterial = defaultMaterial
    }

pendingColumn ∷ PendSpan → Maybe Column
pendingColumn = pendColumn

-- | The levels @[lo, hi)@ of the span.
pendingLevels ∷ PendSpan → (Integer, Integer)
pendingLevels s = (pendLo s, pendHi s)

pendingKey ∷ PendSpan → CellKey
pendingKey = pendKey

-- | The next @(row, column)@ to examine; every candidate column from it on is
-- unresolved.
unresolvedCursor ∷ Unresolved → (Integer, Integer)
unresolvedCursor = unrCursor

cellPlanIdentity ∷ CellPlan → CellIdentity
cellPlanIdentity = cpIdentity

cellPlanView ∷ CellPlan → RenderView
cellPlanView = cpView

-- | The admitted quads, ascending by key: far to near.
cellPlanQuads ∷ CellPlan → [CellQuad]
cellPlanQuads = cpQuads

cellPlanPending ∷ CellPlan → [PendSpan]
cellPlanPending = cpPendings

cellPlanUnresolved ∷ CellPlan → Maybe Unresolved
cellPlanUnresolved = cpUnresolved

cellPlanProgress ∷ CellPlan → Progress
cellPlanProgress = cpProgress

cellPlanDemand ∷ CellPlan → CellDemand
cellPlanDemand = cpDemand

cellPlanBounds ∷ CellPlan → Maybe Rect
cellPlanBounds = cpBounds

-- | The distinct assets the admitted quads reference: the set a caller must
-- hold interests on, and the unit its own budgets count, without any
-- assumption here about how textures are bound or packed.
cellPlanAssets ∷ CellPlan → Set.Set AssetKey
cellPlanAssets = cpUsed

cellPlanStats ∷ CellPlan → CellStats
cellPlanStats = cpStats

-- | Prepare to completion or to a plan-wide bound: start, then step until
-- settled or halted, and return the plan. Equivalent to the stepwise path.
planCells ∷ CellInputs → Either CellError CellPlan
planCells inputs = startCells inputs >>= go >>= cellPlanOf inputs
  where
    go prep = case cellProgressOf prep of
      Working → stepCells inputs prep >>= go
      _ → Right prep
