-- | The retained-removal overlay behind "Hetoimasia.Terrain.Changes".
--
-- Private to the package: the constructor is reachable only from inside, so a
-- value is always canonical, per column a sorted, disjoint, coalesced set of
-- removed-cell intervals.
--
-- State, ownership and lifetime: none. Pure, immutable values.
module Hetoimasia.Terrain.Internal.Changes
  ( Changes (..)
  , emptyChanges
  , removedMap
  , addRemoval
  ) where

import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Hetoimasia.Terrain.Internal.Cell (Column)
import Hetoimasia.Terrain.Internal.Interval

-- | Canonical removed-cell intervals per column, with their running total.
data Changes = Changes
  { changeColumns ∷ !(Map Column (Map Int64 Int64))
  , changeIntervals ∷ !Int
  }
  deriving stock (Eq, Show)

-- | The fresh-session value: nothing removed.
emptyChanges ∷ Changes
emptyChanges = Changes Map.empty 0

-- | A column's removed intervals as an interval map for stepping.
removedMap ∷ Changes → Column → IntervalMap ()
removedMap changes column = case Map.lookup column (changeColumns changes) of
  Nothing → Map.empty
  Just set → Map.map (\hi → (hi, ())) set

-- | Add a removed @[lo, hi)@ to a column, merging every overlapped or touching
-- interval.
addRemoval ∷ Column → Int64 → Int64 → Changes → Changes
addRemoval column lo hi (Changes columns total) =
  Changes (Map.insert column updated columns) (total - Map.size existing + Map.size updated)
  where
    existing = Map.findWithDefault Map.empty column columns
    updated = insertCoalesced lo hi existing
