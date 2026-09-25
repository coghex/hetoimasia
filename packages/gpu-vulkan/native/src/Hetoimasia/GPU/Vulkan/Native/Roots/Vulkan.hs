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
--
-- The device's naming call is @vkSetDebugUtilsObjectNameEXT@ from the device's
-- own dispatch table, offered only when that table resolved it and both
-- command-buffer label calls: a device whose instance did not enable
-- @VK_EXT_debug_utils@ resolves none of them, and is left unnamed.
--
-- A plan that asks for validation features chains a @VkValidationFeaturesEXT@
-- into the instance's own create info, beside the capture's messenger. That is
-- the only way this layer turns synchronization validation on: not an
-- environment variable and not a settings file, either of which a machine
-- could supply, override or omit without the instance ever saying so.
module Hetoimasia.GPU.Vulkan.Native.Roots.Vulkan
  ( VulkanRootOps
  , vulkanRootOps
  , validationFeaturesInfo
  , instancePointer
  , isDeviceLoss
  , vulkanInstrumentation
  ) where

import Control.Exception (SomeException, fromException)
import Control.Monad (forM)
import Data.Bits ((.&.))
import qualified Data.ByteString as ByteString
import qualified Data.Text.Encoding as Encoding
import qualified Data.Vector as Vector
import Data.Word (Word64)
import Foreign.Ptr (FunPtr, Ptr, castFunPtr, castPtr, nullFunPtr, ptrToWordPtr)
import Vulkan.CStruct.Extends (Chain, SomeStruct (..))
import Vulkan.Core10
import Vulkan.Core11 (PhysicalDeviceFeatures2 (..), enumerateInstanceVersion, getPhysicalDeviceFeatures2)
import Vulkan.Core13 (PhysicalDeviceVulkan13Features (..))
import Vulkan.Exception (VulkanException (..))
import Vulkan.Dynamic (DeviceCmds (..))
import Vulkan.Extensions.VK_EXT_debug_utils (DebugUtilsMessengerEXT (..), DebugUtilsObjectNameInfoEXT (..), setDebugUtilsObjectNameEXT)
import Vulkan.Extensions.VK_EXT_validation_features
  ( ValidationFeaturesEXT (..)
  , data VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT
  )
import Vulkan.Extensions.VK_EXT_swapchain_maintenance1 (PhysicalDeviceSwapchainMaintenance1FeaturesKHR (..))
import Vulkan.Extensions.VK_KHR_surface
  ( ColorSpaceKHR (..)
  , CompositeAlphaFlagBitsKHR (..)
  , PresentModeKHR (..)
  , SurfaceCapabilitiesKHR (..)
  , SurfaceFormatKHR (..)
  , SurfaceKHR (..)
  , SurfaceTransformFlagBitsKHR (..)
  , getPhysicalDeviceSurfaceCapabilitiesKHR
  , getPhysicalDeviceSurfaceFormatsKHR
  , getPhysicalDeviceSurfacePresentModesKHR
  , getPhysicalDeviceSurfaceSupportKHR
  )
import Vulkan.Extensions.VK_KHR_swapchain
  ( SwapchainCreateInfoKHR (..)
  , SwapchainKHR (..)
  , createSwapchainKHR
  , destroySwapchainKHR
  , getSwapchainImagesKHR
  )
import Vulkan.Zero (zero)

import Hetoimasia.GPU.Vulkan.Diagnostics (DiagnosticCapture, Quiesced)
import Hetoimasia.GPU.Vulkan.Native.Diagnostics
  ( captureMessengerCreateInfo
  , createCaptureMessenger
  , destroyCaptureMessenger
  , destroyInstanceQuiesced
  )
import Hetoimasia.GPU.Vulkan.Native.Naming (Instrumentation (..), objectTypeCode)
import Hetoimasia.GPU.Vulkan.Native.Profile
  ( DeviceOffer (..)
  , DevicePlan (..)
  , InstanceOffer (..)
  , InstancePlan (..)
  , QueueFamilyOffer (..)
  , ValidationFeature (..)
  )
