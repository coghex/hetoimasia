{-# LANGUAGE OverloadedRecordDot #-}

-- | VK-7's native cases: the production Vulkan roots, run by the supervised
-- graphics owner, over two windows of a real GLFW session.
--
-- A fourth session, after VK-5's, on this same main thread. It uses no
-- stand-in for anything it proves: the composition is the integration
-- package's own 'withVulkanOwnerHost' over the native package's production
-- layer and the GLFW package's production surface bridge — exactly what
-- 'withVulkanOwnerHost' composes — inside a diagnostic lifetime whose capture both of
-- the instance's messengers report into. The only thing the session adds is a
-- 'NativeObserver', which records at every native call the OS thread it ran on
-- — read at the call itself, through @pthread_self@ — and how many reports the
-- capture received during it.
--
-- It observes, in order:
--
-- * the instance, created on the graphics owner's thread, with the profile's
--   extensions and the validation layer;
-- * two windows' surfaces, each created through GLFW on the main thread inside
--   its attachment's construction, and the one device selected against the
--   first and shared by both, created on the owner's thread;
-- * the first-created window closed while the second stays attached: its
--   surface destroyed on the owner's thread, its window released, and the
--   device, the instance and the second target still live;
-- * the exit: the second surface, the device, the explicit messenger and the
--   instance destroyed on the owner's thread, in that order, with the reports
--   the explicit messenger received during child teardown counted apart from
--   the ones the create-info messenger received during @vkDestroyInstance@;
-- * and the capture's verdict, read once its lifetime has ended.
--
-- Like the other sessions, nothing here asserts. It records what it saw, and
-- "Test.Vulkan.Proof.RootsSpec" decides.
module Test.Vulkan.Proof.Roots
  ( RootsOutcome (..)
  , RootsFacts (..)
  , NativeCall (..)
  , runRoots
  , rootsCaptureConfig
  , teardownReports
  ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM (atomically, check)
import Control.Exception (SomeException, displayException, throwIO, try)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as Char8
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)

import Hetoimasia.Foundation.Log
  ( DebugSelection (DebugAll)
  , LogFilter (..)
  , LogLevel (Info)
  , Logger
  , callbackSink
  , mkLogger
  )
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GLFW.Window (hiddenTestWindowConfig)
import Hetoimasia.GPU.Model.Budget (defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.Diagnostics
  ( CaptureConfig (..)
  , CaptureCounters (..)
  , CaptureStatus (..)
  , DiagnosticCapture
  , DiagnosticVerdict
  , captureStatus
  , defaultCaptureConfig
  )
import Hetoimasia.GPU.Vulkan.GLFW
  ( NativeObserver (..)
  , Readiness (..)
  , VulkanHandover (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , handOverVulkanTarget
  , readReadiness
  , readVulkanRoots
  , readVulkanTargets
  , vulkanHostConfig
  , withVulkanOwnerHost
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (RootTargetView (..), RootsView (..))
import Hetoimasia.Runtime.GLFW
  ( CloseStart (..)
  , LoopHooks (..)
  , TargetStanding (..)
  , Turn (..)
  , TurnStep (..)
  , closeHostWindow
  , defaultHostConfig
  , graphicsAttachment
  , hostWindowIdentities
  , noApplicationEvents
  , readTargetStanding
  , runGraphicsOwnerApplication
  , runOwnerLoop
  )
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Test.Vulkan.Proof.Interop (osThread)
import Test.Vulkan.Proof.Journal (Journal, heading, note)

-- | One native call, where it ran, and what the capture received during it.
data NativeCall = NativeCall
  { callName ∷ !Text
  , callOsThread ∷ !Word64
  , callHaskellThread ∷ !ThreadId
  , callReports ∷ !Word64
    -- ^ Reports the capture's callback received between the call's start and
    -- its return. Vulkan invokes a messenger only from inside a Vulkan call,
    -- so these arrived during it.
  , callRaised ∷ !(Maybe Text)
  }
  deriving (Show)

data RootsFacts = RootsFacts
  { rootsMainOsThread ∷ !Word64
  , rootsMainHaskellThread ∷ !ThreadId
  , rootsCalls ∷ ![NativeCall]
    -- ^ Every observed native call, in the order they returned.
  , rootsReadiness ∷ !Text
  , rootsTargets ∷ ![(TargetClass, Word64)]
    -- ^ The roots' targets once both windows were handed over.
  , rootsBeforeClose ∷ !RootsView
  , rootsAfterClose ∷ !RootsView
  , rootsSecondAfterClose ∷ !(Maybe TargetStanding)
  , rootsWindowsAfterClose ∷ !Int
  , rootsVerdict ∷ !DiagnosticVerdict
  }
  deriving (Show)

data RootsOutcome
  = RootsProved RootsFacts
  | RootsStopped Text [NativeCall]
  deriving (Show)

-- | The capture limits this session runs under: the design's defaults, with
-- the text budget VK-6's session raised to so MoltenVK's routine extension
-- listing arrives whole.
rootsCaptureConfig ∷ CaptureConfig
rootsCaptureConfig = defaultCaptureConfig {captureTextBudget = 16384}

-- | The validation layer, which the provisioned layer path supplies.
validationLayer ∷ Text
validationLayer = "VK_LAYER_KHRONOS_validation"

-- | Reports received during child teardown — through the explicit messenger,
-- which is live until its own destruction — and during @vkDestroyInstance@,
-- through the create-info messenger alone.
teardownReports ∷ [NativeCall] → (Word64, Word64)
teardownReports calls =
  ( sum [callReports call | call ← teardown, callName call /= "vkDestroyInstance"]
  , sum [callReports call | call ← teardown, callName call == "vkDestroyInstance"]
  )
  where
    teardown = dropWhile ((/= "vkDestroySurfaceKHR") . callName) calls

-- | Run the session on the process main thread.
runRoots ∷ Journal → IO RootsOutcome
runRoots journal = do
  heading journal "VK-7: the Vulkan roots under the graphics owner"
  recorded ← newIORef []
  outcome ← try @SomeException (session journal recorded)
  case outcome of
    Right facts → pure (RootsProved facts)
    Left failure → do
      let reason = Text.pack (displayException failure)
      note journal ("the roots session stopped: " <> reason)
      RootsStopped reason . reverse <$> readIORef recorded

stopWith ∷ Text → IO a
stopWith reason = throwIO (userError (Text.unpack reason))

session ∷ Journal → IORef [NativeCall] → IO RootsFacts
session journal recorded = do
  mainOs ← osThread
  mainHaskell ← myThreadId
  scene ← prepare ()
  budgets ← either (stopWith . Text.pack . show) pure (validateBudgets defaultBudgetRequest)
  verdictCell ← newIORef Nothing
  let windows = [hiddenTestWindowConfig "hetoimasia VK-7 first" 320 240, hiddenTestWindowConfig "hetoimasia VK-7 second" 320 240]
      host = defaultHostConfig windows
      config =
        (vulkanHostConfig host rootsCaptureConfig budgets scene)
          { vulkanLayers = [encode validationLayer]
          , vulkanObserver = observer recorded
          }
  observed ←
    withLoaderIntegration $ \integration →
      runGraphicsOwnerApplication
        (withLoggingLifetime quietLogger)
        "vulkan-proof-vk7"
        ( \_ use → do
            (result, verdict) ← withVulkanOwnerHost quietLogger integration config use
            writeIORef verdictCell (Just verdict)
            pure result
        )
        vulkanWindowHost
        (\vulkan _ → pure vulkan)
        (body journal)
  verdict ← readIORef verdictCell >>= maybe (stopWith "the diagnostic lifetime gave no verdict") pure
  calls ← reverse <$> readIORef recorded
  let (readiness, targets, before, after, second, remaining) = observed
      (explicit, createInfo) = teardownReports calls
  note journal ("the explicit messenger received " <> tshow explicit <> " reports during child teardown")
  note journal ("the create-info messenger received " <> tshow createInfo <> " reports during vkDestroyInstance")
  pure
    RootsFacts
      { rootsMainOsThread = mainOs
      , rootsMainHaskellThread = mainHaskell
      , rootsCalls = calls
      , rootsReadiness = readiness
      , rootsTargets = targets
      , rootsBeforeClose = before
      , rootsAfterClose = after
      , rootsSecondAfterClose = second
      , rootsWindowsAfterClose = remaining
      , rootsVerdict = verdict
      }

type Observed = (Text, [(TargetClass, Word64)], RootsView, RootsView, Maybe TargetStanding, Int)

body ∷ Journal → VulkanHost () → RuntimeControl → IO Observed
body journal vulkan control = do
  readiness ← atomically $ do
    state ← readReadiness (vulkanController vulkan)
    check (state /= RootsPending)
    pure state
  case readiness of
    RootsFailed reason → stopWith ("the owner's startup failed: " <> reason)
    _ → pure ()
  note journal "the owner created the instance and its explicit messenger, and leased it to the surface bridge"
  windows ← atomically (hostWindowIdentities (vulkanWindowHost vulkan))
  (first, second) ← case windows of
    [one, two] → pure (one, two)
    other → stopWith ("the host holds " <> tshow (length other) <> " windows, not two")
  _ ← handOver first RequiredTarget
  two ← handOver second RequiredTarget
  targets ← atomically (readVulkanTargets (vulkanController vulkan))
  before ← atomically (readVulkanRoots (vulkanController vulkan))
  note journal ("both targets admitted on " <> maybe "no device" id (viewDeviceName before) <> ", queue family " <> maybe "none" tshow (viewQueueFamily before))
  closed ← closeHostWindow (vulkanWindowHost vulkan) first
  case closed of
    CloseStarted → pure ()
    other → stopWith ("closing the first window answered " <> tshow other)
  pumpUntil vulkan control $ notElem first <$> atomically (hostWindowIdentities (vulkanWindowHost vulkan))
  after ← atomically (readVulkanRoots (vulkanController vulkan))
  standing ← atomically (readTargetStanding (vulkanGraphicsOwner vulkan) (graphicsAttachment two))
  remaining ← length <$> atomically (hostWindowIdentities (vulkanWindowHost vulkan))
  note journal ("after the first window closed: device " <> tshow (viewDevice after) <> ", instance " <> tshow (viewInstance after) <> ", " <> tshow (length (viewTargets after)) <> " target")
  pure
    ( tshow readiness
    , [(targetViewClass view, targetViewSurface view) | (_, view) ← targets]
    , before
    , after
    , standing
    , remaining
    )
  where
    handOver window classification =
      handOverVulkanTarget vulkan window classification >>= \case
        VulkanTargetHandedOver service →
          atomically (readTargetStanding (vulkanGraphicsOwner vulkan) (graphicsAttachment service) >>= maybe retrying settled) >>= \case
            TargetUsable → pure service
            standing → stopWith ("the target was not admitted: " <> tshow standing)
        other → stopWith ("the window was not handed over: " <> tshow other)
    settled = \case
      TargetConstructing → retrying
      standing → pure standing
    retrying = check False >> pure TargetConstructing

-- | Turn the owner loop on the main thread until the condition holds, as a
-- window's close retires on turns.
pumpUntil ∷ VulkanHost () → RuntimeControl → IO Bool → IO ()
pumpUntil vulkan control ready =
  runOwnerLoop
    (vulkanWindowHost vulkan)
    control
    LoopHooks
      { loopLogger = quietLogger
      , loopEvent = noApplicationEvents
      , loopUpdate = \turn → do
          done ← ready
          if done
            then pure (Finish ())
            else
              if turnNumber turn > 5000
                then stopWith "the first window's close never finished"
                else pure Continue
      }

-- | Record, around every native call, the OS thread it ran on and the reports
-- the capture received meanwhile.
observer ∷ IORef [NativeCall] → DiagnosticCapture → NativeObserver
observer recorded capture = NativeObserver $ \name call → do
  onOs ← osThread
  onHaskell ← myThreadId
  before ← offered
  outcome ← try @SomeException call
  after ← offered
  let raised = either (Just . Text.pack . displayException) (const Nothing) outcome
  modifyIORef' recorded (NativeCall name onOs onHaskell (after - before) raised :)
  either throwIO pure outcome
  where
    offered = countOffered . statusCounters <$> captureStatus capture

quietLogger ∷ Logger
quietLogger =
  mkLogger
    LogFilter
      { filterEnabled = True
      , filterGlobalLevel = Info
      , filterComponentLevels = Map.empty
      , filterDebug = DebugAll
      , filterSource = False
      }
    (callbackSink (\_ → pure ()))

encode ∷ Text → ByteString
encode = Char8.pack . Text.unpack

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
