-- | The Lua engine package's component specs, composed under one @LuaEngine@ group.
module Test.LuaEngine.Spec (spec) where

import qualified Test.LuaEngine.Boundary as Boundary
import qualified Test.LuaEngine.Manifest.Examples as Examples
import qualified Test.LuaEngine.Manifest.Schema as Schema
import qualified Test.LuaEngine.Manifest.Syntax as Syntax
import qualified Test.LuaEngine.Manifest.Tick as Tick
import qualified Test.LuaEngine.Profile as Profile
import qualified Test.LuaEngine.Request.Spec as Requests
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "LuaEngine" $ do
  Examples.spec
  Syntax.spec
  Schema.spec
  Tick.spec
  Profile.spec
  Requests.spec
  Boundary.spec
