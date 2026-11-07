-- | Sparse resident detail: the known column segments, independent of the
-- source and of the retained changes.
--
-- Resident detail is a sparse map from a column to its known segments. A
-- segment covers at most 32 consecutive levels inside one vertical region
-- (see "Hetoimasia.Terrain.Segment"). Coverage is explicit:
--
-- * a level inside a segment is /known/, and holds a value (possibly air);
-- * a level in no segment is /unmaterialized/ ('Nothing'), which is not air;
-- * two segments of one column are disjoint, and two in one region are not
--   adjacent (adjacent known levels in a region are one segment).
--
-- 'materialize' makes exactly the requested levels known and nothing else: a
-- top-only request creates one one-cell segment, never a 32-cell slab; two
-- requests far apart leave their gap unmaterialized; no request licenses
-- filling buried source cells. A region is an index key and never an allocated
-- 16 x 16 x 32 array. Values are computed from the same immutable source plus
-- all retained removals ("Hetoimasia.Terrain.Changes"), so a cell removed while
-- it was not resident is absent when it is materialized later.
-- 'discardRange' and 'discardRegion' drop resident detail only; they never
-- touch changes, so reconstructing afterwards yields the same answer.
--
-- Materializing again over known levels recomputes them from the authority, so
-- a stale value cannot survive a reconstruction. It re-derives the merged
-- segment's whole interval (at most 32 values) from source plus changes and
-- chooses the new encoding once; it never expands unknown depth to do so.
--
-- == State, ownership and lifetime
--
-- A 'Resident' is an immutable value; the arena that keeps it owns it, and every
-- operation returns a new value and leaves the old one unchanged, so a refusal
-- preserves the previous value. This module has no thread, no resource and no
-- disposal. Residency admission, eviction eligibility, revisions and offload
-- protocols belong to later services.
module Hetoimasia.Terrain.Resident
  ( Resident
  , emptyResident
  , ResidentError (..)
  , materialize
  , discardRange
  , discardRegion
  , discardColumn

    -- * Queries
  , residentPacked
  , residentCell
  , residentSegments
  , residentColumns

    -- * Accounting
  , ResidentStats (..)
  , residentStats
  , columnIndexBytes
  ) where

import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Changes (Changes)
import Hetoimasia.Terrain.Coordinate
import Hetoimasia.Terrain.Internal.Cell (ZRange (..))
import Hetoimasia.Terrain.Internal.Column
import Hetoimasia.Terrain.Internal.Coordinate (AxisCoord (..))
import Hetoimasia.Terrain.Palette
import Hetoimasia.Terrain.Segment
import Hetoimasia.Terrain.Source (Source)

-- | Known segments per column, each column's segments keyed by start level.
newtype Resident = Resident (Map Column (Map Int64 Segment))
  deriving stock (Eq, Show)

-- | Nothing known anywhere.
emptyResident ∷ Resident
emptyResident = Resident Map.empty

-- | Why a materialization was refused. The previous 'Resident' and 'Palette'
-- are unaffected.
data ResidentError
  = -- | The requested range spans more levels than the caller allows: the levels
    -- and the limit.
    MaterializeTooLarge !Integer !Int
  | ResidentPalette !PaletteError
  | ResidentSegment !SegmentError
  deriving stock (Eq, Show)

regionLevelsInt ∷ Int64
regionLevelsInt = 32

-- | Split @[a, hi)@ at the vertical region boundaries.
pieces ∷ Int64 → Int64 → [(Int64, Int64)]
pieces a hi
  | a >= hi = []
  | otherwise = let stop = min hi ((a `div` regionLevelsInt + 1) * regionLevelsInt) in (a, stop) : pieces stop hi