import Hetoimasia.GPU.Vulkan.Native.Presentation
  ( GenerationPlan (..)
  , SurfaceCapabilities (..)
  , SurfaceExtent (..)
  , SurfaceFormat (..)
  , SurfaceOffer (..)
  , undefinedExtentDimension
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (GenerationOps (..), RootOps (..), SwapchainRequest (..))

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
        let names = [layer.layerName | layer ← Vector.toList layers]
        -- A layer's own extensions are listed by naming the layer; the
        -- loader's listing above does not include them.
        layerExtensions ← forM names $ \name → do
          (_, offered) ← enumerateInstanceExtensionProperties (Just name)
          pure (name, [extension.extensionName | extension ← Vector.toList offered])
        pure
          InstanceOffer
            { offerLoaderVersion = version
            , offerInstanceExtensions = [extension.extensionName | extension ← Vector.toList extensions]
            , offerLayers = names
            , offerLayerExtensions = layerExtensions
            }
    , opsCreateInstance = \plan →
        let messenger = captureMessengerCreateInfo capture
         in if null plan.planValidationFeatures
              then createInstance (instanceCreateInfo plan (messenger, ())) Nothing
              else createInstance (instanceCreateInfo plan (messenger, (validationFeaturesInfo plan.planValidationFeatures, ()))) Nothing
    , opsCreateMessenger = \created → createCaptureMessenger created capture
    , opsDestroyMessenger = destroyCaptureMessenger
    , opsDestroyInstance = destroyInstanceQuiesced capture
    , opsDeviceOffers = deviceOffers
    , opsCreateDevice = \_ plan → createDevice plan.planDevice (deviceCreateInfo plan) Nothing
    , opsDestroyDevice = \device → destroyDevice device Nothing
    , opsSurfaceSupport = \_ physical family surface →
        getPhysicalDeviceSurfaceSupportKHR physical family (SurfaceKHR surface)
    , opsDeviceLoss = isDeviceLoss
    , opsMessengerHandle = \(DebugUtilsMessengerEXT handle) → handle
    , opsDeviceHandle = dispatchable . deviceHandle
    , opsDeviceQueue = \device family → dispatchable . queueHandle <$> getDeviceQueue device family 0
    , opsInstrumentation = pure . vulkanInstrumentation
    , opsGenerations = vulkanGenerationOps
    }

-- | A dispatchable handle's pointer, as the 64-bit value the naming call
-- takes for it.
dispatchable ∷ Ptr a → Word64
dispatchable = fromIntegral . ptrToWordPtr

-- | The device's naming call, when its dispatch table resolved it and both
-- command-buffer label calls.
vulkanInstrumentation ∷ Device → Maybe Instrumentation
vulkanInstrumentation device
  | any (== nullFunPtr) resolved = Nothing
  | otherwise =
      Just $
        Instrumentation $ \kind handle name →
          setDebugUtilsObjectNameEXT
            device
            DebugUtilsObjectNameInfoEXT {objectType = ObjectType (objectTypeCode kind), objectHandle = handle, objectName = Just name}
  where
    Device {deviceCmds = commands} = device
    resolved ∷ [FunPtr ()]
    resolved =
      [ castFunPtr (pVkSetDebugUtilsObjectNameEXT commands)
      , castFunPtr (pVkCmdBeginDebugUtilsLabelEXT commands)
      , castFunPtr (pVkCmdEndDebugUtilsLabelEXT commands)
      ]

