-- | The profile's pure decisions: what the instance asks for, and which device
-- the session takes.
module Test.GPU.Vulkan.Native.Profile (spec) where

import qualified Data.ByteString as ByteString
import qualified Data.Text as Text
import Hetoimasia.GPU.Vulkan.Native.Naming
  ( NativeObjectKind (..)
  , boundedName
  , deviceName
  , maximumNameBytes
  , objectTypeCode
  , queueName
  )
import Hetoimasia.GPU.Vulkan.Native.Profile
import Test.GPU.Vulkan.Native.StandIn (standInDevice)
import Vulkan.Core10.Enums.ObjectType (ObjectType (..))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Vulkan.Extensions.VK_EXT_debug_utils (data EXT_DEBUG_UTILS_EXTENSION_NAME)
import Vulkan.Extensions.VK_EXT_surface_maintenance1 (data EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME)
import Vulkan.Extensions.VK_EXT_validation_features (data EXT_VALIDATION_FEATURES_EXTENSION_NAME)
import Vulkan.Extensions.VK_EXT_swapchain_maintenance1 (data EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME)
import Vulkan.Extensions.VK_KHR_get_surface_capabilities2 (data KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME)
import Vulkan.Extensions.VK_KHR_portability_enumeration (data KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)
import Vulkan.Extensions.VK_KHR_portability_subset (data KHR_PORTABILITY_SUBSET_EXTENSION_NAME)
import Vulkan.Extensions.VK_KHR_swapchain (data KHR_SWAPCHAIN_EXTENSION_NAME)

