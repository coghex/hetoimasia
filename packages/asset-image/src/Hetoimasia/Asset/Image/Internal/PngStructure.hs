-- | The checks a PNG passes before JuicyPixels decodes it.
--
-- JuicyPixels reads every chunk's CRC and requires IEND, but it reads the
-- decompressed image data and the palette without bounds checks: a stream
-- that inflates to fewer bytes than the header's extent needs, or a header
-- whose bit depth its colour type does not allow, would have it read past the
-- end of its buffer and return whatever memory lay there. Those inputs are
-- refused here, before it runs, so what it returns is always the image the
-- file describes. Palette indices are checked where the palette is applied
-- ('Hetoimasia.Asset.Image.Internal.Texels').
--
-- The same pass reads a greyscale or truecolour image's @tRNS@ colour key,
-- which JuicyPixels does not apply.
module Hetoimasia.Asset.Image.Internal.PngStructure
  ( checkStructure
  , ColourKey (..)
  )
where

import Codec.Compression.Zlib.Internal (DecompressError, decompressST, defaultDecompressParams, foldDecompressStreamWithInput, zlibFormat)
import Codec.Picture.Png.Internal.Type
  ( PngIHdr (..)
  , PngImageType (..)
  , PngInterlaceMethod (..)
  , PngRawChunk (..)
  , PngRawImage (..)
  , iDATSignature
  , pngComputeCrc
  , pngSignature
  , tRNSSignature
  )
import Data.Binary (get)
import Data.Binary.Get (runGetOrFail)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word16, Word8)

-- | A greyscale or truecolour image's @tRNS@ colour key: the sample values,
-- at the image's own bit depth, of the one colour that is fully transparent.
-- A texel whose stored samples all equal the key's has alpha 0; every other
-- texel has alpha 255.
data ColourKey
  = GreyKey !Word16
  | RgbKey !Word16 !Word16 !Word16
  deriving (Eq, Show)

-- | The header of a PNG whose framing, header and image data stream are
-- sound, with its colour key if it has one; or the reason they are not.
checkStructure ∷ ByteString → Either Text (PngIHdr, Maybe ColourKey)
checkStructure bytes
  | ByteString.null bytes = Left "the bytes are empty"
  | bytes `ByteString.isPrefixOf` signature = Left "the PNG is truncated within its signature"
  | not (signature `ByteString.isPrefixOf` bytes) = Left "the bytes are not a PNG: they do not begin with the PNG signature"
  | otherwise = do
      raw ← case runGetOrFail get (Lazy.fromStrict bytes) of
        Left (_, _, message) → Left ("the PNG is malformed or truncated: " <> Text.pack message)
        Right (_, _, raw) → Right raw
      checkHeaderChunk bytes
      let ihdr = header raw
      checkHeader ihdr
      checkImageData ihdr (Lazy.concat [chunkData c | c ← chunks raw, chunkType c == iDATSignature])
      Right (ihdr, colourKey (colourType ihdr) [chunkData c | c ← chunks raw, chunkType c == tRNSSignature])
  where
    signature = Lazy.toStrict pngSignature

-- | The colour key of a greyscale or truecolour image: its one @tRNS@ chunk,
-- two big-endian bytes for greyscale and six for truecolour. A @tRNS@ chunk of
-- another length, a second @tRNS@ chunk, or one on a colour type with an
-- alpha channel is malformed. JuicyPixels decodes such a file without
-- complaint; so does this decoder, ignoring the chunk, as JuicyPixels ignores
-- a palette image's @tRNS@ when there is more than one. A palette image's
-- @tRNS@ is JuicyPixels' to apply.
colourKey ∷ PngImageType → [Lazy.ByteString] → Maybe ColourKey
colourKey colour = \case
  [key] → case (colour, map fromIntegral (Lazy.unpack key) ∷ [Word16]) of
    (PngGreyscale, [hi, lo]) → Just (GreyKey (sample hi lo))
    (PngTrueColour, [rh, rl, gh, gl, bh, bl]) → Just (RgbKey (sample rh rl) (sample gh gl) (sample bh bl))
    _ → Nothing
  _ → Nothing
  where
    sample hi lo = hi * 256 + lo

