-- | The surface bridge: window surfaces created under a protected attachment,
-- and the obligations that destroy them.
--
-- This module names no Vulkan type and makes no native call of its own. The
-- two it needs — creating a surface for a live window and destroying one — are
-- the loader integration capability's, which the host's session took at entry
-- ("Hetoimasia.GLFW.Internal.Session"); the production capability comes from
-- the GLFW package's Vulkan interop component and the test seam scripts one. A
-- dispatchable instance crosses as the untyped pointer it is, and a surface as
-- the 64-bit value every supported Vulkan ABI gives a non-dispatchable handle,
-- held behind the opaque 'WindowSurface' and 'SurfaceObligation'.
--
-- = Where a surface may be created
--
-- Only through a 'SurfaceAccess', and an access is open only while one of two
-- things runs on the owner thread:
--
-- * the construction step of an attachment made through
--   'attachWindowGraphicsWithSurfaces', for exactly that attachment while it is
--   still registering; or
-- * an explicitly admitted replacement, 'replaceWindowSurface', on that same
--   attachment while it is still active and its window is not closing.
--
-- Every other request — an access whose step has returned, a retiring or
-- replaced attachment, a closing or ended window, a session that took no
-- capability, an instance leased through another capability, and an instance
-- whose lease has begun releasing — is refused with a 'SurfaceRefusal' before
-- any native effect. Admitting a replacement decides nothing about when one is
-- wanted, how old surfaces retire, or how often to retry: that policy is
-- VK-14's.
--
-- = The handoff record
--
-- Admission and the reservation are one transaction: it counts a hold on the
-- exact attachment and a construction on the instance's lease before the native
-- call. The window's native pointer is borrowed inside the bridge, for the call
-- alone, through the host's own window borrow, and never leaves it. The call is
-- made with asynchronous exceptions held off — a native call cannot be
-- interrupted part-way in any case — so its result is always recorded:
--
-- * success turns the reservation into one owned 'SurfaceObligation', which
--   keeps holding the attachment and the lease, and is recorded on the lease so
--   whoever owns the instance can always find it;
-- * a native failure releases the reservation and answers the @VkResult@ with
--   what GLFW reported ('SurfaceCreationFailed');
-- * an exception raised before a native result exists releases the
--   reservation and propagates as itself, never as a fabricated @VkResult@.
--
-- A created surface is published as a live 'WindowSurface' only if nothing has
-- changed since admission and GLFW reported nothing during the call; otherwise
-- the caller receives its obligation alone ('SurfaceUnpublished'). A
-- cancellation that arrives after the call is delivered only once the result is
-- recorded, so a caller that loses the answer to it has not lost the surface:
-- its obligation is still on the lease, and still holds the attachment.
--
-- = Obligations
--
-- 'dischargeSurfaceObligation' destroys the surface through the capability's
-- Vulkan destroy operation, never through GLFW, from any thread. It runs once:
-- a second discharge is refused. Only a destruction that returned releases the
-- attachment hold and the lease: one that raised is 'DestructionUncertain',
-- keeps both holds for good, and is never retried.
--
-- While any obligation or construction holds an attachment, the retirement
-- boundary refuses its 'DependentsDisposed' fact and downgrades a failed
-- construction's safe rollback to unsafe
-- ("Hetoimasia.Runtime.GLFW.Internal.Retirement"). So no cancellation,
-- timeout, or cleanup error can certify the attachment's retirement while one
-- of its surfaces may still exist.
--
-- = Instance leases
--
-- The instance's owner leases it to the bridge with 'leaseSurfaceInstance'
-- and asks to take it back with 'releaseSurfaceInstance'. The first release
-- request closes the lease to new constructions; the answer is
-- 'InstanceReleasable' only once no construction is in flight and every
-- obligation against it has been discharged and confirmed. Until then it is
-- 'InstanceRetained', and the instance must not be destroyed.
--
-- = State
--
-- +---------------------+-----------------+----------------------------------+--------+--------------------+-----------------------------+
-- | State               | Owner           | Readers and writers              | Thread | Lifetime           | Reset or disposal           |
-- +=====================+=================+==================================+========+====================+=============================+
-- | An access's phase   | The attach or   | Opened and closed around the     | Owner  | The access value   | Closed when its step ends,  |
-- |                     | replacement     | step; creation reads it          |        |                    | however it ends             |
-- |                     | that made it    |                                  |        |                    |                             |
-- +---------------------+-----------------+----------------------------------+--------+--------------------+-----------------------------+
-- | An instance lease   | The instance's  | Creation reserves and settles;   | Any;   | Until the owner    | Releasable only with        |
-- | and its obligations | owner           | discharge settles; release reads | STM    | releases it        | nothing in flight or owed   |
-- |                     |                 | and closes admission             |        |                    |                             |
-- +---------------------+-----------------+----------------------------------+--------+--------------------+-----------------------------+
-- | An obligation's     | Whoever holds   | Creation makes it owed; one      | Any;   | Until discharged,  | Discharged once; uncertain  |
-- | state               | it              | discharge settles it             | STM    | or for good        | is retained for good        |
-- +---------------------+-----------------+----------------------------------+--------+--------------------+-----------------------------+
module Hetoimasia.Runtime.GLFW.Internal.Surface
  ( -- * Instances
    SurfaceInstance
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

    -- * Operations
  , createSurfaceOperation
  , replaceSurfaceOperation
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, writeTVar)
import Control.Exception (ExceptionWithContext, SomeException, bracket_, displayException, finally, mask_, rethrowIO, tryWithContext, uninterruptibleMask_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Unique (Unique, newUnique)
import Data.Word (Word64)
import Foreign.Ptr (Ptr)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation)
import Hetoimasia.GLFW.Internal.Attachment
  ( Acknowledgement
  , AttachmentId
  , AttachmentPhase (..)
  , acknowledgedAttachment
  , attachmentWindow
  )
