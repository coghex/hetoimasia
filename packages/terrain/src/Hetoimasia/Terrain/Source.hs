-- | The immutable declarative terrain source: authored materials, base layers
-- shared by every column, and bounded per-column patches.
--
-- A definition is plain data ('SourceSpec'): a list of unique material
-- identifiers, a sorted list of non-overlapping half-open @[z_min, z_max)@
-- layers shared by all columns, and a list of @(x, y, z_min, z_max, value)@
-- patches that override the base with air or a material and shape. An omitted
-- layer endpoint means the supported extreme; an omitted upper end is one past
-- the highest level, so the last supported cell is covered. A level no layer or
-- patch covers is air. There is no callback, Lua value, random stream or
-- game-specific generator: soil over stone is an ordinary pair of layers a
-- caller supplies, for example @stone [-inf, -3)@ under @soil [-3, 1)@.
--
-- 'mkSource' validates the whole definition and returns a 'Source' or the first
-- refusal; no partial source exists. It refuses an overlapping layer (and a
-- layer out of order), overlapping patches in one column, an invalid or empty
-- interval, a coordinate outside the supported range, a duplicate or unknown
-- material, a shape outside @0..15@ and an oversized definition. Creating a
-- source instantiates no column and no buried cell; its size is its authored
-- records.
--
-- == Limits and accounting
--
-- A definition is bounded by 'SourceLimits' (the initial approved values are
-- 'defaultSourceLimits': 256 KiB and 8,192 authored runs) and by
-- 'maxAuthoredMaterials' (4,095, the non-air palette indices). An /authored
-- run/ is every layer and every patch; materials are not runs. The byte
-- accounting is conservative and fixed: 'definitionHeaderBytes' once, plus
-- 'materialRecordBytes' and the identifier's UTF-8 length per material, plus
-- 'layerRecordBytes' per layer and 'patchRecordBytes' per patch. It is an
-- accounting figure for admission, not a statement about heap or process
-- memory. Counts are taken with traversals that stop one past a bound and the
-- total is computed in 'Integer', so a limit is decided before any record is
-- validated or stored and an oversized definition costs work bounded by the
-- limit, not by its length.
--
-- State, ownership and lifetime: none. A 'Source' is immutable and pure.
module Hetoimasia.Terrain.Source
  ( -- * Definition
    SourceSpec (..)
  , LayerSpec (..)
  , PatchSpec (..)
  , CellSpec (..)

    -- * Limits and accounting
  , SourceLimits (..)
  , defaultSourceLimits
  , definitionHeaderBytes
  , materialRecordBytes
  , layerRecordBytes
  , patchRecordBytes

    -- * Validation
  , Source
  , SourceError (..)
  , RecordRef (..)
  , mkSource

    -- * Inspection
  , sourceMaterials
  , sourceLayerCount
  , sourcePatchCount
  , sourceAuthoredRuns
  , sourceDefinitionBytes
  ) where

import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Internal.Source

-- | The declared materials in authored order.
sourceMaterials ∷ Source → [MaterialId]
sourceMaterials = sourceMaterialList

-- | The number of base layers.
sourceLayerCount ∷ Source → Int
sourceLayerCount = sourceLayerTotal

-- | The number of patches.
sourcePatchCount ∷ Source → Int
sourcePatchCount = sourcePatchTotal

-- | Layers plus patches: the quantity 'limitAuthoredRuns' bounds.
sourceAuthoredRuns ∷ Source → Int
sourceAuthoredRuns source = sourceLayerTotal source + sourcePatchTotal source

-- | The definition's conservative accounted size.
sourceDefinitionBytes ∷ Source → Int
sourceDefinitionBytes = sourceByteTotal
