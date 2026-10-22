-- | The bounded PNG preflight's structure and limit contracts: the limits'
-- validation, recognition and its refusal classes, framing and CRC, the
-- header, the profile fixtures, every limit with its one-past case, and the
-- order the checks run in. Inflation, ownership and faults are in
-- "Test.Asset.Image.PngPreflightInflation".
--
-- Every defective input is built by "Test.Asset.Image.PngBuilder" or flipped
-- in a committed fixture here, independently of the production parser, and
-- every expected scanline count is counted pixel by pixel.
module Test.Asset.Image.PngPreflight (spec) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Word (Word8)
import Hetoimasia.Asset (Asset (..), AssetId (..))
import Hetoimasia.Asset.Image (ImageKind (..))
import Hetoimasia.Asset.Image.Png (decodePng)
import Hetoimasia.Asset.Image.PngPreflight
import Test.Asset.Image.PngBuilder
import Test.Asset.Image.PreflightSupport
import Test.Asset.Image.Support (fixtureBytes)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "PngPreflight" $ do
  limitsSpec
  profileSpec
  recognitionSpec
  framingSpec
  headerSpec
  limitEdgesSpec
  precedenceSpec
  scanlineSpec

limitsSpec ∷ Spec
limitsSpec = describe "limits" $ do
  it "holds the approved M1 values" $
    m1Settings
      `shouldBe` PngLimitSettings
        { settingSourceBytes = 32 * 1024 * 1024
        , settingChunks = 4096
        , settingWidth = 2048
        , settingHeight = 2048
        , settingPixels = 4194304
        , settingRgba8Bytes = 16 * 1024 * 1024
        , settingInflatedBytes = 40 * 1024 * 1024
        }

  it "constructs from the M1 values, and gives the same limits as m1PngLimits" $
    pngLimits m1Settings `shouldBe` Right m1PngLimits

  it "accepts 1 and the largest limit in every position" $
    forM_ [1, largestLimit] $ \value →
      pngLimits (PngLimitSettings value value value value value value value) `shouldSatisfy` either (const False) (const True)

  it "states the largest limit as 2^31 - 1" $
    largestLimit `shouldBe` 2147483647

  forM_ (zip [minBound .. maxBound] fields) $ \(kind, (name, set)) →
    forM_ [(0 ∷ Integer), -1, -4096, largestLimit + 1, 2 ^ (62 ∷ Int), 2 ^ (63 ∷ Int), 2 ^ (64 ∷ Int), 2 ^ (200 ∷ Int)] $ \value →
      it ("refuses " <> show value <> " as the " <> name <> " limit, naming it and no other") $
        case pngLimits (set value m1Settings) of
          Left refusal → do
            refusedLimit refusal `shouldBe` kind
            limitsRefusalReason refusal `shouldSatisfy` (\reason → length (show reason) < 200)
          Right _ → fail "the limits were accepted"

  it "reads no value as unlimited: zero, negatives and the machine's largest Int are all refused" $
    forM_ [0, -1, toInteger (maxBound ∷ Int), toInteger (minBound ∷ Int)] $ \value →
      pngLimits (PngLimitSettings value value value value value value value) `shouldSatisfy` either (const True) (const False)
  where
    fields =
      [ ("source byte", \v s → s {settingSourceBytes = v})
      , ("chunk count", \v s → s {settingChunks = v})
      , ("width", \v s → s {settingWidth = v})
      , ("height", \v s → s {settingHeight = v})
      , ("pixel count", \v s → s {settingPixels = v})
      , ("RGBA8 byte", \v s → s {settingRgba8Bytes = v})
      , ("inflated byte", \v s → s {settingInflatedBytes = v})
      ]

