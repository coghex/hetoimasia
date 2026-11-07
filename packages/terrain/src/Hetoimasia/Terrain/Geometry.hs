-- | The canonical unit-cell solid of every catalog shape, and its pure
-- membership and intersection semantics.
--
-- This module is the one geometric authority later consumers share: face
-- generation, cutaway coverage and picking all read the same 'Solid', so they
-- cannot drift into unrelated approximations. See the package README for the
-- full contract, the reference mapping and the rationale.
--
-- = Cell frame
--
-- A cell's local frame has X to the East, Y to the South (North is toward
-- negative Y) and Z up; the cell occupies @[0,1]³@ and its base is its tile's
-- elevation. 'cellWorldPoint' places a local point in tile space exactly.
--
-- = The solid of a shape
--
-- The solid is the closed convex set @0 <= x,y <= 1@, @z >= 0@ under the top
-- surface: a flat top at @z = 1@ for identities 0 and 15, and otherwise one
-- ramp per set bit, each a full-width 45° plane that is @0@ high on its own
-- side and @1@ high on the opposite side:
--
-- * North: @z <= y@; East: @z <= 1 - x@; South: @z <= 1 - y@; West: @z <= x@.
--
-- A set bit therefore lowers its own side to the base, where the neighbor one
-- level lower meets it, and the solid is the intersection of every ramp (the
-- lower envelope), so it is always a convex polytope with piecewise-planar
-- faces. A lowered side leaves a zero-thickness edge, which is no face.
-- Identity 15 is the authored all-sides identity with a flat top: its solid is
-- exactly that of identity 0.
--
-- = Exactness and conventions
--
-- Every value is an exact 'Rational'; there is no floating-point arithmetic
-- and so no tolerance. A contact is tangential exactly when its rational
-- parameter says so. The solid is /closed/: its boundary belongs to it, so two
-- cells that share a face, edge or vertex touch. 'classifyPoint' separates
-- 'Interior', 'Boundary' and 'Exterior'. Floating-point input is accepted only
-- through 'v3FromDoubles' and 'mkRayFromDoubles', which refuse non-finite
-- components.
--
-- State, ownership and lifetime: none. Every value is immutable and every
-- function pure.
module Hetoimasia.Terrain.Geometry
  ( -- * Points
    V3 (..)
  , GeometryError (..)
  , v3FromDoubles
  , cellWorldPoint
  , rotatePoint

    -- * Solids and faces
  , Solid
  , solidShape
  , solidPlanes
  , solidVertices
  , solidFaces
  , shapeSolid
  , Plane (..)
  , FaceKind (..)
  , Face (..)
  , faceFootprintArea

    -- * Face coverage
  , Coverage (..)
  , sideCoverageArea
  , sideCoverage

    -- * Membership
  , PointClass (..)
  , classifyPoint

    -- * Ray and segment queries
  , Ray
  , rayOrigin
  , rayDirection
  , mkRay
  , mkRayFromDoubles
  , Contact (..)
  , RayHit (..)
  , castRay
  , castSegment
  ) where

import Data.List (sortOn)
import Data.Maybe (listToMaybe)
import Hetoimasia.Terrain.Coordinate (TileCoord (..), axisValue)
import Hetoimasia.Terrain.Internal.Polytope
import Hetoimasia.Terrain.Internal.Shape

-- | Why a geometric input was refused.
data GeometryError
  = -- | A floating-point component that is NaN or infinite.
    NonFiniteComponent
  | -- | A ray direction or a segment with no length.
    ZeroLengthDirection
  deriving stock (Eq, Show)

-- | A floating-point triple as an exact point, refusing NaN and infinity.
v3FromDoubles ∷ Double → Double → Double → Either GeometryError V3
v3FromDoubles x y z
  | any (\value → isNaN value || isInfinite value) [x, y, z] = Left NonFiniteComponent
  | otherwise = Right (V3 (toRational x) (toRational y) (toRational z))

-- | A cell-local point placed in tile space: the tile's exact integer
-- coordinates added to the local point. Nothing is converted to floating point,
-- so a point is exact at the extreme coordinates.
cellWorldPoint ∷ TileCoord → V3 → V3
cellWorldPoint (TileCoord x y z) (V3 a b c) =
  V3 (toRational (axisValue x) + a) (toRational (axisValue y) + b) (toRational (axisValue z) + c)

-- | Rotate a cell-local point about the cell's vertical centre axis by quarter
-- turns, in the compass sense of 'rotateSide': one positive turn takes North to
-- East, which takes local @(x, y)@ to @(1 - y, x)@. Z is unchanged. A solid of
-- shape @s@ rotated by @t@ is the solid of @rotateShape t s@.
rotatePoint ∷ Turns → V3 → V3
rotatePoint count point@(V3 x y z) = case turnCount count of
  0 → point
  1 → V3 (1 - y) x z
  2 → V3 (1 - x) (1 - y) z
  _ → V3 y (1 - x) z