-- | JuicyPixels skips the header chunk's length and CRC; every other chunk's
-- CRC it checks itself.
checkHeaderChunk ∷ ByteString → Either Text ()
checkHeaderChunk bytes
  | ByteString.length bytes < 33 = Left "the PNG is truncated within its header"
  | word32 8 /= 13 = Left "the PNG's IHDR chunk is not 13 bytes long"
  | toInteger (pngComputeCrc [Lazy.fromStrict (slice 12 17)]) /= word32 29 = Left "the PNG's IHDR chunk fails its CRC"
  | otherwise = Right ()
  where
    slice from count = ByteString.take count (ByteString.drop from bytes)
    word32 at = ByteString.foldl' (\acc byte → acc * 256 + toInteger byte) 0 (slice at 4)

checkHeader ∷ PngIHdr → Either Text ()
checkHeader ihdr
  | width ihdr == 0 || height ihdr == 0 = Left "the PNG's width or height is zero"
  | compressionMethod ihdr /= 0 = Left "the PNG names an unknown compression method"
  | filterMethod ihdr /= 0 = Left "the PNG names an unknown filter method"
  | bitDepth ihdr `notElem` allowedDepths (colourType ihdr) =
      Left ("the PNG's bit depth " <> tshow (bitDepth ihdr) <> " is not allowed for its colour type")
  | otherwise = Right ()

-- | The bit depths the PNG specification allows for each colour type.
allowedDepths ∷ PngImageType → [Word8]
allowedDepths = \case
  PngGreyscale → [1, 2, 4, 8, 16]
  PngTrueColour → [8, 16]
  PngIndexedColor → [1, 2, 4, 8]
  PngGreyscaleWithAlpha → [8, 16]
  PngTrueColourWithAlpha → [8, 16]

-- | The compressed stream must inflate, and to at least the bytes the
-- header's extent, bit depth and interlacing need.
checkImageData ∷ PngIHdr → Lazy.ByteString → Either Text ()
checkImageData ihdr compressed = case inflatedLength compressed of
  Left failure → Left ("the PNG's compressed image data is corrupt: " <> tshow failure)
  Right inflated
    | toInteger inflated < needed →
        Left ("the PNG's image data inflates to " <> tshow inflated <> " bytes, and its header needs " <> tshow needed)
    | otherwise → Right ()
  where
    needed = filteredSize ihdr

inflatedLength ∷ Lazy.ByteString → Either DecompressError Int
inflatedLength compressed =
  foldDecompressStreamWithInput
    (\piece continue counted → continue $! counted + ByteString.length piece)
    (\_ counted → Right counted)
    (\failure _ → Left failure)
    (decompressST zlibFormat defaultDecompressParams)
    compressed
    0

-- | The size of the filtered image data: for each pass (one, or Adam7's
-- seven), one filter byte per row plus the row's packed samples.
filteredSize ∷ PngIHdr → Integer
filteredSize ihdr = case interlaceMethod ihdr of
  PngNoInterlace → pass w h
  PngInterlaceAdam7 →
    sum
      [ pass (extent w column0 columnStep) (extent h row0 rowStep)
      | (column0, columnStep, row0, rowStep) ← adam7
      ]
  where
    w = toInteger (width ihdr)
    h = toInteger (height ihdr)
    bitsPerPixel = channels (colourType ihdr) * toInteger (bitDepth ihdr)
    pass passWidth passHeight
      | passWidth <= 0 || passHeight <= 0 = 0
      | otherwise = passHeight * (1 + (passWidth * bitsPerPixel + 7) `div` 8)
    extent size start step
      | size <= start = 0
      | otherwise = (size - start + step - 1) `div` step
    adam7 = [(0, 8, 0, 8), (4, 8, 0, 8), (0, 4, 4, 8), (2, 4, 0, 4), (0, 2, 2, 4), (1, 2, 0, 2), (0, 1, 1, 2)]

channels ∷ PngImageType → Integer
channels = \case
  PngGreyscale → 1
  PngTrueColour → 3
  PngIndexedColor → 1
  PngGreyscaleWithAlpha → 2
  PngTrueColourWithAlpha → 4

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
