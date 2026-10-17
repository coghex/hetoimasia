-- | The runtime adapter's examples. Every execution and lifecycle example
-- acquires real VMs under a real supervision boundary; the structural checks
-- need no VM.
module Test.LuaRuntime.Spec (spec) where

import qualified Test.LuaRuntime.Callbacks
import qualified Test.LuaRuntime.Dependencies
import qualified Test.LuaRuntime.HostFailures
import qualified Test.LuaRuntime.Identity
import qualified Test.LuaRuntime.Independence
import qualified Test.LuaRuntime.Readiness
import qualified Test.LuaRuntime.Settlement
import qualified Test.LuaRuntime.Stop
import qualified Test.LuaRuntime.Submission
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "the Lua runtime adapter" $ do
  Test.LuaRuntime.Dependencies.spec
  Test.LuaRuntime.Readiness.spec
  Test.LuaRuntime.Identity.spec
  Test.LuaRuntime.Submission.spec
  Test.LuaRuntime.Settlement.spec
  Test.LuaRuntime.HostFailures.spec
  Test.LuaRuntime.Stop.spec
  Test.LuaRuntime.Independence.spec
  Test.LuaRuntime.Callbacks.spec