-- | Make the requested levels of a column known, from the source plus all
-- retained removals. @maxLevels@ bounds the range. The palette grows by the
-- materials first met; on any refusal nothing is returned.
materialize ∷ Int → Source → Changes → Palette → Resident → Column → ZRange → Either ResidentError (Palette, Resident)
materialize maxLevels source changes palette0 (Resident columns) column range@(ZRange lo hi)
  | zRangeLevels range > toInteger maxLevels = Left (MaterializeTooLarge (zRangeLevels range) maxLevels)
  | otherwise = do
      (palette, segments) ← foldlM' piece (palette0, Map.findWithDefault Map.empty column columns) (pieces lo hi)
      pure (palette, Resident (Map.insert column segments columns))
  where
    view = columnView source changes column
    piece (palette, segments) (a, b) = do
      let region = a `div` regionLevelsInt * regionLevelsInt
          inRegion = Map.takeWhileAntitone (< region + regionLevelsInt) (Map.dropWhileAntitone (< region) segments)
          touching = Map.filter (\s → toInteger a <= segmentEnd s && segStart s <= b) inRegion
          start = minimum (a : map segStart (Map.elems touching))
          end = maximum (b : map (fromInteger . segmentEnd) (Map.elems touching))
      (cells, palette') ← packRuns palette (runsIn view start end)
      built ← either (Left . ResidentSegment) Right (buildSegment (AxisCoord start) cells)
      pure (palette', Map.insert start built (Map.difference segments touching))
    segStart = (\(AxisCoord z) → z) . segmentStart

foldlM' ∷ (b → a → Either e b) → b → [a] → Either e b
foldlM' _ acc [] = Right acc
foldlM' f acc (x : xs) = f acc x >>= \acc' → foldlM' f acc' xs

packRuns ∷ Palette → [(Int64, Int64, Cell)] → Either ResidentError ([PackedCell], Palette)
packRuns palette0 = go palette0 []
  where
    go palette acc [] = Right (concat (reverse acc), palette)
    go palette acc ((a, b, cell) : rest) = do
      (packed, palette') ← either (Left . ResidentPalette) Right (internCell cell palette)
      go palette' (replicate (fromIntegral (b - a)) packed : acc) rest

-- | Forget the resident detail in @[lo, hi)@ of a column, trimming a segment
-- that straddles an end. Changes are untouched.
discardRange ∷ Column → ZRange → Resident → Resident
discardRange column (ZRange lo hi) (Resident columns) = case Map.lookup column columns of
  Nothing → Resident columns
  Just segments →
    let overlapping = Map.filter (\s → segStart s < hi && fromInteger (segmentEnd s) > lo) segments
        keep = Map.difference segments overlapping
        remnants = concatMap remnant (Map.elems overlapping)
        rebuilt = foldr (\s m → Map.insert (segStart s) s m) keep remnants
     in Resident (if Map.null rebuilt then Map.delete column columns else Map.insert column rebuilt columns)
  where
    segStart = (\(AxisCoord z) → z) . segmentStart
    remnant segment =
      [ built
      | (a, b) ← [(minBound, lo), (hi, maxBound)]
      , Just (first, cells) ← [segmentSlice segment a b]
      , Right built ← [buildSegment first cells]
      ]

-- | Forget every segment of one column.
discardColumn ∷ Column → Resident → Resident
discardColumn column (Resident columns) = Resident (Map.delete column columns)

-- | Forget everything resident in a region: the 16 x 16 columns and 32 levels it
-- names. A region key naming no supported level forgets nothing.
discardRegion ∷ RegionCoord → Resident → Resident
discardRegion (RegionCoord rx ry rz) resident@(Resident columns) =
  case mkZRange (toInteger rz * 32) (toInteger rz * 32 + 32) of
    Left _ → resident
    Right range →
      foldr (\column acc → discardRange column range acc) resident (filter inRegion (Map.keys columns))
  where
    inRegion (Column (AxisCoord x) (AxisCoord y)) = x `div` 16 == rx && y `div` 16 == ry

-- | The packed value at a tile, or 'Nothing' if the level is unmaterialized.
residentPacked ∷ Resident → TileCoord → Maybe PackedCell
residentPacked (Resident columns) (TileCoord x y z) = do
  segments ← Map.lookup (Column x y) columns
  (_, segment) ← Map.lookupLE (axisValue z) segments
  segmentLookup segment z

-- | The decoded cell at a tile, or 'Nothing' if the level is unmaterialized. An
-- unmaterialized level is never reported as air.
residentCell ∷ Palette → Resident → TileCoord → Either PaletteError (Maybe Cell)
residentCell palette resident tile = case residentPacked resident tile of
  Nothing → Right Nothing
  Just packed → Just <$> unpackCell palette packed

-- | A column's known segments in ascending level order.
residentSegments ∷ Resident → Column → [Segment]
residentSegments (Resident columns) column = maybe [] Map.elems (Map.lookup column columns)

-- | The columns with at least one known segment.
residentColumns ∷ Resident → [Column]
residentColumns (Resident columns) = Map.keys columns

-- | Counts and accounted bytes of resident detail, kept apart so each can be
-- reported on its own.
data ResidentStats = ResidentStats
  { statColumns ∷ !Int
  , statSegments ∷ !Int
  , statKnownCells ∷ !Int
  , statPayloadBytes ∷ !Int
  , statMetadataBytes ∷ !Int
  }
  deriving stock (Eq, Show)

-- | Conservative accounted bytes of one column's index entry.
columnIndexBytes ∷ Int
columnIndexBytes = 48

-- | Totals over every segment. Payload bytes are the encoded values alone;
-- metadata bytes are the segments' metadata plus the column index entries.
residentStats ∷ Resident → ResidentStats
residentStats (Resident columns) =
  ResidentStats
    { statColumns = Map.size columns
    , statSegments = length segments
    , statKnownCells = sum (map segmentLength segments)
    , statPayloadBytes = sum (map segmentPayloadBytes segments)
    , statMetadataBytes = sum (map segmentMetadataBytes segments) + columnIndexBytes * Map.size columns
    }
  where
    segments = concatMap Map.elems (Map.elems columns)
