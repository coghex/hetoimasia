-- | The validated declarative source behind "Hetoimasia.Terrain.Source".
--
-- Private to the package: the constructor of 'Source' is reachable only from
-- here, so a client can hold a source only after 'mkSource' validated the whole
-- definition. Nothing is exposed for a definition that fails any check.
--
-- State, ownership and lifetime: none. A 'Source' is immutable. It holds the
-- authored layers and patches only, never a column, a buried cell or a
-- per-column stack.
module Hetoimasia.Terrain.Internal.Source
  ( SourceSpec (..)
  , LayerSpec (..)
  , PatchSpec (..)
  , CellSpec (..)
  , SourceLimits (..)
  , defaultSourceLimits
  , RecordRef (..)
  , SourceError (..)
  , Source (..)
  , mkSource
  , definitionHeaderBytes
  , materialRecordBytes
  , layerRecordBytes
  , patchRecordBytes
  ) where

import Control.Monad (foldM)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Hetoimasia.Terrain.Internal.Cell
import Hetoimasia.Terrain.Internal.Coordinate
import Hetoimasia.Terrain.Internal.Interval
import Hetoimasia.Terrain.Internal.Shape

-- | What a patch holds: air, or a declared material with a shape identity.
data CellSpec
  = SpecAir
  | SpecSolid String Int
  deriving stock (Eq, Show)

-- | A base layer shared by every column: @[layerMin, layerMax)@ of one
-- material and shape. An omitted lower end means the lowest supported level;
-- an omitted upper end means one past the highest, so the last supported cell
-- is covered.
data LayerSpec = LayerSpec
  { layerMin ∷ Maybe Integer
  , layerMax ∷ Maybe Integer
  , layerMaterial ∷ String
  , layerShape ∷ Int
  }
  deriving stock (Eq, Show)

-- | A bounded override of one column's span: @[patchMin, patchMax)@ at
-- @(patchX, patchY)@ becomes air or a material with a shape.
data PatchSpec = PatchSpec
  { patchX ∷ Integer
  , patchY ∷ Integer
  , patchMin ∷ Integer
  , patchMax ∷ Integer
  , patchValue ∷ CellSpec
  }
  deriving stock (Eq, Show)

-- | An unvalidated source definition: unique authored materials, sorted
-- nonoverlapping layers, and column patches. Intervals no layer or patch
-- covers are air.
data SourceSpec = SourceSpec
  { specMaterials ∷ [String]
  , specLayers ∷ [LayerSpec]
  , specPatches ∷ [PatchSpec]
  }
  deriving stock (Eq, Show)

-- | The caller-supplied bounds on a definition. The initial approved values
-- are 'defaultSourceLimits'.
data SourceLimits = SourceLimits
  { limitDefinitionBytes ∷ !Int
  , limitAuthoredRuns ∷ !Int
  }
  deriving stock (Eq, Show)

-- | 256 KiB per definition and 8,192 authored runs (layers plus patches).
defaultSourceLimits ∷ SourceLimits
defaultSourceLimits = SourceLimits {limitDefinitionBytes = 256 * 1024, limitAuthoredRuns = 8192}

-- | Which record of the definition an error names, counted from zero in the
-- order supplied.
data RecordRef = LayerRecord !Int | PatchRecord !Int
  deriving stock (Eq, Show)

-- | Why a definition was refused. The whole definition is checked before any
-- value is exposed.
data SourceError
  = -- | More than 'maxAuthoredMaterials' materials; the field is that bound.
    TooManyMaterials !Int
  | -- | More authored runs (layers plus patches) than the limit.
    TooManyAuthoredRuns !Int
  | -- | The conservative byte accounting exceeded the limit: the total and the
    -- limit.
    DefinitionTooLarge !Integer !Int
  | -- | The material at this index of the list is not a valid identifier.
    InvalidMaterialId !Int !MaterialIdError
  | -- | The identifier at this index repeats an earlier one.
    DuplicateMaterialId !Int String
  | -- | A layer or patch names a material the definition does not declare.
    UnknownMaterial !RecordRef String
  | -- | A shape identity outside @0..15@.
    InvalidShape !RecordRef !Int
  | InvalidInterval !RecordRef !IntervalError
  | -- | A layer that begins before the previous layer begins.
    LayersOutOfOrder !Int
  | -- | A layer that begins before the previous layer ends.
    OverlappingLayers !Int
  | InvalidPatchCoordinate !Int !CoordinateError
  | -- | A patch overlapping another patch in its column.
    OverlappingPatches !Int
  deriving stock (Eq, Show)

-- | A validated, immutable source.
data Source = Source
  { sourceMaterialList ∷ ![MaterialId]
  , sourceLayerMap ∷ !(IntervalMap Cell)
  , sourcePatchMap ∷ !(Map Column (IntervalMap Cell))
  , sourceLayerTotal ∷ !Int
  , sourcePatchTotal ∷ !Int
  , sourceByteTotal ∷ !Int
  }
  deriving stock (Eq, Show)

