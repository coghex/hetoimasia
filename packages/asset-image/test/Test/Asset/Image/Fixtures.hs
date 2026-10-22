-- | Every committed fixture decodes to the texels written here.
--
-- The expected texels are the fixture script's inputs, restated by hand: the
-- straight (unpremultiplied) RGBA8 values each file holds once a missing alpha
-- becomes 255 and 16-bit components round to nearest. A data decode must
-- return them exactly; a colour decode must return them premultiplied, within
-- one code value of the independent reference, with alpha unchanged.
module Test.Asset.Image.Fixtures (spec, Expected (..), expectedFixtures, shouldMatchPremultiplied) where

import qualified Codec.Picture.Png as JuicyPixels
import Control.Monad (forM_, zipWithM_)
import Data.Either (isRight)
import Data.Word (Word8)
import Hetoimasia.Asset.Image (DecodedImage (..), ImageKind (..))
import Test.Asset.Image.Support (Texel, decodeFixture, fixtureBytes, referencePremultiplied, shouldBeWithinOne, texels)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe)

-- | A fixture, its extent, and its straight texels row by row.
data Expected = Expected FilePath Int Int [Texel]

grey ∷ Word8 → Texel
grey y = (y, y, y, 255)

greyAlpha ∷ (Word8, Word8) → Texel
greyAlpha (y, a) = (y, y, y, a)

opaque ∷ (Word8, Word8, Word8) → Texel
opaque (r, g, b) = (r, g, b, 255)

rgb8, rgba8 ∷ [Texel]
rgb8 = map opaque [(255, 0, 0), (0, 255, 0), (0, 0, 255), (12, 34, 56)]
rgba8 = [(255, 0, 0, 255), (0, 255, 0, 128), (0, 0, 255, 0), (200, 100, 50, 64), (255, 255, 255, 255), (1, 2, 3, 4)]

colourTypes ∷ [Expected]
colourTypes =
  [ Expected "grey1.png" 10 2 (map (grey . (* 255)) ([0, 1, 0, 1, 1, 0, 0, 1, 1, 1] <> [1, 0, 1, 0, 0, 1, 1, 0, 0, 0]))
  , Expected "grey2.png" 5 2 (map grey [0, 85, 170, 255, 0, 255, 170, 85, 0, 85])
  , Expected "grey4.png" 3 2 (map grey [0, 119, 255, 17, 136, 238])
  , Expected "grey8.png" 3 2 (map grey [0, 128, 255, 17, 64, 200])
  , Expected "grey-alpha8.png" 3 1 (map greyAlpha [(10, 0), (128, 127), (255, 255)])
  , Expected "palette1.png" 9 1 (map ([(255, 0, 0, 255), (0, 0, 255, 255)] !!) [0, 1, 1, 0, 1, 0, 0, 1, 1])
  , Expected "palette2.png" 5 1 (map ([(0, 0, 0, 255), (255, 0, 0, 255), (0, 255, 0, 255), (0, 0, 255, 255)] !!) [3, 2, 1, 0, 2])
  , Expected "palette4.png" 3 2 (map opaque [(0, 255, 0), (80, 175, 5), (240, 15, 15), (160, 95, 10), (16, 239, 1), (144, 111, 9)])
  , Expected "palette8.png" 3 1 (map opaque [(0, 255, 0), (100, 155, 188), (199, 56, 113)])
  , Expected "palette-trns.png" 4 1 [(255, 0, 0, 0), (0, 255, 0, 128), (0, 0, 255, 255), (255, 255, 255, 255)]
  , Expected "rgb8.png" 2 2 rgb8
  , Expected "rgba8.png" 3 2 rgba8
  ]

-- | 16-bit files, with the source values beside each expected texel: 129
-- rounds to 1 where truncation would give 0, and 386 to 2 where it would give 1.
sixteenBit ∷ [Expected]
sixteenBit =
  [ -- 0, 129, 383 / 386, 32896, 65535
    Expected "grey16.png" 3 2 (map grey [0, 1, 1, 2, 128, 255])
  , -- (65535, 129), (32896, 386), (129, 65535)
    Expected "grey-alpha16.png" 3 1 (map greyAlpha [(255, 1), (128, 2), (1, 255)])
  , -- (129, 383, 386), (65535, 0, 32896)
    Expected "rgb16.png" 2 1 (map opaque [(1, 1, 2), (255, 0, 128)])
  , -- (65535, 129, 0, 386), (32896, 386, 383, 65535)
    Expected "rgba16.png" 2 1 [(255, 1, 0, 2), (128, 2, 1, 255)]
  ]

