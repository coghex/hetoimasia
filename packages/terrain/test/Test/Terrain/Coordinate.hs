-- | Examples for checked tile identity, region decomposition and cutaway.
--
-- Every expected value is stated literally (powers of two are written out), so
-- none is produced by the library. The extremes are @-2^62 =
-- -4611686018427387904@ and @2^62 - 1 = 4611686018427387903@.
module Test.Terrain.Coordinate (spec) where

import Data.Int (Int64)
import Hetoimasia.Terrain.Coordinate
import Test.Hspec
import Test.QuickCheck

lowest, highest ∷ Integer
lowest = -4611686018427387904
highest = 4611686018427387903

axis ∷ Integer → AxisCoord
axis value = either (error . show) id (axisFromInteger value)

tile ∷ Integer → Integer → Integer → TileCoord
tile x y z = either (error . show) id (tileCoord x y z)

local ∷ Integer → Integer → Integer → LocalCoord
local x y z = either (error . show) id (mkLocalCoord x y z)

-- | The region key and local offset of a tile that varies on one axis only.
xSplit, ySplit, zSplit ∷ Integer → (Int64, Integer)
xSplit value = let (RegionCoord r _ _, l) = decomposeTile (tile value 0 0) in (r, toInteger (localX l))
ySplit value = let (RegionCoord _ r _, l) = decomposeTile (tile 0 value 0) in (r, toInteger (localY l))
zSplit value = let (RegionCoord _ _ r, l) = decomposeTile (tile 0 0 value) in (r, toInteger (localZ l))

spec ∷ Spec
spec = describe "Coordinates" $ do
  rangeSpec
  arithmeticSpec
  regionSpec
  propertySpec
  cutawaySpec

rangeSpec ∷ Spec
rangeSpec = describe "the supported range" $ do
  it "states the range as -2^62 .. 2^62 - 1" $ do
    axisMinValue `shouldBe` lowest
    axisMaxValue `shouldBe` highest
  it "accepts both extremes exactly" $ do
    fmap axisValue (axisFromInteger lowest) `shouldBe` Right (-4611686018427387904)
    fmap axisValue (axisFromInteger highest) `shouldBe` Right 4611686018427387903
  it "refuses a value just outside either end, keeping the exact value" $ do
    axisFromInteger (highest + 1) `shouldBe` Left (AxisOutOfRange 4611686018427387904)
    axisFromInteger (lowest - 1) `shouldBe` Left (AxisOutOfRange (-4611686018427387905))
  it "refuses values far beyond 64 bits without wrapping" $ do
    axisFromInteger (2 ^ (64 ∷ Int)) `shouldBe` Left (AxisOutOfRange 18446744073709551616)
    axisFromInteger (negate (2 ^ (70 ∷ Int))) `shouldBe` Left (AxisOutOfRange (negate (2 ^ (70 ∷ Int))))
  it "builds a tile from three checked axes and reports the first axis out of range" $ do
    tileCoord 1 (-2) 3 `shouldBe` Right (TileCoord (axis 1) (axis (-2)) (axis 3))
    tileCoord 0 (highest + 1) (lowest - 1) `shouldBe` Left (AxisOutOfRange 4611686018427387904)
    tileCoord 0 0 (lowest - 1) `shouldBe` Left (AxisOutOfRange (-4611686018427387905))