-- | The kind of a face. The derived order is the canonical face order used to
-- break ties: top surfaces, then the walls North, East, South, West, then the
-- bottom.
data FaceKind = TopFace | WallFace Side | BottomFace
  deriving stock (Eq, Ord, Show)

-- | One face of a solid: its kind, its supporting plane (normal pointing out)
-- and its corners in counter-clockwise order seen from outside.
data Face = Face
  { faceKind ∷ !FaceKind
  , facePlane ∷ !Plane
  , faceVertices ∷ ![V3]
  }
  deriving stock (Eq, Show)

-- | A cell's canonical solid. Obtain one with 'shapeSolid'.
data Solid = Solid
  { solidShape ∷ !ShapeId
  , solidPlanes ∷ ![Plane]
  , solidVertices ∷ ![V3]
  , solidFaces ∷ ![Face]
  }
  deriving stock (Eq, Show)

-- | The canonical solid of a shape, with its half-spaces, distinct vertices and
-- faces of positive area in canonical order.
shapeSolid ∷ ShapeId → Solid
shapeSolid shape = solids !! shapeIdValue shape

solids ∷ [Solid]
solids = map build allShapeIds
  where
    build shape =
      let tagged = taggedPlanes shape
          planes = map snd tagged
          vertices = polytopeVertices planes
          faces =
            sortOn
              faceKind
              [ Face kind plane polygon
              | (kind, plane) ← tagged
              , Just polygon ← [facePolygon plane vertices]
              ]
       in Solid shape planes vertices faces

-- | The half-spaces of a shape, each tagged with the face kind it can bound.
taggedPlanes ∷ ShapeId → [(FaceKind, Plane)]
taggedPlanes shape =
  [ (WallFace West, Plane (V3 (-1) 0 0) 0)
  , (WallFace East, Plane (V3 1 0 0) 1)
  , (WallFace North, Plane (V3 0 (-1) 0) 0)
  , (WallFace South, Plane (V3 0 1 0) 1)
  , (BottomFace, Plane (V3 0 0 (-1)) 0)
  ]
    <> tops
  where
    -- Identity 15 is the authored all-sides identity with a flat top.
    tops
      | shapeIdValue shape == 15 || null sides = [(TopFace, Plane (V3 0 0 1) 1)]
      | otherwise = [(TopFace, ramp side) | side ← sides]
    sides = shapeSides shape
    -- z <= y, z <= 1 - x, z <= 1 - y, z <= x.
    ramp North = Plane (V3 0 (-1) 1) 0
    ramp East = Plane (V3 1 0 1) 1
    ramp South = Plane (V3 0 1 1) 1
    ramp West = Plane (V3 (-1) 0 1) 0

-- | The area of a face's projection on its kind's own plane: the footprint for
-- a top or bottom face, the wall's own plane for a wall. Exact.
faceFootprintArea ∷ Face → Rational
faceFootprintArea face = case faceKind face of
  WallFace _ → polygonArea (faceVertices face)
  _ → polygonArea [V3 x y 0 | V3 x y _ ← faceVertices face]

-- | How much of a cell side a shape's wall covers.
data Coverage = NoCoverage | PartialCoverage | FullCoverage
  deriving stock (Eq, Ord, Show)

-- | The exact area of a side's wall, in @[0, 1]@. A lowered side has none; an
-- opposite side of a single ramp is the full square.
sideCoverageArea ∷ ShapeId → Side → Rational
sideCoverageArea shape side =
  sum [faceFootprintArea face | face ← solidFaces (shapeSolid shape), faceKind face == WallFace side]

-- | 'sideCoverageArea' as none, partial or full coverage of the cell side.
sideCoverage ∷ ShapeId → Side → Coverage
sideCoverage shape side = case sideCoverageArea shape side of
  0 → NoCoverage
  1 → FullCoverage
  _ → PartialCoverage

-- | Where a point lies relative to a closed solid.
data PointClass = Interior | Boundary | Exterior
  deriving stock (Eq, Show)

-- | Interior when every half-space holds strictly, exterior when any is
-- violated, and boundary otherwise (a face, an edge or a vertex). The solid is
-- closed, so a boundary point belongs to it.
classifyPoint ∷ Solid → V3 → PointClass
classifyPoint solid point
  | any (> 0) values = Exterior
  | all (< 0) values = Interior
  | otherwise = Boundary
  where
    values = map (`planeValue` point) (solidPlanes solid)

