-- | Examples for tagged replacements: the conditional narrowing of an observed
-- cell, runs split and coalesced without touching an unaffected level, and the
-- cell, column, surface and resident reads agreeing on what every level holds.
module Test.Terrain.Narrowing (spec) where

import Control.Monad (foldM_, forM_)
import Data.Bits (complement, (.&.))
import Data.Maybe (fromMaybe)
import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Changes
import Hetoimasia.Terrain.Coordinate (TileCoord, axisValue)
import Hetoimasia.Terrain.Palette
import Hetoimasia.Terrain.Query
import Hetoimasia.Terrain.Resident
import Hetoimasia.Terrain.Shape (CornerMask, cornerMaskValue, mkCornerMask, mkShapeId)
import Hetoimasia.Terrain.Source
import Test.Hspec
import Test.QuickCheck hiding ((.&.))
import Test.Terrain.Model

limitless ∷ ChangeLimits
limitless = ChangeLimits 1000000

mask ∷ Int → CornerMask
mask = either (error . show) id . mkCornerMask

corner ∷ String → Int → Cell
corner material value = CornerSolid (mustMaterial material) (mask value)

side ∷ String → Int → Cell
side material value = Solid (mustMaterial material) (either (error . show) id (mkShapeId value))

-- | Side 0 at level 0, corner 15 of @a@ on levels 1 to 3 and of @b@ on levels 4
-- and 5 (so a run over levels 3 to 5 crosses a material boundary), and side 15
-- at level 10. Every other level is air.
fixture ∷ Source
fixture =
  mustSource
    ( SourceSpec
        ["a", "b"]
        [layer 0 1 "a" 0, cornerLayer 1 4 "a" 15, cornerLayer 4 6 "b" 15, layer 10 11 "a" 15]
        []
    )

-- | What the source holds at a level of column (0, 0).
base ∷ Integer → Cell
base z
  | z == 0 = side "a" 0
  | 1 <= z && z <= 3 = corner "a" 15
  | z == 4 || z == 5 = corner "b" 15
  | z == 10 = side "a" 15
  | otherwise = Air

levels ∷ [Integer]
levels = [lowLevel .. highLevel - 1]

-- | The levels read: from @lowLevel@ up to, not including, @highLevel@.
lowLevel, highLevel ∷ Integer
lowLevel = -1
highLevel = 12

tile ∷ Integer → TileCoord
tile = mustTile 0 0

narrowAt ∷ Changes → Integer → Cell → Int → Either NarrowError Changes
narrowAt = narrowLimited limitless

narrowLimited ∷ ChangeLimits → Changes → Integer → Cell → Int → Either NarrowError Changes
narrowLimited limits changes z expected target = narrowCell limits fixture (tile z) expected (mask target) changes

must ∷ Show e ⇒ Either e a → a
must = either (error . show) id

removeAt ∷ Changes → Integer → Changes
removeAt changes z = removeResult (must (removeCell limitless fixture (tile z) changes))

cellsAt ∷ Source → Changes → [Cell]
cellsAt source changes = [cellAt source changes (tile z) | z ← levels]

-- | Every read of column (0, 0) over 'levels' answers @expected@, the source
-- cells with the given levels replaced: the cell query, the column runs, the
-- highest occupied cell and the resident detail, the last also when the
-- levels were resident before the edit.
readsAgree ∷ Changes → [(Integer, Cell)] → Expectation
readsAgree changes edits = do
  cellsAt fixture changes `shouldBe` expected
  runCells `shouldBe` expected
  and (zipWith (/=) (map runCell runs) (drop 1 (map runCell runs))) `shouldBe` True
  highestRead `shouldBe` lastOccupied
  residentAfter `shouldBe` map Just expected
  where
    expected = [fromMaybe (base z) (lookup z edits) | z ← levels]
    runs = either (error . show) id (columnRuns defaultQueryLimits fixture changes (mustColumn 0 0) (mustRange lowLevel highLevel))
    runCells = concat [replicate (fromInteger (toInteger (zRangeHi (runRange r)) - toInteger (zRangeLo (runRange r)))) (runCell r) | r ← runs]
    highestRead = fmap (\o → (toInteger (axisValue (occupiedLevel o)), occupiedMaterial o, occupiedShape o)) (highestOccupied fixture changes (mustColumn 0 0))
    lastOccupied = case [(z, m, k) | (z, c) ← zip levels expected, Just (m, k) ← [cellOccupant c]] of
      [] → Nothing
      found → Just (last found)
    palette = must (internSourceMaterials fixture emptyPalette)
    range = mustRange lowLevel highLevel
    resident0 = must (materialize 8192 fixture emptyChanges palette emptyResident (mustColumn 0 0) range)
    residentAfter =
      let (pal, res) = must (uncurry (\p r → materialize 8192 fixture changes p r (mustColumn 0 0) range) resident0)
       in [must (residentCell pal res (tile z)) | z ← levels]

