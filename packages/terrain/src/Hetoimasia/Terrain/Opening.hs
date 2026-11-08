-- | The exact empty space of a cell, its openings on the six cell faces, and
-- the connections between neighboring cells' openings.
--
-- This module is the geometric authority for /where empty space can pass/. It
-- derives every opening from the same canonical 'Solid' as
-- "Hetoimasia.Terrain.Geometry", so a portal, a point query and a ray query
-- cannot disagree, and it adds no state, no I/O and no traversal: it reports what
-- one cell leaves open and where two cells' openings meet, and nothing else. It
-- does not inspect residency, turn missing data into air, or walk a world.
--
-- = The empty region and its components
--
-- An occupied shape's empty region is the unit-cell space strictly above its top
-- height @h@ (see "Hetoimasia.Terrain.Geometry"). Identity 0 (@h = 1@) has none.
-- Every other catalog identity has exactly one connected empty component: the
-- region lies above a graph, so every empty point is joined straight up to the
-- top face, and the top face's open part (where @h < 1@, which is the footprint
-- less at most an edge or a point) is connected. Component membership is
-- nevertheless explicit ('cellComponents'): a 'Component' lists the portals it
-- owns, and the connection inside a cell is exactly "two portals of one
-- component are joined". A consumer therefore never assumes that a cell has at
-- most one component.
--
-- = Portals
--
-- A 'Portal' is the part of one cell face through which a component is open: an
-- exact 'Opening' region on that face, owned by one component. Face
-- coordinates are @(y, z)@ on the East and West faces, @(x, z)@ on the North and
-- South faces and @(x, y)@ on the Top and Bottom faces, each in @[0, 1]@, so a
-- face shared by two neighbors has the same coordinates seen from either cell.
-- A horizontal face's opening is its portion with @z > h@; the top opening is
-- where @h < 1@; no catalog shape has a bottom opening of positive area. A
-- selected side is open above the base, and an unselected side may be partly open
-- or sealed according to the same height function: nothing here equates an unset
-- bit with a sealed side. Full air ('airOpenings') is one component open over the
-- whole of all six faces; it is not a seventeenth shape identity.
--
-- The opening of a face is the unit square less the face's section of the solid.
-- That section is the convex hull of the solid's vertices on the face's plane
-- (the plane supports the solid, so the section is a face of the polytope), and
-- the difference is split into convex pieces ('openingPieces'). The pieces are
-- one representation of a region, not a canonical one for comparing regions;
-- compare regions by 'openingArea' and 'openingContains'.
--
-- = Connections
--
-- Two neighboring cells' components connect through a shared face exactly when
-- the two portals on it overlap over positive area, computed exactly after both
-- are placed in world coordinates ('placePortals', 'connectPortals',
-- 'connectCells'). Comparing the two areas, or asking whether both sides are
-- nonempty, is not enough: an N ramp and an S ramp across X each open half of
-- the shared face but overlap over a quarter of it. Edge-only and point-only
-- contact has area zero and never connects; there is no tolerance. Only the six
-- face directions connect, so cells that touch along an edge or at a corner are
-- not linked, and a cell carrying a solid material is not automatically a sealed
-- cube: whether it seals a face is the portal's business alone.
--
-- = Rotation
--
-- 'rotateOpenings' follows 'rotateShape': the openings of a shape turned by a
-- number of quarter turns are the openings of the turned shape, with North to
-- East to South to West, face coordinates turned with the face, and four turns
-- restoring the original. A camera facing selects a view orientation and never
-- rewrites an authored shape identity or a connection.
--
-- State, ownership and lifetime: none. Every value is immutable and every
-- function pure.
module Hetoimasia.Terrain.Opening
  ( -- * Cell faces
    cellFaces
  , oppositeFace
  , rotateFace
  , neighbourTile

    -- * Regions of a face
  , Opening
  , openingPieces
  , openingArea
  , openingIsEmpty
  , openingContains

    -- * The openings of a cell
  , CellOpenings
  , shapeOpenings
  , airOpenings
  , rotateOpenings
  , openingsShape
  , Component
  , cellComponents
  , componentIndex
  , componentPortals
  , Portal
  , cellPortals
  , portalsOn
  , portalFace
  , portalComponent
  , portalOpening

    -- * Placement in the world
  , PlacedPortal
  , placePortals
  , placedTile
  , placedPortal
  , placedWorldPieces

    -- * Connections
  , ComponentRef
  , componentRefTile
  , componentRefIndex
  , PortalConnection
  , connectionFrom
  , connectionTo
  , connectionFace
  , connectionArea
  , connectionRegion
  , connectPortals
  , connectCells
  ) where

