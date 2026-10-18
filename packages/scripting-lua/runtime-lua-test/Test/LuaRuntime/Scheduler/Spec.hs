-- | The scheduling machinery's examples (LUA-21). None needs a VM except the one
-- that checks a lifecycle binding is still not yet supported: everything else
-- runs scripted segments under an injected clock and a fake timer, and none
-- sleeps.
module Test.LuaRuntime.Scheduler.Spec (spec) where

import qualified Test.LuaRuntime.Scheduler.Budget
import qualified Test.LuaRuntime.Scheduler.Classes
import qualified Test.LuaRuntime.Scheduler.Control
import qualified Test.LuaRuntime.Scheduler.Elapsed
import qualified Test.LuaRuntime.Scheduler.Lifecycle
import qualified Test.LuaRuntime.Scheduler.Logical
import qualified Test.LuaRuntime.Scheduler.Policy
import qualified Test.LuaRuntime.Scheduler.Requests
import qualified Test.LuaRuntime.Scheduler.Stop
import qualified Test.LuaRuntime.Scheduler.Structure
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "the Lua task scheduling machinery" $ do
  Test.LuaRuntime.Scheduler.Structure.spec
  Test.LuaRuntime.Scheduler.Policy.spec
  Test.LuaRuntime.Scheduler.Classes.spec
  Test.LuaRuntime.Scheduler.Logical.spec
  Test.LuaRuntime.Scheduler.Elapsed.spec
  Test.LuaRuntime.Scheduler.Budget.spec
  Test.LuaRuntime.Scheduler.Control.spec
  Test.LuaRuntime.Scheduler.Stop.spec
  Test.LuaRuntime.Scheduler.Lifecycle.spec
  Test.LuaRuntime.Scheduler.Requests.spec
