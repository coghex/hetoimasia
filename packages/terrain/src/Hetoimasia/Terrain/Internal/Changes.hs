-- | The retained-replacement overlay behind "Hetoimasia.Terrain.Changes".
--
-- Private to the package: the constructor is reachable only from inside, so a
-- value is always canonical. Per column the overlay is a sorted set of
-- disjoint half-open runs keyed by lower level, each tagged with a
-- 'Replacement'; no two adjacent runs carry the same tag, and a column with no
-- run has no entry.
--
-- State, ownership and lifetime: none. Pure, immutable values.
module Hetoimasia.Terrain.Internal.Changes
  ( Changes (..)
  , Replacement (..)
  , emptyChanges
  , replacementRunMap
  , assignRange
  , meetReplacement
  ) where

import Data.Bits ((.&.))
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Hetoimasia.Terrain.Internal.Cell (Column)
import Hetoimasia.Terrain.Internal.Interval (IntervalMap)
import Hetoimasia.Terrain.Internal.Shape (CornerMask, cornerMaskValue, mkCornerMask)

-- | What a run does to the levels it covers: makes them air, or limits each
-- solid level to a corner mask. A mask is never zero, since zero is air, and a
-- replacement never creates material: a level whose source cell is air stays
-- air whatever its tag.
data Replacement
  = ReplaceAir
  | ReplaceMask !CornerMask
  deriving stock (Eq, Show)

-- | Canonical replacement runs per column, with the running totals of all runs
-- and of the mask-tagged ones among them.
data Changes = Changes
  { changeColumns ∷ !(Map Column (IntervalMap Replacement))
  , changeRuns ∷ !Int
  , changeMaskRuns ∷ !Int
  }
  deriving stock (Eq, Show)

-- | The fresh-session value: nothing replaced.
emptyChanges ∷ Changes
emptyChanges = Changes Map.empty 0 0

-- | A column's runs, as stored: stepping searches this map in place, so
-- building a view of a column copies nothing.
replacementRunMap ∷ Changes → Column → IntervalMap Replacement
replacementRunMap changes column = Map.findWithDefault Map.empty column (changeColumns changes)

-- | The replacement both tags keep: the corners that both leave set. Air is
-- mask zero, so it wins over any mask. Symmetric, associative and idempotent.
meetReplacement ∷ Replacement → Replacement → Replacement
meetReplacement ReplaceAir _ = ReplaceAir
meetReplacement _ ReplaceAir = ReplaceAir
meetReplacement (ReplaceMask a) (ReplaceMask b) =
  case mkCornerMask (cornerMaskValue a .&. cornerMaskValue b) of
    Right mask | cornerMaskValue mask /= 0 → ReplaceMask mask
    _ → ReplaceAir

-- | Rewrite the replacement of every level of @[lo, hi)@ in one column: @f@
-- receives the level's current tag ('Nothing' for an untouched level) and
-- returns its new one ('Nothing' leaves it untouched). A run is split at either
-- end of the range, and equal neighbours coalesce, so no unaffected level
-- changes. The work is logarithmic plus the runs and gaps the range meets: the
-- result is built from the affected pieces once, never by reinserting them.
assignRange ∷ Column → Int64 → Int64 → (Maybe Replacement → Maybe Replacement) → Changes → Changes
assignRange column lo hi f (Changes columns total masks) =
  Changes
    (if Map.null updated then Map.delete column columns else Map.insert column updated columns)
    (total - Map.size existing + Map.size updated)
    (masks - maskRuns existing + maskRuns updated)
  where
    existing = Map.findWithDefault Map.empty column columns
    updated = Map.union (Map.union (Map.deleteMax keptBelow) rebuilt) (Map.deleteMin keptAbove)

    -- The rewritten pieces, with the run on either side that they may join,
    -- coalesced once in order and built as one map.
    rebuilt =
      Map.fromDistinctAscList
        [ (a, (b, p))
        | (a, b, p) ← coalescePieces (maybe [] (pure . triple) (Map.lookupMax keptBelow) ++ concatMap rewrite (walk lo inRange) ++ maybe [] (pure . triple) (Map.lookupMin keptAbove))
        ]
    triple (a, (b, p)) = (a, b, p)

    -- Only runs from the one before @lo@ to the one at @hi@ can differ, so the
    -- mask count is corrected from that neighbourhood alone.
    from = maybe lo fst (Map.lookupLT lo existing)
    maskRuns = Map.size . Map.filter (isMask . snd) . Map.takeWhileAntitone (<= hi) . Map.dropWhileAntitone (< from)
    isMask p = p /= ReplaceAir

    (below, rest) = Map.spanAntitone (< lo) existing
    (middle, above) = Map.spanAntitone (< hi) rest

    -- The run that straddles @lo@ is the last one starting below it: it keeps
    -- its part below the range, and its part inside joins the runs to rewrite.
    (keptBelow, straddle) = case Map.lookupMax below of
      Just (k, (e, p)) | e > lo → (Map.insert k (lo, p) below, [(lo, e, p)])
      _ → (below, [])
    overlapping = straddle ++ [(s, e, p) | (s, (e, p)) ← Map.toAscList middle]

    -- The last overlapping run may reach past @hi@: the rest stays as it is.
    (inRange, keptAbove) = case reverse overlapping of
      (s, e, p) : earlier | e > hi → (reverse ((s, hi, p) : earlier), Map.insert hi (e, p) above)
      _ → (overlapping, above)

    -- The runs and the gaps between them that tile @[lo, hi)@, in order.
    walk z pieces
      | z >= hi = []
      | otherwise = case pieces of
          (a, b, p) : more
            | a > z → (z, a, Nothing) : (a, b, Just p) : walk b more
            | otherwise → (a, b, Just p) : walk b more
          [] → [(z, hi, Nothing)]

    rewrite (a, b, current) = [(a, b, p) | p ← maybe (maybe [] pure current) pure (f current)]

-- | Merge each run with the next when they touch and carry the same tag. The
-- input is ascending and disjoint.
coalescePieces ∷ [(Int64, Int64, Replacement)] → [(Int64, Int64, Replacement)]
coalescePieces ((a, b, p) : (c, d, q) : rest)
  | b == c && p == q = coalescePieces ((a, d, p) : rest)
coalescePieces (piece : rest) = piece : coalescePieces rest
coalescePieces [] = []
