-- | Checked regions over one parent's shared coverage (TRA-17).
--
-- Every expectation is stated by hand. The parent planes are built from a stated bit rule
-- through the generic 'buildBinaryCoverage', and each expected texel, index and refusal is
-- worked out in a comment beside it, never computed with the helper being tested.
module Test.Asset.Image.Region (spec) where

import qualified Data.ByteString as ByteString
import Data.Either (isLeft)
import Data.Ratio ((%))
import Data.Word (Word32)
import Hetoimasia.Asset.Image.DataMap (CoveragePlane, buildBinaryCoverage, coverageSample)
import Hetoimasia.Asset.Image.Region
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "Region" $ do
  rectangleSpec
  viewSpec
  samplingSpec
  identitySpec

-- | A parent of the given extent whose texel (x, y) is covered exactly when the rule says so.
plane ∷ Word32 → Word32 → (Word32 → Word32 → Bool) → CoveragePlane
plane w h rule = either (error . show) id (buildBinaryCoverage w h bytes)
  where
    bytes = ByteString.pack (concat [[0, 0, 0, if rule x y then 255 else 0] | y ← [0 .. h - 1], x ← [0 .. w - 1]])

-- | An 8 x 4 parent whose odd columns are covered: columns 1, 3, 5 and 7.
stripes ∷ CoveragePlane
stripes = plane 8 4 (\x _ → odd x)

region ∷ Word32 → Word32 → Word32 → Word32 → ImageRegion
region x y w h = either (error . show) id (mkImageRegion x y w h)

view ∷ ImageRegion → RegionView
view r = either (error . show) id (mkRegionView 7 0 stripes r)

rectangleSpec ∷ Spec
rectangleSpec = describe "rectangles" $ do
  it "refuses a zero width or height, naming the extent" $ do
    mkImageRegion 0 0 0 4 `shouldBe` Left (RegionEmpty 0 4)
    mkImageRegion 0 0 4 0 `shouldBe` Left (RegionEmpty 4 0)
  it "refuses a far edge that does not fit 32 bits and accepts the last representable one" $ do
    -- 4294967295 + 1 = 4294967296 exceeds 32 bits; 4294967294 + 1 = 4294967295 does not.
    mkImageRegion 4294967295 0 1 1 `shouldBe` Left (RegionOverflow 4294967295 0 1 1)
    mkImageRegion 0 4294967295 1 2 `shouldBe` Left (RegionOverflow 0 4294967295 1 2)
    mkImageRegion 4294967294 0 1 1 `shouldSatisfy` either (const False) (const True)
  it "reports the extent and origin it holds" $ do
    let r = region 3 2 5 7
    (regionOriginX r, regionOriginY r, regionWidth r, regionHeight r) `shouldBe` (3, 2, 5, 7)
  it "states a refusal as text" $ regionRefusalText (RegionEmpty 0 1) `shouldBe` "a region needs a positive extent, not 0 x 1"

viewSpec ∷ Spec
viewSpec = describe "views" $ do
  it "accepts a rectangle that exactly fills the parent and one in a corner" $ do
    mkRegionView 1 0 stripes (region 0 0 8 4) `shouldSatisfy` either (const False) (const True)
    -- (6, 2) + (2, 2) = (8, 4): the last texel is (7, 3), inside the 8 x 4 parent.
    mkRegionView 1 0 stripes (region 6 2 2 2) `shouldSatisfy` either (const False) (const True)
  it "refuses a rectangle that leaves the parent on either axis" $ do
    -- (7, 0) + (2, 1) reaches column 8; (0, 3) + (1, 2) reaches row 4.
    mkRegionView 1 0 stripes (region 7 0 2 1) `shouldBe` Left (RegionOutOfBounds (region 7 0 2 1) 8 4)
    mkRegionView 1 0 stripes (region 0 3 1 2) `shouldBe` Left (RegionOutOfBounds (region 0 3 1 2) 8 4)
    mkRegionView 1 0 stripes (region 8 0 1 1) `shouldSatisfy` isLeft
  it "refuses a rectangle whose far edge would wrap in 32 bits instead of accepting a wrapped one" $
    -- origin 4294967294 + width 1 is representable, and far outside the 8 x 4 parent.
    mkRegionView 1 0 stripes (region 4294967294 0 1 1) `shouldSatisfy` isLeft
  it "makes the whole-image view of a plane with origin zero and the plane's extent" $
    case fullImageView 9 stripes of
      Left refusal → expectationFailure (show refusal)
      Right whole → do
        (regionOriginX (regionViewRegion whole), regionOriginY (regionViewRegion whole)) `shouldBe` (0, 0)
        (regionWidth (regionViewRegion whole), regionHeight (regionViewRegion whole)) `shouldBe` (8, 4)
        regionViewParentVersion whole `shouldBe` 9
        regionViewLayout whole `shouldBe` 0
        regionViewParentExtent whole `shouldBe` (8, 4)
  it "holds the parent plane itself, so a region carries no plane of its own" $
    regionViewParent (view (region 1 0 4 4)) `shouldBe` stripes

