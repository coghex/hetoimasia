-- | The bounded lifetime port: a full port is reported as backpressure having
-- reserved nothing, and it blocks neither the stop nor the owner's progress.
module Test.GLFW.Owner.Port (spec) where

import Control.Concurrent.MVar (newEmptyMVar, takeMVar)
import Control.Concurrent.STM
  ( atomically
  , newTVarIO
  , writeTVar
  )
import Control.Monad (when)
import qualified Data.Text as Text
import Hetoimasia.Runtime.GLFW
import Test.GLFW.Owner.Fixture.Drive (handedOver, theWindow)
import Test.GLFW.Owner.Fixture.Journal (Note (..), journalled, ordered)
import Test.GLFW.Owner.Fixture.Rig (Rig (..), newRigWith, ownedHostHeldStart)
import Test.GLFW.Support (Scope, boundedExample, cutExamples)
import Test.Hspec (Spec, it, shouldBe, shouldContain, shouldSatisfy)

spec ∷ Spec
spec = do
  it "reports a full port as backpressure, having reserved and attached nothing"
    (boundedExample testPortFullReported)
  cutExamples "the full-port fixtures" [0, 1] portFullReportedScenario
  cutExamples "the full-port exit fixture" [0, 1] fullPortDoesNotBlockExitScenario
  it "prevents neither the stop, nor terminal evidence, nor owner progress when it is full"
    (boundedExample testFullPortDoesNotBlockExit)

-- | A port with no room refuses the handover before anything is reserved.
testPortFullReported ∷ IO ()
testPortFullReported = portFullReportedFixture (\_ → pure ())

-- | The same fixture ended at the cut (#593): 0 in the startup hook before the owner is held in its startup, 1 once the release of that
-- hold is registered.
portFullReportedScenario ∷ Int → Scope → IO () → IO ()
portFullReportedScenario k _ atParked = portFullReportedFixture (\i → when (i == k) atParked)

portFullReportedFixture ∷ (Int → IO ()) → IO ()
portFullReportedFixture cut = do
  rig ← newRigWith (\config → config {ownerEventCapacity = 1})
  gate ← newTVarIO False
  entered ← newEmptyMVar
  -- The owner is held inside its first startup, so it drains no event at all
  -- and the one-slot port really is full.
  (second, pending) ← ownedHostHeldStart cut rig (rigHostConfig rig) gate entered (ownerReady (Text.pack "late")) $ \host owner _control → do
    takeMVar entered
    window ← theWindow host
    _ ← handedOver host owner window
    -- The one slot is spent and undrained. A second handover cannot be told to
    -- the owner, so it reserves nothing and attaches nothing.
    refused ← handOverGraphicsTarget host owner window
    pending ← atomically (hostPendingAttachments host)
    atomically (writeTVar gate True)
    pure (refused, pending)
  second `shouldSatisfy` \case
    HandoverPortFull → True
    _ → False
  -- Exactly the one attachment the first handover made.
  length pending `shouldBe` 1

-- | A full ordinary port stops neither the stop, nor the terminal evidence,
-- nor the owner's own progress.
testFullPortDoesNotBlockExit ∷ IO ()
testFullPortDoesNotBlockExit = fullPortDoesNotBlockExitFixture (\_ → pure ())

-- | The same fixture ended at the cut (#593): 0 in the startup hook before the owner is held in its startup, 1 once the release of that
-- hold is registered.
fullPortDoesNotBlockExitScenario ∷ Int → Scope → IO () → IO ()
fullPortDoesNotBlockExitScenario k _ atParked = fullPortDoesNotBlockExitFixture (\i → when (i == k) atParked)

fullPortDoesNotBlockExitFixture ∷ (Int → IO ()) → IO ()
fullPortDoesNotBlockExitFixture cut = do
  rig ← newRigWith (\config → config {ownerEventCapacity = 1})
  gate ← newTVarIO False
  entered ← newEmptyMVar
  ownedHostHeldStart cut rig (rigHostConfig rig) gate entered (ownerReady (Text.pack "late")) $ \host owner _control → do
    takeMVar entered
    window ← theWindow host
    _ ← handedOver host owner window
    refused ← handOverGraphicsTarget host owner window
    refused `shouldSatisfy` \case
      HandoverPortFull → True
      _ → False
    atomically (writeTVar gate True)
  notes ← journalled (rigJournal rig)
  -- The exit still reached every phase, in order, with a full port behind it.
  notes `shouldContain` [OwnerRetirement, OwnerDestruction]
  ordered notes [OwnerRetirement, OwnerDestruction, SessionEnded]
