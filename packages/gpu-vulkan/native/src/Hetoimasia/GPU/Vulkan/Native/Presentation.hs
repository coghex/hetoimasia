-- | The first presentation profile and D-30's extent policy, as pure
-- decisions over what a surface reports.
--
-- Nothing here makes a native call or names a binding type. The native layer
-- reads a surface's capabilities, formats and presentation modes into a
-- 'SurfaceOffer'; 'planGeneration' decides from that offer, the target's last
-- published geometry and the configured image tracking limit whether a
-- swapchain generation can be built now, with what, and why not otherwise. The
-- same decision therefore runs against stand-ins in the headless examples and
-- against the driver in a native run.
--
-- = The profile
--
-- P-15's first profile, deliberately small: single-sample SDR color-attachment
-- rendering, FIFO presentation and an advertised 8-bit sRGB surface format —
-- @B8G8R8A8_SRGB@ or @R8G8B8A8_SRGB@ in the sRGB nonlinear color space. A
-- surface that offers none of these, no FIFO mode, no color-attachment usage
-- or no composite-alpha mode is reported as unsupported ('PresentationGap'),
-- naming the whole gap; nothing is assumed. Normal targets never require the
-- transfer usages the retired proof harness asked for, and never fall back to
-- a UNORM or an arbitrary format.
--
-- = The extent
--
-- D-30, in this order, which is the order of "Hetoimasia.Runtime.GLFW"'s
-- @chooseTargetExtent@ seam:
--
-- 1. the target's own render eligibility — a target the main thread knows to
--    be hidden, minimized or closing is withheld before anything else;
-- 2. a concrete current extent the surface supplied is taken as it is, unless
--    it has no area;
-- 3. otherwise the application chooses: the last published framebuffer
--    observation, checked for area /before/ it is clamped — so clamping a zero
--    framebuffer to a positive minimum never resumes it — and then clamped to
--    the bounds the platform published, if any, and to the surface's own
--    reported bounds. A clamp that still leaves no area is withheld too.
--
-- A withheld extent suspends acquisition for the target; it is not a failed
-- construction.
module Hetoimasia.GPU.Vulkan.Native.Presentation
  ( -- * What a surface reports
    SurfaceExtent (..)
  , SurfaceCapabilities (..)
  , SurfaceFormat (..)
  , SurfaceOffer (..)
  , undefinedExtentDimension

    -- * What the target's owner published
  , TargetGeometry (..)
  , noGeometry

    -- * The extent
  , ExtentSource (..)
  , Suspension (..)
  , ExtentChoice (..)
  , chooseExtent

    -- * The generation plan
  , GenerationPlan (..)
  , PresentationGap (..)
  , PlanAnswer (..)
  , planGeneration

    -- * The profile's values
  , formatB8G8R8A8Srgb
  , formatR8G8B8A8Srgb
  , colorSpaceSrgbNonlinear
  , presentModeFifo
  , imageUsageColorAttachment
  , compositeAlphaOpaque
  , compositeAlphaPreMultiplied
  , compositeAlphaPostMultiplied
  , compositeAlphaInherit
  ) where

import Data.Bits ((.&.))
import Data.Text (Text)
import Data.Word (Word32)
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- What a surface reports

-- | A two-dimensional extent in physical pixels.
data SurfaceExtent = SurfaceExtent
  { extentWidth ∷ !Word32
  , extentHeight ∷ !Word32
  }
  deriving (Eq, Ord, Show)

-- | The value either dimension of a surface's current extent takes when the
-- surface leaves the extent to the application.
undefinedExtentDimension ∷ Word32
undefinedExtentDimension = maxBound

-- | What @vkGetPhysicalDeviceSurfaceCapabilitiesKHR@ reported, as far as
-- planning needs it.
data SurfaceCapabilities = SurfaceCapabilities
  { capabilityMinImages ∷ !Word32
  , capabilityMaxImages ∷ !Word32
    -- ^ Zero when the surface sets no maximum.
  , capabilityCurrentExtent ∷ !(Maybe SurfaceExtent)
    -- ^ 'Nothing' when the surface reported the undefined extent, which is
    -- the "application chooses" case.
  , capabilityMinExtent ∷ !SurfaceExtent
  , capabilityMaxExtent ∷ !SurfaceExtent
  , capabilityUsage ∷ !Word32
    -- ^ The supported image usage flags.
  , capabilityCurrentTransform ∷ !Word32
  , capabilityCompositeAlpha ∷ !Word32
    -- ^ The supported composite-alpha flags.
  }
  deriving (Eq, Show)

