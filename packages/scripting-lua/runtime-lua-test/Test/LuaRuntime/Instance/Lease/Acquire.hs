-- | Acquiring through an instance's scope: from every hook, with the handle lost or
-- never stored, through a constructor that fails, within the instance's capacity, and
-- for a resource that belongs to someone else.
--
-- None of the modules these examples run does any cleanup of its own. That is the
-- claim: what an instance acquired is released by the engine however the instance
-- behaved.
module Test.LuaRuntime.Instance.Lease.Acquire (spec) where

import Control.Monad (forM_)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (cleanupFailureLabel, cleanupFailuresInContext)
import Hetoimasia.Runtime.Supervision (WorkerStatus (WorkerUnavailable))
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease
import Hetoimasia.Scripting.Lua.Owner (BoundaryFault (boundaryReason), FaultReason (BindingRefused, ValueRefused))
import Hetoimasia.Scripting.Lua.Runtime (CallFault (BoundaryFailed))
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (ValueRefusal (refusalRule), ValueRule (RuleRetiredHandle))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Lease.Support
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (awaitEffect, awaitScheduledTerminal)
import Test.LuaRuntime.Support (bounded, brokenIs, expectFatal, failExample, optionalPolicy, requiredPolicy, withBoundary)
import Control.Concurrent.STM (atomically)
import Control.Exception (ExceptionWithContext (ExceptionWithContext))

-- | The failure an instance settled as, which an example expects it did.
expectFailure ∷ InstanceSettlement → IO InstanceFailure
expectFailure settled = case failureOf' settled of
  Just failure → pure failure
  Nothing → failExample ("expected a failure, found " <> show (resultOutcome settled))

-- | The reason a call was refused, when the failure is a refusal of a call.
refusedWith ∷ InstanceError → Maybe FaultReason
refusedWith = \case
  ErrorFault (BoundaryFailed fault) → Just (boundaryReason fault)
  _ → Nothing

isBindingRefused ∷ InstanceError → Bool
isBindingRefused failure = case refusedWith failure of
  Just (BindingRefused _) → True
  _ → False

isRetiredHandle ∷ InstanceError → Bool
isRetiredHandle failure = case refusedWith failure of
  Just (ValueRefused refusal) → case refusalRule refusal of
    RuleRetiredHandle _ → True
    _ → False
  _ → False

-- | The releases in a history, in the order they ran.
releases ∷ [Text.Text] → [Text.Text]
releases = filter (Text.isPrefixOf "release ")

stop ∷ LFix → ScheduledOwner → Text.Text → IO ()
stop fixture owner name = settleControl (lfBase fixture) owner name InstanceStop >>= (`shouldBe` ControlApplied)

