{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | #250's native case: a real validation report on a named managed resource,
-- inside a labelled recording region, carried by the capture with that
-- resource's name.
--
-- The roots, the generation and the managed resources are VK-11's native
-- case's, built the same way on private roots: the production native layer
-- planned from the request every native case uses — the validation layer with
-- synchronization validation — one window's surface, a generation built for a
-- verification capture, and the production recording layer, which names every
-- object it creates and labels every batch because the device offers
-- @VK_EXT_debug_utils@. The batch is VK-11's triangle and copy.
--
-- = The provoked report
--
-- The one thing that differs is a destructive seam this fixture alone holds:
-- it wraps the production recording layer so that the batch's copy into the
-- readback buffer is recorded, through the binding's own call, starting
-- 'overrunBytes' into the buffer rather than at its start. The whole image no
-- longer fits, which core validation reports while the command is recorded, as
-- 'expectedMessageId', naming the buffer among its objects. Nothing is
-- submitted, so no invalid work ever reaches the GPU; no handle leaves the
-- backend's public interface, since the wrapper sees only what the backend
-- hands its own native layer; and the batch is discarded like VK-11's.
--
-- The case passes when that report, and no other error, reached the capture;
-- when its objects carry the readback buffer's handle with the name the
-- backend gave it; when the label the backend opened around the batch is the
-- innermost command-buffer label of the report, if the pinned layer reports
-- command-buffer labels at all — which labels each layer populates is recorded
-- in the record, not assumed; and when the error latch, and nothing else,
-- fails the verdict after the last teardown callback, with nothing lost.
module Test.GPU.Vulkan.Native.Naming
  ( NamingOutcome (..)
  , runNaming
  , namingSection
  , expectedMessageId
  , spec
  ) where

import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception (SomeException, displayException, finally, throwIO, try, tryWithContext)
import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as Char8
import Data.Foldable (for_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import qualified Data.Vector as Vector
import Data.Word (Word32, Word64)
import Foreign.Ptr (nullPtr)
import Numeric (showHex)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Vulkan.Core10
  ( Buffer (..)
  , BufferImageCopy (..)
  , CommandBuffer
  , Device
  , Extent3D (..)
  , Image (..)
  , ImageAspectFlagBits (IMAGE_ASPECT_COLOR_BIT)
  , ImageSubresourceLayers (..)
  , Instance
  , Offset3D (..)
  , PhysicalDevice
  , cmdCopyImageToBuffer
  , data IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
  )
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
import Hetoimasia.GPU.Model.Identity (GenerationId, TargetClass (..), TargetId, frameSlotNumber)
import Hetoimasia.GPU.Vulkan.Diagnostics
  ( CaptureConfig (..)
  , CaptureCounters (..)
  , CaptureStatus (..)
  , ConsumerOutcome (..)
  , DiagnosticCapture
  , DiagnosticVerdict (..)
  , Quiesced
  , VerdictIssue (..)
  , captureStatus
  , defaultCaptureConfig
  , diagnosticVerdict
  , verdictIssues
  , withDiagnosticCapture
  )
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
import Hetoimasia.GPU.Vulkan.Native.Naming (NativeObjectKind (ObjectBuffer), batchLabel, objectTypeCode, readbackBufferName)
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
  , readRootsInstrumentation
  , retireRootTarget
  , retireRoots
  , startRoots
  )
import Hetoimasia.GPU.Vulkan.Native.Roots.Vulkan (instancePointer, vulkanRootOps)
import Test.GPU.Vulkan.Native.Environment (validationFeatures)
import Test.GPU.Vulkan.Native.Recording (acquireInModel, settleInModel)
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

-- | The report core validation gives a copy whose buffer region runs past the
-- end of the buffer.
expectedMessageId ∷ Text
expectedMessageId = "VUID-vkCmdCopyImageToBuffer-pRegions-00183"

-- | How far into the readback buffer the provoked copy starts: one texel, so
-- the offset stays texel-aligned and only the region's end is wrong.
overrunBytes ∷ Word64
overrunBytes = 4

-- | The step whose command is the provoked copy.
provokedStep ∷ Text
provokedStep = "recording the batch, with the copy overrunning the readback buffer"

-- | One stage of the case, and what the capture received during it.
data NamingStep = NamingStep
  { stepName ∷ !Text
  , stepReports ∷ !Word64
  , stepErrors ∷ !Word64
  }
  deriving (Show)

-- | What the native session observed, before its lifetime's verdict.
data Observed = Observed
  { observedDevice ∷ !Text
  , observedInstrumented ∷ !Bool
    -- ^ Whether the device offered naming, and so labels.
  , observedBatch ∷ !(Maybe BatchView)
  , observedBuffer ∷ !Word64
    -- ^ The readback buffer's native handle.
  , observedBufferName ∷ !ByteString
    -- ^ The name the backend derives for it from its 'ResourceId'.
  , observedBatchLabel ∷ !ByteString
    -- ^ The label the backend opened around the batch.
  }
  deriving (Show)

data NamingFacts = NamingFacts
  { factsObserved ∷ !Observed
  , factsSteps ∷ ![NamingStep]
  , factsEntries ∷ ![LogEntry]
  , factsVerdict ∷ !DiagnosticVerdict
  }
  deriving (Show)

data NamingOutcome
  = NamingRecorded NamingFacts
  | NamingStopped Text (Maybe DiagnosticVerdict) [NamingStep]
  deriving (Show)

-- | The capture limits: the ones the shared roots run under.
namingCaptureConfig ∷ CaptureConfig
namingCaptureConfig = defaultCaptureConfig {captureTextBudget = 16384}

stopWith ∷ Text → IO a
stopWith reason = throwIO (userError (Text.unpack reason))

-- | Run the case on the calling thread, which must be the process main
-- thread: GLFW's window and surface are made there, and so is everything
-- else, since this private process has no other owner.
runNaming ∷ Journal → IO NamingOutcome
runNaming journal = do
  heading journal "#250: a validation report on a named managed resource inside a labelled batch"
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
  started ← glfwInit
  outcome ←
    if not started
      then (\reason → Left (Text.unpack reason, Nothing)) <$> lastGlfwError
      else
        either (\failure → Left (displayException failure, diagnosticVerdict failure)) Right
          <$> try @SomeException (withDiagnosticCapture namingCaptureConfig logger (session journal steps))
          `finally` glfwTerminate
  entries ← reverse <$> readTVarIO logged
  seen ← reverse <$> readIORef steps
  case outcome of
    Left (failure, verdict) → do
      note journal ("the naming session stopped: " <> Text.pack failure)
      pure (NamingStopped (Text.pack failure) verdict seen)
    Right (observed, verdict) → do
      for_ (errorEntries entries) $ \errorEntry → do
        note journal ("error " <> field "message.id" errorEntry <> ": objects " <> tshow (objectsOf errorEntry))
        note journal ("  queue labels reported: " <> orNone (field "queue.labels" errorEntry) <> ", " <> tshow (labelsOf "queue" errorEntry))
        note journal ("  command-buffer labels reported: " <> orNone (field "cmdbuf.labels" errorEntry) <> ", " <> tshow (labelsOf "cmdbuf" errorEntry))
      note journal ("the lifetime delivered " <> tshow (verdictDelivered verdict) <> " records")
      pure (NamingRecorded (NamingFacts observed seen entries verdict))
  where
    orNone value = if Text.null value then "none" else value

-- | Count what the capture received during one stage.
measure ∷ DiagnosticCapture → IORef [NamingStep] → Text → IO a → IO a
measure capture steps name action = do
  before ← statusCounters <$> captureStatus capture
  result ← action
  after ← statusCounters <$> captureStatus capture
  modifyIORef' steps (NamingStep name (countOffered after - countOffered before) (countErrors after - countErrors before) :)
  pure result

-- | The instant this many milliseconds after the scripted origin.
at ∷ Integer → Instant
at milliseconds = scriptedInstant (either (error . show) id (durationFromNanoseconds AllowZero (milliseconds * 1000000)))

session ∷ Journal → IORef [NamingStep] → DiagnosticCapture → IO (Observed, Quiesced)
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
  window ← createProofWindow 160 120 "hetoimasia #250 names and labels" >>= maybe (lastGlfwError >>= stopWith . ("no window: " <>)) pure
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
  (devicePlan, _) ← atomically (readRootsDevice roots) >>= maybe (stopWith "the roots hold no device") pure
  instrumented ← isJust <$> readRootsInstrumentation roots
  note journal ("the device " <> planDeviceName devicePlan <> (if instrumented then " offers" else " does not offer") <> " debug-utils naming")
  ops ← vulkanRecordingOps (planDevice devicePlan)
  recording ← newRecording (provoking ops) roots generations
  (batch, buffer, bufferName) ← record journal step roots recording target (viewGeneration generation) extent format
  step "releasing and destroying the managed resources" (retireRecording recording (at 1))
  pure
    Observed
      { observedDevice = planDeviceName devicePlan
      , observedInstrumented = instrumented
      , observedBatch = batch
      , observedBuffer = buffer
      , observedBufferName = bufferName
      , observedBatchLabel = maybe "" (\held → batchLabel (viewBatch held) (viewGeneration generation)) batch
      }

-- | The production layer, with the one destructive seam this fixture holds:
-- a copy into a readback buffer is recorded 'overrunBytes' into the buffer, so
-- the whole image no longer fits. Every other call is the production layer's.
provoking ∷ RecordingOps Device CommandBuffer → RecordingOps Device CommandBuffer
provoking ops =
  ops
    { opsRecord = \commands → \case
        CommandCopyImageToBuffer image extent buffer →
          cmdCopyImageToBuffer
            commands
            (Image image)
            IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
            (Buffer buffer)
            ( Vector.singleton
                BufferImageCopy
                  { bufferOffset = overrunBytes
                  , bufferRowLength = 0
                  , bufferImageHeight = 0
                  , imageSubresource = ImageSubresourceLayers {aspectMask = IMAGE_ASPECT_COLOR_BIT, mipLevel = 0, baseArrayLayer = 0, layerCount = 1}
                  , imageOffset = Offset3D 0 0 0
                  , imageExtent = Extent3D (extentWidth extent) (extentHeight extent) 1
                  }
            )
        other → opsRecord ops commands other
    }

-- | Construct the managed resources, supply the frame, record the batch with
-- its provoked copy, and discard it.
record
  ∷ Journal
  → (∀ a. Text → IO a → IO a)
  → VulkanRoots
  → Recording Quiesced Instance DebugUtilsMessengerEXT PhysicalDevice Device CommandBuffer
  → TargetId
  → GenerationId
  → SurfaceExtent
  → Word32
  → IO (Maybe BatchView, Word64, ByteString)
record journal step roots recording target generation extent format = do
  let made ∷ Show refusal ⇒ Text → IO (Either refusal a) → IO a
      made name action = step name action >>= either (stopWith . ((name <> " was refused: ") <>) . tshow) pure
      command name action = action >>= either (stopWith . ((name <> " was refused: ") <>) . tshow) pure
      width = extentWidth extent
      height = extentHeight extent
  layout ← made "vkCreatePipelineLayout" (createPipelineLayout recording)
  pipeline ← made "vkCreateGraphicsPipelines" (createPipeline recording layout verificationShaders format)
  frame ← acquireInModel roots target
  _ ← made "vkCreateCommandPool" (createFrameStorage recording target (frameSlotNumber frame))
  readback ← made "vkCreateBuffer" (createReadback recording (readbackBytesFor extent))
  buffer ←
    atomically (readManaged recording) >>= \views →
      case [handle | view ← views, viewResource view == managedResource readback, handle : _ ← [viewNativeHandles view]] of
        handle : _ → pure handle
        [] → stopWith "the readback buffer has no native handle"
  let bufferName = readbackBufferName (managedResource readback)
  note journal ("the readback buffer 0x" <> Text.pack (showHex buffer "") <> " is named " <> decode bufferName)
  (batch, ()) ←
    made provokedStep $
      recordFrame recording frame $ \recorder → do
        command "the transition into rendering" (transitionImage recorder LayoutUndefined LayoutColorAttachment)
        command "vkCmdBeginRendering" (beginRendering recorder (ClearColor 0.1 0.1 0.1 1))
        command "vkCmdBindPipeline" (bindPipeline recorder pipeline)
        command "vkCmdSetViewport" (setViewport recorder (Viewport 0 0 (fromIntegral width) (fromIntegral height)))
        command "vkCmdSetScissor" (setScissor recorder (Rect 0 0 width height))
        command "vkCmdDraw" (draw recorder 3 1)
        command "vkCmdEndRendering" (endRendering recorder)
        command "the transition to the copy" (transitionImage recorder LayoutColorAttachment LayoutTransferSource)
        command "the overrunning copy" (copyToReadback recorder readback)
        command "the transition to presentation" (transitionImage recorder LayoutTransferSource LayoutPresentSource)
  view ← atomically (readBatch recording batch)
  note journal ("recorded " <> tshow batch <> ", labelled " <> decode (batchLabel batch generation) <> ": " <> tshow view)
  step "vkResetCommandPool, discarding the batch" (discardBatch recording batch) >>= either (stopWith . ("the discard was refused: " <>) . tshow) pure
  settleInModel roots frame
  pure (view, buffer, bufferName)

-- | The record's section.
namingSection ∷ NamingOutcome → [Text]
namingSection = \case
  NamingStopped reason verdict steps →
    ["", "## The session stopped", "", reason, ""]
      <> stepTable steps
      <> ["", "- verdict issues: " <> maybe "no verdict" (tshow . verdictIssues) verdict]
  NamingRecorded facts →
    let observed = factsObserved facts
     in [ ""
        , "## A named readback buffer overrun inside a labelled batch"
        , ""
        , "- device: " <> observedDevice observed
        , "- debug-utils naming offered: " <> tshow (observedInstrumented observed)
        , "- batch: " <> tshow (observedBatch observed)
        , "- the readback buffer: 0x" <> Text.pack (showHex (observedBuffer observed) "") <> ", named " <> decode (observedBufferName observed)
        , "- the batch's label: " <> decode (observedBatchLabel observed)
        , ""
        ]
          <> stepTable (factsSteps facts)
          <> [""]
          <> concat
            [ [ "- error " <> field "message.id" entry <> ", objects " <> tshow (objectsOf entry)
              , "  - queue labels reported: " <> orZero (field "queue.labels" entry) <> ", copied " <> tshow (labelsOf "queue" entry)
              , "  - command-buffer labels reported: " <> orZero (field "cmdbuf.labels" entry) <> ", copied " <> tshow (labelsOf "cmdbuf" entry)
              ]
            | entry ← errorEntries (factsEntries facts)
            ]
          <> [ "- records delivered: " <> tshow (verdictDelivered (factsVerdict facts))
             , "- undelivered: " <> tshow (verdictUndelivered (factsVerdict facts))
             , "- verdict issues: " <> tshow (verdictIssues (factsVerdict facts))
             ]
  where
    orZero value = if Text.null value then "0" else value
    stepTable steps =
      ["| step | reports | errors |", "| --- | --- | --- |"]
        <> ["| " <> step.stepName <> " | " <> tshow step.stepReports <> " | " <> tshow step.stepErrors <> " |" | step ← steps]

-- ---------------------------------------------------------------------------
-- The verdict

spec ∷ NamingOutcome → Spec
spec outcome = describe "#250 names and labels" $ do
  it "established every step of its private roots, its generation and its managed resources, on a device that offers naming" $
    onFacts outcome $ \facts → observedInstrumented (factsObserved facts) `shouldBe` True

  it "recorded the batch inside its labels, and the report left it sealed and discardable" $
    onFacts outcome $ \facts → do
      let batch = observedBatch (factsObserved facts)
      fmap viewBatchStanding batch `shouldBe` Just BatchSealed
      fmap viewBatchCommands batch `shouldBe` Just 15

  it "received the provoked report while the overrunning copy was recorded, and no error from any other step" $
    onFacts outcome $ \facts → do
      let during = find ((== provokedStep) . (.stepName)) (factsSteps facts)
      fmap (.stepErrors) during `shouldSatisfy` maybe False (> 0)
      [step.stepName | step ← factsSteps facts, step.stepErrors > 0, step.stepName /= provokedStep] `shouldBe` []
      map (field "message.id") (errorEntries (factsEntries facts)) `shouldSatisfy` (not . null)
      for_ (errorEntries (factsEntries facts)) $ \entry → field "message.id" entry `shouldBe` expectedMessageId

  it "carried the readback buffer, with the name the backend gave it, among the report's objects" $
    onFacts outcome $ \facts → do
      let observed = factsObserved facts
          buffer = tshow (objectTypeCode ObjectBuffer) <> ":0x" <> Text.pack (showHex (observedBuffer observed) "")
      for_ (errorEntries (factsEntries facts)) $ \entry →
        objectsOf entry `shouldSatisfy` elem (buffer, Just (decode (observedBufferName observed)))

  it "carried the batch's label as the report's innermost command-buffer label, wherever the layer reports one" $
    onFacts outcome $ \facts →
      for_ (errorEntries (factsEntries facts)) $ \entry → case labelsOf "cmdbuf" entry of
        [] → pure ()
        labels → last labels `shouldBe` decode (observedBatchLabel (factsObserved facts))

  it "lost nothing, and failed its verdict after the last teardown callback for the latched error alone" $
    onFacts outcome $ \facts → do
      let verdict = factsVerdict facts
          counters = verdict.verdictStatus.statusCounters
      counters.countAdmitted `shouldBe` counters.countOffered
      verdict.verdictDelivered `shouldBe` counters.countAdmitted
      verdict.verdictUndelivered `shouldBe` 0
      verdict.verdictQuiescent `shouldBe` True
      completed verdict.verdictConsumer `shouldBe` True
      verdictIssues verdict `shouldBe` [ErrorLatched]
  where
    completed = \case
      ConsumerCompleted → True
      _ → False

onFacts ∷ NamingOutcome → (NamingFacts → Expectation) → Expectation
onFacts outcome assertion = case outcome of
  NamingStopped reason _ _ → expectationFailure ("the naming session stopped: " <> Text.unpack reason)
  NamingRecorded facts → assertion facts

-- ---------------------------------------------------------------------------
-- Reading the delivered records

errorEntries ∷ [LogEntry] → [LogEntry]
errorEntries = filter ((== Just "error") . Map.lookup "severity" . (.entryFields))

field ∷ Text → LogEntry → Text
field key entry = Map.findWithDefault "" key entry.entryFields

-- | A record's copied objects, in order: each one's @type:0xhandle@ and name.
objectsOf ∷ LogEntry → [(Text, Maybe Text)]
objectsOf entry =
  mapMaybe
    (\index → (\object → (object, Map.lookup (key index <> ".name") entry.entryFields)) <$> Map.lookup (key index) entry.entryFields)
    [1 .. 64 ∷ Int]
  where
    key index = "object." <> tshow index

-- | A record's copied labels of one kind, @queue@ or @cmdbuf@, in the
-- callback's order.
labelsOf ∷ Text → LogEntry → [Text]
labelsOf kind entry = mapMaybe (\index → Map.lookup (kind <> ".label." <> tshow index) entry.entryFields) [1 .. 64 ∷ Int]

decode ∷ ByteString → Text
decode = Encoding.decodeUtf8Lenient

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
