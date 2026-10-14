-- | @hetoimasia-image2d@: the image2d sample — a committed PNG decoded with
-- @asset-image@ and drawn in a world layer and again in a UI layer, and an
-- RGBA8 KTX2 image drawn beside it — through the 2D renderer's host adapter
-- and the window integration's public host (R2D-8).
--
-- > hetoimasia-image2d --evidence --output-dir DIRECTORY [--validation]
-- > hetoimasia-image2d --windowed [--ui-scale SCALE] [--validation]
--
-- @--evidence@ starts a surface-free session, opens no window, waits for the
-- textures' uploads, renders the frame into a 256×256 sRGB RGBA8 target,
-- reads it back once its batch has completed, checks every pixel against the
-- independent oracle and its named probes against colours stated by hand, runs
-- the swap-rule demonstration, and writes @image2d.png@ and
-- @image2d-probes.json@ into the directory
-- ("Hetoimasia.Sample.Image2d.Evidence"). It exits 0 only when every check
-- passed and the diagnostic verdict is clean.
--
-- @--windowed@ opens one window, publishes snapshots to it through the host
-- adapter ('publish2DSnapshot') and renders its adopted snapshot until the
-- window is closed, then exits; it is the owner-visible path, launched
-- explicitly and never by a test. It publishes again whenever the window's
-- frame reports another framebuffer extent. @--ui-scale@ sets the UI copy's
-- UI scale, 0.5 to 4: the copy is a fixed 48 logical pixels, so its physical
-- size is that times the UI scale times the display's content scale.
-- @--validation@ enables the validation layer with synchronization
-- validation, which the provisioned prefix supplies.
--
-- Both start the device without a surface; the windowed mode admits its
-- window once the textures are uploaded and registered. The windowed mode
-- configures the host's per-window scene mode, and fills the adapter's host
-- record from the host's public publication and release-request operations;
-- it holds no native handle and makes no GLFW or Vulkan call of its own. See
-- @samples/image2d/README.md@.
module Main (main) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO, retry, writeTVar)
import Control.Monad (forM_, unless, when)
import Data.Text (Text)
import qualified Data.Text as Text
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitFailure, exitWith)
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

