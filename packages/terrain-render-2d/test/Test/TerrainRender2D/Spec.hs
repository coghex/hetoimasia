-- | The package's component specs, composed under one group.
module Test.TerrainRender2D.Spec (spec) where

import Test.Hspec (Spec, describe)
import qualified Test.TerrainRender2D.Atlas as Atlas
import qualified Test.TerrainRender2D.AtlasAssets as AtlasAssets
import qualified Test.TerrainRender2D.Camera as Camera
import qualified Test.TerrainRender2D.Cells as Cells
import qualified Test.TerrainRender2D.CellsClient as CellsClient
import qualified Test.TerrainRender2D.CellsCoverage as CellsCoverage
import qualified Test.TerrainRender2D.CellsEvidence as CellsEvidence
import qualified Test.TerrainRender2D.CellsProgress as CellsProgress
import qualified Test.TerrainRender2D.CellsWork as CellsWork
import qualified Test.TerrainRender2D.Expectation as Expectation
import qualified Test.TerrainRender2D.MapAssets as MapAssets
import qualified Test.TerrainRender2D.Material as Material
import qualified Test.TerrainRender2D.ReferenceTint as ReferenceTint
import qualified Test.TerrainRender2D.TexelRule as TexelRule
import qualified Test.TerrainRender2D.Projection as Projection

spec ∷ Spec
spec = describe "TerrainRender2D" $ do
  Projection.spec
  Camera.spec
  MapAssets.spec
  Material.spec
  Expectation.spec
  ReferenceTint.spec
  TexelRule.spec
  Atlas.spec
  AtlasAssets.spec
  Cells.spec
  CellsCoverage.spec
  CellsProgress.spec
  CellsWork.spec
  CellsClient.spec
  CellsEvidence.spec
