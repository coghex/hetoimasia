-- | One failure, reported once: by the exit or by the supervision sentinel,
-- never again as the exit's retained cleanup.
module Test.GLFW.Owner.Failure.Reporting (spec) where

import Control.Concurrent.STM
  ( atomically
  , check
  , modifyTVar'
  , newTVarIO
  , readTVarIO
  , writeTVar
  )
import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , fromException
  , throwIO
  )
import Control.Monad (forM_, void, when)
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Resource (cleanupFailureException, cleanupFailures)
import qualified Hetoimasia.Foundation.Worker as Worker
import Hetoimasia.GLFW.Internal.Seam (Reporter, reportError)
import Hetoimasia.GLFW.Session (NativeError (..), NativeFailure (..), Reports (..))
import Hetoimasia.Runtime.GLFW
import Hetoimasia.Runtime.Supervision
  ( SupervisedStart (..)
  , cancelSupervised
  , checkRuntime
  , supervisedWorker
  )
import Test.GLFW.Owner.Fixture.Drive
  ( awaitStanding
  , describeStart
  , handedOver
  , pumpUntilRetired
  , raisedBy
  , theWindow
  )
import Test.GLFW.Owner.Fixture.Fake (Fake (..), script)
import Test.GLFW.Owner.Fixture.Journal (Scripted (..))
import Test.GLFW.Owner.Fixture.Rig (Rig (..), newRig, ownedHostCaught)
import Test.GLFW.Support (boundedExample, unexpected)
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = do
  it "reports a failure it retained while it ran exactly once, not once again as cleanup"
    (boundedExample testRetainedFailureReportedOnce)
  it "reports one that escaped its run exactly once as well"
    (boundedExample testEscapingRunFailureReportedOnce)
  it "reports a supervised owner failure once, though the sentinel raised it at a checkpoint"
    (boundedExample testSupervisedFailureReportedOnce)
  it "reports a supervised failure it survived once as well"
    (boundedExample testSupervisedRetainedFailureReportedOnce)
  it "suppresses nothing for a sentinel that was cancelled before it delivered"
    (boundedExample testUndeliveredSentinelSuppressesNothing)
  describe "when the owner's final wake raises" $ do
    forM_ [(False, "without supervision"), (True, "under supervision")] $ \(supervised, how) → do
      it ("keeps the body's failure primary and retains the retirement and an unexpected wake failure, " <> how)
        (boundedExample (testFinalWake supervised (failedRun unexpectedWake)))
      it ("keeps them when the seam's own wake raises an exception of its own, " <> how)
        (boundedExample (testFinalWake supervised (failedRun raisingWake)))
      it ("makes a drain failure primary after a successful body and retains the wake's, " <> how)
        (boundedExample (testFinalWake supervised (succeededRun True unexpectedWake)))
      it ("reports the wake's failure itself when it is the only one, " <> how)
        (boundedExample (testFinalWake supervised (succeededRun False raisingWake)))
      it ("changes nothing when the final wake is healthy, " <> how)
        (boundedExample (testFinalWake supervised (failedRun healthyWake)))
      it ("changes nothing when the final wake degrades with the expected platform error, " <> how)
        (boundedExample (testFinalWake supervised (failedRun degradedWake)))

