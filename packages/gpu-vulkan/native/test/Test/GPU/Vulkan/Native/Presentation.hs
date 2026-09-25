-- | The first presentation profile and D-30's extent policy, as pure
-- decisions: no native call, no stand-in.
module Test.GPU.Vulkan.Native.Presentation (spec) where

import Data.Bits ((.&.), (.|.))
import Test.Hspec (Spec, describe, it, shouldBe)
import Vulkan.Core10 (Format (..), ImageUsageFlagBits (..))
import Vulkan.Extensions.VK_KHR_surface (ColorSpaceKHR (..), CompositeAlphaFlagBitsKHR (..), PresentModeKHR (..))

import Hetoimasia.GPU.Vulkan.Native.Presentation

spec ∷ Spec
spec = describe "Presentation" $ do
  it "spells every profile value as the binding does" $ do
    let Format bgra = FORMAT_B8G8R8A8_SRGB
        Format rgba = FORMAT_R8G8B8A8_SRGB
        ColorSpaceKHR srgb = COLOR_SPACE_SRGB_NONLINEAR_KHR
        PresentModeKHR fifo = PRESENT_MODE_FIFO_KHR
        ImageUsageFlagBits color = IMAGE_USAGE_COLOR_ATTACHMENT_BIT
        CompositeAlphaFlagBitsKHR opaque = COMPOSITE_ALPHA_OPAQUE_BIT_KHR
        CompositeAlphaFlagBitsKHR pre = COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR
        CompositeAlphaFlagBitsKHR post = COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR
        CompositeAlphaFlagBitsKHR inherit = COMPOSITE_ALPHA_INHERIT_BIT_KHR
    [formatB8G8R8A8Srgb, formatR8G8B8A8Srgb] `shouldBe` map fromIntegral [bgra, rgba]
    colorSpaceSrgbNonlinear `shouldBe` fromIntegral srgb
    presentModeFifo `shouldBe` fromIntegral fifo
    imageUsageColorAttachment `shouldBe` color
    [compositeAlphaOpaque, compositeAlphaPreMultiplied, compositeAlphaPostMultiplied, compositeAlphaInherit]
      `shouldBe` [opaque, pre, post, inherit]

  describe "the extent" $ do
    it "takes a concrete extent the surface supplies, whatever the observation says" $
      chooseExtent (eligible (SurfaceExtent 320 240)) (capabilities (Just (SurfaceExtent 1280 960)))
        `shouldBe` ExtentChosen ExtentFromSurface (SurfaceExtent 1280 960)

    it "chooses from the last observation when the surface leaves it to the application, clamped to its bounds" $
      chooseExtent (eligible (SurfaceExtent 5000 100)) (capabilities Nothing) {capabilityMinExtent = SurfaceExtent 200 200, capabilityMaxExtent = SurfaceExtent 4096 4096}
        `shouldBe` ExtentChosen ExtentFromObservation (SurfaceExtent 4096 200)

    it "clamps to the bounds the platform published as well as the surface's" $
      chooseExtent (eligible (SurfaceExtent 1000 700)) {geometryBounds = Just (SurfaceExtent 1 1, SurfaceExtent 800 800)} (capabilities Nothing)
        `shouldBe` ExtentChosen ExtentFromObservation (SurfaceExtent 800 700)

    it "checks zero area before clamping, so a zero framebuffer is never resumed at the minimum" $
      chooseExtent (eligible (SurfaceExtent 0 480)) (capabilities Nothing) {capabilityMinExtent = SurfaceExtent 64 64}
        `shouldBe` ExtentWithheld (SuspendedZeroArea (SurfaceExtent 0 480))

    it "suspends on a concrete extent without area" $
      chooseExtent (eligible (SurfaceExtent 640 480)) (capabilities (Just (SurfaceExtent 0 0)))
        `shouldBe` ExtentWithheld (SuspendedZeroArea (SurfaceExtent 0 0))

    it "decides eligibility first, before anything the surface reports" $
      chooseExtent (eligible (SurfaceExtent 640 480)) {geometryEligibility = Left "minimized"} (capabilities (Just (SurfaceExtent 640 480)))
        `shouldBe` ExtentWithheld (SuspendedIneligible "minimized")

    it "cannot invent geometry: an application choice with nothing observed is withheld" $
      chooseExtent (eligible (SurfaceExtent 640 480)) {geometryFramebuffer = Nothing} (capabilities Nothing)
        `shouldBe` ExtentWithheld SuspendedUnobserved

    it "withholds a clamp that leaves no area" $
      chooseExtent (eligible (SurfaceExtent 640 480)) (capabilities Nothing) {capabilityMaxExtent = SurfaceExtent 0 0, capabilityMinExtent = SurfaceExtent 0 0}
        `shouldBe` ExtentWithheld (SuspendedInvalidBounds (SurfaceExtent 0 0) (SurfaceExtent 0 0))

  describe "the plan" $ do
    it "plans BGRA sRGB, FIFO, color attachment only, opaque, and one image beyond the minimum" $
      planGeneration 16 (eligible (SurfaceExtent 640 480)) offer
        `shouldBe` Planned
          GenerationPlan
            { planFormat = SurfaceFormat formatB8G8R8A8Srgb colorSpaceSrgbNonlinear
            , planPresentMode = presentModeFifo
            , planExtent = SurfaceExtent 640 480
            , planExtentSource = ExtentFromSurface
            , planMinImages = 3
            , planUsage = imageUsageColorAttachment
            , planTransform = 1
            , planCompositeAlpha = compositeAlphaOpaque
            }

    it "takes RGBA sRGB when BGRA is not offered" $
      planFormat <$> planned (planGeneration 16 (eligible (SurfaceExtent 640 480)) offer {offerFormats = [SurfaceFormat formatR8G8B8A8Srgb colorSpaceSrgbNonlinear]})
        `shouldBe` Just (SurfaceFormat formatR8G8B8A8Srgb colorSpaceSrgbNonlinear)

    it "never requires, nor asks for, the transfer usages a capture path needs" $ do
      let ImageUsageFlagBits source = IMAGE_USAGE_TRANSFER_SRC_BIT
          ImageUsageFlagBits destination = IMAGE_USAGE_TRANSFER_DST_BIT
          transfer = source .|. destination
          usage = planUsage <$> planned (planGeneration 16 (eligible (SurfaceExtent 640 480)) (withUsage imageUsageColorAttachment))
      usage `shouldBe` Just imageUsageColorAttachment
      fmap (.&. transfer) usage `shouldBe` Just 0

    it "reports every gap of an unsupported surface together, and falls back to no UNORM or arbitrary format" $ do
      let unorm = SurfaceFormat 44 colorSpaceSrgbNonlinear
          Format bgra = FORMAT_B8G8R8A8_SRGB
          PresentModeKHR mailbox = PRESENT_MODE_MAILBOX_KHR
          poor =
            offer
              { offerFormats = [unorm, SurfaceFormat (fromIntegral bgra) extendedSrgbLinear]
              , offerPresentModes = [fromIntegral mailbox]
              , offerCapabilities = (offerCapabilities offer) {capabilityUsage = 0, capabilityCompositeAlpha = 0}
              }
          -- The right format in another color space is not the profile's.
          extendedSrgbLinear = 1000104002
      planGeneration 16 (eligible (SurfaceExtent 640 480)) poor
        `shouldBe` PlanUnsupported
          [ NoSrgbFormat (offerFormats poor)
          , NoFifoPresentation [fromIntegral mailbox]
          , NoColorAttachmentUsage 0
          , NoCompositeAlpha
          ]

    it "suspends before it reports what the surface lacks" $
      planGeneration 16 (eligible (SurfaceExtent 0 0)) offer {offerFormats = [], offerCapabilities = capabilities Nothing}
        `shouldBe` PlanSuspended (SuspendedZeroArea (SurfaceExtent 0 0))

    it "asks for images within the surface's maximum and the tracking limit" $ do
      planMinImages <$> planned (planGeneration 16 (eligible (SurfaceExtent 640 480)) (withImages 3 3)) `shouldBe` Just 3
      planMinImages <$> planned (planGeneration 16 (eligible (SurfaceExtent 640 480)) (withImages 2 0)) `shouldBe` Just 3
      planMinImages <$> planned (planGeneration 2 (eligible (SurfaceExtent 640 480)) (withImages 2 0)) `shouldBe` Just 2

    it "refuses a surface whose minimum image count exceeds the tracking limit" $
      planGeneration 2 (eligible (SurfaceExtent 640 480)) (withImages 3 0)
        `shouldBe` PlanUnsupported [TrackingLimitBelowMinimum 3 2]

    it "prefers the opaque composite, then inherit" $
      planCompositeAlpha <$> planned (planGeneration 16 (eligible (SurfaceExtent 640 480)) offer {offerCapabilities = (offerCapabilities offer) {capabilityCompositeAlpha = compositeAlphaInherit + compositeAlphaPreMultiplied}})
        `shouldBe` Just compositeAlphaInherit
  where
    planned = \case
      Planned plan → Just plan
      _ → Nothing
    withUsage usage = offer {offerCapabilities = (offerCapabilities offer) {capabilityUsage = usage}}
    withImages minimum' maximum' = offer {offerCapabilities = (offerCapabilities offer) {capabilityMinImages = minimum', capabilityMaxImages = maximum'}}

eligible ∷ SurfaceExtent → TargetGeometry
eligible framebuffer = TargetGeometry (Right ()) (Just framebuffer) Nothing 1

capabilities ∷ Maybe SurfaceExtent → SurfaceCapabilities
capabilities current =
  SurfaceCapabilities
    { capabilityMinImages = 2
    , capabilityMaxImages = 8
    , capabilityCurrentExtent = current
    , capabilityMinExtent = SurfaceExtent 1 1
    , capabilityMaxExtent = SurfaceExtent 4096 4096
    , capabilityUsage = imageUsageColorAttachment
    , capabilityCurrentTransform = 1
    , capabilityCompositeAlpha = compositeAlphaOpaque
    }

offer ∷ SurfaceOffer
offer =
  SurfaceOffer
    { offerCapabilities = capabilities (Just (SurfaceExtent 640 480))
    , offerFormats = [SurfaceFormat 44 colorSpaceSrgbNonlinear, SurfaceFormat formatB8G8R8A8Srgb colorSpaceSrgbNonlinear]
    , offerPresentModes = [0, presentModeFifo]
    }
