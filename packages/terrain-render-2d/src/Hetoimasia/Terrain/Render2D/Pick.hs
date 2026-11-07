-- | CPU picking against one exact plan.
--
-- A pick takes the immutable 'Plan' it is to answer from, the identity the
-- caller believes that plan has and a window point. It converts the point with
-- the plan's own render-2d mapping (the one drawing uses, including its pixel
-- snap), finds the frontmost planned face whose projected coverage polygon
-- contains it, and returns that face with the cell identity it carries.
--
-- * The plan's faces are exactly the visible ones: nothing above the cut, no
--   face the plan did not emit, and no face behind a nearer one, because the
--   nearest of the containing faces by depth key wins and the keys are the
--   plan's own ordering. A 2D inverse-diamond calculation is never used.
-- * A face is tested as drawn. Each vertex of its coverage mask goes through its
--   instance quad and the world-to-target transform in 32-bit floating point,
--   as drawing does, and when the view snaps to the pixel grid the face moves by
--   the rounding of its instance origin, as the recorder does it. A point on
--   an edge shared by two faces belongs to the one whose left or top edge it
--   is, the viewport's own half-open rule, so exactly one contains it.
-- * The integer cell identity is carried by the face, never derived from the
--   float position, so it is exact at any coordinate.
-- * A point outside the viewport hits nothing, and a viewport with a zero
--   extent has no hits.
-- * Terrain nothing is known about is never turned into an authoritative answer:
--   if the point lies inside a region the plan marks unknown, the result is
--   'PickIncomplete', carrying the best known candidate if there is one, and a
--   miss through such a region is not 'PickNoHit'.
-- * Picking removes nothing and issues no token: token authenticity and the
--   Lua connection are later slices.
--
-- State, ownership and lifetime: none; a pure function of its arguments.
module Hetoimasia.Terrain.Render2D.Pick
  ( PickQuery (..)
  , PickResult (..)
  , PickError (..)
  , pickPlan
  ) where

import Data.List (sortOn)
import Data.Ord (Down (..))
import Hetoimasia.Math.Affine2 (applyPoint)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Mapping
  ( ViewMapping
  , mappingPixelSnap
  , snapPoint
  , targetToWorld
  , viewportContains
  , viewportIsEmpty
  , windowToTarget
  , worldToTarget
  )
import Hetoimasia.Terrain.Render2D.Internal.Polygon (containsHalfOpen)
import Hetoimasia.Terrain.Render2D.Plan
import Hetoimasia.Terrain.Render2D.Projection

-- | One pick: the identity the caller holds for the plan and a window point
-- (a cursor position, in the logical window's coordinates).
data PickQuery = PickQuery
  { pickIdentity ∷ !PlanIdentity
  , pickPoint ∷ !V2
  }
  deriving stock (Eq, Show)

-- | What a pick found.
data PickResult
  = -- | The frontmost face under the point, authoritative.
    PickHit !PlannedFace
  | -- | Nothing is under the point and nothing unknown could be.
    PickNoHit
  | -- | The point lies in terrain nothing is known about: the best known
    -- candidate, which is not authoritative, if any.
    PickIncomplete !(Maybe PlannedFace)
  deriving stock (Eq, Show)

-- | Why a pick was refused.
data PickError
  = -- | The presented identity is not the plan's: a mixed or superseded input.
    PickStale
  | -- | The point is not finite.
    PickInvalidPoint
  deriving stock (Eq, Show)

-- | Pick the frontmost face under a window point.
pickPlan ∷ Plan → PickQuery → Either PickError PickResult
pickPlan plan (PickQuery identity point@(V2 px py))
  | identity /= planIdentity plan = Left PickStale
  | any (\c → isNaN c || isInfinite c) [px, py] = Left PickInvalidPoint
  | viewportIsEmpty viewport = Right PickNoHit
  | otherwise = Right $ case windowToTarget mapping point of
      Nothing → PickNoHit
      Just target
        | not (viewportContains viewport target) → PickNoHit
        | otherwise → resolve target
  where
    view = planView plan
    mapping = rvMapping view
    viewport = setupViewport (rvSetup view)
    resolve target =
      let candidate = case [face | face ← sortOn (Down . faceDepthKey) (planFaces plan), contains target face] of
            (face : _) → Just face
            [] → Nothing
          unknown = case targetToWorld mapping target of
            Just (V2 wx wy) → any (`rectContains` (toRational wx, toRational wy)) (planUnknown plan)
            Nothing → False
       in case (unknown, candidate) of
            (True, c) → PickIncomplete c
            (False, Just face) → PickHit face
            (False, Nothing) → PickNoHit
    contains (V2 tx ty) face = containsHalfOpen (drawnPolygon mapping face) (toRational tx, toRational ty)

-- A face's coverage polygon in target pixels as it is drawn.
drawnPolygon ∷ ViewMapping → PlannedFace → [(Rational, Rational)]
drawnPolygon mapping face = [(toRational x + sx, toRational y + sy) | Just (V2 x y) ← corners]
  where
    quad = faceQuad face
    place (u, v) = worldToTarget mapping (applyPoint quad (V2 (fromRational u) (fromRational v)))
    corners = map place (faceMask face)
    -- The recorder rounds the instance origin; the whole instance moves with it.
    (sx, sy)
      | mappingPixelSnap mapping = case place (0, 0) of
          Just origin@(V2 ox oy) →
            let V2 rx ry = snapPoint origin in (toRational rx - toRational ox, toRational ry - toRational oy)
          Nothing → (0, 0)
      | otherwise = (0, 0)