runsOfTag ∷ Changes → [(Integer, Integer, Replacement)]
runsOfTag changes = [(toInteger (zRangeLo r), toInteger (zRangeHi r), p) | (r, p) ← replacementRuns changes (mustColumn 0 0)]

spec ∷ Spec
spec = describe "Tagged replacements" $ do
  narrowingSpec
  runSpec
  accountingSpec
  mergeSpec
  modelSpec

narrowingSpec ∷ Spec
narrowingSpec = describe "conditional narrowing" $ do
  it "takes each full identity through 14, 12, 8 and air, keeping its material and every neighbour" $
    forM_ [(0, side "a" 0, "a"), (1, corner "a" 15, "a"), (4, corner "b" 15, "b")] $ \(z, full, material) → do
      let go (changes, observed) target = do
            let resulting = if target == 0 then Air else corner material target
                next = must (narrowAt changes z observed target)
            readsAgree next [(z, resulting)]
            narrowAt next z observed target `shouldBe` Left StaleObservation
            pure (next, resulting)
      foldM_ go (emptyChanges, full) [14, 12, 8, 0]
  it "refuses a stale duplicate and leaves the previous value" $ do
    let firstEdit = must (narrowAt emptyChanges 1 (corner "a" 15) 14)
    narrowAt firstEdit 1 (corner "a" 15) 14 `shouldBe` Left StaleObservation
    narrowAt firstEdit 1 (corner "a" 15) 12 `shouldBe` Left StaleObservation
    readsAgree firstEdit [(1, corner "a" 14)]
  it "clears several corners in one edit" $ do
    readsAgree (must (narrowAt emptyChanges 1 (corner "a" 15) 3)) [(1, corner "a" 3)]
    readsAgree (must (narrowAt emptyChanges 0 (side "a" 0) 5)) [(0, corner "a" 5)]
    readsAgree (must (narrowAt emptyChanges 4 (corner "b" 15) 0)) [(4, Air)]
    readsAgree (must (narrowAt (must (narrowAt emptyChanges 1 (corner "a" 15) 14)) 1 (corner "a" 14) 2)) [(1, corner "a" 2)]
  it "reports a different material, family, value or a removed cell as stale" $ do
    narrowAt emptyChanges 4 (corner "a" 15) 14 `shouldBe` Left StaleObservation
    narrowAt emptyChanges 0 (corner "a" 15) 14 `shouldBe` Left StaleObservation
    narrowAt emptyChanges 1 (side "a" 0) 14 `shouldBe` Left StaleObservation
    narrowAt emptyChanges 1 (corner "a" 14) 12 `shouldBe` Left StaleObservation
    narrowAt emptyChanges 10 (side "a" 0) 14 `shouldBe` Left StaleObservation
    narrowAt (removeAt emptyChanges 1) 1 (corner "a" 15) 14 `shouldBe` Left StaleObservation
    narrowAt emptyChanges 7 (corner "a" 15) 14 `shouldBe` Left StaleObservation
  it "refuses an invalid pair as invalid, whatever the cell holds" $ do
    forM_ [1, 3, 5, 7, 11, 15] $ \v → narrowAt emptyChanges 10 (side "a" v) 0 `shouldBe` Left InvalidNarrowing
    narrowAt emptyChanges 7 Air 0 `shouldBe` Left InvalidNarrowing
    narrowAt emptyChanges 1 (corner "a" 0) 0 `shouldBe` Left InvalidNarrowing
    narrowAt emptyChanges 1 (corner "a" 15) 15 `shouldBe` Left InvalidNarrowing
    narrowAt emptyChanges 0 (side "a" 0) 15 `shouldBe` Left InvalidNarrowing
    narrowAt emptyChanges 1 (corner "a" 12) 13 `shouldBe` Left InvalidNarrowing
    narrowAt emptyChanges 1 (corner "a" 12) 3 `shouldBe` Left InvalidNarrowing
    narrowAt emptyChanges 4 (corner "a" 12) 12 `shouldBe` Left InvalidNarrowing
    forM_ [(a, b) | a ← [1 .. 15], b ← [0 .. 15 ∷ Int]] $ \(a, b) →
      (narrowedCell (corner "a" a) (mask b) /= Nothing) `shouldBe` (b /= a && b .&. complement a == 0)
  it "names the cell a valid narrowing leaves" $ do
    narrowedCell (side "a" 0) (mask 14) `shouldBe` Just (corner "a" 14)
    narrowedCell (corner "b" 15) (mask 0) `shouldBe` Just Air

