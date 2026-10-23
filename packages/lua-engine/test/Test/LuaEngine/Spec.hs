-- | The Lua engine package's component specs, composed under one @LuaEngine@ group.
module Test.LuaEngine.Spec (spec) where

import qualified Test.LuaEngine.Behavior as Behavior
import qualified Test.LuaEngine.Boot as Boot
import qualified Test.LuaEngine.Boundary as Boundary
import qualified Test.LuaEngine.Data.Spec as Data
import qualified Test.LuaEngine.Facade.Spec as Facade
import qualified Test.LuaEngine.Loader as Loader
import qualified Test.LuaEngine.Manifest.Examples as Examples
import qualified Test.LuaEngine.Manifest.Schema as Schema
import qualified Test.LuaEngine.Manifest.Syntax as Syntax
import qualified Test.LuaEngine.Manifest.Tick as Tick
import qualified Test.LuaEngine.Modules.Spec as Modules
import qualified Test.LuaEngine.Profile as Profile
import qualified Test.LuaEngine.Request.Spec as Requests
import qualified Test.LuaEngine.Scene.Spec as Scene
import qualified Test.LuaEngine.Texture.Spec as Texture
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "LuaEngine" $ do
  Examples.spec
  Syntax.spec
  Schema.spec
  Tick.spec
  Profile.spec
  Requests.spec
  Data.spec
  Modules.spec
  Texture.spec
  Scene.spec
  Facade.spec
  Behavior.spec
  Boot.spec
  Loader.spec
  Boundary.spec
