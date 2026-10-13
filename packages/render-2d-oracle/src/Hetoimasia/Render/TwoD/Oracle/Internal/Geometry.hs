-- | Exact placement and coverage of a sprite's quad.
--
-- An instance's transform places the unit square [0, 1]² in its layer's space,
-- and the layer's transform (the view's world or UI transform) takes that to
-- target pixels. This module composes the two over 'Rational's, so a quad's
-- corners, whether a pixel centre lies inside it, and its distance from an edge
-- are exact for the 32-bit coefficients the snapshot holds: there is no
-- rounding to tell a zero-area quad from a thin one, and no NaN to explain.
--
-- A quad is /singular/ when its linear part has a zero determinant, which is
-- exact here, and it covers no pixel. A quad whose corners cannot be held as
-- finite 'Float's is /not representable/: the recorder's 32-bit vertices could
-- not carry it.
--
-- __Dependencies.__ @base@ and @hetoimasia-math@.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Oracle.Internal.Geometry
  ( -- * Placement
    Placement (..)
  , place
  , instanceIsSingular
  , isDegenerate
  , representable
  , localPoint
  , inverseLinear

    -- * Coverage
  , Coverage (..)
  , coverage
  , nearBoundary
  , Point

    -- * Clip rectangles
  , ClipStanding (..)
  , clipStanding
  ) where

import Hetoimasia.Math.Affine2 (Affine2, columns)
import Hetoimasia.Math.Vector (V2 (..))

-- | A point.
type Point a = (a, a)

-- | A placement of the unit square in target pixels: local @(x, y)@ goes to
-- @(a·x + c·y + tx, b·x + d·y + ty)@, the convention of "Hetoimasia.Math.Affine2".
data Placement = Placement
  { plA ∷ !Rational
  , plB ∷ !Rational
  , plC ∷ !Rational
  , plD ∷ !Rational
  , plTx ∷ !Rational
  , plTy ∷ !Rational
  }
  deriving stock (Eq, Show)

rationalColumns ∷ Affine2 → (Rational, Rational, Rational, Rational, Rational, Rational)
rationalColumns transform = (r a, r b, r c, r d, r tx, r ty)
  where
    (V2 a b, V2 c d, V2 tx ty) = columns transform
    r = toRational

