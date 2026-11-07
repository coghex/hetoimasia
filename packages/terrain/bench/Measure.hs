-- | A reproducible measurement of terrain storage, run on request.
--
-- This is a benchmark component, not part of the routine suite: nothing in a
-- required validation group runs it and nothing asserts a wall-clock figure.
-- It reports, separately for each fixture and demand pattern:
--
-- * the payload bytes of the packed values, from 'segmentPayloadBytes';
-- * the accounted metadata bytes (segment metadata plus column index entries),
--   a conservative figure and not a heap measurement;
-- * the source definition's accounted bytes;
-- * the heap the resident detail actually retains, as the change in live bytes
--   across major collections with the detail held, and the bytes allocated
--   while building it, both from "GHC.Stats";
-- * lookup, bulk-scan, edit and encoding-transition costs in nanoseconds per
--   operation, from the monotonic clock over a fixed number of repetitions.
--
-- The payload figures describe values only; the retained-heap figure includes
-- Haskell object headers and the maps that index the segments, which is why the
-- two differ by more than the stated metadata. Timings are one run on one
-- machine and carry no claim of a speedup, a universal ratio or a threshold.
module Main (main) where

import Control.Exception (evaluate)
import Control.Monad (forM_, when)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stats (GCDetails (gcdetails_live_bytes), RTSStats (allocated_bytes, gc), getRTSStats, getRTSStatsEnabled)
import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Changes
import Hetoimasia.Terrain.Coordinate
import Hetoimasia.Terrain.Palette
import Hetoimasia.Terrain.Query
import Hetoimasia.Terrain.Resident
import Hetoimasia.Terrain.Segment
import Hetoimasia.Terrain.Source
import System.Exit (die)
import System.Mem (performMajorGC)

main ∷ IO ()
main = do
  enabled ← getRTSStatsEnabled
  when (not enabled) $ die "runtime statistics are disabled; run with +RTS -T (the component sets it)"
  putStrLn "terrain-measure: payload, metadata, heap and operation costs (one run, one machine)"
  putStrLn "columns: fixture | demand | segments | known cells | uniform/runs/dense | payload B | metadata B (accounted) | source B (accounted) | retained heap B | allocated building B"
  forM_ fixtures $ \(name, definition) → do
    let source = must (mkSource defaultSourceLimits definition)
        palette = must (internSourceMaterials source emptyPalette)
    forM_ demands $ \(demandName, requests) → do
      (resident, built, retained) ← buildResident source palette requests
      report name demandName source resident built retained
    operations name source palette
  transitions

must ∷ Show e ⇒ Either e a → a
must = either (error . show) id

axis ∷ Integer → AxisCoord
axis = must . axisFromInteger

tileAt ∷ Integer → Integer → Integer → TileCoord
tileAt x y z = must (tileCoord x y z)

column ∷ Integer → Integer → Column
column x y = must (mkColumn x y)

layer ∷ Integer → Integer → String → LayerSpec
layer lo hi m = LayerSpec (Just lo) (Just hi) m 0

stoneBelow ∷ Integer → LayerSpec
stoneBelow hi = LayerSpec Nothing (Just hi) "stone" 0

-- | Flat, layered, hollow and fragmented fixtures over a 16 x 16 block of
-- columns. Every column of a fixture shares its layers; the hollow one adds a
-- cavity patch to each column.
fixtures ∷ [(String, SourceSpec)]
fixtures =
  [ ("flat", SourceSpec ["soil", "stone"] [stoneBelow (-3), layer (-3) 1 "soil"] [])
  ,
    ( "layered"
    , SourceSpec
        ["a", "b", "stone"]
        (stoneBelow (-40) : [layer (-40 + 10 * i) (-30 + 10 * i) (if even i then "a" else "b") | i ← [0 .. 3]])
        []
    )
  ,
    ( "hollow"
    , SourceSpec
        ["rock"]
        [LayerSpec Nothing (Just 0) "rock" 0]
        [PatchSpec x y (-20) (-8) SpecAir | x ← [0 .. 15], y ← [0 .. 15]]
    )
  , ("fragmented", SourceSpec ["a", "b"] [layer i (i + 1) (if even i then "a" else "b") | i ← [-64 .. 63]] [])
  ]

-- | A top-only demand of one cell per column, and a full 128-level demand.
demands ∷ [(String, [(Integer, Integer, Integer, Integer)])]
demands =
  [ ("top-only", [(x, y, 0, 1) | x ← [0 .. 15], y ← [0 .. 15]])
  , ("full-128", [(x, y, -64, 64) | x ← [0 .. 15], y ← [0 .. 15]])
  ]

