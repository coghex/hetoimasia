-- | The folded surface of a corner mask as two planar wedges, behind
-- "Hetoimasia.Terrain.Geometry".
--
-- On the unit footprint, X increases east and Y south. Each of the four
-- corners is at height 0 or 1 according to its mask bit (north-west 1,
-- north-east 2, south-east 4, south-west 8). The footprint is cut by one
-- diagonal into two triangles and the surface is the planar interpolation of
-- the corner heights on each. The crease is chosen so that a lone high or low
-- corner is joined to its two neighbours, and two opposite high corners are
-- separated by the line joining the two lows; every other mask is coplanar
-- under either diagonal. The crease belongs to both triangles, so the surface
-- is continuous.
--
-- A wedge is one triangle: the solid between the base and the surface over
-- it. It is convex. The solid of a mask is the union of its wedges that have
-- positive volume; a wedge whose three corners are at the base is flat and
-- thin, and is not a wedge of the solid.
--
-- State, ownership and lifetime: none. Pure functions over immutable values.
module Hetoimasia.Terrain.Internal.Corner
  ( Wedge (..)
  , cornerWedges
  , wedgeHasVolume
  , cornerHeight
  ) where

import Data.Bits (testBit)
import Data.Maybe (mapMaybe)
import Hetoimasia.Terrain.Internal.Polytope
import Hetoimasia.Terrain.Internal.Shape

-- | One triangle of the footprint and the solid under the surface over it.
data Wedge = Wedge
  { wedgeWalls ∷ ![(Maybe Side, Plane)]
  -- ^ The vertical half-spaces over the triangle's three edges, normals
  -- pointing out. An edge on a cell side carries that side; the crease, which
  -- is shared with the other wedge, carries none.
  , wedgeTop ∷ !Plane
  -- ^ The plane of the surface over the triangle, normal pointing up.
  , wedgeCorners ∷ ![V3]
  -- ^ The triangle's three corners with their heights.
  }

-- | The wedges of a mask, including a wedge that is flat at the base.
cornerWedges ∷ CornerMask → [Wedge]
cornerWedges mask = map wedge triangles
  where
    value = fromIntegral (cornerMaskValue mask) ∷ Int
    height bit = if testBit value bit then 1 else 0
    northWest = V3 0 0 (height 0)
    northEast = V3 1 0 (height 1)
    southEast = V3 1 1 (height 2)
    southWest = V3 0 1 (height 3)
    triangles
      | creaseJoinsNortheastSouthwest value =
          [[northWest, northEast, southWest], [northEast, southEast, southWest]]
      | otherwise =
          [[northWest, northEast, southEast], [northWest, southEast, southWest]]

-- | Whether the crease runs between the north-east and south-west corners,
-- rather than between the north-west and south-east corners. A lone high
-- corner and a lone low corner join their two neighbours, and two opposite
-- high corners are separated by the line joining the two lows. The remaining
-- masks are coplanar, so either diagonal gives the same surface.
creaseJoinsNortheastSouthwest ∷ Int → Bool
creaseJoinsNortheastSouthwest value = value `elem` [1, 4, 5, 11, 14]

wedge ∷ [V3] → Wedge
wedge corners = case corners of
  [a, b, c] →
    Wedge
      { wedgeWalls = [wall a b c, wall b c a, wall c a b]
      , wedgeTop = top a b c
      , wedgeCorners = corners
      }
  _ → error "Internal.Corner.wedge: a wedge has three corners"

-- | The vertical half-space over the edge from @a@ to @b@, away from @c@.
wall ∷ V3 → V3 → V3 → (Maybe Side, Plane)
wall a@(V3 ax ay _) (V3 bx by _) c = (side, Plane normal (dot normal a))
  where
    outward = V3 (by - ay) (ax - bx) 0
    normal = if dot outward (c `minus` a) > 0 then scaleBy (-1) outward else outward
    side
      | ay == 0 && by == 0 = Just North
      | ax == 1 && bx == 1 = Just East
      | ay == 1 && by == 1 = Just South
      | ax == 0 && bx == 0 = Just West
      | otherwise = Nothing

-- | The plane through three corners with an upward normal. The corners are
-- not collinear in the footprint, so the vertical component is nonzero.
top ∷ V3 → V3 → V3 → Plane
top a b c = Plane normal (dot normal a)
  where
    raw = cross (b `minus` a) (c `minus` a)
    V3 _ _ rise = raw
    normal = if rise < 0 then scaleBy (-1) raw else raw

-- | Whether the wedge has positive volume: some corner is above the base.
wedgeHasVolume ∷ Wedge → Bool
wedgeHasVolume = any (\(V3 _ _ h) → h > 0) . wedgeCorners

-- | The surface height at a footprint point of the unit square. Every wedge
-- whose closed triangle holds the point reports its plane's height there;
-- these agree on a shared edge, and a wedge flat at the base reports zero.
cornerHeight ∷ CornerMask → Rational → Rational → Rational
cornerHeight mask x y = maximum (0 : mapMaybe heightIn (cornerWedges mask))
  where
    heightIn w
      | all (\(_, plane) → planeValue plane (V3 x y 0) <= 0) (wedgeWalls w) = Just (surfaceAt (wedgeTop w))
      | otherwise = Nothing
    surfaceAt (Plane (V3 nx ny nz) offset) = (offset - nx * x - ny * y) / nz
