-- | A start of the graphics owner that is abandoned after its handle was published (#613).
--
-- The matrix of "Test.GLFW.Owner.Fixture.Cut" cuts every fixture at the boundaries of the start, in three ways each, and judges that
-- the exit finishes when the owner's run action never began. This module holds what the matrix cannot say for itself:
--
-- * an owner whose run action /did/ begin, and ended without destruction evidence, is still waited for when the start is abandoned
--   afterwards, and nothing it retains is released until independent evidence ends the wait: the new case is narrow, not a
--   relaxation of the exit's rule;
-- * an owner published to an exit whose quiescence had already committed, or that commits while the owner is published and before it
--   is withdrawn, ends with its publications closed and the exit finished;
-- * an owner whose worker ends before it acknowledges, while the start's wait returns normally, is withdrawn as well.
module Test.GLFW.Owner.Failure.AbandonedStart (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, tryReadMVar)
import Control.Concurrent.STM (atomically, check, newTVarIO, readTVar, retry, writeTVar)
import Control.Exception (SomeException, fromException, throwIO, toException, try)
import Control.Monad (when)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Messaging.Snapshot (Publication (..))
import Hetoimasia.Foundation.Worker (Completion (..), Result (..), RunExit (..), WorkerEvidence (..), pollCompletion, workerEvidence)
import Hetoimasia.Runtime.GLFW
import qualified Hetoimasia.Runtime.GLFW.Internal as Private
import Test.GLFW.Owner.Fixture.Drive (awaitDiagnostic)
import Test.GLFW.Owner.Fixture.Fake (Fake (..), script)
import Test.GLFW.Owner.Fixture.Journal (Note (..), Scene (..), Scripted (..), journalled)
import Test.GLFW.Owner.Fixture.Rig (Observer (..), Rig (..), newRig, ownedHostObserved)
import Test.GLFW.Support
  ( Boom (..)
  , boundedExample
  , holdForever
  , newSinkTrace
  , quietLogger
  , sinkFailingOn
  , traced
  , unexpected
  )
import Test.Hspec (Spec, it, shouldBe, shouldSatisfy)
import Test.Support.Owned (withOwnedThreadOpening)

spec ∷ Spec
spec = do
  it "still waits for an owner whose run began and ended without destruction evidence when the start is abandoned afterwards, and retains everything until independent evidence ends the wait (#613)" $
    boundedExample testEnteredOwnerStillWaitedFor
  it "closes the publications of an owner withdrawn from an exit whose quiescence committed before the owner was published (#613)" $
    boundedExample (testWithdrawnAfterQuiescence QuiescedBeforeStart)
  it "closes the publications of an owner withdrawn from an exit whose quiescence committed while the owner was published (#613)" $
    boundedExample (testWithdrawnAfterQuiescence QuiescedWhilePublished)
  it "withdraws an owner whose worker ended before it acknowledged although the start's wait returned (#613)" $
    boundedExample testWorkerEndedBeforeAcknowledging

-- | What a run of the rig left for the example to judge.
data Ran = Ran
  { ranFailure ∷ Maybe SomeException
    -- ^ What the run raised, caught on the designated main thread where it still carries its context.
  , ranOwner ∷ Maybe (GraphicsOwner Scene)
    -- ^ The owner, as its handle was published.
  }

-- | Run the rig under these hooks and a body that must not be entered, and report what was observed.
observedRun ∷ Rig → Private.HostHooks → IO Ran
observedRun rig hooks = do
  failure ← newIORef Nothing
  owner ← newIORef Nothing
  _ ←
    try @SomeException $
      ownedHostObserved
        hooks
        Observer {observedOwner = writeIORef owner . Just, observedFailure = writeIORef failure . Just}
        (pure ())
        quietLogger
        (rigSeam rig)
        (rigHostConfig rig)
        (rigOwnerConfig rig)
        (\_ _ _ → pure ())
  Ran <$> readIORef failure <*> readIORef owner

-- | The one abandoned start a failure carries evidence of, with the run exit of the worker that was drained.
abandonedExit ∷ SomeException → IO RunExit
abandonedExit failure = case [completionExit summary | AbandonedStart summary ← workerEvidence failure] of
  [exit] → pure exit
  other → unexpected ("the failure carried " <> show (length other) <> " abandoned starts")

backendNote ∷ Note → Bool
backendNote = \case
  OwnerStartup → True
  Constructed _ → True
  Stepped → True
  TargetRetirement _ → True
  OwnerRetirement → True
  OwnerDestruction → True
  DestroyRaised _ → True
  _ → False

-- | Requirement 2: an abandoned start is not a reason to stop waiting for an owner that ran.
--
-- The backend's destruction always fails, so the owner's run ends without evidence. The start is abandoned only once the run is
-- known to have entered (the backend was asked to start), so the owner is never one that did not run. The exit therefore waits,
-- says so once, and retains the windows and the session until a thread other than the owner's publishes evidence it established.
testEnteredOwnerStillWaitedFor ∷ IO ()
testEnteredOwnerStillWaitedFor = do
  rig ← newRig
  trace ← newSinkTrace
  published ← newTVarIO Nothing
  seen ← newEmptyMVar
  script (fakeDestroy (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "destroy")))
  failure ← newIORef Nothing
  let hooks =
        Private.noHostHooks
          { Private.ownerBoundary = \case
              Private.OwnerAwaitingStartup → do
                -- The run has entered: the backend was asked to start.
                atomically (readTVar (rigJournal rig) >>= check . elem OwnerStartup)
                throwIO Boom
              _ → pure ()
          }
      -- The supplier of the independent evidence. It publishes only once the exit has said it is retaining everything, and records
      -- what was released at that instant for the example to judge: an assertion here would be swallowed with the thread.
      supplier = do
        owner ← atomically (readTVar published >>= maybe retry pure)
        awaitDiagnostic trace
        journalled (rigJournal rig) >>= putMVar seen
        publishOwnerDestruction owner (ownerDestroyed (Text.pack "destroyed independently"))
  withOwnedThreadOpening (pure ()) supplier $ \_ _ → do
    outcome ←
      try @SomeException $
        ownedHostObserved
          hooks
          Observer {observedOwner = atomically . writeTVar published . Just, observedFailure = writeIORef failure . Just}
          (pure ())
          (sinkFailingOn (Text.pack "never") trace)
          (rigSeam rig)
          (rigHostConfig rig)
          (rigOwnerConfig rig)
          (\_ _ _ → pure ())
    case outcome of
      Right () → unexpected "the abandoned start returned"
      Left raised → fromException raised `shouldBe` Just Boom
    caught ← readIORef failure >>= maybe (unexpected "the failure was not observed") pure
    exit ← abandonedExit caught
    -- The worker had entered its run: it was not "never entered", and it was not withdrawn.
    exit `shouldSatisfy` \case
      RunExited _ _ → True
      RunNotEntered → False
  retainedWhileUnverified ← tryReadMVar seen >>= maybe (unexpected "the exit never said it was retaining the owner's state") pure
  -- While the exit waited for evidence, no window and no session had been released and the backend's destruction had been tried.
  retainedWhileUnverified `shouldSatisfy` notElem SessionEnded
  retainedWhileUnverified `shouldSatisfy` all (\entry → case entry of WindowGone _ → False; _ → True)
  -- The run entered the backend. Whether the drain's destruction was then attempted or was itself ended by the starter's cancellation
  -- before the backend was called is the cancellation's timing, and either leaves no evidence, so neither is asserted.
  retainedWhileUnverified `shouldSatisfy` elem OwnerStartup
  -- Then, and only then, the evidence ended the wait and the unwind ran.
  notes ← journalled (rigJournal rig)
  notes `shouldSatisfy` elem SessionEnded
  -- Said exactly once.
  components ← traced trace
  length (filter (== Text.pack "glfw.graphics-owner") components) `shouldBe` 1

