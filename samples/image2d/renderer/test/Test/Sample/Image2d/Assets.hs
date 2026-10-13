-- | The committed images against the tables that restate them (R2D-8): each
-- decodes with @asset-image@ to the extent, levels, format and alpha mark the
-- sample's README records, and its level-0 texels are the ones its region
-- table gives.
--
-- The expected texels come from "Hetoimasia.Sample.Image2d.Fixtures" and, for
-- the one image with translucent texels, from premultiplication worked out
-- here in 'Double' with the sRGB transfer function of IEC 61966-2-1, never
-- from the decoder.
module Test.Sample.Image2d.Assets (spec) where

import qualified Data.ByteString as ByteString
import Data.Word (Word8)
import Hetoimasia.Asset.Image (DecodedImage (..), TexelFormat (..))
import Hetoimasia.Sample.Image2d.Assets
import Hetoimasia.Sample.Image2d.Fixtures
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "the committed images" $ do
  mapM_ imageSpec allImages

  it "embeds a PNG's signature and a KTX2 file's identifier" $ do
    ByteString.take 8 (embeddedBytes Quadrants) `shouldBe` ByteString.pack [137, 80, 78, 71, 13, 10, 26, 10]
    ByteString.take 8 (embeddedBytes Fade) `shouldBe` ByteString.pack [137, 80, 78, 71, 13, 10, 26, 10]
    ByteString.take 12 (embeddedBytes Stripes) `shouldBe` ByteString.pack [0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A]

  it "has region tables that cover every texel, so none is transparent black by default" $
    mapM_
      ( \name → do
          let image = fixture name
          [texel | x ← [0 .. fromIntegral (fixtureWidth image) - 1], y ← [0 .. fromIntegral (fixtureHeight image) - 1], let texel = texelAt image (x, y), texel == Colour 0 0 0 0]
            `shouldBe` []
      )
      allImages

  it "maps a texel format to the upload endpoint's the asset package names" $
    map imageFormatOf [TexelRgba8Srgb, TexelRgba8Linear, TexelBc7Srgb, TexelBc7Linear] `shouldSatisfy` ((== 4) . length)

imageSpec ∷ ImageName → Spec
imageSpec name = describe (show name) $ do
  let image = fixture name
  case decodeImage name of
    Left reason → it "decodes" (expectationFailure ("not decoded: " <> show reason))
    Right decoded → do
      it "has the extent, format, level count and alpha mark its README records" $ do
        (decodedWidth decoded, decodedHeight decoded) `shouldBe` (fixtureWidth image, fixtureHeight image)
        decodedFormat decoded `shouldBe` fixtureFormat image
        length (decodedLevels decoded) `shouldBe` fixtureLevels image
        decodedBinaryAlpha decoded `shouldBe` fixtureBinaryAlpha image

      it "stores every level tightly packed, level 0 first" $ do
        let sizes = [max 1 (fromIntegral (decodedWidth decoded) `div` (2 ^ level)) * max 1 (fromIntegral (decodedHeight decoded) `div` (2 ^ level)) * 4 | level ← [0 .. length (decodedLevels decoded) - 1 ∷ Int]]
        map ByteString.length (decodedLevels decoded) `shouldBe` sizes

      it "holds, at level 0, the texels its region table gives, premultiplied in linear light" $ do
        let level0 = ByteString.concat (take 1 (decodedLevels decoded))
            width = fromIntegral (decodedWidth decoded)
            texel (x, y) = let at = (y * width + x) * 4 in map (ByteString.index level0) [at .. at + 3]
            expected = [(x, y, premultiplied (texelAt image (x, y))) | y ← [0 .. fromIntegral (decodedHeight decoded) - 1], x ← [0 .. width - 1]]
            wrong = [(x, y, texel (x, y), want) | (x, y, want) ← expected, not (closeTo 1 (texel (x, y)) want)]
        take 3 wrong `shouldBe` []

-- | The bytes the decoder is contracted to give a straight colour: the colour
-- channels decoded from sRGB to linear light, multiplied by alpha, and encoded
-- again; the alpha unchanged.
premultiplied ∷ Colour → [Word8]
premultiplied (Colour r g b a) = [channel r, channel g, channel b, a]
  where
    alpha = fromIntegral a / 255 ∷ Double
    channel c = round (255 * encode (decode (fromIntegral c / 255) * alpha))
    decode v = if v <= 0.04045 then v / 12.92 else ((v + 0.055) / 1.055) ** 2.4
    encode v = if v <= 0.0031308 then v * 12.92 else 1.055 * v ** (1 / 2.4) - 0.055

closeTo ∷ Int → [Word8] → [Word8] → Bool
closeTo steps one other = and (zipWith (\x y → abs (fromIntegral x - fromIntegral y) <= steps) one other)
