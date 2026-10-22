-- | The opt-in atomic admission of requests and its settlement (LFE-7), composed.
module Test.LuaRuntime.Admission.Spec (spec) where

import qualified Test.LuaRuntime.Admission.Banks
import qualified Test.LuaRuntime.Admission.Failure
import qualified Test.LuaRuntime.Admission.Handles
import qualified Test.LuaRuntime.Admission.Lease
import qualified Test.LuaRuntime.Admission.Release
import qualified Test.LuaRuntime.Admission.Timing
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Opt-in admission" $ do
  Test.LuaRuntime.Admission.Banks.spec
  Test.LuaRuntime.Admission.Release.spec
  Test.LuaRuntime.Admission.Failure.spec
  Test.LuaRuntime.Admission.Lease.spec
  Test.LuaRuntime.Admission.Handles.spec
  Test.LuaRuntime.Admission.Timing.spec
