{-# LANGUAGE OverloadedStrings #-}

-- | PNG bytes the texture examples write to a temporary content root, built byte by byte so the
-- real bounded decoder meets real content: a valid static image of any size, one with a
-- chunk corrupted, an animated one and bytes that are no PNG at all.
--
-- Nothing here is a codec. The scanlines are stored unfiltered and compressed by the zlib binding,
-- and the chunks are framed with their own CRC-32.
module Test.LuaEngine.Texture.Png
  ( opaque
  , translucent
  , rgba8
  , animated
  , corruptedData
  , truncatedStream
  , notAPng
  , expectedOpaque
  ) where

import Codec.Compression.Zlib (compress)
import Data.Array (Array, listArray, (!))
import Data.Bits (complement, shiftR, xor, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import Data.Word (Word32, Word8)

-- | The image of this size whose every texel is opaque and varies with its position.
opaque ∷ Int → Int → ByteString
opaque width height = rgba8 width height (\x y → (fromIntegral (x * 7 + y), fromIntegral (y * 5 + x), fromIntegral (x + y), 255))

-- | The image whose every texel is translucent, so the decoder's premultiplication changes it.
translucent ∷ Int → Int → ByteString
translucent width height = rgba8 width height (\x y → (200, fromIntegral (x * 3), fromIntegral (y * 3), 128))

-- | The texel the decoder must produce for an opaque pixel of 'opaque': the same bytes.
expectedOpaque ∷ Int → Int → Int → Int → [Word8]
expectedOpaque _ _ x y = [fromIntegral (x * 7 + y), fromIntegral (y * 5 + x), fromIntegral (x + y), 255]

-- | A static RGBA8 image from a texel function.
rgba8 ∷ Int → Int → (Int → Int → (Word8, Word8, Word8, Word8)) → ByteString
rgba8 width height texel = png width height (idat width height texel) []

idat ∷ Int → Int → (Int → Int → (Word8, Word8, Word8, Word8)) → ByteString
idat width height texel =
  Lazy.toStrict . compress . Lazy.fromStrict . ByteString.concat $
    [ ByteString.pack (0 : concat [[r, g, b, a] | x ← [0 .. width - 1], let (r, g, b, a) = texel x y])
    | y ← [0 .. height - 1]
    ]

-- | A PNG of this size, with the extra chunks placed right after the header.
png ∷ Int → Int → ByteString → [ByteString] → ByteString
png width height compressed extras =
  ByteString.concat $
    [signature, chunk "IHDR" header] <> extras <> [chunk "IDAT" compressed, chunk "IEND" ""]
  where
    header = ByteString.concat [be32 (fromIntegral width), be32 (fromIntegral height), ByteString.pack [8, 6, 0, 0, 0]]

-- | The same image with an animation control chunk before its data, so it is not a static PNG.
animated ∷ Int → Int → ByteString
animated width height =
  png width height (idat width height (\_ _ → (1, 2, 3, 255))) [chunk "acTL" (ByteString.concat [be32 2, be32 0])]

-- | A sound header and a data chunk whose CRC does not match, so the image is invalid.
corruptedData ∷ Int → Int → ByteString
corruptedData width height =
  ByteString.concat
    [ signature
    , chunk "IHDR" (ByteString.concat [be32 (fromIntegral width), be32 (fromIntegral height), ByteString.pack [8, 6, 0, 0, 0]])
    , badCrc (chunk "IDAT" (Lazy.toStrict (compress (Lazy.fromStrict (ByteString.replicate (height * (width * 4 + 1)) 0)))))
    , chunk "IEND" ""
    ]
  where
    badCrc bytes = ByteString.take (ByteString.length bytes - 1) bytes <> ByteString.pack [255 - ByteString.last bytes]

-- | A static image whose compressed data stops half way, so it inflates to fewer bytes than the
-- header needs.
truncatedStream ∷ Int → Int → ByteString
truncatedStream width height =
  png width height (ByteString.take (ByteString.length full `div` 2) full) []
  where
    full = idat width height (\x y → (fromIntegral x, fromIntegral y, 9, 255))

-- | Bytes that begin with no PNG signature.
notAPng ∷ ByteString
notAPng = "this is not a png file, whatever its name says"

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
