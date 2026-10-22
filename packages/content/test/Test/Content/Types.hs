-- | The values the service reports: limits, bounded diagnostics and failure
-- attribution.
module Test.Content.Types (spec) where

import Control.Exception (displayException)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Hetoimasia.Content
import Test.Content.Support (names)
import Test.Hspec

attribution ∷ RootAttribution
attribution = RootAttribution (BC.pack "/launch/path") (Just (NativeIdentity 3 4))

spec ∷ Spec
spec = do
  describe "limits" $ do
    it "accepts positive bounds and refuses zero and negative ones" $ do
      fmap (\l → (limitPathDepth l, limitReadChunk l)) (contentLimits 3 7) `shouldBe` Just (3, 7)
      fmap limitPathDepth (contentLimits 0 7) `shouldBe` Nothing
      fmap limitPathDepth (contentLimits 3 0) `shouldBe` Nothing
      fmap limitPathDepth (contentLimits (-1) (-1)) `shouldBe` Nothing
    it "names defaults of sixty-four levels and one mebibyte" $ do
      limitPathDepth defaultContentLimits `shouldBe` 64
      limitReadChunk defaultContentLimits `shouldBe` 1048576

  describe "failures" $ do
    it "attribute a failure to the launch path, the identity and the path, without loss" $ do
      let long = replicate 40 (BS.replicate 300 0xff)
          failure' = ContentFailure attribution (names long) NotFound
      failurePath failure' `shouldBe` names long
      attributedSelection (failureRoot failure') `shouldBe` BC.pack "/launch/path"
      attributedIdentity (failureRoot failure') `shouldBe` Just (NativeIdentity 3 4)

    it "render a bounded diagnostic however long the path and names are" $ do
      let long = replicate 200 (BS.replicate 300 0xff)
          rendered = displayException (ContentFailure attribution (names long) ForbiddenLink)
      length rendered `shouldSatisfy` (< 2500)
      rendered `shouldContain` "184 more"
      rendered `shouldContain` "\\xff"

    it "render the class of failure, so a caller can also read it from the text" $ do
      displayException (ContentFailure attribution (names ["a"]) ForbiddenLink) `shouldContain` "symbolic link"
      displayException (ContentFailure attribution (names ["a"]) (DirectoryCycle (names ["a", "b"]) 1)) `shouldContain` "cycle"
      displayException (ContentFailure attribution (names ["a"]) (Unsupported 38)) `shouldContain` "unsupported"
