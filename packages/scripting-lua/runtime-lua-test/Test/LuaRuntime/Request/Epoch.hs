-- | Epochs (P-9): the application advances an owner's request epoch at a point of its choosing;
-- every outstanding request settles, once, as cancelled by the change, the providers are told,
-- and the accounting for work that is not over is retained under the identities it was issued
-- under, so a late reply retires it without reaching anything the new epoch issues.
module Test.LuaRuntime.Request.Epoch (spec) where

import Data.Maybe (isJust)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Request.Support
import Test.LuaRuntime.Scheduler.Support (nanoseconds)
import Test.LuaRuntime.Support (bounded, failExample, requiredPolicy, withBoundary)
import Control.Monad (void)
import Hetoimasia.Runtime.Supervision (WorkerStatus (WorkerStopped))
import Test.LuaRuntime.Scheduled.Support (awaitScheduledTerminal)

-- | The epoch change, expecting there to be one.
advanced ∷ ScheduledOwner → IO EpochReport
advanced owner = advanceRequestEpoch (scheduledEndpoint owner) >>= maybe (failExample "expected an epoch to advance") pure

spec ∷ Spec
spec = describe "epochs" $ do
  it "settles every outstanding request once as cancelled by the change, wakes a waiting script, tells the providers, and keeps their accounting until they say they are done" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \_ runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "epoch" [asker] cmdConfig (grantOf fake 4) requiredPolicy
      admitAsker fixture owner "i" "asker"
      admitAsker fixture owner "j" "asker"
      command fixture owner "i" "start" "a"
      awaitLine fixture "cmd start a started"
      command fixture owner "i" "start" "b"
      awaitLine fixture "cmd start b started"
      command fixture owner "j" "start_wait_take" "c"
      awaitLine fixture "waiting c"
      awaitSubmitted fake 3
      report ← advanced owner
      epochCancelled report `shouldBe` 3
      epochDiscarded report `shouldBe` 0
      awaitCancelled fake 3
      cancelledOrder fake >>= (`shouldBe` [0, 1, 2])
      awaitLine fixture "cmd start_wait_take c {reason=epoch_change,status=cancelled}"
      command fixture owner "i" "take" "a"
      awaitLine fixture "cmd take a {reason=epoch_change,status=cancelled}"
      command fixture owner "i" "take" "b"
      awaitLine fixture "cmd take b {reason=epoch_change,status=cancelled}"
      -- The providers have not said their work is over, and it is still counted.
      d ← diagnostics owner
      (rdWorkPending d, rdEpochCancelled d) `shouldBe` (3, 3)
      mapM_ (finishWork fake) [0, 1, 2]
      awaitDiagnostic owner ((== 0) . rdWorkPending)
      awaitDiagnostic owner ((== 0) . rdOutstanding)
      cancelledOrder fake >>= (`shouldBe` [0, 1, 2])

  it "lets a late reply retire the old epoch's work without reaching a request the new epoch issued" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \_ runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "stale" [asker] cmdConfig (grantOf fake 4) requiredPolicy
      admitAsker fixture owner "i" "asker"
      command fixture owner "i" "start" "a"
      awaitLine fixture "cmd start a started"
      before ← rdEpoch <$> diagnostics owner
      _ ← advanced owner
      after ← rdEpoch <$> diagnostics owner
      after `shouldSatisfy` (/= before)
      command fixture owner "i" "start" "b"
      awaitLine fixture "cmd start b started"
      -- The old request's reply is late, retires its work, and settles nothing of the new one.
      answerResult fake 0 99 >>= (`shouldBe` ReplyLate)
      command fixture owner "i" "ready" "b"
      awaitLine fixture "cmd ready b false"
      answerResult fake 1 5 >>= (`shouldBe` ReplySettled)
      command fixture owner "i" "take" "b"
      awaitLine fixture "cmd take b {status=result,value=5}"
      command fixture owner "i" "take" "a"
      awaitLine fixture "cmd take a {reason=epoch_change,status=cancelled}"
      awaitDiagnostic owner ((== 0) . rdWorkPending)

  it "discards a settled result nobody had taken, as the model does, and refuses the handle after" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \_ runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "discard" [asker] cmdConfig (grantOf fake 4) requiredPolicy
      admitAsker fixture owner "i" "asker"
      command fixture owner "i" "start" "a"
      awaitLine fixture "cmd start a started"
      _ ← answerResult fake 0 3
      report ← advanced owner
      (epochCancelled report, epochDiscarded report) `shouldBe` (0, 1)
      command fixture owner "i" "take" "a"
      refusalOf fixture "i" >>= (`shouldBe` Just "request refused: the handle names no request that is still held")

  it "leaves the instances alone: the same instance asks again after the change" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \_ runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "alive" [asker] cmdConfig (grantOf fake 4) requiredPolicy
      admitAsker fixture owner "i" "asker"
      _ ← advanced owner
      command fixture owner "i" "start" "a"
      awaitLine fixture "cmd start a started"
      phaseOf fixture owner "i" >>= (`shouldBe` Just Active)

  it "lets a tick that was held for a request begin, and the script take the cancellation" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \control runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "logical" [asker] cmdConfig (logicalGrant fake 4 Nothing) requiredPolicy
      admitAsker fixture owner "i" "asker"
      command fixture owner "i" "start" "a"
      awaitLine fixture "cmd start a started"
      void (grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1))
      tickReached owner >>= (`shouldBe` 0)
      _ ← advanced owner
      _ ← awaitTicksComplete control owner
      tickReached owner >>= (`shouldBe` 1)
      command fixture owner "i" "take" "a"
      awaitLine fixture "cmd take a {reason=epoch_change,status=cancelled}"

  it "advances nothing for an owner with no request service, and nothing once the owner has exited" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \control runtime → providersFinish fake $ do
      ungranted ← startRequesterWith fixture runtime ((requestSpec fixture "ungranted" [asker] cmdConfig (grantOf fake 4) requiredPolicy) {scheduledRequests = Nothing})
      advanceRequestEpoch (scheduledEndpoint ungranted) >>= (`shouldSatisfy` not . isJust)
      owner ← startRequester fixture runtime "exiting" [asker] cmdConfig (grantOf fake 4) requiredPolicy
      retireScheduled owner
      awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerStopped → True; _ → False)
      advanceRequestEpoch (scheduledEndpoint owner) >>= (`shouldSatisfy` not . isJust)
