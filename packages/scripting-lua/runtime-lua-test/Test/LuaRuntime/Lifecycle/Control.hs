-- | A script's control of instances of other owners: pause, resume and stop, the
-- receipts it holds for them and what reading one does.
module Test.LuaRuntime.Lifecycle.Control (spec) where

import Control.Concurrent (yield)
import Control.Monad (replicateM_)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Scheduled (ServiceClass (OrdinaryClass))
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

  it "pauses a periodic instance's updates across owners and resumes them one interval later, as the application's own pause and resume do" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \control runtime → do
      owner ← startTarget targetFx runtime "target" [echoer] (testConfig instanceBounds')
      _ ← admitWith targetFx owner "p" (InstanceRequest (moduleNamed "echoer") (Periodic (LogicalTicks 1)) (Just "p") OrdinaryClass ["tick"])
      awaitPhase targetFx owner "p" Active
      tid ← tidValue targetFx "p"
      caller ← startCaller callerFx runtime "caller" (Just (target owner))
      admitCommander callerFx caller "cmdr"
      grantOne control owner
      awaitCount' targetFx "update" 1
      ask callerFx caller "cmdr" "pause" (Just tid) Nothing >>= (`shouldBe` "{accepted=true,receipt=0}")
      awaitPhase targetFx owner "p" Paused
      -- Ticks pass and nothing is due while it is paused.
      replicateM_ 3 (grantOne control owner)
      logCount targetFx "update" >>= (`shouldBe` 1)
      ask callerFx caller "cmdr" "resume" (Just tid) Nothing >>= (`shouldBe` "{accepted=true,receipt=1}")
      awaitPhase targetFx owner "p" Active
      -- The first update newly due is one full interval after the resume.
      logCount targetFx "update" >>= (`shouldBe` 1)
      grantOne control owner
      awaitCount' targetFx "update" 2
  where
    awaitCount' fixture line wanted = do
      seen ← logCount fixture line
      if seen >= wanted then pure () else yield >> awaitCount' fixture line wanted
