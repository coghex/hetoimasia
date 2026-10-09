-- | A lossless PNG writer for the scene3d evidence (GRS-10): 8-bit RGBA, no
-- interlacing, every scanline unfiltered, and the image data in stored
-- (uncompressed) deflate blocks, so the file holds the target's bytes exactly
-- as read back. It declares no colour space and converts nothing: the bytes
-- are the linear target's. It needs no dependency beyond @bytestring@. It is
-- the sprites sample's writer, kept as a copy so that each sample stands on
-- the backend's public interface alone.
module Hetoimasia.Sample.Scene3d.Png
  ( encodePng
  , crc32
  , adler32
  ) where

import Data.Bits (complement, shiftR, xor, (.&.))
import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as Lazy
import Data.Word (Word32, Word8)

-- | A PNG of an image this wide and high from its tightly packed RGBA8 rows,
-- top first.
encodePng ∷ Int → Int → ByteString → ByteString
encodePng width height pixels =
  Lazy.toStrict . Builder.toLazyByteString $
    Builder.byteString (ByteString.pack [137, 80, 78, 71, 13, 10, 26, 10])
      <> chunk "IHDR" (Lazy.toStrict (Builder.toLazyByteString (Builder.word32BE (fromIntegral width) <> Builder.word32BE (fromIntegral height) <> Builder.word8 8 <> Builder.word8 6 <> Builder.word8 0 <> Builder.word8 0 <> Builder.word8 0)))
      <> chunk "IDAT" (zlibStored scanlines)
      <> chunk "IEND" ByteString.empty
  where
    stride = width * 4
    scanlines = ByteString.concat [ByteString.cons 0 (ByteString.take stride (ByteString.drop (row * stride) pixels)) | row ← [0 .. height - 1]]

-- | One chunk: its length, type, data, and the CRC of its type and data.
chunk ∷ ByteString → ByteString → Builder.Builder
chunk kind body =
  Builder.word32BE (fromIntegral (ByteString.length body))
    <> Builder.byteString kind
    <> Builder.byteString body
    <> Builder.word32BE (crc32 (kind <> body))

-- | A zlib stream of stored deflate blocks of at most 65,535 bytes each,
-- with its Adler-32 check.
zlibStored ∷ ByteString → ByteString
zlibStored bytes =
  Lazy.toStrict . Builder.toLazyByteString $
    Builder.word8 0x78
      <> Builder.word8 0x01
      <> blocks bytes
      <> Builder.word32BE (adler32 bytes)
  where
    blocks remaining
      | ByteString.length remaining <= 65535 = block True remaining
      | otherwise = let (first, rest) = ByteString.splitAt 65535 remaining in block False first <> blocks rest
    block final piece =
      let size = fromIntegral (ByteString.length piece)
       in Builder.word8 (if final then 1 else 0)
            <> Builder.word16LE size
            <> Builder.word16LE (complement size)
            <> Builder.byteString piece

-- | The CRC-32 PNG chunks carry (ISO 3309, reflected polynomial
-- 0xEDB88320).
crc32 ∷ ByteString → Word32
crc32 = complement . ByteString.foldl' step 0xFFFFFFFF
  where
    step crc byte = foldl' (\c _ → if c .&. 1 == 1 then (c `shiftR` 1) `xor` 0xEDB88320 else c `shiftR` 1) (crc `xor` fromIntegral (byte ∷ Word8)) [1 .. 8 ∷ Int]

-- | The Adler-32 check a zlib stream ends with.
adler32 ∷ ByteString → Word32
adler32 = (\(a, b) → b * 65536 + a) . ByteString.foldl' (\(a, b) byte → let a' = (a + fromIntegral byte) `mod` 65521 in (a', (b + a') `mod` 65521)) (1, 0)