-- | The placement of an instance whose transform is the second argument in a
-- layer whose transform is the first. With a snapped origin, the quad is
-- translated rigidly so its origin lands there; without one the origin is
-- wherever the composition puts it.
place ∷ Affine2 → Affine2 → Maybe (Point Float) → Placement
place layer instanceTransform snapped =
  Placement
    { plA = fa * ia + fc * ib
    , plB = fb * ia + fd * ib
    , plC = fa * ic + fc * id'
    , plD = fb * ic + fd * id'
    , plTx = maybe (fa * itx + fc * ity + ftx) (toRational . fst) snapped
    , plTy = maybe (fb * itx + fd * ity + fty) (toRational . snd) snapped
    }
  where
    (fa, fb, fc, fd, ftx, fty) = rationalColumns layer
    (ia, ib, ic, id', itx, ity) = rationalColumns instanceTransform

-- | Whether an instance's own transform has a zero determinant: its quad has
-- no area wherever the layer puts it, because a layer transform is invertible.
instanceIsSingular ∷ Affine2 → Bool
instanceIsSingular transform = a * d - b * c == 0
  where
    (a, b, c, d, _, _) = rationalColumns transform

determinant ∷ Placement → Rational
determinant p = plA p * plD p - plB p * plC p

-- | Whether a placement has no inverse. A layer's transform is invertible, so
-- this holds for a placed instance only when 'instanceIsSingular' does; it is
-- the guard that keeps the coverage arithmetic total all the same.
isDegenerate ∷ Placement → Bool
isDegenerate p = determinant p == 0

corners ∷ Placement → [Point Rational]
corners p =
  [ (plTx p, plTy p)
  , (plA p + plTx p, plB p + plTy p)
  , (plC p + plTx p, plD p + plTy p)
  , (plA p + plC p + plTx p, plB p + plD p + plTy p)
  ]

-- | Whether every corner is within the finite 'Float' range.
representable ∷ Placement → Bool
representable p = all inRange (concatMap (\(x, y) → [x, y]) (corners p))
  where
    limit = toRational (maxFinite ∷ Float)
    inRange value = abs value <= limit

maxFinite ∷ Float
maxFinite = encodeFloat 16777215 104

-- | The local coordinates of a target point under a non-singular placement.
localPoint ∷ Placement → Point Rational → Point Rational
localPoint p (x, y) = ((plD p * dx - plC p * dy) / det, (plA p * dy - plB p * dx) / det)
  where
    det = determinant p
    dx = x - plTx p
    dy = y - plTy p

-- | The inverse of a non-singular placement's linear part, row by row: local
-- @x@ is @m00·dx + m01·dy@ and local @y@ is @m10·dx + m11·dy@.
inverseLinear ∷ Placement → ((Rational, Rational), (Rational, Rational))
inverseLinear p = ((plD p / det, negate (plC p) / det), (negate (plB p) / det, plA p / det))
  where
    det = determinant p

-- | How a pixel centre stands to a quad.
data Coverage
  = -- | Clear of the quad: outside, and farther than 1/16 pixel from every edge.
    Outside
  | -- | Inside, and farther than 1/16 pixel from every edge.
    Inside !(Point Rational)
  | -- | Within 1/16 pixel of an edge: neither is claimed.
    NearEdge
  deriving stock (Eq, Show)

-- | Where a pixel centre stands to a non-singular placement's quad.
coverage ∷ Placement → Point Rational → Coverage
coverage p centre
  | nearBoundary (1 / 16) (edges (corners p)) centre = NearEdge
  | inside = Inside (lx, ly)
  | otherwise = Outside
  where
    (lx, ly) = localPoint p centre
    inside = lx >= 0 && lx <= 1 && ly >= 0 && ly <= 1
    edges [p00, p10, p01, p11] = [(p00, p10), (p10, p11), (p11, p01), (p01, p00)]
    edges _ = []

-- | Whether a point is within a distance of any of the segments.
nearBoundary ∷ (Fractional a, Ord a) ⇒ a → [(Point a, Point a)] → Point a → Bool
nearBoundary distance segments point =
  any (\(from, to) → segmentDistanceSquared from to point <= distance * distance) segments

-- | The squared distance from a point to a segment.
segmentDistanceSquared ∷ (Fractional a, Ord a) ⇒ Point a → Point a → Point a → a
segmentDistanceSquared (x0, y0) (x1, y1) (px, py)
  | lengthSquared == 0 = squared (px - x0) + squared (py - y0)
  | otherwise = squared (px - nearestX) + squared (py - nearestY)
  where
    ex = x1 - x0
    ey = y1 - y0
    lengthSquared = squared ex + squared ey
    along = max 0 (min 1 (((px - x0) * ex + (py - y0) * ey) / lengthSquared))
    nearestX = x0 + along * ex
    nearestY = y0 + along * ey
    squared value = value * value

-- | How a pixel centre stands to a clip rectangle, as the layer's transform
-- places it in target pixels.
data ClipStanding
  = -- | Outside the rectangle, and farther than 1/16 pixel from its boundary.
    ClipOutside
  | -- | Inside the rectangle, and farther than 1/16 pixel from its boundary.
    ClipInside
  | -- | Within 1/16 pixel of the rectangle's boundary, after transformation.
    ClipNearEdge
  deriving stock (Eq, Show)

-- | Where a target pixel centre stands to the half-open rectangle
-- @[left, right) × [top, bottom)@ of the layer's space, under a non-singular
-- placement of that space in target pixels (the layer's transform, with no
-- instance in it).
--
-- Membership is exact: the centre is carried back to the layer's space by the
-- placement's inverse and compared with the rectangle, the left and top edges
-- inside and the right and bottom edges outside. The band is measured in
-- target pixels: the rectangle's four corners are carried forward and a centre
-- within 1/16 pixel, in the Euclidean distance, of any of the four segments
-- between them is 'ClipNearEdge', as a quad's edges are in 'coverage'.
clipStanding ∷ Placement → (Rational, Rational, Rational, Rational) → Point Rational → ClipStanding
clipStanding p (left, top, right, bottom) centre
  | nearBoundary (1 / 16) (zip corners' (drop 1 corners' <> take 1 corners')) centre = ClipNearEdge
  | inside = ClipInside
  | otherwise = ClipOutside
  where
    (qx, qy) = localPoint p centre
    inside = left <= qx && qx < right && top <= qy && qy < bottom
    forward (x, y) = (plA p * x + plC p * y + plTx p, plB p * x + plD p * y + plTy p)
    corners' = map forward [(left, top), (right, top), (right, bottom), (left, bottom)]
