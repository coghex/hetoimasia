-- | Pure content operations of the terrain service: demand construction, the
-- real work of a load job, removal preparation and snapshot restriction.
--
-- Everything here is a pure function of immutable values. The owner thread
-- calls these between its transactions; nothing here reads or writes service
-- state, so a failed or abandoned computation leaves the arena as it was.
module Hetoimasia.Terrain.Runtime.Internal.Content
  ( -- * Demands
    tileDemand
  , columnDemands
  , realPieces

    -- * Jobs
  , runJob
  , columnsSegmentStats

    -- * Removal
  , Prepared (..)
  , prepareRemoval

    -- * Snapshots
  , restrictResident

    -- * Accounting
  , regionLevelsInteger
  ) where

import Data.List (sort)
import Data.Word (Word64)
import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Changes
import Hetoimasia.Terrain.Coordinate
import Hetoimasia.Terrain.Palette (Palette)
import Hetoimasia.Terrain.Residency
import Hetoimasia.Terrain.Resident
import Hetoimasia.Terrain.Segment (segmentMetadataBytes, segmentPayloadBytes)
import Hetoimasia.Terrain.Source (Source)

-- | The levels of one vertical region.
regionLevelsInteger ∷ Integer
regionLevelsInteger = 32

-- | The demand of one cell: its region and the one-cell coverage inside it.
tileDemand ∷ TileCoord → RegionDemand
tileDemand tile = let (region, local) = decomposeTile tile in RegionDemand region (coverageTile local)

-- | The regions a finite half-open range of one column spans, each with the
-- column's levels inside it. A range is at most the caller's level limit, so
-- the list is short.
columnDemands ∷ Column → ZRange → Either String [RegionDemand]
columnDemands column range = traverse piece [first .. final]
  where
    lo = zRangeLo range
    hi = zRangeHi range
    first = lo `div` regionLevelsInteger
    final = (hi - 1) `div` regionLevelsInteger
    x = toInteger (axisValue (columnX column))
    y = toInteger (axisValue (columnY column))
    piece rz = do
      let zLo = max lo (rz * regionLevelsInteger) - rz * regionLevelsInteger
          zHi = min hi ((rz + 1) * regionLevelsInteger) - rz * regionLevelsInteger
      anchor ← either (Left . show) Right (tileCoord x y (rz * regionLevelsInteger))
      let (RegionCoord rx ry _, local) = decomposeTile anchor
          lx = fromIntegral (localX local)
          ly = fromIntegral (localY local)
      cover ← either (Left . show) Right (coverageBox lx (lx + 1) ly (ly + 1) (fromInteger zLo) (fromInteger zHi))
      Right (RegionDemand (RegionCoord rx ry (fromInteger rz)) cover)

-- | The real columns and level ranges a region-local coverage names.
realPieces ∷ RegionCoord → Coverage → Either String [(Column, ZRange)]
realPieces (RegionCoord rx ry rz) cover =
  sequence
    [ (,) <$> either (Left . show) Right (mkColumn (toInteger rx * 16 + toInteger lx) (toInteger ry * 16 + toInteger ly))
        <*> either (Left . show) Right (mkZRange (toInteger rz * 32 + toInteger lo) (toInteger rz * 32 + toInteger hi))
    | ((lx, ly), intervals) ← coverageIntervals cover
    , (lo, hi) ← intervals
    ]

-- | Segment count and payload bytes of the given columns.
columnsSegmentStats ∷ Resident → [Column] → (Word64, Word64, Word64)
columnsSegmentStats resident columns =
  ( fromIntegral (sum [length segs | segs ← per])
  , fromIntegral (sum [segmentPayloadBytes s | segs ← per, s ← segs])
  , fromIntegral (sum [segmentMetadataBytes s | segs ← per, s ← segs])
  )
  where
    per = [residentSegments resident c | c ← columns]

