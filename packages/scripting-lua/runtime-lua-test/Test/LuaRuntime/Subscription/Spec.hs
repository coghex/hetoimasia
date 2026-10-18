-- | Owned subscriptions to provider events (LUA-26), composed.
module Test.LuaRuntime.Subscription.Spec (spec) where

import qualified Test.LuaRuntime.Subscription.Basics
import qualified Test.LuaRuntime.Subscription.Epochs
import qualified Test.LuaRuntime.Subscription.Failures
import qualified Test.LuaRuntime.Subscription.Logical
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Subscriptions" $ do
  Test.LuaRuntime.Subscription.Basics.spec
  Test.LuaRuntime.Subscription.Epochs.spec
  Test.LuaRuntime.Subscription.Failures.spec
  Test.LuaRuntime.Subscription.Logical.spec
