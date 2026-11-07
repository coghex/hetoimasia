-- | Checked terrain tile identity and region decomposition.
--
-- A tile coordinate is three signed 64-bit axis values, each in the supported
-- range @[-2^62, 2^62 - 1]@ ('axisMinValue' to 'axisMaxValue'). Construction
-- and arithmetic compute in 'Integer' and refuse an out-of-range result with
-- 'AxisOutOfRange'; nothing wraps, truncates or saturates, and no floating-point
-- value is ever a tile identity.
--
-- Regions are keys and index calculations only. A region is 16 columns on X, 16
-- on Y and 32 levels on Z; constructing, translating or decomposing a
-- coordinate allocates no terrain volume and scans no column. Decomposition
-- uses floor division with nonnegative local remainders, so X or Y @-1@ is
-- region @-1@ local @15@, and Z @-33@ is region @-2@ local @31@.
--
-- A cell @(x, y, z)@ occupies the unit footprint and begins at elevation @z@.
-- Whole-cell cutaway level @k@ includes the cells with @z <= k@ and its
-- clipping plane is at elevation @k + 1@ ('cutawayIncludes',
-- 'cutawayPlaneElevation').
--
-- State, ownership and lifetime: none. Every value is immutable and every
-- function pure; the module has no owner, thread, resource or disposal.
module Hetoimasia.Terrain.Coordinate
  ( -- * Axis values
    AxisCoord
  , CoordinateError (..)
  , axisMinValue
  , axisMaxValue
  , axisFromInteger
  , axisValue
  , offsetAxis
  , axisDelta

    -- * Tile identity
  , TileCoord (..)
  , tileCoord
  , translateTile
  , TileDelta (..)
  , tileDelta

    -- * Regions
  , columnSize
  , regionLevels
  , RegionCoord (..)
  , LocalCoord
  , localX
  , localY
  , localZ
  , mkLocalCoord
  , decomposeTile
  , composeTile

    -- * Cutaway
  , cutawayIncludes
  , cutawayPlaneElevation
  ) where

import Data.Int (Int64)
import Data.Word (Word8)
import Hetoimasia.Terrain.Internal.Coordinate

-- | A checked tile identity. Each field is an already-checked 'AxisCoord', so
-- the constructor cannot build an out-of-range tile.
data TileCoord = TileCoord
  { tileX ∷ !AxisCoord
  , tileY ∷ !AxisCoord
  , tileZ ∷ !AxisCoord
  }
  deriving stock (Eq, Ord, Show)

-- | Check three axis values. The first axis outside the range is the one
-- reported, in the order X, Y, Z.
tileCoord ∷ Integer → Integer → Integer → Either CoordinateError TileCoord
tileCoord x y z = TileCoord <$> axisFromInteger x <*> axisFromInteger y <*> axisFromInteger z

-- | Translate by an exact offset on each axis. The sum is computed in a checked
-- wider representation and a result outside the range is refused.
translateTile ∷ Int64 → Int64 → Int64 → TileCoord → Either CoordinateError TileCoord
translateTile dx dy dz (TileCoord x y z) =
  TileCoord <$> offsetAxis x dx <*> offsetAxis y dy <*> offsetAxis z dz

-- | An exact per-axis difference between two tiles.
data TileDelta = TileDelta
  { deltaX ∷ !Int64
  , deltaY ∷ !Int64
  , deltaZ ∷ !Int64
  }
  deriving stock (Eq, Show)

-- | @tileDelta from to@ is the exact offset that takes @from@ to @to@. It is
-- available before any camera-relative floating-point conversion and never
-- overflows (see 'axisDelta'); 'translateTile' of it from @from@ gives back @to@.
tileDelta ∷ TileCoord → TileCoord → TileDelta
tileDelta (TileCoord fx fy fz) (TileCoord tx ty tz) =
  TileDelta (axisDelta fx tx) (axisDelta fy ty) (axisDelta fz tz)

-- | A region key: 16 × 16 horizontal columns and 32 vertical levels. The
-- fields are bare 'Int64' keys, so a key built by hand can name a region that
-- holds no supported tile; 'composeTile' refuses such a result.
data RegionCoord = RegionCoord
  { regionX ∷ !Int64
  , regionY ∷ !Int64
  , regionZ ∷ !Int64
  }
  deriving stock (Eq, Ord, Show)

-- | The local X offset, @0..15@.
localX ∷ LocalCoord → Word8
localX (LocalCoord x _ _) = x

-- | The local Y offset, @0..15@.
localY ∷ LocalCoord → Word8
localY (LocalCoord _ y _) = y

-- | The local Z offset, @0..31@.
localZ ∷ LocalCoord → Word8
localZ (LocalCoord _ _ z) = z

-- | Split a tile into its region key and local offset, by floor division.
decomposeTile ∷ TileCoord → (RegionCoord, LocalCoord)
decomposeTile (TileCoord x y z) =
  let (rx, lx) = splitAxis columnSize x
      (ry, ly) = splitAxis columnSize y
      (rz, lz) = splitAxis regionLevels z
   in (RegionCoord rx ry rz, LocalCoord lx ly lz)

-- | Recombine a region key and a local offset into a tile. The product and sum
-- are computed in 'Integer'; a result outside the supported range is refused.
composeTile ∷ RegionCoord → LocalCoord → Either CoordinateError TileCoord
composeTile (RegionCoord rx ry rz) (LocalCoord lx ly lz) =
  TileCoord
    <$> axisFromInteger (combine columnSize rx lx)
    <*> axisFromInteger (combine columnSize ry ly)
    <*> axisFromInteger (combine regionLevels rz lz)
  where
    combine size region local = toInteger region * toInteger size + toInteger local

-- | Whether whole-cell cutaway level @k@ includes the cell at level @z@: the
-- cells with @z <= k@ are included.
cutawayIncludes ∷ AxisCoord → AxisCoord → Bool
cutawayIncludes level cell = cell <= level

-- | The elevation of cutaway level @k@'s clipping plane, @k + 1@, as an exact
-- 'Integer' (it may be @2^62@, one above the highest cell level).
cutawayPlaneElevation ∷ AxisCoord → Integer
cutawayPlaneElevation level = toInteger (axisValue level) + 1
