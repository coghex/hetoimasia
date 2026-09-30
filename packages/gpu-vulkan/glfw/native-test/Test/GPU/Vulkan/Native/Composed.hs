{-# LANGUAGE OverloadedRecordDot #-}

-- | VK-16's native case (@vk16-composed@): two attached targets rendered
-- through the composed loop, on private roots in a child process of its own.
--
-- The production composition — 'withVulkanOwnerHost' over the loader
-- integration, with the validation layer and synchronization validation — is
-- driven by 'runVulkanOwnerLoop', the main-thread loop adapter, over two
-- visible windows. Nothing is published by hand: the adapter publishes each
-- window's observation and its captured render demand every turn, and the
-- graphics owner renders each frame on its own thread with the configuration's
-- clearing renderer.
--
-- 1. Both windows are asked for frames, each as soon as its last one was
--    presented, until each has presented three.
-- 2. The first window is hidden through its command port. Its target is
--    suspended in the model — its eligibility is the main thread's observation
--    of the hidden window — while the second keeps presenting three more
--    frames, and the first presents none.
-- 3. The first window is shown again, and presents again.
-- 4. The loop finishes and the host exits through D-33: the owner retires
--    both targets once every presentation of theirs has retired on its present
--    fence, then the device, the messenger and the instance, and is joined
--    before the windows go.
--
-- The case asserts the counts, that every Vulkan call ran on the graphics
-- owner's thread and no other while every surface was created on the main
-- thread, that every presentation's retirement was observed through its own
-- present fence before the device went, the destruction order, and a verdict,
-- read after the last callback, with no issue at all.
module Test.GPU.Vulkan.Native.Composed
  ( ComposedOutcome (..)
  , runComposed
  , composedSection
  , spec
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM (STM, atomically, check, modifyTVar', newTVarIO, orElse, readTVar, readTVarIO, registerDelay, retry, writeTVar)
import Control.Exception (SomeException, displayException, throwIO, try)
import Control.Monad (forM_, when)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isSubsequenceOf, nub)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock (addUTCTime, diffUTCTime, getCurrentTime)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

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
import Hetoimasia.GLFW.Command (SubmitResult (..), clientDemandPublisher, hideWindowCommand, showWindowCommand, submitWindowCommand)
import Hetoimasia.GLFW.Demand (immediateDemand, publishDemand)
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GLFW.Window (WindowConfig (..), hiddenTestWindowConfig)
import Hetoimasia.GPU.Model (TargetPhase (..), TargetView (..), targetView)
import Hetoimasia.GPU.Model.Budget (defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.Diagnostics (CaptureConfig (..), DiagnosticVerdict (..), defaultCaptureConfig, verdictIssues)
import Hetoimasia.GPU.Vulkan.GLFW
  ( FrameEvent (..)
  , Readiness (..)
  , VulkanHandover (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , handOverVulkanTarget
  , readReadiness
  , readVulkanModel
  , readVulkanTargets
  , runVulkanOwnerLoop
  , vulkanHostConfig
  , withVulkanOwnerHost
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (RootTargetView (..))
import Hetoimasia.Runtime.GLFW
  ( ScheduledStep (..)
  , TargetStanding (..)
  , UpdateSchedule (..)
  , defaultHostConfig
  , defaultScheduledHooks
  , graphicsAttachment
  , hostCommandPort
  , hostWindowClient
  , hostWindowIdentities
  , readTargetStanding
  , runGraphicsOwnerApplication
  )
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Test.GPU.Vulkan.Native.Environment (validationFeatures)
import Hetoimasia.GLFW.Session (Backend)
import Test.GPU.Vulkan.Native.Platform (requestingBackend)
import Test.Vulkan.Proof.Journal (Journal, heading, note)
import Test.Vulkan.Proof.Roots (NativeCall (..), nativeCallObserver)

-- | What the case saw.
data ComposedFacts = ComposedFacts
  { factsFirstFrames ∷ !(Int, Int)
    -- ^ Frames each target presented before the first window was hidden.
  , factsSuspended ∷ !Bool
    -- ^ Whether the hidden window's target was suspended in the model.
  , factsWhileHidden ∷ !(Int, Int)
    -- ^ Frames each presented while the first was hidden.
  , factsAfterShown ∷ !Int
    -- ^ Frames the first presented once shown again.
  , factsPresented ∷ !Int
  , factsRetired ∷ !Int
    -- ^ Presentations whose present fences were observed signalled.
  , factsCalls ∷ ![NativeCall]
  , factsMainThread ∷ !ThreadId
  , factsVerdict ∷ !(Maybe DiagnosticVerdict)
  , factsErrors ∷ ![Text]
  , factsSeconds ∷ !Double
  }

data ComposedOutcome
  = ComposedFailed !Text
  | ComposedRecorded !ComposedFacts

-- | The phase the composed loop's update opportunity is in.
data Phase
  = RenderingBoth
  | Hiding !(Int, Int)
    -- ^ The counts when the first window was asked to hide.
  | Hidden !(Int, Int)
  | Showing !Int
  | Done

-- | Run the case on the calling thread, which must be the process main thread.
runComposed ∷ Maybe Backend → Journal → IO ComposedOutcome
runComposed backend journal = do
  heading journal "VK-16: two targets rendered through the composed loop, one suspended and resumed while the other presents"
  started ← getCurrentTime
  recorded ← newIORef []
  events ← newTVarIO []
  logged ← newTVarIO []
  verdictHeld ← newIORef Nothing
  factsHeld ← newIORef Nothing
  scene ← prepare ()
  budgets ← either (stopWith . tshow) pure (validateBudgets defaultBudgetRequest)
  let window name = (hiddenTestWindowConfig name 160 120) {windowVisible = True}
      host = requestingBackend backend (defaultHostConfig [window "hetoimasia VK-16 first", window "hetoimasia VK-16 second"])
      logger = recordingLogger (\entry → atomically (modifyTVar' logged (entry :)))
      config =
        (vulkanHostConfig host defaultCaptureConfig {captureTextBudget = 16384} budgets scene)
          { vulkanLayers = ["VK_LAYER_KHRONOS_validation"]
          , vulkanValidationFeatures = validationFeatures
          , vulkanObserver = nativeCallObserver recorded
          , vulkanFrameObserver = \event → atomically (modifyTVar' events (event :))
          }
  outcome ←
    try @SomeException $
      withLoaderIntegration $ \integration →
        runGraphicsOwnerApplication
          (withLoggingLifetime logger)
          "vulkan-native-vk16-composed"
          ( \_ use → do
              (result, verdict) ← withVulkanOwnerHost logger integration config use
              writeIORef verdictHeld (Just verdict)
              pure result
          )
          vulkanWindowHost
          (\vulkan _ → pure vulkan)
          (\vulkan control → body vulkan control events factsHeld)
  finished ← getCurrentTime
  verdict ← readIORef verdictHeld
  calls ← reverse <$> readIORef recorded
  entries ← readTVarIO logged
  seen ← reverse <$> readTVarIO events
  let errors = [maybe "" id (Map.lookup "message" entry.entryFields) | entry ← entries, Map.lookup "severity" entry.entryFields == Just "error"]
      presented = length [() | FramePresented {} ← seen]
      retired = length [() | PresentationRetired _ ← seen]
  case outcome of
    Left failure → pure (ComposedFailed (Text.pack (displayException failure)))
    Right () →
      readIORef factsHeld >>= \case
        Nothing → pure (ComposedFailed "the loop returned without its facts")
        Just partial → do
          note journal ("presented " <> tshow presented <> " frames; " <> tshow retired <> " presentations retired on their present fences")
          pure . ComposedRecorded $
            partial
              { factsPresented = presented
              , factsRetired = retired
              , factsCalls = calls
              , factsVerdict = verdict
              , factsErrors = errors
              , factsSeconds = realToFrac (diffUTCTime finished started)
              }
  where
    body vulkan control events factsHeld = do
      main ← myThreadId
      let controller = vulkanController vulkan
          windowHost = vulkanWindowHost vulkan
      readiness ← awaitWithin 10 "the owner's startup" $
        readReadiness controller >>= \case
          RootsPending → pure Nothing
          other → pure (Just other)
      case readiness of
        RootsFailed reason → stopWith ("the owner's startup failed: " <> reason)
        _ → pure ()
      windows ← atomically (hostWindowIdentities windowHost)
      (first, second) ← case windows of
        [one, two] → pure (one, two)
        other → stopWith ("the host holds " <> tshow (length other) <> " windows, not two")
      let handOver window =
            handOverVulkanTarget vulkan window RequiredTarget >>= \case
              VulkanTargetHandedOver service → pure service
              other → stopWith ("a window was not handed over: " <> tshow other)
      firstService ← handOver first
      secondService ← handOver second
      let services = [firstService, secondService]
          one = graphicsAttachment firstService
          two = graphicsAttachment secondService
      forM_ services $ \service → do
        standing ← awaitWithin 10 "a target's admission" $
          readTargetStanding (vulkanGraphicsOwner vulkan) (graphicsAttachment service) >>= \case
            Just TargetConstructing → pure Nothing
            Nothing → pure Nothing
            Just other → pure (Just other)
        when (standing /= TargetUsable) (stopWith ("a target was not admitted: " <> tshow standing))
      let presents attachment = length . filter (presentedTo attachment) <$> readTVarIO events
          presentedTo attachment = \case
            FramePresented at _ _ _ → at == attachment
            _ → False
          suspended attachment = do
            model ← readVulkanModel controller
            targets ← readVulkanTargets controller
            pure (or [viewTargetPhase held == TargetSuspended | (at, view) ← targets, at == attachment, Just held ← [targetView (targetViewIdentity view) model]])
          command window build =
            submitWindowCommand (hostCommandPort windowHost) [("client", "vk16-composed")] (build window) >>= \case
              SubmitAccepted _ → pure ()
              other → stopWith ("a window command was not admitted: " <> tshow other)
      asked ← newTVarIO (Map.fromList [(one, 0), (two, 0)])
      phase ← newTVarIO RenderingBoth
      -- Ask a window for a frame as soon as its last one was presented: a
      -- continuous scene at the rate the owner presents it.
      let demand window attachment = do
            presented ← presents attachment
            wanted ← Map.findWithDefault 0 attachment <$> readTVarIO asked
            when (presented >= wanted) $ do
              client ← atomically (hostWindowClient windowHost window) >>= maybe (stopWith "a window has no client") pure
              _ ← publishDemand (clientDemandPublisher client) immediateDemand
              atomically (modifyTVar' asked (Map.insert attachment (presented + 1)))
      deadline ← addUTCTime 15 <$> getCurrentTime
      runVulkanOwnerLoop vulkan control . defaultScheduledHooks quiet $ \_ → do
        now ← getCurrentTime
        when (now > deadline) $ do
          counts ← (,) <$> presents one <*> presents two
          note journal ("the composed loop reached its deadline having presented " <> tshow counts)
          stopWith "the composed loop did not finish within 15 seconds"
        demand first one
        demand second two
        current ← readTVarIO phase
        firstCount ← presents one
        secondCount ← presents two
        case current of
          RenderingBoth
            | firstCount >= 3 && secondCount >= 3 → do
                note journal ("both targets presented three frames " <> tshow (firstCount, secondCount) <> "; hiding the first window")
                command first hideWindowCommand
                atomically (writeTVar phase (Hiding (firstCount, secondCount)))
          -- Counted from the turn the suspension was seen: a frame the first
          -- target made before its hidden window's observation arrived was a
          -- visible window's.
          Hiding _ → do
            done ← atomically (suspended one)
            when done $ do
              note journal ("the first target is suspended at " <> tshow (firstCount, secondCount))
              atomically (writeTVar phase (Hidden (firstCount, secondCount)))
          Hidden (firstAt, secondAt)
            | secondCount >= secondAt + 3 → do
                writeIORef factsHeld . Just $
                  ComposedFacts
                    { factsFirstFrames = (firstAt, secondAt)
                    , factsSuspended = True
                    , factsWhileHidden = (firstCount - firstAt, secondCount - secondAt)
                    , factsAfterShown = 0
                    , factsPresented = 0
                    , factsRetired = 0
                    , factsCalls = []
                    , factsMainThread = main
                    , factsVerdict = Nothing
                    , factsErrors = []
                    , factsSeconds = 0
                    }
                note journal ("the second target presented three more frames " <> tshow (firstCount, secondCount) <> "; showing the first window")
                command first showWindowCommand
                atomically (writeTVar phase (Showing firstCount))
          Showing firstAt
            | firstCount > firstAt → do
                note journal ("the first target presented again " <> tshow (firstCount, secondCount))
                modifyIORef' factsHeld (fmap (\facts → facts {factsAfterShown = firstCount - firstAt}))
                atomically (writeTVar phase Done)
          _ → pure ()
        ended ← readTVarIO phase
        pure $ case ended of
          Done → FinishWith ()
          _ → ContinueWith NoUpdateDemand
    quiet = recordingLogger (\_ → pure ())

-- | The record's section.
composedSection ∷ ComposedOutcome → [Text]
composedSection = \case
  ComposedFailed reason → ["", "## The composed case did not complete", "", reason]
  ComposedRecorded facts →
    [ ""
    , "## Two targets through the composed loop"
    , ""
    , "- frames before the first window was hidden (first, second): " <> tshow (factsFirstFrames facts)
    , "- the hidden window's target was suspended: " <> tshow (factsSuspended facts)
    , "- frames while it was hidden (first, second): " <> tshow (factsWhileHidden facts)
    , "- frames the first presented once shown again: " <> tshow (factsAfterShown facts)
    , "- presentations made: " <> tshow (factsPresented facts) <> "; retired on their present fences: " <> tshow (factsRetired facts)
    , "- Vulkan calls: " <> tshow (length (vulkanCalls facts)) <> ", on " <> tshow (length (nub (map (.callHaskellThread) (vulkanCalls facts)))) <> " thread(s)"
    , "- verdict issues: " <> maybe "no verdict" (tshow . verdictIssues) (factsVerdict facts)
    , "- error reports: " <> tshow (length (factsErrors facts))
    , "- seconds, from the loader integration to the verdict: " <> Text.pack (show (factsSeconds facts))
    ]

vulkanCalls ∷ ComposedFacts → [NativeCall]
vulkanCalls facts = [call | call ← factsCalls facts, "vk" `Text.isPrefixOf` call.callName]

spec ∷ ComposedOutcome → Spec
spec outcome = describe "VK-16 composed loop" $ do
  it "rendered both targets through the adapter's publications, with nothing published by hand" $
    on outcome $ \facts → factsFirstFrames facts `shouldSatisfy` \(first, second) → first >= 3 && second >= 3

  it "suspended the hidden window's target while the other kept presenting, and presented to it none" $
    on outcome $ \facts → do
      factsSuspended facts `shouldBe` True
      fst (factsWhileHidden facts) `shouldBe` 0
      snd (factsWhileHidden facts) `shouldSatisfy` (>= 3)

  it "presented to the first target again once its window was shown" $
    on outcome $ \facts → factsAfterShown facts `shouldSatisfy` (>= 1)

  it "made every Vulkan call on the graphics owner's thread, and every surface creation on the main thread" $
    on outcome $ \facts → do
      let threads = nub (map (.callHaskellThread) (vulkanCalls facts))
      length threads `shouldBe` 1
      threads `shouldSatisfy` notElem (factsMainThread facts)
      [call.callHaskellThread | call ← factsCalls facts, call.callName == "glfwCreateWindowSurface"] `shouldSatisfy` all (== factsMainThread facts)

  it "observed every presentation's retirement through its present fence, and retired both targets and the roots in dependency order" $
    on outcome $ \facts → do
      factsRetired facts `shouldBe` factsPresented facts
      let names = map (.callName) (factsCalls facts)
      names `shouldSatisfy` isSubsequenceOf ["vkDestroySwapchainKHR", "vkDestroySurfaceKHR", "vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]
      length [() | "vkDestroySurfaceKHR" ← names] `shouldBe` 2
      [name | name ← dropWhile (/= "vkDestroyDevice") names, name == "vkQueuePresentKHR"] `shouldBe` []

  it "reached a verdict after the last callback with no issue and no error" $
    on outcome $ \facts → do
      fmap verdictIssues (factsVerdict facts) `shouldBe` Just []
      factsErrors facts `shouldBe` []
  where
    on = \case
      ComposedFailed reason → const (expectationFailure (Text.unpack reason))
      ComposedRecorded facts → ($ facts)

-- ---------------------------------------------------------------------------
-- Helpers

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
