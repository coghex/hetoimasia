-- | Retained replacements: the session changes, separate from the source and
-- from any resident detail.
--
-- 'Changes' holds, per column, a sorted, disjoint, coalesced set of half-open
-- level runs, each tagged 'ReplaceAir' or 'ReplaceMask'. It is not an
-- operation log: an edit inside a run splits it, an edit next to a run with the
-- same tag grows it, and every level outside the edit keeps its tag. The source
-- plus these changes is the authority for what a cell holds; resident detail is
-- a reconstructible cache.
--
-- A run tagged 'ReplaceMask' limits each of its levels to that corner mask of
-- the level's own source material, so a run that spans a source material
-- boundary reads each level with its own material, and a level whose source
-- cell is air reads as air under any tag. A replacement never creates material,
-- and a mask is never zero: zero is air.
--
-- 'removeCell' removes a whole cell: whatever the cell held, a ramp or a
-- narrowed cell included, is gone, and the level takes the air tag. It does not
-- reshape a neighbour. 'narrowCell' is the conditional edit: it clears corners
-- of a cell the caller observed, and only while that cell is still current.
-- Both return a complete new value or a typed refusal, and the previous
-- 'Changes' is untouched either way. The revision counter, admission
-- reservation and cancellation arbitration that surround a commit are later
-- service concerns, not this module's.
--
-- An empty 'Changes' ('emptyChanges') is a fresh session.
--
-- Accounting has two families of figures. 'changeIntervalBytes',
-- 'changeColumnBytes' and 'runsMeetingLevels' describe an overlay that holds
-- only air runs, as every removal-only client builds one, and keep their
-- values. 'replacementRunBytes' and 'replacementRunsMeetingLevels' bound any
-- overlay: alternating tags can occupy one run per level. 'changesBytes' and
-- 'changeIntervalCount' charge and count the runs actually retained, air or
-- mask, and 'ChangeLimits' bounds that same count.
--
-- State, ownership and lifetime: none. Every value is immutable and every
-- function pure; a caller that wants a session owns the value it keeps.
module Hetoimasia.Terrain.Changes
  ( Changes
  , Replacement (..)
  , emptyChanges
  , removedIntervals
  , removedColumns
  , replacementRuns
  , replacedColumns
  , changeIntervalCount
  , changeColumnCount
  , changesBytes
  , changeColumnBytes
  , changeIntervalBytes
  , runsMeetingLevels
  , replacementRunBytes
  , replacementRunsMeetingLevels

    -- * Removal
  , ChangeLimits (..)
  , ChangeError (..)
  , RemoveOutcome (..)
  , removeCell

    -- * Narrowing
  , NarrowError (..)
  , narrowedCell
  , narrowCell

    -- * Merging and restoring
  , mergeChanges
  , changesFromIntervals
  , changesFromReplacements
  ) where

import Control.Monad (guard)
import Data.Bits (complement, (.&.))
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Coordinate
import Hetoimasia.Terrain.Internal.Cell (ZRange (..))
import Hetoimasia.Terrain.Internal.Changes
import Hetoimasia.Terrain.Internal.Column
import Hetoimasia.Terrain.Internal.Shape (CornerMask, cornerMaskValue, resolveCorner, shapeIdValue)
import Hetoimasia.Terrain.Internal.Source (Source)

-- | The columns that hold at least one air run, in column order.
removedColumns ∷ Changes → [Column]
removedColumns changes = [column | (column, runs) ← Map.toAscList (changeColumns changes), any ((== ReplaceAir) . snd) runs]

-- | The columns that hold at least one run of either tag, in column order.
replacedColumns ∷ Changes → [Column]
replacedColumns = Map.keys . changeColumns

-- | A column's removed intervals in ascending order: its air runs, disjoint
-- and with no two adjacent. A level narrowed to a nonzero mask is not removed
-- and is in none of them, so a client that rebuilds changes from these
-- intervals ('changesFromIntervals') keeps only what was removed.
removedIntervals ∷ Changes → Column → [ZRange]
removedIntervals changes column =
  [ ZRange lo hi
  | (lo, (hi, ReplaceAir)) ← Map.toAscList (replacementRunMap changes column)
  ]

