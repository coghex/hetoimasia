-- | The module coordinator's examples (LFE-11), composed under one @Modules@ group.
module Test.LuaEngine.Modules.Spec (spec) where

import qualified Test.LuaEngine.Modules.Basics as Basics
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Modules" $ do
  Basics.spec