-- | When the host's quiescence commits relative to the owner's publication.
data Quiescence
  = QuiescedBeforeStart
    -- ^ Before the start: the publication itself closes the owner.
  | QuiescedWhilePublished
    -- ^ After the handle was published and before it is withdrawn: the quiescence closes the owner, then the withdrawal finds it
    -- closed.

-- | An owner withdrawn from an exit that quiesced closes its publications, and the exit completes without waiting for destruction.
testWithdrawnAfterQuiescence ∷ Quiescence → IO ()
testWithdrawnAfterQuiescence quiescence = do
  rig ← newRig
  hosted ← newIORef Nothing
  let quiesce = readIORef hosted >>= maybe (unexpected "the host was not offered") (atomically . Private.quiesceWindowHost)
      hooks =
        Private.noHostHooks
          { Private.beforeConsumer = \host → do
              writeIORef hosted (Just host)
              when (isBefore quiescence) quiesce
          , Private.ownerBoundary = \case
              Private.OwnerAwaitingStartup → do
                when (not (isBefore quiescence)) quiesce
                throwIO Boom
              _ → pure ()
          , Private.ownerWorkerBoundary = \case
              Private.OwnerWorkerStarting → holdForever
              Private.OwnerWorkerEntering → pure ()
          }
  ran ← observedRun rig hooks
  failure ← maybe (unexpected "the run did not fail") pure (ranFailure ran)
  fromException failure `shouldBe` Just Boom
  abandonedExit failure >>= (`shouldBe` RunNotEntered)
  owner ← maybe (unexpected "the owner was never published") pure (ranOwner ran)
  scene ← prepare (Scene 1)
  closed ← atomically (publishOwnerScene (ownerHandoff owner) scene)
  closed `shouldBe` ScenePublication PublicationClosed
  notes ← journalled (rigJournal rig)
  notes `shouldSatisfy` elem SessionEnded
  filter backendNote notes `shouldBe` []
  where
    isBefore = \case
      QuiescedBeforeStart → True
      QuiescedWhilePublished → False

-- | A worker that ends before it acknowledges while the start's wait returns normally (the wait is for its termination as well) is a
-- terminal owner that never ran. The start returns it to the application, which can see how it ended through the worker handle, as
-- it always could; what changes is that the exit does not wait for destruction evidence that its never-run action cannot produce.
testWorkerEndedBeforeAcknowledging ∷ IO ()
testWorkerEndedBeforeAcknowledging = do
  rig ← newRig
  let hooks =
        Private.noHostHooks
          { Private.ownerWorkerBoundary = \case
              Private.OwnerWorkerStarting → throwIO Boom
              Private.OwnerWorkerEntering → pure ()
          }
  ran ← observedRun rig hooks
  owner ← maybe (unexpected "the owner was never published") pure (ranOwner ran)
  -- The worker ended without acknowledging, with the failure it was given, and never entered its run.
  completion ← atomically (pollCompletion (graphicsOwnerWorker owner)) >>= maybe (unexpected "the worker never ended") pure
  completionExit completion `shouldBe` RunNotEntered
  case completionResult completion of
    Failed failure → fromException (toException failure) `shouldBe` Just Boom
    Cancelled _ → unexpected "the worker was cancelled instead of failing"
    Succeeded () → unexpected "the worker succeeded"
  -- The exit finished: the session is gone and the backend was asked for nothing.
  notes ← journalled (rigJournal rig)
  notes `shouldSatisfy` elem SessionEnded
  filter backendNote notes `shouldBe` []
