-- | Asynchronous requests with reserved result slots (LUA-7), composed.
module Test.LuaRuntime.Request.Spec (spec) where

import qualified Test.LuaRuntime.Request.Admission
import qualified Test.LuaRuntime.Request.Epoch
import qualified Test.LuaRuntime.Request.Failures
import qualified Test.LuaRuntime.Request.Invariants
import qualified Test.LuaRuntime.Request.Logical
import qualified Test.LuaRuntime.Request.Settlement
import qualified Test.LuaRuntime.Request.Smoke
import qualified Test.LuaRuntime.Request.Teardown
import qualified Test.LuaRuntime.Request.Waiting
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Requests" $ do
  Test.LuaRuntime.Request.Admission.spec
  Test.LuaRuntime.Request.Epoch.spec
  Test.LuaRuntime.Request.Failures.spec
  Test.LuaRuntime.Request.Invariants.spec
  Test.LuaRuntime.Request.Logical.spec
  Test.LuaRuntime.Request.Settlement.spec
  Test.LuaRuntime.Request.Smoke.spec
  Test.LuaRuntime.Request.Teardown.spec
  Test.LuaRuntime.Request.Waiting.spec
