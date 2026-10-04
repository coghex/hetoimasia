{-# LANGUAGE AllowAmbiguousTypes #-}

-- | GRS-15's examples: a session whose device is created without a surface,
-- zero-target progress, and owner-thread actions, over whole graphics hosts on
-- the GLFW package's scripted seam with the stand-in native layers of
-- "Test.GPU.Vulkan.GLFW.StandIn".
--
-- Every wait here is on a transaction or on an event the stand-ins journal,
-- never on elapsed time. An action that must hold the owner's thread waits on
-- a gate the example opens; one that must prove something did not happen
-- meanwhile reads the order it was journalled in.
module Test.GPU.Vulkan.GLFW.Actions (spec) where

import Control.Concurrent (forkIO, myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, orElse, readTVar, readTVarIO, registerDelay, writeTVar)
import Control.Exception (Exception (..), ExceptionWithContext (..), SomeException, throwIO, toException, try)
import Control.Monad (void, when)
import qualified Data.ByteString as ByteString
import Data.List (isSubsequenceOf)
import Data.Maybe (isJust, isNothing)
import System.Timeout (timeout)

import Hetoimasia.Foundation.Log (unsafeComponent)
import Hetoimasia.Foundation.Recovery (Disposition (Required))
import Hetoimasia.Foundation.Worker (awaitStopRequest, workerDefinition)
import Hetoimasia.GLFW.Command (clientDemandPublisher)
import Hetoimasia.GLFW.Demand (immediateDemand, publishDemand)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.Diagnostics (verdictIssues)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Loop (runVulkanOwnerLoop)
import Hetoimasia.GPU.Vulkan.Native.Profile (TargetRejection (..))
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( BufferDescription (..)
  , BufferKind (..)
  , ImageDescription (..)
  , ImageFormat (..)
  , ImageKind (..)
  , Pipeline
  , PipelineLayout
  , PipelineShaders (..)
  , Refusal (RefusedOwnerWait)
  , TicketState (..)
  , awaitTicket
  , readTicket
  )
import Hetoimasia.GPU.Vulkan.Native.Uploads (UploadRequest (..), UploadState (..), awaitUploadTicket, validateUploadConfig)
import Hetoimasia.GPU.Vulkan.Native.TextureTable (SwapState (..), readSwapTicket, validateTableConfig)
import Hetoimasia.GPU.Vulkan.Native.Roots (GraphicsDeviceLost (..), GraphicsSessionFailed (..), RootStanding (..), RootsView (..), TerminalCause (..))
import Hetoimasia.Runtime.GLFW
  ( ScheduledStep (..)
  , UpdateSchedule (..)
  , ScheduledTurn (..)
  , TargetStanding (..)
  , Turn (..)
  , defaultScheduledHooks
  , graphicsAttachment
  , hostPendingAttachments
  , ownerDestroyed
  , publishOwnerDestruction
  , hostWindowClient
  , OwnerStatus (..)
  , readOwnerFailure
  , readOwnerStatusNow
  , releaseGraphicsTarget
  , superviseGraphicsOwner
  )
import Hetoimasia.Runtime.Supervision
  ( Recognition (Unrecognized)
  , Role (Service)
  , RuntimeControl
  , WorkerPolicy (..)
  , checkRuntime
  , startSupervised
  )
import Test.GPU.Vulkan.GLFW.Bound (boundOf, boundedIt)
import Test.GPU.Vulkan.GLFW.StandIn
import Test.Hspec (Expectation, Spec, describe, expectationFailure, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "Vulkan surface-free sessions and owner-thread actions" $ do
  describe "surface-free startup" $ do
    itBounded "creates the device in the owner's startup with no surface and no window, and retires it, the messenger and the instance in order" testSurfaceFreeTeardown
    itBounded "admits a window handed over later that the chosen family presents to, and refuses one it cannot, with one device" testLaterSurfaces

  describe "owner-thread actions" $ do
    itBounded "run on the owner's thread with the session's construction, and return their results" testActionOnOwner
    itBounded "are refused as device-not-ready before the first window's admission by default, creating nothing, and run after it" testDeviceNotReady
    itBounded "are refused at once when the queue is full, never waiting for room" testQueueFull
    itBounded "return a raising action's failure to the caller, keep what it constructed managed, and let the owner go on" testRaisingAction
    itBounded "end the owner's run when a construction inside one loses the device, never answering it as the action's own failure alone" testEscapedConstruction
    itBounded "end the owner's run with a construction's loss that the action caught and returned from, answering the ticket with the loss" testCaughtEscape
    itBounded "settle the ticket with a failure setting the construction up before that failure ends the owner's run" testSetupFailure
    itBounded "are refused after the session's terminal failure, including one queued before it that never started" testTerminalRefusal
    itBounded "are refused once the owner's exit begins, including one queued behind a running action, which finishes" testExitRefusal
    itBounded "are refused at the application's pre-drain quiescence, while a worker drains, a queued one without waiting for the owner, and a running one finishes" testQuiescenceRefusal
    itBounded "never run beside a frame's rendering: a frame asked for meanwhile follows the action" testSerialization
    itBounded "create a buffer and an image of every kind through the lent construction on the owner's thread, and release them for the owner to destroy, each view before its image" testBuffersAndImages

  describe "frame-less batches (GRS-12)" $ do
    itBounded "are recorded inside an action with no target, submitted in seal order when it returns, and complete their tickets only on fence evidence, waited on with a deadline" testFramelessBatches
    itBounded "are discarded when their action raises, submitting nothing" testFramelessRaising
    itBounded "fail a texture swap still pending at the owner's exit before frame-less retirement, which retains a batch that never completed (GRS-9)" testSwapAtRetirement

  describe "zero-target progress" $ do
    itBounded "admits uploads from another thread into an idle owner with no target, keeps them uploading past a wait's deadline while their batches are pending, and completes them on fence evidence" testUploads
    itBounded "disposes of a released resource with no target, recording no frame, before the host exits" testZeroTargetDisposal
    itBounded "keeps making progress after the last target closes, the device serving later actions" testAfterLastTarget
    itBounded "names no deadline once nothing is owed, sleeping until an action wakes it rather than polling" testIdleSleeps

-- ---------------------------------------------------------------------------
-- Surface-free startup

testSurfaceFreeTeardown ∷ IO ()
testSurfaceFreeTeardown = do
  rig ← surfaceFreeRig 0
  (roots, layout) ← runRig rig $ \host _ → do
    awaitReady host
    roots ← atomically (readVulkanRoots (vulkanController host))
    layout ← returned =<< act host (VulkanAction (\construction → constructPipelineLayout construction))
    pure (roots, layout)
  (viewDevice roots, viewTargets roots) `shouldBe` (RootLive, [])
  layout `shouldSatisfy` either (const False) (const True)
  events ← journal rig
  made ← case [handle | LayoutMade handle ← events] of
    [handle] → pure handle
    other → failWith ("expected one layout, but " <> show other)
  events
    `shouldBe` [ InstanceCreated
               , MessengerCreated
               , DevicesQueriedWithoutSurface
               , DeviceCreated
               , LayoutMade made
               , LayoutGone made
               , DeviceDestroyed
               , MessengerDestroyed
               , InstanceDestroyed
               , SessionEnded
               ]
  Just verdict ← readTVarIO (rigVerdict rig)
  verdictIssues verdict `shouldBe` []

testLaterSurfaces ∷ IO ()
testLaterSurfaces = do
  rig ← surfaceFreeRig 2
  declareUnsupported rig 101
  (first, second, rejection) ← runRig rig $ \host control → do
    [one, two] ← windowsOf host
    usable ← handedOver host one RequiredTarget
    first ← awaitStanding host usable
    refused ← handedOver host two OptionalTarget
    second ← awaitStanding host refused
    rejection ← atomically (readTargetRejection (vulkanController host) (graphicsAttachment refused))
    _ ← releaseGraphicsTarget (vulkanWindowHost host) (vulkanGraphicsOwner host) refused
    pumpUntil host control "the rejected attachment's retirement" ((== 1) . length <$> atomically (hostPendingAttachments (vulkanWindowHost host)))
    pure (first, second, rejection)
  first `shouldBe` TargetUsable
  second `shouldBe` TargetUnusable False
  rejection `shouldBe` Just (RejectedByRoots (TargetSurfaceUnsupported 0))
  events ← journal rig
  -- The device was made before any surface existed, against none, and each
  -- surface was then only checked against its family.
  events `shouldSatisfy` isSubsequenceOf [DevicesQueriedWithoutSurface, DeviceCreated, SurfaceCreated 100, SupportQueried 100, SurfaceCreated 101, SupportQueried 101, SurfaceDestroyed 101]
  length [() | DeviceCreated ← events] `shouldBe` 1
  [() | DevicesQueried _ ← events] `shouldBe` []

-- ---------------------------------------------------------------------------
-- Owner-thread actions

testActionOnOwner ∷ IO ()
testActionOnOwner = do
  rig ← surfaceFreeRig 0
  (caller, ran, built) ← runRig rig $ \host _ → do
    awaitReady host
    caller ← myThreadId
    (ran, built) ← returned =<< act host (VulkanAction (\construction → (,) <$> myThreadId <*> buildPipeline construction))
    pure (caller, ran, built)
  built `shouldSatisfy` either (const False) (const True)
  -- The device, and everything the action built, were made on one thread:
  -- the owner's, which is not the caller's.
  owners ← threadsOf rig (\case DeviceCreated → True; LayoutMade _ → True; PipelineMade {} → True; _ → False)
  owners `shouldBe` replicate 3 ran
  ran `shouldSatisfy` (/= caller)

testDeviceNotReady ∷ IO ()
testDeviceNotReady = do
  rig ← newRig
  (before, after) ← runRig rig $ \host _ → do
    awaitReady host
    before ← atomically (submitVulkanAction (vulkanController host) (VulkanAction (\_ → pure ())))
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    after ← act host (VulkanAction (\_ → pure ("ran" ∷ String)))
    pure (refusalOf before, after)
  before `shouldBe` Just ActionDeviceNotReady
  either (const Nothing) Just (outcomeValue after) `shouldBe` Just "ran"
  -- Nothing was created for the refused one: the device came with the
  -- window's surface.
  events ← journal rig
  takeWhile (/= DeviceCreated) events `shouldSatisfy` elem (SurfaceCreated 100)

testQueueFull ∷ IO ()
testQueueFull = do
  rig ← withActionCapacity 2 <$> surfaceFreeRig 0
  (queued, full, outcomes) ← runRig rig $ \host _ → do
    awaitReady host
    (gate, running, holding) ← holdingAction
    held ← admitted =<< atomically (submitVulkanAction (vulkanController host) holding)
    atomically (readTVar running >>= check)
    -- The owner is inside the holding action: two more are queued, and a
    -- third finds the queue full at once.
    first ← admitted =<< atomically (submitVulkanAction (vulkanController host) (VulkanAction (\_ → pure (1 ∷ Int))))
    second ← admitted =<< atomically (submitVulkanAction (vulkanController host) (VulkanAction (\_ → pure (2 ∷ Int))))
    full ← atomically (submitVulkanAction (vulkanController host) (VulkanAction (\_ → pure (3 ∷ Int))))
    queued ← atomically ((,) <$> readVulkanAction first <*> readVulkanAction second)
    atomically (writeTVar gate True)
    outcomes ← atomically ((,,) <$> awaitVulkanAction held <*> awaitVulkanAction first <*> awaitVulkanAction second)
    pure (queued, refusalOf full, outcomes)
  (isJust (fst queued), isJust (snd queued)) `shouldBe` (False, False)
  full `shouldBe` Just ActionQueueFull
  let (held, first, second) = outcomes
  (outcomeValue held, outcomeValue first, outcomeValue second) `shouldBe` (Right (), Right 1, Right 2)

testRaisingAction ∷ IO ()
testRaisingAction = do
  rig ← surfaceFreeRig 0
  (raised, after, whileRunning) ← runRig rig $ \host _ → do
    awaitReady host
    raised ← act host (VulkanAction (\construction → constructPipelineLayout construction >> throwIO (ActionBroke "the consumer's own failure")))
    after ← act host (VulkanAction (\_ → pure ("still running" ∷ String)))
    whileRunning ← journal rig
    pure (raised, after, whileRunning)
  case raised of
    ActionRaised (ExceptionWithContext _ inner) → fromException inner `shouldBe` Just (ActionBroke "the consumer's own failure")
    _ → failWith "the action's failure did not reach its caller"
  outcomeValue after `shouldBe` Right "still running"
  -- What it built before it raised was not destroyed while the host ran, and
  -- was destroyed before the device on its exit.
  made ← case [handle | LayoutMade handle ← whileRunning] of
    [handle] → pure handle
    other → failWith ("expected one layout, but " <> show other)
  whileRunning `shouldSatisfy` notElem (LayoutGone made)
  events ← journal rig
  events `shouldSatisfy` isSubsequenceOf [LayoutGone made, DeviceDestroyed, InstanceDestroyed]

testEscapedConstruction ∷ IO ()
testEscapedConstruction = do
  rig ← surfaceFreeRig 0
  raiseOnCreate rig CreatePipeline (toException (StandInLoss "vkCreateGraphicsPipelines"))
  observed ← newTVarIO Nothing
  outcome ← runRigCaught rig $ \host control → do
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    awaitReady host
    answer ← act host (VulkanAction buildPipeline)
    atomically (writeTVar observed (Just answer))
    atomically (readOwnerFailure (vulkanGraphicsOwner host) >>= check . isJust)
    checkRuntime control
  loss ← raisedAs @GraphicsDeviceLost outcome
  lostDuring loss `shouldBe` "vkCreateGraphicsPipelines"
  answered ← readTVarIO observed
  case answered of
    Just (ActionRaised failure) → show failure `shouldSatisfy` isSubsequenceOf "vkCreateGraphicsPipelines"
    other → failWith ("the action was not answered with the loss it raised: " <> maybe "nothing" outcomeText other)

testCaughtEscape ∷ IO ()
testCaughtEscape = do
  rig ← surfaceFreeRig 0
  raiseOnCreate rig CreatePipeline (toException (StandInLoss "vkCreateGraphicsPipelines"))
  observed ← newTVarIO Nothing
  outcome ← runRigCaught rig $ \host control → do
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    awaitReady host
    -- The action swallows what the construction raised and returns normally.
    answer ← act host (VulkanAction (\construction → either (\(_ ∷ SomeException) → "swallowed" ∷ String) (const "built") <$> try (buildPipeline construction)))
    atomically (writeTVar observed (Just answer))
    atomically (readOwnerFailure (vulkanGraphicsOwner host) >>= check . isJust)
    checkRuntime control
  loss ← raisedAs @GraphicsDeviceLost outcome
  lostDuring loss `shouldBe` "vkCreateGraphicsPipelines"
  readTVarIO observed >>= \case
    Just (ActionRaised failure) → show failure `shouldSatisfy` isSubsequenceOf "vkCreateGraphicsPipelines"
    other → failWith ("the ticket was not answered with the escaped loss: " <> maybe "nothing" outcomeText other)

testSetupFailure ∷ IO ()
testSetupFailure = do
  rig ← surfaceFreeRig 0
  raiseOnCreate rig CreateRecording (toException (StandInFailure "the recording's layer could not be made"))
  observed ← newTVarIO Nothing
  outcome ← runRigCaught rig $ \host control → do
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    awaitReady host
    answer ← act host (VulkanAction (\_ → pure ()))
    atomically (writeTVar observed (Just answer))
    atomically (readOwnerFailure (vulkanGraphicsOwner host) >>= check . isJust)
    checkRuntime control
  failure ← raisedAs @StandInFailure outcome
  failure `shouldBe` StandInFailure "the recording's layer could not be made"
  readTVarIO observed >>= \case
    Just (ActionRaised (ExceptionWithContext _ inner)) → fromException inner `shouldBe` Just failure
    other → failWith ("the ticket was not settled with the setup failure: " <> maybe "nothing" outcomeText other)

testTerminalRefusal ∷ IO ()
testTerminalRefusal = do
  rig ← surfaceFreeRig 0
  observed ← newTVarIO Nothing
  outcome ← runRigCaught rig $ \host control → do
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    awaitReady host
    reportErrorNow rig "an error before an action"
    -- Nothing is latched yet, so this is admitted, and it wakes the owner,
    -- whose checkpoint latches the error before it starts anything.
    queued ← admitted =<< atomically (submitVulkanAction (vulkanController host) (VulkanAction (\_ → pure ())))
    atomically (readOwnerFailure (vulkanGraphicsOwner host) >>= check . isJust)
    settled ← atomically (awaitVulkanAction queued)
    later ← atomically (submitVulkanAction (vulkanController host) (VulkanAction (\_ → pure ())))
    atomically (writeTVar observed (Just (outcomeText settled, refusalOf later)))
    checkRuntime control
  failure ← raisedAs @GraphicsSessionFailed outcome
  failure `shouldBe` GraphicsSessionFailed TerminalValidationError
  readTVarIO observed
    `shouldReturnValue` Just (outcomeText (ActionRefused @() (ActionSessionFailed TerminalValidationError)), Just (ActionSessionFailed TerminalValidationError))

testExitRefusal ∷ IO ()
testExitRefusal = do
  rig ← surfaceFreeRig 0
  answers ← newTVarIO Nothing
  (gate, running, holding) ← holdingAction
  outcomes ← runRig rig $ \host _ → do
    awaitReady host
    held ← admitted =<< atomically (submitVulkanAction (vulkanController host) holding)
    atomically (readTVar running >>= check)
    behind ← admitted =<< atomically (submitVulkanAction (vulkanController host) (VulkanAction (\_ → pure ())))
    -- Once the exit has begun, the one queued behind the running action is
    -- refused without waiting for the owner, a new one is refused at
    -- admission, and only then does the running one finish.
    _ ← forkIO $ do
      refused ← atomically (awaitVulkanAction behind)
      late ← atomically (submitVulkanAction (vulkanController host) (VulkanAction (\_ → pure ())))
      atomically $ do
        writeTVar answers (Just (outcomeText refused, refusalOf late))
        writeTVar gate True
    pure (host, held)
  let (host, held) = outcomes
  readTVarIO answers `shouldReturnValue` Just (outcomeText (ActionRefused @() ActionOwnerClosed), Just ActionOwnerClosed)
  finished ← atomically (readVulkanAction held)
  fmap outcomeValue finished `shouldBe` Just (Right ())
  after ← atomically (submitVulkanAction (vulkanController host) (VulkanAction (\_ → pure ())))
  refusalOf after `shouldBe` Just ActionOwnerClosed

-- | The application's own pre-drain quiescence is the boundary that refuses
-- owner-thread actions, not the protected exit after the ordinary drain.
--
-- An ordinary supervised worker looks while it is held in the supervision
-- drain, with a running action holding the owner's thread: the action queued
-- behind it already reads as refused — the worker reads its ticket and does
-- not wait — and a new one is refused at admission, while the running one has
-- still not returned. Only then does the worker let it finish.
testQuiescenceRefusal ∷ IO ()
testQuiescenceRefusal = do
  rig ← surfaceFreeRig 0
  answers ← newTVarIO Nothing
  (gate, running, holding) ← holdingAction
  ticket ← runRig rig $ \host control → do
    awaitReady host
    held ← admitted =<< atomically (submitVulkanAction (vulkanController host) holding)
    atomically (readTVar running >>= check)
    behind ← admitted =<< atomically (submitVulkanAction (vulkanController host) (VulkanAction (\_ → pure ())))
    let watcher =
          workerDefinition
            "quiescence watcher"
            (\_ → pure ())
            ( \token () → do
                atomically (awaitStopRequest token)
                queued ← atomically (readVulkanAction behind)
                late ← atomically (submitVulkanAction (vulkanController host) (VulkanAction (\_ → pure ())))
                stillRunning ← isNothing <$> atomically (readVulkanAction held)
                atomically $ do
                  writeTVar answers (Just (fmap outcomeText queued, refusalOf late, stillRunning))
                  writeTVar gate True
            )
    _ ← startSupervised control (WorkerPolicy Service Required (unsafeComponent "test.vulkan-actions") (\_ → pure Unrecognized)) watcher
    pure held
  readTVarIO answers
    `shouldReturnValue` Just (Just (outcomeText (ActionRefused @() ActionOwnerClosed)), Just ActionOwnerClosed, True)
  finished ← atomically (readVulkanAction ticket)
  fmap outcomeValue finished `shouldBe` Just (Right ())
  events ← journal rig
  events `shouldSatisfy` isSubsequenceOf [DeviceDestroyed, MessengerDestroyed, InstanceDestroyed, SessionEnded]

testSerialization ∷ IO ()
testSerialization = do
  rig ← visibleRig
  order ← newTVarIO ([] ∷ [String])
  onFrameEvent rig $ \case
    FrameAcquired {} → atomically (modifyTVar' order (<> ["frame acquired"]))
    FramePresented {} → atomically (modifyTVar' order (<> ["frame presented"]))
    _ → pure ()
  runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    demandFrame host window
    composedUntil host control "a first presented frame" ((>= 1) <$> presentsOf rig (graphicsAttachment service))
    gate ← newTVarIO False
    running ← newTVarIO False
    let holding = do
          atomically $ do
            modifyTVar' order (<> ["action began"])
            writeTVar running True
          atomically (readTVar gate >>= check)
          atomically (modifyTVar' order (<> ["action ended"]))
    ticket ← admitted =<< atomically (submitVulkanAction (vulkanController host) (VulkanAction (\_ → holding)))
    atomically (readTVar running >>= check)
    -- A frame asked for while the action holds the owner's thread waits for
    -- it.
    demandFrame host window
    atomically (writeTVar gate True)
    _ ← atomically (awaitVulkanAction ticket)
    composedUntil host control "a frame after the action" ((>= 2) <$> presentsOf rig (graphicsAttachment service))
  recorded ← readTVarIO order
  recorded `shouldSatisfy` isSubsequenceOf ["frame presented", "action began", "action ended", "frame acquired", "frame presented"]
  -- Nothing of a frame happened between the action's beginning and its end.
  takeWhile (/= "action ended") (dropWhile (/= "action began") recorded) `shouldBe` ["action began"]

-- | GRS-2's buffers and images, through the construction an action is lent:
-- made on the owner's thread, released through the same construction, and
-- destroyed by the owner's own progress while the host still runs — an
-- image's view before the image, and both before the device.
testBuffersAndImages ∷ IO ()
testBuffersAndImages = do
  rig ← surfaceFreeRig 0
  (owner, whileRunning) ← runRig rig $ \host _ → do
    awaitReady host
    let images = [ImageDescription TextureImage Rgba8Srgb 16 16 5, ImageDescription DepthTarget Depth32Float 16 16 1, ImageDescription ColorTarget Bgra8Srgb 16 16 1]
    (owner, made) ←
      returned =<< act host (VulkanAction (\construction → do
        owner ← myThreadId
        buffers ← mapM (\kind → constructBuffer construction (BufferDescription kind 256)) [minBound .. maxBound]
        made ← mapM (constructImage construction) images
        pure (owner, (sequence buffers, sequence made))))
    (buffers, built) ← case made of
      (Right buffers, Right built) → pure (buffers, built)
      other → failWith ("a construction was refused: " <> show (either Just (const Nothing) (fst other), either Just (const Nothing) (snd other)))
    released ←
      returned =<< act host (VulkanAction (\construction → (,) <$> mapM (releaseConstructed construction) buffers <*> mapM (releaseConstructed construction) built))
    released `shouldBe` (map (const (Right ())) buffers, map (const (Right ())) built)
    events ← journal rig
    -- Reclaimed by the owner's own progress, with no target and no frame.
    mapM_ (awaitEvent rig . BufferGone) [buffer | BufferMade buffer _ ← events]
    mapM_ (awaitEvent rig . ImageGone) [image | ImageMade image _ ← events]
    (,) owner <$> journal rig
  [size | BufferMade _ size ← whileRunning] `shouldBe` replicate 5 256
  [format | ImageMade _ format ← whileRunning] `shouldBe` [43, 126, 50]
  makers ← threadsOf rig (\case BufferMade {} → True; ImageMade {} → True; OwnedViewMade {} → True; DeviceCreated → True; _ → False)
  makers `shouldBe` replicate 12 owner
  [ ()
    | OwnedViewMade view image ← whileRunning
    , not ([OwnedViewMade view image, OwnedViewGone view, ImageGone image] `isSubsequenceOf` whileRunning)
    ]
    `shouldBe` []
  length [() | OwnedViewGone _ ← whileRunning] `shouldBe` 3
  whileRunning `shouldSatisfy` notElem DeviceDestroyed

-- ---------------------------------------------------------------------------
-- Zero-target progress

-- | Two frame-less batches recorded in one action with no target, submitted
-- when it returns — the inner one, sealed first, first — and their tickets
-- pending, under a deadline that passes, until the fences answer signalled,
-- and complete only once the owner's own progress has observed that.
testFramelessBatches ∷ IO ()
testFramelessBatches = do
  rig ← surfaceFreeRig 0
  submissionsComplete rig False
  (tickets, pending, complete, submitted, recorded) ← runRig rig $ \host _ → do
    awaitReady host
    tickets ← returned =<< act host (VulkanAction (\construction → nested construction))
    submitted ← (\events → [handle | QueueSubmitted handle ← events]) <$> journal rig
    pending ← mapM (\ticket → awaitTicket ticket (millisecondsOf 1)) tickets
    submissionsComplete rig True
    complete ← mapM (\ticket → awaitTicket ticket (millisecondsOf 30000)) tickets
    recorded ← commandsRecorded rig
    pure (tickets, pending, complete, submitted, recorded)
  length tickets `shouldBe` 2
  pending `shouldBe` [Right TicketPending, Right TicketPending]
  complete `shouldBe` [Right TicketComplete, Right TicketComplete]
  length submitted `shouldBe` 2
  -- Nothing but the two empty batches was recorded, and no image acquired.
  recorded `shouldBe` []
  events ← journal rig
  [() | ImageAcquired {} ← events] `shouldBe` []
  Just verdict ← readTVarIO (rigVerdict rig)
  verdictIssues verdict `shouldBe` []
  where
    nested construction =
      constructFramelessBatch construction (\_ → constructFramelessBatch construction (\_ → pure ())) >>= \case
        Right (outer, Right (inner, ())) → pure [inner, outer]
        other → failWith ("the frame-less batches were refused: " <> show (fmap (fmap (fmap fst)) other))

-- | Uploads (GRS-6) admitted from a thread other than the owner's into a
-- zero-target session whose owner is idle: admission wakes it, it records
-- their copies into a frame-less batch, and their tickets wait — through a
-- wait whose deadline passes, which cancels nothing — until the batch's fence
-- answers signalled and the owner's own progress observes that. A wait on
-- the owner's thread is refused.
testUploads ∷ IO ()
testUploads = do
  rig ← withUploads (either (error . show) id (validateUploadConfig (1024 * 1024) 65536 4)) <$> surfaceFreeRig 0
  submissionsComplete rig False
  (early, late, owner') ← runRig rig $ \host _ → do
    awaitReady host
    (texture, vertices) ← returned =<< act host (VulkanAction (\construction → do
      texture ← constructImage construction (ImageDescription TextureImage Rgba8Linear 64 64 2) >>= either (failWith . show) pure
      vertices ← constructBuffer construction (BufferDescription VertexBuffer 4096) >>= either (failWith . show) pure
      pure (texture, vertices)))
    answers ← newEmptyMVar
    _ ← forkIO $ do
      admitted' ←
        mapM
          (submitVulkanUpload (vulkanController host))
          [ UploadImage texture [ByteString.replicate 16384 1, ByteString.replicate 4096 2]
          , UploadBuffer vertices (ByteString.replicate 4096 3)
          ]
      case sequence admitted' of
        Left refusal → putMVar answers (Left refusal)
        Right tickets → do
          early ← mapM (\ticket → awaitUploadTicket ticket (millisecondsOf 20)) tickets
          putMVar answers (Right (tickets, early))
    (tickets, early) ← takeMVar answers >>= either (failWith . ("the upload was refused: " <>) . show) pure
    submissionsComplete rig True
    late ← mapM (\ticket → awaitUploadTicket ticket (millisecondsOf 30000)) tickets
    owner' ← returned =<< act host (VulkanAction (\_ → mapM (\ticket → awaitUploadTicket ticket (millisecondsOf 1)) tickets))
    pure (early, late, owner')
  -- Past the first deadline neither has settled: each is still queued or
  -- uploading, never complete while its batch's fence has not answered.
  early `shouldSatisfy` all (`elem` [Right UploadQueued, Right UploadUploading])
  late `shouldBe` replicate 2 (Right UploadComplete)
  owner' `shouldBe` replicate 2 (Left RefusedOwnerWait)
  Just verdict ← readTVarIO (rigVerdict rig)
  verdictIssues verdict `shouldBe` []

-- | A texture swap accepted before the owner's exit, whose replacement's
-- upload never completes because no submission does, fails at the exit: the
-- retirement fails every pending swap before it retires the frame-less
-- batches, which retain the batch that never completed, so the swap's ticket
-- is settled however the rest of the teardown ends.
testSwapAtRetirement ∷ IO ()
testSwapAtRetirement = do
  rig ← withUploads (either (error . show) id (validateUploadConfig (1024 * 1024) 65536 4)) <$> surfaceFreeRig 0
  submissionsComplete rig False
  held ← newTVarIO Nothing
  _ ← runRigCaught rig $ \host _ → do
    awaitReady host
    (handle, replacement) ← returned =<< act host (VulkanAction (\construction → do
      constructTextureTable construction (either (error . show) id (validateTableConfig 16 4 2)) >>= either (failWith . show) pure
      old ← constructImage construction (ImageDescription TextureImage Rgba8Linear 2 2 1) >>= either (failWith . show) pure
      replacement ← constructImage construction (ImageDescription TextureImage Rgba8Linear 2 2 1) >>= either (failWith . show) pure
      handle ← registerConstructedTexture construction old >>= either (failWith . show) pure
      pure (handle, replacement)))
    _ ← submitVulkanUpload (vulkanController host) (UploadImage replacement [ByteString.replicate 16 1]) >>= either (failWith . show) pure
    ticket ← returned =<< act host (VulkanAction (\construction → swapConstructedTexture construction handle replacement >>= either (failWith . show) pure))
    atomically (writeTVar held (Just ticket))
    -- The exit retains the batch that never completed, and finishes only on
    -- independent evidence of the owner's destruction, which this publishes
    -- once the swap has failed — or after a bound, so a ticket left pending
    -- fails the example rather than hanging it.
    let owner = vulkanGraphicsOwner host
    bound ← registerDelay 15000000
    void . forkIO $ do
      atomically ((readSwapTicket ticket >>= check . (== SwapFailed)) `orElse` (readTVar bound >>= check))
      publishOwnerDestruction owner (ownerDestroyed "published independently by the example")
  ticket ← readTVarIO held >>= maybe (failWith "the swap was not accepted") pure
  atomically (readSwapTicket ticket) >>= (`shouldBe` SwapFailed)

-- | An action that seals a frame-less batch and then raises submits nothing:
-- the batch is discarded, and its ticket says so.
testFramelessRaising ∷ IO ()
testFramelessRaising = do
  rig ← surfaceFreeRig 0
  (outcome, ticket) ← runRig rig $ \host _ → do
    awaitReady host
    held ← newTVarIO Nothing
    outcome ← act host (VulkanAction (\construction → do
      constructFramelessBatch construction (\_ → pure ()) >>= \case
        Right (ticket, ()) → atomically (writeTVar held (Just ticket))
        Left refusal → failWith (show refusal)
      throwIO (userError "the action failed")))
    ticket ← readTVarIO held >>= maybe (failWith "no batch was recorded") pure
    pure (outcome, ticket)
  either (const True) (const False) (outcomeValue (outcome ∷ ActionOutcome ())) `shouldBe` True
  atomically (readTicket ticket) >>= (`shouldBe` TicketDiscarded)
  events ← journal rig
  [handle | QueueSubmitted handle ← events] `shouldBe` []

testZeroTargetDisposal ∷ IO ()
testZeroTargetDisposal = do
  rig ← surfaceFreeRig 0
  (made, whileRunning) ← runRig rig $ \host _ → do
    awaitReady host
    layout ← either (failWith . show) pure =<< returned =<< act host (VulkanAction constructPipelineLayout)
    released ← returned =<< act host (VulkanAction (\construction → releaseConstructed construction layout))
    released `shouldSatisfy` either (const False) (const True)
    events ← journal rig
    made ← case [handle | LayoutMade handle ← events] of
      [handle] → pure handle
      other → failWith ("expected one layout, but " <> show other)
    -- Reclaimed by the owner's own progress, with no target and no frame,
    -- while the host is still running.
    awaitEvent rig (LayoutGone made)
    (,) made <$> journal rig
  whileRunning `shouldSatisfy` isSubsequenceOf [LayoutMade made, LayoutGone made]
  whileRunning `shouldSatisfy` notElem DeviceDestroyed
  frames ← frameEvents rig
  frames `shouldBe` []
  [() | ImageAcquired {} ← whileRunning] `shouldBe` []

testAfterLastTarget ∷ IO ()
testAfterLastTarget = do
  rig ← newRig
  (roots, whileRunning) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    _ ← releaseGraphicsTarget (vulkanWindowHost host) (vulkanGraphicsOwner host) service
    _ ← awaitTerminal host service
    pumpUntil host control "the released attachment's retirement" (null <$> atomically (hostPendingAttachments (vulkanWindowHost host)))
    -- No target remains; the device still serves an action, and what it
    -- releases is still reclaimed.
    layout ← either (failWith . show) pure =<< returned =<< act host (VulkanAction constructPipelineLayout)
    _ ← returned =<< act host (VulkanAction (\construction → releaseConstructed construction layout))
    events ← journal rig
    case [handle | LayoutMade handle ← events] of
      [made] → awaitEvent rig (LayoutGone made)
      other → failWith ("expected one layout, but " <> show other)
    roots ← atomically (readVulkanRoots (vulkanController host))
    (,) roots <$> journal rig
  (viewDevice roots, viewTargets roots) `shouldBe` (RootLive, [])
  whileRunning `shouldSatisfy` isSubsequenceOf [SurfaceDestroyed 100]
  whileRunning `shouldSatisfy` notElem DeviceDestroyed

testIdleSleeps ∷ IO ()
testIdleSleeps = do
  rig ← surfaceFreeRig 0
  answer ← runRig rig $ \host _ → do
    awaitReady host
    -- Something is owed after the action's release, and nothing once it is
    -- disposed of: the owner then names no deadline of its own. An owner
    -- that polled without cause would keep naming one, and this wait would
    -- never end.
    layout ← either (failWith . show) pure =<< returned =<< act host (VulkanAction constructPipelineLayout)
    _ ← returned =<< act host (VulkanAction (\construction → releaseConstructed construction layout))
    idle ← timeout (10 * 1000 * 1000) . atomically $ do
      status ← readOwnerStatusNow (vulkanGraphicsOwner host)
      check (statusRounds status > 0 && isNothing (statusNextDeadline status))
    when (isNothing idle) (failWith "the idle owner kept naming a deadline of its own")
    -- An action still wakes it.
    act host (VulkanAction (\_ → pure ("woken" ∷ String)))
  outcomeValue answer `shouldBe` Right "woken"

-- ---------------------------------------------------------------------------
-- Helpers

-- | A failure an action raises on its own account.
newtype ActionBroke = ActionBroke String
  deriving (Eq, Show)

instance Exception ActionBroke

shaders ∷ PipelineShaders
shaders = PipelineShaders "stand-in vertex SPIR-V" "stand-in fragment SPIR-V"

-- | Build a layout and a pipeline over it, as a consumer preparing its
-- pipelines before any frame would.
buildPipeline ∷ Construction q inst msgr phys dev cmd → IO (Either Refusal (PipelineLayout, Pipeline))
buildPipeline construction =
  constructPipelineLayout construction >>= \case
    Left refusal → pure (Left refusal)
    Right layout → fmap ((,) layout) <$> constructPipeline construction layout shaders 50

-- | An action that holds the owner's thread until its gate opens, and says
-- when it has begun.
holdingAction ∷ IO (TVar Bool, TVar Bool, VulkanAction ())
holdingAction = do
  gate ← newTVarIO False
  running ← newTVarIO False
  pure
    ( gate
    , running
    , VulkanAction $ \_ → do
        atomically (writeTVar running True)
        atomically (readTVar gate >>= check)
    )

-- | Wait until the owner's startup has leased its instance, as an application
-- does before it acts.
awaitReady ∷ VulkanHost Scene → IO ()
awaitReady host = atomically (readReadiness (vulkanController host) >>= check . (== RootsReady))

-- | Submit an action, failing the example if it was refused, and wait for its
-- outcome.
act ∷ VulkanHost Scene → VulkanAction r → IO (ActionOutcome r)
act host action = do
  ticket ← admitted =<< atomically (submitVulkanAction (vulkanController host) action)
  atomically (awaitVulkanAction ticket)

admitted ∷ Either ActionRefusal (ActionTicket r) → IO (ActionTicket r)
admitted = either (\refusal → failWith ("the action was refused: " <> show refusal)) pure

-- | What an action returned, failing the example otherwise.
returned ∷ ActionOutcome r → IO r
returned outcome = either failWith pure (outcomeValue outcome)

outcomeValue ∷ ActionOutcome r → Either String r
outcomeValue = \case
  ActionReturned value → Right value
  other → Left (outcomeText other)

outcomeText ∷ ActionOutcome r → String
outcomeText = \case
  ActionReturned _ → "returned"
  ActionRaised failure → "raised " <> displayException failure
  ActionRefused refusal → "refused " <> show refusal

refusalOf ∷ Either ActionRefusal a → Maybe ActionRefusal
refusalOf = either Just (const Nothing)

demandFrame ∷ VulkanHost Scene → WindowId → IO ()
demandFrame host window = do
  client ← atomically (hostWindowClient (vulkanWindowHost host) window) >>= maybe (failWith "the window has no client") pure
  void (publishDemand (clientDemandPublisher client) immediateDemand)

-- | Run the composed loop until the condition holds.
composedUntil ∷ VulkanHost Scene → RuntimeControl → String → IO Bool → IO ()
composedUntil host control what done =
  runVulkanOwnerLoop host control $
    defaultScheduledHooks quietLogger $ \turn → do
      finished ← done
      if finished
        then pure (FinishWith ())
        else
          if turnNumber (scheduledTurn turn) > 20000
            then failWith ("the loop never reached " <> what)
            else pure (ContinueWith NoUpdateDemand)

shouldReturnValue ∷ (Eq a, Show a) ⇒ IO a → a → Expectation
shouldReturnValue action expected = action >>= (`shouldBe` expected)

-- | One example under the suite's fixture-aware bound of a minute
-- ("Test.GPU.Vulkan.GLFW.Bound").
itBounded ∷ String → IO () → Spec
itBounded = boundedIt (boundOf 60)

raisedAs ∷ ∀ e a. Exception e ⇒ Either SomeException a → IO e
raisedAs = \case
  Left failure → case fromException failure of
    Just typed → pure typed
    Nothing → failWith ("the run failed with something else: " <> show failure)
  Right _ → failWith "the run returned instead of failing"

failWith ∷ String → IO a
failWith message = expectationFailure message >> throwIO (userError message)