import Data.Int (Int64)
import Data.Maybe (mapMaybe)
import Hetoimasia.Terrain.Coordinate
  ( CoordinateError
  , TileCoord
  , TileDelta (..)
  , tileDelta
  , translateTile
  )
import Hetoimasia.Terrain.Geometry (FaceKind (..), V3 (..), cellWorldPoint, shapeSolid, solidVertices)
import Hetoimasia.Terrain.Internal.Polygon
import Hetoimasia.Terrain.Internal.Shape
  ( ShapeId
  , Side (..)
  , Turns
  , allShapeIds
  , rotateShape
  , rotateSide
  , shapeIdValue
  , turns
  )

-- ---------------------------------------------------------------------------
-- Cell faces

-- | The six faces of a cell, in the canonical 'FaceKind' order: the top, the
-- walls North, East, South and West, then the bottom. A cell face is named by
-- the kind of solid face that would seal it.
cellFaces ∷ [FaceKind]
cellFaces = [TopFace, WallFace North, WallFace East, WallFace South, WallFace West, BottomFace]

-- | The face a neighbor presents across a shared face: North and South, East and
-- West, top and bottom exchange.
oppositeFace ∷ FaceKind → FaceKind
oppositeFace TopFace = BottomFace
oppositeFace BottomFace = TopFace
oppositeFace (WallFace side) = WallFace (rotateSide (turns 2) side)

-- | A face after quarter turns: a wall moves with its side, the top and the
-- bottom stay.
rotateFace ∷ Turns → FaceKind → FaceKind
rotateFace count (WallFace side) = WallFace (rotateSide count side)
rotateFace _ face = face

-- | The tile across a face: one step toward North (negative Y), East (positive
-- X), South (positive Y), West (negative X), up (positive Z) or down. The sum is
-- checked, so a step off the supported range is refused rather than wrapped.
neighbourTile ∷ FaceKind → TileCoord → Either CoordinateError TileCoord
neighbourTile face = let (dx, dy, dz) = faceStep face in translateTile dx dy dz

faceStep ∷ FaceKind → (Int64, Int64, Int64)
faceStep (WallFace North) = (0, -1, 0)
faceStep (WallFace East) = (1, 0, 0)
faceStep (WallFace South) = (0, 1, 0)
faceStep (WallFace West) = (-1, 0, 0)
faceStep TopFace = (0, 0, 1)
faceStep BottomFace = (0, 0, -1)

-- | The face of a cell that looks toward another tile exactly one step away on
-- one axis, or nothing when the tiles are the same, diagonal or farther apart.
faceToward ∷ TileCoord → TileCoord → Maybe FaceKind
faceToward from to = case tileDelta from to of
  TileDelta 0 (-1) 0 → Just (WallFace North)
  TileDelta 1 0 0 → Just (WallFace East)
  TileDelta 0 1 0 → Just (WallFace South)
  TileDelta (-1) 0 0 → Just (WallFace West)
  TileDelta 0 0 1 → Just TopFace
  TileDelta 0 0 (-1) → Just BottomFace
  _ → Nothing

