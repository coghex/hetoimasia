-- | The compiled connectivity of a source, and its queries.
--
-- = Representation
--
-- The compiler cuts each axis at the coordinates where the source can change
-- (the authored layer and patch boundaries, the columns of the patches and
-- their face neighbours, and the cell just below each boundary and the cell at
-- the top). The cuts make a /lattice/ of boxes, a product of three interval
-- sequences. Inside a box every cell holds the same kind of content, so the box
-- is described by that kind and by its extents, never by its cells. The lattice
-- is the whole of the geometry: a box is a /node/ only when its kind has empty
-- space, and a full block is nothing but a missing node.
--
-- A node with a connected axis (its cells join their neighbours along it, per
-- "Hetoimasia.Terrain.Opening") has no parameter on that axis; an axis that does
-- not connect keeps the cell's coordinate as a /parameter/ of the component, so
-- a covered uniform N-ramp layer is one node whose components are indexed by row
-- and by level. Two nodes joined through a shared face merge into one /class/;
-- the join identifies the nodes' parameters (and removes a parameter when one
-- side has none), so a shaft that joins a vast range of levels removes the level
-- parameter instead of enumerating the levels.
--
-- A component is a class together with the values of its remaining parameters.
-- Its canonical key is the origin of the class's first box in (z, y, x) order,
-- which depends on the validated source alone, and those values.
--
-- = Exterior and the world limits
--
-- A class is exterior exactly when one of its nodes lies in the topmost level
-- and its kind has a top portal of positive area. The X and Y limits and the
-- lower Z limit open nothing, and a full block at the top is not a node.
--
-- State, ownership and lifetime: none. A 'Connectivity' is an immutable value
-- built whole by "Hetoimasia.Terrain.Internal.Connectivity.Prepare"; it holds
-- no cell, no flooded sky and no discovered state, and nothing mutates it.
module Hetoimasia.Terrain.Internal.Connectivity.Index
  ( Axis (..)
  , CellRange (..)
  , rangeCells
  , Node (..)
  , Relation (..)
  , Stats (..)
  , Connectivity (..)
  , ComponentKey
  , keyOrigin
  , keyParameters
  , VoidLookup (..)
  , PortalRelation (..)
  , BoundaryFace (..)
  , Across (..)
  , AcrossKind (..)

    -- * Lattice arithmetic shared with the compiler
  , cutAt
  , cutIndex
  , latticeSize
  , strides
  , decodeLattice
  , axisBit

    -- * Queries
  , lookupVoid
  , cellBox
  , componentOf
  , isExterior
  , componentRanges
  , componentRelations
  , componentBoundary
  , componentContains
  , portalRelations
  ) where

import Data.Bits (shiftL, (.&.))
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import Data.Maybe (catMaybes, mapMaybe)
import Data.Sequence (Seq)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Word (Word8)
import Hetoimasia.Terrain.Coordinate (TileCoord (..))
import Hetoimasia.Terrain.Geometry (FaceKind (..))
import Hetoimasia.Terrain.Internal.Connectivity.Kind (Kind, joined)
import Hetoimasia.Terrain.Internal.Coordinate (AxisCoord (..), axisFromInteger, axisValue)
import Hetoimasia.Terrain.Internal.Shape (Side (..))

-- | The three axes: X runs east, Y south and Z up.
data Axis = AxisX | AxisY | AxisZ
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | A box of cells, each axis a half-open @[lo, hi)@ in exact integers. The
-- upper end of an axis may be @2^62@, one past the highest supported cell.
data CellRange = CellRange
  { rangeXLo ∷ !Integer
  , rangeXHi ∷ !Integer
  , rangeYLo ∷ !Integer
  , rangeYHi ∷ !Integer
  , rangeZLo ∷ !Integer
  , rangeZHi ∷ !Integer
  }
  deriving stock (Eq, Ord, Show)

-- | The number of cells in a range, exactly.
rangeCells ∷ CellRange → Integer
rangeCells r = (rangeXHi r - rangeXLo r) * (rangeYHi r - rangeYLo r) * (rangeZHi r - rangeZLo r)

-- | One structural node: a lattice box of uniform void-bearing content.
data Node = Node
  { nodeLattice ∷ !Int
  -- ^ The box's lattice index.
  , nodeKind ∷ !Kind
  , nodeClass ∷ !Int
  -- ^ The first node, by lattice index, of the node's class.
  , nodeRetain ∷ !Word8
  -- ^ The axes along which the box's cells do not connect and which have more
  -- than one cell (bit 0 X, 1 Y, 2 Z).
  , nodeAxes ∷ !Word8
  -- ^ The retained axes that stay parameters of the class's components.
  }
  deriving stock (Eq, Show)

