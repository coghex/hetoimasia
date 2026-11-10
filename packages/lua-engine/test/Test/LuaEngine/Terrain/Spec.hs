-- | The terrain facade's examples (TRA-5), over the real terrain service.
module Test.LuaEngine.Terrain.Spec (spec) where

import qualified Test.LuaEngine.Terrain.Basics as Basics
import qualified Test.LuaEngine.Terrain.Composition as Composition
import qualified Test.LuaEngine.Terrain.Domain as Domain
import qualified Test.LuaEngine.Terrain.Fixture as Fixture
import qualified Test.LuaEngine.Terrain.Isolation as Isolation
import qualified Test.LuaEngine.Terrain.Limits as Limits
import qualified Test.LuaEngine.Terrain.Matrix as Matrix
import qualified Test.LuaEngine.Terrain.Model as Model
import qualified Test.LuaEngine.Terrain.Names as Names
import qualified Test.LuaEngine.Terrain.Ownership as Ownership
import qualified Test.LuaEngine.Terrain.Picks as Picks
import qualified Test.LuaEngine.Terrain.Races as Races
import qualified Test.LuaEngine.Terrain.Validation as Validation
import qualified Test.LuaEngine.Terrain.Windows as Windows
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Terrain" $ do
  Basics.spec
  Fixture.spec
  Composition.spec
  Validation.spec
  Domain.spec
  Ownership.spec
  Names.spec
  Races.spec
  Limits.spec
  Isolation.spec
  Picks.spec
  Windows.spec
  Matrix.spec
  Model.spec
