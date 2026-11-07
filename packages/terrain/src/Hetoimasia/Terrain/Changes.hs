-- | Retained removals: the session changes, separate from the source and from
-- any resident detail.
--
-- 'Changes' holds, per column, a sorted, disjoint, coalesced set of
-- removed-cell intervals. It is not an operation log: removing a cell next to
-- an already removed one grows an existing interval, and removing air or a cell
-- already removed records nothing. The source plus these changes is the
-- authority for what a cell holds; resident detail is a reconstructible cache.
--
-- 'removeCell' removes a whole cell: whatever the cell held, a ramp included, is
-- gone. It does not reshape a neighbour. It returns a complete new value or a
-- typed refusal, and the previous 'Changes' is untouched either way. The
-- revision counter, admission reservation and cancellation arbitration that
-- surround a commit are later service concerns, not this module's.
--
-- An empty 'Changes' ('emptyChanges') is a fresh session. 'mergeChanges' is the
-- pure union a later offload needs.
--
-- State, ownership and lifetime: none. Every value is immutable and every
-- function pure; a caller that wants a session owns the value it keeps.
module Hetoimasia.Terrain.Changes
  ( Changes
  , emptyChanges
  , removedIntervals
  , removedColumns
  , changeIntervalCount
  , changeColumnCount
  , changesBytes
  , changeColumnBytes
  , changeIntervalBytes

    -- * Removal
  , ChangeLimits (..)
  , ChangeError (..)
  , RemoveOutcome (..)
  , removeCell

    -- * Merging and restoring
  , mergeChanges
  , changesFromIntervals
  ) where

import qualified Data.Map.Strict as Map
import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Coordinate
import Hetoimasia.Terrain.Internal.Cell (ZRange (..))
import Hetoimasia.Terrain.Internal.Changes
import Hetoimasia.Terrain.Internal.Column
import Hetoimasia.Terrain.Internal.Source (Source)

-- | The columns that hold at least one removal, in column order.
removedColumns ∷ Changes → [Column]
removedColumns = Map.keys . changeColumns

-- | A column's removed intervals in ascending order, disjoint and with no two
-- adjacent.
removedIntervals ∷ Changes → Column → [ZRange]
removedIntervals changes column =
  [ ZRange lo hi
  | (lo, hi) ← Map.toAscList (Map.findWithDefault Map.empty column (changeColumns changes))
  ]

-- | The total number of retained intervals.
changeIntervalCount ∷ Changes → Int
changeIntervalCount = changeIntervals

-- | The number of columns with a removal.
changeColumnCount ∷ Changes → Int
changeColumnCount = Map.size . changeColumns

-- | Conservative accounted bytes of one retained interval: two endpoints.
changeIntervalBytes ∷ Int
changeIntervalBytes = 16

-- | Conservative accounted bytes of one column's index entry: the key, the
-- set header and a pointer.
changeColumnBytes ∷ Int
changeColumnBytes = 48

-- | The conservative accounted size of the retained changes. An accounting
-- figure, not a heap measurement.
changesBytes ∷ Changes → Int
changesBytes changes =
  changeColumnCount changes * changeColumnBytes + changeIntervalCount changes * changeIntervalBytes

-- | The caller's bound on retained removal intervals.
newtype ChangeLimits = ChangeLimits
  { limitRemovedIntervals ∷ Int
  }
  deriving stock (Eq, Show)

-- | Why a removal was refused.
data ChangeError
  = -- | The result would hold more intervals than the limit; the field is the
    -- limit.
    TooManyRemovedIntervals !Int
  deriving stock (Eq, Show)

-- | A successful removal: whether anything changed and the complete result. When
-- 'removeChanged' is false the result is the very value that was passed in.
data RemoveOutcome = RemoveOutcome
  { removeChanged ∷ !Bool
  , removeResult ∷ !Changes
  }
  deriving stock (Eq, Show)

-- | Remove the cell at a tile. Removing air, or a cell already removed, reports
-- @changed = False@ and records nothing. Otherwise the cell's level joins its
-- column's removed intervals, coalescing with a neighbour. A result that would
-- exceed the limit is refused and nothing is recorded.
removeCell ∷ ChangeLimits → Source → TileCoord → Changes → Either ChangeError RemoveOutcome
removeCell limits source (TileCoord x y z) changes = case cellIn view level of
  Air → Right (RemoveOutcome False changes)
  Solid {} →
    let updated = addRemoval column level (level + 1) changes
     in if changeIntervals updated > limitRemovedIntervals limits
          then Left (TooManyRemovedIntervals (limitRemovedIntervals limits))
          else Right (RemoveOutcome True updated)
  where
    column = Column x y
    level = axisValue z
    view = columnView source changes column

-- | Canonical changes from removed intervals, as an offload or reload hands them
-- back: overlapping and touching inputs are merged, whatever their order. A
-- result with more intervals than the limit is refused. No cell of an interval
-- is visited.
changesFromIntervals ∷ ChangeLimits → [(Column, ZRange)] → Either ChangeError Changes
changesFromIntervals limits intervals
  | changeIntervals changes > limitRemovedIntervals limits =
      Left (TooManyRemovedIntervals (limitRemovedIntervals limits))
  | otherwise = Right changes
  where
    changes = foldl' (\acc (column, ZRange lo hi) → addRemoval column lo hi acc) emptyChanges intervals

-- | The union of two sets of removals, canonical and coalesced. It is symmetric
-- and associative, so offloaded changes merge in any grouping.
mergeChanges ∷ Changes → Changes → Changes
mergeChanges a b = Map.foldlWithKey' addColumn a (changeColumns b)
  where
    addColumn acc column set = Map.foldlWithKey' (\inner lo hi → addRemoval column lo hi inner) acc set
