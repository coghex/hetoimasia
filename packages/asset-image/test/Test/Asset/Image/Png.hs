-- | The shape of a decoded image for the upload endpoint, the cutout mark,
-- determinism, and the decoder interface.
module Test.Asset.Image.Png (spec) where

import qualified Data.ByteString as ByteString
import Hetoimasia.Asset (Decoder (..))
import Hetoimasia.Asset.Image (DecodedImage (..), ImageKind (..), TexelFormat (..))
import Hetoimasia.Asset.Image.Png (decodePng, pngDecoder)
import Test.Asset.Image.Support (decodeFixture, fixtureAsset, fixtureBytes)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)

spec ∷ Spec
spec = describe "PNG" $ do
  describe "the format and level layout" $ do
    it "is the sRGB RGBA8 format for a colour image" $
      decoded ColourImage "rgba8.png" $ \image → decodedFormat image `shouldBe` TexelRgba8Srgb
    it "is the linear RGBA8 format for a data image" $
      decoded DataImage "rgba8.png" $ \image → decodedFormat image `shouldBe` TexelRgba8Linear
    it "is one level of width × height × 4 bytes, for either kind" $
      mapM_
        ( \kind → decoded kind "interlaced-rgba8.png" $ \image → do
            (decodedWidth image, decodedHeight image) `shouldBe` (5, 5)
            map ByteString.length (decodedLevels image) `shouldBe` [5 * 5 * 4]
        )
        [ColourImage, DataImage]
    it "holds rows top row first with no padding between them" $
      -- grey8.png's rows are 0 128 255 / 17 64 200: three texels each, and
      -- the second row begins at byte 12.
      decoded DataImage "grey8.png" $ \image →
        decodedLevels image
          `shouldBe` [ByteString.pack (concatMap (\y → [y, y, y, 255]) [0, 128, 255, 17, 64, 200])]

  describe "the cutout mark" $ do
    let marks kind name expected = decoded kind name $ \image → decodedBinaryAlpha image `shouldBe` expected
    it "is true when every alpha is 0 or 255" $ mapM_ (\kind → marks kind "alpha-binary.png" True) [ColourImage, DataImage]
    it "is true for an image without an alpha channel" $ mapM_ (\kind → marks kind "rgb8.png" True) [ColourImage, DataImage]
    it "is false when one texel holds alpha 1" $ mapM_ (\kind → marks kind "alpha-one.png" False) [ColourImage, DataImage]
    it "is false when one texel holds alpha 254" $ mapM_ (\kind → marks kind "alpha-254.png" False) [ColourImage, DataImage]
    it "is false for 16-bit alpha that rounds to 1" $ mapM_ (\kind → marks kind "grey-alpha16.png" False) [ColourImage, DataImage]

  describe "determinism" $
    it "gives the same result for the same bytes and kind" $
      mapM_
        ( \(kind, name) → do
            bytes ← fixtureBytes name
            decodePng kind (fixtureAsset name) bytes `shouldBe` decodePng kind (fixtureAsset name) (ByteString.copy bytes)
        )
        [(kind, name) | kind ← [ColourImage, DataImage], name ← ["rgba8.png", "palette-trns.png", "corrupt-stream.png"]]

  describe "the decoder interface" $
    it "runs the same decode as decodePng" $
      mapM_
        ( \kind → do
            bytes ← fixtureBytes "rgba16.png"
            runDecoder (pngDecoder kind) (fixtureAsset "rgba16.png") bytes `shouldBe` decodePng kind (fixtureAsset "rgba16.png") bytes
        )
        [ColourImage, DataImage]
  where
    decoded kind name check =
      decodeFixture kind name >>= \case
        Left refusal → expectationFailure ("refused: " <> show refusal)
        Right image → check image