-- | Do a load job's work on real resident detail and measure what it stored.
-- The cost attributes columns to the region (its own columns), never the shared
-- index's growth, as the residency model charges.
runJob ∷ Source → Changes → Palette → Resident → RegionCoord → Coverage → Either String (Palette, Resident, Cost)
runJob source changes palette0 resident0 region cover = do
  pieces ← realPieces region cover
  let columns = [c | (c, _) ← pieces]
      (segmentsBefore, payloadBefore, _) = columnsSegmentStats resident0 columns
  (palette, resident) ← foldlE materializePiece (palette0, resident0) pieces
  let (segmentsAfter, payloadAfter, _) = columnsSegmentStats resident columns
      grew a b = if a > b then a - b else 0
  Right (palette, resident, Cost (coverageColumns cover) (grew segmentsAfter segmentsBefore) (grew payloadAfter payloadBefore))
  where
    materializePiece (p, r) (column, range) =
      either (Left . show) Right (materialize (fromInteger regionLevelsInteger) source changes p r column range)
    foldlE f z xs = foldl (\acc x → acc >>= \a → f a x) (Right z) xs

-- | The staged result of a removal, ready to publish. Nothing in it has been
-- published: the owner publishes it, with the success settlement, in one
-- transaction.
data Prepared = Prepared
  { preparedChanged ∷ !Bool
  , preparedChanges ∷ !Changes
  , preparedPalette ∷ !Palette
  , preparedResident ∷ !Resident
  , -- | The removed interval in the cell's column, when something was removed.
    preparedInterval ∷ !(Maybe (Column, ZRange))
  , -- | The retained-edit bytes the removal adds.
    preparedRetained ∷ !Word64
  , -- | The bytes the rebuilt segment now accounts beyond the old one.
    preparedGrowth ∷ !Word64
  }

-- | Remove a whole cell from source plus changes and rebuild the resident
-- detail of the cell's column from the new authority. Removing air changes
-- nothing. Total: it returns a typed refusal and builds no partial value.
prepareRemoval ∷ ChangeLimits → Source → Changes → Palette → Resident → TileCoord → Either String Prepared
prepareRemoval limits source changes palette resident tile = do
  outcome ← either (Left . show) Right (removeCell limits source tile changes)
  if not (removeChanged outcome)
    then Right (Prepared False changes palette resident Nothing 0 0)
    else do
      let TileCoord x y z = tile
          column = Column x y
          level = toInteger (axisValue z)
      range ← either (Left . show) Right (mkZRange level (level + 1))
      let changes' = removeResult outcome
          bytesOf r = let (_, payload, metadata) = columnsSegmentStats r [column] in payload + metadata
          before = bytesOf resident
      (palette', resident') ←
        either (Left . show) Right (materialize (fromInteger regionLevelsInteger) source changes' palette resident column range)
      let after = bytesOf resident'
          grown = fromIntegral (changesBytes changes' - changesBytes changes)
      Right
        Prepared
          { preparedChanged = True
          , preparedChanges = changes'
          , preparedPalette = palette'
          , preparedResident = resident'
          , preparedInterval = Just (column, range)
          , preparedRetained = grown
          , preparedGrowth = if after > before then after - before else 0
          }

-- | Keep only the resident detail inside the given regions. The result shares no
-- unaccounted detail with the original: a snapshot built from it holds exactly
-- what its holds charge.
restrictResident ∷ [RegionCoord] → Resident → Resident
restrictResident regions resident = foldl trim resident (residentColumns resident)
  where
    footprint column =
      sort
        [ (toInteger rz * 32, toInteger rz * 32 + 32)
        | RegionCoord rx ry rz ← regions
        , axisValue (columnX column) `div` 16 == rx
        , axisValue (columnY column) `div` 16 == ry
        ]
    trim acc column = case footprint column of
      [] → discardColumn column acc
      keeps → foldl (\r (a, b) → discardIn column a b r) acc (gapsBetween keeps)
    discardIn column a b r = either (const r) (\range → discardRange column range r) (mkZRange a b)
    -- The complement of the kept ranges inside the supported levels.
    gapsBetween keeps =
      let lowest = -(2 ^ (62 ∷ Int))
          highest = 2 ^ (62 ∷ Int)
          edges = [lowest] <> concat [[a, b] | (a, b) ← keeps] <> [highest]
          pairs (a : b : rest) = (a, b) : pairs rest
          pairs _ = []
       in [(a, b) | (a, b) ← pairs edges, a < b]
