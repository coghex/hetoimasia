-- | The end of an owner with requests outstanding, and what a provider's dependency waits for:
-- stop, failure and cancellation revoke every request, tell the providers, and keep the owner
-- live, and what its work needed undisposed of, until each provider has proved its work over;
-- cancelling a script's interest is not proof the work ended; and a cancel and a stop racing
-- settle a request once.
module Test.LuaRuntime.Request.Teardown (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (ExceptionWithContext (ExceptionWithContext))
import Hetoimasia.Runtime.Supervision (WorkerStatus (WorkerLive, WorkerStopped, WorkerUnavailable))
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Request.Support
import Test.LuaRuntime.Scheduled.Support (awaitScheduledTerminal)
import Test.LuaRuntime.Support (bounded, brokenIs, optionalPolicy, requiredPolicy, withBoundary)

isLive ∷ WorkerStatus → Bool
isLive = \case
  WorkerLive → True
  _ → False

spec ∷ Spec
spec = describe "the owner's end" $ do
  it "revokes what is outstanding on a stop, tells the provider, and stays live, with what its work needed undisposed of, until the provider proves its work over" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \control runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "stop" [asker] cmdConfig (grantOf fake 4) requiredPolicy
      admitAsker fixture owner "i" "asker"
      commandFrom fixture owner "i" "start" "a" Nothing (Just 4)
      awaitLine fixture "cmd start a started"
      retireScheduled owner
      awaitCancelled fake 1
      cancelledOrder fake >>= (`shouldBe` [0])
      -- The provider has been told, and has not said it is done: the owner is live, and its
      -- dependency is where it was.
      atomically (scheduledStatus owner) >>= (`shouldSatisfy` isLive)
      linesOf fixture >>= (`shouldSatisfy` notElem "disposed 4")
      finishWork fake 0
      awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerStopped → True; _ → False)
      linesOf fixture >>= (`shouldSatisfy` elem "disposed 4")
      rdInvalidated <$> diagnostics owner >>= (`shouldBe` 1)

  it "does the same when the owner fails, with the failure primary" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \control runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "failing" [asker] cmdConfig (grantOf fake 4) (optionalPolicy (brokenIs "boom"))
      admitAsker fixture owner "i" "asker"
      commandFrom fixture owner "i" "start" "a" Nothing (Just 5)
      awaitLine fixture "cmd start a started"
      command fixture owner "i" "hostfail" "a"
      awaitCancelled fake 1
      atomically (scheduledStatus owner) >>= (`shouldSatisfy` isLive)
      linesOf fixture >>= (`shouldSatisfy` notElem "disposed 5")
      finishWork fake 0
      awaitScheduledTerminal control owner >>= \case
        WorkerUnavailable (ExceptionWithContext _ failure) → failure `shouldSatisfy` brokenIs "boom"
        other → fail ("expected an unavailable owner, found " <> show other)
      linesOf fixture >>= (`shouldSatisfy` elem "disposed 5")

  it "does the same when the owner is cancelled" $ bounded $ do
    fixture ← newIFixture
    fake ← newFake
    withBoundary $ \control runtime → providersFinish fake $ do
      owner ← startRequester fixture runtime "cancelled" [asker] cmdConfig (grantOf fake 4) (optionalPolicy (const True))
      admitAsker fixture owner "i" "asker"
      commandFrom fixture owner "i" "start" "a" Nothing (Just 6)
      awaitLine fixture "cmd start a started"
      cancelScheduled owner
      awaitCancelled fake 1
      atomically (scheduledStatus owner) >>= (`shouldSatisfy` isLive)
      linesOf fixture >>= (`shouldSatisfy` notElem "disposed 6")
      finishWork fake 0
      _ ← awaitScheduledTerminal control owner
      linesOf fixture >>= (`shouldSatisfy` elem "disposed 6")

  describe "what a request's work needed" $ do
    it "stays undisposed of after the script cancelled, until the provider proves its work over by its own reading" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "dependency" [asker] cmdConfig (grantOf fake 4) requiredPolicy
        admitAsker fixture owner "i" "asker"
        commandFrom fixture owner "i" "start" "a" Nothing (Just 7)
        awaitLine fixture "cmd start a started"
        command fixture owner "i" "cancel" "a"
        awaitLine fixture "cmd cancel a cancelled"
        command fixture owner "i" "take" "a"
        awaitLine fixture "cmd take a {reason=owner,status=cancelled}"
        -- Cancelled and taken: the script's interest is gone, and the work is not over.
        linesOf fixture >>= (`shouldSatisfy` notElem "disposed 7")
        rdWorkPending <$> diagnostics owner >>= (`shouldBe` 1)
        finishWork fake 0
        awaitLine fixture "disposed 7"
        awaitDiagnostic owner ((== 0) . rdWorkPending)

    it "is disposed of once when the provider's reply is the proof" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← startRequester fixture runtime "reply proof" [asker] cmdConfig (grantOf fake 4) requiredPolicy
        admitAsker fixture owner "i" "asker"
        commandFrom fixture owner "i" "start" "a" Nothing (Just 8)
        awaitLine fixture "cmd start a started"
        linesOf fixture >>= (`shouldSatisfy` notElem "disposed 8")
        _ ← answerResult fake 0 1
        awaitLine fixture "disposed 8"
        _ ← answerResult fake 0 2
        command fixture owner "i" "take" "a"
        awaitLine fixture "cmd take a {status=result,value=1}"
        countOf fixture "disposed 8" >>= (`shouldBe` 1)

  describe "a cancel and a stop racing" $ do
    it "settle a request once, in either order, and the provider is told once" $ bounded $ do
      mapM_
        ( \order → do
            fixture ← newIFixture
            fake ← newFake
            withBoundary $ \_ runtime → providersFinish fake $ do
              owner ← startRequester fixture runtime "race" [asker] cmdConfig (grantOf fake 4) requiredPolicy
              admitAsker fixture owner "i" "asker"
              command fixture owner "i" "start" "a"
              awaitLine fixture "cmd start a started"
              if order
                then do
                  command fixture owner "i" "cancel" "a"
                  awaitLine fixture "cmd cancel a cancelled"
                  _ ← expectControl fixture owner "i" InstanceStop
                  pure ()
                else do
                  _ ← expectControl fixture owner "i" InstanceStop
                  awaitCancelled fake 1
              finishWork fake 0
              _ ← awaitSettled fixture "i"
              cancelledOrder fake >>= (`shouldBe` [0])
              awaitDiagnostic owner ((== 0) . rdOutstanding)
              d ← diagnostics owner
              -- Cancelled by the script, or revoked by the stop, and never both.
              (rdInvalidated d, rdWorkPending d) `shouldSatisfy` (\(invalidated, pending) → invalidated <= 1 && pending == 0)
        )
        [True, False]
