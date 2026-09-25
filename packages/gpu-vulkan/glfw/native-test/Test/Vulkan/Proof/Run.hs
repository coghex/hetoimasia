{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The native run: one linear procedure on the process main thread that
-- observes everything issue #158 asks for and then tears down as much of the
-- session as its own evidence permits.
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
--
-- Teardown is not promised complete. A run that finished owes nothing and
-- releases all ten of its cleanup entries in order; a run that stopped with a
-- presentation still outstanding, or whose device-idle boundary failed, does
-- not, and destroying on through that would be the device-idle fallback the
-- accepted design forbids. What may be destroyed is decided by
-- "Test.Vulkan.Proof.Retention", which is pure and is exercised headlessly by
-- "Test.Vulkan.Proof.RetentionSpec"; this module supplies that decision with
-- the native effects and results it recorded, and obeys it. Retention plus
-- process exit is the escape for a session that never resolves: no native call
-- here is preemptible and no native destroy is wrapped in a timeout.
--
-- What a native call did is owned the same way a handle is.
-- @vkQueuePresentKHR@ has enqueued its semaphore waits and chained its present
-- fence the moment it returns, and the ledger entry saying so is the only
-- evidence teardown has of it;
-- so the call and that entry are one masked step, which
-- "Test.Vulkan.Proof.Publication" performs and
-- "Test.Vulkan.Proof.PublicationSpec" exercises headlessly with the call
-- replaced. A cancellation delivered across it is deferred until the entry is
-- in and then stops the run at the presentation step, carrying its own
-- failure, rather than being lost or reported as an unexpected exception.
--
-- Teardown can only decide over handles it was given, so every native object
-- this module creates has a cleanup owner before the next fallible step runs.
-- For a handle whose whole construction is one call that is 'owning', which
-- puts the create and the registration in one masked step. For the two
-- composites built from several fallible calls — a frame slot, and the capture
-- buffer with its memory — it is "Test.Vulkan.Proof.Construction": every one
-- of their releases is registered before the first of their native calls runs,
-- against places that are empty until each child exists, so a failure partway
-- releases exactly what exists, in dependency order, before the device is
-- destroyed. The successful path is unchanged by that — the same ten entries
-- in the same order — because the capture frees its own two handles at the end
-- as it always did and then recalls their registrations. Both constructions
-- are exercised headlessly, with the native layer replaced and the step to
-- fail at chosen, by "Test.Vulkan.Proof.ConstructionSpec".
module Test.Vulkan.Proof.Run (runProof) where

import Control.Concurrent (isCurrentThreadBound, rtsSupportsBoundThreads)
import Control.Exception (SomeException, displayException, mask_, throwIO, try)
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
import System.Directory (canonicalizePath)
import System.Environment (lookupEnv)
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
import Vulkan.Extensions.VK_EXT_validation_features (ValidationFeaturesEXT, data EXT_VALIDATION_FEATURES_EXTENSION_NAME)
import Vulkan.Extensions.VK_KHR_get_surface_capabilities2
import Vulkan.Extensions.VK_KHR_portability_enumeration
import Vulkan.Extensions.VK_KHR_portability_subset
import Vulkan.Extensions.VK_KHR_surface
import Vulkan.Extensions.VK_KHR_swapchain
import Vulkan.Zero (zero)

import Hetoimasia.GPU.Vulkan.Native.Roots.Vulkan (validationFeaturesInfo)
import Test.GPU.Vulkan.Native.Consent (Consent, describeConsent)
import Test.GPU.Vulkan.Native.Environment (applyImplicitLayerPolicy, clearConflictingOverrides, validationFeatures)
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
import Test.Vulkan.Proof.Construction
  ( CaptureOps (..)
  , CapturePlaces
  , SlotOps (..)
  , SlotParts (..)
  , capturePlaceReleases
  , fillSlot
  , newCapturePlaces
  , newSlotPlaces
  , runCapture
  , slotPlaceReleases
  )
import Test.Vulkan.Proof.Journal (Journal, heading, note)
import Test.Vulkan.Proof.Loader (loaderSelection, loaderVariable)
import Test.Vulkan.Proof.Ownership
  ( Cleanups
  , Ledger
  , newCleanups
  , newLedger
  , observe
  , observations
  , onExit
  , onExitHolding
  , onExitRecallable
  , owning
  , runCleanups
  )
import Test.Vulkan.Proof.Publication
  ( catchAll
  , presentationStep
  , publishPresent
  , require
  , stop
  )
import Test.Vulkan.Proof.Retention
  ( Handle (..)
  , NativeResult (..)
  , Observation (..)
  , SlotName
  , Standing (..)
  , classifyResult
  , classifyThrown
  , describeResult
  , standingFrom
  )

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

-- | Where the revision under test comes from. `tools/vulkan/run.sh`
-- derives it from the checkout, marking a dirty one.
revisionVariable ∷ String
revisionVariable = "HETOIMASIA_VULKAN_REVISION"

-- | The exact identity of the sources under test, which the runner computes
-- from their content. A revision can be dirty or absent; this cannot.
digestVariable ∷ String
digestVariable = "HETOIMASIA_VULKAN_SOURCE_DIGEST"


-- --------------------------------------------------------------------------
-- The run

-- | Run the whole proof. Returns what it observed, or the step it stopped at.
--
-- Either way teardown has run to completion and the callback evidence is
-- complete before this returns. Teardown running to completion is not the
-- session being fully destroyed: a run that stopped owing a presentation, or
-- whose device-idle boundary failed, deliberately returns with the handles
-- that presentation outlives still alive — up to and including the device,
-- the window, the instance, the callback trampoline, and GLFW — and the
-- outcome says which and why. Those are released by process exit.
runProof ∷ Journal → Consent → IO Outcome
runProof journal consent = do
  cleanups ← newCleanups
  sink ← newCallbackSink
  ledger ← newLedger
  outcome ← catchAll (Proved <$> procedure journal consent cleanups sink ledger) (pure . (`Stopped` noTeardown))
  -- Teardown happens here: after the procedure, and before the callback
  -- evidence is read. That ordering is the requirement. What it destroys is
  -- not fixed — a stop can leave a presentation outstanding, and a handle it
  -- outlives is retained rather than freed.
  facts ← runCleanups journal ledger cleanups
  diagnostics ← reverse <$> readIORef sink.sinkDiagnostics
  failures ← reverse <$> readIORef sink.sinkFailures
  for_ failures $ \failure → note journal ("a callback reported a failure: " <> failure)
  pure (completeAfterTeardown facts diagnostics failures outcome)

-- | Fill in the facts that only exist once teardown has run: the callback
-- evidence, and what teardown itself did.
--
-- A stopped run keeps its step and its failed verdict and gains the teardown
-- facts. Teardown can obtain the very completion the run stopped waiting for,
-- and that still does not make the run a proof; what it changes is what the
-- record can say about which handles survived it.
completeAfterTeardown ∷ TeardownFacts → [Diagnostic] → [Text] → Outcome → Outcome
completeAfterTeardown facts diagnostics failures = \case
  Stopped failure _ → Stopped failure facts
  Proved findings →
    Proved
      findings
        { findingsTeardown = facts
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

procedure ∷ Journal → Consent → Cleanups → CallbackSink → Ledger → IO Findings
procedure journal consent cleanups sink ledger = do
  heading journal "The environment"
  cleared ← clearConflictingOverrides
  for_ cleared $ \name → note journal ("cleared a conflicting discovery override: " <> name)
  implicitPolicy ← applyImplicitLayerPolicy
  note journal ("implicit-layer policy: " <> implicitPolicy)
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
  -- GLFW is handed this same entry point, so the two share a loader by
  -- construction; what that does not establish is that the loader is the
  -- qualified one rather than a substitute a runtime search path put ahead of
  -- it. Both paths are canonicalized, because the dynamic linker reports the
  -- soname it opened and the record names the file behind it.
  recordedLoader ← lookupEnv loaderVariable >>= traverse canonicalizePath
  loadedLoader ← traverse (canonicalizePath . Text.unpack) (provenanceImage bindingEntry)
  case loaderSelection recordedLoader loadedLoader of
    Left reason → stop "the recorded loader" reason
    Right loaded → note journal ("the binding's loader is the recorded loader " <> Text.pack loaded)
  initVulkanLoader entry
  -- The registration is inside the mask with the call that earns it, so a
  -- cancellation delivered here cannot leave GLFW initialized with nothing to
  -- terminate it. Everything below that acquires a handle does the same, either
  -- through 'owning' or through a mask of its own where the call reports
  -- success some other way than by returning the handle.
  started ← mask_ $ do
    ok ← glfwInit
    when ok (onExit cleanups GlfwTermination glfwTerminate)
    pure ok
  unless started $ do
    reason ← lastGlfwError
    stop "GLFW initialization" ("glfwInit failed: " <> reason)
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
          <> [EXT_VALIDATION_FEATURES_EXTENSION_NAME]
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
  -- Synchronization validation is enabled by this instance's own create info,
  -- through the layer's validation-features extension, exactly as the
  -- production roots enable it. A layer that does not offer the extension is
  -- a stop, never a run validated without it.
  (_, layerExtensions) ← enumerateInstanceExtensionProperties (Just validationLayer)
  require
    "synchronization validation"
    "the validation layer does not offer VK_EXT_validation_features, so synchronization validation cannot be enabled"
    (EXT_VALIDATION_FEATURES_EXTENSION_NAME `elem` [e.extensionName | e ← Vector.toList layerExtensions])
  note journal ("the instance enables the validation features " <> Text.pack (show validationFeatures) <> " through its create info")

  -- Registered before the instance, so it is released after it: the trampoline
  -- has to still be callable while vkDestroyInstance runs.
  callback ←
    owning cleanups TheCallbackTrampoline (wrapDebugCallback (debugCallback sink)) freeHaskellFunPtr
  let createInfo = messengerCreateInfo callback

  enterPhase sink "instance creation"
  handle ←
    owning cleanups TheVulkanInstance
    ( createInstance
      ( InstanceCreateInfo
          { next = (createInfo, (validationFeaturesInfo validationFeatures, ()))
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
          ∷ InstanceCreateInfo '[DebugUtilsMessengerCreateInfoEXT, ValidationFeaturesEXT]
      )
      Nothing
    )
    -- The create-info messenger is still live while the instance is destroyed.
    -- That is deliberate: requirement 8 asks what reaches Haskell during
    -- instance destruction, after the explicit messenger is already gone.
    ( \created → do
        enterPhase sink destructionPhase
        destroyInstance created Nothing
    )
  enterPhase sink "after instance creation"

  bindingSample ← provenanceOf (castFunPtrToPtr (pVkCreateDevice handle.instanceCmds))
  glfwSample ← instanceProcAddress (castPtr (instanceHandle handle)) "vkCreateDevice" >>= provenanceOf
  note journal ("the binding resolves vkCreateDevice to " <> describeProvenance bindingSample)
  note journal ("GLFW resolves vkCreateDevice to " <> describeProvenance glfwSample)

  enterPhase sink "messenger creation"
  -- Registered immediately after the instance, so it is destroyed immediately
  -- before it — and therefore after the swapchain, the device, the surface and
  -- the window. A messenger torn down before them would leave every diagnostic
  -- those destructions emit, including a device's leak reports, with nowhere to
  -- go, while the record still said zero validation errors. The create-info
  -- messenger cannot stand in: the extension uses it for instance creation and
  -- destruction alone.
  _ ←
    owning
      cleanups
      TheExplicitMessenger
      (createDebugUtilsMessengerEXT handle createInfo Nothing)
      ( \created → do
          enterPhase sink afterMessengerPhase
          destroyDebugUtilsMessengerEXT handle created Nothing
      )
  inject sink handle "creation"

  heading journal "The window and its surface"
  -- Both of these report failure by something other than throwing, so neither
  -- can go through 'owning': the registration has to be conditional on the
  -- result, inside the same mask as the call that produced it.
  opened ← mask_ $ do
    outcome ← createProofWindow 320 240 "hetoimasia Vulkan proof"
    for_ outcome $ \shown → onExit cleanups TheProofWindow (destroyProofWindow shown)
    pure outcome
  window ← case opened of
    Nothing → do
      reason ← lastGlfwError
      stop "the proof window" ("glfwCreateWindow failed: " <> reason)
    Just value → pure value
  (surfaceResult, surfaceHandle) ← mask_ $ do
    outcome@(result, raw) ← createWindowSurface (castPtr (instanceHandle handle)) window
    when (result == 0) $
      onExit cleanups TheWindowSurface (destroySurfaceKHR handle (SurfaceKHR raw) Nothing)
    pure outcome
  require
    "the window surface"
    ("glfwCreateWindowSurface returned " <> Text.pack (show (Result (fromIntegral surfaceResult))))
    (surfaceResult == 0)
  let surface = SurfaceKHR surfaceHandle
  pollEvents

  heading journal "The device profile"
  (_, devices) ← enumeratePhysicalDevices handle
  require "physical devices" "the loader enumerated no physical device through the pinned driver" (not (Vector.null devices))
  selection ← selectDevice journal surface (Vector.toList devices)

  enterPhase sink "device creation"
  device ←
    owning cleanups TheLogicalDevice
    ( createDevice
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
    )
    (\created → destroyDevice created Nothing)
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
  target ← buildTarget journal cleanups device selection surface

  slots ← newSlots cleanups device selection.selectedQueueFamily ledger

  -- The capture path's buffer and its memory, owned from here rather than from
  -- inside that path, for two reasons. Its releases have to be registered
  -- before the teardown boundary below, so teardown reaches them after the
  -- boundary that establishes its copy has completed; and a place that exists
  -- before the first native call is what lets every step of the capture fail
  -- without orphaning what already exists. A capture that reaches the end
  -- frees both itself and recalls these two registrations, so a whole run
  -- still arrives at teardown holding the same ten entries it always did.
  capturePlaces ← newCapturePlaces
  let captureOperations = captureOps device selection.selectedDevice queue target slots.firstSlot
  recallCapture ←
    forM (reverse (capturePlaceReleases captureOperations capturePlaces)) $
      \(what, cleanup) → onExitRecallable cleanups what cleanup

  -- Registered last, so it runs first: every destruction below rests on what
  -- this establishes, and every diagnostic any of them emits is attributed to
  -- teardown. It is not itself a destruction. Its device-idle result and the
  -- bounded present-fence waits it then takes are the whole of the evidence
  -- the releases below are judged against; device idle alone is not that
  -- evidence, which is why the waits are here at all.
  onExit cleanups TheTeardownBoundary $ do
    enterPhase sink teardownPhase
    idled ← try @SomeException (deviceWaitIdle device)
    observe ledger (TeardownBoundaryReached (either classifyThrown (const Succeeded) idled))
    probePresentFences device ledger slots
    either throwIO pure idled

  heading journal "Presentation completion"
  enterPhase sink "submission"
  inject sink handle "submission"
  completion ← proveCompletion journal device queue target slots

  heading journal "Safe abandonment"
  enterPhase sink "abandonment"
  abandonment ← proveAbandonment journal device queue target slots

  heading journal "Transfer-source capture"
  enterPhase sink "capture"
  capture ← proveCapture journal device target slots captureOperations capturePlaces
  -- Reached only when the capture freed both of its handles itself, which is
  -- the one path on which taking the registrations back is right.
  sequence_ recallCapture

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
            , platformImplicitLayerPolicy = implicitPolicy
            , platformValidationLayerLoaded = validationLoaded
            , platformValidationFeatures = map (Text.pack . show) validationFeatures
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
        findingsTeardown = noTeardown
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

-- | The swapchain is registered inside this function rather than by its
-- caller, because two fallible steps follow its creation — reading its images
-- back, and allocating the counter the abandonment paths check — and a failure
-- at either used to leave a created swapchain with no owner while the device
-- release registered above it still ran.
buildTarget ∷ Journal → Cleanups → Device → Selection → SurfaceKHR → IO Target
buildTarget journal cleanups device selection surface = do
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
    owning cleanups TheSwapchain
    ( createSwapchainKHR
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
    )
    (\created → destroySwapchainKHR device created Nothing)
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
  , slotLedger ∷ Ledger
    -- ^ The run's shared ledger, reached through the slot because the slot is
    -- what creates a presentation obligation and what later discharges one.
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

-- | The name a slot is known by, in the record and on the ledger.
slotNameAt ∷ Int → SlotName
slotNameAt index = "slot " <> Text.pack (show index)

-- | The native layer a frame slot is built from.
slotOps ∷ Device → Word32 → SlotOps Semaphore Fence CommandPool CommandBuffer
slotOps device family =
  SlotOps
    { createSlotSemaphore =
        createSemaphore device (SemaphoreCreateInfo {next = (), flags = zero} ∷ SemaphoreCreateInfo '[]) Nothing
    , destroySlotSemaphore = \semaphore → destroySemaphore device semaphore Nothing
    , createSlotFence =
        createFence device (FenceCreateInfo {next = (), flags = zero} ∷ FenceCreateInfo '[]) Nothing
    , destroySlotFence = \fence → destroyFence device fence Nothing
    , createSlotPool =
        createCommandPool
          device
          CommandPoolCreateInfo
            { next = ()
            , flags = COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT
            , queueFamilyIndex = family
            }
          Nothing
    , destroySlotPool = \pool → destroyCommandPool device pool Nothing
    , allocateSlotCommands = \pool →
        Vector.head
          <$> allocateCommandBuffers
            device
            CommandBufferAllocateInfo
              { commandPool = pool
              , level = COMMAND_BUFFER_LEVEL_PRIMARY
              , commandBufferCount = 1
              }
    }

-- | Build the pool of slots, with every release registered before the first
-- native object of either exists.
--
-- Both slots' places and all six of their releases come first, in reverse of
-- the order teardown reaches them because a registration is a push. Only then
-- does anything get created. That is the whole of the repair for this
-- composite: a failure at any step of either slot — the second semaphore of
-- the first, or any step of the second while the first is already whole —
-- now releases exactly the children that exist, in dependency order, before
-- the device registered above them is destroyed.
--
-- A slot's own three releases stay separable so that an outstanding present
-- can withhold its fence and its presentation semaphore while its command
-- pool, rendering fence and acquisition semaphore — whose completion the
-- teardown boundary does establish — still go.
newSlots ∷ Cleanups → Device → Word32 → Ledger → IO Slots
newSlots cleanups device family ledger = do
  let ops = slotOps device family
      names = map slotNameAt [0 .. slotCount - 1]
  places ← forM names newSlotPlaces
  for_ (reverse (concat (zipWith (slotPlaceReleases ops) names places))) $ \(what, cleanup) →
    onExitHolding cleanups what cleanup
  built ← forM (zip names places) $ \(name, place) → do
    parts ← fillSlot ops place
    presented ← newIORef False
    pure
      Slot
        { slotName = name
        , slotAcquire = parts.partAcquireSemaphore
        , slotPresent = parts.partPresentSemaphore
        , slotRenderFence = parts.partRenderFence
        , slotPresentFence = parts.partPresentFence
        , slotPool = parts.partPool
        , slotCommands = parts.partCommands
        , slotPresented = presented
        , slotLedger = ledger
        }
  case built of
    [a, b] → pure (Slots a b)
    _ → stop "the frame slots" "the slot pool was not built as a pair"

-- | The one route from retained to destroyed that is not device loss: during
-- teardown, a bounded wait on every present fence the run still owes.
--
-- The bound is the fence wait's own timeout, which is a native parameter. No
-- native call is made preemptible and no destroy is wrapped in a Haskell
-- timeout: a wait that expires here leaves the obligation exactly where it
-- was, and the handles behind it are retained until the process exits.
probePresentFences ∷ Device → Ledger → Slots → IO ()
probePresentFences device ledger slots = do
  recorded ← observations ledger
  let owed = map fst (standingFrom recorded).standingPending
  for_ (eachSlot slots) $ \slot →
    when (slot.slotName `elem` owed) $ do
      outcome ←
        try @SomeException
          (waitForFences device (Vector.singleton slot.slotPresentFence) True (5 * oneSecond))
      observe ledger (PresentFenceWaited slot.slotName (either classifyThrown classifyResult outcome))

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

-- | Wait on a rendering or cleanup fence. These are queue fences: the device
-- has no presentation obligation riding on them, so nothing here is recorded
-- for the release decision.
awaitFence ∷ Text → Device → Fence → IO Bool
awaitFence what device fence = do
  result ← waitForFences device (Vector.singleton fence) True (5 * oneSecond)
  require "completion" (what <> " did not signal within five seconds: " <> Text.pack (show result)) (result == SUCCESS)
  status ← getFenceStatus device fence
  pure (status == SUCCESS)

-- | Wait on a slot's present fence, recording what the wait returned before
-- deciding anything about it.
--
-- A timeout still stops the run at the step a timeout has always stopped it
-- at. What changes is that the obligation it leaves outstanding is now on the
-- ledger teardown reads, so the slot's present fence and presentation
-- semaphore are retained rather than destroyed behind it. A timeout is never
-- promoted to device loss: only @VK_ERROR_DEVICE_LOST@ is that.
awaitPresentFence ∷ Text → Device → Slot → IO Bool
awaitPresentFence what device slot = do
  outcome ←
    try @SomeException
      (waitForFences device (Vector.singleton slot.slotPresentFence) True (5 * oneSecond))
  let result = either classifyThrown classifyResult outcome
  observe slot.slotLedger (PresentFenceWaited slot.slotName result)
  require
    "completion"
    (what <> " did not signal within five seconds: " <> describeResult result)
    (result == Succeeded)
  status ← getFenceStatus device slot.slotPresentFence
  pure (status == SUCCESS)

-- | Present one acquired image with a present fence, reporting the fence's
-- status before the wait as well as after it.
--
-- The enqueue and the ledger entry that records it are one masked step, which
-- 'publishPresent' performs. @vkQueuePresentKHR@ chains the slot's present
-- fence and enqueues its semaphore waits, so the obligation exists on the
-- device from the instant the call returns; a cancellation taken before the
-- entry is written would leave teardown with no evidence of it, and teardown
-- would then destroy the present fence, the presentation semaphore and the
-- swapchain behind it. The mask covers the native call and the 'IORef' write
-- that records its effect. The driver may block inside the call; a @safe@
-- import does not make it interruptible or bound cancellation latency.
-- Explicit fence and acquire waits remain outside this mask with their
-- cancellation behaviour unchanged; cancellation may await native return.
-- No destroy is wrapped in a timeout. 'publishPresent' takes cancellation
-- deferred across the handoff once the entry is in, stopping the run here at
-- the presentation step with the cancellation's own failure.
presentWithFence ∷ Device → Queue → Target → Slot → Word32 → IO (Text, Text, Bool)
presentWithFence device queue target slot index = do
  resetFences device (Vector.singleton slot.slotPresentFence)
  (outcome, result) ←
    publishPresent slot.slotLedger slot.slotName slot.slotPresented $
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
    presentationStep
    ("vkQueuePresentKHR returned " <> describeResult result)
    (result == Succeeded || result == Suboptimal)
  before ← getFenceStatus device slot.slotPresentFence
  pollEvents
  signalled ← awaitPresentFence "the present fence" device slot
  pure (either (Text.pack . displayException) (Text.pack . show) outcome, if before == SUCCESS then "signalled" else "not ready", signalled)

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
      _ ← awaitPresentFence ("the present fence of " <> slot.slotName) device slot
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

-- | How large a readback of the whole presented image is.
captureSize ∷ Target → Word64
captureSize target =
  let extent = target.targetExtent
   in fromIntegral extent.width * fromIntegral extent.height * 4

-- | The native layer the capture path is built from.
--
-- The allocation is carried as a pair with the size it was made at, because
-- the readback needs that size and the size is a property of the allocation
-- rather than of the buffer the caller asked for. Nothing else about either
-- handle leaves this function: the construction above them is written once,
-- against open types, so the headless examples run the same sequence.
captureOps
  ∷ Device
  → PhysicalDevice
  → Queue
  → Target
  → Slot
  → CaptureOps Buffer (DeviceMemory, DeviceSize) Word32
captureOps device physical queue target slot =
  CaptureOps
    { captureCreateBuffer =
        createBuffer
          device
          ( BufferCreateInfo
              { next = ()
              , flags = zero
              , size = captureSize target
              , usage = BUFFER_USAGE_TRANSFER_DST_BIT
              , sharingMode = SHARING_MODE_EXCLUSIVE
              , queueFamilyIndices = Vector.empty
              }
              ∷ BufferCreateInfo '[]
          )
          Nothing
    , captureDestroyBuffer = \buffer → destroyBuffer device buffer Nothing
    , captureAllocateMemory = \buffer → do
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
        pure (memory, requirements.size)
    , captureFreeMemory = \(memory, _) → freeMemory device memory Nothing
    , captureBindMemory = \buffer (memory, _) → bindBufferMemory device buffer memory 0
    , captureAcquireImage = snd <$> acquireInto device target slot
    , captureRecordAndSubmit = \buffer image → do
        let extent = target.targetExtent
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
                            , imageExtent = Extent3D extent.width extent.height 1
                            }
                            ∷ BufferImageCopy2 '[]
                        )
                    )
              }
          transition slot.slotCommands (imageAt target image) IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL IMAGE_LAYOUT_PRESENT_SRC_KHR
          -- The copy has to be made available to the host domain before the
          -- host may read it. Waiting on the submission fence does not do
          -- that: a fence's access scope covers device accesses only.
          -- Host-coherent memory removes the need to invalidate a mapped
          -- range; it does not remove the need for this barrier, and without
          -- one the bytes that come back are the implementation's habit rather
          -- than a guarantee.
          hostReadBarrier slot.slotCommands buffer
        resetFences device (Vector.singleton slot.slotRenderFence)
        submitWith queue [slot.slotAcquire] [slot.slotCommands] [slot.slotPresent] slot.slotRenderFence
    , captureAwaitSubmission =
        () <$ awaitFence "the capture submission" device slot.slotRenderFence
    , captureReadBack = \(memory, size) → do
        mapped ← mapMemory device memory 0 size zero
        observed ← forM [0 .. 3 ∷ Int] $ \offset → do
          byte ← peekByteOff mapped offset ∷ IO Word8
          pure (fromIntegral byte ∷ Word32)
        unmapMemory device memory
        pure observed
    , capturePresent = \image → () <$ presentWithFence device queue target slot image
    }

-- | The transfer-source capture, whose buffer and memory are owned from the
-- instant each exists.
--
-- The places are the procedure's, registered before the teardown boundary, so
-- a failure anywhere in this path leaves both to a teardown that destroys them
-- after the boundary has established that the copy completed — or retains them
-- and says why, if it has not. The path that reaches the end frees both
-- itself, exactly once, as it always did.
proveCapture
  ∷ Journal
  → Device
  → Target
  → Slots
  → CaptureOps Buffer (DeviceMemory, DeviceSize) Word32
  → CapturePlaces Buffer (DeviceMemory, DeviceSize)
  → IO CaptureFacts
proveCapture journal device target slots operations places = do
  let slot = slots.firstSlot
      extent = target.targetExtent
  _ ← reclaim device slot
  -- The same operations the procedure registered these places' releases
  -- against, rather than a second value built the same way: whichever of the
  -- two reaches a place first is the only one that destroys what is in it, and
  -- there is no question of which destructor that was.
  observed ← runCapture operations places
  note journal ("captured " <> Text.pack (show observed) <> " through TRANSFER_SRC from the presented format")
  pure
    CaptureFacts
      { captureFormat = Text.pack (show target.targetFormat)
      , captureExtent = (extent.width, extent.height)
      , captureExpected = Text.pack (show proofColorBytes)
      , captureObserved = Text.pack (show observed)
      , captureMatched = observed == proofColorBytes
      , captureBytes = captureSize target
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
