-- | The loader selection, exercised headlessly: the decision is pure, and the
-- native run makes it over the image its own entry point resolved into.
module Test.Vulkan.Proof.LoaderSpec (spec) where

import qualified Data.Text as Text
import Test.Hspec

import Test.Vulkan.Proof.Loader

spec ∷ Spec
spec = describe "The loaded Vulkan loader" $ do
  it "accepts the recorded loader" $
    loaderSelection (Just "/prefix/lib/libvulkan.so.1.3.275") (Just "/prefix/lib/libvulkan.so.1.3.275")
      `shouldBe` Right "/prefix/lib/libvulkan.so.1.3.275"

  it "refuses an alternate loader found ahead of it on the search path, naming both" $
    case loaderSelection (Just "/prefix/lib/libvulkan.so.1.3.275") (Just "/elsewhere/libvulkan.so.1") of
      Left reason → do
        reason `shouldSatisfy` Text.isInfixOf "/elsewhere/libvulkan.so.1"
        reason `shouldSatisfy` Text.isInfixOf "not the recorded loader /prefix/lib/libvulkan.so.1.3.275"
      Right loaded → expectationFailure ("accepted " <> loaded)

  it "refuses a run whose runner named no recorded loader" $
    loaderSelection Nothing (Just "/prefix/lib/libvulkan.so.1.3.275") `shouldSatisfy` either (const True) (const False)

  it "refuses an entry point attributed to no image" $
    loaderSelection (Just "/prefix/lib/libvulkan.so.1.3.275") Nothing `shouldSatisfy` either (const True) (const False)
