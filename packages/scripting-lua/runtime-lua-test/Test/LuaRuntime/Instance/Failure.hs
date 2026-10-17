-- | What happens when an instance's code fails, or the code that ends it does:
-- a failed @init@, a hook that cannot suspend and does, a callback that raises, a
-- @shutdown@ that raises, and what the application decides about each.
module Test.LuaRuntime.Instance.Failure (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), fromException)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (cleanupFailureLabel, cleanupFailuresInContext)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Owner (BoundaryFault (boundaryReason), FaultReason (SuspendRefused))
import Hetoimasia.Scripting.Lua.Runtime (CallFault (BoundaryFailed), Discard (Discard), ExitKind (ExitFailed), Progress (Started))
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Runtime.Supervision (WorkerStatus (WorkerUnavailable))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (awaitEffect, awaitScheduledTerminal)
import Test.LuaRuntime.Support (bounded, brokenIs, expectFatal, optionalPolicy, requiredPolicy, withBoundary)

-- | The failure an instance settled as, which an example expects it did.
expectFailure ∷ InstanceSettlement → IO InstanceFailure
expectFailure settled = case failureOf' settled of
  Just failure → pure failure
  Nothing → fail ("expected a failure, found " <> show (resultOutcome settled))

isSuspendRefused ∷ InstanceError → Bool
isSuspendRefused = \case
  ErrorFault (BoundaryFailed fault) → case boundaryReason fault of
    SuspendRefused _ → True
    _ → False
  _ → False