-- | Narrow levels 2, 3 and 4 (material @a@, @a@, @b@) to corners 12: one run.
crossRun ∷ Changes
crossRun = foldl (\changes (z, m) → must (narrowAt changes z (corner m 15) 12)) emptyChanges [(2, "a"), (3, "a"), (4, "b")]

runSpec ∷ Spec
runSpec = describe "runs" $ do
  it "reads one mask run across a source material boundary with each level's own material" $ do
    runsOfTag crossRun `shouldBe` [(2, 5, ReplaceMask (mask 12))]
    readsAgree crossRun [(2, corner "a" 12), (3, corner "a" 12), (4, corner "b" 12)]
  it "splits a run at an edit inside it and leaves every other level" $ do
    let split = must (narrowAt crossRun 3 (corner "a" 12) 8)
    runsOfTag split `shouldBe` [(2, 3, ReplaceMask (mask 12)), (3, 4, ReplaceMask (mask 8)), (4, 5, ReplaceMask (mask 12))]
    readsAgree split [(2, corner "a" 12), (3, corner "a" 8), (4, corner "b" 12)]
  it "splits at an end of a run too, and coalesces equal neighbours in either order" $ do
    let edited order = foldl (\changes (z, m) → must (narrowAt changes z (corner m 12) 8)) crossRun order
    runsOfTag (edited [(2, "a")]) `shouldBe` [(2, 3, ReplaceMask (mask 8)), (3, 5, ReplaceMask (mask 12))]
    runsOfTag (edited [(4, "b")]) `shouldBe` [(2, 4, ReplaceMask (mask 12)), (4, 5, ReplaceMask (mask 8))]
    edited [(2, "a"), (3, "a"), (4, "b")] `shouldBe` edited [(4, "b"), (3, "a"), (2, "a")]
    runsOfTag (edited [(2, "a"), (3, "a"), (4, "b")]) `shouldBe` [(2, 5, ReplaceMask (mask 8))]
    readsAgree (edited [(2, "a"), (4, "b")]) [(2, corner "a" 8), (3, corner "a" 12), (4, corner "b" 8)]
  it "removes a narrowed cell inside a run: its neighbours keep their mask and air coalesces from either operation" $ do
    let removed = removeAt crossRun 3
    removeChanged (must (removeCell limitless fixture (tile 3) crossRun)) `shouldBe` True
    runsOfTag removed `shouldBe` [(2, 3, ReplaceMask (mask 12)), (3, 4, ReplaceAir), (4, 5, ReplaceMask (mask 12))]
    readsAgree removed [(2, corner "a" 12), (3, Air), (4, corner "b" 12)]
    let joined = must (narrowAt removed 4 (corner "b" 12) 0)
    runsOfTag joined `shouldBe` [(2, 3, ReplaceMask (mask 12)), (3, 5, ReplaceAir)]
    removedIntervals joined (mustColumn 0 0) `shouldBe` [mustRange 3 5]
    removeChanged (must (removeCell limitless fixture (tile 3) joined)) `shouldBe` False
  it "rebuilds changes from replacement runs with a mask of zero as air, coalescing it with air beside it" $ do
    let col0 = mustColumn 0 0
        built runs = must (either (Left . show) Right (changesFromReplacements limitless [(col0, mustRange lo hi, tag) | (lo, hi, tag) ← runs]))
        tags changes = [(zRangeLo r, zRangeHi r, t) | (r, t) ← replacementRuns changes col0]
    tags (built [(0, 5, ReplaceAir), (5, 8, ReplaceMask (mask 0))]) `shouldBe` [(0, 8, ReplaceAir)]
    tags (built [(5, 8, ReplaceMask (mask 0))]) `shouldBe` [(5, 8, ReplaceAir)]
    removedIntervals (built [(5, 8, ReplaceMask (mask 0))]) col0 `shouldBe` [mustRange 5 8]
    tags (built [(0, 3, ReplaceMask (mask 12)), (3, 6, ReplaceMask (mask 0))]) `shouldBe` [(0, 3, ReplaceMask (mask 12)), (3, 6, ReplaceAir)]
  it "gives a replacement no material of its own: a level whose source cell is air reads as air" $ do
    let openedAbove =
          mustSource (SourceSpec ["a", "b"] [layer 0 1 "a" 0, cornerLayer 1 4 "a" 15, cornerLayer 4 6 "b" 15] [patchAir 0 0 3 10])
    map (\z → cellAt openedAbove crossRun (tile z)) [2, 3, 4, 5] `shouldBe` [corner "a" 12, Air, Air, Air]
    case highestOccupied openedAbove crossRun (mustColumn 0 0) of
      Just o →
        (toInteger (axisValue (occupiedLevel o)), occupiedMaterial o, Just (occupiedShape o))
          `shouldBe` (2, mustMaterial "a", cellShapeKey (corner "a" 12))
      Nothing → expectationFailure "the column holds a solid below the opened levels"

