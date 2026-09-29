{-# LANGUAGE OverloadedRecordDot #-}

-- | VK-17's required native profile (@vk17-one-slot@, @vk17-two-slots@): the
-- triangle sample's renderer ("Hetoimasia.Sample.Triangle") in two windows
-- sharing one device, through the production host with verification capture
-- on, on private roots in a child process of its own — one child with one
-- frame slot and one with two.
--
-- The host is the production composition — the loader integration, the
-- validation layer with synchronization validation, the diagnostic lifetime,
-- the protected window host and its graphics owner — built by the package's
-- private sublibrary with capture on ('withVulkanOwnerHostAs' 'CaptureOn'),
-- and driven by 'runVulkanOwnerLoop' over two mapped windows that request no
-- focus. The renderer is the sample's own, unchanged; only this suite reaches
-- the capture.
--
-- 1. Each window's frame is captured, and its clear and triangle checked.
-- 2. The first window is resized through its command port. Once its target's
--    active generation is the one built at the new extent, a frame of it is
--    captured and checked at that extent.
-- 3. The first-created window is closed. Once its target has retired, a frame
--    of the second is captured and checked: the second keeps rendering.
-- 4. The loop finishes and the host exits through D-33.
--
-- Each captured frame is checked at a clear-background point and at the
-- triangle's centroid, within a tolerance — never a whole-image hash — beside
-- that frame's own acquisition, submission, presentation and present-fence
-- retirement. The profile also asserts the frame budget it ran with, that
-- every generation was an unclipped transfer source, that every Vulkan call
-- ran on the graphics owner's thread and every surface was created on the
-- main thread, and a verdict, read after the last callback, with no issue and
-- no error. It infers no refresh cadence, vertical blank or pacing from any
-- timing.
module Test.GPU.Vulkan.Native.Triangle
  ( ProfileOutcome (..)
  , runProfile
  , profileSection
  , spec
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM (STM, atomically, check, modifyTVar', newTVarIO, orElse, readTVar, readTVarIO, registerDelay, retry, writeTVar)
import Control.Exception (SomeException, displayException, throwIO, try)
import Control.Monad (forM, forM_, when)
import Data.Bits ((.&.))
import qualified Data.ByteString as ByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (nub)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock (addUTCTime, diffUTCTime, getCurrentTime)
import Data.Word (Word32, Word8)
import Numeric.Natural (Natural)
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
import Hetoimasia.GLFW.Command (SubmitResult (..), setWindowSizeCommand, submitWindowCommand)
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GLFW.Window (Extent (..), WindowConfig (..), hiddenTestWindowConfig)
import Hetoimasia.GPU.Model (modelBudgets)
import Hetoimasia.GPU.Model.Budget (BudgetRequest (..), defaultBudgetRequest, frameSlotLimit, validateBudgets)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.Diagnostics (CaptureConfig (..), DiagnosticVerdict (..), defaultCaptureConfig, verdictIssues)
import Hetoimasia.GPU.Vulkan.GLFW
  ( FrameEvent (..)
  , Readiness (..)
  , VulkanHandover (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , VulkanRenderer (..)
  , FrameRequest (..)
  , constructPipeline
  , constructPipelineLayout
  , handOverVulkanTarget
  , readReadiness
  , readVulkanGenerations
  , readVulkanModel
  , readVulkanTargets
  , runVulkanOwnerLoop
  , vulkanHostConfig
  )
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller
  ( CaptureMode (CaptureOn)
  , CaptureOutcome (..)
  , CaptureTicket
  , CapturedFrame (..)
  , requestVulkanCapture
  , takeVulkanCapture
  )
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Production (withVulkanOwnerHostAs)
import Hetoimasia.GPU.Vulkan.Native.Generations (GenerationView (..), TargetGenerationsView (..))
import Hetoimasia.GPU.Vulkan.Native.Presentation (GenerationPlan (..), SurfaceExtent (..), formatB8G8R8A8Srgb, formatR8G8B8A8Srgb, imageUsageTransferSource)
import Hetoimasia.Runtime.GLFW
  ( AttachmentId
  , CloseStart (..)
  , ScheduledStep (..)
  , TargetStanding (..)
  , UpdateSchedule (..)
  , closeHostWindow
  , defaultHostConfig
  , defaultScheduledHooks
  , graphicsAttachment
  , hostCommandPort
  , hostWindowIdentities
  , readTargetStanding
  , runGraphicsOwnerApplication
  )
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Sample.Triangle (Builders (..), Triangle, drawTriangle, newTriangle, triangleFormats)
import Hetoimasia.Sample.Triangle.Geometry (clearColour, interior, triangleColour)
import Test.GPU.Vulkan.Native.Environment (validationFeatures)
import Test.Vulkan.Proof.Journal (Journal, heading, note)
import Test.Vulkan.Proof.Roots (NativeCall (..), nativeCallObserver)

-- | How far each channel may be from its expected value: rounding in the
-- encoding, and nothing else.
tolerance ∷ Int
tolerance = 6

-- | One of the profile's checked frames.
data Checked = Checked
  { checkedStep ∷ !Text
    -- ^ Which step of the profile captured it.
  , checkedAttachment ∷ !AttachmentId
  , checkedOutcome ∷ !CaptureOutcome
  , checkedActiveExtent ∷ !(Maybe SurfaceExtent)
    -- ^ The extent of the target's active generation when it was asked for.
  }

data ProfileFacts = ProfileFacts
  { factsSlots ∷ !Natural
    -- ^ The frame budget the model ran with.
  , factsChecked ∷ ![Checked]
  , factsResizedFrom ∷ !(Maybe SurfaceExtent)
  , factsFirstRetired ∷ !Bool
    -- ^ Whether the first window's target had retired before the second's
    -- last capture was asked for.
  , factsPlans ∷ ![(Natural, Bool)]
    -- ^ Every generation's image usage and whether it was clipped, as seen.
  , factsFormats ∷ ![Word32]
  , factsEvents ∷ ![FrameEvent]
  , factsCalls ∷ ![NativeCall]
  , factsMainThread ∷ !ThreadId
  , factsVerdict ∷ !(Maybe DiagnosticVerdict)
  , factsErrors ∷ ![Text]
  , factsSeconds ∷ !Double
  }

data ProfileOutcome
  = ProfileFailed !Natural !Text
  | ProfileRecorded !ProfileFacts

-- | The step the composed loop's update opportunity is in.
data Step
  = Starting
  | CapturingBoth
  | Resizing !SurfaceExtent
    -- ^ The first target's active extent when the resize was asked for.
  | CapturingResized
  | Closing
  | CapturingSecond
  | Settling
    -- ^ Every capture is in; the presentations made retire.
  | Done

-- | Run one profile, with this many frame slots, on the calling thread, which
-- must be the process main thread.
runProfile ∷ Natural → Journal → IO ProfileOutcome
runProfile slots journal = do
  heading journal ("VK-17: the triangle sample in two windows, resized and closed, with " <> tshow slots <> " frame slot(s)")
  started ← getCurrentTime
  recorded ← newIORef []
  events ← newTVarIO []
  logged ← newTVarIO []
  verdictHeld ← newIORef Nothing
  factsHeld ← newIORef Nothing
  triangle ← newTriangle
  scene ← prepare ()
  outcome ← try @SomeException $ do
    budgets ← either (stopWith . tshow) pure (validateBudgets defaultBudgetRequest {requestedFrameSlots = fromIntegral slots})
    let window name = (hiddenTestWindowConfig name 160 120) {windowVisible = True}
        host = defaultHostConfig [window "hetoimasia VK-17 first", window "hetoimasia VK-17 second"]
        logger = recordingLogger (\entry → atomically (modifyTVar' logged (entry :)))
        config =
          (vulkanHostConfig host defaultCaptureConfig {captureTextBudget = 16384} budgets scene)
            { vulkanLayers = ["VK_LAYER_KHRONOS_validation"]
            , vulkanValidationFeatures = validationFeatures
            , vulkanObserver = nativeCallObserver recorded
            , vulkanFrameObserver = \event → atomically (modifyTVar' events (event :))
            , vulkanRenderer = triangleRenderer triangle
            }
    withLoaderIntegration $ \integration →
      runGraphicsOwnerApplication
        (withLoggingLifetime logger)
        "vulkan-native-vk17-profile"
        ( \_ use → do
            (result, verdict) ← withVulkanOwnerHostAs CaptureOn logger integration config use
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
  formats ← triangleFormats triangle
  let errors = [maybe "" id (Map.lookup "message" entry.entryFields) | entry ← entries, Map.lookup "severity" entry.entryFields == Just "error"]
  case outcome of
    Left failure → pure (ProfileFailed slots (Text.pack (displayException failure)))
    Right () →
      readIORef factsHeld >>= \case
        Nothing → pure (ProfileFailed slots "the loop returned without its facts")
        Just partial → do
          forM_ (factsChecked partial) $ \checked →
            note journal (checkedStep checked <> ": " <> describeOutcome (checkedOutcome checked))
          pure . ProfileRecorded $
            partial
              { factsFormats = formats
              , factsEvents = seen
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
      (firstWindow, _) ← case windows of
        [one, two] → pure (one, two)
        other → stopWith ("the host holds " <> tshow (length other) <> " windows, not two")
      services ← forM windows $ \window →
        handOverVulkanTarget vulkan window RequiredTarget >>= \case
          VulkanTargetHandedOver service → pure service
          other → stopWith ("a window was not handed over: " <> tshow other)
      forM_ services $ \service → do
        standing ← awaitWithin 10 "a target's admission" $
          readTargetStanding (vulkanGraphicsOwner vulkan) (graphicsAttachment service) >>= \case
            Just TargetConstructing → pure Nothing
            Nothing → pure Nothing
            Just other → pure (Just other)
        when (standing /= TargetUsable) (stopWith ("a target was not admitted: " <> tshow standing))
      (first, second) ← case map graphicsAttachment services of
        [one, two] → pure (one, two)
        _ → stopWith "two targets were not handed over"
      model ← atomically (readVulkanModel controller)
      step ← newTVarIO Starting
      tickets ← newTVarIO (Map.empty ∷ Map.Map AttachmentId (CaptureTicket, Text, Maybe SurfaceExtent))
      checked ← newTVarIO []
      plans ← newTVarIO []
      resizedFrom ← newTVarIO Nothing
      retiredFirst ← newTVarIO False
      let activeOf attachment = do
            view ← atomically (readVulkanGenerations controller attachment)
            pure $ do
              held ← view
              active ← viewActive held
              generation ← lookup active [(viewGeneration each, each) | each ← viewGenerations held]
              pure (planExtent (viewPlan generation))
          notePlans attachment = do
            view ← atomically (readVulkanGenerations controller attachment)
            forM_ (maybe [] viewGenerations view) $ \generation →
              atomically (modifyTVar' plans (nub . ((fromIntegral (planUsage (viewPlan generation)), planClipped (viewPlan generation)) :)))
          ask label attachment = do
            active ← activeOf attachment
            atomically (requestVulkanCapture controller attachment) >>= \case
              Right ticket → atomically (modifyTVar' tickets (Map.insert attachment (ticket, label, active)))
              Left refusal → stopWith ("a capture was refused: " <> tshow refusal)
          -- Take every outcome that has settled; answer whether none is
          -- still awaited.
          collect = do
            held ← Map.toList <$> readTVarIO tickets
            forM_ held $ \(attachment, (ticket, label, active)) →
              atomically (takeVulkanCapture controller ticket) >>= \case
                Nothing → pure ()
                Just outcome → atomically $ do
                  modifyTVar' tickets (Map.delete attachment)
                  modifyTVar' checked (<> [Checked label attachment outcome active])
            Map.null <$> readTVarIO tickets
          retired = do
            seen ← readTVarIO events
            let presented = [presentation | FramePresented _ _ presentation _ ← seen]
                done = [presentation | PresentationRetired presentation ← seen]
            pure (all (`elem` done) presented)
      deadline ← addUTCTime 20 <$> getCurrentTime
      runVulkanOwnerLoop vulkan control . defaultScheduledHooks quiet $ \_ → do
        now ← getCurrentTime
        when (now > deadline) (stopWith "the profile did not finish within 20 seconds")
        mapM_ notePlans [first, second]
        current ← readTVarIO step
        case current of
          Starting → do
            ready ← and <$> mapM (fmap (maybe False (const True)) . activeOf) [first, second]
            when ready $ do
              ask "both windows, first" first
              ask "both windows, second" second
              atomically (writeTVar step CapturingBoth)
          CapturingBoth → do
            done ← collect
            when done $
              activeOf first >>= \case
                Nothing → pure ()
                Just extent → do
                  submitWindowCommand (hostCommandPort windowHost) [("client", "vk17-profile")] (setWindowSizeCommand firstWindow (Extent 200 150)) >>= \case
                    SubmitAccepted _ → pure ()
                    other → stopWith ("the resize was not admitted: " <> tshow other)
                  atomically $ do
                    writeTVar resizedFrom (Just extent)
                    writeTVar step (Resizing extent)
          Resizing before → do
            -- The resized target's active generation is the one built at the
            -- new extent.
            activeOf first >>= \case
              Just extent | extent /= before → do
                ask "the first window, resized" first
                atomically (writeTVar step CapturingResized)
              _ → pure ()
          CapturingResized → do
            done ← collect
            when done $ do
              closeHostWindow windowHost firstWindow >>= \case
                CloseStarted → pure ()
                other → stopWith ("the first window's close did not start: " <> tshow other)
              atomically (writeTVar step Closing)
          Closing → do
            targets ← atomically (readVulkanTargets controller)
            when (first `notElem` map fst targets) $ do
              atomically (writeTVar retiredFirst True)
              ask "the second window, after the first closed" second
              atomically (writeTVar step CapturingSecond)
          CapturingSecond → do
            done ← collect
            when done (atomically (writeTVar step Settling))
          Settling → do
            done ← retired
            when done (atomically (writeTVar step Done))
          Done → pure ()
        ended ← readTVarIO step
        pure $ case ended of
          Done → FinishWith ()
          _ → ContinueWith NoUpdateDemand
      captured ← readTVarIO checked
      seenPlans ← readTVarIO plans
      from ← readTVarIO resizedFrom
      closed ← readTVarIO retiredFirst
      writeIORef factsHeld . Just $
        ProfileFacts
          { factsSlots = frameSlotLimit (modelBudgets model)
          , factsChecked = captured
          , factsResizedFrom = from
          , factsFirstRetired = closed
          , factsPlans = seenPlans
          , factsFormats = []
          , factsEvents = []
          , factsCalls = []
          , factsMainThread = main
          , factsVerdict = Nothing
          , factsErrors = []
          , factsSeconds = 0
          }
    quiet = recordingLogger (\_ → pure ())

-- | The 8-bit sRGB encoding a sRGB swapchain image stores for one linear
-- channel.
encoded ∷ Float → Word8
encoded linear = round (255 * max 0 (min 1 value))
  where
    value
      | linear <= 0.0031308 = 12.92 * linear
      | otherwise = 1.055 * linear ** (1 / 2.4) - 0.055

opaque ∷ (Float, Float, Float) → (Word8, Word8, Word8, Word8)
opaque (red, green, blue) = (encoded red, encoded green, encoded blue, 255)

-- | The pixel at this point of a captured frame, red, green, blue and alpha,
-- if its format is one the profile renders to.
pixelAt ∷ CapturedFrame → (Int, Int) → Maybe (Word8, Word8, Word8, Word8)
pixelAt frame (x, y)
  | offset + 4 > ByteString.length bytes = Nothing
  | capturedFormat frame == formatB8G8R8A8Srgb = Just (byte 2, byte 1, byte 0, byte 3)
  | capturedFormat frame == formatR8G8B8A8Srgb = Just (byte 0, byte 1, byte 2, byte 3)
  | otherwise = Nothing
  where
    bytes = capturedBytes frame
    SurfaceExtent width _ = capturedExtent frame
    offset = (y * fromIntegral width + x) * 4
    byte index = ByteString.index bytes (offset + index)

-- | A point inside the clear, clear of the triangle: near the top-left corner.
backgroundPoint ∷ SurfaceExtent → (Int, Int)
backgroundPoint (SurfaceExtent width height) = (fromIntegral width `div` 16, fromIntegral height `div` 16)

-- | The triangle's centroid, from the sample's own geometry.
trianglePoint ∷ SurfaceExtent → (Int, Int)
trianglePoint (SurfaceExtent width height) =
  let (x, y) = interior
   in (floor ((x + 1) / 2 * fromIntegral width), floor ((y + 1) / 2 * fromIntegral height))

near ∷ (Word8, Word8, Word8, Word8) → (Word8, Word8, Word8, Word8) → Bool
near (r, g, b, a) (r', g', b', a') = all (\(one, two) → abs (fromIntegral one - fromIntegral two) <= tolerance) [(r, r'), (g, g'), (b, b'), (a, a')]

describeOutcome ∷ CaptureOutcome → Text
describeOutcome = \case
  CaptureDelivered frame →
    "captured "
      <> tshow (capturedExtent frame)
      <> " in format "
      <> tshow (capturedFormat frame)
      <> "; background "
      <> tshow (pixelAt frame (backgroundPoint (capturedExtent frame)))
      <> ", triangle "
      <> tshow (pixelAt frame (trianglePoint (capturedExtent frame)))
  CaptureWithheld _ reason → "withheld: " <> tshow reason

-- | The record's section.
profileSection ∷ ProfileOutcome → [Text]
profileSection = \case
  ProfileFailed slots reason → ["", "## The profile with " <> tshow slots <> " frame slot(s) did not complete", "", reason]
  ProfileRecorded facts →
    [ ""
    , "## The triangle sample in two windows, with " <> tshow (factsSlots facts) <> " frame slot(s)"
    , ""
    ]
      <> [ "- " <> checkedStep checked <> ", " <> tshow (checkedAttachment checked) <> ": " <> describeOutcome (checkedOutcome checked)
         | checked ← factsChecked facts
         ]
      <> [ "- the first window was resized from " <> maybe "no extent" tshow (factsResizedFrom facts)
         , "- the first window's target had retired before the second's last capture: " <> tshow (factsFirstRetired facts)
         , "- generations seen (usage, clipped): " <> tshow (factsPlans facts)
         , "- color formats the sample built pipelines for: " <> tshow (factsFormats facts)
         , "- expected (red, green, blue, alpha) within " <> tshow tolerance <> ": background " <> tshow (opaque clearColour) <> ", triangle " <> tshow (opaque triangleColour)
         , "- Vulkan calls: " <> tshow (length (vulkanCalls facts)) <> ", on " <> tshow (length (nub (map (.callHaskellThread) (vulkanCalls facts)))) <> " thread(s)"
         , "- verdict issues: " <> maybe "no verdict" (tshow . verdictIssues) (factsVerdict facts)
         , "- error reports: " <> tshow (length (factsErrors facts))
         , "- seconds, from the loader integration to the verdict: " <> Text.pack (show (factsSeconds facts))
         ]

vulkanCalls ∷ ProfileFacts → [NativeCall]
vulkanCalls facts = [call | call ← factsCalls facts, "vk" `Text.isPrefixOf` call.callName]

spec ∷ Natural → ProfileOutcome → Spec
spec slots outcome = describe ("VK-17 required profile, " <> show slots <> " frame slot(s)") $ do
  it "ran with the frame budget it was given" $
    on outcome $ \facts → factsSlots facts `shouldBe` slots

  it "captured both windows, the first again at its new extent after the resize, and the second again after the first closed" $
    on outcome $ \facts → do
      map checkedStep (factsChecked facts) `shouldSatisfy` \steps →
        all (`elem` steps) ["both windows, first", "both windows, second", "the first window, resized", "the second window, after the first closed"]
      forM_ (factsChecked facts) $ \item → delivered item $ \frame →
        ByteString.length (capturedBytes frame) `shouldBe` (let SurfaceExtent width height = capturedExtent frame in fromIntegral (width * height * 4))

  it "found the clear at a background point and the sample's triangle at its centroid in every captured frame, within the tolerance" $
    on outcome $ \facts →
      forM_ (factsChecked facts) $ \item → delivered item $ \frame → do
        pixelAt frame (backgroundPoint (capturedExtent frame)) `shouldSatisfy` maybe False (near (opaque clearColour))
        pixelAt frame (trianglePoint (capturedExtent frame)) `shouldSatisfy` maybe False (near (opaque triangleColour))

  it "captured the resized window at the extent of the generation built after the resize, not the one before" $
    on outcome $ \facts →
      case [item | item ← factsChecked facts, checkedStep item == "the first window, resized"] of
        [item] → delivered item $ \frame → do
          Just (capturedExtent frame) `shouldBe` checkedActiveExtent item
          Just (capturedExtent frame) `shouldSatisfy` (/= factsResizedFrom facts)
        _ → expectationFailure "the resized window was not captured once"

  it "retired the first window's target before the second's last capture, which the second still rendered" $
    on outcome $ \facts → factsFirstRetired facts `shouldBe` True

  it "captured each from a frame it acquired, submitted, presented and saw retire on its own present fence" $
    on outcome $ \facts →
      forM_ (factsChecked facts) $ \item → delivered item $ \frame → do
        let seen = factsEvents facts
            slot = capturedFrame frame
        [image | FrameAcquired _ at image ← seen, at == slot, image == capturedImage frame] `shouldSatisfy` (not . null)
        [() | FrameSubmitted _ at _ ← seen, at == slot] `shouldSatisfy` (not . null)
        [presentation | FramePresented _ at presentation _ ← seen, at == slot] `shouldSatisfy` elem (capturedPresentation frame)
        [presentation | PresentationRetired presentation ← seen] `shouldSatisfy` elem (capturedPresentation frame)

  it "built every generation unclipped, as a transfer source" $
    on outcome $ \facts → do
      factsPlans facts `shouldSatisfy` (not . null)
      factsPlans facts `shouldSatisfy` all (\(usage, clipped) → fromIntegral usage .&. imageUsageTransferSource /= 0 && not clipped)

  it "made every Vulkan call on the graphics owner's thread, and every surface creation on the main thread" $
    on outcome $ \facts → do
      let threads = nub (map (.callHaskellThread) (vulkanCalls facts))
      length threads `shouldBe` 1
      threads `shouldSatisfy` notElem (factsMainThread facts)
      [call.callHaskellThread | call ← factsCalls facts, call.callName == "glfwCreateWindowSurface"] `shouldSatisfy` all (== factsMainThread facts)

  it "reached a verdict after the last callback with no issue and no error" $
    on outcome $ \facts → do
      fmap verdictIssues (factsVerdict facts) `shouldBe` Just []
      factsErrors facts `shouldBe` []
  where
    on = \case
      ProfileFailed _ reason → const (expectationFailure (Text.unpack reason))
      ProfileRecorded facts → ($ facts)
    delivered item check' = case checkedOutcome item of
      CaptureDelivered frame → check' frame
      other → expectationFailure (Text.unpack (checkedStep item) <> ": the capture was not delivered: " <> show other)

-- ---------------------------------------------------------------------------
-- Helpers

-- | The sample's drawing as the host's renderer, exactly as the sample's
-- executable hands it over: each frame's format and extent, and the two
-- constructions the host lends.
triangleRenderer ∷ Triangle → VulkanRenderer ()
triangleRenderer triangle = VulkanRenderer $ \_ request construction recorder →
  drawTriangle
    triangle
    (Builders (constructPipelineLayout construction) (constructPipeline construction))
    (requestFormat request)
    (requestExtent request)
    recorder

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
