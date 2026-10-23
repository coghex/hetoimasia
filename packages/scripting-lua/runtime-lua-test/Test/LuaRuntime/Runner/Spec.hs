-- | The runner's examples (LUA-27): real Lua on real supervised scheduled owners, with the injected
-- clock, a fake timer, gates and STM signals, and no sleeping.
--
-- Select them with @--match Runner@.
module Test.LuaRuntime.Runner.Spec (spec) where

import qualified Test.LuaRuntime.Runner.Determinism
import qualified Test.LuaRuntime.Runner.Ending
import qualified Test.LuaRuntime.Runner.Events
import qualified Test.LuaRuntime.Runner.Failures
import qualified Test.LuaRuntime.Runner.Kinds
import qualified Test.LuaRuntime.Runner.Output
import qualified Test.LuaRuntime.Runner.Production
import qualified Test.LuaRuntime.Runner.Query
import qualified Test.LuaRuntime.Runner.Retirement
import qualified Test.LuaRuntime.Runner.Scripts
import qualified Test.LuaRuntime.Runner.Sources
import qualified Test.LuaRuntime.Runner.Tables
import qualified Test.LuaRuntime.Runner.Ticks
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Runner" $ do
  Test.LuaRuntime.Runner.Scripts.spec
  Test.LuaRuntime.Runner.Sources.spec
  Test.LuaRuntime.Runner.Kinds.spec
  Test.LuaRuntime.Runner.Output.spec
  Test.LuaRuntime.Runner.Query.spec
  Test.LuaRuntime.Runner.Ending.spec
  Test.LuaRuntime.Runner.Events.spec
  Test.LuaRuntime.Runner.Determinism.spec
  Test.LuaRuntime.Runner.Production.spec
  Test.LuaRuntime.Runner.Failures.spec
  Test.LuaRuntime.Runner.Retirement.spec
  Test.LuaRuntime.Runner.Tables.spec
  Test.LuaRuntime.Runner.Ticks.spec
