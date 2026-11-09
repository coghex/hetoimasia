-- | TRA-17: the terrain's texel-index rule (owner amendment v2, 1/128 texel), evaluated exactly.
module Test.TerrainRender2D.TexelRule (spec) where

import Data.Ratio ((%))
import Hetoimasia.Terrain.Render2D.TexelRule
import Test.Hspec

spec ∷ Spec
spec = describe "TRA-17 the texel rule" $ do
  it "is min (n - 1) (floor (clamp u 0 1 * n + 1/128)), with the bias named once" $ do
    texelBias `shouldBe` 1 % 128
    texelIndexExact 4 0 `shouldBe` 0
    texelIndexExact 4 1 `shouldBe` 3
    texelIndexExact 4 5 `shouldBe` 3
    texelIndexExact 4 (-2) `shouldBe` 0
  it "keeps the lower texel only below 1/4 - 1/512 = 127/512 of a four-texel region, exactly" $ do
    texelIndexExact 4 (127 % 512 - 1 % 1000000000) `shouldBe` 0
    texelIndexExact 4 (127 % 512) `shouldBe` 1
    texelIndex 4 (127 / 512 - 1.0e-9) `shouldBe` Just 0
    texelIndex 4 (127 / 512) `shouldBe` Just 1
  it "selects the higher texel at every interior boundary, even where the nearest Double lies below it" $
    mapM_
      (\(n, k) → texelIndex n (fromRational (toInteger k % toInteger n)) `shouldBe` Just k)
      [(n, k) | n ← [3, 7, 64, 96, 1000], k ← [1 .. n - 1]]
  it "converts the coordinate with toRational before the product: a Double product would round across the threshold" $ do
    -- 0.031168619791666664 x 96 + 1/128 is just below 3 exactly; a Double product + bias rounds up to 3.
    let u = 0.031168619791666664 ∷ Double
    texelIndex 96 u `shouldBe` Just 2
    floor (u * 96 + 1 / 128 ∷ Double) `shouldBe` (3 ∷ Int)
  it "has no texel for a coordinate that is not a number or an extent of zero" $ do
    texelIndex 96 (0 / 0) `shouldBe` Nothing
    texelIndex 0 0.5 `shouldBe` Nothing
  it "gives an unbiased rule only to the negative controls" $ do
    texelIndexWith 0 4 (1 % 4 - 1 % 1000000000) `shouldBe` 0
    texelIndexWith (1 % 10000) 4 (1 % 4 - 1 % 40000) `shouldBe` 1