-- | A portal relation: the lower node, the upper node one step along the axis
-- and the axis (0 X, 1 Y, 2 Z). The two share a whole face.
data Relation = Relation !Int !Int !Int
  deriving stock (Eq, Show)

-- | The structural figures of a compiled result.
data Stats = Stats
  { statLatticeCells ∷ !Integer
  , statNodes ∷ !Integer
  , statRelations ∷ !Integer
  , statClasses ∷ !Integer
  , statResultBytes ∷ !Integer
  }
  deriving stock (Eq, Show)

-- | The complete compiled connectivity of one source. The constructor is
-- private to the package.
data Connectivity = Connectivity
  { cXCuts ∷ !(Set Int64)
  , cYCuts ∷ !(Set Int64)
  , cZCuts ∷ !(Set Int64)
  , cNodeAt ∷ !(IntMap Int)
  , cNodes ∷ !(IntMap Node)
  , cMembers ∷ !(IntMap [Int])
  , cExterior ∷ !IntSet
  , cRelations ∷ !(Seq Relation)
  , cStats ∷ !Stats
  }
  deriving stock (Eq, Show)

-- | The identity of one connected component of the source's empty space: the
-- origin of its class's first box and the values of the parameters its class
-- keeps. Equal keys name the same component, and a key depends on the validated
-- source and the component's parameters alone.
data ComponentKey = ComponentKey !TileCoord !(Maybe AxisCoord) !(Maybe AxisCoord) !(Maybe AxisCoord)
  deriving stock (Eq, Ord, Show)

-- | The origin tile of the key's class.
keyOrigin ∷ ComponentKey → TileCoord
keyOrigin (ComponentKey origin _ _ _) = origin

-- | The parameters of the key: the axes whose coordinate distinguishes this
-- component from its siblings of the same class, with their values.
keyParameters ∷ ComponentKey → [(Axis, AxisCoord)]
keyParameters (ComponentKey _ x y z) = [(axis, v) | (axis, Just v) ← [(AxisX, x), (AxisY, y), (AxisZ, z)]]

-- | The answer to a component lookup for one void of one cell.
data VoidLookup
  = -- | The cell has no empty space at all (a full block).
    NoVoid
  | -- | The cell has voids, but not one with this index.
    NoSuchVoid
  | -- | The component the void belongs to.
    InComponent !ComponentKey
  deriving stock (Eq, Show)

-- | Two neighbouring ranges of one component that meet over a shared face and
-- connect through it. The ranges are the layers of cells on the two sides of
-- the face, of equal extent across it.
data PortalRelation = PortalRelation
  { relationLower ∷ !CellRange
  , relationUpper ∷ !CellRange
  , relationAxis ∷ !Axis
  }
  deriving stock (Eq, Show)

-- | What lies across a boundary face.
data Across
  = -- | No tile: a supported coordinate limit.
    AcrossLimit
  | -- | The tiles across the face, which are not members of the component.
    AcrossTiles !CellRange !AcrossKind
  deriving stock (Eq, Show)

-- | Whether the tiles across a boundary face hold any empty space.
data AcrossKind
  = -- | Full blocks.
    AcrossSolid
  | -- | Cells with empty space of another component.
    AcrossOtherVoid
  deriving stock (Eq, Show)

-- | A face of a component that does not continue into the component: the layer
-- of its member cells touching the face, the face, and what lies across.
data BoundaryFace = BoundaryFace
  { boundaryCells ∷ !CellRange
  , boundaryFace ∷ !FaceKind
  , boundaryAcross ∷ !Across
  }
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- Lattice arithmetic

-- | The cut at a position of a sorted cut set, or 'Nothing' outside it.
cutAt ∷ Set Int64 → Int → Maybe Int64
cutAt cuts i
  | i < 0 || i >= Set.size cuts = Nothing
  | otherwise = Just (Set.elemAt i cuts)

-- | The index of the lattice interval containing a coordinate.
cutIndex ∷ Set Int64 → Int64 → Maybe Int
cutIndex cuts v = Set.lookupLE v cuts >>= (`Set.lookupIndex` cuts)

-- | The intervals per axis: one fewer than the cuts.
latticeSize ∷ Connectivity → (Int, Int, Int)
latticeSize c = (Set.size (cXCuts c) - 1, Set.size (cYCuts c) - 1, Set.size (cZCuts c) - 1)

-- | The lattice index steps along X, Y and Z.
strides ∷ (Int, Int, Int) → (Int, Int, Int)
strides (nx, ny, _) = (1, nx, nx * ny)

