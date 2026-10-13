-- | The colour pipeline: shading, the premultiplied blend and the 8-bit store.
--
-- A fragment's source is four 'Chan's: a value in linear light, premultiplied,
-- held exactly as a 'Rational' (the sRGB transfer function, which is
-- irrational, enters only through a 'Double' that is converted exactly), with
-- whether the value is /exact/, meaning that it is a whole stored byte carried
-- through unchanged (or exactly 0 or 1, which no rounding can move).
--
-- The destination is four 'Stored' channels. A store converts a value to 8 bits
-- by rounding to nearest, but Vulkan does not fix the direction of a tie, and a
-- device's floating-point arithmetic can fall either side of a value within a
-- hair of one, so a store has a /range/ of possible bytes: every integer within
-- half a step plus 'slack' of the value. The next blend reads the whole range,
-- and since a blend is monotone in its destination the range carries through
-- every store as two bounds. A channel whose range at the end is wider than
-- the tolerance of 1 can bound (three bytes, @hi − lo ≤ 2@) is not given a
-- wider tolerance: the probe is indeterminate.
--
-- Every blended fragment is encoded to the target's 8-bit storage before the
-- next one reads it: a fixed-point attachment stores after every draw, so eight
-- sources of byte 4 over transparent black give 32 and not 30.
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
  , Cut (..)
  , cutoutThreshold
  , cutoutBand
  , cutout
  , blend
  , pixelOutcome
  ) where

