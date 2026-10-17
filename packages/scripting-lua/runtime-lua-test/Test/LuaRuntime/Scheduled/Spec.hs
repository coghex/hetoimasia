-- | The scheduled owners' examples (LUA-6). Every one runs real Lua tasks as
-- coroutines on a real supervised scheduled owner, under an injected clock and a
-- fake timer whose wakes the example fires, with barriers and gates instead of
-- sleeps.
module Test.LuaRuntime.Scheduled.Spec (spec) where

import qualified Test.LuaRuntime.Scheduled.Callbacks
import qualified Test.LuaRuntime.Scheduled.Creation
import qualified Test.LuaRuntime.Scheduled.Determinism
import qualified Test.LuaRuntime.Scheduled.Execution
import qualified Test.LuaRuntime.Scheduled.Failures
import qualified Test.LuaRuntime.Scheduled.Lifecycle
import qualified Test.LuaRuntime.Scheduled.Settlement
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "the scheduled Lua owners" $ do
  Test.LuaRuntime.Scheduled.Creation.spec
  Test.LuaRuntime.Scheduled.Execution.spec
  Test.LuaRuntime.Scheduled.Settlement.spec
  Test.LuaRuntime.Scheduled.Callbacks.spec
  Test.LuaRuntime.Scheduled.Lifecycle.spec
  Test.LuaRuntime.Scheduled.Failures.spec
  Test.LuaRuntime.Scheduled.Determinism.spec
