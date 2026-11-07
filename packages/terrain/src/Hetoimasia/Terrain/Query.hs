-- | Pure queries over a source plus retained removals.
--
-- Every function takes the immutable 'Source' and the 'Changes' of a session
-- ('emptyChanges' for the source alone) and answers from those two values
-- only, so a query consults the retained changes whether or not any cell is
-- resident, and the answer does not depend on the order or the history of
-- earlier requests.
--
-- * 'cellAt' answers one cell: 'Air' or a material with a shape.
--
-- * 'columnRuns' answers a complete finite half-open range of one column as
--   coalesced runs. The runs cover the whole requested interval, air included,
--   with no gap and no two adjacent equal runs. A range longer than
--   'limitRangeLevels', or one that would return more than 'limitReturnedRuns'
--   runs, is refused with the limit; it is never truncated.
--
-- * 'highestOccupied' answers the highest level holding a solid cell, or
--   'Nothing' for a column with none.
--
-- == Cost
--
-- Each query steps from one interval boundary to the next across the source's
-- layers, the column's patches and its removed intervals. A long run of air, of
-- solid or of removed cells is one step however many levels it spans, so a
-- query at a great depth, or across a wide gap, does work proportional to the
-- intervals it meets, not to the levels between them, and allocates no cell
-- for them. 'columnRuns' stops pulling runs as soon as it has found one more
-- than the limit allows.
--
-- State, ownership and lifetime: none. Every function is pure.
module Hetoimasia.Terrain.Query
  ( QueryLimits (..)
  , defaultQueryLimits
  , QueryError (..)
  , Run (..)
  , Occupied (..)
  , cellAt
  , columnRuns
  , highestOccupied
  ) where

import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Changes (Changes)
import Hetoimasia.Terrain.Coordinate
import Hetoimasia.Terrain.Internal.Cell (ZRange (..))
import Hetoimasia.Terrain.Internal.Column
import Hetoimasia.Terrain.Internal.Coordinate (AxisCoord (..))
import Hetoimasia.Terrain.Internal.Source (Source)
import Hetoimasia.Terrain.Shape (ShapeId)

-- | The caller's bounds on a range answer.
data QueryLimits = QueryLimits
  { limitReturnedRuns ∷ !Int
  , limitRangeLevels ∷ !Int
  }
  deriving stock (Eq, Show)

-- | The initial approved bounds: 1,024 returned runs and an 8,192-level range.
defaultQueryLimits ∷ QueryLimits
defaultQueryLimits = QueryLimits {limitReturnedRuns = 1024, limitRangeLevels = 8192}

-- | Why a range query was refused. Nothing partial is returned.
data QueryError
  = -- | The requested range spans more levels than the limit: the levels and
    -- the limit.
    RangeTooLarge !Integer !Int
  | -- | The answer would hold more runs than the limit; the field is the limit.
    TooManyRuns !Int
  deriving stock (Eq, Show)

-- | A maximal stretch of one value inside a range answer.
data Run = Run
  { runRange ∷ !ZRange
  , runCell ∷ !Cell
  }
  deriving stock (Eq, Show)

-- | The highest solid cell of a column.
data Occupied = Occupied
  { occupiedLevel ∷ !AxisCoord
  , occupiedMaterial ∷ !MaterialId
  , occupiedShape ∷ !ShapeId
  }
  deriving stock (Eq, Show)

-- | The cell at a tile.
cellAt ∷ Source → Changes → TileCoord → Cell
cellAt source changes (TileCoord x y z) =
  cellIn (columnView source changes (Column x y)) (axisValue z)

-- | The coalesced runs of one column over @[lo, hi)@, covering it exactly, or a
-- refusal.
columnRuns ∷ QueryLimits → Source → Changes → Column → ZRange → Either QueryError [Run]
columnRuns limits source changes column range@(ZRange lo hi)
  | zRangeLevels range > toInteger (limitRangeLevels limits) =
      Left (RangeTooLarge (zRangeLevels range) (limitRangeLevels limits))
  | length bounded > bound = Left (TooManyRuns bound)
  | otherwise = Right [Run (ZRange a b) c | (a, b, c) ← bounded]
  where
    bound = max 0 (limitReturnedRuns limits)
    bounded = take (bound + 1) (runsIn (columnView source changes column) lo hi)

-- | The highest solid cell of a column, or 'Nothing' for an empty column.
highestOccupied ∷ Source → Changes → Column → Maybe Occupied
highestOccupied source changes column = case highestIn (columnView source changes column) of
  Just (level, Solid material shape) → Just (Occupied (AxisCoord level) material shape)
  _ → Nothing
