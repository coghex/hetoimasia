-- | The lossless PNG writer: its checks against known values, its header,
-- and image data that inflates — stored blocks read back here — to the
-- target's bytes with one unfiltered byte before each row.
module Test.Sample.Sprites.Png (spec) where

import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import Data.Bits (shiftL, (.|.))
import qualified Data.ByteString.Char8 as Char8
import Data.Word (Word32)
import Test.Hspec

import Hetoimasia.Sample.Sprites.Png

spec ∷ Spec
spec = describe "Sprites PNG writer" $ do
  it "computes PNG's CRC-32 and zlib's Adler-32 as their specifications' examples do" $ do
    crc32 (Char8.pack "IEND") `shouldBe` 0xAE426082
    adler32 (Char8.pack "Wikipedia") `shouldBe` 0x11E60398

  it "writes an 8-bit RGBA header, and image data that is every row's bytes unchanged behind a no-filter byte, across several stored blocks" $ do
    let width = 256
        height = 256
        pixels = ByteString.pack [fromIntegral ((i * 7 + i `div` 1024) `mod` 256) | i ← [0 .. width * height * 4 - 1 ∷ Int]]
        png = encodePng width height pixels
    ByteString.take 8 png `shouldBe` ByteString.pack [137, 80, 78, 71, 13, 10, 26, 10]
    let chunks = readChunks (ByteString.drop 8 png)
    map fst chunks `shouldBe` [Char8.pack "IHDR", Char8.pack "IDAT", Char8.pack "IEND"]
    case chunks of
      [(_, header), (_, image), _] → do
        ByteString.unpack header `shouldBe` [0, 0, 1, 0, 0, 0, 1, 0, 8, 6, 0, 0, 0]
        let rows = inflateStored (ByteString.drop 2 image)
            expected = ByteString.concat [ByteString.cons 0 (ByteString.take (width * 4) (ByteString.drop (row * width * 4) pixels)) | row ← [0 .. height - 1]]
        rows `shouldBe` Just expected
        fmap adler32 rows `shouldBe` Just (word32 (ByteString.drop (ByteString.length image - 4) image))
      _ → expectationFailure "expected three chunks"

-- | Every chunk's type and data, each checked against its CRC.
readChunks ∷ ByteString → [(ByteString, ByteString)]
readChunks bytes
  | ByteString.null bytes = []
  | otherwise =
      let size = fromIntegral (word32 bytes)
          kind = ByteString.take 4 (ByteString.drop 4 bytes)
          body = ByteString.take size (ByteString.drop 8 bytes)
          crc = word32 (ByteString.drop (8 + size) bytes)
       in if crc32 (kind <> body) == crc then (kind, body) : readChunks (ByteString.drop (12 + size) bytes) else [(Char8.pack "BAD!", body)]

-- | The data of a run of stored deflate blocks, or 'Nothing' for anything
-- else.
inflateStored ∷ ByteString → Maybe ByteString
inflateStored = go []
  where
    go pieces bytes = case ByteString.unpack (ByteString.take 5 bytes) of
      [final, l0, l1, n0, n1]
        | final <= 1 →
            let size = fromIntegral l0 .|. fromIntegral l1 `shiftL` 8 ∷ Int
                complement' = fromIntegral n0 .|. fromIntegral n1 `shiftL` 8 ∷ Int
                piece = ByteString.take size (ByteString.drop 5 bytes)
                rest = ByteString.drop (5 + size) bytes
             in if size + complement' /= 65535
                  then Nothing
                  else if final == 1 then Just (ByteString.concat (reverse (piece : pieces))) else go (piece : pieces) rest
      _ → Nothing

word32 ∷ ByteString → Word32
word32 bytes = foldl (\acc byte → acc `shiftL` 8 .|. fromIntegral byte) 0 (ByteString.unpack (ByteString.take 4 bytes))