import Hetoimasia.GLFW.Internal.Capture (Reports (..), hasReports, settleStrayOwnerReports, takeOwnerReports)
import Hetoimasia.GLFW.Internal.Session
  ( IntegrationNative (..)
  , SessionIntegration
  , integrationIdentity
  , integrationNativeOperations
  , ownerOperation
  , sessionCapture
  , sessionIntegration
  )
import Hetoimasia.GLFW.Internal.Window (WindowResult (..), windowNativeHandle)
import Hetoimasia.GLFW.Window (WindowId, windowLocalIdentity)
import Hetoimasia.Runtime.GLFW.Internal
  ( AttachmentProtocol (..)
  , GraphicsAttachment
  , WindowHost
  , attachWindowGraphics
  , hostRetirementOf
  , hostSessionOf
  , hostWindowClosing
  , withHostWindow
  )
import Hetoimasia.Runtime.GLFW.Internal.Retirement
  ( HostRetirement
  , holdAttachment
  , releaseAttachmentHold
  , windowAttachmentState
  )
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Instances

-- | A Vulkan instance its owner has leased to the bridge.
--
-- It carries the instance's dispatchable handle, the identity of the loader
-- integration capability it was leased through, and the lease: what is in
-- flight against it, what is owed, and whether it still admits constructions.
data SurfaceInstance = SurfaceInstance
  { instanceKey ∷ !Unique
  , instanceIntegration ∷ !Unique
  , instanceHandle ∷ !(Ptr ())
  , instanceLease ∷ !(TVar Lease)
  }

instance Eq SurfaceInstance where
  left == right = instanceKey left == instanceKey right

data Lease = Lease
  { leaseAdmitting ∷ !Bool
  , leaseConstructing ∷ !Natural
  , leaseObligations ∷ !(Map Unique SurfaceObligation)
    -- ^ Every obligation created against the instance and not yet confirmed
    -- destroyed, uncertain ones included.
  }

-- | What a lease holds now.
data LeaseStanding = LeaseStanding
  { standingAdmitting ∷ !Bool
    -- ^ Whether a construction may still be admitted against it.
  , standingConstructing ∷ !Natural
    -- ^ Constructions admitted whose native call has not settled.
  , standingOwed ∷ !Natural
    -- ^ Obligations not yet discharged, and not uncertain.
  , standingUncertain ∷ !Natural
    -- ^ Obligations whose destruction raised. They are never retried, and
    -- they keep the lease for good.
  }
  deriving (Eq, Show)

