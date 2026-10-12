{-# LANGUAGE OverloadedRecordDot #-}

-- | GRS-13's native case (@grs13-window-depth@): the scene3d sample's two
-- cubes drawn with a depth test into a window's own image, with the depth
-- image of the window's swapchain generation, through the production host
-- with verification capture on, on private roots in a child process of its
-- own.
--
-- The host is the production composition — the loader integration, the
-- validation layer with synchronization validation, the diagnostic lifetime,
-- the protected window host and its graphics owner — built by the package's
-- private sublibrary with capture on ('withVulkanOwnerHostAs' 'CaptureOn'),
-- configured with 'vulkanWindowDepth', and driven by 'runVulkanOwnerLoop' over
-- one mapped window that requests no focus. The renderer is the sample's
-- windowed drawing ("Hetoimasia.Sample.Scene3d.Windowed") from the evidence's
-- front camera, which does not orbit, so the independent oracle's probes
-- apply at the window's framebuffer.
--
-- 1. A frame of the window is captured, and the front pose's probes at its
--    extent checked against the oracle.
-- 2. The window is resized through its command port. Once its target's active
--    generation is the one built at the new extent, a frame of it is captured
--    and its probes checked at that extent.
-- 3. The loop finishes and the host exits through D-33.
--
-- Each probe is checked within an explicit tolerance, never a whole-image
-- hash, in the sRGB encoding the swapchain stores. The occlusion probes sit
-- where both cubes are struck and the nearer, drawn first, must show: only a
-- depth test the depth image makes work shows it. Every generation the target
-- held is checked to have owned a depth image of its own, every frame's
-- request is checked to have named its generation's, and the captures and the
-- probe record are written where the validation runner keeps its evidence.
-- The case also asserts that every Vulkan call ran on the graphics owner's
-- thread, and a verdict, read after the last callback, with no issue and no
-- error — synchronization validation included, so no hazard of the shared
-- depth image across frames in flight and no leak of it across the resize.
module Test.GPU.Vulkan.Native.WindowedDepth
  ( WindowDepthOutcome (..)
  , runWindowDepth
  , windowDepthSection
  , spec
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM (STM, TVar, atomically, check, modifyTVar', newTVarIO, orElse, readTVar, readTVarIO, registerDelay, retry, writeTVar)
import Control.Exception (SomeException, displayException, throwIO, try)
import Control.Monad (forM, forM_, when)
import Data.Bits ((.&.))
import qualified Data.ByteString as ByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (nub)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Data.Time.Clock (addUTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Numeric.Natural (Natural)
import System.Directory (createDirectoryIfMissing, doesFileExist, getTemporaryDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
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
import Hetoimasia.GLFW.Session (Backend)
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GLFW.Window (Extent (..), WindowConfig (..), hiddenTestWindowConfig)
import Hetoimasia.GPU.Model.Budget (BudgetRequest (..), defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (GenerationId, ResourceId, TargetClass (..), imageGeneration)
import Hetoimasia.GPU.Vulkan.Diagnostics (CaptureConfig (..), DiagnosticVerdict (..), defaultCaptureConfig, verdictIssues)
import Hetoimasia.GPU.Vulkan.GLFW
  ( FrameEvent (..)
  , FrameRequest (..)
  , Readiness (..)
  , Refusal (..)
  , VulkanHandover (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , VulkanRenderer (..)
  , constructDepthCheckedPipeline
  , constructDepthFormat
  , constructImage
  , constructPipelineLayoutFor
  , constructReadback
  , constructRing
  , handOverVulkanTarget
  , readReadiness
  , readVulkanGenerations
  , runVulkanOwnerLoop
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
import Hetoimasia.GPU.Vulkan.Native.Generations (GenerationStanding (..), GenerationView (..), TargetGenerationsView (..))
import Hetoimasia.GPU.Vulkan.Native.Presentation (GenerationPlan (..), SurfaceExtent (..), formatB8G8R8A8Srgb, formatR8G8B8A8Srgb, imageUsageTransferSource)
import Hetoimasia.GPU.Vulkan.Native.Recording (Image)
import Hetoimasia.Runtime.GLFW
  ( ScheduledStep (..)
  , TargetStanding (..)
  , UpdateSchedule (..)
  , defaultHostConfig
  , defaultScheduledHooks
  , graphicsAttachment
  , hostCommandPort
  , hostWindowIdentities
  , readTargetStanding
  , runGraphicsOwnerApplication
  )
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Sample.Scene3d (Builders (..))
import Hetoimasia.Sample.Scene3d.Png (encodePng)
import Hetoimasia.Sample.Scene3d.Scene (Probe (..), ProbePurpose (..), PoseName (..), Rgba (..), poseNamed)
import Hetoimasia.Sample.Scene3d.Windowed
  ( WindowedFrame (..)
  , WindowedProbe (..)
  , WindowedScene
  , drawWindowed
  , newWindowedScene
  , storedColour
  , windowedProbes
  )
import Test.GPU.Vulkan.Native.Environment (validationFeatures)
import Test.GPU.Vulkan.Native.Platform (requestingBackend)
import Test.Vulkan.Proof.Journal (Journal, heading, note)
import Test.Vulkan.Proof.Roots (NativeCall (..), nativeCallObserver)

-- | How far each channel may be from its expected value: the rounding in the
-- sRGB encoding and in the device's conversion, and nothing else.
tolerance ∷ Int
tolerance = 6

-- | What the case saw of a captured frame.
data Checked = Checked
  { checkedStep ∷ !Text
  , checkedOutcome ∷ !CaptureOutcome
  , checkedActiveExtent ∷ !(Maybe SurfaceExtent)
    -- ^ The extent of the target's active generation when it was asked for.
  }

-- | One frame request the renderer was handed: its generation, its extent and
-- the depth image it named.
data Requested = Requested
  { requestedGeneration ∷ !GenerationId
  , requestedExtent ∷ !SurfaceExtent
  , requestedDepth ∷ !(Maybe Image)
  }
  deriving (Eq, Show)

-- | A generation the target held, as seen: its extent and the depth image its
-- record named.
data Held = Held
  { heldGeneration ∷ !GenerationId
  , heldExtent ∷ !SurfaceExtent
  , heldDepth ∷ !(Maybe ResourceId)
  }
  deriving (Eq, Show)

data WindowDepthFacts = WindowDepthFacts
  { factsChecked ∷ ![Checked]
  , factsResizedFrom ∷ !(Maybe SurfaceExtent)
  , factsHeld ∷ ![Held]
    -- ^ Every generation seen, oldest first.
  , factsRequests ∷ ![Requested]
  , factsPlans ∷ ![(Natural, Bool)]
  , factsEvents ∷ ![FrameEvent]
  , factsCalls ∷ ![NativeCall]
  , factsMainThread ∷ !ThreadId
  , factsVerdict ∷ !(Maybe DiagnosticVerdict)
  , factsErrors ∷ ![Text]
  , factsSeconds ∷ !Double
  , factsEvidence ∷ !(Maybe FilePath)
    -- ^ Where the captures and the probe record were written.
  }

data WindowDepthOutcome
  = WindowDepthFailed !Text
  | WindowDepthRecorded !WindowDepthFacts

-- | The step the composed loop's update opportunity is in.
data Step
  = Starting
  | CapturingFirst
  | Resizing !SurfaceExtent
    -- ^ The target's active extent when the resize was asked for.
  | CapturingResized
  | Settling
    -- ^ Both captures are in; the presentations made retire.
  | Done

-- | Run the case on the calling thread, which must be the process main thread.
runWindowDepth ∷ Maybe Backend → Journal → IO WindowDepthOutcome
runWindowDepth backend journal = do
  heading journal "GRS-13: the scene3d sample's cubes drawn with the depth image of a window's swapchain generation, captured before and after a resize and checked against the independent oracle"
  started ← getCurrentTime
  recorded ← newIORef []
  events ← newTVarIO []
  logged ← newTVarIO []
  verdictHeld ← newIORef Nothing
  factsHeld ← newIORef Nothing
  requests ← newTVarIO []
  windowed ← newWindowedScene
  scene ← prepare ()
  directory ← evidenceDirectory
  outcome ← try @SomeException $ do
    budgets ← either (stopWith . tshow) pure (validateBudgets defaultBudgetRequest {requestedBytes = 2 * 1024 * 1024 * 1024})
    let window = (hiddenTestWindowConfig "hetoimasia GRS-13" 160 120) {windowVisible = True}
        host = requestingBackend backend (defaultHostConfig [window])
        logger = recordingLogger (\entry → atomically (modifyTVar' logged (entry :)))
        config =
          (vulkanHostConfig host defaultCaptureConfig {captureTextBudget = 16384} budgets scene)
            { vulkanLayers = ["VK_LAYER_KHRONOS_validation"]
            , vulkanValidationFeatures = validationFeatures
            , vulkanObserver = nativeCallObserver recorded
            , vulkanFrameObserver = \event → atomically (modifyTVar' events (event :))
            , vulkanWindowDepth = True
            , vulkanRenderer = frontRenderer windowed requests
            }
    withLoaderIntegration $ \integration →
      runGraphicsOwnerApplication
        (withLoggingLifetime logger)
        "vulkan-native-grs13-window-depth"
        ( \_ use → do
            (result, verdict) ← withVulkanOwnerHostAs CaptureOn logger integration config use
            writeIORef verdictHeld (Just verdict)
            pure result
        )
        vulkanWindowHost
        (\vulkan _ → pure vulkan)
        (\vulkan control → body vulkan control events requests factsHeld)
  finished ← getCurrentTime
  verdict ← readIORef verdictHeld
  calls ← reverse <$> readIORef recorded
  entries ← readTVarIO logged
  seen ← reverse <$> readTVarIO events
  asked ← reverse <$> readTVarIO requests
  let errors = [maybe "" id (Map.lookup "message" entry.entryFields) | entry ← entries, Map.lookup "severity" entry.entryFields == Just "error"]
  case outcome of
    Left failure → pure (WindowDepthFailed (Text.pack (displayException failure)))
    Right () →
      readIORef factsHeld >>= \case
        Nothing → pure (WindowDepthFailed "the loop returned without its facts")
        Just partial → do
          forM_ (factsChecked partial) $ \checked → note journal (checkedStep checked <> ": " <> describeOutcome (checkedOutcome checked))
          written ← writeEvidence directory (factsChecked partial)
          forM_ written $ \path → note journal ("the windowed evidence is written into " <> Text.pack path)
          pure . WindowDepthRecorded $
            partial
              { factsRequests = asked
              , factsEvents = seen
              , factsCalls = calls
              , factsVerdict = verdict
              , factsErrors = errors
              , factsSeconds = realToFrac (diffUTCTime finished started)
              , factsEvidence = written
              }
  where
    body vulkan control events requests factsHeld = do
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
      window ← atomically (hostWindowIdentities windowHost) >>= \case
        [one] → pure one
        other → stopWith ("the host holds " <> tshow (length other) <> " windows, not one")
      service ←
        handOverVulkanTarget vulkan window RequiredTarget >>= \case
          VulkanTargetHandedOver handed → pure handed
          other → stopWith ("the window was not handed over: " <> tshow other)
      standing ← awaitWithin 10 "the target's admission" $
        readTargetStanding (vulkanGraphicsOwner vulkan) (graphicsAttachment service) >>= \case
          Just TargetConstructing → pure Nothing
          Nothing → pure Nothing
          Just other → pure (Just other)
      when (standing /= TargetUsable) (stopWith ("the target was not admitted: " <> tshow standing))
      let attachment = graphicsAttachment service
      step ← newTVarIO Starting
      ticket ← newTVarIO Nothing
      checked ← newTVarIO []
      plans ← newTVarIO []
      held ← newTVarIO []
      resizedFrom ← newTVarIO Nothing
      let viewOf = atomically (readVulkanGenerations controller attachment)
          activeOf = do
            view ← viewOf
            pure $ do
              generations ← view
              active ← viewActive generations
              generation ← lookup active [(viewGeneration each, each) | each ← viewGenerations generations]
              pure (planExtent (viewPlan generation))
          -- Every generation the target holds, with the depth image its
          -- record names, noted as it is seen.
          noteGenerations = do
            view ← viewOf
            -- A generation still being built is seen with no depth image yet:
            -- its construction makes the image last and publishes it after, so
            -- only a generation the target published is held to have one.
            forM_ [generation | generation ← maybe [] viewGenerations view, viewStanding generation /= GenerationBuilding] $ \generation → do
              atomically $ do
                modifyTVar' plans (nub . ((fromIntegral (planUsage (viewPlan generation)), planClipped (viewPlan generation)) :))
                modifyTVar' held $ \seen →
                  let entry = Held (viewGeneration generation) (planExtent (viewPlan generation)) (viewDepth generation)
                   in if entry `elem` seen then seen else seen <> [entry]
          ask label = do
            active ← activeOf
            atomically (requestVulkanCapture controller attachment) >>= \case
              Right asked → atomically (writeTVar ticket (Just (asked, label, active)))
              Left refusal → stopWith ("a capture was refused: " <> tshow refusal)
          -- Take the outcome once it has settled; answer whether none is
          -- still awaited.
          collect = do
            pending ← readTVarIO ticket
            case pending of
              Nothing → pure True
              Just (asked, label, active) →
                atomically (takeVulkanCapture controller asked) >>= \case
                  Nothing → pure False
                  Just outcome → do
                    atomically $ do
                      writeTVar ticket Nothing
                      modifyTVar' checked (<> [Checked label outcome active])
                    pure True
          retired = do
            seen ← readTVarIO events
            let presented = [presentation | FramePresented _ _ presentation _ ← seen]
                done = [presentation | PresentationRetired presentation ← seen]
            pure (all (`elem` done) presented)
      deadline ← addUTCTime 20 <$> getCurrentTime
      runVulkanOwnerLoop vulkan control . defaultScheduledHooks quiet $ \_ → do
        now ← getCurrentTime
        when (now > deadline) (stopWith "the case did not finish within 20 seconds")
        noteGenerations
        current ← readTVarIO step
        case current of
          Starting →
            activeOf >>= \case
              Nothing → pure ()
              Just _ → do
                ask "the window, before the resize"
                atomically (writeTVar step CapturingFirst)
          CapturingFirst → do
            done ← collect
            when done $
              activeOf >>= \case
                Nothing → pure ()
                Just extent → do
                  submitWindowCommand (hostCommandPort windowHost) [("client", "grs13-window-depth")] (setWindowSizeCommand window (Extent 200 150)) >>= \case
                    SubmitAccepted _ → pure ()
                    other → stopWith ("the resize was not admitted: " <> tshow other)
                  atomically $ do
                    writeTVar resizedFrom (Just extent)
                    writeTVar step (Resizing extent)
          Resizing before →
            -- The resized target's active generation is the one built at the
            -- new extent.
            activeOf >>= \case
              Just extent | extent /= before → do
                ask "the window, after the resize"
                atomically (writeTVar step CapturingResized)
              _ → pure ()
          CapturingResized → do
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
      seenHeld ← readTVarIO held
      from ← readTVarIO resizedFrom
      _ ← readTVarIO requests
      writeIORef factsHeld . Just $
        WindowDepthFacts
          { factsChecked = captured
          , factsResizedFrom = from
          , factsHeld = seenHeld
          , factsRequests = []
          , factsPlans = seenPlans
          , factsEvents = []
          , factsCalls = []
          , factsMainThread = main
          , factsVerdict = Nothing
          , factsErrors = []
          , factsSeconds = 0
          , factsEvidence = Nothing
          }
    quiet = recordingLogger (\_ → pure ())

-- | The sample's windowed drawing as the host's renderer, from the evidence's
-- front camera: each frame's extent, color format and depth image, the
-- request kept for the record, and the constructions the host lends.
frontRenderer ∷ WindowedScene → TVar [Requested] → VulkanRenderer ()
frontRenderer windowed requests = VulkanRenderer $ \_ request construction recorder → do
  atomically (modifyTVar' requests (Requested (imageGeneration (requestImage request)) (requestExtent request) (requestDepth request) :))
  case requestDepth request of
    Nothing → pure (Left (RefusedIllegal "the frame's request names no depth image"))
    Just depth →
      drawWindowed
        windowed
        Builders
          { buildRing = constructRing construction
          , buildImage = constructImage construction
          , buildLayout = constructPipelineLayoutFor construction
          , buildPipeline = constructDepthCheckedPipeline construction
          , buildReadback = constructReadback construction
          , chooseDepthFormat = constructDepthFormat construction
          }
        (poseNamed FrontPose)
        (WindowedFrame (requestExtent request) (requestFormat request) depth)
        recorder

-- ---------------------------------------------------------------------------
-- Probes

-- | The pixel at this point of a captured frame, red, green, blue and alpha,
-- if its format is one the case renders to.
pixelAt ∷ CapturedFrame → (Int, Int) → Maybe Rgba
pixelAt frame (x, y)
  | offset + 4 > ByteString.length bytes = Nothing
  | capturedFormat frame == formatB8G8R8A8Srgb = Just (Rgba (byte 2) (byte 1) (byte 0) (byte 3))
  | capturedFormat frame == formatR8G8B8A8Srgb = Just (Rgba (byte 0) (byte 1) (byte 2) (byte 3))
  | otherwise = Nothing
  where
    bytes = capturedBytes frame
    SurfaceExtent width _ = capturedExtent frame
    offset = (y * fromIntegral width + x) * 4
    byte index = ByteString.index bytes (offset + index)

-- | A captured frame's extent as the oracle takes one.
extentOf ∷ CapturedFrame → (Int, Int)
extentOf frame = let SurfaceExtent width height = capturedExtent frame in (fromIntegral width, fromIntegral height)

-- | Whether a pixel is within the tolerance of what a color reads as in the
-- sRGB image.
near ∷ Rgba → Rgba → Bool
near (Rgba r g b a) (Rgba r' g' b' a') = all (\(one, two) → abs (fromIntegral one - fromIntegral two ∷ Int) <= tolerance) [(r, r'), (g, g'), (b, b'), (a, a')]

-- | One probe of a captured frame: what the oracle expects as the image stores
-- it, what the frame read, and whether they agree.
data Verdict = Verdict
  { verdictProbe ∷ !WindowedProbe
  , verdictExpected ∷ !Rgba
  , verdictObserved ∷ !(Maybe Rgba)
  , verdictPassed ∷ !Bool
  }
  deriving (Show)

verdictsOf ∷ CapturedFrame → [Verdict]
verdictsOf frame =
  [ Verdict probe expected observed (maybe False (near expected) observed)
  | probe ← windowedProbes (extentOf frame)
  , let expected = storedColour (windowedExpected probe)
        observed = pixelAt frame (windowedPixel probe)
  ]

describeOutcome ∷ CaptureOutcome → Text
describeOutcome = \case
  CaptureDelivered frame →
    "captured "
      <> tshow (capturedExtent frame)
      <> " in format "
      <> tshow (capturedFormat frame)
      <> "; "
      <> tshow (length (filter verdictPassed (verdictsOf frame)))
      <> " of "
      <> tshow (length (verdictsOf frame))
      <> " probes within the tolerance"
  CaptureWithheld _ reason → "withheld: " <> tshow reason

-- ---------------------------------------------------------------------------
-- Evidence

-- | Where the captures and the probe record are written: beneath the
-- validation runner's evidence directory when it names one, and otherwise a
-- directory of this run's own.
evidenceDirectory ∷ IO FilePath
evidenceDirectory =
  lookupEnv "HETOIMASIA_VALIDATION_EVIDENCE" >>= \case
    Just evidence | not (null evidence) → pure (evidence </> "scene3d-windowed")
    _ → do
      temporary ← getTemporaryDirectory
      stamp ← (round . (* 1000) . utcTimeToPOSIXSeconds) <$> getCurrentTime ∷ IO Integer
      pure (temporary </> ("hetoimasia-scene3d-windowed-" <> show stamp))

-- | Write each delivered capture as a lossless PNG — the bytes as the window's
-- image held them, converted only from its channel order — and the probe
-- record. Answers the directory.
writeEvidence ∷ FilePath → [Checked] → IO (Maybe FilePath)
writeEvidence directory checked = do
  createDirectoryIfMissing True directory
  written ← forM [(item, frame) | item ← checked, CaptureDelivered frame ← [checkedOutcome item]] $ \(item, frame) → do
    let name = "scene3d-windowed-" <> Text.unpack (Text.replace " " "-" (Text.replace "," "" (checkedStep item))) <> ".png"
        SurfaceExtent width height = capturedExtent frame
    ByteString.writeFile (directory </> name) (encodePng (fromIntegral width) (fromIntegral height) (rgba frame))
    pure (item, frame, name)
  Text.writeFile (directory </> "scene3d-windowed-probes.json") (record written)
  pure (Just directory)
  where
    rgba frame
      | capturedFormat frame == formatB8G8R8A8Srgb = ByteString.pack (concat [[b2, b1, b0, b3] | [b0, b1, b2, b3] ← chunksOf4 (ByteString.unpack (capturedBytes frame))])
      | otherwise = capturedBytes frame
    chunksOf4 bytes = case splitAt 4 bytes of
      (chunk, rest) | length chunk == 4 → chunk : chunksOf4 rest
      _ → []
    record written =
      Text.unlines $
        ["{", "  \"tolerance\": " <> tshow tolerance <> ",", "  \"frames\": ["]
          <> [Text.intercalate ",\n" [frameRecord item frame name | (item, frame, name) ← written]]
          <> ["  ]", "}"]
    frameRecord item frame name =
      let (width, height) = extentOf frame
       in Text.unlines $
            [ "    {"
            , "      \"step\": " <> tshow (checkedStep item) <> ","
            , "      \"capture\": " <> tshow name <> ","
            , "      \"extent\": [" <> tshow width <> ", " <> tshow height <> "],"
            , "      \"format\": " <> tshow (capturedFormat frame) <> ","
            , "      \"probes\": ["
            , Text.intercalate ",\n" [probeRecord verdict | verdict ← verdictsOf frame]
            , "      ]"
            , "    }"
            ]
    probeRecord verdict =
      let probe = windowedProbe (verdictProbe verdict)
          (x, y) = windowedPixel (verdictProbe verdict)
          colour (Rgba r g b a) = "[" <> Text.intercalate ", " (map tshow [r, g, b, a]) <> "]"
       in "        {\"name\": "
            <> tshow (probeName probe)
            <> ", \"pixel\": ["
            <> tshow x
            <> ", "
            <> tshow y
            <> "], \"purpose\": "
            <> tshow (show (probePurpose probe))
            <> ", \"expected\": "
            <> colour (verdictExpected verdict)
            <> ", \"observed\": "
            <> maybe "null" colour (verdictObserved verdict)
            <> ", \"passed\": "
            <> (if verdictPassed verdict then "true" else "false")
            <> "}"

-- ---------------------------------------------------------------------------
-- The record and the examples

-- | The record's section.
windowDepthSection ∷ WindowDepthOutcome → [Text]
windowDepthSection = \case
  WindowDepthFailed reason → ["", "## The windowed depth case did not complete", "", reason]
  WindowDepthRecorded facts →
    [ ""
    , "## The scene3d sample's cubes drawn with a window's depth image"
    , ""
    ]
      <> [ "- " <> checkedStep checked <> ": " <> describeOutcome (checkedOutcome checked)
         | checked ← factsChecked facts
         ]
      <> [ "- the window was resized from " <> maybe "no extent" tshow (factsResizedFrom facts)
         , "- generations seen (extent, depth image): " <> tshow [(heldExtent entry, isJust (heldDepth entry)) | entry ← factsHeld facts]
         , "- frame requests: " <> tshow (length (factsRequests facts)) <> ", every one naming its generation's depth image: " <> tshow (all (isJust . requestedDepth) (factsRequests facts))
         , "- generations seen (usage, clipped): " <> tshow (factsPlans facts)
         , "- expected as the sRGB image stores each color, within " <> tshow tolerance
         , "- Vulkan calls: " <> tshow (length (vulkanCalls facts)) <> ", on " <> tshow (length (nub (map (.callHaskellThread) (vulkanCalls facts)))) <> " thread(s)"
         , "- evidence: " <> maybe "not written" Text.pack (factsEvidence facts)
         , "- verdict issues: " <> maybe "no verdict" (tshow . verdictIssues) (factsVerdict facts)
         , "- error reports: " <> tshow (length (factsErrors facts))
         , "- seconds, from the loader integration to the verdict: " <> Text.pack (show (factsSeconds facts))
         ]

vulkanCalls ∷ WindowDepthFacts → [NativeCall]
vulkanCalls facts = [call | call ← factsCalls facts, "vk" `Text.isPrefixOf` call.callName]

spec ∷ WindowDepthOutcome → Spec
spec outcome = describe "GRS-13 windowed depth" $ do
  it "gave every generation the target held a depth image of its own, and named its generation's in every frame's request" $
    on outcome $ \facts → do
      -- Two generations at least: the one built at the window's size and the
      -- one built after the resize.
      length (factsHeld facts) `shouldSatisfy` (>= 2)
      map heldDepth (factsHeld facts) `shouldSatisfy` all isJust
      let depths = [depth | Just depth ← map heldDepth (factsHeld facts)]
      length (nub depths) `shouldBe` length depths
      factsRequests facts `shouldSatisfy` (not . null)
      map requestedDepth (factsRequests facts) `shouldSatisfy` all isJust
      -- Every frame of one generation named the one depth image.
      forM_ (nub (map requestedGeneration (factsRequests facts))) $ \generation →
        length (nub [requestedDepth request | request ← factsRequests facts, requestedGeneration request == generation]) `shouldBe` 1

  it "captured the window before the resize and again at the extent of the generation built after it" $
    on outcome $ \facts → do
      map checkedStep (factsChecked facts) `shouldBe` ["the window, before the resize", "the window, after the resize"]
      forM_ (factsChecked facts) $ \item → delivered item $ \frame →
        ByteString.length (capturedBytes frame) `shouldBe` (let SurfaceExtent width height = capturedExtent frame in fromIntegral (width * height * 4))
      case factsChecked facts of
        [before, after] → delivered before $ \first → delivered after $ \second → do
          capturedExtent second `shouldSatisfy` (/= capturedExtent first)
          Just (capturedExtent second) `shouldBe` checkedActiveExtent after
          Just (capturedExtent first) `shouldBe` factsResizedFrom facts
        _ → expectationFailure "the window was not captured twice"

  it "showed the nearer cube, drawn first, where the cubes overlap, and the flat colors and the clear elsewhere, before and after the resize, within the tolerance" $
    on outcome $ \facts →
      forM_ (factsChecked facts) $ \item → delivered item $ \frame → do
        let verdicts = verdictsOf frame
            purposes = nub [probePurpose (windowedProbe (verdictProbe verdict)) | verdict ← verdicts]
        verdicts `shouldSatisfy` (not . null)
        [probeName (windowedProbe (verdictProbe verdict)) | verdict ← verdicts, not (verdictPassed verdict)] `shouldBe` []
        purposes `shouldSatisfy` (\found → all (`elem` found) [Occlusion, FaceColour, Clear])

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

  it "wrote the captures as lossless PNGs and the probe record where the validation runner keeps its evidence" $
    on outcome $ \facts → case factsEvidence facts of
      Nothing → expectationFailure "no evidence was written"
      Just directory → do
        pngs ← mapM (doesFileExist . (directory </>)) ["scene3d-windowed-the-window-before-the-resize.png", "scene3d-windowed-the-window-after-the-resize.png"]
        record ← doesFileExist (directory </> "scene3d-windowed-probes.json")
        (pngs, record) `shouldBe` ([True, True], True)

  it "reached a verdict after the last callback with no issue and no error, synchronization validation included" $
    on outcome $ \facts → do
      fmap verdictIssues (factsVerdict facts) `shouldBe` Just []
      factsErrors facts `shouldBe` []
  where
    on = \case
      WindowDepthFailed reason → const (expectationFailure (Text.unpack reason))
      WindowDepthRecorded facts → ($ facts)
    delivered item check' = case checkedOutcome item of
      CaptureDelivered frame → check' frame
      other → expectationFailure (Text.unpack (checkedStep item) <> ": the capture was not delivered: " <> show other)

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
