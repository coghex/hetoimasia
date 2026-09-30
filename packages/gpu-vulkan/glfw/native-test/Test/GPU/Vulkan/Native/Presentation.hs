{-# LANGUAGE OverloadedRecordDot #-}

-- | VK-13's native case: frames presented to two windows with verified present
-- fences, a resized target's old generation retired only on that evidence, the
-- first target closed while the second keeps presenting, and the session
-- retired with every fence observed — on private roots, with validation
-- reporting nothing.
--
-- The roots are VK-12's case's: the production native layers, the validation
-- layer with synchronization validation, and a surface for each of two
-- windows, each with a swapchain generation. Over them the production frames
-- layer ("Hetoimasia.GPU.Vulkan.Native.Frames.Vulkan"):
--
-- 1. presents three triangle frames to each window back to back — each
--    acquired through 'tryAcquireFrame', recorded, submitted through
--    'submitFrames' and presented through 'presentFrame' with its pool
--    record's present fence — and then drains until every presentation's
--    retirement has been observed through its own present fence;
-- 2. presents a frame to the first window, resizes that window before any
--    progress step has asked the fence, and steps the generations until the
--    replacement is active: the old generation is retired but, its
--    presentation still unobserved, held and not destroyed, however many
--    generation steps run. Only once the present fence's retirement has been
--    observed does the next step destroy it. The first window then presents
--    on its new generation;
-- 3. presents to the first window, leaves a second frame acquired, and closes
--    that target: its frames are closed, and its retirement is attempted
--    while the second window keeps presenting, withheld until every piece of
--    its evidence has arrived; then its frames, its generations and its
--    surface are destroyed, and the second window presents three more frames
--    on the same device;
-- 4. drains until nothing is outstanding and retires the second target, the
--    recording, the device and the instance.
--
-- The only waits are 'awaitFrames'' finite drain waits — at most 10 ms each, on
-- one pending fence, and never evidence — and a millisecond between the
-- generation steps a resize needs, bounded by a patience after which the case
-- stops.
module Test.GPU.Vulkan.Native.Presentation
  ( PresentationOutcome (..)
  , runPresentation
  , presentationSection
  , spec
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception (SomeException, displayException, finally, onException, throwIO, try, tryWithContext)
import Control.Monad (forM, forM_, replicateM, unless, when)
import qualified Data.ByteString.Char8 as Char8
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import Foreign.Ptr (Ptr, nullPtr)
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
import Hetoimasia.GPU.Model (HoldView (..), PresentOutcome (..), holdView)
import Hetoimasia.GPU.Model.Budget (defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (GenerationId, HoldSubject (..), PresentationId, SubmissionId, TargetClass (..), TargetId, generationTarget, imageGeneration, imageIndex)
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

-- | One presentation's way through the case.
data Shown = Shown
  { shownWindow ∷ !Text
  , shownPresentation ∷ !PresentationId
  , shownImage ∷ !Word32
  , shownOutcome ∷ !PresentOutcome
  , shownRetiredAfter ∷ !Int
    -- ^ How many further drain steps the case waited, once the presentations
    -- made with it had been made, for its retirement to be observed.
  }
  deriving (Show)

-- | What the resize showed.
data Resized = Resized
  { resizedFrom ∷ !SurfaceExtent
  , resizedTo ∷ !SurfaceExtent
  , resizedOld ∷ !GenerationId
  , resizedNew ∷ !GenerationId
  , resizedHeldBy ∷ ![PresentationId]
    -- ^ The presentations holding the old generation once the replacement
    -- was active.
  , resizedStepsHeld ∷ !Int
    -- ^ Generation steps after the replacement during which the old
    -- generation, its presentation unobserved, still existed.
  , resizedDestroyedAfterRetirement ∷ !Bool
    -- ^ Whether the first generation step after the retirement was observed
    -- destroyed it.
  }
  deriving (Show)

-- | What closing the first target showed.
data Closed = Closed
  { closedWithheld ∷ !Int
    -- ^ Retirement attempts withheld while its evidence was outstanding.
  , closedWithheldBy ∷ ![Text]
    -- ^ What the first withheld attempt named.
  , closedSecondDuring ∷ !Int
    -- ^ Frames the second window presented while the first was retiring.
  , closedSecondAfter ∷ ![Shown]
    -- ^ The second window's presentations after the first's surface was
    -- destroyed.
  }
  deriving (Show)

data Observed = Observed
  { observedDevice ∷ !Text
  , observedFormat ∷ !Word32
  , observedExtents ∷ ![SurfaceExtent]
  , observedFirst ∷ ![Shown]
  , observedResized ∷ !Resized
  , observedAfterResize ∷ ![Shown]
  , observedClosed ∷ !Closed
  , observedCalls ∷ ![Text]
    -- ^ Every native call the frames made, in order, status queries and drain
    -- waits left out.
  , observedWaits ∷ !Int
  , observedLeft ∷ !([FrameStanding], [PresentationStanding], [SubmissionId])
    -- ^ What the frames still held before the second target's retirement.
  }
  deriving (Show)

data PresentationFacts = PresentationFacts
  { factsObserved ∷ !Observed
  , factsSteps ∷ ![Step]
  , factsEntries ∷ ![LogEntry]
  , factsVerdict ∷ !DiagnosticVerdict
  }
  deriving (Show)

data PresentationOutcome
  = PresentationRecorded PresentationFacts
  | PresentationStopped Text (Maybe DiagnosticVerdict) [Step] [LogEntry]
  deriving (Show)

presentationCaptureConfig ∷ CaptureConfig
presentationCaptureConfig = defaultCaptureConfig {captureTextBudget = 16384}

-- | How many drain steps, each waiting at most 10 ms, the case waits for any
-- one piece of evidence before it stops.
patience ∷ Int
patience = 500

stopWith ∷ Text → IO a
stopWith reason = throwIO (userError (Text.unpack reason))

-- | Run the case on the calling thread, which must be the process main
-- thread: GLFW's windows and surfaces are made there, and so is everything
-- else, since this private process has no other owner.
runPresentation ∷ Maybe Backend → Journal → IO PresentationOutcome
runPresentation backend journal = do
  heading journal "VK-13: frames presented, generations and a window retired on present fences"
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
          <$> try @SomeException (withDiagnosticCapture presentationCaptureConfig logger (session journal steps))
          `finally` glfwTerminate
  entries ← reverse <$> readTVarIO logged
  seen ← reverse <$> readIORef steps
  case outcome of
    Left (failure, verdict) → do
      note journal ("the presentation session stopped: " <> Text.pack failure)
      pure (PresentationStopped (Text.pack failure) verdict seen entries)
    Right (observed, verdict) → do
      note journal ("the lifetime delivered " <> tshow (verdictDelivered verdict) <> " records")
      pure (PresentationRecorded (PresentationFacts observed seen entries verdict))

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
  observed ← withWindows journal step roots `finally` finish
  readIORef proved >>= \case
    Just quiesced → pure (observed, quiesced)
    Nothing → stopWith "the instance's destruction proved nothing"

-- | One window, its surface and its target.
data Window = Window
  { windowName ∷ !Text
  , windowHandle ∷ !(Ptr ProofWindow)
  , windowTarget ∷ !TargetId
  }

withWindows ∷ Journal → (∀ a. Text → IO a → IO a) → VulkanRoots → IO Observed
withWindows journal step roots = do
  instanceHandle ← atomically (readRootsInstance roots) >>= maybe (stopWith "the roots hold no instance") pure
  generations ← newGenerations roots
  let open name = do
        window ← createProofWindow 160 120 ("hetoimasia VK-13 " <> Text.unpack name) >>= maybe (lastGlfwError >>= stopWith . ("no window: " <>)) pure
        (result, surface) ← createWindowSurface (instancePointer instanceHandle) window
        when (result /= 0) (stopWith ("glfwCreateWindowSurface answered " <> tshow result))
        let destroy = either SurfaceDestructionUncertain (const SurfaceDestroyed) <$> tryWithContext (destroySurfaceKHR instanceHandle (SurfaceKHR surface) Nothing)
        target ←
          step ("the target of the " <> name <> " window") (admitRootTarget roots RequiredTarget (TargetSurface surface destroy))
            >>= either (stopWith . ("the target was refused: " <>) . tshow) pure
        atomically (trackTarget generations target RequiredTarget surface)
        pure (Window name window target)
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
  observed ←
    withFrames journal step roots generations first second destroyed
      `finally` (retireWindow first >> retireWindow second)
  pure observed

withFrames
  ∷ Journal
  → (∀ a. Text → IO a → IO a)
  → VulkanRoots
  → VulkanGenerations
  → Window
  → Window
  → IORef [Text]
  → IO Observed
withFrames journal step roots generations first second destroyed = do
  _ ← step "the swapchain generations" (stepGenerations generations (at 0) =<< geometriesOf [first, second])
  views ← forM [first, second] $ \window → do
    view ← atomically (readTargetGenerations generations (windowTarget window)) >>= maybe (stopWith "the target is not tracked") pure
    unless (viewCondition view == Presenting) (stopWith ("the " <> windowName window <> " window's target is not presenting: " <> tshow (viewCondition view)))
    maybe (stopWith "the target has no active generation") pure (viewActive view >>= \active → find ((== active) . viewGeneration) (viewGenerations view))
  let format = case views of
        generation : _ → surfaceFormat (planFormat (viewPlan generation))
        [] → 0
  (devicePlan, _) ← atomically (readRootsDevice roots) >>= maybe (stopWith "the roots hold no device") pure
  ops ← vulkanRecordingOps (planDevice devicePlan)
  recording ← newRecording ops roots generations
  calls ← newIORef []
  waits ← newIORef 0
  frames ← newFrames (observing calls waits vulkanFrameOps) recording
  outcome ← try @SomeException (exercise journal step roots generations recording frames format first second destroyed)
  -- A case that stopped part-way may have left work pending: observe what
  -- still arrives, within a bounded number of drain waits, before retiring.
  case outcome of
    Left _ → do
      let settle count = do
            _ ← try @SomeException (awaitFrames frames (at 80000) drainWaitLimit)
            left ← atomically ((,) <$> readPresentations frames <*> readOutstandingSubmissions frames)
            unless (null (fst left) && null (snd left) || count >= patience) (settle (count + (1 ∷ Int)))
      settle 0
    Right _ → pure ()
  -- Whatever happened, what the frames still hold is retired, then the
  -- recording's resources; anything unsettled is retained, and says so.
  _ ← try @SomeException (step "retiring the second window's frames" (retireTargetFrames frames (windowTarget second)))
  _ ← try @SomeException (step "releasing and destroying the managed resources" (retireRecording recording (at 90000)))
  case outcome of
    Left failure → throwIO failure
    Right (shownFirst, resized, afterResize, closed, left) → do
      made ← reverse <$> readIORef calls
      waited ← readIORef waits
      pure
        Observed
          { observedDevice = planDeviceName devicePlan
          , observedFormat = format
          , observedExtents = map (planExtent . viewPlan) views
          , observedFirst = shownFirst
          , observedResized = resized
          , observedAfterResize = afterResize
          , observedClosed = closed
          , observedCalls = made
          , observedWaits = waited
          , observedLeft = left
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
  → VulkanRoots
  → VulkanGenerations
  → VulkanRecording
  → VulkanFrames
  → Word32
  → Window
  → Window
  → IORef [Text]
  → IO ([Shown], Resized, [Shown], Closed, ([FrameStanding], [PresentationStanding], [SubmissionId]))
exercise journal step roots generations recording frames format first second destroyed = do
  let made ∷ Show refusal ⇒ Text → IO (Either refusal a) → IO a
      made name action = step name action >>= either (stopWith . ((name <> " was refused: ") <>) . tshow) pure
      command name action = action >>= either (stopWith . ((name <> " was refused: ") <>) . tshow) pure
  clock ← newIORef (1000 ∷ Integer)
  -- Every presentation whose retirement any step has observed so far.
  retiredSoFar ← newIORef []
  let tick = atomicTick clock
      live = do
        gone ← readIORef destroyed
        pure [window | window ← [first, second], windowName window `notElem` gone]
      -- One owner step: the frames, then the generations of every live
      -- window at its current framebuffer.
      drain = do
        now ← tick
        report ← awaitFrames frames (at now) drainWaitLimit
        modifyIORef' retiredSoFar (<> progressRetired report)
        _ ← stepGenerations generations (at now) =<< geometriesOf =<< live
        pure report
      -- Drain until the predicate holds of everything that has retired so
      -- far, answering how many drain steps that took — none, if it already
      -- held.
      drainUntil ∷ Text → ([PresentationId] → Bool) → IO Int
      drainUntil what done = go 0
        where
          go count = do
            seen ← readIORef retiredSoFar
            if done seen
              then pure count
              else
                if count >= patience
                  then stopWith (what <> " did not arrive in " <> tshow count <> " drain steps")
                  else drain >> go (count + 1)
      extentOf image = do
        view ← atomically (readTargetGenerations generations (imageTargetOf image)) >>= maybe (stopWith "the target is not tracked") pure
        maybe (stopWith "the frame's generation is not tracked") (pure . planExtent . viewPlan) (find ((== imageGeneration image) . viewGeneration) (viewGenerations view))
      imageTargetOf image = generationTarget (imageGeneration image)
  layout ← made "vkCreatePipelineLayout" (createPipelineLayout recording)
  pipeline ← made "vkCreateGraphicsPipelines" (createPipeline recording layout verificationShaders format)
  forM_ [first, second] $ \window → forM_ [0, 1] $ \slot →
    made ("vkCreateCommandPool, " <> windowName window <> " slot " <> tshow slot) (createFrameStorage recording (windowTarget window) slot)

  let -- Acquire a frame of the window, draining between answers that are
      -- only pending.
      acquire window = go (1 ∷ Int)
        where
          go attempt =
            tryAcquireFrame frames (windowTarget window) >>= \case
              Right (AcquisitionOwned frame) → pure frame
              Right (AcquisitionPending _) | attempt < patience → drain >> go (attempt + 1)
              other → stopWith ("no frame of the " <> windowName window <> " window was acquired after " <> tshow attempt <> " attempts: " <> tshow other)
      -- Acquire, record a triangle, submit and present one frame of the
      -- window, without waiting for anything.
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
          Right (PresentedAs presentation outcome) → pure (windowName window, presentation, fromIntegral (imageIndex (ownedImage frame)), outcome)
          other → stopWith ("the presentation answered " <> tshow other)
      -- Present these frames back to back, then drain until every one has
      -- retired.
      presentAll window count = do
        made' ← replicateM count (present window)
        retiredAt ← forM made' $ \(_, presentation, _, _) →
          step ("awaiting a present fence of the " <> windowName window <> " window") (drainUntil "a presentation's retirement" (presentation `elem`))
        pure [Shown name presentation image outcome after | ((name, presentation, image, outcome), after) ← zip made' retiredAt]

  -- 1. Three frames to each window, with every present fence observed.
  shownFirst ← (<>) <$> presentAll first 3 <*> presentAll second 3
  note journal ("presented and retired " <> tshow (length shownFirst) <> " frames on two windows")

  -- 2. Resize the first window with a presentation of its old generation still
  -- unobserved.
  (_, pending, _, _) ← present first
  old ← activeOf generations (windowTarget first)
  from ← planExtent . viewPlan <$> generationOf generations old
  setWindowSize (windowHandle first) 200 150
  let replace attempt = do
        pollEvents
        now ← tick
        _ ← stepGenerations generations (at now) =<< geometriesOf [first, second]
        active ← activeOf generations (windowTarget first)
        if active /= old
          then pure active
          else
            if attempt >= patience
              then stopWith "the resize built no replacement generation"
              else threadDelay 1000 >> replace (attempt + (1 ∷ Int))
  new ← step "replacing the resized window's generation" (replace 1)
  to ← planExtent . viewPlan <$> generationOf generations new
  heldBy ← maybe [] viewPresentations . holdView (GenerationSubject old) <$> atomically (readRootsModel roots)
  -- More generation steps, with no progress step to observe the fence: the
  -- old generation is held however long that is.
  held ← fmap length . forM [1 .. 3 ∷ Int] $ \_ → do
    now ← tick
    _ ← stepGenerations generations (at now) =<< geometriesOf [first, second]
    stillThere ← existsGeneration generations old
    unless stillThere (stopWith "the old generation was destroyed before its presentation's retirement was observed")
  -- Only the frames step here: a generation step between the observation
  -- and the check below would destroy the old generation before it is looked
  -- for.
  _ ← step "awaiting the old generation's present fence" $ do
    let go count = do
          seen ← readIORef retiredSoFar
          if pending `elem` seen
            then pure count
            else
              if count >= patience
                then stopWith "the old generation's presentation did not retire"
                else do
                  now ← tick
                  report ← awaitFrames frames (at now) drainWaitLimit
                  modifyIORef' retiredSoFar (<> progressRetired report)
                  go (count + (1 ∷ Int))
    go 0
  destroyedAfter ← do
    now ← tick
    _ ← step "destroying the old generation" (stepGenerations generations (at now) =<< geometriesOf [first, second])
    not <$> existsGeneration generations old
  afterResize ← presentAll first 2
  let resized = Resized from to old new heldBy held destroyedAfter
  note journal ("resized " <> tshow from <> " to " <> tshow to <> "; the old generation was held by " <> tshow heldBy)

  -- 3. Close the first window while the second keeps presenting.
  (_, closing, _, _) ← present first
  unpresented ← acquire first
  answers ← step "closing the first window's frames" (closeTargetFrames frames (windowTarget first))
  unless (all (either (const False) (const True) . snd) answers) (stopWith ("closing the frames answered " <> tshow answers))
  withheld ← newIORef (0 ∷ Int)
  firstWithheld ← newIORef []
  during ← newIORef (0 ∷ Int)
  let retireFirst attempt = do
        outcome ← try @SomeException (retireTargetFrames frames (windowTarget first))
        case outcome of
          Right () → pure ()
          Left failure
            | attempt >= patience → throwIO failure
            | otherwise → do
                modifyIORef' withheld (+ 1)
                noted ← readIORef firstWithheld
                when (null noted) (writeIORef firstWithheld [Text.pack (displayException failure)])
                -- The second window presents meanwhile.
                when (attempt <= 3) $ do
                  _ ← present second
                  modifyIORef' during (+ 1)
                _ ← drain
                retireFirst (attempt + (1 ∷ Int))
  step "retiring the first window's frames" (retireFirst 1)
  _ ← step "the first window's generations" (retireTargetGenerations generations (at 50000) (windowTarget first))
  _ ← step "the first window's surface" (retireRootTarget roots (windowTarget first))
  destroyProofWindow (windowHandle first)
  modifyIORef' destroyed (windowName first :)
  note journal ("closed the first window after its presentation " <> tshow closing <> " and its skipped frame " <> tshow (ownedFrame unpresented) <> " settled")
  secondAfter ← presentAll second 3
  closed ← Closed <$> readIORef withheld <*> readIORef firstWithheld <*> readIORef during <*> pure secondAfter

  -- 4. Drain until nothing is outstanding, and hand the rest to retirement.
  let settle count = do
        _ ← drain
        left ← atomically ((,,) <$> readFrameStandings frames <*> readPresentations frames <*> readOutstandingSubmissions frames)
        case left of
          ([], [], []) → pure left
          _ | count >= patience → pure left
          _ → settle (count + (1 ∷ Int))
  left ← step "draining the second window" (settle 1)
  pure (shownFirst, resized, afterResize, closed, left)
  where
    atomicTick clock = do
      now ← readIORef clock
      writeIORef clock (now + 17)
      pure now

-- | The active generation of a target.
activeOf ∷ VulkanGenerations → TargetId → IO GenerationId
activeOf generations target =
  atomically (readTargetGenerations generations target) >>= \case
    Just view | Just active ← viewActive view → pure active
    other → stopWith ("the target has no active generation: " <> tshow (fmap viewCondition other))

generationOf ∷ VulkanGenerations → GenerationId → IO GenerationView
generationOf generations generation =
  atomically (readTargetGenerations generations (generationTarget generation)) >>= \case
    Just view | Just native ← find ((== generation) . viewGeneration) (viewGenerations view) → pure native
    _ → stopWith ("the generation is not tracked: " <> tshow generation)

existsGeneration ∷ VulkanGenerations → GenerationId → IO Bool
existsGeneration generations generation =
  maybe False (any ((== generation) . viewGeneration) . viewGenerations)
    <$> atomically (readTargetGenerations generations (generationTarget generation))

-- | The frames layer, noting each call's entry point before it is made.
observing ∷ IORef [Text] → IORef Int → FrameOps dev cmd → FrameOps dev cmd
observing calls waits ops =
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
    , opsPresent = \device family request status → do
        outcome ← try @SomeException (opsPresent ops device family request status)
        written ← readIORef status
        modifyIORef' calls (("vkQueuePresentKHR: " <> tshow written) :)
        either throwIO pure outcome
    , opsWaitFence = \device fence timeout → do
        modifyIORef' waits (+ 1)
        opsWaitFence ops device fence timeout
    }
  where
    -- Status queries and drain waits are the polling itself, and are left
    -- out of the calls.
    noted ∷ Text → IO a → IO a
    noted name action = modifyIORef' calls (name :) >> action

-- | The record's section.
presentationSection ∷ PresentationOutcome → [Text]
presentationSection = \case
  PresentationStopped reason verdict steps logged →
    ["", "## The session stopped", "", reason, ""]
      <> stepTable steps
      <> [ ""
         , "- error reports: " <> errorReports logged
         , "- verdict issues: " <> maybe "no verdict" (tshow . verdictIssues) verdict
         ]
  PresentationRecorded facts →
    let observed = factsObserved facts
        resized = observedResized observed
        closed = observedClosed observed
        shown label presentations =
          ("- " <> label <> ":")
            : [ "  - " <> shownWindow each <> ": " <> tshow (shownPresentation each) <> ", image " <> tshow (shownImage each)
                  <> ", " <> tshow (shownOutcome each) <> ", retired after " <> tshow (shownRetiredAfter each) <> " drain steps"
              | each ← presentations
              ]
     in [ ""
        , "## Frames presented, and generations and a window retired on present fences"
        , ""
        , "- device: " <> observedDevice observed
        , "- format " <> tshow (observedFormat observed) <> ", first generations " <> Text.intercalate " and " [tshow (extentWidth extent) <> "x" <> tshow (extentHeight extent) | extent ← observedExtents observed]
        ]
          <> shown "presented to both windows" (observedFirst observed)
          <> [ "- resized the first window from " <> extentText (resizedFrom resized) <> " to " <> extentText (resizedTo resized)
                 <> ": " <> tshow (resizedOld resized) <> " replaced by " <> tshow (resizedNew resized)
             , "- the old generation, once replaced, was held by " <> tshow (resizedHeldBy resized)
                 <> " through " <> tshow (resizedStepsHeld resized) <> " more generation steps"
             , "- destroyed by the first generation step after its presentation's retirement was observed: " <> tshow (resizedDestroyedAfterRetirement resized)
             ]
          <> shown "presented to the resized window" (observedAfterResize observed)
          <> [ "- the first window's retirement was withheld " <> tshow (closedWithheld closed) <> " times; first: " <> Text.intercalate "; " (closedWithheldBy closed)
             , "- the second window presented " <> tshow (closedSecondDuring closed) <> " frames while the first was retiring"
             ]
          <> shown "presented to the second window after the first's surface was destroyed" (closedSecondAfter closed)
          <> [ "- drain waits: " <> tshow (observedWaits observed)
             , "- left before retirement: " <> tshow (observedLeft observed)
             , ""
             , "Native calls the frames made, status queries and drain waits left out:"
             , ""
             ]
          <> ["1. " <> call | call ← observedCalls observed]
          <> [""]
          <> stepTable (factsSteps facts)
          <> [ ""
             , "- error reports: " <> errorReports (factsEntries facts)
             , "- records delivered: " <> tshow (verdictDelivered (factsVerdict facts))
             , "- undelivered: " <> tshow (verdictUndelivered (factsVerdict facts))
             , "- verdict issues: " <> tshow (verdictIssues (factsVerdict facts))
             ]
  where
    extentText extent = tshow (extentWidth extent) <> "x" <> tshow (extentHeight extent)
    errorReports logged = case [Map.findWithDefault "" "message.id" entry.entryFields <> ": " <> Text.take 600 entry.entryMessage | entry ← logged, Map.lookup "severity" entry.entryFields == Just "error"] of
      [] → "none"
      reports → Text.intercalate "; " reports
    stepTable steps =
      ["| step | reports | errors |", "| --- | --- | --- |"]
        <> ["| " <> step.stepName <> " | " <> tshow step.stepReports <> " | " <> tshow step.stepErrors <> " |" | step ← steps]

-- ---------------------------------------------------------------------------
-- The verdict

spec ∷ PresentationOutcome → Spec
spec outcome = describe "VK-13 presentation" $ do
  it "established every step of its private roots, its two windows' generations, its resources and its frames" $
    onFacts outcome $ \_ → pure ()

  it "presented every frame with its present fence reset immediately before, and observed every presentation's retirement through that fence" $
    onFacts outcome $ \facts → do
      let observed = factsObserved facts
          calls = observedCalls observed
          presents = [call | call ← calls, "vkQueuePresentKHR" `Text.isPrefixOf` call]
          everyShown = observedFirst observed <> observedAfterResize observed <> closedSecondAfter (observedClosed observed)
      presents `shouldSatisfy` all (`elem` ["vkQueuePresentKHR: PresentStatusSuccess", "vkQueuePresentKHR: PresentStatusSuboptimal"])
      -- Three to each window, two after the resize, three after the close.
      length everyShown `shouldBe` 11
      [call | (previous, call) ← zip calls (drop 1 calls), "vkQueuePresentKHR" `Text.isPrefixOf` call, previous /= "vkResetFences"] `shouldBe` []
      -- Every presentation the case made, those it left pending while it
      -- resized and closed the first window included.
      length presents `shouldBe` length everyShown + 2 + closedSecondDuring (observedClosed observed)

  it "retired the resized window's old generation only once its presentation's present fence had been observed" $
    onFacts outcome $ \facts → do
      let resized = observedResized (factsObserved facts)
      resizedNew resized `shouldSatisfy` (/= resizedOld resized)
      resizedTo resized `shouldSatisfy` (/= resizedFrom resized)
      resizedHeldBy resized `shouldSatisfy` ((== 1) . length)
      resizedStepsHeld resized `shouldBe` 3
      resizedDestroyedAfterRetirement resized `shouldBe` True

  it "closed the first window, withholding its retirement until its evidence arrived, while the second kept presenting on the shared device" $
    onFacts outcome $ \facts → do
      let closed = observedClosed (factsObserved facts)
      closedWithheld closed `shouldSatisfy` (>= 1)
      closedSecondDuring closed `shouldSatisfy` (>= 1)
      length (closedSecondAfter closed) `shouldBe` 3

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

onFacts ∷ PresentationOutcome → (PresentationFacts → Expectation) → Expectation
onFacts outcome assertion = case outcome of
  PresentationStopped reason _ _ _ → expectationFailure ("the presentation session stopped: " <> Text.unpack reason)
  PresentationRecorded facts → assertion facts

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