spec ∷ Spec
spec = describe "acquiring" $ do
  it "acquires in init, in a callback and in shutdown, keeps every handle usable in shutdown, and releases them after the hook, newest first and each in its declared order" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    withBoundary $ \_ runtime → do
      owner ← startLeased fixture runtime "every hook" [holdsAtEveryHook] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "holdsateveryhook")
      awaitPhase base owner "a" Active
      liveFor fixture "a" 1
      expectDelivered base owner "a" 1
      liveFor fixture "a" 2
      stop fixture owner "a"
      settled ← awaitSettled base "a"
      resultOutcome settled `shouldSatisfy` \case InstanceStopped → True; _ → False
      entries ← history fixture
      -- The handle from init was usable inside the hook that ran after the callback's.
      entries `shouldSatisfy` elem "use init-res"
      -- Then everything, newest acquisition first, and each in its assembly's order.
      releases entries
        `shouldBe` [ "release shutdown-res.b"
                   , "release shutdown-res.a"
                   , "release callback-res.b"
                   , "release callback-res.a"
                   , "release init-res.b"
                   , "release init-res.a"
                   ]
      position entries "release shutdown-res.b" `shouldSatisfy` (> position entries "shutdown 1 stopped")
      position entries "release shutdown-res.b" `shouldSatisfy` (> position entries "acquire shutdown-res.a")
      resultLeases settled `shouldBe` LeaseOutcome 3 0 0
      summaryOf fixture "a" >>= (`shouldBe` ScopeSummary 0 0 0 0 4 0)

  it "releases what an invocation acquired when it raised before it stored the handle" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    withBoundary $ \_ runtime → do
      owner ← startLeased fixture runtime "raised" [acquiresThenRaises] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "acquiresthenraises")
      awaitPhase base owner "a" Active
      expectDelivered base owner "a" 1
      settled ← awaitSettled base "a"
      resultPhase settled `shouldBe` Failed
      entries ← history fixture
      releases entries `shouldBe` ["release raised-res.b", "release raised-res.a"]
      -- After the hook, which saw a handle it never had.
      position entries "release raised-res.b" `shouldSatisfy` (> position entries "shutdown 1 failed")
      summaryOf fixture "a" >>= (`shouldBe` ScopeSummary 0 0 0 0 4 0)

  it "releases every handle a script overwrote or never stored, with no collection of its own" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    withBoundary $ \_ runtime → do
      owner ← startLeased fixture runtime "overwritten" [overwrites, losesTheHandle] leaseConfig requiredPolicy
      _ ← admit base owner "over" (moduleNamed "overwrites")
      _ ← admit base owner "lost" (moduleNamed "losesthehandle")
      -- Nothing is released while the instances live, however the scripts treat the handles.
      awaitPhase base owner "over" Active
      awaitPhase base owner "lost" Active
      liveFor fixture "over" 3
      liveFor fixture "lost" 2
      releases <$> history fixture >>= (`shouldBe` [])
      stop fixture owner "over"
      stop fixture owner "lost"
      _ ← awaitSettled base "over"
      _ ← awaitSettled base "lost"
      entries ← releases <$> history fixture
      -- Each instance's holdings, newest first; the instances are told apart by what they hold.
      filter (Text.isInfixOf "third") entries `shouldBe` ["release third.b", "release third.a"]
      let at name = position entries ("release " <> name <> ".a")
      (at "third" < at "second", at "second" < at "first") `shouldBe` (True, True)
      (at "lost-two" < at "lost-one") `shouldBe` True

  it "rolls back a constructor that fails at its second stage, registers nothing and gives Lua no handle, and the constructor's exception stays the host's" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    ExceptionWithContext _ raised ← expectFatal $ \control runtime → do
      owner ← startLeased fixture runtime "constructor" [failingConstructor] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "failingconstructor")
      awaitPhase base owner "a" Active
      expectDelivered base owner "a" 1
      awaitScheduledTerminal control owner
    raised `shouldSatisfy` brokenIs "constructor"
    entries ← history fixture
    -- The first stage completed and was rolled back; no handle was made.
    filter (Text.isInfixOf "doomed") entries
      `shouldBe` ["acquire doomed.first", "construct doomed.second", "release doomed.first"]
    summaryOf fixture "a" >>= \summary → (summaryCharged summary, summaryLive summary) `shouldBe` (0, 0)

  it "ends an optional owner that recognizes every exception as unavailable, not fatal, when only the constructor fails" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    withBoundary $ \control runtime → do
      owner ← startLeased fixture runtime "optional constructor" [failingConstructor] leaseConfig (optionalPolicy (const True))
      _ ← admit base owner "a" (moduleNamed "failingconstructor")
      awaitPhase base owner "a" Active
      expectDelivered base owner "a" 1
      awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerUnavailable _ → True; _ → False)

  it "keeps a failed rollback release as cleanup evidence beside the constructor's failure, fatal for required and optional owners alike" $ bounded $ do
    forM_ [("required", requiredPolicy), ("optional", optionalPolicy (const True))] $ \(label, policy) → do
      fixture ← newLFix 4
      let base = lfBase fixture
      breakRelease fixture "doomed"
      ExceptionWithContext context raised ← expectFatal $ \control runtime → do
        owner ← startLeased fixture runtime ("rollback " <> label) [failingConstructor] leaseConfig policy
        _ ← admit base owner "a" (moduleNamed "failingconstructor")
        awaitPhase base owner "a" Active
        expectDelivered base owner "a" 1
        awaitScheduledTerminal control owner
      raised `shouldSatisfy` brokenIs "constructor"
      map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` any (Text.isInfixOf "doomed.first")
      summaryOf fixture "a" >>= (`shouldBe` ScopeSummary 0 0 0 0 4 0)
      -- The rollback failure is kept in the instance's outcome as well, beside the
      -- constructor's exception, which stays the owner's failure: the instance is failed at the release.
      settled ← tickOf base "a" >>= pollInstance
      case settled of
        Just result → do
          resultPhase result `shouldBe` Failed
          leasesFailed (resultLeases result) `shouldBe` 1
          case failureOf' result of
            Just failure → do
              failureStage failure `shouldBe` StageRelease
              failureMessage failure `shouldSatisfy` Text.isInfixOf "a rollback release failed: doomed.first"
            Nothing → failExample "expected the instance to have failed at the release"
        Nothing → failExample "expected the instance to have settled"

  it "refuses an acquisition over the instance's capacity as the engine, before any stage runs, and a script that catches the error is still faulted and not made a host failure" $ bounded $ do
    fixture ← newLFix 2
    let base = lfBase fixture
    withBoundary $ \control runtime → do
      owner ← startLeased fixture runtime "capacity" [overCapacity, plain] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "overcapacity")
      _ ← admit base owner "p" (moduleNamed "plain")
      awaitPhase base owner "a" Active
      awaitPhase base owner "p" Active
      expectDelivered base owner "a" 1
      settled ← awaitSettled base "a"
      -- The script saw a Lua error, caught it and went on: the engine's fault is kept.
      entries ← history fixture
      entries `shouldSatisfy` elem "third false"
      entries `shouldSatisfy` elem "caught true"
      entries `shouldSatisfy` elem "continued"
      resultPhase settled `shouldBe` Failed
      failure ← expectFailure settled
      failureError failure `shouldSatisfy` isBindingRefused
      failureMessage failure `shouldSatisfy` Text.isInfixOf "capacity"
      -- No stage of the refused acquisition ran, and nothing of it was charged.
      entries `shouldSatisfy` notElem "acquire three.a"
      entries `shouldSatisfy` notElem "acquire three.b"
      -- It is no failure of the host: the owner is live and its other instance goes on.
      expectDelivered base owner "p" 1
      awaitEffect (sf base) "shutdown 1"
      atomically (scheduledStatus owner) >>= (`shouldSatisfy` isLive)
      retireScheduled owner
      _ ← awaitScheduledTerminal control owner
      pure ()

  it "refuses an acquisition made from a thread the callback started, with nothing charged" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    withBoundary $ \_ runtime → do
      owner ← startLeased fixture runtime "thread" [threadedAcquire] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "threadedacquire")
      awaitPhase base owner "a" Active
      expectDelivered base owner "a" 1
      awaitEffect (sf base) "thread refused"
      entries ← history fixture
      entries `shouldSatisfy` notElem "acquire from-thread.a"
      summaryOf fixture "a" >>= (`shouldBe` ScopeSummary 0 0 0 0 4 0)

  it "leaves a lease discoverable when the result of the call that acquired it cannot be published" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    withBoundary $ \_ runtime → do
      owner ← startLeased fixture runtime "unpublished" [unpublishable] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "unpublishable")
      awaitPhase base owner "a" Active
      expectDelivered base owner "a" 1
      settled ← awaitSettled base "a"
      resultPhase settled `shouldBe` Failed
      failure ← expectFailure settled
      failureError failure `shouldSatisfy` \case
        ErrorFault (BoundaryFailed fault) → case boundaryReason fault of
          ValueRefused _ → True
          _ → False
        _ → False
      -- Acquired, never given to Lua, and released by the end.
      entries ← history fixture
      entries `shouldSatisfy` elem "acquire unseen.a"
      releases entries `shouldBe` ["release unseen.b", "release unseen.a"]
      resultLeases settled `shouldBe` LeaseOutcome 1 0 0

  it "leaves a shared asset with its owner and with another instance's lease when one instance ends" $ bounded $ do
    fixture ← newLFix 4
    let base = lfBase fixture
    withBoundary $ \control runtime → do
      owner ← startLeased fixture runtime "shared" [sharedAsset] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "sharedasset")
      _ ← admit base owner "b" (moduleNamed "sharedasset")
      awaitPhase base owner "a" Active
      awaitPhase base owner "b" Active
      liveFor fixture "a" 1
      liveFor fixture "b" 1
      assetHolders fixture "shared-asset" >>= (`shouldBe` 2)
      stop fixture owner "a"
      _ ← awaitSettled base "a"
      -- A dropped its interest and nothing else: the asset has one holder, and it is usable.
      assetHolders fixture "shared-asset" >>= (`shouldBe` 1)
      expectDelivered base owner "b" 1
      awaitEffect (sf base) "uses 2 asset shared-asset"
      retireScheduled owner
      _ ← awaitScheduledTerminal control owner
      assetHolders fixture "shared-asset" >>= (`shouldBe` 0)
      entries ← history fixture
      -- Only interests were taken and dropped: the asset itself was never destroyed.
      filter (Text.isInfixOf "shared-asset") entries
        `shouldBe` ["take shared-asset", "take shared-asset", "drop shared-asset", "use asset shared-asset", "uses 2 asset shared-asset", "drop shared-asset"]

  it "does not extend a handle's lifetime when a script caches it where another instance can reach it: it stays retired, even where its capacity is used again" $ bounded $ do
    fixture ← newLFix 1
    let base = lfBase fixture
    withBoundary $ \control runtime → do
      owner ← startLeased fixture runtime "cached" [cachesHandle] leaseConfig requiredPolicy
      _ ← admit base owner "a" (moduleNamed "cacheshandle")
      awaitEffect (sf base) "cached by 1"
      -- Another instance, while the first lives, is refused: the handle is the first's.
      _ ← admit base owner "b" (moduleNamed "cacheshandle")
      awaitPhase base owner "b" Active
      expectDelivered base owner "b" 1
      b ← awaitSettled base "b"
      resultPhase b `shouldBe` Failed
      expectFailure b >>= \failure → failureError failure `shouldSatisfy` isBindingRefused
      -- Once the first has ended its handle is retired, and a third instance's own
      -- lease, which took the capacity the first gave back, is usable.
      stop fixture owner "a"
      _ ← awaitSettled base "a"
      _ ← admit base owner "c" (moduleNamed "cacheshandle")
      awaitPhase base owner "c" Active
      expectDelivered base owner "c" 1
      c ← awaitSettled base "c"
      expectFailure c >>= \failure → failureError failure `shouldSatisfy` isRetiredHandle
      entries ← history fixture
      entries `shouldSatisfy` elem "mine asset cache-asset"
      entries `shouldSatisfy` elem "cached usable false"
      -- The same borrow handed back as data: its own resource is lent, another instance's is refused in the
      -- same words as the fault, and the instance that asked is not faulted by asking.
      entries `shouldSatisfy` elem "mine try ok asset cache-asset"
      entries `shouldSatisfy` elem "cached try refused: the lease belongs to another instance"
      retireScheduled owner
      _ ← awaitScheduledTerminal control owner
      pure ()
