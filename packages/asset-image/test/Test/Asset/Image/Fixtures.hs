-- | Every committed fixture decodes to the texels written here.
--
-- The expected texels are the fixture script's inputs, restated by hand: the
-- straight (unpremultiplied) RGBA8 values each file holds once a missing alpha
-- becomes 255 and 16-bit components round to nearest. A data decode must
-- return them exactly; a colour decode must return them premultiplied, within
-- one code value of the independent reference, with alpha unchanged.
module Test.Asset.Image.Fixtures (spec) where

import qualified Codec.Picture.Png as JuicyPixels
import Control.Monad (forM_, zipWithM_)
import Data.Either (isRight)
import Data.Word (Word8)
import Hetoimasia.Asset.Image (DecodedImage (..), ImageKind (..))
import Test.Asset.Image.Support (Texel, decodeFixture, fixtureBytes, referencePremultiplied, shouldBeWithinOne, texels)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)

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

grey8 ∷ [Texel]
grey8 = map grey [0, 128, 255, 17, 64, 200]

spec ∷ Spec
spec = describe "Fixtures" $ do
  describe "every colour type at 8 bits and below" $ mapM_ decodesTo colourTypes
  describe "16-bit components round to nearest" $ mapM_ decodesTo sixteenBit
  describe "Adam7 interlacing" $ mapM_ decodesTo interlaced
  describe "chunks that do not change texels" $ mapM_ decodesTo ignoredChunks
  describe "tRNS colour keys" $ mapM_ decodesTo colourKeys
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
      length (texels image) `shouldBe` length straight
      zipWithM_ premultipliedFrom straight (texels image)
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
