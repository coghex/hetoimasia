-- | An independent, deliberately naive model of terrain content, and the
-- builders the source/storage specs share.
--
-- The model reads a 'SourceSpec' as plain data and answers by scanning every
-- layer, patch and removal for every level it is asked about. It shares no code
-- with the library: it does not step across intervals, does not use a map and
-- does not mirror the encoding selection. Every comparison in the specs is
-- between the library and this model, or against a literal.
module Test.Terrain.Model
  ( -- * Builders
    lowest
  , highest
  , topEnd
  , mustSource
  , mustTile
  , mustColumn
  , mustRange
  , mustMaterial
  , cellOf
  , solidSpec
  , layer
  , softLayer
  , patchAir
  , patchSolid
  , soilOverStone
  , fromCell

    -- * The model
  , Removal
  , modelCell
  , modelRuns
  , modelHighest
  ) where

import Data.List (group)
import Data.Maybe (fromMaybe)
import Hetoimasia.Terrain.Cell
import Hetoimasia.Terrain.Coordinate
import Hetoimasia.Terrain.Shape
import Hetoimasia.Terrain.Source

lowest, highest, topEnd ∷ Integer
lowest = -4611686018427387904
highest = 4611686018427387903
topEnd = 4611686018427387904

mustSource ∷ SourceSpec → Source
mustSource = either (error . ("source refused: " <>) . show) id . mkSource defaultSourceLimits

mustTile ∷ Integer → Integer → Integer → TileCoord
mustTile x y z = either (error . show) id (tileCoord x y z)

mustColumn ∷ Integer → Integer → Column
mustColumn x y = either (error . show) id (mkColumn x y)

mustRange ∷ Integer → Integer → ZRange
mustRange lo hi = either (error . show) id (mkZRange lo hi)

mustMaterial ∷ String → MaterialId
mustMaterial = either (error . show) id . mkMaterialId

cellOf ∷ String → Int → Cell
cellOf material shape = Solid (mustMaterial material) (either (error . show) id (mkShapeId shape))

-- | The model's reading of a library cell.
fromCell ∷ Cell → Maybe (String, Int)
fromCell Air = Nothing
fromCell (Solid material shape) = Just (materialIdString material, shapeIdValue shape)

solidSpec ∷ String → Int → CellSpec
solidSpec = SpecSolid

-- | A layer with both endpoints given.
layer ∷ Integer → Integer → String → Int → LayerSpec
layer lo hi = LayerSpec (Just lo) (Just hi)

-- | A layer with the endpoints as given, possibly omitted.
softLayer ∷ Maybe Integer → Maybe Integer → String → Int → LayerSpec
softLayer = LayerSpec

patchAir ∷ Integer → Integer → Integer → Integer → PatchSpec
patchAir x y lo hi = PatchSpec x y lo hi SpecAir

patchSolid ∷ Integer → Integer → Integer → Integer → String → Int → PatchSpec
patchSolid x y lo hi material shape = PatchSpec x y lo hi (SpecSolid material shape)

-- | The configured fixture: stone from the lowest level up to @-3@ and soil over
-- it on @[-3, 1)@. The thickness and identifiers are ordinary parameters of the
-- generic layers.
soilOverStone ∷ SourceSpec
soilOverStone =
  SourceSpec
    { specMaterials = ["soil", "stone"]
    , specLayers = [softLayer Nothing (Just (-3)) "stone" 0, layer (-3) 1 "soil" 0]
    , specPatches = []
    }

-- | A removed interval in a column: @(x, y, lo, hi)@.
type Removal = (Integer, Integer, Integer, Integer)

-- | The cell at @(x, y, z)@, found by scanning every record.
modelCell ∷ SourceSpec → [Removal] → (Integer, Integer, Integer) → Maybe (String, Int)
modelCell spec removals (x, y, z)
  | or [rx == x && ry == y && lo <= z && z < hi | (rx, ry, lo, hi) ← removals] = Nothing
  | (value : _) ← [patchValue p | p ← specPatches spec, patchX p == x, patchY p == y, patchMin p <= z, z < patchMax p] =
      case value of
        SpecAir → Nothing
        SpecSolid material shape → Just (material, shape)
  | (found : _) ←
      [ (layerMaterial l, layerShape l)
      | l ← specLayers spec
      , fromMaybe lowest (layerMin l) <= z
      , z < fromMaybe topEnd (layerMax l)
      ] =
      Just found
  | otherwise = Nothing

-- | The runs of @[lo, hi)@, level by level then grouped.
modelRuns ∷ SourceSpec → [Removal] → Integer → Integer → Integer → Integer → [(Integer, Integer, Maybe (String, Int))]
modelRuns spec removals x y lo hi = go lo (group [modelCell spec removals (x, y, z) | z ← [lo .. hi - 1]])
  where
    go _ [] = []
    go start (g : gs) = let end = start + toInteger (length g) in (start, end, headOr g) : go end gs
    headOr (v : _) = v
    headOr [] = Nothing

-- | The highest solid level of a column. The answer must be the top of some
-- stretch, so only the level below each interval boundary is tried.
modelHighest ∷ SourceSpec → [Removal] → Integer → Integer → Maybe (Integer, (String, Int))
modelHighest spec removals x y =
  case [(z, v) | z ← candidates, Just v ← [modelCell spec removals (x, y, z)]] of
    [] → Nothing
    found → Just (maximum' found)
  where
    boundaries =
      [topEnd]
        <> concat
          [ [fromMaybe lowest (layerMin l), fromMaybe topEnd (layerMax l)]
          | l ← specLayers spec
          ]
        <> concat [[patchMin p, patchMax p] | p ← specPatches spec, patchX p == x, patchY p == y]
        <> concat [[lo, hi] | (rx, ry, lo, hi) ← removals, rx == x, ry == y]
    candidates = [b - 1 | b ← boundaries, b - 1 >= lowest, b - 1 <= highest]
    maximum' = foldr1 (\a b -> if fst a >= fst b then a else b)
