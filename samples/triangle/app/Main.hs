-- | @hetoimasia-triangle@: one triangle in each of two windows sharing one
-- Vulkan device, drawn through the window integration's public host.
--
-- It opens two windows, hands each to the host's graphics owner, and asks
-- each for a new frame as soon as its last one was presented, so each renders
-- continuously at the rate its swapchain presents. Everything else is the
-- host's delivered behaviour: a window resized is rebuilt at its new size, a
-- minimized or zero-area one suspends rendering until it is restored, a window
-- whose close button is pressed is closed and retires alone while the other
-- keeps rendering, and once every window has closed — or after @--seconds@,
-- when that is given — the application exits, the host retiring the targets,
-- the device and the instance in order before the windows go. It prints each
-- window's presented frames and the diagnostic verdict at the end, and exits 0
-- only when that verdict is clean.
--
-- > hetoimasia-triangle [--frame-slots 1|2] [--seconds N] [--validation]
--
-- @--frame-slots@ chooses the model's frame budget (two by default);
-- @--validation@ enables the validation layer with synchronization
-- validation, which the provisioned prefix supplies.
--
-- It is launched explicitly and nothing routine runs it: it opens windows on
-- the desktop it is started on. See @samples/triangle/README.md@.
module Main (main) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO, retry, writeTVar)
import Control.Monad (forM, forM_, unless, when)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Numeric.Natural (Natural)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitWith, ExitCode (ExitFailure))
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

