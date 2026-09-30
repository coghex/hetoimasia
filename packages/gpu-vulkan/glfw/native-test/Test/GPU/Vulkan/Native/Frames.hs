{-# LANGUAGE OverloadedRecordDot #-}

-- | VK-12's native case: frames acquired, a triangle batch with its capture
-- submitted and awaited, and images returned without ever being presented —
-- on private roots, with validation reporting nothing.
--
-- The roots, the generations and the recording are VK-11's case's: the
-- production native layers, the validation layer with synchronization
-- validation, and one window's surface with a generation built for a
-- verification capture. Over them the production frames layer
-- ("Hetoimasia.GPU.Vulkan.Native.Frames.Vulkan"):
--
-- 1. acquires a frame through 'tryAcquireFrame', records the triangle into it
--    and the copy of its image into a readback buffer the host filled with a
--    sentinel, submits that batch through 'submitFrames', and steps
--    'progressFrames' until its fence has signalled — the only completion
--    evidence — after which the readback exposes the copied bytes;
-- 2. closes that frame, which was never presented, and steps until its
--    render-finished semaphore has been consumed by a tracked cleanup
--    submission and its image returned through @vkReleaseSwapchainImagesEXT@;
-- 3. acquires a second frame and skips it, and steps until the cleanup
--    submission waiting on its acquisition semaphore has completed and its
--    image has gone back;
-- 4. acquires again, skipping each frame, until an image that went back
--    earlier is acquired once more — a returned image is acquirable, and no
--    swapchain was rebuilt — and retires the target's frames, the recording,
--    the generation, the surface and the roots.
--
-- Nothing is presented: presentation is VK-13's. The only waits are the
-- owner's bounded polling of 'progressFrames', each step non-blocking, with a
-- millisecond between steps and a deadline after which the case stops.
module Test.GPU.Vulkan.Native.Frames
  ( FramesOutcome (..)
  , runFrames
  , framesSection
  , spec
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception (SomeException, displayException, finally, throwIO, try, tryWithContext)
import Control.Monad (unless, when)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64, Word8)
import Foreign.Ptr (nullPtr)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Vulkan.Core10 (CommandBuffer, Device, Instance, PhysicalDevice)
import Vulkan.Dynamic (getInstanceProcAddr')
import Vulkan.Extensions.VK_EXT_debug_utils (DebugUtilsMessengerEXT)
import Vulkan.Extensions.VK_KHR_surface (SurfaceKHR (..), destroySurfaceKHR)

import Hetoimasia.Foundation.Log
  ( DebugSelection (DebugAll)
  , LogEntry (..)
  , LogFilter (..)
  , LogLevel (Info)
  , callbackSink
  , mkLogger
  )
import Hetoimasia.Foundation.Time (DurationRequirement (AllowZero), Instant, durationFromNanoseconds, scriptedInstant, scriptedSource, zeroDuration)
import Hetoimasia.GPU.Model.Budget (defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (FrameSlotId, SubmissionId, TargetClass (..), TargetId, imageIndex)
import Hetoimasia.GPU.Vulkan.Diagnostics
  ( CaptureConfig (..)
  , CaptureCounters (..)
  , CaptureStatus (..)
  , ConsumerOutcome (..)
  , DiagnosticCapture
  , DiagnosticVerdict (..)
  , Quiesced
  , captureStatus
  , defaultCaptureConfig
  , diagnosticVerdict
  , verdictIssues
  , withDiagnosticCapture
  )
import Hetoimasia.GPU.Vulkan.Native.Frames
import Hetoimasia.GPU.Vulkan.Native.Frames.Vulkan (vulkanFrameOps)
import Hetoimasia.GPU.Vulkan.Native.Generations
  ( GenerationView (..)
  , Generations
  , TargetCondition (..)
  , TargetGenerationsView (..)
  , newGenerationsCapturing
  , readTargetGenerations
  , retireTargetGenerations
  , stepGenerations
  , trackTarget
  )
import Hetoimasia.GPU.Vulkan.Native.Presentation (GenerationPlan (..), SurfaceExtent (..), SurfaceFormat (..), TargetGeometry (..))
import Hetoimasia.GPU.Vulkan.Native.Profile (DevicePlan (..), InstanceRequest (..))
import Hetoimasia.GPU.Vulkan.Native.Recording
import Hetoimasia.GPU.Vulkan.Native.Recording.Shaders (verificationShaders)
import Hetoimasia.GPU.Vulkan.Native.Recording.Vulkan (vulkanRecordingOps)
import Hetoimasia.GPU.Vulkan.Native.Roots
  ( Roots
  , SurfaceDestruction (..)
  , TargetSurface (..)
  , admitRootTarget
  , destroyRoots
  , newRoots
  , readRootsDevice
  , readRootsInstance
  , retireRootTarget
  , retireRoots
  , startRoots
  )
import Hetoimasia.GPU.Vulkan.Native.Roots.Vulkan (instancePointer, vulkanRootOps)
import Test.GPU.Vulkan.Native.Environment (validationFeatures)
import Test.Vulkan.Proof.Interop
  ( createProofWindow
  , createWindowSurface
  , destroyProofWindow
  , glfwTerminate
  , initVulkanLoader
  , lastGlfwError
  , requiredInstanceExtensions
  )
import Hetoimasia.GLFW.Session (Backend)
import Test.GPU.Vulkan.Native.Platform (initRequested)
import Test.Vulkan.Proof.Journal (Journal, heading, note)

type VulkanRoots = Roots Quiesced Instance DebugUtilsMessengerEXT PhysicalDevice Device

type VulkanGenerations = Generations Quiesced Instance DebugUtilsMessengerEXT PhysicalDevice Device

type VulkanRecording = Recording Quiesced Instance DebugUtilsMessengerEXT PhysicalDevice Device CommandBuffer

type VulkanFrames = Frames Quiesced Instance DebugUtilsMessengerEXT PhysicalDevice Device CommandBuffer

-- | One stage of the case, and what the capture received during it.
data Step = Step
  { stepName ∷ !Text
  , stepReports ∷ !Word64
  , stepErrors ∷ !Word64
  }
  deriving (Show)

-- | One frame's way through the case.
data FrameTrace = FrameTrace
  { traceFrame ∷ !FrameSlotId
  , traceImage ∷ !Word32
  , traceSuboptimal ∷ !Bool
  , traceAttempts ∷ !Int
    -- ^ How many acquisitions it took, the pending answers included.
  , traceSettledAfter ∷ !Int
    -- ^ How many progress steps its settlement took.
  }
  deriving (Show)

data Observed = Observed
  { observedDevice ∷ !Text
  , observedExtent ∷ !SurfaceExtent
  , observedFormat ∷ !Word32
  , observedImages ∷ !Int
  , observedRendered ∷ !FrameTrace
  , observedSubmission ∷ !SubmissionId
  , observedCompletedAfter ∷ !Int
    -- ^ How many progress steps the submission's completion took.
  , observedReadbackBefore ∷ !Text
    -- ^ What reading the readback answered before the completion.
  , observedReadback ∷ !(Either Text [Word8])
    -- ^ The first pixel's bytes, once the completion exposed them.
  , observedSentinelLeft ∷ !Bool
    -- ^ Whether every byte of the copied image still held the sentinel.
  , observedSkipped ∷ !FrameTrace
  , observedReacquired ∷ !FrameTrace
    -- ^ The frame that acquired an image a frame before it had returned.
  , observedReturned ∷ ![Word32]
    -- ^ The images the rendered and the skipped frame returned.
  , observedConstructions ∷ !Integer
  , observedCalls ∷ ![Text]
    -- ^ Every native call the frames made, in order.
  , observedLeft ∷ !([FrameStanding], [SlotView], [SubmissionId])
    -- ^ What the frames still held before their retirement.
  }
  deriving (Show)

data FramesFacts = FramesFacts
  { factsObserved ∷ !Observed
  , factsSteps ∷ ![Step]
  , factsEntries ∷ ![LogEntry]
  , factsVerdict ∷ !DiagnosticVerdict
  }
  deriving (Show)

data FramesOutcome
  = FramesRecorded FramesFacts
  | FramesStopped Text (Maybe DiagnosticVerdict) [Step]
  deriving (Show)

framesCaptureConfig ∷ CaptureConfig
framesCaptureConfig = defaultCaptureConfig {captureTextBudget = 16384}

-- | The byte the host fills the readback with before the copy.
sentinel ∷ Word8
sentinel = 0xA5

-- | How many progress steps, a millisecond apart, the case waits for any one
-- piece of evidence before it stops.
patience ∷ Int
patience = 5000

stopWith ∷ Text → IO a
stopWith reason = throwIO (userError (Text.unpack reason))

-- | Run the case on the calling thread, which must be the process main
-- thread: GLFW's window and surface are made there, and so is everything
-- else, since this private process has no other owner.
runFrames ∷ Maybe Backend → Journal → IO FramesOutcome
runFrames backend journal = do
  heading journal "VK-12: frames acquired, submitted, awaited and returned without presenting"
  logged ← newTVarIO []
  steps ← newIORef []
  let logger =
        mkLogger
          LogFilter
            { filterEnabled = True
            , filterGlobalLevel = Info
            , filterComponentLevels = Map.empty
            , filterDebug = DebugAll
            , filterSource = False
            }
          (callbackSink (\entry → atomically (modifyTVar' logged (entry :))))
  entry ← Char8.useAsCString "vkGetInstanceProcAddr" (getInstanceProcAddr' nullPtr)
  initVulkanLoader entry
  started ← initRequested journal backend
  outcome ←
    if not started
      then (\reason → Left (Text.unpack reason, Nothing)) <$> lastGlfwError
      else
        either (\failure → Left (displayException failure, diagnosticVerdict failure)) Right
          <$> try @SomeException (withDiagnosticCapture framesCaptureConfig logger (session journal steps))
          `finally` glfwTerminate
  entries ← reverse <$> readTVarIO logged
  seen ← reverse <$> readIORef steps
  case outcome of
    Left (failure, verdict) → do
      note journal ("the frames session stopped: " <> Text.pack failure)
      pure (FramesStopped (Text.pack failure) verdict seen)
    Right (observed, verdict) → do
      note journal ("the lifetime delivered " <> tshow (verdictDelivered verdict) <> " records")
      pure (FramesRecorded (FramesFacts observed seen entries verdict))

measure ∷ DiagnosticCapture → IORef [Step] → Text → IO a → IO a
measure capture steps name action = do
  before ← statusCounters <$> captureStatus capture
  result ← action
  after ← statusCounters <$> captureStatus capture
  modifyIORef' steps (Step name (countOffered after - countOffered before) (countErrors after - countErrors before) :)
  pure result

-- | The instant this many milliseconds after the scripted origin.
at ∷ Integer → Instant
at milliseconds = scriptedInstant (either (error . show) id (durationFromNanoseconds AllowZero (milliseconds * 1000000)))

session ∷ Journal → IORef [Step] → DiagnosticCapture → IO (Observed, Quiesced)
session journal steps capture = do
  let step ∷ Text → IO a → IO a
      step = measure capture steps
  required ← requiredInstanceExtensions >>= maybe (stopWith "GLFW requires no surface extensions, so no surface can be made") pure
  budgets ← either (stopWith . tshow) pure (validateBudgets defaultBudgetRequest)
  roots ← newRoots (vulkanRootOps capture) budgets (scriptedSource (pure (scriptedInstant zeroDuration)))
  _ ← step "the instance and its messenger" (startRoots roots (InstanceRequest required ["VK_LAYER_KHRONOS_validation"] validationFeatures))
  proved ← newIORef Nothing
  let finish = do
        _ ← try @SomeException (step "the device" (retireRoots roots))
        step "the messenger and the instance" (destroyRoots roots) >>= writeIORef proved
  observed ← withWindow journal step roots `finally` finish
  readIORef proved >>= \case
    Just quiesced → pure (observed, quiesced)
    Nothing → stopWith "the instance's destruction proved nothing"

withWindow ∷ Journal → (∀ a. Text → IO a → IO a) → VulkanRoots → IO Observed
withWindow journal step roots = do
  window ← createProofWindow 160 120 "hetoimasia VK-12 frames" >>= maybe (lastGlfwError >>= stopWith . ("no window: " <>)) pure
  flip finally (destroyProofWindow window) $ do
    instanceHandle ← atomically (readRootsInstance roots) >>= maybe (stopWith "the roots hold no instance") pure
    (result, surface) ← createWindowSurface (instancePointer instanceHandle) window
    when (result /= 0) (stopWith ("glfwCreateWindowSurface answered " <> tshow result))
    let destroy = either SurfaceDestructionUncertain (const SurfaceDestroyed) <$> tryWithContext (destroySurfaceKHR instanceHandle (SurfaceKHR surface) Nothing)
    target ←
      step "the device and the target" (admitRootTarget roots RequiredTarget (TargetSurface surface destroy))
        >>= either (stopWith . ("the target was refused: " <>) . tshow) pure
    generations ← newGenerationsCapturing roots
    atomically (trackTarget generations target RequiredTarget surface)
    observed ←
      withGeneration journal step roots generations target
        `finally` step "the generation" (retireTargetGenerations generations (at 9) target)
    step "the target's surface" (retireRootTarget roots target)
    pure observed

withGeneration ∷ Journal → (∀ a. Text → IO a → IO a) → VulkanRoots → VulkanGenerations → TargetId → IO Observed
withGeneration journal step roots generations target = do
  _ ←
    step "the swapchain generation" $
      stepGenerations generations (at 0) (Map.singleton target (TargetGeometry (Right ()) (Just (SurfaceExtent 160 120)) Nothing 1))
  view ← atomically (readTargetGenerations generations target) >>= maybe (stopWith "the target is not tracked") pure
  unless (viewCondition view == Presenting) (stopWith ("the target is not presenting: " <> tshow (viewCondition view)))
  generation ←
    maybe (stopWith "the target has no active generation") pure $
      viewActive view >>= \active → find ((== active) . viewGeneration) (viewGenerations view)
  let plan = viewPlan generation
      extent = planExtent plan
      format = surfaceFormat (planFormat plan)
  note journal ("the generation is " <> tshow (extentWidth extent) <> "x" <> tshow (extentHeight extent) <> " in format " <> tshow format <> " with " <> tshow (length (viewImages generation)) <> " images")
  (devicePlan, _) ← atomically (readRootsDevice roots) >>= maybe (stopWith "the roots hold no device") pure
  ops ← vulkanRecordingOps (planDevice devicePlan)
  recording ← newRecording ops roots generations
  calls ← newIORef []
  frames ← newFrames (observing calls vulkanFrameOps) recording
  outcome ← try @SomeException (exercise journal step recording frames target extent format)
  -- Whatever happened, what the frames still hold is retired, then the
  -- recording's resources; anything unsettled is retained, and says so.
  _ ← try @SomeException (step "retiring the frames" (retireTargetFrames frames target))
  _ ← try @SomeException (step "releasing and destroying the managed resources" (retireRecording recording (at 8)))
  case outcome of
    Left failure → throwIO failure
    Right (rendered, submission, completedAfter, before, readback, sentinelLeft, skipped, reacquired, left) → do
      constructions ← maybe 0 (toInteger . viewConstructions) <$> atomically (readTargetGenerations generations target)
      made ← reverse <$> readIORef calls
      pure
        Observed
          { observedDevice = planDeviceName devicePlan
          , observedExtent = extent
          , observedFormat = format
          , observedImages = length (viewImages generation)
          , observedRendered = rendered
          , observedSubmission = submission
          , observedCompletedAfter = completedAfter
          , observedReadbackBefore = before
          , observedReadback = readback
          , observedSentinelLeft = sentinelLeft
          , observedSkipped = skipped
          , observedReacquired = reacquired
          , observedReturned = [traceImage rendered, traceImage skipped]
          , observedConstructions = constructions
          , observedCalls = made
          , observedLeft = left
          }

exercise
  ∷ Journal
  → (∀ a. Text → IO a → IO a)
  → VulkanRecording
  → VulkanFrames
  → TargetId
  → SurfaceExtent
  → Word32
  → IO (FrameTrace, SubmissionId, Int, Text, Either Text [Word8], Bool, FrameTrace, FrameTrace, ([FrameStanding], [SlotView], [SubmissionId]))
exercise journal step recording frames target extent format = do
  let made ∷ Show refusal ⇒ Text → IO (Either refusal a) → IO a
      made name action = step name action >>= either (stopWith . ((name <> " was refused: ") <>) . tshow) pure
      command name action = action >>= either (stopWith . ((name <> " was refused: ") <>) . tshow) pure
      width = extentWidth extent
      height = extentHeight extent
      bytes = readbackBytesFor extent
  layout ← made "vkCreatePipelineLayout" (createPipelineLayout recording)
  pipeline ← made "vkCreateGraphicsPipelines" (createPipeline recording layout verificationShaders format)
  _ ← made "vkCreateCommandPool, slot 0" (createFrameStorage recording target 0)
  _ ← made "vkCreateCommandPool, slot 1" (createFrameStorage recording target 1)
  readback ← made "vkCreateBuffer" (createReadback recording bytes)
  made "filling the readback with the sentinel" (fillReadback recording readback sentinel)

  -- 1. Acquire, record the triangle and its capture, submit, and await.
  (rendered, attempts) ← step "acquiring the rendered frame" (acquireFrame frames target)
  (batch, ()) ←
    made "recording the triangle batch" $
      recordFrame recording (ownedFrame rendered) $ \recorder → do
        command "the transition into rendering" (transitionImage recorder LayoutUndefined LayoutColorAttachment)
        command "vkCmdBeginRendering" (beginRendering recorder (ClearColor 0.1 0.1 0.1 1))
        command "vkCmdBindPipeline" (bindPipeline recorder pipeline)
        command "vkCmdSetViewport" (setViewport recorder (Viewport 0 0 (fromIntegral width) (fromIntegral height)))
        command "vkCmdSetScissor" (setScissor recorder (Rect 0 0 width height))
        command "vkCmdDraw" (draw recorder 3 1)
        command "vkCmdEndRendering" (endRendering recorder)
        command "the transition to the copy" (transitionImage recorder LayoutColorAttachment LayoutTransferSource)
        command "vkCmdCopyImageToBuffer" (copyToReadback recorder readback)
        command "the transition to presentation" (transitionImage recorder LayoutTransferSource LayoutPresentSource)
  submission ←
    step "vkQueueSubmit2, the triangle batch" (submitFrames frames (batch :| [])) >>= \case
      Right (SubmittedAs submission) → pure submission
      other → stopWith ("the submission answered " <> tshow other)
  note journal ("submitted " <> tshow batch <> " as " <> tshow submission)
  before ← either tshow (const "bytes were exposed") <$> readReadback recording readback 0 4
  completedAfter ← step "awaiting the submission's fence" (stepUntil frames (\report → submission `elem` progressCompleted report))
  readbackAnswer ← readReadback recording readback 0 bytes
  let pixel = either (Left . tshow) (Right . ByteString.unpack . ByteString.take 4) readbackAnswer
      sentinelLeft = either (const True) (ByteString.all (== sentinel)) readbackAnswer
  note journal ("after the completion the readback's first pixel is " <> tshow pixel)

  -- 2. The rendered frame is never presented: close it and settle it.
  made "closing the unpresented frame" (closeUnpresentedFrame frames (ownedFrame rendered))
  renderedSettled ← step "settling the unpresented frame" (stepUntil frames (\report → ownedFrame rendered `elem` progressSettled report))

  -- 3. A skipped frame.
  (skipped, skippedAttempts) ← step "acquiring the skipped frame" (acquireFrame frames target)
  made "skipping the frame" (skipFrame frames (ownedFrame skipped))
  skippedSettled ← step "settling the skipped frame" (stepUntil frames (\report → ownedFrame skipped `elem` progressSettled report))

  -- 4. A returned image is acquirable again: acquire, skipping each frame,
  -- until an image that went back earlier comes back.
  let returned = map (imageIndex . ownedImage) [rendered, skipped]
      reacquire count = do
        (frame, attempts') ← step "acquiring again" (acquireFrame frames target)
        made "skipping the frame acquired again" (skipFrame frames (ownedFrame frame))
        settled ← step "settling the frame acquired again" (stepUntil frames (\report → ownedFrame frame `elem` progressSettled report))
        if imageIndex (ownedImage frame) `elem` returned || count >= (8 ∷ Int)
          then pure (frame, attempts', settled, count)
          else reacquire (count + 1)
  (again, againAttempts, againSettled, reacquisitions) ← reacquire 1
  note journal ("image " <> tshow (imageIndex (ownedImage again)) <> " came back at reacquisition " <> tshow reacquisitions)

  left ← atomically ((,,) <$> readFrameStandings frames <*> readSlots frames <*> readOutstandingSubmissions frames)
  let trace frame attempts' settledAfter = FrameTrace (ownedFrame frame) (fromIntegral (imageIndex (ownedImage frame))) (ownedSuboptimal frame) attempts' settledAfter
  pure
    ( trace rendered attempts renderedSettled
    , submission
    , completedAfter
    , before
    , pixel
    , sentinelLeft
    , trace skipped skippedAttempts skippedSettled
    , trace again againAttempts againSettled
    , left
    )

-- | Acquire a frame, stepping between answers that are only pending.
acquireFrame ∷ VulkanFrames → TargetId → IO (OwnedFrame, Int)
acquireFrame frames target = go 1
  where
    go attempt =
      tryAcquireFrame frames target >>= \case
        Right (AcquisitionOwned frame) → pure (frame, attempt)
        Right (AcquisitionPending _) | attempt < patience → do
          _ ← progressFrames frames (at 1)
          threadDelay 1000
          go (attempt + 1)
        other → stopWith ("no frame was acquired after " <> tshow attempt <> " attempts: " <> tshow other)

-- | Step the frames until a step's report satisfies the predicate, answering
-- how many steps that took.
stepUntil ∷ VulkanFrames → (Progress → Bool) → IO Int
stepUntil frames done = go 1
  where
    go count = do
      report ← progressFrames frames (at 1)
      if done report
        then pure count
        else
          if count >= patience
            then stopWith ("the evidence did not arrive in " <> tshow count <> " steps")
            else threadDelay 1000 >> go (count + 1)

-- | The frames layer, noting each call's entry point before it is made.
observing ∷ IORef [Text] → FrameOps dev cmd → FrameOps dev cmd
observing calls ops =
  ops
    { opsCreateSemaphore = \device → noted "vkCreateSemaphore" (opsCreateSemaphore ops device)
    , opsDestroySemaphore = \device handle → noted "vkDestroySemaphore" (opsDestroySemaphore ops device handle)
    , opsCreateFence = \device → noted "vkCreateFence" (opsCreateFence ops device)
    , opsDestroyFence = \device handle → noted "vkDestroyFence" (opsDestroyFence ops device handle)
    , opsResetFence = \device handle → noted "vkResetFences" (opsResetFence ops device handle)
    , opsAcquireImage = \device swapchain semaphore → do
        answer ← opsAcquireImage ops device swapchain semaphore
        modifyIORef' calls (("vkAcquireNextImageKHR: " <> tshow answer) :)
        pure answer
    , opsSubmit = \device family batches fence →
        noted ("vkQueueSubmit2: " <> (if all (null . submitCommands) batches then "cleanup" else "rendering")) (opsSubmit ops device family batches fence)
    , opsReleaseImages = \device swapchain indices → noted ("vkReleaseSwapchainImagesEXT: " <> tshow indices) (opsReleaseImages ops device swapchain indices)
    }
  where
    -- Status queries are the polling itself, and are left out.
    noted ∷ Text → IO a → IO a
    noted name action = modifyIORef' calls (name :) >> action

-- | The record's section.
framesSection ∷ FramesOutcome → [Text]
framesSection = \case
  FramesStopped reason verdict steps →
    ["", "## The session stopped", "", reason, ""]
      <> stepTable steps
      <> ["", "- verdict issues: " <> maybe "no verdict" (tshow . verdictIssues) verdict]
  FramesRecorded facts →
    let observed = factsObserved facts
        frame label trace' =
          "- " <> label <> ": " <> tshow (traceFrame trace') <> ", image " <> tshow (traceImage trace')
            <> (if traceSuboptimal trace' then " (suboptimal)" else "")
            <> ", acquired at attempt " <> tshow (traceAttempts trace')
            <> ", settled after " <> tshow (traceSettledAfter trace') <> " steps"
     in [ ""
        , "## Frames acquired, submitted, awaited and returned without presenting"
        , ""
        , "- device: " <> observedDevice observed
        , "- generation: " <> tshow (extentWidth (observedExtent observed)) <> "x" <> tshow (extentHeight (observedExtent observed)) <> ", format " <> tshow (observedFormat observed) <> ", " <> tshow (observedImages observed) <> " images"
        , frame "rendered, never presented" (observedRendered observed)
        , "- its submission: " <> tshow (observedSubmission observed) <> ", completed after " <> tshow (observedCompletedAfter observed) <> " steps"
        , "- the readback before the completion: " <> observedReadbackBefore observed
        , "- the readback's first pixel after it: " <> tshow (observedReadback observed)
        , "- every byte still the sentinel: " <> tshow (observedSentinelLeft observed)
        , frame "skipped" (observedSkipped observed)
        , frame "acquiring a returned image again, then skipped" (observedReacquired observed)
        , "- images the first two frames returned: " <> tshow (observedReturned observed)
        , "- swapchain constructions: " <> tshow (observedConstructions observed)
        , "- left before retirement: " <> tshow (observedLeft observed)
        , ""
        , "Native calls the frames made, status queries left out:"
        , ""
        ]
          <> ["1. " <> call | call ← observedCalls observed]
          <> [""]
          <> stepTable (factsSteps facts)
          <> [ ""
             , "- error reports: " <> joined [Map.findWithDefault "" "message.id" entry.entryFields <> ": " <> Text.take 600 entry.entryMessage | entry ← factsEntries facts, Map.lookup "severity" entry.entryFields == Just "error"]
             , "- records delivered: " <> tshow (verdictDelivered (factsVerdict facts))
             , "- undelivered: " <> tshow (verdictUndelivered (factsVerdict facts))
             , "- verdict issues: " <> tshow (verdictIssues (factsVerdict facts))
             ]
  where
    joined [] = "none"
    joined reports = Text.intercalate "; " reports
    stepTable steps =
      ["| step | reports | errors |", "| --- | --- | --- |"]
        <> ["| " <> step.stepName <> " | " <> tshow step.stepReports <> " | " <> tshow step.stepErrors <> " |" | step ← steps]

-- ---------------------------------------------------------------------------
-- The verdict

spec ∷ FramesOutcome → Spec
spec outcome = describe "VK-12 frames" $ do
  it "established every step of its private roots, its generation, its resources and its frames" $
    onFacts outcome $ \_ → pure ()

  it "exposed the copied bytes only once the submission's fence signalled, and they are not the sentinel" $
    onFacts outcome $ \facts → do
      let observed = factsObserved facts
      observedReadbackBefore observed `shouldSatisfy` Text.isPrefixOf "RefusedNotWritten"
      observedReadback observed `shouldSatisfy` either (const False) ((== 4) . length)
      observedSentinelLeft observed `shouldBe` False

  it "returned the rendered, never-presented image only after its rendering and its render-finished semaphore's cleanup completed" $
    onFacts outcome $ \facts →
      inOrder
        ["vkQueueSubmit2: rendering", "vkResetFences", "vkQueueSubmit2: cleanup", "vkReleaseSwapchainImagesEXT"]
        (observedCalls (factsObserved facts))
        `shouldBe` True

  it "skipped acquired frames through cleanup submissions and releases, and acquired a returned image again without rebuilding the swapchain" $
    onFacts outcome $ \facts → do
      let observed = factsObserved facts
          calls = observedCalls observed
          cleanups = length (filter (Text.isPrefixOf "vkQueueSubmit2: cleanup") calls)
      -- Every frame went back through a cleanup submission and a release.
      cleanups `shouldSatisfy` (>= 3)
      length (filter (Text.isPrefixOf "vkReleaseSwapchainImagesEXT") calls) `shouldBe` cleanups
      length (filter (Text.isPrefixOf "vkQueueSubmit2: rendering") calls) `shouldBe` 1
      observedConstructions observed `shouldBe` 1
      traceImage (observedReacquired observed) `shouldSatisfy` (`elem` observedReturned observed)

  it "held nothing unsettled before its retirement" $
    onFacts outcome $ \facts → do
      let (live, _, outstanding) = observedLeft (factsObserved facts)
      (live, outstanding) `shouldBe` ([], [])

  it "received no validation error during any step" $
    onFacts outcome $ \facts →
      [(step.stepName, step.stepErrors) | step ← factsSteps facts, step.stepErrors > 0] `shouldBe` []

  it "completed its capture, and its verdict after the last teardown callback is clean" $
    onFacts outcome $ \facts → do
      let verdict = factsVerdict facts
          counters = verdict.verdictStatus.statusCounters
      counters.countAdmitted `shouldBe` counters.countOffered
      verdict.verdictDelivered `shouldBe` counters.countAdmitted
      verdict.verdictUndelivered `shouldBe` 0
      verdict.verdictQuiescent `shouldBe` True
      completed verdict.verdictConsumer `shouldBe` True
      verdictIssues verdict `shouldBe` []
  where
    completed = \case
      ConsumerCompleted → True
      _ → False
    -- Whether calls beginning with each wanted name appear in this order.
    inOrder wanted calls = case (wanted, calls) of
      ([], _) → True
      (_, []) → False
      (next : rest, call : later)
        | next `Text.isPrefixOf` call → inOrder rest later
        | otherwise → inOrder wanted later

onFacts ∷ FramesOutcome → (FramesFacts → Expectation) → Expectation
onFacts outcome assertion = case outcome of
  FramesStopped reason _ _ → expectationFailure ("the frames session stopped: " <> Text.unpack reason)
  FramesRecorded facts → assertion facts

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
