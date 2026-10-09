-- | @hetoimasia-scene3d@: the scene3d sample's two flat-coloured cubes, one in
-- front of the other, drawn indexed with a depth test from two camera poses
-- through the window integration's public host (GRS-10).
--
-- > hetoimasia-scene3d --evidence --output-dir DIRECTORY [--validation]
--
-- @--evidence@ starts a surface-free session, opens no window, renders the
-- scene from each of two camera poses into a 256×192 linear RGBA8 target with
-- a depth target, reads each back once its batch has completed, checks every
-- probe against the independent oracle, and writes @scene3d-front.png@,
-- @scene3d-side.png@ and @scene3d-probes.json@ into the directory
-- ("Hetoimasia.Sample.Scene3d.Evidence"). It exits 0 only when every probe
-- passed and the diagnostic verdict is clean. @--validation@ enables the
-- validation layer with synchronization validation, which the provisioned
-- prefix supplies.
--
-- There is no windowed mode yet: it arrives with windowed depth (GRS-13),
-- which follows swapchain generations. The executable holds no native handle
-- and makes no GLFW or Vulkan call of its own. See
-- @samples/scene3d/README.md@.
module Main (main) where

import Control.Concurrent.STM (atomically, newTVarIO, readTVarIO, retry, writeTVar)
import Control.Monad (forM_, unless)
import Data.Text (Text)
import qualified Data.Text as Text
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitFailure, exitWith)
import System.IO (hPutStrLn, stderr)

import Hetoimasia.Foundation.Log (defaultLogFilter)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Time (Duration, DurationRequirement (AllowZero), durationFromNanoseconds)
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GPU.Model.Budget (BudgetRequest (..), defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Vulkan.Diagnostics (CaptureConfig (..), DiagnosticVerdict, defaultCaptureConfig, verdictIssues)
import Hetoimasia.GPU.Vulkan.GLFW
  ( ActionOutcome (..)
  , Construction
  , Readiness (..)
  , Refusal
  , TicketState (..)
  , ValidationFeature (..)
  , VulkanAction (..)
  , VulkanDeviceStart (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , awaitTicket
  , awaitVulkanAction
  , constructDepthCheckedPipeline
  , constructDepthFormat
  , constructFramelessBatch
  , constructImage
  , constructPipelineLayoutFor
  , constructReadback
  , constructRing
  , readConstructedReadback
  , readReadiness
  , submitVulkanAction
  , vulkanHostConfig
  , withVulkanOwnerHost
  )
import Hetoimasia.Runtime.GLFW (defaultHostConfig, runGraphicsOwnerApplication)
import Hetoimasia.Runtime.Logging (lifetimeLogger, withHandleLoggingLifetime)
import Hetoimasia.Sample.Scene3d (Builders (..))
import Hetoimasia.Sample.Scene3d.Evidence (Evidence (..), Host (..), PoseEvidence (..), runEvidence)
import Hetoimasia.Sample.Scene3d.Oracle (ProbeResult (..))
import Hetoimasia.Sample.Scene3d.Scene (Probe (..), targetBytes)

data Options = Options
  { optionEvidence ∷ !Bool
  , optionOutput ∷ !(Maybe FilePath)
  , optionValidation ∷ !Bool
  }

-- | The evidence directory and whether validation is enabled.
parseOptions ∷ [String] → Either String (FilePath, Bool)
parseOptions arguments = go (Options False Nothing False) arguments >>= finish
  where
    go options = \case
      [] → Right options
      "--evidence" : rest → go options {optionEvidence = True} rest
      "--output-dir" : directory : rest → go options {optionOutput = Just directory} rest
      "--validation" : rest → go options {optionValidation = True} rest
      "--windowed" : _ → Left "there is no windowed mode yet: it arrives with windowed depth (GRS-13)"
      other : _ → Left ("unknown argument " <> other)
    finish options = case (optionEvidence options, optionOutput options) of
      (True, Just directory) → Right (directory, optionValidation options)
      (True, Nothing) → Left "--evidence needs --output-dir DIRECTORY"
      (False, _) → Left "choose --evidence --output-dir DIRECTORY"

usage ∷ String
usage = "usage: hetoimasia-scene3d --evidence --output-dir DIRECTORY [--validation]"

main ∷ IO ()
main =
  parseOptions <$> getArgs >>= \case
    Left problem → hPutStrLn stderr (problem <> "\n" <> usage) >> exitWith (ExitFailure 2)
    Right (directory, validation) → run directory validation

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