-- | The committed fixtures the profile accepts, with their header fields.
-- Fixtures the general decoder refuses for palette or texel reasons are in:
-- the preflight leaves palette indices to decoding.
profileFixtures ∷ [(FilePath, Int, Int, PngColourType, Int, PngInterlace)]
profileFixtures =
  [ ("alpha-254.png", 2, 1, ColourTruecolourAlpha, 8, InterlaceNone)
  , ("alpha-binary.png", 2, 2, ColourTruecolourAlpha, 8, InterlaceNone)
  , ("alpha-one.png", 2, 1, ColourTruecolourAlpha, 8, InterlaceNone)
  , ("grey-alpha16.png", 3, 1, ColourGreyscaleAlpha, 16, InterlaceNone)
  , ("grey-alpha8-trns.png", 3, 1, ColourGreyscaleAlpha, 8, InterlaceNone)
  , ("grey-alpha8.png", 3, 1, ColourGreyscaleAlpha, 8, InterlaceNone)
  , ("grey1-trns-rgb-length.png", 10, 2, ColourGreyscale, 1, InterlaceNone)
  , ("grey1-trns.png", 10, 2, ColourGreyscale, 1, InterlaceNone)
  , ("grey1.png", 10, 2, ColourGreyscale, 1, InterlaceNone)
  , ("grey16-trns.png", 3, 2, ColourGreyscale, 16, InterlaceNone)
  , ("grey16.png", 3, 2, ColourGreyscale, 16, InterlaceNone)
  , ("grey2-trns-out-of-range.png", 5, 2, ColourGreyscale, 2, InterlaceNone)
  , ("grey2-trns.png", 5, 2, ColourGreyscale, 2, InterlaceNone)
  , ("grey2.png", 5, 2, ColourGreyscale, 2, InterlaceNone)
  , ("grey4-trns.png", 3, 2, ColourGreyscale, 4, InterlaceNone)
  , ("grey4.png", 3, 2, ColourGreyscale, 4, InterlaceNone)
  , ("grey8-trns-high-byte.png", 3, 2, ColourGreyscale, 8, InterlaceNone)
  , ("grey8-trns-rgb-length.png", 3, 2, ColourGreyscale, 8, InterlaceNone)
  , ("grey8-trns-unmatched.png", 3, 2, ColourGreyscale, 8, InterlaceNone)
  , ("grey8-trns.png", 3, 2, ColourGreyscale, 8, InterlaceNone)
  , ("grey8-two-trns.png", 3, 2, ColourGreyscale, 8, InterlaceNone)
  , ("grey8.png", 3, 2, ColourGreyscale, 8, InterlaceNone)
  , ("interlaced-grey1.png", 5, 5, ColourGreyscale, 1, InterlaceAdam7)
  , ("interlaced-grey2-trns.png", 5, 5, ColourGreyscale, 2, InterlaceAdam7)
  , ("interlaced-rgb8-trns.png", 5, 5, ColourTruecolour, 8, InterlaceAdam7)
  , ("interlaced-rgba8.png", 5, 5, ColourTruecolourAlpha, 8, InterlaceAdam7)
  , ("no-palette.png", 2, 1, ColourIndexed, 8, InterlaceNone)
  , ("palette-index-out-of-range.png", 2, 1, ColourIndexed, 8, InterlaceNone)
  , ("palette-trns.png", 4, 1, ColourIndexed, 8, InterlaceNone)
  , ("palette1.png", 9, 1, ColourIndexed, 1, InterlaceNone)
  , ("palette2.png", 5, 1, ColourIndexed, 2, InterlaceNone)
  , ("palette4.png", 3, 2, ColourIndexed, 4, InterlaceNone)
  , ("palette8.png", 3, 1, ColourIndexed, 8, InterlaceNone)
  , ("rgb16-trns.png", 2, 2, ColourTruecolour, 16, InterlaceNone)
  , ("rgb16.png", 2, 1, ColourTruecolour, 16, InterlaceNone)
  , ("rgb8-iccp.png", 2, 2, ColourTruecolour, 8, InterlaceNone)
  , ("rgb8-trns-grey-length.png", 2, 2, ColourTruecolour, 8, InterlaceNone)
  , ("rgb8-trns.png", 2, 2, ColourTruecolour, 8, InterlaceNone)
  , ("rgb8.png", 2, 2, ColourTruecolour, 8, InterlaceNone)
  , ("rgba16.png", 2, 1, ColourTruecolourAlpha, 16, InterlaceNone)
  , ("rgba8-colour-chunks.png", 3, 2, ColourTruecolourAlpha, 8, InterlaceNone)
  , ("rgba8-trns.png", 3, 2, ColourTruecolourAlpha, 8, InterlaceNone)
  , ("rgba8.png", 3, 2, ColourTruecolourAlpha, 8, InterlaceNone)
  ]

colourCode ∷ PngColourType → Word8
colourCode = \case
  ColourGreyscale → 0
  ColourTruecolour → 2
  ColourIndexed → 3
  ColourGreyscaleAlpha → 4
  ColourTruecolourAlpha → 6

