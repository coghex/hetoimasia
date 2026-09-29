-- | One failure, reported once: by the exit or by the supervision sentinel,
-- never again as the exit's retained cleanup.
module Test.GLFW.Owner.Failure.Reporting (spec) where

import Control.Concurrent.STM
  ( atomically
  , check
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
import Control.Monad (forM_, void)
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Resource (cleanupFailureException, cleanupFailures)
import qualified Hetoimasia.Foundation.Worker as Worker
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
import Test.Hspec (Spec, it, shouldBe, shouldReturn)

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

-- | How many times one failure appears in a raised exception: as the
-- exception itself, and in every cleanup failure retained beside it.
occurrencesOf ∷ Scripted → SomeException → Int
occurrencesOf wanted caught =
  length (filter (== Just wanted) (fromException caught : retained))
  where
    retained =
      [ fromException (exceptionOf (cleanupFailureException failure))
      | failure ← cleanupFailures caught
      ]

exceptionOf ∷ ExceptionWithContext SomeException → SomeException
exceptionOf (ExceptionWithContext _ failure) = failure
