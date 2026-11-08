-- | Exact convex-polygon arithmetic in the plane, behind
-- "Hetoimasia.Terrain.Opening".
--
-- A cell face's opening is the unit square less the part of the face the solid
-- covers, and the covered part of a face of a convex solid is itself convex.
-- Everything here is therefore convex-polygon work in exact 'Rational'
-- arithmetic: hull, area, half-plane clip, intersection, and the difference of
-- two convex polygons as interior-disjoint convex pieces. There is no
-- floating-point value and so no tolerance: two polygons overlap over positive
-- area exactly when their exact intersection has positive area, and a shared
-- edge or point has area zero.
--
-- A polygon is a list of corners in counter-clockwise order, without a repeated
-- first corner, without collinear corners and starting at its least corner, so
-- two polygons of one shape compare equal. A degenerate polygon (a segment, a
-- point or nothing) is the empty list wherever a function returns one.
--
-- State, ownership and lifetime: none. Pure functions over immutable values.
module Hetoimasia.Terrain.Internal.Polygon
  ( P2
  , Poly
  , unitSquare
  , polyArea
  , convexHull
  , intersectConvex
  , subtractConvex
  , containsClosed
  , rotateToLeast
  ) where

import Data.List (group, nub, sort)

-- | A point in a face's own plane.
type P2 = (Rational, Rational)

-- | A convex polygon, counter-clockwise, or empty.
type Poly = [P2]

-- | The unit square, the footprint of every cell face.
unitSquare ∷ Poly
unitSquare = [(0, 0), (1, 0), (1, 1), (0, 1)]

-- | Twice the signed area is the shoelace sum; this is the area itself, which is
-- positive for a counter-clockwise polygon and zero for a degenerate one.
polyArea ∷ Poly → Rational
polyArea corners = sum (zipWith cross corners (drop 1 corners <> take 1 corners)) / 2
  where
    cross (a, b) (c, d) = a * d - b * c

-- | The cross product of @b - a@ and @c - a@: positive when @c@ is to the left
-- of the directed line from @a@ to @b@.
orient ∷ P2 → P2 → P2 → Rational
orient (ax, ay) (bx, by) (cx, cy) = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)

-- | The convex hull of a set of points, counter-clockwise from its least corner
-- and without collinear corners; empty when the points do not enclose an area.
convexHull ∷ [P2] → Poly
convexHull points
  | length ordered < 3 = []
  | polyArea hull <= 0 = []
  | otherwise = hull
  where
    ordered = sort (nub points)
    lower = chain ordered
    upper = chain (reverse ordered)
    hull = init lower <> init upper
    -- Andrew's monotone chain: keep only strictly left turns.
    chain = reverse . foldl step []
    step (b : a : rest) c | orient a b c <= 0 = step (a : rest) c
    step acc c = c : acc

-- | Put a polygon in the canonical form: its least corner first.
rotateToLeast ∷ Poly → Poly
rotateToLeast [] = []
rotateToLeast corners = let (before, from) = break (== minimum corners) corners in from <> before

-- | Remove repeated and collinear corners and put the polygon in canonical
-- form; a polygon with no area becomes empty.
tidy ∷ [P2] → Poly
tidy corners
  | length cleaned < 3 || polyArea cleaned <= 0 = []
  | otherwise = rotateToLeast cleaned
  where
    cleaned = dropCollinear (dropRepeats corners)

-- | Merge equal neighbors, including the last corner with the first.
dropRepeats ∷ [P2] → [P2]
dropRepeats corners = case concatMap (take 1) (group corners) of
  merged@(first : _ : _) | last merged == first → init merged
  merged → merged

-- | Remove every corner that lies on the line through its two neighbors.
dropCollinear ∷ [P2] → [P2]
dropCollinear corners
  | length corners < 3 = corners
  | length kept == length corners = corners
  | otherwise = dropCollinear kept
  where
    triples = zip3 (last corners : corners) corners (drop 1 corners <> take 1 corners)
    kept = [b | (a, b, c) ← triples, orient a b c /= 0]

-- | Keep the part of a convex polygon on the closed left of the directed line
-- from @a@ to @b@ (@keepLeft@) or on its closed right.
clipLine ∷ Bool → (P2, P2) → [P2] → [P2]
clipLine keepLeft (a, b) corners = concat (zipWith edge corners (drop 1 corners <> take 1 corners))
  where
    side p = (if keepLeft then id else negate) (orient a b p)
    edge p q
      | sp >= 0 && sq >= 0 = [q]
      | sp >= 0 = [crossing]
      | sq >= 0 = [crossing, q]
      | otherwise = []
      where
        sp = side p
        sq = side q
        t = sp / (sp - sq)
        crossing = (fst p + t * (fst q - fst p), snd p + t * (snd q - snd p))

-- | The intersection of two convex polygons: the corners of the common region,
-- or empty when it has no area (disjoint, or touching only along an edge or at a
-- point).
intersectConvex ∷ Poly → Poly → Poly
intersectConvex first second
  | null first || null second = []
  | otherwise = tidy (foldl (\acc edge → if null acc then [] else clipLine True edge acc) first (edges second))

edges ∷ Poly → [(P2, P2)]
edges corners = zip corners (drop 1 corners <> take 1 corners)

-- | The part of a convex polygon outside another convex polygon, as convex
-- pieces without a common interior: for each edge of the second polygon in
-- turn, the part of the first that lies beyond that edge and inside every edge
-- before it. Pieces of no area are dropped, and a second polygon of no area
-- removes nothing.
subtractConvex ∷ Poly → Poly → [Poly]
subtractConvex whole removed
  | null removed = [whole]
  | otherwise = go whole (edges removed)
  where
    go _ [] = []
    go remaining (edge : rest) =
      let outside = tidy (clipLine False edge remaining)
          inside = clipLine True edge remaining
       in [outside | not (null outside)] <> (if null inside then [] else go inside rest)

-- | Whether a point lies in a convex polygon, boundary included.
containsClosed ∷ Poly → P2 → Bool
containsClosed corners p = not (null corners) && all (\(a, b) → orient a b p >= 0) (edges corners)
