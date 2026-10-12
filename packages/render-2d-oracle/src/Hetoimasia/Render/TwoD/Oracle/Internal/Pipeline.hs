-- | The colour pipeline: shading, the premultiplied blend and the 8-bit store.
--
-- A fragment's source is four 'Chan's: a double-precision value in linear
-- light, premultiplied, together with whether the value is /exact/, meaning
-- that it is a whole stored byte carried through unchanged (or exactly 0 or
-- 1, which no rounding can move). The destination is four stored bytes, each
-- with the same flag. The flags are what lets the oracle give a channel
-- tolerance 0 only where nothing rounds.
--
-- Every blended fragment is encoded to the target's 8-bit storage and
-- rounded, round half up, before the next fragment reads it: a fixed-point
-- attachment stores after every draw, so eight sources of byte 4 over
-- transparent black give 32 and not 30.
--
-- __Dependencies.__ @base@ and the oracle's colour module.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Oracle.Internal.Pipeline
  ( Quad (..)
  , Chan (..)
  , Stored (..)
  , Source
  , Pixel
  , zeroChan
  , pinChan
  , clearPixel
  , shade
  , blend
  , pixelValue
  , pixelTolerance
  ) where

import Data.Word (Word8)
import Hetoimasia.Render.TwoD.Oracle.Colour
  ( ColourFormat
  , Rgba8 (..)
  , Tolerance (..)
  , formatIsSrgb
  , linearToSrgb
  , srgbToLinear
  )
import Hetoimasia.Render.TwoD.Snapshot (ClearColour (..), Tint (..))

-- | Four values, in red, green, blue, alpha order.
data Quad a = Quad !a !a !a !a
  deriving stock (Eq, Show, Functor)

-- | A value in linear light, and whether it is exact.
data Chan = Chan
  { chanValue ∷ !Double
  , chanExact ∷ !Bool
  }
  deriving stock (Eq, Show)

-- | A stored byte, and whether it is exact.
data Stored = Stored !Word8 !Bool
  deriving stock (Eq, Show)

-- | A fragment's colour, premultiplied, in linear light.
type Source = Quad Chan

-- | A target pixel as stored.
type Pixel = Quad Stored

-- | Exactly zero.
zeroChan ∷ Chan
zeroChan = Chan 0 True

-- | A value that is exactly 0 or 1 is exact whatever produced it.
pinChan ∷ Chan → Chan
pinChan (Chan value exact) = Chan value (exact || value == 0 || value == 1)

-- | A clamp to [0, 1]. A value that clamps is exactly 0 or 1.
clampChan ∷ Chan → Chan
clampChan (Chan value exact)
  | value <= 0 = Chan 0 True
  | value >= 1 = Chan 1 True
  | otherwise = Chan value exact

-- | The 8-bit store of a value in [0, 1]: round half up, clamped.
quantise ∷ Double → Word8
quantise value = fromIntegral (max 0 (min 255 (floor (value * 255 + 0.5) ∷ Int)))

-- | The target's storage of a colour channel's linear value.
encodeColour ∷ ColourFormat → Double → Double
encodeColour format value
  | formatIsSrgb format = linearToSrgb value
  | otherwise = value

-- | The linear value of a stored colour byte.
decodeColour ∷ ColourFormat → Word8 → Double
decodeColour format byte
  | formatIsSrgb format = srgbToLinear (fromIntegral byte / 255)
  | otherwise = fromIntegral byte / 255

-- | The pixel a pass starts from: the clear colour, a linear value encoded
-- like any other. A component of 0 or 1 is exact.
clearPixel ∷ ColourFormat → ClearColour → Pixel
clearPixel format (ClearColour red green blue alpha) =
  Quad (colour red) (colour green) (colour blue) (linearAlpha alpha)
  where
    colour component = store (encodeColour format (realToFrac component)) component
    linearAlpha component = store (realToFrac component) component
    store encoded component =
      Stored (quantise encoded) (component == 0 || component == 1)

-- | The output of the default material, @m = t@, through the tint, the
-- brightness and the additive flag, clamped to [0, 1]:
--
-- > s = m × c;  s.rgb = s.rgb × b;  additive: s.a = 0
shade ∷ Tint → Float → Bool → Source → Source
shade (Tint tr tg tb ta) brightness additive (Quad r g b a) =
  fmap clampChan (Quad lr lg lb la)
  where
    Quad mr mg mb ma = Quad (byteFactor tr r) (byteFactor tg g) (byteFactor tb b) (byteFactor ta a)
    lit chan
      | brightness == 1 = chan
      | otherwise = scaleBy (realToFrac brightness) chan
    -- An additive source's colour is summed into the destination whatever its
    -- alpha is, and the sum rounds: its alpha of zero does not make it exact.
    colour chan
      | additive = pinChan (Chan (chanValue chan) False)
      | otherwise = chan
    lr = colour (lit mr)
    lg = colour (lit mg)
    lb = colour (lit mb)
    la
      | additive = zeroChan
      | otherwise = ma

-- | A channel scaled by a tint byte over 255. 255 leaves it alone and 0 zeroes
-- it; anything between rounds.
byteFactor ∷ Word8 → Chan → Chan
byteFactor byte chan@(Chan value _)
  | byte == 255 = chan
  | byte == 0 = zeroChan
  | otherwise = pinChan (Chan (value * (fromIntegral byte / 255)) False)

scaleBy ∷ Double → Chan → Chan
scaleBy factor (Chan value _) = pinChan (Chan (value * factor) False)

-- | One fragment blended over a pixel and stored:
--
-- > result = s + destination × (1 − s.a)
--
-- A channel the fragment leaves untouched (a source of exactly zero under a
-- source alpha of exactly zero) keeps its stored byte and its flag. A source
-- alpha of exactly 1 replaces the destination, so the result is exact when
-- the source is. A destination byte of 0 contributes nothing. Any other sum
-- of two non-zero terms involves rounding and is not exact, unless it clamps.
blend ∷ ColourFormat → Source → Pixel → Pixel
blend format (Quad sr sg sb sa) (Quad dr dg db da) =
  Quad
    (channel (decodeColour format) (encodeColour format) sr dr)
    (channel (decodeColour format) (encodeColour format) sg dg)
    (channel (decodeColour format) (encodeColour format) sb db)
    (channel linearByte id sa da)
  where
    alpha = chanValue sa
    linearByte byte = fromIntegral byte / 255
    channel decode encode source@(Chan sourceValue _) stored@(Stored byte exact)
      | sourceValue == 0 && alpha == 0 = stored
      | otherwise =
          let term2
                | alpha == 1 || byte == 0 = zeroChan
                | alpha == 0 = Chan (decode byte) exact
                | otherwise = Chan (decode byte * (1 - alpha)) False
              summed
                | sourceValue == 0 = term2
                | chanValue term2 == 0 = source
                | otherwise = Chan (sourceValue + chanValue term2) False
              Chan result resultExact = clampChan summed
           in Stored (quantise (encode result)) resultExact

-- | A pixel's channels as bytes.
pixelValue ∷ Pixel → Rgba8
pixelValue (Quad (Stored r _) (Stored g _) (Stored b _) (Stored a _)) = Rgba8 r g b a

-- | A pixel's tolerance: 0 on an exact channel and 1 on any other.
pixelTolerance ∷ Pixel → Tolerance
pixelTolerance (Quad r g b a) = Tolerance (step r) (step g) (step b) (step a)
  where
    step (Stored _ exact) = if exact then 0 else 1
