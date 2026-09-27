{-# LANGUAGE OverloadedRecordDot #-}

-- | VK-15's native cases, each on private roots in a child process of its own.
--
-- __A validation error during rendering__ (@vk15-validation-stop@). The
-- production native layers, the validation layer with synchronization
-- validation, one window with a swapchain generation, and VK-12's and VK-13's
-- frames over them, with the roots watching the capture as the controller has
-- them do. Two triangle frames are presented and retired on their present
-- fences; a third is acquired, recorded and submitted, and then an
-- error-severity validation message is delivered through
-- @vkSubmitDebugUtilsMessageEXT@ — the injected error, named by its own
-- message identifier. The next checkpoint, the frame's presentation, is
-- refused naming it, and so is an acquisition; the frame is closed unpresented
-- and everything is torn down under the ordinary rules, every obligation
-- settling on its own evidence. The verdict, reached after the last callback,
-- must carry the injected error and nothing else: another error, a dropped or
-- cut record, or an incomplete capture fails the case.
--
-- __A retained unverified resource__ (@vk15-retention@). The production
-- composition, 'withVulkanOwnerHost', over one visible window: its target's
-- generation is built, a CPU use of it is held and never ended, and the host
-- exits. The owner's drain cannot verify the generation, so it retains it and,
-- above it, the surface, the device and the instance, and says so; the host's
-- exit then waits for evidence nobody will produce. That wait is not broken
-- from inside: a watcher records what was reported, the case's verdict is
-- written, and the process is terminated — which is #220's destructive
-- boundary, the escape the lifetime design leaves for exactly this, and never
-- an orderly cleanup. No diagnostic verdict follows, because the instance's
-- messengers are never destroyed and so the last callback is never reached.
--
-- No device loss is induced.
module Test.GPU.Vulkan.Native.Terminal
  ( ValidationOutcome (..)
  , runValidationStop
  , validationSection
  , validationSpec
  , RetentionFacts (..)
  , runRetention
  , retentionSection
  , retentionSpec
  , injectedMessageId
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM (STM, atomically, check, modifyTVar', newTVarIO, orElse, readTVar, readTVarIO, registerDelay, retry)
import Control.Exception (SomeException, displayException, finally, throwIO, try, tryWithContext)
import Control.Monad (forM_, replicateM, unless, void, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as Char8
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import qualified Data.Vector as Vector
import Data.Word (Word64)
import Foreign.Ptr (Ptr, nullPtr)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Vulkan.Core10 (Device, Instance, PhysicalDevice)
import Vulkan.Dynamic (getInstanceProcAddr')
import Vulkan.Extensions.VK_EXT_debug_utils
  ( DebugUtilsMessengerCallbackDataEXT (..)
  , DebugUtilsMessengerEXT
  , submitDebugUtilsMessageEXT
  , data DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT
  , data DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT
  )
import Vulkan.Extensions.VK_KHR_surface (SurfaceKHR (..), destroySurfaceKHR)
import Vulkan.Zero (zero)

import Hetoimasia.Foundation.Log
  ( DebugSelection (DebugAll)
  , LogEntry (..)
  , LogFilter (..)
  , LogLevel (Info)
  , Logger
  , callbackSink
  , mkLogger
  )
import Hetoimasia.Foundation.Messaging.Payload (prepare, preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)
import Hetoimasia.Foundation.Time (DurationRequirement (AllowZero), Instant, durationFromNanoseconds, scriptedInstant, scriptedSource, zeroDuration)
import Hetoimasia.GLFW.Command (clientObservations)
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GLFW.Window (WindowConfig (..), hiddenTestWindowConfig, observedRevision)
import Hetoimasia.GPU.Model.Budget (defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (SubmissionId, TargetClass (..), TargetId)
import Hetoimasia.GPU.Vulkan.Diagnostics
  ( CaptureConfig (..)
  , CaptureCounters (..)
  , CaptureStatus (..)
  , ConsumerOutcome (..)
  , DiagnosticCapture
  , DiagnosticVerdict (..)
  , Quiesced
  , VerdictIssue (..)
  , captureSinkFailure
  , captureStatus
  , defaultCaptureConfig
  , diagnosticVerdict
  , verdictIssues
  , withDiagnosticCapture
  )
import Hetoimasia.GPU.Vulkan.GLFW
  ( Readiness (..)
  , TeardownEvidence (..)
  , TerminalCause (..)
  , TerminalReport (..)
  , VulkanHandover (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , handOverVulkanTarget
  , readReadiness
  , readVulkanGenerations
  , readVulkanRoots
  , readVulkanTerminal
  , useVulkanGeneration
  , vulkanHostConfig
  , withVulkanOwnerHost
  )
import Hetoimasia.GPU.Vulkan.Native.Frames
import Hetoimasia.GPU.Vulkan.Native.Frames.Vulkan (vulkanFrameOps)
import Hetoimasia.GPU.Vulkan.Native.Generations
  ( GenerationStanding (..)
  , GenerationView (..)
  , Generations
  , TargetCondition (..)
  , TargetGenerationsView (..)
  , newGenerations
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
  ( DiagnosticAlarm (..)
  , RootStanding (..)
  , Roots
  , RootsView (..)
  , SurfaceDestruction (..)
  , TargetSurface (..)
  , admitRootTarget
  , destroyRoots
  , newRoots
  , readRootsDevice
  , readRootsInstance
  , readRootsTerminal
  , retireRootTarget
  , retireRoots
  , startRoots
  , watchRootsDiagnostics
  )
import Hetoimasia.GPU.Vulkan.Native.Roots.Vulkan (instancePointer, vulkanRootOps)
import Hetoimasia.Runtime.GLFW
  ( OwnerTerminal (..)
  , TargetStanding (..)
  , defaultHostConfig
  , graphicsAttachment
  , hostWindowClient
  , hostWindowIdentities
  , publishGraphicsObservation
  , readOwnerTerminalNow
  , readTargetStanding
  , readTargetTerminalsNow
  , runGraphicsOwnerApplication
  , windowRenderEligibility
  )
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Test.GPU.Vulkan.Native.Environment (validationFeatures)
import Test.Vulkan.Proof.Interop
  ( ProofWindow
  , createProofWindow
  , createWindowSurface
  , destroyProofWindow
  , framebufferSize
  , glfwInit
  , glfwTerminate
  , initVulkanLoader
  , lastGlfwError
  , pollEvents
  , requiredInstanceExtensions
  )
import Test.Vulkan.Proof.Journal (Journal, heading, note)
import Test.Vulkan.Proof.Roots (NativeCall (..), nativeCallObserver)

type VulkanRoots = Roots Quiesced Instance DebugUtilsMessengerEXT PhysicalDevice Device

type VulkanGenerations = Generations Quiesced Instance DebugUtilsMessengerEXT PhysicalDevice Device

-- | The message identifier of the one error this case injects. Any other
-- error-severity record fails it.
injectedMessageId ∷ ByteString
injectedMessageId = "VUID-hetoimasia-vk15-injected-validation-error"

-- | One stage of the case, and what the capture received during it.
data Step = Step
  { stepName ∷ !Text
  , stepReports ∷ !Word64
  , stepErrors ∷ !Word64
  }
  deriving (Show)

-- | What the capture's latches say, as a checkpoint asks them: the error latch
-- and the sink's failure. The controller installs the same watch.
alarms ∷ DiagnosticCapture → IO [DiagnosticAlarm]
alarms capture = do
  latched ← statusErrorLatched <$> captureStatus capture
  sink ← atomically (captureSinkFailure capture)
  pure ([AlarmValidationError | latched] <> [AlarmSinkFailed reason | Just reason ← [sink]])

-- ---------------------------------------------------------------------------
-- A validation error during rendering

data Stopped = Stopped
  { stoppedDevice ∷ !Text
  , stoppedPresented ∷ !Int
    -- ^ Frames presented and retired before the injected error.
  , stoppedPresentAnswer ∷ !(Either Refusal Presented)
    -- ^ What presenting the interrupted frame answered: the checkpoint.
  , stoppedAcquireAnswer ∷ !(Either Refusal Acquisition)
  , stoppedReport ∷ !TerminalReport
    -- ^ The terminal latch once the error was observed.
  , stoppedLeft ∷ !([FrameStanding], [PresentationStanding], [SubmissionId])
    -- ^ What the frames still held once teardown had drained them.
  , stoppedRetirement ∷ ![(Text, Maybe Text)]
    -- ^ Each retirement step, and what it raised if anything.
  , stoppedCalls ∷ ![Text]
    -- ^ Every native call the frames made, status queries and drain waits left
    -- out.
  }
  deriving (Show)

data ValidationFacts = ValidationFacts
  { factsStopped ∷ !Stopped
  , factsSteps ∷ ![Step]
  , factsEntries ∷ ![LogEntry]
  , factsVerdict ∷ !DiagnosticVerdict
  , factsOfferedAfterInstance ∷ !Word64
    -- ^ What the capture had been offered once @vkDestroyInstance@ returned.
  }
  deriving (Show)

data ValidationOutcome
  = ValidationRecorded ValidationFacts
  | ValidationStopped Text (Maybe DiagnosticVerdict) [Step] [LogEntry]
  deriving (Show)

validationCaptureConfig ∷ CaptureConfig
validationCaptureConfig = defaultCaptureConfig {captureTextBudget = 16384}

-- | How many drain steps, each waiting at most 10 ms, the case waits for any
-- one piece of evidence before it stops.
patience ∷ Int
patience = 500

stopWith ∷ Text → IO a
stopWith reason = throwIO (userError (Text.unpack reason))

-- | Run the case on the calling thread, which must be the process main thread.
runValidationStop ∷ Journal → IO ValidationOutcome
runValidationStop journal = do
  heading journal "VK-15: a validation error during rendering stops the session at its next checkpoint"
  logged ← newTVarIO []
  steps ← newIORef []
  offeredAfter ← newIORef 0
  let logger = recordingLogger (\entry → atomically (modifyTVar' logged (entry :)))
  entry ← Char8.useAsCString "vkGetInstanceProcAddr" (getInstanceProcAddr' nullPtr)
  initVulkanLoader entry
  started ← glfwInit
  outcome ←
    if not started
      then (\reason → Left (Text.unpack reason, Nothing)) <$> lastGlfwError
      else
        either (\failure → Left (displayException failure, diagnosticVerdict failure)) Right
          <$> try @SomeException (withDiagnosticCapture validationCaptureConfig logger (validationSession journal steps offeredAfter))
          `finally` glfwTerminate
  entries ← reverse <$> readTVarIO logged
  seen ← reverse <$> readIORef steps
  case outcome of
    Left (failure, verdict) → do
      note journal ("the session stopped: " <> Text.pack failure)
      pure (ValidationStopped (Text.pack failure) verdict seen entries)
    Right (stopped, verdict) → do
      note journal ("the lifetime delivered " <> tshow (verdictDelivered verdict) <> " records")
      offered ← readIORef offeredAfter
      pure (ValidationRecorded (ValidationFacts stopped seen entries verdict offered))

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

validationSession ∷ Journal → IORef [Step] → IORef Word64 → DiagnosticCapture → IO (Stopped, Quiesced)
validationSession journal steps offeredAfter capture = do
  let step ∷ Text → IO a → IO a
      step = measure capture steps
  required ← requiredInstanceExtensions >>= maybe (stopWith "GLFW requires no surface extensions, so no surface can be made") pure
  budgets ← either (stopWith . tshow) pure (validateBudgets defaultBudgetRequest)
  roots ← newRoots (vulkanRootOps capture) budgets (scriptedSource (pure (scriptedInstant zeroDuration)))
  -- The roots ask the capture at every checkpoint, as the controller has them.
  atomically (watchRootsDiagnostics roots (alarms capture))
  _ ← step "the instance and its messenger" (startRoots roots (InstanceRequest required ["VK_LAYER_KHRONOS_validation"] validationFeatures))
  proved ← newIORef Nothing
  let finish = do
        _ ← try @SomeException (step "the device" (retireRoots roots))
        quiesced ← step "the messenger and the instance" (destroyRoots roots)
        writeIORef offeredAfter . countOffered . statusCounters =<< captureStatus capture
        writeIORef proved quiesced
  stopped ← withWindow journal step roots `finally` finish
  readIORef proved >>= \case
    Just quiesced → pure (stopped, quiesced)
    Nothing → stopWith "the instance's destruction proved nothing"

withWindow ∷ Journal → (∀ a. Text → IO a → IO a) → VulkanRoots → IO Stopped
withWindow journal step roots = do
  instanceHandle ← atomically (readRootsInstance roots) >>= maybe (stopWith "the roots hold no instance") pure
  window ← createProofWindow 160 120 "hetoimasia VK-15 validation stop" >>= maybe (lastGlfwError >>= stopWith . ("no window: " <>)) pure
  (result, surface) ← step "the window's surface" (createWindowSurface (instancePointer instanceHandle) window)
  when (result /= 0) (stopWith ("glfwCreateWindowSurface answered " <> tshow result))
  let destroy = either SurfaceDestructionUncertain (const SurfaceDestroyed) <$> tryWithContext (destroySurfaceKHR instanceHandle (SurfaceKHR surface) Nothing)
  target ←
    step "the window's target" (admitRootTarget roots RequiredTarget (TargetSurface surface destroy))
      >>= either (stopWith . ("the target was refused: " <>) . tshow) pure
  generations ← newGenerations roots
  atomically (trackTarget generations target RequiredTarget surface)
  withFrames journal step roots generations window instanceHandle target `finally` destroyProofWindow window

withFrames
  ∷ Journal
  → (∀ a. Text → IO a → IO a)
  → VulkanRoots
  → VulkanGenerations
  → Ptr ProofWindow
  → Instance
  → TargetId
  → IO Stopped
withFrames journal step roots generations window instanceHandle target = do
  let geometry = do
        pollEvents
        (width, height) ← framebufferSize window
        pure (Map.singleton target (TargetGeometry (Right ()) (Just (SurfaceExtent (fromIntegral width) (fromIntegral height))) Nothing 1))
  _ ← step "the swapchain generation" (stepGenerations generations (at 0) =<< geometry)
  view ← atomically (readTargetGenerations generations target) >>= maybe (stopWith "the target is not tracked") pure
  unless (viewCondition view == Presenting) (stopWith ("the target is not presenting: " <> tshow (viewCondition view)))
  generation ← maybe (stopWith "the target has no active generation") pure (viewActive view >>= \active → find ((== active) . viewGeneration) (viewGenerations view))
  let format = surfaceFormat (planFormat (viewPlan generation))
      SurfaceExtent width height = planExtent (viewPlan generation)
  (devicePlan, _) ← atomically (readRootsDevice roots) >>= maybe (stopWith "the roots hold no device") pure
  ops ← vulkanRecordingOps (planDevice devicePlan)
  recording ← newRecording ops roots generations
  calls ← newIORef []
  frames ← newFrames (observing calls vulkanFrameOps) recording
  clock ← newIORef (1000 ∷ Integer)
  let tick = do
        now ← readIORef clock
        writeIORef clock (now + 17)
        pure now
      made ∷ Show refusal ⇒ Text → IO (Either refusal a) → IO a
      made name action = step name action >>= either (stopWith . ((name <> " was refused: ") <>) . tshow) pure
      command name action = action >>= either (stopWith . ((name <> " was refused: ") <>) . tshow) pure
      drain = do
        now ← tick
        report ← awaitFrames frames (at now) drainWaitLimit
        _ ← stepGenerations generations (at now) =<< geometry
        pure report
      acquire = go (1 ∷ Int)
        where
          go attempt =
            tryAcquireFrame frames target >>= \case
              Right (AcquisitionOwned frame) → pure frame
              Right (AcquisitionPending _) | attempt < patience → drain >> go (attempt + 1)
              other → stopWith ("no frame was acquired after " <> tshow attempt <> " attempts: " <> tshow other)
  layout ← made "vkCreatePipelineLayout" (createPipelineLayout recording)
  pipeline ← made "vkCreateGraphicsPipelines" (createPipeline recording layout verificationShaders format)
  forM_ [0, 1] $ \slot → made ("vkCreateCommandPool, slot " <> tshow slot) (createFrameStorage recording target slot)
  let render name frame = do
        (batch, ()) ←
          made name $
            recordFrame recording (ownedFrame frame) $ \recorder → do
              command "the transition into rendering" (transitionImage recorder LayoutUndefined LayoutColorAttachment)
              command "vkCmdBeginRendering" (beginRendering recorder (ClearColor 0.1 0.1 0.1 1))
              command "vkCmdBindPipeline" (bindPipeline recorder pipeline)
              command "vkCmdSetViewport" (setViewport recorder (Viewport 0 0 (fromIntegral width) (fromIntegral height)))
              command "vkCmdSetScissor" (setScissor recorder (Rect 0 0 width height))
              command "vkCmdDraw" (draw recorder 3 1)
              command "vkCmdEndRendering" (endRendering recorder)
              command "the transition to presentation" (transitionImage recorder LayoutColorAttachment LayoutPresentSource)
        step ("vkQueueSubmit2, " <> name) (submitFrames frames (batch :| [])) >>= \case
          Right (SubmittedAs _) → pure ()
          other → stopWith ("the submission answered " <> tshow other)
  outcome ← try @SomeException $ do
    -- 1. Ordinary rendering: two frames presented, each retired on its own
    --    present fence.
    presented ← replicateM 2 $ do
      frame ← acquire
      render "a triangle" frame
      step "vkQueuePresentKHR" (presentFrame frames (ownedFrame frame)) >>= \case
        Right (PresentedAs presentation _) → pure presentation
        other → stopWith ("the presentation answered " <> tshow other)
    let retired seen count = do
          left ← atomically (readPresentations frames)
          if all ((`notElem` presented) . standingPresentation) left
            then pure seen
            else
              if count >= patience
                then stopWith "the presentations did not retire"
                else drain >> retired seen (count + (1 ∷ Int))
    _ ← step "awaiting the present fences" (retired () 0)
    note journal "presented two triangle frames and observed both present fences"
    -- 2. A third frame, submitted, and then the injected error.
    interrupted ← acquire
    render "the frame the error interrupts" interrupted
    step "vkSubmitDebugUtilsMessageEXT, the injected error" $
      submitDebugUtilsMessageEXT
        instanceHandle
        DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT
        DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT
        ( DebugUtilsMessengerCallbackDataEXT
            { next = ()
            , flags = zero
            , messageIdName = Just injectedMessageId
            , messageIdNumber = 0
            , message = Just (Encoding.encodeUtf8 "an error-severity validation message injected by VK-15's native case")
            , queueLabels = Vector.empty
            , cmdBufLabels = Vector.empty
            , objects = Vector.empty
            }
            ∷ DebugUtilsMessengerCallbackDataEXT '[]
        )
    note journal "injected one error-severity validation message during rendering"
    -- 3. The next checkpoints refuse, naming it.
    presentAnswer ← step "vkQueuePresentKHR, refused at the checkpoint" (presentFrame frames (ownedFrame interrupted))
    acquireAnswer ← step "vkAcquireNextImageKHR, refused at the checkpoint" (tryAcquireFrame frames target)
    report ← atomically (readRootsTerminal roots)
    note journal ("the checkpoint answered " <> tshow presentAnswer <> "; the primary is " <> tshow (reportPrimary report))
    pure (length presented, presentAnswer, acquireAnswer, report)
  -- 4. Teardown, under the ordinary rules: close what is live, drain until
  --    every obligation has settled on its own evidence, then retire.
  _ ← try @SomeException (step "closing the window's frames" (closeTargetFrames frames target))
  let settle count = do
        _ ← try @SomeException drain
        left ← atomically ((,,) <$> readFrameStandings frames <*> readPresentations frames <*> readOutstandingSubmissions frames)
        case left of
          ([], [], []) → pure left
          _ | count >= patience → pure left
          _ → settle (count + (1 ∷ Int))
  left ← step "draining the frames" (settle 1)
  retirement ←
    mapM
      (\(name, action) → (,) name . either (Just . Text.pack . displayException) (const Nothing) <$> try @SomeException (step name action))
      [ ("retiring the frames", retireTargetFrames frames target)
      , ("retiring the generations", retireTargetGenerations generations (at 90000) target)
      , ("destroying the surface", retireRootTarget roots target)
      , ("releasing and destroying the managed resources", retireRecording recording (at 90000))
      ]
  made' ← reverse <$> readIORef calls
  plan ← pure devicePlan
  case outcome of
    Left failure → throwIO failure
    Right (count, presentAnswer, acquireAnswer, report) →
      pure
        Stopped
          { stoppedDevice = planDeviceName plan
          , stoppedPresented = count
          , stoppedPresentAnswer = presentAnswer
          , stoppedAcquireAnswer = acquireAnswer
          , stoppedReport = report
          , stoppedLeft = left
          , stoppedRetirement = retirement
          , stoppedCalls = made'
          }

-- | The frames layer, noting each call's entry point before it is made.
observing ∷ IORef [Text] → FrameOps dev cmd → FrameOps dev cmd
observing calls ops =
  ops
    { opsCreateSemaphore = \device → noted "vkCreateSemaphore" (opsCreateSemaphore ops device)
    , opsDestroySemaphore = \device handle → noted "vkDestroySemaphore" (opsDestroySemaphore ops device handle)
    , opsCreateFence = \device → noted "vkCreateFence" (opsCreateFence ops device)
    , opsDestroyFence = \device handle → noted "vkDestroyFence" (opsDestroyFence ops device handle)
    , opsResetFence = \device handle → noted "vkResetFences" (opsResetFence ops device handle)
    , opsAcquireImage = \device swapchain semaphore → noted "vkAcquireNextImageKHR" (opsAcquireImage ops device swapchain semaphore)
    , opsSubmit = \device family batches fence →
        noted ("vkQueueSubmit2: " <> (if all (null . submitCommands) batches then "cleanup" else "rendering")) (opsSubmit ops device family batches fence)
    , opsReleaseImages = \device swapchain indices → noted "vkReleaseSwapchainImagesEXT" (opsReleaseImages ops device swapchain indices)
    , opsPresent = \device family request status → noted "vkQueuePresentKHR" (opsPresent ops device family request status)
    }
  where
    noted ∷ Text → IO a → IO a
    noted name action = modifyIORef' calls (name :) >> action

validationSection ∷ ValidationOutcome → [Text]
validationSection = \case
  ValidationStopped reason verdict steps logged →
    ["", "## The session stopped", "", reason, ""]
      <> stepTable steps
      <> ["", "- error reports: " <> errorReports logged, "- verdict issues: " <> maybe "no verdict" (tshow . verdictIssues) verdict]
  ValidationRecorded facts →
    let stopped = factsStopped facts
        verdict = factsVerdict facts
        report = stoppedReport stopped
     in [ ""
        , "## A validation error during rendering"
        , ""
        , "- device: " <> stoppedDevice stopped
        , "- frames presented and retired before the error: " <> tshow (stoppedPresented stopped)
        , "- the interrupted frame's presentation answered: " <> tshow (stoppedPresentAnswer stopped)
        , "- a further acquisition answered: " <> tshow (stoppedAcquireAnswer stopped)
        , "- primary failure: " <> tshow (reportPrimary report)
        , "- device loss observed: " <> tshow (reportDeviceLost report)
        , "- teardown evidence: " <> tshow (reportEvidence report)
        , "- left once teardown had drained: " <> tshow (stoppedLeft stopped)
        , "- retirement: " <> Text.intercalate "; " [name <> ": " <> maybe "returned" ("raised " <>) raised | (name, raised) ← stoppedRetirement stopped]
        , ""
        , "Native calls the frames made, status queries and drain waits left out:"
        , ""
        ]
          <> ["1. " <> call | call ← stoppedCalls stopped]
          <> [""]
          <> stepTable (factsSteps facts)
          <> [ ""
             , "- error reports: " <> errorReports (factsEntries facts)
             , "- offered once vkDestroyInstance had returned: " <> tshow (factsOfferedAfterInstance facts)
             , "- offered in the verdict: " <> tshow verdict.verdictStatus.statusCounters.countOffered
             , "- records delivered: " <> tshow (verdictDelivered verdict)
             , "- undelivered: " <> tshow (verdictUndelivered verdict)
             , "- verdict issues: " <> tshow (verdictIssues verdict)
             ]
  where
    errorReports logged = case [Map.findWithDefault "" "message.id" entry.entryFields <> ": " <> Text.take 600 entry.entryMessage | entry ← logged, Map.lookup "severity" entry.entryFields == Just "error"] of
      [] → "none"
      reports → Text.intercalate "; " reports
    stepTable steps =
      ["| step | reports | errors |", "| --- | --- | --- |"]
        <> ["| " <> each.stepName <> " | " <> tshow each.stepReports <> " | " <> tshow each.stepErrors <> " |" | each ← steps]

validationSpec ∷ ValidationOutcome → Spec
validationSpec outcome = describe "VK-15 validation stop" $ do
  it "established its private roots, its window's generation, its resources and its frames, and rendered before the error" $
    onValidation outcome $ \facts → stoppedPresented (factsStopped facts) `shouldBe` 2

  it "refused the interrupted frame's presentation and a further acquisition at the next checkpoint, naming the injected error" $
    onValidation outcome $ \facts → do
      let stopped = factsStopped facts
      refusal (stoppedPresentAnswer stopped) `shouldBe` Just TerminalValidationError
      refusal (stoppedAcquireAnswer stopped) `shouldBe` Just TerminalValidationError
      -- Neither refusal made a native call: the presentation after the
      -- injection is the only one missing.
      length [() | call ← stoppedCalls stopped, call == "vkQueuePresentKHR"] `shouldBe` stoppedPresented stopped

  it "made the error the session's primary failure, with no device loss, and tore down under the ordinary rules with every obligation settled" $
    onValidation outcome $ \facts → do
      let stopped = factsStopped facts
          report = stoppedReport stopped
      reportPrimary report `shouldBe` Just TerminalValidationError
      reportDeviceLost report `shouldBe` Nothing
      stoppedLeft stopped `shouldBe` ([], [], [])
      [(name, raised) | (name, Just raised) ← stoppedRetirement stopped] `shouldBe` []

  it "received exactly one error, the injected one, and no other in any step" $
    onValidation outcome $ \facts → do
      [(each.stepName, each.stepErrors) | each ← factsSteps facts, each.stepErrors > 0]
        `shouldBe` [("vkSubmitDebugUtilsMessageEXT, the injected error", 1)]
      [Map.lookup "message.id" entry.entryFields | entry ← factsEntries facts, Map.lookup "severity" entry.entryFields == Just "error"]
        `shouldBe` [Just (Encoding.decodeUtf8 injectedMessageId)]

  it "counted the final callbacks in a verdict whose only issue is the injected error" $
    onValidation outcome $ \facts → do
      let verdict = factsVerdict facts
          counters = verdict.verdictStatus.statusCounters
      verdictIssues verdict `shouldBe` [ErrorLatched]
      counters.countErrors `shouldBe` 1
      counters.countAdmitted `shouldBe` counters.countOffered
      verdict.verdictDelivered `shouldBe` counters.countAdmitted
      verdict.verdictUndelivered `shouldBe` 0
      verdict.verdictQuiescent `shouldBe` True
      completed verdict.verdictConsumer `shouldBe` True
      -- Everything offered through vkDestroyInstance is in the verdict, and
      -- nothing after it: the verdict follows the last callback.
      counters.countOffered `shouldBe` factsOfferedAfterInstance facts
  where
    refusal = \case
      Left (RefusedSessionFailed primary) → Just primary
      _ → Nothing
    completed = \case
      ConsumerCompleted → True
      _ → False

onValidation ∷ ValidationOutcome → (ValidationFacts → Expectation) → Expectation
onValidation outcome assertion = case outcome of
  ValidationStopped reason _ _ _ → expectationFailure ("the validation-stop session stopped: " <> Text.unpack reason)
  ValidationRecorded facts → assertion facts

-- ---------------------------------------------------------------------------
-- A retained unverified resource

data RetentionFacts = RetentionFacts
  { retentionHeld ∷ !Bool
    -- ^ Whether a CPU use of the active generation was held.
  , retentionReport ∷ !TerminalReport
  , retentionOwner ∷ !OwnerTerminal
  , retentionRoots ∷ !RootsView
  , retentionGeneration ∷ !(Maybe GenerationStanding)
    -- ^ Where the held generation stood when the watcher read it.
  , retentionCalls ∷ ![Text]
    -- ^ Every observed native call, in the order they returned.
  , retentionWindowHeld ∷ !Bool
    -- ^ Whether the host still holds the window, its attachment with no
    -- terminal record: nothing the owner produced lets it go.
  }
  deriving (Show)

-- | Run the case on the calling thread, which must be the process main thread.
-- It never returns: once the retention has been reported, the watcher hands
-- the facts to the continuation, which writes the case's record and
-- terminates the process.
runRetention ∷ Journal → (Either Text RetentionFacts → IO ()) → IO a
runRetention journal conclude = do
  heading journal "VK-15: a retained unverified resource, reported rather than released"
  recorded ← newIORef []
  logged ← newTVarIO []
  scene ← prepare ()
  budgets ← either (stopWith . tshow) pure (validateBudgets defaultBudgetRequest)
  let window = (hiddenTestWindowConfig "hetoimasia VK-15 retention" 160 120) {windowVisible = True}
      host = defaultHost [window]
      logger = recordingLogger (\entry → atomically (modifyTVar' logged (entry :)))
      config =
        (vulkanHostConfig host defaultCaptureConfig {captureTextBudget = 16384} budgets scene)
          { vulkanLayers = ["VK_LAYER_KHRONOS_validation"]
          , vulkanValidationFeatures = validationFeatures
          , vulkanObserver = nativeCallObserver recorded
          }
  outcome ←
    try @SomeException $
      withLoaderIntegration $ \integration →
        runGraphicsOwnerApplication
          (withLoggingLifetime logger)
          "vulkan-native-vk15-retention"
          (\_ use → fst <$> withVulkanOwnerHost logger integration config use)
          vulkanWindowHost
          (\vulkan _ → pure vulkan)
          (\vulkan _ → body vulkan recorded)
  -- The host's exit waits for evidence nobody will produce; returning here
  -- means it did not, which is itself the failure.
  conclude (Left ("the host returned, or failed, instead of retaining: " <> either (Text.pack . displayException) (const "it returned") outcome))
  stopWith "the process was not terminated"
  where
    defaultHost = defaultHostConfig
    body vulkan recorded = do
      let controller = vulkanController vulkan
          owner = vulkanGraphicsOwner vulkan
      readiness ← awaitWithin 10 "the owner's startup" (settledReadiness <$> readReadiness controller)
      case readiness of
        RootsFailed reason → stopWith ("the owner's startup failed: " <> reason)
        _ → pure ()
      windows ← atomically (hostWindowIdentities (vulkanWindowHost vulkan))
      windowId ← case windows of
        [one] → pure one
        other → stopWith ("the host holds " <> tshow (length other) <> " windows, not one")
      service ←
        handOverVulkanTarget vulkan windowId RequiredTarget >>= \case
          VulkanTargetHandedOver service → pure service
          other → stopWith ("the window was not handed over: " <> tshow other)
      standing ← awaitWithin 10 "the target's admission" $
        readTargetStanding owner (graphicsAttachment service) >>= \case
          Nothing → pure Nothing
          Just TargetConstructing → pure Nothing
          Just other → pure (Just other)
      unless (standing == TargetUsable) (stopWith ("the target was not admitted: " <> tshow standing))
      -- Publish the window's observation, as an application's loop does, so
      -- the owner builds its generation.
      client ← atomically (hostWindowClient (vulkanWindowHost vulkan) windowId) >>= maybe (stopWith "the window has no client") pure
      observation ← preparedValue . observedValue <$> atomically (readSnapshot (clientObservations client))
      _ ← publishGraphicsObservation owner service (observedRevision observation + 1) observation (windowRenderEligibility observation) Nothing
      active ← awaitWithin 10 "the target's generation" $
        readVulkanGenerations controller (graphicsAttachment service) >>= \case
          Just view | viewCondition view == Presenting → pure (viewActive view)
          _ → pure Nothing
      -- The deliberately retained resource: a CPU use of the generation that
      -- is held and never ended, so nothing can verify that it may go.
      held ← atomically (useVulkanGeneration controller active)
      note journal ("holding a CPU use of " <> tshow active <> ": " <> either tshow (const "held") held)
      -- The watcher: once the owner's drain has reported the retention, the
      -- owner's run has ended without destruction evidence and the host has
      -- said so, it records what it saw and hands it on. Everything it reads
      -- is read while the host still waits.
      void . forkIO $ do
        facts ← try @SomeException $ do
          (report, terminal) ← awaitWithin 20 "the reported retention" $ do
            report ← readVulkanTerminal controller
            terminal ← readOwnerTerminalNow owner
            pure $
              if ownerRunEnded terminal && any retainedEvidence (reportEvidence report)
                then Just (report, terminal)
                else Nothing
          roots ← atomically (readVulkanRoots controller)
          generations ← atomically (readVulkanGenerations controller (graphicsAttachment service))
          calls ← map (.callName) . reverse <$> readIORef recorded
          -- The owner ended; the attachment it could not retire has no terminal
          -- record, so the host still holds the window, and will.
          terminals ← atomically (readTargetTerminalsNow owner)
          held' ← (windowId `elem`) <$> atomically (hostWindowIdentities (vulkanWindowHost vulkan))
          pure
            RetentionFacts
              { retentionHeld = either (const False) (const True) held
              , retentionReport = report
              , retentionOwner = terminal
              , retentionRoots = roots
              , retentionGeneration = generations >>= \view → lookup active [(viewGeneration each, viewStanding each) | each ← viewGenerations view]
              , retentionCalls = calls
              , retentionWindowHeld = held' && Map.notMember (graphicsAttachment service) terminals
              }
        case facts of
          Right found → conclude (Right found)
          Left failure → do
            -- Say which part of the report never arrived.
            report ← atomically (readVulkanTerminal controller)
            terminal ← atomically (readOwnerTerminalNow owner)
            conclude . Left $
              Text.pack (displayException failure)
                <> "; the owner's run ended: " <> tshow (ownerRunEnded terminal)
                <> "; the report: " <> tshow report
      note journal "the host exits with the generation's use still held"
    settledReadiness = \case
      RootsPending → Nothing
      other → Just other
    retainedEvidence = \case
      RetainedUnverified _ → True
      _ → False

retentionSection ∷ Either Text RetentionFacts → [Text]
retentionSection = \case
  Left reason → ["", "## The retention case did not reach its report", "", reason]
  Right facts →
    [ ""
    , "## A retained unverified resource"
    , ""
    , "- a CPU use of the active generation held and never ended: " <> tshow (retentionHeld facts)
    , "- where the held generation stood: " <> tshow (retentionGeneration facts)
    , "- primary failure: " <> tshow (reportPrimary (retentionReport facts))
    , "- what teardown reported retained:"
    ]
      <> ["  - " <> tshow evidence | evidence ← reportEvidence (retentionReport facts)]
      <> [ "- the owner's run ended: " <> tshow (ownerRunEnded (retentionOwner facts)) <> "; destruction evidence: " <> tshow (ownerDestroyedEvidence (retentionOwner facts))
         , "- the roots when the watcher read them: instance " <> tshow (viewInstance (retentionRoots facts)) <> ", device " <> tshow (viewDevice (retentionRoots facts)) <> ", targets " <> tshow (length (viewTargets (retentionRoots facts)))
         , "- the host still holds the window, its attachment without a terminal record: " <> tshow (retentionWindowHeld facts)
         , ""
         , "The process was then terminated by the fixture's destructive boundary. The"
         , "session released nothing more: the operating system reclaims the window,"
         , "the surface, the device and the instance. This is not orderly cleanup,"
         , "and no diagnostic verdict follows, because the instance's messengers were"
         , "never destroyed and the last callback was never reached."
         , ""
         , "Native calls the session made, in the order they returned:"
         , ""
         ]
      <> ["1. " <> call | call ← retentionCalls facts]

retentionSpec ∷ Either Text RetentionFacts → Spec
retentionSpec outcome = describe "VK-15 retention" $ do
  it "held a CPU use of the target's active generation, which nothing certified as ended" $
    onRetention outcome $ \facts → do
      retentionHeld facts `shouldBe` True
      retentionGeneration facts `shouldSatisfy` isJust

  it "reported the generation and every parent above it as retained, without calling that a failure" $
    onRetention outcome $ \facts → do
      let report = retentionReport facts
      reportPrimary report `shouldBe` Nothing
      reportDeviceLost report `shouldBe` Nothing
      length [() | RetainedUnverified _ ← reportEvidence report] `shouldSatisfy` (>= 2)

  it "destroyed nothing the held generation depends on: not its swapchain, the surface, the device, the messenger or the instance" $
    onRetention outcome $ \facts → do
      [call | call ← retentionCalls facts, call `elem` ["vkDestroySwapchainKHR", "vkDestroySurfaceKHR", "vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]]
        `shouldBe` []
      viewDevice (retentionRoots facts) `shouldBe` RootLive
      viewInstance (retentionRoots facts) `shouldBe` RootLive
      length (viewTargets (retentionRoots facts)) `shouldBe` 1

  it "ended the owner's run without destruction evidence or the target's terminal record, so the host still holds the window and every parent" $
    onRetention outcome $ \facts → do
      ownerRunEnded (retentionOwner facts) `shouldBe` True
      ownerDestroyedEvidence (retentionOwner facts) `shouldSatisfy` isNothing
      retentionWindowHeld facts `shouldBe` True

onRetention ∷ Either Text RetentionFacts → (RetentionFacts → Expectation) → Expectation
onRetention outcome assertion = case outcome of
  Left reason → expectationFailure ("the retention case did not reach its report: " <> Text.unpack reason)
  Right facts → assertion facts

-- ---------------------------------------------------------------------------
-- Shared

-- | Wait for a transaction to answer, failing after the given seconds rather
-- than waiting forever on a session that stopped progressing.
awaitWithin ∷ Double → Text → STM (Maybe a) → IO a
awaitWithin seconds what transaction = do
  expired ← registerDelay (round (seconds * 1000000))
  atomically ((transaction >>= maybe retry (pure . Just)) `orElse` (Nothing <$ (readTVar expired >>= check)))
    >>= maybe (throwIO (userError (Text.unpack what <> " did not happen within " <> show seconds <> " seconds"))) pure

recordingLogger ∷ (LogEntry → IO ()) → Logger
recordingLogger keep =
  mkLogger
    LogFilter
      { filterEnabled = True
      , filterGlobalLevel = Info
      , filterComponentLevels = Map.empty
      , filterDebug = DebugAll
      , filterSource = False
      }
    (callbackSink keep)

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