arithmeticSpec ∷ Spec
arithmeticSpec = describe "arithmetic" $ do
  it "translates by an exact offset" $
    translateTile 5 (-7) 0 (tile 10 10 10) `shouldBe` Right (tile 15 3 10)
  it "refuses a result one past either extreme" $ do
    translateTile 1 0 0 (tile highest 0 0) `shouldBe` Left (AxisOutOfRange 4611686018427387904)
    translateTile 0 (-1) 0 (tile 0 lowest 0) `shouldBe` Left (AxisOutOfRange (-4611686018427387905))
    translateTile 0 0 1 (tile 0 0 highest) `shouldBe` Left (AxisOutOfRange 4611686018427387904)
  it "reaches an extreme exactly" $ do
    translateTile 0 0 (-1) (tile 0 0 (lowest + 1)) `shouldBe` Right (tile 0 0 lowest)
    translateTile 1 0 0 (tile (highest - 1) 0 0) `shouldBe` Right (tile highest 0 0)
  it "uses a wider intermediate: the largest offset from the lowest tile lands on the highest" $
    translateTile maxBound 0 0 (tile lowest 0 0) `shouldBe` Right (tile highest 0 0)
  it "refuses, with the exact value, an offset that would wrap a 64-bit sum" $ do
    translateTile maxBound 0 0 (tile highest 0 0) `shouldBe` Left (AxisOutOfRange 13835058055282163710)
    translateTile minBound 0 0 (tile lowest 0 0) `shouldBe` Left (AxisOutOfRange (-13835058055282163712))
  it "keeps the exact difference between the extremes" $ do
    tileDelta (tile lowest lowest lowest) (tile highest highest highest)
      `shouldBe` TileDelta 9223372036854775807 9223372036854775807 9223372036854775807
    tileDelta (tile highest lowest 0) (tile lowest highest 0)
      `shouldBe` TileDelta (-9223372036854775807) 9223372036854775807 0
  it "applies a delta to give back the target, even across the whole range" $ do
    let from = tile lowest highest 5
        to = tile highest lowest (-5)
        TileDelta dx dy dz = tileDelta from to
    translateTile dx dy dz from `shouldBe` Right to
  it "never converts identity to floating point: adjacent tiles at the extreme stay distinct" $
    tile highest 0 0 `shouldNotBe` tile (highest - 1) 0 0

regionSpec ∷ Spec
regionSpec = describe "region and local decomposition" $ do
  it "decomposes X by 16, with negative seams" $
    mapM_
      (\(value, region, offset) → xSplit value `shouldBe` (region, offset))
      [(0, 0, 0), (15, 0, 15), (16, 1, 0), (-1, -1, 15), (-16, -1, 0), (-17, -2, 15), (-32, -2, 0), (-33, -3, 15)]
  it "decomposes Y by 16, with negative seams" $
    mapM_
      (\(value, region, offset) → ySplit value `shouldBe` (region, offset))
      [(0, 0, 0), (15, 0, 15), (16, 1, 0), (-1, -1, 15), (-16, -1, 0), (-17, -2, 15), (-32, -2, 0), (-33, -3, 15)]
  it "decomposes Z by 32, with negative seams" $
    mapM_
      (\(value, region, offset) → zSplit value `shouldBe` (region, offset))
      [(0, 0, 0), (31, 0, 31), (32, 1, 0), (-1, -1, 31), (-32, -1, 0), (-33, -2, 31), (-64, -2, 0), (-65, -3, 31)]
  it "decomposes the extremes" $ do
    let (RegionCoord rx ry rz, l) = decomposeTile (tile highest highest highest)
    (rx, ry, rz) `shouldBe` (288230376151711743, 288230376151711743, 144115188075855871)
    (localX l, localY l, localZ l) `shouldBe` (15, 15, 31)
    let (RegionCoord lx ly lz, m) = decomposeTile (tile lowest lowest lowest)
    (lx, ly, lz) `shouldBe` (-288230376151711744, -288230376151711744, -144115188075855872)
    (localX m, localY m, localZ m) `shouldBe` (0, 0, 0)
  it "recomposes a region and a local offset" $
    composeTile (RegionCoord (-1) 2 (-2)) (local 15 0 31) `shouldBe` Right (tile (-1) 32 (-33))
  it "refuses a recomposition outside the supported range, on each axis" $ do
    composeTile (RegionCoord 288230376151711744 0 0) (local 0 0 0) `shouldBe` Left (AxisOutOfRange 4611686018427387904)
    composeTile (RegionCoord 0 (-288230376151711745) 0) (local 0 15 0)
      `shouldBe` Left (AxisOutOfRange (-4611686018427387905))
    composeTile (RegionCoord 0 0 144115188075855872) (local 0 0 0) `shouldBe` Left (AxisOutOfRange 4611686018427387904)
    composeTile (RegionCoord maxBound maxBound maxBound) (local 15 15 31)
      `shouldBe` Left (AxisOutOfRange 147573952589676412927)
  it "accepts the last region on each side" $ do
    composeTile (RegionCoord 288230376151711743 0 0) (local 15 0 0) `shouldBe` Right (tile highest 0 0)
    composeTile (RegionCoord 0 0 (-144115188075855872)) (local 0 0 0) `shouldBe` Right (tile 0 0 lowest)
  it "refuses a local offset outside its region" $ do
    mkLocalCoord 16 0 0 `shouldBe` Left (LocalOutOfRange 16 16)
    mkLocalCoord 0 (-1) 0 `shouldBe` Left (LocalOutOfRange (-1) 16)
    mkLocalCoord 0 0 32 `shouldBe` Left (LocalOutOfRange 32 32)
    mkLocalCoord 15 15 31 `shouldSatisfy` either (const False) (const True)
  it "states the region size" $ do
    columnSize `shouldBe` 16
    regionLevels `shouldBe` 32