-- | A failure the owner retained while it kept running is reported exactly
-- once, not once as the exit's own primary and again as its retained cleanup.
--
-- The latch and the retained store hold the same first failure by design —
-- one is notification, what a supervision sentinel waits on, and the other is
-- evidence with its own context — so an exit that raised both would report a
-- single failed operation twice and invent a second one that never happened.
--
-- The application's own action fails as well, so the boundary keeps that
-- failure primary and retains everything the exit found beside it, which is
-- where inspection can count them.
testRetainedFailureReportedOnce ∷ IO ()
testRetainedFailureReportedOnce = do
  rig ← newRig
  script (fakeRetireTarget (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "retire target")))
  outcome ← ownedHostCaught (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
    window ← theWindow host
    service ← handedOver host owner window
    awaitStanding owner service `shouldReturn` TargetUsable
    _ ← releaseGraphicsTarget host owner service
    -- Latched and retained together, which is the pair this example is about.
    atomically (readOwnerFailure owner >>= check . isJust)
    atomically (readOwnerFailures owner >>= check . not . null)
    -- Nothing offers the failed retirement again, so independent evidence is
    -- what retires the attachment and lets this exit finish at all.
    publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
    acknowledgement ←
      atomically (ownerTargetAcknowledgement owner (graphicsAttachment service))
        >>= maybe (unexpected "the attachment kept no acknowledgement") pure
    forM_ allRetirementFacts $ \fact →
      void (publishCompletion publisher (completionNotice (graphicsAttachment service) acknowledgement fact))
    pumpUntilRetired host control
    throwIO (Scripted (Text.pack "body"))
  caught ← raisedBy outcome
  fromException caught `shouldBe` Just (Scripted (Text.pack "body"))
  -- Once over the primary and every cleanup failure retained beside it.
  occurrencesOf (Scripted (Text.pack "retire target")) caught `shouldBe` 1

-- | A failure that escaped the owner's own run is reported exactly once too.
--
-- This one is latched /and/ carried out by the worker's own outcome, so it is
-- the other way a single failure could be told twice.
testEscapingRunFailureReportedOnce ∷ IO ()
testEscapingRunFailureReportedOnce = do
  rig ← newRig
  script (fakeStep (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "step")))
  outcome ← ownedHostCaught (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_host owner _control → do
    atomically (readOwnerTerminalNow owner >>= check . ownerRunEnded)
    throwIO (Scripted (Text.pack "body"))
  caught ← raisedBy outcome
  fromException caught `shouldBe` Just (Scripted (Text.pack "body"))
  occurrencesOf (Scripted (Text.pack "step")) caught `shouldBe` 1

-- | The production composition reports a supervised owner failure exactly
-- once: the sentinel raises it at the application's checkpoint, and the exit
-- does not raise it again.
--
-- This is the shape a real application has, and the one the two examples
-- above cannot reach: without 'superviseGraphicsOwner' the exit is the only
-- reporter and nothing can duplicate. With it, the latched failure has a
-- designated reporter, and everything the exit still owes — each distinct
-- failure the drain found — has to survive that.
testSupervisedFailureReportedOnce ∷ IO ()
testSupervisedFailureReportedOnce = do
  rig ← newRig
  failing ← newTVarIO False
  -- The step fails only once the example says so, so the sentinel is
  -- certainly registered before the failure it must deliver exists.
  script (fakeStep (rigFake rig)) $ \_ →
    readTVarIO failing >>= \doomed →
      if doomed then throwIO (Scripted (Text.pack "fatal step")) else pure noStepWork
  -- A distinct failure in the drain, which the worker's outcome retains
  -- beside the run's own. It must still be reported exactly once, which is
  -- what makes this more than "drop the worker's outcome".
  script (fakeRetireOwner (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "retire owner")))
  outcome ← ownedHostCaught (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_host owner control → do
    started ← superviseGraphicsOwner control owner
    case started of
      WorkerStarted _ → pure ()
      other → unexpected ("the sentinel did not start: " <> describeStart other)
    atomically (writeTVar failing True)
    -- Immediate demand wakes the idle owner into the step that fails.
    demand ← prepare (OwnerDemand True Nothing)
    _ ← atomically (publishOwnerDemand (ownerHandoff owner) demand)
    atomically (readOwnerFailure owner >>= check . isJust)
    -- The checkpoint is where the sentinel's failure reaches the application,
    -- and from there it is the composition's primary failure.
    checkRuntime control
  caught ← raisedBy outcome
  fromException caught `shouldBe` Just (Scripted (Text.pack "fatal step"))
  -- Once over the primary and every cleanup failure retained beside it.
  occurrencesOf (Scripted (Text.pack "fatal step")) caught `shouldBe` 1
  -- And the drain's own failure, which nothing else reported, is still there
  -- exactly once: suppressing the duplicate may not swallow a distinct one.
  occurrencesOf (Scripted (Text.pack "retire owner")) caught `shouldBe` 1

-- | A supervised failure the owner /survived/ is reported exactly once too.
--
-- It latches from the retained store rather than from the run's end, which is
-- the other source the exit has to account for.
testSupervisedRetainedFailureReportedOnce ∷ IO ()
testSupervisedRetainedFailureReportedOnce = do
  rig ← newRig
  script (fakeRetireTarget (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "retire target")))
  outcome ← ownedHostCaught (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
    started ← superviseGraphicsOwner control owner
    case started of
      WorkerStarted _ → pure ()
      other → unexpected ("the sentinel did not start: " <> describeStart other)
    window ← theWindow host
    service ← handedOver host owner window
    awaitStanding owner service `shouldReturn` TargetUsable
    _ ← releaseGraphicsTarget host owner service
    atomically (readOwnerFailure owner >>= check . isJust)
    -- Nothing offers the failed retirement again, so independent evidence is
    -- what retires the attachment and lets this exit finish at all.
    publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
    acknowledgement ←
      atomically (ownerTargetAcknowledgement owner (graphicsAttachment service))
        >>= maybe (unexpected "the attachment kept no acknowledgement") pure
    forM_ allRetirementFacts $ \fact →
      void (publishCompletion publisher (completionNotice (graphicsAttachment service) acknowledgement fact))
    pumpUntilRetired host control
    checkRuntime control
  caught ← raisedBy outcome
  fromException caught `shouldBe` Just (Scripted (Text.pack "retire target"))
  occurrencesOf (Scripted (Text.pack "retire target")) caught `shouldBe` 1

-- | A sentinel that never delivered may not make the exit suppress anything.
--
-- The exit leaves out the failure supervision has already reported, so the
-- record that it /was/ reported has to mean it really was. This cancels the
-- sentinel while it is still waiting, before any failure exists for it to
-- take, and then makes one: nothing was delivered, nothing is recorded, and
-- the exit reports the failure in full.
--
-- The remaining window — between the transaction that records the delivery
-- and the raise it promises — is closed by masking rather than by an example,
-- because once masked there is no instant at which it can be observed.
testUndeliveredSentinelSuppressesNothing ∷ IO ()
testUndeliveredSentinelSuppressesNothing = do
  rig ← newRig
  failing ← newTVarIO False
  script (fakeStep (rigFake rig)) $ \_ →
    readTVarIO failing >>= \doomed →
      if doomed then throwIO (Scripted (Text.pack "fatal step")) else pure noStepWork
  outcome ← ownedHostCaught (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_host owner control → do
    started ← superviseGraphicsOwner control owner
    sentinel ← case started of
      WorkerStarted worker → pure worker
      other → unexpected ("the sentinel did not start: " <> describeStart other)
    -- Cancelled while it waits, which is the one part of it that is
    -- interruptible, and before any failure exists for it to take.
    cancelSupervised sentinel
    atomically (Worker.pollCompletion (supervisedWorker sentinel) >>= check . isJust)
    -- Only now does the owner fail, so the sentinel certainly delivered
    -- nothing.
    atomically (writeTVar failing True)
    demand ← prepare (OwnerDemand True Nothing)
    _ ← atomically (publishOwnerDemand (ownerHandoff owner) demand)
    atomically (readOwnerTerminalNow owner >>= check . ownerRunEnded)
  caught ← raisedBy outcome
  -- Reported by the exit, because nothing else reported it, and reported once.
  fromException caught `shouldBe` Just (Scripted (Text.pack "fatal step"))
  occurrencesOf (Scripted (Text.pack "fatal step")) caught `shouldBe` 1

-- | One final-wake case: what the run, the drain and the owner's last wake do,
-- and what the reported failures must then hold.
data FinalWake = FinalWake
  { wakeBodyFails ∷ !Bool
    -- ^ Whether the owner's own run fails, at startup.
  , wakeRetirementFails ∷ !Bool
    -- ^ Whether whole-owner retirement fails in the drain.
  , wakeScript ∷ !(Reporter → IO ())
    -- ^ What the final wake's empty-event post does.
  , wakePrimary ∷ !(SomeException → Bool)
  , wakeCounted ∷ ![(String, SomeException → Bool, Int)]
    -- ^ Each original failure, and how many times it must be reported.
  }

-- | A run that fails at startup and a whole-owner retirement that fails, with
-- destruction succeeding and no target attached, ending in this final wake.
failedRun ∷ (Reporter → IO (), Maybe (String, SomeException → Bool)) → FinalWake
failedRun (wake, wakeFailure) =
  FinalWake
    { wakeBodyFails = True
    , wakeRetirementFails = True
    , wakeScript = wake
    , wakePrimary = is startupFailure
    , wakeCounted =
        [("startup", is startupFailure, 1), ("retire owner", is retirementFailure, 1)]
          <> maybe [] (\(name, matches) → [(name, matches, 1)]) wakeFailure
    }

-- | A run that succeeds, optionally a whole-owner retirement that fails, and
-- this final wake, which fails.
succeededRun ∷ Bool → (Reporter → IO (), Maybe (String, SomeException → Bool)) → FinalWake
succeededRun retirement (wake, wakeFailure) =
  FinalWake
    { wakeBodyFails = False
    , wakeRetirementFails = retirement
    , wakeScript = wake
    , wakePrimary = if retirement then is retirementFailure else maybe (const False) snd wakeFailure
    , wakeCounted =
        [("startup", is startupFailure, 0), ("retire owner", is retirementFailure, if retirement then 1 else 0)]
          <> maybe [] (\(name, matches) → [(name, matches, 1)]) wakeFailure
    }

startupFailure, retirementFailure, seamWakeFailure ∷ Scripted
startupFailure = Scripted (Text.pack "startup")
retirementFailure = Scripted (Text.pack "retire owner")
seamWakeFailure = Scripted (Text.pack "wake")

-- | A wake that posts and reports nothing.
healthyWake ∷ (Reporter → IO (), Maybe (String, SomeException → Bool))
healthyWake = (\_ → pure (), Nothing)

-- | The expected platform failure, which the classifier degrades rather than
-- raises.
degradedWake ∷ (Reporter → IO (), Maybe (String, SomeException → Bool))
degradedWake = (\reporter → reportError reporter 0x00010008 "final wake degraded", Nothing)

-- | An error the classifier does not expect, which it raises as the wake's
-- 'NativeFailure'.
unexpectedWake ∷ (Reporter → IO (), Maybe (String, SomeException → Bool))
unexpectedWake =
  ( \reporter → reportError reporter notInitialized "final wake not initialized"
  , Just ("the wake's NativeFailure", notInitializedWake)
  )
  where
    notInitializedWake caught = case fromException caught of
      Just (NativeFailure _ reports) → any ((== notInitialized) . nativeErrorCode) (reportedErrors reports)
      Nothing → False

-- | GLFW_NOT_INITIALIZED.
notInitialized ∷ Int
notInitialized = 0x00010001

-- | A native operation that raises an exception of its own, which the session
-- propagates as it is.
raisingWake ∷ (Reporter → IO (), Maybe (String, SomeException → Bool))
raisingWake = (\_ → throwIO seamWakeFailure, Just ("the seam's own wake failure", is seamWakeFailure))

is ∷ Scripted → SomeException → Bool
is wanted = (== Just wanted) . fromException

-- | The owner's final wake fails, or is a control, and every original failure
-- is reported exactly as often as the case says — with no sentinel, where the
-- exit reports the worker's outcome, and with one, where the sentinel raises a
-- failure that ended the run and the exit leaves that outcome to the group.
--
-- Only the final wake is scripted: whole-owner destruction, the last operation
-- the drain attempts, arms it, and nothing posts between that and the run
-- action's own last wake.
testFinalWake ∷ Bool → FinalWake → IO ()
testFinalWake supervised expected = do
  rig ← newRig
  when (wakeBodyFails expected) $
    script (fakeStart (rigFake rig)) (\_ → throwIO startupFailure)
  when (wakeRetirementFails expected) $
    script (fakeRetireOwner (rigFake rig)) (\_ → throwIO retirementFailure)
  woke ← newTVarIO (0 ∷ Int)
  script (fakeDestroy (rigFake rig)) $ \_ → do
    atomically . writeTVar (rigWake rig) $ \reporter → do
      atomically (modifyTVar' woke (+ 1))
      wakeScript expected reporter
    pure (ownerDestroyed (Text.pack "destroyed"))
  outcome ← ownedHostCaught (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_host owner control →
    when supervised $ do
      started ← superviseGraphicsOwner control owner
      case started of
        WorkerStarted _ → pure ()
        other → unexpected ("the sentinel did not start: " <> describeStart other)
      when (wakeBodyFails expected) $ do
        -- The startup failure is latched before the application's own startup,
        -- so the sentinel delivers it at this checkpoint, as the composition's
        -- primary failure.
        atomically (readOwnerFailure owner >>= check . isJust)
        checkRuntime control
  caught ← raisedBy outcome
  -- The scripted wake is the run action's final one, and it is attempted once.
  readTVarIO woke `shouldReturn` 1
  caught `shouldSatisfy` wakePrimary expected
  forM_ (wakeCounted expected) $ \(name, matches, times) →
    (name, occurrencesWhere matches caught) `shouldBe` (name, times)

-- | How many times one failure appears in a raised exception: as the
-- exception itself, and in every cleanup failure retained beside it.
occurrencesOf ∷ Scripted → SomeException → Int
occurrencesOf = occurrencesWhere . is

-- | 'occurrencesOf' for any failure this recognizes.
occurrencesWhere ∷ (SomeException → Bool) → SomeException → Int
occurrencesWhere matches caught =
  length (filter matches (caught : retained))
  where
    retained =
      [ exceptionOf (cleanupFailureException failure)
      | failure ← cleanupFailures caught
      ]

exceptionOf ∷ ExceptionWithContext SomeException → SomeException
exceptionOf (ExceptionWithContext _ failure) = failure
