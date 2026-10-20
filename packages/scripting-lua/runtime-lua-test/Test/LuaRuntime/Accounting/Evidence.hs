-- | Cleanup failures an owner retains, and the wait for its accounting (LUA-31, D-47).
--
-- A failure of cleanup is fatal: it ends the owner as a failure, however the rest of its work came to,
-- and an owner holds it until its turn reports it. Every place it is retained publishes a notice the wait
-- reads, or is read by it directly. These examples drive each such place with the owner parked, nothing
-- owed and no grant outstanding, and require the wait begun there never to answer: it ends with the failure.
--
-- The places are the scheduler's own list ('closeOwed', the stop a control applies, the owner's own stop of
-- a task), the owner's two lists of evidence ('Hetoimasia.Scripting.Lua.Cleanup'): written by the settling of a
-- task's fault, the draining of an instance, the retirement of a lease or a request and the disposal of what it
-- needed, and the settlement an ending's escalation can fail. The first two are in "Waits" and "Windows";
-- the rest are here.
module Test.LuaRuntime.Accounting.Evidence (spec) where

import Control.Exception (throwIO)
import Control.Monad (void, when)
import Data.IORef (writeIORef)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VInteger, VText))
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.LuaRuntime.Accounting.Support
import Test.LuaRuntime.Instance.Lease.Support
import Test.LuaRuntime.Instance.Support
import qualified Test.LuaRuntime.Request.Support as Request
import Test.LuaRuntime.Scheduled.Support
import Test.LuaRuntime.Support (Broken (Broken), bounded, requiredPolicy)

spec ∷ Spec
spec = describe "cleanup evidence the owner retains" $ do
  describe "the scheduler's own" $ do
    it "does not complete while the failure of closing a refused task's coroutine is held, closed by the owner as the task ended" $ bounded $ do
      fixture ← newSFixture
      retainedFailure fixture [] "blk" $ \_ runtime → do
        owner ← startPlain fixture runtime "close owed" requiredPolicy defaultSchedulerBounds
        -- Both are admitted while the owner is held: the first is refused its wait and its closing handler
        -- raises, the second parks the owner at a gate.
        let go = holdingSafely fixture owner $ do
              void (admitTask' fixture owner "R" refusedClosing')
              void (admitTask' fixture owner "B" (request "block_in" [VText "blk"] OrdinaryClass OneShot Nothing))
        pure (owner, go)

  describe "the owner's own" $ do
    it "does not complete while the cleanup failure that settling a task's fault retained is held" $ bounded $ do
      fixture ← newSFixture
      retainedFailure fixture [] "y" $ \_ runtime → do
        owner <- startPlain fixture runtime "settled fault" requiredPolicy defaultSchedulerBounds
        let endpoint = scheduledEndpoint owner
        parked ← admitTask' fixture owner "Y" (closesGated "y")
        awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
        -- The task that fails is held inside the application's observer before its first segment, and the
        -- stop of the other is accepted meanwhile; when it is let go its failure and the failure of closing
        -- what it held are kept by the owner, and the next boundary closes the parked task's coroutine, at a gate.
        writeIORef (sfObserver fixture) $ \context → when (contextName context == Just "X") (blockOn fixture "obs")
        void (admitTask' fixture owner "X" (request "fails_then_close_fails" [VText "g", VInteger 0] OrdinaryClass OneShot (Just "X")))
        awaitEntered fixture "obs"
        requestTaskControl endpoint (ticketTask parked) RequestStop >>= \case
          TaskControlAccepted _ → pure ()
          other → fail ("expected the stop accepted, found " <> show other)
        pure (owner, releaseGate fixture "obs")

    it "ends the wait with a lease's failed retirement" $ bounded $ do
      fixture ← newLFix 4
      let base = lfBase fixture
      failingWait (sf base) [] $ \control runtime → providersFinish fixture $ do
        owner ← startLeased fixture runtime "retirement failed" [retiresOnStop] leaseConfig requiredPolicy
        _ ← admit base owner "a" (moduleNamed "retiresonstop")
        awaitPhase base owner "a" Active
        liveFor fixture "a" 1
        settleControl base owner "a" InstanceStop >>= (`shouldBe` ControlApplied)
        awaitSummary fixture "a" ((== 1) . summaryPending)
        waiting ← beginWait control owner
        awaitPending waiting
        failRetirement fixture "res-stop"
        pure waiting

    it "ends the wait with the failure of draining what an instance held" $ bounded $ do
      fixture ← newLFix 4
      let base = lfBase fixture
      breakRelease fixture "drain-res"
      failingWait (sf base) [] $ \control runtime → providersFinish fixture $ do
        owner ← startLeased fixture runtime "drain failed" [drainsBroken] leaseConfig requiredPolicy
        _ ← admit base owner "a" (moduleNamed "drainsbroken")
        awaitPhase base owner "a" Active
        liveFor fixture "a" 1
        _ ← expectControl base owner "a" InstanceStop
        -- The ending has begun, held in the instance's shutdown, and is the wait's; letting it go drains what
        -- the instance held, whose release fails.
        awaitEntered (sf base) "shutdown"
        waiting ← beginWait control owner
        awaitPending waiting
        releaseGate (sf base) "shutdown"
        pure waiting

    it "ends the wait with the failure of disposing what a retirement needed" $ bounded $ do
      fixture ← newLFix 4
      let base = lfBase fixture
      breakRelease fixture "dep-res.device"
      failingWait (sf base) [] $ \control runtime → providersFinish fixture $ do
        owner ← startLeased fixture runtime "disposal failed" [dependentHolder] leaseConfig requiredPolicy
        _ ← admit base owner "a" (moduleNamed "dependentholder")
        awaitPhase base owner "a" Active
        expectDelivered base owner "a" 1
        awaitEffect (sf base) "release Retiring"
        _ ← expectControl base owner "a" InstanceStop
        awaitPhase base owner "a" Stopping
        waiting ← beginWait control owner
        awaitPending waiting
        completeRetirement fixture "dep-res"
        pure waiting

    it "ends the wait with a request provider that raises when told its interest was withdrawn" $ bounded $ do
      fixture ← newIFixture
      fake ← Request.newFake
      Request.onCancel fake (\_ → throwIO (Broken "cancel"))
      failingWait (sf fixture) [] $ \control runtime → Request.providersFinish fake $ do
        owner ← Request.startRequester fixture runtime "request told" [Request.asker] Request.cmdConfig (Request.grantOf fake 4) requiredPolicy
        Request.admitAsker fixture owner "i" "asker"
        Request.command fixture owner "i" "start" "a"
        Request.awaitLine fixture "cmd start a started"
        _ ← expectControl fixture owner "i" InstanceStop
        awaitPhase fixture owner "i" Stopping
        waiting ← beginWait control owner
        Request.awaitCancelled fake 1
        Request.finishWork fake 0
        pure waiting
