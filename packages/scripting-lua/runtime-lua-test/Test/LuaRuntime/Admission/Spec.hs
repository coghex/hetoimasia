-- | The opt-in atomic admission of requests and its settlement (LFE-7), composed.
module Test.LuaRuntime.Admission.Spec (spec) where

import qualified Test.LuaRuntime.Admission.Banks
import qualified Test.LuaRuntime.Admission.Release
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Opt-in admission" $ do
  Test.LuaRuntime.Admission.Banks.spec
  Test.LuaRuntime.Admission.Release.spec
