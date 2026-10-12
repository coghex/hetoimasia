-- | The oracle's colour vocabulary: a target's format, an 8-bit pixel, a
-- per-channel tolerance and the sRGB transfer function.
--
-- __Formats.__ A colour target is @R8G8B8A8@ or @B8G8R8A8@, each sRGB or
-- UNORM, the four the backend contract allows. The format decides two things:
-- the order of the bytes a readback holds, and whether the colour channels
-- are stored sRGB-encoded. Alpha is linear in every format. Everything this
-- package reports is in RGBA order whatever the target's channel order.
--
-- __sRGB.__ 'srgbToLinear' and 'linearToSrgb' are the standard piecewise
-- transfer function of IEC 61966-2-1, evaluated in double precision.
--
-- __Dependencies.__ @base@.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Oracle.Colour
  ( -- * Target formats
    ColourFormat (..)
  , formatIsSrgb
  , formatIsBgra

    -- * Pixels
  , Rgba8 (..)
  , Tolerance (..)
  , Channel (..)
  , exactTolerance
  , withinTolerance

    -- * The transfer function
  , srgbToLinear
  , linearToSrgb
  ) where

import Data.Word (Word8)

-- | A colour target's format.
data ColourFormat
  = R8G8B8A8Srgb
  | R8G8B8A8Unorm
  | B8G8R8A8Srgb
  | B8G8R8A8Unorm
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Whether the format stores its colour channels sRGB-encoded.
formatIsSrgb ∷ ColourFormat → Bool
formatIsSrgb R8G8B8A8Srgb = True
formatIsSrgb B8G8R8A8Srgb = True
formatIsSrgb R8G8B8A8Unorm = False
formatIsSrgb B8G8R8A8Unorm = False

-- | Whether the format stores its bytes blue first.
formatIsBgra ∷ ColourFormat → Bool
formatIsBgra B8G8R8A8Srgb = True
formatIsBgra B8G8R8A8Unorm = True
formatIsBgra R8G8B8A8Srgb = False
formatIsBgra R8G8B8A8Unorm = False

-- | A pixel as four 8-bit channels, in red, green, blue, alpha order, as the
-- target stores them: sRGB-encoded colour in an sRGB format.
data Rgba8 = Rgba8 !Word8 !Word8 !Word8 !Word8
  deriving stock (Eq, Ord, Show)

-- | How far each channel of a stored pixel may differ from an expectation:
-- red, green, blue and alpha. Zero means the channel must match exactly; the
-- oracle gives either zero or one.
data Tolerance = Tolerance !Word8 !Word8 !Word8 !Word8
  deriving stock (Eq, Ord, Show)

-- | One of a pixel's four channels.
data Channel = Red | Green | Blue | Alpha
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The tolerance of a pixel every channel of which must match exactly.
exactTolerance ∷ Tolerance
exactTolerance = Tolerance 0 0 0 0

-- | Whether an actual pixel is within a tolerance of an expected one on every
-- channel.
withinTolerance ∷ Tolerance → Rgba8 → Rgba8 → Bool
withinTolerance (Tolerance tr tg tb ta) (Rgba8 er eg eb ea) (Rgba8 ar ag ab aa) =
  close tr er ar && close tg eg ag && close tb eb ab && close ta ea aa
  where
    close tolerance expected actual =
      abs (fromIntegral expected - fromIntegral actual ∷ Int) <= fromIntegral tolerance

-- | The linear value of an sRGB-encoded one, both in [0, 1].
srgbToLinear ∷ Double → Double
srgbToLinear encoded
  | encoded <= 0.04045 = encoded / 12.92
  | otherwise = ((encoded + 0.055) / 1.055) ** 2.4

-- | The sRGB encoding of a linear value, both in [0, 1].
linearToSrgb ∷ Double → Double
linearToSrgb linear
  | linear <= 0.0031308 = linear * 12.92
  | otherwise = 1.055 * linear ** (1 / 2.4) - 0.055
