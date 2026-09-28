{-# LANGUAGE AllowAmbiguousTypes #-}

-- | VK-16's examples: the main-thread loop adapter and the graphics owner's
-- rendering, over whole graphics hosts on the GLFW package's scripted seam,
-- with the stand-in native layers of "Test.GPU.Vulkan.GLFW.StandIn".
--
-- The examples that prove a schedule read a scripted clock the host and the
-- owner share: it moves only when the example moves it, and the owner's timer
-- expires only once it has passed the instant the owner armed it for, so the
-- deadlines asserted are the ones the owner computed, never ones a real clock
-- happened to reach. None sleeps for correctness; the one bounded wait for
-- something /not/ to happen is labelled where it is made.
module Test.GPU.Vulkan.GLFW.Loop (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM (atomically, check, modifyTVar', newTVarIO, orElse, readTVar, readTVarIO, registerDelay, retry, writeTVar)
import Control.Exception (Exception (..), SomeException, throwIO, toException)
import Control.Monad (forM_, unless, void, when)
import Data.List (isSubsequenceOf)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
import Data.Word (Word32)
import qualified Data.Text as Text
import System.Timeout (timeout)

import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Time (Duration, DurationRequirement (AllowZero), Instant, addDuration, durationFromNanoseconds, elapsedBetween, readInstant, scriptedInstant, zeroDuration)
import Hetoimasia.GLFW.Command (WaitedSubmission (..), awaitCompletion, awaitSubmitWindowCommand, clientDemandPublisher, setWindowSizeCommand)
import Hetoimasia.GLFW.Demand (deadlineDemand, immediateDemand, publishDemand)
import Hetoimasia.GLFW.Window (Extent (..), WindowId)
import Hetoimasia.GPU.Model (TargetPhase (..), TargetView (..), targetView)
import Hetoimasia.GPU.Model.Budget (BudgetRequest (..), defaultBudgetRequest)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Loop (foldOwnerDeadline, newLoopAdapter, publishVulkanScene, runVulkanOwnerLoop)
import Hetoimasia.GPU.Vulkan.Native.Generations (GenerationView (..), TargetCondition (..), TargetGenerationsView (..))
import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceExtent (..))
import Hetoimasia.GPU.Vulkan.Native.Roots (GraphicsDeviceLost (..), RootTargetView (..))
import Hetoimasia.Runtime.GLFW
  ( GraphicsService
  , HostConfig (..)
  , OwnerDemand (..)
  , OwnerPhase (..)
  , OwnerStatus (..)
  , ScheduledStep (..)
  , ScheduledTurn (..)
  , TargetStanding (..)
  , Turn (..)
  , TurnPacing (..)
  , UpdateSchedule (..)
  , awaitOwnerRound
  , closeHostWindow
  , defaultScheduledHooks
  , graphicsAttachment
  , hostCommandPort
  , hostWindowClient
  , hostWindowIdentities
  , ownerHandoff
  , publishOwnerDemand
  , readOwnerDemandTaken
  , readOwnerStatusNow
  , readTargetTerminalsNow
  , releaseGraphicsTarget
  , superviseGraphicsOwner
  )
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Test.GPU.Vulkan.GLFW.StandIn
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = describe "Vulkan loop adapter" $ do
  describe "the composed loop" $ do
    it "publishes each attached window's observation and captured demand, and the owner presents a frame of its own" (bounded testComposedPresent)
    it "folds the owner's deadline into the main loop's wait, shortening it and never lengthening it" (bounded testDeadlineFolded)
    it "keeps demand captured before the owner took it, whatever newer demand is published over it" (bounded testDemandKeptUntilTaken)
    it "serves both parts of demand captured in one turn: one window's now, and another's later deadline once it comes" (bounded testCombinedDemand)
    it "keeps a redraw the owner took before any target was constructed, and renders it once one is" (bounded testRedrawBeforeTarget)
    it "keeps a closed window's retirement observable while the owner's step is held and demand waits" (bounded testCloseWhileSaturated)

  describe "the owner's pacing" $ do
    it "keeps a quiet continuous scene with demand out of the idle backoff" (bounded testContinuousDemand)
    it "backs completion polls off through 5, 10, 20, 40, 80 and 100 ms, and restarts on new demand, an observed completion and a close" (bounded testBackoffSchedule)
    it "polls no fence on an unrelated early wake, and takes a round whose deadline its work consumed without sleeping again" (bounded testEarlyWakeAndWorkDuration)
    it "keeps a finite progress deadline for a suspended target, without spinning" (bounded testSuspendedTarget)
    it "keeps presenting to one target while another's acquisitions cannot be answered" (bounded testBusyTargetFairness)
    it "tries a frame the renderer refused again at the backoff's first interval, not on every round" (bounded testRefusedFramePaced)
    it "lets a fresh request supersede a retry still pending, rendering at once" (bounded testFreshRequestSupersedesRetry)
    it "asks a frame of a generation a target moved to once, so an unrelated wake does not retry it early" (bounded testGenerationAskedOnce)
    it "renders a quiet target's replacement published in the step that disposed of its only generation, with nothing published" (bounded testQuietReplacementRendered)

  describe "a stalled main thread" $ do
    it "keeps the owner rendering while the native event call is held, and serves a window command once it returns" (bounded testStalledMainThread)
    it "keeps the owner rendering and rebuilding through a live resize that never pauses while the native event call is held" (bounded testStalledLiveResize)

  describe "status and exit" $ do
    it "brings a presentation's device loss to the application's next checkpoint" (bounded testLossAtCheckpoint)
    it "waits for owed presentations in the exit drain, retires in dependency order, and leaves no worker awaiting the ended loop" (bounded testExitWithOwedPresentations)
    it "keeps the exit drain waiting on its own deadlines once a demand deadline no frame can serve has passed" (bounded testDrainPastDemand)
    it "keeps the exit drain waiting on its own deadlines once a closing target's settling replacement is past due" (bounded testDrainPastSettling)

-- ---------------------------------------------------------------------------
-- The composed loop

-- | A window's own demand publisher.
demandFrame ∷ VulkanHost Scene → WindowId → IO ()
demandFrame host window = do
  client ← atomically (hostWindowClient (vulkanWindowHost host) window) >>= maybe (failWith "the window has no client") pure
  void (publishDemand (clientDemandPublisher client) immediateDemand)

-- | Run the composed loop until the condition holds, offering the
-- application's update opportunity each turn to this action first.
composedUntil ∷ Rig → VulkanHost Scene → RuntimeControl → String → (ScheduledTurn → IO ()) → IO Bool → IO ()
composedUntil rig host control what each done =
  runVulkanOwnerLoop host control $
    defaultScheduledHooks quietLogger $ \turn → do
      each turn
      finished ← done
      if finished
        then pure (FinishWith ())
        else
          if turnNumber (scheduledTurn turn) > 20000
            then do
              events ← frameEvents rig
              throwIO (StandInFailure (Text.pack ("the composed loop never reached " <> what <> "; the last frame events: " <> show (drop (length events - 12) events))))
            else pure (ContinueWith NoUpdateDemand)

-- | Hand the host's window over, wait until its owner has built it a
-- generation, and present one frame through the composed loop.
firstFrame ∷ Rig → VulkanHost Scene → RuntimeControl → WindowId → IO GraphicsService
firstFrame rig host control window = do
  service ← handedOver host window RequiredTarget
  TargetUsable ← awaitStanding host service
  demandFrame host window
  composedUntil rig host control "a first presented frame" (\_ → pure ()) ((>= 1) <$> presentsOf rig (graphicsAttachment service))
  pure service

testComposedPresent ∷ IO ()
testComposedPresent = do
  rig ← visibleRig
  events ← runRig rig $ \host control → do
    [window] ← windowsOf host
    -- No observation is published by hand: the adapter publishes it.
    _ ← firstFrame rig host control window
    frameEvents rig
  map kind events `shouldSatisfy` isSubsequenceOf ["acquired", "submitted", "requested", "presented"]
  calls ← journal rig
  calls `shouldSatisfy` any presented
  where
    presented = \case
      ImagePresented _ _ → True
      _ → False

testDeadlineFolded ∷ IO ()
testDeadlineFolded = do
  base ← scriptedRigOf 1
  -- A long idle bound: a turn that did not fold the owner's deadline in would
  -- wait for this fallback.
  let rig = base {rigHostConfig = (rigHostConfig base) {hostIdleWait = 5}}
  presentationsRetire rig False
  pacings ← newTVarIO []
  (due, now, folded) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    _ ← firstFrame rig host control window
    -- A presentation is pending, so the owner holds a finite poll deadline;
    -- the clock is still, so the deadline is too.
    due ← awaitAnchoredAfterPresent rig host
    now ← clockNow rig
    adapter ← newLoopAdapter host
    let later = either (error . show) id (addDuration due (millis 3600000))
        earlier = scriptedInstant zeroDuration
    folded ←
      sequence
        [ foldOwnerDeadline adapter now NoUpdateDemand
        , foldOwnerDeadline adapter now (UpdateBy later)
        , foldOwnerDeadline adapter now (UpdateBy earlier)
        , foldOwnerDeadline adapter now UpdateImmediately
        , -- A deadline that has already come is the owner's own to meet.
          foldOwnerDeadline adapter due NoUpdateDemand
        ]
    -- And the turns the composed loop takes meanwhile wait for it.
    count ← newTVarIO (0 ∷ Int)
    composedUntil
      rig
      host
      control
      "three turns"
      (\turn → atomically (modifyTVar' pacings (<> [scheduledPacing turn]) >> modifyTVar' count (+ 1)))
      ((>= 3) <$> readTVarIO count)
    letExitFinish rig
    pure (due, now, folded)
  folded `shouldBe` [UpdateBy due, UpdateBy due, UpdateBy (scriptedInstant zeroDuration), UpdateImmediately, NoUpdateDemand]
  seen ← readTVarIO pacings
  -- The first turn's wait was chosen before this loop's adapter had read the
  -- owner; every later one waited for the owner's deadline and never for the
  -- five-second fallback.
  drop 1 seen `shouldSatisfy` all (== WaitedForDeadline (elapsedBetween now due))

testContinuousDemand ∷ IO ()
testContinuousDemand = do
  rig ← scriptedRigOf 1
  presents ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← firstFrame rig host control window
    atomically (writeTVar (rigArmings rig) [])
    -- Every turn moves the clock a millisecond, and a frame is wanted again
    -- as soon as the last one was presented: a quiet scene rendered
    -- continuously, at the rate the owner presents it.
    asked ← newTVarIO (1 ∷ Int)
    composedUntil
      rig
      host
      control
      "six more frames"
      ( \_ → do
          advanceClock rig 1
          presented ← presentsOf rig (graphicsAttachment service)
          wanted ← readTVarIO asked
          when (presented >= wanted) $ do
            demandFrame host window
            atomically (writeTVar asked (presented + 1))
      )
      ((>= 7) <$> presentsOf rig (graphicsAttachment service))
    letExitFinish rig
    presentsOf rig (graphicsAttachment service)
  presents `shouldSatisfy` (>= 7)
  armings ← readTVarIO (rigArmings rig)
  -- The owner never waited longer than the first pending-work interval.
  armings `shouldSatisfy` all (<= millis 5)

testBackoffSchedule ∷ IO ()
testBackoffSchedule = do
  rig ← scriptedRigOf 1
  presentationsRetire rig False
  (walked, unrelated, afterDemand, afterCompletion, afterClose) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← firstFrame rig host control window
    let owner = vulkanGraphicsOwner host
    -- From the presenting step's instant, each poll at its deadline: nothing
    -- has progressed and nothing is wanted.
    start ← clockNow rig
    first ← awaitAnchoredAfterPresent rig host
    walked ← (elapsedBetween start first :) <$> walk rig host first 6
    -- An unrelated event: a publication of no demand at all, a millisecond
    -- before the next poll is due. It takes a round, and resets nothing.
    due ← awaitDeadline rig host
    before ← (,) <$> fenceQueries rig <*> atomically (readOwnerStatusNow owner)
    advanceClock rig 1
    nothing ← prepare (OwnerDemand False Nothing)
    _ ← atomically (publishOwnerDemand (ownerHandoff owner) nothing)
    _ ← atomically (awaitOwnerRound owner (statusRounds (snd before)))
    after ← (,) <$> fenceQueries rig <*> awaitDeadline rig host
    let unrelated = (fst after == fst before, snd after == due)
    -- New demand, and the new presentation it makes: the schedule restarts at
    -- its first interval, anchored where the frame was made.
    demandedAt ← clockNow rig
    demandFrame host window
    composedUntil rig host control "the demanded frame" (\_ → pure ()) ((>= 2) <$> presentsOf rig (graphicsAttachment service))
    restarted ← awaitAnchoredAfterPresent rig host
    afterDemand ← (elapsedBetween demandedAt restarted :) <$> walk rig host restarted 1
    -- An observed completion: one pending presentation retires at a poll
    -- well into the schedule, which restarts it rather than continuing it.
    -- The others stay pending, so there is still something to poll.
    demandFrame host window
    composedUntil rig host control "a third frame" (\_ → pure ()) ((>= 3) <$> presentsOf rig (graphicsAttachment service))
    anchored ← awaitAnchoredAfterPresent rig host
    _ ← walk rig host anchored 2
    completionDue ← awaitDeadline rig host
    retireNextPresentations rig (Just 1)
    presentationsRetire rig True
    afterCompletion ← awaitRetirementsObserved rig host completionDue
    presentationsRetire rig False
    -- A close: releasing the target closes it, which restarts the schedule of
    -- the cleanup its retirement waits for.
    closeDue ← awaitDeadline rig host
    _ ← walk rig host closeDue 2
    closedAt ← clockNow rig
    beforeClose ← atomically (readOwnerStatusNow owner)
    _ ← releaseGraphicsTarget (vulkanWindowHost host) owner service
    _ ← atomically (awaitOwnerRound owner (statusRounds beforeClose))
    afterClose ← elapsedBetween closedAt <$> awaitDeadlineAfter host closedAt
    letExitFinish rig
    _ ← awaitTerminal host service
    pure (walked, unrelated, afterDemand, afterCompletion, afterClose)
  walked `shouldBe` map millis [5, 10, 20, 40, 80, 100, 100]
  unrelated `shouldBe` (True, True)
  afterDemand `shouldBe` map millis [5, 10]
  afterCompletion `shouldBe` millis 5
  afterClose `shouldSatisfy` (<= millis 5)

testEarlyWakeAndWorkDuration ∷ IO ()
testEarlyWakeAndWorkDuration = do
  rig ← scriptedRigOf 1
  presentationsRetire rig False
  (early, consumed) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    _ ← firstFrame rig host control window
    let owner = vulkanGraphicsOwner host
    first ← awaitAnchoredAfterPresent rig host
    [second] ← walk rig host first 1
    let due = either (error . show) id (addDuration first second)
    -- An early wake: a millisecond after the last poll, something unrelated
    -- takes the owner a round. It asks no fence.
    queried ← fenceQueries rig
    status ← atomically (readOwnerStatusNow owner)
    advanceClock rig 1
    nothing ← prepare (OwnerDemand False Nothing)
    _ ← atomically (publishOwnerDemand (ownerHandoff owner) nothing)
    _ ← atomically (awaitOwnerRound owner (statusRounds status))
    queriedAfter ← fenceQueries rig
    -- Work that consumes the interval: the poll at the next deadline takes
    -- longer than the interval after it, so the deadline it anchors has
    -- already come when it returns, and the owner takes that round without
    -- arming its timer in between.
    slowNativeCalls rig (Just 50)
    polled ← fenceQueries rig
    setClock rig due
    atomically $ do
      queries ← length . filter isQuery . map snd <$> readTVar (rigJournal rig)
      check (queries >= polled + 2)
    slowNativeCalls rig Nothing
    events ← journal rig
    letExitFinish rig
    let queries = [index | (index, FenceQueried _) ← zip [0 ∷ Int ..] events]
        between = case drop polled queries of
          first' : second' : _ → [event | (index, event) ← zip [0 ..] events, index > first', index < second']
          _ → [OwnerTimerArmed]
    pure (queriedAfter == queried, OwnerTimerArmed `notElem` between)
  early `shouldBe` True
  consumed `shouldBe` True
  where
    isQuery = \case
      FenceQueried _ → True
      _ → False

testSuspendedTarget ∷ IO ()
testSuspendedTarget = do
  rig ← scriptedRigOf 1
  presentationsRetire rig False
  (deadline, spun, polledLater) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← firstFrame rig host control window
    let owner = vulkanGraphicsOwner host
    hidden ← newTVarIO False
    _ ← forkIO (setVisible rig host window False >> atomically (writeTVar hidden True))
    composedUntil rig host control "the hidden window's suspension" (\_ → pure ()) $ do
      done ← readTVarIO hidden
      model ← atomically (readVulkanModel (vulkanController host))
      targets ← atomically (readVulkanTargets (vulkanController host))
      let suspended = [() | (attachment, view) ← targets, attachment == graphicsAttachment service, Just held ← [targetView (targetViewIdentity view) model], viewTargetPhase held == TargetSuspended]
      pure (done && not (null suspended))
    -- The presentation is still pending, so the suspended target keeps a
    -- finite deadline.
    due ← awaitDeadline rig host
    settled ← atomically (readOwnerStatusNow owner)
    -- The one bounded wait for something not to happen: with the clock still,
    -- a spinning owner would take round after round in this time.
    expired ← registerDelay 50000
    spun ← atomically $ (True <$ (readOwnerStatusNow owner >>= check . (> statusRounds settled + 2) . statusRounds)) `orElse` (False <$ (readTVar expired >>= check))
    queried ← fenceQueries rig
    setClock rig due
    atomically $ do
      queries ← length . filter isQuery . map snd <$> readTVar (rigJournal rig)
      check (queries > queried)
    letExitFinish rig
    pure (due, spun, True)
  deadline `shouldSatisfy` (> scriptedInstant zeroDuration)
  spun `shouldBe` False
  polledLater `shouldBe` True
  where
    isQuery = \case
      FenceQueried _ → True
      _ → False

testBusyTargetFairness ∷ IO ()
testBusyTargetFairness = do
  rig ← visibleRigOf 2
  (busy, other, pended) ← runRig rig $ \host control → do
    [first, second] ← windowsOf host
    one ← firstFrame rig host control first
    two ← firstFrame rig host control second
    -- The first target's swapchain answers not ready from now on.
    view ← atomically (readVulkanGenerations (vulkanController host) (graphicsAttachment one)) >>= maybe (failWith "the first target has no generations") pure
    active ← maybe (failWith "the first target has no active generation") pure (viewActive view)
    swapchain ← case [handle | generation ← viewGenerations view, viewGeneration generation == active, Just handle ← [viewSwapchain generation]] of
      handle : _ → pure handle
      [] → failWith "the first target's generation has no swapchain"
    pendingBefore ← length . filter (pendingFor (graphicsAttachment one)) <$> frameEvents rig
    stallSwapchain rig swapchain
    -- A frame of the first target acquired before the stall is presented in
    -- the step that acquired it; once one of its acquisitions has answered
    -- not ready since, none is in flight, and the count is its last.
    -- One request is enough: a frame the swapchain cannot answer stays
    -- wanted, and the owner retries it on its own pacing.
    demandFrame host first
    composedUntil rig host control "the stalled target's first unanswered acquisition" (\_ → pure ()) $
      (> pendingBefore) . length . filter (pendingFor (graphicsAttachment one)) <$> frameEvents rig
    busyBefore ← presentsOf rig (graphicsAttachment one)
    otherBefore ← presentsOf rig (graphicsAttachment two)
    -- The second window is asked for a frame as soon as its last one was
    -- presented.
    asked ← newTVarIO otherBefore
    composedUntil
      rig
      host
      control
      "five more frames on the second target"
      ( \_ → do
          presented ← presentsOf rig (graphicsAttachment two)
          wanted ← readTVarIO asked
          when (presented >= wanted) $ do
            demandFrame host second
            atomically (writeTVar asked (presented + 1))
      )
      ((>= otherBefore + 5) <$> presentsOf rig (graphicsAttachment two))
    busyAfter ← presentsOf rig (graphicsAttachment one)
    pending ← length . filter (pendingFor (graphicsAttachment one)) <$> frameEvents rig
    pure (busyAfter - busyBefore, otherBefore, pending)
  busy `shouldBe` 0
  other `shouldSatisfy` (>= 1)
  pended `shouldSatisfy` (> 0)
  where
    pendingFor attachment = \case
      FramePending at _ → at == attachment
      _ → False

testStalledMainThread ∷ IO ()
testStalledMainThread = do
  rig ← visibleRig
  (duringStall, servedDuringStall, servedAfter) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← firstFrame rig host control window
    served ← newTVarIO False
    rendered ← newTVarIO 0
    servedWhileHeld ← newTVarIO Nothing
    -- The test's own thread: once the main thread is held inside its native
    -- event call, it publishes scenes — which is what an application thread
    -- other than the main one does — and submits a window command.
    _ ← forkIO $ do
      atomically (pumpHeld rig >>= check)
      before ← presentsOf rig (graphicsAttachment service)
      _ ← forkIO $
        -- Admitted at once, and executed only by the main thread's pump.
        awaitSubmitWindowCommand (hostCommandPort (vulkanWindowHost host)) [("client", "integration-tests")] (setWindowSizeCommand window (Extent 80 60)) >>= \case
          WaitAccepted ticket → awaitCompletion ticket >> atomically (writeTVar served True)
          WaitClosed → pure ()
      forM_ [1 .. 3 ∷ Int] $ \count → do
        scene ← prepare ()
        _ ← publishVulkanScene host scene
        atomically $ do
          -- Each scene is presented while the pump stays held.
          held ← pumpHeld rig
          unless held retry
        awaitPresents rig (graphicsAttachment service) (before + count)
      now ← presentsOf rig (graphicsAttachment service)
      atomically (writeTVar rendered (now - before))
      servedNow ← readTVarIO served
      atomically (writeTVar servedWhileHeld (Just servedNow))
      holdPump rig False
    holdPump rig True
    composedUntil rig host control "the command's service after the stall" (\_ → pure ()) (readTVarIO served)
    (,,) <$> readTVarIO rendered <*> readTVarIO servedWhileHeld <*> readTVarIO served
  duringStall `shouldSatisfy` (>= 3)
  servedDuringStall `shouldBe` Just False
  servedAfter `shouldBe` True

-- | A Cocoa live resize: the main thread stays inside its native event call
-- while the surface's extent changes about every 8 ms, faster than a
-- replacement's settling period, and the swapchain answers suboptimal while it
-- is stale. The owner keeps presenting from the active generation while each
-- replacement settles, and builds one a period from the newest extent, rather
-- than waiting for a pause that never comes.
testStalledLiveResize ∷ IO ()
testStalledLiveResize = do
  rig ← visibleRig
  (presented, built) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← firstFrame rig host control window
    suboptimalWhileStale rig
    result ← newTVarIO Nothing
    _ ← forkIO $ do
      atomically (pumpHeld rig >>= check)
      presentedBefore ← presentsOf rig (graphicsAttachment service)
      builtBefore ← swapchainsCreated rig
      forM_ [1 .. 40 ∷ Word32] $ \step → do
        offerExtent rig (Just (SurfaceExtent (640 + step * 4) 480))
        scene ← prepare ()
        _ ← publishVulkanScene host scene
        threadDelay 8000
      presentedAfter ← presentsOf rig (graphicsAttachment service)
      builtAfter ← swapchainsCreated rig
      atomically (writeTVar result (Just (presentedAfter - presentedBefore, builtAfter - builtBefore)))
      holdPump rig False
    holdPump rig True
    composedUntil rig host control "the end of the live resize" (\_ → pure ()) (isJust <$> readTVarIO result)
    readTVarIO result >>= maybe (throwIO (StandInFailure (Text.pack "the live resize reported nothing"))) pure
  -- Forty scenes over about 320 ms: the owner presents throughout, where a
  -- rule that waits for the geometry to be quiet would present almost none,
  -- and builds several replacements, where it would build none.
  presented `shouldSatisfy` (>= 10)
  built `shouldSatisfy` (>= 3)

testLossAtCheckpoint ∷ IO ()
testLossAtCheckpoint = do
  rig ← visibleRig
  outcome ← runRigCaught rig $ \host control → do
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    raiseOnPresent rig (toException (StandInLoss "vkQueuePresentKHR"))
    demandFrame host window
    -- The composed loop's own checkpoint raises it.
    composedUntil rig host control "the loss at a checkpoint" (\_ → pure ()) (pure False)
  loss ← raisedAs @GraphicsDeviceLost outcome
  lostDuring loss `shouldBe` "vkQueuePresentKHR"

testExitWithOwedPresentations ∷ IO ()
testExitWithOwedPresentations = do
  rig ← visibleRig
  presentationsRetire rig False
  ended ← newTVarIO False
  answered ← newTVarIO Nothing
  retiring ← newTVarIO False
  runRig rig $ \host control → do
    [window] ← windowsOf host
    _ ← firstFrame rig host control window
    let owner = vulkanGraphicsOwner host
    -- A worker that submits a window command once the loop has ended.
    _ ← forkIO $ do
      atomically (readTVar ended >>= check)
      answer ← awaitSubmitWindowCommand (hostCommandPort (vulkanWindowHost host)) [("client", "integration-tests")] (setWindowSizeCommand window (Extent 90 70))
      atomically (writeTVar answered (Just (accepted answer)))
    -- The presentations retire only once the owner is retiring, so the exit
    -- drain has to wait for them.
    _ ← forkIO $ do
      atomically (readOwnerStatusNow owner >>= check . (== OwnerRetiring) . statusPhase)
      atomically (writeTVar retiring True)
      presentationsRetire rig True
    atomically (writeTVar ended True)
  -- The worker was answered, not left waiting on the ended loop.
  worker ← timeout (10 * 1000 * 1000) (atomically (readTVar answered >>= maybe retry pure))
  worker `shouldSatisfy` isJust
  readTVarIO retiring >>= (`shouldBe` True)
  events ← journal rig
  events
    `shouldSatisfy` isSubsequenceOf
      [ SurfaceCreated 100
      , DeviceCreated
      , SurfaceDestroyed 100
      , DeviceDestroyed
      , MessengerDestroyed
      , InstanceDestroyed
      , WindowGone True
      , SessionEnded
      ]
  -- The present fence was asked, and answered, before the swapchain went.
  let presentedAt = [index | (index, ImagePresented _ _) ← zip [0 ∷ Int ..] events]
      destroyedAt = [index | (index, SwapchainDestroyed _) ← zip [0 ∷ Int ..] events]
  presentedAt `shouldSatisfy` (not . null)
  destroyedAt `shouldSatisfy` (not . null)
  maximum presentedAt < minimum destroyedAt `shouldBe` True
  where
    accepted = \case
      WaitAccepted _ → True
      WaitClosed → False

-- | The exit drain, with a presentation still owed and a demand deadline the
-- owner took but no step served. Every target is closing, so no frame can
-- serve that deadline: once it passes, the drain keeps waiting on its own
-- poll deadlines — arming its timer each time the clock moves — rather than
-- asking again at once, for ever, about a deadline that has come.
testDrainPastDemand ∷ IO ()
testDrainPastDemand = do
  rig ← scriptedRigOf 1
  presentationsRetire rig False
  paced ← newTVarIO False
  runRig rig $ \host control → do
    [window] ← windowsOf host
    _ ← firstFrame rig host control window
    let owner = vulkanGraphicsOwner host
    soon ← either (error . show) id . (`addDuration` millis 250) <$> clockNow rig
    client ← atomically (hostWindowClient (vulkanWindowHost host) window) >>= maybe (failWith "no client") pure
    _ ← publishDemand (clientDemandPublisher client) (deadlineDemand soon)
    -- The adapter publishes it at the end of the first turn, so the owner's
    -- answer is read from the second on.
    turns ← newTVarIO (0 ∷ Int)
    composedUntil
      rig
      host
      control
      "the owner taking the demand deadline"
      (\_ → atomically (modifyTVar' turns (+ 1)))
      (atomically ((&&) . (>= 2) <$> readTVar turns <*> readOwnerDemandTaken owner))
    _ ← forkIO $ do
      atomically (readOwnerStatusNow owner >>= check . (== OwnerRetiring) . statusPhase)
      -- Past the demand deadline and well beyond, a tenth of a second at a
      -- time: the drain arms its timer again after every move.
      forM_ [1 .. 6 ∷ Int] $ \_ → do
        armed ← length <$> readTVarIO (rigArmings rig)
        advanceClock rig 100
        atomically (readTVar (rigArmings rig) >>= check . (> armed) . length)
      atomically (writeTVar paced True)
      letExitFinish rig
    pure ()
  readTVarIO paced `shouldReturn` True

-- | The exit drain, with a presentation still owed and the target's
-- replacement settling from a resize. A closing target is never reconciled
-- again, so its settling instant is owed nothing: once the clock passes it, the
-- drain keeps waiting on the model's poll deadlines — arming its timer each
-- time the clock moves — rather than asking again at once, for ever.
testDrainPastSettling ∷ IO ()
testDrainPastSettling = do
  rig ← scriptedRigOf 1
  presentationsRetire rig False
  paced ← newTVarIO False
  runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← firstFrame rig host control window
    let owner = vulkanGraphicsOwner host
    resizeFramebuffer rig host window (800, 600)
    composedUntil rig host control "the resize settling" (\_ → pure ()) $ do
      view ← atomically (readVulkanGenerations (vulkanController host) (graphicsAttachment service))
      pure $ case viewCondition <$> view of
        Just (Settling _) → True
        _ → False
    _ ← forkIO $ do
      atomically (readOwnerStatusNow owner >>= check . (== OwnerRetiring) . statusPhase)
      forM_ [1 .. 6 ∷ Int] $ \_ → do
        armed ← length <$> readTVarIO (rigArmings rig)
        advanceClock rig 100
        atomically (readTVar (rigArmings rig) >>= check . (> armed) . length)
      atomically (writeTVar paced True)
      letExitFinish rig
    pure ()
  readTVarIO paced `shouldReturn` True

-- | A renderer that refuses every frame leaves the target's render demand
-- standing. The owner tries the frame again at the backoff's first interval:
-- with the scripted clock still, its deadline stays ahead of the clock and it
-- makes no second attempt, and once the clock reaches the interval it makes
-- one.
testRefusedFramePaced ∷ IO ()
testRefusedFramePaced = do
  rig ← scriptedRigOf 1
  (interval, before, after, presented) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← firstFrame rig host control window
    refuseFrames rig True
    demandFrame host window
    composedUntil rig host control "a refused frame" (\_ → pure ()) ((>= 1) <$> framesAbandoned rig)
    now ← clockNow rig
    due ← awaitDeadlineAfter host now
    before ← framesAbandoned rig
    setClock rig due
    atomically (framesAbandonedNow rig >>= check . (> before))
    after ← framesAbandoned rig
    refuseFrames rig False
    advanceClock rig 5
    composedUntil rig host control "a frame once the renderer accepts" (\_ → pure ()) ((>= 2) <$> presentsOf rig (graphicsAttachment service))
    letExitFinish rig
    (,,,) (elapsedBetween now due) before after <$> presentsOf rig (graphicsAttachment service)
  interval `shouldSatisfy` (<= millis 5)
  before `shouldBe` 1
  after `shouldBe` 2
  presented `shouldSatisfy` (>= 2)
  where
    framesAbandonedNow rig = length . filter abandoned <$> readTVar (rigFrameEvents rig)
    abandoned = \case
      FrameAbandoned {} → True
      _ → False

testDemandKeptUntilTaken ∷ IO ()
testDemandKeptUntilTaken = do
  rig ← visibleRig
  presents ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← firstFrame rig host control window
    gate ← newTVarIO False
    holding ← holdAcquisitions rig gate
    phase ← newTVarIO (0 ∷ Int)
    far ← either (error . show) id . (`addDuration` millis 3600000) <$> readInstant (hostClock (rigHostConfig rig))
    -- Turn by turn: demand now, and once the owner's step holds inside the
    -- acquisition it made for it, demand now again — which it has not taken —
    -- and then a deadline an hour away over it. Released, the owner must find
    -- the demand it never saw, not only the newest publication.
    composedUntil
      rig
      host
      control
      "the frame the untaken demand asked for"
      ( \_ → do
          current ← readTVarIO phase
          held ← atomically holding
          case current of
            0 → demandFrame host window >> atomically (writeTVar phase 1)
            1 | held → demandFrame host window >> atomically (writeTVar phase 2)
            2 → do
              client ← atomically (hostWindowClient (vulkanWindowHost host) window) >>= maybe (failWith "no client") pure
              _ ← publishDemand (clientDemandPublisher client) (deadlineDemand far)
              atomically (writeTVar phase 3)
            3 → atomically (writeTVar gate True >> writeTVar phase 4)
            _ → pure ()
      )
      ((>= 3) <$> presentsOf rig (graphicsAttachment service))
    presentsOf rig (graphicsAttachment service)
  presents `shouldSatisfy` (>= 3)

-- | Two windows publish in one turn — one asking now, the other by a later
-- deadline — so the owner receives one publication carrying both. It renders
-- now, and holds the deadline: with the scripted clock still, nothing more is
-- rendered, and once the clock reaches the deadline the owner renders again.
testCombinedDemand ∷ IO ()
testCombinedDemand = do
  rig ← scriptedRigOf 2
  (early, still, late) ← runRig rig $ \host control → do
    [first, second] ← windowsOf host
    one ← firstFrame rig host control first
    two ← firstFrame rig host control second
    let total = (+) <$> presentsOf rig (graphicsAttachment one) <*> presentsOf rig (graphicsAttachment two)
        client window = atomically (hostWindowClient (vulkanWindowHost host) window) >>= maybe (failWith "no client") pure
    base ← total
    soon ← either (error . show) id . (`addDuration` millis 50) <$> clockNow rig
    now' ← client first
    later ← client second
    published ← newTVarIO False
    composedUntil
      rig
      host
      control
      "the request made now"
      ( \_ → do
          done ← readTVarIO published
          unless done $ do
            _ ← publishDemand (clientDemandPublisher now') immediateDemand
            _ ← publishDemand (clientDemandPublisher later) (deadlineDemand soon)
            atomically (writeTVar published True)
      )
      ((>= base + 2) <$> total)
    early ← total
    -- The clock is still, short of the deadline: the owner settles on a
    -- deadline of its own, no later than the one it holds, and renders
    -- nothing meanwhile.
    due ← clockNow rig >>= awaitDeadlineAfter host
    when (due > soon) (failWith "the owner's deadline passed the demand it holds")
    still ← total
    setClock rig soon
    turns ← newTVarIO (0 ∷ Int)
    composedUntil
      rig
      host
      control
      "the request by the deadline"
      (\_ → atomically (modifyTVar' turns (+ 1)))
      ((||) . (> still) <$> total <*> ((>= 400) <$> readTVarIO turns))
    late ← total
    letExitFinish rig
    pure (early - base, still - early, late - still)
  early `shouldBe` 2
  still `shouldBe` 0
  late `shouldBe` 2

-- | A redraw published, and taken by the owner, while it had no target
-- constructed to request a frame of. The target handed over afterwards is
-- still asked for that frame once it is constructed, with nothing published
-- since.
testRedrawBeforeTarget ∷ IO ()
testRedrawBeforeTarget = do
  rig ← visibleRig
  presented ← runRig rig $ \host control → do
    [window] ← windowsOf host
    let owner = vulkanGraphicsOwner host
    now' ← prepare (OwnerDemand True Nothing)
    _ ← atomically (publishOwnerDemand (ownerHandoff owner) now')
    turns ← newTVarIO (0 ∷ Int)
    composedUntil
      rig
      host
      control
      "the owner taking the redraw"
      (\_ → atomically (modifyTVar' turns (+ 1)))
      (atomically ((&&) . (>= 2) <$> readTVar turns <*> readOwnerDemandTaken owner))
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    atomically (writeTVar turns 0)
    composedUntil
      rig
      host
      control
      "the redraw's frame"
      (\_ → atomically (modifyTVar' turns (+ 1)))
      ((||) . (>= 1) <$> presentsOf rig (graphicsAttachment service) <*> ((>= 400) <$> readTVarIO turns))
    presentsOf rig (graphicsAttachment service)
  presented `shouldSatisfy` (>= 1)

-- | A frame the renderer refused leaves a retry pending at the backoff's
-- first interval. A fresh request is an opportunity now: with the scripted
-- clock still, short of that retry, the owner renders at once.
testFreshRequestSupersedesRetry ∷ IO ()
testFreshRequestSupersedesRetry = do
  rig ← scriptedRigOf 1
  (before, after) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← firstFrame rig host control window
    refuseFrames rig True
    demandFrame host window
    composedUntil rig host control "a refused frame" (\_ → pure ()) ((>= 1) <$> framesAbandoned rig)
    now ← clockNow rig
    _ ← awaitDeadlineAfter host now
    before ← presentsOf rig (graphicsAttachment service)
    refuseFrames rig False
    demandFrame host window
    turns ← newTVarIO (0 ∷ Int)
    composedUntil
      rig
      host
      control
      "the fresh request's frame"
      (\_ → atomically (modifyTVar' turns (+ 1)))
      ((||) . (> before) <$> presentsOf rig (graphicsAttachment service) <*> ((>= 400) <$> readTVarIO turns))
    after ← presentsOf rig (graphicsAttachment service)
    letExitFinish rig
    pure (before, after)
  after `shouldBe` before + 1

-- | A resize moves a target that has presented to a new generation, and it
-- is asked a frame of it once. The renderer refuses that frame, leaving a
-- retry at the backoff's first interval: an unrelated early wake, with the
-- scripted clock still, makes no second attempt, and the retry comes when the
-- clock reaches it.
testGenerationAskedOnce ∷ IO ()
testGenerationAskedOnce = do
  rig ← scriptedRigOf 1
  (before, early, retried) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    _ ← firstFrame rig host control window
    let owner = vulkanGraphicsOwner host
    built ← swapchainsCreated rig
    refuseFrames rig True
    resizeFramebuffer rig host window (800, 600)
    -- The move is coalesced for its period: the clock moves a millisecond a
    -- turn until the replacement is built and its frame refused.
    composedUntil
      rig
      host
      control
      "the new generation's refused frame"
      (\_ → advanceClock rig 1)
      ((&&) . (> built) <$> swapchainsCreated rig <*> ((>= 1) <$> framesAbandoned rig))
    before ← framesAbandoned rig
    -- The owner settles on a deadline ahead of the still clock: its retry. One
    -- that asked again every round would never settle, so this is bounded.
    settled ← clockNow rig >>= timeout (5 * 1000 * 1000) . awaitDeadlineAfter host
    when (isNothing settled) (failWith "the owner never settled on a deadline ahead of the clock")
    status ← atomically (readOwnerStatusNow owner)
    -- An unrelated wake: a publication of no demand at all.
    nothing ← prepare (OwnerDemand False Nothing)
    _ ← atomically (publishOwnerDemand (ownerHandoff owner) nothing)
    _ ← atomically (awaitOwnerRound owner (statusRounds status))
    early ← framesAbandoned rig
    advanceClock rig 5
    atomically (length . filter abandoned <$> readTVar (rigFrameEvents rig) >>= check . (> early))
    retried ← framesAbandoned rig
    refuseFrames rig False
    letExitFinish rig
    pure (before, early, retried)
  early `shouldBe` before
  retried `shouldBe` before + 1
  where
    abandoned = \case
      FrameAbandoned {} → True
      _ → False

-- | With one live generation, a quiet target's resize retires its only
-- generation on its own, and the replacement is built and published in a step
-- that leaves nothing owed. The owner asks a frame of it in that same step:
-- the replacement is rendered with nothing published at all.
testQuietReplacementRendered ∷ IO ()
testQuietReplacementRendered = do
  base ← scriptedRigOf 1
  let rig = base {rigBudgets = defaultBudgetRequest {requestedGenerations = 1}}
  (builtBefore, builtAfter, before, after) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← firstFrame rig host control window
    builtBefore ← swapchainsCreated rig
    before ← presentsOf rig (graphicsAttachment service)
    resizeFramebuffer rig host window (800, 600)
    turns ← newTVarIO (0 ∷ Int)
    composedUntil
      rig
      host
      control
      "the replacement's frame"
      (\_ → advanceClock rig 1 >> atomically (modifyTVar' turns (+ 1)))
      ((||) . (> before) <$> presentsOf rig (graphicsAttachment service) <*> ((>= 400) <$> readTVarIO turns))
    builtAfter ← swapchainsCreated rig
    after ← presentsOf rig (graphicsAttachment service)
    letExitFinish rig
    pure (builtBefore, builtAfter, before, after)
  builtAfter `shouldBe` builtBefore + 1
  after `shouldBe` before + 1

testCloseWhileSaturated ∷ IO ()
testCloseWhileSaturated = do
  rig ← visibleRig
  retired ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← firstFrame rig host control window
    gate ← newTVarIO False
    holding ← holdAcquisitions rig gate
    demandFrame host window
    composedUntil rig host control "the owner's step held" (\_ → pure ()) (atomically holding)
    -- Demand keeps arriving that the held owner cannot take, and the window is
    -- closed meanwhile.
    demandFrame host window
    _ ← closeHostWindow (vulkanWindowHost host) window
    atomically (writeTVar gate True)
    -- The record is forgotten once the host has validated its facts and let
    -- the window go, so either is the evidence it was written; composedUntil
    -- fails the example if neither arrives.
    composedUntil rig host control "the closed window's retirement" (\_ → pure ()) $ atomically $ do
      recorded ← Map.member (graphicsAttachment service) <$> readTargetTerminalsNow (vulkanGraphicsOwner host)
      gone ← notElem window <$> hostWindowIdentities (vulkanWindowHost host)
      pure (recorded || gone)
    pure True
  retired `shouldBe` True

-- ---------------------------------------------------------------------------
-- Helpers

kind ∷ FrameEvent → String
kind = \case
  FrameAcquired {} → "acquired"
  FramePending {} → "pending"
  FrameSubmitted {} → "submitted"
  FramePresentRequested {} → "requested"
  FramePresented {} → "presented"
  FrameAbandoned {} → "abandoned"
  SubmissionCompleted _ → "completed"
  PresentationRetired _ → "retired"

-- | Let every pending presentation retire, and move the scripted clock far
-- enough that every deadline the owner or its exit drain waits for has come:
-- a scripted clock moves only when an example moves it, and the drain waits
-- for owed retirements on the owner's own deadlines.
letExitFinish ∷ Rig → IO ()
letExitFinish rig = do
  retireNextPresentations rig Nothing
  presentationsRetire rig True
  advanceClock rig 60000

-- | The owner's published deadline, once it is later than the scripted
-- clock: the one it settled on, rather than an opportunity it owed now and is
-- about to take.
awaitDeadline ∷ Rig → VulkanHost Scene → IO Instant
awaitDeadline rig host = clockNow rig >>= awaitDeadlineAfter host

-- | The deadline the owner anchored once its latest presentation was made:
-- the round after the one that presented it polls, and anchors the next
-- poll, beyond the scripted clock.
awaitAnchoredAfterPresent ∷ Rig → VulkanHost Scene → IO Instant
awaitAnchoredAfterPresent rig host = do
  rounds ← presentRounds rig
  let presentedIn = maybe 0 (+ 1) (lastMaybe rounds)
  now ← clockNow rig
  atomically $
    readOwnerStatusNow (vulkanGraphicsOwner host) >>= \status → case statusNextDeadline status of
      Just due | statusRounds status > presentedIn && due > now → pure due
      _ → retry
  where
    lastMaybe = \case
      [] → Nothing
      held → Just (last held)

-- | The owner's published deadline, once it is later than this instant.
awaitDeadlineAfter ∷ VulkanHost Scene → Instant → IO Instant
awaitDeadlineAfter host instant = atomically $
  readOwnerStatusNow (vulkanGraphicsOwner host) >>= \status → case statusNextDeadline status of
    Just due | due > instant → pure due
    _ → retry

-- | From a poll deadline, move the clock to it this many times, answering
-- the interval each poll announced next.
walk ∷ Rig → VulkanHost Scene → Instant → Int → IO [Duration]
walk _ _ _ 0 = pure []
walk rig host due count = do
  setClock rig due
  next ← awaitDeadlineAfter host due
  (elapsedBetween due next :) <$> walk rig host next (count - 1)

-- | Move the clock to a poll that observes the pending presentations'
-- retirement, and answer the interval it announced next.
awaitRetirementsObserved ∷ Rig → VulkanHost Scene → Instant → IO Duration
awaitRetirementsObserved rig host due = do
  setClock rig due
  atomically (readTVar (rigFrameEvents rig) >>= check . any retired)
  elapsedBetween due <$> awaitDeadlineAfter host due
  where
    retired = \case
      PresentationRetired _ → True
      _ → False

millis ∷ Integer → Duration
millis count = either (error . show) id (durationFromNanoseconds AllowZero (count * 1000000))

bounded ∷ IO () → Expectation
bounded action =
  timeout (60 * 1000 * 1000) action >>= \case
    Just () → pure ()
    Nothing → expectationFailure "the example did not finish within its bound"

raisedAs ∷ ∀ e a. Exception e ⇒ Either SomeException a → IO e
raisedAs = \case
  Left failure → case fromException failure of
    Just typed → pure typed
    Nothing → failWith ("the run failed with something else: " <> show failure)
  Right _ → failWith "the run returned instead of failing"

failWith ∷ String → IO a
failWith message = expectationFailure message >> throwIO (userError message)
