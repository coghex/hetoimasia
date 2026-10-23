-- | The Lua authoring facade's examples (LFE-12), composed under one @Facade@ group.
module Test.LuaEngine.Facade.Spec (spec) where

import qualified Test.LuaEngine.Facade.Authoring as Authoring
import qualified Test.LuaEngine.Facade.Client as Client
import qualified Test.LuaEngine.Facade.Clocks as Clocks
import qualified Test.LuaEngine.Facade.Imports as Imports
import qualified Test.LuaEngine.Facade.Limits as Limits
import qualified Test.LuaEngine.Facade.Output as Output
import qualified Test.LuaEngine.Facade.Ownership as Ownership
import qualified Test.LuaEngine.Facade.Requests as Requests
import qualified Test.LuaEngine.Facade.Sinks as Sinks
import qualified Test.LuaEngine.Facade.Validation as Validation
import qualified Test.LuaEngine.Facade.Waits as Waits
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Facade" $ do
  Authoring.spec
  Ownership.spec
  Imports.spec
  Requests.spec
  Clocks.spec
  Waits.spec
  Output.spec
  Sinks.spec
  Client.spec
  Validation.spec
  Limits.spec
