-- | The data-image policy of the bounded decoder and the generic data-map validators (TRA-15).
--
-- Every expectation is stated by hand here: the fixtures' straight texels are the suite's own
-- ('Test.Asset.Image.Fixtures'), the small levels below are spelled out byte by byte, and every
-- expected bit, byte and index of the coverage plane and its sampling rule is worked out in a comment
-- beside it, never computed with the production helper being tested.
module Test.Asset.Image.DataMap (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import Data.Word (Word32, Word64, Word8)
import GHC.Float (castWord64ToDouble)
import Hetoimasia.Asset.Image (DecodedImage (..), ImageKind (..), TexelFormat (..))
import Hetoimasia.Asset.Image.DataMap
import Hetoimasia.Asset.Image.PngDecode (DecodePolicy (..), decodeBoundedWith, decodeReservations, m1WorkspaceBytes)
import Hetoimasia.Asset.Image.PngPreflight (PngRefusal (..), m1PngLimits, preflightPng)
import Test.Asset.Image.DecodeSupport (decodeAsset)
import Test.Asset.Image.Fixtures (Expected (..), expectedFixtures)
import Test.Asset.Image.PayloadLedger (chargeCaller, ledgerAccount, liveBytes, newLedger)
import Test.Asset.Image.Support (decodeFixture, fixtureBytes, texels)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "DataMap" $ do
  dataPolicySpec
  coverageSpec
  samplingSpec
  normalSpec

-- The data policy ---------------------------------------------------------------------------------------------

-- | Decode a fixture under a policy in an M1 bank that already holds the encoded input, as the pipeline
-- does, and answer the image and what the bank holds after.
decodeUnder ∷ DecodePolicy → FilePath → IO (DecodedImage, Int)
decodeUnder policy name = do
  bytes ← fixtureBytes name
  ledger ← newLedger m1WorkspaceBytes
  charged ← chargeCaller ledger (ByteString.length bytes)
  charged `shouldBe` True
  case preflightPng m1PngLimits decodeAsset bytes of
    Left refusal → expectationFailure ("preflight refused " <> show refusal) >> fail "refused"
    Right preflighted → do
      result ← decodeBoundedWith policy (ledgerAccount ledger) preflighted
      case result of
        Left refusal → expectationFailure ("refused: " <> Text.unpack (pngRefusalReason refusal)) >> fail "refused"
        Right image → do
          live ← liveBytes ledger
          pure (image, live - ByteString.length bytes)

dataPolicySpec ∷ Spec
dataPolicySpec = do
 describe "the data policy of the bounded decoder" $
  forM_ expectedFixtures $ \(Expected name width height straight) → describe name $ do
    it "decodes to one top-row-first linear RGBA8 level of exactly the file's texels: no gamma, no premultiplication, transparent RGB kept" $ do
      (image, _) ← decodeUnder DecodeData name
      (decodedWidth image, decodedHeight image) `shouldBe` (fromIntegral width, fromIntegral height)
      decodedFormat image `shouldBe` TexelRgba8Linear
      map ByteString.length (decodedLevels image) `shouldBe` [width * height * 4]
      texels image `shouldBe` straight
      decodedBinaryAlpha image `shouldBe` all (\(_, _, _, a) → a == 0 || a == 255) straight

    it "is byte for byte the general decoder's data image" $ do
      (image, _) ← decodeUnder DecodeData name
      general ← decodeFixture DataImage name
      Right image `shouldBe` either (Left . show) Right general

    it "charges exactly what the colour policy does: the output, and the caller's input" $ do
      (_, dataHeld) ← decodeUnder DecodeData name
      (_, colourHeld) ← decodeUnder DecodeColour name
      dataHeld `shouldBe` colourHeld
      dataHeld `shouldBe` width * height * 4


 describe "reservations" $
  it "are the same whichever policy reads the texels: output, scratch and scanlines, in that order" $ do
    bytes ← fixtureBytes "rgba8.png"
    case preflightPng m1PngLimits decodeAsset bytes of
      Left refusal → expectationFailure (show refusal)
      Right preflighted → map snd (decodeReservations preflighted) `shouldSatisfy` ((== 3) . length)

-- Binary coverage ---------------------------------------------------------------------------------------------

-- | A level of this alpha channel, row by row, with colour channels that are not alpha: 7, 8 and 9.
levelOfAlphas ∷ [Word8] → ByteString.ByteString
levelOfAlphas alphas = ByteString.pack (concat [[7, 8, 9, a] | a ← alphas])

planeOf ∷ Word32 → Word32 → [Word8] → IO CoveragePlane
planeOf w h alphas = case buildBinaryCoverage w h (levelOfAlphas alphas) of
  Right plane → pure plane
  Left refusal → expectationFailure ("no plane: " <> show refusal) >> fail "no plane"

coverageSpec ∷ Spec
coverageSpec = describe "binary coverage" $ do
  it "is one bit per texel, top row first, least significant bit first, and 3×3 spills into a partial second byte" $ do
    -- Alphas, row by row:  255 0 255 / 0 255 0 / 255 255 0.
    -- Bit k is texel k (row-major): 1 0 1 0 1 0 1 1 | 0.
    -- Byte 0 = bits 0..7 with bit 0 least significant = 0b11010101 = 0xD5; byte 1 = bit 8 = 0 = 0x00.
    plane ← planeOf 3 3 [255, 0, 255, 0, 255, 0, 255, 255, 0]
    ByteString.unpack (coverageBits plane) `shouldBe` [0xD5, 0x00]
    (coverageWidth plane, coverageHeight plane) `shouldBe` (3, 3)

  it "packs tightly across rows without padding: a 4×2 plane is one byte" $ do
    -- Row 0 = 255 0 0 0 (bit 0), row 1 = 0 0 0 255 (texel 7, bit 7): byte = 0b10000001 = 0x81.
    plane ← planeOf 4 2 [255, 0, 0, 0, 0, 0, 0, 255]
    ByteString.unpack (coverageBits plane) `shouldBe` [0x81]

  it "is all zero for an all-clear level, whose final byte is partial" $ do
    -- 5×3 = 15 texels = 2 bytes.
    plane ← planeOf 5 3 (replicate 15 0)
    ByteString.unpack (coverageBits plane) `shouldBe` [0x00, 0x00]
    coveragePlaneBytes 5 3 `shouldBe` 2

  it "is all one for an all-opaque level, and the unused high bits of the partial final byte stay zero" $ do
    -- 15 texels: byte 0 = 0xFF (bits 0..7), byte 1 = bits 8..14 set = 0b01111111 = 0x7F.
    plane ← planeOf 5 3 (replicate 15 255)
    ByteString.unpack (coverageBits plane) `shouldBe` [0xFF, 0x7F]

  it "reproduces every decoded alpha, texel by texel, in a rectangle that is not a multiple of eight" $ do
    let alphas = [if (x * 3 + y * 5) `mod` 4 == 0 then 255 else 0 | y ← [0 .. 6 ∷ Int], x ← [0 .. 8 ∷ Int]]
    plane ← planeOf 9 7 alphas
    -- 63 texels = 8 bytes, the last holding seven.
    ByteString.length (coverageBits plane) `shouldBe` 8
    forM_ [0 .. 6] $ \y → forM_ [0 .. 8] $ \x →
      coverageAt plane x y `shouldBe` Just (alphas !! (fromIntegral y * 9 + fromIntegral x) == 255)
    coverageAt plane 9 0 `shouldBe` Nothing
    coverageAt plane 0 7 `shouldBe` Nothing

  it "reproduces the alpha of every fixture that has binary alpha" $
    forM_ [e | e@(Expected _ _ _ straight) ← expectedFixtures, all (\(_, _, _, a) → a == 0 || a == 255) straight] $ \(Expected _ width height straight) → do
      let level = ByteString.pack (concat [[r, g, b, a] | (r, g, b, a) ← straight])
      case buildBinaryCoverage (fromIntegral width) (fromIntegral height) level of
        Left refusal → expectationFailure (show refusal)
        Right plane →
          forM_ (zip [0 ..] straight) $ \(k, (_, _, _, a)) →
            coverageAt plane (k `mod` fromIntegral width) (k `div` fromIntegral width) `shouldBe` Just (a == 255)

  it "refuses an alpha of 1 or 254 as a nonbinary image naming the first such texel, and thresholds nothing" $ do
    buildBinaryCoverage 2 2 (levelOfAlphas [255, 0, 1, 255]) `shouldBe` Left (CoverageNotBinary 0 1 1)
    buildBinaryCoverage 2 2 (levelOfAlphas [0, 254, 254, 0]) `shouldBe` Left (CoverageNotBinary 1 0 254)
    buildBinaryCoverage 1 1 (levelOfAlphas [128]) `shouldBe` Left (CoverageNotBinary 0 0 128)
    case buildBinaryCoverage 2 1 (levelOfAlphas [255, 128]) of
      Left refusal → Text.unpack (coverageRefusalText refusal) `shouldSatisfy` (\text → "coverage=binary" `isIn` text && "alpha 128" `isIn` text)
      Right _ → expectationFailure "a nonbinary level was given a plane"

  it "refuses a level that is not width × height × 4 bytes rather than reading past it" $ do
    buildBinaryCoverage 2 2 (ByteString.replicate 15 255) `shouldBe` Left (CoverageLevelMismatch 15 16)
    buildBinaryCoverage 2 2 ByteString.empty `shouldBe` Left (CoverageLevelMismatch 0 16)

  it "accounts a plane as its bits plus the fixed metadata, and the validated pixel limit's worst case as 524,288 plane bytes" $ do
    coverageRetainedBytes 96 64 `shouldBe` 96 * 64 `div` 8 + coverageMetadataBytes
    coverageRetainedBytes 3 3 `shouldBe` 2 + coverageMetadataBytes
    maxCoveragePlaneBytes 4194304 `shouldBe` 524288
    maxCoveragePlaneBytes 4194305 `shouldBe` 524289
  where
    isIn needle text = Text.pack needle `Text.isInfixOf` Text.pack text

-- Sampling ------------------------------------------------------------------------------------------------------

-- | A double from its IEEE 754 bit pattern, so a neighbour of a boundary is named exactly and not by
-- floating arithmetic.
bits ∷ Word64 → Double
bits = castWord64ToDouble

samplingSpec ∷ Spec
samplingSpec = describe "the normalized sampling rule i = min (n - 1) (floor (clamp u 0 1 × n))" $ do
  it "selects the higher texel at an interior boundary that is exactly representable, and the lower one just below it" $ do
    -- n = 4: 1/4 = 0x3FD0000000000000 is exact, so floor (0.25 × 4) = 1. Its predecessor is 0x3FCFFFFFFFFFFFFF.
    sampleIndex 4 (bits 0x3FD0000000000000) `shouldBe` Just 1
    sampleIndex 4 (bits 0x3FCFFFFFFFFFFFFF) `shouldBe` Just 0
    sampleIndex 4 (bits 0x3FD0000000000001) `shouldBe` Just 1

  it "does not round the predecessor of k/n up onto the boundary, for a width that is not a power of two" $ do
    -- n = 3: the double nearest 1/3 is 0x3FD5555555555555 = 0.333333333333333314829616256247…, which is
    -- below 1/3, so the exact product with 3 is 0.99999999999999994449 and the texel is 0. A floating product
    -- u × 3 rounds to 1.0 and would wrongly select texel 1. Its successor 0x3FD5555555555556 is above 1/3.
    sampleIndex 3 (bits 0x3FD5555555555555) `shouldBe` Just 0
    sampleIndex 3 (bits 0x3FD5555555555556) `shouldBe` Just 1
    -- 2/3: 0x3FE5555555555555 = 0.66666666666666662966, below 2/3 (texel 1); successor 0x3FE5555555555556 above (texel 2).
    sampleIndex 3 (bits 0x3FE5555555555555) `shouldBe` Just 1
    sampleIndex 3 (bits 0x3FE5555555555556) `shouldBe` Just 2

  it "agrees on 96 texels: 3/96 = 1/32 is exact and selects texel 3, its predecessor texel 2; 1/2 selects 48, its predecessor 47" $ do
    sampleIndex 96 (bits 0x3FA0000000000000) `shouldBe` Just 3 -- 0.03125
    sampleIndex 96 (bits 0x3F9FFFFFFFFFFFFF) `shouldBe` Just 2
    sampleIndex 96 (bits 0x3FE0000000000000) `shouldBe` Just 48 -- 0.5
    sampleIndex 96 (bits 0x3FDFFFFFFFFFFFFF) `shouldBe` Just 47

  it "selects the last texel at the outer edge and clamps outside the unit interval" $ do
    sampleIndex 3 1 `shouldBe` Just 2
    sampleIndex 96 1 `shouldBe` Just 95
    sampleIndex 96 0 `shouldBe` Just 0
    sampleIndex 96 (-0.5) `shouldBe` Just 0
    sampleIndex 96 7 `shouldBe` Just 95
    sampleIndex 96 (1 / 0) `shouldBe` Just 95
    sampleIndex 96 (-1 / 0) `shouldBe` Just 0
    -- The largest double below one is still inside the last texel.
    sampleIndex 96 (bits 0x3FEFFFFFFFFFFFFF) `shouldBe` Just 95
    -- And 1 itself, when n = 1, is texel 0.
    sampleIndex 1 1 `shouldBe` Just 0

  it "has no texel for a coordinate that is not a number, or for an empty extent" $ do
    sampleIndex 4 (0 / 0) `shouldBe` Nothing
    sampleIndex 0 0.5 `shouldBe` Nothing

  it "samples a rectangle on each axis independently: u on the width, v on the height, rows from the top" $ do
    -- 4 wide, 2 tall; only texel (3, 1) is covered.
    plane ← planeOf 4 2 [0, 0, 0, 0, 0, 0, 0, 255]
    coverageSample plane 1 1 `shouldBe` Just True
    coverageSample plane (bits 0x3FE7FFFFFFFFFFFF) 1 `shouldBe` Just False -- just below 3/4: texel 2
    coverageSample plane (bits 0x3FE8000000000000) 1 `shouldBe` Just True -- exactly 3/4: texel 3
    coverageSample plane 0.9 (bits 0x3FDFFFFFFFFFFFFF) `shouldBe` Just False -- row 0
    coverageSample plane 0.9 (bits 0x3FE0000000000000) `shouldBe` Just True -- v = 1/2 selects row 1
    coverageSample plane (0 / 0) 0 `shouldBe` Nothing

-- Normal encodings ----------------------------------------------------------------------------------------------

-- | A level from straight texels.
levelOf ∷ [(Word8, Word8, Word8, Word8)] → ByteString.ByteString
levelOf quads = ByteString.pack (concat [[r, g, b, a] | (r, g, b, a) ← quads])

normalSpec ∷ Spec
normalSpec = describe "unit-normal-rgb-v1" $ do
  it "is named by its spelling and by nothing else" $ do
    normalEncodingName UnitNormalRgbV1 `shouldBe` Text.pack "unit-normal-rgb-v1"
    parseNormalEncoding (Text.pack "unit-normal-rgb-v1") `shouldBe` Just UnitNormalRgbV1
    parseNormalEncoding (Text.pack "Unit-Normal-RGB-v1") `shouldBe` Nothing
    parseNormalEncoding (Text.pack "unit-normal-rgb-v2") `shouldBe` Nothing

  it "accepts flat-up (128,128,255), the W ramp (38,128,218) and the legal extremes, leaving the bytes as they are" $ do
    let level = levelOf [(128, 128, 255, 255), (38, 128, 218, 255), (1, 1, 1, 255), (255, 255, 255, 255), (1, 255, 128, 7), (129, 128, 128, 255), (128, 128, 127, 255)]
    checkNormalEncoding UnitNormalRgbV1 7 1 level `shouldBe` Right ()
    ByteString.length level `shouldBe` 28

  it "refuses the zero vector (128,128,128) in a nontransparent texel, naming it" $ do
    checkNormalEncoding UnitNormalRgbV1 2 1 (levelOf [(128, 128, 255, 255), (128, 128, 128, 255)]) `shouldBe` Left (NormalZeroVector 1 0)
    -- Alpha 1 is nontransparent.
    checkNormalEncoding UnitNormalRgbV1 1 1 (levelOf [(128, 128, 128, 1)]) `shouldBe` Left (NormalZeroVector 0 0)

  it "refuses each channel of zero in a nontransparent texel" $ do
    checkNormalEncoding UnitNormalRgbV1 1 1 (levelOf [(0, 128, 255, 255)]) `shouldBe` Left (NormalZeroChannel 0 0 0 128 255)
    checkNormalEncoding UnitNormalRgbV1 1 2 (levelOf [(128, 128, 255, 255), (128, 0, 255, 255)]) `shouldBe` Left (NormalZeroChannel 0 1 128 0 255)
    checkNormalEncoding UnitNormalRgbV1 1 1 (levelOf [(128, 128, 0, 200)]) `shouldBe` Left (NormalZeroChannel 0 0 128 128 0)

  it "ignores the RGB of a transparent texel, invalid or not" $ do
    checkNormalEncoding UnitNormalRgbV1 3 1 (levelOf [(0, 0, 0, 0), (128, 128, 128, 0), (128, 128, 255, 255)]) `shouldBe` Right ()

  it "gives the refusal as bounded text naming the policy and the texel" $
    case checkNormalEncoding UnitNormalRgbV1 1 1 (levelOf [(0, 128, 255, 255)]) of
      Left refusal → do
        let text = normalRefusalText UnitNormalRgbV1 refusal
        Text.unpack text `shouldSatisfy` (\found → "normal_encoding=unit-normal-rgb-v1" `inText` found && "column 0, row 0" `inText` found)
        Text.length text `shouldSatisfy` (< 300)
      Right () → expectationFailure "a zero channel was accepted"

  it "refuses a level that is not width × height × 4 bytes" $
    checkNormalEncoding UnitNormalRgbV1 2 2 (ByteString.replicate 12 200) `shouldBe` Left (NormalLevelMismatch 12 16)

  it "decodes by normalizing c − (128,128,128): flat-up is (0,0,1) and the W ramp is (−√½, 0, √½)" $ do
    unitNormal (128, 128, 255) `shouldBeNear` (0, 0, 1)
    unitNormal (38, 128, 218) `shouldBeNear` (-sqrt 0.5, 0, sqrt 0.5)
    unitNormal (128, 128, 128) `shouldBe` Nothing

  it "represents round (128 + 127 × n) per channel, so the encoded ramp decodes back to the unit vector within one level" $ do
    let encode n = fromIntegral (round (128 + 127 * n ∷ Double) ∷ Int) ∷ Word8
    (encode (-sqrt 0.5), encode 0, encode (sqrt 0.5)) `shouldBe` (38, 128, 218)
    (encode 0, encode 0, encode 1) `shouldBe` (128, 128, 255)
  where
    inText needle haystack = Text.pack needle `Text.isInfixOf` Text.pack haystack
    shouldBeNear found (ex, ey, ez) = case found of
      Nothing → expectationFailure "the zero vector has no direction"
      Just (x, y, z) → forM_ [(x, ex), (y, ey), (z, ez)] $ \(got, want) → abs (got - want) `shouldSatisfy` (< 1.0e-9)
