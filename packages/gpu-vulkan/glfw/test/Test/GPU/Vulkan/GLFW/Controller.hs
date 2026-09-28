{-# LANGUAGE AllowAmbiguousTypes #-}

-- | The Vulkan controller's examples: whole graphics hosts over the GLFW
-- package's scripted seam, driven through the real owner machinery and the
-- real controller, with the native layer and the surface bridge replaced by
-- "Test.GPU.Vulkan.GLFW.StandIn".
--
-- Every example asserts an order of journalled events, a thread, or an
-- observed state, and coordinates threads with STM; none sleeps. The journal
-- records each native call with the thread that made it, so the thread
-- placement they assert is the stand-ins' own record rather than an example's
-- name. That is still the headless half of the evidence: the native half is
-- the proof harness's VK-7 session, on a real loader.
module Test.GPU.Vulkan.GLFW.Controller (spec) where

import Control.Concurrent (ThreadId, forkIO, myThreadId, throwTo, yield)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (..), threadStatus)
import Control.Concurrent.STM (TVar, atomically, check, newTVarIO, orElse, readTVar, registerDelay, retry, writeTVar)
import Control.Exception (Exception (..), ExceptionWithContext (ExceptionWithContext), SomeException, asyncExceptionFromException, asyncExceptionToException, finally, throwIO, try)
import Control.Monad (forM_, replicateM_, void)
import Data.List (isSubsequenceOf, nub)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
import qualified Data.Text
import System.Timeout (timeout)
import Hetoimasia.GPU.Model (SessionFailureCause (DeviceLost), SessionState (..), TargetView (..), sessionState, targetView)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.Diagnostics (CaptureConfig (..), CaptureCounters (..), CaptureStatus (..), DiagnosticVerdict (..), VerdictIssue (..), defaultCaptureConfig, verdictIssues)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller
import Hetoimasia.Foundation.Messaging.Payload (prepare, preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)
import Hetoimasia.GLFW.Command (clientObservations)
import Hetoimasia.GLFW.Window (Attribute (Observed), Extent (..), WindowId, observedFramebufferExtent)
import Hetoimasia.GPU.Vulkan.Native.Generations (GenerationView (..), SwapchainResult (..), TargetCondition (..), TargetGenerationsView (..))
import Data.Word (Word64)
import Numeric.Natural (Natural)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Hetoimasia.GPU.Vulkan.Native.Presentation (Suspension (..))
import Hetoimasia.GPU.Vulkan.Native.Profile (NoCompatibleDevice (..), TargetRejection (..))
import Hetoimasia.GPU.Vulkan.Native.Roots (GraphicsDeviceLost (..), GraphicsSessionFailed (..), RootStanding (..), RootTargetView (..), RootsView (..), SurfaceDestructionFailed (..), TeardownEvidence (..), TerminalCause (..), TerminalReport (..))
import Hetoimasia.Runtime.GLFW
  ( CloseStart (..)
  , EventAdmission (..)
  , GraphicsService
  , OwnerStatus (..)
  , ReleaseAnswer (..)
  , SlotState (..)
  , Stage (..)
  , TargetStanding (..)
  , allRetirementFacts
  , awaitOwnerRound
  , readOwnerStatusNow
  , ownerHandoff
  , publishOwnerScene
  , closeHostWindow
  , completionNotice
  , custodyOf
  , graphicsAttachment
  , hostGraphicsPublisher
  , hostWindowClient
  , hostPendingAttachments
  , observedSlot
  , ownerDestroyed
  , ownerTargetAcknowledgement
  , publishCompletion
  , publishOwnerDestruction
  , readGraphicsService
  , readOwnerFailure
  , readOwnerFailures
  , readOwnerTerminalNow
  , OwnerTerminal (..)
  , readTargetTerminalsNow
  , releaseGraphicsTarget
  , superviseGraphicsOwner
  , windowGraphicsService
  )
import Hetoimasia.Runtime.Supervision (checkRuntime)
import Test.GPU.Vulkan.GLFW.StandIn
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "Vulkan controller" $ do
  describe "handing targets over" $ do
    it "creates each surface on the main thread, and every root and destruction on the owner's thread" (bounded testThreadPlacement)
    it "selects the device against the first surface and shares it with the second, recording each designation" (bounded testSharedDevice)
    it "attaches nothing before the owner has leased an instance" (bounded testNotReady)
    it "rejects a surface the session's queue family cannot present to, leaving the device and the other target as they were" (bounded testIncompatible)
    it "destroys an unusable surface on the owner's thread and rolls its target back" (bounded testUnusable)
    it "rolls back a target whose surface was never created, destroying nothing" (bounded testNotCreated)

  describe "construction rollback" $ do
    it "at the instance: destroys nothing" (bounded (testStartupFails AtCreateInstance []))
    it "at the messenger: destroys the instance" (bounded (testStartupFails AtCreateMessenger [InstanceDestroyed]))
    it "at the device query: destroys the bootstrap surface, the messenger and the instance" (bounded (testBootstrapFails AtQueryDevices))
    it "at the device: destroys the bootstrap surface, the messenger and the instance" (bounded (testBootstrapFails AtCreateDevice))
    it "with no compatible device: fails structurally and destroys the same" (bounded testNoCompatibleDevice)

  describe "cancellation" $ do
    it "during the handoff's surface creation leaves the attachment announced and the instance retained until the owner settles it" (bounded testCancelledHandoff)
    it "delivered repeatedly during the exit changes neither the destruction order nor the join" (bounded testRepeatedCancellation)

  describe "a full owner port" $ do
    it "leaves a deferred attachment the owner destroys on its own thread once it is released" (bounded testDeferredReleased)
    it "lets a deferred attachment be announced again and admitted" (bounded testDeferredAnnounced)
    it "reports a deferred surface whose destruction failed at a checkpoint, never retries it, and retains its parents" (bounded testDeferredUncertain)
    it "watches an attachment whose answer a cancellation lost after publication, when its recovered announcement finds the port full" (bounded testRecoveredDeferred)
    it "watches a refused attachment even when the owner drains its port and goes idle before the handover answers" (bounded testRefusalThenIdle)

  describe "close and exit" $ do
    it "closing the first-created window retires its target alone, leaving the shared roots and the second target live" (bounded testCloseFirst)
    it "releasing one target destroys its surface before its terminal record, with the owner and the other target live" (bounded testRelease)
    it "a whole-host exit destroys every surface, the device, the messenger and the instance, then joins the owner before any window goes" (bounded testExitOrder)
    it "a destruction still pending certifies nothing" (bounded testPendingDestruction)

  describe "device loss" $ do
    it "closes admission at once and reaches an application checkpoint while retirement is still pending" (bounded testLossReachesCheckpoint)
    it "keeps the loss primary, never retries a failed destruction, and retains its parents without certifying the attachment" (bounded testLossWithFailedCleanup)
    it "treats an unknown outcome as neither device loss nor destruction" (bounded testUnknownOutcome)

  describe "terminal failure" $ do
    it "latches a validation error reported inside a native call as the primary at the owner's next checkpoint, refusing every later handover naming it" (bounded testValidationStops)
    it "latches an error whose record a full capture dropped, since the latch is set before the record is admitted" (bounded testDroppedErrorStops)
    it "latches a sink failure as a terminal status of its own, with the capture's verdict saying so" (bounded testSinkFailure)
    it "wakes an idle owner when the capture's worker records a sink failure, with nothing else published" (bounded testIdleSinkWakes)
    it "keeps a sink failure that came first as the primary when a validation error arrives before the next checkpoint" (bounded testSinkThenError)
    it "refuses a handover while a sink failure has claimed the order but not yet published, latching nothing until it has" (bounded testClaimedSinkPending)
    it "admits no target whose construction begins after a validation error arrived, making no native call for it" (bounded testQueuedConstructionStops)
    it "reports what an exit could not verify as retained, beside the cleanup failure that is its primary" (bounded testRetentionReported)
    it "keeps the dependency order and the loss when cancellation is delivered repeatedly during the drain that follows it" (bounded testCancelledAfterLoss)
    it "latches the failed destruction of a surface created while the lease closed, beside the earlier primary, and retains the instance" (bounded testLateSurfaceFails)
    it "latches each surface destruction that fails in one pass as a cleanup failure of its own, naming its surface" (bounded testSeveralDischargesFail)
    it "latches the failed destructions of two distinct surfaces that share a handle, each with its own attachment" (bounded testReusedHandleFails)

  describe "progress" $
    it "reports no work and no deadline while nothing is deferred and no frame is wanted" (bounded testNoDemand)

  describe "recovering a lost surface (VK-14)" $ do
    it "replaces it on the main thread under the same attachment, after its generation and then the lost surface went on the owner's thread, and leaves the other target alone" (bounded testSurfaceReplaced)
    it "lets a close defeat a replacement still asked for: nothing is created, and the target retires" (bounded testReplacementAfterClose)
    it "reports an optional target whose episode was spent unavailable, while the other target keeps its generation" (bounded testOptionalSpent)
    it "fails the session at a checkpoint when a required target's episode is spent" (bounded testRequiredSpent)
    it "disposes of an optional target whose replacement the device cannot present to, destroying that surface on the owner's thread, with no second device" (bounded testUnsupportedOptional)
    it "fails the session when a required target's replacement cannot be presented to" (bounded testUnsupportedRequired)
    it "spends no attempt for an ordinary resize, and one for each out-of-date result at unchanged geometry" (bounded testResizeVersusFailure)

  describe "swapchain generations" $ do
    it "builds a visible target's generation on the owner's thread, from the framebuffer the owner last observed, and the exit destroys it" (bounded testGenerationBuilt)
    it "replaces it after a resize the owner observed, handing the old one over, and destroys the old one only once its hold ends" (bounded testGenerationReplaced)
    it "builds nothing for a hidden target, and asks its surface nothing" (bounded testHiddenSuspended)
    it "destroys a closing window's views and swapchain on the owner's thread before its surface" (bounded testGenerationClosed)

-- ---------------------------------------------------------------------------
-- Handing targets over

testThreadPlacement ∷ IO ()
testThreadPlacement = do
  rig ← twoWindows
  mainThread ← newTVarIO Nothing
  _ ← runRig rig $ \host _ → do
    myThreadId >>= atomically . writeTVar mainThread . Just
    [first, second] ← windowsOf host
    one ← handedOver host first RequiredTarget
    TargetUsable ← awaitStanding host one
    two ← handedOver host second OptionalTarget
    TargetUsable ← awaitStanding host two
    pure ()
  Just main ← atomically (readTVar mainThread)
  created ← threadsOf rig isSurfaceCreation
  created `shouldSatisfy` (\threads → length threads == 2 && all (== main) threads)
  owned ← threadsOf rig ownerEvent
  -- Every root's creation and destruction, and every surface's destruction,
  -- on one thread, which is not the main one.
  length owned `shouldBe` 8
  nub owned `shouldSatisfy` (\threads → length threads == 1 && main `notElem` threads)
  Just verdict ← atomically (readTVar (rigVerdict rig))
  verdictQuiescent verdict `shouldBe` True
  where
    isSurfaceCreation = \case
      SurfaceCreated _ → True
      _ → False
    ownerEvent = \case
      InstanceCreated → True
      MessengerCreated → True
      DeviceCreated → True
      SurfaceDestroyed _ → True
      DeviceDestroyed → True
      MessengerDestroyed → True
      InstanceDestroyed → True
      _ → False

