{-# LANGUAGE OverloadedRecordDot #-}

-- | WL-4's connection-loss case (@wayland-connection-loss@): a compositor
-- ended while the production host is rendering to a Wayland surface on it, in
-- a private-roots child of its own. It runs only under the isolated
-- compositor's consent; under any other the parent reports it pending
-- ("Test.GPU.Vulkan.Native.Private").
--
-- The compositor the run's consent names serves every other case, so this one
-- starts a compositor of its own ("Test.GPU.Vulkan.Native.Compositor") and
-- points its session at it alone. The production composition — the loader
-- integration, the validation layer with synchronization validation, the
-- protected window host and its graphics owner — requests Wayland by name and
-- is driven by 'runVulkanOwnerLoop' over one visible window, whose target the
-- owner renders with the configuration's clearing renderer.
--
-- 1. The window is asked for a frame as soon as its last one was presented: a
--    continuous scene at the rate the owner presents it.
-- 2. Once a presentation has been observed retiring on its own present fence,
--    and with a frame asked for, the loop's update ends the compositor:
--    @SIGTERM@ and its exit. Termination follows observed rendering, never an
--    elapsed time.
-- 3. The loop keeps asking for frames. Its next event processing finds the
--    connection gone and raises 'ConnectionFailed', which ends the loop; the
--    host's protected exit then retires the target, the device, the messenger
--    and the instance, and terminates the session, under the Wayland
--    qualification design's D-10: the loss is terminal and nothing
--    reconnects.
--
-- The case asserts that rendering was verified before the loss; that the
-- session ended with the loss, a transport closure or protocol failure, as the
-- application's failure; that no surface was created after it; that every
-- presentation-fence retirement and every submission completion recorded, at
-- any time, belongs to a presentation or submission the owner actually made —
-- a loss is never recorded as a signalled fence, a completion or a device loss
-- — and that the teardown completed: every swapchain created was destroyed,
-- the roots in dependency order with the instance last, and a verdict, read
-- after the last callback, with no issue and no error, so no dependency was
-- released under work the validation layer saw outstanding. Genuine completion
-- the driver reports after the loss is kept, never discarded. The parent
-- enforces the child's deadline from outside; an expiry or a forced
-- termination fails the case.
module Test.GPU.Vulkan.Native.ConnectionLoss
  ( LossOutcome (..)
  , runConnectionLoss
  , lossSection
  , spec
  ) where

import Control.Concurrent.STM (STM, atomically, check, modifyTVar', newTVarIO, orElse, readTVar, readTVarIO, registerDelay, retry, writeTVar)
import Control.Exception (SomeException, displayException, fromException, throwIO, try)
import Control.Monad (forM_, when)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isSubsequenceOf)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock (addUTCTime, getCurrentTime)
import System.Exit (ExitCode)
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
import Hetoimasia.GLFW.Command (clientDemandPublisher)
import Hetoimasia.GLFW.Demand (immediateDemand, publishDemand)
import Hetoimasia.GLFW.Session (Backend (Wayland), ConnectionCause (..), ConnectionFailed (..))
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GLFW.Window (WindowConfig (..), hiddenTestWindowConfig)
import Hetoimasia.GPU.Model.Budget (defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.Diagnostics (CaptureConfig (..), DiagnosticVerdict (..), defaultCaptureConfig, diagnosticVerdict, verdictIssues)
import Hetoimasia.GPU.Vulkan.GLFW
  ( FrameEvent (..)
  , Readiness (..)
  , VulkanHandover (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , handOverVulkanTarget
  , readReadiness
  , runVulkanOwnerLoop
  , vulkanHostConfig
  , withVulkanOwnerHost
  )
import Hetoimasia.Runtime.GLFW
  ( ScheduledStep (..)
  , TargetStanding (..)
  , UpdateSchedule (..)
  , defaultHostConfig
  , defaultScheduledHooks
  , graphicsAttachment
  , hostWindowClient
  , hostWindowIdentities
  , readTargetStanding
  , runGraphicsOwnerApplication
  )
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Test.GPU.Vulkan.Native.Compositor (Compositor, compositorVersion, endCompositor, enterPrivate, withPrivateCompositor)
import Test.GPU.Vulkan.Native.Environment (validationFeatures)
import Test.GPU.Vulkan.Native.Platform (notePlatform, requestingBackend)
import Test.Vulkan.Proof.Journal (Journal, heading, note)
import Test.Vulkan.Proof.Roots (NativeCall (..), nativeCallObserver)

-- | The moment the compositor was ended: how far each record had reached.
data Loss = Loss
  { lossEvents ∷ !Int
    -- ^ How many frame events had been recorded.
  , lossCalls ∷ !Int
    -- ^ How many native calls had returned.
  , lossExit ∷ !ExitCode
    -- ^ How the compositor exited.
  }

-- | What the case saw.
data LossFacts = LossFacts
  { factsCompositor ∷ !String
  , factsLoss ∷ !Loss
  , factsFailure ∷ !Text
    -- ^ How the application ended, as displayed.
  , factsConnection ∷ !(Maybe ConnectionFailed)
    -- ^ The loss, when the application's failure was it.
  , factsEvents ∷ ![FrameEvent]
    -- ^ Every frame event, oldest first.
  , factsCalls ∷ ![NativeCall]
    -- ^ Every native call, in the order they returned.
  , factsVerdict ∷ !(Maybe DiagnosticVerdict)
  , factsErrors ∷ ![Text]
  }

data LossOutcome
  = LossFailed !Text
  | LossRecorded !LossFacts

-- | Run the case on the calling thread, which must be the process main thread.
runConnectionLoss ∷ Journal → IO LossOutcome
runConnectionLoss journal = do
  heading journal "WL-4: the compositor ended while the production host renders to a Wayland surface"
  outcome ← try @SomeException . withPrivateCompositor $ \compositor → do
    enterPrivate compositor
    note journal ("started a private compositor, " <> Text.pack (compositorVersion compositor) <> ", and pointed this process's sessions at it alone")
    session journal compositor
  case outcome of
    Left failure → pure (LossFailed (Text.pack (displayException failure)))
    Right recorded → pure recorded

session ∷ Journal → Compositor → IO LossOutcome
session journal compositor = do
  recorded ← newIORef []
  events ← newTVarIO []
  logged ← newTVarIO []
  verdictHeld ← newIORef Nothing
  lossHeld ← newIORef Nothing
  scene ← prepare ()
  budgets ← either (stopWith . tshow) pure (validateBudgets defaultBudgetRequest)
  let window = (hiddenTestWindowConfig "hetoimasia WL-4 connection loss" 160 120) {windowVisible = True}
      host = requestingBackend (Just Wayland) (defaultHostConfig [window])
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
          "vulkan-native-wl4-connection-loss"
          ( \_ use → do
              (result, verdict) ← withVulkanOwnerHost logger integration config use
              writeIORef verdictHeld (Just verdict)
              pure result
          )
          vulkanWindowHost
          (\vulkan _ → pure vulkan)
          (\vulkan control → body vulkan control recorded events lossHeld)
  -- The host returns its verdict only when it returns; a host the loss ended
  -- attaches it to the failure instead.
  verdict ← maybe (either diagnosticVerdict (const Nothing) outcome) Just <$> readIORef verdictHeld
  calls ← reverse <$> readIORef recorded
  entries ← readTVarIO logged
  seen ← reverse <$> readTVarIO events
  let errors = [maybe "" id (Map.lookup "message" entry.entryFields) | entry ← entries, Map.lookup "severity" entry.entryFields == Just "error"]
  readIORef lossHeld >>= \case
    Nothing → pure (LossFailed ("the compositor was never ended: " <> either (Text.pack . displayException) (const "the loop returned") outcome))
    Just loss → do
      let failure = either (Text.pack . displayException) (const "the application returned without a failure") outcome
          connection = either fromException (const Nothing) outcome
      note journal ("the compositor exited " <> tshow (lossExit loss) <> " after " <> tshow (lossEvents loss) <> " frame events")
      note journal ("the application ended: " <> failure)
      note journal
        ( "presented "
            <> tshow (length [() | FramePresented {} ← seen])
            <> " frames; "
            <> tshow (length [() | PresentationRetired _ ← seen])
            <> " presentations retired on their present fences"
        )
      pure . LossRecorded $
        LossFacts
          { factsCompositor = compositorVersion compositor
          , factsLoss = loss
          , factsFailure = failure
          , factsConnection = connection
          , factsEvents = seen
          , factsCalls = calls
          , factsVerdict = verdict
          , factsErrors = errors
          }
  where
    body vulkan control recorded events lossHeld = do
      notePlatform journal (Just Wayland)
      let controller = vulkanController vulkan
          windowHost = vulkanWindowHost vulkan
      readiness ← awaitWithin 10 "the owner's startup" $
        readReadiness controller >>= \case
          RootsPending → pure Nothing
          other → pure (Just other)
      case readiness of
        RootsFailed reason → stopWith ("the owner's startup failed: " <> reason)
        _ → pure ()
      windowId ←
        atomically (hostWindowIdentities windowHost) >>= \case
          [one] → pure one
          other → stopWith ("the host holds " <> tshow (length other) <> " windows, not one")
      service ←
        handOverVulkanTarget vulkan windowId RequiredTarget >>= \case
          VulkanTargetHandedOver service → pure service
          other → stopWith ("the window was not handed over: " <> tshow other)
      standing ← awaitWithin 10 "the target's admission" $
        readTargetStanding (vulkanGraphicsOwner vulkan) (graphicsAttachment service) >>= \case
          Just TargetConstructing → pure Nothing
          Nothing → pure Nothing
          Just other → pure (Just other)
      when (standing /= TargetUsable) (stopWith ("the target was not admitted: " <> tshow standing))
      asked ← newTVarIO (0 ∷ Int)
      let presented = length . filter isPresented <$> readTVarIO events
          -- Ask for a frame as soon as the last one asked for was presented.
          demand = do
            count ← presented
            wanted ← readTVarIO asked
            when (count >= wanted) $ do
              client ← atomically (hostWindowClient windowHost windowId) >>= maybe (stopWith "the window has no client") pure
              _ ← publishDemand (clientDemandPublisher client) immediateDemand
              atomically (writeTVar asked (count + 1))
          -- Rendering is verified once a presentation has retired on its own
          -- present fence.
          verified = do
            seen ← readTVarIO events
            pure (not (null [() | PresentationRetired presentation ← seen, presentation `elem` [made | FramePresented _ _ made _ ← seen]]))
      deadline ← addUTCTime 15 <$> getCurrentTime
      runVulkanOwnerLoop vulkan control . defaultScheduledHooks quiet $ \_ → do
        now ← getCurrentTime
        when (now > deadline) (stopWith "the loss was not confirmed within 15 seconds")
        demand
        ended ← readIORef lossHeld
        ready ← verified
        case ended of
          Nothing | ready → do
            -- A frame is asked for, and the compositor goes while the owner
            -- renders it.
            seen ← length <$> readTVarIO events
            calls ← length <$> readIORef recorded
            exit ← endCompositor compositor
            writeIORef lossHeld (Just (Loss seen calls exit))
          _ → pure ()
        pure (ContinueWith NoUpdateDemand)
    quiet = recordingLogger (\_ → pure ())
    isPresented = \case
      FramePresented {} → True
      _ → False

-- | The record's section.
lossSection ∷ LossOutcome → [Text]
lossSection = \case
  LossFailed reason → ["", "## The connection-loss case did not complete", "", reason]
  LossRecorded facts →
    [ ""
    , "## The compositor ended during rendering"
    , ""
    , "- compositor: " <> Text.pack (factsCompositor facts) <> ", headless, private to this child; exited " <> tshow (lossExit (factsLoss facts))
    , "- before the loss: " <> tshow (length (before facts)) <> " frame events, " <> tshow (presentedIn (before facts)) <> " presentations made and " <> tshow (retiredIn (before facts)) <> " retired on their present fences"
    , "- after the loss: " <> tshow (length (after facts)) <> " frame events, " <> tshow (presentedIn (after facts)) <> " presentations made and " <> tshow (retiredIn (after facts)) <> " retired on their present fences"
    , "- the application ended: " <> factsFailure facts
    , "- the loss: " <> maybe "not a connection failure" (\failure → tshow (connectionCause failure) <> ", " <> tshow (connectionBoundary failure)) (factsConnection facts)
    , "- surfaces created after the loss: " <> tshow (length [() | call ← callsAfter facts, call.callName == "glfwCreateWindowSurface"])
    , "- swapchains created and destroyed: " <> tshow (countCalls "vkCreateSwapchainKHR" facts) <> " and " <> tshow (countCalls "vkDestroySwapchainKHR" facts)
    , "- verdict issues: " <> maybe "no verdict" (tshow . verdictIssues) (factsVerdict facts)
    , "- error reports: " <> tshow (length (factsErrors facts))
    ]
  where
    presentedIn seen = length [() | FramePresented {} ← seen]
    retiredIn seen = length [() | PresentationRetired _ ← seen]

before, after ∷ LossFacts → [FrameEvent]
before facts = take (lossEvents (factsLoss facts)) (factsEvents facts)
after facts = drop (lossEvents (factsLoss facts)) (factsEvents facts)

callsAfter ∷ LossFacts → [NativeCall]
callsAfter facts = drop (lossCalls (factsLoss facts)) (factsCalls facts)

countCalls ∷ Text → LossFacts → Int
countCalls name facts = length [() | call ← factsCalls facts, call.callName == name, call.callRaised == Nothing]

spec ∷ LossOutcome → Spec
spec outcome = describe "WL-4 connection loss during rendering" $ do
  it "presented to the Wayland surface, with a presentation retired on its own present fence, before the compositor was ended" $
    on outcome $ \facts →
      [presentation | PresentationRetired presentation ← before facts, presentation `elem` [made | FramePresented _ _ made _ ← before facts]]
        `shouldSatisfy` (not . null)

  it "ended the session with the confirmed loss as the application's failure, and reconnected nothing" $
    on outcome $ \facts → do
      case factsConnection facts of
        Nothing → expectationFailure ("the application did not end with the connection's loss: " <> Text.unpack (factsFailure facts))
        Just failure → connectionCause failure `shouldSatisfy` confirmed
      [call.callName | call ← callsAfter facts, call.callName == "glfwCreateWindowSurface"] `shouldBe` []

  it "recorded no fence, completion or device loss for work the lost connection interrupted" $
    on outcome $ \facts → do
      let seen = factsEvents facts
      forM_ (zip [0 ∷ Int ..] seen) $ \(index, event) → case event of
        PresentationRetired presentation →
          [() | FramePresented _ _ made _ ← take index seen, made == presentation] `shouldSatisfy` (not . null)
        SubmissionCompleted submission →
          [() | FrameSubmitted _ _ made ← take index seen, made == submission] `shouldSatisfy` (not . null)
        _ → pure ()
      Text.toLower (factsFailure facts) `shouldSatisfy` (not . Text.isInfixOf "device lost")

  it "retired every generation, the surface and the roots under the protected boundary, with no issue and no error" $
    on outcome $ \facts → do
      countCalls "vkDestroySwapchainKHR" facts `shouldBe` countCalls "vkCreateSwapchainKHR" facts
      let names = map (.callName) (factsCalls facts)
      names `shouldSatisfy` isSubsequenceOf ["vkDestroySurfaceKHR", "vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]
      [name | name ← names, "vk" `Text.isPrefixOf` name] `shouldSatisfy` (\vulkan → not (null vulkan) && last vulkan == "vkDestroyInstance")
      fmap verdictIssues (factsVerdict facts) `shouldBe` Just []
      factsErrors facts `shouldBe` []
  where
    on = \case
      LossFailed reason → const (expectationFailure (Text.unpack reason))
      LossRecorded facts → ($ facts)
    -- The probe found the connection gone; a probe that could not establish
    -- the status at all is not a confirmed loss.
    confirmed = \case
      TransportClosed _ → True
      ProtocolFailure → True
      ProbeFailure _ → False

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
