-- | The instance leases' examples (LUA-22). Every one runs real instances on a real
-- supervised scheduled owner that lends its collection and holds leases, under an
-- injected clock and a fake timer, with fake resources and a fake provider, and with
-- barriers and gates instead of sleeps. None of the modules written for them needs Lua
-- cleanup code to pass.
module Test.LuaRuntime.Instance.Lease.Spec (spec) where

import qualified Test.LuaRuntime.Instance.Lease.Acquire
import qualified Test.LuaRuntime.Instance.Lease.Configure
import qualified Test.LuaRuntime.Instance.Lease.Release
import qualified Test.LuaRuntime.Instance.Lease.Retire
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "the instance leases" $ do
  Test.LuaRuntime.Instance.Lease.Configure.spec
  Test.LuaRuntime.Instance.Lease.Acquire.spec
  Test.LuaRuntime.Instance.Lease.Release.spec
  Test.LuaRuntime.Instance.Lease.Retire.spec
