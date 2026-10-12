-- | The render-api package's component specs, composed under one @RenderApi@
-- group.
module Test.Render.Api.Spec (spec) where

import qualified Test.Render.Api.Handle as Handle
import qualified Test.Render.Api.Opacity as Opacity
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "RenderApi" $ do
  Handle.spec
  Opacity.spec
