-- | Exact planar polygon arithmetic over 'Rational', private to the package.
--
-- Every polygon here is convex and listed in the order that gives it a
-- positive 'signedArea' (counter-clockwise in the numeric sense of the
-- coordinates). There is no tolerance: an overlap has area exactly when the
-- rational area is positive, and a point is on an edge exactly when its cross
-- product is zero.
module Hetoimasia.Terrain.Render2D.Internal.Polygon
  ( P2
  , signedArea
  , orient
  , clipConvex
  , centroidOf
  , containsClosed
  , containsHalfOpen
  , boundingBox
  ) where

type P2 = (Rational, Rational)

cross ∷ P2 → P2 → P2 → Rational
cross (ax, ay) (bx, by) (px, py) = (bx - ax) * (py - ay) - (by - ay) * (px - ax)

-- | The shoelace area, positive for the numeric counter-clockwise order.
signedArea ∷ [P2] → Rational
signedArea points = sum (zipWith term points (drop 1 points <> take 1 points)) / 2
  where
    term (x1, y1) (x2, y2) = x1 * y2 - x2 * y1

-- | The polygon in positive order, or 'Nothing' if it has no area.
orient ∷ [P2] → Maybe [P2]
orient points = case compare (signedArea points) 0 of
  GT → Just points
  LT → Just (reverse points)
  EQ → Nothing

-- | The part of the first convex polygon inside the second (Sutherland and
-- Hodgman), both in positive order. The result may be empty or degenerate; use
-- 'signedArea' to tell.
clipConvex ∷ [P2] → [P2] → [P2]
clipConvex subject clip = foldl clipEdge subject (zip clip (drop 1 clip <> take 1 clip))
  where
    clipEdge [] _ = []
    clipEdge polygon (a, b) = concat (zipWith step polygon (drop 1 polygon <> take 1 polygon))
      where
        inside p = cross a b p >= 0
        step p q = case (inside p, inside q) of
          (True, True) → [q]
          (True, False) → [meet p q]
          (False, True) → [meet p q, q]
          (False, False) → []
        meet p@(px, py) q@(qx, qy) =
          let cp = cross a b p
              cq = cross a b q
              t = cp / (cp - cq)
           in (px + t * (qx - px), py + t * (qy - py))

-- | The vertex average of a polygon: an interior point of a convex polygon of
-- positive area.
centroidOf ∷ [P2] → P2
centroidOf points = (sum (map fst points) / n, sum (map snd points) / n)
  where
    n = fromIntegral (length points)

-- | Whether a point lies in the closed polygon.
containsClosed ∷ [P2] → P2 → Bool
containsClosed polygon p = and [cross a b p >= 0 | (a, b) ← edges polygon]

-- | Whether a point lies in the polygon under the half-open rule the viewport
-- uses: left and top edges belong to it, right and bottom edges do not, with
-- screen Y pointing down. Two polygons that share an edge therefore never
-- both contain a point on it.
containsHalfOpen ∷ [P2] → P2 → Bool
containsHalfOpen polygon p = and [inside a b | (a, b) ← edges polygon]
  where
    inside a@(_, ay) b@(bx, by) = case compare (cross a b p) 0 of
      GT → True
      EQ → by < ay || (by == ay && bx > fst a)
      LT → False

edges ∷ [P2] → [(P2, P2)]
edges polygon = zip polygon (drop 1 polygon <> take 1 polygon)

-- | @(minX, maxX, minY, maxY)@ of a nonempty polygon.
boundingBox ∷ [P2] → (Rational, Rational, Rational, Rational)
boundingBox points = (minimum xs, maximum xs, minimum ys, maximum ys)
  where
    xs = map fst points
    ys = map snd points
