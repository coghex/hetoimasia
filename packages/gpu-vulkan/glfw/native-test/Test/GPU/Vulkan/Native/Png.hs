-- | A minimal PNG encoder for the native cases' offscreen readbacks (GRS-5):
-- 8-bit RGBA, no filtering, and the image data in stored — uncompressed —
-- deflate blocks, so no compression library is needed. What it writes is for
-- a person to look at; nothing reads it back and nothing is committed.
module Test.GPU.Vulkan.Native.Png
  ( encodeRgba
  ) where

import Data.Bits (complement, shiftL, shiftR, xor, (.&.), (.|.))
import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as Builder
import qualified Data.ByteString.Lazy as Lazy
import Data.Word (Word32, Word8)

-- | A PNG of this width and height from tightly packed RGBA rows, top first.
encodeRgba ∷ Int → Int → ByteString → ByteString
encodeRgba width height pixels =
  ByteString.concat
    [ ByteString.pack [137, 80, 78, 71, 13, 10, 26, 10]
    , chunk "IHDR" (built (word32 (fromIntegral width) <> word32 (fromIntegral height) <> Builder.word8 8 <> Builder.word8 6 <> Builder.word8 0 <> Builder.word8 0 <> Builder.word8 0))
    , chunk "IDAT" (zlibStored raw)
    , chunk "IEND" ByteString.empty
    ]
  where
    stride = width * 4
    -- Each row is preceded by its filter type, none.
    raw = ByteString.concat [ByteString.cons 0 (ByteString.take stride (ByteString.drop (row * stride) pixels)) | row ← [0 .. height - 1]]

chunk ∷ ByteString → ByteString → ByteString
chunk kind body = built (word32 (fromIntegral (ByteString.length body)) <> Builder.byteString kind <> Builder.byteString body <> word32 (crc32 (kind <> body)))

-- | A zlib stream of stored deflate blocks, at most 65535 bytes each.
zlibStored ∷ ByteString → ByteString
zlibStored bytes = built (Builder.word8 0x78 <> Builder.word8 0x01 <> blocks bytes <> word32 (adler32 bytes))
  where
    blocks remaining
      | ByteString.length remaining <= 65535 = block True remaining
      | otherwise = block False (ByteString.take 65535 remaining) <> blocks (ByteString.drop 65535 remaining)
    block final piece =
      let size = fromIntegral (ByteString.length piece) ∷ Word32
       in Builder.word8 (if final then 1 else 0)
            <> Builder.word16LE (fromIntegral size)
            <> Builder.word16LE (fromIntegral (complement size .&. 0xFFFF))
            <> Builder.byteString piece

crc32 ∷ ByteString → Word32
crc32 = complement . ByteString.foldl' step 0xFFFFFFFF
  where
    step crc byte = foldl' (\current _ → if current .&. 1 == 1 then (current `shiftR` 1) `xor` 0xEDB88320 else current `shiftR` 1) (crc `xor` fromIntegral byte) [1 ∷ Int .. 8]

adler32 ∷ ByteString → Word32
adler32 bytes = (b `shiftL` 16) .|. a
  where
    (a, b) = ByteString.foldl' step (1, 0) bytes
    step (low, high) byte = let low' = (low + fromIntegral (byte ∷ Word8)) `mod` 65521 in (low', (high + low') `mod` 65521)

word32 ∷ Word32 → Builder.Builder
word32 = Builder.word32BE

built ∷ Builder.Builder → ByteString
built = Lazy.toStrict . Builder.toLazyByteString
