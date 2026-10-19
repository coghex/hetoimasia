-- | The retirement reading the engine polls is never re-run against a stale view (#488).
module Test.LuaRuntime.Retention.Spec (spec) where

import qualified Test.LuaRuntime.Retention.Leases
import qualified Test.LuaRuntime.Retention.Requests
import qualified Test.LuaRuntime.Retention.Writes
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Retention" $ do
  Test.LuaRuntime.Retention.Requests.spec
  Test.LuaRuntime.Retention.Leases.spec
  Test.LuaRuntime.Retention.Writes.spec
