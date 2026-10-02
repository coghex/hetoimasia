{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | GRS-3's native case: managed resources ordered by checked transitions and
-- mechanical boundary barriers, under synchronization validation, on private
-- roots.
--
-- The roots, the generation, the recording and the frames are VK-12's case's:
-- the production native layers with the validation layer and synchronization
-- validation. Over them, one depth target and one vertex buffer, both managed
-- (GRS-2), are written by three frame batches:
--
-- 1. the first initializes them — the depth target by a transition from
--    undefined, the buffer by a transition into the copy's use and back — and
--    is submitted and awaited, and its frame closed and settled;
-- 2. the second and the third each touch the same depth target and the same
--    buffer with no layout change, writing both, and are submitted one after
--    the other with no completion wait between: only the entry and exit
--    barriers the recorder records, chained on the one graphics queue, order
--    the third batch's writes after the second's.
--
-- The writes are the issue's narrowly scoped test-only accesses (#335): a
-- depth-only dynamic rendering pass that clears and stores the depth target,
-- and a @vkCmdFillBuffer@ of the buffer, each recorded straight into the
-- batch's command buffer after the production transition that touches it. No production
-- attachment, binding or upload API is added for them: the command buffer is
-- the one this case's wrapper of the production recording layer saw begun.
-- Each later batch's first transition of a resource is its entry barrier, so
-- between the second batch's writes and the third's stand only the second's
-- exit barriers and the third's entry barriers. Nothing is presented.
--
-- What the clean verdict can show was measured once, by hand, on the pinned
-- layer (1.3.296), whose submit-time synchronization validation is on by
-- default: with every barrier of the two later batches dropped, it reports
-- the buffer's write-after-write at the third batch's submission, so the
-- buffer's ordering is genuinely checked across submissions; it reports
-- nothing for the depth target's load-op clear across submissions even then,
-- so for the depth target the case shows the barriers recorded and their
-- layouts accepted, not a hazard the layer could have seen.
module Test.GPU.Vulkan.Native.Ordering
  ( OrderingOutcome (..)
  , runOrdering
  , orderingSection
  , spec
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception (SomeException, displayException, finally, throwIO, try, tryWithContext)
import Control.Monad (unless, when)
import qualified Data.ByteString.Char8 as Char8
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import Data.Word (Word32, Word64)
import Foreign.Ptr (nullPtr)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Vulkan.CStruct.Extends (SomeStruct (..))
import Vulkan.Core10 (CommandBuffer, Device, Instance, PhysicalDevice)
import qualified Vulkan.Core10 as Core10
import Vulkan.Core12 (ResolveModeFlagBits (RESOLVE_MODE_NONE))
import Vulkan.Core13 (RenderingAttachmentInfo (..), RenderingInfo (..), cmdBeginRendering, cmdEndRendering)
import Vulkan.Dynamic (getInstanceProcAddr')
import Vulkan.Extensions.VK_EXT_debug_utils (DebugUtilsMessengerEXT)
import Vulkan.Extensions.VK_KHR_surface (SurfaceKHR (..), destroySurfaceKHR)
import Vulkan.Zero (zero)

import Hetoimasia.Foundation.Log
  ( DebugSelection (DebugAll)
  , LogEntry (..)
  , LogFilter (..)
  , LogLevel (Info)
  , callbackSink
  , mkLogger
  )
import Hetoimasia.Foundation.Time (DurationRequirement (AllowZero), Instant, durationFromNanoseconds, scriptedInstant, scriptedSource, zeroDuration)
import Hetoimasia.GPU.Model (Initialization (..), resourceInitialization)
import Hetoimasia.GPU.Model.Budget (BudgetRequest (..), defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (BatchId, SubmissionId, TargetClass (..), TargetId)
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
  , newGenerations
  , readTargetGenerations
  , retireTargetGenerations
  , stepGenerations
  , trackTarget
  )
import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceExtent (..), TargetGeometry (..))
import Hetoimasia.GPU.Vulkan.Native.Profile (DevicePlan (..), InstanceRequest (..))
import Hetoimasia.GPU.Vulkan.Native.Recording
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
  )
import Hetoimasia.GPU.Vulkan.Native.Roots.Vulkan (instancePointer, vulkanRootOps)
import Hetoimasia.GLFW.Session (Backend)
import Test.GPU.Vulkan.Native.Environment (validationFeatures)
import Test.GPU.Vulkan.Native.Platform (initRequested)
import Test.Vulkan.Proof.Interop
  ( createProofWindow
  , createWindowSurface
  , destroyProofWindow
  , glfwTerminate
  , initVulkanLoader
  , lastGlfwError
  , requiredInstanceExtensions
  )
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

data Observed = Observed
  { observedDevice ∷ !Text
  , observedInitialized ∷ !(Maybe Initialization, Maybe Initialization)
    -- ^ The depth target's initialization before its initializing batch was
    -- submitted, and after.
  , observedBatches ∷ ![(BatchId, SubmissionId)]
    -- ^ The three batches, in submission order, with their submissions.
  , observedBarriers ∷ ![[Text]]
    -- ^ Each batch's barriers, in recording order.
  , observedOutstandingBetween ∷ ![SubmissionId]
    -- ^ What was still outstanding when the third batch was submitted.
  , observedLeft ∷ !([FrameStanding], [SubmissionId])
  }
  deriving (Show)

data OrderingFacts = OrderingFacts
  { factsObserved ∷ !Observed
  , factsSteps ∷ ![Step]
  , factsEntries ∷ ![LogEntry]
  , factsVerdict ∷ !DiagnosticVerdict
  }
  deriving (Show)

data OrderingOutcome
  = OrderingRecorded OrderingFacts
  | OrderingStopped Text (Maybe DiagnosticVerdict) [Step]
  deriving (Show)

orderingCaptureConfig ∷ CaptureConfig
orderingCaptureConfig = defaultCaptureConfig {captureTextBudget = 16384}

-- | The depth target's side, in texels.
side ∷ Word32
side = 64

-- | How many progress steps, a millisecond apart, the case waits for any one
-- piece of evidence before it stops.
patience ∷ Int
patience = 5000

stopWith ∷ Text → IO a
stopWith reason = throwIO (userError (Text.unpack reason))

-- | Run the case on the calling thread, which must be the process main
-- thread: GLFW's window and surface are made there, and so is everything
-- else, since this private process has no other owner.
runOrdering ∷ Maybe Backend → Journal → IO OrderingOutcome
runOrdering backend journal = do
  heading journal "GRS-3: managed resources ordered by checked transitions and boundary barriers"
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
          <$> try @SomeException (withDiagnosticCapture orderingCaptureConfig logger (session journal steps))
          `finally` glfwTerminate
  entries ← reverse <$> readTVarIO logged
  seen ← reverse <$> readIORef steps
  case outcome of
    Left (failure, verdict) → do
      note journal ("the ordering session stopped: " <> Text.pack failure)
      pure (OrderingStopped (Text.pack failure) verdict seen)
    Right (observed, verdict) → do
      note journal ("the lifetime delivered " <> tshow (verdictDelivered verdict) <> " records")
      pure (OrderingRecorded (OrderingFacts observed seen entries verdict))

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
  -- Each memory usage opens a block of its own, as VK-11's case explains, so
  -- the byte budget is VK-11's 2 GiB rather than the default 256 MiB.
  budgets ← either (stopWith . tshow) pure (validateBudgets defaultBudgetRequest {requestedBytes = 2 * 1024 * 1024 * 1024})
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
  window ← createProofWindow 160 120 "hetoimasia GRS-3 ordering" >>= maybe (lastGlfwError >>= stopWith . ("no window: " <>)) pure
  flip finally (destroyProofWindow window) $ do
    instanceHandle ← atomically (readRootsInstance roots) >>= maybe (stopWith "the roots hold no instance") pure
    (result, surface) ← createWindowSurface (instancePointer instanceHandle) window
    when (result /= 0) (stopWith ("glfwCreateWindowSurface answered " <> tshow result))
    let destroy = either SurfaceDestructionUncertain (const SurfaceDestroyed) <$> tryWithContext (destroySurfaceKHR instanceHandle (SurfaceKHR surface) Nothing)
    target ←
      step "the device and the target" (admitRootTarget roots RequiredTarget (TargetSurface surface destroy))
        >>= either (stopWith . ("the target was refused: " <>) . tshow) pure
    generations ← newGenerations roots
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
  note journal ("the generation has " <> tshow (length (viewImages generation)) <> " images")
  (devicePlan, _) ← atomically (readRootsDevice roots) >>= maybe (stopWith "the roots hold no device") pure
  production ← vulkanRecordingOps (planDevice devicePlan)
  -- The command buffer each batch records into, as the production layer is
  -- asked to begin it, and every barrier it is asked to record.
  current ← newIORef Nothing
  barriers ← newIORef []
  let ops =
        production
          { opsBeginCommands = \commands → writeIORef current (Just commands) >> opsBeginCommands production commands
          , opsRecord = \commands native → do
              case native of
                CommandResourceBarrier object from to → modifyIORef' barriers (describeBarrier object from to :)
                _ → pure ()
              opsRecord production commands native
          }
  recording ← newRecording ops roots generations
  frames ← newFrames vulkanFrameOps recording
  outcome ← try @SomeException (exercise journal step roots recording frames target current barriers)
  -- Whatever happened, what the frames still hold is retired, then the
  -- recording's resources; anything unsettled is retained, and says so.
  _ ← try @SomeException (step "retiring the frames" (retireTargetFrames frames target))
  _ ← try @SomeException (step "releasing and destroying the managed resources" (retireRecording recording (at 8)))
  case outcome of
    Left failure → do
      -- Retirement after a failure may fail too, and would then be what the
      -- session reports; the record keeps the cause.
      note journal ("the case failed: " <> Text.pack (displayException failure))
      throwIO failure
    Right (initialized, batches, recorded, between, left) →
      pure
        Observed
          { observedDevice = planDeviceName devicePlan
          , observedInitialized = initialized
          , observedBatches = batches
          , observedBarriers = recorded
          , observedOutstandingBetween = between
          , observedLeft = left
          }

exercise
  ∷ Journal
  → (∀ a. Text → IO a → IO a)
  → VulkanRoots
  → VulkanRecording
  → VulkanFrames
  → TargetId
  → IORef (Maybe CommandBuffer)
  → IORef [Text]
  → IO ((Maybe Initialization, Maybe Initialization), [(BatchId, SubmissionId)], [[Text]], [SubmissionId], ([FrameStanding], [SubmissionId]))
exercise journal step roots recording frames target current barriers = do
  let made ∷ Show refusal ⇒ Text → IO (Either refusal a) → IO a
      made name action = step name action >>= either (stopWith . ((name <> " was refused: ") <>) . tshow) pure
      command name action = action >>= either (stopWith . ((name <> " was refused: ") <>) . tshow) pure
      initialization resource = resourceInitialization resource <$> atomically (readRootsModel roots)
  _ ← made "vkCreateCommandPool, slot 0" (createFrameStorage recording target 0)
  _ ← made "vkCreateCommandPool, slot 1" (createFrameStorage recording target 1)
  depth ← made "the depth target" (createImage recording (ImageDescription DepthTarget Depth32Float side side 1))
  vertices ← made "the vertex buffer" (createBuffer recording (BufferDescription VertexBuffer 256))
  views ← atomically (readManaged recording)
  depthView ← case [viewNativeHandles view | view ← views, viewResource view == managedResource depth] of
    [_ : imageView : _] → pure imageView
    other → stopWith ("the depth target's handles are " <> tshow other)
  buffer ← case [viewNativeHandles view | view ← views, viewResource view == managedResource vertices] of
    [handle : _] → pure handle
    other → stopWith ("the buffer's handles are " <> tshow other)
  let commandBuffer = readIORef current >>= maybe (stopWith "no command buffer was begun") pure
      -- The test-only accesses: a depth-only pass that clears and stores the
      -- depth target, and a fill of the buffer.
      depthPass value = do
        commands ← commandBuffer
        cmdBeginRendering
          commands
          ( RenderingInfo
              { next = ()
              , flags = zero
              , renderArea = Core10.Rect2D {offset = Core10.Offset2D 0 0, extent = Core10.Extent2D side side}
              , layerCount = 1
              , viewMask = 0
              , colorAttachments = Vector.empty
              , depthAttachment =
                  Just . SomeStruct $
                    RenderingAttachmentInfo
                      { next = ()
                      , imageView = Core10.ImageView depthView
                      , imageLayout = Core10.IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL
                      , resolveMode = RESOLVE_MODE_NONE
                      , resolveImageView = Core10.NULL_HANDLE
                      , resolveImageLayout = Core10.IMAGE_LAYOUT_UNDEFINED
                      , loadOp = Core10.ATTACHMENT_LOAD_OP_CLEAR
                      , storeOp = Core10.ATTACHMENT_STORE_OP_STORE
                      , clearValue = Core10.DepthStencil (Core10.ClearDepthStencilValue value 0)
                      }
              , stencilAttachment = Nothing
              }
              ∷ RenderingInfo '[]
          )
        cmdEndRendering commands
      fill value = do
        commands ← commandBuffer
        Core10.cmdFillBuffer commands (Core10.Buffer buffer) 0 Core10.WHOLE_SIZE value
      -- One batch's writes: the depth target and the buffer, each between
      -- production transitions.
      writes depthFrom value recorder = do
        command "the depth target's transition" (transitionResource recorder depth depthFrom DepthAttachment)
        depthPass (fromIntegral value / 4)
        command "the buffer's transition into the copy" (transitionResource recorder vertices (FromUse GeometryRead) TransferWrite)
        fill value
        command "the buffer's transition back to rest" (transitionResource recorder vertices (FromUse TransferWrite) GeometryRead)
      record name depthFrom value frame = do
        writeIORef barriers []
        (batch, ()) ← made name (recordFrame recording (ownedFrame frame) (writes depthFrom value))
        written ← reverse <$> readIORef barriers
        pure (batch, written)
      submit name batch =
        step name (submitFrames frames (batch :| [])) >>= \case
          Right (SubmittedAs submission) → pure submission
          other → stopWith (name <> " answered " <> tshow other)
      settle frame = do
        made "closing the frame" (closeUnpresentedFrame frames (ownedFrame frame))
        _ ← step "settling the frame" (stepUntil frames (\report → ownedFrame frame `elem` progressSettled report))
        pure ()

  -- 1. Initialize both, submit, await, and settle the frame.
  first ← step "acquiring the initializing frame" (acquireFrame frames target)
  (initializing, initialBarriers) ← record "recording the initializing batch" FromUndefined 1 first
  before ← initialization (managedResource depth)
  initialSubmission ← submit "vkQueueSubmit2, the initializing batch" initializing
  after ← initialization (managedResource depth)
  _ ← step "awaiting the initializing batch" (stepUntil frames (\report → initialSubmission `elem` progressCompleted report))
  settle first

  -- 2. Two batches touching the same depth target and buffer with no layout
  -- change, submitted in order with no completion wait between.
  second ← step "acquiring the second frame" (acquireFrame frames target)
  third ← step "acquiring the third frame" (acquireFrame frames target)
  (secondBatch, secondBarriers) ← record "recording the second batch" (FromUse DepthAttachment) 2 second
  secondSubmission ← submit "vkQueueSubmit2, the second batch" secondBatch
  (thirdBatch, thirdBarriers) ← record "recording the third batch" (FromUse DepthAttachment) 3 third
  between ← atomically (readOutstandingSubmissions frames)
  thirdSubmission ← submit "vkQueueSubmit2, the third batch" thirdBatch
  note journal ("submitted " <> tshow secondBatch <> " and " <> tshow thirdBatch <> " with " <> tshow between <> " outstanding between them")
  step "awaiting both" (waitAll frames [secondSubmission, thirdSubmission])
  settle second
  settle third
  left ← atomically ((,) <$> readFrameStandings frames <*> readOutstandingSubmissions frames)
  pure
    ( (before, after)
    , [(initializing, initialSubmission), (secondBatch, secondSubmission), (thirdBatch, thirdSubmission)]
    , [initialBarriers, secondBarriers, thirdBarriers]
    , between
    , left
    )

-- | Step until none of these submissions is outstanding.
waitAll ∷ VulkanFrames → [SubmissionId] → IO ()
waitAll frames submissions = go (1 ∷ Int)
  where
    go count = do
      _ ← progressFrames frames (at 1)
      outstanding ← atomically (readOutstandingSubmissions frames)
      unless (all (`notElem` outstanding) submissions) $
        if count >= patience
          then stopWith ("the submissions were still outstanding after " <> tshow count <> " steps")
          else threadDelay 1000 >> go (count + 1)

-- | Acquire a frame, stepping between answers that are only pending.
acquireFrame ∷ VulkanFrames → TargetId → IO OwnedFrame
acquireFrame frames target = go (1 ∷ Int)
  where
    go attempt =
      tryAcquireFrame frames target >>= \case
        Right (AcquisitionOwned frame) → pure frame
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

-- | A barrier as the record shows it: what it covers, and the stages it waits
-- for and makes ready.
describeBarrier ∷ BarrierObject → AccessScope → AccessScope → Text
describeBarrier object from to =
  subject <> " " <> hex (scopeStages from) <> "/" <> hex (scopeAccess from) <> " -> " <> hex (scopeStages to) <> "/" <> hex (scopeAccess to)
  where
    subject = case object of
      BarrierBuffer _ → "buffer"
      BarrierImage _ _ _ old new → "image " <> tshow old <> "->" <> tshow new
    hex value = "0x" <> Text.pack (showHex' value)
    showHex' value
      | value < 16 = [digit value]
      | otherwise = showHex' (value `div` 16) <> [digit (value `mod` 16)]
    digit d = "0123456789abcdef" !! fromIntegral d

-- | The record's section.
orderingSection ∷ OrderingOutcome → [Text]
orderingSection = \case
  OrderingStopped reason verdict steps →
    ["", "## The session stopped", "", reason, ""]
      <> stepTable steps
      <> ["", "- verdict issues: " <> maybe "no verdict" (tshow . verdictIssues) verdict]
  OrderingRecorded facts →
    let observed = factsObserved facts
     in [ ""
        , "## Managed resources ordered by checked transitions and boundary barriers"
        , ""
        , "- device: " <> observedDevice observed
        , "- the depth target's initialization before and after its batch's submission: " <> tshow (observedInitialized observed)
        , "- batches and their submissions, in order: " <> tshow (observedBatches observed)
        , "- outstanding when the third batch was submitted: " <> tshow (observedOutstandingBetween observed)
        , "- left before retirement: " <> tshow (observedLeft observed)
        , ""
        , "Barriers each batch recorded, in order:"
        , ""
        ]
          <> concat
            [ ("- batch " <> tshow index <> ":") : ["  1. " <> barrier | barrier ← recorded]
            | (index, recorded) ← zip [1 ∷ Int ..] (observedBarriers observed)
            ]
          <> [""]
          <> stepTable (factsSteps facts)
          <> [ ""
             , "- error reports: " <> joined [Map.findWithDefault "" "message.id" entry.entryFields <> ": " <> Text.take 600 (Map.findWithDefault entry.entryMessage "text" entry.entryFields) | entry ← factsEntries facts, Map.lookup "severity" entry.entryFields == Just "error"]
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

spec ∷ OrderingOutcome → Spec
spec outcome = describe "GRS-3 ordering" $ do
  it "established every step of its private roots, its generation, its resources and its frames" $
    onFacts outcome $ \_ → pure ()

  it "published the depth target's initialization only on its batch's submission" $
    onFacts outcome $ \facts → case observedBatches (factsObserved facts) of
      (initializing, _) : _ → observedInitialized (factsObserved facts) `shouldBe` (Just (InitializingIn initializing), Just Initialized)
      [] → expectationFailure "no batch was recorded"

  it "recorded entry barriers at each batch's first touch, its transitions, and exit barriers back to rest, the later batches with no layout change" $
    onFacts outcome $ \facts → do
      let depth = "0x300/0x600"
          buffer = "0x4/0x4"
          copy = "0x1000/0x1000"
          later =
            [ "image 1000241000->1000241000 " <> depth <> " -> " <> depth
            , "buffer " <> buffer <> " -> " <> copy
            , "buffer " <> copy <> " -> " <> buffer
            , "image 1000241000->1000241000 " <> depth <> " -> " <> depth
            , "buffer " <> buffer <> " -> " <> buffer
            ]
      observedBarriers (factsObserved facts)
        `shouldBe` [ [ "image 0->1000241000 " <> depth <> " -> " <> depth
                     , "buffer " <> buffer <> " -> " <> copy
                     , "buffer " <> copy <> " -> " <> buffer
                     , "image 1000241000->1000241000 " <> depth <> " -> " <> depth
                     , "buffer " <> buffer <> " -> " <> buffer
                     ]
                   , later
                   , later
                   ]

  it "submitted the third batch while the second was still outstanding" $
    onFacts outcome $ \facts → case observedBatches (factsObserved facts) of
      [_, (_, second), _] → observedOutstandingBetween (factsObserved facts) `shouldSatisfy` (second `elem`)
      other → expectationFailure ("the batches were " <> show other)

  it "held nothing unsettled before its retirement" $
    onFacts outcome $ \facts → observedLeft (factsObserved facts) `shouldBe` ([], [])

  it "received no validation error, synchronization hazards included, during any step" $
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

onFacts ∷ OrderingOutcome → (OrderingFacts → Expectation) → Expectation
onFacts outcome assertion = case outcome of
  OrderingStopped reason _ _ → expectationFailure ("the ordering session stopped: " <> Text.unpack reason)
  OrderingRecorded facts → assertion facts

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