-- | How a request to take an instance back was answered.
data InstanceRelease
  = InstanceReleasable
    -- ^ Nothing is in flight or owed against it, and it admits nothing more:
    -- its owner may destroy it.
  | InstanceRetained !LeaseStanding
    -- ^ Something is still in flight, owed, or uncertain. The lease no longer
    -- admits constructions, and the instance must not be destroyed.
  deriving (Eq, Show)

-- | Lease an instance to the bridge, through the loader integration
-- capability it was created with. The handle is the instance's dispatchable
-- handle; only a session that took that same capability creates surfaces
-- against it.
leaseSurfaceInstance ∷ SessionIntegration → Ptr () → IO SurfaceInstance
leaseSurfaceInstance integration handle = do
  key ← newUnique
  SurfaceInstance key (integrationIdentity integration) handle
    <$> newTVarIO (Lease True 0 Map.empty)

-- | Ask to take an instance back. The first request closes the lease to new
-- constructions, whatever it answers; see 'InstanceRelease'. Any thread may
-- ask, as often as it likes.
releaseSurfaceInstance ∷ SurfaceInstance → STM InstanceRelease
releaseSurfaceInstance lease = do
  modifyTVar' (instanceLease lease) (\held → held {leaseAdmitting = False})
  standing ← readLeaseStanding lease
  pure $
    if standingConstructing standing == 0 && standingOwed standing == 0 && standingUncertain standing == 0
      then InstanceReleasable
      else InstanceRetained standing

-- | What the lease holds now. Any thread may read it.
readLeaseStanding ∷ SurfaceInstance → STM LeaseStanding
readLeaseStanding lease = do
  held ← readTVar (instanceLease lease)
  states ← traverse (readTVar . obligationState) (Map.elems (leaseObligations held))
  pure
    LeaseStanding
      { standingAdmitting = leaseAdmitting held
      , standingConstructing = leaseConstructing held
      , standingOwed = count (/= ObligationUncertain) states
      , standingUncertain = count (== ObligationUncertain) states
      }
  where
    count wanted = fromIntegral . length . filter wanted

-- | Every obligation against the instance that has not been confirmed
-- destroyed, in no particular order. The instance's owner uses it to find an
-- obligation whose creator lost the answer to a cancellation.
leasedObligations ∷ SurfaceInstance → STM [SurfaceObligation]
leasedObligations lease = Map.elems . leaseObligations <$> readTVar (instanceLease lease)

-- ---------------------------------------------------------------------------
-- Access

-- | Where a surface may be created: one window of one protected host, and —
-- only while a construction step or an admitted replacement runs — the exact
-- attachment that step belongs to.
data SurfaceAccess = SurfaceAccess
  { accessHost ∷ !WindowHost
  , accessWindow ∷ !WindowId
  , accessPhase ∷ !(TVar AccessPhase)
  }

data AccessPhase
  = AccessClosed
  | AccessOpen !Acknowledgement !Purpose

data Purpose
  = InitialConstruction
    -- ^ The attachment is still registering.
  | AdmittedReplacement
    -- ^ The attachment is active, and stays so for as long as creation is
    -- admitted.
  deriving (Eq)

-- | Attach a graphics owner whose construction step may create surfaces.
--
-- It is 'attachWindowGraphics', unchanged in every answer, with the protocol
-- built from an access that is open for exactly the attachment being
-- constructed, and only while its 'protocolConstruct' runs. The access is
-- closed when the step ends, however it ends; the rollback, the retirement
-- step, and anything after them receive a closed one.
attachWindowGraphicsWithSurfaces
  ∷ HasCallStack ⇒ WindowHost → WindowId → (SurfaceAccess → AttachmentProtocol) → IO GraphicsAttachment
attachWindowGraphicsWithSurfaces host target build = do
  phase ← newTVarIO AccessClosed
  let protocol = build (SurfaceAccess host target phase)
      construct identity acknowledgement =
        bracket_
          (atomically (writeTVar phase (AccessOpen acknowledgement InitialConstruction)))
          (atomically (writeTVar phase AccessClosed))
          (protocolConstruct protocol identity acknowledgement)
  attachWindowGraphics host target protocol {protocolConstruct = construct}

