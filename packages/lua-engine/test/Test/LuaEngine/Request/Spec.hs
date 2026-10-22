-- | The M1 request adapter's examples (LFE-7), composed.
module Test.LuaEngine.Request.Spec (spec) where

import qualified Test.LuaEngine.Request.Contract as Contract
import qualified Test.LuaEngine.Request.Failure as Failure
import qualified Test.LuaEngine.Request.Limits as Limits
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Requests" $ do
  Contract.spec
  Limits.spec
  Failure.spec