-- | The interval indices of a lattice index.
decodeLattice ∷ (Int, Int, Int) → Int → (Int, Int, Int)
decodeLattice (nx, ny, _) index =
  let (layer, rest) = index `divMod` (nx * ny)
      (row, column) = rest `divMod` nx
   in (column, row, layer)

axisBit ∷ Int → Word8
axisBit axis = 1 `shiftL` axis

-- ---------------------------------------------------------------------------
-- Boxes

nodeRange ∷ Connectivity → Node → Maybe CellRange
nodeRange c node = do
  let (i, j, k) = decodeLattice (latticeSize c) (nodeLattice node)
  x0 ← cutAt (cXCuts c) i
  x1 ← cutAt (cXCuts c) (i + 1)
  y0 ← cutAt (cYCuts c) j
  y1 ← cutAt (cYCuts c) (j + 1)
  z0 ← cutAt (cZCuts c) k
  z1 ← cutAt (cZCuts c) (k + 1)
  pure (CellRange (toInteger x0) (toInteger x1) (toInteger y0) (toInteger y1) (toInteger z0) (toInteger z1))

tileIndex ∷ Connectivity → TileCoord → Maybe Int
tileIndex c (TileCoord x y z) = do
  i ← cutIndex (cXCuts c) (axisValue x)
  j ← cutIndex (cYCuts c) (axisValue y)
  k ← cutIndex (cZCuts c) (axisValue z)
  let (nx, ny, _) = latticeSize c
  pure (i + nx * (j + ny * k))

tileNode ∷ Connectivity → TileCoord → Maybe (Int, Node)
tileNode c tile = do
  index ← tileIndex c tile
  nid ← IntMap.lookup index (cNodeAt c)
  node ← IntMap.lookup nid (cNodes c)
  pure (nid, node)

-- | The lattice box of the cell: the range of cells that hold the same content
-- and that the compiler treats as one node, whether or not the content holds
-- empty space. A box is a unit of the compressed description, not a component.
cellBox ∷ Connectivity → TileCoord → Maybe CellRange
cellBox c tile = do
  index ← tileIndex c tile
  let (i, j, k) = decodeLattice (latticeSize c) index
  x0 ← cutAt (cXCuts c) i
  x1 ← cutAt (cXCuts c) (i + 1)
  y0 ← cutAt (cYCuts c) j
  y1 ← cutAt (cYCuts c) (j + 1)
  z0 ← cutAt (cZCuts c) k
  z1 ← cutAt (cZCuts c) (k + 1)
  pure (CellRange (toInteger x0) (toInteger x1) (toInteger y0) (toInteger y1) (toInteger z0) (toInteger z1))

-- ---------------------------------------------------------------------------
-- Component identity

keyOf ∷ Connectivity → TileCoord → Int → Node → Maybe ComponentKey
keyOf c (TileCoord x y z) _ node = do
  rep ← IntMap.lookup (nodeClass node) (cNodes c)
  origin ← nodeOrigin c rep
  let param axis value = if nodeAxes node .&. axisBit axis /= 0 then Just value else Nothing
  pure (ComponentKey origin (param 0 x) (param 1 y) (param 2 z))

nodeOrigin ∷ Connectivity → Node → Maybe TileCoord
nodeOrigin c node = do
  range ← nodeRange c node
  x ← axisFromInteger (rangeXLo range) `orNothing` ()
  y ← axisFromInteger (rangeYLo range) `orNothing` ()
  z ← axisFromInteger (rangeZLo range) `orNothing` ()
  pure (TileCoord x y z)
  where
    orNothing r () = either (const Nothing) Just r

-- | The component of one void of the cell at a tile. A full block has no void
-- and says so; it is never reported as air or as an unknown component.
lookupVoid ∷ Connectivity → TileCoord → Int → VoidLookup
lookupVoid c tile index = case tileNode c tile of
  Nothing → NoVoid
  Just (nid, node)
    | index /= 0 → NoSuchVoid
    | otherwise → maybe NoVoid InComponent (keyOf c tile nid node)

-- | The component of the cell's one void, when it has a void.
componentOf ∷ Connectivity → TileCoord → Maybe ComponentKey
componentOf c tile = case lookupVoid c tile 0 of
  InComponent key → Just key
  _ → Nothing

