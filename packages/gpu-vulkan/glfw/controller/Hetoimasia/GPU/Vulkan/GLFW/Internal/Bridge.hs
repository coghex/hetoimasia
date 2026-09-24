-- | The surface bridge, as the Vulkan controller uses it.
--
-- The GLFW package's surface bridge (VK-5, "Hetoimasia.GLFW.Vulkan") is what
-- creates a window surface on the main thread inside an attachment's
-- construction step, and what destroys it through Vulkan from whichever thread
-- holds its obligation. The controller reaches it through this record rather
-- than directly, for one reason: the headless examples must drive the
-- controller's decisions over a scripted bridge, and the bridge's own leases
-- can only be made from a production loader capability, which a headless
-- example does not have. 'vulkanSurfaceBridge' is the production record, and
-- it is a direct restatement of the bridge's contract, deciding nothing.
module Hetoimasia.GPU.Vulkan.GLFW.Internal.Bridge
  ( SurfaceBridge (..)
  , Created (..)
  , Discharged (..)
  , LeaseAnswer (..)
  , vulkanSurfaceBridge
  , DischargeNotPerformed (..)
  ) where

import Control.Concurrent.STM (STM)
import Control.Exception (Exception, ExceptionWithContext, SomeException, throwIO, tryWithContext)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Foreign.Ptr (Ptr)
import Hetoimasia.GLFW.Vulkan
  ( Discharge (..)
  , DischargeRefusal (..)
  , InstanceRelease (..)
  , LeaseStanding (..)
  , LoaderIntegration
  , SurfaceCreation (..)
  , SurfaceInstance
  , SurfaceObligation
  , attachWindowGraphicsWithSurfaces
  , createWindowSurface
  , dischargeSurfaceObligation
  , leaseSurfaceInstance
  , leasedObligations
  , obligationAttachment
  , obligationHandle
  , releaseSurfaceInstance
  , surfaceObligation
  )
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.Runtime.GLFW (AttachmentId, AttachmentProtocol, GraphicsAttachment, WindowHost)

-- | What one surface creation left, from the controller's side.
data Created obligation
  = CreatedLive !obligation
    -- ^ A live surface, owed its one destruction.
  | CreatedUnusable !obligation !Text
    -- ^ A surface exists and must not be used — the window began closing, the
    -- attachment began retiring, GLFW reported during the call — so only its
    -- obligation came back, with why.
  | CreationFailed !Text
    -- ^ Nothing was created: the native call failed, or the bridge refused
    -- before any native effect.

-- | How one destruction went.
data Discharged
  = DischargeDone
    -- ^ The surface no longer exists.
  | DischargeUncertain !(ExceptionWithContext SomeException)
    -- ^ The destruction raised, or was refused because an earlier one was
    -- uncertain or is still running. The surface may exist, and its holds on
    -- the attachment and the instance stay.

-- | Every operation of the surface bridge the controller needs.
data SurfaceBridge lease obligation = SurfaceBridge
  { bridgeLease ∷ Ptr () → IO lease
    -- ^ Lease the instance, by its dispatchable handle, to the bridge.
  , bridgeAttach
      ∷ WindowHost
      → WindowId
      → ((lease → IO (Created obligation)) → AttachmentProtocol)
      → IO GraphicsAttachment
    -- ^ Attach a protocol whose construction step may create surfaces for
    -- that attachment, on the main thread; the step is handed the creation.
  , bridgeObligations ∷ lease → STM [obligation]
    -- ^ Every obligation against the lease not yet confirmed destroyed, which
    -- is how one whose creator lost its answer is found.
  , bridgeObligationAttachment ∷ obligation → AttachmentId
  , bridgeObligationHandle ∷ obligation → Word64
  , bridgeDischarge ∷ obligation → IO Discharged
    -- ^ Destroy the surface through Vulkan, from the calling thread, once.
  , bridgeRelease ∷ lease → STM LeaseAnswer
    -- ^ Close the lease to new constructions, whatever it answers, and say
    -- whether the instance may now be destroyed.
  }

-- | What a lease's release answered.
data LeaseAnswer
  = LeaseReleasable
    -- ^ Nothing is in flight or owed against it, and it admits nothing more.
  | LeaseInFlight
    -- ^ A surface creation admitted before the lease closed is still in its
    -- native call; it is finite, and what it leaves is then owed.
  | LeaseOwed
    -- ^ A surface is owed or uncertain against it. The instance must not be
    -- destroyed.
  deriving (Eq, Show)

-- | A discharge the bridge refused, reported as the uncertainty it is.
newtype DischargeNotPerformed = DischargeNotPerformed Text
  deriving (Eq, Show)

instance Exception DischargeNotPerformed

-- | The production bridge over a loader integration capability.
vulkanSurfaceBridge ∷ LoaderIntegration → SurfaceBridge SurfaceInstance SurfaceObligation
vulkanSurfaceBridge integration =
  SurfaceBridge
    { bridgeLease = leaseSurfaceInstance integration
    , bridgeAttach = \host window build →
        attachWindowGraphicsWithSurfaces host window (\access → build (fmap created . createWindowSurface access))
    , bridgeObligations = leasedObligations
    , bridgeObligationAttachment = obligationAttachment
    , bridgeObligationHandle = obligationHandle
    , bridgeDischarge = \obligation →
        dischargeSurfaceObligation obligation >>= \case
          SurfaceDestroyed → pure DischargeDone
          -- Only an earlier destruction that returned leaves this answer, so the
          -- surface is gone whoever destroyed it.
          DischargeRefused AlreadyDischarged → pure DischargeDone
          DischargeRefused refusal → uncertain (DischargeNotPerformed (Text.pack (show refusal)))
          DestructionUncertain failure → pure (DischargeUncertain failure)
    , bridgeRelease = \lease →
        releaseSurfaceInstance lease >>= \case
          InstanceReleasable → pure LeaseReleasable
          InstanceRetained standing
            | standingConstructing standing > 0 → pure LeaseInFlight
            | otherwise → pure LeaseOwed
    }
  where
    created = \case
      SurfaceCreated surface → CreatedLive (surfaceObligation surface)
      SurfaceUnpublished obligation reason → CreatedUnusable obligation (Text.pack (show reason))
      SurfaceCreationFailed result reports →
        CreationFailed ("the native call returned VkResult " <> Text.pack (show result) <> ", reporting " <> Text.pack (show reports))
      SurfaceRefused refusal → CreationFailed ("refused before any native effect: " <> Text.pack (show refusal))
    uncertain refusal = either DischargeUncertain (\() → DischargeDone) <$> tryWithContext (throwIO refusal)
