-- | The scheduled owners' examples (LUA-6). Every one runs real Lua tasks as
-- coroutines on a real supervised scheduled owner, under an injected clock and a
-- fake timer whose wakes the example fires, with barriers and gates instead of
-- sleeps.
module Test.LuaRuntime.Scheduled.Spec (spec) where

import qualified Test.LuaRuntime.Scheduled.Execution
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "the scheduled Lua owners" $ do
  Test.LuaRuntime.Scheduled.Execution.spec
