-- | R2D-14's examples: a scene for each window, the adoption and release of
-- the revisions the owner holds, and release requests (D-28, D-30), over whole
-- graphics hosts on the GLFW package's scripted seam with the stand-in native
-- layers of "Test.GPU.Vulkan.GLFW.StandIn".
--
-- Every wait here is on a transaction or on an event the stand-ins journal,
-- never on elapsed time. Where an example needs a publication and a request
-- to be one fact, it makes both in one transaction, which no owner step can
-- fall between; where it needs a request to be held back, it names a window
-- that has a publication and no target, which nothing will adopt until the
-- window ends. An example that proves something did not happen says what it
-- read it from.
module Test.GPU.Vulkan.GLFW.Scenes (spec) where

import Control.Concurrent (ThreadId, forkIO, throwTo, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, orElse, readTVar, readTVarIO, registerDelay, stateTVar, writeTVar)
import Control.Exception (ErrorCall (..), SomeException, throwIO, toException, try)
import Control.Monad (void, when)
import Data.List (nub, sort)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (..), threadStatus)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Data.Word (Word64)
import Numeric.Natural (Natural)
import System.Timeout (timeout)

import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Messaging.Snapshot (Publication (..))
import Hetoimasia.GPU.Vulkan.Native.Frames (PresentStatus (..))
import Hetoimasia.GLFW.Command (awaitSubmitWindowCommand, createWindowCommand)
import Hetoimasia.GLFW.Window (WindowId, hiddenTestWindowConfig)
import Hetoimasia.GPU.Model.Budget (defaultBudgetRequest, frameSlotLimit, validateBudgets)
import Hetoimasia.GPU.Model (TargetPhase (..), TargetView (..), targetView)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Loop (publishVulkanScene, publishVulkanWindowScene, runVulkanOwnerLoop)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Scenes (adoptScene, endSceneTarget, newScenes, readSceneState, registerSceneTarget, releaseScenes, retentionLimit)
import Hetoimasia.GPU.Vulkan.Native.Generations (GenerationView (..), SwapchainResult (..), TargetCondition (..), TargetGenerationsView (..))
import Hetoimasia.GPU.Vulkan.Native.Recording (ClearColor (..))
import Hetoimasia.GPU.Vulkan.Native.Roots (RootTargetView (..), TerminalCause (..))
import Hetoimasia.Runtime.Supervision (checkRuntime)
import Hetoimasia.Runtime.GLFW
  ( AttachmentId
  , CloseStart (..)
  , GraphicsService
  , ScheduledStep (..)
  , ScheduledTurn (..)
  , ScenePublication (..)
  , TargetStanding (..)
  , Turn (..)
  , WindowScenePublication (..)
  , OwnerStatus (..)
  , awaitOwnerRound
  , closeHostWindow
  , defaultScheduledHooks
  , graphicsAttachment
  , hostCommandPort
  , ownerHandoff
  , publishGraphicsWindowScene
  , publishOwnerScene
  , readOwnerFailure
  , readOwnerStatusNow
  , releaseGraphicsTarget
  , superviseGraphicsOwner
  )