-- | A column's runs of either tag in ascending order, disjoint and with no
-- two adjacent runs of the same tag.
replacementRuns ∷ Changes → Column → [(ZRange, Replacement)]
replacementRuns changes column =
  [(ZRange lo hi, p) | (lo, (hi, p)) ← Map.toAscList (replacementRunMap changes column)]

-- | The total number of retained runs, air or mask.
changeIntervalCount ∷ Changes → Int
changeIntervalCount = changeRuns

-- | The number of columns with at least one retained run.
changeColumnCount ∷ Changes → Int
changeColumnCount = Map.size . changeColumns

-- | Conservative accounted bytes of one retained air run: two endpoints.
changeIntervalBytes ∷ Int
changeIntervalBytes = 16

-- | The most retained air runs of one column that can meet a range of @levels@
-- levels, for an overlay that holds only air runs: air runs are coalesced, so
-- two of them are a level apart, and @levels / 2 + 1@ of them can meet it. It
-- does not bound an overlay that holds masks: see
-- 'replacementRunsMeetingLevels'.
runsMeetingLevels ∷ Integral a ⇒ a → a
runsMeetingLevels levels = max 0 levels `div` 2 + 1

-- | Conservative accounted bytes of one retained mask run: two endpoints and
-- the mask, rounded to a word.
replacementRunBytes ∷ Int
replacementRunBytes = 24

-- | The most retained runs of one column, of either tag, that can meet a range
-- of @levels@ levels: alternating tags leave no gap, so one per level.
replacementRunsMeetingLevels ∷ Integral a ⇒ a → a
replacementRunsMeetingLevels = max 0

-- | Conservative accounted bytes of one column's index entry: the key, the
-- map header and a pointer.
changeColumnBytes ∷ Int
changeColumnBytes = 48

-- | The conservative accounted size of the retained changes: each column's
-- entry, each air run at 'changeIntervalBytes' and each mask run at
-- 'replacementRunBytes'. An accounting figure, not a heap measurement.
changesBytes ∷ Changes → Int
changesBytes changes =
  changeColumnCount changes * changeColumnBytes
    + (changeRuns changes - changeMaskRuns changes) * changeIntervalBytes
    + changeMaskRuns changes * replacementRunBytes

-- | The caller's bound on retained runs, air or mask. The field keeps its name
-- from the removal-only overlay.
newtype ChangeLimits = ChangeLimits
  { limitRemovedIntervals ∷ Int
  }
  deriving stock (Eq, Show)

-- | Why a removal was refused.
data ChangeError
  = -- | The result would hold more runs than the limit; the field is the
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
-- @changed = False@ and records nothing. Otherwise the cell's level takes the
-- air tag, splitting a run it sits inside and coalescing with a neighbouring
-- air run. A result that would exceed the limit is refused and nothing is
-- recorded.
removeCell ∷ ChangeLimits → Source → TileCoord → Changes → Either ChangeError RemoveOutcome
removeCell limits source (TileCoord x y z) changes = case occupiedKey of
  Nothing → Right (RemoveOutcome False changes)
  Just _ →
    let updated = assignRange column level (level + 1) (const (Just ReplaceAir)) changes
     in if changeRuns updated > limitRemovedIntervals limits
          then Left (TooManyRemovedIntervals (limitRemovedIntervals limits))
          else Right (RemoveOutcome True updated)
  where
    occupiedKey = cellShapeKey (cellIn view level)
    column = Column x y
    level = axisValue z
    view = columnView source changes column

-- | Why a conditional edit changed nothing. The first two depend only on what
-- the caller supplied and the cell they observed.
data NarrowError
  = -- | The expected cell and target are not a narrowing: the expected cell is
    -- air, a side identity other than 0, or a corner solid with mask 0, or the
    -- target equals the observed corners or sets one they do not. Decided
    -- before the current cell is read.
    InvalidNarrowing
  | -- | The pair is well formed, but the current cell differs from the
    -- expected one in material, family or value.
    StaleObservation
  | -- | The result would hold more runs than the limit; the field is the
    -- limit.
    NarrowTooManyRuns !Int
  deriving stock (Eq, Show)

