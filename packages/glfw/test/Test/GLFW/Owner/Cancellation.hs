-- | Cancellation of the protected host's exit, honoured at each of its waits in
-- dependency order, with nothing released early however often it repeats.
module Test.GLFW.Owner.Cancellation (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
  ( atomically
  , check
  , newTVarIO
  , readTVar
  , retry
  , writeTVar
  )
import Control.Exception (AsyncException (ThreadKilled), throwTo)
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Worker (requestCancel)
import Hetoimasia.Runtime.GLFW
import Test.GLFW.Owner.Fixture.Drive (absorbing, handedOver, theWindow)
import Test.GLFW.Owner.Fixture.Fake (Fake (..), script)
import Test.GLFW.Owner.Fixture.Journal (Note (..), journalled, ordered)
import Test.GLFW.Owner.Fixture.Rig (Rig (..), newRig, ownedHost)
import Test.GLFW.Support (boundedExample)
import Test.Hspec (Spec, it, shouldBe)

spec ∷ Spec
spec =
  it "honours it at each wait in dependency order, and repeated cancellation releases nothing early"
    (boundedExample testRepeatedCancellation)

-- | Cancellation is honoured at the owner's waits and absorbed by its drain.
--
-- The backend's whole-owner retirement absorbs the cancellations delivered to
-- it and finishes, which is exactly the shape a real one has: a cancellation
-- is not permission to abandon retirement. What the example asserts is that no
-- number of them released anything before the evidence existed.
testRepeatedCancellation ∷ IO ()
testRepeatedCancellation = do
  rig ← newRig
  cancellations ← newTVarIO (0 ∷ Int)
  release ← newTVarIO False
  stepping ← newEmptyMVar
  retiring ← newEmptyMVar
  -- The owner is held inside a step, so the first cancellation is delivered at
  -- a wait rather than wherever it happens to land.
  script (fakeStep (rigFake rig)) $ \_ → do
    putMVar stepping ()
    atomically (readTVar release >>= check)
    pure noStepWork
  -- Its whole-owner retirement absorbs every cancellation delivered to it and
  -- finishes, which is the shape a real one has: a cancellation is not
  -- permission to abandon retirement.
  script (fakeRetireOwner (rigFake rig)) $ \_ → do
    putMVar retiring ()
    absorbing cancellations (atomically (readTVar release >>= check))
    pure (ownerRetired (Text.pack "retired under cancellation"))
  terminal ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    _ ← handedOver host owner window
    takeMVar stepping
    -- The first cancellation ends the run action at that wait and enters the
    -- drain, which retires the target before it retires the owner.
    requestCancel (graphicsOwnerWorker owner)
    takeMVar retiring
    -- Two more land inside the drain, where they are absorbed. They are
    -- delivered directly, because a worker's own cancellation request forks
    -- exactly one delivery however often it is made, and what this example
    -- must show is what /repeated/ delivery cannot do.
    ownerThread ← atomically (readTVar (fakeThreads (rigFake rig)) >>= \seen → case seen of
      thread : _ → pure thread
      [] → retry)
    throwTo ownerThread ThreadKilled
    atomically (readTVar cancellations >>= check . (>= 1))
    throwTo ownerThread ThreadKilled
    atomically (readTVar cancellations >>= check . (>= 2))
    atomically (writeTVar release True)
    held ← atomically $ do
      terminal ← readOwnerTerminalNow owner
      check (isJust (ownerDestroyedEvidence terminal))
      pure terminal
    -- Nothing released this target, so its attachment is still the main
    -- thread's until the exit begins its retirement. What the example asserts
    -- is the exit's own order, below.
    pure held
  ownerRetiredEvidence terminal `shouldBe` Just (Text.pack "retired under cancellation")
  ownerDestroyedEvidence terminal `shouldBe` Just (Text.pack "destroyed")
  notes ← journalled (rigJournal rig)
  -- Dependency order held through every cancellation: the target, then the
  -- owner, then its destruction, and the window and the session only after
  -- all three.
  ordered
    notes
    [TargetRetirement (Text.pack "WindowId 1"), OwnerRetirement, OwnerDestruction, WindowGone 1, SessionEnded]
