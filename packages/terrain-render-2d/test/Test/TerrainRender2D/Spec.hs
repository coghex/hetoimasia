-- | The package's component specs, composed under one group.
module Test.TerrainRender2D.Spec (spec) where

import Test.Hspec (Spec, describe)
import qualified Test.TerrainRender2D.Camera as Camera
import qualified Test.TerrainRender2D.Generated as Generated
import qualified Test.TerrainRender2D.MapAssets as MapAssets
import qualified Test.TerrainRender2D.Material as Material
import qualified Test.TerrainRender2D.Opacity as Opacity
import qualified Test.TerrainRender2D.Ordering as Ordering
import qualified Test.TerrainRender2D.Pick as Pick
import qualified Test.TerrainRender2D.Planning as Planning
import qualified Test.TerrainRender2D.Projection as Projection
import qualified Test.TerrainRender2D.Scenes as Scenes

spec ∷ Spec
spec = describe "TerrainRender2D" $ do
  Projection.spec
  Camera.spec
  Planning.spec
  Ordering.spec
  Pick.spec
  Generated.spec
  Opacity.spec
  Material.spec
  Scenes.spec
  MapAssets.spec
