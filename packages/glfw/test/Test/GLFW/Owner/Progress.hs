-- | Independent progress: the owner keeps taking rounds while the main thread
-- is blocked, the main thread keeps serving while the owner is, and the owner
-- wakes for its own deadline and for newly published input.
module Test.GLFW.Owner.Progress (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
  ( atomically
  , check
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , writeTVar
  )
import Data.List (isSubsequenceOf, nub)
import Data.Maybe (isJust)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Messaging.Snapshot (Publication (..))
import Hetoimasia.GLFW.Command
  ( CommandResult (ObservationPublished)
  , Disposition (Performed)
  , SubmitResult (SubmitAccepted)
  , observeWindowCommand
  , pollCompletion
  , submitWindowCommand
  )
import Hetoimasia.Runtime.GLFW
import Test.GLFW.Owner.Fixture.Drive (awaitIdle, awaitRound, handedOver, pumpUntil, theWindow)
import Test.GLFW.Owner.Fixture.Fake (Fake (..), ScriptedTimer (..), fireTimer, script)
import Test.GLFW.Owner.Fixture.Journal (Note (..), Scene (..), journalled)
import Test.GLFW.Owner.Fixture.Rig (Rig (..), newRig, ownedHost)
import Test.GLFW.Support (at, boundedExample, millis, unexpected)
import Test.Hspec (Spec, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = do
  it "keeps taking rounds while the main thread is blocked"
    (boundedExample testBlockedMainThread)
  it "serves the main thread's window commands while the owner is blocked inside a step"
    (boundedExample testBlockedOwner)
  it "progresses with the main loop's wake withheld entirely"
    (boundedExample testWakeWithheld)
  it "meets a deadline of its own from its own timer, with nothing else waking it"
    (boundedExample testOwnDeadline)
  it "wakes an idle owner for newly published demand and a newer scene"
    (boundedExample testPublicationWakesIdleOwner)
  it "hands its step each publication's revision, so equal publications stay distinct, and says when demand was taken"
    (boundedExample testStepRevisions)

-- | A main thread that is not turning at all does not stop the owner.
testBlockedMainThread ∷ IO ()
testBlockedMainThread = do
  rig ← newRig
  -- Work is always owed, so the owner takes rounds without waiting for any
  -- wake at all.
  script (fakeStep (rigFake rig)) (\_ → pure (StepReport True True))
  status ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    _ ← handedOver host owner window
    -- The main thread does nothing at all from here: no turn, no pump, no
    -- publication. The owner's rounds are its own.
    observed' ← awaitRound owner 5
    script (fakeStep (rigFake rig)) (\_ → pure noStepWork)
    pure observed'
  statusRounds status `shouldSatisfy` (> 5)

-- | An owner blocked inside its own step does not stop the main thread's
-- window commands.
testBlockedOwner ∷ IO ()
testBlockedOwner = do
  rig ← newRig
  gate ← newTVarIO False
  blocked ← newTVarIO False
  entered ← newEmptyMVar
  script (fakeStep (rigFake rig)) $ \_ → do
    atomically (writeTVar blocked True)
    putMVar entered ()
    atomically (readTVar gate >>= check)
    atomically (writeTVar blocked False)
    pure noStepWork
  settled ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
    window ← theWindow host
    _ ← handedOver host owner window
    takeMVar entered
    -- The owner is inside its step and stays there. The main thread's own
    -- port still admits, its own turn still executes, and the command really
    -- completes — all before anything releases the owner.
    admitted ← submitWindowCommand (hostCommandPort host) [] (observeWindowCommand window)
    ticket ← case admitted of
      SubmitAccepted ticket → pure ticket
      other → unexpected ("the command was not admitted: " <> show other)
    pumpUntil host control "the command's completion" $
      isJust <$> atomically (pollCompletion ticket)
    settled ← atomically (pollCompletion ticket)
    -- Only now, so nothing above could have been served by an owner that had
    -- already left its step.
    stepping ← atomically (readTVar blocked)
    stepping `shouldBe` True
    atomically (writeTVar gate True)
    pure settled
  settled `shouldSatisfy` \case
    Just (Performed (ObservationPublished {})) → True
    _ → False

-- | The owner's rounds do not depend on the main loop waking it.
testWakeWithheld ∷ IO ()
testWakeWithheld = do
  rig ← newRig
  script (fakeStep (rigFake rig)) (\_ → pure (StepReport True True))
  rounds ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control → do
    -- No target, no observation, no demand, no scene, and no pump: nothing at
    -- all crosses from the main thread, and the owner still progresses.
    status ← awaitRound owner 3
    -- Stop owing work before the exit, so what it asserts is the owner's
    -- progress rather than a hot loop racing its own retirement.
    script (fakeStep (rigFake rig)) (\_ → pure noStepWork)
    pure (statusRounds status)
  rounds `shouldSatisfy` (> 3)
  journalled (rigJournal rig) >>= \notes → filter raised notes `shouldBe` []
  where
    raised = \case
      DestroyRaised _ → True
      _ → False

-- | A deadline the backend named is met from the owner's own timer.
testOwnDeadline ∷ IO ()
testOwnDeadline = do
  rig ← newRig
  script (fakeDeadline (rigFake rig)) (pure (OwnerDeadline (at (millis 1000000))))
  (before, after, armings) ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control → do
    first ← awaitRound owner 0
    -- The owner is now waiting on a deadline far in its own future. Nothing
    -- else can wake it: no event, no observation, no stop.
    atomically (check . not . null =<< readTVar (timerArmings (rigTimer rig)))
    fireTimer (rigTimer rig)
    later ← awaitRound owner (statusRounds first)
    armings ← readTVarIO (timerArmings (rigTimer rig))
    pure (statusRounds first, statusRounds later, armings)
  before `shouldSatisfy` (>= 1)
  after `shouldSatisfy` (> before)
  armings `shouldSatisfy` (not . null)

-- | An idle owner wakes for demand and for a scene, not only for an event, an
-- observation or its own timer.
testPublicationWakesIdleOwner ∷ IO ()
testPublicationWakesIdleOwner = do
  rig ← newRig
  (afterDemand, afterScene, scenes) ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control → do
    -- The owner is idle: no target, no deadline, no event, and its step owes
    -- nothing. Only a publication can wake it.
    first ← awaitIdle owner
    demand ← prepare (OwnerDemand True Nothing)
    published ← atomically (publishOwnerDemand (ownerHandoff owner) demand)
    published `shouldBe` Published
    afterDemand ← atomically (awaitOwnerRound owner (statusRounds first))
    second ← awaitIdle owner
    scene ← prepare (Scene 7)
    _ ← atomically (publishOwnerScene (ownerHandoff owner) scene)
    afterScene ← atomically (awaitOwnerRound owner (statusRounds second))
    scenes ← readTVarIO (fakeScenes (rigFake rig))
    pure (statusRounds afterDemand, statusRounds afterScene, scenes)
  afterDemand `shouldSatisfy` (> 0)
  afterScene `shouldSatisfy` (> afterDemand)
  -- The scene the owner stepped with is the one that was published.
  last scenes `shouldBe` Scene 7

-- | Every step is handed the revision of the demand and of the scene it was
-- given, so two publications of the same demand are two requests; and the
-- demand's publisher can tell when the owner has taken its latest one.
testStepRevisions ∷ IO ()
testStepRevisions = do
  rig ← newRig
  revisions ← newTVarIO []
  script (fakeStep (rigFake rig)) $ \step → do
    atomically (modifyTVar' revisions (<> [(stepDemandRevision step, stepSceneRevision step)]))
    pure noStepWork
  (untakenAtPublication, taken, seen) ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control → do
    first ← awaitIdle owner
    demand ← prepare (OwnerDemand True Nothing)
    -- Read in the transaction that published it, the demand cannot have been
    -- taken yet.
    untaken ← atomically $ do
      _ ← publishOwnerDemand (ownerHandoff owner) demand
      not <$> readOwnerDemandTaken owner
    afterFirst ← atomically (awaitOwnerRound owner (statusRounds first))
    second ← awaitIdle owner
    _ ← atomically (publishOwnerDemand (ownerHandoff owner) demand)
    _ ← atomically (awaitOwnerRound owner (statusRounds second))
    third ← awaitIdle owner
    scene ← prepare (Scene 3)
    _ ← atomically (publishOwnerScene (ownerHandoff owner) scene)
    _ ← atomically (awaitOwnerRound owner (statusRounds third))
    _ ← awaitIdle owner
    taken ← atomically (readOwnerDemandTaken owner)
    seen ← readTVarIO revisions
    statusRounds afterFirst `shouldSatisfy` (> 0)
    pure (untaken, taken, seen)
  untakenAtPublication `shouldBe` True
  taken `shouldBe` True
  -- Two equal demands, two revisions, and the scene's own beside them.
  let demands = nub (map fst seen)
      scenes = nub (map snd seen)
  demands `shouldSatisfy` (\held → [1, 2] `isSubsequenceOf` held)
  scenes `shouldSatisfy` (\held → maximum held > minimum held)
