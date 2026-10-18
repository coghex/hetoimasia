-- | An instance's control of itself: asked in a segment, and applied only once the
-- segment has returned or yielded, as any control of the instance whose invocation is
-- running is.
module Test.LuaRuntime.Lifecycle.SelfControl (spec) where

import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lifecycle
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Lifecycle.Support
import Test.LuaRuntime.Support (bounded, withBoundary)

-- | A grant that covers the owner it is given to.
overSelf ∷ LifecycleGrant
overSelf = lifecycleGrant [GrantTarget GrantedSelf bothPermits Nothing]

-- | What the commanders recorded around a request, in order.
trace ∷ IFixture → IO [Text]
trace fixture = filter (\line → any (`Text.isPrefixOf` line) ["cmd ", "post "]) <$> logged fixture

spec ∷ Spec
spec = describe "an instance's control of itself" $ do
  it "pauses it only after the segment that asked has returned: its own inspection inside that segment still reads it as active" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startCaller fixture runtime "self" (Just overSelf)
      admitCommander fixture owner "cmdr"
      ask fixture owner "cmdr" "pause_self_inspect" Nothing Nothing >>= (`shouldBe` "{accepted=true,receipt=0} active")
      awaitPhase fixture owner "cmdr" Paused
      trace fixture >>= (`shouldBe` ["cmd pause_self_inspect {accepted=true,receipt=0} active", "post pause_self_inspect"])
      -- Paused, it runs nothing: resumed, its result is read by the instance that asked.
      _ ← settleControl fixture owner "cmdr" InstanceResume
      receiptResult fixture owner "cmdr" 0 >>= (`shouldBe` "applied")

  it "stops it only after the segment that asked has returned, and runs its shutdown once, after" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startCaller fixture runtime "self" (Just overSelf)
      admitCommander fixture owner "cmdr"
      ask fixture owner "cmdr" "stop_self" Nothing Nothing >>= (`shouldBe` "{accepted=true,receipt=0}")
      settled ← awaitSettled fixture "cmdr"
      resultPhase settled `shouldBe` Stopped
      trace fixture
        >>= (`shouldBe` ["cmd stop_self {accepted=true,receipt=0}", "post stop_self", "post shutdown stopped"])
