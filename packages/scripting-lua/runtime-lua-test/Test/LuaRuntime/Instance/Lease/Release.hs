-- | Releasing: early and twice, a release that fails, and the drain on every way an
-- instance can end.
--
-- Every end the instance layer has is exercised with a module that holds a resource and
-- does nothing about it, and each must release it, after the instance's @shutdown@
-- when that ran, and without Lua cleanup of any kind.
module Test.LuaRuntime.Instance.Lease.Release (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext))
import Control.Monad (forM_)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (cleanupFailureLabel, cleanupFailuresInContext)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease (ScopeSummary (..))
import Hetoimasia.Scripting.Lua.Owner (BoundaryFault (boundaryReason), FaultReason (ValueRefused))
import Hetoimasia.Scripting.Lua.Runtime (CallFault (BoundaryFailed), Discard (Discard), ExitKind (ExitCancelled))
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (ValueRefusal (refusalRule), ValueRule (RuleRetiredHandle))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Lease.Support
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (awaitScheduledTerminal, cancelQueued)
import Test.LuaRuntime.Support (bounded, brokenIs, expectFatal, optionalPolicy, requiredPolicy, withBoundary)

releases ∷ [Text.Text] → [Text.Text]
releases = filter (Text.isPrefixOf "release ")

stop ∷ LFix → ScheduledOwner → Text.Text → IO ()
stop fixture owner name = settleControl (lfBase fixture) owner name InstanceStop >>= (`shouldBe` ControlApplied)