profileSpec ∷ Spec
profileSpec = describe "the supported static profile" $ do
  forM_ profileFixtures $ \(name, w, h, colour, depth, interlace) →
    it ("preflights " <> name <> " and states its header, scanline size and RGBA8 size") $ do
      bytes ← fixtureBytes name
      result ← preflight bytes
      acceptedWith result $ \accepted → do
        (preflightWidth accepted, preflightHeight accepted) `shouldBe` (w, h)
        preflightColourType accepted `shouldBe` colour
        preflightBitDepth accepted `shouldBe` depth
        preflightInterlace accepted `shouldBe` interlace
        preflightScanlineBytes accepted `shouldBe` expectedScanlineBytes (interlace == InterlaceAdam7) (colourCode colour) depth w h
        preflightInflatedBytes accepted `shouldSatisfy` (>= preflightScanlineBytes accepted)
        preflightRgba8Bytes accepted `shouldBe` w * h * 4

  it "covers every supported colour type and bit depth, interlaced and not" $
    ( [(colour, depth) | (_, _, _, colour, depth, _) ← profileFixtures]
        `shouldSatisfy` \seen → all (`elem` seen) (supportedPairs)
    )

  it "reads the colour key as the general decoder does: exactly one tRNS of the colour type's length" $ do
    keyOf "grey8-trns.png" >>= (`shouldBe` Just (GreyKey 128))
    keyOf "rgb8-trns.png" >>= (`shouldBe` Just (RgbKey 255 0 0))
    keyOf "grey8-two-trns.png" >>= (`shouldBe` Nothing)
    keyOf "grey8-trns-rgb-length.png" >>= (`shouldBe` Nothing)
    keyOf "rgb8-trns-grey-length.png" >>= (`shouldBe` Nothing)
    keyOf "rgba8-trns.png" >>= (`shouldBe` Nothing)
    keyOf "grey8.png" >>= (`shouldBe` Nothing)

  it "keeps a palette image's PLTE and tRNS data for decoding, without checking its indices" $ do
    bytes ← fixtureBytes "palette-trns.png"
    result ← preflight bytes
    acceptedWith result $ \accepted → do
      preflightPalette accepted `shouldBe` Just (ByteString.pack [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])
      length (preflightTransparency accepted) `shouldBe` 1
    -- Decoding's concern: an index outside the palette, and no palette at all.
    forM_ ["palette-index-out-of-range.png", "no-palette.png"] $ \name → do
      other ← fixtureBytes name >>= preflight
      other `shouldSatisfy` either (const False) (const True)

  it "does not decompress colour or profile metadata: a corrupt iCCP profile is accepted" $ do
    let corruptProfile = chunk "iCCP" ("profile\0\0" <> ByteString.pack [1 .. 40])
    result ← preflight (imagePngWith [corruptProfile] (header 2 2 8 2) 14 0)
    result `shouldSatisfy` either (const False) (const True)

  it "does not decompress colour or profile metadata: a profile that would inflate past the limit is accepted" $ do
    -- 4 MiB of zeros in a few KiB of iCCP; the inflation limit is 1 KiB.
    let bomb = chunk "iCCP" ("profile\0\0" <> zlibOf (zeros (4 * 1024 * 1024)))
        limits = limitsWith (\s → s {settingInflatedBytes = 1024})
    result ← preflightUnder limits (imagePngWith [bomb] (header 2 2 8 2) 14 0)
    result `shouldSatisfy` either (const False) (const True)
  where
    keyOf name = fixtureBytes name >>= preflight >>= fmap preflightColourKey . shouldBeAccepted
    supportedPairs =
      [(ColourGreyscale, d) | d ← [1, 2, 4, 8, 16]]
        <> [(ColourIndexed, d) | d ← [1, 2, 4, 8]]
        <> [(c, d) | c ← [ColourTruecolour, ColourGreyscaleAlpha, ColourTruecolourAlpha], d ← [8, 16]]

