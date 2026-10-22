-- | Native names: what may be handed to a directory-relative open as one
-- component, and what is refused because it could cross a component boundary.
module Test.Content.Names (spec) where

import qualified Data.ByteString as BS
import Hetoimasia.Content (NameRefusal (..), nativeName, nativeNameBytes)
import Test.Hspec

spec ∷ Spec
spec = do
  describe "refusals" $ do
    it "refuses the empty name" $
      nativeName "" `shouldBe` Left EmptyName
    it "refuses a name carrying NUL, wherever it sits" $ do
      nativeName "a\0b" `shouldBe` Left NulInName
      nativeName "\0" `shouldBe` Left NulInName
    it "refuses a name carrying a separator, wherever it sits" $ do
      nativeName "a/b" `shouldBe` Left SeparatorInName
      nativeName "/a" `shouldBe` Left SeparatorInName
      nativeName "a/" `shouldBe` Left SeparatorInName
      nativeName "/" `shouldBe` Left SeparatorInName
    it "refuses the structural names" $ do
      nativeName "." `shouldBe` Left DotName
      nativeName ".." `shouldBe` Left DotDotName
    it "refuses a name longer than the enumeration buffer" $
      nativeName (BS.replicate 1024 0x61) `shouldBe` Left (NameTooLong 1024)

  describe "acceptance" $ do
    it "accepts ordinary names, dotted names and three dots" $
      mapM_
        (\bytes → fmap nativeNameBytes (nativeName bytes) `shouldBe` Right bytes)
        ["a", "a.b", ".hidden", "...", "a b", "UPPER", "..a", "a.."]
    it "accepts the longest name without altering its bytes" $
      fmap nativeNameBytes (nativeName (BS.replicate 1023 0x61)) `shouldBe` Right (BS.replicate 1023 0x61)
    it "accepts bytes that are not valid UTF-8, losslessly" $ do
      let invalid = BS.pack [0xff, 0xfe, 0x61, 0xc3]
      fmap nativeNameBytes (nativeName invalid) `shouldBe` Right invalid

  describe "diagnostics" $ do
    it "shows a name escaped and never decoded" $ do
      show <$> nativeName (BS.pack [0x61, 0xff, 0x5c]) `shouldBe` Right "a\\xff\\\\"
    it "bounds a shown name and keeps its bytes whole" $ do
      let long = BS.replicate 200 0x61
      fmap (length . show) (nativeName long) `shouldBe` Right 65
      fmap nativeNameBytes (nativeName long) `shouldBe` Right long
