-- | Examples for the palette, the 16-bit packing and the three segment
-- encodings.
--
-- Decoded values are compared with an explicit list of cells; the expected
-- payload sizes are the literals of the approved table, and the threshold cases
-- are worked by hand beside the examples that use them.
module Test.Terrain.Segment (spec) where

import Control.Monad (filterM, forM_)
import Data.Bits (shiftL, shiftR, (.&.))
import Data.Word (Word16)
import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Coordinate
import Hetoimasia.Terrain.Palette
import Hetoimasia.Terrain.Segment
import Hetoimasia.Terrain.Shape
import Test.Hspec
import Test.QuickCheck hiding ((.&.))
import Test.Terrain.Model

axis ∷ Integer → AxisCoord
axis = either (error . show) id . axisFromInteger

-- | A packed value from an index and a shape, written out bit by bit.
word ∷ Word16 → Word16 → PackedCell
word index shape = either (error . show) id (mkPackedCell ((index `shiftL` 4) + shape))

air, a, b, c ∷ PackedCell
air = packedAir
a = word 1 0
b = word 2 0
c = word 3 7

mustIntern ∷ String → Palette → (Word16, Palette)
mustIntern name = either (error . show) id . internMaterial (mustMaterial name)

build ∷ Integer → [PackedCell] → Segment
build start = either (error . show) id . buildSegment (axis start)

spec ∷ Spec
spec = describe "Packed storage" $ do
  packingSpec
  paletteSpec
  encodingSpec
  boundarySpec
  updateSpec

packingSpec ∷ Spec
packingSpec = describe "the 16-bit cell value" $ do
  it "encodes air as zero" $ do
    packedWord packedAir `shouldBe` 0
    packCell emptyPalette Air `shouldBe` Right packedAir
  it "keeps every shape identity of a material distinct, including 0 and 15, and distinct from air" $ do
    let (idx, palette) = mustIntern "stone" emptyPalette
        packed = [packCell palette (cellOf "stone" s) | s ← [0 .. 15]]
    idx `shouldBe` 1
    [fmap packedWord p | p ← packed] `shouldBe` [Right (16 + s) | s ← [0 .. 15]]
    forM_ [0 .. 15] $ \s → fmap (unpackCell palette) (packed !! s) `shouldBe` Right (Right (cellOf "stone" s))
    packCell palette (cellOf "stone" 0) `shouldNotBe` Right packedAir
  it "splits a value into a 12-bit index over a 4-bit shape" $ do
    let p = either (error . show) id (mkPackedCell 0xABCF)
    (packedIndex p, packedShape p) `shouldBe` (0xABC, 0xF)
    (packedWord p `shiftR` 4, packedWord p .&. 15) `shouldBe` (0xABC, 0xF)
  it "refuses an air index carrying a shape instead of normalizing it" $ do
    mkPackedCell 0x0005 `shouldBe` Left (NonCanonicalAir 5)
    mkPackedCell 0x000F `shouldBe` Left (NonCanonicalAir 15)
    mkPackedCell 0 `shouldBe` Right packedAir
    unpackCell emptyPalette (word 0 0) `shouldBe` Right Air
  it "refuses a cell whose material is not in the palette, and an unassigned index" $ do
    packCell emptyPalette (cellOf "stone" 3) `shouldBe` Left (MaterialNotInPalette (mustMaterial "stone"))
    unpackCell emptyPalette (word 4 0) `shouldBe` Left (UnassignedIndex 4)