spec ∷ Spec
spec = describe "failure" $ do
  it "fails only an instance whose init failed: no later hook runs, its connections are revoked, and the failure names it" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "init failure" [badInit, echoer] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "badinit")
      _ ← admit fixture owner "b" (moduleNamed "echoer")
      settled ← awaitSettled fixture "a"
      identity ← idOf fixture "a"
      resultPhase settled `shouldBe` Failed
      failure ← expectFailure settled
      failureInstance failure `shouldBe` identity
      failureOwner failure `shouldBe` "init failure"
      failureName failure `shouldBe` Just "a"
      failureSource failure `shouldBe` moduleNamed "badinit"
      failurePhase failure `shouldBe` Initializing
      failureStage failure `shouldBe` StageInit
      failureMessage failure `shouldSatisfy` Text.isInfixOf "init boom"
      failureTraceback failure `shouldSatisfy` isJust
      -- Nothing else ever ran on it, and what it had connected is revoked.
      awaitPhase fixture owner "b" Active
      logged fixture >>= (`shouldBe` ["init", "init 1"])
      let termination = resultTermination settled
      terminationConnections termination `shouldBe` 1
      terminationShutdown termination `shouldBe` ShutdownSkippedNoInit
      deliverTick fixture owner "a" 1 >>= (`shouldBe` DeliveryUnknownTarget)
      -- Its peer is untouched.
      expectDelivered fixture owner "b" 1
      awaitEffect (sf fixture) "tick 1 n=1 seq=0 t=0 count=1"

  it "reports a wait or a yield inside init as a fault of that hook" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "yield init" [yieldInit] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "yieldinit")
      failure ← awaitSettled fixture "a" >>= expectFailure
      failureStage failure `shouldBe` StageInit
      failureError failure `shouldSatisfy` isSuspendRefused
      logged fixture >>= (`shouldBe` [])

  it "reports a wait inside shutdown as a fault of that hook, keeps it, and still cleans up" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "yield shutdown" [yieldShutdown, echoer] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "yieldshutdown")
      _ ← admit fixture owner "b" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      settleControl fixture owner "a" InstanceStop >>= (`shouldBe` ControlApplied)
      settled ← awaitSettled fixture "a"
      resultPhase settled `shouldBe` Failed
      failure ← expectFailure settled
      failureStage failure `shouldBe` StageShutdown
      failureError failure `shouldSatisfy` isSuspendRefused
      let termination = resultTermination settled
      terminationShutdown termination `shouldBe` ShutdownRaised
      terminationConnections termination `shouldBe` 1
      -- Not retried, and the owner and its other instance go on.
      logCount fixture "shutdown stopped" >>= (`shouldBe` 1)
      awaitPhase fixture owner "b" Active
      expectDelivered fixture owner "b" 1
      awaitEffect (sf fixture) "tick 1 n=1 seq=0 t=0 count=1"

  it "fails an instance whose callback raised, suppresses its remaining work, runs its shutdown, and leaves its peer running" $ bounded $ do
    fixture ← newIFixture
    told ← newIORef []
    let config = (testConfig instanceBounds') {instanceEscalate = \failure → atomicModifyIORef' told (\held → (failure : held, Isolate))}
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "callback failure" [failCallback, echoer] config requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "failcallback")
      _ ← admit fixture owner "b" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      awaitPhase fixture owner "b" Active
      expectDelivered fixture owner "a" 1
      settled ← awaitSettled fixture "a"
      failure ← expectFailure settled
      failureStage failure `shouldBe` StageEvent "tick"
      failurePhase failure `shouldBe` Active
      failureMessage failure `shouldSatisfy` Text.isInfixOf "callback boom"
      terminationShutdown (resultTermination settled) `shouldBe` ShutdownRan
      logged fixture >>= (`shouldSatisfy` elem "shutdown 1 failed")
      -- The application is told once, after the instance ended.
      identity ← idOf fixture "a"
      readIORef told >>= (`shouldSatisfy` \held → map failureInstance held == [identity])
      awaitEffect (sf fixture) "init 2"
      expectDelivered fixture owner "b" 1
      awaitEffect (sf fixture) "tick 2 n=1 seq=0 t=0 count=1"

  it "fails an instance whose callback asked for a wait the scheduler refused, runs its shutdown, and leaves its peer running" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "refused wait" [badWait, echoer] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "badwait")
      _ ← admit fixture owner "b" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      awaitPhase fixture owner "b" Active
      expectDelivered fixture owner "a" 1
      settled ← awaitSettled fixture "a"
      resultPhase settled `shouldBe` Failed
      failure ← expectFailure settled
      failureStage failure `shouldBe` StageEvent "tick"
      failureError failure `shouldSatisfy` \case ErrorRefusedWait _ → True; _ → False
      logged fixture >>= (`shouldSatisfy` elem "shutdown 1 failed")
      expectDelivered fixture owner "b" 1
      awaitEffect (sf fixture) "tick 2 n=1 seq=0 t=0 count=1"

  it "keeps an instance's primary failure primary when its shutdown fails as well" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "both" [failBoth] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "failboth")
      awaitPhase fixture owner "a" Active
      expectDelivered fixture owner "a" 1
      settled ← awaitSettled fixture "a"
      failure ← expectFailure settled
      failureStage failure `shouldBe` StageEvent "tick"
      failureMessage failure `shouldSatisfy` Text.isInfixOf "callback boom"
      map fst (failureSecondary failure) `shouldBe` [StageShutdown]
      terminationShutdown (resultTermination settled) `shouldBe` ShutdownRaised

  it "keeps a failing shutdown, never retries it, and still releases what the instance held" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "bad shutdown" [badShutdown, echoer] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "badshutdown")
      _ ← admit fixture owner "b" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      awaitPhase fixture owner "b" Active
      settleControl fixture owner "a" InstanceStop >>= (`shouldBe` ControlApplied)
      settled ← awaitSettled fixture "a"
      resultPhase settled `shouldBe` Failed
      failure ← expectFailure settled
      failureStage failure `shouldBe` StageShutdown
      failureMessage failure `shouldSatisfy` Text.isInfixOf "shutdown boom"
      logCount fixture "shutdown stopped" >>= (`shouldBe` 1)
      terminationConnections (resultTermination settled) `shouldBe` 1
      -- A second stop is refused as stale, and nothing runs again.
      askControl fixture owner "a" InstanceStop >>= (`shouldSatisfy` \case InstanceControlUnknown → True; _ → False)
      logCount fixture "shutdown stopped" >>= (`shouldBe` 1)
      expectDelivered fixture owner "b" 1
      awaitEffect (sf fixture) "tick 2 n=1 seq=0 t=0 count=1"

  it "reaches the application's escalation for a failure that may have damaged shared state, and fails the owner under supervision" $ bounded $ do
    fixture ← newIFixture
    let config = (testConfig instanceBounds') {instanceEscalate = \_ → pure Escalate}
    ExceptionWithContext _ raised ← expectFatal $ \control runtime → do
      owner ← startInstances fixture runtime "escalated" [failCallback, echoer] config requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "failcallback")
      _ ← admit fixture owner "b" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      awaitPhase fixture owner "b" Active
      expectDelivered fixture owner "a" 1
      awaitScheduledTerminal control owner
    case fromException raised of
      Just (InstanceEscalated failure) → do
        failureOwner failure `shouldBe` "escalated"
        failureStage failure `shouldBe` StageEvent "tick"
      Nothing → fail ("expected the escalation, found " <> show raised)
    -- The instance that failed had ended before the owner did, as its failure; the
    -- one that was running was discarded with its owner.
    a ← tickOf fixture "a" >>= pollInstance
    fmap (resultPhase) a `shouldBe` Just Failed
    b ← tickOf fixture "b" >>= pollInstance
    fmap resultOutcome b `shouldSatisfy` \case
      Just (InstanceDiscarded (Discard ExitFailed Started)) → True
      _ → False

  it "ends the owner, not the instance, for a failure of the host, and runs no hook for the instances it discards" $ bounded $ do
    fixture ← newIFixture
    ExceptionWithContext _ raised ← expectFatal $ \control runtime → do
      owner ← startInstances fixture runtime "host failure" [hostFailing, echoer] (testConfig instanceBounds') requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "hostfailing")
      _ ← admit fixture owner "b" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      awaitPhase fixture owner "b" Active
      expectDelivered fixture owner "a" 1
      awaitScheduledTerminal control owner
    raised `shouldSatisfy` brokenIs "boom"
    b ← tickOf fixture "b" >>= pollInstance
    fmap resultOutcome b `shouldSatisfy` \case
      Just (InstanceDiscarded (Discard ExitFailed Started)) → True
      _ → False
    fmap (terminationShutdown . resultTermination) b `shouldBe` Just ShutdownSkippedUnsafe
    logged fixture >>= (`shouldBe` ["init 1"])

  it "raises the application's escalation of a failure met while a stop closes a coroutine as the owner's own failure, which its policy decides" $ bounded $ do
    fixture ← newIFixture
    let config = (testConfig instanceBounds') {instanceEscalate = \_ → pure Escalate}
        recognizes failure = isJust (fromException failure ∷ Maybe InstanceEscalated)
    withBoundary $ \control runtime → do
      owner ← startInstances fixture runtime "escalated stop" [waitBadShutdown] config (optionalPolicy recognizes)
      _ ← admit fixture owner "a" (moduleNamed "waitbadshutdown")
      awaitPhase fixture owner "a" Active
      expectDelivered fixture owner "a" 1
      awaitDiagnosticsWaiting owner
      _ ← settleControl fixture owner "a" InstanceStop
      -- The owner is unavailable as an optional owner whose policy recognizes the
      -- escalation: it was not mistaken for a failure of the close, which is fatal.
      awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerUnavailable _ → True; _ → False)
      settled ← awaitSettled fixture "a"
      resultPhase settled `shouldBe` Failed
      fmap failureStage (failureOf' settled) `shouldBe` Just StageShutdown

  it "keeps the failure of closing a coroutine as cleanup evidence for supervision, whatever the application's escalation answers" $ bounded $ do
    fixture ← newIFixture
    ExceptionWithContext context _ ← expectFatal $ \control runtime → do
      owner ← startInstances fixture runtime "closer" [badClose] (testConfig instanceBounds') (optionalPolicy (const True))
      _ ← admit fixture owner "a" (moduleNamed "badclose")
      awaitPhase fixture owner "a" Active
      expectDelivered fixture owner "a" 1
      awaitDiagnosticsWaiting owner
      _ ← settleControl fixture owner "a" InstanceStop
      awaitScheduledTerminal control owner
    map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` elem "lua task close"

  it "keeps the failure of closing a failed callback's coroutine beside the instance's primary failure, and supervision receives both" $ bounded $ do
    fixture ← newIFixture
    ExceptionWithContext context _ ← expectFatal $ \control runtime → do
      owner ← startInstances fixture runtime "close beside" [failClose] (testConfig instanceBounds') (optionalPolicy (const True))
      _ ← admit fixture owner "a" (moduleNamed "failclose")
      awaitPhase fixture owner "a" Active
      expectDelivered fixture owner "a" 1
      awaitScheduledTerminal control owner
    -- The closing handler's failure is the owner's cleanup evidence, fatal for an
    -- owner that recognizes everything, and the application's escalation (which
    -- isolated the failure) could not hide it.
    map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` (not . null)
    -- The script's own error stays the primary failure of the instance that raised it.
    settled ← tickOf fixture "a" >>= pollInstance
    case settled >>= failureOf' of
      Just failure → do
        failureStage failure `shouldBe` StageEvent "tick"
        failureMessage failure `shouldSatisfy` Text.isInfixOf "callback boom"
      Nothing → fail "expected the instance to have failed with the script's own error"
