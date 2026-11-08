-- | The terrain package's component specs, composed under one @Terrain@ group.
module Test.Terrain.Spec (spec) where

import Test.Hspec (Spec, describe)
import qualified Test.Terrain.Coordinate as Coordinate
import qualified Test.Terrain.Geometry as Geometry
import qualified Test.Terrain.Growth as Growth
import qualified Test.Terrain.Opacity as Opacity
import qualified Test.Terrain.Opening as Opening
import qualified Test.Terrain.Query as Query
import qualified Test.Terrain.Reference as Reference
import qualified Test.Terrain.Resident as Resident
import qualified Test.Terrain.Residency as Residency
import qualified Test.Terrain.ResidencyCycle as ResidencyCycle
import qualified Test.Terrain.ResidencyProperty as ResidencyProperty
import qualified Test.Terrain.Segment as Segment
import qualified Test.Terrain.Shape as Shape
import qualified Test.Terrain.Source as Source

spec ∷ Spec
spec = describe "Terrain" $ do
  Coordinate.spec
  Shape.spec
  Geometry.spec
  Opening.spec
  Reference.spec
  Source.spec
  Segment.spec
  Query.spec
  Resident.spec
  Residency.spec
  ResidencyCycle.spec
  ResidencyProperty.spec
  Growth.spec
  Opacity.spec
