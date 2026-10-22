-- | The PNG profile's colour types, interlace methods and the arithmetic that
-- turns a header into the bytes its filtered scanlines occupy.
--
-- Every size here is an 'Integer': a header's extent comes from two untrusted
-- 32-bit fields, and their products do not fit a machine word, so nothing is
-- narrowed until the caller has compared it with a validated limit. The
-- checks that run before JuicyPixels
-- ('Hetoimasia.Asset.Image.Internal.PngStructure') and the bounded preflight
-- ('Hetoimasia.Asset.Image.PngPreflight') share these definitions, so the
-- size one of them expects is the size the other does.
module Hetoimasia.Asset.Image.Internal.PngGeometry
  ( PngColourType (..)
  , PngInterlace (..)
  , colourTypeOfCode
  , interlaceOfCode
  , allowedDepths
  , channels
  , scanlineBytes
  )
where

import Data.Word (Word8)

-- | The five colour types the PNG specification defines.
data PngColourType
  = ColourGreyscale
  | ColourTruecolour
  | ColourIndexed
  | ColourGreyscaleAlpha
  | ColourTruecolourAlpha
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The two interlace methods the PNG specification defines.
data PngInterlace
  = InterlaceNone
  | InterlaceAdam7
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The colour type a header's colour-type byte names, if it names one.
colourTypeOfCode ∷ Word8 → Maybe PngColourType
colourTypeOfCode = \case
  0 → Just ColourGreyscale
  2 → Just ColourTruecolour
  3 → Just ColourIndexed
  4 → Just ColourGreyscaleAlpha
  6 → Just ColourTruecolourAlpha
  _ → Nothing

-- | The interlace method a header's interlace byte names, if it names one.
interlaceOfCode ∷ Word8 → Maybe PngInterlace
interlaceOfCode = \case
  0 → Just InterlaceNone
  1 → Just InterlaceAdam7
  _ → Nothing

-- | The bit depths the PNG specification allows for each colour type.
allowedDepths ∷ PngColourType → [Word8]
allowedDepths = \case
  ColourGreyscale → [1, 2, 4, 8, 16]
  ColourTruecolour → [8, 16]
  ColourIndexed → [1, 2, 4, 8]
  ColourGreyscaleAlpha → [8, 16]
  ColourTruecolourAlpha → [8, 16]

-- | Samples per pixel.
channels ∷ PngColourType → Integer
channels = \case
  ColourGreyscale → 1
  ColourTruecolour → 3
  ColourIndexed → 1
  ColourGreyscaleAlpha → 2
  ColourTruecolourAlpha → 4

-- | The size of the filtered image data for a header's interlace method,
-- colour type, bit depth, width and height: for each pass (one, or Adam7's
-- seven), one filter byte per row plus the row's samples packed to a whole
-- number of bytes. An Adam7 pass with no columns or no rows contributes
-- nothing, not even filter bytes.
scanlineBytes ∷ PngInterlace → PngColourType → Word8 → Integer → Integer → Integer
scanlineBytes interlace colour depth w h = case interlace of
  InterlaceNone → pass w h
  InterlaceAdam7 →
    sum
      [ pass (extent w column0 columnStep) (extent h row0 rowStep)
      | (column0, columnStep, row0, rowStep) ← adam7
      ]
  where
    bitsPerPixel = channels colour * toInteger depth
    pass passWidth passHeight
      | passWidth <= 0 || passHeight <= 0 = 0
      | otherwise = passHeight * (1 + (passWidth * bitsPerPixel + 7) `div` 8)
    extent size start step
      | size <= start = 0
      | otherwise = (size - start + step - 1) `div` step
    adam7 = [(0, 8, 0, 8), (4, 8, 0, 8), (0, 4, 4, 8), (2, 4, 0, 4), (0, 2, 2, 4), (1, 2, 0, 2), (0, 1, 1, 2)]