-- | One advertised surface format.
data SurfaceFormat = SurfaceFormat
  { surfaceFormat ∷ !Word32
  , surfaceColorSpace ∷ !Word32
  }
  deriving (Eq, Show)

-- | Everything one surface reported for one device.
data SurfaceOffer = SurfaceOffer
  { offerCapabilities ∷ !SurfaceCapabilities
  , offerFormats ∷ ![SurfaceFormat]
  , offerPresentModes ∷ ![Word32]
  }
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- What the target's owner published

-- | The last coherent geometry the target's owner holds: whether the main
-- thread's latest observation leaves it eligible to render, the framebuffer
-- extent that observation last reported, and the bounds the platform
-- published, if any. It is the integration's view of D-30's seam, carried in
-- this package's own terms.
data TargetGeometry = TargetGeometry
  { geometryEligibility ∷ !(Either Text ())
    -- ^ 'Left' with the reason when the target is not eligible to render.
  , geometryFramebuffer ∷ !(Maybe SurfaceExtent)
    -- ^ 'Nothing' when no framebuffer extent has ever been observed.
  , geometryBounds ∷ !(Maybe (SurfaceExtent, SurfaceExtent))
    -- ^ The minimum and maximum the platform published, if any.
  , geometryRevision ∷ !Natural
    -- ^ The observation revision this geometry was folded from.
  }
  deriving (Eq, Show)

-- | A target nothing has been observed for yet: eligibility is unknown, so it
-- is withheld.
noGeometry ∷ TargetGeometry
noGeometry = TargetGeometry (Left "no observation has been published") Nothing Nothing 0

-- ---------------------------------------------------------------------------
-- The extent

-- | Where a chosen extent came from.
data ExtentSource
  = ExtentFromSurface
    -- ^ The surface supplied a concrete current extent.
  | ExtentFromObservation
    -- ^ The application chose it from the last published framebuffer
    -- observation, clamped to the reported bounds.
  deriving (Eq, Show)

-- | Why no extent can be used now. Each suspends acquisition for the target;
-- none is a failed construction.
data Suspension
  = SuspendedIneligible !Text
    -- ^ The target's own eligibility excludes rendering.
  | SuspendedZeroArea !SurfaceExtent
    -- ^ The extent has no area. Checked before clamping.
  | SuspendedUnobserved
    -- ^ The surface leaves the extent to the application and no framebuffer
    -- extent has been observed to choose from.
  | SuspendedInvalidBounds !SurfaceExtent !SurfaceExtent
    -- ^ Clamping to these reported bounds leaves no area.
  deriving (Eq, Show)

data ExtentChoice
  = ExtentChosen !ExtentSource !SurfaceExtent
  | ExtentWithheld !Suspension
  deriving (Eq, Show)

-- | D-30's extent, in the order the module header states.
chooseExtent ∷ TargetGeometry → SurfaceCapabilities → ExtentChoice
chooseExtent geometry capabilities
  | Left reason ← geometryEligibility geometry = ExtentWithheld (SuspendedIneligible reason)
  | Just current ← capabilityCurrentExtent capabilities =
      if blank current then ExtentWithheld (SuspendedZeroArea current) else ExtentChosen ExtentFromSurface current
  | otherwise = case geometryFramebuffer geometry of
      Nothing → ExtentWithheld SuspendedUnobserved
      Just observed
        | blank observed → ExtentWithheld (SuspendedZeroArea observed)
        | blank clamped → ExtentWithheld (SuspendedInvalidBounds low high)
        | otherwise → ExtentChosen ExtentFromObservation clamped
        where
          published = maybe observed (\(minimum', maximum') → clamp minimum' maximum' observed) (geometryBounds geometry)
          low = capabilityMinExtent capabilities
          high = capabilityMaxExtent capabilities
          clamped = clamp low high published
  where
    blank extent = extentWidth extent == 0 || extentHeight extent == 0
    clamp low high extent =
      SurfaceExtent
        { extentWidth = bound (extentWidth low) (extentWidth high) (extentWidth extent)
        , extentHeight = bound (extentHeight low) (extentHeight high) (extentHeight extent)
        }
    bound low high value = max low (min high value)

-- ---------------------------------------------------------------------------
-- The generation plan

-- | What one swapchain generation is created with.
data GenerationPlan = GenerationPlan
  { planFormat ∷ !SurfaceFormat
  , planPresentMode ∷ !Word32
  , planExtent ∷ !SurfaceExtent
  , planExtentSource ∷ !ExtentSource
  , planMinImages ∷ !Word32
    -- ^ The image count asked for. The driver may return more; the returned
    -- count is checked against the tracking limit before anything depends on
    -- it.
  , planUsage ∷ !Word32
  , planTransform ∷ !Word32
  , planCompositeAlpha ∷ !Word32
  }
  deriving (Eq, Show)