spec ∷ Spec
spec = describe "Profile" $ do
  describe "names" $ do
    it "spells every named object's type as the binding does" $
      [(kind, objectTypeCode kind) | kind ← [minBound .. maxBound]]
        `shouldBe` [ (kind, code)
                   | (kind, ObjectType code) ←
                       [ (ObjectDevice, OBJECT_TYPE_DEVICE)
                       , (ObjectQueue, OBJECT_TYPE_QUEUE)
                       , (ObjectSurface, OBJECT_TYPE_SURFACE_KHR)
                       , (ObjectSwapchain, OBJECT_TYPE_SWAPCHAIN_KHR)
                       , (ObjectImage, OBJECT_TYPE_IMAGE)
                       , (ObjectImageView, OBJECT_TYPE_IMAGE_VIEW)
                       , (ObjectCommandPool, OBJECT_TYPE_COMMAND_POOL)
                       , (ObjectCommandBuffer, OBJECT_TYPE_COMMAND_BUFFER)
                       , (ObjectPipelineLayout, OBJECT_TYPE_PIPELINE_LAYOUT)
                       , (ObjectPipeline, OBJECT_TYPE_PIPELINE)
                       , (ObjectShaderModule, OBJECT_TYPE_SHADER_MODULE)
                       , (ObjectBuffer, OBJECT_TYPE_BUFFER)
                       , (ObjectDeviceMemory, OBJECT_TYPE_DEVICE_MEMORY)
                       ]
                   ]

    it "bounds every name at 64 bytes, and never lets a NUL end one early" $ do
      maximumNameBytes `shouldBe` 64
      ByteString.length (boundedName (Text.replicate 200 "x")) `shouldBe` 64
      boundedName "a\NULb" `shouldBe` "ab"
      -- The largest queue identity the device can report still fits.
      ByteString.length (queueName maxBound maxBound) `shouldSatisfy` (<= maximumNameBytes)
      [deviceName, queueName 0 0] `shouldBe` ["hetoimasia device", "hetoimasia queue family 0 index 0"]

  describe "the instance" $ do
    it "asks for the surface extensions, the capture's and the maintenance chain's, and nothing the loader lacks" $ do
      plan ← rightOf (planInstance request (offer ["VK_KHR_surface", "VK_KHR_xcb_surface", debugUtilsExtension, getSurfaceCapabilities2Extension, surfaceMaintenance1Extension]))
      planInstanceExtensions plan
        `shouldBe` ["VK_KHR_surface", "VK_KHR_xcb_surface", debugUtilsExtension, getSurfaceCapabilities2Extension, surfaceMaintenance1Extension]
      planPortabilityEnumeration plan `shouldBe` False
      apiMajorMinor (planApiVersion plan) `shouldBe` (1, 3)

    it "enables portability enumeration exactly where the loader advertises it" $ do
      plan ← rightOf (planInstance request (offer (portabilityEnumerationExtension : everything)))
      planPortabilityEnumeration plan `shouldBe` True
      planInstanceExtensions plan `shouldSatisfy` elem portabilityEnumerationExtension

    it "refuses a loader below Vulkan 1.3" $
      planInstance request (offer everything) {offerLoaderVersion = packApiVersion 1 2 198}
        `shouldBe` Left (LoaderVersionTooOld (packApiVersion 1 2 198))

    it "names every instance extension the loader lacks, not just the first" $
      planInstance request (offer ["VK_KHR_surface", "VK_KHR_xcb_surface", debugUtilsExtension])
        `shouldBe` Left (InstanceExtensionsUnavailable [getSurfaceCapabilities2Extension, surfaceMaintenance1Extension])

    it "refuses a layer the loader does not offer" $
      planInstance request {requestLayers = ["VK_LAYER_KHRONOS_validation"]} (offer everything)
        `shouldBe` Left (InstanceLayersUnavailable ["VK_LAYER_KHRONOS_validation"])

    it "enables synchronization validation through an enabled layer that offers it" $ do
      plan ← rightOf (planInstance validating (offer everything) {offerLayers = [validation], offerLayerExtensions = [(validation, ["VK_EXT_debug_utils", validationFeaturesExtension])]})
      planValidationFeatures plan `shouldBe` [SynchronizationValidation]
      planLayers plan `shouldBe` [validation]
      planInstanceExtensions plan `shouldSatisfy` elem validationFeaturesExtension

    it "refuses validation features no enabled layer offers, rather than validating without them" $ do
      -- The loader's own listing never carries a layer's extension, and a
      -- layer that is offered but not enabled contributes nothing.
      planInstance validating (offer (validationFeaturesExtension : everything)) {offerLayers = [validation, "VK_LAYER_other"], offerLayerExtensions = [(validation, ["VK_EXT_debug_utils"]), ("VK_LAYER_other", [validationFeaturesExtension])]}
        `shouldBe` Left (ValidationFeaturesUnavailable [validation])
      planInstance validating {requestLayers = []} (offer everything) {offerLayerExtensions = [(validation, [validationFeaturesExtension])]}
        `shouldBe` Left (ValidationFeaturesUnavailable [])

    it "asks for the validation features extension only when a feature is requested" $ do
      plan ← rightOf (planInstance request {requestLayers = [validation]} (offer everything) {offerLayers = [validation], offerLayerExtensions = [(validation, [validationFeaturesExtension])]})
      planValidationFeatures plan `shouldBe` []
      planInstanceExtensions plan `shouldSatisfy` notElem validationFeaturesExtension

  describe "the device" $ do
    it "takes the first device satisfying the whole profile, with one family for graphics and presentation" $ do
      let other = standInDevice {offerDevice = "second", offerDeviceName = "second"}
      plan ← rightOf (selectDevice [standInDevice, other])
      planDevice plan `shouldBe` "stand-in device"
      planQueueFamily plan `shouldBe` 0
      planDeviceExtensions plan `shouldBe` [swapchainExtension, swapchainMaintenance1Extension]
      planPortabilitySubset plan `shouldBe` False

    it "enables the portability subset exactly where the device advertises it" $ do
      let portable = standInDevice {offerDeviceExtensions = portabilitySubsetExtension : offerDeviceExtensions standInDevice}
      plan ← rightOf (selectDevice [portable])
      planPortabilitySubset plan `shouldBe` True
      planDeviceExtensions plan `shouldSatisfy` elem portabilitySubsetExtension

    it "skips a device that lacks the profile for a later one that has it" $ do
      let old = standInDevice {offerDevice = "old", offerDeviceName = "old", offerDeviceApiVersion = packApiVersion 1 2 0}
      plan ← rightOf (selectDevice [old, standInDevice])
      planDevice plan `shouldBe` "stand-in device"

    it "requires one family that answers both graphics and presentation, not two that answer one each" $ do
      let split = standInDevice {offerQueueFamilies = [QueueFamilyOffer 0 True False, QueueFamilyOffer 1 False True]}
      selectDevice [split] `shouldBe'` Left (NoCompatibleDevice [("stand-in device", [DeviceNoPresentingGraphicsFamily])])

    it "names everything each candidate lacks when none will do" $ do
      let poor =
            standInDevice
              { offerDeviceApiVersion = packApiVersion 1 1 0
              , offerDeviceExtensions = []
              , offerDynamicRendering = False
              , offerSynchronization2 = False
              , offerSwapchainMaintenance1 = False
              , offerQueueFamilies = []
              }
      selectDevice [poor]
        `shouldBe'` Left
          ( NoCompatibleDevice
              [
                ( "stand-in device"
                ,
                  [ DeviceApiTooOld (packApiVersion 1 1 0)
                  , DeviceExtensionMissing swapchainExtension
                  , DeviceExtensionMissing swapchainMaintenance1Extension
                  , DeviceFeatureMissing "dynamicRendering"
                  , DeviceFeatureMissing "synchronization2"
                  , DeviceFeatureMissing "swapchainMaintenance1"
                  , DeviceNoPresentingGraphicsFamily
                  ]
                )
              ]
          )

    it "fails structurally when no device was enumerated at all" $
      selectDevice ([] ∷ [DeviceOffer ()]) `shouldBe'` Left (NoCompatibleDevice [])

  it "spells every extension exactly as the binding does" $
    [ debugUtilsExtension
    , portabilityEnumerationExtension
    , getSurfaceCapabilities2Extension
    , surfaceMaintenance1Extension
    , swapchainExtension
    , swapchainMaintenance1Extension
    , portabilitySubsetExtension
    , validationFeaturesExtension
    ]
      `shouldBe` [ EXT_DEBUG_UTILS_EXTENSION_NAME
                 , KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME
                 , KHR_GET_SURFACE_CAPABILITIES_2_EXTENSION_NAME
                 , EXT_SURFACE_MAINTENANCE_1_EXTENSION_NAME
                 , KHR_SWAPCHAIN_EXTENSION_NAME
                 , EXT_SWAPCHAIN_MAINTENANCE_1_EXTENSION_NAME
                 , KHR_PORTABILITY_SUBSET_EXTENSION_NAME
                 , EXT_VALIDATION_FEATURES_EXTENSION_NAME
                 ]
  where
    request = InstanceRequest ["VK_KHR_surface", "VK_KHR_xcb_surface"] [] []
    validation = "VK_LAYER_KHRONOS_validation"
    validating = request {requestLayers = [validation], requestValidationFeatures = [SynchronizationValidation]}
    everything = ["VK_KHR_surface", "VK_KHR_xcb_surface", debugUtilsExtension, getSurfaceCapabilities2Extension, surfaceMaintenance1Extension]
    offer extensions = InstanceOffer (packApiVersion 1 3 275) extensions [] []

-- | The value of a decision expected to succeed.
rightOf ∷ Show e ⇒ Either e a → IO a
rightOf = either (\refused → fail ("expected a plan, but: " <> show refused)) pure

-- | Compare selections by their plan's observable parts, since a plan carries
-- the native layer's device handle.
shouldBe' ∷ Either NoCompatibleDevice (DevicePlan device) → Either NoCompatibleDevice () → IO ()
shouldBe' actual expected = fmap (const ()) actual `shouldBe` expected
