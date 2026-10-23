-- | The clear colour: an sRGB byte channel from a Lua number, and its linear value.
--
-- A channel is a Lua integer, or a float that is exactly a whole number, from 0 to 255. A float with a
-- fraction, a string, a boolean, NaN, an infinity and anything out of range is refused: nothing is
-- coerced or clamped. The host's integer schema refuses 1.0, so the channel is read from the number
-- schema, which keeps which representation it was, and checked here.
--
-- The renderer's clear is linear light, and the byte is sRGB: the conversion is the sRGB transfer
-- function, so byte 128 is about 0.2159, not 0.5. This is the one conversion of the adapter.
module Hetoimasia.LuaEngine.Scene.Colour
  ( channelByte
  , linearOfByte
  , clearOfBytes
  ) where

import Data.Word (Word8)
import GHC.Float (double2Float)
import Hetoimasia.LuaEngine.Scene.Types (SceneReason (..))
import Hetoimasia.Render.TwoD.Snapshot (ClearColour (ClearColour))
import Hetoimasia.Scripting.Lua.Value (Value (VFloat, VInteger))

-- | A channel byte from a number, or why it is not one.
channelByte ∷ Value → Either SceneReason Word8
channelByte = \case
  VInteger whole
    | whole < 0 || whole > 255 → Left ChannelOutOfRange
    | otherwise → Right (fromIntegral whole)
  VFloat found
    | isNaN found || isInfinite found → Left NotFinite
    | found < 0 || found > 255 → Left ChannelOutOfRange
    | found /= fromIntegral (truncate found ∷ Int) → Left ChannelNotIntegral
    | otherwise → Right (truncate found)
  _ → Left NumberRequired

-- | The linear-light value of an sRGB byte channel, in [0, 1]: 0 and 255 are exactly 0 and 1.
linearOfByte ∷ Word8 → Float
linearOfByte byte = double2Float linear
  where
    encoded = fromIntegral byte / 255 ∷ Double
    linear
      | encoded <= 0.04045 = encoded / 12.92
      | otherwise = ((encoded + 0.055) / 1.055) ** 2.4

-- | The opaque clear colour of three channel bytes.
clearOfBytes ∷ Word8 → Word8 → Word8 → ClearColour
clearOfBytes r g b = ClearColour (linearOfByte r) (linearOfByte g) (linearOfByte b) 1