testSharedDevice ∷ IO ()
testSharedDevice = do
  rig ← twoWindows
  (targets, roots) ← runRig rig $ \host _ → do
    [first, second] ← windowsOf host
    one ← handedOver host first RequiredTarget
    TargetUsable ← awaitStanding host one
    two ← handedOver host second OptionalTarget
    TargetUsable ← awaitStanding host two
    targets ← atomically (readVulkanTargets (vulkanController host))
    roots ← atomically (readVulkanRoots (vulkanController host))
    pure ([(attachment == graphicsAttachment one, targetViewClass view, targetViewSurface view) | (attachment, view) ← targets], roots)
  targets `shouldBe` [(True, RequiredTarget, 100), (False, OptionalTarget, 101)]
  viewDevice roots `shouldBe` RootLive
  viewDeviceName roots `shouldBe` Just "stand-in device"
  events ← journal rig
  -- Selected against the first surface; the second is checked against the
  -- queue family already chosen, and no second device exists.
  [e | e ← events, isDeviceEvent e]
    `shouldBe` [DevicesQueried 100, DeviceCreated, SupportQueried 101, DeviceDestroyed]
  where
    isDeviceEvent = \case
      DevicesQueried _ → True
      DeviceCreated → True
      SupportQueried _ → True
      DeviceDestroyed → True
      _ → False

testNotReady ∷ IO ()
testNotReady = do
  rig ← newRig
  gate ← newTVarIO False
  scriptNative rig AtCreateInstance (HoldsUntil gate)
  (answer, pending) ← runRig rig $ \host _ → do
    outcome ←
      flip finally (atomically (writeTVar gate True)) $ do
        [window] ← windowsOf host
        answer ← handOverVulkanTarget (vulkanController host) (vulkanWindowHost host) (vulkanGraphicsOwner host) window RequiredTarget
        pending ← atomically (hostPendingAttachments (vulkanWindowHost host))
        pure (answer, pending)
    -- Let the startup finish before the exit asks the owner to stop.
    atomically (readReadiness (vulkanController host) >>= check . (== RootsReady))
    pure outcome
  answer `shouldSatisfy` \case
    VulkanRootsNotReady RootsPending → True
    _ → False
  pending `shouldBe` []
  events ← journal rig
  [() | SurfaceCreated _ ← events] `shouldBe` []

testIncompatible ∷ IO ()
testIncompatible = do
  rig ← twoWindows
  declareUnsupported rig 101
  (standing, rejection, before, after, firstStanding) ← runRig rig $ \host control → do
    [first, second] ← windowsOf host
    one ← handedOver host first RequiredTarget
    TargetUsable ← awaitStanding host one
    before ← atomically (readVulkanRoots (vulkanController host))
    two ← handedOver host second RequiredTarget
    standing ← awaitStanding host two
    rejection ← atomically (readTargetRejection (vulkanController host) (graphicsAttachment two))
    after ← atomically (readVulkanRoots (vulkanController host))
    -- Rolled back: releasing it needs nothing from the owner but the record
    -- its verified rollback already is.
    _ ← releaseGraphicsTarget (vulkanWindowHost host) (vulkanGraphicsOwner host) two
    pumpUntil host control "the rejected attachment's retirement" ((== 1) . length <$> atomically (hostPendingAttachments (vulkanWindowHost host)))
    firstStanding ← awaitStanding host one
    pure (standing, rejection, before, after, firstStanding)
  standing `shouldBe` TargetUnusable False
  rejection `shouldBe` Just (RejectedByRoots (TargetSurfaceUnsupported 0))
  after `shouldBe` before
  firstStanding `shouldBe` TargetUsable
  events ← journal rig
  -- The rejected surface was destroyed during its construction, before any
  -- root was, and exactly one device ever existed.
  takeWhile (/= DeviceDestroyed) events `shouldSatisfy` elem (SurfaceDestroyed 101)
  length [() | DeviceCreated ← events] `shouldBe` 1

testUnusable ∷ IO ()
testUnusable = do
  rig ← newRig
  scriptSurface rig 100 CreateUnusable
  (standing, rejection) ← runRig rig $ \host _ → do
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    standing ← awaitStanding host service
    rejection ← atomically (readTargetRejection (vulkanController host) (graphicsAttachment service))
    pure (standing, rejection)
  standing `shouldBe` TargetUnusable False
  rejection `shouldSatisfy` \case
    Just (SurfaceUnusable _) → True
    _ → False
  events ← journal rig
  [e | e ← events, e `elem` [SurfaceCreated 100, SurfaceDestroyed 100, DeviceCreated]] `shouldBe` [SurfaceCreated 100, SurfaceDestroyed 100]
  owner ← threadsOf rig (== InstanceCreated)
  destroyer ← threadsOf rig (== SurfaceDestroyed 100)
  destroyer `shouldBe` owner

testNotCreated ∷ IO ()
testNotCreated = do
  rig ← newRig
  scriptSurface rig 100 CreateFails
  (standing, rejection) ← runRig rig $ \host _ → do
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    standing ← awaitStanding host service
    rejection ← atomically (readTargetRejection (vulkanController host) (graphicsAttachment service))
    pure (standing, rejection)
  standing `shouldBe` TargetUnusable False
  rejection `shouldSatisfy` \case
    Just (SurfaceNotCreated _) → True
    _ → False
  events ← journal rig
  [() | SurfaceDestroyed _ ← events] `shouldBe` []

-- ---------------------------------------------------------------------------
-- Construction rollback

-- | The owner's startup fails at this step: the run reports it, and the
-- owner's drain destroys exactly what exists before any window goes.
testStartupFails ∷ Step → [Event] → IO ()
testStartupFails at destroyed = do
  rig ← newRig
  scriptNative rig at Fails
  outcome ← runRigCaught rig $ \host _ → do
    atomically (readReadiness (vulkanController host) >>= check . failed)
    ownerEnded host
  failure ← raisedAs @StandInFailure outcome
  failure `shouldBe` StandInFailure (showText at)
  events ← journal rig
  dropWhile (not . destruction) events `shouldBe` destroyed <> [WindowGone True, SessionEnded]
  where
    failed = \case
      RootsFailed _ → True
      _ → False

-- | The bootstrap target's construction fails at this step: the loss of the
-- run is the owner's, and its drain destroys the surface, then the messenger
-- and the instance — there is no device.
testBootstrapFails ∷ Step → IO ()
testBootstrapFails at = do
  rig ← newRig
  scriptNative rig at Fails
  outcome ← runRigCaught rig $ \host _ → do
    [window] ← windowsOf host
    _ ← handedOver host window RequiredTarget
    ownerEnded host
  failure ← raisedAs @StandInFailure outcome
  failure `shouldBe` StandInFailure (showText at)
  events ← journal rig
  dropWhile (not . destruction) events
    `shouldBe` [SurfaceDestroyed 100, MessengerDestroyed, InstanceDestroyed, WindowGone True, SessionEnded]

testNoCompatibleDevice ∷ IO ()
testNoCompatibleDevice = do
  rig ← newRig
  declareUnsupported rig 100
  outcome ← runRigCaught rig $ \host _ → do
    [window] ← windowsOf host
    _ ← handedOver host window RequiredTarget
    ownerEnded host
  NoCompatibleDevice candidates ← raisedAs @NoCompatibleDevice outcome
  map fst candidates `shouldBe` ["stand-in device"]
  events ← journal rig
  dropWhile (not . destruction) events
    `shouldBe` [SurfaceDestroyed 100, MessengerDestroyed, InstanceDestroyed, WindowGone True, SessionEnded]

-- ---------------------------------------------------------------------------
-- Cancellation

-- | A cancellation, as an asynchronous exception: what a supervisor's
-- 'Control.Concurrent.killThread' or a timeout delivers.
data Cancelled = Cancelled
  deriving (Eq, Show)

instance Exception Cancelled where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

testCancelledHandoff ∷ IO ()
testCancelledHandoff = do
  rig ← newRig
  gate ← newTVarIO False
  scriptSurface rig 100 (CreateHolds gate)
  (answer, stage, standing, instanceWhileOwned) ← runRig rig $ \host _ → do
    [window] ← windowsOf host
    atomically (readReadiness (vulkanController host) >>= check . (== RootsReady))
    main ← myThreadId
    -- Once the surface's creation is holding, as its native call would, a
    -- cancellation is aimed at the main thread and the creation released; the
    -- cancellation is delivered whenever the handoff next permits one.
    void . forkIO $ do
      atomically (creationsBegun rig >>= check . (>= 1))
      thrower ← forkIO (throwTo main Cancelled)
      -- Released only once the cancellation is waiting on the held call, so
      -- it certainly arrives during this handoff and not after it.
      awaitThrowing thrower
      atomically (writeTVar gate True)
    answer ← try @Cancelled (handOverVulkanTarget (vulkanController host) (vulkanWindowHost host) (vulkanGraphicsOwner host) window RequiredTarget)
    -- Whatever the caller heard, the attachment exists and the owner was told
    -- of it: its answer, if lost, was recovered and announced.
    Just service ← atomically (windowGraphicsService (vulkanWindowHost host) window)
    stage ← atomically (custodyOf (vulkanGraphicsOwner host) (graphicsAttachment service))
    standing ← awaitStanding host service
    roots ← atomically (readVulkanRoots (vulkanController host))
    pure (either (const "cancelled") (const "answered") answer ∷ String, stage, standing, viewInstance roots)
  answer `shouldSatisfy` (`elem` ["cancelled", "answered"])
  stage `shouldSatisfy` (`elem` [Just CustodyAnnounced, Just CustodyOwned])
  standing `shouldBe` TargetUsable
  instanceWhileOwned `shouldBe` RootLive
  events ← journal rig
  events `shouldSatisfy` isSubsequenceOf [SurfaceCreated 100, SurfaceDestroyed 100, InstanceDestroyed, WindowGone True]