-- | The cell-local point on a face at the given face coordinates.
liftToCell ∷ FaceKind → P2 → V3
liftToCell (WallFace North) (u, v) = V3 u 0 v
liftToCell (WallFace South) (u, v) = V3 u 1 v
liftToCell (WallFace West) (u, v) = V3 0 u v
liftToCell (WallFace East) (u, v) = V3 1 u v
liftToCell BottomFace (u, v) = V3 u v 0
liftToCell TopFace (u, v) = V3 u v 1

-- | Whether a cell-local point lies in the plane of a face.
onFacePlane ∷ FaceKind → V3 → Bool
onFacePlane (WallFace North) (V3 _ y _) = y == 0
onFacePlane (WallFace South) (V3 _ y _) = y == 1
onFacePlane (WallFace West) (V3 x _ _) = x == 0
onFacePlane (WallFace East) (V3 x _ _) = x == 1
onFacePlane BottomFace (V3 _ _ z) = z == 0
onFacePlane TopFace (V3 _ _ z) = z == 1

-- | The face coordinates of a cell-local point (its coordinate along the face's
-- normal is dropped).
faceCoordinates ∷ FaceKind → V3 → P2
faceCoordinates (WallFace North) (V3 x _ z) = (x, z)
faceCoordinates (WallFace South) (V3 x _ z) = (x, z)
faceCoordinates (WallFace West) (V3 _ y z) = (y, z)
faceCoordinates (WallFace East) (V3 _ y z) = (y, z)
faceCoordinates BottomFace (V3 x y _) = (x, y)
faceCoordinates TopFace (V3 x y _) = (x, y)

-- ---------------------------------------------------------------------------
-- Regions of a face

-- | An exact region of a cell face, in face coordinates: a union of convex
-- pieces without a common interior. Obtain one from a 'Portal'.
newtype Opening = Opening [Poly]
  deriving stock (Eq, Show)

-- | The convex pieces, each counter-clockwise from its least corner, with the
-- pieces in a fixed order. Together they are the region; no piece has zero area.
openingPieces ∷ Opening → [[(Rational, Rational)]]
openingPieces (Opening pieces) = pieces

-- | The exact area of the region, in @[0, 1]@.
openingArea ∷ Opening → Rational
openingArea (Opening pieces) = sum (map polyArea pieces)

-- | Whether the region has no area.
openingIsEmpty ∷ Opening → Bool
openingIsEmpty (Opening pieces) = null pieces

-- | Whether a face point is in the region, its boundary included. The boundary
-- the region shares with the solid belongs to the solid, which is closed
-- (@classifyPoint@ calls such a point a boundary point, not exterior), so a
-- point strictly inside the region is exactly a point the solid classifies as
-- exterior.
openingContains ∷ Opening → (Rational, Rational) → Bool
openingContains (Opening pieces) point = any (`containsClosed` point) pieces

-- ---------------------------------------------------------------------------
-- The openings of a cell

-- | The openings of a cell: its components and their portals. Obtain one with
-- 'shapeOpenings' or 'airOpenings'; the constructor is private.
data CellOpenings = CellOpenings !(Maybe ShapeId) ![Component]
  deriving stock (Eq, Show)

-- | One connected region of empty space inside a cell, with the portals through
-- which it reaches the cell's faces. Every portal of a component is joined to
-- every other through the component.
data Component = Component !Int ![Portal]
  deriving stock (Eq, Show)

-- | The part of one cell face through which a component is open.
data Portal = Portal !FaceKind !Int !Opening
  deriving stock (Eq, Show)

-- | The shape these openings were derived from; 'Nothing' for full air.
openingsShape ∷ CellOpenings → Maybe ShapeId
openingsShape (CellOpenings shape _) = shape

-- | The cell's empty components: none for a sealed block, one for every other
-- catalog shape and for air, and in general any number.
cellComponents ∷ CellOpenings → [Component]
cellComponents (CellOpenings _ components) = components

-- | Which component of the cell this is, from zero.
componentIndex ∷ Component → Int
componentIndex (Component index _) = index

-- | The portals a component owns, in 'cellFaces' order.
componentPortals ∷ Component → [Portal]
componentPortals (Component _ portals) = portals