interlaced ∷ [Expected]
interlaced =
  [ Expected "interlaced-rgba8.png" 5 5 [(x * 50, y * 50, (x + y) * 20, 255 - x * 10 - y * 20) | y ← [0 .. 4], x ← [0 .. 4]]
  , Expected "interlaced-grey1.png" 5 5 [grey (255 * ((x + y) `mod` 2)) | y ← [0 .. 4 ∷ Word8], x ← [0 .. 4]]
  ]

-- | Colour-space chunks over the same texels as rgba8.png and rgb8.png.
ignoredChunks ∷ [Expected]
ignoredChunks =
  [ Expected "rgba8-colour-chunks.png" 3 2 rgba8
  , Expected "rgb8-iccp.png" 2 2 rgb8
  ]

-- | A greyscale texel of this 8-bit value, transparent when its stored
-- sample equals the key.
keyedGrey ∷ (Word8, Bool) → Texel
keyedGrey (y, keyed) = (y, y, y, if keyed then 0 else 255)

-- | tRNS colour keys, compared with the stored samples at the file's own bit
-- depth. Each list pairs a texel's 8-bit value with whether its stored
-- sample equals the key.
colourKeys ∷ [Expected]
colourKeys =
  [ -- 1-bit samples; key 1.
    Expected "grey1-trns.png" 10 2 [keyedGrey (255 * s, s == 1) | s ← [0, 1, 0, 1, 1, 0, 0, 1, 1, 1] <> [1, 0, 1, 0, 0, 1, 1, 0, 0, 0]]
  , -- 2-bit samples 0 1 2 3 0 / 3 2 1 0 1; key 1.
    Expected "grey2-trns.png" 5 2 [keyedGrey (85 * s, s == 1) | s ← [0, 1, 2, 3, 0, 3, 2, 1, 0, 1]]
  , -- 4-bit samples 0 7 15 / 1 8 14; key 7.
    Expected "grey4-trns.png" 3 2 [keyedGrey (17 * s, s == 7) | s ← [0, 7, 15, 1, 8, 14]]
  , -- key 128.
    Expected "grey8-trns.png" 3 2 [keyedGrey (s, s == 128) | s ← [0, 128, 255, 17, 64, 200]]
  , -- 16-bit samples 0x1234 0x1299 0x5534 / 0x1234 0 65535; key 0x1234.
    -- 0x1299 shares only the key's high byte and is not keyed.
    Expected "grey16-trns.png" 3 2 (map keyedGrey [(18, True), (19, False), (85, False), (18, True), (0, False), (255, False)])
  , -- key (255, 0, 0).
    Expected "rgb8-trns.png" 2 2 [(255, 0, 0, 0), (0, 255, 0, 255), (0, 0, 255, 255), (12, 34, 56, 255)]
  , -- 16-bit (0x1234, 0x5678, 0x9abc) (0x12ff, 0x56ff, 0x9aff) /
    -- (0x1234, 0x5678, 0x9abd) (0x1234, 0x5678, 0x9abc); key
    -- (0x1234, 0x5678, 0x9abc). The second shares only the key's high bytes;
    -- the third reduces to the key's 8-bit texel but is not the key.
    Expected "rgb16-trns.png" 2 2 [(18, 86, 154, 0), (19, 87, 154, 255), (18, 86, 154, 255), (18, 86, 154, 0)]
  , -- Adam7, 2-bit samples (x + 2y) mod 4; key 2.
    Expected "interlaced-grey2-trns.png" 5 5 [keyedGrey (85 * s, s == 2) | y ← [0 .. 4], x ← [0 .. 4 ∷ Word8], let s = (x + 2 * y) `mod` 4]
  , -- Adam7, (x mod 2 × 100, y mod 2 × 100, 7); key (100, 0, 7).
    Expected "interlaced-rgb8-trns.png" 5 5
      [(r, g, 7, if (r, g) == (100, 0) then 0 else 255) | y ← [0 .. 4], x ← [0 .. 4 ∷ Word8], let r = x `mod` 2 * 100, let g = y `mod` 2 * 100]
  , -- Keys no stored sample equals: 77, absent from the image; 5, beyond the
    -- 2-bit range; 0x0180, whose low byte is a texel's 128.
    Expected "grey8-trns-unmatched.png" 3 2 grey8
  , Expected "grey2-trns-out-of-range.png" 5 2 (map grey [0, 85, 170, 255, 0, 255, 170, 85, 0, 85])
  , Expected "grey8-trns-high-byte.png" 3 2 grey8
  ]