testRepeatedCancellation ∷ IO ()
testRepeatedCancellation = do
  rig ← twoWindows
  gate ← newTVarIO False
  scriptNative rig AtDestroyDevice (HoldsUntil gate)
  outcome ← runRigCaught rig $ \host _ → do
    [first, second] ← windowsOf host
    one ← handedOver host first RequiredTarget
    TargetUsable ← awaitStanding host one
    two ← handedOver host second OptionalTarget
    TargetUsable ← awaitStanding host two
    main ← myThreadId
    -- The exit reaches the device's destruction and holds there; three
    -- cancellations are then aimed at the main thread, which is awaiting the
    -- owner, before the destruction is let go.
    void . forkIO $ do
      awaitEvent rig (SurfaceDestroyed 101)
      replicateM_ 3 (throwTo main Cancelled)
      atomically (writeTVar gate True)
  _ ← raisedAs @Cancelled outcome
  events ← journal rig
  dropWhile (not . destruction) events
    `shouldBe` [ SurfaceDestroyed 100
               , SurfaceDestroyed 101
               , DeviceDestroyed
               , MessengerDestroyed
               , InstanceDestroyed
               , WindowGone True
               , WindowGone True
               , SessionEnded
               ]

-- ---------------------------------------------------------------------------
-- A full owner port

-- | Three windows, an owner port of one event, and the owner held inside the
-- first window's construction: the second window's announcement fills the
-- port, and the third's is refused. Answers the third's service, with the
-- gate that releases the owner.
deferredThird ∷ Rig → VulkanHost Scene → IO (GraphicsService, TVar Bool, [GraphicsService])
deferredThird rig host = do
  gate ← newTVarIO False
  scriptNative rig AtQueryDevices (HoldsUntil gate)
  [first, second, third] ← windowsOf host
  one ← handedOver host first RequiredTarget
  -- The owner has taken the first announcement and is inside its
  -- construction, so the port is empty and stays so until it is released.
  atomically (custodyOf (vulkanGraphicsOwner host) (graphicsAttachment one) >>= check . (== Just CustodyOwned))
  two ← handedOver host second RequiredTarget
  deferred ←
    handOverVulkanTarget (vulkanController host) (vulkanWindowHost host) (vulkanGraphicsOwner host) third RequiredTarget >>= \case
      VulkanAnnouncementDeferred service → pure service
      other → failWith ("the third window was not deferred: " <> show other)
  pure (deferred, gate, [one, two])

testDeferredReleased ∷ IO ()
testDeferredReleased = do
  base ← newRigOf 3
  let rig = base {rigPortCapacity = Just 1}
  (slot, destroyedWhileRunning) ← runRig rig $ \host control → do
    (deferred, gate, _) ← deferredThird rig host
    flip finally (atomically (writeTVar gate True)) $ do
      _ ← releaseGraphicsTarget (vulkanWindowHost host) (vulkanGraphicsOwner host) deferred
      atomically (writeTVar gate True)
      -- The owner, not the exit, destroys it: nothing else ever told the owner
      -- about this attachment.
      pumpUntil host control "the deferred surface's destruction" (elem (SurfaceDestroyed 102) <$> journal rig)
      pumpUntil host control "the deferred attachment's retirement" $
        (== SlotFree) . observedSlot <$> atomically (readGraphicsService deferred)
      roots ← atomically (readVulkanRoots (vulkanController host))
      events ← journal rig
      pure (SlotFree, (viewInstance roots, takeWhile (/= DeviceDestroyed) events))
  slot `shouldBe` SlotFree
  fst destroyedWhileRunning `shouldBe` RootLive
  snd destroyedWhileRunning `shouldSatisfy` elem (SurfaceDestroyed 102)
  owner ← threadsOf rig (== InstanceCreated)
  destroyer ← threadsOf rig (== SurfaceDestroyed 102)
  destroyer `shouldBe` owner

testDeferredAnnounced ∷ IO ()
testDeferredAnnounced = do
  base ← newRigOf 3
  let rig = base {rigPortCapacity = Just 1}
  (standing, earlyDestruction) ← runRig rig $ \host _ → do
    (deferred, gate, earlier) ← deferredThird rig host
    atomically (writeTVar gate True)
    mapM_ (awaitStanding host) earlier
    admitted ← announceVulkanTarget (vulkanController host) (vulkanGraphicsOwner host) deferred
    case admitted of
      EventAdmitted → pure ()
      other → failWith ("the deferred window was not announced: " <> show other)
    standing ← awaitStanding host deferred
    events ← journal rig
    pure (standing, SurfaceDestroyed 102 `elem` events)
  standing `shouldBe` TargetUsable
  earlyDestruction `shouldBe` False

testRefusalThenIdle ∷ IO ()
testRefusalThenIdle = do
  base ← newRigOf 3
  let rig = base {rigPortCapacity = Just 1}
  (deadline, destroyedWhileRunning) ← runRig rig $ \host control → do
    gate ← newTVarIO False
    scriptNative rig AtQueryDevices (HoldsUntil gate)
    chosen ← newTVarIO Nothing
    flip finally (atomically (writeTVar gate True)) $ do
      let owner = vulkanGraphicsOwner host
      [first, second, third] ← windowsOf host
      one ← handedOver host first RequiredTarget
      atomically (custodyOf owner (graphicsAttachment one) >>= check . (== Just CustodyOwned))
      two ← handedOver host second RequiredTarget
      -- In the instant after the refusal, and before the handover answers, the
      -- owner is let go: it finishes the first construction, takes the second
      -- announcement, constructs it, and completes that round — choosing its
      -- next deadline — while nothing else is left to wake it.
      afterRefusal rig $ \_ → do
        held ← atomically (statusRounds <$> readOwnerStatusNow owner)
        atomically (writeTVar gate True)
        TargetUsable ← awaitStanding host two
        status ← atomically (awaitOwnerRound owner (held + 1))
        atomically (writeTVar chosen (Just (statusNextDeadline status)))
      deferred ←
        handOverVulkanTarget (vulkanController host) (vulkanWindowHost host) owner third RequiredTarget >>= \case
          VulkanAnnouncementDeferred service → pure service
          other → failWith ("the third window was not deferred: " <> show other)
      _ ← releaseGraphicsTarget (vulkanWindowHost host) owner deferred
      pumpUntil host control "the deferred surface's destruction" (elem (SurfaceDestroyed 102) <$> journal rig)
      deadline ← atomically (readTVar chosen)
      roots ← atomically (readVulkanRoots (vulkanController host))
      pure (deadline, viewInstance roots)
  -- The round the owner finished before the handover answered already named a
  -- deadline, because the watch was registered before the announcement.
  deadline `shouldSatisfy` maybe False isJust
  destroyedWhileRunning `shouldBe` RootLive
  owner ← threadsOf rig (== InstanceCreated)
  destroyer ← threadsOf rig (== SurfaceDestroyed 102)
  destroyer `shouldBe` owner

testRecoveredDeferred ∷ IO ()
testRecoveredDeferred = do
  base ← newRigOf 3
  let rig = base {rigPortCapacity = Just 1}
  (answer, destroyedWhileRunning) ← runRig rig $ \host control → do
    gate ← newTVarIO False
    scriptNative rig AtQueryDevices (HoldsUntil gate)
    flip finally (atomically (writeTVar gate True)) $ do
      [first, second, third] ← windowsOf host
      one ← handedOver host first RequiredTarget
      atomically (custodyOf (vulkanGraphicsOwner host) (graphicsAttachment one) >>= check . (== Just CustodyOwned))
      _ ← handedOver host second RequiredTarget
      -- The third window's attachment is published, and a cancellation then
      -- loses its answer before the handover hears it; the recovery's
      -- announcement finds the port full.
      raiseAfterAttach rig (toException Cancelled)
      answer ← try @Cancelled (handOverVulkanTarget (vulkanController host) (vulkanWindowHost host) (vulkanGraphicsOwner host) third RequiredTarget)
      Just service ← atomically (windowGraphicsService (vulkanWindowHost host) third)
      _ ← releaseGraphicsTarget (vulkanWindowHost host) (vulkanGraphicsOwner host) service
      atomically (writeTVar gate True)
      pumpUntil host control "the recovered surface's destruction" (elem (SurfaceDestroyed 102) <$> journal rig)
      pumpUntil host control "the recovered attachment's retirement" $
        (== SlotFree) . observedSlot <$> atomically (readGraphicsService service)
      roots ← atomically (readVulkanRoots (vulkanController host))
      pure (either (const "cancelled") (const "answered") answer ∷ String, viewInstance roots)
  answer `shouldBe` "cancelled"
  destroyedWhileRunning `shouldBe` RootLive
  owner ← threadsOf rig (== InstanceCreated)
  destroyer ← threadsOf rig (== SurfaceDestroyed 102)
  destroyer `shouldBe` owner

testDeferredUncertain ∷ IO ()
testDeferredUncertain = do
  base ← newRigOf 3
  let rig = base {rigPortCapacity = Just 1}
  scriptSurface rig 102 DestroyFails
  observed ← newTVarIO Nothing
  outcome ← runRigCaught rig $ \host control → do
    let owner = vulkanGraphicsOwner host
        windows = vulkanWindowHost host
    _ ← superviseGraphicsOwner control owner
    (deferred, gate, _) ← deferredThird rig host
    flip finally (atomically (writeTVar gate True)) $ do
      _ ← releaseGraphicsTarget windows owner deferred
      atomically (writeTVar gate True)
      -- The owner's step reports the failed destruction as its own failure.
      atomically (readOwnerFailure owner >>= check . isJust)
      roots ← atomically (readVulkanRoots (vulkanController host))
      atomically (writeTVar observed (Just (viewInstance roots, graphicsAttachment deferred)))
      -- The uncertain surface retains the instance for good, so the owner can
      -- produce no destruction evidence; only independent evidence lets this
      -- example's exit finish.
      void . forkIO $ do
        atomically (check . null =<< hostPendingAttachments windows)
        publishOwnerDestruction owner (ownerDestroyed "published independently by the example")
      checkRuntime control
  UnannouncedSurfaceUncertain attachment _ ← raisedAs @UnannouncedSurfaceUncertain outcome
  -- It names the deferred attachment, and the instance was still live.
  atomically (readTVar observed) >>= (`shouldBe` Just (RootLive, attachment))
  events ← journal rig
  -- Destroyed once, on the owner's thread, and never again; nothing above it.
  length [() | SurfaceDestroyed 102 ← events] `shouldBe` 1
  [e | e ← events, e `elem` [DeviceDestroyed, MessengerDestroyed, InstanceDestroyed]] `shouldBe` []
  owner ← threadsOf rig (== InstanceCreated)
  destroyer ← threadsOf rig (== SurfaceDestroyed 102)
  destroyer `shouldBe` owner

-- ---------------------------------------------------------------------------
-- Close and exit

