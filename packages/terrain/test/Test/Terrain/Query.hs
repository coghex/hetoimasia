-- | Examples for queries over a source plus retained removals: single cells,
-- complete column ranges, the highest occupied cell, removal semantics and the
-- bounded-model comparison.
module Test.Terrain.Query (spec) where

import Control.Monad (foldM, forM_)
import Data.List (permutations)
import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Changes
import Hetoimasia.Terrain.Coordinate (axisValue)
import Hetoimasia.Terrain.Query
import Hetoimasia.Terrain.Shape (shapeIdValue)
import Hetoimasia.Terrain.Source
import Test.Hspec
import Test.QuickCheck
import Test.Terrain.Model

limitless ∷ ChangeLimits
limitless = ChangeLimits 1000000

remove ∷ Source → Changes → (Integer, Integer, Integer) → RemoveOutcome
remove source changes (x, y, z) = either (error . show) id (removeCell limitless source (mustTile x y z) changes)

mustChanges ∷ [(Column, ZRange)] → Changes
mustChanges = either (error . show) id . changesFromIntervals limitless

removeAll ∷ Source → [(Integer, Integer, Integer)] → Changes
removeAll source = foldl (\acc t → removeResult (remove source acc t)) emptyChanges

runsOf ∷ Source → Changes → Integer → Integer → Integer → Integer → [(Integer, Integer, Maybe (String, Int))]
runsOf source changes x y lo hi =
  case columnRuns defaultQueryLimits source changes (mustColumn x y) (mustRange lo hi) of
    Left e → error (show e)
    Right runs → [(zRangeLo (runRange r), zRangeHi (runRange r), fromCell (runCell r)) | r ← runs]

highestOf ∷ Source → Changes → Integer → Integer → Maybe (Integer, (String, Int))
highestOf source changes x y = case highestOccupied source changes (mustColumn x y) of
  Nothing → Nothing
  Just o → Just (toInteger (axisValue (occupiedLevel o)), (materialIdString (occupiedMaterial o), shapeIdValue (occupiedShape o)))

spec ∷ Spec
spec = describe "Queries and removals" $ do
  cellSpec
  rangeSpec
  surfaceSpec
  removalSpec
  modelSpec

cellSpec ∷ Spec
cellSpec = describe "cell queries" $ do
  it "answers air or a material with a shape, in a soil-over-stone source" $ do
    let source = mustSource soilOverStone
    cellAt source emptyChanges (mustTile 0 0 1) `shouldBe` Air
    cellAt source emptyChanges (mustTile 0 0 (-1)) `shouldBe` cellOf "soil" 0
    cellAt source emptyChanges (mustTile 0 0 (-3)) `shouldBe` cellOf "soil" 0
    cellAt source emptyChanges (mustTile 0 0 (-4)) `shouldBe` cellOf "stone" 0
  it "answers the same for any request order" $ do
    let source = mustSource soilOverStone
        zs = [5, -4, 0, lowest, highest, -3, -2, 1, -1000000]
        at z = fromCell (cellAt source emptyChanges (mustTile 1 2 z))
        expected z = modelCell soilOverStone [] (1, 2, z)
    forM_ (take 24 (permutations zs)) $ \order →
      map at order `shouldBe` map expected order