-- | Every portal of the cell, in 'cellFaces' order and then component order.
cellPortals ∷ CellOpenings → [Portal]
cellPortals openings = concatMap componentPortals (cellComponents openings)

-- | The portals of the cell on one face.
portalsOn ∷ FaceKind → CellOpenings → [Portal]
portalsOn face openings = [portal | portal ← cellPortals openings, portalFace portal == face]

-- | The cell face a portal lies on.
portalFace ∷ Portal → FaceKind
portalFace (Portal face _ _) = face

-- | The index of the component that owns a portal.
portalComponent ∷ Portal → Int
portalComponent (Portal _ index _) = index

-- | The exact region of the face the portal opens, in face coordinates.
portalOpening ∷ Portal → Opening
portalOpening (Portal _ _ opening) = opening

-- | Full air: one empty component, open over the whole of all six faces. It is
-- the adjoining geometry of a known empty cell, and it is not a shape identity.
airOpenings ∷ CellOpenings
airOpenings = CellOpenings Nothing [Component 0 [Portal face 0 (Opening [unitSquare]) | face ← cellFaces]]

-- | The openings of a catalog shape in its authored orientation.
shapeOpenings ∷ ShapeId → CellOpenings
shapeOpenings shape = catalog !! shapeIdValue shape

-- | The openings after quarter turns. For a shape this is the openings of the
-- turned shape, so facets, components and face coordinates turn together and four
-- turns restore the original; full air is unchanged.
rotateOpenings ∷ Turns → CellOpenings → CellOpenings
rotateOpenings count openings = case openingsShape openings of
  Nothing → openings
  Just shape → shapeOpenings (rotateShape count shape)

catalog ∷ [CellOpenings]
catalog = map build allShapeIds
  where
    build shape = CellOpenings (Just shape) [Component 0 owned | not (null owned)]
      where
        vertices = solidVertices (shapeSolid shape)
        -- A face's opening: the unit square less the solid's section by the
        -- face's plane, which is the hull of the solid's vertices on that plane.
        opening face =
          Opening
            (subtractConvex unitSquare (convexHull [faceCoordinates face v | v ← vertices, onFacePlane face v]))
        -- Every portal belongs to the shape's one component: the empty region
        -- lies above a graph, so it is joined upward to the top face (see the
        -- module header). A shape with no portal of positive area has no empty
        -- component.
        owned = [Portal face 0 region | face ← cellFaces, let region = opening face, not (openingIsEmpty region)]

-- ---------------------------------------------------------------------------
-- Placement in the world

-- | A portal placed on a tile, so it has a world position. Obtain one with
-- 'placePortals'.
data PlacedPortal = PlacedPortal !TileCoord !Portal
  deriving stock (Eq, Show)

-- | Every portal of a cell placed on its tile.
placePortals ∷ TileCoord → CellOpenings → [PlacedPortal]
placePortals tile openings = [PlacedPortal tile portal | portal ← cellPortals openings]

-- | The tile a placed portal is on.
placedTile ∷ PlacedPortal → TileCoord
placedTile (PlacedPortal tile _) = tile

-- | The portal, in its cell's face coordinates.
placedPortal ∷ PlacedPortal → Portal
placedPortal (PlacedPortal _ portal) = portal

-- | The pieces of the portal's opening as exact world points: the tile's
-- integer coordinates added to the cell-local points, so the result is exact at
-- the supported extremes and across negative region seams.
placedWorldPieces ∷ PlacedPortal → [[V3]]
placedWorldPieces (PlacedPortal tile (Portal face _ opening)) =
  [map (cellWorldPoint tile . liftToCell face) piece | piece ← openingPieces opening]

-- | The world plane a placed portal lies in: the axis of its normal (0 for X, 1
-- for Y, 2 for Z) and its exact coordinate on it.
worldPlane ∷ PlacedPortal → (Int, Rational)
worldPlane (PlacedPortal tile (Portal face _ _)) = (axis, value)
  where
    V3 x y z = cellWorldPoint tile (liftToCell face (0, 0))
    (axis, value) = case face of
      WallFace East → (0, x)
      WallFace West → (0, x)
      WallFace North → (1, y)
      WallFace South → (1, y)
      TopFace → (2, z)
      BottomFace → (2, z)