propertySpec ∷ Spec
propertySpec = describe "decomposition properties" $ do
  it "recomposes every decomposed tile to itself" $
    property $ forAll genTile $ \t → uncurry composeTile (decomposeTile t) === Right t
  it "keeps the local offset inside its region and the arithmetic exact" $
    property $ forAll genTile $ \t →
      let (RegionCoord rx ry rz, l) = decomposeTile t
          TileCoord x y z = t
       in conjoin
            [ property (localX l < 16)
            , property (localY l < 16)
            , property (localZ l < 32)
            , toInteger rx * 16 + toInteger (localX l) === toInteger (axisValue x)
            , toInteger ry * 16 + toInteger (localY l) === toInteger (axisValue y)
            , toInteger rz * 32 + toInteger (localZ l) === toInteger (axisValue z)
            ]
  it "decomposes a recomposed region and local offset to themselves" $
    property $ forAll genTile $ \t →
      let (region, offset) = decomposeTile t
       in fmap decomposeTile (composeTile region offset) === Right (region, offset)
  it "takes a tile to another by its exact delta" $
    property $ forAll ((,) <$> genTile <*> genTile) $ \(from, to) →
      let TileDelta dx dy dz = tileDelta from to
       in translateTile dx dy dz from === Right to
  it "agrees with Integer division for any tile" $
    property $ forAll genTile $ \t →
      let TileCoord x _ _ = t
          (RegionCoord rx _ _, _) = decomposeTile t
       in toInteger rx === toInteger (axisValue x) `div` 16

-- | Tiles drawn mostly from the extremes and the region seams, which is where
-- a wrong decomposition shows, with an unbiased share.
genTile ∷ Gen TileCoord
genTile = tile' <$> genAxis <*> genAxis <*> genAxis
  where
    tile' x y z = tile x y z

genAxis ∷ Gen Integer
genAxis =
  frequency
    [ (3, choose (lowest, highest))
    , (2, (+ lowest) <$> choose (0, 70))
    , (2, (highest -) <$> choose (0, 70))
    , (3, choose (-70, 70))
    ]

cutawaySpec ∷ Spec
cutawaySpec = describe "whole-cell cutaway" $ do
  it "includes cells with z <= k" $ do
    cutawayIncludes (axis 5) (axis 5) `shouldBe` True
    cutawayIncludes (axis 5) (axis 6) `shouldBe` False
    cutawayIncludes (axis 5) (axis (-100)) `shouldBe` True
    cutawayIncludes (axis (-1)) (axis 0) `shouldBe` False
  it "puts the plane at k + 1, exactly, even one above the highest level" $ do
    cutawayPlaneElevation (axis 5) `shouldBe` 6
    cutawayPlaneElevation (axis (-1)) `shouldBe` 0
    cutawayPlaneElevation (axis highest) `shouldBe` 4611686018427387904
    cutawayPlaneElevation (axis lowest) `shouldBe` (-4611686018427387903)
