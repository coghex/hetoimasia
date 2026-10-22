-- | The bounded PNG decoder's pixels and refusals, through the complete entry
-- (preflight, then decode in a bank).
--
-- Every fixture whose texels the suite states by hand is decoded here through
-- the bounded path and compared with those texels, and with the general
-- decoder's colour image byte for byte. The pixel-level examples at scale
-- build their images in this module with an encoder written for the example,
-- independent of the decoder, of JuicyPixels and of the fixture script.
module Test.Asset.Image.PngDecode (spec) where

import qualified Codec.Compression.Zlib as Zlib
import Control.Monad (forM_)
import Data.Bits (shiftR, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.ByteString.Unsafe as ByteString
import Data.Word (Word8)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (castPtr, plusPtr)
import Hetoimasia.Asset.Image (DecodedImage (..), ImageKind (..), TexelFormat (..))
import Hetoimasia.Asset.Image.Png (decodePng)
import Hetoimasia.Asset.Image.PngDecode
import Hetoimasia.Asset.Image.PngPreflight
import Test.Asset.Image.DecodeSupport
import Test.Asset.Image.Fixtures (Expected (..), expectedFixtures, shouldMatchPremultiplied)
import Test.Asset.Image.PayloadLedger
import Test.Asset.Image.PngBuilder
import Test.Asset.Image.Support (decodeFixture, fixtureAsset, fixtureBytes, referencePremultiplied, shouldBeWithinOne, texels)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "PngDecode" $ do
  fixturesSpec
  markSpec
  evaluationSpec
  colourSpec
  refusalSpec
  secondPassSpec
  scaleSpec

-- | Every fixture with hand-stated texels.
fixturesSpec ∷ Spec
fixturesSpec = describe "every fixture through the bounded path" $
  forM_ expectedFixtures $ \(Expected name width height straight) → describe name $ do
    it "decodes to one top-row-first sRGB RGBA8 level of its texels, premultiplied once" $ do
      outcome ← decodeFixtureBounded name
      image ← acceptedImage outcome
      (decodedWidth image, decodedHeight image) `shouldBe` (fromIntegral width, fromIntegral height)
      decodedFormat image `shouldBe` TexelRgba8Srgb
      map ByteString.length (decodedLevels image) `shouldBe` [width * height * 4]
      straight `shouldMatchPremultiplied` image
      decodedBinaryAlpha image `shouldBe` all (\(_, _, _, a) → a == 0 || a == 255) straight

    it "is byte for byte the general decoder's colour image" $ do
      outcome ← decodeFixtureBounded name
      image ← acceptedImage outcome
      general ← decodeFixture ColourImage name
      Right image `shouldBe` either (Left . show) Right general

    it "leaves exactly its output charged, and the caller's input" $ do
      outcome ← decodeFixtureBounded name
      _ ← acceptedImage outcome
      live ← liveBytes (outcomeLedger outcome)
      live `shouldBe` outcomeSourceBytes outcome + width * height * 4

-- | The cutout mark: true exactly when every alpha is 0 or 255.
markSpec ∷ Spec
markSpec = describe "the cutout mark" $
  forM_
    [ ("alpha-binary.png", True)
    , ("rgb8.png", True)
    , ("alpha-one.png", False)
    , ("alpha-254.png", False)
    , ("grey-alpha16.png", False)
    , ("grey16-trns.png", True)
    , ("rgb16-trns.png", True)
    , ("palette-trns.png", False)
    ]
    $ \(name, expected) →
      it (name <> " is " <> (if expected then "binary" else "not binary")) $ do
        outcome ← decodeFixtureBounded name
        image ← acceptedImage outcome
        decodedBinaryAlpha image `shouldBe` expected

-- | Nothing is left to be evaluated by a consumer.
evaluationSpec ∷ Spec
evaluationSpec = describe "the returned value" $
  forM_ ["rgba8.png", "palette-trns.png", "adam7-rgba16.png"] $ \name →
    it (name <> " is constructors all the way down, so no failure can come from reading it later") $ do
      outcome ← decodeFixtureBounded name
      image ← acceptedImage outcome
      evaluated ← fullyEvaluated image
      evaluated `shouldBe` True

-- | Premultiplication happens once, in linear light, and the endpoints are
-- exact.
colourSpec ∷ Spec
colourSpec = describe "the colour contract" $ do
  it "leaves opaque channels unchanged and makes alpha-zero texels zero" $ do
    -- rgba8.png: (255,0,0,255) (0,255,0,128) (0,0,255,0) / (200,100,50,64) (255,255,255,255) (1,2,3,4)
    outcome ← decodeFixtureBounded "rgba8.png"
    image ← acceptedImage outcome
    let found = texels image
    found !! 0 `shouldBe` (255, 0, 0, 255)
    found !! 2 `shouldBe` (0, 0, 0, 0)
    found !! 4 `shouldBe` (255, 255, 255, 255)

  it "premultiplies a semi-transparent texel once, in linear light, not the encoded values" $ do
    outcome ← decodeFixtureBounded "rgba8.png"
    image ← acceptedImage outcome
    let (_, g, _, a) = texels image !! 1
    a `shouldBe` 128
    g `shouldBeWithinOne` referencePremultiplied 128 255
    -- Multiplying the encoded value would give 128, and a second
    -- premultiplication a smaller one: both are far from the reference.
    g `shouldSatisfy` (\v → v > 180 && v < 190)

-- | Refusals through the complete entry: the class, the asset, and an account
-- left as it was.
refusalSpec ∷ Spec
refusalSpec = describe "refusals" $ do
  let refuses name expected = it (name <> " is refused as " <> show expected <> ", with nothing left charged") $ do
        outcome ← decodeFixtureBounded name
        outcome `refusedAs` expected
        live ← liveBytes (outcomeLedger outcome)
        live `shouldBe` outcomeSourceBytes outcome
  refuses "corrupt-stream.png" MalformedPng
  refuses "short-stream.png" MalformedPng
  refuses "rgb-depth4.png" MalformedPng
  refuses "zero-width.png" MalformedPng

  describe "found while decoding" $ do
    forM_ [("palette-index-out-of-range.png", "a palette index"), ("no-palette.png", "has no palette"), ("palette-length-4.png", "whole number"), ("invalid-filter.png", "filter type 5")] $ \(name, reason) →
      it (name <> " is refused as malformed, every charge released in reverse") $ do
        outcome ← decodeFixtureBounded name
        outcome `refusedAs` MalformedPng
        either (\refusal → show (pngRefusalReason refusal) `shouldSatisfy` contains reason) (const (pure ())) (outcomeResult outcome)
        live ← liveBytes (outcomeLedger outcome)
        live `shouldBe` outcomeSourceBytes outcome
        Just preflighted ← pure (outcomePreflight outcome)
        seen ← events (outcomeLedger outcome)
        let (o, sc, w) = (chargeFor StageOutput preflighted, chargeFor StageScratch preflighted, chargeFor StageWorking preflighted)
        -- A refusal that needs no buffer (no palette) is found before any is
        -- reserved; the others reserve all three and release them in reverse.
        case seen of
          [_] → pure ()
          _ → seen `shouldBe` [CallerCharged (outcomeSourceBytes outcome), Granted StageOutput o, Granted StageScratch sc, Granted StageWorking w, Released StageWorking w, Released StageScratch sc, Released StageOutput o]

  it "refuses an invalid filter in the bounded path though the general decoder accepts the file" $ do
    bytes ← fixtureBytes "invalid-filter.png"
    case decodePng ColourImage (fixtureAsset "invalid-filter.png") bytes of
      Right _ → pure ()
      Left refusal → expectationFailure ("the general decoder changed: " <> show refusal)

  it "refuses every truncation of a PNG, through the complete entry, without a partial image" $ do
    whole ← fixtureBytes "interlaced-rgba8.png"
    forM_ [1 .. ByteString.length whole - 1] $ \n → do
      outcome ← decodeFresh (ByteString.take n whole)
      case outcomeResult outcome of
        Left refusal → pngRefusalClass refusal `shouldSatisfy` (`elem` [UnsupportedFormat, MalformedPng])
        Right _ → expectationFailure ("a truncation to " <> show n <> " bytes decoded")
      live ← liveBytes (outcomeLedger outcome)
      live `shouldBe` n

  it "applies the preflight's refusals to every limit through the complete entry" $ do
    png ← fixtureBytes "rgba8.png"
    let under change = do
          ledger ← m1Bank
          decodeIn ledger id (limitsOf change) png
        limitsOf change = either (error "limits") id (pngLimits (change (pngLimitSettings m1PngLimits)))
    under (\s → s {settingWidth = 2}) >>= (`refusedAs` ExceededLimit LimitWidth)
    under (\s → s {settingHeight = 1}) >>= (`refusedAs` ExceededLimit LimitHeight)
    under (\s → s {settingPixels = 5}) >>= (`refusedAs` ExceededLimit LimitPixels)
    under (\s → s {settingRgba8Bytes = 23}) >>= (`refusedAs` ExceededLimit LimitRgba8Bytes)
    under (\s → s {settingInflatedBytes = 12}) >>= (`refusedAs` ExceededLimit LimitInflatedBytes)
    under (\s → s {settingChunks = 2}) >>= (`refusedAs` ExceededLimit LimitChunks)
    under (\s → s {settingSourceBytes = 50}) >>= (`refusedAs` ExceededLimit LimitSourceBytes)
    -- The same limits one past: accepted and decoded.
    outcome ← under (\s → s {settingWidth = 3, settingHeight = 2, settingPixels = 6, settingRgba8Bytes = 24, settingInflatedBytes = 26, settingChunks = 3})
    _ ← acceptedImage outcome
    pure ()

  it "does not decompress ignored metadata: compressed chunks that are not zlib streams change nothing" $ do
    outcome ← decodeFixtureBounded "rgb8-garbage-text.png"
    _ ← acceptedImage outcome
    pure ()

  it "does not expand a compressed metadata chunk that is a decompression bomb" $ do
    -- 256 MiB of zeros in an iCCP chunk of about a quarter of a megabyte.
    let bomb = Lazy.toStrict (Zlib.compressWith Zlib.defaultCompressParams {Zlib.compressLevel = Zlib.bestCompression} (zeros (256 * 1024 * 1024)))
        png = assemble [ihdrChunk (header 2 2 8 2), chunk "iCCP" ("bomb\0\0" <> bomb), chunk "IDAT" (zlibOf (zeros 14)), chunk "IEND" ""]
    ByteString.length bomb `shouldSatisfy` (< 1024 * 1024)
    preflighted ← either (\refusal → expectationFailure (show refusal) >> fail "refused") pure (preflightPng m1PngLimits decodeAsset png)
    ledger ← m1Bank
    (result, allocated) ← allocatedDuring (decodeBounded (ledgerAccount ledger) preflighted)
    either (\refusal → expectationFailure (show refusal)) (const (pure ())) result
    -- Expanding the chunk would allocate its 256 MiB of output.
    allocated `shouldSatisfy` (< 4 * 1024 * 1024)
  where
    contains needle haystack = needle `isInfixOfString` haystack
    isInfixOfString needle haystack = any (needle `isPrefixOfString`) (tailsOf haystack)
    isPrefixOfString [] _ = True
    isPrefixOfString _ [] = False
    isPrefixOfString (a : as) (b : bs) = a == b && isPrefixOfString as bs
    tailsOf [] = [[]]
    tailsOf s@(_ : rest) = s : tailsOf rest

-- | The second pass reinflates the same bytes under the same budget. The
-- bytes are changed after the preflight, which no caller may do, to show the
-- decoder does not rely on the first pass for its safety: each change to the
-- stream is met at the second pass's own bound or check.
secondPassSpec ∷ Spec
secondPassSpec = describe "a second pass that meets different bytes" $ do
  let image = header 1 1 8 0
      limit = 64 * 1024 ∷ Int
      small = zlibOf (zeros (60 * 1024))
      big = zlibOf (zeros (600 * 1024))
      padded stream = stream <> ByteString.replicate (ByteString.length big - ByteString.length stream) 0
      pngOf stream = assemble [ihdrChunk image, chunk "IDAT" stream, chunk "IEND" ""]
      dataOffset = 8 + 25 + 8
      limits = either (error "limits") id (pngLimits ((pngLimitSettings m1PngLimits) {settingInflatedBytes = toInteger limit}))

      -- Preflight the first stream, overwrite it in the preflight's own buffer
      -- with the second, then decode.
      tampered first second = do
        ledger ← m1Bank
        let bytes = ByteString.copy (pngOf (padded first))
        _ ← chargeCaller ledger (ByteString.length bytes)
        preflighted ← case preflightPng limits decodeAsset bytes of
          Right accepted → pure accepted
          Left refusal → expectationFailure ("the untampered image was refused: " <> show refusal) >> fail "refused"
        ByteString.unsafeUseAsCStringLen bytes $ \(destination, _) →
          ByteString.unsafeUseAsCStringLen (padded second) $ \(source, size) →
            copyBytes (castPtr destination `plusPtr` dataOffset) (castPtr source) size
        result ← decodeBounded (ledgerAccount ledger) preflighted
        live ← liveBytes ledger
        pure (Outcome result (Just preflighted) ledger (ByteString.length bytes), live)

  it "bounds a stream that now inflates past the limit, wherever the limit falls" $ do
    (outcome, live) ← tampered small big
    outcome `refusedAs` ExceededLimit LimitInflatedBytes
    live `shouldBe` outcomeSourceBytes outcome

  it "refuses a stream that is now corrupt" $ do
    (outcome, live) ← tampered small (ByteString.take 2 small <> ByteString.pack [0xFF] <> ByteString.drop 3 small)
    outcome `refusedAs` MalformedPng
    live `shouldBe` outcomeSourceBytes outcome

  it "refuses a stream that now inflates to fewer bytes than the header needs" $ do
    (outcome, live) ← tampered small (zlibOf (zeros 1))
    outcome `refusedAs` MalformedPng
    live `shouldBe` outcomeSourceBytes outcome

  it "refuses a stream that is now truncated" $ do
    -- A stored block that declares 65,535 bytes and is followed by fewer.
    (outcome, live) ← tampered small (ByteString.pack [0x78, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x00])
    outcome `refusedAs` MalformedPng
    live `shouldBe` outcomeSourceBytes outcome

-- | Images large enough that their cost is real: a pixel-exact decode of a
-- noise image under Adam7 at 16 bits, and the approved maxima.
scaleSpec ∷ Spec
scaleSpec = describe "at scale" $ do
  it "decodes a 16-bit RGBA Adam7 noise image of odd extent to its exact texels, allocating no more than it charged" $ do
    let (w, h) = (701, 499)
        stream = zlibOf (Lazy.fromStrict (adam7Raw16 w h (\x y → let (r, g, b, a) = noisePixel x y in [r, g, b, a])))
        png = assemble ([ihdrChunk (Header (fromIntegral w) (fromIntegral h) 16 6 0 0 1)] <> idatChunks 65536 stream <> [chunk "IEND" ""])
    -- The compressed noise is about as large as the samples: a decoder that
    -- concatenated the IDAT chunks would allocate another copy of it.
    ByteString.length png `shouldSatisfy` (> w * h * 8 `div` 2)
    preflighted ← either (\refusal → expectationFailure (show refusal) >> fail "refused") pure (preflightPng m1PngLimits decodeAsset png)
    ledger ← m1Bank
    _ ← chargeCaller ledger (ByteString.length png)
    (result, allocated) ← allocatedDuring (decodeBounded (ledgerAccount ledger) preflighted)
    image ← either (\refusal → expectationFailure (show refusal) >> fail "refused") pure result
    (decodedWidth image, decodedHeight image) `shouldBe` (fromIntegral w, fromIntegral h)
    let straight = [(narrow16 r, narrow16 g, narrow16 b, narrow16 a) | y ← [0 .. h - 1], x ← [0 .. w - 1], let (r, g, b, a) = noisePixel x y]
    straight `shouldMatchPremultiplied` image
    peak ← peakBytes ledger
    toInteger peak `shouldBe` decodePeakBytes preflighted
    -- The allocator's total is the buffers charged and the inflater's output
    -- pieces (as many bytes as it inflated), nothing else of size.
    let charged = sum (map snd (decodeReservations preflighted))
        inflated = toInteger (preflightInflatedBytes preflighted)
    toInteger allocated `shouldSatisfy` (< charged + inflated + 1024 * 1024)

-- | nearest(v × 255 ÷ 65535) as an exact rational rounding.
narrow16 ∷ Int → Word8
narrow16 v = fromInteger (round (toRational v * 255 / 65535))

-- | A 16-bit RGBA pixel of pseudo-random samples, with alpha 0 and 65535
-- among them.
noisePixel ∷ Int → Int → (Int, Int, Int, Int)
noisePixel x y = (mix 0, mix 1, mix 2, alpha)
  where
    mix c = (((x * 40503 + y * 9973 + c * 7919 + (x * y) `mod` 977) * 2654435761) `shiftR` 7) .&. 0xFFFF
    alpha = case (x * 3 + y) `mod` 13 of
      0 → 0
      1 → 65535
      _ → mix 3

-- | The filtered scanlines of a 16-bit Adam7 image, every row with filter
-- type 0, written pass by pass as the specification lays them out: the
-- encoder the example brings, independent of the decoder.
adam7Raw16 ∷ Int → Int → (Int → Int → [Int]) → ByteString
adam7Raw16 w h pixel = mconcat [pass column0 columnStep row0 rowStep | (column0, columnStep, row0, rowStep) ← passes]
  where
    passes = [(0, 8, 0, 8), (4, 8, 0, 8), (0, 4, 4, 8), (2, 4, 0, 4), (0, 2, 2, 4), (1, 2, 0, 2), (0, 1, 1, 2)]
    pass column0 columnStep row0 rowStep =
      let columns = [column0, column0 + columnStep .. w - 1]
       in if null columns
            then mempty
            else mconcat [ByteString.pack (0 : concat [concatMap sixteen (pixel x y) | x ← columns]) | y ← [row0, row0 + rowStep .. h - 1]]
    sixteen v = [fromIntegral (v `shiftR` 8), fromIntegral (v .&. 255)]
