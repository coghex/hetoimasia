-- | The package's component specs, composed under one group.
module Test.TerrainRender2D.Spec (spec) where

import Test.Hspec (Spec, describe)
import qualified Test.TerrainRender2D.Camera as Camera
import qualified Test.TerrainRender2D.Opacity as Opacity
import qualified Test.TerrainRender2D.Ordering as Ordering
import qualified Test.TerrainRender2D.Pick as Pick
import qualified Test.TerrainRender2D.Planning as Planning
import qualified Test.TerrainRender2D.Projection as Projection

spec ∷ Spec
spec = describe "TerrainRender2D" $ do
  Projection.spec
  Camera.spec
  Planning.spec
  Ordering.spec
  Pick.spec
  Opacity.spec
