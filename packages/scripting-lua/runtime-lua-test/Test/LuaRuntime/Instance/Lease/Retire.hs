-- | A provider that retires a resource later: the obligation it leaves, what it keeps
-- charged and live, and what it does to the instance's stop completion, the owner's
-- life and the bound on what an instance can have outstanding.
--
-- The fake provider completes or fails a retirement on the example's command and the
-- examples wait in STM, so none of them guesses how long anything takes.
module Test.LuaRuntime.Instance.Lease.Retire (spec) where

import Control.Concurrent.STM (atomically, writeTVar)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), toException)
import Control.Monad (forM_)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (cleanupFailureLabel, cleanupFailuresInContext)
import Hetoimasia.Runtime.Supervision (WorkerStatus (WorkerUnavailable))
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease
import Hetoimasia.Scripting.Lua.Owner (BoundaryFault (boundaryReason), FaultReason (BindingRefused))
import Hetoimasia.Scripting.Lua.Runtime (CallFault (BoundaryFailed), Discard (Discard), ExitKind (ExitCancelled, ExitFailed))
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Lease.Support
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (SFixture (sfOwnerThread), awaitEffect, awaitIdle, awaitScheduledTerminal, cancelQueued)
import Test.LuaRuntime.Support (Broken (Broken), awaitBlockedOnSTM, bounded, brokenIs, expectFatal, optionalPolicy, requiredPolicy, withBoundary)
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

  it "drains and parks an instance whose shutdown raises a failure of the host as the owner retires, and the owner waits for the provider" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    ExceptionWithContext _ raised ← expectFatal $ \control runtime → providersFinish fixture $ do
      owner ← startLeased fixture runtime "hook fails" [asyncShutdownFails] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "asyncshutdownfails")
      awaitPhase base owner "a" Active
      liveFor fixture "a" 1
      -- A segment runs and the owner goes idle, so that its thread is known and nothing it was
      -- given is left to serve.
      expectDelivered base owner "a" 1
      awaitIdle (sf base)
      retireScheduled owner
      -- The drain ran: the resource is handed to its provider, whose retirement is pending.
      awaitEffect (sf base) "retire async-hook"
      readMVar (sfOwnerThread (sf base)) >>= awaitBlockedOnSTM
      tickOf base "a" >>= pollInstance >>= (`shouldSatisfy` \case Nothing → True; Just _ → False)
      atomically (scheduledStatus owner) >>= (`shouldSatisfy` isLive)
      summaryOf fixture "a" >>= \summary → (summaryPending summary, summaryCharged summary) `shouldBe` (1, 1)
      completeRetirement fixture "async-hook"
      awaitScheduledTerminal control owner
    raised `shouldSatisfy` brokenIs "boom"
    settled ← tickOf base "a" >>= pollInstance
    fmap (leasesDrained . resultLeases) settled `shouldBe` Just 1
    summaryOf fixture "a" >>= (`shouldBe` ScopeSummary 0 0 0 0 4 0)

  it "retains a provider's query that throws as that retirement failing, and goes on awaiting the independent one until its provider completes it" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    ExceptionWithContext context _ ← expectFatal $ \control runtime → providersFinish fixture $ do
      owner ← startLeased fixture runtime "query throws" [asyncNamed] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "asyncnamed")
      _ ← admit base owner "b" (moduleNamed "asyncnamed")
      awaitPhase base owner "a" Active
      awaitPhase base owner "b" Active
      expectDelivered base owner "a" 1
      expectDelivered base owner "b" 1
      awaitPending fixture "a" 1
      awaitPending fixture "b" 1
      retireScheduled owner
      awaitPhase base owner "a" Stopping
      awaitPhase base owner "b" Stopping
      readMVar (sfOwnerThread (sf base)) >>= awaitBlockedOnSTM
      -- The first provider's query throws from now on; the second provider is still working.
      throwQuery fixture "named-1"
      a ← tickOf base "a"
      _ ← waitInstance a
      -- The failed one has settled, as failed at its release; the other is still awaited, and
      -- the owner is live with it.
      tickOf base "b" >>= pollInstance >>= (`shouldSatisfy` \case Nothing → True; Just _ → False)
      atomically (scheduledStatus owner) >>= (`shouldSatisfy` isLive)
      summaryOf fixture "b" >>= \summary → summaryPending summary `shouldBe` 1
      completeRetirement fixture "named-2"
      awaitScheduledTerminal control owner
    map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` any (Text.isInfixOf "lua lease retirement")
    settledA ← tickOf base "a" >>= pollInstance
    fmap resultPhase settledA `shouldBe` Just Failed
    settledB ← tickOf base "b" >>= pollInstance
    fmap (leasesAwaited . resultLeases) settledB `shouldBe` Just 1

  it "settles every ending that is ready when settling one raises the application's escalation as the owner retires, and does not wait for what has already completed" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    _ ← expectFatal $ \control runtime → providersFinish fixture $ do
      owner ← startLeased fixture runtime "escalated" [asyncNamed] escalating requiredPolicy
      _ ← admit base owner "a" (moduleNamed "asyncnamed")
      _ ← admit base owner "b" (moduleNamed "asyncnamed")
      awaitPhase base owner "a" Active
      awaitPhase base owner "b" Active
      expectDelivered base owner "a" 1
      expectDelivered base owner "b" 1
      awaitPending fixture "a" 1
      awaitPending fixture "b" 1
      retireScheduled owner
      awaitPhase base owner "a" Stopping
      awaitPhase base owner "b" Stopping
      readMVar (sfOwnerThread (sf base)) >>= awaitBlockedOnSTM
      tickOf base "a" >>= pollInstance >>= (`shouldSatisfy` \case Nothing → True; Just _ → False)
      tickOf base "b" >>= pollInstance >>= (`shouldSatisfy` \case Nothing → True; Just _ → False)
      -- Both providers finish together, the first with a failure that fails its instance:
      -- the application escalates it while the second is still to be settled.
      first ← provided fixture "named-1"
      second ← provided fixture "named-2"
      atomically (writeTVar first (ProviderFailed (toException (Broken "retire named-1"))) >> writeTVar second ProviderComplete)
      awaitScheduledTerminal control owner
    settledA ← tickOf base "a" >>= pollInstance
    settledB ← tickOf base "b" >>= pollInstance
    fmap resultPhase settledA `shouldBe` Just Failed
    fmap resultPhase settledB `shouldSatisfy` (/= Nothing)

  it "begins nothing once a provider's failed retirement is observed: work queued behind it never starts, and the owner exits as a failure" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    ExceptionWithContext context _ ← expectFatal $ \control runtime → providersFinish fixture $ do
      owner ← startLeased fixture runtime "halted" [asyncNamed, marker, holder] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "asyncnamed")
      _ ← admit base owner "m" (moduleNamed "marker")
      awaitPhase base owner "a" Active
      awaitPhase base owner "m" Active
      expectDelivered base owner "a" 1
      awaitPending fixture "a" 1
      -- The owner is held inside a segment while the provider fails and an event is queued
      -- for the other instance: both are waiting when it comes to its next boundary.
      holdOwner base owner
      expectDelivered base owner "m" 1
      failRetirement fixture "named-1"
      releaseOwner base
      awaitScheduledTerminal control owner
    map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` any (Text.isInfixOf "lua lease retirement")
    -- The queued work never began: it is discarded as an unstarted invocation.
    history fixture >>= (`shouldSatisfy` notElem "ran marker")
    settled ← tickOf base "m" >>= pollInstance
    case settled of
      Just result → do
        resultOutcome result `shouldSatisfy` \case InstanceDiscarded (Discard ExitFailed _) → True; _ → False
        terminationUnstarted (resultTermination result) `shouldBe` 1
      Nothing → fail "expected the instance to have settled"

  it "disposes what a retirement needs only when the provider has proved it complete: not under a pending retirement, in a stop or a cancellation, and before the stop completion settles" $ bounded $ do
    forM_ [("stopped", False), ("retired", True)] $ \(label, byOwner) → do
      fixture ← newLFix 4
      let base = lfBase fixture
      withBoundary $ \control runtime → providersFinish fixture $ do
        owner ← startLeased fixture runtime ("dependency " <> label) [dependentHolder] leaseConfig requiredPolicy
        _ ← admit base owner "a" (moduleNamed "dependentholder")
        awaitPhase base owner "a" Active
        expectDelivered base owner "a" 1
        awaitEffect (sf base) "release Retiring"
        if byOwner then retireScheduled owner else stop fixture owner "a"
        awaitPhase base owner "a" Stopping
        tickOf base "a" >>= pollInstance >>= (`shouldSatisfy` \case Nothing → True; Just _ → False)
        -- The device was acquired and is still in use by the retirement.
        history fixture >>= \entries → (entries `shouldSatisfy` elem "acquire dep-res.device") >> (entries `shouldSatisfy` notElem "dispose dep-res.device")
        completeRetirement fixture "dep-res"
        settled ← awaitSettled base "a"
        history fixture >>= \entries → filter (== "dispose dep-res.device") entries `shouldBe` ["dispose dep-res.device"]
        resultLeases settled `shouldBe` LeaseOutcome 0 1 0
        retireScheduled owner
        _ ← awaitScheduledTerminal control owner
        pure ()

  it "keeps a lease whose disposal failed failed: a closing handler's release during the teardown answers the failure and does not run the disposal again" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    breakRelease fixture "dep-res.device"
    _ ← expectFatal $ \control runtime → providersFinish fixture $ do
      owner ← startLeased fixture runtime "disposal failed" [closingDependent] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "closingdependent")
      awaitPhase base owner "a" Active
      expectDelivered base owner "a" 1
      awaitEffect (sf base) "release Retiring"
      awaitDiagnosticsWaiting owner
      completeRetirement fixture "dep-res"
      awaitScheduledTerminal control owner
    entries ← history fixture
    -- The disposal ran once and failed; the release from the closing handler was not
    -- answered as released, and ran nothing.
    filter (== "dispose dep-res.device") entries `shouldBe` ["dispose dep-res.device"]
    entries `shouldSatisfy` elem "closing release false"
    entries `shouldSatisfy` all (not . Text.isPrefixOf "released AlreadyReleased")

  it "disposes what a release needs at once when no retirement is pending, after the resource it released" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    withBoundary $ \control runtime → do
      owner ← startLeased fixture runtime "dependency now" [dependentNowHolder] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "dependentnowholder")
      awaitPhase base owner "a" Active
      expectDelivered base owner "a" 1
      awaitEffect (sf base) "release Released"
      history fixture >>= \entries →
        filter (Text.isInfixOf "now-res") entries
          `shouldBe` ["acquire now-res.device", "acquire now-res", "release now-res", "dispose now-res.device"]
      retireScheduled owner
      _ ← awaitScheduledTerminal control owner
      pure ()

  it "never disposes what a failed retirement needs, and retains the failure" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    _ ← expectFatal $ \control runtime → providersFinish fixture $ do
      owner ← startLeased fixture runtime "dependency failed" [dependentHolder] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "dependentholder")
      awaitPhase base owner "a" Active
      expectDelivered base owner "a" 1
      awaitEffect (sf base) "release Retiring"
      failRetirement fixture "dep-res"
      awaitScheduledTerminal control owner
    history fixture >>= \entries → entries `shouldSatisfy` notElem "dispose dep-res.device"

  it "keeps a disposal that fails as cleanup evidence, fatal whatever the policy" $ bounded $ do
    forM_ [("required", requiredPolicy), ("optional", optionalPolicy (const True))] $ \(label, policy) → do
      fixture ← newLFix 4
      let base = lfBase fixture
      breakRelease fixture "dep-res.device"
      ExceptionWithContext context _ ← expectFatal $ \control runtime → providersFinish fixture $ do
        owner ← startLeased fixture runtime ("dependency broken " <> label) [dependentHolder] leaseConfig policy
        _ ← admit base owner "a" (moduleNamed "dependentholder")
        awaitPhase base owner "a" Active
        expectDelivered base owner "a" 1
        awaitEffect (sf base) "release Retiring"
        completeRetirement fixture "dep-res"
        awaitScheduledTerminal control owner
      map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` any (Text.isInfixOf "lua lease dependency")

  it "keeps what a rolled-back stage's retirement needs until its provider is done, though the constructor failed" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    withBoundary $ \control runtime → providersFinish fixture $ do
      owner ← startLeased fixture runtime "dependency rolled back" [dependentRollback] leaseConfig (optionalPolicy (const True))
      _ ← admit base owner "a" (moduleNamed "dependentrollback")
      awaitPhase base owner "a" Active
      expectDelivered base owner "a" 1
      awaitSummary fixture "a" (\summary → summaryPending summary == 1)
      awaitPhase base owner "a" Stopping
      history fixture >>= (`shouldSatisfy` notElem "dispose dep-rolled.device")
      completeRetirement fixture "dep-rolled"
      awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerUnavailable _ → True; _ → False)
      history fixture >>= (`shouldSatisfy` elem "dispose dep-rolled.device")

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
