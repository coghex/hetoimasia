-- | Region-local coverage and the conservative charges derived from it.
--
-- A 'Coverage' is an exact set of cells inside one region: per column, a
-- sorted list of disjoint, non-adjacent half-open level intervals. It is never
-- widened to a bounding box: two separated intervals stay separate, so a union
-- of disjoint demands does not authorize filling the unknown cells between
-- them. Its constructor is private; every value comes from a checked box.
module Hetoimasia.Terrain.Internal.Residency.Coverage
  ( Coverage
  , CoverageError (..)
  , coverageBox
  , coverageTile
  , coverageUnion
  , coverageDifference
  , coverageIntersects
  , coverageSubset
  , coverageIsEmpty
  , coverageCells
  , coverageColumns
  , coverageSegments
  , coverageColumnSet
  , coverageIntervals

    -- * Charges
  , Cost (..)
  , costBytes
  , reserveCost
  , removalResidentGrowthBytes
  , regionMetadataBytes
  , interestRecordBytes
  , holdRecordBytes
  , commandRecordBytes
  , descriptionBytes
  , scratchBytes
  , removalRetainedBytes
  , removalStagingBytes
  , checkedAdd
  , checkedMul
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Word (Word64)
import Hetoimasia.Terrain.Changes (changeColumnBytes, changeIntervalBytes)
import Hetoimasia.Terrain.Coordinate (LocalCoord, localX, localY, localZ)
import Hetoimasia.Terrain.Resident (columnIndexBytes)

-- | A set of cells inside one region.
newtype Coverage = Coverage (Map (Int, Int) [(Int, Int)])
  deriving stock (Eq, Ord, Show)

-- | Why a box was refused.
data CoverageError
  = -- | An end is not above its start.
    EmptyBox
  | -- | The box leaves the region's @16 x 16 x 32@ cells.
    BoxOutsideRegion
  deriving stock (Eq, Show)

-- | The cells @x0 <= x < x1@, @y0 <= y < y1@, @z0 <= z < z1@ (region-local).
coverageBox ∷ Int → Int → Int → Int → Int → Int → Either CoverageError Coverage
coverageBox x0 x1 y0 y1 z0 z1
  | x0 >= x1 || y0 >= y1 || z0 >= z1 = Left EmptyBox
  | x0 < 0 || y0 < 0 || z0 < 0 || x1 > 16 || y1 > 16 || z1 > 32 = Left BoxOutsideRegion
  | otherwise = Right (Coverage (Map.fromList [((x, y), [(z0, z1)]) | x ← [x0 .. x1 - 1], y ← [y0 .. y1 - 1]]))

-- | One cell.
coverageTile ∷ LocalCoord → Coverage
coverageTile local =
  Coverage (Map.singleton (fromIntegral (localX local), fromIntegral (localY local)) [(z, z + 1)])
  where
    z = fromIntegral (localZ local)

normalize ∷ [(Int, Int)] → [(Int, Int)]
normalize = merge . filter (\(a, b) → a < b) . sortPairs
  where
    sortPairs = Set.toAscList . Set.fromList
    merge ((a, b) : (c, d) : rest)
      | c <= b = merge ((a, max b d) : rest)
      | otherwise = (a, b) : merge ((c, d) : rest)
    merge other = other

-- | Remove @cut@ from @from@ (both normalized).
subtractIntervals ∷ [(Int, Int)] → [(Int, Int)] → [(Int, Int)]
subtractIntervals from [] = from
subtractIntervals [] _ = []
subtractIntervals ((a, b) : rest) cuts@((c, d) : cuts')
  | d <= a = subtractIntervals ((a, b) : rest) cuts'
  | c >= b = (a, b) : subtractIntervals rest cuts
  | otherwise =
      [(a, c) | a < c]
        <> (if d < b then subtractIntervals ((d, b) : rest) cuts' else subtractIntervals rest cuts)

overlap ∷ [(Int, Int)] → [(Int, Int)] → Bool
overlap [] _ = False
overlap _ [] = False
overlap xs@((a, b) : xs') ys@((c, d) : ys')
  | b <= c = overlap xs' ys
  | d <= a = overlap xs ys'
  | otherwise = True

coverageUnion ∷ Coverage → Coverage → Coverage
coverageUnion (Coverage a) (Coverage b) = Coverage (Map.unionWith (\x y → normalize (x <> y)) a b)

-- | The cells of the first that are not in the second.
coverageDifference ∷ Coverage → Coverage → Coverage
coverageDifference (Coverage a) (Coverage b) =
  Coverage (Map.filter (not . null) (Map.mapWithKey (\k ivs → subtractIntervals ivs (Map.findWithDefault [] k b)) a))

coverageIntersects ∷ Coverage → Coverage → Bool
coverageIntersects (Coverage a) (Coverage b) = or (Map.elems (Map.intersectionWith overlap a b))

coverageIsEmpty ∷ Coverage → Bool
coverageIsEmpty (Coverage a) = Map.null a

-- | Every cell of the first is in the second.
coverageSubset ∷ Coverage → Coverage → Bool
coverageSubset a b = coverageIsEmpty (coverageDifference a b)

-- | The number of cells.
coverageCells ∷ Coverage → Word64
coverageCells (Coverage a) = foldl' (\n ivs → n + sum [fromIntegral (e - s) | (s, e) ← ivs]) 0 (Map.elems a)

-- | The number of columns with at least one cell.
coverageColumns ∷ Coverage → Word64
coverageColumns (Coverage a) = fromIntegral (Map.size a)

-- | The number of separate intervals, each at most one stored segment.
coverageSegments ∷ Coverage → Word64
coverageSegments (Coverage a) = fromIntegral (sum (map length (Map.elems a)))

coverageColumnSet ∷ Coverage → Set (Int, Int)
coverageColumnSet (Coverage a) = Map.keysSet a

-- | Columns with their intervals, ascending.
coverageIntervals ∷ Coverage → [((Int, Int), [(Int, Int)])]
coverageIntervals (Coverage a) = Map.toAscList a

-- ---------------------------------------------------------------------------
-- Charges

-- | What the data layer reports it stored, or the model derives as an upper
-- bound for a reservation. Plain data: a figure is checked where it is used.
data Cost = Cost
  { costColumns ∷ !Word64
  , costSegments ∷ !Word64
  , costPayloadBytes ∷ !Word64
  }
  deriving stock (Eq, Ord, Show)

checkedAdd ∷ Word64 → Word64 → Maybe Word64
checkedAdd a b = let s = toInteger a + toInteger b in if s > toInteger (maxBound ∷ Word64) then Nothing else Just (fromInteger s)

checkedMul ∷ Word64 → Word64 → Maybe Word64
checkedMul a b = let p = toInteger a * toInteger b in if p > toInteger (maxBound ∷ Word64) then Nothing else Just (fromInteger p)

-- | The accounted resident bytes of a cost: 48 per column index entry, 32 per
-- segment of metadata and the payload (the figures of
-- "Hetoimasia.Terrain.Resident" and "Hetoimasia.Terrain.Segment"). 'Nothing' when
-- the arithmetic does not fit.
costBytes ∷ Cost → Maybe Word64
costBytes (Cost columns segments payload) = do
  c ← checkedMul columns (fromIntegral columnIndexBytes)
  s ← checkedMul segments segmentBytes
  cs ← checkedAdd c s
  checkedAdd cs payload
  where
    segmentBytes = 32

-- | The conservative cost of making @delta@ known in one region, whatever else is
-- or becomes known there, and whatever order other work completes or cancels in:
--
-- * a column index entry for every column of @delta@. The data layer keeps one
--   index entry per column across all vertical regions, but a region is charged
--   for its own columns and keeps that charge until it is released, so evicting
--   one region never leaves another under-charged (the model over-charges, never
--   under-charges, the shared index). A job does not depend on any other job to
--   fund its columns.
-- * at most one segment per interval of @delta@ (merging only lowers the count);
-- * the dense payload bound, 64 bytes, per interval: an interval becomes, or
--   merges into, one segment of at most 32 cells, and a segment's payload is at
--   most two bytes per cell. Merging into segments that already exist can raise
--   the payload of the merged segment (a uniform 31-cell segment is two bytes,
--   the merged dense segment 64), so a figure proportional to the new cells alone
--   would not bound the growth.
reserveCost ∷ Coverage → Cost
reserveCost delta =
  Cost
    { costColumns = coverageColumns delta
    , costSegments = coverageSegments delta
    , costPayloadBytes = 64 * coverageSegments delta
    }

-- | The most a whole-cell removal can raise the payload of the segment it edits:
-- a segment's payload is at least 2 bytes (uniform) and at most 64 (dense, 32
-- cells), and the edit rebuilds exactly that one segment.
removalResidentGrowthBytes ∷ Word64
removalResidentGrowthBytes = 62

-- | Fixed metadata charged for each resident region, however little of it is
-- known: the region key, its coverage index and its bookkeeping. This is what
-- keeps vertical-region residency bounded when the horizontal column count is
-- fixed.
regionMetadataBytes ∷ Word64
regionMetadataBytes = 256

-- | One caller's interest in one region (staging).
interestRecordBytes ∷ Word64
interestRecordBytes = 64

-- | One hold's reference to one region (staging).
holdRecordBytes ∷ Word64
holdRecordBytes = 64

-- | An accepted command's record with @n@ regions (staging).
commandRecordBytes ∷ Word64 → Word64
commandRecordBytes n = 128 + 32 * n

-- | A pending latest-value camera description naming @n@ regions (staging).
descriptionBytes ∷ Word64 → Word64
descriptionBytes n = 128 + 64 * n

-- | The scratch a load of @delta@ needs (staging): a fixed frame plus a full
-- extra copy of its cells at two bytes each.
scratchBytes ∷ Coverage → Word64
scratchBytes delta = 256 + 2 * coverageCells delta

-- | The worst-case retained growth of one whole-cell removal: one new removed
-- interval and one new column index entry (the figures of
-- "Hetoimasia.Terrain.Changes"). A removal never splits an interval.
removalRetainedBytes ∷ Word64
removalRetainedBytes = fromIntegral (changeIntervalBytes + changeColumnBytes)

-- | The staging a removal needs: the decoded segment, its rebuilt copy, the
-- staged overlay and the result settlement.
removalStagingBytes ∷ Word64
removalStagingBytes = 512