-- | Fixed bytes charged to every definition.
definitionHeaderBytes ∷ Int
definitionHeaderBytes = 64

-- | Bytes charged to one material, plus its UTF-8 identifier length.
materialRecordBytes ∷ Int
materialRecordBytes = 16

-- | Bytes charged to one layer: two endpoints, a material reference and a shape.
layerRecordBytes ∷ Int
layerRecordBytes = 24

-- | Bytes charged to one patch: two column coordinates, two endpoints and a
-- value.
patchRecordBytes ∷ Int
patchRecordBytes = 40

-- | Validate a whole definition. Counts and the byte total are decided first,
-- from bounded traversals that never read further than one past a bound, so an
-- oversized definition is refused without a result proportional to it; then
-- every record is checked, and the first refusal is returned.
mkSource ∷ SourceLimits → SourceSpec → Either SourceError Source
mkSource limits spec = do
  let materialCount = boundedLength (maxAuthoredMaterials + 1) (specMaterials spec)
      runBound = max 0 (limitAuthoredRuns limits)
      layerCount = boundedLength (runBound + 1) (specLayers spec)
      patchCount = boundedLength (runBound + 1) (specPatches spec)
  if materialCount > maxAuthoredMaterials then Left (TooManyMaterials maxAuthoredMaterials) else pure ()
  if layerCount + patchCount > runBound then Left (TooManyAuthoredRuns runBound) else pure ()
  let total =
        toInteger definitionHeaderBytes
          + sum [toInteger (materialRecordBytes + utf8LengthCapped (maxMaterialIdBytes + 1) m) | m ← specMaterials spec]
          + toInteger layerCount * toInteger layerRecordBytes
          + toInteger patchCount * toInteger patchRecordBytes
  if total > toInteger (limitDefinitionBytes limits)
    then Left (DefinitionTooLarge total (limitDefinitionBytes limits))
    else pure ()
  palette ← buildMaterials (specMaterials spec)
  layers ← buildLayers palette (specLayers spec)
  patches ← buildPatches palette (specPatches spec)
  pure
    Source
      { sourceMaterialList = map snd (toList' palette)
      , sourceLayerMap = layers
      , sourcePatchMap = patches
      , sourceLayerTotal = layerCount
      , sourcePatchTotal = patchCount
      , sourceByteTotal = fromInteger total
      }
  where
    toList' m = Map.toAscList (Map.fromList [(i, mid) | (mid, i) ← Map.toList m])

boundedLength ∷ Int → [a] → Int
boundedLength bound = length . take bound

type MaterialTable = Map MaterialId Int

buildMaterials ∷ [String] → Either SourceError MaterialTable
buildMaterials = foldM step Map.empty . zip [0 ..]
  where
    step table (index, text) = do
      identifier ← either (Left . InvalidMaterialId index) Right (mkMaterialId text)
      if Map.member identifier table
        then Left (DuplicateMaterialId index text)
        else pure (Map.insert identifier index table)

resolveCell ∷ MaterialTable → RecordRef → String → Int → Either SourceError Cell
resolveCell table ref material shape = do
  shapeId ← either (const (Left (InvalidShape ref shape))) Right (mkShapeId shape)
  identifier ← either (const (Left (UnknownMaterial ref material))) Right (mkMaterialId material)
  if Map.member identifier table
    then Right (Solid identifier shapeId)
    else Left (UnknownMaterial ref material)

buildLayers ∷ MaterialTable → [LayerSpec] → Either SourceError (IntervalMap Cell)
buildLayers table specs = fst <$> foldM step (Map.empty, Nothing) (zip [0 ..] specs)
  where
    step (acc, previous) (index, layer) = do
      let ref = LayerRecord index
          lo = fromMaybe axisMinValue (layerMin layer)
          hi = fromMaybe (axisMaxValue + 1) (layerMax layer)
      range ← either (Left . InvalidInterval ref) Right (mkZRange lo hi)
      cell ← resolveCell table ref (layerMaterial layer) (layerShape layer)
      let ZRange l h = range
      case previous of
        Just (prevLo, prevHi)
          | l < prevLo → Left (LayersOutOfOrder index)
          | l < prevHi → Left (OverlappingLayers index)
        _ → pure ()
      pure (Map.insert l (h, cell) acc, Just (l, h ∷ Int64))

buildPatches ∷ MaterialTable → [PatchSpec] → Either SourceError (Map Column (IntervalMap Cell))
buildPatches table = foldM step Map.empty . zip [0 ..]
  where
    step acc (index, patch) = do
      let ref = PatchRecord index
      column ← either (Left . InvalidPatchCoordinate index) Right (mkColumn (patchX patch) (patchY patch))
      ZRange l h ← either (Left . InvalidInterval ref) Right (mkZRange (patchMin patch) (patchMax patch))
      cell ← case patchValue patch of
        SpecAir → Right Air
        SpecSolid material shape → resolveCell table ref material shape
      let existing = Map.findWithDefault Map.empty column acc
      case insertDisjoint l h cell existing of
        Nothing → Left (OverlappingPatches index)
        Just updated → Right (Map.insert column updated acc)
