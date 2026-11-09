-- | The terrain facade's examples (TRA-5), over the real terrain service.
module Test.LuaEngine.Terrain.Spec (spec) where

import qualified Test.LuaEngine.Terrain.Basics as Basics
import qualified Test.LuaEngine.Terrain.Domain as Domain
import qualified Test.LuaEngine.Terrain.Names as Names
import qualified Test.LuaEngine.Terrain.Ownership as Ownership
import qualified Test.LuaEngine.Terrain.Validation as Validation
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Terrain" $ do
  Basics.spec
  Validation.spec
  Domain.spec
  Ownership.spec
  Names.spec
