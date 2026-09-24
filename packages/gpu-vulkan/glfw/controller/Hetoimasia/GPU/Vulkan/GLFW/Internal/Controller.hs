{-# LANGUAGE RankNTypes #-}

-- | The Vulkan session controller: VK-7's operations for VK-18's supervised
-- graphics owner, and the main-thread handover that brings each window's
-- surface to it.
--
-- It composes three delivered contracts and replaces none of them:
--
-- * the roots ("Hetoimasia.GPU.Vulkan.Native.Roots"), which own the instance,
--   the explicit messenger, the one shared device and each target's surface,
--   in child-before-parent order;
-- * the graphics owner ("Hetoimasia.Runtime.GLFW"), which runs these
--   operations on its own thread and owns the handoffs, the cancellation and
--   the D-33 exit; and
-- * the surface bridge ("Hetoimasia.GLFW.Vulkan", through
--   "Hetoimasia.GPU.Vulkan.GLFW.Internal.Bridge"), which creates each surface
--   through GLFW on the main thread inside its attachment's construction and
--   destroys it through Vulkan from the thread that holds its obligation.
--
-- = Threads
--
-- Every operation in 'controllerOperations' runs on the graphics owner's
-- thread, and so does every native call the roots make and every surface
-- destruction: the controller makes no GLFW call. The only thing that runs on
-- the main thread is 'handOverVulkanTarget', whose attachment's construction
-- step creates the surface through GLFW and deposits what it created for the
-- owner to take.
--
-- = A surface's way to the owner
--
-- 1. The main thread attaches the window with a protocol whose construction
--    step first registers the attachment with the owner's ledger — exactly
--    'graphicsTargetProtocol''s — then creates the surface against the
--    instance's lease, and deposits the result under the attachment's
--    identity. From the moment the native call returns, the surface's
--    obligation holds the attachment and the lease, so the window cannot be
--    released and the instance cannot be destroyed while it exists.
-- 2. The attachment is announced to the owner through its bounded port.
-- 3. The owner's construction takes the deposit. A live surface is offered to
--    the roots: admitted, it is a target; refused — the session's queue family
--    cannot present to it, or admission has closed — it is destroyed there
--    and then, on the owner's thread, and the target settles as a verified
--    rollback with the structured reason retained ('readTargetRejection').
--    An unusable surface is destroyed the same way. A deposit that never
--    arrived — its creator lost the answer to a cancellation — is found on
--    the lease instead, and destroyed.
--
-- So the owner receives either the live surface or its destruction
-- obligation, and nothing can end a hold on the attachment or the instance
-- before one of the two has been settled: a construction that raised leaves
-- the obligation on the lease, where the target's retirement finds it.
--
-- = Destruction
--
-- A target's retirement destroys its surface, through the roots when they
-- admitted it and directly when they did not, and raises — manufacturing no
-- evidence — when that destruction was uncertain. Whole-owner retirement
-- closes the lease, destroys every surface no target holds (those whose
-- announcement never reached the owner), and destroys the device; whole-owner
-- destruction waits for any surface creation still in its native call, settles
-- what it left, and destroys the explicit messenger and then the instance —
-- only once the lease is releasable. What any of it cannot verify retains
-- everything above it.
module Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller
  ( -- * The controller
    VulkanController
  , newVulkanController
  , controllerOperations
  , supplyInstanceExtensions

    -- * Readiness
  , Readiness (..)
  , readReadiness

    -- * Handing targets over
  , VulkanHandover (..)
  , handOverVulkanTarget

    -- * Observation
  , VulkanRejection (..)
  , readTargetRejection
  , rejectionsRetained
  , readVulkanTargets
  , readVulkanRoots
  , readVulkanModel

    -- * The composition
  , VulkanHostConfig (..)
  , vulkanHostConfig
  , VulkanHost (..)
  , withVulkanOwnerHostOver
  , NativeObserver (..)
  , noObserver

    -- * Failures
  , InstanceExtensionsMissing (..)
  , OrphanSurfacesUncertain (..)
  , LeaseRetained (..)
  , RootsOutlivedHost (..)
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry, stateTVar, writeTVar)
import Control.Exception
  ( Exception (displayException)
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , fromException
  , mask
  , mask_
  , rethrowIO
  , throwIO
  , tryWithContext
  )
import Control.Monad (unless, void, when)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as Char8
import Data.Foldable (for_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import Data.List (nubBy)
import Data.Function (on)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Foreign.Ptr (Ptr)
import Numeric (showHex)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.Foundation.Messaging.Payload (Prepared)
import Hetoimasia.Foundation.Resource (Scoped)
import Hetoimasia.Foundation.Time (MonotonicSource)
import Hetoimasia.GLFW.Session (Session, SessionConfig)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.GPU.Model (GpuModel)
import Hetoimasia.GPU.Model.Budget (Budgets)
import Hetoimasia.GPU.Model.Identity (TargetClass (..), TargetId)
import Hetoimasia.GPU.Vulkan.Diagnostics
  ( CaptureConfig
  , DiagnosticCapture
  , DiagnosticVerdict
  , Quiesced
  , afterLastCallback
  , retainStorage
  , withDiagnosticCapture
  )
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Bridge
import Hetoimasia.GPU.Vulkan.Native.Profile (InstancePlan (..), InstanceRequest (..), TargetRejection (..))
import Hetoimasia.GPU.Vulkan.Native.Roots
  ( RootOps (..)
  , RootStanding (..)
  , RootTargetView (..)
  , Roots
  , RootsNotStarted (..)
  , RootsView (..)
  , SurfaceDestruction (..)
  , TargetSurface (..)
  , admitRootTarget
  , checkRoots
  , destroyRoots
  , newRoots
  , readRootTargets
  , readRootsInstance
  , readRootsModel
  , readRootsQuiesced
  , readRootsView
  , retireRootTarget
  , retireRoots
  , startRoots
  )
import Hetoimasia.Runtime.GLFW
  ( AttachmentId
  , AttachmentProtocol (..)
  , EventAdmission (..)
  , GraphicsAttachment (..)
  , GraphicsOperations (..)
  , GraphicsOwner
  , GraphicsOwnerConfig
  , GraphicsRefusal
  , GraphicsService
  , HostConfig (..)
  , NextDeadline (..)
  , OwnerDestroyed
  , OwnerReady
  , OwnerRetire (..)
  , OwnerRetired
  , RolledBack
  , Stage (CustodyRegistered)
  , TargetHandoff (..)
  , TargetRetire (..)
  , TargetRetired
  , TargetStart (..)
  , WindowHost
  , announceGraphicsTarget
  , custodyOf
  , graphicsAttachment
  , graphicsOwnerConfig
  , graphicsTargetProtocol
  , noStepWork
  , ownerDestroyed
  , ownerHandoff
  , ownerReady
  , ownerRetired
  , rollbackEvidence
  , targetEventsOpen
  , targetEvidence
  , targetRetired
  , windowGraphicsService
  , withGraphicsOwnerHostIn
  )

-- ---------------------------------------------------------------------------
-- The controller

-- | One graphics session's controller: its roots, the surface bridge, and the
-- handoff state between the main thread and the owner.
--
-- Its native handle types and the bridge's are hidden, so production and the
-- headless examples drive the same value through the same functions.
data VulkanController = ∀ inst msgr phys dev lease obligation. VulkanController !(State inst msgr phys dev lease obligation)

data State inst msgr phys dev lease obligation = State
  { stateRoots ∷ !(Roots Quiesced inst msgr phys dev)
  , statePointer ∷ !(inst → Ptr ())
  , stateBridge ∷ !(SurfaceBridge lease obligation)
  , stateLayers ∷ ![ByteString]
  , stateRequest ∷ !(TVar (Maybe InstanceRequest))
    -- ^ Supplied on the main thread from the session, before the owner starts.
  , stateLease ∷ !(TVar (Lease lease))
  , stateDeposits ∷ !(TVar (Map AttachmentId (Deposit obligation)))
    -- ^ Written by a construction step on the main thread; taken by the
    -- owner's construction or retirement of that attachment.
  , stateTargets ∷ !(TVar (Map AttachmentId TargetId))
    -- ^ The owner thread's alone: which roots target each attachment is.
  , stateRejections ∷ !(TVar (Map AttachmentId VulkanRejection))
  }

data Lease lease
  = LeasePending
  | LeaseReady !lease
  | LeaseFailed !Text

-- | What a construction step created, and the designation the application
-- gave the target.
data Deposit obligation = Deposit !TargetClass !(Created obligation)

-- | A controller over a native layer and a surface bridge.
--
-- The layers are the ones the instance is asked to enable, each of which the
-- loader must offer. The clock is the one the roots' model reads, which must
-- be the host's.
newVulkanController
  ∷ RootOps Quiesced inst msgr phys dev
  → (inst → Ptr ())
  → SurfaceBridge lease obligation
  → [ByteString]
  → Budgets
  → MonotonicSource
  → IO VulkanController
newVulkanController ops pointer bridge layers budgets clock = do
  roots ← newRoots ops budgets clock
  fmap VulkanController $
    State roots pointer bridge layers
      <$> newTVarIO Nothing
      <*> newTVarIO LeasePending
      <*> newTVarIO Map.empty
      <*> newTVarIO Map.empty
      <*> newTVarIO Map.empty

-- | Supply the instance extensions the window system requires, copied from
-- the loader-aware session on the main thread. The owner's startup reads
-- them; it is refused without them.
supplyInstanceExtensions ∷ VulkanController → [ByteString] → STM ()
supplyInstanceExtensions (VulkanController state) required =
  writeTVar (stateRequest state) (Just (InstanceRequest required (stateLayers state)))

-- | The owner started before the session's instance extensions were supplied.
data InstanceExtensionsMissing = InstanceExtensionsMissing
  deriving (Eq, Show)

instance Exception InstanceExtensionsMissing

-- | Surfaces no target held could not all be destroyed, so the device and
-- the instance are retained.
newtype OrphanSurfacesUncertain = OrphanSurfacesUncertain Int
  deriving (Eq, Show)

instance Exception OrphanSurfacesUncertain

-- | The instance's lease still owes a surface, so the instance is retained.
newtype LeaseRetained = LeaseRetained LeaseAnswer
  deriving (Eq, Show)

instance Exception LeaseRetained

-- | The host returned while the instance was not destroyed, which its exit
-- does not permit. The capture's storage is retained rather than freed under
-- a messenger that may still name it.
newtype RootsOutlivedHost = RootsOutlivedHost RootStanding
  deriving (Eq, Show)

instance Exception RootsOutlivedHost

-- ---------------------------------------------------------------------------
-- Readiness

-- | Whether the owner's startup has leased the instance to the surface
-- bridge, so windows can be handed over.
data Readiness
  = RootsPending
  | RootsReady
  | RootsFailed !Text
    -- ^ The owner's startup failed with this; it retires what it created.
  deriving (Eq, Show)

readReadiness ∷ VulkanController → STM Readiness
readReadiness (VulkanController state) =
  readTVar (stateLease state) >>= \case
    LeasePending → pure RootsPending
    LeaseReady _ → pure RootsReady
    LeaseFailed reason → pure (RootsFailed reason)

-- ---------------------------------------------------------------------------
-- The owner's operations

-- | The operations the graphics owner runs, on its own thread.
--
-- The progress step raises a latched device loss and otherwise reports no
-- work and no demand: this slice records and submits nothing.
controllerOperations ∷ VulkanController → GraphicsOperations scene
controllerOperations (VulkanController state) =
  GraphicsOperations
    { graphicsStartOwner = \_ → startOwner state
    , graphicsConstructTarget = constructTarget state
    , graphicsStep = \_ → noStepWork <$ checkRoots (stateRoots state)
    , graphicsNextDeadline = pure NoOwnerDemand
    , graphicsRetireTarget = retireTarget state
    , graphicsRetireOwner = retireOwner state
    , graphicsDestroyOwner = \_ → destroyOwner state
    }


startOwner ∷ State inst msgr phys dev lease obligation → IO OwnerReady
startOwner state = do
  attempted ← tryWithContext $ do
    request ← readTVarIO (stateRequest state) >>= maybe (throwIO InstanceExtensionsMissing) pure
    plan ← startRoots roots request
    created ← atomically (readRootsInstance roots) >>= maybe (throwIO RootsNotStarted) pure
    lease ← bridgeLease (stateBridge state) (statePointer state created)
    atomically (writeTVar (stateLease state) (LeaseReady lease))
    pure plan
  case attempted of
    Left (failure ∷ ExceptionWithContext SomeException) → do
      atomically (writeTVar (stateLease state) (LeaseFailed (Text.pack (displayException failure))))
      rethrowIO failure
    Right plan →
      pure . ownerReady $
        "created the instance with "
          <> listNames (planInstanceExtensions plan)
          <> (if planPortabilityEnumeration plan then ", portability enumeration on" else "")
          <> ", and its explicit messenger; leased it to the surface bridge"
  where
    roots = stateRoots state

-- | Take one attachment's surface from the main thread's deposit, and settle
-- its handoff: admitted, or destroyed and rolled back.
constructTarget ∷ State inst msgr phys dev lease obligation → TargetStart → IO TargetHandoff
constructTarget state start = do
  deposit ← atomically (stateTVar (stateDeposits state) (\held → (Map.lookup attachment held, Map.delete attachment held)))
  readTVarIO (stateLease state) >>= \case
    LeaseReady lease → do
      listed ← atomically (obligationsOf bridge lease attachment)
      case deposit of
        Just (Deposit classification (CreatedLive obligation)) → do
          -- Admission and the record of which target it made are one masked
          -- step: a cancellation between them would leave the roots owning a
          -- surface no retirement could name. The native calls inside are
          -- uninterruptible in any case.
          admitted ← mask_ $ do
            answer ← admitRootTarget (stateRoots state) classification (TargetSurface (handleOf obligation) (destruction bridge obligation))
            for_ answer $ \target → atomically (modifyTVar' (stateTargets state) (Map.insert attachment target))
            pure answer
          case admitted of
            Right target → do
              view ← atomically (readRootsView (stateRoots state))
              pure . TargetConstructed . targetEvidence $
                "admitted "
                  <> tshow target
                  <> " ("
                  <> describeClass classification
                  <> ") on surface "
                  <> hex (handleOf obligation)
                  <> maybe "" (" of device " <>) (viewDeviceName view)
                  <> maybe "" ((", queue family " <>) . tshow) (viewQueueFamily view)
            Left refused → reject state attachment (RejectedByRoots refused) (distinct (obligation : listed))
        Just (Deposit _ (CreatedUnusable obligation reason)) → reject state attachment (SurfaceUnusable reason) (distinct (obligation : listed))
        Just (Deposit _ (CreationFailed reason)) → reject state attachment (SurfaceNotCreated reason) listed
        Nothing → reject state attachment SurfaceNotHandedOver listed
    -- No lease means no surface could have been created against one.
    _ → reject state attachment (RejectedByRoots TargetAdmissionClosed) []
  where
    bridge = stateBridge state
    attachment = startingTarget start
    handleOf = bridgeObligationHandle bridge
    distinct = nubBy ((==) `on` handleOf)

-- | Destroy everything an attachment left and settle it as a verified
-- rollback — or, if a destruction was uncertain, as a partial construction the
-- owner keeps and retires.
reject
  ∷ State inst msgr phys dev lease obligation
  → AttachmentId
  → VulkanRejection
  → [obligation]
  → IO TargetHandoff
reject state attachment reason obligations = do
  outcomes ← mapM (bridgeDischarge (stateBridge state)) obligations
  atomically (retainRejection state attachment reason)
  let uncertain = length [() | DischargeUncertain _ ← outcomes]
      destroyed = length obligations - uncertain
  pure $
    if uncertain == 0
      then TargetRolledBack (rollbackEvidence (describeRejection reason <> "; destroyed " <> plural destroyed "surface"))
      else
        TargetPartial . targetEvidence $
          describeRejection reason <> "; destroying " <> plural uncertain "surface" <> " did not complete, so it is retained"

-- | Retire one target: destroy its surface, through the roots when they
-- admitted it, and whatever else the lease still lists for its attachment.
retireTarget ∷ State inst msgr phys dev lease obligation → TargetRetire → IO TargetRetired
retireTarget state retiring = do
  mapped ← atomically (Map.lookup attachment <$> readTVar (stateTargets state))
  retiredRoot ← case mapped of
    Just target → mask_ $ do
      -- Raises, and keeps the record and this mapping, if the destruction was
      -- uncertain: the owner then never offers this again.
      retireRootTarget (stateRoots state) target
      atomically (modifyTVar' (stateTargets state) (Map.delete attachment))
      pure ("destroyed the surface of " <> tshow target)
    Nothing → pure "the roots held no target for it"
  -- A deposit the owner never took, and any obligation whose answer was lost.
  _ ← atomically (stateTVar (stateDeposits state) (\held → (Map.lookup attachment held, Map.delete attachment held)))
  swept ← readTVarIO (stateLease state) >>= \case
    LeaseReady lease → do
      left ← atomically (obligationsOf (stateBridge state) lease attachment)
      outcomes ← mapM (bridgeDischarge (stateBridge state)) left
      case [failure | DischargeUncertain failure ← outcomes] of
        failure : _ → rethrowIO failure
        [] → pure (length left)
    _ → pure 0
  pure . targetRetired $
    retiredRoot <> (if swept > 0 then "; destroyed " <> plural swept "further surface" else "")
  where
    attachment = retiringTarget retiring

-- | Retire the owner: close the lease, destroy every surface no target held,
-- and destroy the device.
retireOwner ∷ State inst msgr phys dev lease obligation → OwnerRetire → IO OwnerRetired
retireOwner state retiring = do
  orphaned ← readTVarIO (stateLease state) >>= \case
    LeaseReady lease → do
      held ← atomically $ do
        -- Closing it first means nothing new is created against it.
        _ ← bridgeRelease bridge lease
        Map.keys <$> readTVar (stateTargets state)
      listed ← atomically (bridgeObligations bridge lease)
      let exempt = held <> retiringUnverified retiring
          orphans = [obligation | obligation ← listed, bridgeObligationAttachment bridge obligation `notElem` exempt]
      outcomes ← mapM (bridgeDischarge bridge) orphans
      let uncertain = length [() | DischargeUncertain _ ← outcomes]
      when (uncertain > 0) (throwIO (OrphanSurfacesUncertain uncertain))
      pure (length orphans)
    _ → pure 0
  atomically (writeTVar (stateDeposits state) Map.empty)
  device ← retireRoots (stateRoots state)
  pure . ownerRetired $
    (if orphaned > 0 then "destroyed " <> plural orphaned "surface" <> " no target held; " else "") <> device
  where
    bridge = stateBridge state

-- | Destroy the owner's shared state: settle the lease, then destroy the
-- explicit messenger and the instance.
destroyOwner ∷ State inst msgr phys dev lease obligation → IO OwnerDestroyed
destroyOwner state = do
  late ← readTVarIO (stateLease state) >>= \case
    LeaseReady lease → do
      -- A creation admitted before the lease closed may still be in its
      -- native call on the main thread. It is finite and owes the owner
      -- nothing, so this waits for it rather than destroying the instance
      -- under it, and then destroys what it left.
      atomically (bridgeRelease bridge lease >>= \answer → when (answer == LeaseInFlight) retry)
      held ← atomically (Map.keys <$> readTVar (stateTargets state))
      listed ← atomically (bridgeObligations bridge lease)
      let late = [obligation | obligation ← listed, bridgeObligationAttachment bridge obligation `notElem` held]
      _ ← mapM (bridgeDischarge bridge) late
      answer ← atomically (bridgeRelease bridge lease)
      unless (answer == LeaseReleasable) (throwIO (LeaseRetained answer))
      pure (length late)
    _ → pure 0
  proved ← destroyRoots (stateRoots state)
  pure . ownerDestroyed $
    (if late > 0 then "destroyed " <> plural late "late surface" <> "; " else "")
      <> maybe "no instance was created" (const "destroyed the explicit messenger and then the instance") proved
  where
    bridge = stateBridge state

obligationsOf ∷ SurfaceBridge lease obligation → lease → AttachmentId → STM [obligation]
obligationsOf bridge lease attachment =
  filter ((== attachment) . bridgeObligationAttachment bridge) <$> bridgeObligations bridge lease

-- | A surface's destruction, as the roots run it.
destruction ∷ SurfaceBridge lease obligation → obligation → IO SurfaceDestruction
destruction bridge obligation =
  bridgeDischarge bridge obligation >>= \case
    DischargeDone → pure SurfaceDestroyed
    DischargeUncertain failure → pure (SurfaceDestructionUncertain failure)

-- ---------------------------------------------------------------------------
-- Handing targets over

-- | How a handover was answered.
data VulkanHandover
  = VulkanTargetHandedOver !GraphicsService
    -- ^ The window's surface was created under its attachment and the owner
    -- has been told. Whether its target was admitted is the owner's answer:
    -- 'Hetoimasia.Runtime.GLFW.readTargetStanding', and 'readTargetRejection'
    -- when it was rolled back.
  | VulkanAnnouncementDeferred !GraphicsService
    -- ^ Attached, with its surface deposited, but the owner's bounded port was
    -- full. It is backpressure: announce it again with
    -- 'Hetoimasia.Runtime.GLFW.announceGraphicsTarget', or release it.
  | VulkanRootsNotReady !Readiness
    -- ^ The owner has not leased an instance to the bridge, so nothing was
    -- attached.
  | VulkanOwnerClosed !(Maybe GraphicsService)
    -- ^ The owner's admission has ended. Nothing was attached, or what was is
    -- named: its surface is destroyed by the owner's own retirement.
  | VulkanHandoverRefused !GraphicsRefusal
  | VulkanHandoverSuperseded !AttachmentId
    -- ^ The host's admission closed while the attachment was constructed. It
    -- is retiring; the owner's retirement destroys its surface.
  | VulkanHandoverRolledBack !RolledBack
  | VulkanHandoverUnavailable !Text
    -- ^ The host cannot attach at all — it is unprotected, or the protocol's
    -- declarations were rejected.
  deriving (Show)

-- | Create one window's surface on the main thread, under its attachment, and
-- hand it to the owner; the application designates the target required or
-- optional.
--
-- It must run on the main thread, as the surface's creation is a GLFW call.
-- The attachment is restored to cancellation, as the owner's own handover
-- restores it; everything around it is masked. A cancellation that arrives
-- during the construction step is caught there and delivered here once the
-- attachment is published and announced, so the caller loses the answer and
-- not the target. One that escapes the attachment elsewhere still announces an
-- attachment that registered and was never announced, so none is left that the
-- owner never hears of: its surface, if it was created, is on the lease, and
-- the owner settles it.
handOverVulkanTarget
  ∷ VulkanController → WindowHost → GraphicsOwner scene → WindowId → TargetClass → IO VulkanHandover
handOverVulkanTarget (VulkanController state) host owner window classification =
  mask $ \restore →
    readTVarIO (stateLease state) >>= \case
      LeaseReady lease → do
        open ← atomically (targetEventsOpen (ownerHandoff owner))
        if not open
          then pure (VulkanOwnerClosed Nothing)
          else do
            deferred ← newIORef Nothing
            answer ←
              tryWithContext (restore (bridgeAttach (stateBridge state) host window (protocol deferred lease))) >>= \case
                Left failure → do
                  recover
                  rethrowIO (failure ∷ ExceptionWithContextSome)
                Right (GraphicsAttached service) → announce service
                Right (GraphicsSuperseded attachment) → pure (VulkanHandoverSuperseded attachment)
                Right (GraphicsRolledBack rolled) → pure (VulkanHandoverRolledBack rolled)
                Right (GraphicsRefused refusal) → pure (VulkanHandoverRefused refusal)
                Right other → pure (VulkanHandoverUnavailable (tshow other))
            -- A cancellation the construction step caught is delivered now,
            -- once the attachment it interrupted has been published and the
            -- owner told of it: the caller loses the answer, not the target.
            readIORef deferred >>= maybe (pure answer) rethrowIO
      LeasePending → pure (VulkanRootsNotReady RootsPending)
      LeaseFailed reason → pure (VulkanRootsNotReady (RootsFailed reason))
  where
    base = graphicsTargetProtocol host owner
    protocol deferred lease create =
      base
        { -- Masked throughout, so a cancellation cannot land between the
          -- registration and the creation, or between the native call's return
          -- and the deposit. One aimed at the thread meanwhile arrives as the
          -- mask ends — still inside this step, where the host would take it
          -- for a failed construction and roll back an attachment whose
          -- surface exists — so it is caught here and delivered by the
          -- handover once the attachment is announced. A creation it
          -- interrupted before the native call created nothing; one whose
          -- answer it lost after the call left its obligation on the lease,
          -- where the owner finds it. A synchronous failure is the
          -- construction's own, and fails it.
          protocolConstruct = \attachment acknowledgement →
            tryWithContext
              ( mask_ $ do
                  protocolConstruct base attachment acknowledgement
                  created ← create lease
                  atomically (modifyTVar' (stateDeposits state) (Map.insert attachment (Deposit classification created)))
              )
              >>= \case
                Right () → pure ()
                Left caught@(ExceptionWithContext _ exception)
                  | isAsynchronous exception → writeIORef deferred (Just caught)
                  | otherwise → rethrowIO caught
        }
    announce service =
      announceGraphicsTarget owner service >>= \case
        EventAdmitted → pure (VulkanTargetHandedOver service)
        EventRefusedFull → pure (VulkanAnnouncementDeferred service)
        EventPortClosed → pure (VulkanOwnerClosed (Just service))
    recover = do
      found ← atomically (windowGraphicsService host window)
      for_ found $ \service → do
        stage ← atomically (custodyOf owner (graphicsAttachment service))
        when (stage == Just CustodyRegistered) (void (announceGraphicsTarget owner service))

type ExceptionWithContextSome = ExceptionWithContext SomeException

isAsynchronous ∷ SomeException → Bool
isAsynchronous exception = isJust (fromException exception ∷ Maybe SomeAsyncException)

-- ---------------------------------------------------------------------------
-- Observation

-- | Why a target was rolled back rather than admitted.
data VulkanRejection
  = RejectedByRoots !TargetRejection
    -- ^ The roots refused it: its surface cannot be presented to by the
    -- session's queue family, admission has closed, or the model's budget is
    -- exhausted. No second device was created.
  | SurfaceUnusable !Text
    -- ^ A surface was created and could not be published.
  | SurfaceNotCreated !Text
    -- ^ No surface was created.
  | SurfaceNotHandedOver
    -- ^ The construction step's answer never arrived; whatever the lease
    -- listed for the attachment was destroyed.
  deriving (Eq, Show)

describeRejection ∷ VulkanRejection → Text
describeRejection = \case
  RejectedByRoots (TargetSurfaceUnsupported family) →
    "rejected: queue family " <> tshow family <> " of the session's device cannot present to this surface"
  RejectedByRoots TargetAdmissionClosed → "rejected: the roots admit no new target"
  RejectedByRoots (TargetBudgetExhausted kind) → "rejected: the model's " <> tshow kind <> " is exhausted"
  SurfaceUnusable reason → "rejected: the surface could not be published (" <> reason <> ")"
  SurfaceNotCreated reason → "rejected: no surface was created (" <> reason <> ")"
  SurfaceNotHandedOver → "rejected: the construction step's answer never arrived"

-- | How many rejections are kept, newest attachments first to stay.
rejectionsRetained ∷ Int
rejectionsRetained = 64

retainRejection ∷ State inst msgr phys dev lease obligation → AttachmentId → VulkanRejection → STM ()
retainRejection state attachment reason =
  modifyTVar' (stateRejections state) $ \held →
    let grown = Map.insert attachment reason held
     in if Map.size grown > rejectionsRetained then Map.deleteMin grown else grown

-- | Why this attachment's target was rolled back, while it is retained.
readTargetRejection ∷ VulkanController → AttachmentId → STM (Maybe VulkanRejection)
readTargetRejection (VulkanController state) attachment = Map.lookup attachment <$> readTVar (stateRejections state)

-- | Every admitted target, by the attachment it serves.
readVulkanTargets ∷ VulkanController → STM [(AttachmentId, RootTargetView)]
readVulkanTargets (VulkanController state) = do
  mapped ← readTVar (stateTargets state)
  views ← readRootTargets (stateRoots state)
  pure
    [ (attachment, view)
    | (attachment, target) ← Map.toAscList mapped
    , view ← views
    , targetViewIdentity view == target
    ]

-- | Where the roots stand.
readVulkanRoots ∷ VulkanController → STM RootsView
readVulkanRoots (VulkanController state) = readRootsView (stateRoots state)

-- | The model the roots keep their identities in.
readVulkanModel ∷ VulkanController → STM GpuModel
readVulkanModel (VulkanController state) = readRootsModel (stateRoots state)

-- ---------------------------------------------------------------------------
-- The composition

-- | Something that observes every native call the controller makes: it is
-- given each call's name and the call itself, and must run the call exactly
-- once and answer what it answered. It exists for evidence — a native run
-- records the thread each call ran on and the diagnostics each one produced —
-- and it decides nothing: an observer that records nothing is 'noObserver'.
newtype NativeObserver = NativeObserver (∀ a. Text → IO a → IO a)

noObserver ∷ NativeObserver
noObserver = NativeObserver (\_ call → call)

-- | The native layer, with every call observed under its Vulkan name.
observeRoots ∷ NativeObserver → RootOps q inst msgr phys dev → RootOps q inst msgr phys dev
observeRoots (NativeObserver observe) ops =
  ops
    { opsInstanceOffer = observe "vkEnumerateInstanceExtensionProperties" (opsInstanceOffer ops)
    , opsCreateInstance = observe "vkCreateInstance" . opsCreateInstance ops
    , opsCreateMessenger = observe "vkCreateDebugUtilsMessengerEXT" . opsCreateMessenger ops
    , opsDestroyMessenger = \created messenger → observe "vkDestroyDebugUtilsMessengerEXT" (opsDestroyMessenger ops created messenger)
    , opsDestroyInstance = observe "vkDestroyInstance" . opsDestroyInstance ops
    , opsDeviceOffers = \created surface → observe "vkEnumeratePhysicalDevices" (opsDeviceOffers ops created surface)
    , opsCreateDevice = \created plan → observe "vkCreateDevice" (opsCreateDevice ops created plan)
    , opsDestroyDevice = observe "vkDestroyDevice" . opsDestroyDevice ops
    , opsSurfaceSupport = \created physical family surface →
        observe "vkGetPhysicalDeviceSurfaceSupportKHR" (opsSurfaceSupport ops created physical family surface)
    }

-- | The surface bridge, with its two native calls observed.
observeBridge ∷ NativeObserver → SurfaceBridge lease obligation → SurfaceBridge lease obligation
observeBridge (NativeObserver observe) bridge =
  bridge
    { bridgeAttach = \host window build →
        bridgeAttach bridge host window (\create → build (observe "glfwCreateWindowSurface" . create))
    , bridgeDischarge = observe "vkDestroySurfaceKHR" . bridgeDischarge bridge
    }

-- | What one Vulkan graphics host is built from.
data VulkanHostConfig scene = VulkanHostConfig
  { vulkanHost ∷ !HostConfig
    -- ^ The window host; its session configuration is the loader-aware
    -- session's.
  , vulkanCapture ∷ !CaptureConfig
  , vulkanLayers ∷ ![ByteString]
    -- ^ Instance layers to enable, such as the validation layer.
  , vulkanBudgets ∷ !Budgets
  , vulkanScene ∷ !(Prepared scene)
  , vulkanOwner ∷ GraphicsOwnerConfig scene → GraphicsOwnerConfig scene
    -- ^ Adjusts the owner's configuration: its label, its port, its timer.
  , vulkanObserver ∷ DiagnosticCapture → NativeObserver
    -- ^ What observes each native call, given the session's capture.
  }

-- | A configuration with the given capture configuration and budgets, no
-- layers, the owner's defaults, and no observer.
vulkanHostConfig ∷ HostConfig → CaptureConfig → Budgets → Prepared scene → VulkanHostConfig scene
vulkanHostConfig host capture budgets scene = VulkanHostConfig host capture [] budgets scene id (const noObserver)

-- | A running Vulkan graphics host.
data VulkanHost scene = VulkanHost
  { vulkanWindowHost ∷ !WindowHost
  , vulkanGraphicsOwner ∷ !(GraphicsOwner scene)
  , vulkanController ∷ !VulkanController
  }

-- | The whole composition, over a native layer and a surface bridge:
--
-- 1. the diagnostic lifetime, whose capture the native layer reports into;
-- 2. the loader-aware session, entered on the calling thread — the main
--    thread — which copies the instance extensions its surfaces need;
-- 3. the protected window host and its supervised graphics owner, whose
--    startup creates the instance and its explicit messenger on the owner's
--    thread, and whose exit retires every target, the device, the messenger
--    and the instance there, in that order, before the owner is joined and
--    any window or the session is released;
-- 4. the body.
--
-- The lifetime's quiescence evidence is what the instance's destruction
-- returned; roots whose instance was never created prove it trivially. The
-- result is the body's, with the capture's verdict.
withVulkanOwnerHostOver
  ∷ Logger
  → (DiagnosticCapture → RootOps Quiesced inst msgr phys dev)
  → (inst → Ptr ())
  → SurfaceBridge lease obligation
  → (SessionConfig → Scoped Session)
  → (Session → IO [ByteString])
  → VulkanHostConfig scene
  → (VulkanHost scene → IO r)
  → IO (r, DiagnosticVerdict)
withVulkanOwnerHostOver logger layer pointer bridge enter extensions config use =
  withDiagnosticCapture (vulkanCapture config) logger $ \capture → do
    let observer = vulkanObserver config capture
    controller@(VulkanController state) ←
      newVulkanController
        (observeRoots observer (layer capture))
        pointer
        (observeBridge observer bridge)
        (vulkanLayers config)
        (vulkanBudgets config)
        (hostClock host)
    let session = do
          entered ← enter (hostSessionConfig host)
          copied ← liftIO (extensions entered)
          liftIO (atomically (supplyInstanceExtensions controller copied))
          pure entered
        owner = vulkanOwner config (graphicsOwnerConfig (controllerOperations controller) (vulkanScene config))
    outcome ← tryWithContext (withGraphicsOwnerHostIn logger session host owner (\windows graphics → use (VulkanHost windows graphics controller)))
    -- However the host ended, an instance it did not destroy may still have
    -- a messenger naming the capture, so the capture's storage is kept rather
    -- than freed under it. Only an independent publication of the owner's
    -- destruction can end the host with the instance alive.
    view ← atomically (readRootsView (stateRoots state))
    proved ← atomically (readRootsQuiesced (stateRoots state))
    let survived = viewInstance view `notElem` [RootAbsent, RootDestroyed]
    when survived (retainStorage capture)
    case outcome of
      Left (failure ∷ ExceptionWithContext SomeException) → rethrowIO failure
      Right result → do
        quiesced ← case (viewInstance view, proved) of
          (RootDestroyed, Just evidence) → pure evidence
          (RootAbsent, _) → afterLastCallback capture (pure ())
          (standing, _) → throwIO (RootsOutlivedHost standing)
        pure (result, quiesced)
  where
    host = vulkanHost config

-- ---------------------------------------------------------------------------
-- Descriptions

listNames ∷ [ByteString] → Text
listNames = Text.intercalate ", " . map (Text.pack . Char8.unpack)

describeClass ∷ TargetClass → Text
describeClass = \case
  RequiredTarget → "required"
  OptionalTarget → "optional"

hex ∷ (Integral a, Show a) ⇒ a → Text
hex value = "0x" <> Text.pack (showHex value "")

plural ∷ Int → Text → Text
plural 1 noun = "1 " <> noun
plural count noun = tshow count <> " " <> noun <> "s"

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
