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
  , bitsPerPixel
  , packedRowBytes
  , Pass (..)
  , passesOf
  , scanlineBytes
  )
where

import Control.DeepSeq (NFData (rnf))
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

instance NFData PngColourType where
  rnf colour = colour `seq` ()

instance NFData PngInterlace where
  rnf interlace = interlace `seq` ()

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

-- | Bits per pixel: samples per pixel times the bit depth.
bitsPerPixel ∷ PngColourType → Word8 → Integer
bitsPerPixel colour depth = channels colour * toInteger depth

-- | The bytes of one packed row of @columns@ pixels, rounded up to a whole
-- byte, filter byte not included.
packedRowBytes ∷ Integer → Integer → Integer
packedRowBytes bits columns = (columns * bits + 7) `div` 8

-- | One pass of the image data: a non-interlaced image is one pass over every
-- pixel, an Adam7 image up to seven. A pass holds @passColumns@ pixels in each
-- of @passRows@ rows; its pixel @(column, row)@ is the image's pixel
-- @(passColumn0 + column × passColumnStep, passRow0 + row × passRowStep)@.
data Pass = Pass
  { passColumns ∷ !Integer
  , passRows ∷ !Integer
  , passColumn0 ∷ !Integer
  , passColumnStep ∷ !Integer
  , passRow0 ∷ !Integer
  , passRowStep ∷ !Integer
  }
  deriving (Eq, Show)

-- | The non-empty passes of an image of this interlace method, width and
-- height, in the order their data follows one another. An Adam7 pass with no
-- columns or no rows is not listed: it contributes no data, not even filter
-- bytes.
passesOf ∷ PngInterlace → Integer → Integer → [Pass]
passesOf interlace w h = case interlace of
  InterlaceNone → [Pass w h 0 1 0 1 | w > 0, h > 0]
  InterlaceAdam7 →
    [ pass
    | (column0, columnStep, row0, rowStep) ← adam7
    , let pass = Pass (extent w column0 columnStep) (extent h row0 rowStep) column0 columnStep row0 rowStep
    , passColumns pass > 0
    , passRows pass > 0
    ]
  where
    extent size start step
      | size <= start = 0
      | otherwise = (size - start + step - 1) `div` step
    adam7 = [(0, 8, 0, 8), (4, 8, 0, 8), (0, 4, 4, 8), (2, 4, 0, 4), (0, 2, 2, 4), (1, 2, 0, 2), (0, 1, 1, 2)]

-- | The size of the filtered image data for a header's interlace method,
-- colour type, bit depth, width and height: for each pass (one, or Adam7's
-- seven), one filter byte per row plus the row's samples packed to a whole
-- number of bytes. An Adam7 pass with no columns or no rows contributes
-- nothing, not even filter bytes.
scanlineBytes ∷ PngInterlace → PngColourType → Word8 → Integer → Integer → Integer
scanlineBytes interlace colour depth w h =
  sum [passRows pass * (1 + packedRowBytes (bitsPerPixel colour depth) (passColumns pass)) | pass ← passesOf interlace w h]
