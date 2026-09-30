{-# LANGUAGE OverloadedRecordDot #-}

-- | GRS-15's native cases: a graphics session whose device the owner's
-- startup creates without a surface, through the production host, on private
-- roots in a child process of its own.
--
-- The production composition — the loader integration, the validation layer
-- with synchronization validation, the diagnostic lifetime, the protected
-- window host and its graphics owner — is configured with 'DeviceSurfaceFree'.
--
-- * @grs15-surface-free@ opens no window at all. Its owner creates the
--   instance, its messenger and the device; one owner-thread action builds a
--   pipeline layout and a pipeline over the embedded verification shaders, and
--   a second releases both; the owner's own progress destroys them, with no
--   target and no frame; and the host exits through D-33.
-- * @grs15-surface-free-window@ creates the device the same way, then hands
--   over one mapped window, whose surface is admitted against the device's
--   queue family, presents one frame of it and sees that presentation retire
--   on its own present fence, and exits.
--
-- Each asserts where the device came from — enumerated and created with no
-- surface query — the order of the roots' destruction, that every Vulkan call
-- ran on the graphics owner's thread, and a verdict read after the last
-- callback with no issue and no error. It infers nothing from any timing.
module Test.GPU.Vulkan.Native.SurfaceFree
  ( SurfaceFreeOutcome (..)
  , runSurfaceFree
  , runLaterWindow
  , surfaceFreeSection
  , laterWindowSection
  , surfaceFreeSpec
  , laterWindowSpec
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM (STM, TVar, atomically, check, modifyTVar', newTVarIO, orElse, readTVar, readTVarIO, registerDelay, retry)
import Control.Exception (SomeException, displayException, throwIO, try)
import Control.Monad (void, when)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (elemIndex, nub)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock (addUTCTime, diffUTCTime, getCurrentTime)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

import Hetoimasia.Foundation.Log
  ( DebugSelection (DebugAll)
  , LogEntry (..)
  , LogFilter (..)
  , LogLevel (Info)
  , Logger
  , callbackSink
  , mkLogger
  )
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.GLFW.Session (Backend)
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GLFW.Window (WindowConfig (..), hiddenTestWindowConfig)
import Hetoimasia.GPU.Model.Budget (defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.Diagnostics (CaptureConfig (..), DiagnosticVerdict (..), defaultCaptureConfig, verdictIssues)
import Hetoimasia.GPU.Vulkan.GLFW
  ( ActionOutcome (..)
  , Construction
  , FrameEvent (..)
  , NativeObserver (..)
  , Pipeline
  , PipelineLayout
  , Readiness (..)
  , Refusal
  , VulkanAction (..)
  , VulkanDeviceStart (..)
  , VulkanHandover (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , awaitVulkanAction
  , constructPipeline
  , constructPipelineLayout
  , handOverVulkanTarget
  , publishVulkanScene
  , readReadiness
  , readVulkanRoots
  , releaseConstructed
  , runVulkanOwnerLoop
  , submitVulkanAction
  , vulkanHostConfig
  , withVulkanOwnerHost
  )
import Hetoimasia.GPU.Vulkan.Native.Presentation (formatB8G8R8A8Srgb)
import Hetoimasia.GPU.Vulkan.Native.Recording.Shaders (verificationShaders)
import Hetoimasia.GPU.Vulkan.Native.Roots (RootStanding (..), RootsView (..))
import Hetoimasia.Runtime.GLFW
  ( ScheduledStep (..)
  , TargetStanding (..)
  , UpdateSchedule (..)
  , defaultHostConfig
  , defaultScheduledHooks
  , graphicsAttachment
  , hostWindowIdentities
  , readTargetStanding
  , runGraphicsOwnerApplication
  )
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Test.GPU.Vulkan.Native.Environment (validationFeatures)
import Test.GPU.Vulkan.Native.Platform (requestingBackend)
import Test.Vulkan.Proof.Journal (Journal, heading, note)
import Test.Vulkan.Proof.Roots (NativeCall (..), nativeCallObserver)

-- | What one case saw.
data SurfaceFreeFacts = SurfaceFreeFacts
  { factsCalls ∷ ![NativeCall]
    -- ^ Every observed native call, oldest first.
  , factsRunning ∷ ![Text]
    -- ^ The names of the calls made by the time the body finished, before
    -- the host's exit began.
  , factsMainThread ∷ !ThreadId
  , factsActionThreads ∷ ![ThreadId]
    -- ^ The thread each owner-thread action ran on.
  , factsActions ∷ ![Text]
    -- ^ What each owner-thread action answered.
  , factsWindows ∷ !Int
  , factsRoots ∷ !(Maybe RootsView)
    -- ^ The roots as the body last saw them.
  , factsStanding ∷ !(Maybe TargetStanding)
  , factsEvents ∷ ![FrameEvent]
  , factsVerdict ∷ !(Maybe DiagnosticVerdict)
  , factsErrors ∷ ![Text]
  , factsSeconds ∷ !Double
  }

data SurfaceFreeOutcome
  = SurfaceFreeFailed !Text
  | SurfaceFreeRecorded !SurfaceFreeFacts

-- | What a body records beside the calls.
data Seen = Seen
  { seenThreads ∷ ![ThreadId]
  , seenActions ∷ ![Text]
  , seenWindows ∷ !Int
  , seenRoots ∷ !(Maybe RootsView)
  , seenStanding ∷ !(Maybe TargetStanding)
  }

-- | The case with no window, on the calling thread, which must be the process
-- main thread.
runSurfaceFree ∷ Maybe Backend → Journal → IO SurfaceFreeOutcome
runSurfaceFree backend journal = do
  heading journal "GRS-15: a surface-free session with no window acts on its device through the owner's thread"
  runCase backend [] "vulkan-native-grs15-surface-free" $ \vulkan _ names _ → do
    (threads, answers) ← actOnDevice vulkan
    -- What the second action released is destroyed by the owner's own
    -- progress, with no target, while the host still runs.
    awaitWithin 10 "the released pipeline's destruction" $ do
      made ← readTVar names
      pure (if all (`elem` made) ["vkDestroyPipeline", "vkDestroyPipelineLayout"] then Just () else Nothing)
    windows ← length <$> atomically (hostWindowIdentities (vulkanWindowHost vulkan))
    roots ← atomically (readVulkanRoots (vulkanController vulkan))
    note journal ("the actions answered " <> Text.intercalate "; " answers)
    pure (Seen threads answers windows (Just roots) Nothing)

-- | The case that admits a window after the device exists.
runLaterWindow ∷ Maybe Backend → Journal → IO SurfaceFreeOutcome
runLaterWindow backend journal = do
  heading journal "GRS-15: a surface-free session admits a window after its device exists, and presents to it"
  let window = (hiddenTestWindowConfig "hetoimasia GRS-15 later window" 160 120) {windowVisible = True}
  runCase backend [window] "vulkan-native-grs15-surface-free-window" $ \vulkan control _ events → do
    [identity] ← atomically (hostWindowIdentities (vulkanWindowHost vulkan))
    service ←
      handOverVulkanTarget vulkan identity RequiredTarget >>= \case
        VulkanTargetHandedOver service → pure service
        other → stopWith ("the window was not handed over: " <> tshow other)
    standing ← awaitWithin 10 "the target's admission" $
      readTargetStanding (vulkanGraphicsOwner vulkan) (graphicsAttachment service) >>= \case
        Just TargetConstructing → pure Nothing
        Nothing → pure Nothing
        Just other → pure (Just other)
    when (standing /= TargetUsable) (stopWith ("the target was not admitted: " <> tshow standing))
    -- A newer scene asks the target for a frame; the loop turns until that
    -- frame is presented and its presentation retires.
    void (publishVulkanScene vulkan =<< prepare ())
    deadline ← addUTCTime 15 <$> getCurrentTime
    runVulkanOwnerLoop vulkan control . defaultScheduledHooks quiet $ \_ → do
      now ← getCurrentTime
      when (now > deadline) (stopWith "the window was not presented to within 15 seconds")
      seen ← readTVarIO events
      let presented = [presentation | FramePresented _ _ presentation _ ← seen]
          retired = [presentation | PresentationRetired presentation ← seen]
      pure (if any (`elem` retired) presented then FinishWith () else ContinueWith NoUpdateDemand)
    note journal "presented a frame to the later window and saw its presentation retire"
    roots ← atomically (readVulkanRoots (vulkanController vulkan))
    pure (Seen [] [] 1 (Just roots) (Just standing))
  where
    quiet = recordingLogger (\_ → pure ())

-- | Build a layout and a pipeline through one owner-thread action, and
-- release both through another, answering the thread each ran on and what
-- each answered.
actOnDevice ∷ VulkanHost () → IO ([ThreadId], [Text])
actOnDevice vulkan = do
  built ← act vulkan (VulkanAction building)
  (builtOn, pair) ← case built of
    ActionReturned (ran, Right pair) → pure (ran, pair)
    ActionReturned (_, Left refusal) → stopWith ("the construction was refused: " <> tshow refusal)
    other → stopWith ("the building action did not return: " <> outcomeText other)
  released ← act vulkan (VulkanAction (releasing pair))
  case released of
    ActionReturned (releasedOn, (Right (), Right ())) → pure ([builtOn, releasedOn], ["built a pipeline layout and a pipeline", "released both"])
    ActionReturned (_, answers) → stopWith ("a release was refused: " <> tshow answers)
    other → stopWith ("the releasing action did not return: " <> outcomeText other)
  where
    act host action =
      atomically (submitVulkanAction host action) >>= \case
        Left refusal → stopWith ("an action was refused: " <> tshow refusal)
        Right ticket → atomically (awaitVulkanAction ticket)
    outcomeText = \case
      ActionReturned _ → "returned"
      ActionRaised failure → "raised " <> Text.pack (displayException failure)
      ActionRefused refusal → "refused " <> tshow refusal

-- | Build a layout and a pipeline over the verification shaders, answering the
-- thread it ran on.
building ∷ Construction q inst msgr phys dev cmd → IO (ThreadId, Either Refusal (PipelineLayout, Pipeline))
building construction = do
  ran ← myThreadId
  answer ←
    constructPipelineLayout construction >>= \case
      Left refusal → pure (Left refusal)
      Right layout → fmap ((,) layout) <$> constructPipeline construction layout verificationShaders formatB8G8R8A8Srgb
  pure (ran, answer)

-- | Release the pipeline and then its layout, answering the thread it ran on.
releasing ∷ (PipelineLayout, Pipeline) → Construction q inst msgr phys dev cmd → IO (ThreadId, (Either Refusal (), Either Refusal ()))
releasing (layout, pipeline) construction = do
  ran ← myThreadId
  released ← releaseConstructed construction pipeline
  gone ← releaseConstructed construction layout
  pure (ran, (released, gone))

-- | Run one case's production host with the device started without a
-- surface, over these windows.
runCase
  ∷ Maybe Backend
  → [WindowConfig]
  → Text
  → (VulkanHost () → RuntimeControl → TVar [Text] → TVar [FrameEvent] → IO Seen)
  → IO SurfaceFreeOutcome
runCase backend windows label body = do
  started ← getCurrentTime
  recorded ← newIORef []
  names ← newTVarIO []
  events ← newTVarIO []
  logged ← newTVarIO []
  verdictHeld ← newIORef Nothing
  partial ← newIORef Nothing
  scene ← prepare ()
  budgets ← either (stopWith . tshow) pure (validateBudgets defaultBudgetRequest)
  let host = requestingBackend backend (defaultHostConfig windows)
      logger = recordingLogger (\entry → atomically (modifyTVar' logged (entry :)))
      config =
        (vulkanHostConfig host defaultCaptureConfig {captureTextBudget = 16384} budgets scene)
          { vulkanLayers = ["VK_LAYER_KHRONOS_validation"]
          , vulkanValidationFeatures = validationFeatures
          , vulkanObserver = \capture → naming names (nativeCallObserver recorded capture)
          , vulkanFrameObserver = \event → atomically (modifyTVar' events (event :))
          , vulkanDeviceStart = DeviceSurfaceFree
          }
  outcome ←
    try @SomeException $
      withLoaderIntegration $ \integration →
        runGraphicsOwnerApplication
          (withLoggingLifetime logger)
          label
          ( \_ use → do
              (result, verdict) ← withVulkanOwnerHost logger integration config use
              writeIORef verdictHeld (Just verdict)
              pure result
          )
          vulkanWindowHost
          (\vulkan _ → pure vulkan)
          (\vulkan control → do
              main ← myThreadId
              readiness ← awaitWithin 10 "the owner's startup" $
                readReadiness (vulkanController vulkan) >>= \case
                  RootsPending → pure Nothing
                  other → pure (Just other)
              case readiness of
                RootsFailed reason → stopWith ("the owner's startup failed: " <> reason)
                _ → pure ()
              seen ← body vulkan control names events
              running ← reverse <$> readTVarIO names
              writeIORef partial (Just (main, seen, running)))
  finished ← getCurrentTime
  verdict ← readIORef verdictHeld
  calls ← reverse <$> readIORef recorded
  entries ← readTVarIO logged
  seenEvents ← reverse <$> readTVarIO events
  let errors = [maybe "" id (Map.lookup "message" entry.entryFields) | entry ← entries, Map.lookup "severity" entry.entryFields == Just "error"]
  case outcome of
    Left failure → pure (SurfaceFreeFailed (Text.pack (displayException failure)))
    Right () →
      readIORef partial >>= \case
        Nothing → pure (SurfaceFreeFailed "the body returned without its facts")
        Just (main, seen, running) →
          pure . SurfaceFreeRecorded $
            SurfaceFreeFacts
              { factsCalls = calls
              , factsRunning = running
              , factsMainThread = main
              , factsActionThreads = seenThreads seen
              , factsActions = seenActions seen
              , factsWindows = seenWindows seen
              , factsRoots = seenRoots seen
              , factsStanding = seenStanding seen
              , factsEvents = seenEvents
              , factsVerdict = verdict
              , factsErrors = errors
              , factsSeconds = realToFrac (diffUTCTime finished started)
              }
  where
    -- Every call's name, as it returns, where a transaction can wait for it.
    naming names (NativeObserver observe) = NativeObserver $ \name call → do
      answer ← observe name call
      atomically (modifyTVar' names (name :))
      pure answer

-- ---------------------------------------------------------------------------
-- The records

surfaceFreeSection ∷ SurfaceFreeOutcome → [Text]
surfaceFreeSection = section "A surface-free session with no window, acting on its device"

laterWindowSection ∷ SurfaceFreeOutcome → [Text]
laterWindowSection = section "A surface-free session that admits a window later"

section ∷ Text → SurfaceFreeOutcome → [Text]
section title = \case
  SurfaceFreeFailed reason → ["", "## The case did not complete", "", reason]
  SurfaceFreeRecorded facts →
    [ ""
    , "## " <> title
    , ""
    , "- windows: " <> tshow (factsWindows facts)
    , "- roots at the end of the body: " <> maybe "unread" tshow (factsRoots facts)
    , "- target standing: " <> maybe "no target" tshow (factsStanding facts)
    , "- actions: " <> Text.intercalate "; " (factsActions facts)
    , "- device calls, in order: " <> Text.intercalate ", " (filter (`elem` rootCalls) (map (.callName) (factsCalls facts)))
    , "- Vulkan calls: " <> tshow (length (vulkanCalls facts)) <> ", on " <> tshow (length (nub (map (.callHaskellThread) (vulkanCalls facts)))) <> " thread(s)"
    , "- frames presented: " <> tshow (length [() | FramePresented {} ← factsEvents facts]) <> ", presentations retired: " <> tshow (length [() | PresentationRetired _ ← factsEvents facts])
    , "- verdict issues: " <> maybe "no verdict" (tshow . verdictIssues) (factsVerdict facts)
    , "- error reports: " <> tshow (length (factsErrors facts))
    , "- seconds, from the loader integration to the verdict: " <> Text.pack (show (factsSeconds facts))
    ]
  where
    rootCalls =
      [ "vkCreateInstance"
      , "vkCreateDebugUtilsMessengerEXT"
      , "vkEnumeratePhysicalDevices"
      , "vkCreateDevice"
      , "glfwCreateWindowSurface"
      , "vkGetPhysicalDeviceSurfaceSupportKHR"
      , "vkDestroySurfaceKHR"
      , "vkDestroyDevice"
      , "vkDestroyDebugUtilsMessengerEXT"
      , "vkDestroyInstance"
      ]

vulkanCalls ∷ SurfaceFreeFacts → [NativeCall]
vulkanCalls facts = [call | call ← factsCalls facts, "vk" `Text.isPrefixOf` call.callName]

-- ---------------------------------------------------------------------------
-- The examples

surfaceFreeSpec ∷ SurfaceFreeOutcome → Spec
surfaceFreeSpec outcome = describe "GRS-15 surface-free session" $ do
  it "opened no window and created no surface" $
    on outcome $ \facts → do
      factsWindows facts `shouldBe` 0
      callNames facts `shouldSatisfy` notElem "glfwCreateWindowSurface"

  it "created the device in the owner's startup, asking no surface about presentation" $
    on outcome $ \facts → do
      deviceFirst facts
      callNames facts `shouldSatisfy` notElem "vkGetPhysicalDeviceSurfaceSupportKHR"
      fmap (\roots → (viewDevice roots, viewTargets roots)) (factsRoots facts) `shouldBe` Just (RootLive, [])

  it "built and released a pipeline layout and a pipeline through owner-thread actions, on the owner's thread" $
    on outcome $ \facts → do
      factsActions facts `shouldBe` ["built a pipeline layout and a pipeline", "released both"]
      ownerThread facts $ \owner → factsActionThreads facts `shouldBe` [owner, owner]
      factsActionThreads facts `shouldSatisfy` notElem (factsMainThread facts)

  it "destroyed what it released through the owner's own progress, with no target and no frame, before the host's exit" $
    on outcome $ \facts → do
      factsRunning facts `shouldSatisfy` ordered ["vkCreatePipelineLayout", "vkCreateGraphicsPipelines", "vkDestroyPipeline", "vkDestroyPipelineLayout"]
      factsRunning facts `shouldSatisfy` notElem "vkDestroyDevice"
      factsEvents facts `shouldBe` []

  it "retired cleanly: the device, then the messenger, then the instance, with every Vulkan call on the owner's thread" $
    on outcome $ \facts → do
      callNames facts `shouldSatisfy` ordered ["vkDestroyPipelineLayout", "vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]
      oneOwnerThread facts

  it "reached a verdict after the last callback with no issue and no error" $
    on outcome clean

laterWindowSpec ∷ SurfaceFreeOutcome → Spec
laterWindowSpec outcome = describe "GRS-15 surface-free session with a later window" $ do
  it "created the device with no surface before the window's surface existed" $
    on outcome $ \facts → do
      deviceFirst facts
      callNames facts `shouldSatisfy` ordered ["vkCreateDevice", "glfwCreateWindowSurface", "vkGetPhysicalDeviceSurfaceSupportKHR"]

  it "admitted the window against the device's queue family, with one device" $
    on outcome $ \facts → do
      factsStanding facts `shouldBe` Just TargetUsable
      length (filter (== "vkCreateDevice") (callNames facts)) `shouldBe` 1

  it "presented a frame to it and saw that presentation retire on its own present fence" $
    on outcome $ \facts → do
      let presented = [presentation | FramePresented _ _ presentation _ ← factsEvents facts]
          retired = [presentation | PresentationRetired presentation ← factsEvents facts]
      presented `shouldSatisfy` (not . null)
      presented `shouldSatisfy` any (`elem` retired)

  it "retired the surface, then the device, then the messenger, then the instance, with every Vulkan call on the owner's thread" $
    on outcome $ \facts → do
      callNames facts `shouldSatisfy` ordered ["vkDestroySurfaceKHR", "vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]
      oneOwnerThread facts

  it "reached a verdict after the last callback with no issue and no error" $
    on outcome clean

-- ---------------------------------------------------------------------------
-- Helpers

on ∷ SurfaceFreeOutcome → (SurfaceFreeFacts → Expectation) → Expectation
on = \case
  SurfaceFreeFailed reason → const (expectationFailure (Text.unpack reason))
  SurfaceFreeRecorded facts → ($ facts)

callNames ∷ SurfaceFreeFacts → [Text]
callNames facts = map (.callName) (factsCalls facts)

-- | The device was enumerated and created right after the instance and its
-- messenger, before anything else native.
deviceFirst ∷ SurfaceFreeFacts → Expectation
deviceFirst facts =
  take 4 [name | name ← callNames facts, name `notElem` ["vkEnumerateInstanceExtensionProperties"]]
    `shouldBe` ["vkCreateInstance", "vkCreateDebugUtilsMessengerEXT", "vkEnumeratePhysicalDevices", "vkCreateDevice"]

-- | The thread the device was created on.
ownerThread ∷ SurfaceFreeFacts → (ThreadId → Expectation) → Expectation
ownerThread facts check' = case [call.callHaskellThread | call ← factsCalls facts, call.callName == "vkCreateDevice"] of
  [owner] → check' owner
  other → expectationFailure ("expected one device creation, but " <> show (length other))

oneOwnerThread ∷ SurfaceFreeFacts → Expectation
oneOwnerThread facts = do
  let threads = nub (map (.callHaskellThread) (vulkanCalls facts))
  length threads `shouldBe` 1
  threads `shouldSatisfy` notElem (factsMainThread facts)

clean ∷ SurfaceFreeFacts → Expectation
clean facts = do
  fmap verdictIssues (factsVerdict facts) `shouldBe` Just []
  factsErrors facts `shouldBe` []

-- | Whether these names occur in this order among the calls.
ordered ∷ [Text] → [Text] → Bool
ordered wanted calls = go wanted calls
  where
    go [] _ = True
    go (first : rest) remaining = case elemIndex first remaining of
      Nothing → False
      Just at → go rest (drop (at + 1) remaining)

stopWith ∷ Text → IO a
stopWith reason = throwIO (userError (Text.unpack reason))

-- | Wait for the transaction to answer something, for at most this many
-- seconds.
awaitWithin ∷ Double → Text → STM (Maybe a) → IO a
awaitWithin seconds what transaction = do
  expired ← registerDelay (round (seconds * 1000000))
  atomically ((transaction >>= maybe retry (pure . Just)) `orElse` (Nothing <$ (readTVar expired >>= check)))
    >>= maybe (stopWith (what <> " did not happen within " <> tshow seconds <> " seconds")) pure

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
