{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | VK-6's native cases: the production diagnostic capture on a real instance.
--
-- A second, separate session after the VK-2 run, on its own instance, with no
-- window and no surface. Everything that can report into it reports through
-- the native backend package's C messenger callback into a
-- "Hetoimasia.GPU.Vulkan.Diagnostics" lifetime; this session installs no
-- Haskell callback, so no Vulkan call it makes can re-enter Haskell. That is
-- what lets two of its calls go through genuine @unsafe@ foreign imports, which
-- is the case D-28 needs shown and the VK-2 run, whose Haskell callback is
-- the binding-wide @safe@ configuration, cannot show:
--
-- * @vkSubmitDebugUtilsMessageEXT@, which delivers one chosen message to the
--   explicit messenger from inside the call; and
-- * @vkCmdSetViewport@ with a viewport count of zero, a short recording command
--   the validation layer rejects, so a validation error reaches the production
--   callback from inside an unsafe recording call.
--
-- Around every native call the session reads the storage's own counters, so
-- the reports each call produced are attributed to it by the callback's
-- synchronous effect rather than by anything the callback wrote to Haskell. The
-- storage is released only after the last of them: 'withDiagnosticCapture'
-- owns this whole session, and @vkDestroyInstance@ — where the create-info
-- messenger reports after the explicit one is gone — is the last thing its
-- body does. The verdict is read afterwards.
--
-- Like "Test.Vulkan.Proof.Run", nothing here asserts. It records what it saw,
-- and "Test.Vulkan.Proof.DiagnosticsSpec" decides.
module Test.Vulkan.Proof.Diagnostics
  ( DiagnosticsOutcome (..)
  , DiagnosticsFacts (..)
  , PhaseReports (..)
  , runDiagnostics
  , submittedMessageId
  , provokedValidationId
  , unsafeImportNames
  , destructionPhase
  , submitPhase
  , recordingPhase
  , creationPhase
  , sessionConfig
  ) where

import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception (SomeException, displayException, throwIO, try)
import Control.Monad (forM, unless)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as Char8
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import qualified Data.Vector as Vector
import Data.Word (Word32, Word64)
import Foreign.Ptr (FunPtr, Ptr, castFunPtr, castFunPtrToPtr, castPtr, nullPtr)
import System.Directory (canonicalizePath)
import System.Environment (getExecutablePath, lookupEnv)

import Vulkan.CStruct (withCStruct)
import Vulkan.Core10
import Vulkan.Core13 (data API_VERSION_1_3)
import Vulkan.CStruct.Extends (SomeStruct (..))
import Vulkan.Dynamic (DeviceCmds (..), InstanceCmds (..))
import Vulkan.Extensions.VK_EXT_debug_utils
import Vulkan.Extensions.VK_KHR_portability_enumeration
import Vulkan.Extensions.VK_KHR_portability_subset
import Vulkan.Zero (zero)

import Hetoimasia.Foundation.Log
  ( DebugSelection (DebugAll)
  , LogEntry (..)
  , LogFilter (..)
  , LogLevel (Info)
  , callbackSink
  , mkLogger
  )
import Hetoimasia.Foundation.Resource (withResourceLabelled)
import Hetoimasia.GPU.Vulkan.Diagnostics
  ( CaptureConfig (..)
  , CaptureCounters (..)
  , CaptureStatus (..)
  , DiagnosticCapture
  , DiagnosticVerdict (..)
  , captureStatus
  , defaultCaptureConfig
  , diagnosticVerdict
  , withDiagnosticCapture
  )
import Hetoimasia.GPU.Vulkan.Native.Diagnostics
  ( NativeFfiConfiguration
  , captureMessengerCallback
  , captureMessengerCreateInfo
  , createCaptureMessenger
  , destroyCaptureMessenger
  , nativeFfiConfiguration
  )
import Test.Vulkan.Proof.Interop (Provenance (..), provenanceOf)
import Test.Vulkan.Proof.Journal (Journal, heading, note)

-- | The reports that arrived during one native step, read off the storage's
-- own counters before and after it, and the delivered records that were them.
data PhaseReports = PhaseReports
  { phaseName ∷ Text
  , phaseReports ∷ Word64
  , phaseErrors ∷ Word64
  , phaseEntries ∷ [LogEntry]
    -- ^ Attributed by admission order, which is only possible when nothing
    -- was dropped; otherwise empty.
  }
  deriving (Show)

data DiagnosticsFacts = DiagnosticsFacts
  { factsPhases ∷ [PhaseReports]
  , factsVerdict ∷ DiagnosticVerdict
  , factsLoggedEntries ∷ Int
    -- ^ What the logger's sink actually received.
  , factsDevice ∷ Text
  , factsCallback ∷ Provenance
  , factsExecutable ∷ Text
  , factsFfi ∷ NativeFfiConfiguration
  , factsPinnedSafeForeignCalls ∷ Maybe Text
  , factsPinnedDarwinLibDirs ∷ Maybe Text
  , factsUnsafeImports ∷ [Text]
  }
  deriving (Show)

data DiagnosticsOutcome
  = DiagnosticsProved DiagnosticsFacts
  | DiagnosticsStopped Text (Maybe DiagnosticVerdict) [PhaseReports]
    -- ^ Why, the verdict the lifetime still reached, and what had been seen.
  deriving (Show)

-- | The capture configuration this session runs under: the design's defaults
-- with a 16 KiB text budget in place of 4 KiB.
--
-- The first macOS run at the default budget cut exactly one record, MoltenVK's
-- routine info report of its 145 supported extensions during
-- vkCreateInstance, and the truncation rightly made that verdict not clean.
-- The default stays as P-11 set it; the finding is VK-7's and VK-8's to settle.
-- This session is about where reports come from and that each is delivered, so
-- it gives each one the room to arrive whole, and says so in its record.
sessionConfig ∷ CaptureConfig
sessionConfig = defaultCaptureConfig {captureTextBudget = 16384}

-- | The id the submitted message carries, so its delivery can be found.
submittedMessageId ∷ Text
submittedMessageId = "hetoimasia-vulkan-proof-unsafe-submit"

-- | The validation error a zero viewport count is: the count must be positive.
provokedValidationId ∷ Text
provokedValidationId = "VUID-vkCmdSetViewport-viewportCount-arraylength"

-- | The genuine unsafe imports this session declares, by Vulkan name.
unsafeImportNames ∷ [Text]
unsafeImportNames = ["vkSubmitDebugUtilsMessageEXT", "vkCmdSetViewport"]

creationPhase, submitPhase, recordingPhase, destructionPhase ∷ Text
creationPhase = "vkCreateInstance"
submitPhase = "vkSubmitDebugUtilsMessageEXT, through an unsafe import"
recordingPhase = "vkCmdSetViewport, through an unsafe import"
destructionPhase = "vkDestroyInstance, after the explicit messenger was destroyed"

foreign import ccall unsafe "dynamic"
  unsafeSubmitDebugUtilsMessage
    ∷ FunPtr (Ptr Instance_T → Word32 → Word32 → Ptr () → IO ())
    → Ptr Instance_T
    → Word32
    → Word32
    → Ptr ()
    → IO ()

foreign import ccall unsafe "dynamic"
  unsafeCmdSetViewport
    ∷ FunPtr (Ptr CommandBuffer_T → Word32 → Word32 → Ptr Viewport → IO ())
    → Ptr CommandBuffer_T
    → Word32
    → Word32
    → Ptr Viewport
    → IO ()

validationLayer ∷ ByteString
validationLayer = "VK_LAYER_KHRONOS_validation"

-- | Stop the session at a step it could not take.
stopWith ∷ Text → IO a
stopWith reason = throwIO (userError (Text.unpack reason))

-- | Run the session. It inherits the process environment the VK-2 run
-- established — the pinned driver manifest, the one-layer path, and the
-- implicit-layer policy — because it runs after it in the same process.
runDiagnostics ∷ Journal → IO DiagnosticsOutcome
runDiagnostics journal = do
  heading journal "VK-6: C-only validation capture"
  logged ← newTVarIO []
  let logger =
        mkLogger
          LogFilter
            { filterEnabled = True
            , filterGlobalLevel = Info
            , filterComponentLevels = Map.empty
            , filterDebug = DebugAll
            , filterSource = False
            }
          (callbackSink (\entry → atomically (modifyTVar' logged (entry :))))
  phases ← newIORef []
  cursor ← newIORef (0, 0)
  outcome ←
    try @SomeException $
      withDiagnosticCapture sessionConfig logger (session journal phases cursor)
  entries ← reverse <$> readTVarIO logged
  seen ← attribute entries . reverse <$> readIORef phases
  case outcome of
    Left failure → do
      note journal ("the capture session stopped: " <> Text.pack (displayException failure))
      pure (DiagnosticsStopped (Text.pack (displayException failure)) (diagnosticVerdict failure) seen)
    Right ((device, located), verdict) → do
      executable ← Text.pack <$> (getExecutablePath >>= canonicalizePath)
      -- The image the dynamic linker names can be the path the program was
      -- started by rather than the file behind it, so both are compared as
      -- canonical paths.
      image ← traverse (fmap Text.pack . canonicalizePath . Text.unpack) located.provenanceImage
      let callback = located {provenanceImage = image}
      safeCalls ← fmap Text.pack <$> lookupEnv "VULKAN_FLAG_SAFE_FOREIGN_CALLS"
      darwinLibDirs ← fmap Text.pack <$> lookupEnv "VULKAN_FLAG_DARWIN_LIB_DIRS"
      note journal ("the lifetime delivered " <> tshow (verdictDelivered verdict) <> " records to the logger")
      pure
        ( DiagnosticsProved
            DiagnosticsFacts
              { factsPhases = seen
              , factsVerdict = verdict
              , factsLoggedEntries = length entries
              , factsDevice = device
              , factsCallback = callback
              , factsExecutable = executable
              , factsFfi = nativeFfiConfiguration
              , factsPinnedSafeForeignCalls = safeCalls
              , factsPinnedDarwinLibDirs = darwinLibDirs
              , factsUnsafeImports = unsafeImportNames
              }
        )

-- | Hand each phase the delivered records its reports became. The worker
-- delivers in admission order, so when every report was admitted the phases'
-- counts partition the delivered list.
attribute ∷ [LogEntry] → [PhaseReports] → [PhaseReports]
attribute entries phases
  | fromIntegral (length entries) /= sum (map phaseReports phases) = phases
  | otherwise = go entries phases
  where
    go _ [] = []
    go remaining (phase : rest) =
      let (mine, others) = splitAt (fromIntegral (phaseReports phase)) remaining
       in phase {phaseEntries = mine} : go others rest

-- | Read the storage's counters around one native step, and attribute the
-- difference to it. Anything that arrived since the previous step, outside any
-- measured call, is recorded as a phase of its own rather than folded into
-- this one.
measure ∷ DiagnosticCapture → IORef [PhaseReports] → IORef (Word64, Word64) → Text → IO a → IO a
measure capture phases cursor name action = do
  (seenReports, seenErrors) ← readIORef cursor
  before ← statusCounters <$> captureStatus capture
  let gap = countOffered before - seenReports
  unless (gap == 0) $
    modifyIORef' phases (PhaseReports "between steps" gap (countErrors before - seenErrors) [] :)
  result ← action
  after ← statusCounters <$> captureStatus capture
  modifyIORef'
    phases
    ( PhaseReports
        name
        (countOffered after - countOffered before)
        (countErrors after - countErrors before)
        []
        :
    )
  writeIORef cursor (countOffered after, countErrors after)
  pure result

session
  ∷ Journal
  → IORef [PhaseReports]
  → IORef (Word64, Word64)
  → DiagnosticCapture
  → IO (Text, Provenance)
session journal phases cursor capture = do
  let step ∷ Text → IO a → IO a
      step = measure capture phases cursor
  callback ← provenanceOf (castFunPtrToPtr captureMessengerCallback)
  note journal ("the messenger callback is " <> describe callback)

  (_, extensions) ← enumerateInstanceExtensionProperties Nothing
  (_, layers) ← enumerateInstanceLayerProperties
  let advertised name = name `elem` [e.extensionName | e ← Vector.toList extensions]
      portability = advertised KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME
  unless (validationLayer `elem` [l.layerName | l ← Vector.toList layers]) $
    stopWith "the pinned layer path offers no VK_LAYER_KHRONOS_validation"
  unless (advertised EXT_DEBUG_UTILS_EXTENSION_NAME) $
    stopWith "the loader does not advertise VK_EXT_debug_utils"

  let createInfo =
        InstanceCreateInfo
          { next = (captureMessengerCreateInfo capture, ())
          , flags = if portability then INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR else zero
          , applicationInfo =
              Just
                ApplicationInfo
                  { applicationName = Just "hetoimasia-vulkan-proof-vk6"
                  , applicationVersion = 0
                  , engineName = Just "hetoimasia"
                  , engineVersion = 0
                  , apiVersion = API_VERSION_1_3
                  }
          , enabledLayerNames = Vector.singleton validationLayer
          , enabledExtensionNames =
              Vector.fromList
                ([EXT_DEBUG_UTILS_EXTENSION_NAME] <> [KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME | portability])
          }
          ∷ InstanceCreateInfo '[DebugUtilsMessengerCreateInfoEXT]
  -- The instance is the outermost native scope, so vkDestroyInstance is the
  -- last thing this body does: after the explicit messenger, and before the
  -- lifetime closes admission.
  withResourceLabelled
    "the VK-6 instance"
    (step creationPhase (createInstance createInfo Nothing))
    (\vulkan → step destructionPhase (destroyInstance vulkan Nothing))
    $ \vulkan →
      withResourceLabelled
        "the VK-6 explicit messenger"
        (step "vkCreateDebugUtilsMessengerEXT" (createCaptureMessenger vulkan capture))
        (step "vkDestroyDebugUtilsMessengerEXT" . destroyCaptureMessenger vulkan)
        $ \_ → do
          heading journal "VK-6: a message submitted through an unsafe import"
          step submitPhase (submitUnsafely vulkan)
          note journal "vkSubmitDebugUtilsMessageEXT returned from its unsafe import"

          heading journal "VK-6: a validation error from an unsafe recording call"
          (_, physicals) ← step "vkEnumeratePhysicalDevices" (enumeratePhysicalDevices vulkan)
          candidates ← forM (Vector.toList physicals) $ \physical → do
            properties ← getPhysicalDeviceProperties physical
            families ← getPhysicalDeviceQueueFamilyProperties physical
            (_, deviceExtensions) ← enumerateDeviceExtensionProperties physical Nothing
            let graphics =
                  [ index
                  | (index, family) ← zip [0 ..] (Vector.toList families)
                  , family.queueFlags .&. QUEUE_GRAPHICS_BIT /= zero
                  ]
                subset = KHR_PORTABILITY_SUBSET_EXTENSION_NAME `elem` [e.extensionName | e ← Vector.toList deviceExtensions]
            pure [(physical, decode properties.deviceName, family, subset) | family ← take 1 graphics]
          (physical, deviceName, family, subset) ← case concat candidates of
            chosen : _ → pure chosen
            [] → stopWith "no physical device offers a graphics queue"
          note journal ("recording on " <> deviceName <> ", queue family " <> tshow family)
          let deviceInfo =
                DeviceCreateInfo
                  { next = ()
                  , flags = zero
                  , queueCreateInfos =
                      Vector.singleton
                        ( SomeStruct
                            ( DeviceQueueCreateInfo
                                { next = ()
                                , flags = zero
                                , queueFamilyIndex = family
                                , queuePriorities = Vector.singleton 1.0
                                }
                                ∷ DeviceQueueCreateInfo '[]
                            )
                        )
                  , enabledLayerNames = Vector.empty
                  , enabledExtensionNames = Vector.fromList [KHR_PORTABILITY_SUBSET_EXTENSION_NAME | subset]
                  , enabledFeatures = Nothing
                  }
                  ∷ DeviceCreateInfo '[]
          withResourceLabelled
            "the VK-6 device"
            (step "vkCreateDevice" (createDevice physical deviceInfo Nothing))
            (\device → step "vkDestroyDevice" (destroyDevice device Nothing))
            $ \device →
              withResourceLabelled
                "the VK-6 command pool"
                ( step
                    "vkCreateCommandPool"
                    ( createCommandPool
                        device
                        CommandPoolCreateInfo {next = (), flags = zero, queueFamilyIndex = family}
                        Nothing
                    )
                )
                (\pool → step "vkDestroyCommandPool" (destroyCommandPool device pool Nothing))
                $ \pool → do
                  buffers ←
                    step
                      "vkAllocateCommandBuffers"
                      ( allocateCommandBuffers
                          device
                          CommandBufferAllocateInfo
                            { commandPool = pool
                            , level = COMMAND_BUFFER_LEVEL_PRIMARY
                            , commandBufferCount = 1
                            }
                      )
                  commands ← maybe (stopWith "vkAllocateCommandBuffers returned no command buffer") pure (listToMaybe (Vector.toList buffers))
                  step
                    "vkBeginCommandBuffer"
                    ( beginCommandBuffer
                        commands
                        ( CommandBufferBeginInfo
                            { next = ()
                            , flags = COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
                            , inheritanceInfo = Nothing
                            }
                            ∷ CommandBufferBeginInfo '[]
                        )
                    )
                  step recordingPhase (recordUnsafely commands)
                  note journal "vkCmdSetViewport returned from its unsafe import"
                  step "vkEndCommandBuffer" (endCommandBuffer commands)
          heading journal "VK-6: teardown"
          note journal "the device and its pool are gone; the explicit messenger is destroyed next, then the instance"
          pure (deviceName, callback)
  where
    describe provenance =
      maybe "an unnamed address" id provenance.provenanceSymbol
        <> " in "
        <> maybe "no image" id provenance.provenanceImage

-- | One message, through the instance's own dispatch pointer and a genuine
-- unsafe import. It reaches the explicit messenger from inside the call.
submitUnsafely ∷ Instance → IO ()
submitUnsafely vulkan = do
  let function = castFunPtr (pVkSubmitDebugUtilsMessageEXT vulkan.instanceCmds)
      payload =
        DebugUtilsMessengerCallbackDataEXT
          { next = ()
          , flags = zero
          , messageIdName = Just (Encoding.encodeUtf8 submittedMessageId)
          , messageIdNumber = 0
          , message = Just "delivered from inside an unsafe foreign call"
          , queueLabels = Vector.empty
          , cmdBufLabels = Vector.empty
          , objects = Vector.empty
          }
          ∷ DebugUtilsMessengerCallbackDataEXT '[]
  withCStruct payload $ \pointer →
    unsafeSubmitDebugUtilsMessage
      function
      vulkan.instanceHandle
      (severityBits DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT)
      (typeBits DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT)
      (castPtr pointer)
  where
    severityBits (DebugUtilsMessageSeverityFlagBitsEXT bits) = bits
    typeBits (DebugUtilsMessageTypeFlagBitsEXT bits) = bits

-- | A zero-count viewport through the device's own dispatch pointer and a
-- genuine unsafe import: a short recording command the layer rejects.
recordUnsafely ∷ CommandBuffer → IO ()
recordUnsafely commands =
  unsafeCmdSetViewport
    (castFunPtr (pVkCmdSetViewport commands.deviceCmds))
    commands.commandBufferHandle
    0
    0
    nullPtr

decode ∷ ByteString → Text
decode = Encoding.decodeUtf8Lenient . Char8.takeWhile (/= '\0')

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