accountingSpec ∷ Spec
accountingSpec = describe "accounting" $ do
  it "counts and charges every retained run and refuses exactly past the limit, keeping the previous value" $ do
    (changeIntervalCount crossRun, changeColumnCount crossRun) `shouldBe` (1, 1)
    changesBytes crossRun `shouldBe` changeColumnBytes + replacementRunBytes
    let split = must (narrowAt crossRun 3 (corner "a" 12) 8)
    changeIntervalCount split `shouldBe` 3
    changesBytes split `shouldBe` changeColumnBytes + 3 * replacementRunBytes
    narrowLimited (ChangeLimits 3) crossRun 3 (corner "a" 12) 8 `shouldBe` Right split
    narrowLimited (ChangeLimits 2) crossRun 3 (corner "a" 12) 8 `shouldBe` Left (NarrowTooManyRuns 2)
    removeCell (ChangeLimits 2) fixture (tile 3) crossRun `shouldBe` Left (TooManyRemovedIntervals 2)
    removeCell (ChangeLimits 3) fixture (tile 3) crossRun `shouldSatisfy` either (const False) removeChanged
    crossRun `shouldBe` crossRun
    changeIntervalCount crossRun `shouldBe` 1
  it "charges an air run and a mask run at their own figures" $ do
    let mixed = removeAt crossRun 3
    (changeIntervalCount mixed, changesBytes mixed) `shouldBe` (3, changeColumnBytes + changeIntervalBytes + 2 * replacementRunBytes)
    changesBytes (removeAt emptyChanges 0) `shouldBe` changeColumnBytes + changeIntervalBytes
  it "bounds the runs that meet a range of levels, one per level for any tags, and keeps the air-only figures" $ do
    map replacementRunsMeetingLevels [0, 1, 2, 7 ∷ Int] `shouldBe` [0, 1, 2, 7]
    (changeIntervalBytes, changeColumnBytes) `shouldBe` (16, 48)
    map runsMeetingLevels [0, 1, 2, 34 ∷ Int] `shouldBe` [1, 1, 2, 18]
  it "lists only the air runs as removed intervals, and a column of masks alone as not removed" $ do
    removedIntervals crossRun (mustColumn 0 0) `shouldBe` []
    removedColumns crossRun `shouldBe` []
    replacedColumns crossRun `shouldBe` [mustColumn 0 0]
    let withAir = removeAt crossRun 3
    removedIntervals withAir (mustColumn 0 0) `shouldBe` [mustRange 3 4]
    removedColumns withAir `shouldBe` [mustColumn 0 0]
    changesFromIntervals limitless [(mustColumn 0 0, mustRange 3 4)] `shouldBe` Right (removeAt emptyChanges 3)

mergeSpec ∷ Spec
mergeSpec = describe "merging" $ do
  let a = must (narrowAt emptyChanges 1 (corner "a" 15) 12)
      b = must (narrowAt emptyChanges 1 (corner "a" 15) 10)
      c = removeAt emptyChanges 1
      d = must (narrowAt (must (narrowAt emptyChanges 2 (corner "a" 15) 14)) 3 (corner "a" 15) 3)
  it "keeps the corners both overlays leave set, air winning, so two removal sets unite" $ do
    runsOfTag (mergeChanges a b) `shouldBe` [(1, 2, ReplaceMask (mask 8))]
    runsOfTag (mergeChanges a (must (narrowAt emptyChanges 1 (corner "a" 15) 3))) `shouldBe` [(1, 2, ReplaceAir)]
    runsOfTag (mergeChanges a c) `shouldBe` [(1, 2, ReplaceAir)]
    runsOfTag (mergeChanges a d) `shouldBe` [(1, 2, ReplaceMask (mask 12)), (2, 3, ReplaceMask (mask 14)), (3, 4, ReplaceMask (mask 3))]
    mergeChanges (removeAt emptyChanges 4) (removeAt emptyChanges 5) `shouldBe` removeAt (removeAt emptyChanges 4) 5
  it "is symmetric, associative, idempotent and has the empty value as identity" $ do
    forM_ [(x, y, z) | x ← [a, b, c, d], y ← [a, b, c, d], z ← [a, b, c, d]] $ \(x, y, z) → do
      mergeChanges x y `shouldBe` mergeChanges y x
      mergeChanges (mergeChanges x y) z `shouldBe` mergeChanges x (mergeChanges y z)
    forM_ [a, b, c, d] $ \x → do
      mergeChanges x x `shouldBe` x
      mergeChanges emptyChanges x `shouldBe` x
      mergeChanges x emptyChanges `shouldBe` x

