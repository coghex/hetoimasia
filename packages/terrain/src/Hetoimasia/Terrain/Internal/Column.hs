-- | Stepping through one column of source plus retained removals.
--
-- A column's content is the composition of three interval maps, in priority
-- order: the retained removals (air), the column's authored patches, and the
-- shared base layers; a level none of them covers is air. 'step' answers, for
-- one level, a run of constant content that ends at the nearest boundary of
-- any of the three, so a long empty, removed or solid stretch is one step. The
-- work of every query here is proportional to the intervals it crosses, never
-- to the levels between them.
--
-- State, ownership and lifetime: none. Pure, immutable values.
module Hetoimasia.Terrain.Internal.Column
  ( ColumnView
  , columnView
  , step
  , cellIn
  , runsIn
  , highestIn
  ) where

import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import Hetoimasia.Terrain.Internal.Cell
import Hetoimasia.Terrain.Internal.Changes
import Hetoimasia.Terrain.Internal.Interval
import Hetoimasia.Terrain.Internal.Source

-- | One column's three composed interval maps.
data ColumnView = ColumnView
  { viewBase ∷ !(IntervalMap Cell)
  , viewPatches ∷ !(IntervalMap Cell)
  , viewRemoved ∷ !(IntervalMap ())
  }

-- | The view of one column; building it reads only that column's records.
columnView ∷ Source → Changes → Column → ColumnView
columnView source changes column =
  ColumnView
    { viewBase = sourceLayerMap source
    , viewPatches = Map.findWithDefault Map.empty column (sourcePatchMap source)
    , viewRemoved = removedMap changes column
    }

-- | The run of constant content around level @z@: @(lo, hi, cell)@ with
-- @lo <= z < hi@. Not necessarily maximal; adjacent equal runs are coalesced by
-- the caller.
step ∷ ColumnView → Int64 → (Int64, Int64, Cell)
step view z = (lo, hi, cell)
  where
    base = spanAt (viewBase view) z
    patch = spanAt (viewPatches view) z
    removed = spanAt (viewRemoved view) z
    lo = maximum [spanLo base, spanLo patch, spanLo removed]
    hi = minimum [spanHi base, spanHi patch, spanHi removed]
    cell = case (spanValue removed, spanValue patch, spanValue base) of
      (Just (), _, _) → Air
      (Nothing, Just patched, _) → patched
      (Nothing, Nothing, Just layered) → layered
      (Nothing, Nothing, Nothing) → Air

-- | The cell at one level.
cellIn ∷ ColumnView → Int64 → Cell
cellIn view z = let (_, _, cell) = step view z in cell

-- | The coalesced runs covering @[lo, hi)@ exactly, produced lazily in
-- ascending order so a consumer can stop at a bound without computing the rest.
runsIn ∷ ColumnView → Int64 → Int64 → [(Int64, Int64, Cell)]
runsIn view lo hi = coalesce (go lo)
  where
    go z
      | z >= hi = []
      | otherwise =
          let (_, stop, cell) = step view z
              end = min stop hi
           in (z, end, cell) : go end
    coalesce ((a, b, c) : (b', e, c') : rest)
      | b == b' && c == c' = coalesce ((a, e, c) : rest)
    coalesce (run : rest) = run : coalesce rest
    coalesce [] = []

-- | The highest level holding a solid cell, searched downward one run at a
-- time from the top of the supported range, and 'Nothing' for an empty column.
highestIn ∷ ColumnView → Maybe (Int64, Cell)
highestIn view = go topExclusive
  where
    go top
      | top <= bottomLevel = Nothing
      | otherwise =
          let z = top - 1
              (lo, _, cell) = step view z
           in case cell of
                Air → go lo
                Solid {} → Just (z, cell)