-- | A ray: an origin and a nonzero direction. Obtain one with 'mkRay'.
data Ray = Ray
  { rayOrigin ∷ !V3
  , rayDirection ∷ !V3
  }
  deriving stock (Eq, Show)

-- | A ray with a nonzero direction, refusing a zero direction.
mkRay ∷ V3 → V3 → Either GeometryError Ray
mkRay origin direction
  | direction == V3 0 0 0 = Left ZeroLengthDirection
  | otherwise = Right (Ray origin direction)

-- | A ray from floating-point components, refusing NaN and infinity before a
-- zero direction.
mkRayFromDoubles ∷ (Double, Double, Double) → (Double, Double, Double) → Either GeometryError Ray
mkRayFromDoubles (ox, oy, oz) (dx, dy, dz) = do
  origin ← v3FromDoubles ox oy oz
  direction ← v3FromDoubles dx dy dz
  mkRay origin direction

-- | How the first contact meets the solid.
data Contact
  = -- | The origin is strictly inside the solid; no face is entered.
    StartsInside
  | -- | The query passes from the exterior into the interior at the hit point,
    -- through the reported face.
    Enters
  | -- | The query touches the closed solid without entering its interior: at one
    -- boundary point (an edge or a vertex, or a surface seen edge-on), or along
    -- a stretch that lies inside a boundary plane. The reported face is the
    -- first, in canonical order, that contains the point.
    Grazes
  deriving stock (Eq, Show)

-- | The first contact of a ray or segment with a closed solid.
data RayHit = RayHit
  { hitParameter ∷ !Rational
  -- ^ @t@ with @hitPoint = origin + t * direction@; at least zero.
  , hitPoint ∷ !V3
  , hitFace ∷ !(Maybe Face)
  -- ^ The face entered or touched; 'Nothing' only for 'StartsInside'.
  , hitContact ∷ !Contact
  }
  deriving stock (Eq, Show)

-- | The first contact of a ray, over @t >= 0@, with a solid, or 'Nothing' when
-- it misses.
--
-- A ray that touches the closed solid anywhere hits it. Ties are resolved by
-- fixed rules rather than by tolerance:
--
-- * An origin strictly inside hits at @t = 0@ with 'StartsInside'.
-- * An origin on the boundary that moves into the interior hits at @t = 0@
--   with 'Enters'; one that moves out, or along the boundary, 'Grazes'.
-- * A ray that enters through an edge or a vertex reports, among the faces
--   containing the entry point that it moves into, the first in canonical face
--   order ('FaceKind' order, then the order of the shape's ramps).
-- * A ray that lies in a face's plane never enters through that face; if it
--   also never enters the interior it 'Grazes', reporting the first face in
--   canonical order that contains the first contact point.
castRay ∷ Solid → Ray → Maybe RayHit
castRay solid (Ray origin direction) = cast solid origin direction Nothing

-- | The first contact of the segment from @start@ to @end@ (@t@ in @[0, 1]@),
-- by the same rules as 'castRay'. A segment of no length is refused.
castSegment ∷ Solid → V3 → V3 → Either GeometryError (Maybe RayHit)
castSegment solid start end
  | start == end = Left ZeroLengthDirection
  | otherwise = Right (cast solid start (end `minus` start) (Just 1))

cast ∷ Solid → V3 → V3 → Maybe Rational → Maybe RayHit
cast solid origin direction limit
  | any outsideParallel constraints = Nothing
  | enter > leave = Nothing
  | otherwise = Just (RayHit enter point face contact)
  where
    -- For each plane: value at the origin and its rate along the direction.
    constraints = [(planeValue plane origin, dot (planeNormal plane) direction) | plane ← solidPlanes solid]
    outsideParallel (c, s) = s == 0 && c > 0
    entries = [negate c / s | (c, s) ← constraints, s < 0]
    exits = [negate c / s | (c, s) ← constraints, s > 0] <> maybe [] pure limit
    enter = maximum (0 : entries)
    leave = if null exits then enter else minimum exits
    point = origin `plus` scaleBy enter direction
    inPlane = any (\(c, s) → s == 0 && c == 0) constraints
    startsInside = enter == 0 && all (\(c, _) → c < 0) constraints
    contact
      | startsInside = StartsInside
      | enter < leave && not inPlane = Enters
      | otherwise = Grazes
    containing = [candidate | candidate ← solidFaces solid, planeValue (facePlane candidate) point == 0]
    facing candidate = dot (planeNormal (facePlane candidate)) direction < 0
    face = case contact of
      StartsInside → Nothing
      Enters → listToMaybe (filter facing containing)
      Grazes → listToMaybe containing
