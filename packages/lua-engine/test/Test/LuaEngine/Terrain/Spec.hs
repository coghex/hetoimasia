-- | The terrain facade's examples (TRA-5), over the real terrain service.
module Test.LuaEngine.Terrain.Spec (spec) where

import qualified Test.LuaEngine.Terrain.Basics as Basics
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Terrain" $ do
  Basics.spec