import Hetoimasia.Runtime.GLFW (UpdateSchedule (..))
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Test.GPU.Vulkan.GLFW.Bound (boundOf, boundedIt)
import Test.GPU.Vulkan.GLFW.StandIn
import Test.Hspec (Spec, describe, expectationFailure, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "Vulkan scenes for each window (R2D-14)" $ do
  describe "publishing" $ do
    itBounded "asks only the published window's target for a frame, handing the renderer that window's scene and revision" testOnlyThatWindowAsked
    itBounded "refuses a shared scene in a per-window host, and a window's scene in a shared one, and a window the host does not hold, naming it" testRefusals
    itBounded "keeps a window's publication across its target's release and reattachment, adopting it again under the new attachment" testPublicationSurvivesReattachment
    itBounded "keeps a window's attachment, adoption and publication through the recovery of a lost surface, notifying nothing for it" testPublicationAcrossRecovery

  describe "adoption and release" $ do
    itBounded "adopts the initial scene as revision 0 on a target's first step, asking for no frame, and a suspended window adopts what is published without rendering it" testAdoption
    itBounded "notifies neither a revision replaced before the owner's step took it nor any not adopted, and releases each adopted revision once, in adoption order" testSkippedRevisions
    itBounded "releases a superseded revision only after the last frame recorded with it has completed, and only once" testReleaseAfterCompletion
    itBounded "releases several superseded revisions with frames in flight in adoption order, once each, as their submissions complete" testReleaseOrder
    itBounded "keeps a revision awaiting release while its submission is pending, whatever became of the frame's presentation" testAbandonedFrameKeepsRevision
    itBounded "releases the revisions of an ended target and of the owner's retirement, each exactly once" testReleaseAtEnd
    itBounded "holds a finite number of unreleased revisions for a target, adopting nothing newer behind a pending submission until a release makes room, then catching up in order" testRetentionBound
    itBounded "keeps a revision awaiting release when the device's loss lets its submission go without completing it" testLossKeepsRevision
    itBounded "keeps the revision of a recording the device's loss interrupted, which no reset discarded" testLossDuringRecording
    itBounded "keeps a revision while a submission the owner's cancellation followed is pending, then releases it once on the completion" testCancelledAfterSubmission
    itBounded "releases a revision exactly once when the owner is cancelled right after the completion that ended its last use was recorded" testCancelledAfterCompletion
    itBounded "releases a revision exactly once when the owner is cancelled right after a recording was discarded" testCancelledAfterDiscard
    itBounded "completes an adoption's record, notification and watermark, and a release's removal and notifications, whatever cancels the owner meanwhile" testLedgerCancellation
    itBounded "ends the use of a recording that raised once the target's teardown discards it, releasing its revision at the target's retirement" testTeardownDiscard

  describe "release requests" $ do
    itBounded "wait for the revision current when they were made, observably, and run once the window adopts it" testRequestWaitsForAdoption
    itBounded "wait for a window with a publication and no target, run in the order made without holding back an action that has no barrier, and are released by that window's end" testRequestOrderAndWindowEnd
    itBounded "wait for every window the host holds, even one with no target and no publication, in a per-window host and in a shared one" testTargetlessWindowHolds
    itBounded "leave out a window that has never published when the host declares its initial scene holds nothing, and still wait for a published window with no target until a target adopts it or the window is dropped, in a per-window host and in a shared one" testNeverPublishedWindowLeavesBarrier
    itBounded "are not delayed by a window created after they were made" testRequestIgnoresLaterWindow
    itBounded "wait for a window whose adopting target was released until another adopts, in a per-window host and in a shared one, with the host's declaration and without" testDetachedWindowHoldsRequest
    itBounded "wait on a shared scene's revision for every window in a shared host" testRequestSharedMode
    itBounded "are refused when their own bound is full, never by the actions queued, and before the device exists, and settled as refused, never replayed, when the owner exits" testRequestAdmission
    itBounded "are refused after the session's failure, including one queued before it that never started" testRequestAfterFailure
    itBounded "are refused after a failure reported while the owner is idle, which the next publication brings to its checkpoint, including one queued before it that never started" testRequestAfterFailureWhileIdle

-- ---------------------------------------------------------------------------
-- Helpers

itBounded ∷ String → IO () → Spec
itBounded = boundedIt (boundOf 60)

failWith ∷ String → IO a
failWith message = expectationFailure message >> throwIO (userError message)

-- | A rig over this many visible windows with a scene for each.
scenesRig ∷ Int → IO Rig
scenesRig count = withPerWindowScenes <$> visibleRigOf count

-- | Run the composed loop until the condition holds.
--
-- It fails, naming what it waited for and what the owner had done, past
-- twenty seconds or twenty thousand turns: the loop turns only when the owner
-- or a window asks, so an idle owner never reaches the turn bound alone.
composedUntil ∷ Rig → VulkanHost Scene → RuntimeControl → String → IO Bool → IO ()
composedUntil rig host control what done =
  timeout 20000000 (runVulkanOwnerLoop host control (defaultScheduledHooks quietLogger step)) >>= \case
    Just () → pure ()
    Nothing → stalled
  where
    step turn = do
      finished ← done
      if finished
        then pure (FinishWith ())
        else
          if turnNumber (scheduledTurn turn) > 20000
            then stalled
            else pure (ContinueWith NoUpdateDemand)
    stalled ∷ IO a
    stalled = do
      events ← frameEvents rig
      scene ← sceneEvents rig
      status ← atomically (readOwnerStatusNow (vulkanGraphicsOwner host))
      throwIO . StandInFailure . Text.pack $
        "the composed loop never reached "
          <> what
          <> "; the last frame events: "
          <> show (drop (length events - 8) events)
          <> "; the scene events: "
          <> show scene
          <> "; the owner: "
          <> show (statusPhase status, statusRounds status, statusAdvanced status, statusImmediate status, statusNextDeadline status)

-- | Whether the target's generation is presenting, so a frame asked for is
-- offered one.
generationPresenting ∷ VulkanHost Scene → GraphicsService → IO Bool
generationPresenting host service = do
  view ← atomically (readVulkanGenerations (vulkanController host) (graphicsAttachment service))
  pure (fmap viewCondition view == Just Presenting)

-- | Whether the target is suspended in the GPU model.
targetSuspended ∷ VulkanHost Scene → GraphicsService → IO Bool
targetSuspended host service = do
  model ← atomically (readVulkanModel (vulkanController host))
  targets ← atomically (readVulkanTargets (vulkanController host))
  pure (or [viewTargetPhase held == TargetSuspended | (attachment, view) ← targets, attachment == graphicsAttachment service, Just held ← [targetView (targetViewIdentity view) model]])

-- | Hand a window over and wait until its target is usable.
attach ∷ VulkanHost Scene → WindowId → IO GraphicsService
attach host window = do
  service ← handedOver host window RequiredTarget
  TargetUsable ← awaitStanding host service
  pure service

-- | Hand the host's first two windows over, and turn the loop until both
-- targets have a presenting generation and have adopted the initial scene.
attachBoth ∷ Rig → VulkanHost Scene → RuntimeControl → IO (WindowId, GraphicsService, WindowId, GraphicsService)
attachBoth rig host control = do
  windows ← windowsOf host
  (a, b) ← case windows of
    first : second : _ → pure (first, second)
    _ → failWith "the host holds fewer than two windows"
  sa ← attach host a
  sb ← attach host b
  composedUntil rig host control "both generations presenting" $ do
    ready ← (&&) <$> generationPresenting host sa <*> generationPresenting host sb
    adopted ← sceneEvents rig
    pure (ready && length [() | SceneAdopted {} ← adopted] >= 2)
  settleOwner rig host
  pure (a, sa, b, sb)

-- | Wait for the owner round that made the latest scene event or the latest
-- presentation to end, so everything that round did, such as a release at the
-- end of the step that adopted, has been done. It waits for no round that is
-- not coming.
settleOwner ∷ Rig → VulkanHost Scene → IO ()
settleOwner rig host = do
  scene ← sceneRounds rig
  presented ← presentRounds rig
  let latest = maximum (0 : take 1 (reverse scene) <> take 1 (reverse presented))
  void (atomically (awaitOwnerRound (vulkanGraphicsOwner host) latest))

publishTo ∷ VulkanHost Scene → WindowId → Scene → IO WindowScenePublication
publishTo host window value = prepare value >>= publishVulkanWindowScene host window

-- | A renderer that records what it was handed, then clears the frame.
recording ∷ TVar [(AttachmentId, Scene, Natural)] → VulkanRenderer Scene
recording seen = VulkanRenderer $ \scene frame construction recorder → do
  atomically (modifyTVar' seen (<> [(requestAttachment frame, scene, requestSceneRevision frame)]))
  renderScene (clearRenderer (\_ _ → ClearColor 0 0 0 1)) scene frame construction recorder

adoptedBy ∷ [SceneEvent] → WindowId → [(Natural, Scene)]
adoptedBy events window = [(revision, scene) | SceneAdopted at revision scene ← events, at == window]

releasedBy ∷ [SceneEvent] → WindowId → [Natural]
releasedBy events window = [revision | SceneReleased at revision ← events, at == window]

-- | Hand a release request to the owner, failing the example if it is refused.
request ∷ VulkanHost Scene → VulkanAction r → IO (ActionTicket r)
request host action =
  atomically (requestVulkanRelease (vulkanController host) action) >>= either (\refusal → failWith ("the release request was refused: " <> show refusal)) pure

-- | The request's returned value once it has run.
ranWith ∷ ActionTicket r → IO (Maybe r)
ranWith ticket =
  atomically (readVulkanAction ticket) >>= \case
    Just (ActionReturned value) → pure (Just value)
    Just _ → failWith "the release request did not return"
    Nothing → pure Nothing

-- | Mark that something ran, in order.
mark ∷ TVar [String] → String → VulkanAction ()
mark ran label = VulkanAction (\_ → atomically (modifyTVar' ran (<> [label])))

-- ---------------------------------------------------------------------------
-- Publishing

testOnlyThatWindowAsked ∷ IO ()
testOnlyThatWindowAsked = do
  rig ← scenesRig 2
  seen ← newTVarIO []
  renderWith rig (recording seen)
  (first, second, toBBefore, toBAfterA, toAAfterB, attachments) ← runRig rig $ \host control → do
    (a, sa, b, sb) ← attachBoth rig host control
    let attachmentA = graphicsAttachment sa
        attachmentB = graphicsAttachment sb
    baselineA ← presentsOf rig attachmentA
    baselineB ← presentsOf rig attachmentB
    published ← publishTo host a 11
    composedUntil rig host control "A's frame" ((> baselineA) <$> presentsOf rig attachmentA)
    settleOwner rig host
    toBAfterA ← subtract baselineB <$> presentsOf rig attachmentB
    second ← publishTo host b 22
    composedUntil rig host control "B's frame" ((> baselineB) <$> presentsOf rig attachmentB)
    toAAfterB ← subtract baselineA <$> presentsOf rig attachmentA
    pure (published, second, baselineB, toBAfterA, toAAfterB, (a, attachmentA, attachmentB))
  let (a, attachmentA, attachmentB) = attachments
  first `shouldBe` WindowScenePublished a 1
  case second of
    WindowScenePublished _ 1 → pure ()
    other → failWith ("window B's first publication was " <> show other <> ", not revision 1: revisions rise independently")
  -- A's publication presented a frame to A and none to B; B's later one
  -- presented to B and none more to A.
  toBAfterA `shouldBe` 0
  toAAfterB `shouldBe` 1
  toBBefore `shouldSatisfy` (>= 0)
  -- Each frame was recorded with its own window's scene and revision.
  rendered ← readTVarIO seen
  [(attachment, scene, revision) | (attachment, scene, revision) ← rendered, scene /= 0]
    `shouldBe` [(attachmentA, 11, 1), (attachmentB, 22, 1)]
  -- And the revision a frame was presented with is its window's.
  events ← frameEvents rig
  [(attachment, revision) | FramePresentRequested attachment _ _ revision ← events, revision /= 0]
    `shouldBe` [(attachmentA, 1), (attachmentB, 1)]

testRefusals ∷ IO ()
testRefusals = do
  perWindow ← scenesRig 2
  (shared, windowId, unknown, ended) ← runRig perWindow $ \host control → do
    (a, _, b, _) ← attachBoth perWindow host control
    shared ← prepare 5 >>= publishVulkanScene host
    -- A window that has ended is a window the host no longer holds.
    CloseStarted ← closeHostWindow (vulkanWindowHost host) b
    composedUntil perWindow host control "the second window's end" ((notElem b) <$> windowsOf host)
    unknown ← publishTo host b 9
    -- Nothing was changed by the refusals: the first window's first
    -- publication is still revision 1.
    first ← publishTo host a 1
    pure (shared, a, (unknown, b), first)
  shared `shouldBe` SceneRefusedPerWindow
  case unknown of
    (WindowSceneUnknown named, window) → named `shouldBe` window
    (other, _) → failWith ("a publication for an ended window was " <> show other)
  ended `shouldBe` WindowScenePublished windowId 1
  sharedRig ← visibleRigOf 1
  refused ← runRig sharedRig $ \host _ → do
    [window] ← windowsOf host
    (,) window <$> publishTo host window 3
  snd refused `shouldBe` WindowScenesNotEnabled (fst refused)

testPublicationSurvivesReattachment ∷ IO ()
testPublicationSurvivesReattachment = do
  rig ← scenesRig 1
  (first, second, events) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← attach host window
    composedUntil rig host control "the first adoption" ((not . null) <$> (flip adoptedBy window <$> sceneEvents rig))
    _ ← publishTo host window 41
    composedUntil rig host control "the publication's adoption" ((>= 2) . length . flip adoptedBy window <$> sceneEvents rig)
    -- Release the attachment and attach the window again: a fresh attachment
    -- incarnation, under which the window's publication is still revision 1.
    _ ← releaseGraphicsTarget (vulkanWindowHost host) (vulkanGraphicsOwner host) service
    _ ← awaitTerminal host service
    composedUntil rig host control "the first target's release" ((>= 1) . length . flip releasedBy window <$> sceneEvents rig)
    again ← attach host window
    composedUntil rig host control "the reattached target's adoption" ((>= 3) . length . flip adoptedBy window <$> sceneEvents rig)
    events ← sceneEvents rig
    pure (graphicsAttachment service, graphicsAttachment again, events)
  [window] ← case nub [at | SceneAdopted at _ _ ← events] of
    [only] → pure [only]
    other → failWith ("expected one window, saw " <> show other)
  -- The reattached target adopted the publication the first one had: the
  -- same revision and the exact scene, again, under a different attachment.
  adoptedBy events window `shouldBe` [(0, 0), (1, 41), (1, 41)]
  first `shouldSatisfy` (/= second)

-- ---------------------------------------------------------------------------
-- Adoption and release

testAdoption ∷ IO ()
testAdoption = do
  rig ← scenesRig 2
  seen ← newTVarIO []
  renderWith rig (recording seen)
  (events, suspendedAdopted, presentedWhileSuspended, initialFrames) ← runRig rig $ \host control → do
    (a, sa, _, sb) ← attachBoth rig host control
    initial ← sceneEvents rig
    initialFrames ← (+) <$> presentsOf rig (graphicsAttachment sa) <*> presentsOf rig (graphicsAttachment sb)
    -- Hide the windows: the targets are suspended.
    hidden ← newTVarIO False
    forkAndSet (setVisible rig host a False) hidden
    composedUntil rig host control "the suspension" ((&&) <$> readTVarIO hidden <*> targetSuspended host sa)
    before ← presentsOf rig (graphicsAttachment sa)
    _ ← publishTo host a 77
    composedUntil rig host control "the suspended window's adoption" (isJust . lookup 1 . flip adoptedBy a <$> sceneEvents rig)
    settleOwner rig host
    after ← presentsOf rig (graphicsAttachment sa)
    events ← sceneEvents rig
    pure (events, initial, after - before, initialFrames)
  -- Both targets adopted the initial scene, as revision 0, with no
  -- publication behind it, and asked for no frame by it.
  [(revision, scene) | SceneAdopted _ revision scene ← suspendedAdopted] `shouldBe` [(0, 0), (0, 0)]
  initialFrames `shouldBe` 0
  -- The suspended window adopted the publication and rendered nothing of it.
  presentedWhileSuspended `shouldBe` 0
  length [() | SceneAdopted _ 1 77 ← events] `shouldBe` 1

-- | Run an action on another thread, and set the flag once it has returned.
forkAndSet ∷ IO () → TVar Bool → IO ()
forkAndSet action flag = void (forkIO (action >> atomically (writeTVar flag True)))

-- | Every adoption and release the host's lifecycle reported, once the host
-- has ended.
adoptedPairs ∷ [SceneEvent] → [(WindowId, Natural)]
adoptedPairs events = [(window, revision) | SceneAdopted window revision _ ← events]

testSkippedRevisions ∷ IO ()
testSkippedRevisions = do
  rig ← scenesRig 1
  runRig rig $ \host control → do
    [window] ← windowsOf host
    _ ← attach host window
    composedUntil rig host control "the first adoption" (not . null . flip adoptedBy window <$> sceneEvents rig)
    first ← prepare 51
    second ← prepare 52
    -- Two publications in one transaction: the owner can take only the
    -- second, and the first is replaced before any step could.
    published ← atomically ((,) <$> publishGraphicsWindowScene (vulkanGraphicsOwner host) window first <*> publishGraphicsWindowScene (vulkanGraphicsOwner host) window second)
    published `shouldBe` (WindowScenePublished window 1, WindowScenePublished window 2)
    composedUntil rig host control "the second publication's adoption" ((>= 2) . length . flip adoptedBy window <$> sceneEvents rig)
    _ ← publishTo host window 53
    composedUntil rig host control "the third publication's adoption" ((>= 3) . length . flip adoptedBy window <$> sceneEvents rig)
    settleOwner rig host
  -- Read once the host has ended, so the owner's retirement is behind it.
  events ← sceneEvents rig
  [window] ← case nub (map fst (adoptedPairs events)) of
    [only] → pure [only]
    other → failWith ("expected one window, saw " <> show other)
  -- Revision 1 was published and replaced before it was adopted: it was never
  -- adopted, so it was never notified and is never released.
  adoptedBy events window `shouldBe` [(0, 0), (2, 52), (3, 53)]
  -- Each adopted revision is released once, in adoption order, the last at
  -- the owner's retirement.
  releasedBy events window `shouldBe` [0, 2, 3]

testReleaseAfterCompletion ∷ IO ()
testReleaseAfterCompletion = do
  rig ← scenesRig 1
  (beforeCompletion, afterCompletion, settled) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← attach host window
    composedUntil rig host control "the first adoption" (not . null . flip adoptedBy window <$> sceneEvents rig)
    -- No submission completes until the example lets it.
    submissionsComplete rig False
    baseline ← presentsOf rig (graphicsAttachment service)
    _ ← publishTo host window 61
    composedUntil rig host control "the first revision's frame" ((> baseline) <$> presentsOf rig (graphicsAttachment service))
    _ ← publishTo host window 62
    composedUntil rig host control "the second revision's adoption" ((>= 3) . length . flip adoptedBy window <$> sceneEvents rig)
    settleOwner rig host
    -- Revision 1 is superseded, and a frame recorded with it is in flight:
    -- only revision 0, which no frame was recorded with, is released.
    beforeCompletion ← flip releasedBy window <$> sceneEvents rig
    submissionsComplete rig True
    composedUntil rig host control "the completion's release" ((>= 2) . length . flip releasedBy window <$> sceneEvents rig)
    settleOwner rig host
    afterCompletion ← flip releasedBy window <$> sceneEvents rig
    settled ← flip releasedBy window <$> sceneEvents rig
    pure (beforeCompletion, afterCompletion, settled)
  beforeCompletion `shouldBe` [0]
  -- Released once the frame completed, and exactly once however long the
  -- owner went on: revision 2 is still the window's current one.
  afterCompletion `shouldBe` [0, 1]
  settled `shouldBe` [0, 1]

testAbandonedFrameKeepsRevision ∷ IO ()
testAbandonedFrameKeepsRevision = do
  rig ← scenesRig 1
  (whileAbandoned, afterCompletion) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← attach host window
    composedUntil rig host control "the first adoption" (not . null . flip adoptedBy window <$> sceneEvents rig)
    submissionsComplete rig False
    -- The presentation enqueues nothing: the frame is abandoned after its
    -- submission, which has not completed.
    scriptPresentStatus rig PresentStatusOutOfMemory
    raiseOnPresent rig (toException StandInNotPresented)
    _ <- publishTo host window 71
    composedUntil rig host control "the abandoned frame" $ do
      events ← frameEvents rig
      pure (not (null [() | FrameAbandoned attachment _ _ ← events, attachment == graphicsAttachment service]))
    scriptPresentStatus rig PresentStatusSuccess
    _ ← publishTo host window 72
    composedUntil rig host control "the second revision's adoption" ((>= 3) . length . flip adoptedBy window <$> sceneEvents rig)
    settleOwner rig host
    -- Revision 1 is superseded and its frame was abandoned, but the commands
    -- may still be executing: abandonment is not release.
    whileAbandoned ← flip releasedBy window <$> sceneEvents rig
    submissionsComplete rig True
    composedUntil rig host control "the submission's completion" ((>= 2) . length . flip releasedBy window <$> sceneEvents rig)
    afterCompletion ← flip releasedBy window <$> sceneEvents rig
    pure (whileAbandoned, afterCompletion)
  whileAbandoned `shouldBe` [0]
  afterCompletion `shouldBe` [0, 1]

testReleaseAtEnd ∷ IO ()
testReleaseAtEnd = do
  rig ← scenesRig 2
  (windowA, windowB, whileRunning) ← runRig rig $ \host control → do
    (a, sa, b, sb) ← attachBoth rig host control
    _ ← publishTo host a 81
    _ ← publishTo host b 82
    composedUntil rig host control "both frames" $ do
      forA ← presentsOf rig (graphicsAttachment sa)
      forB ← presentsOf rig (graphicsAttachment sb)
      pure (forA >= 1 && forB >= 1)
    -- The first window ends: its target ends with it, and the revision it
    -- held is released once every frame recorded with it has completed.
    CloseStarted ← closeHostWindow (vulkanWindowHost host) a
    composedUntil rig host control "the first window's end" (notElem a <$> windowsOf host)
    composedUntil rig host control "the first window's release" ((>= 2) . length . flip releasedBy a <$> sceneEvents rig)
    settleOwner rig host
    events ← sceneEvents rig
    pure (a, b, (releasedBy events a, releasedBy events b))
  events ← sceneEvents rig
  fst whileRunning `shouldBe` [0, 1]
  -- The second window's current revision was still held while it ran.
  snd whileRunning `shouldBe` [0]
  -- At the owner's retirement it was released, and nothing was released twice
  -- or without having been adopted.
  releasedBy events windowB `shouldBe` [0, 1]
  releasedBy events windowA `shouldBe` [0, 1]
  sort [(window, revision) | SceneReleased window revision ← events] `shouldBe` sort (adoptedPairs events)

-- ---------------------------------------------------------------------------
-- Release requests

testRequestWaitsForAdoption ∷ IO ()
testRequestWaitsForAdoption = do
  rig ← scenesRig 2
  (barrier, published, adoptedAtRequest, seenAtRun, after) ← runRig rig $ \host control → do
    (a, _, b, _) ← attachBoth rig host control
    _ ← publishTo host b 91
    composedUntil rig host control "B showing revision 1" ((>= 2) . length . flip adoptedBy b <$> sceneEvents rig)
    second ← prepare 92
    -- The publication and the request are one fact: the request waits for
    -- the revision just published, which the owner has not yet taken.
    (published, ticket, state) ← atomically $ do
      p ← publishGraphicsWindowScene (vulkanGraphicsOwner host) b second
      t ← requestVulkanRelease (vulkanController host) (VulkanAction (\_ → readTVarIO (rigSceneEvents rig)))
      s ← readVulkanSceneState (vulkanController host)
      pure (p, t, s)
    held ← either (\refusal → failWith ("refused: " <> show refusal)) pure ticket
    composedUntil rig host control "the request's run" (isJust <$> ranWith held)
    seen ← ranWith held >>= maybe (failWith "the request did not run") pure
    after ← atomically (readVulkanSceneState (vulkanController host))
    pure ((a, b, state), published, state, seen, after)
  let (a, b, state) = barrier
  published `shouldBe` WindowScenePublished b 2
  case sceneRequests adoptedAtRequest of
    [named] → do
      Map.lookup b named `shouldBe` Just 2
      Map.lookup a named `shouldBe` Just 0
    other → failWith ("expected one pending request, saw " <> show other)
  fmap windowPublished (Map.lookup b (sceneWindows state)) `shouldBe` Just (Just 2)
  fmap windowAdopted (Map.lookup b (sceneWindows state)) `shouldBe` Just (Just 1)
  -- It ran only after B had adopted revision 2.
  adoptedBy seenAtRun b `shouldBe` [(0, 0), (1, 91), (2, 92)]
  sceneRequests after `shouldBe` []

testRequestOrderAndWindowEnd ∷ IO ()
testRequestOrderAndWindowEnd = do
  rig ← scenesRig 3
  (barriers, whileHeld, finished) ← runRig rig $ \host control → do
    windows ← windowsOf host
    c ← case drop 2 windows of
      third : _ → pure third
      [] → failWith "the host holds fewer than three windows"
    (a, _, b, _) ← attachBoth rig host control
    -- A window with a publication and no target: nothing adopts it until the
    -- window ends.
    held ← publishTo host c 1
    held `shouldBe` WindowScenePublished c 1
    ran ← newTVarIO []
    _ ← request host (mark ran "first")
    _ ← request host (mark ran "second")
    _ ← atomically (submitVulkanAction (vulkanController host) (mark ran "plain")) >>= either (\refusal → failWith ("refused: " <> show refusal)) pure
    composedUntil rig host control "the plain action's run" ((== ["plain"]) <$> readTVarIO ran)
    settleOwner rig host
    whileHeld ← readTVarIO ran
    -- Requests that cannot start are not work: the owner they are queued for
    -- names no deadline and owes nothing at once, and takes no round while it
    -- waits. The one bounded wait for something not to happen: a spinning
    -- owner would take round after round in this time.
    idle ← atomically (readOwnerStatusNow (vulkanGraphicsOwner host))
    expired ← registerDelay 100000
    spun ← atomically $
      (True <$ (readOwnerStatusNow (vulkanGraphicsOwner host) >>= check . (> statusRounds idle + 2) . statusRounds))
        `orElse` (False <$ (readTVar expired >>= check))
    spun `shouldBe` False
    (statusNextDeadline idle, statusImmediate idle) `shouldBe` (Nothing, False)
    state ← atomically (readVulkanSceneState (vulkanController host))
    CloseStarted ← closeHostWindow (vulkanWindowHost host) c
    composedUntil rig host control "the first window's end" (notElem c <$> windowsOf host)
    composedUntil rig host control "both requests" ((== 3) . length <$> readTVarIO ran)
    finished ← readTVarIO ran
    pure ((a, b, c, sceneRequests state), whileHeld, finished)
  let (a, b, c, requests) = barriers
  -- Held while C's publication was unadopted, behind neither each other nor
  -- the action admitted after them.
  whileHeld `shouldBe` ["plain"]
  length requests `shouldBe` 2
  forM_' requests $ \named →
    named `shouldBe` Map.fromList [(a, 0), (b, 0), (c, 1)]
  -- The window's end released them, in the order they were made.
  finished `shouldBe` ["plain", "first", "second"]

-- | A request names every window the host holds, whether or not it has a
-- target or a publication yet: the scene it holds may be adopted by a target
-- attached later, and must find what it references still there.
testTargetlessWindowHolds ∷ IO ()
testTargetlessWindowHolds = do
  perWindow ← scenesRig 3
  shared ← visibleRigOf 3
  forM_' [(perWindow, 0), (shared, 0)] $ \(rig, expected) → do
    (named, whileHeld, afterEnd) ← runRig rig $ \host control → do
      windows ← windowsOf host
      c ← case drop 2 windows of
        third : _ → pure third
        [] → failWith "the host holds fewer than three windows"
      (a, _, b, _) ← attachBoth rig host control
      ran ← newTVarIO []
      -- C has no target and no publication.
      _ ← request host (mark ran "request")
      state ← atomically (readVulkanSceneState (vulkanController host))
      _ ← atomically (submitVulkanAction (vulkanController host) (mark ran "plain")) >>= either (\refusal → failWith ("refused: " <> show refusal)) pure
      composedUntil rig host control "the plain action's run" ((== ["plain"]) <$> readTVarIO ran)
      settleOwner rig host
      whileHeld ← readTVarIO ran
      CloseStarted ← closeHostWindow (vulkanWindowHost host) c
      composedUntil rig host control "the request after C's end" (notElem c <$> windowsOf host)
      composedUntil rig host control "the request's run" ((== 2) . length <$> readTVarIO ran)
      afterEnd ← readTVarIO ran
      pure ((a, b, c, sceneRequests state), whileHeld, afterEnd)
    let (a, b, c, requests) = named
    requests `shouldBe` [Map.fromList [(a, expected), (b, expected), (c, expected)]]
    whileHeld `shouldBe` ["plain"]
    afterEnd `shouldBe` ["plain", "request"]

-- | A host that declares its initial scene references nothing a release
-- request releases is not held by a window that has never published: in a
-- per-window host one with no publication, in a shared host every window while
-- the shared scene is unpublished. The request runs at the next owner step and
-- names nothing, though the observation still reports revision 0. A window that
-- has published, with no live target, is named as ever, and holds every later
-- request until a target of it adopts the barrier's revision or the host drops
-- the window; publishing another blank scene is a publication too.
testNeverPublishedWindowLeavesBarrier ∷ IO ()
testNeverPublishedWindowLeavesBarrier =
  forM_' [(label, build, publish, adopt, value) | (label, build, publish) ← hosts, (adopt, value) ← [(True, 5), (False, 5), (True, 0)]] $ \(label, build, publish, adopt, value) → do
    rig ← withInitialSceneHoldsNothing <$> build
    (unpublished, afterPublish, order) ← runRig rig $ \host control → do
      windows ← windowsOf host
      c ← case drop 2 windows of
        third : _ → pure third
        [] → failWith "the host holds fewer than three windows"
      (a, _, b, _) ← attachBoth rig host control
      ran ← newTVarIO []
      -- C has no target, and nothing has been published: the request names no
      -- window, and runs without any window adopting anything.
      _ ← request host (mark ran "never published")
      beforeRun ← atomically (readVulkanSceneState (vulkanController host))
      composedUntil rig host control "the request's run" ((== ["never published"]) <$> readTVarIO ran)
      -- C publishes. It still has no target, so the next request is held to it.
      _ ← publish host c value
      _ ← request host (mark ran "published")
      afterPublish ← atomically (readVulkanSceneState (vulkanController host))
      _ ← atomically (submitVulkanAction (vulkanController host) (mark ran "plain")) >>= either (\refusal → failWith ("refused: " <> show refusal)) pure
      composedUntil rig host control "the plain action's run" ((== ["never published", "plain"]) <$> readTVarIO ran)
      settleOwner rig host
      whileHeld ← readTVarIO ran
      if adopt
        then void (attach host c)
        else do
          CloseStarted ← closeHostWindow (vulkanWindowHost host) c
          pure ()
      composedUntil rig host control "the held request's run" ((== 3) . length <$> readTVarIO ran)
      finished ← readTVarIO ran
      pure ((a, b, c, beforeRun), (afterPublish, whileHeld), finished)
    let (a, b, c, beforeRun) = unpublished
    -- Observed unfiltered: C's published revision is still 0.
    (label, fmap windowPublished (Map.lookup c (sceneWindows beforeRun))) `shouldBe` (label, Just (Just 0))
    (label, sceneRequests beforeRun) `shouldBe` (label, [Map.empty])
    let (published, whileHeld) = afterPublish
    -- The request made after C published names it, at its revision, and the
    -- window with no target holds it however long it waits.
    -- In a shared host the one scene is every window's, so the others are
    -- named at its revision too; in a per-window host only C is.
    (label, sceneRequests published)
      `shouldBe` (label, [Map.fromList ([(c, 1)] <> [(window, 1) | sharedHost label, window ← [a, b]])])
    (label, whileHeld) `shouldBe` (label, ["never published", "plain"])
    (label, order) `shouldBe` (label, ["never published", "plain", "published"])
  where
    hosts ∷ [(String, IO Rig, VulkanHost Scene → WindowId → Scene → IO ())]
    hosts =
      [ ("a per-window host", scenesRig 3, \host window scene → void (publishTo host window scene))
      , ("a shared host", visibleRigOf 3, \host _ scene → void (prepare scene >>= publishVulkanScene host))
      ]
    sharedHost ∷ String → Bool
    sharedHost label = label == "a shared host"

testRequestIgnoresLaterWindow ∷ IO ()
testRequestIgnoresLaterWindow = do
  rig ← scenesRig 3
  (requests, created, finished) ← runRig rig $ \host control → do
    windows ← windowsOf host
    c ← case drop 2 windows of
      third : _ → pure third
      [] → failWith "the host holds fewer than three windows"
    _ ← attachBoth rig host control
    ran ← newTVarIO []
    _ ← request host (mark ran "request")
    state ← atomically (readVulkanSceneState (vulkanController host))
    -- A window created after the request, with a publication nothing will
    -- adopt: it is not named, and delays nothing once C ends.
    submitted ← newTVarIO False
    forkAndSet (void (awaitSubmitWindowCommand (hostCommandPort (vulkanWindowHost host)) [("client", "integration-tests")] (createWindowCommand (hiddenTestWindowConfig "created later" 64 48)))) submitted
    composedUntil rig host control "the created window" ((== 4) . length <$> windowsOf host)
    later ← filter (`notElem` windows) <$> windowsOf host
    late ← case later of
      [one] → pure one
      other → failWith ("expected one new window, saw " <> show other)
    published ← publishTo host late 9
    published `shouldBe` WindowScenePublished late 1
    CloseStarted ← closeHostWindow (vulkanWindowHost host) c
    composedUntil rig host control "the request's run" ((== ["request"]) <$> readTVarIO ran)
    pure (sceneRequests state, late, ())
  case requests of
    [named] → Map.member created named `shouldBe` False
    other → failWith ("expected one pending request, saw " <> show other)
  finished `shouldBe` ()

forM_' ∷ [a] → (a → IO ()) → IO ()
forM_' items body = mapM_ body items

testRequestSharedMode ∷ IO ()
testRequestSharedMode = do
  rig ← visibleRigOf 2
  (named, windows, seenAtRun) ← runRig rig $ \host control → do
    (a, _, b, _) ← attachBoth rig host control
    scene ← prepare 31
    (published, ticket, state) ← atomically $ do
      p ← publishOwnerScene (ownerHandoff (vulkanGraphicsOwner host)) scene
      t ← requestVulkanRelease (vulkanController host) (VulkanAction (\_ → readTVarIO (rigSceneEvents rig)))
      s ← readVulkanSceneState (vulkanController host)
      pure (p, t, s)
    published `shouldBe` ScenePublication Published
    held ← either (\refusal → failWith ("refused: " <> show refusal)) pure ticket
    composedUntil rig host control "the request's run" (isJust <$> ranWith held)
    seen ← ranWith held >>= maybe (failWith "the request did not run") pure
    pure (sceneRequests state, (a, b), seen)
  let (a, b) = windows
  -- The shared scene's revision is every window's.
  named `shouldBe` [Map.fromList [(a, 1), (b, 1)]]
  adoptedBy seenAtRun a `shouldBe` [(0, 0), (1, 31)]
  adoptedBy seenAtRun b `shouldBe` [(0, 0), (1, 31)]

testRequestAdmission ∷ IO ()
testRequestAdmission = do
  early ← scenesRig 1
  refusedEarly ← runRig early $ \host _ →
    either Just (const Nothing) <$> atomically (requestVulkanRelease (vulkanController host) (VulkanAction (\_ → pure ())))
  refusedEarly `shouldBe` Just ActionDeviceNotReady
  rig ← withReleaseCapacity 1 . withActionCapacity 1 <$> scenesRig 3
  ran ← newTVarIO []
  (full, ticket, controller) ← runRig rig $ \host control → do
    windows ← windowsOf host
    c ← case drop 2 windows of
      third : _ → pure third
      [] → failWith "the host holds fewer than three windows"
    _ ← attachBoth rig host control
    _ ← publishTo host c 1
    held ← request host (mark ran "held")
    -- The queue holds its whole release capacity: one more request is refused
    -- at once, and nothing waits for room. The queued request is no action's
    -- business: an action is admitted against its own bound, which a held
    -- request does not count toward, and so it is refused only once the
    -- actions themselves fill it.
    full ← atomically (requestVulkanRelease (vulkanController host) (mark ran "full"))
    plain ← atomically (submitVulkanAction (vulkanController host) (mark ran "plain"))
    pure ((either Just (const Nothing) full, either Just (const Nothing) plain), held, vulkanController host)
  fst full `shouldBe` Just ReleaseQueueFull
  snd full `shouldBe` Nothing
  -- Still queued when the owner's exit began, it was refused and never run;
  -- and the closed owner admits no more.
  atomically (readVulkanAction ticket) >>= \case
    Just (ActionRefused ActionOwnerClosed) → pure ()
    _ → failWith "the queued request was not settled as refused by the owner's closing"
  -- The admitted action may have run before the exit; the refused request
  -- and the held one never did.
  readTVarIO ran >>= (`shouldSatisfy` all (== "plain"))
  late ← atomically (requestVulkanRelease controller (VulkanAction (\_ → pure ())))
  either Just (const Nothing) late `shouldBe` Just ActionOwnerClosed

testPublicationAcrossRecovery ∷ IO ()
testPublicationAcrossRecovery = do
  rig ← scenesRig 1
  (attachments, before, after) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← attach host window
    composedUntil rig host control "a presenting generation" (generationPresenting host service)
    _ ← publishTo host window 55
    composedUntil rig host control "the first frame" ((>= 1) <$> presentsOf rig (graphicsAttachment service))
    swapchain ← activeSwapchainOf host service
    -- The target's surface is lost and replaced on the same live window, under
    -- the same attachment.
    Just active ← (>>= viewActive) <$> atomically (readVulkanGenerations (vulkanController host) (graphicsAttachment service))
    noted ← atomically (noteVulkanSwapchainResult (vulkanController host) active SwapchainSurfaceLost)
    noted `shouldBe` True
    nudgeOwner rig host service window
    composedUntil rig host control "the replacement's generation" ((&&) <$> generationPresenting host service <*> ((\now → now /= Nothing && now /= Just swapchain) <$> activeSwapchainNow host service))
    _ ← publishTo host window 56
    composedUntil rig host control "the next publication's adoption" ((>= 3) . length . flip adoptedBy window <$> sceneEvents rig)
    settleOwner rig host
    events ← sceneEvents rig
    targets ← atomically (readVulkanTargets (vulkanController host))
    pure ([attachment | (attachment, _) ← targets], adoptedBy events window, releasedBy events window)
  attachments `shouldSatisfy` ((== 1) . length)
  -- Recovery keeps the attachment and its target, so it re-adopts nothing: the
  -- window's publications are adopted once each, in order.
  before `shouldBe` [(0, 0), (1, 55), (2, 56)]
  -- And it releases nothing but what a publication superseded.
  after `shouldBe` [0, 1]

-- | The swapchain of the target's active generation, if it has one now.
activeSwapchainNow ∷ VulkanHost Scene → GraphicsService → IO (Maybe Word64)
activeSwapchainNow host service = do
  view ← atomically (readVulkanGenerations (vulkanController host) (graphicsAttachment service))
  pure $ do
    held ← view
    case [handle | generation ← viewGenerations held, Just (viewGeneration generation) == viewActive held, Just handle ← [viewSwapchain generation]] of
      handle : _ → Just handle
      [] → Nothing

activeSwapchainOf ∷ VulkanHost Scene → GraphicsService → IO Word64
activeSwapchainOf host service = activeSwapchainNow host service >>= maybe (failWith "the target has no active swapchain") pure

testReleaseOrder ∷ IO ()
testReleaseOrder = do
  rig ← scenesRig 1
  (held, released) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← attach host window
    composedUntil rig host control "the first adoption" (not . null . flip adoptedBy window <$> sceneEvents rig)
    submissionsComplete rig False
    baseline ← presentsOf rig (graphicsAttachment service)
    -- Two frames in flight, one of each revision, neither complete.
    _ ← publishTo host window 31
    composedUntil rig host control "the first frame" ((> baseline) <$> presentsOf rig (graphicsAttachment service))
    _ ← publishTo host window 32
    composedUntil rig host control "the second frame" ((> baseline + 1) <$> presentsOf rig (graphicsAttachment service))
    _ ← publishTo host window 33
    composedUntil rig host control "the third revision's adoption" ((>= 4) . length . flip adoptedBy window <$> sceneEvents rig)
    settleOwner rig host
    held ← flip releasedBy window <$> sceneEvents rig
    submissionsComplete rig True
    composedUntil rig host control "both releases" ((>= 3) . length . flip releasedBy window <$> sceneEvents rig)
    settleOwner rig host
    released ← flip releasedBy window <$> sceneEvents rig
    pure (held, released)
  -- Only the revision no frame was recorded with could go.
  held `shouldBe` [0]
  -- The rest went in the order they were adopted, each once, revision 3 still
  -- being the window's current one.
  released `shouldBe` [0, 1, 2]

testRequestAfterFailure ∷ IO ()
testRequestAfterFailure = requestAfterFailure False

testRequestAfterFailureWhileIdle ∷ IO ()
testRequestAfterFailureWhileIdle = requestAfterFailure True

-- | A validation error is reported while a release request waits, and the
-- session fails: the request that never started is settled as refused by the
-- failure, and a request made after it is refused at once.
--
-- The owner latches the error at its next checkpoint, and reporting it wakes
-- nobody (the latch table in docs/gpu_backend.md). The one thing queued is a
-- release request blocked on its barrier, which wakes no idle owner either. So
-- an owner that has ended the round that took the publication before the error
-- is reported is never asked for another, and the wait for its failure never
-- ends; whether that happens used to be down to the scheduler (it left the
-- example running into its bound once on Linux CI, #438). The example reports
-- the error and then gives the owner a round as an application does, by
-- publishing the window's next scene. With @idle@ it first waits for the owner
-- to have ended its last round with nothing owed, which is the interleaving
-- that stalled.
requestAfterFailure ∷ Bool → IO ()
requestAfterFailure idle = do
  rig ← withPerWindowScenes <$> surfaceFreeRig 1
  observed ← newTVarIO Nothing
  outcome ← runRigCaught rig $ \host control → do
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    atomically (readReadiness (vulkanController host) >>= check . (== RootsReady))
    [window] ← windowsOf host
    -- A window with a publication and no target: nothing adopts it, so the
    -- request is still queued when the session fails.
    published ← publishTo host window 1
    published `shouldBe` WindowScenePublished window 1
    queued ← request host (VulkanAction (\_ → pure ()))
    when idle (awaitIdleOwner host)
    reportErrorNow rig "an error while a request waits"
    -- The round that takes the error. Its answer does not matter: the window
    -- may already have ended with the session.
    _ ← publishTo host window 2
    atomically (readOwnerFailure (vulkanGraphicsOwner host) >>= check . isJust)
    settled ← atomically (awaitVulkanAction queued)
    later ← atomically (requestVulkanRelease (vulkanController host) (VulkanAction (\_ → pure ())))
    atomically (writeTVar observed (Just (settledAs settled, either Just (const Nothing) later)))
    checkRuntime control
  case outcome of
    Left _ → pure ()
    Right _ → failWith "the run returned instead of failing with the session's failure"
  readTVarIO observed
    >>= (`shouldBe` Just (Just TerminalValidationError, Just (ActionSessionFailed TerminalValidationError)))
  where
    settledAs = \case
      ActionRefused (ActionSessionFailed cause) → Just cause
      _ → Nothing

-- | Wait until the owner has ended a round that began after everything this
-- thread did so far, with nothing left to ask it for another.
--
-- An action with no barrier runs in a round of the owner's, and that round
-- counts the rounds ended before it (the idiom 'settleOwner' uses for a
-- scene event). The first action settles inside some round; the second is
-- admitted after that, so it runs in a later round, one that began after the
-- caller's earlier publications and admissions were made and read them. When
-- that round has ended the owner is waiting for a wake, and none is owed: the
-- release request that waits wakes no one.
awaitIdleOwner ∷ VulkanHost Scene → IO ()
awaitIdleOwner host = do
  _ ← inRound
  rounds ← inRound
  void (atomically (awaitOwnerRound (vulkanGraphicsOwner host) rounds))
  where
    owner = vulkanGraphicsOwner host
    inRound = do
      seen ← newTVarIO 0
      ticket ←
        atomically (submitVulkanAction (vulkanController host) (VulkanAction (\_ → atomically (readOwnerStatusNow owner >>= writeTVar seen . statusRounds))))
          >>= either (\refusal → failWith ("the action was refused: " <> show refusal)) pure
      atomically (awaitVulkanAction ticket) >>= \case
        ActionReturned () → readTVarIO seen
        _ → failWith "the action did not return"

-- ---------------------------------------------------------------------------
-- Retention, cancellation and teardown

testRetentionBound ∷ IO ()
testRetentionBound = do
  rig ← scenesRig 1
  slots ← either (const (failWith "the default budgets are invalid")) (pure . frameSlotLimit) (validateBudgets defaultBudgetRequest)
  let bound = retentionLimit slots
      extra = 5 ∷ Natural
  atLimit ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← attach host window
    composedUntil rig host control "the first adoption" (not . null . flip adoptedBy window <$> sceneEvents rig)
    submissionsComplete rig False
    baseline ← presentsOf rig (graphicsAttachment service)
    _ ← publishTo host window 1
    composedUntil rig host control "the first revision's frame" ((> baseline) <$> presentsOf rig (graphicsAttachment service))
    let standingOf = (Map.lookup window . sceneWindows) <$> atomically (readVulkanSceneState (vulkanController host))
        adoptedAt = maybe Nothing windowAdopted <$> standingOf
    -- One submission has not completed, so no revision adopted after the first
    -- is released: each adoption the target may make, it makes, until its
    -- record is full.
    forM_' [2 .. bound] $ \revision → do
      _ ← publishTo host window (fromIntegral revision)
      composedUntil rig host control "the next adoption" ((== Just revision) <$> adoptedAt)
    -- Publications beyond it replace each other in the window's snapshot, and
    -- the target defers adopting any of them: the ledger says so.
    forM_' [bound + 1 .. bound + extra] $ \revision → void (publishTo host window (fromIntegral revision))
    composedUntil rig host control "an adoption deferred at the limit" $
      (maybe False ((>= 1) . windowDeferrals)) <$> standingOf
    atLimit ← standingOf
    -- Completion makes room, and the target catches up with the latest.
    submissionsComplete rig True
    composedUntil rig host control "the latest revision's adoption" ((== Just (bound + extra)) <$> adoptedAt)
    settleOwner rig host
    pure atLimit
  -- Read once the host has ended, so the owner's retirement is behind it.
  events ← sceneEvents rig
  fmap windowPublished atLimit `shouldBe` Just (Just (bound + extra))
  fmap windowAdopted atLimit `shouldBe` Just (Just bound)
  fmap (length . windowAwaitingRelease) atLimit `shouldSatisfy` (maybe False (< fromIntegral bound))
  [window] ← case nub [at | SceneAdopted at _ _ ← events] of
    [only] → pure [only]
    other → failWith ("expected one window, saw " <> show other)
  -- The revisions between were replaced in the snapshot and never adopted;
  -- the releases went in adoption order, each once.
  map fst (adoptedBy events window) `shouldBe` [0] <> [1 .. bound] <> [bound + extra]
  releasedBy events window `shouldBe` [0] <> [1 .. bound] <> [bound + extra]

-- | The ledger's two transitions, cancelled from outside while their hooks
-- run: the adoption is recorded, notified and published to the barrier, and the
-- release is removed and notified for every record it took, whatever cancels
-- the thread meanwhile.
testLedgerCancellation ∷ IO ()
testLedgerCancellation = do
  rig ← scenesRig 1
  (adoptedBeforeCancel, adoptedAfter, releasedAll) ← runRig rig $ \host _ → do
    [window] ← windowsOf host
    service ← attach host window
    let attachment = graphicsAttachment service
    scenes ← newScenes False
    atomically (registerSceneTarget scenes attachment)
    hooks ← newTVarIO ([] ∷ [String])
    entered ← newEmptyMVar
    proceed ← newEmptyMVar
    let lifecycle = SceneLifecycle
          { sceneAdopted = \_ revision _ → do
              atomically (modifyTVar' hooks (<> ["adopted " <> show revision]))
              putMVar entered ()
              takeMVar proceed
          , sceneReleased = \_ revision → do
              atomically (modifyTVar' hooks (<> ["released " <> show revision]))
              putMVar entered ()
              takeMVar proceed
          }
        cancelDuring action = do
          finished ← newEmptyMVar
          thread ← forkIO (try @SomeException (void action) >>= putMVar finished)
          takeMVar entered
          -- The cancellation is delivered once the transition ends, never in it:
          -- the thrower is blocked until then, and only then is the hook let go.
          cancelled ← forkIO (throwTo thread (ErrorCall "cancelled"))
          awaitSettled cancelled
          putMVar proceed ()
          takeMVar finished
    -- An adoption cancelled while its hook runs.
    _ ← cancelDuring (adoptScene scenes lifecycle 100 attachment (5 ∷ Scene) 3)
    standing ← atomically (readSceneState scenes (pure []))
    -- A second revision, then the target ends: two records are due, and the
    -- release is cancelled while the first one's hook runs.
    _ ← cancelDuring (adoptScene scenes lifecycle 100 attachment (6 ∷ Scene) 4)
    -- Take the second adoption's own cancellation out of the way: the thread
    -- it ran on is gone, and nothing is waiting on 'proceed'.
    atomically (endSceneTarget scenes attachment)
    finished ← newEmptyMVar
    thread ← forkIO (try @SomeException (releaseScenes scenes (sceneReleased lifecycle) (\_ _ → pure False)) >>= putMVar finished)
    takeMVar entered
    cancelled ← forkIO (throwTo thread (ErrorCall "cancelled"))
    awaitSettled cancelled
    putMVar proceed ()
    -- The second record's hook runs as well, though the first was cancelled.
    takeMVar entered
    putMVar proceed ()
    _ ← takeMVar finished
    after ← atomically (readSceneState scenes (pure []))
    done ← readTVarIO hooks
    pure (fmap windowAdopted (Map.lookup window (sceneWindows standing)), Just (maybe [] windowAwaitingRelease (Map.lookup window (sceneWindows after))), done)
  adoptedBeforeCancel `shouldBe` Just (Just 3)
  adoptedAfter `shouldBe` Just []
  releasedAll `shouldBe` ["adopted 3", "adopted 4", "released 3", "released 4"]

testTeardownDiscard ∷ IO ()
testTeardownDiscard = do
  -- A renderer that raises leaves its frame acquired with a partial recording.
  -- The owner's run ends; its teardown skips the frame, which discards the
  -- recording once the recorder's reset succeeds, and the revision is released
  -- at the target's retirement. (A refused skip discards nothing, so its use
  -- stays; the frames' retirement then never completes, which an example
  -- cannot end, so that half is the code's: the use is removed only on a skip
  -- that answered.)
  discarded ← scenesRig 1
  outcome ← runRigCaught discarded $ \host control → do
    [held] ← windowsOf host
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    _ ← attach host held
    composedUntil discarded host control "the first adoption" (not . null . flip adoptedBy held <$> sceneEvents discarded)
    renderWith discarded (VulkanRenderer (\_ _ _ _ → throwIO (StandInFailure "the renderer raised")))
    _ ← publishTo host held 77
    composedUntil discarded host control "the renderer's failure" (checkRuntime control >> pure False)
  either (const (pure ())) (const (failWith "the run returned instead of failing with the renderer's")) outcome
  events ← sceneEvents discarded
  [window] ← case nub [at | SceneAdopted at _ _ ← events] of
    [only] → pure [only]
    other → failWith ("expected one window, saw " <> show other)
  adoptedBy events window `shouldBe` [(0, 0), (1, 77)]
  releasedBy events window `shouldBe` [0, 1]

-- | Wait until a thread throwing an exception to another is blocked on its
-- delivery, or has delivered it.
awaitSettled ∷ ThreadId → IO ()
awaitSettled thread =
  threadStatus thread >>= \case
    ThreadBlocked BlockedOnException → pure ()
    ThreadFinished → pure ()
    ThreadDied → pure ()
    _ → yield >> awaitSettled thread

testLossKeepsRevision ∷ IO ()
testLossKeepsRevision = do
  rig ← scenesRig 1
  outcome ← runRigCaught rig $ \host control → do
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    [window] ← windowsOf host
    _ ← attach host window
    composedUntil rig host control "the first adoption" (not . null . flip adoptedBy window <$> sceneEvents rig)
    -- The frame's submission never completes, and its presentation reports the
    -- device lost: the loss lets the submission go, which is not completion.
    submissionsComplete rig False
    raiseOnPresent rig (toException (StandInLoss "vkQueuePresentKHR"))
    _ ← publishTo host window 91
    composedUntil rig host control "the loss at a checkpoint" (checkRuntime control >> pure False)
  either (const (pure ())) (const (failWith "the run returned instead of failing with the loss")) outcome
  events ← sceneEvents rig
  [window] ← case nub [at | SceneAdopted at _ _ ← events] of
    [only] → pure [only]
    other → failWith ("expected one window, saw " <> show other)
  adoptedBy events window `shouldBe` [(0, 0), (1, 91)]
  -- Revision 1 is the target's current one when it ends, but nothing verified
  -- the frame's commands over: it stays awaiting release.
  releasedBy events window `shouldBe` [0]

-- | The device is lost while a frame is being recorded: the unsubmitted
-- recording is let go of under the loss rule, which resets nothing, so no
-- discard is evidenced and the revision stays awaiting release.
testLossDuringRecording ∷ IO ()
testLossDuringRecording = do
  rig ← scenesRig 1
  outcome ← runRigCaught rig $ \host control → do
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    [window] ← windowsOf host
    _ ← attach host window
    composedUntil rig host control "the first adoption" (not . null . flip adoptedBy window <$> sceneEvents rig)
    loseWhileRecording rig
    _ ← publishTo host window 93
    composedUntil rig host control "the loss at a checkpoint" (checkRuntime control >> pure False)
  either (const (pure ())) (const (failWith "the run returned instead of failing with the loss")) outcome
  events ← sceneEvents rig
  [window] ← case nub [at | SceneAdopted at _ _ ← events] of
    [only] → pure [only]
    other → failWith ("expected one window, saw " <> show other)
  adoptedBy events window `shouldBe` [(0, 0), (1, 93)]
  releasedBy events window `shouldBe` [0]

-- | A window whose adopting target was released holds nothing, however long
-- ago its revision was adopted: a request made then waits until a target
-- adopts again, since the revision the window published is one that target
-- will take.
testDetachedWindowHoldsRequest ∷ IO ()
testDetachedWindowHoldsRequest = do
  perWindow ← scenesRig 1
  shared ← visibleRigOf 1
  declaringPerWindow ← withInitialSceneHoldsNothing <$> scenesRig 1
  declaringShared ← withInitialSceneHoldsNothing <$> visibleRigOf 1
  -- The declaration changes nothing here: the window has published, so a
  -- request names it, and the watermark of the target that ended counts for
  -- nothing.
  forM_' [(perWindow, \host window → void (publishTo host window 7)), (shared, \host _ → void (prepare 7 >>= publishVulkanScene host)), (declaringPerWindow, \host window → void (publishTo host window 7)), (declaringShared, \host _ → void (prepare 7 >>= publishVulkanScene host))] $ \(rig, publish) → do
    (whileDetached, afterReattach) ← runRig rig $ \host control → do
      [window] ← windowsOf host
      service ← attach host window
      composedUntil rig host control "the first adoption" (not . null . flip adoptedBy window <$> sceneEvents rig)
      publish host window
      composedUntil rig host control "the publication's adoption" ((>= 2) . length . flip adoptedBy window <$> sceneEvents rig)
      _ ← releaseGraphicsTarget (vulkanWindowHost host) (vulkanGraphicsOwner host) service
      _ ← awaitTerminal host service
      composedUntil rig host control "the target's release" ((>= 1) . length . flip releasedBy window <$> sceneEvents rig)
      ran ← newTVarIO []
      -- The window still publishes revision 1, and nothing holds it.
      _ ← request host (mark ran "request")
      _ ← atomically (submitVulkanAction (vulkanController host) (mark ran "plain")) >>= either (\refusal → failWith ("refused: " <> show refusal)) pure
      composedUntil rig host control "the plain action's run" ((== ["plain"]) <$> readTVarIO ran)
      settleOwner rig host
      whileDetached ← readTVarIO ran
      _ ← attach host window
      composedUntil rig host control "the request's run" ((== ["plain", "request"]) <$> readTVarIO ran)
      (,) whileDetached <$> readTVarIO ran
    whileDetached `shouldBe` ["plain"]
    afterReattach `shouldBe` ["plain", "request"]

-- | The owner is cancelled right after the frames accepted a submission, from
-- another thread, with its completion withheld. The cancellation lands when
-- the masked step that submits and associates it has ended, so the revision
-- is still held for a submission that has not completed, and is released once,
-- on the completion.
testCancelledAfterSubmission ∷ IO ()
testCancelledAfterSubmission = do
  rig ← scenesRig 1
  heldWhilePending ← runRigCaught rig $ \host control → do
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    [window] ← windowsOf host
    _ ← attach host window
    composedUntil rig host control "the first adoption" (not . null . flip adoptedBy window <$> sceneEvents rig)
    submissionsComplete rig False
    cancelOwnerAt rig CancelAfterSubmit
    _ ← publishTo host window 61
    atomically (ownerCancelled rig >>= check)
    -- The owner is gone, its submission not complete: nothing says the commands
    -- are over.
    pending ← flip releasedBy window <$> sceneEvents rig
    submissionsComplete rig True
    pending `shouldBe` [0]
    composedUntil rig host control "the owner's end" (checkRuntime control >> pure False)
  either (const (pure ())) (const (failWith "the run returned instead of failing with the cancellation")) heldWhilePending
  events ← sceneEvents rig
  [window] ← case nub [at | SceneAdopted at _ _ ← events] of
    [only] → pure [only]
    other → failWith ("expected one window, saw " <> show other)
  releasedBy events window `shouldBe` [0, 1]

testCancelledAfterCompletion ∷ IO ()
testCancelledAfterCompletion = do
  rig ← scenesRig 1
  outcome ← runRigCaught rig $ \host control → do
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    [window] ← windowsOf host
    _ ← attach host window
    composedUntil rig host control "the first adoption" (not . null . flip adoptedBy window <$> sceneEvents rig)
    cancelOwnerAt rig CancelAfterCompletion
    _ ← publishTo host window 62
    composedUntil rig host control "the owner's end" (checkRuntime control >> pure False)
  either (const (pure ())) (const (failWith "the run returned instead of failing with the cancellation")) outcome
  cancelled ← atomically (ownerCancelled rig)
  cancelled `shouldBe` True
  events ← sceneEvents rig
  [window] ← case nub [at | SceneAdopted at _ _ ← events] of
    [only] → pure [only]
    other → failWith ("expected one window, saw " <> show other)
  -- The completion was recorded before the step could return it: the evidence
  -- survived, and the revision was released once.
  releasedBy events window `shouldBe` [0, 1]

testCancelledAfterDiscard ∷ IO ()
testCancelledAfterDiscard = do
  rig ← scenesRig 1
  fired ← newTVarIO False
  outcome ← runRigCaught rig $ \host control → do
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    [window] ← windowsOf host
    _ ← attach host window
    composedUntil rig host control "the first adoption" (not . null . flip adoptedBy window <$> sceneEvents rig)
    -- The renderer refuses the frame: it is skipped, which resets and drops its
    -- recording, and the owner is cancelled as the abandonment is reported.
    refuseFrames rig True
    onFrameEvent rig $ \case
      FrameAbandoned {} → do
        first ← atomically (stateTVar fired (\held → (not held, True)))
        when first (cancelOwnerNow' rig)
      _ → pure ()
    _ ← publishTo host window 63
    composedUntil rig host control "the owner's end" (checkRuntime control >> pure False)
  either (const (pure ())) (const (failWith "the run returned instead of failing with the cancellation")) outcome
  events ← sceneEvents rig
  [window] ← case nub [at | SceneAdopted at _ _ ← events] of
    [only] → pure [only]
    other → failWith ("expected one window, saw " <> show other)
  releasedBy events window `shouldBe` [0, 1]