-- | One edit of a bounded column: remove a level, or narrow it to a mask.
data Edit = RemoveLevel Integer | NarrowLevel Integer Int
  deriving stock (Show)

instance Arbitrary Edit where
  arbitrary =
    oneof
      [ RemoveLevel <$> choose (0, 7)
      , NarrowLevel <$> choose (0, 7) <*> choose (0, 15)
      ]

-- | The source of the property: corner 15 of @a@ on levels 0 to 3 and of @b@ on
-- 4 to 7.
propertySource ∷ Source
propertySource = mustSource (SourceSpec ["a", "b"] [cornerLayer 0 4 "a" 15, cornerLayer 4 8 "b" 15] [])

propertyBase ∷ Integer → Cell
propertyBase z = corner (if z < 4 then "a" else "b") 15

-- | Apply edits to the overlay and to a per-level model together. A narrowing
-- observes the cell the model holds, as a client would, so a target that is no
-- strict subset of it is refused and changes nothing.
applyEdits ∷ [Edit] → (Changes, [Cell])
applyEdits = foldl apply (emptyChanges, map propertyBase [0 .. 7])
  where
    apply (changes, cells) edit = case edit of
      RemoveLevel z →
        ( removeResult (must (removeCell limitless propertySource (mustTile 0 0 z) changes))
        , replaceAt z Air cells
        )
      NarrowLevel z target →
        let observed = cells !! fromInteger z
         in case narrowedCell observed (mask target) of
              Nothing → (changes, cells)
              Just resulting → (must (narrowCell limitless propertySource (mustTile 0 0 z) observed (mask target) changes), replaceAt z resulting cells)
    replaceAt z cell cells = [if toInteger i == z then cell else c | (i, c) ← zip [0 ∷ Int ..] cells]

modelSpec ∷ Spec
modelSpec = describe "against a per-level model" $
  it "keeps canonical runs and agrees with the model after random removals and narrowings, and after merging" $
    property $ \(edits ∷ [Edit]) (others ∷ [Edit]) →
      let (changes, cells) = applyEdits edits
          (changes', cells') = applyEdits others
          read' c = [cellAt propertySource c (mustTile 0 0 z) | z ← [0 .. 7]]
          runs c = [(a, b, p) | (r, p) ← replacementRuns c (mustColumn 0 0), let a = toInteger (zRangeLo r), let b = toInteger (zRangeHi r)]
          canonical c =
            and (zipWith (\(_, hi, p) (lo, _, q) → hi < lo || (hi == lo && p /= q)) (runs c) (drop 1 (runs c)))
          masks c = length [() | (_, _, ReplaceMask _) ← runs c]
          merged = mergeChanges changes changes'
          bits cell = case cell of
            CornerSolid _ m → cornerMaskValue m
            _ → 0
       in conjoin
            [ counterexample "reads" (read' changes === cells)
            , counterexample "canonical" (canonical changes)
            , counterexample "count" (changeIntervalCount changes === length (runs changes))
            , counterexample "bytes" (changesBytes changes === changeColumnCount changes * changeColumnBytes + (length (runs changes) - masks changes) * changeIntervalBytes + masks changes * replacementRunBytes)
            , counterexample "merged reads" (map bits (read' merged) === zipWith (.&.) (map bits (read' changes)) (map bits (read' changes')))
            , counterexample "merged canonical" (canonical merged)
            , counterexample "merged count" (changeIntervalCount merged === length (runs merged))
            , counterexample "merge symmetric" (merged === mergeChanges changes' changes)
            , counterexample "other" (read' changes' === cells')
            ]