-- | How a request to replace a surface was answered.
data Replacement a
  = ReplacementRan !a
    -- ^ The replacement was admitted and its body ran with an open access.
  | ReplacementRefused !SurfaceRefusal
    -- ^ Refused before the body ran.
  deriving (Eq, Show)

-- | Run an explicitly admitted replacement-surface operation on an existing,
-- still-live attachment, on the owner thread.
--
-- It is admitted only while the acknowledgement's attachment is the one its
-- window holds, that attachment is active rather than registering or retiring,
-- and the window is not closing; otherwise it is refused before the body runs.
-- The body receives an access open for that attachment alone, closed again when
-- it ends however it ends, and every surface it creates is admitted afresh.
-- Whether and when a replacement is wanted, how the surface it replaces
-- retires, and how often to try again are the caller's policy.
--
-- Refuses other threads with 'Hetoimasia.GLFW.Session.NotSessionOwner'.
replaceWindowSurface ∷ WindowHost → Acknowledgement → (SurfaceAccess → IO a) → IO (Replacement a)
replaceWindowSurface host acknowledgement body =
  ownerOperation (hostSessionOf host) replaceSurfaceOperation (windowIdentifiers window) $ do
    phase ← newTVarIO (AccessOpen acknowledgement AdmittedReplacement)
    let access = SurfaceAccess host window phase
    admitted ← atomically (admission access)
    case admitted of
      Left refusal → do
        atomically (writeTVar phase AccessClosed)
        pure (ReplacementRefused refusal)
      Right _ →
        -- One masked close covers the body and the answer's handoff alike, so
        -- no cancellation between the two can leave the access open.
        (ReplacementRan <$> body access) `finally` atomically (writeTVar phase AccessClosed)
  where
    window = attachmentWindow (acknowledgedAttachment acknowledgement)

-- ---------------------------------------------------------------------------
-- Creating surfaces

-- | Why a surface was not created. Every one is answered before any native
-- effect.
data SurfaceRefusal
  = SurfaceAccessClosed
    -- ^ No construction step or admitted replacement is running for this
    -- access.
  | SurfaceHostUnprotected
    -- ^ The host owns no retirement state, so nothing could hold a surface.
  | SurfaceSessionNotLoaderAware
    -- ^ The host's session took no loader integration capability.
  | SurfaceForeignInstance
    -- ^ The instance was leased through another capability than the one the
    -- host's session took.
  | SurfaceInstanceReleasing
    -- ^ The instance's owner has asked for it back.
  | SurfaceWindowClosing
    -- ^ The window's close protocol has begun.
  | SurfaceWindowUnavailable
    -- ^ The host no longer holds the window.
  | SurfaceAttachmentNotAdmitting !(Maybe AttachmentPhase)
    -- ^ The access's attachment is not the one its window holds in the phase
    -- this access admits: it has begun retiring, it was replaced, or it has
    -- gone. Carries the phase of whatever the window holds now.
  deriving (Eq, Show)

-- | Why a created surface was handed back as its obligation alone.
data UnpublishedReason
  = CreatedWithReports !Reports
    -- ^ GLFW reported errors during a call that nonetheless returned a surface.
  | CreatedAfterAdmissionEnded !SurfaceRefusal
    -- ^ Something that would now refuse the creation — the window began closing,
    -- the attachment began retiring, the step ended — changed during the call.
  | CreatedThenRaised !(ExceptionWithContext SomeException)
    -- ^ The call returned a surface and something after it in the bridge
    -- raised; the failure is kept here rather than losing the surface.

instance Show UnpublishedReason where
  showsPrec precedence = \case
    CreatedWithReports reports → showParen (precedence > 10) (showString "CreatedWithReports " . showsPrec 11 reports)
    CreatedAfterAdmissionEnded refusal →
      showParen (precedence > 10) (showString "CreatedAfterAdmissionEnded " . showsPrec 11 refusal)
    CreatedThenRaised failure →
      showParen (precedence > 10) (showString "CreatedThenRaised " . showsPrec 11 (displayException failure))