-- | The pieces of a placed portal in the world coordinates tangent to its plane
-- (the face coordinates shifted by the tile).
worldTangent ∷ PlacedPortal → [Poly]
worldTangent placed@(PlacedPortal _ (Portal face _ _)) = [map (faceCoordinates face) piece | piece ← placedWorldPieces placed]

-- ---------------------------------------------------------------------------
-- Connections

-- | One component of one placed cell.
data ComponentRef = ComponentRef !TileCoord !Int
  deriving stock (Eq, Ord, Show)

-- | The tile of the component's cell.
componentRefTile ∷ ComponentRef → TileCoord
componentRefTile (ComponentRef tile _) = tile

-- | The index of the component within its cell.
componentRefIndex ∷ ComponentRef → Int
componentRefIndex (ComponentRef _ index) = index

-- | Two components joined through a shared face, with the exact region of the
-- face their portals have in common.
data PortalConnection = PortalConnection !ComponentRef !ComponentRef !FaceKind !Rational ![[V3]]
  deriving stock (Eq, Show)

-- | The component of the first portal given.
connectionFrom ∷ PortalConnection → ComponentRef
connectionFrom (PortalConnection from _ _ _ _) = from

-- | The component of the second portal given.
connectionTo ∷ PortalConnection → ComponentRef
connectionTo (PortalConnection _ to _ _ _) = to

-- | The face of the first portal's cell on which the two meet.
connectionFace ∷ PortalConnection → FaceKind
connectionFace (PortalConnection _ _ face _ _) = face

-- | The exact area of the common opening, always positive.
connectionArea ∷ PortalConnection → Rational
connectionArea (PortalConnection _ _ _ area _) = area

-- | The common opening as convex pieces of exact world points on the shared
-- plane.
connectionRegion ∷ PortalConnection → [[V3]]
connectionRegion (PortalConnection _ _ _ _ region) = region

-- | Connect two placed portals. They connect exactly when they are on opposite
-- faces of one world plane and their openings overlap over positive area; an
-- overlap along an edge or at a point, a different plane, the same direction or
-- a different tile column never connects. The result names both components and
-- the exact common region.
connectPortals ∷ PlacedPortal → PlacedPortal → Maybe PortalConnection
connectPortals first second
  | portalFace (placedPortal first) /= oppositeFace (portalFace (placedPortal second)) = Nothing
  | worldPlane first /= worldPlane second = Nothing
  | null common = Nothing
  | otherwise =
      Just
        ( PortalConnection
            (ComponentRef (placedTile first) (portalComponent (placedPortal first)))
            (ComponentRef (placedTile second) (portalComponent (placedPortal second)))
            (portalFace (placedPortal first))
            (sum (map polyArea common))
            (map (map lift) common)
        )
  where
    common = [piece | a ← worldTangent first, b ← worldTangent second, let piece = intersectConvex a b, not (null piece)]
    (axis, value) = worldPlane first
    lift (p, q) = case axis of
      0 → V3 value p q
      1 → V3 p value q
      _ → V3 p q value

-- | Every connection between two placed cells. Cells connect only through a face
-- they share, so tiles that are the same, diagonal or farther apart have none;
-- the second cell's portals are those facing the first.
connectCells ∷ TileCoord → CellOpenings → TileCoord → CellOpenings → [PortalConnection]
connectCells tileA openingsA tileB openingsB = case faceToward tileA tileB of
  Nothing → []
  Just face →
    mapMaybe
      (uncurry connectPortals)
      [ (a, b)
      | a ← placePortals tileA openingsA
      , portalFace (placedPortal a) == face
      , b ← placePortals tileB openingsB
      , portalFace (placedPortal b) == oppositeFace face
      ]