buildResident ∷ Source → Palette → [(Integer, Integer, Integer, Integer)] → IO (Resident, Word64, Integer)
buildResident source palette requests = do
  performMajorGC
  liveBefore ← liveBytes
  allocBefore ← allocatedBytes
  let step r (x, y, lo, hi) = either (error . show) snd (materialize 8192 source emptyChanges palette r (column x y) (must (mkZRange lo hi)))
  resident ← evaluate (foldl' step emptyResident requests)
  _ ← evaluate (statKnownCells (residentStats resident))
  allocAfter ← allocatedBytes
  performMajorGC
  liveAfter ← liveBytes
  -- Hold the resident detail past the second collection.
  _ ← evaluate (statSegments (residentStats resident))
  pure (resident, allocAfter - allocBefore, toInteger liveAfter - toInteger liveBefore)

liveBytes, allocatedBytes ∷ IO Word64
liveBytes = gcdetails_live_bytes . gc <$> getRTSStats
allocatedBytes = allocated_bytes <$> getRTSStats

report ∷ String → String → Source → Resident → Word64 → Integer → IO ()
report name demandName source resident built retained = do
  let stats = residentStats resident
      segments = concatMap (residentSegments resident) (residentColumns resident)
      count e = length (filter ((== e) . segmentEncoding) segments)
  putStrLn $
    unwords
      [ name
      , "|"
      , demandName
      , "|"
      , show (statSegments stats)
      , "|"
      , show (statKnownCells stats)
      , "|"
      , show (count Uniform) <> "/" <> show (count Runs) <> "/" <> show (count Dense)
      , "|"
      , show (statPayloadBytes stats)
      , "|"
      , show (statMetadataBytes stats)
      , "|"
      , show (sourceDefinitionBytes source)
      , "|"
      , show retained
      , "|"
      , show built
      ]

-- | Time @n@ repetitions of an action that returns a checksum, in nanoseconds per
-- repetition. The checksum keeps the work from being optimized away.
timed ∷ Int → (Int → Int) → IO (Double, Int)
timed n work = do
  start ← getMonotonicTimeNSec
  total ← evaluate (foldl' (\acc i → acc + work i) 0 [0 .. n - 1])
  end ← getMonotonicTimeNSec
  pure (fromIntegral (end - start) / fromIntegral n, total)

lineFor ∷ String → String → String → Double → Int → IO ()
lineFor fixture operation unit nanos checksum =
  putStrLn (unwords [fixture, "|", operation, "|", show (round nanos ∷ Integer), unit, "| checksum", show checksum])

operations ∷ String → Source → Palette → IO ()
operations name source palette = do
  let requests = snd (demands !! 1)
      step r (x, y, lo, hi) = either (error . show) snd (materialize 8192 source emptyChanges palette r (column x y) (must (mkZRange lo hi)))
      resident = foldl' step emptyResident requests
  _ ← evaluate (statSegments (residentStats resident))
  -- Coherent lookups walk consecutive levels of one column; scattered lookups
  -- jump between columns and levels with a fixed multiplicative sequence.
  let coherent i = maybe 0 (fromIntegral . packedWord) (residentPacked resident (tileAt 3 4 (toInteger (i `mod` 128) - 64)))
      scattered i =
        let h = (i * 2654435761) `mod` 32768
         in maybe 0 (fromIntegral . packedWord) (residentPacked resident (tileAt (toInteger (h `mod` 16)) (toInteger ((h `div` 16) `mod` 16)) (toInteger ((h `div` 256) `mod` 128) - 64)))
  (c1, k1) ← timed 2000000 coherent
  lineFor name "lookup coherent" "ns/op" c1 k1
  (c2, k2) ← timed 2000000 scattered
  lineFor name "lookup scattered" "ns/op" c2 k2
  -- Bulk scan: the complete 128-level range of every column, as coalesced runs.
  let scan i = case columnRuns defaultQueryLimits source emptyChanges (column (toInteger (i `mod` 16)) (toInteger ((i `div` 16) `mod` 16))) (must (mkZRange (-64) 64)) of
        Right runs → length runs
        Left _ → 0
  (c3, k3) ← timed 100000 scan
  lineFor name "bulk scan 128 levels" "ns/column" c3 k3
  -- Edit: remove a cell, then refresh that cell's segment from source plus changes.
  let limits = ChangeLimits 1000000
      edit i =
        let z = toInteger (i `mod` 3)
            changes = either (error . show) removeResult (removeCell limits source (tileAt 1 1 (negate z)) emptyChanges)
         in either (const 0) (statKnownCells . residentStats . snd) (materialize 8192 source changes palette resident (column 1 1) (must (mkZRange (negate z) (negate z + 1))))
  (c4, k4) ← timed 50000 edit
  lineFor name "remove + refresh one cell" "ns/op" c4 k4

-- | Encoding transitions of one 32-cell segment, each through 'updateSegment':
-- uniform to runs (one cell changed), runs to dense (every odd cell changed) and
-- dense back to uniform (every even cell restored).
transitions ∷ IO ()
transitions = do
  let cell n = either (error . show) id (mkPackedCell n)
      a = cell 16
      b = cell 32
      uniform = must (buildSegment (axis 0) (replicate 32 a))
      runs = must (updateSegment uniform [(axis 10, b)])
      dense = must (updateSegment uniform [(axis (toInteger i), b) | i ← [0, 2 .. 30 ∷ Int]])
      toRuns i = segmentPayloadBytes (must (updateSegment uniform [(axis (toInteger (i `mod` 32)), b)]))
      toDense _ = segmentPayloadBytes (must (updateSegment runs [(axis (toInteger (2 * k + 1)), b) | k ← [0 .. 15 ∷ Int]]))
      toUniform _ = segmentPayloadBytes (must (updateSegment dense [(axis (toInteger (2 * k)), a) | k ← [0 .. 15 ∷ Int]]))
  (t1, k1) ← timed 200000 toRuns
  lineFor "segment" "uniform -> runs (1 cell)" "ns/op" t1 k1
  (t2, k2) ← timed 200000 toDense
  lineFor "segment" "runs -> dense (16 cells)" "ns/op" t2 k2
  (t3, k3) ← timed 200000 toUniform
  lineFor "segment" "dense -> uniform (16 cells)" "ns/op" t3 k3
  putStrLn (unwords ["segment encodings reached:", show (segmentEncoding runs), show (segmentEncoding (must (updateSegment runs [(axis (toInteger (2 * k + 1)), b) | k ← [0 .. 15 ∷ Int]]))), show (segmentEncoding (must (updateSegment dense [(axis (toInteger (2 * k)), a) | k ← [0 .. 15 ∷ Int]])))])