testCloseFirst ∷ IO ()
testCloseFirst = do
  rig ← twoWindows
  (roots, secondStanding) ← runRig rig $ \host control → do
    [first, second] ← windowsOf host
    one ← handedOver host first RequiredTarget
    TargetUsable ← awaitStanding host one
    two ← handedOver host second RequiredTarget
    TargetUsable ← awaitStanding host two
    CloseStarted ← closeHostWindow (vulkanWindowHost host) first
    pumpUntil host control "the first window's release" ((`elem` [WindowGone False]) . lastOf <$> journal rig)
    roots ← atomically (readVulkanRoots (vulkanController host))
    standing ← awaitStanding host two
    pure (roots, standing)
  viewDevice roots `shouldBe` RootLive
  viewInstance roots `shouldBe` RootLive
  length (viewTargets roots) `shouldBe` 1
  secondStanding `shouldBe` TargetUsable
  events ← journal rig
  dropWhile (not . destruction) events
    `shouldBe` [ SurfaceDestroyed 100
               , WindowGone False
               , SurfaceDestroyed 101
               , DeviceDestroyed
               , MessengerDestroyed
               , InstanceDestroyed
               , WindowGone True
               , SessionEnded
               ]
  where
    lastOf events = if null events then SessionEnded else last events

testRelease ∷ IO ()
testRelease = do
  rig ← twoWindows
  (answer, recorded, roots) ← runRig rig $ \host _ → do
    [first, second] ← windowsOf host
    one ← handedOver host first RequiredTarget
    TargetUsable ← awaitStanding host one
    two ← handedOver host second RequiredTarget
    TargetUsable ← awaitStanding host two
    answer ← releaseGraphicsTarget (vulkanWindowHost host) (vulkanGraphicsOwner host) one
    _ ← awaitTerminal host one
    -- By the time the terminal record exists, its surface is gone.
    recorded ← journal rig
    roots ← atomically (readVulkanRoots (vulkanController host))
    pure (describeRelease answer, recorded, roots)
  answer `shouldBe` "begun"
  recorded `shouldSatisfy` elem (SurfaceDestroyed 100)
  recorded `shouldSatisfy` notElem DeviceDestroyed
  viewDevice roots `shouldBe` RootLive
  length (viewTargets roots) `shouldBe` 1
  where
    describeRelease = \case
      ReleaseBegun → "begun" ∷ String
      _ → "other"

testExitOrder ∷ IO ()
testExitOrder = do
  rig ← newRig
  runRig rig $ \host _ → do
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    pure ()
  journal rig
    `shouldReturnE` [ InstanceCreated
                    , MessengerCreated
                    , SurfaceCreated 100
                    , DevicesQueried 100
                    , DeviceCreated
                    , SurfaceDestroyed 100
                    , DeviceDestroyed
                    , MessengerDestroyed
                    , InstanceDestroyed
                    , WindowGone True
                    , SessionEnded
                    ]

testPendingDestruction ∷ IO ()
testPendingDestruction = do
  rig ← twoWindows
  gate ← newTVarIO False
  scriptSurface rig 100 (DestroyHolds gate)
  (whilePending, afterwards) ← runRig rig $ \host control →
    flip finally (atomically (writeTVar gate True)) $ do
      [first, second] ← windowsOf host
      one ← handedOver host first RequiredTarget
      TargetUsable ← awaitStanding host one
      two ← handedOver host second RequiredTarget
      TargetUsable ← awaitStanding host two
      _ ← releaseGraphicsTarget (vulkanWindowHost host) (vulkanGraphicsOwner host) one
      awaitEvent rig (SurfaceDestroyStarted 100)
      -- Its destruction has begun and not returned: nothing is certified.
      terminals ← atomically (readTargetTerminalsNow (vulkanGraphicsOwner host))
      observation ← atomically (readGraphicsService one)
      atomically (writeTVar gate True)
      _ ← awaitTerminal host one
      pumpUntil host control "the released attachment's retirement" ((== 1) . length <$> atomically (hostPendingAttachments (vulkanWindowHost host)))
      settled ← atomically (readGraphicsService one)
      pure ((Map.member (graphicsAttachment one) terminals, observedSlot observation), observedSlot settled)
  whilePending `shouldBe` (False, SlotRetiring)
  afterwards `shouldBe` SlotFree

-- ---------------------------------------------------------------------------
-- Device loss

testLossReachesCheckpoint ∷ IO ()
testLossReachesCheckpoint = do
  rig ← newRigOf 3
  gate ← newTVarIO False
  scriptSurface rig 100 (DestroyHolds gate)
  observed ← newTVarIO Nothing
  outcome ← runRigCaught rig $ \host control →
    flip finally (atomically (writeTVar gate True)) $ do
      [first, second, third] ← windowsOf host
      _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
      one ← handedOver host first RequiredTarget
      TargetUsable ← awaitStanding host one
      scriptNative rig AtSupport Loses
      _ ← handedOver host second RequiredTarget
      atomically (readOwnerFailure (vulkanGraphicsOwner host) >>= check . isJust)
      -- Closed at once: the roots admit nothing, the owner takes nothing.
      roots ← atomically (readVulkanRoots (vulkanController host))
      answer ← handOverVulkanTarget (vulkanController host) (vulkanWindowHost host) (vulkanGraphicsOwner host) third RequiredTarget
      model ← atomically (readVulkanModel (vulkanController host))
      -- The owner's drain is holding inside the first surface's destruction,
      -- so retirement is still pending when the checkpoint raises.
      awaitEvent rig (SurfaceDestroyStarted 100)
      atomically (writeTVar observed (Just (viewAdmitting roots, isJust (viewLoss roots), refusedNamingLoss answer, sessionState model)))
      checkRuntime control
  loss ← raisedAs @GraphicsDeviceLost outcome
  lostDuring loss `shouldBe` "vkGetPhysicalDeviceSurfaceSupportKHR"
  atomically (readTVar observed) >>= (`shouldBe` Just (False, True, True, SessionFailed DeviceLost))
  events ← journal rig
  -- Nothing was recreated, and retirement still ran child before parent.
  length [() | DeviceCreated ← events] `shouldBe` 1
  events `shouldSatisfy` isSubsequenceOf [SurfaceDestroyed 100, DeviceDestroyed, MessengerDestroyed, InstanceDestroyed, WindowGone True]
  where
    -- Refused before anything is attached, naming the loss that failed the
    -- session.
    refusedNamingLoss = \case
      VulkanSessionFailed (TerminalDeviceLost loss) → lostDuring loss == "vkGetPhysicalDeviceSurfaceSupportKHR"
      _ → False

testLossWithFailedCleanup ∷ IO ()
testLossWithFailedCleanup = do
  rig ← twoWindows
  scriptSurface rig 100 DestroyFails
  observed ← newTVarIO Nothing
  outcome ← runRigCaught rig $ \host control → do
    [first, second] ← windowsOf host
    let owner = vulkanGraphicsOwner host
    _ ← superviseGraphicsOwner control owner
    one ← handedOver host first RequiredTarget
    TargetUsable ← awaitStanding host one
    scriptNative rig AtSupport Loses
    two ← handedOver host second RequiredTarget
    -- The owner's own drain runs as soon as the loss ends its run: the second
    -- target, whose construction reported the loss, retires cleanly; the
    -- first one's surface destruction fails.
    failures ← atomically $ do
      held ← readOwnerFailures owner
      check (length held >= 2)
      pure [exception | ExceptionWithContext _ exception ← held]
    _ ← awaitTerminal host two
    terminals ← atomically (readTargetTerminalsNow owner)
    roots ← atomically (readVulkanRoots (vulkanController host))
    atomically $
      writeTVar
        observed
        ( Just
            ( map classify failures
            , Map.member (graphicsAttachment one) terminals
            , (viewDevice roots, viewInstance roots)
            )
        )
    -- The failed destruction retains the first attachment, the device and the
    -- instance for good; only independent evidence lets this example's exit
    -- finish, and it is supplied from another thread.
    independently host one
    checkRuntime control
  loss ← raisedAs @GraphicsDeviceLost outcome
  lostDuring loss `shouldBe` "vkGetPhysicalDeviceSurfaceSupportKHR"
  atomically (readTVar observed)
    >>= (`shouldBe` Just (["loss", "surface destruction failed"], False, (RootLive, RootLive)))
  events ← journal rig
  -- Offered once, never again, and nothing above it was destroyed.
  length [() | SurfaceDestroyed 100 ← events] `shouldBe` 1
  [e | e ← events, e `elem` [DeviceDestroyed, MessengerDestroyed, InstanceDestroyed]] `shouldBe` []
  where
    classify failure
      | isJust (fromException failure ∷ Maybe GraphicsDeviceLost) = "loss" ∷ String
      | isJust (fromException failure ∷ Maybe SurfaceDestructionFailed) = "surface destruction failed"
      | otherwise = show failure

-- ---------------------------------------------------------------------------
-- Terminal failure

testValidationStops ∷ IO ()
testValidationStops = do
  rig ← newRigOf 3
  observed ← newTVarIO Nothing
  -- The second target's retirement holds in its surface's destruction until
  -- its standing has been read, so the drain cannot forget it first.
  retiring ← newTVarIO False
  scriptSurface rig 101 (DestroyHolds retiring)
  outcome ← runRigCaught rig $ \host control → do
    [first, second, third] ← windowsOf host
    let owner = vulkanGraphicsOwner host
        controller = vulkanController host
    _ ← superviseGraphicsOwner control owner
    one ← handedOver host first RequiredTarget
    TargetUsable ← awaitStanding host one
    -- The layer reports an error from inside the later target's support
    -- query, which itself returns normally.
    scriptNative rig AtSupport (ReportsError "an injected validation error")
    two ← handedOver host second OptionalTarget
    -- Admitted into a session that had failed by the time admission
    -- returned: the owner owns it and retires it, and it is never usable.
    standing ← awaitStanding host two
    atomically (writeTVar retiring True)
    -- The owner's next checkpoint latches it and ends its run.
    atomically (readOwnerFailure owner >>= check . isJust)
    answer ← handOverVulkanTarget controller (vulkanWindowHost host) owner third RequiredTarget
    report ← atomically (readVulkanTerminal controller)
    atomically (writeTVar observed (Just (standing, refused answer, reportPrimary report, reportDeviceLost report)))
    checkRuntime control
  failure ← raisedAs @GraphicsSessionFailed outcome
  failure `shouldBe` GraphicsSessionFailed TerminalValidationError
  atomically (readTVar observed) >>= (`shouldBe` Just (TargetUnusable True, True, Just TerminalValidationError, Nothing))
  -- Teardown followed the ordinary rules, child before parent.
  events ← journal rig
  events `shouldSatisfy` isSubsequenceOf [SurfaceDestroyed 100, SurfaceDestroyed 101, DeviceDestroyed, MessengerDestroyed, InstanceDestroyed, WindowGone True]
  -- The final verdict, after the last callback, carries the error.
  Just verdict ← atomically (readTVar (rigVerdict rig))
  verdictIssues verdict `shouldSatisfy` elem ErrorLatched
  where
    refused = \case
      VulkanSessionFailed TerminalValidationError → True
      _ → False

