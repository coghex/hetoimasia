-- | The runtime profile the Vulkan roots require, as pure decisions.
--
-- Nothing here makes a native call or names a binding type. The native layer
-- ("Hetoimasia.GPU.Vulkan.Native.Roots.Vulkan") reads what the loader and each
-- physical device offer, and these functions decide what to ask for and which
-- device to take, so the same decisions run against stand-ins in the headless
-- examples and against the loader in a native run.
--
-- The profile is the one the VK-2 proof settled
-- (@docs/vulkan_compatibility_record.md@) and D-12 accepted:
--
-- * Vulkan 1.3, with the @dynamicRendering@ and @synchronization2@ features;
-- * @VK_EXT_swapchain_maintenance1@ and its @swapchainMaintenance1@ feature,
--   with its dependencies — @VK_KHR_swapchain@ on the device, and
--   @VK_EXT_surface_maintenance1@ and @VK_KHR_get_surface_capabilities2@ on
--   the instance. The KHR spelling of the maintenance extension is an alias
--   neither selected driver resolves, so it is never asked for;
-- * @VK_KHR_portability_enumeration@ on the instance wherever the loader
--   advertises it, and @VK_KHR_portability_subset@ on the device wherever that
--   device advertises it — two separate decisions, because Linux's loader
--   advertises the first and Lavapipe does not advertise the second;
-- * @VK_EXT_debug_utils@, which the diagnostic capture's messengers need;
-- * @VK_EXT_validation_features@, from an enabled layer, exactly when the
--   caller asks for a 'ValidationFeature' — synchronization validation, which
--   the Khronos layer leaves off unless the instance's own create info turns
--   it on; and
-- * one queue family that answers both graphics and presentation to the
--   bootstrap surface.
--
-- A later surface is admitted only if that same queue family presents to it
-- ('TargetRejection'); no second device and no second queue is ever chosen
-- for it (D-7).
module Hetoimasia.GPU.Vulkan.Native.Profile
  ( -- * Versions
    packApiVersion
  , apiMajorMinor
  , describeApiVersion
  , minimumApiVersion
  , requestedApiVersion

    -- * Extension names
  , debugUtilsExtension
  , portabilityEnumerationExtension
  , getSurfaceCapabilities2Extension
  , surfaceMaintenance1Extension
  , swapchainExtension
  , swapchainMaintenance1Extension
  , portabilitySubsetExtension
  , validationFeaturesExtension

    -- * The instance
  , ValidationFeature (..)
  , InstanceRequest (..)
  , InstanceOffer (..)
  , InstancePlan (..)
  , InstanceRefusal (..)
  , planInstance

    -- * The device
  , QueueFamilyOffer (..)
  , DeviceOffer (..)
  , DeviceRejection (..)
  , DevicePlan (..)
  , NoCompatibleDevice (..)
  , selectDevice

    -- * Later targets
  , TargetRejection (..)
  ) where

import Control.Exception (Exception (displayException))
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as Char8
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32)
import Hetoimasia.GPU.Model.Budget (BudgetKind)

-- ---------------------------------------------------------------------------
-- Versions

-- | A version in Vulkan's packed representation, variant zero.
packApiVersion ∷ Word32 → Word32 → Word32 → Word32
packApiVersion major minor patch = (major `shiftL` 22) .|. (minor `shiftL` 12) .|. patch

-- | The major and minor parts of a packed version, which is what the minimum
-- is stated in: a patch level never decides it.
apiMajorMinor ∷ Word32 → (Word32, Word32)
apiMajorMinor version = ((version `shiftR` 22) .&. 0x7f, (version `shiftR` 12) .&. 0x3ff)

describeApiVersion ∷ Word32 → Text
describeApiVersion version =
  Text.intercalate "." (map (Text.pack . show) [major, minor, version .&. 0xfff])
  where
    (major, minor) = apiMajorMinor version

-- | D-12's minimum, for the loader and for a device alike.
minimumApiVersion ∷ (Word32, Word32)
minimumApiVersion = (1, 3)

-- | The version the instance asks for.
requestedApiVersion ∷ Word32
requestedApiVersion = packApiVersion 1 3 0

