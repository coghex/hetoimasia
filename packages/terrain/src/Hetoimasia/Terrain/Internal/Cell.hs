-- | The cell value, material identity and Z-interval representations behind
-- "Hetoimasia.Terrain.Cell".
--
-- Private to the package: the constructors of 'MaterialId' and 'ZRange' are
-- reachable only from inside it, so a client can obtain either value only
-- through a checking constructor.
--
-- State, ownership and lifetime: none. Every value is immutable and every
-- function pure; nothing here allocates a terrain volume.
module Hetoimasia.Terrain.Internal.Cell
  ( -- * Materials
    MaterialId (..)
  , MaterialIdError (..)
  , maxMaterialIdBytes
  , maxAuthoredMaterials
  , mkMaterialId
  , materialIdString
  , materialIdBytes
  , utf8LengthCapped

    -- * Cells
  , Cell (..)

    -- * Z intervals
  , ZRange (..)
  , IntervalError (..)
  , bottomLevel
  , topExclusive
  , mkZRange
  , zRangeLo
  , zRangeHi
  , zRangeLevels

    -- * Columns
  , Column (..)
  , mkColumn
  ) where

import Data.Char (isControl)
import Data.Int (Int64)
import Hetoimasia.Terrain.Internal.Coordinate
import Hetoimasia.Terrain.Internal.Shape (ShapeId)

-- | A validated authored material identifier: nonempty text of at most
-- 'maxMaterialIdBytes' UTF-8 bytes with no control character and no surrogate
-- code point. The constructor is private.
newtype MaterialId = MaterialId String
  deriving stock (Eq, Ord, Show)

-- | Why an authored material identifier was refused.
data MaterialIdError
  = EmptyMaterialId
  | -- | Longer than this many UTF-8 bytes.
    MaterialIdTooLong !Int
  | -- | A control character or a surrogate code point, which is not valid
    -- UTF-8 text.
    InvalidMaterialChar !Char
  deriving stock (Eq, Show)

-- | The longest accepted material identifier, in UTF-8 bytes.
maxMaterialIdBytes ∷ Int
maxMaterialIdBytes = 64

-- | The most materials a source may declare: the non-air palette indices
-- @1..4095@ of a 12-bit index.
maxAuthoredMaterials ∷ Int
maxAuthoredMaterials = 4095

-- | Check an authored identifier. The scan stops at the first refusal and
-- never reads past 'maxMaterialIdBytes' bytes of a longer input.
mkMaterialId ∷ String → Either MaterialIdError MaterialId
mkMaterialId [] = Left EmptyMaterialId
mkMaterialId text = go 0 text
  where
    go ∷ Int → String → Either MaterialIdError MaterialId
    go _ [] = Right (MaterialId text)
    go used (c : cs)
      | invalidChar c = Left (InvalidMaterialChar c)
      | used + charBytes c > maxMaterialIdBytes = Left (MaterialIdTooLong maxMaterialIdBytes)
      | otherwise = go (used + charBytes c) cs
    invalidChar c = isControl c || (fromEnum c >= 0xD800 && fromEnum c <= 0xDFFF)

-- | The text of a validated identifier.
materialIdString ∷ MaterialId → String
materialIdString (MaterialId text) = text

-- | The UTF-8 byte length of a validated identifier.
materialIdBytes ∷ MaterialId → Int
materialIdBytes (MaterialId text) = sum (map charBytes text)

charBytes ∷ Char → Int
charBytes c
  | n < 0x80 = 1
  | n < 0x800 = 2
  | n < 0x10000 = 3
  | otherwise = 4
  where
    n = fromEnum c

-- | The UTF-8 length of unvalidated text, counted no further than @cap@: the
-- result is at most @cap@, so scanning an oversized identifier is bounded.
utf8LengthCapped ∷ Int → String → Int
utf8LengthCapped cap = go 0
  where
    go used [] = used
    go used (c : cs)
      | used >= cap = cap
      | otherwise = go (used + charBytes c) cs

-- | What one cell holds: empty space, or a material with a shape. Air is a
-- value, never a material that needs an allocation.
data Cell
  = Air
  | Solid !MaterialId !ShapeId
  deriving stock (Eq, Ord, Show)

-- | A half-open Z interval @[lo, hi)@ of cell levels inside the supported
-- range. The lower endpoint is a supported level; the exclusive upper endpoint
-- may be one past the highest supported level, so the last supported cell is
-- reachable. The constructor is private.
data ZRange = ZRange !Int64 !Int64
  deriving stock (Eq, Ord, Show)

-- | Why a Z interval was refused.
data IntervalError
  = -- | A lower endpoint outside @[-2^62, 2^62 - 1]@.
    LowerOutOfRange !Integer
  | -- | An exclusive upper endpoint above @2^62@, one past the highest level.
    UpperOutOfRange !Integer
  | -- | The interval is empty or inverted: @lo >= hi@.
    EmptyInterval !Integer !Integer
  deriving stock (Eq, Show)

-- | The lowest supported level.
bottomLevel ∷ Int64
bottomLevel = negate (2 ^ (62 ∷ Int))

-- | One past the highest supported level: the largest exclusive endpoint.
topExclusive ∷ Int64
topExclusive = 2 ^ (62 ∷ Int)

-- | Check a half-open interval. The lower endpoint must be a supported level,
-- the exclusive end at most one past the highest, and the interval nonempty.
mkZRange ∷ Integer → Integer → Either IntervalError ZRange
mkZRange lo hi
  | lo < axisMinValue || lo > axisMaxValue = Left (LowerOutOfRange lo)
  | hi > axisMaxValue + 1 = Left (UpperOutOfRange hi)
  | hi <= lo = Left (EmptyInterval lo hi)
  | otherwise = Right (ZRange (fromInteger lo) (fromInteger hi))

-- | The inclusive lower endpoint.
zRangeLo ∷ ZRange → Integer
zRangeLo (ZRange lo _) = toInteger lo

-- | The exclusive upper endpoint, at most one past the highest level.
zRangeHi ∷ ZRange → Integer
zRangeHi (ZRange _ hi) = toInteger hi

-- | The number of levels, exactly.
zRangeLevels ∷ ZRange → Integer
zRangeLevels (ZRange lo hi) = toInteger hi - toInteger lo

-- | One horizontal column of cells.
data Column = Column
  { columnX ∷ !AxisCoord
  , columnY ∷ !AxisCoord
  }
  deriving stock (Eq, Ord, Show)

-- | Check two integer axis values.
mkColumn ∷ Integer → Integer → Either CoordinateError Column
mkColumn x y = Column <$> axisFromInteger x <*> axisFromInteger y
