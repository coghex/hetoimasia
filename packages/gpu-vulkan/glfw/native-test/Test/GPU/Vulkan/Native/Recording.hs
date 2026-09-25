{-# LANGUAGE OverloadedRecordDot #-}

-- | VK-11's native case: managed resources and a recorded, discarded triangle
-- batch on private roots, with validation reporting nothing.
--
-- The roots are the production native layer's ("Hetoimasia.GPU.Vulkan.Native.Roots.Vulkan"),
-- planned from the request every native case uses — the validation layer with
-- synchronization validation — and one window's surface is admitted to them,
-- so a real swapchain generation exists to record against — one built for a
-- verification capture, whose images are also transfer sources, which is the
-- capture profile VK-2 verified on both drivers. Over it the
-- production recording layer ("Hetoimasia.GPU.Vulkan.Native.Recording.Vulkan")
-- constructs a pipeline layout, a graphics pipeline over VK-9's embedded
-- verification shaders, the frame slot's command storage and a readback
-- buffer sized for the generation's extent; records one batch — into
-- rendering, the pipeline, viewport and scissor, a triangle, out of
-- rendering, the copy into the readback buffer with its host-read barrier,
-- and the image left ready to present — through the audited unsafe subset;
-- discards it without submitting; and releases and destroys every resource
-- before the roots go.
--
-- = The fixture-private frame
--
-- Public acquisition is VK-12's, so the checked frame this case records into
-- is supplied privately: the fixture reserves a frame and records its
-- acquisition of image 0 in the model alone, through the roots' model. No
-- native acquisition is made, so there is no acquisition semaphore, fence or
-- image ownership to settle natively; after the discard the fixture skips the
-- frame in the model and supplies its unpresented-frame settlement, which is
-- the whole of what that frame owes. Nothing in the backend's own interface
-- fakes an acquisition: this construction lives here, in the suite.
--
-- Nothing is submitted, so the readback buffer's bytes are never valid; the
-- case asserts the backend refuses to expose them rather than claiming a
-- captured pixel.
module Test.GPU.Vulkan.Native.Recording
  ( RecordingOutcome (..)
  , RecordingFacts (..)
  , RecordingStep (..)
  , runRecording
  , recordingSection
  , spec
  ) where

import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception (SomeException, displayException, finally, throwIO, try, tryWithContext)
import Control.Monad (unless, when)
import qualified Data.ByteString.Char8 as Char8
import Data.Foldable (for_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
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
import Hetoimasia.GPU.Model
  ( AcquireAnswer (..)
  , AcquireOutcome (..)
  , CompletionFact (..)
  , HoldView (..)
  , Outcome (..)
  , acquireImage
  , holdView
  , recordCompletion
  , reserveFrame
  , skipUnsubmittedFrame
  )
import Hetoimasia.GPU.Model.Budget (defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (BatchId, FrameSlotId, HoldSubject (..), ResourceId, TargetClass (..), TargetId, frameSlotNumber)
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
import Hetoimasia.GPU.Vulkan.Native.Diagnostics (describeFfiConfiguration, nativeFfiConfiguration)
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
  , readRootsModel
  , retireRootTarget
  , retireRoots
  , startRoots
  , stateRootsModel
  )
import Hetoimasia.GPU.Vulkan.Native.Roots.Vulkan (instancePointer, vulkanRootOps)
import Test.GPU.Vulkan.Native.Environment (validationFeatures)
import Test.Vulkan.Proof.Interop
  ( createProofWindow
  , createWindowSurface
  , destroyProofWindow
  , glfwInit
  , glfwTerminate
  , initVulkanLoader
  , lastGlfwError
  , requiredInstanceExtensions
  )
import Test.Vulkan.Proof.Journal (Journal, heading, note)

type VulkanRoots = Roots Quiesced Instance DebugUtilsMessengerEXT PhysicalDevice Device

type VulkanRecording = Recording Quiesced Instance DebugUtilsMessengerEXT PhysicalDevice Device CommandBuffer

-- | One stage of the case, and what the capture received during it.
data RecordingStep = RecordingStep
  { stepName ∷ !Text
  , stepReports ∷ !Word64
  , stepErrors ∷ !Word64
  }
  deriving (Show)

-- | What the native session observed, before its lifetime's verdict.
data Observed = Observed
  { observedDevice ∷ !Text
  , observedExtent ∷ !SurfaceExtent
  , observedFormat ∷ !Word32
  , observedImages ∷ !Int
  , observedBatch ∷ !(Maybe BatchView)
  , observedHeldBefore ∷ ![(Text, [BatchId])]
    -- ^ Each subject the batch referenced, and the batches the model said
    -- held it, just before the discard.
  , observedHeldAfter ∷ ![(Text, [BatchId])]
  , observedReadback ∷ !Text
    -- ^ What reading the readback answered with nothing submitted.
  , observedResources ∷ ![ResourceId]
  , observedDestroyed ∷ ![ResourceId]
  }
  deriving (Show)

data RecordingFacts = RecordingFacts
  { factsObserved ∷ !Observed
  , factsSteps ∷ ![RecordingStep]
  , factsEntries ∷ ![LogEntry]
  , factsVerdict ∷ !DiagnosticVerdict
  }
  deriving (Show)

data RecordingOutcome
  = RecordingRecorded RecordingFacts
  | RecordingStopped Text (Maybe DiagnosticVerdict) [RecordingStep]
  deriving (Show)

-- | The capture limits: the ones the shared roots run under.
recordingCaptureConfig ∷ CaptureConfig
recordingCaptureConfig = defaultCaptureConfig {captureTextBudget = 16384}

stopWith ∷ Text → IO a
stopWith reason = throwIO (userError (Text.unpack reason))

-- | Run the case on the calling thread, which must be the process main
-- thread: GLFW's window and surface are made there, and so is everything
-- else, since this private process has no other owner.
runRecording ∷ Journal → IO RecordingOutcome
runRecording journal = do
  heading journal "VK-11: managed resources and a recorded, discarded triangle batch"
  for_ (describeFfiConfiguration nativeFfiConfiguration) $ \(label, value) → note journal ("ffi " <> label <> ": " <> value)
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
  -- GLFW is handed the binding's own loader entry point, so the two share a
  -- loader, exactly as the proof's cases do.
  entry ← Char8.useAsCString "vkGetInstanceProcAddr" (getInstanceProcAddr' nullPtr)
  initVulkanLoader entry
  started ← glfwInit
  outcome ←
    if not started
      then (\reason → Left (Text.unpack reason, Nothing)) <$> lastGlfwError
      else
        either (\failure → Left (displayException failure, diagnosticVerdict failure)) Right
          <$> try @SomeException (withDiagnosticCapture recordingCaptureConfig logger (session journal steps))
          `finally` glfwTerminate
  entries ← reverse <$> readTVarIO logged
  seen ← reverse <$> readIORef steps
  case outcome of
    Left (failure, verdict) → do
      note journal ("the recording session stopped: " <> Text.pack failure)
      pure (RecordingStopped (Text.pack failure) verdict seen)
    Right (observed, verdict) → do
      note journal ("the lifetime delivered " <> tshow (verdictDelivered verdict) <> " records")
      pure (RecordingRecorded (RecordingFacts observed seen entries verdict))

-- | Count what the capture received during one stage.
measure ∷ DiagnosticCapture → IORef [RecordingStep] → Text → IO a → IO a
measure capture steps name action = do
  before ← statusCounters <$> captureStatus capture
  result ← action
  after ← statusCounters <$> captureStatus capture
  modifyIORef' steps (RecordingStep name (countOffered after - countOffered before) (countErrors after - countErrors before) :)
  pure result

-- | The instant this many milliseconds after the scripted origin. The case
-- passes every instant explicitly, and nothing in it waits.
at ∷ Integer → Instant
at milliseconds = scriptedInstant (either (error . show) id (durationFromNanoseconds AllowZero (milliseconds * 1000000)))

session ∷ Journal → IORef [RecordingStep] → DiagnosticCapture → IO (Observed, Quiesced)
session journal steps capture = do
  let step ∷ Text → IO a → IO a
      step = measure capture steps
  required ← requiredInstanceExtensions >>= maybe (stopWith "GLFW requires no surface extensions, so no surface can be made") pure
  budgets ← either (stopWith . tshow) pure (validateBudgets defaultBudgetRequest)
  roots ← newRoots (vulkanRootOps capture) budgets (scriptedSource (pure (scriptedInstant zeroDuration)))
  _ ← step "the instance and its messenger" (startRoots roots (InstanceRequest required ["VK_LAYER_KHRONOS_validation"] validationFeatures))
  -- Whatever happens below, the roots are retired child before parent, and
  -- the instance's destruction is the capture's quiescence evidence.
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
  window ← createProofWindow 160 120 "hetoimasia VK-11 recording" >>= maybe (lastGlfwError >>= stopWith . ("no window: " <>)) pure
  flip finally (destroyProofWindow window) $ do
    instanceHandle ← atomically (readRootsInstance roots) >>= maybe (stopWith "the roots hold no instance") pure
    (result, surface) ← createWindowSurface (instancePointer instanceHandle) window
    when (result /= 0) (stopWith ("glfwCreateWindowSurface answered " <> tshow result))
    let destroy = either SurfaceDestructionUncertain (const SurfaceDestroyed) <$> tryWithContext (destroySurfaceKHR instanceHandle (SurfaceKHR surface) Nothing)
    target ←
      step "the device and the target" (admitRootTarget roots RequiredTarget (TargetSurface surface destroy))
        >>= either (stopWith . ("the target was refused: " <>) . tshow) pure
    -- A generation built for a verification capture: its images are also
    -- transfer sources where the surface offers that, as both drivers do.
    generations ← newGenerationsCapturing roots
    atomically (trackTarget generations target RequiredTarget surface)
    observed ←
      withGeneration journal step roots generations target
        `finally` step "the generation" (retireTargetGenerations generations (at 2) target)
    step "the target's surface" (retireRootTarget roots target)
    pure observed

withGeneration
  ∷ Journal
  → (∀ a. Text → IO a → IO a)
  → VulkanRoots
  → Generations Quiesced Instance DebugUtilsMessengerEXT PhysicalDevice Device
  → TargetId
  → IO Observed
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
  (batch, heldBefore, heldAfter, readback, resources) ← record journal step roots recording target extent format
  destroyed ← step "releasing and destroying the managed resources" $ do
    retireRecording recording (at 1)
    pure resources
  pure
    Observed
      { observedDevice = planDeviceName devicePlan
      , observedExtent = extent
      , observedFormat = format
      , observedImages = length (viewImages generation)
      , observedBatch = batch
      , observedHeldBefore = heldBefore
      , observedHeldAfter = heldAfter
      , observedReadback = readback
      , observedResources = resources
      , observedDestroyed = destroyed
      }

-- | Construct the managed resources, supply the frame, record, observe and
-- discard. Whatever this raises, the caller's retirement of the recording's
-- resources and the generation still runs.
record
  ∷ Journal
  → (∀ a. Text → IO a → IO a)
  → VulkanRoots
  → VulkanRecording
  → TargetId
  → SurfaceExtent
  → Word32
  → IO (Maybe BatchView, [(Text, [BatchId])], [(Text, [BatchId])], Text, [ResourceId])
record journal step roots recording target extent format = do
  let made ∷ Show refusal ⇒ Text → IO (Either refusal a) → IO a
      made name action = step name action >>= either (stopWith . ((name <> " was refused: ") <>) . tshow) pure
  layout ← made "vkCreatePipelineLayout" (createPipelineLayout recording)
  pipeline ← made "vkCreateGraphicsPipelines" (createPipeline recording layout verificationShaders format)
  frame ← acquireInModel roots target
  storage ← made "vkCreateCommandPool" (createFrameStorage recording target (frameSlotNumber frame))
  readback ← made "vkCreateBuffer" (createReadback recording (readbackBytesFor extent))
  let resources = [managedResource layout, managedResource pipeline, managedResource storage, managedResource readback]
      width = extentWidth extent
      height = extentHeight extent
      command name action = action >>= either (stopWith . ((name <> " was refused: ") <>) . tshow) pure
  (batch, ()) ←
    made "recording the triangle batch" $
      recordFrame recording frame $ \recorder → do
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
  view ← atomically (readBatch recording batch)
  note journal ("recorded " <> tshow batch <> ": " <> tshow view)
  let named = [("pipeline layout", managedResource layout), ("pipeline", managedResource pipeline), ("frame storage", managedResource storage), ("readback", managedResource readback)]
      heldBy = do
        model ← atomically (readRootsModel roots)
        pure [(name, maybe [] viewRecorded (holdView (ResourceSubject resource) model)) | (name, resource) ← named]
  heldBefore ← heldBy
  readbackAnswer ← either tshow (const "bytes were exposed") <$> readReadback recording readback 0 4
  note journal ("reading the readback with nothing submitted answered " <> readbackAnswer)
  step "vkResetCommandPool, discarding the batch" (discardBatch recording batch) >>= either (stopWith . ("the discard was refused: " <>) . tshow) pure
  heldAfter ← heldBy
  settleInModel roots frame
  pure (view, heldBefore, heldAfter, readbackAnswer, resources)

-- | The fixture-private frame: reserve one on the target and record the
-- acquisition of image 0 in the model alone. No native acquisition is made.
acquireInModel ∷ VulkanRoots → TargetId → IO FrameSlotId
acquireInModel roots target =
  atomically (stateRootsModel roots acquire) >>= either stopWith pure
  where
    acquire model = case reserveFrame target model of
      Admitted (reserved, frame) → case acquireImage frame (AcquiredImage 0) reserved of
        Admitted (acquired, ImageOwned _ _) → (Right frame, acquired)
        _ → (Left "the model refused the frame's acquisition", model)
      _ → (Left "the model refused the frame's reservation", model)

-- | Everything the fixture-private frame owes once its batch is discarded:
-- the skip, and — since nothing native was ever acquired — its settlement.
settleInModel ∷ VulkanRoots → FrameSlotId → IO ()
settleInModel roots frame =
  atomically (stateRootsModel roots settle) >>= either stopWith pure
  where
    settle model = case skipUnsubmittedFrame frame model of
      Admitted skipped → case recordCompletion (at 1) (UnpresentedFrameSettled frame) skipped of
        Admitted settled → (Right (), settled)
        _ → (Left "the model refused the frame's settlement", model)
      _ → (Left "the model refused the skip", model)

-- | The record's section.
recordingSection ∷ RecordingOutcome → [Text]
recordingSection = \case
  RecordingStopped reason verdict steps →
    ["", "## The session stopped", "", reason, ""]
      <> stepTable steps
      <> ["", "- verdict issues: " <> maybe "no verdict" (tshow . verdictIssues) verdict]
  RecordingRecorded facts →
    let observed = factsObserved facts
     in [ ""
        , "## A recorded, discarded triangle batch"
        , ""
        , "- device: " <> observedDevice observed
        , "- generation: " <> tshow (extentWidth (observedExtent observed)) <> "x" <> tshow (extentHeight (observedExtent observed)) <> ", format " <> tshow (observedFormat observed) <> ", " <> tshow (observedImages observed) <> " images"
        , "- batch: " <> tshow (observedBatch observed)
        , "- held before the discard: " <> tshow (observedHeldBefore observed)
        , "- held after the discard: " <> tshow (observedHeldAfter observed)
        , "- the readback with nothing submitted: " <> observedReadback observed
        , "- managed resources destroyed: " <> tshow (length (observedDestroyed observed))
        , ""
        ]
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

spec ∷ RecordingOutcome → Spec
spec outcome = describe "VK-11 managed recording" $ do
  it "established every step of its private roots, its generation and its managed resources" $
    onFacts outcome $ \_ → pure ()

  it "recorded one sealed batch of eleven commands against the generation's image" $
    onFacts outcome $ \facts → do
      let batch = observedBatch (factsObserved facts)
      fmap viewBatchStanding batch `shouldBe` Just BatchSealed
      fmap viewBatchCommands batch `shouldBe` Just 11

  it "held every managed resource the batch referenced, and no longer once the discard invalidated it" $
    onFacts outcome $ \facts → do
      let observed = factsObserved facts
          batch = maybe [] (pure . viewBatch) (observedBatch observed)
      map snd (observedHeldBefore observed) `shouldBe` replicate 4 batch
      map snd (observedHeldAfter observed) `shouldBe` replicate 4 []

  it "exposed no readback bytes, since nothing was submitted" $
    onFacts outcome $ \facts →
      observedReadback (factsObserved facts) `shouldSatisfy` Text.isPrefixOf "RefusedNotWritten"

  it "constructed, released and destroyed every managed resource" $
    onFacts outcome $ \facts →
      length (observedDestroyed (factsObserved facts)) `shouldBe` 4

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

onFacts ∷ RecordingOutcome → (RecordingFacts → Expectation) → Expectation
onFacts outcome assertion = case outcome of
  RecordingStopped reason _ _ → expectationFailure ("the recording session stopped: " <> Text.unpack reason)
  RecordingRecorded facts → assertion facts

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
