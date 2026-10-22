-- | Turning unfiltered PNG scanlines into one tightly packed RGBA8 level,
-- straight from the inflated buffer to the output.
--
-- This is the bounded decoder's replacement for the deinterlacer and the
-- sample vector JuicyPixels builds: each row is unfiltered where it lies in
-- the inflated buffer ('Hetoimasia.Asset.Image.Internal.PngUnfilter') and its
-- pixels are written, premultiplied, to their final place in the output, so
-- no sample, index or pass image is ever materialized. The only memory this
-- module allocates is the palette's table of at most 256 premultiplied
-- entries.
--
-- The texel contract is the general decoder's
-- ('Hetoimasia.Asset.Image.Png'), restated here for the one colour kind:
--
-- * a greyscale or truecolour pixel whose stored samples equal the @tRNS@
--   colour key, compared at the image's own bit depth before any reduction,
--   has alpha 0, and every other pixel alpha 255; other missing alpha becomes
--   255;
-- * a 1-, 2- or 4-bit grey sample @s@ is the grey level @s × 255 ÷ (2^d − 1)@,
--   which is exact for those depths;
-- * a 16-bit component, alpha included, becomes nearest(v × 255 ÷ 65535);
-- * a palette entry's alpha is the one @tRNS@ chunk's byte for its index,
--   255 past the chunk, and 255 if there is not exactly one such chunk;
-- * a palette index must name an entry of the palette;
-- * colour channels are premultiplied once, in linear light, by the texel's
--   alpha, from the shared table.
--
-- Failures here are content failures ('Refusal'): a filter-type byte that is
-- not 0 to 4 and a palette index outside the palette. Every offset is derived
-- from the header's pass geometry, checked against the buffers' lengths
-- before the first read or write.
module Hetoimasia.Asset.Image.Internal.PngRaster
  ( Palette
  , paletteBytes
  , makePalette
  , Raster (..)
  , rasterize
  )
where

import Control.Exception (allowInterrupt, throwIO)
import Control.Monad (unless, when)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Unsafe as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word16, Word8)
import Foreign.ForeignPtr (ForeignPtr, mallocForeignPtrBytes, withForeignPtr)
import Foreign.Ptr (Ptr, plusPtr)
import Foreign.Storable (peekByteOff, pokeByteOff)
import Hetoimasia.Asset.Image.Internal.PngGeometry
  ( Pass (..)
  , PngColourType (..)
  , PngInterlace
  , bitsPerPixel
  , packedRowBytes
  , passesOf
  )
import Hetoimasia.Asset.Image.Internal.PngStructure (ColourKey (..))
import Hetoimasia.Asset.Image.Internal.PngUnfilter (unfilterRow)
import Hetoimasia.Asset.Image.Internal.PngWorkspace (Refusal (..))
import Hetoimasia.Asset.Image.Internal.Premultiply (premultiplyChannel)
import Hetoimasia.Asset.Image.Internal.Texels (narrow)
import Hetoimasia.Asset.Image.PngPreflight (PngRefusalClass (MalformedPng))

-- | A palette image's lookup: how many entries the PLTE chunk holds (every
-- index below that is valid) and the premultiplied RGBA8 of the first at most
-- 256, which is every entry an 8-bit index can name.
data Palette = Palette
  { entryCount ∷ !Int
  , entryTable ∷ !(ForeignPtr Word8)
  }

-- | The most bytes a palette's table occupies: 256 entries of four bytes.
paletteBytes ∷ Int
paletteBytes = 256 * 4

-- | A palette from the PLTE chunk's data (whose length is a multiple of 3)
-- and the file's tRNS chunks' data. Only a file with exactly one tRNS chunk
-- has per-entry alpha.
makePalette ∷ ByteString → [ByteString] → IO Palette
makePalette plte transparency = do
  table ← mallocForeignPtrBytes paletteBytes
  withForeignPtr table $ \pointer →
    mapM_
      ( \i → do
          let alpha = case transparency of
                [alphas] | i < ByteString.length alphas → ByteString.unsafeIndex alphas i
                _ → 255
              channel k = ByteString.unsafeIndex plte (3 * i + k)
          pokeByteOff pointer (4 * i) (premultiplyChannel alpha (channel 0))
          pokeByteOff pointer (4 * i + 1) (premultiplyChannel alpha (channel 1))
          pokeByteOff pointer (4 * i + 2) (premultiplyChannel alpha (channel 2))
          pokeByteOff pointer (4 * i + 3) alpha
      )
      [0 .. min count 256 - 1]
  pure Palette {entryCount = count, entryTable = table}
  where
    count = ByteString.length plte `div` 3

