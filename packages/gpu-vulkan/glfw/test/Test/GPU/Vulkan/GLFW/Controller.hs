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
import Control.Concurrent.STM (atomically, check, newTVarIO, readTVar, writeTVar)
import Control.Exception (Exception (..), ExceptionWithContext (ExceptionWithContext), SomeException, asyncExceptionFromException, asyncExceptionToException, finally, throwIO, try)
import Control.Monad (forM_, replicateM_, void)
import Data.List (isSubsequenceOf, nub)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
import qualified Data.Text
import System.Timeout (timeout)
import Hetoimasia.GPU.Model (SessionFailureCause (DeviceLost), SessionState (..), sessionState)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.Diagnostics (DiagnosticVerdict (..))
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller
import Hetoimasia.GPU.Vulkan.Native.Profile (NoCompatibleDevice (..), TargetRejection (..))
import Hetoimasia.GPU.Vulkan.Native.Roots (GraphicsDeviceLost (..), RootStanding (..), RootTargetView (..), RootsView (..), SurfaceDestructionFailed (..))
import Hetoimasia.Runtime.GLFW
  ( CloseStart (..)
  , GraphicsService
  , OwnerStatus (..)
  , ReleaseAnswer (..)
  , SlotState (..)
  , Stage (..)
  , TargetStanding (..)
  , allRetirementFacts
  , awaitOwnerRound
  , closeHostWindow
  , completionNotice
  , custodyOf
  , graphicsAttachment
  , hostGraphicsPublisher
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

  describe "close and exit" $ do
    it "closing the first-created window retires its target alone, leaving the shared roots and the second target live" (bounded testCloseFirst)
    it "releasing one target destroys its surface before its terminal record, with the owner and the other target live" (bounded testRelease)
    it "a whole-host exit destroys every surface, the device, the messenger and the instance, then joins the owner before any window goes" (bounded testExitOrder)
    it "a destruction still pending certifies nothing" (bounded testPendingDestruction)

  describe "device loss" $ do
    it "closes admission at once and reaches an application checkpoint while retirement is still pending" (bounded testLossReachesCheckpoint)
    it "keeps the loss primary, never retries a failed destruction, and retains its parents without certifying the attachment" (bounded testLossWithFailedCleanup)
    it "treats an unknown outcome as neither device loss nor destruction" (bounded testUnknownOutcome)

  describe "progress" $
    it "reports no work and no deadline, since nothing is recorded or submitted" (bounded testNoDemand)

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
      atomically (writeTVar observed (Just (viewAdmitting roots, isJust (viewLoss roots), closedAnswer answer, sessionState model)))
      checkRuntime control
  loss ← raisedAs @GraphicsDeviceLost outcome
  lostDuring loss `shouldBe` "vkGetPhysicalDeviceSurfaceSupportKHR"
  atomically (readTVar observed) >>= (`shouldBe` Just (False, True, True, SessionFailed DeviceLost))
  events ← journal rig
  -- Nothing was recreated, and retirement still ran child before parent.
  length [() | DeviceCreated ← events] `shouldBe` 1
  events `shouldSatisfy` isSubsequenceOf [SurfaceDestroyed 100, DeviceDestroyed, MessengerDestroyed, InstanceDestroyed, WindowGone True]
  where
    closedAnswer = \case
      VulkanOwnerClosed _ → True
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
    -- The round that constructed the target has completed, and an idle owner
    -- takes no other: nothing it holds wants one.
    atomically (awaitOwnerRound (vulkanGraphicsOwner host) 0)
  statusNextDeadline status `shouldBe` Nothing
  statusAdvanced status `shouldBe` 0
  statusImmediate status `shouldBe` False

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
