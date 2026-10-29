-- | The session coordinator's examples (LFE-13), composed under one @Session@ group.
module Test.LuaEngine.Session.Spec (spec) where

import qualified Test.LuaEngine.Session.Api as Api
import qualified Test.LuaEngine.Session.Client as Client
import qualified Test.LuaEngine.Session.Clocks as Clocks
import qualified Test.LuaEngine.Session.Commit as Commit
import qualified Test.LuaEngine.Session.Control as Control
import qualified Test.LuaEngine.Session.Construction as Construction
import qualified Test.LuaEngine.Session.Diagnostics as Diagnostics
import qualified Test.LuaEngine.Session.Evidence as Evidence
import qualified Test.LuaEngine.Session.Failures as Failures
import qualified Test.LuaEngine.Session.Model as Model
import qualified Test.LuaEngine.Session.Startup as Startup
import qualified Test.LuaEngine.Session.Stop as Stop
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Session" $ do
  Model.spec
  Startup.spec
  Clocks.spec
  Failures.spec
  Evidence.spec
  Stop.spec
  Construction.spec
  Commit.spec
  Diagnostics.spec
  Control.spec
  Api.spec
  Client.spec
