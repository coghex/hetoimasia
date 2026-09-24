-- | The GLFW package's Vulkan interop: one shared loader, the instance
-- extensions a window surface needs, and window surfaces created under a
-- protected attachment.
--
-- This is the package's separate @vulkan-interop@ component. It is built only
-- when its manual @vulkan-interop@ flag is on, which only
-- @cabal.project.vulkan@ sets: an ordinary @cabal build all@, with either of
-- the other two project files, builds none of it, resolves no Vulkan binding,
-- and links no loader. Its C shim is the one translation unit in the package
-- that includes the Vulkan headers, before GLFW's; the package's ordinary
-- native library keeps @GLFW_INCLUDE_NONE@. It depends on no GPU package and no
-- renderer.
--
-- = One loader
--
-- 'allocLoaderIntegration' builds the opaque, single-use 'LoaderIntegration'
-- capability from the loader entry point the Vulkan binding already dispatches
-- through — the binding's own linked @vkGetInstanceProcAddr@ — so GLFW and the
-- binding resolve through one loader by construction. A session takes it
-- through 'Hetoimasia.GLFW.Session.allocIntegratedSession', the additive
-- constructor beside the window-only one, which hands it to GLFW between the
-- initialization hints and @glfwInit@ and restores GLFW's default after
-- termination or a failed initialization; see "Hetoimasia.GLFW.Session".
--
-- = Instance extensions
--
-- 'requiredInstanceExtensions' copies the names GLFW requires into storage the
-- caller owns, on the owner thread of a live loader-aware session.
--
-- = Surfaces
--
-- A surface is created only inside a protected attachment's construction step
-- ('attachWindowGraphicsWithSurfaces') or an admitted replacement on a live
-- attachment ('replaceWindowSurface'), against an instance its owner has
-- leased ('leaseSurfaceInstance'). The window's native pointer is borrowed
-- inside the bridge and never exposed. The caller receives a live
-- 'WindowSurface' or, when it must not be used, its 'SurfaceObligation' alone;
-- either way the obligation holds the attachment and the lease until
-- 'dischargeSurfaceObligation' destroys the surface through Vulkan, from any
-- thread, once. See "Hetoimasia.Runtime.GLFW.Internal.Surface" for the whole
-- contract and @docs/glfw.md@ for the ownership rules.
--
-- No GLFW or Vulkan type crosses this boundary: the capability and the surface
-- records are opaque, an instance is leased as its untyped dispatchable
-- handle, and a surface's handle is the 64-bit value 'surfaceHandle' answers.
module Hetoimasia.GLFW.Vulkan
  ( -- * The loader integration capability
    LoaderIntegration
  , allocLoaderIntegration
  , withLoaderIntegration
  , loaderCapability
  , LoaderUnavailable (..)

    -- * Loader-aware sessions
  , allocLoaderSession
  , withLoaderSession

    -- * Instance extensions
  , requiredInstanceExtensions
  , InteropUnavailable (..)

    -- * Instances
  , SurfaceInstance
  , leaseSurfaceInstance
  , releaseSurfaceInstance
  , InstanceRelease (..)
  , LeaseStanding (..)
  , readLeaseStanding
  , leasedObligations

    -- * Where a surface may be created
  , SurfaceAccess
  , attachWindowGraphicsWithSurfaces
  , replaceWindowSurface
  , Replacement (..)

    -- * Creating surfaces
  , createWindowSurface
  , SurfaceCreation (..)
  , SurfaceRefusal (..)
  , UnpublishedReason (..)
  , WindowSurface
  , surfaceHandle
  , surfaceAttachment
  , surfaceObligation

    -- * Destroying them
  , SurfaceObligation
  , obligationAttachment
  , obligationHandle
  , dischargeSurfaceObligation
  , Discharge (..)
  , DischargeRefusal (..)
  , ObligationState (..)
  , readObligationState
  , DestroyEntryUnresolved (..)
  ) where

import Foreign.Ptr (Ptr)
import Hetoimasia.Foundation.Resource (Scoped, withScoped)
import Hetoimasia.GLFW.Internal.Interop (InteropUnavailable (..), requiredInstanceExtensions)
import Hetoimasia.GLFW.Internal.Session (Session, SessionConfig)
import Hetoimasia.GLFW.Session (allocIntegratedSession)
import Hetoimasia.GLFW.Vulkan.Internal.Capability
  ( LoaderIntegration
  , LoaderUnavailable (..)
  , allocLoaderIntegration
  , loaderCapability
  , withLoaderIntegration
  )
import Hetoimasia.GLFW.Vulkan.Internal.Native (DestroyEntryUnresolved (..))
import Hetoimasia.Runtime.GLFW.Internal.Surface
  ( Discharge (..)
  , DischargeRefusal (..)
  , InstanceRelease (..)
  , LeaseStanding (..)
  , ObligationState (..)
  , Replacement (..)
  , SurfaceAccess
  , SurfaceCreation (..)
  , SurfaceInstance
  , SurfaceObligation
  , SurfaceRefusal (..)
  , UnpublishedReason (..)
  , WindowSurface
  , attachWindowGraphicsWithSurfaces
  , createWindowSurface
  , dischargeSurfaceObligation
  , leasedObligations
  , obligationAttachment
  , obligationHandle
  , readLeaseStanding
  , readObligationState
  , releaseSurfaceInstance
  , replaceWindowSurface
  , surfaceAttachment
  , surfaceHandle
  , surfaceObligation
  )
import qualified Hetoimasia.Runtime.GLFW.Internal.Surface as Surface

-- | Enter a loader-aware session that takes this capability:
-- 'Hetoimasia.GLFW.Session.allocIntegratedSession' with the capability
-- unwrapped.
allocLoaderSession ∷ LoaderIntegration → SessionConfig → Scoped Session
allocLoaderSession = allocIntegratedSession . loaderCapability

-- | 'allocLoaderSession' as a continuation.
withLoaderSession ∷ LoaderIntegration → SessionConfig → (Session → IO r) → IO r
withLoaderSession integration config = withScoped (allocLoaderSession integration config)

-- | Lease a Vulkan instance created through this capability's loader to the
-- surface bridge. The pointer is the instance's dispatchable handle; the
-- lease never destroys it. See 'releaseSurfaceInstance' for taking it back.
leaseSurfaceInstance ∷ LoaderIntegration → Ptr () → IO SurfaceInstance
leaseSurfaceInstance = Surface.leaseSurfaceInstance . loaderCapability