recognitionSpec ∷ Spec
recognitionSpec = describe "recognition" $ do
  it "recognizes a PNG by its bytes, whatever the asset is called" $ do
    -- The asset is not an input to recognition: the same bytes under the
    -- limits give the same answer however the asset is named.
    bytes ← fixtureBytes "rgb8.png"
    one ← preflight bytes
    other ← pure (preflightPng m1PngLimits (asset {assetId = AssetId "photo.jpg"}) bytes)
    fmap preflightWidth one `shouldBe` fmap preflightWidth other

  it "classifies foreign bytes as an unsupported format, never as malformed" $
    forM_ ["this is not a PNG image at all", "GIF89a\1\0\1\0\0\0\0;", "\255\216\255\224JFIF", "\137", "\137PNG\r\n\26\11 not quite"] $ \bytes →
      preflight bytes >>= (`shouldBeRefusedAs` UnsupportedFormat)

  it "classifies a KTX2 file as an unsupported format: it is tried by no other decoder" $
    fixtureBytes "rgba8-srgb.ktx2" >>= preflight >>= (`shouldBeRefusedAs` UnsupportedFormat)

  it "classifies empty input and every proper prefix of the signature as an unsupported format" $
    forM_ [0 .. 7] $ \n →
      preflight (ByteString.take n signature) >>= (`shouldBeRefusedAs` UnsupportedFormat)

  it "classifies input that begins with the whole signature and goes no further as malformed" $
    preflight signature >>= (`shouldBeRefusedAs` MalformedPng)

  it "splits at every cut point of a PNG: inside the signature unsupported, after it malformed" $ do
    whole ← fixtureBytes "interlaced-rgba8.png"
    forM_ [0 .. ByteString.length whole - 1] $ \n →
      preflight (ByteString.take n whole)
        >>= (`shouldBeRefusedAs` if n < 8 then UnsupportedFormat else MalformedPng)

  it "classifies a PNG whose first chunk is not IHDR as malformed" $
    preflight (assemble [chunk "tEXt" "a\0b", ihdrChunk (header 1 1 8 0), chunk "IEND" ""]) >>= (`shouldBeRefusedAs` MalformedPng)

  forM_ [("acTL before the first IDAT", [acTL], []), ("acTL after the IDAT", [], [acTL]), ("a stray fcTL", [fcTL], []), ("a stray fdAT", [], [fdAT])] $ \(name, before, after) →
    it ("refuses an animated PNG, " <> name <> ", as an unsupported format, without inflating it") $ do
      -- The image data is not a zlib stream at all: a refusal for corruption
      -- would show it was read.
      let png = assemble ([ihdrChunk (header 1 1 8 0)] <> before <> [chunk "IDAT" (ByteString.pack [1 .. 9])] <> after <> [chunk "IEND" ""])
      preflight png >>= (`shouldBeRefusedAs` UnsupportedFormat)
      preflight (assemble ([ihdrChunk (header 1 1 8 0)] <> before <> idatChunks 0 (zlibOf (zeros 2)) <> after <> [chunk "IEND" ""]))
        >>= (`shouldBeRefusedAs` UnsupportedFormat)
  where
    acTL = chunk "acTL" (ByteString.replicate 8 0)
    fcTL = chunk "fcTL" (ByteString.replicate 26 0)
    fdAT = chunk "fdAT" (ByteString.replicate 8 0)

framingSpec ∷ Spec
framingSpec = describe "framing and CRCs" $ do
  it "refuses a bad CRC in any chunk, ancillary and unknown chunks and the IHDR included" $ do
    let good = ihdrChunk (header 2 2 8 2)
        stream = idatChunks 0 (zlibOf (zeros 14))
        base extra = assemble ([good] <> extra <> stream <> [chunk "IEND" ""])
    preflight (base [chunk "tEXt" "k\0v"]) >>= (`shouldSatisfy` either (const False) (const True))
    forM_ ["tEXt", "gAMA", "zzZz", "iCCP", "PLTE"] $ \kind →
      preflight (base [chunkBadCrc kind "some data"]) >>= (`shouldBeRefusedAs` MalformedPng)
    preflight (assemble [chunkBadCrc "IHDR" (be13 (header 2 2 8 2)), chunk "IDAT" (zlibOf (zeros 14)), chunk "IEND" ""]) >>= (`shouldBeRefusedAs` MalformedPng)
    preflight (assemble ([good] <> [chunkBadCrc "IDAT" (zlibOf (zeros 14))] <> [chunk "IEND" ""])) >>= (`shouldBeRefusedAs` MalformedPng)
    preflight (assemble ([good] <> stream <> [chunkBadCrc "IEND" ""])) >>= (`shouldBeRefusedAs` MalformedPng)

  it "refuses a flipped byte in the IHDR chunk's CRC and in an IDAT chunk's data of a committed PNG" $ do
    bytes ← fixtureBytes "rgb8.png"
    preflight (flipAt 30 bytes) >>= (`shouldBeRefusedAs` MalformedPng)
    preflight (flipAt 41 bytes) >>= (`shouldBeRefusedAs` MalformedPng)

  it "refuses an IHDR chunk that is not 13 bytes long" $ do
    preflight (assemble [chunk "IHDR" (ByteString.replicate 12 0), chunk "IEND" ""]) >>= (`shouldBeRefusedAs` MalformedPng)
    preflight (assemble [chunk "IHDR" (ByteString.replicate 14 0), chunk "IEND" ""]) >>= (`shouldBeRefusedAs` MalformedPng)

  it "refuses a declared chunk length past the end of the input as a truncation, before taking anything from it" $
    forM_ [0xffffffff, 0x80000000, 0x7fffffff, 1024 * 1024 * 1024, 100] $ \declared → do
      let png = assemble [ihdrChunk (header 1 1 8 0), chunkWithLength declared "IDAT" "tiny", chunk "IEND" ""]
      preflight png >>= (`shouldBeRefusedAs` MalformedPng)
      -- And at the first chunk.
      preflight (assemble [chunkWithLength declared "IHDR" "tiny"]) >>= (`shouldBeRefusedAs` MalformedPng)

  it "refuses input that ends before IEND, with the last chunk whole" $
    preflight (assemble ([ihdrChunk (header 1 1 8 0)] <> idatChunks 0 (zlibOf (zeros 2)))) >>= (`shouldBeRefusedAs` MalformedPng)

  it "does not parse bytes after a complete IEND, as the general decoder does not, and counts them in the source limit" $ do
    let png = imagePng (header 3 2 8 0) 8
        trailing = png <> "trailing bytes that are not a chunk"
    preflight trailing >>= shouldBeAccepted >>= (\accepted → preflightWidth accepted `shouldBe` 3)
    -- Established against the general decoder: it accepts the same bytes.
    isDecodable trailing `shouldBe` True
    preflightUnder (limitsWith (\s → s {settingSourceBytes = toInteger (ByteString.length png)})) trailing
      >>= (`shouldBeRefusedAs` ExceededLimit LimitSourceBytes)
    preflightUnder (limitsWith (\s → s {settingSourceBytes = toInteger (ByteString.length trailing)})) trailing >>= shouldBeAccepted >>= \_ → pure ()
  where
    be13 h = ByteString.take 13 (ByteString.drop 8 (ihdrChunk h))
    flipAt at bytes = ByteString.take at bytes <> ByteString.singleton (ByteString.index bytes at + 1) <> ByteString.drop (at + 1) bytes

