{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | The production native layer under "Hetoimasia.GPU.Vulkan.Native.Roots":
-- the Vulkan binding's own calls, with the diagnostic capture's messengers.
--
-- Every function here is one native call or one read of what the loader or a
-- device offers; every decision about what to ask for and which device to take
-- is "Hetoimasia.GPU.Vulkan.Native.Profile"'s, and every decision about what
-- may be destroyed and when is the roots'. The binding's own imports are
-- @safe@ (`cabal.project.vulkan` constrains the flag), so any of these calls
-- may block or re-enter; none installs a Haskell callback, and both messengers
-- register the C capture callback of "Hetoimasia.GPU.Vulkan.Native.Diagnostics".
module Hetoimasia.GPU.Vulkan.Native.Roots.Vulkan
  ( VulkanRootOps
  , vulkanRootOps
  , instancePointer
  , isDeviceLoss
  ) where

import Control.Exception (SomeException, fromException)
import Control.Monad (forM)
import Data.Bits ((.&.))
import qualified Data.ByteString as ByteString
import qualified Data.Text.Encoding as Encoding
import qualified Data.Vector as Vector
import Data.Word (Word64)
import Foreign.Ptr (Ptr, castPtr)
import Vulkan.CStruct.Extends (SomeStruct (..))
import Vulkan.Core10
import Vulkan.Core11 (PhysicalDeviceFeatures2 (..), enumerateInstanceVersion, getPhysicalDeviceFeatures2)
import Vulkan.Core13 (PhysicalDeviceVulkan13Features (..))
import Vulkan.Exception (VulkanException (..))
import Vulkan.Extensions.VK_EXT_debug_utils (DebugUtilsMessengerCreateInfoEXT, DebugUtilsMessengerEXT)
import Vulkan.Extensions.VK_EXT_swapchain_maintenance1 (PhysicalDeviceSwapchainMaintenance1FeaturesKHR (..))
import Vulkan.Extensions.VK_KHR_surface (SurfaceKHR (..), getPhysicalDeviceSurfaceSupportKHR)
import Vulkan.Zero (zero)

import Hetoimasia.GPU.Vulkan.Diagnostics (DiagnosticCapture, Quiesced)
import Hetoimasia.GPU.Vulkan.Native.Diagnostics
  ( captureMessengerCreateInfo
  , createCaptureMessenger
  , destroyCaptureMessenger
  , destroyInstanceQuiesced
  )
import Hetoimasia.GPU.Vulkan.Native.Profile
  ( DeviceOffer (..)
  , DevicePlan (..)
  , InstanceOffer (..)
  , InstancePlan (..)
  , QueueFamilyOffer (..)
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (RootOps (..))

-- | The production layer's handle types.
type VulkanRootOps = RootOps Quiesced Instance DebugUtilsMessengerEXT PhysicalDevice Device

-- | The native layer over the binding, reporting into this capture.
--
-- The capture must outlive every call made through it: the lifetime that
-- supplies it must enclose the instance from its creation — whose create info
-- chains the capture's messenger — through its destruction, whose return is
-- the 'Quiesced' evidence the lifetime demands.
vulkanRootOps ∷ DiagnosticCapture → VulkanRootOps
vulkanRootOps capture =
  RootOps
    { opsInstanceOffer = do
        version ← enumerateInstanceVersion
        (_, extensions) ← enumerateInstanceExtensionProperties Nothing
        (_, layers) ← enumerateInstanceLayerProperties
        pure
          InstanceOffer
            { offerLoaderVersion = version
            , offerInstanceExtensions = [extension.extensionName | extension ← Vector.toList extensions]
            , offerLayers = [layer.layerName | layer ← Vector.toList layers]
            }
    , opsCreateInstance = \plan →
        createInstance
          ( InstanceCreateInfo
              { next = (captureMessengerCreateInfo capture, ())
              , flags = if plan.planPortabilityEnumeration then INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR else zero
              , applicationInfo =
                  Just
                    ApplicationInfo
                      { applicationName = Just "hetoimasia"
                      , applicationVersion = 0
                      , engineName = Just "hetoimasia"
                      , engineVersion = 0
                      , apiVersion = plan.planApiVersion
                      }
              , enabledLayerNames = Vector.fromList plan.planLayers
              , enabledExtensionNames = Vector.fromList plan.planInstanceExtensions
              }
              ∷ InstanceCreateInfo '[DebugUtilsMessengerCreateInfoEXT]
          )
          Nothing
    , opsCreateMessenger = \created → createCaptureMessenger created capture
    , opsDestroyMessenger = destroyCaptureMessenger
    , opsDestroyInstance = destroyInstanceQuiesced capture
    , opsDeviceOffers = deviceOffers
    , opsCreateDevice = \_ plan → createDevice plan.planDevice (deviceCreateInfo plan) Nothing
    , opsDestroyDevice = \device → destroyDevice device Nothing
    , opsSurfaceSupport = \_ physical family surface →
        getPhysicalDeviceSurfaceSupportKHR physical family (SurfaceKHR surface)
    , opsDeviceLoss = isDeviceLoss
    }

-- | Every physical device, with what the profile asks of it.
deviceOffers ∷ Instance → Word64 → IO [DeviceOffer PhysicalDevice]
deviceOffers created surface = do
  (_, devices) ← enumeratePhysicalDevices created
  forM (Vector.toList devices) $ \physical → do
    properties ← getPhysicalDeviceProperties physical
    features ∷ PhysicalDeviceFeatures2 '[PhysicalDeviceVulkan13Features, PhysicalDeviceSwapchainMaintenance1FeaturesKHR] ←
      getPhysicalDeviceFeatures2 physical
    (_, extensions) ← enumerateDeviceExtensionProperties physical Nothing
    families ← getPhysicalDeviceQueueFamilyProperties physical
    offered ← forM (zip [0 ..] (Vector.toList families)) $ \(index, family) → do
      presents ← getPhysicalDeviceSurfaceSupportKHR physical index (SurfaceKHR surface)
      pure
        QueueFamilyOffer
          { familyIndex = index
          , familyGraphics = family.queueFlags .&. QUEUE_GRAPHICS_BIT /= zero
          , familyPresents = presents
          }
    let (thirteen, (maintenance, ())) = features.next
    pure
      DeviceOffer
        { offerDevice = physical
        , offerDeviceName = Encoding.decodeUtf8Lenient (ByteString.takeWhile (/= 0) properties.deviceName)
        , offerDeviceApiVersion = properties.apiVersion
        , offerDeviceExtensions = [extension.extensionName | extension ← Vector.toList extensions]
        , offerDynamicRendering = thirteen.dynamicRendering
        , offerSynchronization2 = thirteen.synchronization2
        , offerSwapchainMaintenance1 = maintenance.swapchainMaintenance1
        , offerQueueFamilies = offered
        }

-- | One queue from the chosen family, the profile's features, and its
-- extensions.
deviceCreateInfo
  ∷ DevicePlan PhysicalDevice
  → DeviceCreateInfo '[PhysicalDeviceVulkan13Features, PhysicalDeviceSwapchainMaintenance1FeaturesKHR]
deviceCreateInfo plan =
  DeviceCreateInfo
    { next =
        ( (zero ∷ PhysicalDeviceVulkan13Features) {dynamicRendering = True, synchronization2 = True}
        , (PhysicalDeviceSwapchainMaintenance1FeaturesKHR {swapchainMaintenance1 = True}, ())
        )
    , flags = zero
    , queueCreateInfos =
        Vector.singleton
          ( SomeStruct
              ( DeviceQueueCreateInfo
                  { next = ()
                  , flags = zero
                  , queueFamilyIndex = plan.planQueueFamily
                  , queuePriorities = Vector.singleton 1.0
                  }
                  ∷ DeviceQueueCreateInfo '[]
              )
          )
    , enabledLayerNames = Vector.empty
    , enabledExtensionNames = Vector.fromList plan.planDeviceExtensions
    , enabledFeatures = Nothing
    }

-- | The instance's dispatchable handle, untyped, as the surface bridge leases
-- it.
instancePointer ∷ Instance → Ptr ()
instancePointer = castPtr . instanceHandle

-- | Whether the binding raised @VK_ERROR_DEVICE_LOST@. Nothing else is device
-- loss: a timeout, or any other result, is not promoted to it.
isDeviceLoss ∷ SomeException → Bool
isDeviceLoss exception = case fromException exception of
  Just (VulkanException result) → result == ERROR_DEVICE_LOST
  Nothing → False
