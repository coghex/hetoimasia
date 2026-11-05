-- | The bounded lifetime port: a full port is reported as backpressure having
-- reserved nothing, and it blocks neither the stop nor the owner's progress.
module Test.GLFW.Owner.Port (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
  ( atomically
  , check
  , readTVar
  , writeTVar
  )
import Data.IORef (writeIORef)
import qualified Data.Text as Text
import Hetoimasia.Runtime.GLFW
import qualified Hetoimasia.Runtime.GLFW.Internal as Private
import Test.GLFW.Owner.Fixture.Cut
  ( Cutting (..)
  , boundaryControls
  , boundaryExamples
  , heldBody
  , ownedHostCut
  , uncut
  )
import Test.GLFW.Owner.Fixture.Drive (handedOver, theWindow)
import Test.GLFW.Owner.Fixture.Fake (Fake (..), script)
import Test.GLFW.Owner.Fixture.Journal (Note (..), journalled, ordered)
import Test.GLFW.Owner.Fixture.Rig (Rig (..), newRigWith)
import Test.GLFW.Support (boundedExample, quietLogger)
import Test.Hspec (Spec, it, shouldBe, shouldContain, shouldSatisfy)

spec ∷ Spec
spec = do
  it "reports a full port as backpressure, having reserved and attached nothing"
    (boundedExample testPortFullReported)
  it "prevents neither the stop, nor terminal evidence, nor owner progress when it is full"
    (boundedExample testFullPortDoesNotBlockExit)
  boundaryExamples "the full-port report" portFullReported
  boundaryControls "the full-port report" portFullReported
  boundaryExamples "the full port's exit" fullPortDoesNotBlockExit
  boundaryControls "the full port's exit" fullPortDoesNotBlockExit

-- | A port with no room refuses the handover before anything is reserved.
testPortFullReported ∷ IO ()
testPortFullReported = uncut >>= portFullReported

-- | The example under a 'Cutting' (#612): the gate it holds the owner at is the cutting's, and the owner is released on every way out
-- of the body and, before the body has begun, by the exit.
portFullReported ∷ Cutting → IO ()
portFullReported cutting = do
  rig ← newRigWith (\config → config {ownerEventCapacity = 1})
  writeIORef (cuttingRig cutting) (Just rig)
  let gate = cuttingGate cutting
  entered ← newEmptyMVar
  -- The owner is held inside its first startup, so it drains no event at all
  -- and the one-slot port really is full.
  script (fakeStart (rigFake rig)) $ \_ → do
    putMVar entered ()
    atomically (readTVar gate >>= check)
    pure (ownerReady (Text.pack "late"))
  (second, pending) ← ownedHostCut cutting Private.noHostHooks quietLogger (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → heldBody cutting $ do
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
testFullPortDoesNotBlockExit = uncut >>= fullPortDoesNotBlockExit

-- | The example under a 'Cutting' (#612); see 'portFullReported'.
fullPortDoesNotBlockExit ∷ Cutting → IO ()
fullPortDoesNotBlockExit cutting = do
  rig ← newRigWith (\config → config {ownerEventCapacity = 1})
  writeIORef (cuttingRig cutting) (Just rig)
  let gate = cuttingGate cutting
  entered ← newEmptyMVar
  script (fakeStart (rigFake rig)) $ \_ → do
    putMVar entered ()
    atomically (readTVar gate >>= check)
    pure (ownerReady (Text.pack "late"))
  ownedHostCut cutting Private.noHostHooks quietLogger (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → heldBody cutting $ do
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
