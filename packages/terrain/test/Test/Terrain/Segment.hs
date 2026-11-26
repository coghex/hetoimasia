-- | Examples for the palette, the 17-bit tagged packing and the three segment
-- encodings.
--
-- Decoded values are compared with an explicit list of cells; the expected
-- payload sizes are the literals of the approved table, and the threshold cases
-- are worked by hand beside the examples that use them.
module Test.Terrain.Segment (spec) where

import Control.Monad (filterM, forM_)
import Data.Bits (shiftL, shiftR, (.&.))
import Data.Word (Word16, Word32)
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
  cornerSpec

packingSpec ∷ Spec
packingSpec = describe "the 16-bit cell value" $ do
  it "encodes air as zero" $ do
    packedWord packedAir `shouldBe` Just 0
    packedBits packedAir `shouldBe` 0
    packCell emptyPalette Air `shouldBe` Right packedAir
  it "keeps every shape identity of a material distinct, including 0 and 15, and distinct from air" $ do
    let (idx, palette) = mustIntern "stone" emptyPalette
        packed = [packCell palette (cellOf "stone" s) | s ← [0 .. 15]]
    idx `shouldBe` 1
    [fmap packedWord p | p ← packed] `shouldBe` [Right (Just (16 + s)) | s ← [0 .. 15]]
    forM_ [0 .. 15] $ \s → fmap (unpackCell palette) (packed !! s) `shouldBe` Right (Right (cellOf "stone" s))
    packCell palette (cellOf "stone" 0) `shouldNotBe` Right packedAir
  it "splits a historic value into a 12-bit index over a 4-bit shape with a clear tag" $ do
    let p = either (error . show) id (mkPackedCell 0xABCF)
    (packedIndex p, packedShape p, packedIsCorner p) `shouldBe` (0xABC, 0xF, False)
    (fmap (`shiftR` 4) (packedWord p), fmap (.&. 15) (packedWord p)) `shouldBe` (Just 0xABC, Just 0xF)
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
    fmap packedWord (packCell full (Solid (names !! 4094) (either (error . show) id (mkShapeId 0)))) `shouldBe` Right (Just (4095 `shiftL` 4))
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
  it "keeps a run word as its exclusive end above its 17-bit value, ascending and coalesced" $ do
    let s = build 0 (replicate 20 b <> replicate 12 c)
    segmentRunWords s `shouldBe` [20 * 131072 + 0x20, 32 * 131072 + 0x37]
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
    property $ forAll (oneof [genCells, genCellsFrom (air : a : c : cornerCells)]) $ \cells →
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
-- all three: uniform 2 (3 for a corner), runs 4 per run, dense 2 per cell and
-- one tag bit per cell when a corner is present, taking the minimum. Ties
-- between runs and dense cost the same, so a byte count suffices.
modelBytes ∷ [PackedCell] → Int
modelBytes cells = minimum ([if any packedIsCorner cells then 3 else 2 | allSame] <> [4 * runCount, dense])
  where
    allSame = and (zipWith (==) cells (drop 1 cells))
    runCount = 1 + length [() | (x, y) ← zip cells (drop 1 cells), x /= y]
    dense = 2 * length cells + (if any packedIsCorner cells then (length cells + 7) `div` 8 else 0)

-- | Contents with every run structure: few cuts, many cuts, any in between.
genCellsFrom ∷ [PackedCell] → Gen [PackedCell]
genCellsFrom pool = do
  n ← choose (1, 32)
  density ← choose (0, 15 ∷ Int)
  cuts ← filterM (\_ → (<= density) <$> choose (0, 15)) [1 .. n - 1]
  let points = 0 : cuts <> [n]
      lengths = zipWith (-) (drop 1 points) points
  values ← vectorOf (length lengths) (elements pool)
  pure (concat (zipWith replicate lengths values))

genCells ∷ Gen [PackedCell]
genCells = genCellsFrom [air, a, b, c]

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

-- | Fixture keys. Side 15 and corner 15 have the same low four bits.
sideK ∷ Int → ShapeKey
sideK = sideKey . either (error . show) id . mkShapeId

cornerK ∷ Int → ShapeKey
cornerK = maybe (error "corner zero") id . resolveCorner . either (error . show) id . mkCornerMask

stonePalette ∷ Palette
stonePalette = snd (mustIntern "stone" emptyPalette)

-- | A stone cell of a key, packed through the checked path.
stone ∷ ShapeKey → PackedCell
stone = either (error . show) id . packKey stonePalette (mustMaterial "stone")

-- | Corner values of index 1 and 2 beside the side values @a@, @b@, @c@.
cornerCells ∷ [PackedCell]
cornerCells = [stone (cornerK 15), stone (cornerK 1), either (error . show) id (packIndexed palette2 2 (cornerK 6))]
  where
    palette2 = snd (mustIntern "other" stonePalette)

keysOf ∷ Palette → Segment → [Maybe (MaterialId, ShapeKey)]
keysOf palette = map (either (error . show) id . unpackKey palette) . segmentCells