import Hetoimasia.Foundation.Log (Logger, defaultLogFilter)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Time (Duration, DurationRequirement (AllowZero), durationFromNanoseconds)
import Hetoimasia.GLFW.Command (clientDemandPublisher)
import Hetoimasia.GLFW.Demand (immediateDemand, publishDemand)
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GLFW.Window (WindowConfig (..), WindowId, defaultWindowConfig)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Model.Budget (BudgetRequest (..), defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Vulkan.Diagnostics (CaptureConfig (..), DiagnosticVerdict, defaultCaptureConfig, verdictIssues)
import Hetoimasia.GPU.Vulkan.GLFW
  ( ActionOutcome (..)
  , BufferDescription (..)
  , BufferKind (..)
  , Construction
  , FrameEvent (..)
  , FrameRequest (..)
  , Readiness (..)
  , UploadRefusal (..)
  , Refusal
  , SceneLifecycle (..)
  , SceneMode (..)
  , TicketState (..)
  , UploadConfig
  , UploadState (..)
  , ValidationFeature (..)
  , VulkanAction (..)
  , VulkanDeviceStart (..)
  , VulkanHandover (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , VulkanRenderer (..)
  , WindowScenePublication (..)
  , awaitTicket
  , awaitUploadTicket
  , awaitVulkanAction
  , constructBlendedCheckedPipeline
  , constructDepthCheckedPipeline
  , constructDepthFormat
  , constructImageFormat
  , constructFramelessBatch
  , constructImage
  , constructReadback
  , constructBuffer
  , constructRingWith
  , constructStorageTable
  , constructTablePipelineLayoutWith
  , TableLayoutOptions (..)
  , TableUse (..)
  , constructTextureTable
  , handOverVulkanTarget
  , publishVulkanWindowScene
  , readConstructedReadback
  , readConstructedTable
  , readReadiness
  , registerConstructedTexture
  , releaseConstructed
  , releaseConstructedTexture
  , requestVulkanRelease
  , runVulkanOwnerLoop
  , submitVulkanAction
  , submitVulkanUpload
  , swapConstructedTexture
  , validateUploadConfig
  , vulkanHostConfig
  , withVulkanOwnerHost
  )
import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceExtent (..))
import Hetoimasia.Render.TwoD.Settings (uiScaleRange)
import Hetoimasia.Render.TwoD.Snapshot (Target (WindowTarget))
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.Vulkan.Chunks (newRetained)
import Hetoimasia.Render.TwoD.Vulkan.Window
  ( Adapter
  , FrameInfo (..)
  , Host (..)
  , HostPublication (..)
  , Scene2D
  , adapterAdopted
  , adapterReleased
  , blankScene
  , newAdapter
  , publish2DSnapshot
  , renderWindowFrame
  )
import Hetoimasia.Runtime.GLFW
  ( ScheduledStep (..)
  , ScheduledTurn (..)
  , Turn (..)
  , UpdateSchedule (..)
  , defaultHostConfig
  , attachmentWindow
  , defaultScheduledHooks
  , honourHostCloseRequest
  , hostWindowClient
  , hostWindowIdentities
  , runGraphicsOwnerApplication
  , superviseGraphicsOwner
  )
import Hetoimasia.Runtime.Logging (lifetimeLogger, withHandleLoggingLifetime)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import qualified Hetoimasia.Sample.Image2d as Sample
import Hetoimasia.Sample.Image2d (Builders (..), Prepared (..), handlesOf)
import Hetoimasia.Sample.Image2d.Evidence (Evidence (..), NamedResult (..), SwapDemonstration (..), runEvidence)
import Hetoimasia.Sample.Image2d.Fixtures (NamedProbe (..))
import Hetoimasia.Sample.Image2d.Scene (Layout (..), snapshotFor)

-- | The evidence mode's directory, or the windowed mode and its UI scale.
data Mode = EvidenceMode !FilePath | WindowedMode !Float

data Options = Options
  { optionEvidence ∷ !Bool
  , optionWindowed ∷ !Bool
  , optionOutput ∷ !(Maybe FilePath)
  , optionUiScale ∷ !(Maybe Float)
  , optionValidation ∷ !Bool
  }

parseOptions ∷ [String] → Either String (Mode, Bool)
parseOptions arguments = go (Options False False Nothing Nothing False) arguments >>= finish
  where
    go options = \case
      [] → Right options
      "--evidence" : rest → go options {optionEvidence = True} rest
      "--windowed" : rest → go options {optionWindowed = True} rest
      "--output-dir" : directory : rest → go options {optionOutput = Just directory} rest
      "--ui-scale" : value : rest → case readMaybe value of
        Just scale | scale >= fst uiScaleRange && scale <= snd uiScaleRange → go options {optionUiScale = Just scale} rest
        _ → Left ("--ui-scale takes a number from " <> show (fst uiScaleRange) <> " to " <> show (snd uiScaleRange) <> ", not " <> value)
      "--validation" : rest → go options {optionValidation = True} rest
      other : _ → Left ("unknown argument " <> other)
    finish options = case (optionEvidence options, optionWindowed options, optionOutput options, optionUiScale options) of
      (True, False, Just directory, Nothing) → Right (EvidenceMode directory, optionValidation options)
      (True, False, Nothing, _) → Left "--evidence needs --output-dir DIRECTORY"
      (True, False, _, Just _) → Left "--ui-scale is for the windowed mode"
      (False, True, Nothing, scale) → Right (WindowedMode (maybe 1 id scale), optionValidation options)
      _ → Left "choose exactly one of --evidence --output-dir DIRECTORY and --windowed"

usage ∷ String
usage = "usage: hetoimasia-image2d --evidence --output-dir DIRECTORY [--validation]\n       hetoimasia-image2d --windowed [--ui-scale SCALE] [--validation]"

main ∷ IO ()
main =
  parseOptions <$> getArgs >>= \case
    Left problem → hPutStrLn stderr (problem <> "\n" <> usage) >> exitWith (ExitFailure 2)
    Right (mode, validation) → run mode validation

-- | The uploads' configuration: a 1 MiB staging buffer, a 128 KiB turn
-- budget — one block row of the widest level any supported device allows —
-- and a queue of eight.
uploadConfig ∷ UploadConfig
uploadConfig = either (error . show) id (validateUploadConfig (1024 * 1024) (128 * 1024) 8)

run ∷ Mode → Bool → IO ()
run mode validation = do
  budgets ← either (\problem → hPutStrLn stderr ("the budgets were refused: " <> show problem) >> exitFailure) pure $
    validateBudgets defaultBudgetRequest {requestedBytes = 2 * 1024 * 1024 * 1024}
  initial ← prepare blankScene
  prepared ← newTVarIO Nothing
  frame ← newTVarIO Nothing
  -- The adapter's slot is filled once the host exists and before any window is
  -- handed over; the lifecycle hooks read it.
  adapterSlot ← newTVarIO Nothing
  presented ← newTVarIO (0 ∷ Int)
  let windows = case mode of
        EvidenceMode _ → []
        WindowedMode _ → [(defaultWindowConfig "hetoimasia image2d" 640 480) {windowFocused = False, windowFocusOnShow = False}]
      capture = if validation then defaultCaptureConfig {captureTextBudget = 16384} else defaultCaptureConfig
      base = vulkanHostConfig (defaultHostConfig windows) capture budgets initial
      config =
        base
          { vulkanRenderer = imageRenderer prepared frame adapterSlot
          , vulkanWindowDepth = True
          , vulkanUploads = Just uploadConfig
          , vulkanDeviceStart = DeviceSurfaceFree
          , vulkanFrameObserver = \case
              FramePresented {} → atomically (modifyTVar' presented (+ 1))
              _ → pure ()
          , vulkanLayers = ["VK_LAYER_KHRONOS_validation" | validation]
          , vulkanValidationFeatures = [SynchronizationValidation | validation]
          , vulkanSceneMode = case mode of
              EvidenceMode _ → vulkanSceneMode base
              WindowedMode _ → PerWindowScenes
          , vulkanSceneLifecycle =
              SceneLifecycle
                { sceneAdopted = \window revision scene → readTVarIO adapterSlot >>= maybe (pure ()) (\adapter → adapterAdopted adapter window revision scene)
                , sceneReleased = \window revision → readTVarIO adapterSlot >>= maybe (pure ()) (\adapter → adapterReleased adapter window revision)
                }
          }
  verdictHeld ← newTVarIO Nothing
  loggerHeld ← newTVarIO Nothing
  passed ← newTVarIO False
  withLoaderIntegration $ \integration →
    runGraphicsOwnerApplication
      (withHandleLoggingLifetime defaultLogFilter stderr)
      "hetoimasia-image2d"
      ( \lifetime use → do
          atomically (writeTVar loggerHeld (Just (lifetimeLogger lifetime)))
          (result, verdict) ← withVulkanOwnerHost (lifetimeLogger lifetime) integration config use
          atomically (writeTVar verdictHeld (Just verdict))
          pure result
      )
      vulkanWindowHost
      (\vulkan _ → pure vulkan)
      ( \vulkan control → do
          awaitReadiness vulkan
          case mode of
            EvidenceMode directory → do
              outcome ← runEvidence (hostOf vulkan) directory
              summarize outcome
              atomically (writeTVar passed (evidencePassed outcome))
            WindowedMode uiScale → do
              _ ← superviseGraphicsOwner control (vulkanGraphicsOwner vulkan)
              logger ← readTVarIO loggerHeld >>= maybe (hPutStrLn stderr "the logging lifetime was never opened" >> exitFailure) pure
              ready ← Sample.prepare (hostOf vulkan)
              made ← either (\failure → hPutStrLn stderr (Text.unpack failure) >> exitFailure) pure ready
              atomically (writeTVar prepared (Just made))
              retained ← newRetained
              adapter ← newAdapter (windowHostOf (vulkanWindowDepth config) vulkan) (preparedTextures made) retained (preparedRenderer made)
              atomically (writeTVar adapterSlot (Just adapter))
              atomically (writeTVar passed True)
              render logger vulkan control adapter made uiScale frame presented
      )
  verdict ← readTVarIO verdictHeld
  ok ← readTVarIO passed
  case mode of
    WindowedMode _ → readTVarIO presented >>= \count → putStrLn (show count <> " frames presented")
    EvidenceMode _ → pure ()
  report verdict
  unless ok exitFailure

-- | Wait for the owner's startup, which creates the device with no surface.
awaitReadiness ∷ VulkanHost scene → IO ()
awaitReadiness vulkan = do
  readiness ← atomically $
    readReadiness (vulkanController vulkan) >>= \case
      RootsPending → retry
      other → pure other
  case readiness of
    RootsFailed reason → hPutStrLn stderr ("the graphics owner did not start: " <> Text.unpack reason) >> exitFailure
    _ → pure ()

-- | The renderer's constructions, from the host's.
renderBuildersOf ∷ Construction q inst msgr phys dev cmd → Render.Builders q inst msgr phys dev cmd
renderBuildersOf construction =
  Render.Builders
    { Render.buildRing = constructRingWith construction
    , Render.buildStorageTable = constructStorageTable construction
    , Render.buildTable = constructTextureTable construction
    , Render.buildTableLayout = \shaders → constructTablePipelineLayoutWith construction shaders (TableLayoutOptions TableShaderSampler True)
    , Render.buildPipeline = constructBlendedCheckedPipeline construction
    , Render.buildDepthPipeline = constructDepthCheckedPipeline construction
    , Render.buildDepthFormat = constructDepthFormat construction
    , Render.buildImageFormat = constructImageFormat construction
    , Render.registerImage = registerConstructedTexture construction
    , Render.swapImage = swapConstructedTexture construction
    , Render.releaseImage = releaseConstructedTexture construction
    , Render.buildVertexBuffer = \bytes → constructBuffer construction (BufferDescription VertexBuffer bytes)
    , -- This sample retains no chunk, so it admits no upload into a chunk's buffer.
      Render.uploadBuffer = \_ _ → pure (Left UploadClosed)
    , Render.releaseBuffer = releaseConstructed construction
    }

-- | The sample's constructions, from the host's.
buildersOf ∷ Construction q inst msgr phys dev cmd → Builders q inst msgr phys dev cmd
buildersOf construction =
  Builders
    { renderBuilders = renderBuildersOf construction
    , buildImage = constructImage construction
    , buildReadback = constructReadback construction
    , inspectTable = readConstructedTable construction
    }

-- | The sample's host: owner-thread actions over the session's
-- constructions, uploads admitted from this thread and waited for, and
-- batches waited for, each wait bounded by a deadline.
hostOf ∷ VulkanHost scene → Sample.Host
hostOf vulkan =
  Sample.Host
    { Sample.hostAct = \what body → act what (VulkanAction (body . buildersOf))
    , Sample.hostRecord = \what body →
        act
          what
          ( VulkanAction
              ( \construction →
                  body (buildersOf construction) >>= \case
                    Left refusal → pure (Left refusal)
                    Right recording →
                      constructFramelessBatch construction recording >>= \case
                        Left refusal → pure (Left refusal)
                        Right (_, Left refusal) → pure (Left refusal)
                        Right (ticket, Right ()) → pure (Right ticket)
              )
          )
    , Sample.hostUpload = \request →
        submitVulkanUpload vulkan request >>= \case
          Left refusal → pure (Left (tshow refusal))
          Right ticket →
            awaitUploadTicket ticket deadline >>= \case
              Right UploadComplete → pure (Right ())
              other → pure (Left (tshow other))
    , Sample.hostAwait = \ticket →
        awaitTicket ticket deadline >>= \case
          Right TicketComplete → pure (Right ())
          other → pure (Left (tshow other))
    , Sample.hostRead = \readback count → act "reading the readback" (VulkanAction (\construction → readConstructedReadback construction readback 0 count))
    }
  where
    act ∷ Text → VulkanAction (Either Refusal a) → IO (Either Text a)
    act what action =
      atomically (submitVulkanAction vulkan action) >>= \case
        Left refusal → pure (Left (what <> " was refused: " <> tshow refusal))
        Right ticket →
          atomically (awaitVulkanAction ticket) >>= \case
            ActionReturned (Right value) → pure (Right value)
            ActionReturned (Left refusal) → pure (Left (what <> " was refused: " <> tshow refusal))
            ActionRaised failure → pure (Left (what <> " raised: " <> tshow failure))
            ActionRefused refusal → pure (Left (what <> " was refused before it ran: " <> tshow refusal))

deadline ∷ Duration
deadline = either (error . show) id (durationFromNanoseconds AllowZero 30000000000)

-- | The adapter's host record, from the window integration's public
-- publication and release-request operations.
windowHostOf ∷ Bool → VulkanHost Scene2D → Host WindowId
windowHostOf windowDepth vulkan =
  Host
    { hostPublish = \window scene →
        prepare scene >>= publishVulkanWindowScene vulkan window >>= \case
          WindowScenePublished _ revision → pure (HostPublished revision)
          WindowSceneUnknown _ → pure HostWindowUnknown
          WindowSceneClosed _ → pure HostClosed
          WindowScenesNotEnabled _ → pure HostSharedScenes
    , hostRequestRelease = \body →
        atomically (requestVulkanRelease vulkan (VulkanAction (body . renderBuildersOf))) >>= \case
          Left refusal → pure (Left (tshow refusal))
          Right _ → pure (Right ())
    , hostRunOnOwner = \body →
        atomically (submitVulkanAction vulkan (VulkanAction (body . renderBuildersOf))) >>= \case
          Left refusal → pure (Left (tshow refusal))
          Right _ → pure (Right ())
    , hostWindowDepth = windowDepth
    }

-- | The window's frame: its adopted snapshot recorded into the frame's image
-- by the adapter, once the textures are registered, and what the frame's
-- request said of the window remembered for the next publication.
imageRenderer ∷ TVar (Maybe Prepared) → TVar (Maybe FrameInfo) → TVar (Maybe (Adapter WindowId)) → VulkanRenderer Scene2D
imageRenderer prepared frame adapterSlot = VulkanRenderer $ \scene request construction recorder →
  (,) <$> readTVarIO prepared <*> readTVarIO adapterSlot >>= \case
    (Just _, Just adapter) → do
      let SurfaceExtent width height = requestExtent request
          info = FrameInfo (width, height) (requestFormat request) (requestLogicalExtent request) (requestContentScale request) (requestDepth request) (requestSceneRevision request)
      atomically (writeTVar frame (Just info))
      renderWindowFrame adapter (renderBuildersOf construction) (attachmentWindow (requestAttachment request)) info scene recorder
    _ → pure (Right ())

-- | Print the evidence's outcome: where it was written, each named probe,
-- the swap demonstration, and the verdict.
summarize ∷ Evidence → IO ()
summarize outcome = do
  forM_ (evidencePng outcome) (\path → putStrLn ("capture: " <> path))
  putStrLn ("probe record: " <> evidenceRecord outcome)
  forM_ (evidenceFailure outcome) (\failure → hPutStrLn stderr ("evidence failed: " <> Text.unpack failure))
  let probes = evidenceProbes outcome
  putStrLn (show (length probes) <> " pixels judged")
  forM_ (evidenceNamed outcome) $ \result →
    putStrLn ((if namedHeld result && namedAgreed result && namedDistinguishes result then "pass " else "FAIL ") <> probeBehaviour (namedProbe result) <> ": " <> show (namedObserved result))
  forM_ (evidenceSwap outcome) $ \swap → do
    putStrLn ("swap to a different mark refused with (registered, replacement) marks " <> show (swapRefused swap) <> "; registered mark after: " <> show (swapMarkAfterRefusal swap))
    putStrLn ("swap with the registered mark kept accepted: " <> show (swapKeepAccepted swap) <> "; registered mark after: " <> show (swapMarkAfterKeep swap))
  putStrLn ("evidence: " <> if evidencePassed outcome then "every check passed" else "failed")

-- | Hand the window over, publish the first snapshot, and run the composed
-- loop, publishing again when the window's frame reports another framebuffer
-- extent and asking for a frame whenever the last was presented, until the
-- window is closed.
render ∷ Logger → VulkanHost Scene2D → RuntimeControl → Adapter WindowId → Prepared → Float → TVar (Maybe FrameInfo) → TVar Int → IO ()
render logger vulkan control adapter prepared uiScale frame presented = do
  windows ← atomically (hostWindowIdentities (vulkanWindowHost vulkan))
  forM_ windows $ \window →
    handOverVulkanTarget vulkan window RequiredTarget >>= \case
      VulkanTargetHandedOver _ → pure ()
      other → hPutStrLn stderr ("the window was not handed over: " <> show other) >> exitFailure
  asked ← newTVarIO (0 ∷ Int)
  published ← newTVarIO Nothing
  let publishFor window layout =
        publish2DSnapshot adapter window (snapshotFor WindowTarget (handlesOf prepared) layout) >>= \case
          Left refusal → hPutStrLn stderr ("the snapshot was refused: " <> show refusal) >> exitFailure
          Right _ → atomically (writeTVar published (Just layout))
  runVulkanOwnerLoop vulkan control . defaultScheduledHooks logger $ \turn → do
    forM_ (turnCloseRequests (scheduledTurn turn)) $ \request →
      () <$ honourHostCloseRequest (vulkanWindowHost vulkan) request
    open ← atomically (hostWindowIdentities (vulkanWindowHost vulkan))
    done ← readTVarIO presented
    wanted ← readTVarIO asked
    seen ← readTVarIO frame
    current ← readTVarIO published
    -- Until a frame has said what the window is, the layout is a guess the
    -- first frame corrects.
    let layout = Layout (maybe (1280, 960) frameExtent seen) uiScale
    forM_ open $ \window → do
      when (current /= Just layout) (publishFor window layout)
      when (done >= wanted) $
        atomically (hostWindowClient (vulkanWindowHost vulkan) window) >>= \case
          Nothing → pure ()
          Just client → do
            _ ← publishDemand (clientDemandPublisher client) immediateDemand
            atomically (writeTVar asked (done + 1))
    pure (if null open then FinishWith () else ContinueWith NoUpdateDemand)

-- | Say what the verdict found, and exit 1 unless it is clean.
report ∷ Maybe DiagnosticVerdict → IO ()
report = \case
  Nothing → hPutStrLn stderr "no diagnostic verdict was reached" >> exitFailure
  Just verdict → do
    let issues = verdictIssues verdict
    putStrLn ("diagnostic verdict: " <> (if null issues then "clean" else show issues))
    unless (null issues) exitFailure

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
