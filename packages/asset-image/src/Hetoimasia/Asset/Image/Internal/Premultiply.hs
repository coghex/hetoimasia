-- | Premultiplying an sRGB colour channel by its alpha, in linear light.
--
-- Each channel is decoded with the sRGB transfer function (IEC 61966-2-1),
-- multiplied by alpha ÷ 255, re-encoded with the inverse function and rounded
-- to nearest. Multiplying the encoded values directly would darken
-- semi-transparent edges, which is why it is not done (asset design D-4).
--
-- Every (alpha, channel) pair is computed once, into a 64 KiB table built the
-- first time any image is premultiplied and shared afterwards; premultiplying
-- a texel is then three lookups.
--
-- The table is the same on every platform: the exact value of every entry
-- lies at least 6 × 10⁻⁶ of a code value from a rounding boundary, far beyond
-- any difference between C libraries' @pow@, so no entry can round differently.
module Hetoimasia.Asset.Image.Internal.Premultiply
  ( premultiplyChannel
  , premultiplyRgba8
  )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Internal as ByteString (unsafeCreate)
import qualified Data.ByteString.Unsafe as ByteString
import Data.Foldable (for_)
import Data.Word (Word8)
import Foreign.Storable (pokeByteOff)

-- | A colour channel premultiplied by an alpha, both as stored bytes. Alpha
-- 255 leaves the channel unchanged and alpha 0 makes it zero, exactly.
premultiplyChannel ∷ Word8 → Word8 → Word8
premultiplyChannel alpha channel =
  ByteString.unsafeIndex table (fromIntegral alpha * 256 + fromIntegral channel)
{-# INLINE premultiplyChannel #-}

-- | A tightly packed RGBA8 level of straight-alpha sRGB texels, each colour
-- channel premultiplied by its texel's alpha and alpha unchanged. Trailing
-- bytes short of a whole texel are not texels and are dropped.
premultiplyRgba8 ∷ ByteString → ByteString
premultiplyRgba8 bytes = ByteString.unsafeCreate (4 * count) $ \pointer →
  for_ [0 .. count - 1] $ \n → do
    let at = 4 * n
        alpha = ByteString.unsafeIndex bytes (at + 3)
    for_ [0 .. 2] $ \channel →
      pokeByteOff pointer (at + channel) (premultiplyChannel alpha (ByteString.unsafeIndex bytes (at + channel)))
    pokeByteOff pointer (at + 3) alpha
  where
    count = ByteString.length bytes `div` 4

-- | Indexed by alpha × 256 + channel.
table ∷ ByteString
table = ByteString.pack [entry alpha channel | alpha ← [0 .. 255], channel ← [0 .. 255]]
{-# NOINLINE table #-}

entry ∷ Int → Int → Word8
entry alpha channel
  | alpha == 0 = 0
  | alpha == 255 = fromIntegral channel
  | otherwise =
      let linear = toLinear (fromIntegral channel / 255) * fromIntegral alpha / 255
       in fromIntegral (min 255 (floor (fromLinear linear * 255 + 0.5) ∷ Int))

-- | The sRGB transfer function's decoding direction, encoded value to linear
-- light, both in [0, 1].
toLinear ∷ Double → Double
toLinear encoded
  | encoded <= 0.04045 = encoded / 12.92
  | otherwise = ((encoded + 0.055) / 1.055) ** 2.4

-- | The sRGB transfer function's encoding direction, linear light to encoded
-- value, both in [0, 1].
fromLinear ∷ Double → Double
fromLinear linear
  | linear <= 0.0031308 = linear * 12.92
  | otherwise = 1.055 * linear ** (1 / 2.4) - 0.055
