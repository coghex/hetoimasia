-- | What becomes of a request and of its receipt: settled exactly once whatever ends its
-- target first, never undone by what ends its caller, and never left holding a reservation
-- nobody can give back.
module Test.LuaRuntime.Lifecycle.Settlement (spec) where

import Control.Monad (forM, forM_, replicateM, void)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VInteger))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Lifecycle.Support
import Test.LuaRuntime.Scheduled.Support (awaitEntered, releaseGate, awaitScheduledTerminal)
import Test.LuaRuntime.Support (bounded, withBoundary)

takenAs ∷ Int → Text
takenAs number = "{accepted=true,receipt=" <> Text.pack (show number) <> "}"

-- | Whether the target's owner holds a reservation for every control it may: it takes
-- this many requests, whose receipts nobody reads, and refuses the next.
reservationsAllFree ∷ IFixture → ScheduledOwner → Text → IO ()
reservationsAllFree fixture owner name = do
  receipts ← replicateM 8 (askUntilTaken fixture owner name InstancePause)
  forM_ receipts $ \answer → answer `shouldSatisfy` \case InstanceControlAccepted _ → True; _ → False
  askControl fixture owner name InstancePause >>= (`shouldSatisfy` \case InstanceControlFull → True; _ → False)

spec ∷ Spec
spec = describe "settlement" $ do
  it "settles every request exactly once, in the order accepted, whatever a stop makes of the ones behind it" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startTarget targetFx runtime "target" [echoer, holder] (testConfig instanceBounds')
      _ ← admit targetFx owner "a" (moduleNamed "echoer")
      awaitPhase targetFx owner "a" Active
      tid ← tidValue targetFx "a"
      caller ← startCaller callerFx runtime "caller" (Just (target owner))
      admitCommander callerFx caller "cmdr"
      holdOwner targetFx owner
      answers ← forM ["pause", "stop", "resume", "stop"] $ \op → ask callerFx caller "cmdr" op (Just tid) Nothing
      answers `shouldBe` map takenAs [0 .. 3]
      releaseOwner targetFx
      results ← forM [0 .. 3] (receiptResult callerFx caller "cmdr")
      -- The stop ended the instance as it was applied: the one behind it found it ended,
      -- and a second stop of what has stopped is where it already was.
      results `shouldBe` ["applied", "applied", "no_longer_applicable", "no_longer_applicable"]
      -- Read once, each is gone.
      forM_ [0 .. 3] $ \n → ask callerFx caller "cmdr" "result" Nothing (Just n) >>= (`shouldBe` "unknown_receipt")

  it "applies a request made of an instance that is still initializing once it has initialized, and settles one its failure overtook as no longer applicable" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startTarget targetFx runtime "target" [gateInit, gateFail] (testConfig instanceBounds')
      caller ← startCaller callerFx runtime "caller" (Just (target owner))
      admitCommander callerFx caller "cmdr"
      -- Held inside @init@: initializing, and a live target.
      _ ← admit targetFx owner "ok" (moduleNamed "gateinit")
      awaitEntered (sf targetFx) "init"
      okTid ← tidValue targetFx "ok"
      ask callerFx caller "cmdr" "inspect" (Just okTid) Nothing >>= (`shouldSatisfy` Text.isInfixOf "status=initializing")
      ask callerFx caller "cmdr" "pause" (Just okTid) Nothing >>= (`shouldBe` takenAs 0)
      releaseGate (sf targetFx) "init"
      awaitPhase targetFx owner "ok" Paused
      receiptResult callerFx caller "cmdr" 0 >>= (`shouldBe` "applied")
      -- The same owner, a second instance whose @init@ fails once it is released.
      _ ← admit targetFx owner "bad" (moduleNamed "gatefail")
      awaitPhase targetFx owner "bad" Initializing
      badTid ← tidValue targetFx "bad"
      ask callerFx caller "cmdr" "pause" (Just badTid) Nothing >>= (`shouldBe` takenAs 1)
      awaitPhase targetFx owner "bad" Failed
      receiptResult callerFx caller "cmdr" 1 >>= (`shouldBe` "no_longer_applicable")

  it "takes a request made of an instance that is stopping, and settles it as no longer applicable once the instance has ended" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startTarget targetFx runtime "target" [gateShutdown] (testConfig instanceBounds')
      _ ← admit targetFx owner "a" (moduleNamed "gateshutdown")
      awaitPhase targetFx owner "a" Active
      tid ← tidValue targetFx "a"
      caller ← startCaller callerFx runtime "caller" (Just (target owner))
      admitCommander callerFx caller "cmdr"
      ask callerFx caller "cmdr" "stop" (Just tid) Nothing >>= (`shouldBe` takenAs 0)
      -- Held inside @shutdown@: stopping.
      awaitEntered (sf targetFx) "shutdown"
      awaitPhase targetFx owner "a" Stopping
      ask callerFx caller "cmdr" "inspect" (Just tid) Nothing >>= (`shouldSatisfy` Text.isInfixOf "status=stopping")
      -- Both are taken: the instance is live until its hook has returned. The owner is inside
      -- that hook, so neither is applied until it has, and the instance has ended by then.
      ask callerFx caller "cmdr" "stop" (Just tid) Nothing >>= (`shouldBe` takenAs 1)
      ask callerFx caller "cmdr" "pause" (Just tid) Nothing >>= (`shouldBe` takenAs 2)
      releaseGate (sf targetFx) "shutdown"
      _ ← awaitSettled targetFx "a"
      results ← forM [0 .. 2] (receiptResult callerFx caller "cmdr")
      results `shouldBe` ["applied", "no_longer_applicable", "no_longer_applicable"]

  it "settles a request its target's owner never applied as no longer applicable when the owner is cancelled, once" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    seen ← newIORef Nothing
    withBoundary $ \control runtime → do
      owner ← startTarget targetFx runtime "target" [echoer, holder] (testConfig instanceBounds')
      _ ← admit targetFx owner "a" (moduleNamed "echoer")
      awaitPhase targetFx owner "a" Active
      tid ← tidValue targetFx "a"
      caller ← startCaller callerFx runtime "caller" (Just (target owner))
      admitCommander callerFx caller "cmdr"
      holdOwner targetFx owner
      ask callerFx caller "cmdr" "pause" (Just tid) Nothing >>= (`shouldBe` takenAs 0)
      -- Cancelled while the owner is inside a segment: what had been accepted is not applied.
      cancelScheduled owner
      releaseOwner targetFx
      void (awaitScheduledTerminal control owner)
      first ← receiptResult callerFx caller "cmdr" 0
      writeIORef seen (Just first)
      second ← ask callerFx caller "cmdr" "result" Nothing (Just 0)
      (first, second) `shouldBe` ("no_longer_applicable", "unknown_receipt")
    readIORef seen >>= (`shouldBe` Just "no_longer_applicable")

  it "never undoes what its caller asked when the caller's instance ends, and gives every reservation back though none of the results was read" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startTarget targetFx runtime "target" [echoer, holder] (testConfig instanceBounds')
      _ ← admit targetFx owner "a" (moduleNamed "echoer")
      awaitPhase targetFx owner "a" Active
      tid ← tidValue targetFx "a"
      caller ← startCaller callerFx runtime "caller" (Just (target owner))
      admitCommander callerFx caller "cmdr"
      holdOwner targetFx owner
      answers ← reserveAll callerFx caller "cmdr" tid 8
      answers `shouldBe` map takenAs [0 .. 7]
      -- The caller's instance ends with all eight results unread.
      stopped ← settleControl callerFx caller "cmdr" InstanceStop
      stopped `shouldBe` ControlApplied
      _ ← awaitSettled callerFx "cmdr"
      releaseOwner targetFx
      -- What it asked was done all the same, and the reservations are all free.
      awaitPhase targetFx owner "a" Paused
      reservationsAllFree targetFx owner "a"

  it "gives every reservation back when the caller's owner retires with results unread, and still applies what it had accepted" $ bounded $ do
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
      answers ← reserveAll callerFx caller "cmdr" tid 8
      answers `shouldBe` map takenAs [0 .. 7]
      retireScheduled caller
      void (awaitScheduledTerminal control caller)
      releaseOwner targetFx
      awaitPhase targetFx owner "a" Paused
      reservationsAllFree targetFx owner "a"

  it "gives a reservation back at settlement for a result forgotten while its request was pending" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startTarget targetFx runtime "target" [echoer, holder] (testConfig instanceBounds')
      _ ← admit targetFx owner "a" (moduleNamed "echoer")
      awaitPhase targetFx owner "a" Active
      tid ← tidValue targetFx "a"
      caller ← startCaller callerFx runtime "caller" (Just (target owner))
      admitCommander callerFx caller "cmdr"
      holdOwner targetFx owner
      answers ← reserveAll callerFx caller "cmdr" tid 8
      answers `shouldBe` map takenAs [0 .. 7]
      forM_ [0 .. 7] $ \n → ask callerFx caller "cmdr" "forget" Nothing (Just n) >>= (`shouldBe` "true")
      releaseOwner targetFx
      awaitPhase targetFx owner "a" Paused
      reservationsAllFree targetFx owner "a"

  it "lets only the instance that made a request read its receipt, and a task's receipts are its owner's tasks' alone" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startTarget targetFx runtime "target" [echoer] (testConfig instanceBounds')
      _ ← admit targetFx owner "a" (moduleNamed "echoer")
      awaitPhase targetFx owner "a" Active
      tid ← tidValue targetFx "a"
      caller ← startCaller callerFx runtime "caller" (Just (target owner))
      admitCommander callerFx caller "first"
      admitCommander callerFx caller "second"
      ask callerFx caller "first" "pause" (Just tid) Nothing >>= (`shouldBe` takenAs 0)
      awaitPhase targetFx owner "a" Paused
      -- Another instance of the same owner holds no such receipt.
      ask callerFx caller "second" "result" Nothing (Just 0) >>= (`shouldBe` "unknown_receipt")
      -- Nor does a task.
      taskLine callerFx caller "result" [VInteger 0] >>= (`shouldBe` "unknown_receipt")
      receiptResult callerFx caller "first" 0 >>= (`shouldBe` "applied")
