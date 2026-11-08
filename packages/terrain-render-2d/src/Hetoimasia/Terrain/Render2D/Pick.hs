-- | CPU picking against one exact plan.
--
-- /Temporary migration baseline/ (TRA-7): this analytic face picker answers
-- from the old per-face plan. The approved visual picker reads the coverage the
-- cell-quad plan draws ("Hetoimasia.Terrain.Render2D.CellPick", TRA-16), and
-- TRA-17 removes this route when it switches every consumer; it must not
-- become a second answer path for the same click.
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
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Mapping
  ( targetToWorld
  , viewportContains
  , viewportIsEmpty
  , windowToTarget
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
  | -- | A face of the plan cannot be placed in the target by the plan's own
    -- mapping; nothing is answered from an incomplete polygon.
    PickUnrepresentable
  deriving stock (Eq, Show)

-- | Pick the frontmost face under a window point.
pickPlan ∷ Plan → PickQuery → Either PickError PickResult
pickPlan plan (PickQuery identity point@(V2 px py))
  | identity /= planIdentity plan = Left PickStale
  | any (\c → isNaN c || isInfinite c) [px, py] = Left PickInvalidPoint
  | viewportIsEmpty viewport = Right PickNoHit
  | otherwise = case windowToTarget mapping point of
      Nothing → Right PickNoHit
      Just target
        | not (viewportContains viewport target) → Right PickNoHit
        | otherwise → resolve target
  where
    view = planView plan
    mapping = rvMapping view
    viewport = setupViewport (rvSetup view)
    resolve target = do
      outlines ← maybe (Left PickUnrepresentable) Right (traverse outline (sortOn (Down . faceDepthKey) (planFaces plan)))
      let V2 tx ty = target
          candidate = case [face | (face, polygon) ← outlines, containsHalfOpen polygon (toRational tx, toRational ty)] of
            (face : _) → Just face
            [] → Nothing
          unknown = case targetToWorld mapping target of
            Just (V2 wx wy) → any (`rectContains` (toRational wx, toRational wy)) (planUnknown plan)
            Nothing → False
      pure $ case (unknown, candidate) of
        (True, c) → PickIncomplete c
        (False, Just face) → PickHit face
        (False, Nothing) → PickNoHit
    outline face = (,) face <$> drawnOutline mapping (faceQuad face) (faceMask face)
