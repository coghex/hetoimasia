-- | @hetoimasia-scene3d@: the scene3d sample's two flat-coloured cubes, one in
-- front of the other, drawn indexed with a depth test through the window
-- integration's public host (GRS-10, GRS-13).
--
-- > hetoimasia-scene3d --evidence --output-dir DIRECTORY [--validation]
-- > hetoimasia-scene3d --windowed [--seconds N] [--validation]
--
-- @--evidence@ starts a surface-free session, opens no window, renders the
-- scene from each of two camera poses into a 256×192 linear RGBA8 target with
-- a depth target, reads each back once its batch has completed, checks every
-- probe against the independent oracle, and writes @scene3d-front.png@,
-- @scene3d-side.png@ and @scene3d-probes.json@ into the directory
-- ("Hetoimasia.Sample.Scene3d.Evidence"). It exits 0 only when every probe
-- passed and the diagnostic verdict is clean.
--
-- @--windowed@ opens one window whose host asked for windowed depth
-- ('vulkanWindowDepth'): each frame is drawn into the window's own image with
-- the depth image of its swapchain generation, from a camera that slowly
-- orbits the scene ("Hetoimasia.Sample.Scene3d.Windowed"), as fast as the
-- swapchain presents, until the window is closed or after @--seconds@. A
-- window resized is rebuilt at its new size with a depth image of its own, as
-- the host delivers. It prints the frames presented and the diagnostic
-- verdict at the end, and exits 0 only when that verdict is clean. It is
-- launched explicitly and nothing routine runs it: it opens a window on the
-- desktop it is started on.
--
-- @--validation@ enables the validation layer with synchronization
-- validation, which the provisioned prefix supplies. The executable holds no
-- native handle and makes no GLFW or Vulkan call of its own. See
-- @samples/scene3d/README.md@.
module Main (main) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO, retry, writeTVar)
import Control.Monad (forM_, unless, when)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitFailure, exitWith)
import System.IO (hPutStrLn, stderr)