rangeSpec ∷ Spec
rangeSpec = describe "column ranges" $ do
  it "returns the complete range as coalesced runs, air included" $ do
    let source = mustSource soilOverStone
    runsOf source emptyChanges 0 0 (-6) 4
      `shouldBe` [(-6, -3, Just ("stone", 0)), (-3, 1, Just ("soil", 0)), (1, 4, Nothing)]
  it "coalesces adjacent equal values and keeps adjacent different ones" $ do
    let source = mustSource base2
        base2 =
          SourceSpec
            ["a", "b"]
            [layer 0 3 "a" 0, layer 3 6 "a" 0, layer 6 8 "a" 1, layer 8 9 "b" 1]
            []
    runsOf source emptyChanges 0 0 0 9
      `shouldBe` [(0, 6, Just ("a", 0)), (6, 8, Just ("a", 1)), (8, 9, Just ("b", 1))]
  it "answers the whole supported width a range may reach, exactly at the top" $ do
    let source = mustSource (SourceSpec ["a"] [softLayer (Just (highest - 3)) Nothing "a" 4] [])
    runsOf source emptyChanges 0 0 (highest - 5) topEnd
      `shouldBe` [(highest - 5, highest - 3, Nothing), (highest - 3, topEnd, Just ("a", 4))]
    runsOf source emptyChanges 0 0 highest topEnd `shouldBe` [(highest, topEnd, Just ("a", 4))]
  it "crosses a deep stone interval without visiting its levels" $ do
    let source = mustSource soilOverStone
    runsOf source emptyChanges 0 0 lowest (lowest + 8192) `shouldBe` [(lowest, lowest + 8192, Just ("stone", 0))]
  it "accepts a range of exactly 8,192 levels and refuses 8,193, without truncating" $ do
    let source = mustSource soilOverStone
        ask n = columnRuns defaultQueryLimits source emptyChanges (mustColumn 0 0) (mustRange 0 n)
    ask 8192 `shouldSatisfy` either (const False) (const True)
    ask 8193 `shouldBe` Left (RangeTooLarge 8193 8192)
    columnRuns defaultQueryLimits source emptyChanges (mustColumn 0 0) (mustRange lowest topEnd)
      `shouldBe` Left (RangeTooLarge 9223372036854775808 8192)
  it "returns exactly 1,024 runs and refuses 1,025" $ do
    -- 513 one-level layers at 0, 4, 8, ...: the first 2,048 levels hold 512 solid
    -- and 512 air runs; level 2,048 adds a 513th solid run and so a 1,025th.
    let source = mustSource (SourceSpec ["a"] [layer (4 * i) (4 * i + 1) "a" 0 | i ← [0 .. 512]] [])
        ask hi = columnRuns defaultQueryLimits source emptyChanges (mustColumn 0 0) (mustRange 0 hi)
    fmap length (ask 2048) `shouldBe` Right 1024
    ask 2049 `shouldBe` Left (TooManyRuns 1024)
    fmap length (columnRuns QueryLimits {limitReturnedRuns = 1023, limitRangeLevels = 8192} source emptyChanges (mustColumn 0 0) (mustRange 0 2048))
      `shouldBe` Left (TooManyRuns 1023)
  it "covers the requested interval contiguously from end to end" $ do
    let source = mustSource soilOverStone {specPatches = [patchAir 0 0 (-2) 0, patchSolid 0 0 3 5 "soil" 9]}
        runs = runsOf source emptyChanges 0 0 (-10) 20
    fst3 (head' runs) `shouldBe` (-10)
    thd (last' runs) `shouldBe` 20
    and (zipWith (\(_, e, _) (s, _, _) → e == s) runs (drop 1 runs)) `shouldBe` True
    and (zipWith (\(_, _, v) (_, _, w) → v /= w) runs (drop 1 runs)) `shouldBe` True
  where
    head' = foldr const (0, 0, Nothing)
    last' = foldl (\_ x → x) (0, 0, Nothing)
    fst3 (a, _, _) = a
    thd (_, c, _) = c

surfaceSpec ∷ Spec
surfaceSpec = describe "highest occupied cell" $ do
  it "finds the top of the soil and answers absent for an empty column" $ do
    let source = mustSource soilOverStone {specPatches = [patchAir 2 2 lowest topEnd]}
    highestOf source emptyChanges 0 0 `shouldBe` Just (0, ("soil", 0))
    highestOf source emptyChanges 2 2 `shouldBe` Nothing
    highestOccupied (mustSource (SourceSpec [] [] [])) emptyChanges (mustColumn 0 0) `shouldBe` Nothing
  it "sees a roof over a cavity and a separate solid span above" $ do
    let source =
          mustSource
            SourceSpec
              { specMaterials = ["rock", "ledge"]
              , specLayers = [layer (-10) 0 "rock" 0]
              , specPatches = [patchAir 3 3 (-6) (-2), patchSolid 3 3 20 22 "ledge" 5]
              }
    highestOf source emptyChanges 3 3 `shouldBe` Just (21, ("ledge", 5))
    highestOf source emptyChanges 4 3 `shouldBe` Just (-1, ("rock", 0))
    let opened = removeAll source [(3, 3, 21), (3, 3, 20)]
    highestOf source opened 3 3 `shouldBe` Just (-1, ("rock", 0))
  it "falls through a removed run to the cell below it" $ do
    let source = mustSource soilOverStone
        changes = removeAll source [(0, 0, 0), (0, 0, -1)]
    highestOf source changes 0 0 `shouldBe` Just (-2, ("soil", 0))
  it "crosses an air gap and a removed stretch of unbounded width in a few steps" $ do
    let source = mustSource soilOverStone {specPatches = [patchAir 1 1 (-1000000000000) 1, patchSolid 1 1 (2 ^ (60 ∷ Int)) (2 ^ (60 ∷ Int) + 1) "soil" 2]}
    highestOf source emptyChanges 1 1 `shouldBe` Just (2 ^ (60 ∷ Int), ("soil", 2))
    let longRemoval = mustChanges [(mustColumn 0 0, mustRange (-(2 ^ (61 ∷ Int))) 1)]
    highestOf (mustSource soilOverStone) longRemoval 0 0 `shouldBe` Just (-(2 ^ (61 ∷ Int)) - 1, ("stone", 0))
  it "reports the highest cell even when it is the last supported level" $ do
    let source = mustSource (SourceSpec ["a"] [softLayer (Just 0) Nothing "a" 15] [])
    highestOf source emptyChanges 0 0 `shouldBe` Just (highest, ("a", 15))

removalSpec ∷ Spec
removalSpec = describe "removals" $ do
  it "removes a solid and reports the change" $ do
    let source = mustSource soilOverStone
        out = remove source emptyChanges (0, 0, 0)
    removeChanged out `shouldBe` True
    cellAt source (removeResult out) (mustTile 0 0 0) `shouldBe` Air
    cellAt source (removeResult out) (mustTile 0 0 (-1)) `shouldBe` cellOf "soil" 0
    cellAt source (removeResult out) (mustTile 1 0 0) `shouldBe` cellOf "soil" 0
    cellAt source emptyChanges (mustTile 0 0 0) `shouldBe` cellOf "soil" 0
  it "removing air, or a removed cell, reports changed = False and records nothing" $ do
    let source = mustSource soilOverStone
        first = removeResult (remove source emptyChanges (0, 0, 0))
        air' = remove source emptyChanges (0, 0, 5)
        repeated = remove source first (0, 0, 0)
    removeChanged air' `shouldBe` False
    removeResult air' `shouldBe` emptyChanges
    removeChanged repeated `shouldBe` False
    removeResult repeated `shouldBe` first
    changeIntervalCount (removeResult repeated) `shouldBe` 1
  it "removes a whole ramp, never reshaping a neighbour" $ do
    let source = mustSource (SourceSpec ["a"] [layer 0 1 "a" 3, layer 1 2 "a" 12] [])
        changes = removeResult (remove source emptyChanges (0, 0, 0))
    cellAt source changes (mustTile 0 0 0) `shouldBe` Air
    cellAt source changes (mustTile 0 0 1) `shouldBe` cellOf "a" 12
    cellAt source changes (mustTile 1 0 0) `shouldBe` cellOf "a" 3
  it "coalesces adjacent removals into one interval, in any order" $ do
    let source = mustSource soilOverStone
        order zs = removeAll source [(0, 0, z) | z ← zs]
    forM_ (permutations [-4, -3, -2, -1, 0]) $ \zs →
      order zs `shouldBe` order [-4, -3, -2, -1, 0]
    changeIntervalCount (order [-4, -3, -2, -1, 0]) `shouldBe` 1
    removedIntervals (order [-4, -3, -2, -1, 0]) (mustColumn 0 0) `shouldBe` [mustRange (-4) 1]
    removedIntervals (order [-4, -2, 0]) (mustColumn 0 0) `shouldBe` [mustRange (-4) (-3), mustRange (-2) (-1), mustRange 0 1]
    changeIntervalCount (order [-4, -2, 0, -3, -1]) `shouldBe` 1
  it "removes across the soil/stone boundary as one interval" $ do
    let source = mustSource soilOverStone
        changes = removeAll source [(0, 0, -4), (0, 0, -3)]
    removedIntervals changes (mustColumn 0 0) `shouldBe` [mustRange (-4) (-2)]
    runsOf source changes 0 0 (-6) 2
      `shouldBe` [(-6, -4, Just ("stone", 0)), (-4, -2, Nothing), (-2, 1, Just ("soil", 0)), (1, 2, Nothing)]
  it "keeps the previous value on a refusal" $ do
    let source = mustSource soilOverStone
        one = removeResult (remove source emptyChanges (0, 0, 0))
    removeCell (ChangeLimits 1) source (mustTile 5 5 0) one `shouldBe` Left (TooManyRemovedIntervals 1)
    removeCell (ChangeLimits 1) source (mustTile 0 0 (-1)) one `shouldSatisfy` either (const False) removeChanged
    one `shouldBe` removeResult (remove source emptyChanges (0, 0, 0))
    removeCell (ChangeLimits 0) source (mustTile 0 0 5) emptyChanges `shouldSatisfy` either (const False) (not . removeChanged)
  it "starts a fresh session empty and merges retained changes in any grouping" $ do
    let source = mustSource soilOverStone
        a = removeAll source [(0, 0, 0), (0, 0, -1), (3, 3, 0)]
        b = removeAll source [(0, 0, -2), (4, 4, -9)]
        c = removeAll source [(0, 0, -3), (3, 3, 0)]
    mergeChanges emptyChanges a `shouldBe` a
    mergeChanges a b `shouldBe` mergeChanges b a
    mergeChanges (mergeChanges a b) c `shouldBe` mergeChanges a (mergeChanges b c)
    mergeChanges a b `shouldBe` removeAll source [(0, 0, 0), (0, 0, -1), (3, 3, 0), (0, 0, -2), (4, 4, -9)]
    removedIntervals (mergeChanges a b) (mustColumn 0 0) `shouldBe` [mustRange (-2) 1]
  it "restores canonical changes from overlapping, touching and unordered intervals" $ do
    let col = mustColumn 1 1
        restored = mustChanges [(col, mustRange 10 20), (col, mustRange 0 5), (col, mustRange 5 12), (col, mustRange 30 31)]
    removedIntervals restored col `shouldBe` [mustRange 0 20, mustRange 30 31]
    changeIntervalCount restored `shouldBe` 2
    changesFromIntervals (ChangeLimits 1) [(col, mustRange 0 1), (col, mustRange 5 6)] `shouldBe` Left (TooManyRemovedIntervals 1)
  it "accounts retained changes conservatively and separately" $ do
    let source = mustSource soilOverStone
        c = removeAll source [(0, 0, 0), (0, 0, -2), (1, 1, 0)]
    (changeColumnCount c, changeIntervalCount c) `shouldBe` (2, 3)
    changesBytes c `shouldBe` 2 * changeColumnBytes + 3 * changeIntervalBytes
    changesBytes emptyChanges `shouldBe` 0

-- | A bounded random definition, random removals and the queries over them,
-- all compared with the naive model.
modelSpec ∷ Spec
modelSpec = describe "against the independent model" $ do
  it "agrees on every cell, range and surface of random definitions with random removals" $
    withNumTests 300 $ property $ forAll genScenario $ \(definition, cells) →
      let source = mustSource definition
       in case foldM (step definition source) (emptyChanges, []) cells of
            Left message → counterexample message False
            Right (changes, removals) → agrees definition source changes removals
  it "gives the same answers whatever order the removals were made in" $
    withNumTests 200 $ property $ forAll genScenario $ \(definition, cells) →
      let source = mustSource definition
          forward = removeAll source cells
          backward = removeAll source (reverse cells)
          removals = [(x, y, z, z + 1) | (x, y, z) ← cells]
       in forward === backward .&&. agrees definition source backward removals
  it "agrees through the extremes of the supported range" $ do
    let definition =
          SourceSpec
            ["a", "b"]
            [softLayer Nothing (Just (lowest + 2)) "a" 1, layer (highest - 1) topEnd "b" 15]
            [patchAir 0 0 lowest (lowest + 1), patchSolid 0 0 highest topEnd "a" 0]
        source = mustSource definition
        changes = removeAll source [(0, 0, highest), (0, 0, lowest + 1)]
        removals = [(0, 0, highest, topEnd), (0, 0, lowest + 1, lowest + 2)]
    forM_ [(x, z) | x ← [0, 1], z ← [lowest, lowest + 1, lowest + 2, highest - 2, highest - 1, highest]] $ \(x, z) →
      fromCell (cellAt source changes (mustTile x 0 z)) `shouldBe` modelCell definition removals (x, 0, z)
    highestOf source changes 0 0 `shouldBe` modelHighest definition removals 0 0
    highestOf source changes 1 0 `shouldBe` modelHighest definition removals 1 0
    highestOf source emptyChanges 0 0 `shouldBe` Just (highest, ("a", 0))
    highestOf source changes 0 0 `shouldBe` Just (highest - 1, ("b", 15))
  where
    step definition source (changes, removals) (x, y, z) = do
      let wasSolid = modelCell definition removals (x, y, z) /= Nothing
      case removeCell limitless source (mustTile x y z) changes of
        Left e → Left (show e)
        Right out
          | removeChanged out /= wasSolid → Left ("changed flag wrong at " <> show (x, y, z))
          | otherwise → Right (removeResult out, if wasSolid then (x, y, z, z + 1) : removals else removals)

agrees ∷ SourceSpec → Source → Changes → [Removal] → Property
agrees definition source changes removals =
  conjoin
    [ conjoin
        [ counterexample ("cell " <> show (x, y, z)) $
            fromCell (cellAt source changes (mustTile x y z)) === modelCell definition removals (x, y, z)
        | x ← [0, 1, 5]
        , y ← [0, 1]
        , z ← [-30 .. 29]
        ]
    , conjoin
        [ counterexample ("runs " <> show (x, y, lo, hi)) $
            runsOf source changes x y lo hi === modelRuns definition removals x y lo hi
        | x ← [0, 1, 5]
        , y ← [0, 1]
        , (lo, hi) ← [(-30, 30), (-3, 4), (7, 8), (-26, -25), (-12, 12)]
        ]
    , conjoin
        [ counterexample ("highest " <> show (x, y)) $
            highestOf source changes x y === modelHighest definition removals x y
        | x ← [0, 1, 5]
        , y ← [0, 1]
        ]
    ]

genScenario ∷ Gen (SourceSpec, [(Integer, Integer, Integer)])
genScenario = do
  definition ← genDefinition
  count ← choose (0, 25)
  cells ← vectorOf count ((,,) <$> choose (0, 1) <*> choose (0, 1) <*> choose (-26, 25))
  pure (definition, cells)

genDefinition ∷ Gen SourceSpec
genDefinition = do
  layerCount ← choose (0, 4)
  layers ← genLayers layerCount
  patches ← genPatches
  pure SourceSpec {specMaterials = ["a", "b", "c"], specLayers = layers, specPatches = patches}

genLayers ∷ Int → Gen [LayerSpec]
genLayers n = genLayersFrom n (-20) >>= openEnds

genLayersFrom ∷ Int → Integer → Gen [LayerSpec]
genLayersFrom 0 _ = pure []
genLayersFrom n start = do
  gap ← choose (0, 5)
  width ← choose (1, 8)
  let lo = start + gap
      hi = lo + width
  material ← elements ["a", "b", "c"]
  shape ← choose (0, 15)
  rest ← genLayersFrom (n - 1) hi
  pure (softLayer (Just lo) (Just hi) material shape : rest)

-- | Sometimes open the first lower end and the last upper end to the extremes.
openEnds ∷ [LayerSpec] → Gen [LayerSpec]
openEnds [] = pure []
openEnds ls = do
  openLow ← arbitrary
  openHigh ← arbitrary
  let firstOpened = if openLow then (\l → l {layerMin = Nothing}) else id
      lastOpened = if openHigh then (\l → l {layerMax = Nothing}) else id
  pure (mapFirst firstOpened (mapLast lastOpened ls))
  where
    mapFirst f (x : xs) = f x : xs
    mapFirst _ [] = []
    mapLast f xs = case reverse xs of
      [] → []
      (y : ys) → reverse (f y : ys)

genPatches ∷ Gen [PatchSpec]
genPatches = do
  attempts ← choose (0, 6)
  candidates ← vectorOf attempts $ do
    x ← choose (0, 1)
    y ← choose (0, 1)
    lo ← choose (-25, 20)
    width ← choose (1, 10)
    value ← oneof [pure SpecAir, SpecSolid <$> elements ["a", "b", "c"] <*> choose (0, 15)]
    pure (PatchSpec x y lo (lo + width) value)
  pure (foldl keep [] candidates)
  where
    keep kept p
      | any (clashes p) kept = kept
      | otherwise = kept <> [p]
    clashes p q = patchX p == patchX q && patchY p == patchY q && patchMin p < patchMax q && patchMin q < patchMax p
