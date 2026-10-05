-- | Mip chains generated on request: their shape, the filter, coverage
-- preservation, the request, and the decode that never asks for one.
--
-- Expected texels are written out here. They come from
-- @fixtures/mip_reference.py@, an independent reference using only Python's
-- standard library, with exact rational footprints; nothing here is produced
-- by the generator under test. The coverage and colour properties are
-- checked against 'referenceAverages' below, which computes each level's
-- averages from requirement 3's footprints with exact rationals.
module Test.Asset.Image.Mips (spec) where

import Control.Monad (forM_, unless, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Bits (shiftR)
import Data.List (nub)
import Data.Ratio ((%))
import Hetoimasia.Asset (AssetRefusal (..), Decoder (..))
import Hetoimasia.Asset.Image (DecodedImage (..), ImageKind (..), TexelFormat (..))
import Hetoimasia.Asset.Image.Mips (Coverage (..), MipRequest (..), generateMips, mipRequest, mipmapped)
import Hetoimasia.Asset.Image.Png (pngDecoder)
import Test.Asset.Image.Support (Texel, decodeFixture, fixtureAsset, fixtureBytes)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "Mips" $ do
  describe "the chain's shape" $ do
    -- Each level's byte count, against the extents requirement 2 gives.
    let sizes w h = map ByteString.length . decodedLevels <$> generated mipRequest (blank w h)
        extents = Right . map (\(w, h) → w * h * 4)
    it "runs a square image's levels down to 1 × 1" $
      sizes 8 8 `shouldBe` extents [(8, 8), (4, 4), (2, 2), (1, 1)]
    it "runs a non-square image's levels until both sides are 1" $ do
      sizes 8 2 `shouldBe` extents [(8, 2), (4, 1), (2, 1), (1, 1)]
      sizes 2 8 `shouldBe` extents [(2, 8), (1, 4), (1, 2), (1, 1)]
    it "halves odd extents rounding down, as the upload endpoint does" $
      sizes 5 3 `shouldBe` extents [(5, 3), (2, 1), (1, 1)]
    it "keeps a 1-pixel-wide image 1 wide" $
      sizes 1 5 `shouldBe` extents [(1, 5), (1, 2), (1, 1)]
    it "gives a 1 × 1 image no level beyond level 0" $
      sizes 1 1 `shouldBe` extents [(1, 1)]
    it "holds level width × height × 4 bytes at every level, and keeps level 0, the format, the extent and the mark" $
      forM_ [blank 5 3, saturation TexelRgba8Srgb, noise 17 9 9] $ \image → do
        let width = fromIntegral (decodedWidth image)
            height = fromIntegral (decodedHeight image)
        withGenerated mipRequest image $ \chain → do
          map ByteString.length (decodedLevels chain)
            `shouldBe` [max 1 (width `shiftR` l) * max 1 (height `shiftR` l) * 4 | l ← [0 .. length (decodedLevels chain) - 1]]
          take 1 (decodedLevels chain) `shouldBe` decodedLevels image
          chain {decodedLevels = []} `shouldBe` image {decodedLevels = []}

  describe "the filter" $ do
    it "averages every texel of an odd-extent data image, the edge column included" $
      -- Each output texel of a 3 × 1 image's 1 × 1 level covers all three
      -- texels with weight ⅓; dropping the third would make red 0.
      withGenerated mipRequest (imageOf TexelRgba8Linear 3 1 [(0, 10, 200, 0), (0, 20, 100, 128), (255, 30, 0, 255)]) $ \chain →
        generatedLevels chain `shouldBeLevels` [[(85, 20, 100, 128)]]
    it "weights a level 0 texel split between two output texels by its overlap with each" $
      -- 5 × 3 to 2 × 1: the middle column is shared half and half.
      withGenerated mipRequest dataFiveByThree $ \chain →
        generatedLevels chain
          `shouldBeLevels` [[(10, 15, 10, 112), (80, 82, 80, 76)], [(45, 48, 45, 94)]]
    it "averages a colour image's premultiplied colour in linear light" $
      -- Pure red, green and blue over a transparent texel: each linear channel
      -- averages to 0.25, which encodes as 137, not the 64 that averaging the
      -- stored bytes gives.
      withGenerated mipRequest (imageOf TexelRgba8Srgb 2 2 [(255, 0, 0, 255), (0, 255, 0, 255), (0, 0, 255, 255), (0, 0, 0, 0)]) $ \chain →
        generatedLevels chain `shouldBeLevels` [[(137, 137, 137, 191)]]
    it "averages an odd-extent, semi-transparent colour image in linear premultiplied space" $
      withGenerated mipRequest colourFiveByThree $ \chain →
        generatedLevels chain `shouldBeLevels` [[(126, 88, 115, 149), (106, 97, 79, 113)], [(117, 93, 99, 131)]]
    it "is pure: the same image and request give the same levels" $
      forM_ [colourFiveByThree, saturation TexelRgba8Srgb] $ \image →
        generated mipRequest image `shouldBe` generated mipRequest image {decodedLevels = map ByteString.copy (decodedLevels image)}
    it "computes every level from level 0, replacing any levels the image already had" $
      withGenerated mipRequest colourFiveByThree $ \chain →
        generated mipRequest chain `shouldBe` Right chain

  describe "coverage preservation" $ do
    it "keeps each level's covered fraction as close to level 0's as any scale allows" $
      forM_ cutouts $ \image → withGenerated mipRequest image (coverageIsClosest image)
    it "leaves the un-premultiplied colour of a scaled colour level unchanged" $
      forM_ (filter ((== TexelRgba8Srgb) . decodedFormat) cutouts) $ \image →
        withGenerated mipRequest image (colourIsUnscaled image)
    it "scales only alpha in a data level" $
      forM_ (filter ((== TexelRgba8Linear) . decodedFormat) cutouts) $ \image →
        withGenerated mipRequest image $ \chain → do
          plain ← either (fail . show) pure (generated (MipRequest PlainAverages) image)
          map (map (\(r, g, b, _) → (r, g, b)) . texelsOf) (generatedLevels chain)
            `shouldBe` map (map (\(r, g, b, _) → (r, g, b)) . texelsOf) (generatedLevels plain)
    it "clamps a saturated level and keeps its colour, rather than scaling colour past alpha" $
      -- Opaque counts 7, 3, 2 and 2 in four groups of eight: level 3's closest
      -- coverage, 2 of 4 against level 0's 14 of 32, needs a scale of 4 ÷ 3,
      -- which saturates the first group's alpha. Its colour stays 200, 40, 40.
      withGenerated mipRequest (saturation TexelRgba8Srgb) $ \chain →
        generatedLevels chain
          `shouldBeLevels` [ [ (200, 40, 40, 255), (200, 40, 40, 255), (200, 40, 40, 255), (146, 26, 26, 128)
                             , (40, 200, 40, 255), (26, 146, 26, 128), (0, 0, 0, 0), (0, 0, 0, 0)
                             , (40, 40, 200, 255), (0, 0, 0, 0), (0, 0, 0, 0), (0, 0, 0, 0)
                             , (200, 200, 40, 255), (0, 0, 0, 0), (0, 0, 0, 0), (0, 0, 0, 0)
                             ]
                           , [ (167, 32, 32, 170), (146, 26, 26, 128), (26, 146, 26, 128), (0, 0, 0, 0)
                             , (20, 20, 121, 85), (0, 0, 0, 0), (121, 121, 20, 85), (0, 0, 0, 0)
                             ]
                           , [(200, 40, 40, 255), (26, 146, 26, 128), (20, 20, 121, 85), (121, 121, 20, 85)]
                           , [(139, 96, 30, 159), (77, 77, 77, 64)]
                           , [(113, 87, 59, 112)]
                           ]
    it "scales a data level's alpha alone, saturating it at 255" $
      withGenerated mipRequest (saturation TexelRgba8Linear) $ \chain →
        map (map (\(_, _, _, a) → a) . texelsOf) (generatedLevels chain)
          `shouldBe` [ [255, 255, 255, 128, 255, 128, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0]
                     , [170, 128, 128, 0, 85, 0, 85, 0]
                     , [255, 128, 85, 85]
                     , [159, 64]
                     , [112]
                     ]
    it "covers texels of equal alpha together" $
      -- Level 1's alphas are 255, 128, 128 and 0: no scale covers one of the
      -- two equal texels without the other.
      withGenerated mipRequest equalGroups $ \chain → do
        coverageIsClosest equalGroups chain
        map (map (\(_, _, _, a) → a) . texelsOf) (generatedLevels chain) `shouldBe` [[255, 128, 128, 0], [191, 64], [128]]
    it "of two equally close counts, takes the one nearer the unscaled count" $
      -- Level 1's averages are 125, 100, 75 and 50, none covered; its share
      -- of level 0's 3 of 8 is 1.5. Covering 1 and covering 2 are equally
      -- close, and 1 is nearer the unscaled 0: the scale puts 125 on the
      -- threshold.
      withGenerated (MipRequest PreserveCoverage) ties $ \chain → do
        coverageIsClosest ties chain
        map (map (\(_, _, _, a) → a) . texelsOf) (generatedLevels chain) `shouldBe` [[128, 102, 77, 51], [128, 71], [88]]
    it "scales a level whose closest count is 0 so that its most opaque texel is 127" $
      -- Level 0 covers 1 of 4; the 1 × 1 level's average, 159, would cover
      -- its share of 0.25.
      withGenerated (MipRequest PreserveCoverage) (imageOf TexelRgba8Linear 4 1 [(10, 20, 30, a) | a ← [127, 127, 127, 255]]) $ \chain →
        map (map (\(_, _, _, a) → a) . texelsOf) (generatedLevels chain) `shouldBe` [[127, 191], [127]]
    it "leaves a fully transparent image transparent at every level" $
      withGenerated (MipRequest PreserveCoverage) (imageOf TexelRgba8Srgb 4 4 (replicate 16 (0, 0, 0, 0))) $ \chain →
        generatedLevels chain `shouldBe` [ByteString.replicate (2 * 2 * 4) 0, ByteString.replicate 4 0]
    it "leaves a fully opaque image opaque, with plain averages, at every level" $
      withGenerated (MipRequest PreserveCoverage) opaque $ \chain → do
        plain ← either (fail . show) pure (generated (MipRequest PlainAverages) opaque)
        decodedLevels chain `shouldBe` decodedLevels plain
        concatMap texelsOf (generatedLevels chain) `shouldSatisfy` all (\(_, _, _, a) → a == 255)

  describe "an image without the cutout mark" $
    it "gets plain averages, with no scaling" $
      -- Alphas 130, 130, 130 and 0: the 1 × 1 level's plain average is 98,
      -- below the threshold, although level 0 is three quarters covered.
      withGenerated mipRequest notCutout $ \chain →
        generatedLevels chain `shouldBeLevels` [[(60, 60, 60, 130), (60, 60, 60, 65)], [(60, 60, 60, 98)]]

  describe "the request" $ do
    it "preserves coverage of an unmarked image when it asks to" $
      withGenerated (MipRequest PreserveCoverage) notCutout $ \chain →
        generatedLevels chain `shouldBeLevels` [[(60, 60, 60, 130), (60, 60, 60, 65)], [(60, 60, 60, 128)]]
    it "takes plain averages of a marked image when it asks to" $
      withGenerated (MipRequest PlainAverages) (saturation TexelRgba8Srgb) $ \chain →
        drop 1 (generatedLevels chain)
          `shouldBeLevels` [ [ (200, 40, 40, 255), (176, 34, 34, 191), (34, 176, 34, 191), (0, 0, 0, 0)
                             , (26, 26, 146, 128), (0, 0, 0, 0), (146, 146, 26, 128), (0, 0, 0, 0)
                             ]
                           , [(188, 37, 37, 223), (22, 128, 22, 96), (16, 16, 106, 64), (106, 106, 16, 64)]
                           , [(139, 96, 30, 159), (77, 77, 77, 64)]
                           , [(113, 87, 59, 112)]
                           ]
    it "leaves coverage to the mark when it does not say" $ do
      generated mipRequest notCutout `shouldBe` generated (MipRequest PlainAverages) notCutout
      generated mipRequest (saturation TexelRgba8Srgb) `shouldBe` generated (MipRequest PreserveCoverage) (saturation TexelRgba8Srgb)

  describe "a decode without a mip request" $ do
    it "returns the decoder's single level unchanged" $
      forM_ [ColourImage, DataImage] $ \kind →
        decodeFixture kind "interlaced-rgba8.png" >>= \case
          Left refusal → expectationFailure ("refused: " <> show refusal)
          Right image → do
            length (decodedLevels image) `shouldBe` 1
            bytes ← fixtureBytes "interlaced-rgba8.png"
            case runDecoder (mipmapped mipRequest (pngDecoder kind)) (fixtureAsset "interlaced-rgba8.png") bytes of
              Left refusal → expectationFailure ("refused with mips: " <> show refusal)
              Right chain → do
                take 1 (decodedLevels chain) `shouldBe` decodedLevels image
                chain {decodedLevels = []} `shouldBe` image {decodedLevels = []}
    it "passes a decoder's refusal through a mipmapped decoder" $ do
      let asset = fixtureAsset "corrupt-stream.png"
      bytes ← fixtureBytes "corrupt-stream.png"
      runDecoder (mipmapped mipRequest (pngDecoder ColourImage)) asset bytes
        `shouldBe` runDecoder (pngDecoder ColourImage) asset bytes

  describe "refusals" $ do
    it "refuses an image whose level 0 does not match its extent" $
      generated mipRequest (blank 2 2) {decodedLevels = [ByteString.replicate 12 0]} `shouldSatisfy` either (const True) (const False)
    it "refuses an image with no level" $
      generated mipRequest (blank 2 2) {decodedLevels = []} `shouldSatisfy` either (const True) (const False)
    it "names the asset when a mipmapped decoder refuses an image" $ do
      let asset = fixtureAsset "rgba8.png"
          misshapen = Decoder (\_ _ → Right (blank 2 2) {decodedLevels = [ByteString.empty]})
      case runDecoder (mipmapped mipRequest misshapen) asset ByteString.empty of
        Left refusal → refusedAsset refusal `shouldBe` asset
        Right _ → expectationFailure "a misshapen image was accepted"

-- * Fixtures

imageOf ∷ TexelFormat → Int → Int → [Texel] → DecodedImage
imageOf format w h ts =
  DecodedImage
    { decodedFormat = format
    , decodedWidth = fromIntegral w
    , decodedHeight = fromIntegral h
    , decodedLevels = [ByteString.pack (concatMap (\(r, g, b, a) → [r, g, b, a]) ts)]
    , decodedBinaryAlpha = all (\(_, _, _, a) → a == 0 || a == 255) ts
    }

blank ∷ Int → Int → DecodedImage
blank w h = imageOf TexelRgba8Srgb w h (replicate (w * h) (0, 0, 0, 255))

dataFiveByThree ∷ DecodedImage
dataFiveByThree =
  imageOf TexelRgba8Linear 5 3 $
    [(10, 0, 0, 255), (20, 40, 0, 255), (30, 80, 0, 0), (40, 120, 0, 255), (250, 160, 0, 255)]
      <> [(0, 0, 10, 200), (0, 0, 20, 100), (0, 0, 30, 50), (0, 0, 40, 25), (0, 0, 250, 0)]
      <> [(5, 5, 5, 1), (15, 15, 15, 2), (25, 25, 25, 3), (35, 35, 35, 4), (245, 245, 245, 5)]

-- | Premultiplied as the decoder premultiplies them; the straight texels
-- were (250, 10, 10, 255), (10, 250, 10, 128), (10, 10, 250, 64), …
colourFiveByThree ∷ DecodedImage
colourFiveByThree =
  imageOf TexelRgba8Srgb 5 3 $
    [(250, 10, 10, 255), (5, 184, 5, 128), (3, 3, 134, 64), (114, 114, 114, 200), (13, 13, 13, 1)]
      <> [(0, 0, 0, 0), (50, 100, 200, 255), (53, 112, 15, 90), (5, 5, 5, 30), (188, 188, 0, 180)]
      <> [(0, 0, 0, 255), (196, 0, 196, 140), (0, 79, 79, 20), (165, 83, 0, 240), (38, 38, 137, 110)]

-- | 32 × 1, binary: four groups of eight with 7, 3, 2 and 2 opaque texels.
saturation ∷ TexelFormat → DecodedImage
saturation format =
  imageOf format 32 1 $
    concat
      [ replicate k (r, g, b, 255) <> replicate (8 - k) (0, 0, 0, 0)
      | ((r, g, b), k) ← zip [(200, 40, 40), (40, 200, 40), (40, 40, 200), (200, 200, 40)] [7, 3, 2, 2]
      ]

-- | Binary noise at an odd extent, opaque where a hash falls below @density@
-- in 20, with colour varying across the image.
noise ∷ Int → Int → Int → DecodedImage
noise w h density =
  imageOf TexelRgba8Srgb w h
    [ if (x * 7919 + y * 104729 + x * y * 31) `mod` 20 < density
        then (fromIntegral (x * 13 `mod` 256), fromIntegral (y * 19 `mod` 256), fromIntegral ((x + y) * 7 `mod` 256), 255)
        else (0, 0, 0, 0)
    | y ← [0 .. h - 1]
    , x ← [0 .. w - 1]
    ]

equalGroups ∷ DecodedImage
equalGroups = imageOf TexelRgba8Linear 8 1 [(100, 100, 100, a) | a ← [255, 255, 255, 0, 255, 0, 0, 0]]

ties ∷ DecodedImage
ties = imageOf TexelRgba8Linear 8 1 [(10, 20, 30, a) | a ← [250, 0, 200, 0, 150, 0, 100, 0]]

notCutout ∷ DecodedImage
notCutout = imageOf TexelRgba8Linear 4 1 [(60, 60, 60, a) | a ← [130, 130, 130, 0]]

opaque ∷ DecodedImage
opaque = imageOf TexelRgba8Srgb 4 4 [(fromIntegral (16 * i), fromIntegral (255 - 16 * i), 77, 255) | i ← [0 .. 15 ∷ Int]]

-- | Cutout-marked fixtures whose every level's achievable coverage is within
-- one texel's share of level 0's.
cutouts ∷ [DecodedImage]
cutouts = [saturation TexelRgba8Srgb, saturation TexelRgba8Linear, noise 17 9 9, noise 19 13 11]

-- * The independent reference

-- | Each output texel of a w × h level: its colour channels' averages — in
-- linear light for a premultiplied image, as stored for a straight one — and
-- its alpha average in code values, exactly. Output texel (x, y) averages
-- level 0's rectangle [x·W÷w, (x+1)·W÷w) × [y·H÷h, (y+1)·H÷h).
referenceAverages ∷ DecodedImage → Int → Int → [([Double], Rational)]
referenceAverages image w h =
  [ ( [sum [fromRational weight * channel c texel | (weight, texel) ← footprint x y] | c ← [0, 1, 2]]
    , sum [weight * fromIntegral (alphaOf texel) | (weight, texel) ← footprint x y]
    )
  | y ← [0 .. h - 1]
  , x ← [0 .. w - 1]
  ]
  where
    width = fromIntegral (decodedWidth image)
    height = fromIntegral (decodedHeight image)
    base = levelZero image
    footprint x y =
      [ (overlap ((x * width) ÷ w) (((x + 1) * width) ÷ w) sx * overlap ((y * height) ÷ h) (((y + 1) * height) ÷ h) sy / ((width ÷ w) * (height ÷ h)), base !! (sy * width + sx))
      | sy ← [0 .. height - 1]
      , sx ← [0 .. width - 1]
      ]
    a ÷ b = toInteger a % toInteger b
    overlap lo hi s = max 0 (min hi (fromIntegral s + 1) - max lo (fromIntegral s))
    channel c (r, g, b, _) =
      let v = [r, g, b] !! c
       in case decodedFormat image of
            TexelRgba8Srgb → toLinear (fromIntegral v / 255)
            TexelRgba8Linear → fromIntegral v
    alphaOf (_, _, _, a) = a

-- | Each generated level's covered count is as close to its share of level
-- 0's as any scale of its averaged alphas allows. The counts any scale
-- achieves are 0 and, for each distinct positive average, the number of
-- averages at least that large.
coverageIsClosest ∷ DecodedImage → DecodedImage → Expectation
coverageIsClosest image chain = do
  let total = length base
      covered0 = length (filter (\(_, _, _, a) → a >= 128) base)
      base = levelZero image
  forM_ (zip [1 ∷ Int ..] (drop 1 (levelsOf chain))) $ \(l, (w, h, level)) → do
    let alphas = map snd (referenceAverages image w h)
        n = w * h
        target = fromIntegral (covered0 * n) % fromIntegral total ∷ Rational
        achievable = 0 : [length (filter (>= v) alphas) | v ← nub (filter (> 0) alphas)]
        best = minimum [abs (fromIntegral k - target) | k ← achievable]
        covered = length (filter (\(_, _, _, a) → a >= 128) level)
    when (best > 1) $
      expectationFailure ("fixture defect: level " <> show l <> "'s achievable coverage is " <> show (fromRational best ∷ Double) <> " texels from its share")
    unless (abs (fromIntegral covered - target) == best) $
      expectationFailure
        ( "level " <> show l <> " covers " <> show covered <> " texels; its share of level 0's coverage is "
            <> show (fromRational target ∷ Double) <> " and the achievable counts are " <> show (nub achievable)
        )

-- | Each generated texel's un-premultiplied colour — linear colour ÷ alpha —
-- equals the plain average's, within what rounding the stored bytes allows:
-- half a code value of the encoded colour, at most 2.3 ÷ 510 in linear
-- light, and half a code value of alpha.
colourIsUnscaled ∷ DecodedImage → DecodedImage → Expectation
colourIsUnscaled image chain =
  forM_ (zip [1 ∷ Int ..] (drop 1 (levelsOf chain))) $ \(l, (w, h, level)) →
    forM_ (zip3 [0 ∷ Int ..] (referenceAverages image w h) level) $ \(k, (colour, alpha), (r, g, b, a)) →
      when (a > 0) $ do
        let stored = fromIntegral a / 255 ∷ Double
            averaged = fromRational alpha / 255
        forM_ (zip colour [r, g, b]) $ \(c, byte) → do
          let expected = c / averaged
              actual = toLinear (fromIntegral byte / 255) / stored
              tolerance = (2.3 / 510 + expected * 0.5 / 255) / stored + 1e-9
          unless (abs (actual - expected) <= tolerance) $
            expectationFailure
              ( "level " <> show l <> " texel " <> show k <> ": un-premultiplied colour " <> show actual
                  <> " differs from the plain average's " <> show expected
              )

toLinear ∷ Double → Double
toLinear v
  | v <= 0.04045 = v / 12.92
  | otherwise = ((v + 0.055) / 1.055) ** 2.4

-- * Helpers

generated ∷ MipRequest → DecodedImage → Either String DecodedImage
generated request = either (Left . show) Right . generateMips request

withGenerated ∷ MipRequest → DecodedImage → (DecodedImage → Expectation) → Expectation
withGenerated request image body = either (expectationFailure . ("refused: " <>)) body (generated request image)

-- | Each level's width, height and texels.
levelsOf ∷ DecodedImage → [(Int, Int, [Texel])]
levelsOf image =
  [ (max 1 (width `shiftR` l), max 1 (height `shiftR` l), texelsOf level)
  | (l, level) ← zip [0 ..] (decodedLevels image)
  ]
  where
    width = fromIntegral (decodedWidth image)
    height = fromIntegral (decodedHeight image)

levelZero ∷ DecodedImage → [Texel]
levelZero image = concatMap texelsOf (take 1 (decodedLevels image))

generatedLevels ∷ DecodedImage → [ByteString]
generatedLevels = drop 1 . decodedLevels

texelsOf ∷ ByteString → [Texel]
texelsOf = quads . ByteString.unpack
  where
    quads (r : g : b : a : rest) = (r, g, b, a) : quads rest
    quads _ = []

-- | Levels whose every byte is within one code value of the expected texels.
shouldBeLevels ∷ [ByteString] → [[Texel]] → Expectation
shouldBeLevels actual expected = do
  map (length . texelsOf) actual `shouldBe` map length expected
  forM_ (zip3 [1 ∷ Int ..] actual expected) $ \(l, level, texels) →
    forM_ (zip3 [0 ∷ Int ..] (texelsOf level) texels) $ \(k, stored, wanted) →
      unless (withinOne stored wanted) $
        expectationFailure ("level " <> show l <> " texel " <> show k <> " is " <> show stored <> ", not within one of " <> show wanted)
  where
    withinOne (r, g, b, a) (r', g', b', a') = all (\(x, y) → abs (fromIntegral x - fromIntegral y ∷ Int) <= 1) [(r, r'), (g, g'), (b, b'), (a, a')]
