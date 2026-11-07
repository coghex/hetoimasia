-- | Examples proving that absolute depth and gap width cause no proportional
-- allocation or traversal.
--
-- The routine proof is deterministic and uses no clock. Each example allocates
-- through the same operation at two widely separated depths or gap widths and
-- compares what the runtime allocated, measured with "GHC.Stats" across major
-- collections after the fixtures were built and forced: two scales separate a
-- change in growth rate from a constant factor, and a per-level cost at either
-- scale would be impossible to hold to the budgets, since a 2^60-level gap
-- cannot be traversed at all. The suite is built with @-with-rtsopts=-T@, and an
-- example that finds the statistics disabled fails rather than reporting a
-- budget as met. Structural counts (known segments and cells) are asserted in
-- "Test.Terrain.Resident".
module Test.Terrain.Growth (spec) where

import Control.Exception (evaluate)
import Control.Monad (forM_, unless)
import Data.Word (Word64)
import GHC.Stats (RTSStats (allocated_bytes), getRTSStats, getRTSStatsEnabled)
import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Changes
import Hetoimasia.Terrain.Palette
import Hetoimasia.Terrain.Query
import Hetoimasia.Terrain.Resident
import Hetoimasia.Terrain.Source
import System.Mem (performMajorGC)
import Test.Hspec
import Test.Terrain.Model

-- | Bytes the runtime allocated while an action ran, measured across major
-- collections.
allocatedBy ∷ IO a → IO Word64
allocatedBy action = do
  enabled ← getRTSStatsEnabled
  unless enabled $ expectationFailure "GHC runtime statistics are disabled; build the suite with -with-rtsopts=-T"
  performMajorGC
  began ← allocated_bytes <$> getRTSStats
  _ ← action
  performMajorGC
  ended ← allocated_bytes <$> getRTSStats
  pure (ended - began)

repeatN ∷ Int → IO a → IO ()
repeatN n action = forM_ [1 .. n] $ \_ → action

-- | The two scales must allocate within a constant factor of each other and
-- both under a budget no per-level traversal could meet.
sameCost ∷ String → Word64 → Word64 → Expectation
sameCost label shallow deep = do
  deep `shouldSatisfy` (<= budget)
  shallow `shouldSatisfy` (<= budget)
  (label, deep <= 2 * shallow + 65536) `shouldBe` (label, True)
  (label, shallow <= 2 * deep + 65536) `shouldBe` (label, True)
  where
    budget = 64 * 1024 * 1024

spec ∷ Spec
spec = describe "Growth with depth and gap width" $ do
  it "answers a deep cell with the allocation of a shallow one" $ do
    let source = mustSource soilOverStone
        column = mustTile 3 3
        ask z = evaluate (cellAt source emptyChanges (column z) == Air)
    _ ← evaluate (sourceAuthoredRuns source)
    shallow ← allocatedBy (repeatN 500 (ask (-10)))
    deep ← allocatedBy (repeatN 500 (ask (lowest + 10)))
    sameCost "deep cell" shallow deep
  it "answers a deep column range with the allocation of a shallow one" $ do
    let source = mustSource soilOverStone
        ask lo = evaluate (either (const 0) length (columnRuns defaultQueryLimits source emptyChanges (mustColumn 0 0) (mustRange lo (lo + 4096))))
    _ ← evaluate (sourceAuthoredRuns source)
    shallow ← allocatedBy (repeatN 200 (ask (-5000)))
    deep ← allocatedBy (repeatN 200 (ask (lowest + 5)))
    sameCost "deep range" shallow deep
  it "crosses an air gap of 2^20 levels and of 2^60 levels at the same cost" $ do
    let gap width = mustSource soilOverStone {specPatches = [patchAir 1 1 (-width) 1, patchSolid 1 1 width (width + 1) "soil" 2]}
        narrow = gap (2 ^ (20 ∷ Int))
        wide = gap (2 ^ (60 ∷ Int))
        top source = evaluate (highestOccupied source emptyChanges (mustColumn 1 1) /= Nothing)
    _ ← evaluate (sourceAuthoredRuns narrow + sourceAuthoredRuns wide)
    cheap ← allocatedBy (repeatN 500 (top narrow))
    costly ← allocatedBy (repeatN 500 (top wide))
    sameCost "air gap" cheap costly
  it "crosses a removed interval of 2^20 levels and of 2^60 levels at the same cost" $ do
    let source = mustSource soilOverStone
        removed width = either (error . show) id (changesFromIntervals (ChangeLimits 4) [(mustColumn 0 0, mustRange (-width) 1)])
        narrow = removed (2 ^ (20 ∷ Int))
        wide = removed (2 ^ (60 ∷ Int))
        top changes = evaluate (highestOccupied source changes (mustColumn 0 0) /= Nothing)
    _ ← evaluate (changeIntervalCount narrow + changeIntervalCount wide)
    cheap ← allocatedBy (repeatN 500 (top narrow))
    costly ← allocatedBy (repeatN 500 (top wide))
    sameCost "removed interval" cheap costly
  it "materializes one cell at a great depth with the allocation of one near the surface" $ do
    let source = mustSource soilOverStone
        palette = either (error . show) id (internSourceMaterials source emptyPalette)
        one z = evaluate (either (const 0) (statKnownCells . residentStats . snd) (materialize 8192 source emptyChanges palette emptyResident (mustColumn 0 0) (mustRange z (z + 1))))
    _ ← evaluate (paletteSize palette)
    shallow ← allocatedBy (repeatN 300 (one (-2)))
    deep ← allocatedBy (repeatN 300 (one (lowest + 7)))
    wide ← allocatedBy (repeatN 300 (one (2 ^ (60 ∷ Int))))
    sameCost "deep materialize" shallow deep
    sameCost "high materialize" shallow wide
  it "materializes widely separated cells with the allocation of the cells alone" $ do
    let source = mustSource soilOverStone
        palette = either (error . show) id (internSourceMaterials source emptyPalette)
        step r z = either (error . show) snd (materialize 8192 source emptyChanges palette r (mustColumn 0 0) (mustRange z (z + 1)))
        build zs = evaluate (statKnownCells (residentStats (foldl step emptyResident zs)))
    _ ← evaluate (paletteSize palette)
    nearBytes ← allocatedBy (repeatN 100 (build [0, 40, 80, 120]))
    farBytes ← allocatedBy (repeatN 100 (build [lowest, -(2 ^ (50 ∷ Int)), 0, 2 ^ (60 ∷ Int)]))
    sameCost "separated segments" nearBytes farBytes
    statKnownCells (residentStats (foldl step emptyResident [lowest, -(2 ^ (50 ∷ Int)), 0, 2 ^ (60 ∷ Int)])) `shouldBe` 4
    statSegments (residentStats (foldl step emptyResident [lowest, -(2 ^ (50 ∷ Int)), 0, 2 ^ (60 ∷ Int)])) `shouldBe` 4
