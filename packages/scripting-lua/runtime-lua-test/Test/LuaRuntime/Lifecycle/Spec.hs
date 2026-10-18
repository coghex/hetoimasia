-- | Lifecycle control and inspection across owners (LUA-23). Every example runs real
-- instances on two or more real supervised scheduled owners, under injected clocks and
-- fake timers, with gates and barriers instead of sleeps.
module Test.LuaRuntime.Lifecycle.Spec (spec) where

import qualified Test.LuaRuntime.Lifecycle.Authority
import qualified Test.LuaRuntime.Lifecycle.Control
import qualified Test.LuaRuntime.Lifecycle.Inspection
import qualified Test.LuaRuntime.Lifecycle.Logical
import qualified Test.LuaRuntime.Lifecycle.Refusals
import qualified Test.LuaRuntime.Lifecycle.SelfControl
import qualified Test.LuaRuntime.Lifecycle.Settlement
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "the lifecycle services" $ do
  Test.LuaRuntime.Lifecycle.Authority.spec
  Test.LuaRuntime.Lifecycle.Control.spec
  Test.LuaRuntime.Lifecycle.Refusals.spec
  Test.LuaRuntime.Lifecycle.SelfControl.spec
  Test.LuaRuntime.Lifecycle.Inspection.spec
  Test.LuaRuntime.Lifecycle.Logical.spec
  Test.LuaRuntime.Lifecycle.Settlement.spec
