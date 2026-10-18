-- | The first request examples: the path from a script's request to its settlement.
module Test.LuaRuntime.Request.Smoke (spec) where

import Hetoimasia.Scripting.Lua.Provider
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Request.Support
import Test.LuaRuntime.Support (bounded, requiredPolicy, withBoundary)

spec ∷ Spec
spec = describe "a request" $ do
  it "is started by an instance, answered by the provider, waited for and taken" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \_ runtime → do
      owner ← startRequester fixture runtime "owner" [asker] cmdConfig (grantOf fake 4) requiredPolicy
      admitAsker fixture owner "i" "asker"
      command fixture owner "i" "start_wait_take" "a"
      awaitSubmitted fake 1
      answer ← answerResult fake 0 7
      answer `shouldBe` ReplySettled
      awaitLine fixture "cmd start_wait_take a {status=result,value=7}"
