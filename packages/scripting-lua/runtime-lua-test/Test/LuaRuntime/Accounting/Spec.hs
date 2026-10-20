-- | The examples of the wait for a scheduled owner's accounting (LUA-31, D-47).
module Test.LuaRuntime.Accounting.Spec (spec) where

import qualified Test.LuaRuntime.Accounting.Evidence
import qualified Test.LuaRuntime.Accounting.Waits
import qualified Test.LuaRuntime.Accounting.Windows
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "the accounting wait" $ do
  Test.LuaRuntime.Accounting.Waits.spec
  Test.LuaRuntime.Accounting.Evidence.spec
  Test.LuaRuntime.Accounting.Windows.spec
