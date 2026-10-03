-- | The fixture-aware example bound ("Test.GPU.Vulkan.GLFW.Bound") and the
-- rig's rescue ("Test.GPU.Vulkan.GLFW.StandIn"), exercised directly.
--
-- Each example runs a bound of its own inside its ordinary one, with a bound
-- and a grace that expire only when the example says and a last resort that
-- records the name it was given instead of ending the process, so nothing
-- here waits for a real deadline. What each asserts is read from the rig's
-- journal and from the threads involved, never from timing.
module Test.GPU.Vulkan.GLFW.Rescue (spec) where

import Control.Concurrent (ThreadId, forkIO, yield)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.Exception (SomeException, displayException, throwIO, try, uninterruptibleMask_)
import Control.Monad (void)
import Data.List (isInfixOf, isSubsequenceOf, nub)
import GHC.Conc (ThreadStatus (..), threadStatus)

import Hetoimasia.GLFW.Command (clientDemandPublisher)
import Hetoimasia.GLFW.Demand (immediateDemand, publishDemand)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Loop (runVulkanOwnerLoop)
import Hetoimasia.Runtime.GLFW
  ( ScheduledStep (..)
  , TargetStanding (..)
  , UpdateSchedule (..)
  , defaultScheduledHooks
  , graphicsAttachment
  , hostWindowClient
  )
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Test.GPU.Vulkan.GLFW.Bound (BoundSettings (..), boundOf, boundedIt, runBounded)
import Test.GPU.Vulkan.GLFW.StandIn
import Test.Hspec (Spec, describe, expectationFailure, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = describe "the fixture-aware example bound" $ do
  itBounded "fails an example blocked with a presentation unretired and the clock stopped, once the owner's exit has completed on real destruction evidence, leaving no thread of it running" testExpiryBeforeRelease
  itBounded "reports an example's own failure raised before it released the rig's gates, once the owner's exit has completed, leaving no thread of it running" testFailureBeforeRelease
  itBounded "opens a native hold the owner had already entered, uninterruptibly, before the run is cancelled" testEnteredHoldRescued
  itBounded "names the example to its last resort when it has not ended within the grace, a blocked cancellation notwithstanding, and settles every thread it started" testLastResort

-- | A blocked example: a frame presented, its presentation never retired, the
-- scripted clock never moved, and the body then waiting on something nothing
-- will ever provide. The bound fires, the rig is rescued, the run's bound
-- thread is cancelled, and the owner's protected exit completes.
testExpiryBeforeRelease ∷ IO ()
testExpiryBeforeRelease = do
  (controls, settings) ← scriptedBound
  rigCell ← newTVarIO Nothing
  blocking ← newTVarIO False
  never ← newTVarIO False
  void . forkIO $ do
    atomically (readTVar blocking >>= check)
    expire controls
  outcome ← try . runBounded settings "a blocked example" $ do
    rig ← scriptedRigOf 1
    atomically (writeTVar rigCell (Just rig))
    presentationsRetire rig False
    runRig rig $ \host control → do
      presentOne rig host control
      atomically (writeTVar blocking True)
      atomically (readTVar never >>= check)
  failedWith "the example did not finish within its bound" outcome
  rig ← readTVarIO rigCell >>= maybe (failWith "the example made no rig") pure
  destroyedEverything rig
  readTVarIO (controlTerminated controls) `shouldReturn` Nothing
  settled rig controls
  -- Kept reachable to the end, so the body's wait was never one the runtime
  -- could see was hopeless.
  atomically (writeTVar never True)

-- | An example that fails before it releases the rig's gates — a presentation
-- unretired, the clock stopped — reports its own failure, after the owner's
-- exit has completed. Its bound never expires.
testFailureBeforeRelease ∷ IO ()
testFailureBeforeRelease = do
  (controls, settings) ← scriptedBound
  rigCell ← newTVarIO Nothing
  outcome ← try . runBounded settings "a failing example" $ do
    rig ← scriptedRigOf 1
    atomically (writeTVar rigCell (Just rig))
    presentationsRetire rig False
    runRig rig $ \host control → do
      presentOne rig host control
      expectationFailure "the example's own failure"
  failedWith "the example's own failure" outcome
  rig ← readTVarIO rigCell >>= maybe (failWith "the example made no rig") pure
  destroyedEverything rig
  readTVarIO (controlTerminated controls) `shouldReturn` Nothing
  settled rig controls

-- | The owner holds, uninterruptibly as a native call does, inside the
-- device's creation for the first handover when the bound fires. Rescue opens
-- the hold before the run is cancelled, so the creation completes and the exit
-- destroys what it made.
testEnteredHoldRescued ∷ IO ()
testEnteredHoldRescued = do
  (controls, settings) ← scriptedBound
  rigCell ← newTVarIO Nothing
  gate ← newTVarIO False
  never ← newTVarIO False
  -- The handover itself waits on the held construction, so it is not the body
  -- that sees the hold entered.
  void . forkIO $ do
    rig ← atomically (readTVar rigCell >>= maybe retry pure)
    awaitHeld rig AtCreateDevice
    expire controls
  outcome ← try . runBounded settings "a held example" $ do
    rig ← newRig
    scriptNative rig AtCreateDevice (HoldsUntil gate)
    atomically (writeTVar rigCell (Just rig))
    runRig rig $ \host _ → do
      [window] ← windowsOf host
      _ ← handedOver host window RequiredTarget
      atomically (readTVar never >>= check)
  failedWith "the example did not finish within its bound" outcome
  rig ← readTVarIO rigCell >>= maybe (failWith "the example made no rig") pure
  events ← journal rig
  -- The held creation completed, and what it made was destroyed.
  events `shouldSatisfy` isSubsequenceOf [DeviceCreated, DeviceDestroyed]
  destroyedEverything rig
  readTVarIO gate `shouldReturn` False
  settled rig controls
  atomically (writeTVar never True)

-- | An example whose thread cannot be cancelled — it waits uninterruptibly on
-- something no rig withholds — is still running when the grace expires. The
-- last resort is given the example's name while the cancellation is still
-- waiting to be delivered; here it only records it, and the example is let go
-- afterwards so the bound's own threads can be seen to settle.
testLastResort ∷ IO ()
testLastResort = do
  (controls, settings) ← scriptedBound
  entered ← newTVarIO False
  stuck ← newTVarIO False
  void . forkIO $ do
    atomically (readTVar entered >>= check)
    atomically (writeTVar (controlGrace controls) True)
    expire controls
    atomically (readTVar (controlTerminated controls) >>= maybe retry (const (pure ())))
    atomically (writeTVar stuck True)
  outcome ← try . runBounded settings "a stuck example" $ do
    atomically (writeTVar entered True)
    uninterruptibleMask_ (atomically (readTVar stuck >>= check))
  failedWith "the example did not finish within its bound" outcome
  readTVarIO (controlTerminated controls) `shouldReturn` Just "a stuck example"
  started ← readTVarIO (controlThreads controls)
  mapM_ awaitEnded started
  -- The example's thread, the watchdog and the one cancellation.
  length (nub started) `shouldBe` 3

-- ---------------------------------------------------------------------------
-- Helpers

-- | What an example drives its own bound with.
data Controls = Controls
  { controlExpired ∷ !(TVar Bool)
  , controlGrace ∷ !(TVar Bool)
  , controlTerminated ∷ !(TVar (Maybe String))
  , controlThreads ∷ !(TVar [ThreadId])
  }

-- | A bound and a grace that expire only when the example says, and a last
-- resort that records the name it was given.
scriptedBound ∷ IO (Controls, BoundSettings)
scriptedBound = do
  controls ← Controls <$> newTVarIO False <*> newTVarIO False <*> newTVarIO Nothing <*> newTVarIO []
  pure
    ( controls
    , (boundOf 1)
        { boundExpiry = pure (opened (controlExpired controls))
        , boundGrace = pure (opened (controlGrace controls))
        , boundTerminate = atomically . writeTVar (controlTerminated controls) . Just
        , boundStarted = \thread → atomically (modifyTVar' (controlThreads controls) (<> [thread]))
        }
    )
  where
    opened cell = readTVar cell >>= check

expire ∷ Controls → IO ()
expire controls = atomically (writeTVar (controlExpired controls) True)

-- | Hand the rig's one window over, and run the composed loop until the
-- owner has presented a frame to it.
presentOne ∷ Rig → VulkanHost Scene → RuntimeControl → IO ()
presentOne rig host control = do
  [window] ← windowsOf host
  service ← handedOver host window RequiredTarget
  TargetUsable ← awaitStanding host service
  client ← atomically (hostWindowClient (vulkanWindowHost host) window) >>= maybe (throwIO (StandInFailure "the window has no client")) pure
  void (publishDemand (clientDemandPublisher client) immediateDemand)
  runVulkanOwnerLoop host control . defaultScheduledHooks quietLogger $ \_ → do
    presented ← presentsOf rig (graphicsAttachment service)
    pure (if presented >= 1 then FinishWith () else ContinueWith NoUpdateDemand)

-- | The owner's exit destroyed the surface, the device, the messenger and the
-- instance, in that order, before the window and the session went.
destroyedEverything ∷ Rig → IO ()
destroyedEverything rig = do
  events ← journal rig
  events `shouldSatisfy` isSubsequenceOf [SurfaceDestroyed 100, DeviceDestroyed, MessengerDestroyed, InstanceDestroyed, WindowGone True, SessionEnded]

-- | Every thread of the example has ended: each that left an event in the
-- rig's journal — the owner's worker and the run's bound thread among them —
-- and each the bound started.
settled ∷ Rig → Controls → IO ()
settled rig controls = do
  journalled ← threadsOf rig (const True)
  started ← readTVarIO (controlThreads controls)
  mapM_ awaitEnded (nub (journalled <> started))

-- | Wait until this thread has ended. Each one asserted on here has already
-- done its last observable act, so this yields to the scheduler until the
-- thread's own return has been run, and a thread that never ends fails the
-- enclosing example's bound.
awaitEnded ∷ ThreadId → IO ()
awaitEnded thread =
  threadStatus thread >>= \case
    ThreadFinished → pure ()
    ThreadDied → pure ()
    _ → yield >> awaitEnded thread

failedWith ∷ String → Either SomeException () → IO ()
failedWith expected = \case
  Left failure → displayException failure `shouldSatisfy` (expected `isInfixOf`)
  Right () → failWith "the example returned instead of failing"

failWith ∷ String → IO a
failWith message = expectationFailure message >> throwIO (userError message)

-- | One example under the suite's fixture-aware bound of a minute.
itBounded ∷ String → IO () → Spec
itBounded = boundedIt (boundOf 60)