meets ∷ Word32 → Bool
meets version = apiMajorMinor version >= minimumApiVersion

-- ---------------------------------------------------------------------------
-- Extension names
--
-- Spelled out rather than taken from the binding so this module needs no
-- binding at all. The native package's examples hold each to the binding's own
-- constant, so the two cannot drift apart unnoticed.

debugUtilsExtension ∷ ByteString
debugUtilsExtension = "VK_EXT_debug_utils"

portabilityEnumerationExtension ∷ ByteString
portabilityEnumerationExtension = "VK_KHR_portability_enumeration"

getSurfaceCapabilities2Extension ∷ ByteString
getSurfaceCapabilities2Extension = "VK_KHR_get_surface_capabilities2"

surfaceMaintenance1Extension ∷ ByteString
surfaceMaintenance1Extension = "VK_EXT_surface_maintenance1"

swapchainExtension ∷ ByteString
swapchainExtension = "VK_KHR_swapchain"

swapchainMaintenance1Extension ∷ ByteString
swapchainMaintenance1Extension = "VK_EXT_swapchain_maintenance1"

portabilitySubsetExtension ∷ ByteString
portabilitySubsetExtension = "VK_KHR_portability_subset"

-- | The layer extension whose create-info structure enables a validation
-- feature. A layer offers it, not the loader, so it is looked for among the
-- extensions of the layers the instance enables.
validationFeaturesExtension ∷ ByteString
validationFeaturesExtension = "VK_EXT_validation_features"

-- ---------------------------------------------------------------------------
-- The instance

-- | A validation feature an enabled layer turns on because the instance's own
-- create info asks for it — never because a machine's environment or settings
-- file happened to.
data ValidationFeature
  = -- | The Khronos layer's synchronization validation: hazards between
    -- commands that no barrier orders, which core validation does not check.
    SynchronizationValidation
  deriving (Eq, Ord, Show, Bounded, Enum)

-- | What the caller asks the instance for beyond the profile.
data InstanceRequest = InstanceRequest
  { requestSurfaceExtensions ∷ ![ByteString]
    -- ^ The instance extensions the windowing system requires for its
    -- surfaces. The caller supplies them — the GLFW integration copies them
    -- from its loader-aware session — because this package knows no window
    -- system.
  , requestLayers ∷ ![ByteString]
    -- ^ Layers to enable, each of which the loader must offer. Empty unless
    -- the caller wants one, such as the validation layer.
  , requestValidationFeatures ∷ ![ValidationFeature]
    -- ^ Validation features to enable through the instance's create info.
    -- Empty unless the caller wants one; any at all requires an enabled layer
    -- that offers @VK_EXT_validation_features@.
  }
  deriving (Eq, Show)

-- | What the loader offers.
data InstanceOffer = InstanceOffer
  { offerLoaderVersion ∷ !Word32
    -- ^ What @vkEnumerateInstanceVersion@ answered.
  , offerInstanceExtensions ∷ ![ByteString]
  , offerLayers ∷ ![ByteString]
  , offerLayerExtensions ∷ ![(ByteString, [ByteString])]
    -- ^ The instance extensions each offered layer provides, by layer name.
  }
  deriving (Eq, Show)

-- | What the instance is created with.
data InstancePlan = InstancePlan
  { planApiVersion ∷ !Word32
  , planInstanceExtensions ∷ ![ByteString]
  , planLayers ∷ ![ByteString]
  , planPortabilityEnumeration ∷ !Bool
    -- ^ Whether @VK_KHR_portability_enumeration@ is enabled, and with it the
    -- instance flag that lets the loader enumerate portability drivers.
  , planValidationFeatures ∷ ![ValidationFeature]
    -- ^ The validation features the create info enables; when there are any,
    -- @VK_EXT_validation_features@ is among 'planInstanceExtensions'.
  }
  deriving (Eq, Show)

-- | Why no instance can be planned from what the loader offers.
data InstanceRefusal
  = LoaderVersionTooOld !Word32
  | InstanceExtensionsUnavailable ![ByteString]
  | InstanceLayersUnavailable ![ByteString]
  | -- | Validation features were asked for, and none of these enabled layers
    -- offers the extension that enables them. Nothing falls back to validation
    -- without them.
    ValidationFeaturesUnavailable ![ByteString]
  deriving (Eq, Show)

