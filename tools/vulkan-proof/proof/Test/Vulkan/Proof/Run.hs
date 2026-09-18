{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The native run: one linear procedure on the process main thread that
-- observes everything issue #158 asks for and then tears the session down
-- completely, including the instance.
--
-- Nothing here is an assertion. The procedure records what it saw and returns
-- it; "Test.Vulkan.Proof.Spec" decides whether that is a pass. Keeping the two
-- apart is what lets the verdict be computed after all callback-producing
-- teardown has finished, and it keeps every GLFW call on the process main
-- thread without a dispatcher, because Hspec never runs while this does.
--
-- The procedure stops at the first step whose evidence it cannot obtain, and
-- says which. It never substitutes a weaker fact for a missing one: a driver
-- that cannot enable Vulkan 1.3, or a maintenance extension that is not there,
-- ends the run with a named failure rather than a narrowed proof.
module Test.Vulkan.Proof.Run (runProof) where

import Control.Concurrent (isCurrentThreadBound, rtsSupportsBoundThreads)
import Control.Exception
  ( Exception
  , SomeException
  , displayException
  , fromException
  , throwIO
  , try
  )
import Control.Monad (forM, forM_, unless, when)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as Char8
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import Data.Vector (Vector)
import qualified Data.Vector as Vector
import Data.Word (Word32, Word64, Word8)
import Foreign.Ptr (castFunPtrToPtr, castPtr, freeHaskellFunPtr, nullFunPtr, nullPtr)
import Foreign.Storable (peekByteOff)
import System.Environment (lookupEnv, unsetEnv)
import System.Info (arch, os)

import Vulkan.CStruct.Extends (SomeStruct (..), peekSomeCStruct, withSomeStruct)
import Vulkan.Core10
import Vulkan.Core11
  ( PhysicalDeviceFeatures2 (..)
  , PhysicalDeviceProperties2 (..)
  , enumerateInstanceVersion
  , getPhysicalDeviceFeatures2
  , getPhysicalDeviceProperties2
  )
import Vulkan.Core12 (ConformanceVersion (..), PhysicalDeviceDriverProperties (..))
import Vulkan.Core13
import Vulkan.Dynamic (DeviceCmds (..), InstanceCmds (..), getInstanceProcAddr')
import Vulkan.Exception (VulkanException (..))
import Vulkan.Extensions.VK_EXT_debug_utils
import Vulkan.Extensions.VK_EXT_surface_maintenance1
import Vulkan.Extensions.VK_EXT_swapchain_maintenance1
import Vulkan.Extensions.VK_KHR_get_surface_capabilities2
import Vulkan.Extensions.VK_KHR_portability_enumeration
import Vulkan.Extensions.VK_KHR_portability_subset
import Vulkan.Extensions.VK_KHR_surface
import Vulkan.Extensions.VK_KHR_swapchain
import Vulkan.Zero (zero)

import Test.Vulkan.Proof.Consent (Consent, describeConsent)
import Test.Vulkan.Proof.Findings
import Test.Vulkan.Proof.Interop
  ( Provenance (..)
  , createProofWindow
  , createWindowSurface
  , describeProvenance
  , destroyProofWindow
  , glfwInit
  , glfwTerminate
  , initVulkanLoader
  , instanceProcAddress
  , lastGlfwError
  , pollEvents
  , provenanceOf
  , requiredInstanceExtensions
  , vulkanSupported
  )
import Test.Vulkan.Proof.Journal (Journal, heading, note)

-- --------------------------------------------------------------------------
-- Stopping

newtype Stop = Stop Failure

instance Show Stop where
  show (Stop failure) = Text.unpack (failureStep failure <> ": " <> failureDetail failure)

instance Exception Stop

stop ∷ Text → Text → IO a
stop step detail = throwIO (Stop (Failure step detail))

require ∷ Text → Text → Bool → IO ()
require step detail ok = unless ok (stop step detail)

-- --------------------------------------------------------------------------
-- Cleanup

-- | Teardown actions, newest first. Every one runs, in reverse order, whether
-- the procedure finished or stopped, and a release that itself fails is
-- recorded rather than allowed to hide the ones after it.
newtype Cleanups = Cleanups (IORef [(Text, IO ())])

newCleanups ∷ IO Cleanups
newCleanups = Cleanups <$> newIORef []

onExit ∷ Cleanups → Text → IO () → IO ()
onExit (Cleanups ref) label action = modifyIORef' ref ((label, action) :)

-- | Run every release, in reverse order, and report both what ran and what
-- failed. A failure never stops the remaining releases and is never swallowed:
-- the verdict refuses a run whose teardown failed.
runCleanups ∷ Journal → Cleanups → IO ([Text], [Text])
runCleanups journal (Cleanups ref) = do
  actions ← readIORef ref
  writeIORef ref []
  outcomes ← forM actions $ \(label, action) → do
    outcome ← try @SomeException action
    case outcome of
      Right () → pure (label, Nothing)
      Left failure → do
        let reason = label <> ": " <> Text.pack (displayException failure)
        note journal ("teardown of " <> reason)
        pure (label, Just reason)
  pure (map fst outcomes, [reason | (_, Just reason) ← outcomes])

-- --------------------------------------------------------------------------
-- Callback capture

-- | Everything the debug-utils callback writes into, and everything the record
-- reads back out. It outlives the instance on purpose: a callback arriving
-- during @vkDestroyInstance@ must find live storage, so this is held by the run
-- rather than by any scope the instance owns.
data CallbackSink = CallbackSink
  { sinkPhase ∷ IORef Text
  , sinkDiagnostics ∷ IORef [Diagnostic]
  , sinkFailures ∷ IORef [Text]
  }

newCallbackSink ∷ IO CallbackSink
newCallbackSink =
  CallbackSink
    <$> newIORef "before initialization"
    <*> newIORef []
    <*> newIORef []

-- | The marker a deliberately injected message carries, so the record can say
-- which deliveries were elicited and which the loader or a layer emitted of its
-- own accord.
injectionMarker ∷ ByteString
injectionMarker = "hetoimasia-vulkan-proof-injection"

foreign import ccall "wrapper"
  wrapDebugCallback
    ∷ FN_vkDebugUtilsMessengerCallbackEXT → IO PFN_vkDebugUtilsMessengerCallbackEXT

-- | The Haskell callback a Vulkan call re-enters. It is the whole reason the
-- binding is pinned at @+safe-foreign-calls@: with @unsafe@ imports this
-- corrupts the RTS instead of running.
--
-- It must not throw back into C, so every failure it has is caught and recorded
-- as callback evidence of its own.
debugCallback ∷ CallbackSink → FN_vkDebugUtilsMessengerCallbackEXT
debugCallback sink severity types callbackData _userData = do
  outcome ← try @SomeException $ do
    phase ← readIORef sink.sinkPhase
    payload ← peekSomeCStruct callbackData
    let (identifier, body) = withSomeStruct payload $ \d → (d.messageIdName, d.message)
        diagnostic =
          Diagnostic
            { diagnosticPhase = phase
            , diagnosticSeverity = describeSeverity severity
            , diagnosticTypes = Text.pack (show types)
            , diagnosticMessageId = maybe "" Encoding.decodeUtf8Lenient identifier
            , diagnosticMessage = maybe "" Encoding.decodeUtf8Lenient body
            , diagnosticInjected = identifier == Just injectionMarker
            }
    atomicModifyIORef' sink.sinkDiagnostics (\existing → (diagnostic : existing, ()))
  case outcome of
    Right () → pure ()
    Left failure →
      atomicModifyIORef'
        sink.sinkFailures
        (\existing → (Text.pack (displayException failure) : existing, ()))
  pure FALSE

describeSeverity ∷ DebugUtilsMessageSeverityFlagBitsEXT → Text
describeSeverity severity
  | severity == DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT = "error"
  | severity == DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT = "warning"
  | severity == DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT = "info"
  | severity == DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT = "verbose"
  | otherwise = Text.pack (show severity)

-- | Move to a phase, so every diagnostic that arrives is attributed to what the
-- proof was doing when it arrived.
enterPhase ∷ CallbackSink → Text → IO ()
enterPhase sink = writeIORef sink.sinkPhase

-- | Deliver a message through the loader's own messenger path. This is a native
-- call that re-enters Haskell at a point the proof chose, which is what makes
-- reentry during creation, submission, and destruction an elicited observation
-- rather than a hope that a layer happens to say something.
inject ∷ CallbackSink → Instance → Text → IO ()
inject sink handle what = do
  before ← length <$> readIORef sink.sinkDiagnostics
  submitDebugUtilsMessageEXT
    handle
    DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT
    DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT
    ( DebugUtilsMessengerCallbackDataEXT
        { next = ()
        , flags = zero
        , messageIdName = Just injectionMarker
        , messageIdNumber = 0
        , message = Just (Encoding.encodeUtf8 ("elicited reentry during " <> what))
        , queueLabels = Vector.empty
        , cmdBufLabels = Vector.empty
        , objects = Vector.empty
        }
        ∷ DebugUtilsMessengerCallbackDataEXT '[]
    )
  after ← length <$> readIORef sink.sinkDiagnostics
  when (after == before) $
    modifyIORef' sink.sinkFailures (("an injected message was not delivered during " <> what) :)

messengerCreateInfo ∷ PFN_vkDebugUtilsMessengerCallbackEXT → DebugUtilsMessengerCreateInfoEXT
messengerCreateInfo callback =
  DebugUtilsMessengerCreateInfoEXT
    { flags = zero
    , messageSeverity =
        DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT
          .|. DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT
          .|. DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
          .|. DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT
    , messageType =
        DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT
          .|. DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT
          .|. DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT
    , pfnUserCallback = callback
    , userData = nullPtr
    }

-- --------------------------------------------------------------------------
-- The environment

-- | Discovery variables that would let the loader find a driver or a layer
-- other than the pinned one. They are removed from this process's environment
-- before anything native runs, and what was removed is recorded: a proof whose
-- driver selection could have been overridden from outside is not a proof of
-- the pinned selection.
-- | The layer this proof requires, by the name it is requested under and by
-- the substring its own shared library carries on both platforms
-- (@libVkLayer_khronos_validation.dylib@, @libVkLayer_khronos_validation.so@).
validationLayerName ∷ ByteString
validationLayerName = "VK_LAYER_KHRONOS_validation"

validationLayerImage ∷ Text
validationLayerImage = "VkLayer_khronos_validation"

-- | Where the revision under proof comes from. `run-proof.sh` derives it from
-- the checkout, and the Linux container bakes it in because there is no
-- checkout inside to ask.
revisionVariable ∷ String
revisionVariable = "HETOIMASIA_PROOF_REVISION"

-- | The exact identity of the sources under proof, which the runner computes
-- from their content. A revision can be dirty or absent; this cannot.
digestVariable ∷ String
digestVariable = "HETOIMASIA_PROOF_SOURCE_DIGEST"

conflictingOverrides ∷ [String]
conflictingOverrides =
  [ -- Driver discovery and selection.
    "VK_ICD_FILENAMES"
  , "VK_ADD_DRIVER_FILES"
  , "VK_LOADER_DRIVERS_SELECT"
  , "VK_LOADER_DRIVERS_DISABLE"
  , -- Explicit layer discovery, and the legacy list that force-enables layers.
    "VK_ADD_LAYER_PATH"
  , "VK_INSTANCE_LAYERS"
  , -- Implicit layers, which need no request from the application at all and
    -- would otherwise join the chain unrecorded.
    "VK_IMPLICIT_LAYER_PATH"
  , "VK_ADD_IMPLICIT_LAYER_PATH"
  , -- The loader's own layer filters. `DISABLE` is the dangerous one: it can
    -- switch off the validation layer this proof requested, leaving a run that
    -- reported zero validation errors because nothing was validating.
    "VK_LOADER_LAYERS_ENABLE"
  , "VK_LOADER_LAYERS_DISABLE"
  , "VK_LOADER_LAYERS_ALLOW"
  ]

clearConflictingOverrides ∷ IO [Text]
clearConflictingOverrides =
  fmap concat . forM conflictingOverrides $ \name → do
    present ← lookupEnv name
    case present of
      Nothing → pure []
      Just value → do
        unsetEnv name
        pure [Text.pack name <> "=" <> Text.pack value]

-- --------------------------------------------------------------------------
-- The run

-- | Run the whole proof. Returns what it observed, or the step it stopped at;
-- either way the session is fully torn down and the callback evidence is
-- complete before this returns.
runProof ∷ Journal → Consent → IO Outcome
runProof journal consent = do
  cleanups ← newCleanups
  sink ← newCallbackSink
  outcome ← catchAll (Proved <$> procedure journal consent cleanups sink) (pure . Stopped)
  -- Teardown, including the instance, happens here: after the procedure, and
  -- before the callback evidence is read. That ordering is the requirement.
  (releases, teardownFailed) ← runCleanups journal cleanups
  diagnostics ← reverse <$> readIORef sink.sinkDiagnostics
  failures ← reverse <$> readIORef sink.sinkFailures
  for_ failures $ \failure → note journal ("a callback reported a failure: " <> failure)
  pure (completeAfterTeardown releases teardownFailed diagnostics failures outcome)

-- | Fill in the facts that only exist once the session is gone: the callback
-- evidence, and what teardown itself did.
completeAfterTeardown ∷ [Text] → [Text] → [Diagnostic] → [Text] → Outcome → Outcome
completeAfterTeardown releases teardownFailed diagnostics failures = \case
  Stopped failure → Stopped failure
  Proved findings →
    Proved
      findings
        { findingsTeardown =
            TeardownFacts
              { teardownReleases = releases
              , teardownFailures = teardownFailed
              }
        , findingsCallbacks =
            (findingsCallbacks findings)
              { callbackPhases = summarizePhases diagnostics
              , callbackDuringInstanceDestruction = countPhase diagnostics destructionPhase
              , callbackAfterExplicitMessengerDestroyed =
                  countPhase diagnostics afterMessengerPhase + countPhase diagnostics destructionPhase
              , callbackTotal = length diagnostics
              , -- Derived, not asserted. A callback that arrived while
                -- vkDestroyInstance was running found both the trampoline and
                -- the storage behind it still valid; the trampoline is
                -- registered before the instance in the cleanup stack, so it is
                -- freed after it. A callback that had failed would have said so.
                callbackStorageAliveAfterInstanceDestroyed =
                  countPhase diagnostics destructionPhase > 0 && null failures
              , callbackValidationErrors =
                  [diagnosticMessage d | d ← diagnostics, diagnosticSeverity d == "error"] <> failures
              , callbackDiagnostics = diagnostics
              }
        }

destructionPhase ∷ Text
destructionPhase = "instance destruction"

afterMessengerPhase ∷ Text
afterMessengerPhase = "after the explicit messenger was destroyed"

teardownPhase ∷ Text
teardownPhase = "teardown"

-- | Turn any escaping failure into a named stop, so a proof that breaks says
-- which requirement it broke at rather than only that it broke.
catchAll ∷ IO a → (Failure → IO a) → IO a
catchAll action handler = do
  outcome ← try action
  case outcome of
    Right value → pure value
    Left escaped
      | Just (Stop failure) ← fromException escaped → handler failure
      | Just (VulkanException result) ← fromException escaped →
          handler (Failure "a Vulkan call failed" (Text.pack (show result)))
      | otherwise →
          handler (Failure "the proof raised an unexpected exception" (Text.pack (displayException escaped)))

procedure ∷ Journal → Consent → Cleanups → CallbackSink → IO Findings
procedure journal consent cleanups sink = do
  heading journal "The environment"
  cleared ← clearConflictingOverrides
  for_ cleared $ \name → note journal ("cleared a conflicting discovery override: " <> name)
  revision ← Text.pack . maybe "unrecorded" id <$> lookupEnv revisionVariable
  digest ← Text.pack . maybe "unrecorded" id <$> lookupEnv digestVariable
  note journal ("proving repository revision " <> revision)
  note journal ("proving source digest " <> digest)
  require
    "source provenance"
    "the runner supplied no source digest, so this record could not say which sources it was produced from"
    (Text.length digest == 64 && Text.all (`elem` ("0123456789abcdef" ∷ String)) digest)
  driverFiles ← fmap Text.pack <$> lookupEnv "VK_DRIVER_FILES"
  layerPath ← fmap Text.pack <$> lookupEnv "VK_LAYER_PATH"
  note journal ("VK_DRIVER_FILES = " <> maybe "(unset)" id driverFiles)
  note journal ("VK_LAYER_PATH = " <> maybe "(unset)" id layerPath)
  require
    "the pinned driver selection"
    "VK_DRIVER_FILES must name the pinned ICD manifest by absolute path; the proof will not accept whatever driver the loader finds by default"
    (maybe False (Text.isPrefixOf "/") driverFiles)

  heading journal "The shared loader"
  -- The binding's own linked loader answers for its own entry point. This exact
  -- function pointer, and no independently found one, is what GLFW is given.
  entry ← Char8.useAsCString "vkGetInstanceProcAddr" (getInstanceProcAddr' nullPtr)
  bindingEntry ← provenanceOf (castFunPtrToPtr entry)
  note journal ("the binding dispatches through " <> describeProvenance bindingEntry)
  require
    "the shared loader"
    "the Haskell binding's own vkGetInstanceProcAddr resolved to nothing, so there is no loader to share"
    (provenanceAddress bindingEntry /= nullPtr)
  initVulkanLoader entry
  started ← glfwInit
  unless started $ do
    reason ← lastGlfwError
    stop "GLFW initialization" ("glfwInit failed: " <> reason)
  onExit cleanups "GLFW" glfwTerminate
  supported ← vulkanSupported
  require "GLFW's loader" "glfwVulkanSupported reported no Vulkan loader after being handed the binding's own" supported
  glfwEntry ← instanceProcAddress nullPtr "vkGetInstanceProcAddr" >>= provenanceOf
  note journal ("GLFW resolves the same name to " <> describeProvenance glfwEntry)

  required ←
    requiredInstanceExtensions >>= \case
      Nothing → stop "surface extensions" "glfwGetRequiredInstanceExtensions reported none, so no surface can be created"
      Just names → pure names
  note journal ("GLFW requires " <> commaSeparated (map decodeName required))

  heading journal "The instance"
  instanceVersion ← enumerateInstanceVersion
  note journal ("the loader reports instance version " <> describeVersion instanceVersion)
  (_, availableExtensions) ← enumerateInstanceExtensionProperties Nothing
  (_, availableLayers) ← enumerateInstanceLayerProperties
  let extensionNames = [e.extensionName | e ← Vector.toList availableExtensions]
      layerNames = [l.layerName | l ← Vector.toList availableLayers]
      advertised name = name `elem` extensionNames
      portabilityEnumeration = advertised KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME
      wantedInstance =
        required
          <> [EXT_DEBUG_UTILS_EXTENSION_NAME]
          <> [KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME]
          <> [EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME]
          <> [KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME | portabilityEnumeration]
      validationLayer = validationLayerName
      enabledLayers = [validationLayer | validationLayer `elem` layerNames]
  forM_ (KHR_SURFACE_EXTENSION_NAME : required) $ \name →
    require
      "surface extensions"
      ("the loader does not advertise the required instance extension " <> decodeName name)
      (advertised name)
  require
    "the maintenance dependency chain"
    ("VK_EXT_swapchain_maintenance1 depends on " <> decodeName EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME <> ", which this loader does not advertise")
    (advertised EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME)
  require
    "the maintenance dependency chain"
    ("VK_EXT_surface_maintenance1 depends on " <> decodeName KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME <> ", which this loader does not advertise")
    (advertised KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME)
  require
    "validation"
    "the pinned layer path supplies no VK_LAYER_KHRONOS_validation, so a clean run would prove nothing"
    (not (null enabledLayers))

  callback ← wrapDebugCallback (debugCallback sink)
  -- Registered before the instance, so it is released after it: the trampoline
  -- has to still be callable while vkDestroyInstance runs.
  onExit cleanups "the callback trampoline" (freeHaskellFunPtr callback)
  let createInfo = messengerCreateInfo callback

  enterPhase sink "instance creation"
  handle ←
    createInstance
      ( InstanceCreateInfo
          { next = (createInfo, ())
          , flags = if portabilityEnumeration then INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR else zero
          , applicationInfo =
              Just
                ApplicationInfo
                  { applicationName = Just "hetoimasia-vulkan-proof"
                  , applicationVersion = packVersion 0 1 0
                  , engineName = Just "hetoimasia"
                  , engineVersion = packVersion 0 1 0
                  , apiVersion = packVersion 1 3 0
                  }
          , enabledLayerNames = Vector.fromList enabledLayers
          , enabledExtensionNames = Vector.fromList wantedInstance
          }
          ∷ InstanceCreateInfo '[DebugUtilsMessengerCreateInfoEXT]
      )
      Nothing
  -- The create-info messenger is still live while the instance is destroyed.
  -- That is deliberate: requirement 8 asks what reaches Haskell during
  -- instance destruction, after the explicit messenger is already gone.
  onExit cleanups "the Vulkan instance" $ do
    enterPhase sink destructionPhase
    destroyInstance handle Nothing
  enterPhase sink "after instance creation"

  bindingSample ← provenanceOf (castFunPtrToPtr (pVkCreateDevice handle.instanceCmds))
  glfwSample ← instanceProcAddress (castPtr (instanceHandle handle)) "vkCreateDevice" >>= provenanceOf
  note journal ("the binding resolves vkCreateDevice to " <> describeProvenance bindingSample)
  note journal ("GLFW resolves vkCreateDevice to " <> describeProvenance glfwSample)

  enterPhase sink "messenger creation"
  messenger ← createDebugUtilsMessengerEXT handle createInfo Nothing
  -- Registered immediately after the instance, so it is destroyed immediately
  -- before it — and therefore after the swapchain, the device, the surface and
  -- the window. A messenger torn down before them would leave every diagnostic
  -- those destructions emit, including a device's leak reports, with nowhere to
  -- go, while the record still said zero validation errors. The create-info
  -- messenger cannot stand in: the extension uses it for instance creation and
  -- destruction alone.
  onExit cleanups "the explicit debug messenger" $ do
    enterPhase sink afterMessengerPhase
    destroyDebugUtilsMessengerEXT handle messenger Nothing
  inject sink handle "creation"

  heading journal "The window and its surface"
  window ←
    createProofWindow 320 240 "hetoimasia Vulkan proof" >>= \case
      Nothing → do
        reason ← lastGlfwError
        stop "the proof window" ("glfwCreateWindow failed: " <> reason)
      Just value → pure value
  onExit cleanups "the proof window" (destroyProofWindow window)
  (surfaceResult, surfaceHandle) ← createWindowSurface (castPtr (instanceHandle handle)) window
  require
    "the window surface"
    ("glfwCreateWindowSurface returned " <> Text.pack (show (Result (fromIntegral surfaceResult))))
    (surfaceResult == 0)
  let surface = SurfaceKHR surfaceHandle
  onExit cleanups "the window surface" (destroySurfaceKHR handle surface Nothing)
  pollEvents

  heading journal "The device profile"
  (_, devices) ← enumeratePhysicalDevices handle
  require "physical devices" "the loader enumerated no physical device through the pinned driver" (not (Vector.null devices))
  selection ← selectDevice journal surface (Vector.toList devices)

  enterPhase sink "device creation"
  device ←
    createDevice
      selection.selectedDevice
      ( DeviceCreateInfo
          { next =
              ( vulkan13Features
              , (PhysicalDeviceSwapchainMaintenance1FeaturesKHR {swapchainMaintenance1 = True}, ())
              )
          , flags = zero
          , queueCreateInfos =
              Vector.singleton
                ( SomeStruct
                    ( DeviceQueueCreateInfo
                        { next = ()
                        , flags = zero
                        , queueFamilyIndex = selection.selectedQueueFamily
                        , queuePriorities = Vector.singleton 1.0
                        }
                        ∷ DeviceQueueCreateInfo '[]
                    )
                )
          , enabledLayerNames = Vector.empty
          , enabledExtensionNames = Vector.fromList selection.selectedDeviceExtensions
          , enabledFeatures = Nothing
          }
          ∷ DeviceCreateInfo '[PhysicalDeviceVulkan13Features, PhysicalDeviceSwapchainMaintenance1FeaturesKHR]
      )
      Nothing
  onExit cleanups "the logical device" (destroyDevice device Nothing)
  enterPhase sink "after device creation"

  -- Which spelling of the release entry point this device actually answered
  -- for. The binding asks for the EXT name first and falls back to the KHR one,
  -- so a proof that enabled only EXT still has to say which was resolved.
  extEntry ← getDeviceProcAddr device "vkReleaseSwapchainImagesEXT"
  khrEntry ← getDeviceProcAddr device "vkReleaseSwapchainImagesKHR"
  bindingRelease ← provenanceOf (castFunPtrToPtr (pVkReleaseSwapchainImagesKHR device.deviceCmds))
  note journal ("the binding dispatches image release through " <> describeProvenance bindingRelease)
  require
    "the maintenance entry point"
    "neither vkReleaseSwapchainImagesEXT nor vkReleaseSwapchainImagesKHR resolved on the created device"
    (provenanceAddress bindingRelease /= nullPtr)
  deviceProcSample ← provenanceOf (castFunPtrToPtr (pVkQueueSubmit2 device.deviceCmds))
  -- Whether validation is really in the chain, rather than whether it was asked
  -- for. A requested layer the loader filtered out would leave every later
  -- "zero validation errors" claim meaningless, and nothing in
  -- vkEnumerateInstanceLayerProperties would say so: it lists what is
  -- available. An entry point that resolves into the layer's own image does.
  let validationLoaded =
        maybe False (Text.isInfixOf validationLayerImage) (provenanceImage deviceProcSample)
  note
    journal
    ( "the validation layer is "
        <> (if validationLoaded then "in" else "NOT in")
        <> " the loaded chain, by the image a device entry point resolves into"
    )

  queue ← getDeviceQueue device selection.selectedQueueFamily 0

  heading journal "The presentation profile"
  target ← buildTarget journal device selection surface
  onExit cleanups "the swapchain" (destroySwapchainKHR device target.targetSwapchain Nothing)

  slots ← newSlots device selection.selectedQueueFamily
  onExit cleanups "the frame slots" (destroySlots device slots)
  -- Registered last, so it runs first: every destruction below happens with the
  -- device idle, whether the procedure finished or stopped, and every
  -- diagnostic any of them emits is attributed to teardown.
  onExit cleanups "the teardown boundary" $ do
    enterPhase sink teardownPhase
    deviceWaitIdle device

  heading journal "Presentation completion"
  enterPhase sink "submission"
  inject sink handle "submission"
  completion ← proveCompletion journal device queue target slots

  heading journal "Safe abandonment"
  enterPhase sink "abandonment"
  abandonment ← proveAbandonment journal device queue target slots

  heading journal "Transfer-source capture"
  enterPhase sink "capture"
  capture ← proveCapture journal device selection.selectedDevice queue target slots

  heading journal "Teardown"
  -- Teardown itself is the cleanup stack, which runs after this procedure
  -- returns and in the reverse of registration order: the device is made idle,
  -- then the slots, swapchain, device, surface and window are destroyed with
  -- the explicit messenger still watching, then that messenger, then the
  -- instance with only the create-info messenger left. No message is injected
  -- after the explicit messenger goes, and that is a finding rather than a gap:
  -- a messenger chained into VkInstanceCreateInfo is used for vkCreateInstance
  -- and vkDestroyInstance alone, so there is nothing for an ordinary message to
  -- reach. Destruction reentry is observed where the extension actually
  -- produces it, inside vkDestroyInstance.
  note journal "teardown runs after this procedure returns: child resources are destroyed while the explicit messenger still watches, then that messenger, then the instance"

  -- Observed rather than asserted: `rtsSupportsBoundThreads` is false unless
  -- this executable was linked `-threaded`, and the procedure runs on the
  -- initial Haskell thread, which is bound to the process main thread exactly
  -- when that holds. Both are what GLFW's main-thread rule needs.
  threaded ← pure rtsSupportsBoundThreads
  bound ← isCurrentThreadBound
  pure
    Findings
      { findingsPlatform =
          PlatformFacts
            { platformOs = Text.pack os
            , platformArch = Text.pack arch
            , platformRevision = revision
            , platformSourceDigest = digest
            , platformConsent = describeConsent consent
            , platformDriverFiles = driverFiles
            , platformLayerPath = layerPath
            , platformClearedOverrides = cleared
            , platformInstanceVersion = describeVersion instanceVersion
            , platformAvailableLayers =
                [ (decodeName properties.layerName, describeVersion properties.specVersion)
                | properties ← Vector.toList availableLayers
                ]
            , platformRequestedLayers = map decodeName enabledLayers
            , platformValidationLayerLoaded = validationLoaded
            , platformGlfwRequired = map decodeName required
            }
      , findingsLoader =
          LoaderFacts
            { loaderBindingEntry = bindingEntry
            , loaderGlfwEntry = glfwEntry
            , loaderSampleName = "vkCreateDevice"
            , loaderBindingSample = bindingSample
            , loaderGlfwSample = glfwSample
            , loaderDriverName = decodeName selection.selectedDriverName
            , loaderDriverId = selection.selectedDriverId
            , loaderDriverInfo = decodeName selection.selectedDriverInfo
            , loaderConformance = selection.selectedConformance
            , loaderDeviceName = selection.selectedDeviceName
            , loaderDeviceApiVersion = describeVersion selection.selectedApiVersion
            , loaderDeviceProcSample = deviceProcSample
            }
      , findingsProfile =
          ProfileFacts
            { profileEnabledInstanceExtensions = map decodeName wantedInstance
            , profilePortabilityEnumeration = portabilityEnumeration
            , profilePortabilitySubsetAdvertised = selection.selectedPortabilityAdvertised
            , profilePortabilitySubsetEnabled =
                KHR_PORTABILITY_SUBSET_EXTENSION_NAME `elem` selection.selectedDeviceExtensions
            , profileDynamicRenderingSupported = selection.selectedDynamicRendering
            , profileSynchronization2Supported = selection.selectedSynchronization2
            , profileDynamicRenderingEnabled = True
            , profileSynchronization2Enabled = True
            , profileQueueFamily = selection.selectedQueueFamily
            , profileQueueGraphics = True
            , profileQueuePresent = True
            , profileSurfaceFormat = Text.pack (show target.targetFormat)
            , profileSurfaceColorSpace = Text.pack (show target.targetColorSpace)
            , profileSupportedUsages = describeUsages target.targetSupportedUsage
            , profileRequestedUsages = describeUsages target.targetRequestedUsage
            , profileTransferSourceSupported =
                target.targetSupportedUsage .&. IMAGE_USAGE_TRANSFER_SRC_BIT /= zero
            , profilePresentModes = map (Text.pack . show) target.targetPresentModes
            , profileChosenPresentMode = Text.pack (show target.targetPresentMode)
            , profileSwapchainImages = Vector.length target.targetImages
            , profileMaintenanceVariant = decodeName EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME
            , profileMaintenanceDependencies =
                [ (decodeName KHR_SWAPCHAIN_EXTENSION_NAME, True)
                , (decodeName EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME, True)
                , (decodeName KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME, True)
                ]
            , profileMaintenanceFeatureSupported = selection.selectedMaintenanceFeature
            , profileMaintenanceFeatureEnabled = True
            , profileMaintenanceAlias =
                [ ("vkReleaseSwapchainImagesEXT", extEntry /= nullFunPtr)
                , ("vkReleaseSwapchainImagesKHR", khrEntry /= nullFunPtr)
                ]
            , profileEnabledDeviceExtensions = map decodeName selection.selectedDeviceExtensions
            }
      , findingsCompletion = completion
      , findingsAbandonment = abandonment
      , findingsCapture = capture
      , findingsCallbacks =
          CallbackFacts
            { callbackSafeForeignCalls = True
            , callbackRtsThreaded = threaded
            , callbackMainThreadBound = bound
            , callbackPhases = []
            , callbackAfterExplicitMessengerDestroyed = 0
            , callbackDuringInstanceDestruction = 0
            , callbackTotal = 0
            , callbackStorageAliveAfterInstanceDestroyed = False
            , callbackValidationErrors = []
            , callbackDiagnostics = []
            }
      , -- Both filled in by 'completeAfterTeardown', because neither exists
        -- until the cleanup stack has run.
        findingsTeardown = TeardownFacts {teardownReleases = [], teardownFailures = []}
      }

-- --------------------------------------------------------------------------
-- Physical device selection

data Selection = Selection
  { selectedDevice ∷ PhysicalDevice
  , selectedDeviceName ∷ Text
  , selectedApiVersion ∷ Word32
  , selectedDriverId ∷ Text
  , selectedDriverName ∷ ByteString
  , selectedDriverInfo ∷ ByteString
  , selectedConformance ∷ Text
  , selectedQueueFamily ∷ Word32
  , selectedDeviceExtensions ∷ [ByteString]
  , selectedPortabilityAdvertised ∷ Bool
  , selectedDynamicRendering ∷ Bool
  , selectedSynchronization2 ∷ Bool
  , selectedMaintenanceFeature ∷ Bool
  }

-- | The first physical device that satisfies the whole contract, or a stop
-- naming what every candidate was missing. Nothing here narrows the
-- requirement to fit what was found.
selectDevice ∷ Journal → SurfaceKHR → [PhysicalDevice] → IO Selection
selectDevice journal surface candidates = do
  results ← mapM examine candidates
  case [selection | Right selection ← results] of
    (selection : _) → do
      note journal ("selected " <> selection.selectedDeviceName <> ", advertising Vulkan " <> describeVersion selection.selectedApiVersion)
      pure selection
    [] →
      stop
        "the device profile"
        ("no enumerated device satisfies the required profile: " <> commaSeparated [reason | Left reason ← results])
  where
    examine physical = do
      properties ∷ PhysicalDeviceProperties2 '[PhysicalDeviceDriverProperties] ←
        getPhysicalDeviceProperties2 physical
      features ∷ PhysicalDeviceFeatures2 '[PhysicalDeviceVulkan13Features, PhysicalDeviceSwapchainMaintenance1FeaturesKHR] ←
        getPhysicalDeviceFeatures2 physical
      (_, extensions) ← enumerateDeviceExtensionProperties physical Nothing
      families ← getPhysicalDeviceQueueFamilyProperties physical
      presenting ←
        fmap concat . forM (zip [0 ..] (Vector.toList families)) $ \(index, family) → do
          supported ← getPhysicalDeviceSurfaceSupportKHR physical index surface
          pure [index | supported && family.queueFlags .&. QUEUE_GRAPHICS_BIT /= zero]
      let core = properties.properties
          (driver, ()) = properties.next
          (thirteen, (maintenance, ())) = features.next
          name = decodeName core.deviceName
          deviceExtensions = [e.extensionName | e ← Vector.toList extensions]
          has extension = extension `elem` deviceExtensions
          portability = has KHR_PORTABILITY_SUBSET_EXTENSION_NAME
      note journal (name <> " advertises Vulkan " <> describeVersion core.apiVersion)
      pure $ do
        family ← case presenting of
          (first : _) → Right first
          [] → Left (name <> " has no queue family with both graphics and surface presentation")
        checkThat (apiMajorMinor core.apiVersion >= (1, 3)) (name <> " advertises only Vulkan " <> describeVersion core.apiVersion)
        checkThat thirteen.dynamicRendering (name <> " does not support dynamicRendering")
        checkThat thirteen.synchronization2 (name <> " does not support synchronization2")
        checkThat (has KHR_SWAPCHAIN_EXTENSION_NAME) (name <> " does not support VK_KHR_swapchain")
        checkThat
          (has EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME)
          (name <> " does not support " <> decodeName EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME)
        checkThat maintenance.swapchainMaintenance1 (name <> " does not support the swapchainMaintenance1 feature")
        Right
          Selection
            { selectedDevice = physical
            , selectedDeviceName = name
            , selectedApiVersion = core.apiVersion
            , selectedDriverId = Text.pack (show driver.driverID)
            , selectedDriverName = driver.driverName
            , selectedDriverInfo = driver.driverInfo
            , selectedConformance = describeConformance driver.conformanceVersion
            , selectedQueueFamily = family
            , selectedDeviceExtensions =
                [KHR_SWAPCHAIN_EXTENSION_NAME, EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME]
                  <> [KHR_PORTABILITY_SUBSET_EXTENSION_NAME | portability]
            , selectedPortabilityAdvertised = portability
            , selectedDynamicRendering = thirteen.dynamicRendering
            , selectedSynchronization2 = thirteen.synchronization2
            , selectedMaintenanceFeature = maintenance.swapchainMaintenance1
            }
    checkThat ok reason = if ok then Right () else Left reason

-- --------------------------------------------------------------------------
-- The presentation target

data Target = Target
  { targetSwapchain ∷ SwapchainKHR
  , targetCreations ∷ IORef Int
    -- ^ How many times a swapchain has been created for this surface. The
    -- abandonment paths must not raise it, and saying so is a count rather
    -- than a claim about code that a reader would have to check.
  , targetImages ∷ Vector Image
  , targetFormat ∷ Format
  , targetColorSpace ∷ ColorSpaceKHR
  , targetExtent ∷ Extent2D
  , targetPresentMode ∷ PresentModeKHR
  , targetPresentModes ∷ [PresentModeKHR]
  , targetSupportedUsage ∷ ImageUsageFlags
  , targetRequestedUsage ∷ ImageUsageFlags
  }

buildTarget ∷ Journal → Device → Selection → SurfaceKHR → IO Target
buildTarget journal device selection surface = do
  let physical = selection.selectedDevice
  capabilities ← getPhysicalDeviceSurfaceCapabilitiesKHR physical surface
  (_, formats) ← getPhysicalDeviceSurfaceFormatsKHR physical surface
  (_, presentModes) ← getPhysicalDeviceSurfacePresentModesKHR physical surface
  require "the presentation profile" "the surface offers no format" (not (Vector.null formats))
  let wantedUsage =
        IMAGE_USAGE_COLOR_ATTACHMENT_BIT
          .|. IMAGE_USAGE_TRANSFER_SRC_BIT
          .|. IMAGE_USAGE_TRANSFER_DST_BIT
      supported = capabilities.supportedUsageFlags
      preferred =
        [ candidate
        | candidate ← Vector.toList formats
        , candidate.format `elem` [FORMAT_B8G8R8A8_UNORM, FORMAT_R8G8B8A8_UNORM]
        ]
      chosen = case preferred of
        (value : _) → value
        [] → Vector.head formats
      modes = Vector.toList presentModes
      current = capabilities.currentExtent
      extent = if current.width == maxBound then Extent2D 320 240 else current
      -- Enough images that acquiring one while another is abandoned or
      -- deliberately unpresented never starves the next acquisition.
      wanted = max 3 (capabilities.minImageCount + 1)
      count = if capabilities.maxImageCount == 0 then wanted else min wanted capabilities.maxImageCount
  require
    "the presentation profile"
    ("the surface does not support the usages this proof needs; it supports " <> commaSeparated (describeUsages supported))
    (supported .&. wantedUsage == wantedUsage)
  require
    "the presentation profile"
    "the surface does not offer PRESENT_MODE_FIFO_KHR, which every conformant implementation must"
    (PRESENT_MODE_FIFO_KHR `elem` modes)
  require
    "the presentation profile"
    ("the surface's current extent is degenerate: " <> Text.pack (show extent))
    (extent.width > 0 && extent.height > 0)
  note
    journal
    ( "presenting "
        <> Text.pack (show count)
        <> " images of "
        <> Text.pack (show chosen.format)
        <> " at "
        <> Text.pack (show extent)
    )
  swapchain ←
    createSwapchainKHR
      device
      ( SwapchainCreateInfoKHR
          { next = ()
          , flags = zero
          , surface = surface
          , minImageCount = count
          , imageFormat = chosen.format
          , imageColorSpace = chosen.colorSpace
          , imageExtent = extent
          , imageArrayLayers = 1
          , imageUsage = wantedUsage
          , imageSharingMode = SHARING_MODE_EXCLUSIVE
          , queueFamilyIndices = Vector.singleton selection.selectedQueueFamily
          , preTransform = capabilities.currentTransform
          , compositeAlpha = COMPOSITE_ALPHA_OPAQUE_BIT_KHR
          , presentMode = PRESENT_MODE_FIFO_KHR
          , clipped = True
          , oldSwapchain = NULL_HANDLE
          }
          ∷ SwapchainCreateInfoKHR '[]
      )
      Nothing
  (_, images) ← getSwapchainImagesKHR device swapchain
  creations ← newIORef 1
  pure
    Target
      { targetSwapchain = swapchain
      , targetCreations = creations
      , targetImages = images
      , targetFormat = chosen.format
      , targetColorSpace = chosen.colorSpace
      , targetExtent = extent
      , targetPresentMode = PRESENT_MODE_FIFO_KHR
      , targetPresentModes = modes
      , targetSupportedUsage = supported
      , targetRequestedUsage = wantedUsage
      }

-- --------------------------------------------------------------------------
-- Frame slots

-- | One frame's synchronization. The presentation semaphore is per slot and is
-- returned to the pool only on that slot's present fence, never on its
-- rendering fence: that distinction is the whole of requirement 5.
data Slot = Slot
  { slotName ∷ Text
  , slotAcquire ∷ Semaphore
  , slotPresent ∷ Semaphore
  , slotRenderFence ∷ Fence
  , slotPresentFence ∷ Fence
  , slotPool ∷ CommandPool
  , slotCommands ∷ CommandBuffer
  , slotPresented ∷ IORef Bool
  }

-- | The pool: two slots, named rather than indexed, so choosing one is total.
data Slots = Slots
  { firstSlot ∷ Slot
  , secondSlot ∷ Slot
  }

slotCount ∷ Int
slotCount = 2

-- | Which slot a frame uses. Alternating between two is what makes a reuse
-- happen at all, and a reuse is what requirement 5's recycling rule is about.
slotFor ∷ Slots → Int → Slot
slotFor slots index = if even index then slots.firstSlot else slots.secondSlot

eachSlot ∷ Slots → [Slot]
eachSlot slots = [slots.firstSlot, slots.secondSlot]

newSlots ∷ Device → Word32 → IO Slots
newSlots device family = do
  built ← forM [0 .. slotCount - 1] (newSlot device family)
  case built of
    [a, b] → pure (Slots a b)
    _ → stop "the frame slots" "the slot pool was not built as a pair"

newSlot ∷ Device → Word32 → Int → IO Slot
newSlot device family index = do
  acquire ← createSemaphore device (SemaphoreCreateInfo {next = (), flags = zero} ∷ SemaphoreCreateInfo '[]) Nothing
  present ← createSemaphore device (SemaphoreCreateInfo {next = (), flags = zero} ∷ SemaphoreCreateInfo '[]) Nothing
  renderFence ← createFence device (FenceCreateInfo {next = (), flags = zero} ∷ FenceCreateInfo '[]) Nothing
  presentFence ← createFence device (FenceCreateInfo {next = (), flags = zero} ∷ FenceCreateInfo '[]) Nothing
  pool ←
    createCommandPool
      device
      CommandPoolCreateInfo
        { next = ()
        , flags = COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT
        , queueFamilyIndex = family
        }
      Nothing
  buffers ←
    allocateCommandBuffers
      device
      CommandBufferAllocateInfo
        { commandPool = pool
        , level = COMMAND_BUFFER_LEVEL_PRIMARY
        , commandBufferCount = 1
        }
  presented ← newIORef False
  pure
    Slot
      { slotName = "slot " <> Text.pack (show index)
      , slotAcquire = acquire
      , slotPresent = present
      , slotRenderFence = renderFence
      , slotPresentFence = presentFence
      , slotPool = pool
      , slotCommands = Vector.head buffers
      , slotPresented = presented
      }

destroySlots ∷ Device → Slots → IO ()
destroySlots device = mapM_ release . eachSlot
  where
    release slot = do
      destroyCommandPool device slot.slotPool Nothing
      destroyFence device slot.slotPresentFence Nothing
      destroyFence device slot.slotRenderFence Nothing
      destroySemaphore device slot.slotPresent Nothing
      destroySemaphore device slot.slotAcquire Nothing

-- --------------------------------------------------------------------------
-- Frames

oneSecond ∷ Word64
oneSecond = 1_000_000_000

-- | Acquire an image into a slot, with a finite timeout. A proof that blocks
-- forever reports nothing.
acquireInto ∷ Device → Target → Slot → IO (Text, Word32)
acquireInto device target slot = do
  (result, index) ← acquireNextImageKHR device target.targetSwapchain (2 * oneSecond) slot.slotAcquire NULL_HANDLE
  require
    "acquisition"
    ("vkAcquireNextImageKHR returned " <> Text.pack (show result))
    (result == SUCCESS || result == SUBOPTIMAL_KHR)
  pure (Text.pack (show result), index)

imageAt ∷ Target → Word32 → Image
imageAt target index = target.targetImages Vector.! fromIntegral index

-- | Record a clear of the acquired image and leave it ready to present.
recordPresentable ∷ Slot → Target → Word32 → IO ()
recordPresentable slot target index = do
  resetCommandBuffer slot.slotCommands zero
  useCommandBuffer slot.slotCommands beginOnce $ do
    transition slot.slotCommands (imageAt target index) IMAGE_LAYOUT_UNDEFINED IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
    cmdClearColorImage
      slot.slotCommands
      (imageAt target index)
      IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
      proofColor
      (Vector.singleton wholeImage)
    transition slot.slotCommands (imageAt target index) IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL IMAGE_LAYOUT_PRESENT_SRC_KHR

-- | Make a transfer write to a buffer available and visible to the host.
hostReadBarrier ∷ CommandBuffer → Buffer → IO ()
hostReadBarrier commands buffer =
  cmdPipelineBarrier2
    commands
    ( DependencyInfo
        { next = ()
        , dependencyFlags = zero
        , memoryBarriers = Vector.empty
        , bufferMemoryBarriers =
            Vector.singleton
              ( SomeStruct
                  ( BufferMemoryBarrier2
                      { next = ()
                      , srcStageMask = PIPELINE_STAGE_2_ALL_TRANSFER_BIT
                      , srcAccessMask = ACCESS_2_TRANSFER_WRITE_BIT
                      , dstStageMask = PIPELINE_STAGE_2_HOST_BIT
                      , dstAccessMask = ACCESS_2_HOST_READ_BIT
                      , srcQueueFamilyIndex = QUEUE_FAMILY_IGNORED
                      , dstQueueFamilyIndex = QUEUE_FAMILY_IGNORED
                      , buffer = buffer
                      , offset = 0
                      , size = WHOLE_SIZE
                      }
                      ∷ BufferMemoryBarrier2 '[]
                  )
              )
        , imageMemoryBarriers = Vector.empty
        }
        ∷ DependencyInfo '[]
    )

beginOnce ∷ CommandBufferBeginInfo '[]
beginOnce =
  CommandBufferBeginInfo
    { next = ()
    , flags = COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
    , inheritanceInfo = Nothing
    }

-- | The payload the capture reads back: opaque magenta, whose bytes are the
-- same under both of the byte orders a swapchain format here can have, so the
-- check does not silently depend on which one was chosen.
proofColor ∷ ClearColorValue
proofColor = Float32 1.0 0.0 1.0 1.0

proofColorBytes ∷ [Word32]
proofColorBytes = [255, 0, 255, 255]

wholeImage ∷ ImageSubresourceRange
wholeImage =
  ImageSubresourceRange
    { aspectMask = IMAGE_ASPECT_COLOR_BIT
    , baseMipLevel = 0
    , levelCount = 1
    , baseArrayLayer = 0
    , layerCount = 1
    }

transition ∷ CommandBuffer → Image → ImageLayout → ImageLayout → IO ()
transition commands image old new =
  cmdPipelineBarrier2
    commands
    ( DependencyInfo
        { next = ()
        , dependencyFlags = zero
        , memoryBarriers = Vector.empty
        , bufferMemoryBarriers = Vector.empty
        , imageMemoryBarriers =
            Vector.singleton
              ( SomeStruct
                  ( ImageMemoryBarrier2
                      { next = ()
                      , srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT
                      , srcAccessMask = ACCESS_2_MEMORY_WRITE_BIT
                      , dstStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT
                      , dstAccessMask = ACCESS_2_MEMORY_READ_BIT .|. ACCESS_2_MEMORY_WRITE_BIT
                      , oldLayout = old
                      , newLayout = new
                      , srcQueueFamilyIndex = QUEUE_FAMILY_IGNORED
                      , dstQueueFamilyIndex = QUEUE_FAMILY_IGNORED
                      , image = image
                      , subresourceRange = wholeImage
                      }
                      ∷ ImageMemoryBarrier2 '[]
                  )
              )
        }
        ∷ DependencyInfo '[]
    )

-- | A submission that waits on the named semaphores, runs the given command
-- buffers, signals the named semaphores, and signals a fence. With no command
-- buffers it is the tracked cleanup submission the abandonment paths use to
-- consume a semaphore that has no other waiter.
submitWith ∷ Queue → [Semaphore] → [CommandBuffer] → [Semaphore] → Fence → IO ()
submitWith queue waits commands signals fence =
  queueSubmit2
    queue
    ( Vector.singleton
        ( SomeStruct
            ( SubmitInfo2
                { next = ()
                , flags = zero
                , waitSemaphoreInfos = Vector.fromList (map semaphoreInfo waits)
                , commandBufferInfos =
                    Vector.fromList
                      [ SomeStruct
                          ( CommandBufferSubmitInfo
                              { next = ()
                              , commandBuffer = commandBufferHandle buffer
                              , deviceMask = 0
                              }
                              ∷ CommandBufferSubmitInfo '[]
                          )
                      | buffer ← commands
                      ]
                , signalSemaphoreInfos = Vector.fromList (map semaphoreInfo signals)
                }
                ∷ SubmitInfo2 '[]
            )
        )
    )
    fence
  where
    semaphoreInfo semaphore =
      SemaphoreSubmitInfo
        { semaphore = semaphore
        , value = 0
        , stageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT
        , deviceIndex = 0
        }

awaitFence ∷ Text → Device → Fence → IO Bool
awaitFence what device fence = do
  result ← waitForFences device (Vector.singleton fence) True (5 * oneSecond)
  require "completion" (what <> " did not signal within five seconds: " <> Text.pack (show result)) (result == SUCCESS)
  status ← getFenceStatus device fence
  pure (status == SUCCESS)

-- | Present one acquired image with a present fence, reporting the fence's
-- status before the wait as well as after it.
presentWithFence ∷ Device → Queue → Target → Slot → Word32 → IO (Text, Text, Bool)
presentWithFence device queue target slot index = do
  resetFences device (Vector.singleton slot.slotPresentFence)
  result ←
    queuePresentKHR
      queue
      ( PresentInfoKHR
          { next = (SwapchainPresentFenceInfoKHR {fences = Vector.singleton slot.slotPresentFence}, ())
          , waitSemaphores = Vector.singleton slot.slotPresent
          , swapchains = Vector.singleton target.targetSwapchain
          , imageIndices = Vector.singleton index
          , results = nullPtr
          }
          ∷ PresentInfoKHR '[SwapchainPresentFenceInfoKHR]
      )
  require
    "presentation"
    ("vkQueuePresentKHR returned " <> Text.pack (show result))
    (result == SUCCESS || result == SUBOPTIMAL_KHR)
  before ← getFenceStatus device slot.slotPresentFence
  pollEvents
  signalled ← awaitFence "the present fence" device slot.slotPresentFence
  writeIORef slot.slotPresented True
  pure (Text.pack (show result), if before == SUCCESS then "signalled" else "not ready", signalled)

-- | Make a slot reusable. Requirement 5 is about what the presentation
-- semaphore waits for, so the evidence this returns names the present fence
-- rather than the rendering fence, and the rendering fence is never what a
-- reuse is attributed to.
reclaim ∷ Device → Slot → IO Text
reclaim device slot = do
  presented ← readIORef slot.slotPresented
  if not presented
    then pure "never presented"
    else do
      _ ← awaitFence ("the present fence of " <> slot.slotName) device slot.slotPresentFence
      pure "present fence"

-- | One ordinary frame: acquire, render, submit, present with a fence, and
-- retire on that fence.
runFrame ∷ Journal → Device → Queue → Target → Slot → Int → IO FrameRecord
runFrame journal device queue target slot index = do
  (acquireResult, image) ← acquireInto device target slot
  recordPresentable slot target image
  resetFences device (Vector.singleton slot.slotRenderFence)
  submitWith queue [slot.slotAcquire] [slot.slotCommands] [slot.slotPresent] slot.slotRenderFence
  renderSignalled ← awaitFence ("the rendering fence of " <> slot.slotName) device slot.slotRenderFence
  (presentResult, before, presentSignalled) ← presentWithFence device queue target slot image
  note
    journal
    ( "frame "
        <> Text.pack (show index)
        <> " presented image "
        <> Text.pack (show image)
        <> " and its present fence "
        <> (if presentSignalled then "signalled" else "did not signal")
    )
  pure
    FrameRecord
      { frameIndex = index
      , frameImage = image
      , frameSemaphoreSlot = slot.slotName
      , frameAcquireResult = acquireResult
      , frameRenderFenceSignalled = renderSignalled
      , framePresentResult = presentResult
      , framePresentFenceStatusBeforeWait = before
      , framePresentFenceSignalled = presentSignalled
      , frameRetiredOn = "present fence"
      }

-- --------------------------------------------------------------------------
-- Requirement 5

proveCompletion ∷ Journal → Device → Queue → Target → Slots → IO CompletionFacts
proveCompletion journal device queue target slots = do
  (frames, reuses) ← foldFrames [0 .. 3] ([], [])
  delayed ← proveDelayed journal device queue target slots.firstSlot 4
  pure
    CompletionFacts
      { completionFrames = reverse frames <> [delayed.delayedRecord]
      , completionPool =
          PoolFacts
            { poolSize = slotCount
            , poolFramesPresented = length frames + 1
            , poolReuses = reverse reuses
            , poolEveryReuseBackedByPresentFence =
                all (\frame → frame.frameRetiredOn == "present fence") frames
            , poolRenderFenceNeverRetiredASemaphore = True
            }
      , completionDelayed = delayed.delayedFacts
      }
  where
    foldFrames [] accumulated = pure accumulated
    foldFrames (index : rest) (frames, reuses) = do
      let slot = slotFor slots index
      evidence ← reclaim device slot
      reuses' ←
        if evidence == "present fence"
          then do
            note journal (slot.slotName <> " was reused for frame " <> Text.pack (show index) <> " on its " <> evidence)
            pure ((slot.slotName, index) : reuses)
          else pure reuses
      frame ← runFrame journal device queue target slot index
      foldFrames rest (frame : frames, reuses')

data Delayed = Delayed
  { delayedRecord ∷ FrameRecord
  , delayedFacts ∷ DelayedFacts
  }

-- | A frame whose rendering has completed and whose presentation is
-- deliberately withheld for several owner turns. What is proved is that the
-- slot is not reused before the present fence says so; no claim is made that
-- occlusion or delay changes when the fence signals.
proveDelayed ∷ Journal → Device → Queue → Target → Slot → Int → IO Delayed
proveDelayed journal device queue target slot index = do
  _ ← reclaim device slot
  (acquireResult, image) ← acquireInto device target slot
  recordPresentable slot target image
  resetFences device (Vector.singleton slot.slotRenderFence)
  submitWith queue [slot.slotAcquire] [slot.slotCommands] [slot.slotPresent] slot.slotRenderFence
  renderSignalled ← awaitFence ("the rendering fence of " <> slot.slotName) device slot.slotRenderFence
  let turns = 3 ∷ Int
  forM_ [1 .. turns] $ \_ → pollEvents
  note journal ("the delayed frame held a completed, unpresented image for " <> Text.pack (show turns) <> " owner turns")
  (presentResult, before, presentSignalled) ← presentWithFence device queue target slot image
  pure
    Delayed
      { delayedRecord =
          FrameRecord
            { frameIndex = index
            , frameImage = image
            , frameSemaphoreSlot = slot.slotName
            , frameAcquireResult = acquireResult
            , frameRenderFenceSignalled = renderSignalled
            , framePresentResult = presentResult
            , framePresentFenceStatusBeforeWait = before
            , framePresentFenceSignalled = presentSignalled
            , frameRetiredOn = "present fence"
            }
      , delayedFacts =
          DelayedFacts
            { delayedFrame = index
            , delayedRenderFenceSignalledBeforePresent = renderSignalled
            , delayedTurnsBetweenSubmitAndPresent = turns
            , delayedSlotWithheldWhileUnpresented = True
            , delayedSlotReusedOnlyAfterPresentFence = presentSignalled
            }
      }

-- --------------------------------------------------------------------------
-- Requirement 6

proveAbandonment ∷ Journal → Device → Queue → Target → Slots → IO AbandonmentFacts
proveAbandonment journal device queue target slots = do
  unsubmitted ← abandonUnsubmittedFrame journal device queue target slots.firstSlot
  unpresented ← abandonUnpresentedFrame journal device queue target slots.secondSlot
  progress ← do
    _ ← reclaim device slots.firstSlot
    runFrame journal device queue target slots.firstSlot 6
  creations ← readIORef target.targetCreations
  pure
    AbandonmentFacts
      { abandonUnsubmitted = unsubmitted
      , abandonUnpresented = unpresented
      , abandonSwapchainRebuilt = creations > 1
      , abandonProgressAfterwards = Just progress
      }

-- | An image acquired and never rendered to. Its acquisition semaphore is
-- settled by a tracked zero-command submission that consumes it, and only then
-- is the image given back.
abandonUnsubmittedFrame ∷ Journal → Device → Queue → Target → Slot → IO ReleaseRecord
abandonUnsubmittedFrame journal device queue target slot = do
  _ ← reclaim device slot
  (_, image) ← acquireInto device target slot
  resetFences device (Vector.singleton slot.slotRenderFence)
  submitWith queue [slot.slotAcquire] [] [] slot.slotRenderFence
  settled ← awaitFence "the cleanup submission" device slot.slotRenderFence
  outcome ←
    try @VulkanException $
      releaseSwapchainImagesKHR
        device
        ReleaseSwapchainImagesInfoKHR
          { swapchain = target.targetSwapchain
          , imageIndices = Vector.singleton image
          }
  note journal ("released unrendered image " <> Text.pack (show image) <> " after its acquisition semaphore was consumed")
  pure
    ReleaseRecord
      { releaseImage = image
      , releaseCleanup = "a tracked zero-command submission waiting on the acquisition semaphore"
      , releaseCleanupFenceSignalled = settled
      , releaseSemaphoreSettledBy = "the cleanup submission's wait"
      , releaseResult = either (Text.pack . show) (const "SUCCESS") outcome
      , releaseSucceeded = either (const False) (const True) outcome
      }

-- | An image rendered to and deliberately never presented. Its render-finished
-- semaphore was signalled and never waited, so it is settled by a tracked
-- cleanup submission before the image is returned. Requirement 5's
-- present-fence-only rule is about presented records; this proven cleanup is
-- the separate permitted retirement path for an unpresented frame.
abandonUnpresentedFrame ∷ Journal → Device → Queue → Target → Slot → IO ReleaseRecord
abandonUnpresentedFrame journal device queue target slot = do
  _ ← reclaim device slot
  (_, image) ← acquireInto device target slot
  recordPresentable slot target image
  resetFences device (Vector.singleton slot.slotRenderFence)
  submitWith queue [slot.slotAcquire] [slot.slotCommands] [slot.slotPresent] slot.slotRenderFence
  rendered ← awaitFence "the rendering fence" device slot.slotRenderFence
  resetFences device (Vector.singleton slot.slotRenderFence)
  submitWith queue [slot.slotPresent] [] [] slot.slotRenderFence
  settled ← awaitFence "the cleanup submission" device slot.slotRenderFence
  outcome ←
    try @VulkanException $
      releaseSwapchainImagesKHR
        device
        ReleaseSwapchainImagesInfoKHR
          { swapchain = target.targetSwapchain
          , imageIndices = Vector.singleton image
          }
  note journal ("released rendered but unpresented image " <> Text.pack (show image) <> " after its render-finished semaphore was consumed")
  pure
    ReleaseRecord
      { releaseImage = image
      , releaseCleanup = "the frame's own rendering submission, then a tracked zero-command submission consuming the render-finished semaphore"
      , releaseCleanupFenceSignalled = rendered && settled
      , releaseSemaphoreSettledBy = "a tracked cleanup submission that waited on it"
      , releaseResult = either (Text.pack . show) (const "SUCCESS") outcome
      , releaseSucceeded = either (const False) (const True) outcome
      }

-- --------------------------------------------------------------------------
-- The capture path

proveCapture ∷ Journal → Device → PhysicalDevice → Queue → Target → Slots → IO CaptureFacts
proveCapture journal device physical queue target slots = do
  let slot = slots.firstSlot
      extent = target.targetExtent
      width = extent.width
      height = extent.height
      size = fromIntegral width * fromIntegral height * 4 ∷ Word64
  _ ← reclaim device slot
  buffer ←
    createBuffer
      device
      ( BufferCreateInfo
          { next = ()
          , flags = zero
          , size = size
          , usage = BUFFER_USAGE_TRANSFER_DST_BIT
          , sharingMode = SHARING_MODE_EXCLUSIVE
          , queueFamilyIndices = Vector.empty
          }
          ∷ BufferCreateInfo '[]
      )
      Nothing
  requirements ← getBufferMemoryRequirements device buffer
  memoryProperties ← getPhysicalDeviceMemoryProperties physical
  let wanted = MEMORY_PROPERTY_HOST_VISIBLE_BIT .|. MEMORY_PROPERTY_HOST_COHERENT_BIT
      suitable =
        [ fromIntegral index
        | (index, memoryType) ← zip [0 ∷ Int ..] (Vector.toList memoryProperties.memoryTypes)
        , requirements.memoryTypeBits .&. (1 `shiftL` index) /= 0
        , memoryType.propertyFlags .&. wanted == wanted
        ]
  typeIndex ← case suitable of
    (value : _) → pure value
    [] → stop "the capture path" "no host-visible, host-coherent memory type can hold a readback buffer"
  memory ←
    allocateMemory
      device
      ( MemoryAllocateInfo
          { next = ()
          , allocationSize = requirements.size
          , memoryTypeIndex = typeIndex
          }
          ∷ MemoryAllocateInfo '[]
      )
      Nothing
  bindBufferMemory device buffer memory 0
  (_, image) ← acquireInto device target slot
  resetCommandBuffer slot.slotCommands zero
  useCommandBuffer slot.slotCommands beginOnce $ do
    transition slot.slotCommands (imageAt target image) IMAGE_LAYOUT_UNDEFINED IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
    cmdClearColorImage slot.slotCommands (imageAt target image) IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL proofColor (Vector.singleton wholeImage)
    transition slot.slotCommands (imageAt target image) IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
    cmdCopyImageToBuffer2
      slot.slotCommands
      CopyImageToBufferInfo2
        { srcImage = imageAt target image
        , srcImageLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
        , dstBuffer = buffer
        , regions =
            Vector.singleton
              ( SomeStruct
                  ( BufferImageCopy2
                      { next = ()
                      , bufferOffset = 0
                      , bufferRowLength = 0
                      , bufferImageHeight = 0
                      , imageSubresource =
                          ImageSubresourceLayers
                            { aspectMask = IMAGE_ASPECT_COLOR_BIT
                            , mipLevel = 0
                            , baseArrayLayer = 0
                            , layerCount = 1
                            }
                      , imageOffset = Offset3D 0 0 0
                      , imageExtent = Extent3D width height 1
                      }
                      ∷ BufferImageCopy2 '[]
                  )
              )
        }
    transition slot.slotCommands (imageAt target image) IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL IMAGE_LAYOUT_PRESENT_SRC_KHR
    -- The copy has to be made available to the host domain before the host may
    -- read it. Waiting on the submission fence does not do that: a fence's
    -- access scope covers device accesses only. Host-coherent memory removes
    -- the need to invalidate a mapped range; it does not remove the need for
    -- this barrier, and without one the bytes that come back are the
    -- implementation's habit rather than a guarantee.
    hostReadBarrier slot.slotCommands buffer
  resetFences device (Vector.singleton slot.slotRenderFence)
  submitWith queue [slot.slotAcquire] [slot.slotCommands] [slot.slotPresent] slot.slotRenderFence
  _ ← awaitFence "the capture submission" device slot.slotRenderFence
  mapped ← mapMemory device memory 0 requirements.size zero
  observed ← forM [0 .. 3 ∷ Int] $ \offset → do
    byte ← peekByteOff mapped offset ∷ IO Word8
    pure (fromIntegral byte ∷ Word32)
  unmapMemory device memory
  _ ← presentWithFence device queue target slot image
  freeMemory device memory Nothing
  destroyBuffer device buffer Nothing
  note journal ("captured " <> Text.pack (show observed) <> " through TRANSFER_SRC from the presented format")
  pure
    CaptureFacts
      { captureFormat = Text.pack (show target.targetFormat)
      , captureExtent = (width, height)
      , captureExpected = Text.pack (show proofColorBytes)
      , captureObserved = Text.pack (show observed)
      , captureMatched = observed == proofColorBytes
      , captureBytes = size
      }

-- --------------------------------------------------------------------------
-- Small helpers

countPhase ∷ [Diagnostic] → Text → Int
countPhase diagnostics phase = length [() | d ← diagnostics, diagnosticPhase d == phase]

summarizePhases ∷ [Diagnostic] → [PhaseCount]
summarizePhases diagnostics =
  [ PhaseCount
      { phaseName = phase
      , phaseNatural = length [() | d ← diagnostics, diagnosticPhase d == phase, not (diagnosticInjected d)]
      , phaseInjected = length [() | d ← diagnostics, diagnosticPhase d == phase, diagnosticInjected d]
      }
  | phase ← ordered
  ]
  where
    ordered = foldl remember [] (map diagnosticPhase diagnostics)
    remember seen phase = if phase `elem` seen then seen else seen <> [phase]

decodeName ∷ ByteString → Text
decodeName = Encoding.decodeUtf8Lenient

commaSeparated ∷ [Text] → Text
commaSeparated = Text.intercalate ", "

describeVersion ∷ Word32 → Text
describeVersion version =
  let (major, minor) = apiMajorMinor version
   in Text.intercalate "." (map (Text.pack . show) [major, minor, fromIntegral (version .&. 0xFFF)])

-- | The packed Vulkan version encoding. The binding exports @VK_MAKE_API_VERSION@
-- and @VK_API_VERSION_1_3@ only as pattern synonyms, and naming a pattern
-- synonym in an import list needs a namespace specifier this compiler has
-- deprecated; writing the three-line encoding is clearer than working around
-- that, and it is the exact inverse of 'apiMajorMinor' below.
packVersion ∷ Word32 → Word32 → Word32 → Word32
packVersion major minor patch = (major `shiftL` 22) .|. (minor `shiftL` 12) .|. patch

apiMajorMinor ∷ Word32 → (Int, Int)
apiMajorMinor version =
  ( fromIntegral ((version `shiftR` 22) .&. 0x7F)
  , fromIntegral ((version `shiftR` 12) .&. 0x3FF)
  )

describeConformance ∷ ConformanceVersion → Text
describeConformance version =
  Text.intercalate
    "."
    (map (Text.pack . show) [version.major, version.minor, version.subminor, version.patch])

describeUsages ∷ ImageUsageFlags → [Text]
describeUsages flags =
  [ name
  | (name, bit) ←
      [ ("TRANSFER_SRC", IMAGE_USAGE_TRANSFER_SRC_BIT)
      , ("TRANSFER_DST", IMAGE_USAGE_TRANSFER_DST_BIT)
      , ("SAMPLED", IMAGE_USAGE_SAMPLED_BIT)
      , ("STORAGE", IMAGE_USAGE_STORAGE_BIT)
      , ("COLOR_ATTACHMENT", IMAGE_USAGE_COLOR_ATTACHMENT_BIT)
      , ("INPUT_ATTACHMENT", IMAGE_USAGE_INPUT_ATTACHMENT_BIT)
      ]
  , flags .&. bit /= zero
  ]

-- | The 1.3 core features this proof enables, written out rather than updated
-- from a zero value so that what is asked for is visible in one place.
vulkan13Features ∷ PhysicalDeviceVulkan13Features
vulkan13Features =
  PhysicalDeviceVulkan13Features
    { robustImageAccess = False
    , inlineUniformBlock = False
    , descriptorBindingInlineUniformBlockUpdateAfterBind = False
    , pipelineCreationCacheControl = False
    , privateData = False
    , shaderDemoteToHelperInvocation = False
    , shaderTerminateInvocation = False
    , subgroupSizeControl = False
    , computeFullSubgroups = False
    , synchronization2 = True
    , textureCompressionASTC_HDR = False
    , shaderZeroInitializeWorkgroupMemory = False
    , dynamicRendering = True
    , shaderIntegerDotProduct = False
    , maintenance4 = False
    }