-- | How a request to create a surface was answered.
data SurfaceCreation
  = SurfaceCreated !WindowSurface
    -- ^ A live surface bound to the attachment and the instance, carrying its
    -- one destruction obligation.
  | SurfaceUnpublished !SurfaceObligation !UnpublishedReason
    -- ^ A surface was created and must not be used: only its obligation is
    -- handed back, for its holder to discharge.
  | SurfaceCreationFailed !Int !Reports
    -- ^ The native call returned this @VkResult@ and created nothing, with what
    -- GLFW reported during it.
  | SurfaceRefused !SurfaceRefusal
    -- ^ Refused before any native effect.

instance Show SurfaceCreation where
  showsPrec precedence = \case
    SurfaceCreated surface → showParen (precedence > 10) (showString "SurfaceCreated " . showsPrec 11 surface)
    SurfaceUnpublished obligation reason →
      showParen (precedence > 10) (showString "SurfaceUnpublished " . showsPrec 11 obligation . showChar ' ' . showsPrec 11 reason)
    SurfaceCreationFailed result reports →
      showParen (precedence > 10) (showString "SurfaceCreationFailed " . showsPrec 11 result . showChar ' ' . showsPrec 11 reports)
    SurfaceRefused refusal → showParen (precedence > 10) (showString "SurfaceRefused " . showsPrec 11 refusal)

-- | A live window surface. It is the 64-bit handle, the attachment and
-- instance it belongs to, and its one destruction obligation.
newtype WindowSurface = WindowSurface SurfaceObligation

instance Show WindowSurface where
  showsPrec precedence (WindowSurface obligation) =
    showParen (precedence > 10) (showString "WindowSurface " . showsPrec 11 obligation)

-- | The surface's non-dispatchable handle, for the graphics owner's own Vulkan
-- calls. Destroying it belongs to its obligation alone.
surfaceHandle ∷ WindowSurface → Word64
surfaceHandle (WindowSurface obligation) = obligationSurface obligation

surfaceAttachment ∷ WindowSurface → AttachmentId
surfaceAttachment (WindowSurface obligation) = obligationTarget obligation

surfaceObligation ∷ WindowSurface → SurfaceObligation
surfaceObligation (WindowSurface obligation) = obligation

-- | Create a window surface against a leased instance, on the owner thread.
--
-- See this module's description for admission, the handoff record, and what
-- each answer means. Refuses other threads with
-- 'Hetoimasia.GLFW.Session.NotSessionOwner' and an ended session with
-- 'Hetoimasia.GLFW.Session.SessionEnded', before any native effect.
createWindowSurface ∷ SurfaceAccess → SurfaceInstance → IO SurfaceCreation
createWindowSurface access lease =
  ownerOperation session createSurfaceOperation (windowIdentifiers (accessWindow access)) $ mask_ $ do
    admitted ← atomically (admission access >>= either (pure . Left) reserve)
    case admitted of
      Left refusal → pure (SurfaceRefused refusal)
      Right (retirement, target, integration) → create retirement target (integrationNativeOperations integration)
  where
    session = hostSessionOf (accessHost access)
    capture = sessionCapture session

    reserve (retirement, target, integration)
      | integrationIdentity integration /= instanceIntegration lease = pure (Left SurfaceForeignInstance)
      | otherwise = do
          held ← readTVar (instanceLease lease)
          if not (leaseAdmitting held)
            then pure (Left SurfaceInstanceReleasing)
            else do
              writeTVar (instanceLease lease) held {leaseConstructing = leaseConstructing held + 1}
              holdAttachment retirement target
              pure (Right (retirement, target, integration))

    unreserve retirement target = do
      modifyTVar' (instanceLease lease) (\held → held {leaseConstructing = leaseConstructing held - 1})
      releaseAttachmentHold retirement target

    create retirement target operations = do
      -- What the native call answered is recorded before anything else can
      -- run, so no later failure can lose a created surface.
      settled ← newIORef Nothing
      attempted ←
        tryWithContext $
          withHostWindow (accessHost access) (accessWindow access) $ \window → uninterruptibleMask_ $ do
            settleStrayOwnerReports capture
            answered ← integrationCreateSurface operations (instanceHandle lease) (windowNativeHandle window)
            writeIORef settled (Just answered)
            reports ← takeOwnerReports capture
            pure (answered, reports)
      native ← readIORef settled
      case (native, attempted) of
        (Just (result, handle), outcome)
          | result == vkSuccess && handle /= 0 → do
              obligation ← owe retirement target operations handle
              standing ← atomically (admission access)
              pure $ case (outcome, standing) of
                (Left failure, _) → SurfaceUnpublished obligation (CreatedThenRaised failure)
                (_, Left refusal) → SurfaceUnpublished obligation (CreatedAfterAdmissionEnded refusal)
                (Right (WindowAvailable (_, reports)), _)
                  | hasReports reports → SurfaceUnpublished obligation (CreatedWithReports reports)
                _ → SurfaceCreated (WindowSurface obligation)
          | otherwise → do
              atomically (unreserve retirement target)
              pure $ case outcome of
                Right (WindowAvailable (_, reports)) → SurfaceCreationFailed result reports
                _ → SurfaceCreationFailed result (Reports [] 0 0)
        (Nothing, Left failure) → do
          -- No native result exists: nothing was created, and the failure is
          -- the caller's to see as itself.
          atomically (unreserve retirement target)
          rethrowIO failure
        (Nothing, Right (WindowEnded _)) → do
          atomically (unreserve retirement target)
          pure (SurfaceRefused SurfaceWindowUnavailable)
        (Nothing, Right (WindowAvailable _)) → do
          -- Unreachable: an available window's call always records its answer.
          atomically (unreserve retirement target)
          pure (SurfaceRefused SurfaceWindowUnavailable)

    owe retirement target operations handle = do
      key ← newUnique
      state ← newTVarIO ObligationOwed
      let obligation =
            SurfaceObligation
              { obligationKey = key
              , obligationTarget = target
              , obligationLease = lease
              , obligationSurface = handle
              , obligationRetirement = retirement
              , obligationDestroy = integrationDestroySurface operations (instanceHandle lease) handle
              , obligationState = state
              }
      atomically $
        modifyTVar' (instanceLease lease) $ \held →
          held
            { leaseConstructing = leaseConstructing held - 1
            , leaseObligations = Map.insert key obligation (leaseObligations held)
            }
      pure obligation