-- | Resolve a key to its representative node and the nodes of its class, or
-- 'Nothing' for a key that names no component of this result.
resolve ∷ Connectivity → ComponentKey → Maybe (Node, [Node])
resolve c key@(ComponentKey origin _ _ _) = do
  (nid, rep) ← tileNode c origin
  _ ← if nodeClass rep == nid then Just () else Nothing
  members ← IntMap.lookup nid (cMembers c)
  nodes ← mapM (`IntMap.lookup` cNodes c) members
  range ← nodeRange c rep
  let ok axis lo hi param
        | nodeAxes rep .&. axisBit axis /= 0 = maybe False (\v → toInteger (axisValue v) >= lo && toInteger (axisValue v) < hi) param
        | otherwise = param == Nothing
      ComponentKey _ px py pz = key
  if ok 0 (rangeXLo range) (rangeXHi range) px && ok 1 (rangeYLo range) (rangeYHi range) py && ok 2 (rangeZLo range) (rangeZHi range) pz
    then Just (rep, nodes)
    else Nothing

-- | Whether the component is initially exterior: connected through positive-area
-- openings to the upper Z boundary. 'Nothing' for a key that names no component.
isExterior ∷ Connectivity → ComponentKey → Maybe Bool
isExterior c key = do
  (rep, _) ← resolve c key
  pure (IntSet.member (nodeClass rep) (cExterior c))

-- | The member of a node under the key's parameters, as a range of cells.
memberRange ∷ Connectivity → ComponentKey → Node → Maybe CellRange
memberRange c (ComponentKey _ px py pz) node = do
  r ← nodeRange c node
  let narrow axis param lo hi
        | nodeAxes node .&. axisBit axis /= 0 = case param of
            Just v | toInteger (axisValue v) >= lo && toInteger (axisValue v) < hi → Just (toInteger (axisValue v), toInteger (axisValue v) + 1)
            _ → Nothing
        | otherwise = Just (lo, hi)
  (x0, x1) ← narrow 0 px (rangeXLo r) (rangeXHi r)
  (y0, y1) ← narrow 1 py (rangeYLo r) (rangeYHi r)
  (z0, z1) ← narrow 2 pz (rangeZLo r) (rangeZHi r)
  pure (CellRange x0 x1 y0 y1 z0 z1)

-- | The ranges of cells that make up a component, one per box of its class: the
-- box under the component's parameters. The description is compressed: its size
-- is the number of boxes in the class, never the number of cells.
componentRanges ∷ Connectivity → ComponentKey → Maybe [CellRange]
componentRanges c key = do
  (_, nodes) ← resolve c key
  pure (mapMaybe (memberRange c key) nodes)

-- | Whether a tile is a cell of the component.
componentContains ∷ Connectivity → ComponentKey → TileCoord → Bool
componentContains c key tile = componentOf c tile == Just key

-- ---------------------------------------------------------------------------
-- Relations

-- | The slab of cells of a range on one side of an axis: the last layer
-- (@high@) or the first layer.
slab ∷ Int → Bool → CellRange → CellRange
slab axis high r = case axis of
  0 → r {rangeXLo = if high then rangeXHi r - 1 else rangeXLo r, rangeXHi = if high then rangeXHi r else rangeXLo r + 1}
  1 → r {rangeYLo = if high then rangeYHi r - 1 else rangeYLo r, rangeYHi = if high then rangeYHi r else rangeYLo r + 1}
  _ → r {rangeZLo = if high then rangeZHi r - 1 else rangeZLo r, rangeZHi = if high then rangeZHi r else rangeZLo r + 1}

axisOf ∷ Int → Axis
axisOf 0 = AxisX
axisOf 1 = AxisY
axisOf _ = AxisZ

-- | The relations among the nodes of a component: for each box of the class and
-- each axis, the relation to its upper neighbour when the two connect through
-- their shared face. Both ends of a relation belong to the same class, so each
-- is listed once, from its lower end.
componentRelations ∷ Connectivity → ComponentKey → Maybe [PortalRelation]
componentRelations c key = do
  (_, nodes) ← resolve c key
  pure (concatMap (relationsFrom c key) nodes)

relationsFrom ∷ Connectivity → ComponentKey → Node → [PortalRelation]
relationsFrom c key node =
  [ PortalRelation (slab axis True lower) (slab axis False upper) (axisOf axis)
  | axis ← [0, 1, 2]
  , Just upperNode ← [forward c node axis]
  , joined axis (nodeKind node) (nodeKind upperNode)
  , Just lower ← [memberRange c key node]
  , Just upper ← [memberRange c key upperNode]
  ]

