-- | Waiting and observing from Lua: a script waits for its request cooperatively, without
-- blocking the owner; a settlement that arrives while its instance is paused is retained
-- without resuming Lua; readiness is a non-blocking query; and a wait in a hook that cannot
-- suspend is a reported hook fault.
module Test.LuaRuntime.Request.Waiting (spec) where

import Control.Concurrent (myThreadId)
import Control.Concurrent.MVar (readMVar)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Owner (BoundaryFault (boundaryReason), FaultReason (SuspendRefused), SuspendRefusal (SuspendOutsideTask))
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Runtime (CallFault (BoundaryFailed))
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Request.Support
import Test.LuaRuntime.Scheduled.Support (SFixture (sfObserver, sfOwnerThread), awaitIdle)
import Test.LuaRuntime.Support (bounded, requiredPolicy, withBoundary)

-- | What the instance's failure was, if the hook faulted on a wait that could not suspend.
suspendRefusalOf ∷ InstanceSettlement → Maybe SuspendRefusal
suspendRefusalOf settled = do
  failure ← failureOf' settled
  case failureError failure of
    ErrorFault (BoundaryFailed fault) | SuspendRefused why ← boundaryReason fault → Just why
    _ → Nothing

spec ∷ Spec
spec = describe "waiting" $ do
  it "resumes the waiting script at a safe boundary after the settlement arrives, without blocking the owner" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \_ runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "wait" [asker] cmdConfig (grantOf fake 4) requiredPolicy
      admitAsker fixture owner "i" "asker"
      admitAsker fixture owner "j" "asker"
      command fixture owner "i" "start_wait_take" "a"
      awaitLine fixture "waiting a"
      -- The owner is free while the script waits: another instance is served.
      command fixture owner "j" "start" "b"
      awaitLine fixture "cmd start b started"
      lineIn fixture "cmd start_wait_take" >>= (`shouldBe` Nothing)
      answerResult fake 0 11 >>= (`shouldBe` ReplySettled)
      awaitLine fixture "cmd start_wait_take a {status=result,value=11}"

  it "reaches Lua only on the owner's own thread: a provider completes on a thread of its own, and the script resumes in a segment of the owner" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    threads ← newIORef []
    atomicModifyIORef' (sfObserver (ifBase fixture)) (const (\_ → myThreadId >>= \thread → atomicModifyIORef' threads (\held → (thread : held, ())), ()))
    withBoundary $ \_ runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "threads" [asker] cmdConfig (grantOf fake 4) requiredPolicy
      admitAsker fixture owner "i" "asker"
      command fixture owner "i" "start_wait_take" "a"
      awaitLine fixture "waiting a"
      before ← length <$> readIORef threads
      providerThread ← myThreadId
      _ ← answerResult fake 0 2
      awaitLine fixture "cmd start_wait_take a {status=result,value=2}"
      seen ← readIORef threads
      ownerThread ← readMVar (sfOwnerThread (ifBase fixture))
      -- The script went on in a segment after the settlement arrived, and every segment was run
      -- by the owner's thread, never by the one that completed the request.
      length seen `shouldSatisfy` (> before)
      seen `shouldSatisfy` all (== ownerThread)
      providerThread `shouldSatisfy` (/= ownerThread)

  it "answers a readiness query without blocking, pending until the settlement is there" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \_ runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "ready" [asker] cmdConfig (grantOf fake 4) requiredPolicy
      admitAsker fixture owner "i" "asker"
      command fixture owner "i" "start" "a"
      awaitLine fixture "cmd start a started"
      command fixture owner "i" "ready" "a"
      awaitLine fixture "cmd ready a false"
      command fixture owner "i" "take" "a"
      awaitLine fixture "cmd take a {status=pending}"
      _ ← answerResult fake 0 4
      command fixture owner "i" "ready" "a"
      awaitLine fixture "cmd ready a true"
      -- A take that found nothing took nothing: the settlement is still there.
      command fixture owner "i" "take" "a"
      awaitLine fixture "cmd take a {status=result,value=4}"

  it "does not wait for a request that has settled already" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \_ runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "settled" [asker] cmdConfig (grantOf fake 4) requiredPolicy
      admitAsker fixture owner "i" "asker"
      command fixture owner "i" "start" "a"
      awaitLine fixture "cmd start a started"
      _ ← answerResult fake 0 6
      command fixture owner "i" "wait_take" "a"
      awaitLine fixture "cmd wait_take a {status=result,value=6}"

  it "retains a settlement that arrives while the instance is paused, without resuming Lua, and resumes it when the instance is resumed" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \_ runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "paused" [asker] cmdConfig (grantOf fake 4) requiredPolicy
      admitAsker fixture owner "i" "asker"
      admitAsker fixture owner "j" "asker"
      command fixture owner "i" "start_wait_take" "a"
      awaitLine fixture "waiting a"
      settleControl fixture owner "i" InstancePause >>= (`shouldBe` ControlApplied)
      _ ← answerResult fake 0 21
      -- The owner has served another instance since the settlement arrived, and is idle.
      command fixture owner "j" "start" "b"
      awaitLine fixture "cmd start b started"
      awaitIdle (ifBase fixture)
      lineIn fixture "cmd start_wait_take" >>= (`shouldBe` Nothing)
      -- The settlement is in the slot, retained.
      rdOutstanding <$> diagnostics owner >>= (`shouldSatisfy` (>= 1))
      settleControl fixture owner "i" InstanceResume >>= (`shouldBe` ControlApplied)
      awaitLine fixture "cmd start_wait_take a {status=result,value=21}"

  it "does not resume the continuation of an instance that is stopped while it waits" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \_ runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "stopped" [asker] cmdConfig (grantOf fake 4) requiredPolicy
      admitAsker fixture owner "i" "asker"
      command fixture owner "i" "start_wait_take" "a"
      awaitLine fixture "waiting a"
      _ ← expectControl fixture owner "i" InstanceStop
      awaitCancelled fake 1
      _ ← answerResult fake 0 1
      finishWork fake 0
      settled ← awaitSettled fixture "i"
      resultOutcome settled `shouldSatisfy` \case InstanceStopped → True; _ → False
      lineIn fixture "cmd start_wait_take" >>= (`shouldBe` Nothing)

  describe "a wait in a hook that cannot suspend" $ do
    it "is a reported hook fault in init" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "init wait" [waitInitAsker] cmdConfig (grantOf fake 4) requiredPolicy
        _ ← admitWith fixture owner "i" (askerRequest "i" "waitinitasker")
        awaitCancelled fake 1
        finishWork fake 0
        settled ← awaitSettled fixture "i"
        suspendRefusalOf settled `shouldBe` Just SuspendOutsideTask
        linesOf fixture >>= (`shouldSatisfy` notElem "init after")

    it "is a reported hook fault in shutdown" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "shutdown wait" [waitShutdownAsker] cmdConfig (grantOf fake 4) requiredPolicy
        admitAsker fixture owner "i" "waitshutdownasker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        _ ← expectControl fixture owner "i" InstanceStop
        awaitCancelled fake 1
        finishWork fake 0
        settled ← awaitSettled fixture "i"
        suspendRefusalOf settled `shouldBe` Just SuspendOutsideTask
        linesOf fixture >>= (`shouldSatisfy` notElem "shutdown after")

  it "refuses a wait for a request that is no longer held, failing the invocation and making no wait" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \_ runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "refused wait" [asker] cmdConfig (grantOf fake 4) requiredPolicy
      admitAsker fixture owner "i" "asker"
      command fixture owner "i" "start" "a"
      awaitLine fixture "cmd start a started"
      _ ← answerResult fake 0 2
      command fixture owner "i" "take" "a"
      awaitLine fixture "cmd take a {status=result,value=2}"
      -- The handle names nothing now: the binding refuses it, and the invocation fails.
      command fixture owner "i" "wait" "a"
      settled ← awaitSettled fixture "i"
      failureOf' settled `shouldSatisfy` maybe False (const True)