-- | @VK_SUCCESS@.
vkSuccess ∷ Int
vkSuccess = 0

-- | Whether this access may create a surface now: its step is running, its
-- attachment is the window's and in the phase the access admits, the window is
-- held and not closing, and the host's session took a capability. Answers the
-- retirement state, the attachment, and the capability.
admission ∷ SurfaceAccess → STM (Either SurfaceRefusal (HostRetirement, AttachmentId, SessionIntegration))
admission access = do
  phase ← readTVar (accessPhase access)
  case phase of
    AccessClosed → pure (Left SurfaceAccessClosed)
    AccessOpen acknowledgement purpose → case (hostRetirementOf host, sessionIntegration (hostSessionOf host)) of
      (Nothing, _) → pure (Left SurfaceHostUnprotected)
      (_, Nothing) → pure (Left SurfaceSessionNotLoaderAware)
      (Just retirement, Just integration) → do
        closing ← hostWindowClosing host (accessWindow access)
        occupant ← windowAttachmentState retirement (accessWindow access)
        let target = acknowledgedAttachment acknowledgement
            wanted = case purpose of
              InitialConstruction → AttachmentRegistering
              AdmittedReplacement → AttachmentActive
        pure $ case (closing, occupant) of
          (Nothing, _) → Left SurfaceWindowUnavailable
          (Just True, _) → Left SurfaceWindowClosing
          (Just False, Just (holder, holderPhase, _))
            | holder == target && holderPhase == wanted → Right (retirement, target, integration)
            | otherwise → Left (SurfaceAttachmentNotAdmitting (Just holderPhase))
          (Just False, Nothing) → Left (SurfaceAttachmentNotAdmitting Nothing)
  where
    host = accessHost access

-- ---------------------------------------------------------------------------
-- Obligations

-- | The one owned obligation to destroy one created surface. It holds its
-- attachment and its instance's lease until a destruction is confirmed.
data SurfaceObligation = SurfaceObligation
  { obligationKey ∷ !Unique
  , obligationTarget ∷ !AttachmentId
  , obligationLease ∷ !SurfaceInstance
  , obligationSurface ∷ !Word64
  , obligationRetirement ∷ !HostRetirement
  , obligationDestroy ∷ IO ()
  , obligationState ∷ !(TVar ObligationState)
  }