-- | The tagged storage: bit 16 distinguishes a corner key, a historic word
-- zero-extends, and a corner value is never narrowed to a side value.
cornerSpec ∷ Spec
cornerSpec = describe "the family tag" $ do
  it "keeps side 0, side 15 and corner 15 of a material distinct occupied values" $ do
    let values = [stone (sideK 0), stone (sideK 15), stone (cornerK 15)]
    map packedBits values `shouldBe` [0x10, 0x1F, 0x1001F]
    map packedIsCorner values `shouldBe` [False, False, True]
    length (filter (== packedAir) values) `shouldBe` 0
    values `shouldSatisfy` (\vs → and [x /= y | (i, x) ← zip [0 ∷ Int ..] vs, (j, y) ← zip [0 ..] vs, i < j])
  it "round-trips all 31 occupied keys at the first and the maximum palette index" $ do
    let names = [mustMaterial ("m" <> show i) | i ← [1 .. 4095 ∷ Int]]
        full = foldl (\p m → either (error . show) snd (internMaterial m p)) emptyPalette names
    forM_ [(stonePalette, mustMaterial "stone", 1), (full, last names, 4095)] $ \(palette, material, index) →
      forM_ allShapeKeys $ \key → do
        let packed = either (error . show) id (packKey palette material key)
        packedIndex packed `shouldBe` index
        unpackKey palette packed `shouldBe` Right (Just (material, key))
        unpackCell palette packed `shouldBe` case [n | n ← [0 .. 15], sideK n == key] of
          [n] → Right (Solid material (either (error . show) id (mkShapeId n)))
          _ → Left (CornerCell (packedShape packed))
  it "zero-extends every valid historic word to the side key it always meant" $
    forM_ [(i, s) | i ← [1, 2, 0x555, 4095], s ← [0 .. 15]] $ \(i, s) → do
      let w = (i `shiftL` 4) + s ∷ Word16
          packed = either (error . show) id (mkPackedCell w)
      (packedBits packed, packedWord packed, packedIsCorner packed) `shouldBe` (fromIntegral w, Just w, False)
      mkPackedBits (fromIntegral w) `shouldBe` Right packed
  it "never gives a corner value a legacy word" $ do
    packedWord (stone (cornerK 15)) `shouldBe` Nothing
    packedWord (stone (cornerK 1)) `shouldBe` Nothing
  it "refuses unknown tag bits, noncanonical air and a corner zero through the checked boundary" $ do
    mkPackedBits 0x20010 `shouldBe` Left (UnknownTagBits 0x20010)
    mkPackedBits 0xFFFFFFFF `shouldBe` Left (UnknownTagBits 0xFFFFFFFF)
    mkPackedBits 0x10000 `shouldBe` Left (NonCanonicalAir 0x10000)
    mkPackedBits 0x1000F `shouldBe` Left (NonCanonicalAir 0x1000F)
    mkPackedBits 0x10010 `shouldBe` Left PackedCornerZero
    mkPackedBits 0x1FFF0 `shouldBe` Left PackedCornerZero
    mkPackedBits 0 `shouldBe` Right packedAir
    fmap packedBits (mkPackedBits 0x1FFFF) `shouldBe` Right 0x1FFFF
  it "refuses a corner zero, an unassigned or unrepresentable material, and an unassigned index" $ do
    let zero = either (error . show) id (mkCornerMask 0)
        full = foldl (\p i → either (error . show) snd (internMaterial (mustMaterial ("m" <> show i)) p)) emptyPalette [1 .. 4095 ∷ Int]
    packCorner stonePalette (mustMaterial "stone") zero `shouldBe` Left PackedCornerZero
    internCorner (mustMaterial "stone") zero emptyPalette `shouldBe` Left PackedCornerZero
    packKey emptyPalette (mustMaterial "stone") (cornerK 3) `shouldBe` Left (MaterialNotInPalette (mustMaterial "stone"))
    internKey (mustMaterial "extra") (cornerK 3) full `shouldBe` Left PaletteFull
    paletteSize full `shouldBe` 4095
    packIndexed stonePalette 2 (cornerK 3) `shouldBe` Left (UnassignedIndex 2)
    packIndexed stonePalette 0 (cornerK 3) `shouldBe` Left (UnassignedIndex 0)
    unpackKey emptyPalette (either (error . show) id (mkPackedBits 0x10041)) `shouldBe` Left (UnassignedIndex 4)
    unpackCell emptyPalette (either (error . show) id (mkPackedBits 0x10041)) `shouldBe` Left (UnassignedIndex 4)
  it "interns a corner's material and returns a corner cell value" $ do
    let mask = either (error . show) id (mkCornerMask 9)
        (packed, palette) = either (error . show) id (internCorner (mustMaterial "soil") mask emptyPalette)
    (packedBits packed, paletteSize palette) `shouldBe` (0x10019, 1)
    unpackKey palette packed `shouldBe` Right (Just (mustMaterial "soil", cornerK 9))
    unpackCell palette packed `shouldBe` Left (CornerCell 9)
  it "stores a uniform corner as 3 bytes and a uniform side as 2" $ do
    let corner = build 0 (replicate 32 (stone (cornerK 15)))
    (segmentEncoding corner, segmentPayloadBytes corner) `shouldBe` (Uniform, 3)
    segmentCells corner `shouldBe` replicate 32 (stone (cornerK 15))
    segmentPayloadBytes (build 0 (replicate 32 (stone (sideK 15)))) `shouldBe` 2
  it "keeps adjacent cells that differ only in the tag in separate runs" $ do
    let side15 = stone (sideK 15)
        corner15 = stone (cornerK 15)
        s = build 0 (replicate 20 side15 <> replicate 12 corner15)
    (segmentEncoding s, segmentRunCount s, segmentPayloadBytes s) `shouldBe` (Runs, Just 2, 8)
    segmentRunWords s `shouldBe` [20 * 131072 + 0x1F, 32 * 131072 + 0x1001F]
    keysOf stonePalette s `shouldBe` replicate 20 (Just (mustMaterial "stone", sideK 15)) <> replicate 12 (Just (mustMaterial "stone", cornerK 15))
    map segmentLookupBits [0, 19, 20, 31] `shouldBe` [0x1F, 0x1F, 0x1001F, 0x1001F]
  it "tags a dense segment with one bit per cell, and prefers runs only below that cost" $ do
    let side15 = stone (sideK 15)
        corner15 = stone (cornerK 15)
        alternatingRuns lens = build 0 (concat [replicate len (if even i then side15 else corner15) | (i, len) ← zip [0 ∷ Int ..] lens])
        sixteen = alternatingRuns (replicate 16 2)
        seventeen = alternatingRuns (replicate 16 1 <> [16])
        alternating = build 0 (concat (replicate 16 [side15, corner15]))
    (segmentEncoding sixteen, segmentPayloadBytes sixteen, segmentRunCount sixteen) `shouldBe` (Runs, 64, Just 16)
    (segmentEncoding seventeen, segmentPayloadBytes seventeen) `shouldBe` (Dense, 68)
    (segmentEncoding alternating, segmentPayloadBytes alternating) `shouldBe` (Dense, 68)
    segmentCells alternating `shouldBe` concat (replicate 16 [side15, corner15])
    keysOf stonePalette alternating `shouldBe` take 32 (cycle [Just (mustMaterial "stone", sideK 15), Just (mustMaterial "stone", cornerK 15)])
    -- Three cells, two runs: 8 run bytes against 6 value bytes and one tag byte.
    let small = build 0 [side15, side15, corner15]
    (segmentEncoding small, segmentPayloadBytes small) `shouldBe` (Dense, 7)
  it "bounds the largest payload at 68 bytes" $
    maxSegmentPayloadBytes `shouldBe` 68
  it "charges a mixed-family segment no more than the largest payload, and a side-only one as before" $
    property $ forAll (genCellsFrom (air : a : b : cornerCells)) $ \cells →
      let s = build 0 cells
          n = length cells
       in conjoin
            [ property (segmentPayloadBytes s <= maxSegmentPayloadBytes)
            , property (segmentPayloadBytes s <= max 3 (2 * n + (n + 7) `div` 8))
            , if any packedIsCorner cells then property True else segmentPayloadBytes s === modelBytes cells
            ]
  it "carries the tag through updates and slices, and returns to the side charge once no corner remains" $ do
    let corner15 = stone (cornerK 15)
        side15 = stone (sideK 15)
        base = build 0 (replicate 32 side15)
        edit segment changes = either (error . show) id (updateSegment segment changes)
        withCorner = edit base [(axis 10, corner15)]
        mixed = edit base [(axis (toInteger i), corner15) | i ← [1, 3 .. 31 ∷ Int]]
        cleared = edit mixed [(axis (toInteger i), side15) | i ← [1, 3 .. 31 ∷ Int]]
    (segmentEncoding withCorner, segmentRunCount withCorner, segmentPayloadBytes withCorner) `shouldBe` (Runs, Just 3, 12)
    segmentLookup withCorner (axis 10) `shouldBe` Just corner15
    segmentLookup withCorner (axis 9) `shouldBe` Just side15
    (segmentEncoding mixed, segmentPayloadBytes mixed) `shouldBe` (Dense, 68)
    segmentSlice mixed 2 6 `shouldBe` Just (axis 2, [side15, corner15, side15, corner15])
    (segmentEncoding cleared, segmentPayloadBytes cleared) `shouldBe` (Uniform, 2)
    -- The predecessor stays valid and unchanged.
    segmentCells base `shouldBe` replicate 32 side15
  it "refuses an update at a level outside the segment without building a mixed one" $ do
    let s = build 4 [stone (sideK 15), stone (sideK 15)]
    updateSegment s [(axis 5, stone (cornerK 15)), (axis 9, stone (cornerK 15))] `shouldBe` Left (LevelNotInSegment 9)
    segmentCells s `shouldBe` [stone (sideK 15), stone (sideK 15)]
  where
    segmentLookupBits z = maybe 0 packedBits (segmentLookup (build 0 (replicate 20 (stone (sideK 15)) <> replicate 12 (stone (cornerK 15)))) (axis z)) ∷ Word32