-- | The cell a valid narrowing leaves, and 'Nothing' for an invalid pair. An
-- observed cell is side 0 or a corner solid with a nonzero mask; side 0 counts
-- as corners 15 for this check alone, so side 0 and corner 15 stay different
-- observations. The target must be a strict subset of the observed corners, and
-- the result keeps the observed material: 'Air' for target 0, otherwise a
-- corner solid.
narrowedCell ∷ Cell → CornerMask → Maybe Cell
narrowedCell expected target = do
  bits ← observed
  guard (wanted .&. complement bits == 0 && wanted /= bits)
  (material, _) ← cellOccupant expected
  pure (cornerCell material target)
  where
    wanted = cornerMaskValue target
    observed = case expected of
      Solid _ side | shapeIdValue side == 0 → Just 15
      CornerSolid _ mask | cornerMaskValue mask /= 0 → Just (cornerMaskValue mask)
      _ → Nothing

-- | Narrow the cell at a tile from an observed cell to a corner mask, while the
-- observation still holds. An invalid pair is refused first, then a current
-- cell that is not the expected one, then a result over the limit; each leaves
-- the previous value untouched. A success always changes the cell: its level
-- takes the target as an air tag for 0 and a mask tag otherwise, splitting a
-- run it sits inside and coalescing with equal neighbours.
narrowCell ∷ ChangeLimits → Source → TileCoord → Cell → CornerMask → Changes → Either NarrowError Changes
narrowCell limits source (TileCoord x y z) expected target changes = case narrowedCell expected target of
  Nothing → Left InvalidNarrowing
  Just _
    | cellIn view level /= expected → Left StaleObservation
    | changeRuns updated > limitRemovedIntervals limits → Left (NarrowTooManyRuns (limitRemovedIntervals limits))
    | otherwise → Right updated
  where
    column = Column x y
    level = axisValue z
    view = columnView source changes column
    tag = maybe ReplaceAir (const (ReplaceMask target)) (resolveCorner target)
    updated = assignRange column level (level + 1) (const (Just tag)) changes

-- | Canonical changes from removed intervals, as an offload or reload hands them
-- back: overlapping and touching inputs are merged, whatever their order. A
-- result with more runs than the limit is refused. No cell of an interval is
-- visited. The result holds air runs only.
changesFromIntervals ∷ ChangeLimits → [(Column, ZRange)] → Either ChangeError Changes
changesFromIntervals limits intervals
  | changeRuns changes > limitRemovedIntervals limits =
      Left (TooManyRemovedIntervals (limitRemovedIntervals limits))
  | otherwise = Right changes
  where
    changes = foldl' (\acc (column, ZRange lo hi) → assignRange column lo hi (const (Just ReplaceAir)) acc) emptyChanges intervals

-- | Canonical changes from replacement runs of either tag, as a reload of a store's runs hands them
-- back: a later run replaces what an earlier one set at the same levels, touching runs of one tag
-- coalesce and whatever the order; a mask of zero is air. A result with more runs than the limit is
-- refused. No cell of a run is visited.
changesFromReplacements ∷ ChangeLimits → [(Column, ZRange, Replacement)] → Either ChangeError Changes
changesFromReplacements limits runs
  | changeRuns changes > limitRemovedIntervals limits =
      Left (TooManyRemovedIntervals (limitRemovedIntervals limits))
  | otherwise = Right changes
  where
    changes = foldl' (\acc (column, ZRange lo hi, tag) → assignRange column lo hi (const (Just (canonical tag))) acc) emptyChanges runs
    -- a mask of zero limits every corner away: it is air
    canonical (ReplaceMask m) | cornerMaskValue m == 0 = ReplaceAir
    canonical tag = tag

-- | The union of two sets of replacements, canonical and coalesced. A level
-- replaced by both keeps the corners both leave set: air wins over a mask, and
-- two masks meet bitwise, zero being air. The result is symmetric, associative
-- and idempotent with 'emptyChanges' as identity, so offloaded changes merge in
-- any grouping. Two air-only overlays merge to the union of their removals.
mergeChanges ∷ Changes → Changes → Changes
mergeChanges a b = Map.foldlWithKey' addColumn a (changeColumns b)
  where
    addColumn acc column runs = Map.foldlWithKey' (addRun column) acc runs
    addRun column acc lo (hi ∷ Int64, p) = assignRange column lo hi (Just . maybe p (`meetReplacement` p)) acc
