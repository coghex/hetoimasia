-- | A script's control of instances of other owners: pause, resume and stop, the
-- receipts it holds for them and what reading one does.
module Test.LuaRuntime.Lifecycle.Control (spec) where

import Hetoimasia.Scripting.Lua.Instance
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Lifecycle.Support
import Test.LuaRuntime.Scheduled.Support (awaitEffect)
import Test.LuaRuntime.Support (bounded, withBoundary)

spec ∷ Spec
spec = describe "control across owners" $ do
  it "pauses, resumes and stops an instance of another owner, and the receipts say each was applied" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startTarget targetFx runtime "target" [echoer] (testConfig instanceBounds')
      _ ← admit targetFx owner "a" (moduleNamed "echoer")
      awaitPhase targetFx owner "a" Active
      caller ← startCaller callerFx runtime "caller" (Just (target owner))
      admitCommander callerFx caller "cmdr"
      tid ← tidValue targetFx "a"
      ask callerFx caller "cmdr" "pause" (Just tid) Nothing >>= (`shouldBe` "{accepted=true,receipt=0}")
      awaitPhase targetFx owner "a" Paused
      ask callerFx caller "cmdr" "result" Nothing (Just 0) >>= (`shouldBe` "applied")
      -- Read once, it is consumed: the engine keeps no history of results.
      ask callerFx caller "cmdr" "result" Nothing (Just 0) >>= (`shouldBe` "unknown_receipt")
      ask callerFx caller "cmdr" "resume" (Just tid) Nothing >>= (`shouldBe` "{accepted=true,receipt=1}")
      awaitPhase targetFx owner "a" Active
      ask callerFx caller "cmdr" "result" Nothing (Just 1) >>= (`shouldBe` "applied")
      ask callerFx caller "cmdr" "stop" (Just tid) Nothing >>= (`shouldBe` "{accepted=true,receipt=2}")
      settled ← awaitSettled targetFx "a"
      resultPhase settled `shouldBe` Stopped
      ask callerFx caller "cmdr" "result" Nothing (Just 2) >>= (`shouldBe` "applied")
      awaitEffect (sf targetFx) "shutdown 1 stopped"