paletteSpec ∷ Spec
paletteSpec = describe "the material palette" $ do
  it "assigns stable indices from 1 and reuses an assigned one" $ do
    let (i1, p1) = mustIntern "a" emptyPalette
        (i2, p2) = mustIntern "b" p1
        (i3, p3) = mustIntern "a" p2
    (i1, i2, i3) `shouldBe` (1, 2, 1)
    paletteSize p3 `shouldBe` 2
    map materialIdString (paletteMaterials p3) `shouldBe` ["a", "b"]
    paletteMaterial p3 2 `shouldBe` Just (mustMaterial "b")
    paletteMaterial p3 0 `shouldBe` Nothing
  it "accepts 4,095 materials and refuses the 4,096th, leaving the previous palette valid" $ do
    let names = [mustMaterial ("m" <> show i) | i ← [1 .. 4096 ∷ Int]]
        fill p [] = p
        fill p (m : ms) = either (error . show) (fill' ms) (internMaterial m p)
        fill' ms (_, p) = fill p ms
        full = fill emptyPalette (take 4095 names)
    maxPaletteEntries `shouldBe` 4095
    paletteSize full `shouldBe` 4095
    paletteIndex full (names !! 4094) `shouldBe` Just 4095
    internMaterial (names !! 4095) full `shouldBe` Left PaletteFull
    -- An assigned material still resolves; nothing was truncated or aliased.
    fmap fst (internMaterial (names !! 7) full) `shouldBe` Right 8
    fmap packedWord (packCell full (Solid (names !! 4094) (either (error . show) id (mkShapeId 0)))) `shouldBe` Right (4095 `shiftL` 4)
    paletteSize full `shouldBe` 4095
  it "starts an arena palette from a source's authored numbering" $ do
    let source = mustSource soilOverStone
    fmap (map materialIdString . paletteMaterials) (internSourceMaterials source emptyPalette) `shouldBe` Right ["soil", "stone"]

-- | The expected encoding and payload bytes of explicit 32-cell patterns.
encodingSpec ∷ Spec
encodingSpec = describe "value encodings" $ do
  it "stores one requested surface cell as a 2-byte uniform value" $ do
    let s = build 0 [a]
    (segmentEncoding s, segmentPayloadBytes s, segmentLength s) `shouldBe` (Uniform, 2, 1)
  it "stores 32 identical cells as 2 bytes" $ do
    let s = build 0 (replicate 32 a)
    (segmentEncoding s, segmentPayloadBytes s) `shouldBe` (Uniform, 2)
  it "stores two runs (soil over stone) as 8 bytes" $ do
    let s = build 0 (replicate 20 b <> replicate 12 a)
    (segmentEncoding s, segmentPayloadBytes s, segmentRunCount s) `shouldBe` (Runs, 8, Just 2)
  it "stores three runs (a cavity) as 12 bytes" $ do
    let s = build 0 (replicate 10 a <> replicate 12 air <> replicate 10 a)
    (segmentEncoding s, segmentPayloadBytes s, segmentRunCount s) `shouldBe` (Runs, 12, Just 3)
  it "stores 16 runs as 64 dense bytes, a tie going to direct indexing" $ do
    let s = build 0 (concat [replicate 2 (if even i then a else b) | i ← [0 .. 15 ∷ Int]])
    (segmentEncoding s, segmentPayloadBytes s, segmentRunCount s) `shouldBe` (Dense, 64, Nothing)
  it "stores 32 alternating cells as 64 dense bytes" $ do
    let s = build 0 (concat (replicate 16 [a, b]))
    (segmentEncoding s, segmentPayloadBytes s) `shouldBe` (Dense, 64)
  it "stores 15 runs as 60 run bytes: the most a nonuniform 32-cell segment keeps as runs" $ do
    -- One run of 18 equal cells, then 14 singletons alternating b, a, ...: 15 runs.
    let fifteen = build 0 (replicate 18 a <> [if odd i then b else a | i ← [1 .. 14 ∷ Int]])
    (segmentLength fifteen, segmentEncoding fifteen, segmentPayloadBytes fifteen, segmentRunCount fifteen)
      `shouldBe` (32, Runs, 60, Just 15)
  it "keeps a run word as its exclusive end over its 16-bit value, ascending and coalesced" $ do
    let s = build 0 (replicate 20 b <> replicate 12 c)
    segmentRunWords s `shouldBe` [20 * 65536 + 0x20, 32 * 65536 + 0x37]
  it "switches at the threshold for other lengths: runs only while 4R < 2N" $ do
    -- N = 10: four runs cost 16 < 20 bytes (runs); five cost 20, a tie (dense).
    let pattern' r = concat [if i == r - 1 then replicate (10 - (r - 1)) (cell i) else [cell i] | i ← [0 .. r - 1]]
        cell i = if even (i ∷ Int) then a else b
    (segmentEncoding (build 0 (pattern' 4)), segmentPayloadBytes (build 0 (pattern' 4))) `shouldBe` (Runs, 16)
    (segmentEncoding (build 0 (pattern' 5)), segmentPayloadBytes (build 0 (pattern' 5))) `shouldBe` (Dense, 20)
    -- N = 2: two different cells cost 8 run bytes against 4 dense bytes.
    (segmentEncoding (build 0 [a, b]), segmentPayloadBytes (build 0 [a, b])) `shouldBe` (Dense, 4)
    -- N = 3: two runs cost 8 > 6, dense; N = 4: two runs cost 8 = 8, a tie, dense.
    segmentEncoding (build 0 [a, a, b]) `shouldBe` Dense
    segmentEncoding (build 0 [a, a, b, b]) `shouldBe` Dense
    -- N = 5: two runs cost 8 < 10: runs.
    segmentEncoding (build 0 [a, a, a, b, b]) `shouldBe` Runs
  it "decodes every encoding to the cells it was built from, by direct and by searched lookup" $
    forM_ patterns $ \cells → do
      let s = build 64 cells
      segmentCells s `shouldBe` cells
      [segmentLookup s (axis (64 + toInteger i)) | i ← [0 .. length cells - 1]] `shouldBe` map Just cells
      segmentLookup s (axis 63) `shouldBe` Nothing
      segmentLookup s (axis (64 + toInteger (length cells))) `shouldBe` Nothing
  it "decodes random contents identically whatever encoding was chosen" $
    property $ forAll genCells $ \cells →
      let s = build 96 cells
       in conjoin
            [ segmentCells s === cells
            , map (segmentLookup s . axis . (96 +) . toInteger) [0 .. length cells - 1] === map Just cells
            , segmentPayloadBytes s === modelBytes cells
            ]
  where
    patterns =
      [ [a]
      , replicate 32 c
      , replicate 5 a <> replicate 27 b
      , replicate 9 a <> replicate 14 air <> replicate 9 b
      , concat (replicate 16 [a, b])
      , concat [replicate 2 (if even i then a else air) | i ← [0 .. 15 ∷ Int]]
      , [if i == 31 then b else a | i ← [0 .. 31 ∷ Int]]
      ]

-- | The payload bytes of the cheapest of the three encodings, found by costing
-- all three: uniform 2, runs 4 per run, dense 2 per cell, taking the minimum.
-- Ties between runs and dense cost the same, so a byte count suffices.
modelBytes ∷ [PackedCell] → Int
modelBytes cells = minimum ([2 | allSame] <> [4 * runCount, 2 * length cells])
  where
    allSame = and (zipWith (==) cells (drop 1 cells))
    runCount = 1 + length [() | (x, y) ← zip cells (drop 1 cells), x /= y]

-- | Contents with every run structure: few cuts, many cuts, any in between.
genCells ∷ Gen [PackedCell]
genCells = do
  n ← choose (1, 32)
  density ← choose (0, 15 ∷ Int)
  cuts ← filterM (\_ → (<= density) <$> choose (0, 15)) [1 .. n - 1]
  let points = 0 : cuts <> [n]
      lengths = zipWith (-) (drop 1 points) points
  values ← vectorOf (length lengths) (elements [air, a, b, c])
  pure (concat (zipWith replicate lengths values))

boundarySpec ∷ Spec
boundarySpec = describe "segment bounds" $ do
  it "accepts 1 to 32 cells and refuses none or 33" $ do
    buildSegment (axis 0) [] `shouldBe` Left EmptySegment
    buildSegment (axis 0) (replicate 33 a) `shouldBe` Left (SegmentTooLong 33)
    buildSegment (axis 0) (replicate 1000 a) `shouldBe` Left (SegmentTooLong 33)
    buildSegment (axis 0) (replicate 32 a) `shouldSatisfy` either (const False) (const True)
  it "keeps a segment inside one vertical region, on both sides of zero" $ do
    buildSegment (axis 31) [a, a] `shouldBe` Left SegmentCrossesRegion
    buildSegment (axis (-1)) [a, a] `shouldBe` Left SegmentCrossesRegion
    buildSegment (axis (-33)) [a, a] `shouldBe` Left SegmentCrossesRegion
    buildSegment (axis 30) [a, a] `shouldSatisfy` either (const False) (const True)
    buildSegment (axis (-32)) (replicate 32 a) `shouldSatisfy` either (const False) (const True)
    buildSegment (axis (-2)) [a, a] `shouldSatisfy` either (const False) (const True)
    buildSegment (axis 1) (replicate 32 a) `shouldBe` Left SegmentCrossesRegion
  it "holds the first and the last supported region" $ do
    buildSegment (axis lowest) [a] `shouldSatisfy` either (const False) (const True)
    buildSegment (axis (highest - 31)) (replicate 32 b) `shouldSatisfy` either (const False) (const True)
    segmentEnd (build (highest - 31) (replicate 32 b)) `shouldBe` topEnd
  it "does not look past the 33rd cell of an endless list" $
    buildSegment (axis 0) (repeat a) `shouldBe` Left (SegmentTooLong 33)

updateSpec ∷ Spec
updateSpec = describe "updating a segment" $ do
  it "chooses the new encoding once, across every transition" $ do
    let uniform = build 0 (replicate 32 a)
        withOne = either (error . show) id (updateSegment uniform [(axis 10, b)])
        withTwo = either (error . show) id (updateSegment withOne [(axis 11, b)])
        alternating = either (error . show) id (updateSegment uniform [(axis (toInteger i), b) | i ← [0, 2 .. 30 ∷ Int]])
        back = either (error . show) id (updateSegment alternating [(axis (toInteger i), a) | i ← [0, 2 .. 30 ∷ Int]])
    (segmentEncoding withOne, segmentRunCount withOne) `shouldBe` (Runs, Just 3)
    (segmentEncoding withTwo, segmentRunCount withTwo) `shouldBe` (Runs, Just 3)
    (segmentEncoding alternating, segmentPayloadBytes alternating) `shouldBe` (Dense, 64)
    (segmentEncoding back, segmentPayloadBytes back) `shouldBe` (Uniform, 2)
  it "leaves the previous segment unchanged and shares nothing mutable with it" $ do
    let original = build 0 (replicate 32 a)
        copy = original
        _ = either (error . show) id (updateSegment original [(axis 0, b), (axis 31, c)])
    original `shouldBe` copy
    segmentCells original `shouldBe` replicate 32 a
  it "takes the last of two updates to one level" $ do
    let s = either (error . show) id (updateSegment (build 0 [a, a, a]) [(axis 1, b), (axis 1, c)])
    segmentCells s `shouldBe` [a, c, a]
  it "refuses a level outside the segment and builds nothing" $ do
    updateSegment (build 4 [a, a]) [(axis 6, b)] `shouldBe` Left (LevelNotInSegment 6)
    updateSegment (build 4 [a, a]) [(axis 4, b), (axis 3, b)] `shouldBe` Left (LevelNotInSegment 3)
  it "never expands the known interval to choose an encoding" $ do
    let s = either (error . show) id (updateSegment (build 100 [a]) [(axis 100, b)])
    (segmentStart s, segmentLength s, segmentPayloadBytes s) `shouldBe` (axis 100, 1, 2)
  it "slices a segment to a clipped interval" $ do
    let s = build 10 [a, b, c, a]
    segmentSlice s 11 13 `shouldBe` Just (axis 11, [b, c])
    segmentSlice s 0 11 `shouldBe` Just (axis 10, [a])
    segmentSlice s 14 20 `shouldBe` Nothing
