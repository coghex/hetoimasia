-- | @hetoimasia-sprites@: the sprites sample's fixed 2D scene — indexed,
-- instanced textured quads through stable texture handles, with
-- premultiplied-alpha blending — through the window integration's public
-- host (GRS-8).
--
-- > hetoimasia-sprites --evidence [--swap] --output-dir DIRECTORY [--validation]
-- > hetoimasia-sprites --windowed [--validation]
--
-- @--evidence@ starts a surface-free session, opens no window, waits for the
-- textures' uploads, renders the scene into a 256×256 linear RGBA8 target,
-- reads it back once its batch has completed, checks every probe against the
-- independent oracle, and writes @sprites.png@ and @sprites-probes.json@ into
-- the directory ("Hetoimasia.Sample.Sprites.Evidence"). With @--swap@ it runs
-- the swap case instead (GRS-9, "Hetoimasia.Sample.Sprites.Swap"): the
-- atlas's handle is redirected to a replacement between a batch's recording
-- and its submission, and @swap-before.png@, @swap-delayed.png@,
-- @swap-after.png@ and @swap-probes.json@ are written. It exits 0 only when
-- every probe and check passed and the diagnostic verdict is clean.
--
-- @--windowed@ opens one window and renders the same scene until the window
-- is closed, then exits; it is the owner-visible path, launched explicitly
-- and never by a test. @--validation@ enables the validation layer with
-- synchronization validation, which the provisioned prefix supplies.
--
-- Both start the device without a surface; the windowed mode admits its
-- window once the scene's textures are uploaded and registered. It holds no
-- native handle and makes no GLFW or Vulkan call of its own. See
-- @samples/sprites/README.md@.
module Main (main) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO, retry, writeTVar)
import Control.Monad (forM_, unless, when)
import Data.Text (Text)
import qualified Data.Text as Text
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitFailure, exitWith)
import System.IO (hPutStrLn, stderr)

import Hetoimasia.Foundation.Log (Logger, defaultLogFilter)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Time (Duration, DurationRequirement (AllowZero), durationFromNanoseconds)
import Hetoimasia.GLFW.Command (clientDemandPublisher)
import Hetoimasia.GLFW.Demand (immediateDemand, publishDemand)
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GLFW.Window (WindowConfig (..), defaultWindowConfig)
import Hetoimasia.GPU.Model.Budget (BudgetRequest (..), defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.Diagnostics (CaptureConfig (..), DiagnosticVerdict, defaultCaptureConfig, verdictIssues)
import Hetoimasia.GPU.Vulkan.GLFW
  ( ActionOutcome (..)
  , Construction
  , FrameEvent (..)
  , FrameRequest (..)
  , Readiness (..)
  , Refusal
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
  , awaitTicket
  , awaitUploadTicket
  , awaitVulkanAction
  , constructBlendedCheckedPipeline
  , constructFramelessBatch
  , constructImage
  , constructReadback
  , constructRing
  , constructTablePipelineLayout
  , constructTextureTable
  , handOverVulkanTarget
  , readConstructedReadback
  , readConstructedTable
  , readReadiness
  , registerConstructedTexture
  , swapConstructedTexture
  , runVulkanOwnerLoop
  , submitVulkanAction
  , submitVulkanUpload
  , validateUploadConfig
  , vulkanHostConfig
  , withVulkanOwnerHost
  )
import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceExtent (..))
import Hetoimasia.Runtime.GLFW
  ( ScheduledStep (..)
  , ScheduledTurn (..)
  , Turn (..)
  , UpdateSchedule (..)
  , defaultHostConfig
  , defaultScheduledHooks
  , honourHostCloseRequest
  , hostWindowClient
  , hostWindowIdentities
  , runGraphicsOwnerApplication
  , superviseGraphicsOwner
  )
import Hetoimasia.Runtime.Logging (lifetimeLogger, withHandleLoggingLifetime)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Hetoimasia.Sample.Sprites
  ( Builders (..)
  , SceneTarget (..)
  , Sprites
  , makeSprites
  , pipelineFor
  , recordScene
  , registerSprites
  , uploadRequests
  )
