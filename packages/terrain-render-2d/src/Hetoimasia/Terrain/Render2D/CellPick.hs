-- | Visual picking from the coverage a cell-quad plan draws (TRA-16).
--
-- A pick takes the immutable 'CellPlan' it is to answer from, the identity the
-- caller believes the plan has and a window point. It never reopens an image,
-- never reads the GPU back and never asks the terrain: it answers from the
-- plan's quads, the plan's own pending information and the coverage planes of
-- the assets the plan was built with.
--
-- == The traversal
--
-- 1. The logical point goes through the plan's own render-2d mapping to a
--    framebuffer position; the /physical pixel/ it lies in is tested at that
--    pixel's centre. A centre outside the viewport, or a view that draws
--    nothing, has no hit.
-- 2. The quads are examined from the nearest (largest depth key) to the
--    farthest. A quad contains the centre under the raster rule stated below,
--    and covers it when the texel it selects is covered in /both/ its colour
--    plane and its map plane (the AND of the two coverage bits, which is
--    colour alpha times map alpha at the 0.5 threshold for binary alpha).
--    A transparent colour texel and a map hole each let a rearward quad be
--    considered. Lighting, haze and darkening play no part.
-- 3. The first covered quad decides: a known part (ordinary, or the known part
--    of a mixed cell) is a hit with its exact cell; a fog part is no hit and
--    ends the search, returning nothing about what lies beneath it.
-- 4. Pending information that could lie ahead of that quad makes the answer
--    'CellPickLoading' with no candidate: a pending span whose conservative
--    footprint contains the centre and whose nearest possible quad is nearer
--    than the covering quad, or an unprocessed candidate column that could
--    cover the point in a row no farther than the covering quad's. When no quad
--    covers the centre, any such information makes the answer loading; only
--    its absence is a miss. Pending information proved behind the covering quad
--    does not change a hit.
--
-- == The raster convention
--
-- A quad is the axis-aligned rectangle its two triangles cover in the target.
-- A framebuffer pixel centre belongs to it under the left-and-top half-open
-- rule the viewport itself uses: left and top edges are inside, right and
-- bottom edges outside. The two triangles share the diagonal, which lies
-- inside the rectangle, so a centre on it is covered by the quad. A centre on
-- an outer edge shared by two adjacent quads therefore belongs to exactly one.
-- The texel index along an axis is @min (n - 1) (floor (u × n))@ with @u@ the
-- exact rational position of the centre across the drawn rectangle: an interior
-- texel boundary selects the higher index, nothing is sampled outside the
-- rectangle merely because UVs clamp, and no floating rounding can move a
-- centre across a boundary. This is the CPU convention; whether a device's
-- rasterizer agrees at every edge is TRA-17's proof, and a disagreement found
-- there is a counterexample, not a reason to change this rule.
--
-- == Privacy
--
-- The result of a pick through fog is the same 'CellPickNoHit' as a miss, and
-- loading carries nothing. A hit is only a known cell the plan drew. No Lua
-- token is issued and nothing is edited here.
--
-- State, ownership and lifetime: none; a pure function of its arguments.
module Hetoimasia.Terrain.Render2D.CellPick
  ( CellPickQuery (..)
  , CellHit (..)
  , CellPickResult (..)
  , CellPickError (..)
  , pickCells
  ) where

import Data.Word (Word32)
import Hetoimasia.Asset.Image.DataMap (coverageAt)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Mapping (targetToWorld, viewportContains, windowToTarget)
import Hetoimasia.Terrain.Coordinate (TileCoord)
import Hetoimasia.Terrain.Render2D.Assets
import Hetoimasia.Terrain.Render2D.Internal.Cells
import Hetoimasia.Terrain.Render2D.Projection

