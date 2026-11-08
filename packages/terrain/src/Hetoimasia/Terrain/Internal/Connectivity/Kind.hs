-- | The content kinds the connectivity compiler distinguishes, and the table of
-- which pairs of face-adjacent kinds connect.
--
-- A /kind/ is air, a full block (shape 0) or one of the fifteen nonflat shapes:
-- 17 kinds. Materials never matter to connectivity. Every figure here is derived
-- from "Hetoimasia.Terrain.Opening", the one authority for where empty space can
-- pass: whether two neighbouring cells connect, whether a cell has any void, and
-- whether its top face opens over positive area are all answered by asking that
-- module about a representative pair of tiles. Nothing is hard-coded per shape
-- identity, so a corrected catalog corrects the compiler.
--
-- The table is translation invariant (a connection depends on the two kinds and
-- the direction alone), which is what lets one uniform box of cells be described
-- by a few flags instead of by its cells.
--
-- State, ownership and lifetime: none. The table is an immutable constant
-- computed on first use; it is shared, never mutated and never reset.
module Hetoimasia.Terrain.Internal.Connectivity.Kind
  ( Kind
  , kindCount
  , kindAir
  , kindBlock
  , kindOfCell
  , kindHasVoid
  , kindVoidCount
  , kindTopOpens
  , joined
  , joinedAlong
  , tableSize
  , tableProbe
  , unsupportedKind
  ) where

import Data.Array (Array, listArray, (!))
import Hetoimasia.Terrain.Coordinate (tileCoord)
import Hetoimasia.Terrain.Geometry (FaceKind (TopFace))
import Hetoimasia.Terrain.Internal.Cell (Cell (..))
import Hetoimasia.Terrain.Internal.Shape (allShapeIds, shapeIdValue)
import Hetoimasia.Terrain.Opening
  ( CellOpenings
  , airOpenings
  , cellComponents
  , cellPortals
  , connectCells
  , portalFace
  , shapeOpenings
  )

-- | A content kind: 0 for air, 1 for the full block and @1 + n@ for shape @n@.
type Kind = Int

-- | The number of kinds: air and the sixteen catalog identities.
kindCount ∷ Int
kindCount = 17

kindAir, kindBlock ∷ Kind
kindAir = 0
kindBlock = 1

-- | The kind of a cell, whatever its material.
kindOfCell ∷ Cell → Kind
kindOfCell Air = kindAir
kindOfCell (Solid _ shape) = 1 + shapeIdValue shape

openingsOf ∷ Kind → CellOpenings
openingsOf 0 = airOpenings
openingsOf kind = case drop (kind - 1) allShapeIds of
  (shape : _) → shapeOpenings shape
  [] → airOpenings

-- | The number of empty components in a cell of this kind.
kindVoidCount ∷ Kind → Int
kindVoidCount = length . cellComponents . openingsOf

-- | Whether a cell of this kind holds any empty space.
kindHasVoid ∷ Kind → Bool
kindHasVoid kind = kindVoidCount kind > 0

-- | A kind whose cell has more than one empty component. The compiler addresses
-- one component per cell, so such a kind cannot be compiled yet (the current
-- catalog has none).
unsupportedKind ∷ Kind → Bool
unsupportedKind kind = kindVoidCount kind > 1

-- | Whether the cell's top face has a portal of positive area: the opening
-- through which a topmost cell reaches the outside.
kindTopOpens ∷ Kind → Bool
kindTopOpens kind = any ((== TopFace) . portalFace) (cellPortals (openingsOf kind))

-- | The number of entries of the connection table: three axes, 17 kinds twice.
tableSize ∷ Int
tableSize = 3 * kindCount * kindCount

-- | The entry at an index in @[0, tableSize)@, forced. One entry is one exact
-- portal comparison, the unit the compiler counts as one step while it forces
-- the table.
tableProbe ∷ Int → Bool
tableProbe index = table ! index

-- | Whether a cell of the lower kind connects to the cell one step up the axis
-- (0 east, 1 south, 2 up) when that cell is of the upper kind: their portals
-- on the shared face overlap over positive area.
joined ∷ Int → Kind → Kind → Bool
joined axis lower upper = table ! ((axis * kindCount + lower) * kindCount + upper)

-- | Whether cells of one kind connect to each other along an axis.
joinedAlong ∷ Int → Kind → Bool
joinedAlong axis kind = joined axis kind kind

table ∷ Array Int Bool
table =
  listArray
    (0, tableSize - 1)
    [ connects axis lower upper
    | axis ← [0, 1, 2]
    , lower ← [0 .. kindCount - 1]
    , upper ← [0 .. kindCount - 1]
    ]

-- | Ask the opening authority about a lower cell at the origin and an upper cell
-- one step along the axis.
connects ∷ Int → Kind → Kind → Bool
connects axis lower upper = case (tileCoord 0 0 0, neighbour) of
  (Right origin, Right other) → not (null (connectCells origin (openingsOf lower) other (openingsOf upper)))
  _ → False
  where
    neighbour = case axis of
      0 → tileCoord 1 0 0
      1 → tileCoord 0 1 0
      _ → tileCoord 0 0 1
