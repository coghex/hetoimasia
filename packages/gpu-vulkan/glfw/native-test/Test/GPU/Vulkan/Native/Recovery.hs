{-# LANGUAGE OverloadedRecordDot #-}

-- | VK-14's native case: a target's surface and swapchain replaced on its
-- same live window after an injected loss while a second target keeps
-- presenting, and an injected allocation failure with no effect recovered by
-- reclaiming a retired generation — on private roots, with validation
-- reporting nothing.
--
-- The roots, the windows and the resources are VK-13's case's: the production
-- native layers, the validation layer with synchronization validation, two
-- windows each with a surface and a swapchain generation, VK-11's pipeline and
-- frame storages, and the production frames layer. Two narrow injections, and
-- nothing else, stand in for what a native run cannot be asked to do on
-- demand:
--
-- * the first window's next acquisition answers @VK_ERROR_SURFACE_LOST_KHR@
--   without the call being made — the answer of an acquisition that had no
--   effect, and nothing more;
-- * one readback buffer's creation raises @VK_ERROR_OUT_OF_DEVICE_MEMORY@
--   without the call being made — a creation that raised, having created
--   nothing.
--
-- Everything that follows is the backend's own, on real objects:
--
-- 1. three triangle frames are presented to each window, and drained until
--    every present fence has been observed;
-- 2. the first window's loss is injected at its acquisition, which gives its
--    reservation back. While the second window presents a frame on every
--    step, the generations retire the first's generation and destroy it, then
--    its lost surface — the window, its GLFW handle and the target's identity
--    unchanged — and the target's episode admits an attempt. A replacement
--    surface is created on that same window, offered, checked against the one
--    device and installed, and a fresh generation — handed nothing — is
--    built on it. The first window presents three frames again;
-- 3. the second window is resized, and its replacement generation published;
--    once the old generation's last presentation has retired it is eligible
--    for disposal and nothing else destroys it. The readback's creation then
--    runs out of memory: one reclamation pass destroys that generation, and
--    the creation is made once more and succeeds;
-- 4. everything is drained and retired, and the device and the instance
--    destroyed.
--
-- The only waits are 'awaitFrames'' finite drain waits and a millisecond
-- between the generation steps a resize needs, each bounded by a patience
-- after which the case stops.
module Test.GPU.Vulkan.Native.Recovery
  ( RecoveryOutcome (..)
  , runRecovery
  , recoverySection
  , spec
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception (SomeException, displayException, finally, onException, throwIO, try, tryWithContext)
import Control.Monad (forM, forM_, replicateM, unless, when)
import qualified Data.ByteString.Char8 as Char8
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find, isSubsequenceOf)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import Foreign.Ptr (Ptr, nullPtr)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Vulkan.Core10 (CommandBuffer, Device, Instance, PhysicalDevice)
import Vulkan.Core10.Enums.Result (Result (ERROR_OUT_OF_DEVICE_MEMORY))
import Vulkan.Dynamic (getInstanceProcAddr')
import Vulkan.Exception (VulkanException (..))
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
import Hetoimasia.GPU.Model (PresentOutcome (..), TargetView (..), disposalEligible, targetView)
import Hetoimasia.GPU.Model.Budget (defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (GenerationId, HoldSubject (..), SubmissionId, TargetClass (..), TargetId, generationTarget, imageGeneration)
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
  , ReplacementAnswer (..)
  , StepSummary (..)
  , TargetCondition (..)
  , TargetGenerationsView (..)
  , newGenerations
  , offerReplacementSurface
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
  ( GenerationOps (..)
  , RootOps (..)
  , Roots
  , SurfaceDestruction (..)
  , SwapchainRequest (..)
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
import Test.GPU.Vulkan.Native.Environment (validationFeatures)
import Test.Vulkan.Proof.Interop
  ( ProofWindow
  , createProofWindow
  , createWindowSurface
  , destroyProofWindow
  , framebufferSize
  , glfwTerminate
  , initVulkanLoader
  , lastGlfwError
  , pollEvents
  , requiredInstanceExtensions
  , setWindowSize
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

-- | What replacing the first window's surface showed.
data Replaced = Replaced
  { replacedLossAnswer ∷ !Text
    -- ^ What the injected acquisition answered.
  , replacedOldSurface ∷ !Word64
  , replacedNewSurface ∷ !Word64
  , replacedOldGeneration ∷ !GenerationId
  , replacedNewGeneration ∷ !GenerationId
  , replacedOffer ∷ !Text
    -- ^ What offering the replacement answered.
  , replacedCalls ∷ ![Text]
    -- ^ The roots' native calls from the injection to the new generation.
  , replacedSecondDuring ∷ !Int
    -- ^ Frames the second window presented while the first recovered.
  , replacedFirstAfter ∷ !Int
    -- ^ Frames the first window presented on its new generation.
  , replacedAttempts ∷ !(Maybe Natural)
    -- ^ The recovery attempts the target's episode spent.
  , replacedTarget ∷ !(TargetId, TargetId)
    -- ^ The first window's target before and after.
  }
  deriving (Show)

-- | What recovering the readback's allocation showed.
data Reclaimed = Reclaimed
  { reclaimedGeneration ∷ !GenerationId
    -- ^ The second window's retired generation.
  , reclaimedEligible ∷ !Bool
    -- ^ Whether the model held it eligible for disposal before the failure.
  , reclaimedCalls ∷ ![Text]
    -- ^ The roots' and the recording's native calls during the creation.
  , reclaimedGone ∷ !Bool
    -- ^ Whether the generation was gone once the creation returned.
  , reclaimedAnswer ∷ !Text
  }
  deriving (Show)

data Observed = Observed
  { observedDevice ∷ !Text
  , observedPresented ∷ !Int
  , observedReplaced ∷ !Replaced
  , observedReclaimed ∷ !Reclaimed
  , observedLeft ∷ !([FrameStanding], [PresentationStanding], [SubmissionId])
  }
  deriving (Show)

data RecoveryFacts = RecoveryFacts
  { factsObserved ∷ !Observed
  , factsSteps ∷ ![Step]
  , factsEntries ∷ ![LogEntry]
  , factsVerdict ∷ !DiagnosticVerdict
  }
  deriving (Show)

data RecoveryOutcome
  = RecoveryRecorded RecoveryFacts
  | RecoveryStopped Text (Maybe DiagnosticVerdict) [Step] [LogEntry]
  deriving (Show)

recoveryCaptureConfig ∷ CaptureConfig
recoveryCaptureConfig = defaultCaptureConfig {captureTextBudget = 16384}

-- | How many drain steps, each waiting at most 10 ms, the case waits for any
-- one piece of evidence before it stops.
patience ∷ Int
patience = 500

stopWith ∷ Text → IO a
stopWith reason = throwIO (userError (Text.unpack reason))

-- | Run the case on the calling thread, which must be the process main
-- thread: GLFW's windows and surfaces are made there, and so is everything
-- else, since this private process has no other owner.
runRecovery ∷ Maybe Backend → Journal → IO RecoveryOutcome
runRecovery backend journal = do
  heading journal "VK-14: a lost surface replaced on its live window, and an allocation recovered by reclamation"
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
          <$> try @SomeException (withDiagnosticCapture recoveryCaptureConfig logger (session journal steps))
          `finally` glfwTerminate
  entries ← reverse <$> readTVarIO logged
  seen ← reverse <$> readIORef steps
  case outcome of
    Left (failure, verdict) → do
      note journal ("the recovery session stopped: " <> Text.pack failure)
      pure (RecoveryStopped (Text.pack failure) verdict seen entries)
    Right (observed, verdict) → do
      note journal ("the lifetime delivered " <> tshow (verdictDelivered verdict) <> " records")
      pure (RecoveryRecorded (RecoveryFacts observed seen entries verdict))

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

-- | The injections, each armed for one call and disarmed by it.
data Injections = Injections
  { injectLoss ∷ !(IORef (Maybe Word64))
    -- ^ The swapchain whose next acquisition answers the surface lost.
  , injectOutOfMemory ∷ !(IORef Bool)
    -- ^ Whether the next readback creation runs out of memory.
  , rootCalls ∷ !(IORef [Text])
    -- ^ The roots' and the recording's native calls, newest first.
  }

session ∷ Journal → IORef [Step] → DiagnosticCapture → IO (Observed, Quiesced)
session journal steps capture = do
  let step ∷ Text → IO a → IO a
      step = measure capture steps
  required ← requiredInstanceExtensions >>= maybe (stopWith "GLFW requires no surface extensions, so no surface can be made") pure
  budgets ← either (stopWith . tshow) pure (validateBudgets defaultBudgetRequest)
  injections ← Injections <$> newIORef Nothing <*> newIORef False <*> newIORef []
  roots ← newRoots (journaled injections (vulkanRootOps capture)) budgets (scriptedSource (pure (scriptedInstant zeroDuration)))
  _ ← step "the instance and its messenger" (startRoots roots (InstanceRequest required ["VK_LAYER_KHRONOS_validation"] validationFeatures))
  proved ← newIORef Nothing
  let finish = do
        _ ← try @SomeException (step "the device" (retireRoots roots))
        step "the messenger and the instance" (destroyRoots roots) >>= writeIORef proved
  observed ← withWindows journal step injections roots `finally` finish
  readIORef proved >>= \case
    Just quiesced → pure (observed, quiesced)
    Nothing → stopWith "the instance's destruction proved nothing"

-- | The roots' native layer, noting each generation and support call.
journaled ∷ Injections → RootOps q inst msgr phys dev → RootOps q inst msgr phys dev
journaled injections ops =
  ops
    { opsSurfaceSupport = \created physical family surface → noted ("vkGetPhysicalDeviceSurfaceSupportKHR " <> hex surface) (opsSurfaceSupport ops created physical family surface)
    , opsGenerations =
        generations
          { opsCreateSwapchain = \device request →
              noted
                ("vkCreateSwapchainKHR on " <> hex (requestSurface request) <> maybe ", handing nothing over" ((", handing over " <>) . hex) (requestOldSwapchain request))
                (opsCreateSwapchain generations device request)
          , opsDestroyImageView = \device view → noted "vkDestroyImageView" (opsDestroyImageView generations device view)
          , opsDestroySwapchain = \device swapchain → noted ("vkDestroySwapchainKHR " <> hex swapchain) (opsDestroySwapchain generations device swapchain)
          }
    }
  where
    generations = opsGenerations ops
    noted ∷ Text → IO a → IO a
    noted name action = modifyIORef' (rootCalls injections) (name :) >> action

-- | One window, its target, and its current surface.
data Window = Window
  { windowName ∷ !Text
  , windowHandle ∷ !(Ptr ProofWindow)
  , windowTarget ∷ !TargetId
  , windowSurface ∷ !Word64
  }

withWindows ∷ Journal → (∀ a. Text → IO a → IO a) → Injections → VulkanRoots → IO Observed
withWindows journal step injections roots = do
  instanceHandle ← atomically (readRootsInstance roots) >>= maybe (stopWith "the roots hold no instance") pure
  generations ← newGenerations roots
  let surfaceOn window = do
        (result, surface) ← createWindowSurface (instancePointer instanceHandle) window
        when (result /= 0) (stopWith ("glfwCreateWindowSurface answered " <> tshow result))
        let destroy = do
              modifyIORef' (rootCalls injections) (("vkDestroySurfaceKHR " <> hex surface) :)
              either SurfaceDestructionUncertain (const SurfaceDestroyed) <$> tryWithContext (destroySurfaceKHR instanceHandle (SurfaceKHR surface) Nothing)
        pure (TargetSurface surface destroy)
      open name = do
        window ← createProofWindow 160 120 ("hetoimasia VK-14 " <> Text.unpack name) >>= maybe (lastGlfwError >>= stopWith . ("no window: " <>)) pure
        surface ← surfaceOn window
        target ←
          step ("the target of the " <> name <> " window") (admitRootTarget roots RequiredTarget surface)
            >>= either (stopWith . ("the target was refused: " <>) . tshow) pure
        atomically (trackTarget generations target RequiredTarget (targetSurfaceHandle surface))
        pure (Window name window target (targetSurfaceHandle surface))
  destroyed ← newIORef []
  let retireWindow window = do
        gone ← (windowName window `elem`) <$> readIORef destroyed
        unless gone $ do
          _ ← try @SomeException (step ("the generations of the " <> windowName window <> " window") (retireTargetGenerations generations (at 100000) (windowTarget window)))
          _ ← try @SomeException (step ("the surface of the " <> windowName window <> " window") (retireRootTarget roots (windowTarget window)))
          destroyProofWindow (windowHandle window)
          modifyIORef' destroyed (windowName window :)
  first ← open "first"
  second ← open "second" `onException` retireWindow first
  withFrames journal step injections roots generations first second (surfaceOn (windowHandle first))
    `finally` (retireWindow first >> retireWindow second)

withFrames
  ∷ Journal
  → (∀ a. Text → IO a → IO a)
  → Injections
  → VulkanRoots
  → VulkanGenerations
  → Window
  → Window
  → IO TargetSurface
  → IO Observed
withFrames journal step injections roots generations first second replacementSurface = do
  _ ← step "the swapchain generations" (stepGenerations generations (at 0) =<< geometriesOf [first, second])
  format ← do
    view ← atomically (readTargetGenerations generations (windowTarget first)) >>= maybe (stopWith "the target is not tracked") pure
    unless (viewCondition view == Presenting) (stopWith ("the first window's target is not presenting: " <> tshow (viewCondition view)))
    generation ← maybe (stopWith "the target has no active generation") pure (viewActive view >>= \active → find ((== active) . viewGeneration) (viewGenerations view))
    pure (surfaceFormat (planFormat (viewPlan generation)))
  (devicePlan, _) ← atomically (readRootsDevice roots) >>= maybe (stopWith "the roots hold no device") pure
  ops ← vulkanRecordingOps (planDevice devicePlan)
  recording ← newRecording (injectingOutOfMemory injections ops) roots generations
  frames ← newFrames (injectingLoss injections vulkanFrameOps) recording
  outcome ← try @SomeException (exercise journal step injections roots generations recording frames format first second replacementSurface)
  case outcome of
    Left _ → do
      let settle count = do
            _ ← try @SomeException (awaitFrames frames (at 80000) drainWaitLimit)
            left ← atomically ((,) <$> readPresentations frames <*> readOutstandingSubmissions frames)
            unless (null (fst left) && null (snd left) || count >= patience) (settle (count + (1 ∷ Int)))
      settle 0
    Right _ → pure ()
  _ ← try @SomeException (step "retiring the first window's frames" (retireTargetFrames frames (windowTarget first)))
  _ ← try @SomeException (step "retiring the second window's frames" (retireTargetFrames frames (windowTarget second)))
  _ ← try @SomeException (step "releasing and destroying the managed resources" (retireRecording recording (at 90000)))
  case outcome of
    Left failure → throwIO failure
    Right (presented, replaced, reclaimed, left) →
      pure
        Observed
          { observedDevice = planDeviceName devicePlan
          , observedPresented = presented
          , observedReplaced = replaced
          , observedReclaimed = reclaimed
          , observedLeft = left
          }

-- | The frames layer, answering the one armed acquisition surface lost
-- without making the call.
injectingLoss ∷ Injections → FrameOps dev cmd → FrameOps dev cmd
injectingLoss injections ops =
  ops
    { opsAcquireImage = \device swapchain semaphore → do
        armed ← atomicModifyIORef' (injectLoss injections) (\held → if held == Just swapchain then (Nothing, True) else (held, False))
        if armed then pure AcquiringSurfaceLost else opsAcquireImage ops device swapchain semaphore
    }

-- | The recording layer, raising out of memory at the one armed readback
-- creation without making the call.
injectingOutOfMemory ∷ Injections → RecordingOps dev cmd → RecordingOps dev cmd
injectingOutOfMemory injections ops =
  ops
    { opsCreateReadback = \device bytes → do
        armed ← atomicModifyIORef' (injectOutOfMemory injections) (\held → (False, held))
        modifyIORef' (rootCalls injections) ((if armed then "vkCreateBuffer: VK_ERROR_OUT_OF_DEVICE_MEMORY (injected)" else "vkCreateBuffer") :)
        if armed then throwIO (VulkanException ERROR_OUT_OF_DEVICE_MEMORY) else opsCreateReadback ops device bytes
    }

-- | Every live window's geometry: eligible, at its current framebuffer.
geometriesOf ∷ [Window] → IO (Map.Map TargetId TargetGeometry)
geometriesOf windows = do
  pollEvents
  fmap Map.fromList . forM windows $ \window → do
    (width, height) ← framebufferSize (windowHandle window)
    pure (windowTarget window, TargetGeometry (Right ()) (Just (SurfaceExtent (fromIntegral width) (fromIntegral height))) Nothing 1)

exercise
  ∷ Journal
  → (∀ a. Text → IO a → IO a)
  → Injections
  → VulkanRoots
  → VulkanGenerations
  → VulkanRecording
  → VulkanFrames
  → Word32
  → Window
  → Window
  → IO TargetSurface
  → IO (Int, Replaced, Reclaimed, ([FrameStanding], [PresentationStanding], [SubmissionId]))
exercise journal step injections roots generations recording frames format first second replacementSurface = do
  let made ∷ Show refusal ⇒ Text → IO (Either refusal a) → IO a
      made name action = step name action >>= either (stopWith . ((name <> " was refused: ") <>) . tshow) pure
      command name action = action >>= either (stopWith . ((name <> " was refused: ") <>) . tshow) pure
  clock ← newIORef (1000 ∷ Integer)
  retiredSoFar ← newIORef []
  wanted ← newIORef []
  let tick = atomicModifyIORef' clock (\now → (now + 17, now))
      -- One owner step: the frames, then the generations of both windows at
      -- their current framebuffers.
      drain = do
        now ← tick
        report ← awaitFrames frames (at now) drainWaitLimit
        modifyIORef' retiredSoFar (<> progressRetired report)
        summary ← stepGenerations generations (at now) =<< geometriesOf [first, second]
        modifyIORef' wanted (<> summarySurfacesWanted summary)
      -- Only the frames: evidence arrives, and no generation is destroyed.
      drainFrames = do
        now ← tick
        report ← awaitFrames frames (at now) drainWaitLimit
        modifyIORef' retiredSoFar (<> progressRetired report)
      until' ∷ Text → IO () → IO Bool → IO ()
      until' what each done = go (0 ∷ Int)
        where
          go count = do
            finished ← done
            unless finished $
              if count >= patience
                then stopWith (what <> " did not arrive in " <> tshow count <> " steps")
                else each >> go (count + 1)
      conditionOf window = fmap viewCondition <$> atomically (readTargetGenerations generations (windowTarget window))
      activeOf window =
        atomically (readTargetGenerations generations (windowTarget window)) >>= \case
          Just view | Just active ← viewActive view → pure active
          other → stopWith ("the " <> windowName window <> " window's target has no active generation: " <> tshow (fmap viewCondition other))
      swapchainOf generation =
        atomically (readTargetGenerations generations (generationTarget generation)) >>= \case
          Just view | Just native ← find ((== generation) . viewGeneration) (viewGenerations view), Just swapchain ← viewSwapchain native → pure swapchain
          _ → stopWith ("the generation has no swapchain: " <> tshow generation)
      exists generation =
        maybe False (any ((== generation) . viewGeneration) . viewGenerations)
          <$> atomically (readTargetGenerations generations (generationTarget generation))
      extentOf image = do
        view ← atomically (readTargetGenerations generations (generationTarget (imageGeneration image))) >>= maybe (stopWith "the target is not tracked") pure
        maybe (stopWith "the frame's generation is not tracked") (pure . planExtent . viewPlan) (find ((== imageGeneration image) . viewGeneration) (viewGenerations view))
  layout ← made "vkCreatePipelineLayout" (createPipelineLayout recording)
  pipeline ← made "vkCreateGraphicsPipelines" (createPipeline recording layout verificationShaders format)
  forM_ [first, second] $ \window → forM_ [0, 1] $ \slot →
    made ("vkCreateCommandPool, " <> windowName window <> " slot " <> tshow slot) (createFrameStorage recording (windowTarget window) slot)
  presentedCount ← newIORef (0 ∷ Int)
  let acquire window = go (1 ∷ Int)
        where
          go attempt =
            tryAcquireFrame frames (windowTarget window) >>= \case
              Right (AcquisitionOwned frame) → pure frame
              Right (AcquisitionPending _) | attempt < patience → drain >> go (attempt + 1)
              other → stopWith ("no frame of the " <> windowName window <> " window was acquired after " <> tshow attempt <> " attempts: " <> tshow other)
      present window = do
        frame ← acquire window
        extent ← extentOf (ownedImage frame)
        let width = extentWidth extent
            height = extentHeight extent
        (batch, ()) ←
          made ("recording a triangle for the " <> windowName window <> " window") $
            recordFrame recording (ownedFrame frame) $ \recorder → do
              command "the transition into rendering" (transitionImage recorder LayoutUndefined LayoutColorAttachment)
              command "vkCmdBeginRendering" (beginRendering recorder (ClearColor 0.1 0.1 0.1 1))
              command "vkCmdBindPipeline" (bindPipeline recorder pipeline)
              command "vkCmdSetViewport" (setViewport recorder (Viewport 0 0 (fromIntegral width) (fromIntegral height)))
              command "vkCmdSetScissor" (setScissor recorder (Rect 0 0 width height))
              command "vkCmdDraw" (draw recorder 3 1)
              command "vkCmdEndRendering" (endRendering recorder)
              command "the transition to presentation" (transitionImage recorder LayoutColorAttachment LayoutPresentSource)
        step ("vkQueueSubmit2, the " <> windowName window <> " window's triangle") (submitFrames frames (batch :| [])) >>= \case
          Right (SubmittedAs _) → pure ()
          other → stopWith ("the submission answered " <> tshow other)
        step ("vkQueuePresentKHR, the " <> windowName window <> " window") (presentFrame frames (ownedFrame frame)) >>= \case
          Right (PresentedAs presentation outcome)
            | outcome `elem` [PresentationEnqueued, PresentationEnqueuedSuboptimal] → do
                modifyIORef' presentedCount (+ 1)
                pure presentation
          other → stopWith ("the presentation answered " <> tshow other)
      presentAll window count = do
        presentations ← replicateM count (present window)
        step ("awaiting the " <> windowName window <> " window's present fences") $
          until' "the presentations' retirement" drain ((\seen → all (`elem` seen) presentations) <$> readIORef retiredSoFar)
      targetIdentity window = do
        model ← atomically (readRootsModel roots)
        pure (fmap (\view → (windowTarget window, viewTargetRecoveryAttempts view)) (targetView (windowTarget window) model))

  -- 1. Three frames to each window, every present fence observed.
  presentAll first 3
  presentAll second 3
  note journal "presented and retired three frames on each window"

  -- 2. The first window's surface is lost at its acquisition.
  oldGeneration ← activeOf first
  oldSwapchain ← swapchainOf oldGeneration
  writeIORef (injectLoss injections) (Just oldSwapchain)
  writeIORef (rootCalls injections) []
  lossAnswer ←
    step "the injected acquisition" (tryAcquireFrame frames (windowTarget first)) >>= \case
      Right answer → pure (tshow answer)
      Left refusal → stopWith ("the acquisition was refused: " <> tshow refusal)
  secondDuring ← newIORef (0 ∷ Int)
  step "retiring the lost surface's generation and the lost surface, while the second window presents" $
    until'
      "the replacement request"
      ( do
          _ ← present second
          modifyIORef' secondDuring (+ 1)
          drain
      )
      ((windowTarget first `elem`) <$> readIORef wanted)
  replacement ← step "the replacement surface, on the same window" replacementSurface
  offered ← step "offering the replacement" (offerReplacementSurface generations (at 50000) (windowTarget first) replacement)
  unless (offered == ReplacementInstalled) (stopWith ("the replacement was not installed: " <> tshow offered))
  step "the replacement's generation, while the second window presents" $
    until'
      "the replacement generation"
      ( do
          _ ← present second
          modifyIORef' secondDuring (+ 1)
          drain
      )
      ((== Just Presenting) <$> conditionOf first)
  newGeneration ← activeOf first
  calls ← reverse <$> readIORef (rootCalls injections)
  presentAll first 3
  identified ← targetIdentity first
  duringCount ← readIORef secondDuring
  let replaced =
        Replaced
          { replacedLossAnswer = lossAnswer
          , replacedOldSurface = windowSurface first
          , replacedNewSurface = targetSurfaceHandle replacement
          , replacedOldGeneration = oldGeneration
          , replacedNewGeneration = newGeneration
          , replacedOffer = tshow offered
          , replacedCalls = calls
          , replacedSecondDuring = duringCount
          , replacedFirstAfter = 3
          , replacedAttempts = snd <$> identified
          , replacedTarget = (windowTarget first, maybe (windowTarget first) fst identified)
          }
  note journal ("replaced the first window's surface " <> hex (windowSurface first) <> " with " <> hex (targetSurfaceHandle replacement) <> " while the second presented " <> tshow duringCount <> " frames")

  -- 3. The second window is resized; its old generation, once its
  -- presentations have retired, is eligible and nothing else destroys it.
  retired ← activeOf second
  setWindowSize (windowHandle second) 200 150
  step "replacing the resized window's generation" $
    until' "the resized window's replacement" (pollEvents >> threadDelay 1000 >> drain) ((/= retired) <$> activeOf second)
  step "awaiting the retired generation's presentations" $
    until' "the retired generation's eligibility" drainFrames (disposalEligible (GenerationSubject retired) <$> atomically (readRootsModel roots))
  eligible ← disposalEligible (GenerationSubject retired) <$> atomically (readRootsModel roots)
  writeIORef (rootCalls injections) []
  writeIORef (injectOutOfMemory injections) True
  readback ← step "the readback's creation, out of memory once" (createReadback recording 65536)
  answer ← either (stopWith . ("the readback's creation was refused: " <>) . tshow) (pure . const "a readback") readback
  reclaimCalls ← reverse <$> readIORef (rootCalls injections)
  gone ← not <$> exists retired
  either (const (pure ())) (\created → made "releasing the readback" (releaseManaged recording created)) readback
  let reclaimed = Reclaimed retired eligible reclaimCalls gone answer
  note journal ("recovered the readback's allocation: " <> Text.intercalate "; " reclaimCalls)

  -- 4. Drain until nothing is outstanding.
  let settle count = do
        drain
        left ← atomically ((,,) <$> readFrameStandings frames <*> readPresentations frames <*> readOutstandingSubmissions frames)
        case left of
          ([], [], []) → pure left
          _ | count >= patience → pure left
          _ → settle (count + (1 ∷ Int))
  left ← step "draining both windows" (settle 1)
  presented ← readIORef presentedCount
  pure (presented, replaced, reclaimed, left)

-- | The record's section.
recoverySection ∷ RecoveryOutcome → [Text]
recoverySection = \case
  RecoveryStopped reason verdict steps logged →
    ["", "## The session stopped", "", reason, ""]
      <> stepTable steps
      <> [ ""
         , "- error reports: " <> errorReports logged
         , "- verdict issues: " <> maybe "no verdict" (tshow . verdictIssues) verdict
         ]
  RecoveryRecorded facts →
    let observed = factsObserved facts
        replaced = observedReplaced observed
        reclaimed = observedReclaimed observed
     in [ ""
        , "## A lost surface replaced on its live window, and an allocation recovered"
        , ""
        , "- device: " <> observedDevice observed
        , "- frames presented in all: " <> tshow (observedPresented observed)
        , "- the injected acquisition answered " <> replacedLossAnswer replaced
        , "- the first window's surface " <> hex (replacedOldSurface replaced) <> " was replaced by " <> hex (replacedNewSurface replaced)
            <> " on the same window; its generation " <> tshow (replacedOldGeneration replaced) <> " by " <> tshow (replacedNewGeneration replaced)
        , "- the target before and after: " <> tshow (replacedTarget replaced) <> "; recovery attempts spent: " <> tshow (replacedAttempts replaced)
        , "- offering the replacement answered " <> replacedOffer replaced
        , "- the second window presented " <> tshow (replacedSecondDuring replaced) <> " frames while the first recovered"
        , "- the first window presented " <> tshow (replacedFirstAfter replaced) <> " frames on its new generation"
        , ""
        , "The roots' native calls from the injection to the replacement's generation:"
        , ""
        ]
          <> ["1. " <> call | call ← replacedCalls replaced]
          <> [ ""
             , "- the second window's retired generation " <> tshow (reclaimedGeneration reclaimed) <> " was eligible for disposal before the failure: " <> tshow (reclaimedEligible reclaimed)
             , "- it was gone once the creation returned: " <> tshow (reclaimedGone reclaimed) <> "; the creation answered " <> reclaimedAnswer reclaimed
             , ""
             , "The native calls during the readback's creation:"
             , ""
             ]
          <> ["1. " <> call | call ← reclaimedCalls reclaimed]
          <> [ ""
             , "- left before retirement: " <> tshow (observedLeft observed)
             , ""
             ]
          <> stepTable (factsSteps facts)
          <> [ ""
             , "- error reports: " <> errorReports (factsEntries facts)
             , "- records delivered: " <> tshow (verdictDelivered (factsVerdict facts))
             , "- undelivered: " <> tshow (verdictUndelivered (factsVerdict facts))
             , "- verdict issues: " <> tshow (verdictIssues (factsVerdict facts))
             ]
  where
    errorReports logged = case [Map.findWithDefault "" "message.id" entry.entryFields <> ": " <> Text.take 600 entry.entryMessage | entry ← logged, Map.lookup "severity" entry.entryFields == Just "error"] of
      [] → "none"
      reports → Text.intercalate "; " reports
    stepTable steps =
      ["| step | reports | errors |", "| --- | --- | --- |"]
        <> ["| " <> step.stepName <> " | " <> tshow step.stepReports <> " | " <> tshow step.stepErrors <> " |" | step ← steps]

-- ---------------------------------------------------------------------------
-- The verdict

spec ∷ RecoveryOutcome → Spec
spec outcome = describe "VK-14 recovery" $ do
  it "established every step of its private roots, its two windows' generations, its resources and its frames" $
    onFacts outcome $ \_ → pure ()

  it "gave the lost acquisition's reservation back, and replaced the surface on the same window and target, as one attempt of its episode" $
    onFacts outcome $ \facts → do
      let replaced = observedReplaced (factsObserved facts)
      replacedLossAnswer replaced `shouldBe` "AcquisitionPending PendingSurfaceLost"
      replacedOffer replaced `shouldBe` "ReplacementInstalled"
      replacedNewSurface replaced `shouldSatisfy` (/= replacedOldSurface replaced)
      replacedNewGeneration replaced `shouldSatisfy` (/= replacedOldGeneration replaced)
      fst (replacedTarget replaced) `shouldBe` snd (replacedTarget replaced)
      replacedAttempts replaced `shouldBe` Just 1

  it "destroyed the lost surface's generation, then the lost surface, and only then checked the replacement against the one device and built a fresh generation on it" $
    onFacts outcome $ \facts → do
      let replaced = observedReplaced (factsObserved facts)
          calls = replacedCalls replaced
          old = replacedOldSurface replaced
          new = replacedNewSurface replaced
      calls
        `shouldSatisfy` isSubsequenceOf
          [ "vkDestroyImageView"
          , "vkDestroySurfaceKHR " <> hex old
          , "vkGetPhysicalDeviceSurfaceSupportKHR " <> hex new
          , "vkCreateSwapchainKHR on " <> hex new <> ", handing nothing over"
          ]
      -- Nothing was ever built on the lost surface again.
      [call | call ← calls, ("vkCreateSwapchainKHR on " <> hex old) `Text.isPrefixOf` call] `shouldBe` []

  it "kept the second window presenting throughout, and presented on the first window's new generation" $
    onFacts outcome $ \facts → do
      let replaced = observedReplaced (factsObserved facts)
      replacedSecondDuring replaced `shouldSatisfy` (>= 1)
      replacedFirstAfter replaced `shouldBe` 3

  it "recovered an allocation that ran out of memory by reclaiming the retired generation once and making the creation once more" $
    onFacts outcome $ \facts → do
      let reclaimed = observedReclaimed (factsObserved facts)
          calls = reclaimedCalls reclaimed
      reclaimedEligible reclaimed `shouldBe` True
      reclaimedGone reclaimed `shouldBe` True
      reclaimedAnswer reclaimed `shouldBe` "a readback"
      calls `shouldSatisfy` isSubsequenceOf ["vkCreateBuffer: VK_ERROR_OUT_OF_DEVICE_MEMORY (injected)", "vkDestroyImageView", "vkCreateBuffer"]
      length [call | call ← calls, "vkCreateBuffer" `Text.isPrefixOf` call] `shouldBe` 2
      length [call | call ← calls, "vkDestroySwapchainKHR" `Text.isPrefixOf` call] `shouldBe` 1

  it "held nothing unsettled before the session's retirement, every fence observed" $
    onFacts outcome $ \facts →
      observedLeft (factsObserved facts) `shouldBe` ([], [], [])

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

onFacts ∷ RecoveryOutcome → (RecoveryFacts → Expectation) → Expectation
onFacts outcome assertion = case outcome of
  RecoveryStopped reason _ _ _ → expectationFailure ("the recovery session stopped: " <> Text.unpack reason)
  RecoveryRecorded facts → assertion facts

hex ∷ Word64 → Text
hex value = "0x" <> Text.pack (showHex value "")

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
