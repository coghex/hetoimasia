-- | The render-2d package's component specs, composed under one @TwoD@ group.
module Test.Render.TwoD.Spec (spec) where

import qualified Test.Render.TwoD.Chunks as Chunks
import qualified Test.Render.TwoD.DrawPlan as DrawPlan
import qualified Test.Render.TwoD.Encoding as Encoding
import qualified Test.Render.TwoD.Flags as Flags
import qualified Test.Render.TwoD.Mapping as Mapping
import qualified Test.Render.TwoD.Materials as Materials
import qualified Test.Render.TwoD.Opacity as Opacity
import qualified Test.Render.TwoD.Snapping as Snapping
import qualified Test.Render.TwoD.Validation as Validation
import qualified Test.Render.TwoD.ZoomSteps as ZoomSteps
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "TwoD" $ do
  Validation.spec
  ZoomSteps.spec
  Mapping.spec
  Snapping.spec
  Encoding.spec
  DrawPlan.spec
  Chunks.spec
  Materials.spec
  Flags.spec
  Opacity.spec