headerSpec ∷ Spec
headerSpec = describe "the header" $ do
  it "refuses a zero width or height as malformed" $
    forM_ [header 0 1 8 0, header 1 0 8 0, header 0 0 8 0] $ \h →
      preflight (imagePng h 2) >>= (`shouldBeRefusedAs` MalformedPng)

  it "refuses every colour type and bit depth pair the specification does not allow" $
    forM_ [(colour, depth) | colour ← [0, 2, 3, 4, 6], depth ← [0, 1, 2, 3, 4, 5, 8, 16, 32], (colour, depth) `notElem` allowedPairs] $ \(colour, depth) →
      preflight (imagePng (header 1 1 depth colour) 6) >>= (`shouldBeRefusedAs` MalformedPng)

  it "accepts exactly the allowed pairs" $
    forM_ allowedPairs $ \(colour, depth) →
      preflight (imagePng (header 1 1 depth colour) (expectedScanlineBytes False colour (fromIntegral depth) 1 1)) >>= shouldBeAccepted >>= \_ → pure ()

  it "refuses a colour type the specification does not define" $
    forM_ [1, 5, 7, 255] $ \colour →
      preflight (imagePng (header 1 1 8 colour) 6) >>= (`shouldBeRefusedAs` MalformedPng)

  it "refuses a compression, filter or interlace method the specification does not define" $ do
    preflight (imagePng (header 1 1 8 0) {hCompression = 1} 2) >>= (`shouldBeRefusedAs` MalformedPng)
    preflight (imagePng (header 1 1 8 0) {hFilter = 1} 2) >>= (`shouldBeRefusedAs` MalformedPng)
    preflight (imagePng (header 1 1 8 0) {hInterlace = 2} 2) >>= (`shouldBeRefusedAs` MalformedPng)

  it "classifies a dimension above the PNG maximum of 2^31 - 1 as malformed, not as too large" $
    forM_ [2 ^ (31 ∷ Int), 2 ^ (31 ∷ Int) + 1, 0xffffffff] $ \big → do
      preflight (imagePng (header big 1 8 0) 2) >>= (`shouldBeRefusedAs` MalformedPng)
      preflight (imagePng (header 1 big 8 0) 2) >>= (`shouldBeRefusedAs` MalformedPng)

  it "classifies a dimension up to 2^31 - 1 that is over the limit as too large, without allocating from it" $ do
    -- A 2^31 - 1 wide RGBA16 image would need about 16 GiB of scanlines.
    preflight (imagePng (header 2147483647 1 16 6) 2) >>= (`shouldBeRefusedAs` ExceededLimit LimitWidth)
    preflight (imagePng (header 1 2147483647 16 6) 2) >>= (`shouldBeRefusedAs` ExceededLimit LimitHeight)
    preflight (imagePng (header 2147483647 2147483647 16 6) 2) >>= (`shouldBeRefusedAs` ExceededLimit LimitWidth)
  where
    allowedPairs ∷ [(Word8, Word8)]
    allowedPairs =
      [(0, d) | d ← [1, 2, 4, 8, 16]] <> [(3, d) | d ← [1, 2, 4, 8]] <> [(c, d) | c ← [2, 4, 6], d ← [8, 16]]