testDroppedErrorStops ∷ IO ()
testDroppedErrorStops = do
  base ← twoWindows
  -- One record of room, and a worker that drains only when the lifetime asks
  -- it to: the warning fills the queue and the error finds it full.
  let rig = base {rigCapture = defaultCaptureConfig {captureQueueCapacity = 1, capturePollInterval = 60000000}}
  outcome ← runRigCaught rig $ \host control → do
    [first, second] ← windowsOf host
    let owner = vulkanGraphicsOwner host
    _ ← superviseGraphicsOwner control owner
    scriptNative rig AtQueryDevices (ReportsWarning "a warning that fills the capture's one place")
    one ← handedOver host first RequiredTarget
    TargetUsable ← awaitStanding host one
    scriptNative rig AtSupport (ReportsError "an error whose record finds no room")
    _ ← handedOver host second OptionalTarget
    atomically (readOwnerFailure owner >>= check . isJust)
    checkRuntime control
  failure ← raisedAs @GraphicsSessionFailed outcome
  failure `shouldBe` GraphicsSessionFailed TerminalValidationError
  Just verdict ← atomically (readTVar (rigVerdict rig))
  let counters = statusCounters (verdictStatus verdict)
  (countErrors counters, countDropped counters, countAdmitted counters) `shouldBe` (1, 1, 1)
  verdictIssues verdict `shouldSatisfy` \issues → ErrorLatched `elem` issues && RecordsDropped 1 `elem` issues

testSinkFailure ∷ IO ()
testSinkFailure = do
  rig ← twoWindows
  outcome ← runRigCaught rig $ \host control → do
    [first, second] ← windowsOf host
    let owner = vulkanGraphicsOwner host
    _ ← superviseGraphicsOwner control owner
    failingSink rig
    one ← handedOver host first RequiredTarget
    TargetUsable ← awaitStanding host one
    -- A warning is a diagnostic, not a failure; the sink that cannot take it
    -- is.
    scriptNative rig AtSupport (ReportsWarning "a warning the sink cannot take")
    two ← handedOver host second OptionalTarget
    TargetUsable ← awaitStanding host two
    atomically (sinkHasFailed rig >>= check)
    -- An idle owner learns of it at its next round, which a published scene
    -- gives it; nothing here waits on a clock.
    scene ← prepare ()
    let poke remaining = do
          seen ← statusRounds <$> atomically (readOwnerStatusNow owner)
          _ ← atomically (publishOwnerScene (ownerHandoff owner) scene)
          _ ← atomically (awaitOwnerRound owner seen)
          failed ← atomically (isJust <$> readOwnerFailure owner)
          if failed || remaining <= (0 ∷ Int) then pure () else poke (remaining - 1)
    poke 1000
    checkRuntime control
  failure ← raisedAs @GraphicsSessionFailed outcome
  failure `shouldSatisfy` \case
    GraphicsSessionFailed (TerminalSinkFailed _) → True
    _ → False
  Just verdict ← atomically (readTVar (rigVerdict rig))
  -- The consumer's own terminal status, not a validation error.
  verdictIssues verdict `shouldSatisfy` elem ConsumerUnsuccessful
  verdictIssues verdict `shouldSatisfy` notElem ErrorLatched

testIdleSinkWakes ∷ IO ()
testIdleSinkWakes = do
  rig ← twoWindows
  woke ← newTVarIO Nothing
  outcome ← runRigCaught rig $ \host control → do
    [first, _] ← windowsOf host
    let owner = vulkanGraphicsOwner host
    _ ← superviseGraphicsOwner control owner
    one ← handedOver host first RequiredTarget
    TargetUsable ← awaitStanding host one
    -- The owner is idle, with no deadline. The worker's sink fails on its own
    -- thread, and nothing is published, handed over or closed afterwards.
    failingSink rig
    reportWarningNow rig "a warning the sink cannot take"
    awaitSinkRecorded rig
    -- A generous bound, so a slow machine is not mistaken for an owner that
    -- was never woken; the owner's own failure is what ends the wait.
    expired ← registerDelay 10000000
    failed ← atomically $
      (readOwnerFailure owner >>= check . isJust >> pure True)
        `orElse` (readTVar expired >>= check >> pure False)
    atomically (writeTVar woke (Just failed))
    checkRuntime control
  atomically (readTVar woke) >>= (`shouldBe` Just True)
  failure ← raisedAs @GraphicsSessionFailed outcome
  failure `shouldSatisfy` \case
    GraphicsSessionFailed (TerminalSinkFailed _) → True
    _ → False

testSinkThenError ∷ IO ()
testSinkThenError = do
  rig ← twoWindows
  gate ← newTVarIO False
  observed ← newTVarIO Nothing
  outcome ← runRigCaught rig $ \host control → do
    [first, second] ← windowsOf host
    let owner = vulkanGraphicsOwner host
    _ ← superviseGraphicsOwner control owner
    one ← handedOver host first RequiredTarget
    TargetUsable ← awaitStanding host one
    -- The owner is busy inside the second target's support query, so nothing
    -- it does reads the capture meanwhile. The sink fails on a warning, and
    -- only then does an error arrive: both are pending when it next checks.
    scriptNative rig AtSupport (HoldsUntil gate)
    _ ← handedOver host second OptionalTarget
    awaitHeld rig AtSupport
    failingSink rig
    reportWarningNow rig "a warning the sink cannot take"
    awaitSinkRecorded rig
    reportErrorNow rig "an error after the sink failed"
    atomically (writeTVar gate True)
    atomically (readOwnerFailure owner >>= check . isJust)
    atomically (readVulkanTerminal (vulkanController host) >>= writeTVar observed . Just)
    checkRuntime control
  failure ← raisedAs @GraphicsSessionFailed outcome
  failure `shouldSatisfy` \case
    GraphicsSessionFailed (TerminalSinkFailed _) → True
    _ → False
  Just report ← atomically (readTVar observed)
  reportPrimary report `shouldSatisfy` \case
    Just (TerminalSinkFailed _) → True
    _ → False
  reportEvidence report `shouldBe` [LaterFailure TerminalValidationError]

testClaimedSinkPending ∷ IO ()
testClaimedSinkPending = do
  rig ← twoWindows
  observed ← newTVarIO Nothing
  outcome ← runRigCaught rig $ \host control → do
    [first, second] ← windowsOf host
    let owner = vulkanGraphicsOwner host
        controller = vulkanController host
    _ ← superviseGraphicsOwner control owner
    one ← handedOver host first RequiredTarget
    TargetUsable ← awaitStanding host one
    -- The worker's sink has claimed the order and not yet published its
    -- failure when an error arrives: which came first is not yet readable.
    claimSinkFirst rig
    reportErrorNow rig "an error after the sink claimed the order"
    during ← handOverVulkanTarget controller (vulkanWindowHost host) owner second RequiredTarget
    pending ← atomically (readVulkanTerminal controller)
    -- The sink's failure is then published: the next handover names it as
    -- the primary, with the error beside it.
    failingSink rig
    reportWarningNow rig "a warning the sink cannot take"
    awaitSinkRecorded rig
    after ← handOverVulkanTarget controller (vulkanWindowHost host) owner second RequiredTarget
    settled ← atomically (readVulkanTerminal controller)
    atomically (writeTVar observed (Just (handoverKind during, reportPrimary pending, handoverKind after, reportPrimary settled, reportEvidence settled)))
    -- The owner's own step takes the failure the handover latched, on the
    -- round its wake asks for; the application's checkpoint then raises it.
    atomically (readOwnerFailure owner >>= check . isJust)
    checkRuntime control
  _ ← raisedAs @GraphicsSessionFailed outcome
  Just (during, pendingPrimary, after, primary, evidence) ← atomically (readTVar observed)
  (during, pendingPrimary) `shouldBe` ("pending", Nothing)
  after `shouldBe` "sink failed"
  primary `shouldSatisfy` \case
    Just (TerminalSinkFailed _) → True
    _ → False
  evidence `shouldBe` [LaterFailure TerminalValidationError]
  -- Nothing was attached for the second window.
  events ← journal rig
  length [() | SurfaceCreated 101 ← events] `shouldBe` 0
  where
    handoverKind = \case
      VulkanDiagnosticPending → "pending" ∷ String
      VulkanSessionFailed (TerminalSinkFailed _) → "sink failed"
      other → show other

testQueuedConstructionStops ∷ IO ()
testQueuedConstructionStops = do
  rig ← twoWindows
  gate ← newTVarIO False
  observed ← newTVarIO Nothing
  -- The second window's surface is still being created on the main thread,
  -- after its handover's own checkpoint found nothing, when a layer reports
  -- an error; the owner is idle, so the handover's announcement is what wakes
  -- it, and its round constructs before its step checks anything.
  scriptSurface rig 101 (CreateHolds gate)
  outcome ← runRigCaught rig $ \host control → do
    [first, second] ← windowsOf host
    let owner = vulkanGraphicsOwner host
        controller = vulkanController host
    _ ← superviseGraphicsOwner control owner
    one ← handedOver host first RequiredTarget
    TargetUsable ← awaitStanding host one
    void . forkIO $ do
      atomically (creationsBegun rig >>= check . (>= 2))
      reportErrorNow rig "an error while a handover is under way"
      atomically (writeTVar gate True)
    two ← handedOver host second OptionalTarget
    -- The owner forgets a verified rollback at once, so its rejection is read
    -- from the controller; a target admitted instead makes its support query,
    -- which answers too rather than being waited past.
    settled ← atomically $
      (Left <$> (readTargetRejection controller (graphicsAttachment two) >>= maybe retry pure))
        `orElse` (Right () <$ (journalHas rig (SupportQueried 101) >>= check))
    report ← atomically (readVulkanTerminal controller)
    atomically (writeTVar observed (Just (either rejected (const False) settled, reportPrimary report)))
    checkRuntime control
  failure ← raisedAs @GraphicsSessionFailed outcome
  failure `shouldBe` GraphicsSessionFailed TerminalValidationError
  -- Never admitted: its surface destroyed and its rollback verified, with no
  -- native call made for it.
  atomically (readTVar observed) >>= (`shouldBe` Just (True, Just TerminalValidationError))
  events ← journal rig
  [e | e@(SupportQueried 101) ← events] `shouldBe` []
  length [() | SurfaceDestroyed 101 ← events] `shouldBe` 1
  where
    rejected = \case
      RejectedSessionFailed TerminalValidationError → True
      _ → False

testRetentionReported ∷ IO ()
testRetentionReported = do
  rig ← twoWindows
  scriptSurface rig 100 DestroyFails
  controllerOf ← newTVarIO Nothing
  _ ← runRigCaught rig $ \host _ → do
    [first, _] ← windowsOf host
    atomically (writeTVar controllerOf (Just (vulkanController host)))
    one ← handedOver host first RequiredTarget
    TargetUsable ← awaitStanding host one
    -- The exit cannot destroy this surface; only independent evidence lets it
    -- finish, and it is supplied from another thread.
    independently host one
  Just controller ← atomically (readTVar controllerOf)
  report ← atomically (readVulkanTerminal controller)
  reportPrimary report `shouldSatisfy` \case
    Just (TerminalCleanupFailed _) → True
    _ → False
  -- The surface, and everything above it, retained and said to be.
  length [() | RetainedUnverified _ ← reportEvidence report] `shouldSatisfy` (>= 2)
  events ← journal rig
  [e | e ← events, e `elem` [DeviceDestroyed, MessengerDestroyed, InstanceDestroyed]] `shouldBe` []