-- | The neighbouring node one lattice step up an axis, when it exists and holds
-- empty space.
forward ∷ Connectivity → Node → Int → Maybe Node
forward c node axis = do
  let size@(nx, ny, nz) = latticeSize c
      (i, j, k) = decodeLattice size (nodeLattice node)
      (sx, sy, sz) = strides size
      (position, limit, step) = case axis of
        0 → (i, nx, sx)
        1 → (j, ny, sy)
        _ → (k, nz, sz)
  if position + 1 >= limit then Nothing else Just ()
  nid ← IntMap.lookup (nodeLattice node + step) (cNodeAt c)
  IntMap.lookup nid (cNodes c)

-- | Every portal relation of the result, each between whole boxes. Its length is
-- the figure the relation limit bounds.
portalRelations ∷ Connectivity → [PortalRelation]
portalRelations c = mapMaybe build (toList (cRelations c))
  where
    build (Relation a b axis) = do
      na ← IntMap.lookup a (cNodes c)
      nb ← IntMap.lookup b (cNodes c)
      ra ← nodeRange c na
      rb ← nodeRange c nb
      pure (PortalRelation (slab axis True ra) (slab axis False rb) (axisOf axis))

-- ---------------------------------------------------------------------------
-- Boundary

-- | The boundary of a component, compressed: for every box of the class and each
-- of the six faces of the box's members, the faces whose across tiles are not
-- members of the component, with the layer of member cells at the face and what
-- lies across. A face across a coordinate limit has no tiles. The size of the
-- description is at most six per box of the class, whatever the extent of the
-- component, and no exposed tile is enumerated.
--
-- Whether two member tiles that touch are joined directly through their shared
-- face is not boundary information: a face between two members of the component
-- is not listed even when it is sealed.
componentBoundary ∷ Connectivity → ComponentKey → Maybe [BoundaryFace]
componentBoundary c key = do
  (_, nodes) ← resolve c key
  pure (concatMap (boundaryOf c key) nodes)

boundaryOf ∷ Connectivity → ComponentKey → Node → [BoundaryFace]
boundaryOf c key node = case (memberRange c key node, nodeRange c node) of
  (Just member, Just box) → catMaybes [face member box axis high | axis ← [0, 1, 2], high ← [False, True]]
  _ → []
  where
    size@(nx, ny, nz) = latticeSize c
    (i, j, k) = decodeLattice size (nodeLattice node)
    (sx, sy, sz) = strides size
    faceKind axis high = case (axis, high) of
      (0, True) → WallFace East
      (0, False) → WallFace West
      (1, True) → WallFace South
      (1, False) → WallFace North
      (_, True) → TopFace
      (_, False) → BottomFace
    bounds r axis = case axis of
      0 → (rangeXLo r, rangeXHi r)
      1 → (rangeYLo r, rangeYHi r)
      _ → (rangeZLo r, rangeZHi r)
    isParameter axis = nodeAxes node .&. axisBit axis /= 0
    face member box axis high =
      let (mLo, mHi) = bounds member axis
          (bLo, bHi) = bounds box axis
          layer = slab axis high member
          shifted = shiftSlab axis (if high then 1 else -1) layer
          limitHit = if high then mHi >= 2 ^ (62 ∷ Int) else mLo <= negate (2 ^ (62 ∷ Int))
          interior = if high then mHi < bHi else mLo > bLo
       in if limitHit
            then Just (BoundaryFace layer (faceKind axis high) AcrossLimit)
            else
              if interior
                then Just (BoundaryFace layer (faceKind axis high) (AcrossTiles shifted AcrossOtherVoid))
                else
                  let (position, limit, step) = case axis of
                        0 → (i, nx, sx)
                        1 → (j, ny, sy)
                        _ → (k, nz, sz)
                      target = nodeLattice node + (if high then step else negate step)
                      inRange = if high then position + 1 < limit else position > 0
                      neighbour = if inRange then IntMap.lookup target (cNodeAt c) >>= (`IntMap.lookup` cNodes c) else Nothing
                   in case neighbour of
                        Nothing → Just (BoundaryFace layer (faceKind axis high) (AcrossTiles shifted AcrossSolid))
                        Just other
                          | nodeClass other == nodeClass node && not (isParameter axis) → Nothing
                          | otherwise → Just (BoundaryFace layer (faceKind axis high) (AcrossTiles shifted AcrossOtherVoid))

shiftSlab ∷ Int → Integer → CellRange → CellRange
shiftSlab axis by r = case axis of
  0 → r {rangeXLo = rangeXLo r + by, rangeXHi = rangeXHi r + by}
  1 → r {rangeYLo = rangeYLo r + by, rangeYHi = rangeYHi r + by}
  _ → r {rangeZLo = rangeZLo r + by, rangeZHi = rangeZHi r + by}