limitEdgesSpec ∷ Spec
limitEdgesSpec = describe "each limit, at its edge and one past" $ do
  -- A 4 × 4 RGBA8 image: 16 pixels, 64 RGBA8 bytes, 4 × (1 + 16) = 68
  -- scanline bytes, three chunks.
  let square = imagePng (header 4 4 8 6) 68
      untouched = m1Settings

  it "source bytes" $ do
    let n = toInteger (ByteString.length square)
    preflightUnder (limitsWith (\s → s {settingSourceBytes = n})) square >>= shouldBeAccepted >>= \_ → pure ()
    preflightUnder (limitsWith (\s → s {settingSourceBytes = n - 1})) square >>= (`shouldBeRefusedAs` ExceededLimit LimitSourceBytes)

  it "source bytes, before the signature is looked at, at the M1 value" $ do
    let limit = 32 * 1024 * 1024
    preflight (ByteString.replicate (limit + 1) 0) >>= (`shouldBeRefusedAs` ExceededLimit LimitSourceBytes)
    preflight (ByteString.replicate limit 0) >>= (`shouldBeRefusedAs` UnsupportedFormat)

  it "chunks, counting IHDR through IEND inclusive" $ do
    -- IHDR, IDAT, IEND: three.
    preflightUnder (limitsWith (\s → s {settingChunks = 3})) square >>= shouldBeAccepted >>= \_ → pure ()
    preflightUnder (limitsWith (\s → s {settingChunks = 2})) square >>= (`shouldBeRefusedAs` ExceededLimit LimitChunks)
    preflightUnder (limitsWith (\s → s {settingChunks = 1})) square >>= (`shouldBeRefusedAs` ExceededLimit LimitChunks)
    let many n = assemble ([ihdrChunk (header 4 4 8 6)] <> replicate n (chunk "zzZz" "") <> idatChunks 0 (zlibOf (zeros 68)) <> [chunk "IEND" ""])
    -- At the M1 value: 4,096 chunks pass and 4,097 do not.
    preflight (many (4096 - 3)) >>= shouldBeAccepted >>= \_ → pure ()
    preflight (many (4096 - 2)) >>= (`shouldBeRefusedAs` ExceededLimit LimitChunks)

  it "a chunk past the limit is refused before it is retained, however many follow" $
    preflight (assemble ([ihdrChunk (header 4 4 8 6)] <> replicate 20000 (chunk "zzZz" "") <> [chunk "IEND" ""]))
      >>= (`shouldBeRefusedAs` ExceededLimit LimitChunks)

  it "width" $ do
    preflightUnder (limitsWith (\s → s {settingWidth = 4})) square >>= shouldBeAccepted >>= \_ → pure ()
    preflightUnder (limitsWith (\s → s {settingWidth = 3})) square >>= (`shouldBeRefusedAs` ExceededLimit LimitWidth)

  it "height" $ do
    preflightUnder (limitsWith (\s → s {settingHeight = 4})) square >>= shouldBeAccepted >>= \_ → pure ()
    preflightUnder (limitsWith (\s → s {settingHeight = 3})) square >>= (`shouldBeRefusedAs` ExceededLimit LimitHeight)

  it "pixels, with each axis within its own limit" $ do
    preflightUnder (limitsWith (\s → s {settingPixels = 16})) square >>= shouldBeAccepted >>= \_ → pure ()
    preflightUnder (limitsWith (\s → s {settingPixels = 15})) square >>= (`shouldBeRefusedAs` ExceededLimit LimitPixels)

  it "the eventual RGBA8 output, with the pixel limit not reached" $ do
    preflightUnder (limitsWith (\s → s {settingRgba8Bytes = 64})) square >>= shouldBeAccepted >>= \_ → pure ()
    preflightUnder (limitsWith (\s → s {settingRgba8Bytes = 63})) square >>= (`shouldBeRefusedAs` ExceededLimit LimitRgba8Bytes)

  it "the scanline bytes the header needs, before the image data is read" $ do
    preflightUnder (limitsWith (\s → s {settingInflatedBytes = 68})) square >>= shouldBeAccepted >>= \_ → pure ()
    -- The image data here is not a zlib stream: a malformed refusal would
    -- show inflation had started.
    let garbage = assemble [ihdrChunk (header 4 4 8 6), chunk "IDAT" (ByteString.pack [1 .. 30]), chunk "IEND" ""]
    preflightUnder (limitsWith (\s → s {settingInflatedBytes = 67})) garbage >>= (`shouldBeRefusedAs` ExceededLimit LimitInflatedBytes)
    preflightUnder (limitsWith (\s → s {settingInflatedBytes = 68})) garbage >>= (`shouldBeRefusedAs` MalformedPng)

  it "every limit at its M1 value, at the approved maxima, without a giant image" $ do
    -- 2048 × 2048 RGBA16: the largest scanline stream a legal M1 header
    -- needs, noninterlaced and Adam7. The stream inflates 33 MB in pieces and
    -- keeps none of it.
    forM_ [(False, 33556480), (True, 33558272)] $ \(interlaced, needed) → do
      let h = (header 2048 2048 16 6) {hInterlace = if interlaced then 1 else 0}
      expectedScanline interlaced `shouldBe` needed
      result ← preflight (imagePng h needed)
      acceptedWith result $ \accepted → do
        preflightScanlineBytes accepted `shouldBe` needed
        preflightRgba8Bytes accepted `shouldBe` 16 * 1024 * 1024
        preflightInflatedBytes accepted `shouldBe` needed

  it "one past the M1 axis, pixel and RGBA8 values" $ do
    preflight (imagePng (header 2049 1 8 0) 2) >>= (`shouldBeRefusedAs` ExceededLimit LimitWidth)
    preflight (imagePng (header 1 2049 8 0) 2) >>= (`shouldBeRefusedAs` ExceededLimit LimitHeight)
    -- At the M1 values the pixel and RGBA8 limits equal 2048 × 2048 and
    -- 2048 × 2048 × 4: smaller independent limits reach them.
    preflightUnder (limitsWith (\s → s {settingPixels = 4194303})) (imagePng (header 2048 2048 1 0) 526336)
      >>= (`shouldBeRefusedAs` ExceededLimit LimitPixels)
    preflightUnder (limitsWith (\s → s {settingRgba8Bytes = 16 * 1024 * 1024 - 1})) (imagePng (header 2048 2048 1 0) 526336)
      >>= (`shouldBeRefusedAs` ExceededLimit LimitRgba8Bytes)

  it "has no limit that another changes: raising the others leaves one refusal in place" $ do
    let big = m1Settings {settingWidth = largestLimit, settingHeight = largestLimit, settingPixels = largestLimit, settingRgba8Bytes = largestLimit, settingInflatedBytes = largestLimit}
    preflightUnder (limitsWith (const big {settingSourceBytes = 50})) square >>= (`shouldBeRefusedAs` ExceededLimit LimitSourceBytes)
    preflightUnder (limitsWith (const untouched)) square >>= shouldBeAccepted >>= \_ → pure ()
  where
    expectedScanline interlaced = expectedScanlineBytes interlaced 6 16 2048 2048