import Hetoimasia.Sample.Sprites.Evidence (Evidence (..), Host (..), runEvidence)
import Hetoimasia.Sample.Sprites.Swap (SwapEvidence (..), SwapFacts (..), runSwapEvidence)
import Hetoimasia.Sample.Sprites.Oracle (ProbeResult (..))
import Hetoimasia.Sample.Sprites.Scene (Probe (..), targetBytes)

-- | The evidence mode's directory, and whether it runs the swap case.
data Mode = EvidenceMode !FilePath !Bool | WindowedMode

data Options = Options
  { optionMode ∷ !(Maybe Mode)
  , optionOutput ∷ !(Maybe FilePath)
  , optionEvidence ∷ !Bool
  , optionSwap ∷ !Bool
  , optionValidation ∷ !Bool
  }

parseOptions ∷ [String] → Either String (Mode, Bool)
parseOptions arguments = go (Options Nothing Nothing False False False) arguments >>= finish
  where
    go options = \case
      [] → Right options
      "--evidence" : rest → go options {optionEvidence = True} rest
      "--swap" : rest → go options {optionSwap = True} rest
      "--output-dir" : directory : rest → go options {optionOutput = Just directory} rest
      "--windowed" : rest → go options {optionMode = Just WindowedMode} rest
      "--validation" : rest → go options {optionValidation = True} rest
      other : _ → Left ("unknown argument " <> other)
    finish options = case (optionEvidence options, optionMode options, optionOutput options) of
      _ | optionSwap options && not (optionEvidence options) → Left "--swap is an evidence case: use it with --evidence"
      (True, Nothing, Just directory) → Right (EvidenceMode directory (optionSwap options), optionValidation options)
      (True, Nothing, Nothing) → Left "--evidence needs --output-dir DIRECTORY"
      (False, Just WindowedMode, Nothing) → Right (WindowedMode, optionValidation options)
      _ → Left "choose exactly one of --evidence --output-dir DIRECTORY and --windowed"

usage ∷ String
usage = "usage: hetoimasia-sprites --evidence [--swap] --output-dir DIRECTORY [--validation]\n       hetoimasia-sprites --windowed [--validation]"

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
  scene ← prepare ()
  ready ← newTVarIO Nothing
  presented ← newTVarIO (0 ∷ Int)
  let windows = case mode of
        EvidenceMode _ _ → []
        WindowedMode → [(defaultWindowConfig "hetoimasia sprites" 512 512) {windowFocused = False, windowFocusOnShow = False}]
      capture = if validation then defaultCaptureConfig {captureTextBudget = 16384} else defaultCaptureConfig
      config =
        (vulkanHostConfig (defaultHostConfig windows) capture budgets scene)
          { vulkanRenderer = spritesRenderer ready
          , vulkanUploads = Just uploadConfig
          , vulkanDeviceStart = DeviceSurfaceFree
          , vulkanFrameObserver = \case
              FramePresented {} → atomically (modifyTVar' presented (+ 1))
              _ → pure ()
          , vulkanLayers = ["VK_LAYER_KHRONOS_validation" | validation]
          , vulkanValidationFeatures = [SynchronizationValidation | validation]
          }
  verdictHeld ← newTVarIO Nothing
  loggerHeld ← newTVarIO Nothing
  passed ← newTVarIO False
  withLoaderIntegration $ \integration →
    runGraphicsOwnerApplication
      (withHandleLoggingLifetime defaultLogFilter stderr)
      "hetoimasia-sprites"
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
            EvidenceMode directory False → do
              outcome ← runEvidence (hostOf vulkan) directory
              summarize outcome
              atomically (writeTVar passed (evidencePassed outcome))
            EvidenceMode directory True → do
              outcome ← runSwapEvidence (hostOf vulkan) directory
              summarizeSwap outcome
              atomically (writeTVar passed (swapPassed outcome))
            WindowedMode → do
              _ ← superviseGraphicsOwner control (vulkanGraphicsOwner vulkan)
              logger ← readTVarIO loggerHeld >>= maybe (hPutStrLn stderr "the logging lifetime was never opened" >> exitFailure) pure
              prepareWindowed vulkan ready
              atomically (writeTVar passed True)
              render logger vulkan control presented
      )
  verdict ← readTVarIO verdictHeld
  ok ← readTVarIO passed
  case mode of
    WindowedMode → readTVarIO presented >>= \count → putStrLn (show count <> " frames presented")
    EvidenceMode _ _ → pure ()
  report verdict
  unless ok exitFailure

