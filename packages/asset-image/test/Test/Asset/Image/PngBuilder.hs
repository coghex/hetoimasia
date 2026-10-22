-- | A PNG byte builder for the preflight examples, independent of the
-- production parser, of JuicyPixels' chunk reader and of its CRC.
--
-- Each defect an example needs is written here byte by byte: the CRC is a
-- bitwise implementation of the PNG specification's Annex D, the zlib streams
-- come from the @zlib@ package's compressor or are spelled out as stored
-- blocks, and the expected scanline sizes are counted pixel by pixel instead
-- of derived from the formula the production code uses.
module Test.Asset.Image.PngBuilder
  ( Header (..)
  , header
  , signature
  , chunk
  , chunkBadCrc
  , chunkWithLength
  , assemble
  , ihdrChunk
  , zlibOf
  , zeros
  , storedStream
  , invalidBlock
  , splitEvery
  , idatChunks
  , imagePng
  , imagePngWith
  , expectedScanlineBytes
  , crc32
  )
where

import qualified Codec.Compression.Zlib as Zlib
import Data.Bits (complement, shiftR, testBit, xor, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import Data.Word (Word32, Word8)

-- | An IHDR chunk's fields, as bytes.
data Header = Header
  { hWidth ∷ Word32
  , hHeight ∷ Word32
  , hDepth ∷ Word8
  , hColour ∷ Word8
  , hCompression ∷ Word8
  , hFilter ∷ Word8
  , hInterlace ∷ Word8
  }

-- | A header with the given extent, depth and colour type code, and every
-- method byte zero.
header ∷ Word32 → Word32 → Word8 → Word8 → Header
header w h depth colour = Header w h depth colour 0 0 0

signature ∷ ByteString
signature = ByteString.pack [137, 80, 78, 71, 13, 10, 26, 10]

-- | The PNG specification's CRC-32 over a chunk's type and data.
crc32 ∷ ByteString → Word32
crc32 = complement . ByteString.foldl' byteStep 0xffffffff
  where
    byteStep crc byte = iterate bitStep (crc `xor` fromIntegral byte) !! 8
    bitStep crc = if testBit crc 0 then 0xedb88320 `xor` (crc `shiftR` 1) else crc `shiftR` 1

be32 ∷ Word32 → ByteString
be32 n = ByteString.pack [fromIntegral (n `shiftR` s .&. 255) | s ← [24, 16, 8, 0]]

-- | A chunk of the given type and data, length and CRC correct.
chunk ∷ ByteString → ByteString → ByteString
chunk kind body = be32 (fromIntegral (ByteString.length body)) <> kind <> body <> be32 (crc32 (kind <> body))

-- | A chunk whose stored CRC is wrong.
chunkBadCrc ∷ ByteString → ByteString → ByteString
chunkBadCrc kind body = be32 (fromIntegral (ByteString.length body)) <> kind <> body <> be32 (crc32 (kind <> body) `xor` 1)

-- | A chunk that declares a length unrelated to its data, with a CRC of what
-- it actually holds.
chunkWithLength ∷ Word32 → ByteString → ByteString → ByteString
chunkWithLength declared kind body = be32 declared <> kind <> body <> be32 (crc32 (kind <> body))

ihdrChunk ∷ Header → ByteString
ihdrChunk h =
  chunk "IHDR" (be32 (hWidth h) <> be32 (hHeight h) <> ByteString.pack [hDepth h, hColour h, hCompression h, hFilter h, hInterlace h])

assemble ∷ [ByteString] → ByteString
assemble = mconcat . (signature :)

-- | A zlib stream of the bytes.
zlibOf ∷ Lazy.ByteString → ByteString
zlibOf = Lazy.toStrict . Zlib.compress

-- | @n@ zero bytes, lazily, so a large count is never held whole.
zeros ∷ Int → Lazy.ByteString
zeros = flip Lazy.replicate 0 . fromIntegral

-- | A zlib stream of stored (uncompressed) deflate blocks, spelled out byte
-- by byte: the header @78 01@, then each block as @00@ (not final, stored),
-- its length, the complement of its length and its bytes, then the bytes
-- given last. The stream ends with whatever the last argument says, so a
-- caller can end it with 'invalidBlock' or leave it unfinished.
storedStream ∷ [Int] → ByteString → ByteString
storedStream blocks ending = ByteString.pack [0x78, 0x01] <> mconcat (map block blocks) <> ending
  where
    block n = ByteString.pack [0x00, fromIntegral (n .&. 255), fromIntegral (n `shiftR` 8), complement (fromIntegral (n .&. 255)), complement (fromIntegral (n `shiftR` 8))] <> ByteString.replicate n 0

-- | A deflate block header with the reserved block type 3 (not final): the
-- inflater rejects it as soon as it reads it.
invalidBlock ∷ ByteString
invalidBlock = ByteString.singleton 0x06

splitEvery ∷ Int → ByteString → [ByteString]
splitEvery n bytes
  | ByteString.null bytes = []
  | otherwise = let (a, b) = ByteString.splitAt n bytes in a : splitEvery n b

-- | The IDAT chunks of a stream split into pieces of the given size; a size
-- of 0 or less leaves it whole.
idatChunks ∷ Int → ByteString → [ByteString]
idatChunks size stream = map (chunk "IDAT") (if size <= 0 then [stream] else splitEvery size stream)

-- | A complete PNG of the header whose image data is all zero bytes of the
-- stated count, in IDAT chunks of the given size, with extra chunks (already
-- encoded) placed before the first IDAT.
imagePngWith ∷ [ByteString] → Header → Int → Int → ByteString
imagePngWith extras h scanlines idatSize = assemble ([ihdrChunk h] <> extras <> idatChunks idatSize (zlibOf (zeros scanlines)) <> [chunk "IEND" ""])

-- | A complete PNG of the header with exactly the scanline bytes it needs.
imagePng ∷ Header → Int → ByteString
imagePng h scanlines = imagePngWith [] h scanlines 0

-- | The scanline bytes a header needs, counted pixel by pixel: a pass's
-- columns and rows are the coordinates satisfying the Adam7 pattern, and an
-- empty pass contributes nothing. Colour type is the PNG code.
expectedScanlineBytes ∷ Bool → Word8 → Int → Int → Int → Int
expectedScanlineBytes interlaced colour depth w h = sum [rows * (1 + (cols * bitsPerPixel + 7) `div` 8) | (cols, rows) ← passes, cols > 0, rows > 0]
  where
    samples = case colour of
      2 → 3
      4 → 2
      6 → 4
      _ → 1
    bitsPerPixel = samples * depth
    passes
      | interlaced = [(length (filter columnOf [0 .. w - 1]), length (filter rowOf [0 .. h - 1])) | (columnOf, rowOf) ← adam7]
      | otherwise = [(w, h)]
    adam7 =
      [ (\x → x `mod` 8 == 0, \y → y `mod` 8 == 0)
      , (\x → x `mod` 8 == 4, \y → y `mod` 8 == 0)
      , (\x → x `mod` 4 == 0, \y → y `mod` 8 == 4)
      , (\x → x `mod` 4 == 2, \y → y `mod` 4 == 0)
      , (\x → x `mod` 2 == 0, \y → y `mod` 4 == 2)
      , (\x → x `mod` 2 == 1, \y → y `mod` 2 == 0)
      , (const True, \y → y `mod` 2 == 1)
      ]