precedenceSpec ∷ Spec
precedenceSpec = describe "the order the checks run in" $ do
  let h = header 1 1 8 0
      acTL = chunk "acTL" (ByteString.replicate 8 0)
      stream = idatChunks 0 (zlibOf (zeros 2))
      end = [chunk "IEND" ""]

  it "decides by the first failing check, in file order" $ do
    -- Chunk-count overflow, then a later animation marker: too many chunks.
    preflightUnder (limitsWith (\s → s {settingChunks = 3})) (assemble ([ihdrChunk h, chunk "zzZz" "", chunk "zzZz" "", acTL] <> stream <> end))
      >>= (`shouldBeRefusedAs` ExceededLimit LimitChunks)
    -- An animation marker, then a later CRC failure: animated.
    preflight (assemble ([ihdrChunk h, acTL] <> stream <> [chunkBadCrc "tEXt" "x"] <> end)) >>= (`shouldBeRefusedAs` UnsupportedFormat)
    -- A CRC failure, then a later animation marker: malformed.
    preflight (assemble ([ihdrChunk h, chunkBadCrc "tEXt" "x", acTL] <> stream <> end)) >>= (`shouldBeRefusedAs` MalformedPng)
    -- An animation marker with a bad CRC of its own: its CRC first.
    preflight (assemble ([ihdrChunk h, chunkBadCrc "acTL" (ByteString.replicate 8 0)] <> stream <> end)) >>= (`shouldBeRefusedAs` MalformedPng)
    -- An animation marker, then an invalid header: the header is checked after the scan.
    preflight (assemble ([ihdrChunk (header 0 0 8 0), acTL] <> stream <> end)) >>= (`shouldBeRefusedAs` UnsupportedFormat)
    -- A truncation after an animation marker is never reached.
    preflight (assemble ([ihdrChunk h, acTL] <> [chunkWithLength 99 "IDAT" ""])) >>= (`shouldBeRefusedAs` UnsupportedFormat)

  it "checks the source length before the signature" $
    preflightUnder (limitsWith (\s → s {settingSourceBytes = 4})) "not a PNG at all" >>= (`shouldBeRefusedAs` ExceededLimit LimitSourceBytes)

  it "checks the header before the size-derived limits, and those before inflating" $ do
    -- Zero width in a file over the width limit's sibling: malformed first.
    preflightUnder (limitsWith (\s → s {settingHeight = 1})) (imagePng (header 0 5 8 0) 2) >>= (`shouldBeRefusedAs` MalformedPng)
    -- Width, height, pixels, RGBA8, scanline bytes: the first that fails.
    let small = limitsWith (\s → s {settingWidth = 1, settingHeight = 1, settingPixels = 1, settingRgba8Bytes = 1, settingInflatedBytes = 1})
    preflightUnder small (imagePng (header 5 5 8 6) 105) >>= (`shouldBeRefusedAs` ExceededLimit LimitWidth)
    preflightUnder small (imagePng (header 1 5 8 6) 25) >>= (`shouldBeRefusedAs` ExceededLimit LimitHeight)
    preflightUnder (limitsWith (\s → s {settingPixels = 1, settingRgba8Bytes = 1, settingInflatedBytes = 1})) (imagePng (header 5 5 8 6) 105)
      >>= (`shouldBeRefusedAs` ExceededLimit LimitPixels)
    preflightUnder (limitsWith (\s → s {settingRgba8Bytes = 1, settingInflatedBytes = 1})) (imagePng (header 5 5 8 6) 105)
      >>= (`shouldBeRefusedAs` ExceededLimit LimitRgba8Bytes)
    preflightUnder (limitsWith (\s → s {settingInflatedBytes = 1})) (imagePng (header 5 5 8 6) 105)
      >>= (`shouldBeRefusedAs` ExceededLimit LimitInflatedBytes)

