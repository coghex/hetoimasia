{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | GRS-18's own windowless device: one instance, one physical device, one
-- device and one queue, created through the @vulkan@ binding and owned by the
-- probe's one thread.
--
-- A device is created either without any layer, for every timing, or with
-- the validation layer and the qualified validation features, for the
-- correctness passes. Validation's messenger is the C callback in
-- @cbits/vma_production.cpp@, so no unsafe foreign call can reach Haskell
-- through it (D-28 of the Vulkan backend design).
module Production.Device
  ( Device (..)
  , Validation (..)
  , MemoryTypeOffer (..)
  , withDevice
  , chooseMemoryType
  , propertyNames
  , validationMessages
  , ValidationMessages (..)
  ) where

import Control.Exception (bracket)
import Control.Monad (forM, unless, when)
import Data.Bits (popCount, testBit, (.&.), (.|.))
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import Data.List (intercalate, sortOn)
import qualified Data.Vector as Vector
import Data.Word (Word32, Word64)
import Foreign.C.String (CString, peekCString)
import Foreign.Ptr (nullPtr)
import Vulkan.CStruct.Extends (SomeStruct (..))
import Vulkan.Core10 hiding (Device, withDevice)
import qualified Vulkan.Core10 as Vk (Device)
import Vulkan.Core11 (PhysicalDeviceProperties2 (..), enumerateInstanceVersion, getPhysicalDeviceProperties2)
import Vulkan.Core12 (PhysicalDeviceDriverProperties (..))
import Vulkan.Core13 (data API_VERSION_1_3)
import Vulkan.Extensions.VK_EXT_debug_utils
  ( DebugUtilsMessengerCreateInfoEXT (..)
  , DebugUtilsMessengerEXT
  , PFN_vkDebugUtilsMessengerCallbackEXT
  , data DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT
  , data DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
  , data DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT
  , data DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT
  , data DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT
  , createDebugUtilsMessengerEXT
  , destroyDebugUtilsMessengerEXT
  )
import Vulkan.Extensions.VK_EXT_validation_features
  ( ValidationFeaturesEXT (..)
  , data VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT
  )
import Vulkan.Zero (zero)

foreign import ccall "&hetoimasia_probe_messenger"
  probeMessenger ∷ PFN_vkDebugUtilsMessengerCallbackEXT

foreign import ccall unsafe "hetoimasia_probe_message_count"
  c_messageCount ∷ Word32 → IO Word64

foreign import ccall unsafe "hetoimasia_probe_messages_kept"
  c_messagesKept ∷ IO Word64

foreign import ccall unsafe "hetoimasia_probe_message_text"
  c_messageText ∷ Word64 → IO CString

-- | Whether a device validates, and with which validation features.
data Validation
  = Unvalidated
  | Validated ![String]
    -- ^ The layer @VK_LAYER_KHRONOS_validation@ with these features, of
    -- which only @synchronization@ is known.
  deriving (Eq, Show)

-- | One memory type the device offers.
data MemoryTypeOffer = MemoryTypeOffer
  { offerIndex ∷ !Word32
  , offerFlags ∷ !Word32
  , offerHeap ∷ !Word32
  }
  deriving (Eq, Show)

-- | An open device and what the report states about it.
data Device = Device
  { deviceInstance ∷ !Instance
  , devicePhysical ∷ !PhysicalDevice
  , deviceVulkan ∷ !Vk.Device
  , deviceQueue ∷ !Queue
  , deviceQueueFamily ∷ !Word32
  , deviceValidation ∷ !Validation
  , deviceName ∷ !String
  , deviceDriverName ∷ !String
  , deviceDriverInfo ∷ !String
  , deviceDriverVersion ∷ !Word32
  , deviceApiVersion ∷ !Word32
  , deviceLoaderVersion ∷ !Word32
  , deviceVendor ∷ !(Word32, Word32)
  , deviceMemoryTypes ∷ ![MemoryTypeOffer]
  , deviceHeaps ∷ ![(Word64, Word32)]
    -- ^ Each heap's size and flags.
  , deviceBufferImageGranularity ∷ !Word64
  , deviceNonCoherentAtomSize ∷ !Word64
  , deviceMaxAllocations ∷ !Word32
  , deviceInstanceExtensions ∷ ![String]
  , deviceExtensions ∷ ![String]
  , deviceLayers ∷ ![String]
  }

validationLayer ∷ ByteString.ByteString
validationLayer = "VK_LAYER_KHRONOS_validation"

-- | Open a device for the duration of the action, and destroy it child
-- before parent afterwards.
withDevice ∷ Validation → (Device → IO a) → IO a
withDevice validation action = do
  loaderVersion ← enumerateInstanceVersion
  (_, offeredExtensions) ← enumerateInstanceExtensionProperties Nothing
  (_, offeredLayers) ← enumerateInstanceLayerProperties
  let extensionNames = [e.extensionName | e ← Vector.toList offeredExtensions]
      layerNames = [l.layerName | l ← Vector.toList offeredLayers]
      portability = "VK_KHR_portability_enumeration" `elem` extensionNames
  layerExtensions ← case validation of
    Unvalidated → pure []
    Validated _ → do
      unless (validationLayer `elem` layerNames) $
        fail "the validation layer VK_LAYER_KHRONOS_validation is not offered, so the correctness passes cannot run"
      (_, offered) ← enumerateInstanceExtensionProperties (Just validationLayer)
      pure [e.extensionName | e ← Vector.toList offered]
  let validating = validation /= Unvalidated
      features = case validation of
        Validated named → named
        Unvalidated → []
      enabledExtensions =
        ["VK_KHR_portability_enumeration" | portability]
          <> ["VK_EXT_debug_utils" | validating]
          <> ["VK_EXT_validation_features" | validating, not (null features)]
      enabledLayers = [validationLayer | validating]
  when (validating && "VK_EXT_debug_utils" `notElem` (extensionNames <> layerExtensions)) $
    fail "VK_EXT_debug_utils is not offered, so validation messages could not be counted"
  when (not (null features) && "VK_EXT_validation_features" `notElem` layerExtensions) $
    fail "the validation layer does not offer VK_EXT_validation_features"
  unless (all (== "synchronization") features) $
    fail ("unknown validation features " <> show features <> "; only synchronization is known")
  let application =
        Just
          ApplicationInfo
            { applicationName = Just "hetoimasia allocator probe"
            , applicationVersion = 0
            , engineName = Just "hetoimasia"
            , engineVersion = 0
            , apiVersion = API_VERSION_1_3
            }
      instanceFlags = if portability then INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR else zero
      messengerInfo =
        DebugUtilsMessengerCreateInfoEXT
          { flags = zero
          , messageSeverity = DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT .|. DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT
          , messageType =
              DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT
                .|. DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT
                .|. DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT
          , pfnUserCallback = probeMessenger
          , userData = nullPtr
          }
      featuresInfo =
        ValidationFeaturesEXT
          { enabledValidationFeatures = Vector.fromList [VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT | "synchronization" `elem` features]
          , disabledValidationFeatures = Vector.empty
          }
      createTheInstance
        | not validating =
            createInstance
              (InstanceCreateInfo () instanceFlags application Vector.empty (Vector.fromList enabledExtensions) ∷ InstanceCreateInfo '[])
              Nothing
        | otherwise =
            createInstance
              ( InstanceCreateInfo (messengerInfo, (featuresInfo, ())) instanceFlags application (Vector.fromList enabledLayers) (Vector.fromList enabledExtensions)
                  ∷ InstanceCreateInfo '[DebugUtilsMessengerCreateInfoEXT, ValidationFeaturesEXT]
              )
              Nothing
  bracket createTheInstance (`destroyInstance` Nothing) $ \created →
    withMessenger validating created messengerInfo $ do
      (_, physicals) ← enumeratePhysicalDevices created
      physical ← case Vector.toList physicals of
        first : _ → pure first
        [] → fail "the loader offers no physical device"
      properties ← getPhysicalDeviceProperties physical
      PhysicalDeviceProperties2 {next = (driver, ())} ←
        getPhysicalDeviceProperties2 physical ∷ IO (PhysicalDeviceProperties2 '[PhysicalDeviceDriverProperties])
      memory ← getPhysicalDeviceMemoryProperties physical
      families ← getPhysicalDeviceQueueFamilyProperties physical
      family ← case [i | (i, f) ← zip [0 ..] (Vector.toList families), f.queueFlags .&. QUEUE_GRAPHICS_BIT /= zero] of
        first : _ → pure first
        [] → fail "the device offers no graphics queue family"
      (_, deviceOffered) ← enumerateDeviceExtensionProperties physical Nothing
      let deviceExtensionNames = ["VK_KHR_portability_subset" | "VK_KHR_portability_subset" `elem` [e.extensionName | e ← Vector.toList deviceOffered]]
          queueInfo =
            DeviceQueueCreateInfo {next = (), flags = zero, queueFamilyIndex = family, queuePriorities = Vector.singleton 1.0}
              ∷ DeviceQueueCreateInfo '[]
          deviceInfo =
            DeviceCreateInfo
              { next = ()
              , flags = zero
              , queueCreateInfos = Vector.singleton (SomeStruct queueInfo)
              , enabledLayerNames = Vector.empty
              , enabledExtensionNames = Vector.fromList deviceExtensionNames
              , enabledFeatures = Nothing
              }
              ∷ DeviceCreateInfo '[]
      bracket (createDevice physical deviceInfo Nothing) (\d → deviceWaitIdle d >> destroyDevice d Nothing) $ \logical → do
        queue ← getDeviceQueue logical family 0
        let types =
              [ MemoryTypeOffer i bits t.heapIndex
              | (i, t) ← zip [0 ..] (take (fromIntegral memory.memoryTypeCount) (Vector.toList memory.memoryTypes))
              , let MemoryPropertyFlagBits bits = t.propertyFlags
              ]
            heaps = [(h.size, bits) | h ← take (fromIntegral memory.memoryHeapCount) (Vector.toList memory.memoryHeaps), let MemoryHeapFlagBits bits = h.flags]
        action
          Device
            { deviceInstance = created
            , devicePhysical = physical
            , deviceVulkan = logical
            , deviceQueue = queue
            , deviceQueueFamily = family
            , deviceValidation = validation
            , deviceName = text properties.deviceName
            , deviceDriverName = text driver.driverName
            , deviceDriverInfo = text driver.driverInfo
            , deviceDriverVersion = properties.driverVersion
            , deviceApiVersion = properties.apiVersion
            , deviceLoaderVersion = loaderVersion
            , deviceVendor = (properties.vendorID, properties.deviceID)
            , deviceMemoryTypes = types
            , deviceHeaps = heaps
            , deviceBufferImageGranularity = properties.limits.bufferImageGranularity
            , deviceNonCoherentAtomSize = properties.limits.nonCoherentAtomSize
            , deviceMaxAllocations = properties.limits.maxMemoryAllocationCount
            , deviceInstanceExtensions = map Char8.unpack enabledExtensions
            , deviceExtensions = map Char8.unpack deviceExtensionNames
            , deviceLayers = map Char8.unpack enabledLayers
            }
  where
    text = Char8.unpack . ByteString.takeWhile (/= 0)

withMessenger ∷ Bool → Instance → DebugUtilsMessengerCreateInfoEXT → IO a → IO a
withMessenger False _ _ action = action
withMessenger True created info action =
  bracket
    (createDebugUtilsMessengerEXT created info Nothing ∷ IO DebugUtilsMessengerEXT)
    (\messenger → destroyDebugUtilsMessengerEXT created messenger Nothing)
    (const action)

-- | The engine's memory-type choice (D-38, D-16): among the types the
-- resource's @memoryTypeBits@ allows that carry every required flag, the one
-- with the most preferred flags, then the fewest avoided flags, then the
-- lowest index. No candidate is a refusal, never a fallback.
chooseMemoryType ∷ [MemoryTypeOffer] → Word32 → Word32 → Word32 → Word32 → Either String MemoryTypeOffer
chooseMemoryType offers typeBits required preferred avoided =
  case sortOn rank candidates of
    best : _ → Right best
    [] →
      Left
        ( "no memory type in bits " <> show typeBits <> " carries " <> intercalate "|" (propertyNames required)
        )
  where
    candidates = [o | o ← offers, testBit typeBits (fromIntegral (offerIndex o)), offerFlags o .&. required == required]
    rank o = (negate (popCount (offerFlags o .&. preferred)), popCount (offerFlags o .&. avoided), offerIndex o)

-- | Memory property flags by name.
propertyNames ∷ Word32 → [String]
propertyNames bits =
  [ name
  | (bit, name) ←
      [ (0, "DEVICE_LOCAL")
      , (1, "HOST_VISIBLE")
      , (2, "HOST_COHERENT")
      , (3, "HOST_CACHED")
      , (4, "LAZILY_ALLOCATED")
      , (5, "PROTECTED")
      ]
  , testBit bits bit
  ]

-- | What the C messenger has received so far.
data ValidationMessages = ValidationMessages
  { messageErrors ∷ !Word64
  , messageWarnings ∷ !Word64
  , messageOther ∷ !Word64
  , messageTexts ∷ ![String]
  }

validationMessages ∷ IO ValidationMessages
validationMessages = do
  errors ← c_messageCount 0
  warnings ← c_messageCount 1
  other ← c_messageCount 2
  kept ← c_messagesKept
  texts ← forM (takeWhile (< kept) [0 ..]) $ \i → c_messageText i >>= peekCString
  pure (ValidationMessages errors warnings other texts)