-- | Malformed tRNS chunks, which JuicyPixels decodes without complaint, and
-- which therefore key nothing: a length the colour type does not take, a
-- colour type with an alpha channel of its own, and a second tRNS chunk.
malformedKeys ∷ [Expected]
malformedKeys =
  [ Expected "grey8-trns-rgb-length.png" 3 2 grey8
  , Expected "grey1-trns-rgb-length.png" 10 2 (map (grey . (* 255)) ([0, 1, 0, 1, 1, 0, 0, 1, 1, 1] <> [1, 0, 1, 0, 0, 1, 1, 0, 0, 0]))
  , Expected "rgb8-trns-grey-length.png" 2 2 rgb8
  , Expected "rgba8-trns.png" 3 2 rgba8
  , Expected "grey-alpha8-trns.png" 3 1 (map greyAlpha [(10, 0), (128, 127), (255, 255)])
  , Expected "grey8-two-trns.png" 3 2 grey8
  ]

-- | The 16-bit rounding the fixtures are stated with: nearest(v × 255 ÷
-- 65535), as an exact rational rounding rather than the decoders' integer
-- arithmetic. 65535 is odd, so there is never a tie.
narrow16 ∷ Int → Word8
narrow16 v = fromInteger (round (toRational v * 255 / 65535))

alphas16 ∷ [Int]
alphas16 = [0, 129, 32896, 65535, 386, 65534]

rgba16Pixel ∷ Int → Int → (Int, Int, Int, Int)
rgba16Pixel x y =
  ((x * 7919 + y * 10477) `mod` 65536, (x * 3571 + y * 9001 + 129) `mod` 65536, (65535 - x * 4099 - y * 257) `mod` 65536, alphas16 !! ((x + y) `mod` 6))

rgba16Texels ∷ Int → Int → [Texel]
rgba16Texels w h = [(narrow16 r, narrow16 g, narrow16 b, narrow16 a) | y ← [0 .. h - 1], x ← [0 .. w - 1], let (r, g, b, a) = rgba16Pixel x y]

greyAlpha16Pixel ∷ Int → Int → (Int, Int)
greyAlpha16Pixel x y = ((x * 13001 + y * 977) `mod` 65536, alphas16 !! ((2 * x + y) `mod` 6))

rgb16KeyedPixel ∷ Int → Int → (Int, Int, Int)
rgb16KeyedPixel x y = ((x `mod` 3) * 20000 + 300, (y `mod` 2) * 30000 + 5, if (x + y) `mod` 4 /= 0 then 0x1234 else 0x12FF)

grey16KeyedPixel ∷ Int → Int → Int
grey16KeyedPixel x y = ((x * 5 + y) `mod` 7) * 0x1111 + (if (x + y) `mod` 3 == 0 then 0x00FF else 0)

-- | Palette 3 × 1: entries (10, 20, 30) and (200, 100, 50), one tRNS byte 128
-- that gives entry 0 alpha 128.
smallPalette ∷ Int → Texel
smallPalette i = [(10, 20, 30, 128), (200, 100, 50, 255)] !! i

rgb8Odd ∷ Int → Int → (Int, Int, Int)
rgb8Odd x y = (x * 15, y * 19, (x * y) `mod` 256)

rgb8Filters ∷ Int → Int → (Int, Int, Int)
rgb8Filters x y = (x * 19 + y, y * 23 + x, (x * y * 7) `mod` 256)

byte ∷ (Int, Int, Int) → Texel
byte (r, g, b) = (fromIntegral r, fromIntegral g, fromIntegral b, 255)

paletteEntry8 ∷ Int → Texel
paletteEntry8 i = (fromIntegral i, fromIntegral (255 - i), fromIntegral ((i * 7) `mod` 256), 255)