testCancelledAfterLoss ∷ IO ()
testCancelledAfterLoss = do
  rig ← twoWindows
  gate ← newTVarIO False
  scriptSurface rig 100 (DestroyHolds gate)
  returned ← newTVarIO False
  controllerOf ← newTVarIO Nothing
  outcome ← runRigCaught rig $ \host _ → do
    [first, second] ← windowsOf host
    let owner = vulkanGraphicsOwner host
    atomically (writeTVar controllerOf (Just (vulkanController host)))
    one ← handedOver host first RequiredTarget
    TargetUsable ← awaitStanding host one
    scriptNative rig AtSupport Loses
    _ ← handedOver host second RequiredTarget
    atomically (readOwnerFailure owner >>= check . isJust)
    -- The owner's drain is holding inside the first surface's destruction.
    awaitEvent rig (SurfaceDestroyStarted 100)
    main ← myThreadId
    -- Once the body has returned and the main thread is waiting for the
    -- owner, three cancellations are aimed at it before the drain goes on.
    void . forkIO $ do
      atomically (readTVar returned >>= check)
      awaitBlocked main
      replicateM_ 3 (throwTo main Cancelled)
      atomically (writeTVar gate True)
    atomically (writeTVar returned True)
  _ ← either pure (\_ → failWith "the run returned although it was cancelled and its owner failed") outcome
  events ← journal rig
  dropWhile (not . destruction) events
    `shouldBe` [ SurfaceDestroyed 100
               , SurfaceDestroyed 101
               , DeviceDestroyed
               , MessengerDestroyed
               , InstanceDestroyed
               , WindowGone True
               , WindowGone True
               , SessionEnded
               ]
  Just controller ← atomically (readTVar controllerOf)
  report ← atomically (readVulkanTerminal controller)
  reportPrimary report `shouldSatisfy` \case
    Just (TerminalDeviceLost _) → True
    _ → False
  where
    awaitBlocked thread =
      threadStatus thread >>= \case
        ThreadBlocked _ → pure ()
        ThreadFinished → pure ()
        _ → yield >> awaitBlocked thread

testLateSurfaceFails ∷ IO ()
testLateSurfaceFails = do
  rig ← twoWindows
  gate ← newTVarIO False
  -- The second window's surface is still in its native call when the owner's
  -- drain closes the lease, and its destruction then fails.
  scriptSurface rig 101 (CreateHolds gate)
  scriptSurface rig 101 DestroyFails
  controllerOf ← newTVarIO Nothing
  _ ← runRigCaught rig $ \host _ → do
    [first, second] ← windowsOf host
    let owner = vulkanGraphicsOwner host
    atomically (writeTVar controllerOf (Just (vulkanController host)))
    one ← handedOver host first RequiredTarget
    TargetUsable ← awaitStanding host one
    scene ← prepare ()
    -- While the main thread is inside the second surface's creation, a layer
    -- reports an error; the owner learns of it at its next round and its
    -- drain retires the first target and the device, then waits for the
    -- creation still in flight before it destroys what it left.
    void . forkIO $ do
      atomically (creationsBegun rig >>= check . (>= 2))
      reportErrorNow rig "an error while a surface is being created"
      -- A newer scene wakes the owner; one publication that lands just as
      -- the owner settles into its wait may not, so the example publishes
      -- again, a bounded number of times, until the failure is latched. The
      -- short wait between publications only paces them: whether the owner
      -- failed is read from its latch.
      let poke remaining = do
            _ ← atomically (publishOwnerScene (ownerHandoff owner) scene)
            paced ← registerDelay 20000
            failed ← atomically $
              (readOwnerFailure owner >>= check . isJust >> pure True)
                `orElse` (readTVar paced >>= check >> pure False)
            if failed || remaining <= (0 ∷ Int) then pure () else poke (remaining - 1)
      poke 500
      awaitEvent rig DeviceDestroyed
      atomically (writeTVar gate True)
    -- The owner's port has closed by the time the creation returns, so the
    -- main thread settles this attachment itself. Nothing the owner produced
    -- lets the instance go: independent evidence of the owner's destruction
    -- ends the exit, once no attachment is pending.
    _ ← handOverVulkanTarget (vulkanController host) (vulkanWindowHost host) owner second RequiredTarget
    void . forkIO $ do
      atomically (check . null =<< hostPendingAttachments (vulkanWindowHost host))
      publishOwnerDestruction owner (ownerDestroyed "published independently by the example")
  Just controller ← atomically (readTVar controllerOf)
  report ← atomically (readVulkanTerminal controller)
  reportPrimary report `shouldBe` Just TerminalValidationError
  reportEvidence report `shouldSatisfy` any (\case LaterFailure (TerminalCleanupFailed _) → True; _ → False)
  events ← journal rig
  length [() | SurfaceDestroyed 101 ← events] `shouldBe` 1
  [e | e ← events, e `elem` [MessengerDestroyed, InstanceDestroyed]] `shouldBe` []

testSeveralDischargesFail ∷ IO ()
testSeveralDischargesFail = do
  base ← newRigOf 4
  let rig = base {rigPortCapacity = Just 1}
  -- Both deferred windows' surfaces fail their destruction.
  scriptSurface rig 102 DestroyFails
  scriptSurface rig 103 DestroyFails
  controllerOf ← newTVarIO Nothing
  _ ← runRigCaught rig $ \host _ → do
    let owner = vulkanGraphicsOwner host
        windows = vulkanWindowHost host
    atomically (writeTVar controllerOf (Just (vulkanController host)))
    -- The owner holds inside the first construction while the second
    -- attachment fills its port, so the third and fourth are deferred.
    gate ← newTVarIO False
    scriptNative rig AtQueryDevices (HoldsUntil gate)
    [first, second, third, fourth] ← windowsOf host
    one ← handedOver host first RequiredTarget
    atomically (custodyOf owner (graphicsAttachment one) >>= check . (== Just CustodyOwned))
    _ ← handedOver host second RequiredTarget
    forM_ [third, fourth] $ \window →
      handOverVulkanTarget (vulkanController host) windows owner window RequiredTarget >>= \case
        VulkanAnnouncementDeferred _ → pure ()
        other → failWith ("a window was not deferred: " <> show other)
    atomically (writeTVar gate True)
    -- Neither failed surface lets the instance go: independent evidence of
    -- the owner's destruction ends the exit, once no attachment is pending.
    void . forkIO $ do
      atomically (check . null =<< hostPendingAttachments windows)
      publishOwnerDestruction owner (ownerDestroyed "published independently by the example")
  Just controller ← atomically (readTVar controllerOf)
  report ← atomically (readVulkanTerminal controller)
  let cleanups = [reason | Just (TerminalCleanupFailed reason) ← [reportPrimary report]] <> [reason | LaterFailure (TerminalCleanupFailed reason) ← reportEvidence report]
      naming handle = filter (Data.Text.isInfixOf ("surface " <> handle <> " ")) cleanups
  -- One cleanup failure for each surface, each naming it and what its own
  -- destruction raised, however many passes found it still owed.
  (length (naming "0x66"), length (naming "0x67")) `shouldBe` (1, 1)
  (naming "0x66" <> naming "0x67") `shouldSatisfy` all (Data.Text.isInfixOf "scripted")
  events ← journal rig
  [length [() | SurfaceDestroyed n ← events, n == handle] | handle ← [102, 103]] `shouldBe` [1, 1]
  [e | e ← events, e `elem` [MessengerDestroyed, InstanceDestroyed]] `shouldBe` []

testReusedHandleFails ∷ IO ()
testReusedHandleFails = do
  base ← newRigOf 4
  let rig = base {rigPortCapacity = Just 1}
  -- The fourth window's surface reuses the third's handle, and both
  -- destructions fail: two distinct obligations, one handle.
  scriptSurface rig 102 DestroyFails
  scriptSurface rig 103 (CreateReusing 102)
  scriptSurface rig 103 DestroyFails
  controllerOf ← newTVarIO Nothing
  _ ← runRigCaught rig $ \host _ → do
    let owner = vulkanGraphicsOwner host
        windows = vulkanWindowHost host
    atomically (writeTVar controllerOf (Just (vulkanController host)))
    -- The owner holds inside the first construction while the second
    -- attachment fills its port, so the third and fourth are deferred.
    gate ← newTVarIO False
    scriptNative rig AtQueryDevices (HoldsUntil gate)
    [first, second, third, fourth] ← windowsOf host
    one ← handedOver host first RequiredTarget
    atomically (custodyOf owner (graphicsAttachment one) >>= check . (== Just CustodyOwned))
    _ ← handedOver host second RequiredTarget
    forM_ [third, fourth] $ \window →
      handOverVulkanTarget (vulkanController host) windows owner window RequiredTarget >>= \case
        VulkanAnnouncementDeferred _ → pure ()
        other → failWith ("a window was not deferred: " <> show other)
    atomically (writeTVar gate True)
    -- Neither failed surface lets the instance go: independent evidence of
    -- the owner's destruction ends the exit, once no attachment is pending.
    void . forkIO $ do
      atomically (check . null =<< hostPendingAttachments windows)
      publishOwnerDestruction owner (ownerDestroyed "published independently by the example")
  Just controller ← atomically (readTVar controllerOf)
  report ← atomically (readVulkanTerminal controller)
  let cleanups = [reason | Just (TerminalCleanupFailed reason) ← [reportPrimary report]] <> [reason | LaterFailure (TerminalCleanupFailed reason) ← reportEvidence report]
      naming handle = filter (Data.Text.isInfixOf ("surface " <> handle <> " ")) cleanups
      of' window = filter (Data.Text.isInfixOf ("(WindowId " <> window <> ")")) (naming "0x66")
  -- One cleanup failure for each obligation, each naming the shared handle,
  -- its own attachment and what its own destruction raised.
  (length (naming "0x66"), length (of' "3"), length (of' "4")) `shouldBe` (2, 1, 1)
  naming "0x66" `shouldSatisfy` all (Data.Text.isInfixOf "scripted")
  events ← journal rig
  length [() | SurfaceDestroyed 102 ← events] `shouldBe` 2
  [e | e ← events, e `elem` [MessengerDestroyed, InstanceDestroyed]] `shouldBe` []