samplingSpec ∷ Spec
samplingSpec = describe "sampling" $ do
  -- The region (1, 0, 4, 4) reads parent columns 1..4 at local indices 0..3. The parent covers
  -- odd columns, so local index i is covered exactly when 1 + i is odd, that is, when i is even:
  -- local 0 yes, 1 no, 2 yes, 3 no.
  let r = view (region 1 0 4 4)
  it "adds the origin after the local index and never reads a neighbouring region" $ do
    mapM (\i → regionViewCoverageAt r i 0) [0 .. 3] `shouldBe` Just [True, False, True, False]
    -- Local index 4 is outside the 4-wide region, though parent column 5 (covered) exists.
    regionViewCoverageAt r 4 0 `shouldBe` Nothing
    regionViewCoverageAt r 0 4 `shouldBe` Nothing
  it "selects the higher texel on an interior boundary and the last texel on the outer edge" $ do
    -- u = 0 -> i 0; u = 0.25 is the boundary between texels 0 and 1 of 4 -> i 1 (higher);
    -- u = 0.5 -> i 2; u = 0.75 -> i 3; u = 1 -> i 3, the last, parent column 4 (uncovered), and
    -- not parent column 5, which belongs to no texel of the region.
    map (\u → regionViewCoverageSample r u 0) [0, 0.25, 0.5, 0.75, 1] `shouldBe` map Just [True, False, True, False, False]
    -- More than the bias below the boundary the lower texel is selected: 0.2499 -> i 0 (covered).
    regionViewCoverageSample r 0.2499 0 `shouldBe` Just True
  it "selects the higher texel within the bias below an interior boundary, the lower beyond it" $ do
    -- The rule: i = min (w - 1) (floor (clamp u 0 1 × w + 1/10000)). The bias is 1/10000 of a texel,
    -- so for 4 texels the lower texel is kept only below 1/4 - 1/40000 = 0.249975 exactly.
    texelBias `shouldBe` 1 % 10000
    texelIndex 4 0.2499749999 `shouldBe` Just 0
    texelIndex 4 0.2499750001 `shouldBe` Just 1
    texelIndexExact 4 (1 % 4 - 1 % 40000) `shouldBe` 1 -- exactly on the bias: floor 1
    texelIndexExact 4 (1 % 4 - 1 % 40000 - 1 % 1000000000) `shouldBe` 0
  it "selects the higher texel at every interior boundary even where the nearest Double lies below it" $
    mapM_
      ( \(n, k) →
          texelIndex n (fromRational (toInteger k % toInteger n)) `shouldBe` Just k
      )
      [(n, k) | n ← [3, 7, 64, 96, 1000], k ← [1 .. n - 1]]
  it "keeps the outer edge on the last texel and the origin edge on the first" $ do
    texelIndex 96 1 `shouldBe` Just 95
    texelIndex 96 0 `shouldBe` Just 0
    texelIndex 96 (-0.00001) `shouldBe` Just 0
    texelIndex 1 1 `shouldBe` Just 0
    texelIndex 0 0.5 `shouldBe` Nothing
  it "clamps coordinates outside the unit square to the region's edge texels" $ do
    regionViewCoverageSample r (-3) 0 `shouldBe` Just True
    regionViewCoverageSample r 3 0 `shouldBe` Just False
  it "has no texel for a coordinate that is not a number" $ do
    regionViewCoverageSample r (0 / 0) 0 `shouldBe` Nothing
    regionViewCoverageSample r 0 (0 / 0) `shouldBe` Nothing
  it "reads like the plain plane sampler for a whole-image view" $
    case fullImageView 1 stripes of
      Left refusal → expectationFailure (show refusal)
      Right whole →
        mapM_
          (\(u, v) → regionViewCoverageSample whole u v `shouldBe` coverageSample stripes u v)
          [(u, v) | u ← [0, 0.12, 0.125, 0.5, 0.875, 1], v ← [0, 0.25, 0.9, 1]]
  it "localises the index to the region's own extent, not the parent's" $
    -- A 2-wide region at column 6: local 0 -> parent 6 (uncovered), local 1 -> parent 7 (covered).
    map (\u → regionViewCoverageSample (view (region 6 0 2 4)) u 0) [0, 0.49, 0.5, 1] `shouldBe` map Just [False, False, True, True]

identitySpec ∷ Spec
identitySpec = describe "identity" $ do
  let base = view (region 1 0 4 4)
  it "is equal for the same rectangle of the same parent version and layout" $
    regionViewIdentity base `shouldBe` regionViewIdentity (view (region 1 0 4 4))
  it "changes when only the rectangle changes on the same parent" $ do
    regionViewIdentity base `shouldSatisfy` (/= regionViewIdentity (view (region 2 0 4 4)))
    regionViewIdentity base `shouldSatisfy` (/= regionViewIdentity (view (region 1 1 4 3)))
    regionViewIdentity base `shouldSatisfy` (/= regionViewIdentity (view (region 1 0 3 4)))
  it "changes with the parent version, the layout identity and the parent extent" $ do
    let other version layout p = either (error . show) id (mkRegionView version layout p (region 1 0 4 4))
    regionViewIdentity base `shouldSatisfy` (/= regionViewIdentity (other 8 0 stripes))
    regionViewIdentity base `shouldSatisfy` (/= regionViewIdentity (other 7 1 stripes))
    regionViewIdentity base `shouldSatisfy` (/= regionViewIdentity (other 7 0 (plane 9 4 (\x _ → odd x))))