import Data.Word (Word8)
import Hetoimasia.Render.TwoD.Oracle.Colour
  ( Channel (..)
  , ColourFormat
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
  { chanValue ∷ !Rational
  , chanExact ∷ !Bool
  }
  deriving stock (Eq, Show)

-- | A stored channel: the lowest and highest byte a device could have stored,
-- and whether the channel is exact.
data Stored = Stored !Word8 !Word8 !Bool
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

clamp01 ∷ Rational → Rational
clamp01 = max 0 . min 1

-- | How far past half a step a value may be and still be a tie to a device: a
-- 1024th of a byte, orders of magnitude above 32-bit arithmetic's error in a
-- channel and far below any value the fixtures or a game's art would sit at.
slack ∷ Rational
slack = 1 / 1024

-- | The lowest and highest byte a store of values between these two, both in
-- [0, 1] and already in the target's encoding, could give.
outcomes ∷ Rational → Rational → (Word8, Word8)
outcomes low high =
  ( fromInteger (max 0 (min 255 (ceiling (low * 255 - 1 / 2 - slack))))
  , fromInteger (max 0 (min 255 (floor (high * 255 + 1 / 2 + slack))))
  )

-- | The target's storage of a colour channel's linear value.
encodeColour ∷ ColourFormat → Rational → Rational
encodeColour format value
  | formatIsSrgb format = toRational (linearToSrgb (fromRational value))
  | otherwise = value

-- | The linear value of a stored colour byte.
decodeColour ∷ ColourFormat → Word8 → Rational
decodeColour format byte
  | formatIsSrgb format = toRational (srgbToLinear (fromIntegral byte / 255))
  | otherwise = fromIntegral byte / 255

linearByte ∷ Word8 → Rational
linearByte byte = fromIntegral byte / 255

-- | The pixel a pass starts from: the clear colour, a linear value encoded like
-- any other. A component of 0 or 1 is exact; one that is a tie is a range.
clearPixel ∷ ColourFormat → ClearColour → Pixel
clearPixel format (ClearColour red green blue alpha) =
  Quad (colour red) (colour green) (colour blue) (store alpha id)
  where
    colour component = store component (encodeColour format)
    store component encode =
      let encoded = encode (toRational component)
          (low, high) = outcomes encoded encoded
       in Stored low high ((component == 0 || component == 1) && low == high)

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
      | otherwise = scaleBy (toRational brightness) chan
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

scaleBy ∷ Rational → Chan → Chan
scaleBy factor (Chan value _) = pinChan (Chan (value * factor) False)

-- | What the cutout variant (design D-26) does with a sample.
data Cut
  = -- | The fragment is discarded: its alpha, before brightness, is below ½.
    Discarded
  | -- | The fragment survives and writes this source, whose alpha is exactly 1.
    Survives !Source
  | -- | The alpha is within 'cutoutBand' of the threshold, where a device's
    -- filtering and arithmetic may fall either side of it.
    AtThreshold
  deriving stock (Eq, Show)

-- | The alpha below which the cutout variant discards.
cutoutThreshold ∷ Rational
cutoutThreshold = 1 / 2

-- | How far from 'cutoutThreshold' an alpha may lie, inclusively, and still be
-- indeterminate: two steps of an 8-bit alpha.
cutoutBand ∷ Rational
cutoutBand = 2 / 255

-- | The default material's cutout variant (D-26), with @m = t@ and a tint of
-- alpha 255 by routing:
--
-- > s = m × c
-- > discard when s.a < ½
-- > result = (s.rgb / s.a) × b, alpha 1
--
-- clamped to [0, 1]. The colour is un-premultiplied by the sample's own alpha,
-- so a filtered edge sample @(0.6, 0.6, 0.6, 0.6)@ writes white, then brightened.
-- The tint's alpha is applied for totality, though routing leaves it 255.
cutout ∷ Tint → Float → Source → Cut
cutout (Tint tr tg tb ta) brightness (Quad r g b a)
  | abs (alpha - cutoutThreshold) <= cutoutBand = AtThreshold
  | alpha < cutoutThreshold = Discarded
  | otherwise = Survives (Quad (finish sr) (finish sg) (finish sb) (Chan 1 True))
  where
    sr = byteFactor tr r
    sg = byteFactor tg g
    sb = byteFactor tb b
    sa = byteFactor ta a
    alpha = chanValue sa
    finish = clampChan . lit . over
    over chan
      | alpha == 1 = chan
      | otherwise = pinChan (Chan (chanValue chan / alpha) False)
    lit chan
      | brightness == 1 = chan
      | otherwise = scaleBy (toRational brightness) chan

-- | One fragment blended over a pixel and stored:
--
-- > result = s + destination × (1 − s.a)
--
-- computed exactly for the lowest and the highest byte the destination could
-- hold, which bounds every result since the blend is monotone in the
-- destination. A channel the fragment leaves untouched (a source of exactly zero
-- under a source alpha of exactly zero) keeps its stored range and its flag. A
-- source alpha of exactly 1 replaces the destination, so the result is exact
-- when the source is. A destination byte of 0 contributes nothing. Any other sum
-- of two non-zero terms involves rounding and is not exact, unless it clamps.
blend ∷ ColourFormat → Source → Pixel → Pixel
blend format (Quad sr sg sb sa) (Quad dr dg db da) =
  Quad (channel True sr dr) (channel True sg dg) (channel True sb db) (channel False sa da)
  where
    alpha = chanValue sa
    channel isColour source stored@(Stored lowByte highByte _)
      | sourceValue == 0 && alpha == 0 = stored
      | otherwise = Stored low high (flag && low == high)
      where
        sourceValue = chanValue source
        decode = if isColour then decodeColour format else linearByte
        encode = if isColour then encodeColour format else id
        zeroTerm = alpha == 1 || highByte == 0
        (termLow, termHigh)
          | zeroTerm = (0, 0)
          | otherwise = (decode lowByte * (1 - alpha), decode highByte * (1 - alpha))
        rawLow = sourceValue + termLow
        rawHigh = sourceValue + termHigh
        (low, high) = outcomes (encode (clamp01 rawLow)) (encode (clamp01 rawHigh))
        flag
          | rawLow >= 1 = True
          | rawHigh <= 0 = True
          | sourceValue == 0 = zeroTerm
          | zeroTerm = chanExact source
          | otherwise = False

-- | What a pixel is expected to hold: its channels as bytes with a tolerance of
-- 0 where exact and 1 where not, or the first channel whose range of possible
-- bytes is wider than three, which no tolerance of 1 can cover. A range of two
-- is read as the upper byte, which is what a tie rounds to, and a range of three
-- as its middle.
pixelOutcome ∷ Pixel → Either Channel (Rgba8, Tolerance)
pixelOutcome (Quad r g b a) = do
  (er, tr) ← settle Red r
  (eg, tg) ← settle Green g
  (eb, tb) ← settle Blue b
  (ea, ta) ← settle Alpha a
  Right (Rgba8 er eg eb ea, Tolerance tr tg tb ta)
  where
    settle channel (Stored low high exact)
      | low == high = Right (low, if exact then 0 else 1)
      | high - low <= 2 = Right (low + (high - low + 1) `div` 2, 1)
      | otherwise = Left channel