-- | Publish, from another thread, the evidence the owner could not produce:
-- this attachment's facts once it is retiring, and the owner's destruction
-- once nothing else is pending. It establishes nothing about the stand-in's
-- objects, and exists only so a retaining exit can end.
independently ∷ VulkanHost Scene → GraphicsService → IO ()
independently host service = do
  let owner = vulkanGraphicsOwner host
      windows = vulkanWindowHost host
  Just publisher ← pure (hostGraphicsPublisher windows)
  Just acknowledgement ← atomically (ownerTargetAcknowledgement owner (graphicsAttachment service))
  void . forkIO $ do
    atomically (readGraphicsService service >>= check . (== SlotRetiring) . observedSlot)
    forM_ allRetirementFacts $ \fact →
      void (publishCompletion publisher (completionNotice (graphicsAttachment service) acknowledgement fact))
    atomically (check . null =<< hostPendingAttachments windows)
    publishOwnerDestruction owner (ownerDestroyed "published independently by the example")

testUnknownOutcome ∷ IO ()
testUnknownOutcome = do
  rig ← twoWindows
  observed ← newTVarIO Nothing
  outcome ← runRigCaught rig $ \host _ → do
    [first, second] ← windowsOf host
    one ← handedOver host first RequiredTarget
    TargetUsable ← awaitStanding host one
    scriptNative rig AtSupport Fails
    _ ← handedOver host second RequiredTarget
    atomically (readOwnerFailure (vulkanGraphicsOwner host) >>= check . isJust)
    roots ← atomically (readVulkanRoots (vulkanController host))
    model ← atomically (readVulkanModel (vulkanController host))
    atomically (writeTVar observed (Just (isNothing (viewLoss roots), sessionState model)))
    ownerEnded host
  _ ← raisedAs @StandInFailure outcome
  atomically (readTVar observed) >>= (`shouldBe` Just (True, SessionRunning))

-- ---------------------------------------------------------------------------
-- Progress

testNoDemand ∷ IO ()
testNoDemand = do
  rig ← newRig
  status ← runRig rig $ \host _ → do
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    -- Once the round that constructed the target has completed, the owner
    -- names no deadline of its own. A round that ran while the handover's
    -- announcement was being watched names the watch's brief poll, and the
    -- round that poll takes clears it; nothing the owner holds wants another.
    let settle seen remaining = do
          status ← atomically (awaitOwnerRound (vulkanGraphicsOwner host) seen)
          if isNothing (statusNextDeadline status) || remaining <= (0 ∷ Int)
            then pure status
            else settle (statusRounds status) (remaining - 1)
    settle 0 5
  statusNextDeadline status `shouldBe` Nothing
  statusAdvanced status `shouldBe` 0
  statusImmediate status `shouldBe` False

-- ---------------------------------------------------------------------------
-- Swapchain generations

testGenerationBuilt ∷ IO ()
testGenerationBuilt = do
  rig ← visibleRig
  mainThread ← newTVarIO Nothing
  view ← runRig rig $ \host control → do
    myThreadId >>= atomically . writeTVar mainThread . Just
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    publishObservation host service window
    pumpUntil host control "the first generation" (presenting host service)
    atomically (readVulkanGenerations (vulkanController host) (graphicsAttachment service))
  fmap viewCondition view `shouldBe` Just Presenting
  events ← journal rig
  -- Built on the target's admission, and destroyed, child before parent, by
  -- the host's exit.
  filter generational events
    `shouldBe` [ SwapchainCreated 500 (640, 480) Nothing
               , ViewCreated 501
               , ViewCreated 502
               , ViewCreated 503
               , ViewDestroyed 503
               , ViewDestroyed 502
               , ViewDestroyed 501
               , SwapchainDestroyed 500
               ]
  Just main ← atomically (readTVar mainThread)
  owners ← threadsOf rig (== InstanceCreated)
  built ← threadsOf rig generational
  built `shouldSatisfy` all (`elem` owners)
  built `shouldSatisfy` all (/= main)

testGenerationReplaced ∷ IO ()
testGenerationReplaced = do
  rig ← visibleRig
  (retainedWhileHeld, events) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    publishObservation host service window
    pumpUntil host control "the first generation" (presenting host service)
    Just first ← (>>= viewActive) <$> atomically (readVulkanGenerations (vulkanController host) (graphicsAttachment service))
    held ← atomically (useVulkanGeneration (vulkanController host) first) >>= either (throwIO . userError . show) pure
    resizeFramebuffer rig host window (800, 600)
    pumpUntil host control "the resize's observation" (observedFramebuffer host window (800, 600))
    publishObservation host service window
    pumpUntil host control "the replacement" (elem (SwapchainCreated 504 (800, 600) (Just 500)) <$> journal rig)
    -- The owner keeps taking rounds while the old generation is held; none
    -- destroys it.
    pumpUntil host control "a later owner round" $ do
      status ← atomically (readOwnerStatusNow (vulkanGraphicsOwner host))
      pure (statusAdvanced status > 0)
    retained ← notElem (SwapchainDestroyed 500) <$> journal rig
    atomically (endVulkanGenerationUse (vulkanController host) held)
    pumpUntil host control "the old generation's destruction" (elem (SwapchainDestroyed 500) <$> journal rig)
    (,) retained <$> journal rig
  retainedWhileHeld `shouldBe` True
  filter generational events
    `shouldBe` [ SwapchainCreated 500 (640, 480) Nothing
               , ViewCreated 501
               , ViewCreated 502
               , ViewCreated 503
               , SwapchainCreated 504 (800, 600) (Just 500)
               , ViewCreated 505
               , ViewCreated 506
               , ViewCreated 507
               , ViewDestroyed 503
               , ViewDestroyed 502
               , ViewDestroyed 501
               , SwapchainDestroyed 500
               ]

testHiddenSuspended ∷ IO ()
testHiddenSuspended = do
  rig ← newRig
  view ← runRig rig $ \host _ → do
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    -- The target is usable once its construction settled, and its
    -- generations are reconciled in that round's step, which follows it.
    atomically $
      readVulkanGenerations (vulkanController host) (graphicsAttachment service) >>= \case
        Just generations | viewCondition generations /= AwaitingGeneration → pure (Just generations)
        _ → retry
  fmap viewCondition view `shouldSatisfy` \case
    Just (Suspended (SuspendedIneligible _)) → True
    _ → False
  filter generational <$> journal rig >>= (`shouldBe` [])

testGenerationClosed ∷ IO ()
testGenerationClosed = do
  rig ← visibleRig
  _ ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    publishObservation host service window
    pumpUntil host control "the first generation" (presenting host service)
    CloseStarted ← closeHostWindow (vulkanWindowHost host) window
    pumpUntil host control "the window's release" (elem (WindowGone False) <$> journal rig)
  events ← journal rig
  takeWhile (/= WindowGone False) (dropWhile (not . closing) events)
    `shouldBe` [ViewDestroyed 503, ViewDestroyed 502, ViewDestroyed 501, SwapchainDestroyed 500, SurfaceDestroyed 100]
  where
    closing = \case
      ViewDestroyed _ → True
      _ → False

testSurfaceReplaced ∷ IO ()
testSurfaceReplaced = do
  rig ← visibleRigOf 2
  mainThread ← newTVarIO Nothing
  (before, after, secondSwapchain, attempts) ← runRig rig $ \host control → do
    myThreadId >>= atomically . writeTVar mainThread . Just
    let controller = vulkanController host
    [first, second] ← windowsOf host
    one ← handedOver host first RequiredTarget
    two ← handedOver host second RequiredTarget
    TargetUsable ← awaitStanding host one
    TargetUsable ← awaitStanding host two
    publishObservation host one first
    publishObservation host two second
    pumpUntil host control "both generations" ((&&) <$> presenting host one <*> presenting host two)
    before ← atomically (readVulkanTargets controller)
    secondSwapchain ← activeSwapchain host two
    loseSurfaceOf rig host one first
    pumpReplacing host control "the replacement's generation" $ do
      targets ← atomically (readVulkanTargets controller)
      ready ← presenting host one
      pure (ready && surfaceOf one targets == [102])
    after ← atomically (readVulkanTargets controller)
    model ← atomically (readVulkanModel controller)
    let attempts = [viewTargetRecoveryAttempts view | (attachment, target) ← after, attachment == graphicsAttachment one, Just view ← [targetView (targetViewIdentity target) model]]
    pure (before, after, secondSwapchain, attempts)
  -- The same attachments and the same targets, one on its new surface.
  map identities after `shouldBe` map identities before
  map (targetViewSurface . snd) before `shouldBe` [100, 101]
  map (targetViewSurface . snd) after `shouldBe` [102, 101]
  attempts `shouldBe` [1]
  events ← journal rig
  let recovery = dropWhile (/= SurfaceDestroyed 100) events
  -- The lost surface went only after its generation, and the replacement was
  -- created, checked against the one device and built on, in that order.
  takeWhile (/= SurfaceDestroyed 100) events `shouldSatisfy` any isSwapchainDestroyed
  recovery `shouldSatisfy` isSubsequenceOf [SurfaceDestroyed 100, SurfaceCreated 102, SupportQueried 102]
  [() | SwapchainCreated _ _ Nothing ← dropWhile (/= SupportQueried 102) recovery] `shouldSatisfy` (not . null)
  -- Until the replacement was built, the other target's generation was left
  -- alone and no window went.
  let untilRebuilt = takeWhile (\case SwapchainCreated _ _ Nothing → False; _ → True) (dropWhile (/= SupportQueried 102) recovery)
  takeWhile (/= SupportQueried 102) recovery <> untilRebuilt `shouldSatisfy` all (\event → event /= SwapchainDestroyed secondSwapchain && not (isWindowGone event))
  length [() | DeviceCreated ← events] `shouldBe` 1
  Just main ← atomically (readTVar mainThread)
  owners ← threadsOf rig (== InstanceCreated)
  threadsOf rig (== SurfaceCreated 102) >>= (`shouldBe` [main])
  threadsOf rig (`elem` [SurfaceDestroyed 100, SupportQueried 102]) >>= (`shouldSatisfy` all (`elem` owners))
  where
    identities (attachment, view) = (attachment, targetViewIdentity view)
    surfaceOf service targets = [targetViewSurface view | (attachment, view) ← targets, attachment == graphicsAttachment service]

testReplacementAfterClose ∷ IO ()
testReplacementAfterClose = do
  rig ← visibleRig
  _ ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    publishObservation host service window
    pumpUntil host control "the first generation" (presenting host service)
    loseSurfaceOf rig host service window
    -- The owner asks, and the main thread closes the window before it
    -- creates anything.
    pumpUntil host control "the request" (conditionOf host service (== Just SurfaceReplacing))
    CloseStarted ← closeHostWindow (vulkanWindowHost host) window
    pumpReplacing host control "the window's release" (elem (WindowGone False) <$> journal rig)
  events ← journal rig
  [surface | SurfaceCreated surface ← events] `shouldBe` [100]
  [surface | SurfaceDestroyed surface ← events] `shouldBe` [100]