instance Eq SurfaceObligation where
  left == right = obligationKey left == obligationKey right

instance Show SurfaceObligation where
  showsPrec precedence obligation =
    showParen (precedence > 10) $
      showString "SurfaceObligation "
        . showsPrec 11 (obligationTarget obligation)
        . showChar ' '
        . showsPrec 11 (obligationSurface obligation)

-- | Where one obligation stands.
data ObligationState
  = ObligationOwed
  | ObligationDischarging
    -- ^ A discharge has claimed it and its destruction is running.
  | ObligationDischarged
    -- ^ Its destruction returned; its holds have ended.
  | ObligationUncertain
    -- ^ Its destruction raised. It keeps its holds for good and is never
    -- retried.
  deriving (Eq, Show)

-- | The attachment this obligation holds.
obligationAttachment ∷ SurfaceObligation → AttachmentId
obligationAttachment = obligationTarget

-- | The surface this obligation destroys.
obligationHandle ∷ SurfaceObligation → Word64
obligationHandle = obligationSurface

-- | Where this obligation stands now. Any thread may read it.
readObligationState ∷ SurfaceObligation → STM ObligationState
readObligationState = readTVar . obligationState

-- | Why a discharge did nothing.
data DischargeRefusal
  = AlreadyDischarged
  | AlreadyDischarging
  | DestructionWasUncertain
    -- ^ An earlier destruction raised, and uncertain destruction is never
    -- retried.
  deriving (Eq, Show)

-- | How a discharge went.
data Discharge
  = SurfaceDestroyed
    -- ^ The destruction returned. The attachment hold and the lease's are
    -- released, and the attachment's retirement may progress.
  | DischargeRefused !DischargeRefusal
  | DestructionUncertain !(ExceptionWithContext SomeException)
    -- ^ The destruction raised. Both holds are kept for good.

instance Show Discharge where
  showsPrec precedence = \case
    SurfaceDestroyed → showString "SurfaceDestroyed"
    DischargeRefused refusal → showParen (precedence > 10) (showString "DischargeRefused " . showsPrec 11 refusal)
    DestructionUncertain _ → showString "DestructionUncertain"

-- | Destroy the obligation's surface through Vulkan, from any thread, once.
--
-- The claim, the destruction, and the settlement run with asynchronous
-- exceptions held off, so a cancellation arriving meanwhile is delivered after
-- the outcome is recorded and can neither lose a destruction that happened nor
-- invent one that did not.
dischargeSurfaceObligation ∷ SurfaceObligation → IO Discharge
dischargeSurfaceObligation obligation = uninterruptibleMask_ $ do
  claimed ← atomically $
    readTVar (obligationState obligation) >>= \case
      ObligationOwed → Nothing <$ writeTVar (obligationState obligation) ObligationDischarging
      ObligationDischarging → pure (Just AlreadyDischarging)
      ObligationDischarged → pure (Just AlreadyDischarged)
      ObligationUncertain → pure (Just DestructionWasUncertain)
  case claimed of
    Just refusal → pure (DischargeRefused refusal)
    Nothing → do
      destroyed ← tryWithContext (obligationDestroy obligation)
      case destroyed of
        Right () → do
          atomically $ do
            writeTVar (obligationState obligation) ObligationDischarged
            modifyTVar' (instanceLease (obligationLease obligation)) $ \held →
              held {leaseObligations = Map.delete (obligationKey obligation) (leaseObligations held)}
            releaseAttachmentHold (obligationRetirement obligation) (obligationTarget obligation)
          pure SurfaceDestroyed
        Left failure → do
          atomically (writeTVar (obligationState obligation) ObligationUncertain)
          pure (DestructionUncertain failure)

-- ---------------------------------------------------------------------------
-- Operations

createSurfaceOperation, replaceSurfaceOperation ∷ Operation
createSurfaceOperation = operation "create window surface"
replaceSurfaceOperation = operation "replace window surface"

windowIdentifiers ∷ WindowId → [(Text, Text)]
windowIdentifiers window = [("window", Text.pack (show (windowLocalIdentity window)))]
