-- | Lifecycle control and inspection across owners (LUA-23). Every example runs real
-- instances on two or more real supervised scheduled owners, under injected clocks and
-- fake timers, with gates and barriers instead of sleeps.
module Test.LuaRuntime.Lifecycle.Spec (spec) where

import qualified Test.LuaRuntime.Lifecycle.Authority
import qualified Test.LuaRuntime.Lifecycle.Control
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "the lifecycle services" $ do
  Test.LuaRuntime.Lifecycle.Authority.spec
  Test.LuaRuntime.Lifecycle.Control.spec