-- | The release failures, secondary or primary, an instance settled with.
spec ∷ Spec
spec = describe "releasing" $ do
  it "releases early and answers released, then already-released for every later release, running the native release once, and accepts the retired handle only to release it" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    withBoundary $ \control runtime → do
      owner ← startLeased fixture runtime "early" [releasesEarly] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "releasesearly")
      awaitPhase base owner "a" Active
      entries ← history fixture
      -- The answers, in order: released, then already-released twice.
      filter (Text.isPrefixOf "released ") entries `shouldBe` ["released Released", "released AlreadyReleased", "released AlreadyReleased"]
      -- One native release of the resource released early; the other is still held.
      releases entries `shouldBe` ["release early.b", "release early.a"]
      liveFor fixture "a" 1
      retireScheduled owner
      _ ← awaitScheduledTerminal control owner
      releases <$> history fixture >>= (`shouldBe` ["release early.b", "release early.a", "release kept.b", "release kept.a"])

  it "refuses every other use of a retired handle before the binding's action runs" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    withBoundary $ \_ runtime → do
      owner ← startLeased fixture runtime "retired" [usesRetired] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "usesretired")
      awaitPhase base owner "a" Active
      expectDelivered base owner "a" 1
      settled ← awaitSettled base "a"
      resultPhase settled `shouldBe` Failed
      case failureOf' settled of
        Just failure → failureError failure `shouldSatisfy` \case
          ErrorFault (BoundaryFailed fault) → case boundaryReason fault of
            ValueRefused refusal → case refusalRule refusal of
              RuleRetiredHandle _ → True
              _ → False
            _ → False
          _ → False
        Nothing → fail "expected a failure"
      entries ← history fixture
      -- The action of the use never ran, so it recorded nothing.
      entries `shouldSatisfy` notElem "use retired-res"
      entries `shouldSatisfy` notElem "unreachable"
      releases entries `shouldBe` ["release retired-res.b", "release retired-res.a"]

  it "keeps a failed release as the answer to every later release, runs no second native release, and is fatal for required and optional owners alike" $ bounded $ do
    forM_ [("required", requiredPolicy), ("optional", optionalPolicy (const True))] $ \(label, policy) → do
      fixture ← newLFix 4
      let base = lfBase fixture
      breakRelease fixture "brittle"
      ExceptionWithContext context raised ← expectFatal $ \control runtime → do
        owner ← startLeased fixture runtime ("brittle " <> label) [breaker] leaseConfig policy
        _ ← admit base owner "a" (moduleNamed "breaker")
        awaitPhase base owner "a" Active
        expectDelivered base owner "a" 1
        awaitScheduledTerminal control owner
      raised `shouldSatisfy` brokenIs "release brittle"
      map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` any (Text.isInfixOf "brittle.a")
      entries ← history fixture
      -- Neither release answered success, and the native cleanup ran once.
      entries `shouldSatisfy` elem "first false"
      entries `shouldSatisfy` elem "second false"
      releases entries `shouldBe` ["release brittle.b", "release brittle.a"]
      entries `shouldSatisfy` all (not . Text.isPrefixOf "released ")

  it "continues past a failing release to every independent holding, retains the failure beside the others and ends the owner as cleanup does" $ bounded $ do
    forM_ [("required", requiredPolicy), ("optional", optionalPolicy (const True))] $ \(label, policy) → do
      fixture ← newLFix 4
      let base = lfBase fixture
      breakRelease fixture "indep-b"
      ExceptionWithContext context raised ← expectFatal $ \control runtime → do
        owner ← startLeased fixture runtime ("independent " <> label) [independent] leaseConfig policy
        _ ← admit base owner "a" (moduleNamed "independent")
        awaitPhase base owner "a" Active
        liveFor fixture "a" 3
        _ ← askControl base owner "a" InstanceStop
        awaitScheduledTerminal control owner
      -- The failure is the owner's cleanup evidence, retained whatever the policy said.
      map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` any (Text.isPrefixOf "lua instance lease")
      raised `shouldSatisfy` brokenIs "release indep-b"
      entries ← history fixture
      -- Newest first, the failing one attempted in its place, and every other released.
      releases entries
        `shouldBe` [ "release indep-c.b"
                   , "release indep-c.a"
                   , "release indep-b.b"
                   , "release indep-b.a"
                   , "release indep-a.b"
                   , "release indep-a.a"
                   ]
      -- The instance's terminal outcome keeps it: failed at the release, not stopped.
      settled ← tickOf base "a" >>= pollInstance
      case settled of
        Just result → do
          resultPhase result `shouldBe` Failed
          fmap failureStage (failureOf' result) `shouldBe` Just StageRelease
          leasesFailed (resultLeases result) `shouldBe` 1
          leasesDrained (resultLeases result) `shouldBe` 2
        Nothing → fail "expected the instance to have settled"

  it "ends the owner as a failure at once: the instances still to end during an orderly retirement have no shutdown run, and their holdings are drained all the same" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    breakRelease fixture "indep-b"
    _ ← expectFatal $ \control runtime → do
      owner ← startLeased fixture runtime "unorderly" [independent, plain] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "independent")
      _ ← admit base owner "b" (moduleNamed "plain")
      awaitPhase base owner "a" Active
      awaitPhase base owner "b" Active
      liveFor fixture "a" 3
      liveFor fixture "b" 1
      retireScheduled owner
      awaitScheduledTerminal control owner
    entries ← history fixture
    -- The first instance's hook ran and its drain failed; the second's hook did not.
    entries `shouldSatisfy` elem "shutdown 1 stopped"
    entries `shouldSatisfy` notElem "shutdown 2 stopped"
    entries `shouldSatisfy` elem "release plain-res.a"
    settled ← tickOf base "b" >>= pollInstance
    case settled of
      Just result → do
        terminationShutdown (resultTermination result) `shouldBe` ShutdownSkippedUnsafe
        leasesDrained (resultLeases result) `shouldBe` 1
      Nothing → fail "expected the instance to have settled"

  it "keeps a failed release in the instance's outcome when a cancellation is queued inside it: the independent holdings are still released, once each, and the failure is not lost" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    breakRelease fixture "indep-b"
    blockRelease fixture "indep-b"
    _ ← expectFatal $ \control runtime → do
      owner ← startLeased fixture runtime "cancelled in release" [independent] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "independent")
      awaitPhase base owner "a" Active
      liveFor fixture "a" 3
      _ ← askControl base owner "a" InstanceStop
      -- The release of the middle holding is inside the drain, at its gate, when the
      -- cancellation is queued behind it.
      awaitReleaseEntered fixture
      cancelQueued owner
      proceedRelease fixture
      awaitScheduledTerminal control owner
    entries ← history fixture
    releases entries
      `shouldBe` [ "release indep-c.b"
                 , "release indep-c.a"
                 , "release indep-b.b"
                 , "release indep-b.a"
                 , "release indep-a.b"
                 , "release indep-a.a"
                 ]
    settled ← tickOf base "a" >>= pollInstance
    case settled of
      Just result → do
        resultPhase result `shouldBe` Failed
        fmap failureStage (failureOf' result) `shouldBe` Just StageRelease
        leasesFailed (resultLeases result) `shouldBe` 1
        leasesDrained (resultLeases result) `shouldBe` 2
      Nothing → fail "expected the instance to have settled"

  it "keeps the instance's primary failure primary and retains a release failure beside it, fatal for the owner whatever its policy" $ bounded $ do
    forM_ [("required", requiredPolicy), ("optional", optionalPolicy (const True))] $ \(label, policy) → do
      fixture ← newLFix 4
      let base = lfBase fixture
      breakRelease fixture "fault-res"
      ExceptionWithContext context _ ← expectFatal $ \control runtime → do
        owner ← startLeased fixture runtime ("primary " <> label) [faultingHolder] leaseConfig policy
        _ ← admit base owner "a" (moduleNamed "faultingholder")
        awaitPhase base owner "a" Active
        expectDelivered base owner "a" 1
        awaitScheduledTerminal control owner
      map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` any (Text.isPrefixOf "lua instance lease")
      settled ← tickOf base "a" >>= pollInstance
      case settled >>= failureOf' of
        Just failure → do
          -- The callback's error is the failure, and the release is beside it.
          failureStage failure `shouldBe` StageEvent "tick"
          failureMessage failure `shouldSatisfy` Text.isInfixOf "callback boom"
          map fst (failureSecondary failure) `shouldBe` [StageRelease]
        Nothing → fail "expected the instance to have failed"

  it "lets a closing handler the script defined release a handle, as the instance whose invocation it is" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    withBoundary $ \control runtime → do
      owner ← startLeased fixture runtime "closing releases" [closingReleaser] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "closingreleaser")
      awaitPhase base owner "a" Active
      expectDelivered base owner "a" 1
      awaitDiagnosticsWaiting owner
      stop fixture owner "a"
      settled ← awaitSettled base "a"
      entries ← history fixture
      entries `shouldSatisfy` elem "closing releases Released"
      -- The handler's release was the only one: the drain found nothing left.
      releases entries `shouldBe` ["release closing-res.b", "release closing-res.a"]
      resultLeases settled `shouldBe` LeaseOutcome 0 0 0
      retireScheduled owner
      _ ← awaitScheduledTerminal control owner
      pure ()

  describe "on every way an instance ends" $ do
    it "releases what a failed init acquired, with no hook after it" $ bounded $ do
      fixture ← newLFix 4
      let base = lfBase fixture
      withBoundary $ \_ runtime → do
        owner ← startLeased fixture runtime "failed init" [failInit] leaseConfig requiredPolicy
        _ ← admit base owner "a" (moduleNamed "failinit")
        settled ← awaitSettled base "a"
        resultPhase settled `shouldBe` Failed
        entries ← history fixture
        releases entries `shouldBe` ["release init-fail-res.b", "release init-fail-res.a"]
        entries `shouldSatisfy` notElem "shutdown"
        terminationShutdown (resultTermination settled) `shouldBe` ShutdownSkippedNoInit
        resultLeases settled `shouldBe` LeaseOutcome 1 0 0

    it "releases after the shutdown hook of an instance that is stopped, and of one whose module defines none" $ bounded $ do
      fixture ← newLFix 4
      let base = lfBase fixture
      withBoundary $ \_ runtime → do
        owner ← startLeased fixture runtime "stopped" [plain, noShutdown] leaseConfig requiredPolicy
        _ ← admit base owner "p" (moduleNamed "plain")
        _ ← admit base owner "n" (moduleNamed "noshutdown")
        awaitPhase base owner "p" Active
        awaitPhase base owner "n" Active
        stop fixture owner "p"
        stop fixture owner "n"
        p ← awaitSettled base "p"
        n ← awaitSettled base "n"
        entries ← history fixture
        position entries "release plain-res.b" `shouldSatisfy` (> position entries "shutdown 1 stopped")
        terminationShutdown (resultTermination n) `shouldBe` ShutdownAbsent
        releases entries `shouldSatisfy` elem "release no-shutdown-res.a"
        map (leasesDrained . resultLeases) [p, n] `shouldBe` [1, 1]

    it "releases what a faulted invocation held, after its shutdown" $ bounded $ do
      fixture ← newLFix 4
      let base = lfBase fixture
      withBoundary $ \_ runtime → do
        owner ← startLeased fixture runtime "faulted" [faultingHolder] leaseConfig requiredPolicy
        _ ← admit base owner "a" (moduleNamed "faultingholder")
        awaitPhase base owner "a" Active
        expectDelivered base owner "a" 1
        settled ← awaitSettled base "a"
        resultPhase settled `shouldBe` Failed
        entries ← history fixture
        position entries "release fault-res.b" `shouldSatisfy` (> position entries "shutdown 1 failed")

    it "releases what an instance whose shutdown raises held, and keeps the hook's error as the failure" $ bounded $ do
      fixture ← newLFix 4
      let base = lfBase fixture
      withBoundary $ \_ runtime → do
        owner ← startLeased fixture runtime "bad shutdown" [badShutdownHolder] leaseConfig requiredPolicy
        _ ← admit base owner "a" (moduleNamed "badshutdownholder")
        awaitPhase base owner "a" Active
        stop fixture owner "a"
        settled ← awaitSettled base "a"
        resultPhase settled `shouldBe` Failed
        fmap failureStage (failureOf' settled) `shouldBe` Just StageShutdown
        entries ← history fixture
        position entries "release bad-shutdown-res.b" `shouldSatisfy` (> position entries "shutdown 1")

    it "releases what a one-shot held when it completed, after its shutdown" $ bounded $ do
      fixture ← newLFix 4
      let base = lfBase fixture
      withBoundary $ \control runtime → do
        owner ← startLeased fixture runtime "one-shot" [oneShotHolder] leaseConfig requiredPolicy
        _ ← admitWith base owner "a" (InstanceRequest (moduleNamed "oneshotholder") RunOnce (Just "a") OrdinaryClass ["tick"])
        liveFor fixture "a" 1
        awaitDiagnosticsWaiting owner
        grantOne control owner
        settled ← awaitSettled base "a"
        resultOutcome settled `shouldSatisfy` \case InstanceCompleted → True; _ → False
        entries ← history fixture
        position entries "release one-shot-res.b" `shouldSatisfy` (> position entries "shutdown 1 completed")

    it "releases what an instance held when the owner retires, after the hook" $ bounded $ do
      fixture ← newLFix 4
      let base = lfBase fixture
      withBoundary $ \control runtime → do
        owner ← startLeased fixture runtime "retired owner" [plain] leaseConfig requiredPolicy
        _ ← admit base owner "p" (moduleNamed "plain")
        awaitPhase base owner "p" Active
        retireScheduled owner
        awaitScheduledTerminal control owner >>= (`shouldSatisfy` isStopped)
        entries ← history fixture
        position entries "release plain-res.b" `shouldSatisfy` (> position entries "shutdown 1 stopped")
        summaryOf fixture "p" >>= (`shouldBe` ScopeSummary 0 0 0 0 4 0)

    it "releases what an instance held when the owner is cancelled, though no hook may run" $ bounded $ do
      fixture ← newLFix 4
      let base = lfBase fixture
      withBoundary $ \_ runtime → do
        owner ← startLeased fixture runtime "cancelled owner" [plain, holder] leaseConfig requiredPolicy
        _ ← admit base owner "p" (moduleNamed "plain")
        awaitPhase base owner "p" Active
        -- The cancellation is queued while the owner is inside a segment, so it lands
        -- when the segment returns and not as an orderly stop.
        holdOwner base owner
        cancelQueued owner
        releaseOwner base
        settled ← awaitSettled base "p"
        resultOutcome settled `shouldSatisfy` \case InstanceDiscarded (Discard ExitCancelled _) → True; _ → False
        terminationShutdown (resultTermination settled) `shouldBe` ShutdownSkippedUnsafe
        entries ← history fixture
        entries `shouldSatisfy` notElem "shutdown 1 stopped"
        releases entries `shouldBe` ["release plain-res.b", "release plain-res.a"]

    it "releases what an instance held when the closing of its callback fails, which is fatal on its own" $ bounded $ do
      fixture ← newLFix 4
      let base = lfBase fixture
      ExceptionWithContext _ _ ← expectFatal $ \control runtime → do
        owner ← startLeased fixture runtime "closing failure" [closingHolder] leaseConfig requiredPolicy
        _ ← admit base owner "a" (moduleNamed "closingholder")
        awaitPhase base owner "a" Active
        expectDelivered base owner "a" 1
        awaitDiagnosticsWaiting owner
        _ ← askControl base owner "a" InstanceStop
        awaitScheduledTerminal control owner
      releases <$> history fixture >>= (`shouldBe` ["release closing-held.b", "release closing-held.a"])
