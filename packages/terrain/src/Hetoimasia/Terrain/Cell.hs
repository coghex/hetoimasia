-- | Authored materials, cell values and Z intervals.
--
-- A cell holds 'Air', a 'Solid' material with a side identity, or a
-- 'CornerSolid' material with a corner mask ('cornerCell' resolves mask zero to
-- air). 'cellShapeKey' gives the tagged key a stored cell reads as. Empty space
-- is a value; it is never a material that needs an allocation, and it is not
-- the same as an unmaterialized cell (see "Hetoimasia.Terrain.Resident").
--
-- A 'MaterialId' is an authored identifier: nonempty validated text of at most
-- 'maxMaterialIdBytes' UTF-8 bytes with no control character and no surrogate
-- code point. 'mkMaterialId' is the only way to make one.
--
-- A 'ZRange' is a half-open interval @[lo, hi)@ of cell levels. The lower end is
-- a supported level (@-2^62 .. 2^62 - 1@); the exclusive upper end may be one
-- past the highest supported level, @2^62@, so the last supported cell is
-- reachable. An empty or inverted interval, a lower end outside the range and
-- an upper end beyond @2^62@ are each refused, never clamped.
--
-- State, ownership and lifetime: none. Every value is immutable and every
-- function pure.
module Hetoimasia.Terrain.Cell
  ( -- * Materials
    MaterialId
  , MaterialIdError (..)
  , maxMaterialIdBytes
  , maxAuthoredMaterials
  , mkMaterialId
  , materialIdString
  , materialIdBytes

    -- * Cells
  , Cell (..)
  , cornerCell
  , cellShapeKey
  , cellOccupant

    -- * Z intervals
  , ZRange
  , IntervalError (..)
  , mkZRange
  , zRangeLo
  , zRangeHi
  , zRangeLevels

    -- * Columns
  , Column (..)
  , mkColumn
  ) where

import Hetoimasia.Terrain.Internal.Cell