scanlineSpec ∷ Spec
scanlineSpec = describe "scanline sizes" $ do
  -- Each expected size was counted pixel by pixel (and, for these rows, by a
  -- second script written separately), not taken from the production formula.
  forM_ cases $ \(w, h, colour, depth, interlaced, expected) →
    it (show w <> " × " <> show h <> ", colour " <> show colour <> " at " <> show depth <> " bits, " <> (if interlaced then "Adam7" else "noninterlaced") <> ": " <> show expected <> " bytes") $ do
      expectedScanlineBytes interlaced colour depth w h `shouldBe` expected
      let hdr = (header (fromIntegral w) (fromIntegral h) (fromIntegral depth) colour) {hInterlace = if interlaced then 1 else 0}
      result ← preflight (imagePng hdr expected)
      acceptedWith result $ \accepted → preflightScanlineBytes accepted `shouldBe` expected
      -- One byte fewer in the stream is a short stream; one fewer allowed is too large.
      preflight (imagePng hdr (expected - 1)) >>= (`shouldBeRefusedAs` MalformedPng)
      preflightUnder (limitsWith (\s → s {settingInflatedBytes = toInteger expected - 1})) (imagePng hdr expected)
        >>= (`shouldBeRefusedAs` ExceededLimit LimitInflatedBytes)
      preflightUnder (limitsWith (\s → s {settingInflatedBytes = toInteger expected})) (imagePng hdr expected) >>= shouldBeAccepted >>= \_ → pure ()

  it "has empty Adam7 passes contribute no filter bytes: a 1 × 1 image takes only the first pass" $
    expectedScanlineBytes True 0 8 1 1 `shouldBe` 2
  where
    cases ∷ [(Int, Int, Word8, Int, Bool, Int)]
    cases =
      [ (1, 1, 0, 8, True, 2)
      , (1, 1, 6, 16, True, 9)
      , (2, 2, 0, 1, True, 6)
      , (1, 5, 0, 8, True, 10)
      , (5, 1, 0, 8, True, 9)
      , (3, 3, 0, 4, True, 13)
      , (9, 1, 0, 1, False, 3)
      , (5, 2, 0, 2, False, 6)
      , (3, 3, 0, 4, False, 9)
      , (10, 2, 0, 1, False, 6)
      , (1, 1, 2, 16, False, 7)
      , (7, 3, 3, 2, True, 15)
      , (8, 8, 2, 8, True, 207)
      , (9, 9, 0, 1, True, 42)
      , (17, 13, 4, 16, True, 910)
      , (4, 4, 6, 8, False, 68)
      , (1, 2048, 2, 8, True, 8192)
      ]

-- | The general decoder, which is unchanged and unbounded, accepts the bytes.
isDecodable ∷ ByteString → Bool
isDecodable = either (const False) (const True) . decodePng DataImage asset
