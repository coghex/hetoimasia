{-# LANGUAGE OverloadedRecordDot #-}

-- | VK-19's native case (@vk19-capture@): a consumer's own triangle pipeline,
-- built through the production host's renderer over the embedded verification
-- shaders, captured from each of two targets, on private roots in a child
-- process of its own.
--
-- The production composition — the loader integration, the validation layer
-- with synchronization validation, the diagnostic lifetime, the protected
-- window host and its graphics owner — is built with verification capture on
-- ('withVulkanOwnerHostAs' 'CaptureOn', reachable only through the package's
-- private sublibrary) and driven by 'runVulkanOwnerLoop' over two mapped
-- windows that request no focus. The consumer's renderer builds a pipeline
-- layout and a pipeline for each frame's color format the first time it meets
-- it, clears to blue, and draws one orange triangle.
--
-- 1. Each target is asked for a capture; nothing else asks for a frame.
-- 2. The loop turns until both captures have settled, and every presentation
--    made has retired on its own present fence.
-- 3. The loop finishes and the host exits through D-33.
--
-- The case asserts, for each target, the captured frame's bytes at a known
-- clear-background point and a known triangle-interior point within a
-- tolerance — never a whole-image hash — beside that frame's own acquisition,
-- submission, presentation and present-fence retirement; that both targets'
-- generations were unclipped transfer sources; that every Vulkan call ran on
-- the graphics owner's thread; and a verdict, read after the last callback,
-- with no issue and no error. It infers no refresh cadence, vertical blank or
-- pacing from any timing.
module Test.GPU.Vulkan.Native.Capture
  ( CaptureCaseOutcome (..)
  , runCapture
  , captureSection
  , spec
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM (STM, atomically, check, modifyTVar', newTVarIO, orElse, readTVar, readTVarIO, registerDelay, retry)
import Control.Exception (SomeException, displayException, throwIO, try)
import Control.Monad (forM, forM_, when)
import Data.Bits ((.&.))
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock (addUTCTime, diffUTCTime, getCurrentTime)
import Data.Word (Word32, Word8)
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
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GLFW.Window (WindowConfig (..), hiddenTestWindowConfig)
import Hetoimasia.GPU.Model.Budget (defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.Diagnostics (CaptureConfig (..), DiagnosticVerdict (..), defaultCaptureConfig, verdictIssues)
import Hetoimasia.GPU.Vulkan.GLFW
  ( ClearColor (..)
  , FrameEvent (..)
  , FrameRequest (..)
  , Pipeline
  , Readiness (..)
  , Rect (..)
  , VulkanHandover (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , VulkanRenderer (..)
  , Viewport (..)
  , beginRendering
  , bindPipeline
  , constructPipeline
  , constructPipelineLayout
  , draw
  , endRendering
  , handOverVulkanTarget
  , readReadiness
  , readVulkanGenerations
  , runVulkanOwnerLoop
  , setScissor
  , setViewport
  , vulkanHostConfig
  )
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller
  ( CaptureMode (CaptureOn)
  , CaptureOutcome (..)
  , CapturedFrame (..)
  , requestVulkanCapture
  , takeVulkanCapture
  )
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Production (withVulkanOwnerHostAs)
import Hetoimasia.GPU.Vulkan.Native.Generations (GenerationView (..), TargetGenerationsView (..))
import Hetoimasia.GPU.Vulkan.Native.Presentation (GenerationPlan (..), SurfaceExtent (..), formatB8G8R8A8Srgb, formatR8G8B8A8Srgb, imageUsageTransferSource)
import Hetoimasia.GPU.Vulkan.Native.Recording.Shaders (verificationShaders)
import Hetoimasia.Runtime.GLFW
  ( AttachmentId
  , ScheduledStep (..)
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
import Test.GPU.Vulkan.Native.Environment (validationFeatures)
import Hetoimasia.GLFW.Session (Backend)
import Test.GPU.Vulkan.Native.Platform (requestingBackend)
import Test.Vulkan.Proof.Journal (Journal, heading, note)
import Test.Vulkan.Proof.Roots (NativeCall (..), nativeCallObserver)

-- | One linear color as the shaders and the clear write it, and the 8-bit
-- sRGB encoding a sRGB swapchain image stores for it, red, green, blue and
-- alpha: the verification shaders' orange (1, 0.5, 0, 1) and the clear's blue.
triangleColor, clearColor ∷ (Word8, Word8, Word8, Word8)
triangleColor = (255, 188, 0, 255)
clearColor = (0, 0, 255, 255)

-- | How far each channel may be from its expected value: rounding in the
-- encoding, and nothing else.
tolerance ∷ Int
tolerance = 6

-- | What the case saw for one target.
data TargetFacts = TargetFacts
  { targetCaptured ∷ !CaptureOutcome
  , targetEvents ∷ ![FrameEvent]
    -- ^ Every frame event of this target, oldest first.
  , targetPlans ∷ ![(Word32, Bool)]
    -- ^ Its generations' image usage and whether each was clipped.
  }

data CaptureFacts = CaptureFacts
  { factsTargets ∷ !(Map AttachmentId TargetFacts)
  , factsCalls ∷ ![NativeCall]
  , factsMainThread ∷ !ThreadId
  , factsVerdict ∷ !(Maybe DiagnosticVerdict)
  , factsErrors ∷ ![Text]
  , factsSeconds ∷ !Double
  }

data CaptureCaseOutcome
  = CaptureCaseFailed !Text
  | CaptureCaseRecorded !CaptureFacts

-- | Run the case on the calling thread, which must be the process main thread.
runCapture ∷ Maybe Backend → Journal → IO CaptureCaseOutcome
runCapture backend journal = do
  heading journal "VK-19: a consumer-built triangle captured from two targets through the production host"
  started ← getCurrentTime
  recorded ← newIORef []
  events ← newTVarIO []
  logged ← newTVarIO []
  verdictHeld ← newIORef Nothing
  partial ← newIORef Nothing
  pipelines ← newIORef Map.empty
  scene ← prepare ()
  budgets ← either (stopWith . tshow) pure (validateBudgets defaultBudgetRequest)
  let window name = (hiddenTestWindowConfig name 160 120) {windowVisible = True}
      host = requestingBackend backend (defaultHostConfig [window "hetoimasia VK-19 first", window "hetoimasia VK-19 second"])
      logger = recordingLogger (\entry → atomically (modifyTVar' logged (entry :)))
      config =
        (vulkanHostConfig host defaultCaptureConfig {captureTextBudget = 16384} budgets scene)
          { vulkanLayers = ["VK_LAYER_KHRONOS_validation"]
          , vulkanValidationFeatures = validationFeatures
          , vulkanObserver = nativeCallObserver recorded
          , vulkanFrameObserver = \event → atomically (modifyTVar' events (event :))
          , vulkanRenderer = triangleRenderer pipelines
          }
  outcome ←
    try @SomeException $
      withLoaderIntegration $ \integration →
        runGraphicsOwnerApplication
          (withLoggingLifetime logger)
          "vulkan-native-vk19-capture"
          ( \_ use → do
              (result, verdict) ← withVulkanOwnerHostAs CaptureOn logger integration config use
              writeIORef verdictHeld (Just verdict)
              pure result
          )
          vulkanWindowHost
          (\vulkan _ → pure vulkan)
          (\vulkan control → body vulkan control events partial)
  finished ← getCurrentTime
  verdict ← readIORef verdictHeld
  calls ← reverse <$> readIORef recorded
  entries ← readTVarIO logged
  seen ← reverse <$> readTVarIO events
  let errors = [maybe "" id (Map.lookup "message" entry.entryFields) | entry ← entries, Map.lookup "severity" entry.entryFields == Just "error"]
  case outcome of
    Left failure → pure (CaptureCaseFailed (Text.pack (displayException failure)))
    Right () →
      readIORef partial >>= \case
        Nothing → pure (CaptureCaseFailed "the loop returned without its facts")
        Just (main, captured) → do
          let targets = Map.mapWithKey (\attachment (outcome', plans) → TargetFacts outcome' (filter (concerns attachment) seen) plans) captured
          forM_ (Map.toList targets) $ \(attachment, facts) →
            note journal (tshow attachment <> ": " <> describeOutcome (targetCaptured facts))
          pure . CaptureCaseRecorded $
            CaptureFacts
              { factsTargets = targets
              , factsCalls = calls
              , factsMainThread = main
              , factsVerdict = verdict
              , factsErrors = errors
              , factsSeconds = realToFrac (diffUTCTime finished started)
              }
  where
    body vulkan control events partial = do
      main ← myThreadId
      let controller = vulkanController vulkan
      readiness ← awaitWithin 10 "the owner's startup" $
        readReadiness controller >>= \case
          RootsPending → pure Nothing
          other → pure (Just other)
      case readiness of
        RootsFailed reason → stopWith ("the owner's startup failed: " <> reason)
        _ → pure ()
      windows ← atomically (hostWindowIdentities (vulkanWindowHost vulkan))
      when (length windows /= 2) (stopWith ("the host holds " <> tshow (length windows) <> " windows, not two"))
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
      let attachments = map graphicsAttachment services
      settled ← newTVarIO Map.empty
      tickets ← newTVarIO Map.empty
      deadline ← addUTCTime 15 <$> getCurrentTime
      runVulkanOwnerLoop vulkan control . defaultScheduledHooks quiet $ \_ → do
        now ← getCurrentTime
        when (now > deadline) (stopWith "the capture loop did not finish within 15 seconds")
        -- Ask each target for a capture once it has an active generation, and
        -- take each outcome once it has settled.
        forM_ attachments $ \attachment → do
          asked ← Map.member attachment <$> readTVarIO tickets
          if asked
            then do
              Just ticket ← Map.lookup attachment <$> readTVarIO tickets
              done ← Map.member attachment <$> readTVarIO settled
              when (not done) $
                atomically (takeVulkanCapture controller ticket) >>= \case
                  Nothing → pure ()
                  Just outcome → do
                    plans ← planned <$> atomically (readVulkanGenerations controller attachment)
                    atomically (modifyTVar' settled (Map.insert attachment (outcome, plans)))
            else do
              active ← (>>= viewActive) <$> atomically (readVulkanGenerations controller attachment)
              case active of
                Nothing → pure ()
                Just _ →
                  atomically (requestVulkanCapture controller attachment) >>= \case
                    Right ticket → atomically (modifyTVar' tickets (Map.insert attachment ticket))
                    Left refusal → stopWith ("a capture was refused: " <> tshow refusal)
        captured ← readTVarIO settled
        seen ← readTVarIO events
        let retired = [presentation | PresentationRetired presentation ← seen]
            presented = [presentation | FramePresented _ _ presentation _ ← seen]
            finished = Map.size captured == length attachments && all (`elem` retired) presented
        pure (if finished then FinishWith () else ContinueWith NoUpdateDemand)
      captured ← readTVarIO settled
      writeIORef partial (Just (main, captured))
    quiet = recordingLogger (\_ → pure ())
    planned = \case
      Nothing → []
      Just view → [(planUsage (viewPlan generation), planClipped (viewPlan generation)) | generation ← viewGenerations view]
    concerns attachment = \case
      FrameAcquired at _ _ → at == attachment
      FramePending at _ → at == attachment
      FrameSubmitted at _ _ → at == attachment
      FramePresentRequested at _ _ _ → at == attachment
      FramePresented at _ _ _ → at == attachment
      FrameAbandoned at _ _ → at == attachment
      -- Completions and retirements name no attachment; they are kept with
      -- every target, and matched by identity.
      SubmissionCompleted _ → True
      PresentationRetired _ → True

-- | The consumer's renderer: a pipeline layout and a pipeline over the
-- embedded verification shaders for each color format it meets, kept across
-- frames, and one triangle drawn over a blue clear.
triangleRenderer ∷ IORef (Map Word32 Pipeline) → VulkanRenderer ()
triangleRenderer pipelines = VulkanRenderer $ \_ request construction recorder → do
  held ← Map.lookup (requestFormat request) <$> readIORef pipelines
  built ← case held of
    Just pipeline → pure (Right pipeline)
    Nothing →
      constructPipelineLayout construction >>= \case
        Left refusal → pure (Left refusal)
        Right layout → constructPipeline construction layout verificationShaders (requestFormat request)
  case built of
    Left refusal → pure (Left refusal)
    Right pipeline → do
      modifyIORef' pipelines (Map.insert (requestFormat request) pipeline)
      let SurfaceExtent width height = requestExtent request
      chain
        [ beginRendering recorder (ClearColor 0 0 1 1)
        , bindPipeline recorder pipeline
        , setViewport recorder (Viewport 0 0 (fromIntegral width) (fromIntegral height))
        , setScissor recorder (Rect 0 0 width height)
        , draw recorder 3 1
        , endRendering recorder
        ]
  where
    chain = \case
      [] → pure (Right ())
      step : rest → step >>= either (pure . Left) (const (chain rest))

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

-- | The triangle's centroid, (0, 1/6) in normalized device coordinates.
trianglePoint ∷ SurfaceExtent → (Int, Int)
trianglePoint (SurfaceExtent width height) = (fromIntegral width `div` 2, (fromIntegral height * 7) `div` 12)

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
captureSection ∷ CaptureCaseOutcome → [Text]
captureSection = \case
  CaptureCaseFailed reason → ["", "## The capture case did not complete", "", reason]
  CaptureCaseRecorded facts →
    [ ""
    , "## A consumer-built triangle captured from two targets"
    , ""
    ]
      <> [ "- " <> tshow attachment <> ": " <> describeOutcome (targetCaptured target) <> "; generations (usage, clipped): " <> tshow (targetPlans target)
         | (attachment, target) ← Map.toList (factsTargets facts)
         ]
      <> [ "- expected (red, green, blue, alpha) within " <> tshow tolerance <> ": background " <> tshow clearColor <> ", triangle " <> tshow triangleColor
         , "- Vulkan calls: " <> tshow (length (vulkanCalls facts)) <> ", on " <> tshow (length (nub (map (.callHaskellThread) (vulkanCalls facts)))) <> " thread(s)"
         , "- verdict issues: " <> maybe "no verdict" (tshow . verdictIssues) (factsVerdict facts)
         , "- error reports: " <> tshow (length (factsErrors facts))
         , "- seconds, from the loader integration to the verdict: " <> Text.pack (show (factsSeconds facts))
         ]

vulkanCalls ∷ CaptureFacts → [NativeCall]
vulkanCalls facts = [call | call ← factsCalls facts, "vk" `Text.isPrefixOf` call.callName]

spec ∷ CaptureCaseOutcome → Spec
spec outcome = describe "VK-19 consumer pipeline and capture" $ do
  it "captured a frame of each of two targets through the production host" $
    on outcome $ \facts → do
      Map.size (factsTargets facts) `shouldBe` 2
      forM_ (Map.elems (factsTargets facts)) $ \target → captured target $ \frame →
        ByteString.length (capturedBytes frame) `shouldBe` fromIntegral (let SurfaceExtent width height = capturedExtent frame in width * height * 4)

  it "found the clear at a background point and the consumer's triangle at an interior point, within the tolerance" $
    on outcome $ \facts →
      forM_ (Map.elems (factsTargets facts)) $ \target → captured target $ \frame → do
        pixelAt frame (backgroundPoint (capturedExtent frame)) `shouldSatisfy` maybe False (near clearColor)
        pixelAt frame (trianglePoint (capturedExtent frame)) `shouldSatisfy` maybe False (near triangleColor)

  it "captured each from a frame it acquired, submitted, presented and saw retire on its own present fence" $
    on outcome $ \facts →
      forM_ (Map.elems (factsTargets facts)) $ \target → captured target $ \frame → do
        let seen = targetEvents target
            slot = capturedFrame frame
        [image | FrameAcquired _ at image ← seen, at == slot, image == capturedImage frame] `shouldSatisfy` (not . null)
        [() | FrameSubmitted _ at _ ← seen, at == slot] `shouldSatisfy` (not . null)
        [presentation | FramePresented _ at presentation _ ← seen, at == slot] `shouldSatisfy` elem (capturedPresentation frame)
        [presentation | PresentationRetired presentation ← seen] `shouldSatisfy` elem (capturedPresentation frame)

  it "built every generation of both targets unclipped, as a transfer source" $
    on outcome $ \facts →
      forM_ (Map.elems (factsTargets facts)) $ \target → do
        targetPlans target `shouldSatisfy` (not . null)
        targetPlans target `shouldSatisfy` all (\(usage, clipped) → usage .&. imageUsageTransferSource /= 0 && not clipped)

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
      CaptureCaseFailed reason → const (expectationFailure (Text.unpack reason))
      CaptureCaseRecorded facts → ($ facts)
    captured target check' = case targetCaptured target of
      CaptureDelivered frame → check' frame
      other → expectationFailure ("the capture was not delivered: " <> show other)

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
