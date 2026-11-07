-- | The terrain package's component specs, composed under one @Terrain@ group.
module Test.Terrain.Spec (spec) where

import Test.Hspec (Spec, describe)
import qualified Test.Terrain.Coordinate as Coordinate
import qualified Test.Terrain.Geometry as Geometry
import qualified Test.Terrain.Opacity as Opacity
import qualified Test.Terrain.Shape as Shape

spec ∷ Spec
spec = describe "Terrain" $ do
  Coordinate.spec
  Shape.spec
  Geometry.spec
  Opacity.spec