-- | The generation calls over the binding. Every decision about what to create
-- is "Hetoimasia.GPU.Vulkan.Native.Presentation"'s plan, and every decision
-- about what to destroy and when is "Hetoimasia.GPU.Vulkan.Native.Generations"'.
vulkanGenerationOps ∷ GenerationOps PhysicalDevice Device
vulkanGenerationOps =
  GenerationOps
    { opsSurfaceOffer = surfaceOffer
    , opsCreateSwapchain = \device request →
        let plan = request.requestPlan
            SwapchainKHR old = maybe NULL_HANDLE SwapchainKHR request.requestOldSwapchain
         in (\(SwapchainKHR created) → created)
              <$> createSwapchainKHR
                device
                ( SwapchainCreateInfoKHR
                    { next = ()
                    , flags = zero
                    , surface = SurfaceKHR request.requestSurface
                    , minImageCount = plan.planMinImages
                    , imageFormat = Format (fromIntegral plan.planFormat.surfaceFormat)
                    , imageColorSpace = ColorSpaceKHR (fromIntegral plan.planFormat.surfaceColorSpace)
                    , imageExtent = Extent2D plan.planExtent.extentWidth plan.planExtent.extentHeight
                    , imageArrayLayers = 1
                    , imageUsage = ImageUsageFlagBits plan.planUsage
                    , imageSharingMode = SHARING_MODE_EXCLUSIVE
                    , queueFamilyIndices = Vector.singleton request.requestQueueFamily
                    , preTransform = SurfaceTransformFlagBitsKHR plan.planTransform
                    , compositeAlpha = CompositeAlphaFlagBitsKHR plan.planCompositeAlpha
                    , presentMode = PresentModeKHR (fromIntegral plan.planPresentMode)
                    , clipped = True
                    , oldSwapchain = SwapchainKHR old
                    }
                    ∷ SwapchainCreateInfoKHR '[]
                )
                Nothing
    , opsSwapchainImages = \device swapchain → do
        (_, images) ← getSwapchainImagesKHR device (SwapchainKHR swapchain)
        pure [handle | Image handle ← Vector.toList images]
    , opsCreateImageView = \device image format →
        (\(ImageView created) → created)
          <$> createImageView
            device
            ( ImageViewCreateInfo
                { next = ()
                , flags = zero
                , image = Image image
                , viewType = IMAGE_VIEW_TYPE_2D
                , format = Format (fromIntegral format)
                , components = ComponentMapping COMPONENT_SWIZZLE_IDENTITY COMPONENT_SWIZZLE_IDENTITY COMPONENT_SWIZZLE_IDENTITY COMPONENT_SWIZZLE_IDENTITY
                , subresourceRange = ImageSubresourceRange IMAGE_ASPECT_COLOR_BIT 0 1 0 1
                }
                ∷ ImageViewCreateInfo '[]
            )
            Nothing
    , opsDestroyImageView = \device view → destroyImageView device (ImageView view) Nothing
    , opsDestroySwapchain = \device swapchain → destroySwapchainKHR device (SwapchainKHR swapchain) Nothing
    }

-- | What the surface reports for the session's physical device.
surfaceOffer ∷ PhysicalDevice → Word64 → IO SurfaceOffer
surfaceOffer physical handle = do
  let surface = SurfaceKHR handle
  capabilities ← getPhysicalDeviceSurfaceCapabilitiesKHR physical surface
  (_, formats) ← getPhysicalDeviceSurfaceFormatsKHR physical surface
  (_, modes) ← getPhysicalDeviceSurfacePresentModesKHR physical surface
  let extent (Extent2D width height) = SurfaceExtent width height
      current = capabilities.currentExtent
      ImageUsageFlagBits usage = capabilities.supportedUsageFlags
      SurfaceTransformFlagBitsKHR transform = capabilities.currentTransform
      CompositeAlphaFlagBitsKHR alpha = capabilities.supportedCompositeAlpha
  pure
    SurfaceOffer
      { offerCapabilities =
          SurfaceCapabilities
            { capabilityMinImages = capabilities.minImageCount
            , capabilityMaxImages = capabilities.maxImageCount
            , capabilityCurrentExtent =
                if current.width == undefinedExtentDimension && current.height == undefinedExtentDimension
                  then Nothing
                  else Just (extent current)
            , capabilityMinExtent = extent capabilities.minImageExtent
            , capabilityMaxExtent = extent capabilities.maxImageExtent
            , capabilityUsage = usage
            , capabilityCurrentTransform = transform
            , capabilityCompositeAlpha = alpha
            }
      , offerFormats =
          [ SurfaceFormat (fromIntegral code) (fromIntegral space)
          | SurfaceFormatKHR {format = Format code, colorSpace = ColorSpaceKHR space} ← Vector.toList formats
          ]
      , offerPresentModes = [fromIntegral mode | PresentModeKHR mode ← Vector.toList modes]
      }

-- | The instance's create info over whichever chain the plan needs.
instanceCreateInfo ∷ InstancePlan → Chain es → InstanceCreateInfo es
instanceCreateInfo plan chain =
  InstanceCreateInfo
    { next = chain
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

-- | The create-info structure that enables these validation features, and
-- disables nothing. Every validation-enabled instance chains it the same way,
-- the proof's own instances included, so what is validated is decided in one
-- place.
validationFeaturesInfo ∷ [ValidationFeature] → ValidationFeaturesEXT
validationFeaturesInfo features =
  ValidationFeaturesEXT
    { enabledValidationFeatures = Vector.fromList (map enable features)
    , disabledValidationFeatures = Vector.empty
    }
  where
    enable SynchronizationValidation = VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT

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
