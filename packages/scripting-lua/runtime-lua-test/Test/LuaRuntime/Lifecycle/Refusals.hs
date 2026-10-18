-- | Every way a request is answered without being taken: a bound held at the caller or
-- at the target, an owner that is not taking requests, and a target that is not live.
-- Each is an answer, never a fault, and none takes a reservation.
module Test.LuaRuntime.Lifecycle.Refusals (spec) where

import Control.Monad (forM, forM_)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lifecycle
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Lifecycle.Support
import Test.LuaRuntime.Scheduled.Support (awaitScheduledTerminal)
import Test.LuaRuntime.Support (bounded, withBoundary)

-- | What an accepted request answered, with this receipt.
takenAs ∷ Int → Text
takenAs number = "{accepted=true,receipt=" <> Text.pack (show number) <> "}"

-- | A grant over the owner with this bound on the receipts a script holds.
holdingAtMost ∷ Int → ScheduledOwner → LifecycleGrant
holdingAtMost bound owner = (target owner) {grantReceiptBound = bound}

spec ∷ Spec
spec = describe "refusals" $ do
  it "refuses a request the target has no reservation for, takes none for it, and takes one again as a result is read" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startTarget targetFx runtime "target" [echoer, holder] (testConfig instanceBounds')
      _ ← admit targetFx owner "a" (moduleNamed "echoer")
      awaitPhase targetFx owner "a" Active
      caller ← startCaller callerFx runtime "caller" (Just (holdingAtMost 16 owner))
      admitCommander callerFx caller "cmdr"
      tid ← tidValue targetFx "a"
      -- The owner is held in a segment, so what is asked is accepted and none is applied: the
      -- target's eight reservations are all that is left to take.
      holdOwner targetFx owner
      answers ← reserveAll callerFx caller "cmdr" tid 9
      answers `shouldBe` map takenAs [0 .. 7] <> ["{accepted=false,refusal=full}"]
      releaseOwner targetFx
      awaitPhase targetFx owner "a" Paused
      -- Applied once, then already in the state asked for, in the order accepted.
      results ← forM [0 .. 7] (receiptResult callerFx caller "cmdr")
      results `shouldBe` "applied" : replicate 7 "already_in_state"
      -- Every reservation came back as its result was read: the request that was refused is
      -- taken now, with the next number, for none was spent on the refusal.
      ask callerFx caller "cmdr" "resume" (Just tid) Nothing >>= (`shouldBe` takenAs 8)

  it "refuses a request past the receipts the caller may hold, whatever room the target has, and takes one again as a result is read or abandoned" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startTarget targetFx runtime "target" [echoer] (testConfig instanceBounds')
      _ ← admit targetFx owner "a" (moduleNamed "echoer")
      awaitPhase targetFx owner "a" Active
      tid ← tidValue targetFx "a"
      caller ← startCaller callerFx runtime "caller" (Just (holdingAtMost 2 owner))
      admitCommander callerFx caller "cmdr"
      ask callerFx caller "cmdr" "pause" (Just tid) Nothing >>= (`shouldBe` "{accepted=true,receipt=0}")
      ask callerFx caller "cmdr" "resume" (Just tid) Nothing >>= (`shouldBe` "{accepted=true,receipt=1}")
      ask callerFx caller "cmdr" "pause" (Just tid) Nothing >>= (`shouldBe` "{accepted=false,refusal=full}")
      -- Reading a settled result gives the place back, and so does abandoning one.
      receiptResult callerFx caller "cmdr" 0 >>= (`shouldBe` "applied")
      ask callerFx caller "cmdr" "pause" (Just tid) Nothing >>= (`shouldBe` "{accepted=true,receipt=2}")
      ask callerFx caller "cmdr" "pause" (Just tid) Nothing >>= (`shouldBe` "{accepted=false,refusal=full}")
      ask callerFx caller "cmdr" "forget" Nothing (Just 1) >>= (`shouldBe` "true")
      ask callerFx caller "cmdr" "forget" Nothing (Just 1) >>= (`shouldBe` "false")
      ask callerFx caller "cmdr" "result" Nothing (Just 1) >>= (`shouldBe` "unknown_receipt")
      ask callerFx caller "cmdr" "stop" (Just tid) Nothing >>= (`shouldBe` "{accepted=true,receipt=3}")

  it "refuses as closed from the moment the target's owner is asked to stop, settles what it had accepted and never applied as no longer applicable, and keeps refusing after it has exited" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \control runtime → do
      owner ← startTarget targetFx runtime "target" [echoer, holder] (testConfig instanceBounds')
      _ ← admit targetFx owner "a" (moduleNamed "echoer")
      awaitPhase targetFx owner "a" Active
      tid ← tidValue targetFx "a"
      caller ← startCaller callerFx runtime "caller" (Just (target owner))
      admitCommander callerFx caller "cmdr"
      holdOwner targetFx owner
      ask callerFx caller "cmdr" "pause" (Just tid) Nothing >>= (`shouldBe` "{accepted=true,receipt=0}")
      retireScheduled owner
      ask callerFx caller "cmdr" "pause" (Just tid) Nothing >>= (`shouldBe` "{accepted=false,refusal=closed}")
      ask callerFx caller "cmdr" "inspect" (Just tid) Nothing >>= (`shouldBe` "{ok=false,refusal=closed}")
      releaseOwner targetFx
      _ ← awaitScheduledTerminal control owner
      receiptResult callerFx caller "cmdr" 0 >>= (`shouldBe` "no_longer_applicable")
      ask callerFx caller "cmdr" "pause" (Just tid) Nothing >>= (`shouldBe` "{accepted=false,refusal=closed}")
      ask callerFx caller "cmdr" "inspect_owner" (Just tid) Nothing >>= (`shouldBe` "{instances={},ok=false,refusal=closed,truncated=false}")

  it "answers a stale identity as unknown, whatever became of the instance: stopped and observed, or never issued, and refuses to inspect or control a terminal one it can no longer reach" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startTarget targetFx runtime "target" [echoer, failCallback] (testConfig instanceBounds')
      _ ← admit targetFx owner "a" (moduleNamed "echoer")
      _ ← admit targetFx owner "f" (moduleNamed "failcallback")
      awaitPhase targetFx owner "a" Active
      awaitPhase targetFx owner "f" Active
      a ← tidValue targetFx "a"
      f ← tidValue targetFx "f"
      caller ← startCaller callerFx runtime "caller" (Just (target owner))
      admitCommander callerFx caller "cmdr"
      -- One stops; one fails: each is terminal, and stays inspectable until it is observed.
      ask callerFx caller "cmdr" "stop" (Just a) Nothing >>= (`shouldBe` "{accepted=true,receipt=0}")
      expectDelivered targetFx owner "f" 1
      awaitPhase targetFx owner "a" Stopped
      awaitPhase targetFx owner "f" Failed
      forM_ [a, f] $ \tid →
        ask callerFx caller "cmdr" "pause" (Just tid) Nothing >>= (`shouldBe` "{accepted=false,refusal=unknown_target}")
      ask callerFx caller "cmdr" "inspect" (Just a) Nothing >>= (`shouldSatisfy` Text.isInfixOf "status=stopped")
      ask callerFx caller "cmdr" "inspect" (Just f) Nothing >>= (`shouldSatisfy` Text.isInfixOf "status=failed")
      -- Observed, an instance's result is given back and the instance is no longer held.
      forM_ ["a", "f"] (awaitSettled targetFx)
      forM_ [a, f] $ \tid →
        ask callerFx caller "cmdr" "inspect" (Just tid) Nothing >>= (`shouldBe` "{ok=false,refusal=unknown_target}")
