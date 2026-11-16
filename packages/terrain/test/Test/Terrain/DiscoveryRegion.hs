-- | The region-level knowledge query (#690): a region's compressed knowledge, built from a plan that
-- evaluates 'queryCell' only where the answer can vary, equals 'queryCell' at every one of the
-- region's 8,192 cells, on scenes whose knowledge the suite's independent oracle also checks; and the
-- plan's work does not grow with the cells of a region whose answer is uniform.
module Test.Terrain.DiscoveryRegion (spec) where

import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Hetoimasia.Terrain.Cell (Column (..), zRangeHi, zRangeLo)
import Hetoimasia.Terrain.Coordinate (RegionCoord (..))
import Hetoimasia.Terrain.Discovery
import Hetoimasia.Terrain.Source (CellSpec (..), PatchSpec (..))
import Test.Hspec
import Test.Terrain.ConnectivityOracle (Cell3, Window (..))
import Test.Terrain.DiscoveryHarness
import Test.Terrain.Model (mustTile)

spec ∷ Spec
spec = describe "Discovery regions" $ do
  describe "a region's knowledge equals queryCell at every cell" $
    mapM_ fixture fixtures

  it "plans a pristine buried region and a pristine sky region as one class of three evaluations, one summary each" $ do
    let rig = settle cavity
        above = RegionCoord 5 5 1
        below = RegionCoord 5 5 (-1)
    planWork rig above `shouldBe` (1, 1, 3, 0)
    planWork rig below `shouldBe` (1, 1, 3, 0)
    fmap regionKnowledgeUniform (regionOf rig above) `shouldBe` Right (Just (CellKnowledge NoSolid VoidKnown))
    fmap regionKnowledgeUniform (regionOf rig below) `shouldBe` Right (Just (CellKnowledge SolidUnknown NoVoidHere))
    fmap (length . regionKnowledgeClasses) (regionOf rig above) `shouldBe` Right 1
    fmap regionKnowledgeColumns (regionOf rig below) `shouldBe` Right []

  it "keeps one class for a column with a removal beside it, and its work grows with the removal, not with the region" $ do
    let pristine = settle (cavityWith [])
        one = settle (cavityWith [(40, 40, -10)])
        region = RegionCoord 2 2 (-1)
        (classes0, _, tiles0, _) = planWork pristine region
        (classes1, _, tiles1, _) = planWork one region
    (classes0, tiles0) `shouldBe` (1, 3)
    -- the removed column and its four side neighbours are classes of their own; the rest is one class
    classes1 `shouldBe` 6
    tiles1 `shouldSatisfy` (<= 3 + 5 * 3 * 3)
    regionMismatches one region `shouldBe` []

  it "evaluates every level of a box whose components keep the level, and counts those evaluations apart" $ do
    let rig = settle rampStack
        region = RegionCoord 0 0 0
        (_, _, tiles, perLevel) = planWork rig region
    perLevel `shouldSatisfy` (>= 8)
    tiles `shouldSatisfy` (>= perLevel)
    regionMismatches rig region `shouldBe` []

  it "refuses answers that do not match the plan's tiles" $ do
    let rig = settle cavity
        plan = planOf rig (RegionCoord 0 0 0)
    assembleRegionKnowledge plan [] `shouldBe` Nothing
    assembleRegionKnowledge plan (replicate (length (planTiles plan) + 1) (CellKnowledge NoSolid VoidKnown)) `shouldBe` Nothing

  it "rebuilds a region's knowledge from its parts and refuses parts that do not cover the region" $ do
    let rig = settle twoOpenings
        region = RegionCoord 0 0 0
    case regionOf rig region of
      Left e → expectationFailure e
      Right rk → do
        mkRegionKnowledge region (regionKnowledgeClasses rk) (regionKnowledgeColumns rk) `shouldBe` Just rk
        mkRegionKnowledge region [] [] `shouldBe` Nothing
        mkRegionKnowledge region [[(0, 31, CellKnowledge NoSolid VoidKnown)]] [] `shouldBe` Nothing
  where
    fixture (name, rig0) = it name $ do
      let rig = rig0
      compareDrained rig `shouldBe` []
      mapM_ (\region → (region, regionMismatches rig region) `shouldBe` (region, [])) (regionsOf rig)

-- ---------------------------------------------------------------------------
-- Scenes: the six of the issue, each with its removals applied and drained

fixtures ∷ [(String, Rig)]
fixtures =
  [ ("a cavity opened to the sky", settle cavity)
  , ("a roof over a removed gap", settle roof)
  , ("a ramp beside an undiscovered void", settle ramps)
  , ("a deep shaft across a region seam", settle shaft)
  , ("buried removals", settle buried)
  , ("a two-opening reveal", settle twoOpenings)
  ]

-- | A scene and the cells it removes.
data Fixture = Fixture Scene [Cell3]

cavity ∷ Fixture
cavity = cavityWith [(2, 0, 7), (2, 0, 6)]

-- | A cave along X sealed under a sky at level 8, and removals.
cavityWith ∷ [Cell3] → Fixture
cavityWith = Fixture (groundScene "cavity" 8 (-3, 10) (-3, 4) 6 (caveRow 0 5 2 6))

-- | A cell removed under the cave's roof joins the sealed cave and reveals nothing; a shaft elsewhere
-- reveals the cave below it.
roof ∷ Fixture
roof = Fixture (groundScene "roof" 8 (-3, 12) (-3, 4) 6 (caveRow 0 5 2 8)) [(4, 0, 6), (8, 1, 7), (8, 1, 6), (8, 1, 5)]

-- | A known corridor beside an N ramp whose empty side is unknown, and a sealed cavity behind it.
ramps ∷ Fixture
ramps =
  Fixture
    ( groundScene "ramps" 8 (-3, 12) (-5, 6) 6 $
        caveRow 1 5 1 7
          <> [PatchSpec 4 0 5 6 (SpecSolid "slab" 1)]
          <> [PatchSpec 4 0 6 7 (SpecSolid "stone" 0)]
          <> [PatchSpec 2 (-3) 5 6 SpecAir, PatchSpec 2 (-2) 5 6 SpecAir]
    )
    [(1, 1, 7), (1, 1, 6), (1, 1, 5)]

-- | A shaft from the sky down past level 0 into the region below.
shaft ∷ Fixture
shaft = Fixture (groundScene "shaft" 8 (-2, 6) (-2, 4) 40 []) [(2, 1, z) | z ← [7, 6 .. -20]]

-- | Removals deep in the stone that reach nothing.
buried ∷ Fixture
buried = Fixture (groundScene "buried" 8 (-2, 8) (-2, 5) 12 []) [(3, 1, -2), (3, 1, -3), (4, 1, -3), (5, 2, 1)]

-- | A cave reached first through one end, then through the other.
twoOpenings ∷ Fixture
twoOpenings =
  Fixture
    (groundScene "two openings" 8 (-3, 13) (-3, 6) 6 (caveRow 0 5 2 8 <> [PatchSpec 5 y 5 6 SpecAir | y ← [1 .. 3]]))
    ([(1, 0, z) | z ← [5 .. 7]] <> [(9, 0, z) | z ← [5 .. 7]])

-- | A covered stack of N ramps: stacked non-flat cells never connect between levels, so each level is
-- its own component.
rampStack ∷ Fixture
rampStack = Fixture (groundScene "ramp stack" 8 (-2, 6) (-2, 6) 9 [PatchSpec 2 2 0 8 (SpecSolid "slab" 1)]) []

-- | Apply a fixture's removals and drain its obligations.
settle ∷ Fixture → Rig
settle (Fixture scene removals) = drainRig allowance (foldl (\rig cell → drainRig allowance (fst (editRig allowance cell rig))) (newRig defaultDiscoveryLimits scene) removals)
  where
    allowance = allowanceOf defaultDiscoveryLimits

-- ---------------------------------------------------------------------------
-- Checks

-- | The regions a fixture's oracle window meets.
regionsOf ∷ Rig → [RegionCoord]
regionsOf rig =
  [ RegionCoord (fromInteger rx) (fromInteger ry) (fromInteger rz)
  | rx ← [x0 `div` 16 .. (x1 - 1) `div` 16]
  , ry ← [y0 `div` 16 .. (y1 - 1) `div` 16]
  , rz ← [z0 `div` 32 .. (z1 - 1) `div` 32]
  ]
  where
    Window (x0, x1) (y0, y1) (z0, z1) = sceneWindow (rigScene rig)

-- | The removed runs a plan reads: those of the region's columns and of the columns beside it, over
-- its read levels.
runsFor ∷ Rig → RegionCoord → Map.Map Column [(Int64, Int64)]
runsFor rig region =
  Map.fromListWith
    (flip (<>))
    [ (column, [(fromInteger (zRangeLo range), fromInteger (zRangeHi range))])
    | (column, range) ← retainedRemovals (rigRetained rig)
    , Set.member column wanted
    , zRangeHi range > toInteger lo
    , zRangeLo range < toInteger hi
    ]
  where
    wanted = Set.fromList (regionColumns region <> regionHaloColumns region)
    (lo, hi) = regionReadLevels region

planOf ∷ Rig → RegionCoord → KnowledgePlan
planOf rig region = planRegionKnowledge (rigEnv rig) region (runsFor rig region)

-- | Classes, pieces, evaluations and per-level evaluations.
planWork ∷ Rig → RegionCoord → (Int, Int, Int, Int)
planWork rig region = let plan = planOf rig region in (planClasses plan, planPieces plan, length (planTiles plan), planPerLevelTiles plan)

-- | The region's compressed knowledge, evaluated through the plan.
regionOf ∷ Rig → RegionCoord → Either String RegionKnowledge
regionOf rig region = do
  let plan = planOf rig region
  answers ← traverse (\tile → either (Left . show) Right (observedValue (queryCell (rigEnv rig) (rigProvider rig) tile))) (planTiles plan)
  maybe (Left "the answers do not match the plan") Right (assembleRegionKnowledge plan answers)

-- | Every cell of the region whose compressed answer differs from 'queryCell'.
regionMismatches ∷ Rig → RegionCoord → [String]
regionMismatches rig region@(RegionCoord rx ry rz) = case regionOf rig region of
  Left e → [e]
  Right rk →
    [ show (x, y, z) <> ": region " <> show got <> ", queryCell " <> show want
    | x ← [16 * toInteger rx .. 16 * toInteger rx + 15]
    , y ← [16 * toInteger ry .. 16 * toInteger ry + 15]
    , z ← [32 * toInteger rz .. 32 * toInteger rz + 31]
    , let tile = mustTile x y z
          got = regionKnowledgeAt rk tile
          want = either (const Nothing) Just (observedValue (queryCell (rigEnv rig) (rigProvider rig) tile))
    , got /= want || got == Nothing
    ]