-- | One pick: the identity the caller holds for the plan and a window point (a
-- cursor position in the logical window's coordinates).
data CellPickQuery = CellPickQuery
  { cellPickIdentity ∷ !CellIdentity
  , cellPickPoint ∷ !V2
  }
  deriving stock (Eq, Show)

-- | A known cell the plan drew under the point, with the plan's coherent
-- identity for the later consistency owner.
data CellHit = CellHit
  { hitCell ∷ !TileCoord
  , hitPart ∷ !PartKind
  , hitIdentity ∷ !CellIdentity
  }
  deriving stock (Eq, Show)

-- | What a pick found.
data CellPickResult
  = -- | The frontmost covered quad is known material.
    CellPickHit !CellHit
  | -- | Nothing selectable is under the point: empty, outside the viewport, or
    -- covered by fog, which are deliberately not distinguished.
    CellPickNoHit
  | -- | Information not yet available could lie ahead of the answer.
    CellPickLoading
  deriving stock (Eq, Show)

-- | Why a pick was refused.
data CellPickError
  = -- | The presented identity is not the plan's: a mixed or superseded input.
    CellPickStale
  | -- | The point is not finite.
    CellPickInvalidPoint
  | -- | The plan's assets lack a plane for a quad it holds.
    CellPickUnrepresentable
  deriving stock (Eq, Show)

-- | Pick the frontmost selectable cell under a window point.
pickCells ∷ CellPlan → CellPickQuery → Either CellPickError CellPickResult
pickCells plan (CellPickQuery presented point@(V2 px py))
  | presented /= identity = Left CellPickStale
  | any (\c → isNaN c || isInfinite c) [px, py] = Left CellPickInvalidPoint
  | zeroDrawable (idSetup identity) = Right CellPickNoHit
  | otherwise = case windowToTarget mapping point of
      Nothing → Right CellPickNoHit
      Just (V2 fx fy)
        | isNaN fx || isInfinite fx || isNaN fy || isInfinite fy → Right CellPickNoHit
        | otherwise →
            let centre = (toRational (floor fx ∷ Integer) + 1 / 2, toRational (floor fy ∷ Integer) + 1 / 2)
             in if viewportContains viewport (V2 (fromRational (fst centre)) (fromRational (snd centre)))
                  then resolve centre
                  else Right CellPickNoHit
  where
    identity = cpIdentity plan
    view = cpView plan
    mapping = rvMapping view
    viewport = setupViewport (rvSetup view)
    assets = cpAssets plan

    resolve centre = do
      front ← firstCovered centre (reverse (cpQuads plan))
      let loading = isLoading centre front
      pure $ case front of
        _ | loading → CellPickLoading
        Nothing → CellPickNoHit
        Just quad → case (cqPart quad, cqCell quad) of
          (PartFog, _) → CellPickNoHit
          (part, Just cell) → CellPickHit (CellHit cell part identity)
          (_, Nothing) → CellPickNoHit

    firstCovered _ [] = Right Nothing
    firstCovered centre (quad : rest)
      | not (contains (cqTarget quad) centre) = firstCovered centre rest
      | otherwise = do
          covered ← coveredBy centre quad
          if covered then Right (Just quad) else firstCovered centre rest

    -- The texel the centre selects, exactly, in both planes.
    coveredBy (cx, cy) quad = do
      let TargetRect l t r b = cqTarget quad
          tx = texel 96 ((cx - l) / (r - l))
          ty = texel 64 ((cy - t) / (b - t))
      colour ← maybe (Left CellPickUnrepresentable) Right (colourCoverage assets (cqColour quad))
      maps ← maybe (Left CellPickUnrepresentable) Right (mapCoverage assets (cqMap quad))
      case (coverageAt colour tx ty, coverageAt maps tx ty) of
        (Just a, Just b') → Right (a && b')
        _ → Left CellPickUnrepresentable

    texel ∷ Integer → Rational → Word32'
    texel n u = fromInteger (min (n - 1) (floor (max 0 (min 1 u) * fromInteger n)))

    isLoading centre front = pendingAhead || unresolvedAheadOf centre
      where
        frontKey = cqKey <$> front
        frontRow = (\(CellKey row _ _ _ _) → row) <$> frontKey
        pendingAhead = any (\s → contains (pendTarget s) centre && maybe True (pendKey s >) frontKey) (cpPendings plan)
        unresolvedAheadOf (cx, cy) = case cpUnresolved plan of
          Nothing → False
          Just unresolved → case targetToWorld mapping (V2 (fromRational cx) (fromRational cy)) of
            Nothing → True
            Just (V2 wx wy) →
              unresolvedAhead unresolved margin (toRational wx, toRational wy) frontRow
        -- One device pixel in render-world pixels, plus the planner's slack.
        margin = 2 + 1 / max (1 / 64) (toRational (viewScale view))

contains ∷ TargetRect → (Rational, Rational) → Bool
contains (TargetRect l t r b) (cx, cy) = l <= cx && cx < r && t <= cy && cy < b

type Word32' = Word32