-- | 16-bit images under Adam7, with alpha and with colour keys, over extents
-- that leave passes empty or short.
adam7Sixteen ∷ [Expected]
adam7Sixteen =
  [ Expected "adam7-rgba16.png" 9 7 (rgba16Texels 9 7)
  , Expected "adam7-grey-alpha16.png" 5 3 [(y', y', y', narrow16 a) | y ← [0 .. 2], x ← [0 .. 4], let (v, a) = greyAlpha16Pixel x y, let y' = narrow16 v]
  , -- Key (20300, 5, 0x1234): the blue high byte alone does not key a texel.
    Expected "adam7-rgb16-trns.png" 7 5
      [ (narrow16 r, narrow16 g, narrow16 b, if (r, g, b) == (20300, 5, 0x1234) then 0 else 255)
      | y ← [0 .. 4]
      , x ← [0 .. 6]
      , let (r, g, b) = rgb16KeyedPixel x y
      ]
  , Expected "adam7-grey16-trns.png" 6 6
      [(y', y', y', if v == 0x2222 then 0 else 255) | y ← [0 .. 5], x ← [0 .. 5], let v = grey16KeyedPixel x y, let y' = narrow16 v]
  ]

-- | Adam7 over extents that leave whole passes empty: a single texel, a
-- single column, a single row, and two by two.
emptyPasses ∷ [Expected]
emptyPasses =
  [ Expected "adam7-grey8-1x1.png" 1 1 [grey 77]
  , Expected "adam7-rgb8-1x9.png" 1 9 [byte (y * 20, 255 - y * 20, y * 3 + 1) | y ← [0 .. 8]]
  , Expected "adam7-grey4-9x1.png" 9 1 [grey (fromIntegral (x * 3 `mod` 16 * 17)) | x ← [0 .. 8 ∷ Int]]
  , Expected "adam7-palette1-3x1.png" 3 1 (map smallPalette [1, 0, 1])
  , Expected "adam7-rgba8-2x2.png" 2 2 [(255, 0, 0, 255), (0, 255, 0, 200), (0, 0, 255, 100), (9, 9, 9, 0)]
  ]

-- | Adam7 over odd extents at the other depths and colour types.
adam7Odd ∷ [Expected]
adam7Odd =
  [ Expected "adam7-palette4-trns-6x4.png" 6 4
      [ (fromIntegral (i * 16), fromIntegral (255 - i * 16), fromIntegral (i * 3), if i < 5 then [255, 200, 100, 50, 0] !! i else 255)
      | y ← [0 .. 3]
      , x ← [0 .. 5]
      , let i = (x * 3 + y * 5) `mod` 16
      ]
  , Expected "adam7-grey2-13x11-trns.png" 13 11
      [keyedGrey (fromIntegral (85 * s), s == 3) | y ← [0 .. 10 ∷ Int], x ← [0 .. 12], let s = (x * x + y) `mod` 4]
  , Expected "adam7-grey4-11x9.png" 11 9 [grey (fromIntegral (17 * ((x * 5 + y * 7) `mod` 16))) | y ← [0 .. 8 ∷ Int], x ← [0 .. 10]]
  , Expected "adam7-rgb8-17x13.png" 17 13 [byte (rgb8Odd x y) | y ← [0 .. 12], x ← [0 .. 16]]
  , Expected "adam7-palette8-10x10.png" 10 10 [paletteEntry8 ((x * 23 + y * 7) `mod` 200) | y ← [0 .. 9], x ← [0 .. 9]]
  , Expected "adam7-grey-alpha8-3x3.png" 3 3 [greyAlpha (fromIntegral (x * 100 + y * 20), fromIntegral (255 - x * 50 - y * 40)) | y ← [0 .. 2 ∷ Int], x ← [0 .. 2]]
  ]

-- | Non-interlaced images tall enough that every filter type (the row index
-- mod 5) is used at every pixel size in bytes: 1 (sub-byte and 8-bit grey,
-- palette), 2, 3, 4 and 8.
filterModes ∷ [Expected]
filterModes =
  [ Expected "filters-rgba16.png" 11 12 (rgba16Texels 11 12)
  , Expected "filters-rgb8.png" 13 11 [byte (rgb8Filters x y) | y ← [0 .. 10], x ← [0 .. 12]]
  , Expected "filters-grey1.png" 21 11 [grey (if (x * 7 + y * 3) `mod` 5 < 2 then 255 else 0) | y ← [0 .. 10 ∷ Int], x ← [0 .. 20]]
  , Expected "filters-grey-alpha8.png" 9 10 [greyAlpha (fromIntegral (x * 27 + y), fromIntegral (255 - x * 13 - y * 7)) | y ← [0 .. 9 ∷ Int], x ← [0 .. 8]]
  , Expected "filters-palette2.png" 17 9 [[(0, 0, 0, 255), (255, 0, 0, 255), (0, 255, 0, 255), (0, 0, 255, 255)] !! ((x + 2 * y) `mod` 4) | y ← [0 .. 8], x ← [0 .. 16]]
  , Expected "filters-grey16.png" 7 9 [grey (narrow16 ((x * 9533 + y * 701) `mod` 65536)) | y ← [0 .. 8], x ← [0 .. 6]]
  ]

-- | The image of filters-rgb8.png with its compressed stream in one-byte IDAT
-- chunks, and in seven-byte pieces separated by empty chunks; and an image
-- whose compressed ancillary chunks (zTXt, iTXt, iCCP) hold bytes that are no
-- zlib stream, over the texels of rgb8.png.
chunkBoundaries ∷ [Expected]
chunkBoundaries =
  [ Expected "idat-single-bytes.png" 13 11 [byte (rgb8Filters x y) | y ← [0 .. 10], x ← [0 .. 12]]
  , Expected "idat-empty-chunks.png" 13 11 [byte (rgb8Filters x y) | y ← [0 .. 10], x ← [0 .. 12]]
  , Expected "rgb8-garbage-text.png" 2 2 rgb8
  ]

-- | Every fixture whose texels are stated here, for the decoders that must
-- reproduce them.
expectedFixtures ∷ [Expected]
expectedFixtures =
  concat [colourTypes, sixteenBit, interlaced, ignoredChunks, colourKeys, malformedKeys, adam7Sixteen, emptyPasses, adam7Odd, filterModes, chunkBoundaries]

grey8 ∷ [Texel]
grey8 = map grey [0, 128, 255, 17, 64, 200]

spec ∷ Spec
spec = describe "Fixtures" $ do
  describe "every colour type at 8 bits and below" $ mapM_ decodesTo colourTypes
  describe "16-bit components round to nearest" $ mapM_ decodesTo sixteenBit
  describe "Adam7 interlacing" $ mapM_ decodesTo interlaced
  describe "chunks that do not change texels" $ mapM_ decodesTo ignoredChunks
  describe "tRNS colour keys" $ mapM_ decodesTo colourKeys
  describe "16-bit Adam7 with alpha and colour keys" $ mapM_ decodesTo adam7Sixteen
  describe "Adam7 passes with no columns or rows" $ mapM_ decodesTo emptyPasses
  describe "Adam7 over odd extents" $ mapM_ decodesTo adam7Odd
  describe "every filter type at every pixel size" $ mapM_ decodesTo filterModes
  describe "IDAT chunk boundaries and compressed chunks that are not zlib" $ mapM_ decodesTo chunkBoundaries
  describe "malformed tRNS chunks" $ forM_ malformedKeys $ \expected@(Expected name _ _ _) → do
    it (name <> " is one JuicyPixels decodes") $ do
      bytes ← fixtureBytes name
      isRight (JuicyPixels.decodePng bytes) `shouldBe` True
    decodesTo expected

decodesTo ∷ Expected → Spec
decodesTo (Expected name width height straight) = describe name $ do
  it "decodes as data to exactly its texels" $
    decoded DataImage $ \image → do
      (decodedWidth image, decodedHeight image) `shouldBe` (fromIntegral width, fromIntegral height)
      texels image `shouldBe` straight
  it "decodes as colour to its texels premultiplied in linear light" $
    decoded ColourImage $ \image → do
      (decodedWidth image, decodedHeight image) `shouldBe` (fromIntegral width, fromIntegral height)
      straight `shouldMatchPremultiplied` image
  where
    decoded kind check =
      decodeFixture kind name >>= \case
        Left refusal → expectationFailure ("refused: " <> show refusal)
        Right image → check image

premultipliedFrom ∷ Texel → Texel → IO ()
premultipliedFrom (r, g, b, a) (r', g', b', a') = do
  a' `shouldBe` a
  forM_ [(r, r'), (g, g'), (b, b')] $ \(channel, stored) →
    stored `shouldBeWithinOne` referencePremultiplied a channel

-- | A colour decode holds exactly these straight texels premultiplied: alpha
-- as stated, each channel within one code value of the independent
-- reference, exact where the reference is exact (alpha 0 and 255).
shouldMatchPremultiplied ∷ [Texel] → DecodedImage → Expectation
shouldMatchPremultiplied straight image = do
  length (texels image) `shouldBe` length straight
  zipWithM_ premultipliedFrom straight (texels image)
