-- | The checked representation behind "Hetoimasia.Terrain.Coordinate".
--
-- This module is private: the package does not expose it, so the constructor of
-- 'AxisCoord' and of 'LocalCoord' is reachable only from inside the package. A
-- client can obtain either value only through a checking constructor, which is
-- what makes an out-of-range tile identity unrepresentable.
--
-- State, ownership and lifetime: none. Every value is immutable and every
-- function is pure; nothing here allocates a terrain volume, owns a resource or
-- reads ambient state.
module Hetoimasia.Terrain.Internal.Coordinate
  ( AxisCoord (..)
  , CoordinateError (..)
  , axisMinValue
  , axisMaxValue
  , axisFromInteger
  , axisValue
  , offsetAxis
  , axisDelta
  , LocalCoord (..)
  , mkLocalCoord
  , columnSize
  , regionLevels
  , splitAxis
  ) where

import Data.Int (Int64)
import Data.Word (Word8)

-- | One axis of a tile coordinate: a signed 64-bit value in
-- @[axisMinValue, axisMaxValue]@. The constructor is private to the package.
newtype AxisCoord = AxisCoord Int64
  deriving stock (Eq, Ord, Show)

-- | Why a coordinate operation refused its input.
data CoordinateError
  = -- | A tile axis value outside the supported range; the value is the refused
    -- one, held exactly in a wider representation.
    AxisOutOfRange !Integer
  | -- | A local offset outside its region: the refused value and the exclusive
    -- upper limit of that axis.
    LocalOutOfRange !Integer !Integer
  deriving stock (Eq, Show)

-- | The lowest supported tile coordinate on every axis, @-2^62@.
axisMinValue ∷ Integer
axisMinValue = negate (2 ^ (62 ∷ Int))

-- | The highest supported tile coordinate on every axis, @2^62 - 1@.
axisMaxValue ∷ Integer
axisMaxValue = 2 ^ (62 ∷ Int) - 1

-- | Check a value against the supported range. The check is made on the exact
-- 'Integer', so no wider input can wrap, truncate or saturate.
axisFromInteger ∷ Integer → Either CoordinateError AxisCoord
axisFromInteger value
  | value < axisMinValue || value > axisMaxValue = Left (AxisOutOfRange value)
  | otherwise = Right (AxisCoord (fromInteger value))

-- | The exact signed 64-bit value of a checked coordinate.
axisValue ∷ AxisCoord → Int64
axisValue (AxisCoord value) = value

-- | Add a signed offset, computed in a checked wider representation; a result
-- outside the supported range is refused, never wrapped.
offsetAxis ∷ AxisCoord → Int64 → Either CoordinateError AxisCoord
offsetAxis (AxisCoord base) offset = axisFromInteger (toInteger base + toInteger offset)

-- | The exact difference @target - origin@. Both operands lie in
-- @[-2^62, 2^62 - 1]@, so the difference lies in @[-(2^63 - 1), 2^63 - 1]@ and
-- always fits a signed 64-bit integer: no wider type is needed to keep it exact.
axisDelta ∷ AxisCoord → AxisCoord → Int64
axisDelta (AxisCoord origin) (AxisCoord target) = target - origin

-- | A tile's offset inside its region: X and Y in @[0, 15]@, Z in @[0, 31]@.
-- The constructor is private to the package.
data LocalCoord = LocalCoord !Word8 !Word8 !Word8
  deriving stock (Eq, Ord, Show)

-- | The horizontal extent of one column of tiles on each of X and Y.
columnSize ∷ Int
columnSize = 16

-- | The number of tile levels in one vertical region.
regionLevels ∷ Int
regionLevels = 32

-- | Check a local offset against the 16 × 16 × 32 region.
mkLocalCoord ∷ Integer → Integer → Integer → Either CoordinateError LocalCoord
mkLocalCoord x y z = do
  x' ← within (toInteger columnSize) x
  y' ← within (toInteger columnSize) y
  z' ← within (toInteger regionLevels) z
  pure (LocalCoord x' y' z')
  where
    within limit value
      | value < 0 || value >= limit = Left (LocalOutOfRange value limit)
      | otherwise = Right (fromInteger value)

-- | Floor division of a checked coordinate by a positive region size, with the
-- nonnegative remainder. @divMod@ on 'Int64' rounds toward negative infinity,
-- which is what negative coordinates need: @-1@ is @(-1, size - 1)@.
splitAxis ∷ Int → AxisCoord → (Int64, Word8)
splitAxis size (AxisCoord value) =
  let (region, local) = value `divMod` fromIntegral size
   in (region, fromIntegral local)
