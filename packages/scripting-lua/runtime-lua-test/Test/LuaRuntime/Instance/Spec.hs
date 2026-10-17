-- | The script instances' examples (LUA-18). Every one runs real instances on a
-- real supervised scheduled owner, under an injected clock and a fake timer, with
-- barriers and gates instead of sleeps.
module Test.LuaRuntime.Instance.Spec (spec) where

import qualified Test.LuaRuntime.Instance.Basics
import qualified Test.LuaRuntime.Instance.Capacity
import qualified Test.LuaRuntime.Instance.Control
import qualified Test.LuaRuntime.Instance.Determinism
import qualified Test.LuaRuntime.Instance.Events
import qualified Test.LuaRuntime.Instance.Failure
import qualified Test.LuaRuntime.Instance.Stop
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "the script instances" $ do
  Test.LuaRuntime.Instance.Basics.spec
  Test.LuaRuntime.Instance.Capacity.spec
  Test.LuaRuntime.Instance.Control.spec
  Test.LuaRuntime.Instance.Determinism.spec
  Test.LuaRuntime.Instance.Events.spec
  Test.LuaRuntime.Instance.Failure.spec
  Test.LuaRuntime.Instance.Stop.spec