instance Exception InstanceRefusal where
  displayException = \case
    LoaderVersionTooOld version →
      "the loader offers Vulkan " <> Text.unpack (describeApiVersion version) <> ", below the 1.3 minimum"
    InstanceExtensionsUnavailable names → "the loader does not offer the instance extensions " <> listed names
    InstanceLayersUnavailable names → "the loader does not offer the layers " <> listed names
    ValidationFeaturesUnavailable names →
      "validation features were requested, but "
        <> (if null names then "no layer is enabled" else "none of the enabled layers " <> listed names <> " offers")
        <> " "
        <> Char8.unpack validationFeaturesExtension

-- | Plan the instance, or say what the loader lacks.
--
-- Every required extension is checked, not just the first missing one, so a
-- refusal names the whole gap.
planInstance ∷ InstanceRequest → InstanceOffer → Either InstanceRefusal InstancePlan
planInstance request offer
  | not (meets (offerLoaderVersion offer)) = Left (LoaderVersionTooOld (offerLoaderVersion offer))
  | not (null missingExtensions) = Left (InstanceExtensionsUnavailable missingExtensions)
  | not (null missingLayers) = Left (InstanceLayersUnavailable missingLayers)
  | not (null features) && not featuresOffered = Left (ValidationFeaturesUnavailable layers)
  | otherwise =
      Right
        InstancePlan
          { planApiVersion = requestedApiVersion
          , planInstanceExtensions =
              required
                <> [portabilityEnumerationExtension | portability]
                <> [validationFeaturesExtension | not (null features)]
          , planLayers = layers
          , planPortabilityEnumeration = portability
          , planValidationFeatures = features
          }
  where
    layers = nub (requestLayers request)
    features = nub (requestValidationFeatures request)
    featuresOffered =
      or
        [ validationFeaturesExtension `elem` extensions
        | (layer, extensions) ← offerLayerExtensions offer
        , layer `elem` layers
        ]
    offered = offerInstanceExtensions offer
    portability = portabilityEnumerationExtension `elem` offered
    required =
      nub
        ( requestSurfaceExtensions request
            <> [debugUtilsExtension, getSurfaceCapabilities2Extension, surfaceMaintenance1Extension]
        )
    missingExtensions = filter (`notElem` offered) required
    missingLayers = filter (`notElem` offerLayers offer) (nub (requestLayers request))

-- ---------------------------------------------------------------------------
-- The device

-- | One queue family of a physical device, as far as selection needs it.
data QueueFamilyOffer = QueueFamilyOffer
  { familyIndex ∷ !Word32
  , familyGraphics ∷ !Bool
  , familyPresents ∷ !Bool
    -- ^ Whether it presents to the bootstrap surface.
  }
  deriving (Eq, Show)

-- | What one physical device offers. The device handle is the native layer's.
data DeviceOffer device = DeviceOffer
  { offerDevice ∷ !device
  , offerDeviceName ∷ !Text
  , offerDeviceApiVersion ∷ !Word32
  , offerDeviceExtensions ∷ ![ByteString]
  , offerDynamicRendering ∷ !Bool
  , offerSynchronization2 ∷ !Bool
  , offerSwapchainMaintenance1 ∷ !Bool
  , offerQueueFamilies ∷ ![QueueFamilyOffer]
  }

-- | Why one physical device cannot be the session's device.
data DeviceRejection
  = DeviceApiTooOld !Word32
  | DeviceExtensionMissing !ByteString
  | DeviceFeatureMissing !Text
  | DeviceNoPresentingGraphicsFamily
    -- ^ No single queue family answers both graphics and presentation to the
    -- bootstrap surface.
  deriving (Eq, Show)

-- | The device the session takes, and what it is created with.
data DevicePlan device = DevicePlan
  { planDevice ∷ !device
  , planDeviceName ∷ !Text
  , planDeviceApiVersion ∷ !Word32
  , planQueueFamily ∷ !Word32
    -- ^ The one queue family graphics and presentation share, for every
    -- target of the session.
  , planDeviceExtensions ∷ ![ByteString]
  , planPortabilitySubset ∷ !Bool
  }