-- | Wait for the owner's startup, which creates the device with no surface.
awaitReadiness ∷ VulkanHost () → IO ()
awaitReadiness vulkan = do
  readiness ← atomically $
    readReadiness (vulkanController vulkan) >>= \case
      RootsPending → retry
      other → pure other
  case readiness of
    RootsFailed reason → hPutStrLn stderr ("the graphics owner did not start: " <> Text.unpack reason) >> exitFailure
    _ → pure ()

-- | The sample's constructions, from the host's.
buildersOf ∷ Construction q inst msgr phys dev cmd → Builders q inst msgr phys dev cmd
buildersOf construction =
  Builders
    { buildRing = constructRing construction
    , buildTable = constructTextureTable construction
    , buildImage = constructImage construction
    , buildTableLayout = constructTablePipelineLayout construction
    , buildPipeline = constructBlendedCheckedPipeline construction
    , buildReadback = constructReadback construction
    , registerImage = registerConstructedTexture construction
    , swapImage = swapConstructedTexture construction
    , inspectTable = readConstructedTable construction
    }

-- | The evidence's host: owner-thread actions over the session's
-- constructions, uploads admitted from this thread and waited for, and
-- batches waited for, each wait bounded by a deadline.
hostOf ∷ VulkanHost () → Host
hostOf vulkan =
  Host
    { hostAct = \what body → act what (VulkanAction (body . buildersOf))
    , hostRecord = \what body →
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
    , hostUpload = \request →
        submitVulkanUpload vulkan request >>= \case
          Left refusal → pure (Left (tshow refusal))
          Right ticket →
            awaitUploadTicket ticket deadline >>= \case
              Right UploadComplete → pure (Right ())
              other → pure (Left (tshow other))
    , hostAwait = \ticket →
        awaitTicket ticket deadline >>= \case
          Right TicketComplete → pure (Right ())
          other → pure (Left (tshow other))
    , hostReadTable = act "reading the texture table" (VulkanAction (fmap Right . readConstructedTable))
    , hostRead = \readback → act "reading the readback" (VulkanAction (\construction → readConstructedReadback construction readback 0 targetBytes))
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

-- | Print the swap case's outcome: where it was written, its facts, each
-- failed probe, and the verdict.
summarizeSwap ∷ SwapEvidence → IO ()
summarizeSwap outcome = do
  forM_ (swapPngs outcome) (\path → putStrLn ("capture: " <> path))
  putStrLn ("swap record: " <> swapRecord outcome)
  forM_ (swapFailure outcome) (\failure → hPutStrLn stderr ("swap evidence failed: " <> Text.unpack failure))
  forM_ (swapFacts outcome) $ \facts → do
    putStrLn ("old slot " <> show (factsOldSlot facts) <> ", new slot " <> show (factsNewSlot facts) <> ", swap " <> show (factsSwapState facts))
    putStrLn ("retiring while the delayed frame held the old version: " <> show (factsRetiringDuringDelay facts) <> "; registered then into slot " <> show (factsSlotDuringDelay facts) <> ", after its completion into slot " <> show (factsSlotAfterCompletion facts))
    putStrLn ("instance data unchanged across the swap: " <> show (factsInstancesUnchanged facts))
  forM_ [(name, result) | (name, results) ← [("before", swapBefore outcome), ("delayed", swapDelayed outcome), ("after", swapAfter outcome)], result ← results, not (resultPassed result)] $ \(name, result) →
    hPutStrLn stderr ("failed " <> name <> " probe " <> Text.unpack (probeName (resultProbe result)) <> ": observed " <> show (resultObserved result))
  putStrLn ("swap evidence: " <> if swapPassed outcome then "every probe and check passed" else "failed")

-- | Print the evidence's outcome: where it was written, each probe, and the
-- verdict.
summarize ∷ Evidence → IO ()
summarize outcome = do
  forM_ (evidencePng outcome) (\path → putStrLn ("capture: " <> path))
  putStrLn ("probe record: " <> evidenceRecord outcome)
  putStrLn ("BC7: " <> maybe "not reached" (\drawn → if drawn then "supported and drawn" else "not supported by the device, as it reports; skipped") (evidenceBc7 outcome))
  forM_ (evidenceFailure outcome) (\failure → hPutStrLn stderr ("evidence failed: " <> Text.unpack failure))
  forM_ (evidenceProbes outcome) $ \result →
    putStrLn ((if resultPassed result then "pass " else "FAIL ") <> Text.unpack (probeName (resultProbe result)) <> ": " <> show (resultObserved result))
  putStrLn ("evidence: " <> if evidencePassed outcome then "every probe passed" else "failed")

-- | Make, upload and register the scene's textures before the window is
-- admitted, then publish the drawing for the renderer.
prepareWindowed ∷ VulkanHost () → TVar (Maybe Sprites) → IO ()
prepareWindowed vulkan ready = case hostOf vulkan of
 Host {hostAct = actOn, hostUpload = upload} → do
  made ← actOn "making the ring, the table, the textures and the layout" makeSprites
  case made of
    Left failure → hPutStrLn stderr (Text.unpack failure) >> exitFailure
    Right textures → do
      uploads ← traverse upload (uploadRequests textures)
      either (\failure → hPutStrLn stderr ("an upload did not complete: " <> Text.unpack failure) >> exitFailure) (const (pure ())) (sequence uploads)
      registered ← actOn "registering the textures" (\builders → registerSprites builders textures)
      either (\failure → hPutStrLn stderr (Text.unpack failure) >> exitFailure) (atomically . writeTVar ready . Just) registered

-- | The scene as the host's renderer: a frame of the window's format and
-- extent, cleared, and — once the textures are registered — the scene drawn
-- across it.
spritesRenderer ∷ TVar (Maybe Sprites) → VulkanRenderer scene
spritesRenderer ready = VulkanRenderer $ \_ request construction recorder →
  readTVarIO ready >>= \case
    Nothing → pure (Right ())
    Just sprites →
      let SurfaceExtent width height = requestExtent request
       in pipelineFor (buildersOf construction) sprites (requestFormat request) >>= \case
            Left refusal → pure (Left refusal)
            Right pipeline → recordScene sprites pipeline (Frame width height) recorder

-- | Hand the window over and run the composed loop, asking for a frame
-- whenever the last was presented, until the window is closed.
render ∷ Logger → VulkanHost () → RuntimeControl → TVar Int → IO ()
render logger vulkan control presented = do
  windows ← atomically (hostWindowIdentities (vulkanWindowHost vulkan))
  forM_ windows $ \window →
    handOverVulkanTarget vulkan window RequiredTarget >>= \case
      VulkanTargetHandedOver _ → pure ()
      other → hPutStrLn stderr ("the window was not handed over: " <> show other) >> exitFailure
  asked ← newTVarIO (0 ∷ Int)
  runVulkanOwnerLoop vulkan control . defaultScheduledHooks logger $ \turn → do
    forM_ (turnCloseRequests (scheduledTurn turn)) $ \request →
      () <$ honourHostCloseRequest (vulkanWindowHost vulkan) request
    open ← atomically (hostWindowIdentities (vulkanWindowHost vulkan))
    done ← readTVarIO presented
    wanted ← readTVarIO asked
    when (done >= wanted) $
      forM_ open $ \window →
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