-- | Something the first presentation profile needs that the surface does not
-- offer.
data PresentationGap
  = NoSrgbFormat ![SurfaceFormat]
    -- ^ None of the advertised formats, named here, is an 8-bit sRGB RGBA or
    -- BGRA format in the sRGB nonlinear color space.
  | NoFifoPresentation ![Word32]
  | NoColorAttachmentUsage !Word32
  | NoCompositeAlpha
  | TrackingLimitBelowMinimum !Word32 !Natural
    -- ^ The surface needs at least this many images, more than the configured
    -- tracking limit allows.
  deriving (Eq, Show)

data PlanAnswer
  = Planned !GenerationPlan
  | PlanSuspended !Suspension
    -- ^ No extent can be used now. This is suspension, not failure.
  | PlanUnsupported ![PresentationGap]
    -- ^ A structured target failure: the surface cannot serve the profile.
  deriving (Eq, Show)

-- | Plan one generation against the image tracking limit.
--
-- The extent is decided first, because a target that cannot render now is
-- suspended whatever else is true of its surface. Every gap in the profile is
-- then named together, so a refusal names the whole of it.
planGeneration ∷ Natural → TargetGeometry → SurfaceOffer → PlanAnswer
planGeneration trackingLimit geometry offer = case chooseExtent geometry capabilities of
  ExtentWithheld suspension → PlanSuspended suspension
  ExtentChosen source extent → case (gaps, format, alpha) of
    ([], Just chosen, Just composite) →
      Planned
        GenerationPlan
          { planFormat = chosen
          , planPresentMode = presentModeFifo
          , planExtent = extent
          , planExtentSource = source
          , planMinImages = requested
          , planUsage = imageUsageColorAttachment
          , planTransform = capabilityCurrentTransform capabilities
          , planCompositeAlpha = composite
          }
    _ → PlanUnsupported gaps
  where
    capabilities = offerCapabilities offer
    format =
      case [candidate | preferred ← [formatB8G8R8A8Srgb, formatR8G8B8A8Srgb], candidate ← offerFormats offer, candidate == SurfaceFormat preferred colorSpaceSrgbNonlinear] of
        chosen : _ → Just chosen
        [] → Nothing
    alpha =
      case [flag | flag ← [compositeAlphaOpaque, compositeAlphaInherit, compositeAlphaPreMultiplied, compositeAlphaPostMultiplied], capabilityCompositeAlpha capabilities .&. flag /= 0] of
        chosen : _ → Just chosen
        [] → Nothing
    minimumImages = capabilityMinImages capabilities
    -- One more than the minimum, so an image can be acquired while another is
    -- still being presented, within the surface's maximum and the tracking
    -- limit.
    wanted = minimumImages + 1
    surfaceCapped = if capabilityMaxImages capabilities == 0 then wanted else min wanted (capabilityMaxImages capabilities)
    requested = fromIntegral (min (fromIntegral surfaceCapped) trackingLimit)
    gaps =
      [NoSrgbFormat (offerFormats offer) | format == Nothing]
        <> [NoFifoPresentation (offerPresentModes offer) | presentModeFifo `notElem` offerPresentModes offer]
        <> [NoColorAttachmentUsage (capabilityUsage capabilities) | capabilityUsage capabilities .&. imageUsageColorAttachment == 0]
        <> [NoCompositeAlpha | alpha == Nothing]
        <> [TrackingLimitBelowMinimum minimumImages trackingLimit | fromIntegral minimumImages > trackingLimit]

-- ---------------------------------------------------------------------------
-- The profile's values
--
-- Spelled out rather than taken from the binding so this module needs no
-- binding at all. The native package's examples hold each to the binding's own
-- constant, so the two cannot drift apart unnoticed.

formatR8G8B8A8Srgb ∷ Word32
formatR8G8B8A8Srgb = 43

formatB8G8R8A8Srgb ∷ Word32
formatB8G8R8A8Srgb = 50

colorSpaceSrgbNonlinear ∷ Word32
colorSpaceSrgbNonlinear = 0

presentModeFifo ∷ Word32
presentModeFifo = 2

imageUsageColorAttachment ∷ Word32
imageUsageColorAttachment = 0x10

compositeAlphaOpaque ∷ Word32
compositeAlphaOpaque = 0x1

compositeAlphaPreMultiplied ∷ Word32
compositeAlphaPreMultiplied = 0x2

compositeAlphaPostMultiplied ∷ Word32
compositeAlphaPostMultiplied = 0x4

compositeAlphaInherit ∷ Word32
compositeAlphaInherit = 0x8
