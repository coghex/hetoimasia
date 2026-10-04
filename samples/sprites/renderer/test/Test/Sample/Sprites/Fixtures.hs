-- | The sprites fixtures: their extents, formats and bytes, the atlas's
-- regions, and the BC7 block decoded again here, by a mode-6 decoder of the
-- suite's own, to check the oracle 'bc7Decoded' independently of any device.
module Test.Sample.Sprites.Fixtures (spec) where

import Data.Bits (shiftL, shiftR, testBit, (.&.), (.|.))
import qualified Data.ByteString as ByteString
import Data.Word (Word8)
import Test.Hspec

import Hetoimasia.GPU.Vulkan.Native.Recording (ImageFormat (..))
import Hetoimasia.Sample.Sprites.Fixtures

spec ∷ Spec
spec = describe "Sprites fixtures" $ do
  it "are one-level textures of the declared formats and extents, whose bytes are their texels" $ do
    [(fixtureFormat t, fixtureWidth t, fixtureHeight t, ByteString.length (fixtureBytes t)) | t ← [atlasFixture, translucentFixture, bc7Fixture]]
      `shouldBe` [(Rgba8Linear, 8, 8, 256), (Rgba8Linear, 2, 2, 16), (Bc7Linear, 4, 4, 16)]
    ByteString.unpack (ByteString.take 4 (fixtureBytes atlasFixture)) `shouldBe` [255, 0, 0, 255]

  it "lay the atlas out as red, green, blue and yellow regions divided at 0.5, and the translucent texture as premultiplied red and blue columns" $ do
    [texelAt atlasFixture x y | (x, y) ← [(1, 1), (6, 1), (1, 6), (6, 6)]]
      `shouldBe` [Rgba 255 0 0 255, Rgba 0 255 0 255, Rgba 0 0 255 255, Rgba 255 255 0 255]
    [texelAt translucentFixture x y | (x, y) ← [(0, 0), (1, 0), (0, 1), (1, 1)]]
      `shouldBe` [Rgba 128 0 0 128, Rgba 0 0 128 128, Rgba 128 0 0 128, Rgba 0 0 128 128]
    map atlasRegion [minBound .. maxBound] `shouldBe` [UvRect 0 0 0.5 0.5, UvRect 0.5 0 1 0.5, UvRect 0 0.5 0.5 1, UvRect 0.5 0.5 1 1]

  it "decode the BC7 block, by an independent mode-6 decoder, to exactly the retained oracle" $
    decodeMode6 (ByteString.unpack bc7Block) `shouldBe` Just bc7Decoded

-- | A BC7 mode-6 decoder: 7-bit RGBA endpoints with a p-bit each, and
-- 4-bit indices, the first an anchor of 3 bits.
decodeMode6 ∷ [Word8] → Maybe [[Rgba]]
decodeMode6 bytes
  | length bytes /= 16 || take 7 bits /= [False, False, False, False, False, False, True] = Nothing
  | otherwise = Just [[texel (x + 4 * y) | x ← [0 .. 3]] | y ← [0 .. 3]]
  where
    bits = [testBit byte i | byte ← bytes, i ← [0 .. 7]]
    field from count = foldr (\bit acc → acc `shiftL` 1 .|. (if bit then 1 else 0)) 0 (take count (drop from bits)) ∷ Int
    endpoint channel which = field (7 + 14 * channel + 7 * which) 7
    pbit which = field (63 + which) 1
    expand channel which = (endpoint channel which `shiftL` 1) .|. pbit which
    index t = if t == 0 then field 65 3 else field (68 + 4 * (t - 1)) 4
    weights = [0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64]
    texel t =
      let w = weights !! index t
          mixed channel = ((64 - w) * expand channel 0 + w * expand channel 1 + 32) `shiftR` 6
       in case map (fromIntegral . (.&. 255) . mixed) [0 .. 3] of
            [r, g, b, a] → Rgba r g b a
            _ → Rgba 0 0 0 0