import Hetoimasia.Foundation.Log (Logger, defaultLogFilter)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Time (Duration, DurationRequirement (AllowZero), durationFromNanoseconds)
import Hetoimasia.GLFW.Command (clientDemandPublisher)
import Hetoimasia.GLFW.Demand (immediateDemand, publishDemand)
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GLFW.Window (defaultWindowConfig)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Model.Budget (BudgetRequest (..), defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Vulkan.Diagnostics (CaptureConfig (..), DiagnosticVerdict, defaultCaptureConfig, verdictIssues)
import Hetoimasia.GPU.Vulkan.GLFW
  ( ActionOutcome (..)
  , Construction
  , FrameEvent (..)
  , FrameRequest (..)
  , Readiness (..)
  , Refusal (..)
  , TicketState (..)
  , ValidationFeature (..)
  , VulkanAction (..)
  , VulkanDeviceStart (..)
  , VulkanHandover (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , VulkanRenderer (..)
  , awaitTicket
  , awaitVulkanAction
  , constructDepthCheckedPipeline
  , constructDepthFormat
  , constructFramelessBatch
  , constructImage
  , constructPipelineLayoutFor
  , constructReadback
  , constructRing
  , handOverVulkanTarget
  , readConstructedReadback
  , readReadiness
  , runVulkanOwnerLoop
  , submitVulkanAction
  , vulkanHostConfig
  , withVulkanOwnerHost
  )
import Hetoimasia.Runtime.GLFW
  ( ScheduledStep (..)
  , ScheduledTurn (..)
  , Turn (..)
  , UpdateSchedule (..)
  , defaultHostConfig
  , defaultScheduledHooks
  , graphicsAttachment
  , honourHostCloseRequest
  , hostWindowClient
  , hostWindowIdentities
  , runGraphicsOwnerApplication
  , superviseGraphicsOwner
  )
import Hetoimasia.Runtime.Logging (lifetimeLogger, withHandleLoggingLifetime)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Hetoimasia.Sample.Scene3d (Builders (..))
import Hetoimasia.Sample.Scene3d.Windowed (WindowedFrame (..), WindowedScene, drawWindowed, newWindowedScene, orbitDegreesPerFrame, orbitPose)
import Hetoimasia.Sample.Scene3d.Evidence (Evidence (..), Host (..), PoseEvidence (..), runEvidence)
import Hetoimasia.Sample.Scene3d.Oracle (ProbeResult (..))
import Hetoimasia.Sample.Scene3d.Scene (Probe (..), targetBytes)

-- | What the command line asked for.
data Mode
  = EvidenceMode !FilePath
  | WindowedMode !(Maybe Double)

data Options = Options
  { optionEvidence ∷ !Bool
  , optionWindowed ∷ !Bool
  , optionOutput ∷ !(Maybe FilePath)
  , optionSeconds ∷ !(Maybe Double)
  , optionValidation ∷ !Bool
  }

-- | The mode and whether validation is enabled.
parseOptions ∷ [String] → Either String (Mode, Bool)
parseOptions arguments = go (Options False False Nothing Nothing False) arguments >>= finish
  where
    go options = \case
      [] → Right options
      "--evidence" : rest → go options {optionEvidence = True} rest
      "--windowed" : rest → go options {optionWindowed = True} rest
      "--output-dir" : directory : rest → go options {optionOutput = Just directory} rest
      "--seconds" : value : rest
        | [(seconds, "")] ← reads value, seconds > 0 → go options {optionSeconds = Just seconds} rest
        | otherwise → Left ("--seconds takes a positive number, not " <> value)
      "--validation" : rest → go options {optionValidation = True} rest
      other : _ → Left ("unknown argument " <> other)
    finish options = case (optionEvidence options, optionWindowed options, optionOutput options, optionSeconds options) of
      (True, False, Just directory, Nothing) → Right (EvidenceMode directory, optionValidation options)
      (True, False, Nothing, _) → Left "--evidence needs --output-dir DIRECTORY"
      (True, False, _, Just _) → Left "--seconds belongs to --windowed"
      (False, True, Nothing, seconds) → Right (WindowedMode seconds, optionValidation options)
      (False, True, Just _, _) → Left "--output-dir belongs to --evidence"
      (True, True, _, _) → Left "choose --evidence or --windowed, not both"
      (False, False, _, _) → Left "choose --evidence --output-dir DIRECTORY or --windowed"

usage ∷ String
usage = "usage: hetoimasia-scene3d --evidence --output-dir DIRECTORY [--validation]\n       hetoimasia-scene3d --windowed [--seconds N] [--validation]"

main ∷ IO ()
main =
  parseOptions <$> getArgs >>= \case
    Left problem → hPutStrLn stderr (problem <> "\n" <> usage) >> exitWith (ExitFailure 2)
    Right (EvidenceMode directory, validation) → run directory validation
    Right (WindowedMode seconds, validation) → runWindowed seconds validation

run ∷ FilePath → Bool → IO ()
run directory validation = do
  budgets ← either (\problem → hPutStrLn stderr ("the budgets were refused: " <> show problem) >> exitFailure) pure $
    validateBudgets defaultBudgetRequest {requestedBytes = 2 * 1024 * 1024 * 1024}
  scene ← prepare ()
  let capture = if validation then defaultCaptureConfig {captureTextBudget = 16384} else defaultCaptureConfig
      config =
        (vulkanHostConfig (defaultHostConfig []) capture budgets scene)
          { vulkanDeviceStart = DeviceSurfaceFree
          , vulkanLayers = ["VK_LAYER_KHRONOS_validation" | validation]
          , vulkanValidationFeatures = [SynchronizationValidation | validation]
          }
  verdictHeld ← newTVarIO Nothing
  passed ← newTVarIO False
  withLoaderIntegration $ \integration →
    runGraphicsOwnerApplication
      (withHandleLoggingLifetime defaultLogFilter stderr)
      "hetoimasia-scene3d"
      ( \lifetime use → do
          (result, verdict) ← withVulkanOwnerHost (lifetimeLogger lifetime) integration config use
          atomically (writeTVar verdictHeld (Just verdict))
          pure result
      )
      vulkanWindowHost
      (\vulkan _ → pure vulkan)
      ( \vulkan _ → do
          awaitReadiness vulkan
          outcome ← runEvidence (hostOf vulkan) directory
          summarize outcome
          atomically (writeTVar passed (evidencePassed outcome))
      )
  verdict ← readTVarIO verdictHeld
  ok ← readTVarIO passed
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
    , buildImage = constructImage construction
    , buildLayout = constructPipelineLayoutFor construction
    , buildPipeline = constructDepthCheckedPipeline construction
    , buildReadback = constructReadback construction
    , chooseDepthFormat = constructDepthFormat construction
    }

-- | The evidence's host: owner-thread actions over the session's
-- constructions, and batches waited for, each wait bounded by a deadline.
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
    , hostAwait = \ticket →
        awaitTicket ticket deadline >>= \case
          Right TicketComplete → pure (Right ())
          other → pure (Left (tshow other))
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

-- | Print the evidence's outcome: the depth format used, where each capture
-- was written, each probe, and the verdict.
summarize ∷ Evidence → IO ()
summarize outcome = do
  putStrLn ("depth format: " <> maybe "not chosen" show (evidenceDepthFormat outcome))
  forM_ (evidencePoses outcome) $ \pose → do
    forM_ (poseEvidencePng pose) (\path → putStrLn ("capture: " <> path))
    forM_ (poseEvidenceProbes pose) $ \result →
      putStrLn ((if resultPassed result then "pass " else "FAIL ") <> Text.unpack (probeName (resultProbe result)) <> ": observed " <> show (resultObserved result))
  putStrLn ("probe record: " <> evidenceRecord outcome)
  forM_ (evidenceFailure outcome) (\failure → hPutStrLn stderr ("evidence failed: " <> Text.unpack failure))
  putStrLn ("evidence: " <> if evidencePassed outcome then "every probe passed" else "failed")

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

-- ---------------------------------------------------------------------------
-- The windowed mode

-- | One window, drawn into with its swapchain generation's depth image: the
-- host asked for windowed depth, each frame's request names the image, and the
-- scene is drawn from a camera that has turned a little further than the
-- last frame's.
runWindowed ∷ Maybe Double → Bool → IO ()
runWindowed seconds validation = do
  budgets ← either (\problem → hPutStrLn stderr ("the budgets were refused: " <> show problem) >> exitFailure) pure $
    validateBudgets defaultBudgetRequest {requestedBytes = 2 * 1024 * 1024 * 1024}
  scene ← prepare ()
  windowed ← newWindowedScene
  angle ← newIORef 0
  presented ← newTVarIO (0 ∷ Int)
  let host = defaultHostConfig [defaultWindowConfig "hetoimasia scene3d" 800 600]
      capture = if validation then defaultCaptureConfig {captureTextBudget = 16384} else defaultCaptureConfig
      config =
        (vulkanHostConfig host capture budgets scene)
          { vulkanRenderer = windowedRenderer windowed angle
          , vulkanWindowDepth = True
          , vulkanFrameObserver = \case
              FramePresented {} → atomically (modifyTVar' presented (+ 1))
              _ → pure ()
          , vulkanLayers = ["VK_LAYER_KHRONOS_validation" | validation]
          , vulkanValidationFeatures = [SynchronizationValidation | validation]
          }
  verdictHeld ← newTVarIO Nothing
  loggerHeld ← newTVarIO Nothing
  withLoaderIntegration $ \integration →
    runGraphicsOwnerApplication
      (withHandleLoggingLifetime defaultLogFilter stderr)
      "hetoimasia-scene3d"
      ( \lifetime use → do
          atomically (writeTVar loggerHeld (Just (lifetimeLogger lifetime)))
          (result, verdict) ← withVulkanOwnerHost (lifetimeLogger lifetime) integration config use
          atomically (writeTVar verdictHeld (Just verdict))
          pure result
      )
      vulkanWindowHost
      (\vulkan _ → pure vulkan)
      ( \vulkan control → do
          _ ← superviseGraphicsOwner control (vulkanGraphicsOwner vulkan)
          expiry ← traverse (\limit → addUTCTime (realToFrac limit) <$> getCurrentTime) seconds
          logger ← readTVarIO loggerHeld >>= maybe (hPutStrLn stderr "the logging lifetime was never opened" >> exitFailure) pure
          renderWindow logger vulkan control presented expiry
      )
  frames ← readTVarIO presented
  verdict ← readTVarIO verdictHeld
  putStrLn (show frames <> " frames presented")
  report verdict

-- | The sample's windowed drawing as the host's renderer: the frame's extent,
-- color format and depth image, and the camera one step further round.
windowedRenderer ∷ WindowedScene → IORef Double → VulkanRenderer scene
windowedRenderer windowed angle = VulkanRenderer $ \_ request construction recorder →
  case requestDepth request of
    Nothing → pure (Left (RefusedIllegal "the frame's request names no depth image"))
    Just depth → do
      degrees ← atomicModifyIORef' angle (\held → (held + orbitDegreesPerFrame, held))
      drawWindowed windowed (buildersOf construction) (orbitPose degrees) (WindowedFrame (requestExtent request) (requestFormat request) depth) recorder

-- | Wait for the owner to lease its instance, hand the window over, then run
-- the composed loop, asking for a frame whenever the last one has been
-- presented and honouring the window's close request, until it has closed or
-- the deadline has passed.
renderWindow ∷ Logger → VulkanHost () → RuntimeControl → TVar Int → Maybe UTCTime → IO ()
renderWindow logger vulkan control presented expiry = do
  awaitReadiness vulkan
  window ←
    atomically (hostWindowIdentities (vulkanWindowHost vulkan)) >>= \case
      [one] → pure one
      other → hPutStrLn stderr ("the host holds " <> show (length other) <> " windows, not one") >> exitFailure
  handOverVulkanTarget vulkan window RequiredTarget >>= \case
    VulkanTargetHandedOver service → asking window (graphicsAttachment service)
    other → hPutStrLn stderr ("the window was not handed over: " <> show other) >> exitFailure
  where
    asking window _ = do
      asked ← newTVarIO (0 ∷ Int)
      runVulkanOwnerLoop vulkan control . defaultScheduledHooks logger $ \turn → do
        forM_ (turnCloseRequests (scheduledTurn turn)) $ \request →
          () <$ honourHostCloseRequest (vulkanWindowHost vulkan) request
        open ← atomically (hostWindowIdentities (vulkanWindowHost vulkan))
        when (window `elem` open) $ do
          done ← readTVarIO presented
          wanted ← readTVarIO asked
          when (done >= wanted) $
            atomically (hostWindowClient (vulkanWindowHost vulkan) window) >>= \case
              Nothing → pure ()
              Just client → do
                _ ← publishDemand (clientDemandPublisher client) immediateDemand
                atomically (writeTVar asked (done + 1))
        now ← getCurrentTime
        let expired = maybe False (now >=) expiry
        pure (if null open || expired then FinishWith () else ContinueWith NoUpdateDemand)
