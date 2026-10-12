-- | The math package's component specs, composed under one @Math@ group.
module Test.Math.Spec (spec) where

import qualified Test.Math.Affine2 as Affine2
import qualified Test.Math.Matrix as Matrix
import qualified Test.Math.Projection as Projection
import qualified Test.Math.Transform as Transform
import qualified Test.Math.Vector as Vector
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Math" $ do
  Vector.spec
  Matrix.spec
  Transform.spec
  Affine2.spec
  Projection.spec