testOptionalSpent ∷ IO ()
testOptionalSpent = do
  rig ← visibleRigOf 2
  forM_ [102, 103, 104] $ \surface → scriptSurface rig surface CreateFails
  (unavailable, stillPresenting, failure) ← runRig rig $ \host control → do
    [first, second] ← windowsOf host
    one ← handedOver host first OptionalTarget
    two ← handedOver host second RequiredTarget
    TargetUsable ← awaitStanding host one
    TargetUsable ← awaitStanding host two
    publishObservation host one first
    publishObservation host two second
    pumpUntil host control "both generations" ((&&) <$> presenting host one <*> presenting host two)
    loseSurfaceOf rig host one first
    pumpReplacing host control "the report" (isJust <$> atomically (readVulkanUnavailability (vulkanController host) (graphicsAttachment one)))
    (,,)
      <$> atomically (readVulkanUnavailability (vulkanController host) (graphicsAttachment one))
      <*> presenting host two
      <*> atomically (readOwnerFailure (vulkanGraphicsOwner host))
  fmap unavailableBecause unavailable `shouldBe` Just UnavailableRecoverySpent
  stillPresenting `shouldBe` True
  isNothing failure `shouldBe` True
  events ← journal rig
  -- Three replacements were asked for, and none was created.
  [surface | SurfaceCreated surface ← events] `shouldBe` [100, 101]

testRequiredSpent ∷ IO ()
testRequiredSpent = do
  rig ← visibleRig
  forM_ [101, 102, 103] $ \surface → scriptSurface rig surface CreateFails
  outcome ← runRigCaught rig $ \host control → do
    [window] ← windowsOf host
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    publishObservation host service window
    pumpUntil host control "the first generation" (presenting host service)
    loseSurfaceOf rig host service window
    pumpReplacing host control "the owner's failure" (isJust <$> atomically (readOwnerFailure (vulkanGraphicsOwner host)))
    checkRuntime control
  VulkanRequiredTargetFailed failed ← raisedAs @VulkanRequiredTargetFailed outcome
  length failed `shouldBe` 1

testUnsupportedOptional ∷ IO ()
testUnsupportedOptional = do
  rig ← visibleRigOf 2
  declareUnsupported rig 102
  (unavailable, stillPresenting) ← runRig rig $ \host control → do
    [first, second] ← windowsOf host
    one ← handedOver host first OptionalTarget
    two ← handedOver host second RequiredTarget
    TargetUsable ← awaitStanding host one
    TargetUsable ← awaitStanding host two
    publishObservation host one first
    publishObservation host two second
    pumpUntil host control "both generations" ((&&) <$> presenting host one <*> presenting host two)
    loseSurfaceOf rig host one first
    pumpReplacing host control "the report" (isJust <$> atomically (readVulkanUnavailability (vulkanController host) (graphicsAttachment one)))
    (,) <$> atomically (readVulkanUnavailability (vulkanController host) (graphicsAttachment one)) <*> presenting host two
  fmap unavailableBecause unavailable `shouldBe` Just (UnavailableSurfaceUnsupported 0)
  stillPresenting `shouldBe` True
  events ← journal rig
  length [() | DeviceCreated ← events] `shouldBe` 1
  -- The surface the device cannot present to was destroyed at once, on the
  -- owner's thread, and never installed; the window stayed until the exit.
  dropWhile (/= SupportQueried 102) events `shouldSatisfy` isSubsequenceOf [SupportQueried 102, SurfaceDestroyed 102]
  owners ← threadsOf rig (== InstanceCreated)
  threadsOf rig (== SurfaceDestroyed 102) >>= (`shouldSatisfy` all (`elem` owners))
  takeWhile (/= SurfaceDestroyed 102) events `shouldSatisfy` (not . any isWindowGone)

testUnsupportedRequired ∷ IO ()
testUnsupportedRequired = do
  rig ← visibleRig
  declareUnsupported rig 101
  outcome ← runRigCaught rig $ \host control → do
    [window] ← windowsOf host
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    publishObservation host service window
    pumpUntil host control "the first generation" (presenting host service)
    loseSurfaceOf rig host service window
    pumpReplacing host control "the owner's failure" (isJust <$> atomically (readOwnerFailure (vulkanGraphicsOwner host)))
    checkRuntime control
  _ ← raisedAs @VulkanRequiredTargetFailed outcome
  events ← journal rig
  length [() | DeviceCreated ← events] `shouldBe` 1

testResizeVersusFailure ∷ IO ()
testResizeVersusFailure = do
  rig ← visibleRig
  (afterResize, afterFailures) ← runRig rig $ \host control → do
    let controller = vulkanController host
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    publishObservation host service window
    pumpUntil host control "the first generation" (presenting host service)
    resizeFramebuffer rig host window (800, 600)
    pumpUntil host control "the resize's observation" (observedFramebuffer host window (800, 600))
    publishObservation host service window
    pumpUntil host control "the replacement" (elem (SwapchainCreated 504 (800, 600) (Just 500)) <$> journal rig)
    resized ← attemptsOf host service
    forM_ [508, 512] $ \expected → do
      Just active ← (>>= viewActive) <$> atomically (readVulkanGenerations controller (graphicsAttachment service))
      _ ← atomically (noteVulkanSwapchainResult controller active SwapchainOutOfDate)
      nudgeOwner rig host service window
      pumpUntil host control "the recovery rebuild" (any (\case SwapchainCreated handle _ _ → handle == expected; _ → False) <$> journal rig)
    (,) resized <$> attemptsOf host service
  afterResize `shouldBe` Just 0
  afterFailures `shouldBe` Just 2

-- | Report the target's active generation's surface lost, as an acquisition
-- or a presentation on the owner's thread would, and take the owner a round.
loseSurfaceOf ∷ Rig → VulkanHost Scene → GraphicsService → WindowId → IO ()
loseSurfaceOf rig host service window = do
  Just active ← (>>= viewActive) <$> atomically (readVulkanGenerations (vulkanController host) (graphicsAttachment service))
  atomically (noteVulkanSwapchainResult (vulkanController host) active SwapchainSurfaceLost) >>= \case
    True → pure ()
    False → failWith "the loss was not recorded against the active generation"
  nudgeOwner rig host service window

-- | 'pumpUntil', creating on each turn any replacement surface the owner asked
-- for, as an application's loop does until VK-16's adapter does it.
pumpReplacing ∷ VulkanHost Scene → RuntimeControl → String → IO Bool → IO ()
pumpReplacing host control what ready =
  pumpUntil host control what (replaceVulkanSurfaces (vulkanController host) (vulkanWindowHost host) (vulkanGraphicsOwner host) >> ready)

conditionOf ∷ VulkanHost Scene → GraphicsService → (Maybe TargetCondition → Bool) → IO Bool
conditionOf host service wanted =
  wanted . fmap viewCondition <$> atomically (readVulkanGenerations (vulkanController host) (graphicsAttachment service))

activeSwapchain ∷ VulkanHost Scene → GraphicsService → IO Word64
activeSwapchain host service = do
  Just view ← atomically (readVulkanGenerations (vulkanController host) (graphicsAttachment service))
  case [swapchain | generation ← viewGenerations view, Just (viewGeneration generation) == viewActive view, Just swapchain ← [viewSwapchain generation]] of
    swapchain : _ → pure swapchain
    [] → failWith "the target has no active swapchain"

attemptsOf ∷ VulkanHost Scene → GraphicsService → IO (Maybe Natural)
attemptsOf host service = atomically $ do
  targets ← readVulkanTargets (vulkanController host)
  model ← readVulkanModel (vulkanController host)
  pure $ case [targetViewIdentity view | (attachment, view) ← targets, attachment == graphicsAttachment service] of
    target : _ → viewTargetRecoveryAttempts <$> targetView target model
    [] → Nothing

isSwapchainDestroyed ∷ Event → Bool
isSwapchainDestroyed = \case
  SwapchainDestroyed _ → True
  _ → False

isWindowGone ∷ Event → Bool
isWindowGone = \case
  WindowGone _ → True
  _ → False

-- | Whether the window's latest observation reports this framebuffer.
observedFramebuffer ∷ VulkanHost Scene → WindowId → (Int, Int) → IO Bool
observedFramebuffer host window (width, height) =
  atomically (hostWindowClient (vulkanWindowHost host) window) >>= \case
    Nothing → pure False
    Just client → do
      observation ← preparedValue . observedValue <$> atomically (readSnapshot (clientObservations client))
      pure (observedFramebufferExtent observation == Observed (Extent width height))

presenting ∷ VulkanHost Scene → GraphicsService → IO Bool
presenting host service =
  atomically $
    maybe False ((== Presenting) . viewCondition) <$> readVulkanGenerations (vulkanController host) (graphicsAttachment service)

generational ∷ Event → Bool
generational = \case
  SwapchainCreated {} → True
  ViewCreated _ → True
  ViewDestroyed _ → True
  SwapchainDestroyed _ → True
  _ → False

-- ---------------------------------------------------------------------------
-- Helpers

-- | Wait until this thread is blocked delivering an exception, or has
-- finished delivering it.
awaitThrowing ∷ ThreadId → IO ()
awaitThrowing thrower =
  threadStatus thrower >>= \case
    ThreadBlocked BlockedOnException → pure ()
    ThreadFinished → pure ()
    _ → yield >> awaitThrowing thrower

-- | Wait until a failed owner's own drain has finished and its run ended.
--
-- A failed owner drains at once rather than at the host's exit. Waiting for
-- it here keeps these examples clear of a race in the host's exit wait, which
-- reads the owner's destruction evidence and whether its run ended in two
-- separate transactions: an owner that records its destruction and ends in
-- between is declared unverified although it was not. That wait is the GLFW
-- package's, and is reported separately rather than repaired here.
ownerEnded ∷ VulkanHost Scene → IO ()
ownerEnded host = atomically (readOwnerTerminalNow (vulkanGraphicsOwner host) >>= check . ownerRunEnded)

bounded ∷ IO () → Expectation
bounded action =
  timeout (30 * 1000 * 1000) action >>= \case
    Just () → pure ()
    Nothing → expectationFailure "the example did not finish within its bound"

destruction ∷ Event → Bool
destruction = \case
  SurfaceDestroyed _ → True
  DeviceDestroyed → True
  MessengerDestroyed → True
  InstanceDestroyed → True
  WindowGone _ → True
  SessionEnded → True
  _ → False

raisedAs ∷ ∀ e a. Exception e ⇒ Either SomeException a → IO e
raisedAs = \case
  Left failure → case fromException failure of
    Just typed → pure typed
    Nothing → failWith ("the run failed with something else: " <> show failure)
  Right _ → failWith "the run returned instead of failing"

failWith ∷ String → IO a
failWith message = expectationFailure message >> throwIO (userError message)

showText ∷ Show a ⇒ a → Data.Text.Text
showText = Data.Text.pack . show

shouldReturnE ∷ IO [Event] → [Event] → IO ()
shouldReturnE action expected = action >>= (`shouldBe` expected)