instance Functor DevicePlan where
  fmap function plan = plan {planDevice = function (planDevice plan)}

-- | No enumerated device satisfies the profile: a structured startup failure,
-- naming every candidate and everything each one lacks.
newtype NoCompatibleDevice = NoCompatibleDevice [(Text, [DeviceRejection])]
  deriving (Eq, Show)

instance Exception NoCompatibleDevice where
  displayException (NoCompatibleDevice []) = "no physical device was enumerated"
  displayException (NoCompatibleDevice candidates) =
    "no physical device satisfies the Vulkan profile: "
      <> concatMap' "; " [Text.unpack name <> " (" <> concatMap' ", " (map describe reasons) <> ")" | (name, reasons) ← candidates]
    where
      describe = \case
        DeviceApiTooOld version → "Vulkan " <> Text.unpack (describeApiVersion version)
        DeviceExtensionMissing name → "no " <> Char8.unpack name
        DeviceFeatureMissing name → "no " <> Text.unpack name
        DeviceNoPresentingGraphicsFamily → "no queue family with both graphics and presentation"

-- | The first device, in enumeration order, that satisfies the whole profile.
selectDevice ∷ [DeviceOffer device] → Either NoCompatibleDevice (DevicePlan device)
selectDevice candidates = case [plan | Right plan ← examined] of
  plan : _ → Right plan
  [] → Left (NoCompatibleDevice [(offerDeviceName offer, reasons) | (offer, Left reasons) ← zip candidates examined])
  where
    examined = map examine candidates

examine ∷ DeviceOffer device → Either [DeviceRejection] (DevicePlan device)
examine offer = case (rejections, family) of
  ([], Just chosen) →
    Right
      DevicePlan
        { planDevice = offerDevice offer
        , planDeviceName = offerDeviceName offer
        , planDeviceApiVersion = offerDeviceApiVersion offer
        , planQueueFamily = chosen
        , planDeviceExtensions = [swapchainExtension, swapchainMaintenance1Extension] <> [portabilitySubsetExtension | portability]
        , planPortabilitySubset = portability
        }
  _ → Left rejections
  where
    has name = name `elem` offerDeviceExtensions offer
    portability = has portabilitySubsetExtension
    family = case [familyIndex queue | queue ← offerQueueFamilies offer, familyGraphics queue, familyPresents queue] of
      first : _ → Just first
      [] → Nothing
    rejections =
      [DeviceApiTooOld (offerDeviceApiVersion offer) | not (meets (offerDeviceApiVersion offer))]
        <> [DeviceExtensionMissing name | name ← [swapchainExtension, swapchainMaintenance1Extension], not (has name)]
        <> [DeviceFeatureMissing "dynamicRendering" | not (offerDynamicRendering offer)]
        <> [DeviceFeatureMissing "synchronization2" | not (offerSynchronization2 offer)]
        <> [DeviceFeatureMissing "swapchainMaintenance1" | not (offerSwapchainMaintenance1 offer)]
        <> [DeviceNoPresentingGraphicsFamily | family == Nothing]

-- ---------------------------------------------------------------------------
-- Later targets

-- | Why a surface was refused as a target of the session's roots. Each is
-- answered before the target exists: its surface is the caller's to destroy,
-- and the device, the instance and every existing target are untouched.
data TargetRejection
  = TargetSurfaceUnsupported !Word32
    -- ^ The session's queue family does not present to this surface. No second
    -- device and no second queue is chosen for it (D-7).
  | TargetAdmissionClosed
    -- ^ The roots admit no new target: they are retiring, or a device loss
    -- closed them.
  | TargetBudgetExhausted !BudgetKind
    -- ^ The model's validated budget has no room for another target.
  deriving (Eq, Show)

listed ∷ [ByteString] → String
listed = concatMap' ", " . map Char8.unpack

concatMap' ∷ String → [String] → String
concatMap' separator = \case
  [] → ""
  first : rest → first <> concatMap (separator <>) rest