import Hetoimasia.Foundation.Log (Logger, defaultLogFilter)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.GLFW.Command (clientDemandPublisher)
import Hetoimasia.GLFW.Demand (immediateDemand, publishDemand)
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GLFW.Window (WindowConfig (..), WindowId, defaultWindowConfig)
import Hetoimasia.GPU.Model.Budget (BudgetRequest (..), defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.Diagnostics (CaptureConfig (..), DiagnosticVerdict, defaultCaptureConfig, verdictIssues)
import Hetoimasia.GPU.Vulkan.GLFW
  ( FrameEvent (..)
  , FrameRequest (..)
  , Readiness (..)
  , ValidationFeature (..)
  , VulkanHandover (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , VulkanRenderer (..)
  , constructPipeline
  , constructPipelineLayout
  , handOverVulkanTarget
  , readReadiness
  , runVulkanOwnerLoop
  , vulkanHostConfig
  , withVulkanOwnerHost
  )
import Hetoimasia.Runtime.GLFW
  ( AttachmentId
  , ScheduledStep (..)
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
import Hetoimasia.Sample.Triangle (Builders (..), Triangle, drawTriangle, newTriangle)

-- | What the command line asked for.
data Options = Options
  { optionSlots ∷ !Natural
  , optionSeconds ∷ !(Maybe Double)
  , optionValidation ∷ !Bool
  }

parseOptions ∷ [String] → Either String Options
parseOptions = go (Options 2 Nothing False)
  where
    go options = \case
      [] → Right options
      "--frame-slots" : value : rest
        | Just slots ← readMaybe value, slots `elem` [1, 2] → go options {optionSlots = slots} rest
        | otherwise → Left ("--frame-slots takes 1 or 2, not " <> value)
      "--seconds" : value : rest
        | Just seconds ← readMaybe value, seconds > 0 → go options {optionSeconds = Just seconds} rest
        | otherwise → Left ("--seconds takes a positive number, not " <> value)
      "--validation" : rest → go options {optionValidation = True} rest
      other : _ → Left ("unknown argument " <> other)

usage ∷ String
usage = "usage: hetoimasia-triangle [--frame-slots 1|2] [--seconds N] [--validation]"

main ∷ IO ()
main =
  parseOptions <$> getArgs >>= \case
    Left problem → hPutStrLn stderr (problem <> "\n" <> usage) >> exitWith (ExitFailure 2)
    Right options → run options

run ∷ Options → IO ()
run options = do
  budgets ← either (\problem → hPutStrLn stderr ("the frame budget was refused: " <> show problem) >> exitFailure) pure $
    validateBudgets defaultBudgetRequest {requestedFrameSlots = fromIntegral (optionSlots options)}
  scene ← prepare ()
  triangle ← newTriangle
  presented ← newTVarIO (Map.empty ∷ Map AttachmentId Int)
  let window title = (defaultWindowConfig title 480 360) {windowFocused = False, windowFocusOnShow = False}
      host = defaultHostConfig [window "hetoimasia triangle, first", window "hetoimasia triangle, second"]
      -- The validation layer's messages are long; the capture keeps each one
      -- whole rather than truncating it, which the verdict would report.
      capture = if optionValidation options then defaultCaptureConfig {captureTextBudget = 16384} else defaultCaptureConfig
      base = vulkanHostConfig host capture budgets scene
      config =
        base
          { vulkanRenderer = triangleRenderer triangle
          , vulkanFrameObserver = \case
              FramePresented attachment _ _ _ → atomically (modifyTVar' presented (Map.insertWith (+) attachment 1))
              _ → pure ()
          , vulkanLayers = ["VK_LAYER_KHRONOS_validation" | optionValidation options]
          , vulkanValidationFeatures = [SynchronizationValidation | optionValidation options]
          }
  verdictHeld ← newTVarIO Nothing
  loggerHeld ← newTVarIO Nothing
  withLoaderIntegration $ \integration →
    runGraphicsOwnerApplication
      (withHandleLoggingLifetime defaultLogFilter stderr)
      "hetoimasia-triangle"
      ( \lifetime use → do
          atomically (writeTVar loggerHeld (Just (lifetimeLogger lifetime)))
          (result, verdict) ← withVulkanOwnerHost (lifetimeLogger lifetime) integration config use
          atomically (writeTVar verdictHeld (Just verdict))
          pure result
      )
      vulkanWindowHost
      (\vulkan _ → pure vulkan)
      (\vulkan control → do
          _ ← superviseGraphicsOwner control (vulkanGraphicsOwner vulkan)
          deadline ← traverse (\seconds → addUTCTime (realToFrac seconds) <$> getCurrentTime) (optionSeconds options)
          logger ← readTVarIO loggerHeld >>= maybe (hPutStrLn stderr "the logging lifetime was never opened" >> exitFailure) pure
          render logger vulkan control presented deadline)
  counts ← readTVarIO presented
  verdict ← readTVarIO verdictHeld
  forM_ (zip [1 ∷ Int ..] (Map.elems counts)) $ \(number, count) →
    putStrLn ("window " <> show number <> ": " <> show count <> " frames presented")
  report verdict

-- | Wait for the owner to lease its instance, hand both windows over, then
-- run the composed loop, asking each window
-- for a frame whenever its last one has been presented, and honouring every
-- close request, until no window is left or the deadline has passed.
render ∷ Logger → VulkanHost () → RuntimeControl → TVar (Map AttachmentId Int) → Maybe UTCTime → IO ()
render logger vulkan control presented deadline = do
  readiness ← atomically $
    readReadiness (vulkanController vulkan) >>= \case
      RootsPending → retry
      other → pure other
  case readiness of
    RootsFailed reason → hPutStrLn stderr ("the graphics owner did not start: " <> Text.unpack reason) >> exitFailure
    _ → pure ()
  windows ← atomically (hostWindowIdentities (vulkanWindowHost vulkan))
  attachments ← forM windows $ \window →
    handOverVulkanTarget vulkan window RequiredTarget >>= \case
      VulkanTargetHandedOver service → pure (window, graphicsAttachment service)
      other → hPutStrLn stderr ("a window was not handed over: " <> show other) >> exitFailure
  asked ← newTVarIO (Map.empty ∷ Map AttachmentId Int)
  runVulkanOwnerLoop vulkan control . defaultScheduledHooks logger $ \turn → do
    forM_ (turnCloseRequests (scheduledTurn turn)) $ \request →
      () <$ honourHostCloseRequest (vulkanWindowHost vulkan) request
    open ← atomically (hostWindowIdentities (vulkanWindowHost vulkan))
    forM_ [(window, attachment) | (window, attachment) ← attachments, window `elem` open] $ \(window, attachment) →
      demand window attachment asked
    now ← getCurrentTime
    let expired = maybe False (now >=) deadline
    pure (if null open || expired then FinishWith () else ContinueWith NoUpdateDemand)
  where
    demand ∷ WindowId → AttachmentId → TVar (Map AttachmentId Int) → IO ()
    demand window attachment asked = do
      done ← Map.findWithDefault 0 attachment <$> readTVarIO presented
      wanted ← Map.findWithDefault 0 attachment <$> readTVarIO asked
      when (done >= wanted) $
        atomically (hostWindowClient (vulkanWindowHost vulkan) window) >>= \case
          Nothing → pure ()
          Just client → do
            _ ← publishDemand (clientDemandPublisher client) immediateDemand
            atomically (modifyTVar' asked (Map.insert attachment (done + 1)))

-- | The sample's drawing as the host's renderer: each frame's format and
-- extent, and the two constructions it lends.
triangleRenderer ∷ Triangle → VulkanRenderer scene
triangleRenderer triangle = VulkanRenderer $ \_ request construction recorder →
  drawTriangle
    triangle
    (Builders (constructPipelineLayout construction) (constructPipeline construction))
    (requestFormat request)
    (requestExtent request)
    recorder

-- | Say what the verdict found, and exit 1 unless it is clean.
report ∷ Maybe DiagnosticVerdict → IO ()
report = \case
  Nothing → hPutStrLn stderr "no diagnostic verdict was reached" >> exitFailure
  Just verdict → do
    let issues = verdictIssues verdict
    putStrLn ("diagnostic verdict: " <> (if null issues then "clean" else Text.unpack (Text.pack (show issues))))
    unless (null issues) exitFailure
