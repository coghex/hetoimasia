-- | PNG bytes the composed examples write to a temporary content root, built byte by byte so the real
-- bounded decoder meets real content. Nothing here is a codec: the scanlines are stored unfiltered and
-- compressed by the zlib binding, and the chunks are framed with their own CRC-32.
module Test.LuaEngine.Graphics.Png
  ( rgba8
  , asymmetric
  , asymmetricTexel
  , opaque
  , solid
  ) where

import Codec.Compression.Zlib (compress)
import Data.Array (Array, listArray, (!))
import Data.Bits (complement, shiftR, xor, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import Data.Word (Word32, Word8)

-- | A static RGBA8 image from a texel function.
rgba8 ∷ Int → Int → (Int → Int → (Word8, Word8, Word8, Word8)) → ByteString
rgba8 width height texel = png width height idat
  where
    idat =
      Lazy.toStrict . compress . Lazy.fromStrict . ByteString.concat $
        [ ByteString.pack (0 : concat [[r, g, b, a] | x ← [0 .. width - 1], let (r, g, b, a) = texel x y])
        | y ← [0 .. height - 1]
        ]

-- | An image of one colour, built a row at a time: the largest legal image (2,048 by 2,048) in a fraction
-- of a second and a few kilobytes on disk.
solid ∷ Int → Int → (Word8, Word8, Word8, Word8) → ByteString
solid width height (r, g, b, a) = png width height (Lazy.toStrict (compress (Lazy.fromStrict (ByteString.concat (replicate height row)))))
  where
    row = ByteString.cons 0 (ByteString.concat (replicate width (ByteString.pack [r, g, b, a])))

-- | An image whose every texel is opaque and varies with its position.
opaque ∷ Int → Int → ByteString
opaque width height = rgba8 width height (\x y → (fromIntegral (x * 7 + y), fromIntegral (y * 5 + x), fromIntegral (x + y), 255))

-- | A small image that is asymmetric in both axes and in alpha: no flip, rotation or channel swap of it
-- equals itself. Its texel at (x, y), top row first, is 'asymmetricTexel'.
asymmetric ∷ Int → Int → ByteString
asymmetric width height = rgba8 width height (asymmetricTexel width height)

-- | The straight-alpha texel of 'asymmetric' at (x, y): red grows with x, green with y, blue marks the
-- diagonal, and alpha is 255 except the top-right quarter, which is half transparent.
asymmetricTexel ∷ Int → Int → Int → Int → (Word8, Word8, Word8, Word8)
asymmetricTexel width height x y =
  ( fromIntegral (40 + 200 * x `div` max 1 (width - 1))
  , fromIntegral (40 + 200 * y `div` max 1 (height - 1))
  , if x == y then 250 else 20
  , if x >= width `div` 2 && y < height `div` 2 then 128 else 255
  )

-- | A PNG of this size.
png ∷ Int → Int → ByteString → ByteString
png width height compressed =
  ByteString.concat [signature, chunk "IHDR" header, chunk "IDAT" compressed, chunk "IEND" ""]
  where
    header = ByteString.concat [be32 (fromIntegral width), be32 (fromIntegral height), ByteString.pack [8, 6, 0, 0, 0]]

signature ∷ ByteString
signature = ByteString.pack [137, 80, 78, 71, 13, 10, 26, 10]

chunk ∷ ByteString → ByteString → ByteString
chunk name payload =
  ByteString.concat [be32 (fromIntegral (ByteString.length payload)), name, payload, be32 (crc32 (name <> payload))]

be32 ∷ Word32 → ByteString
be32 value = ByteString.pack [fromIntegral (value `shiftR` 24), fromIntegral (value `shiftR` 16), fromIntegral (value `shiftR` 8), fromIntegral value]

crc32 ∷ ByteString → Word32
crc32 = complement . ByteString.foldl' step 0xFFFFFFFF
  where
    step crc byte = (crcTable ! fromIntegral ((crc `xor` fromIntegral byte) .&. 0xFF)) `xor` (crc `shiftR` 8)

crcTable ∷ Array Int Word32
crcTable = listArray (0, 255) [iterate (\c → if c .&. 1 == 1 then 0xEDB88320 `xor` (c `shiftR` 1) else c `shiftR` 1) (fromIntegral n) !! 8 | n ← [0 .. 255 ∷ Int]]
