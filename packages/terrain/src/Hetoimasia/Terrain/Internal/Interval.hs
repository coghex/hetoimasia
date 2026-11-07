-- | Disjoint half-open Z interval maps and the single-step view over them.
--
-- An interval map keys each interval by its inclusive lower end and holds its
-- exclusive upper end and a value. 'spanAt' answers, for one level, the
-- maximal interval or gap that contains it; the caller composes several maps
-- by stepping to the nearest enclosing boundary, so a long empty or removed
-- stretch is crossed in one step and never visited level by level.
--
-- State, ownership and lifetime: none. Pure, immutable values.
module Hetoimasia.Terrain.Internal.Interval
  ( IntervalMap
  , Span (..)
  , spanAt
  , spanAtSet
  , insertDisjoint
  , insertCoalesced
  ) where

import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Hetoimasia.Terrain.Internal.Cell (bottomLevel, topExclusive)

-- | Intervals keyed by their inclusive lower end; the value holds the
-- exclusive upper end and the interval's payload.
type IntervalMap a = Map Int64 (Int64, a)

-- | The maximal run around a level: @[spanLo, spanHi)@, either covered by an
-- interval ('Just' its value) or a gap ('Nothing').
data Span a = Span
  { spanLo ∷ !Int64
  , spanHi ∷ !Int64
  , spanValue ∷ !(Maybe a)
  }

-- | The span containing level @z@, for any level in the supported range.
spanAt ∷ IntervalMap a → Int64 → Span a
spanAt intervals z = case Map.lookupLE z intervals of
  Just (lo, (hi, value))
    | z < hi → Span lo hi (Just value)
    | otherwise → Span hi nextLo Nothing
  Nothing → Span bottomLevel nextLo Nothing
  where
    nextLo = maybe topExclusive fst (Map.lookupGT z intervals)

-- | The same view over a canonical set of removed intervals (inclusive start to
-- exclusive end), searched in place: no copy of the set is made, so the work is
-- logarithmic in the intervals held and nothing is allocated for those outside
-- the neighbourhood of @z@.
spanAtSet ∷ Map Int64 Int64 → Int64 → Span ()
spanAtSet set z = case Map.lookupLE z set of
  Just (lo, hi)
    | z < hi → Span lo hi (Just ())
    | otherwise → Span hi nextLo Nothing
  Nothing → Span bottomLevel nextLo Nothing
  where
    nextLo = maybe topExclusive fst (Map.lookupGT z set)

-- | Insert @[lo, hi)@, or 'Nothing' if it overlaps an interval already there.
-- Touching intervals do not overlap.
insertDisjoint ∷ Int64 → Int64 → a → IntervalMap a → Maybe (IntervalMap a)
insertDisjoint lo hi value intervals
  | overlapsBelow = Nothing
  | overlapsAbove = Nothing
  | otherwise = Just (Map.insert lo (hi, value) intervals)
  where
    overlapsBelow = case Map.lookupLE lo intervals of
      Just (_, (prevHi, _)) → prevHi > lo
      Nothing → False
    overlapsAbove = case Map.lookupGT lo intervals of
      Just (nextLo, _) → nextLo < hi
      Nothing → False

-- | Add @[lo, hi)@ to a canonical set of sorted, disjoint, coalesced
-- intervals, merging every interval it overlaps or touches into one. The work
-- is logarithmic plus the number of intervals absorbed.
insertCoalesced ∷ Int64 → Int64 → Map Int64 Int64 → Map Int64 Int64
insertCoalesced lo hi set =
  Map.union (Map.insert lo' hi' below') above'
  where
    (below, rest) = Map.spanAntitone (< lo) set
    (lo', hi0, below') = case Map.lookupMax below of
      Just (k, e) | e >= lo → (k, max hi e, Map.deleteMax below)
      _ → (lo, hi, below)
    (absorbed, above') = Map.spanAntitone (<= hi0) rest
    hi' = maximum (hi0 : Map.elems absorbed)
