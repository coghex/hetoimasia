-- | The asset-image package's component specs, composed under one
-- @AssetImage@ group.
module Test.Asset.Image.Spec (spec) where

import qualified Test.Asset.Image.Bc7 as Bc7
import qualified Test.Asset.Image.Bc7Opacity as Bc7Opacity
import qualified Test.Asset.Image.Fixtures as Fixtures
import qualified Test.Asset.Image.Mips as Mips
import qualified Test.Asset.Image.Png as Png
import qualified Test.Asset.Image.Premultiply as Premultiply
import qualified Test.Asset.Image.Refusals as Refusals
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "AssetImage" $ do
  Fixtures.spec
  Premultiply.spec
  Png.spec
  Refusals.spec
  Bc7.spec
  Bc7Opacity.spec
  Mips.spec
