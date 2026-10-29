-- | The title and size rules of a window request, decided before anything is reserved or issued: UTF-8, the
-- 512-byte bound over the encoded title, the Unicode @Cc@ boundaries, and the whole-value dimension bounds with
-- checked conversion. Pure examples; the service is exercised over a port in the other window examples.
module Test.LuaEngine.Graphics.Window.Request (spec) where

import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import Data.Int (Int64)
import Hetoimasia.LuaEngine.Graphics.Window.Request
import Test.Hspec

spec ∷ Spec
spec = describe "window request validation" $ do
  describe "the title" $ do
    it "accepts the empty title, an ASCII title and a multibyte title" $ do
      accepted "" `shouldBe` True
      accepted "tiles" `shouldBe` True
      accepted (Encoding.encodeUtf8 "ウィンドウ ☃ 🪟") `shouldBe` True

    it "bounds the title by its encoded bytes: 512 is accepted and 513 refused, multibyte included" $ do
      accepted (ByteString.replicate 512 0x61) `shouldBe` True
      accepted (ByteString.replicate 513 0x61) `shouldBe` False
      -- 170 three-byte characters are 510 bytes, 171 are 513: the bound counts bytes, not characters.
      accepted (Encoding.encodeUtf8 (Text.replicate 170 "ウ")) `shouldBe` True
      accepted (Encoding.encodeUtf8 (Text.replicate 171 "ウ")) `shouldBe` False
      windowRequest (ByteString.replicate 513 0x61) 1 1 `shouldBe` Left (TitleTooLong 513)

    it "refuses bytes that are not UTF-8, and checks that before the control rule" $ do
      windowRequest (ByteString.pack [0xFF, 0xFE]) 1 1 `shouldBe` Left TitleNotUtf8
      -- A truncated three-byte sequence and an overlong NUL are not UTF-8 either.
      windowRequest (ByteString.pack [0xE3, 0x82]) 1 1 `shouldBe` Left TitleNotUtf8
      windowRequest (ByteString.pack [0xC0, 0x80]) 1 1 `shouldBe` Left TitleNotUtf8

    it "refuses every Unicode Cc character at its boundaries: C0, DEL and C1" $ do
      mapM_ (\c → refusedControl (Text.singleton (toEnum c))) ([0x00 .. 0x1F] <> [0x7F] <> [0x80 .. 0x9F])
      -- Their neighbours are ordinary characters.
      mapM_ (\c → accepted (Encoding.encodeUtf8 (Text.singleton (toEnum c))) `shouldBe` True) [0x20, 0x7E, 0xA0, 0xA1]
      refusedControl "a\NULb"
      refusedControl "line\nbreak"

  describe "the size" $ do
    it "accepts whole values from 1 to 4096 and refuses 0, 4097 and negatives" $ do
      mapM_ (\n → sized n n `shouldSatisfy` isRight') [1, 2, 640, 4096]
      sized 0 480 `shouldBe` Left (WidthOutOfRange 0)
      sized 640 0 `shouldBe` Left (HeightOutOfRange 0)
      sized 4097 480 `shouldBe` Left (WidthOutOfRange 4097)
      sized 640 4097 `shouldBe` Left (HeightOutOfRange 4097)
      sized (-1) 480 `shouldBe` Left (WidthOutOfRange (-1))
      sized 640 (-4096) `shouldBe` Left (HeightOutOfRange (-4096))

    it "never wraps or clamps a value beyond Int32 or Int64: it is refused whole" $ do
      let beyond32 = fromIntegral (maxBound ∷ Int) + 1 ∷ Int64
      mapM_
        (\n → sized n 480 `shouldBe` Left (WidthOutOfRange n))
        [2 ^ (31 ∷ Int), 2 ^ (32 ∷ Int) + 640, 2 ^ (32 ∷ Int) + 1, maxBound, minBound, beyond32 - 1]
      mapM_ (\n → sized 640 n `shouldBe` Left (HeightOutOfRange n)) [2 ^ (31 ∷ Int), maxBound, minBound]

    it "keeps the accepted request's values exact" $
      case windowRequest "t" 1 4096 of
        Right request → (requestTitle request, requestWidth request, requestHeight request) `shouldBe` ("t", 1, 4096)
        Left refused → expectationFailure (show refused)

  it "states each refusal without echoing the title" $ do
    refusalText (TitleControl 3) `shouldSatisfy` (not . Text.isInfixOf "secret")
    refusalText TitleNotUtf8 `shouldBe` "window title is not valid UTF-8"
  where
    accepted bytes = isRight' (windowRequest bytes 640 480)
    sized width height = windowRequest "t" width height
    refusedControl text = case windowRequest (Encoding.encodeUtf8 text) 1 1 of
      Left (TitleControl _) → pure ()
      other → expectationFailure ("expected a control refusal for " <> show text <> ", found " <> show other)
    isRight' = either (const False) (const True)
