-- | Exact convex-polytope arithmetic behind "Hetoimasia.Terrain.Geometry".
--
-- Every canonical cell solid is the intersection of finitely many closed
-- half-spaces, so its vertices, faces and ray intersections are all computed
-- here in exact 'Rational' arithmetic. There is no floating-point rounding and
-- therefore no numerical tolerance: two contacts are the same contact exactly
-- when their rational parameters are equal.
--
-- State, ownership and lifetime: none. Pure functions over immutable values.
module Hetoimasia.Terrain.Internal.Polytope
  ( V3 (..)
  , dot
  , plus
  , minus
  , scaleBy
  , Plane (..)
  , planeValue
  , polytopeVertices
  , facePolygon
  , polygonArea
  ) where

import Data.List (sortBy)
import Data.Maybe (maybeToList)
import qualified Data.Set as Set

-- | An exact three-dimensional vector or point.
data V3 = V3 !Rational !Rational !Rational
  deriving stock (Eq, Ord, Show)

dot ∷ V3 → V3 → Rational
dot (V3 a b c) (V3 d e f) = a * d + b * e + c * f

plus ∷ V3 → V3 → V3
plus (V3 a b c) (V3 d e f) = V3 (a + d) (b + e) (c + f)

minus ∷ V3 → V3 → V3
minus (V3 a b c) (V3 d e f) = V3 (a - d) (b - e) (c - f)

scaleBy ∷ Rational → V3 → V3
scaleBy k (V3 a b c) = V3 (k * a) (k * b) (k * c)

cross ∷ V3 → V3 → V3
cross (V3 a b c) (V3 d e f) = V3 (b * f - c * e) (c * d - a * f) (a * e - b * d)

-- | The closed half-space @normal · p <= offset@. The normal points out of the
-- solid.
data Plane = Plane
  { planeNormal ∷ !V3
  , planeOffset ∷ !Rational
  }
  deriving stock (Eq, Show)

-- | @normal · p - offset@: negative strictly inside the half-space, zero on
-- its boundary plane, positive outside.
planeValue ∷ Plane → V3 → Rational
planeValue (Plane normal offset) point = dot normal point - offset

-- | The single point where three planes meet, when they meet in exactly one.
meet ∷ Plane → Plane → Plane → Maybe V3
meet (Plane n1 d1) (Plane n2 d2) (Plane n3 d3)
  | determinant == 0 = Nothing
  | otherwise =
      Just
        ( scaleBy
            (1 / determinant)
            (scaleBy d1 (cross n2 n3) `plus` scaleBy d2 (cross n3 n1) `plus` scaleBy d3 (cross n1 n2))
        )
  where
    determinant = dot n1 (cross n2 n3)

-- | The distinct vertices of the polytope the planes bound: every point where
-- three planes meet and that no plane excludes.
polytopeVertices ∷ [Plane] → [V3]
polytopeVertices planes =
  Set.toAscList . Set.fromList $
    [ point
    | (a, rest) ← picks planes
    , (b, rest') ← picks rest
    , c ← rest'
    , point ← maybeToList (meet a b c)
    , all (\plane → planeValue plane point <= 0) planes
    ]
  where
    picks ∷ [x] → [(x, [x])]
    picks [] = []
    picks (x : xs) = (x, xs) : picks xs

-- | The face a plane cuts from the polytope: the vertices on the plane, in
-- counter-clockwise order seen from outside, or 'Nothing' when they do not
-- enclose an area (the plane only touches the solid along an edge or at a
-- point).
facePolygon ∷ Plane → [V3] → Maybe [V3]
facePolygon plane vertices
  | length onPlane < 3 || polygonArea ordered == 0 = Nothing
  | otherwise = Just ordered
  where
    onPlane = filter (\point → planeValue plane point == 0) vertices
    V3 nx ny nz = planeNormal plane
    -- Project along the normal's dominant axis, keeping the right-handed
    -- (first, second, dropped) order so a counter-clockwise turn in the
    -- projection is a counter-clockwise turn seen from the positive side.
    (project, dominant) = case maximum [(abs nx, 0 ∷ Int), (abs ny, 1), (abs nz, 2)] of
      (_, 0) → (\(V3 _ y z) → (y, z), nx)
      (_, 1) → (\(V3 x _ z) → (z, x), ny)
      _ → (\(V3 x y _) → (x, y), nz)
    count = fromIntegral (length onPlane)
    centre = (sum (map (fst . project) onPlane) / count, sum (map (snd . project) onPlane) / count)
    sorted = sortBy (\p q → angleOrder (relative p) (relative q)) onPlane
    relative point = let (a, b) = project point in (a - fst centre, b - snd centre)
    ordered = if dominant > 0 then sorted else reverse sorted

-- | Counter-clockwise angular order of two points relative to a centre, exact.
angleOrder ∷ (Rational, Rational) → (Rational, Rational) → Ordering
angleOrder p q = case compare (half p) (half q) of
  EQ → compare 0 (turn p q)
  other → other
  where
    half (a, b) = if b > 0 || (b == 0 && a > 0) then 0 else 1 ∷ Int
    turn (a, b) (c, d) = a * d - b * c

-- | The area of a planar polygon, exact: half the length of the vector area.
-- Only axis-aligned planes need its value, and a polygon in one has a vector
-- area along one axis; the general case is returned as the sum of the three
-- projected areas' absolute values, which is zero exactly when the polygon is
-- degenerate.
polygonArea ∷ [V3] → Rational
polygonArea points = let V3 a b c = vectorArea points in abs a + abs b + abs c

vectorArea ∷ [V3] → V3
vectorArea points = scaleBy (1 / 2) (foldr plus (V3 0 0 0) (zipWith cross points (drop 1 points <> take 1 points)))
