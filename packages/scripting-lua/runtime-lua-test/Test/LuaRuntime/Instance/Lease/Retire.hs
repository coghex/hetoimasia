-- | A provider that retires a resource later: the obligation it leaves, what it keeps
-- charged and live, and what it does to the instance's stop completion, the owner's
-- life and the bound on what an instance can have outstanding.
--
-- The fake provider completes or fails a retirement on the example's command and the
-- examples wait in STM, so none of them guesses how long anything takes.
module Test.LuaRuntime.Instance.Lease.Retire (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (ExceptionWithContext (ExceptionWithContext))
import Control.Monad (forM_)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (cleanupFailureLabel, cleanupFailuresInContext)
import Hetoimasia.Runtime.Supervision (WorkerStatus (WorkerUnavailable))
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease
import Hetoimasia.Scripting.Lua.Owner (BoundaryFault (boundaryReason), FaultReason (BindingRefused))
import Hetoimasia.Scripting.Lua.Runtime (CallFault (BoundaryFailed), Discard (Discard), ExitKind (ExitCancelled))
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Lease.Support
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (SFixture (sfOwnerThread), awaitEffect, awaitScheduledTerminal, cancelQueued)
import Test.LuaRuntime.Support (awaitBlockedOnSTM, bounded, expectFatal, optionalPolicy, requiredPolicy, withBoundary)
import Control.Concurrent.MVar (readMVar)

-- | Block until an instance has this many retirements pending.
awaitPending ∷ LFix → Text.Text → Int → IO ()
awaitPending fixture name n = awaitSummary fixture name ((== n) . summaryPending)

stop ∷ LFix → ScheduledOwner → Text.Text → IO ()
stop fixture owner name = settleControl (lfBase fixture) owner name InstanceStop >>= (`shouldBe` ControlApplied)

spec ∷ Spec
spec = describe "retained retirement" $ do
  it "revokes at once, answers that the retirement is pending without restarting it, and holds the stop completion until the provider says it is done" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    withBoundary $ \control runtime → providersFinish fixture $ do
      owner ← startLeased fixture runtime "pending" [asyncHolder] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "asyncholder")
      awaitPhase base owner "a" Active
      liveFor fixture "a" 1
      expectDelivered base owner "a" 1
      awaitEffect (sf base) "again Retiring"
      -- Revoked, charged, and handed to its provider once.
      summaryOf fixture "a" >>= \summary → (summaryLive summary, summaryPending summary, summaryCharged summary) `shouldBe` (0, 1, 1)
      history fixture >>= \entries → filter (== "retire async-res") entries `shouldBe` ["retire async-res"]
      history fixture >>= (`shouldSatisfy` elem "release Retiring")
      stop fixture owner "a"
      -- Stopped as far as Lua is concerned, and not stopped as far as anything else is.
      awaitPhase base owner "a" Stopping
      tickOf base "a" >>= pollInstance >>= (`shouldSatisfy` \case Nothing → True; Just _ → False)
      atomically (scheduledStatus owner) >>= (`shouldSatisfy` isLive)
      summaryOf fixture "a" >>= \summary → (summaryPending summary, summaryCharged summary) `shouldBe` (1, 1)
      completeRetirement fixture "async-res"
      settled ← awaitSettled base "a"
      resultOutcome settled `shouldSatisfy` \case InstanceStopped → True; _ → False
      resultLeases settled `shouldBe` LeaseOutcome 0 1 0
      summaryOf fixture "a" >>= (`shouldBe` ScopeSummary 0 0 0 0 4 0)
      history fixture >>= \entries → length (filter (== "retire async-res") entries) `shouldBe` 1
      retireScheduled owner
      _ ← awaitScheduledTerminal control owner
      pure ()

  it "retains a provider's failed retirement as cleanup evidence, fatal for required and optional owners alike, and settles the instance as failed at the release" $ bounded $ do
    forM_ [("required", requiredPolicy), ("optional", optionalPolicy (const True))] $ \(label, policy) → do
      fixture ← newLFix 4
      let base = lfBase fixture
      ExceptionWithContext context _ ← expectFatal $ \control runtime → providersFinish fixture $ do
        owner ← startLeased fixture runtime ("provider failure " <> label) [asyncHolder] leaseConfig policy
        _ ← admit base owner "a" (moduleNamed "asyncholder")
        awaitPhase base owner "a" Active
        expectDelivered base owner "a" 1
        awaitEffect (sf base) "again Retiring"
        failRetirement fixture "async-res"
        awaitScheduledTerminal control owner
      map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` any (Text.isInfixOf "lua lease retirement")
      settled ← tickOf base "a" >>= pollInstance
      case settled of
        Just result → do
          resultPhase result `shouldBe` Failed
          fmap failureStage (failureOf' result) `shouldBe` Just StageRelease
          leasesFailed (resultLeases result) `shouldBe` 1
        Nothing → fail "expected the instance to have settled"

  it "keeps the owner live through a retirement, an orderly stop and a cancellation alike, until the provider has completed it" $ bounded $ do
    forM_ [("retired", False), ("cancelled", True)] $ \(label, cancel) → do
      fixture ← newLFix 4
      let base = lfBase fixture
      withBoundary $ \control runtime → providersFinish fixture $ do
        owner ← startLeased fixture runtime ("live " <> label) [asyncHolder, holder] leaseConfig requiredPolicy
        _ ← admit base owner "a" (moduleNamed "asyncholder")
        awaitPhase base owner "a" Active
        expectDelivered base owner "a" 1
        awaitEffect (sf base) "again Retiring"
        -- A cancellation is queued while the owner is inside a segment, so that it lands
        -- when the segment returns and is not taken for an orderly stop.
        if cancel
          then holdOwner base owner >> cancelQueued owner >> releaseOwner base
          else retireScheduled owner
        -- Its end has begun; nothing finishes it.
        awaitPhase base owner "a" Stopping
        readMVar (sfOwnerThread (sf base)) >>= awaitBlockedOnSTM
        tickOf base "a" >>= pollInstance >>= (`shouldSatisfy` \case Nothing → True; Just _ → False)
        atomically (scheduledStatus owner) >>= (`shouldSatisfy` isLive)
        summaryOf fixture "a" >>= \summary → (summaryPending summary, summaryCharged summary) `shouldBe` (1, 1)
        completeRetirement fixture "async-res"
        awaitScheduledTerminal control owner >>= (`shouldSatisfy` isStopped)
        settled ← awaitSettled base "a"
        -- Nothing is reported as reclaimed before then, and what it came to is the owner's exit.
        if cancel
          then resultOutcome settled `shouldSatisfy` \case InstanceDiscarded (Discard ExitCancelled _) → True; _ → False
          else resultOutcome settled `shouldSatisfy` \case InstanceStopped → True; _ → False
        resultLeases settled `shouldBe` LeaseOutcome 0 1 0
        summaryOf fixture "a" >>= (`shouldBe` ScopeSummary 0 0 0 0 4 0)

  it "bounds what an instance can have outstanding: repeated cycles whose retirement is pending are refused at the capacity, and one the provider completes makes room" $ bounded $ do
    fixture ← newLFix 2
    let base = lfBase fixture
    withBoundary $ \control runtime → providersFinish fixture $ do
      owner ← startLeased fixture runtime "bounded" [cycler] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "cycler")
      awaitPhase base owner "a" Active
      expectDelivered base owner "a" 1
      awaitEffect (sf base) "release Retiring"
      awaitPending fixture "a" 1
      expectDelivered base owner "a" 2
      awaitPending fixture "a" 2
      -- Released, with nothing live, and the capacity still charged.
      summaryOf fixture "a" >>= \summary → (summaryLive summary, summaryPending summary, summaryCharged summary) `shouldBe` (0, 2, 2)
      -- The provider finishes the first, and the next cycle has room.
      completeRetirement fixture "cycle-1"
      awaitPending fixture "a" 1
      summaryOf fixture "a" >>= (`shouldSatisfy` ((== 1) . summaryCharged))
      expectDelivered base owner "a" 3
      awaitPending fixture "a" 2
      history fixture >>= \entries → filter (Text.isPrefixOf "open ") entries `shouldBe` ["open cycle-1 true", "open cycle-2 true", "open cycle-3 true"]
      -- Now it is full again: the fourth is refused before any stage runs, as the engine.
      expectDelivered base owner "a" 4
      awaitEffect (sf base) "open cycle-4 false"
      history fixture >>= \entries → entries `shouldSatisfy` notElem "acquire cycle-4"
      -- The refusal faults the invocation, and the instance's end waits for two
      -- retirements its providers have not finished: it is ending and not ended, and
      -- the owner is live.
      awaitPhase base owner "a" Stopping
      tickOf base "a" >>= pollInstance >>= (`shouldSatisfy` \case Nothing → True; Just _ → False)
      atomically (scheduledStatus owner) >>= (`shouldSatisfy` isLive)
      completeRetirement fixture "cycle-2"
      completeRetirement fixture "cycle-3"
      settled ← awaitSettled base "a"
      resultPhase settled `shouldBe` Failed
      case failureOf' settled of
        Just failure → failureError failure `shouldSatisfy` \case
          ErrorFault (BoundaryFailed fault) → case boundaryReason fault of
            BindingRefused _ → True
            _ → False
          _ → False
        Nothing → fail "expected a failure"
      resultLeases settled `shouldBe` LeaseOutcome 0 2 0
      retireScheduled owner
      _ ← awaitScheduledTerminal control owner
      pure ()

  it "keeps the capacity and the owner's life for a stage rolled back whose provider has not finished, though the constructor failed" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    withBoundary $ \control runtime → providersFinish fixture $ do
      -- The constructor's failure is a failure of the host, which an optional owner that
      -- recognizes it ends as unavailable; the retirement it left is awaited all the same.
      owner ← startLeased fixture runtime "rolled back" [asyncRollback] leaseConfig (optionalPolicy (const True))
      _ ← admit base owner "a" (moduleNamed "asyncrollback")
      awaitPhase base owner "a" Active
      expectDelivered base owner "a" 1
      awaitSummary fixture "a" (\summary → summaryPending summary == 1)
      summaryOf fixture "a" >>= \summary → (summaryLive summary, summaryCharged summary) `shouldBe` (0, 1)
      awaitPhase base owner "a" Stopping
      atomically (scheduledStatus owner) >>= (`shouldSatisfy` isLive)
      tickOf base "a" >>= pollInstance >>= (`shouldSatisfy` \case Nothing → True; Just _ → False)
      completeRetirement fixture "rolled-back"
      awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerUnavailable _ → True; _ → False)
      summaryOf fixture "a" >>= (`shouldBe` ScopeSummary 0 0 0 0 4 0)