-- | What the rasterizer needs of a header: its colour type, bit depth,
-- interlace method and extent, the colour key a greyscale or truecolour image
-- carries, and the palette an indexed one does.
data Raster = Raster
  { rasterColour ∷ !PngColourType
  , rasterDepth ∷ !Word8
  , rasterInterlace ∷ !PngInterlace
  , rasterWidth ∷ !Int
  , rasterHeight ∷ !Int
  , rasterKey ∷ !(Maybe ColourKey)
  , rasterPalette ∷ !(Maybe Palette)
  }

-- | Unfilter and convert every pass of the inflated @scanlines@ (@scanBytes@
-- long) into the RGBA8 level at @out@ (@outBytes@ long), using @zeros@
-- (@zeroBytes@ zero bytes, at least as long as the widest row) as the row
-- above each pass's first. A header whose extent, scanlines, output and zero
-- row do not agree is a fault of the caller, not of the file.
--
-- The pixel writer is chosen once per call and inlined into the pixel loop of
-- each branch, so a pixel costs no allocation: the loops below are the
-- specialisations GHC makes of 'walk' for each colour type and depth.
rasterize ∷ Raster → Ptr Word8 → Int → Ptr Word8 → Int → Ptr Word8 → Int → IO ()
rasterize raster scanlines scanBytes zeros zeroBytes out outBytes = do
  when (needed > toInteger scanBytes) $ error "PngRaster: the scanlines are shorter than the header needs"
  when (toInteger (rasterWidth raster) * toInteger (rasterHeight raster) * 4 > toInteger outBytes) $
    error "PngRaster: the output is shorter than the header's RGBA8 level"
  when (widest > toInteger zeroBytes) $ error "PngRaster: the zero row is shorter than the widest row"
  case (rasterColour raster, depth) of
    (ColourGreyscale, 8) → walk $ \row x dest → do
      y ← byteAt row x
      emit dest y y y (greyAlpha (fromIntegral y))
    (ColourGreyscale, 16) → walk $ \row x dest → do
      s ← wordAt row x
      let y = narrow s
      emit dest y y y (greyAlpha s)
    (ColourGreyscale, d) → walk $ \row x dest → do
      s ← sampleAt d row x
      let y = s * (255 `div` ((1 `shiftL` d) - 1))
      emit dest y y y (greyAlpha (fromIntegral s))
    (ColourTruecolour, 8) → walk $ \row x dest → do
      r ← byteAt row (3 * x)
      g ← byteAt row (3 * x + 1)
      b ← byteAt row (3 * x + 2)
      emit dest r g b (rgbAlpha (fromIntegral r) (fromIntegral g) (fromIntegral b))
    (ColourTruecolour, _) → walk $ \row x dest → do
      r ← wordAt row (3 * x)
      g ← wordAt row (3 * x + 1)
      b ← wordAt row (3 * x + 2)
      emit dest (narrow r) (narrow g) (narrow b) (rgbAlpha r g b)
    (ColourGreyscaleAlpha, 8) → walk $ \row x dest → do
      y ← byteAt row (2 * x)
      a ← byteAt row (2 * x + 1)
      emit dest y y y a
    (ColourGreyscaleAlpha, _) → walk $ \row x dest → do
      y ← narrow <$> wordAt row (2 * x)
      a ← narrow <$> wordAt row (2 * x + 1)
      emit dest y y y a
    (ColourTruecolourAlpha, 8) → walk $ \row x dest → do
      r ← byteAt row (4 * x)
      g ← byteAt row (4 * x + 1)
      b ← byteAt row (4 * x + 2)
      a ← byteAt row (4 * x + 3)
      emit dest r g b a
    (ColourTruecolourAlpha, _) → walk $ \row x dest → do
      r ← narrow <$> wordAt row (4 * x)
      g ← narrow <$> wordAt row (4 * x + 1)
      b ← narrow <$> wordAt row (4 * x + 2)
      a ← narrow <$> wordAt row (4 * x + 3)
      emit dest r g b a
    (ColourIndexed, d) → case rasterPalette raster of
      Nothing → error "PngRaster: an indexed image without a palette"
      Just palette → withForeignPtr (entryTable palette) $ \table →
        walk $ \row x dest → do
          index ← fromIntegral <$> sampleAt d row x
          when (index >= entryCount palette) $
            throwIO
              (Refusal MalformedPng ("a palette index " <> tshow index <> " is outside the " <> tshow (entryCount palette) <> "-entry palette"))
          r ← peekByteOff table (4 * index) ∷ IO Word8
          g ← peekByteOff table (4 * index + 1) ∷ IO Word8
          b ← peekByteOff table (4 * index + 2) ∷ IO Word8
          a ← peekByteOff table (4 * index + 3) ∷ IO Word8
          pokeByteOff dest 0 r
          pokeByteOff dest 1 g
          pokeByteOff dest 2 b
          pokeByteOff dest 3 a
  where
    depth = fromIntegral (rasterDepth raster) ∷ Int
    bits = bitsPerPixel (rasterColour raster) (rasterDepth raster)
    filterBytes = max 1 (fromInteger (bits `div` 8)) ∷ Int
    width = toInteger (rasterWidth raster)
    height = toInteger (rasterHeight raster)
    passes = passesOf (rasterInterlace raster) width height
    needed = sum [passRows p * (1 + packedRowBytes bits (passColumns p)) | p ← passes]
    widest = maximum (0 : [packedRowBytes bits (passColumns p) | p ← passes])

    greyAlpha ∷ Word16 → Word8
    greyAlpha s = case rasterKey raster of
      Just (GreyKey key) | s == key → 0
      _ → 255

    rgbAlpha ∷ Word16 → Word16 → Word16 → Word8
    rgbAlpha r g b = case rasterKey raster of
      Just (RgbKey kr kg kb) | r == kr && g == kg && b == kb → 0
      _ → 255

    -- Every pass in turn, each row unfiltered where it lies and then written
    -- pixel by pixel through the writer (row data, column in the row, the
    -- four output bytes).
    walk ∷ (Ptr Word8 → Int → Ptr Word8 → IO ()) → IO ()
    walk writer = go passes 0
      where
        go [] _ = pure ()
        go (pass : rest) !offset = do
          let columns = fromInteger (passColumns pass) ∷ Int
              rows = fromInteger (passRows pass) ∷ Int
              rowLength = fromInteger (packedRowBytes bits (passColumns pass)) ∷ Int
              stride = rowLength + 1
              rowStep = fromInteger (passRowStep pass) ∷ Int
              columnStep = fromInteger (passColumnStep pass) ∷ Int
              row0 = fromInteger (passRow0 pass) ∷ Int
              column0 = fromInteger (passColumn0 pass) ∷ Int
              rowLoop !y
                | y >= rows = pure ()
                | otherwise = do
                    allowInterrupt
                    let row = scanlines `plusPtr` (offset + y * stride) ∷ Ptr Word8
                        above = if y == 0 then zeros else row `plusPtr` (1 - stride) ∷ Ptr Word8
                    valid ← unfilterRow filterBytes rowLength above row
                    unless valid $ do
                      kind ← peekByteOff row 0 ∷ IO Word8
                      throwIO (Refusal MalformedPng ("a scanline names filter type " <> tshow kind <> ", which is not one of the five the specification defines"))
                    let pixels = row `plusPtr` 1 ∷ Ptr Word8
                        first = ((row0 + y * rowStep) * rasterWidth raster + column0) * 4
                        pixelLoop !x
                          | x >= columns = pure ()
                          | otherwise = writer pixels x (out `plusPtr` (first + x * columnStep * 4)) >> pixelLoop (x + 1)
                    pixelLoop 0
                    rowLoop (y + 1)
          rowLoop 0
          go rest (offset + rows * stride)
    {-# INLINE walk #-}

-- | Four output bytes: the colour channels premultiplied by the alpha, which
-- is stored unchanged.
emit ∷ Ptr Word8 → Word8 → Word8 → Word8 → Word8 → IO ()
emit dest r g b a = do
  pokeByteOff dest 0 (premultiplyChannel a r)
  pokeByteOff dest 1 (premultiplyChannel a g)
  pokeByteOff dest 2 (premultiplyChannel a b)
  pokeByteOff dest 3 a
{-# INLINE emit #-}

byteAt ∷ Ptr Word8 → Int → IO Word8
byteAt = peekByteOff
{-# INLINE byteAt #-}

-- | The big-endian 16-bit sample at this sample index of a row.
wordAt ∷ Ptr Word8 → Int → IO Word16
wordAt row sample = do
  high ← byteAt row (2 * sample)
  low ← byteAt row (2 * sample + 1)
  pure ((fromIntegral high `shiftL` 8) .|. fromIntegral low)
{-# INLINE wordAt #-}

-- | The sample at this pixel of a row of 1-, 2-, 4- or 8-bit samples, packed
-- most significant bits first.
sampleAt ∷ Int → Ptr Word8 → Int → IO Word8
sampleAt depth row x = do
  let bit = x * depth
  byte ← byteAt row (bit `shiftR` 3)
  pure ((byte `shiftR` (8 - depth - (bit .&. 7))) .&. ((1 `shiftL` depth) - 1))
{-# INLINE sampleAt #-}

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
