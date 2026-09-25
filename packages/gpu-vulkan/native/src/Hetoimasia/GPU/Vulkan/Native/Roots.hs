-- | The Vulkan roots of one graphics session: the instance, its explicit
-- debug messenger, the one shared device, and a record for every target
-- surface admitted to them.
--
-- This module owns their construction, admission and destruction order, and
-- nothing else. It makes no native call itself: every call goes through an
-- open native layer, 'RootOps', whose handle types are parameters. The
-- production layer is "Hetoimasia.GPU.Vulkan.Native.Roots.Vulkan"; the
-- headless examples supply stand-ins that fail at a chosen step, and so drive
-- exactly the ownership decisions a native run obeys. It knows no window
-- system either: a surface arrives as its 64-bit handle and the action that
-- destroys it, from whoever created it.
--
-- = Ownership
--
-- * The instance, the explicit messenger and the device belong to the roots,
--   for the session. No target owns the device or gates its lifetime —
--   including the bootstrap target whose surface the device was selected
--   against — so closing the first-created window cannot release a device
--   another target is using (D-7, P-5).
-- * Each admitted target's surface belongs to the roots from admission until
--   'retireRootTarget' destroys it. A surface the roots refused
--   ('TargetRejection') or that an admission raised before taking is still
--   its creator's.
-- * Every handle is recorded in the same masked step that creates it, so no
--   failure and no cancellation delivered at that handoff can leave one
--   unowned; whatever exists is what retirement destroys.
--
-- = Order
--
-- Creation runs parent before child: the instance, the explicit messenger,
-- then — on the first admission, against that target's surface — the device.
-- Destruction runs child before parent and is refused rather than reordered:
--
-- 1. every target's surface ('retireRootTarget');
-- 2. the device ('retireRoots'), only once no target record remains;
-- 3. the explicit messenger, and then the instance ('destroyRoots'), only once
--    the device is gone. The messenger goes immediately before the instance,
--    so every child's destruction still reports somewhere, and the instance's
--    destruction is the last call that can invoke the capture's callback.
--
-- = Names
--
-- When the instance enabled @VK_EXT_debug_utils@ and the device offers its
-- naming call ('opsInstrumentation'), the roots name what they own once a
-- device exists to name it through ("Hetoimasia.GPU.Vulkan.Native.Naming"):
-- the device and its one queue at the first admission, and each target's
-- surface before the target is admitted, under the 'TargetId' the model is
-- about to issue it. A naming call runs on the
-- owner's thread like every other call here, and one that raised fails the
-- admission exactly as any other native failure there does: a surface whose
-- name could not be set is not admitted, so it is still its creator's, and the
-- roots' own names are attempted again at the next admission. Two roots are
-- never named. The instance: naming requires external synchronization of the
-- object named, and the surface bridge's lease lets the main thread use the
-- instance while the owner runs. The explicit messenger: the pinned loader
-- answers its own wrapper for it and forwards a naming call without
-- translating that wrapper, which MoltenVK then reads as one of its own objects
-- and crashes on (#250), so no naming call is ever made for it; its
-- diagnostics are the capture's, which names it nowhere. Without the extension
-- nothing is named and nothing fails.
--
-- A destruction that raised is uncertain: it is recorded, never attempted
-- again, and every parent that must outlive it is retained — a later step
-- answers 'RootsRetained' and destroys nothing. No timeout, cancellation or
-- cleanup failure is ever read as permission.
--
-- = Device loss
--
-- A native call the layer classifies as device loss ('opsDeviceLoss') latches
-- the loss, closes admission and fails the model's session in one
-- transaction, and then raises 'GraphicsDeviceLost' in its place, so the loss
-- is the failure its caller sees first. Nothing is recreated or replayed. The
-- retirement that follows is the ordinary child-before-parent one: nothing has
-- been submitted in this slice, and Vulkan permits destroying a lost device's
-- objects without waiting for work that may never complete. An outcome that
-- is unknown rather than lost is not loss: it is an uncertain destruction, and
-- it retains its parents.
--
-- = State
--
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
-- | State            | Owner     | Readers and writers         | Thread     | Lifetime         | Reset or disposal         |
-- +==================+===========+=============================+============+==================+===========================+
-- | Each root's slot | The roots | Written by the operations   | Written on | 'newRoots' until | Only advances: absent,    |
-- |                  |           | below; any thread reads     | the owning | the session ends | live, then destroyed or   |
-- |                  |           |                             | thread     |                  | uncertain                 |
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
-- | Target records   | The roots | Admission inserts;          | As above   | Admission until  | Removed only by a         |
-- |                  |           | retirement removes          |            | destroyed        | destruction that returned |
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
-- | The model        | The roots | Admission, retirement and   | As above   | The session      | Never reset               |
-- |                  |           | loss                        |            |                  |                           |
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
-- | The loss latch   | The roots | Set once; any thread reads  | Any        | The session      | Never cleared             |
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
--
-- Every mutating operation is meant for one serialized owner — the graphics
-- owner's thread — and none is safe to run concurrently with another.
module Hetoimasia.GPU.Vulkan.Native.Roots
  ( -- * The native layer
    RootOps (..)
  , GenerationOps (..)
  , SwapchainRequest (..)

    -- * The roots
  , Roots
  , newRoots
  , rootsSessionIdentity
  , rootsDeviceId

    -- * Startup
  , startRoots
  , RootsAlreadyStarted (..)

    -- * Targets
  , TargetSurface (..)
  , SurfaceDestruction (..)
  , admitRootTarget
  , retireRootTarget
  , RootsNotStarted (..)
  , UnknownRootTarget (..)
  , SurfaceDestructionFailed (..)
  , TargetGenerationsRemain (..)

    -- * Device loss
  , GraphicsDeviceLost (..)
  , latchDeviceLoss
  , checkRoots

    -- * Retirement
  , retireRoots
  , destroyRoots
  , RootsRetained (..)
  , RootDestructionFailed (..)

    -- * Observation
  , RootStanding (..)
  , RootsView (..)
  , readRootsView
  , RootTargetView (..)
  , readRootTargets
  , readRootsModel
  , readRootsQuiesced
  , readRootsInstance

    -- * For the generations above the roots
  , readRootsDevice
  , readRootsInstrumentation
  , nameRootsObject
  , rootsGenerationOps
  , rootsCall
  , stateRootsModel
  , failRootsSession
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, stateTVar, writeTVar)
import Control.Exception
  ( Exception (displayException)
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , fromException
  , mask_
  , rethrowIO
  , throwIO
  , tryWithContext
  )
import Control.Monad (unless, when)
import Data.Foldable (for_)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Unique (newUnique)
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)
import Hetoimasia.Foundation.Time (MonotonicSource, readInstant)
import Hetoimasia.GPU.Model
  ( GpuModel
  , Outcome (..)
  , SessionFailureCause (..)
  , TargetView (viewTargetGenerations)
  , admitTarget
  , closeTarget
  , escalateSession
  , newGpuModel
  , runProgressTurn
  , silentEvidence
  , targetView
  )
import Hetoimasia.GPU.Model.Budget (Budgets)
import Hetoimasia.GPU.Model.Identity (DeviceId, SessionIdentity, TargetClass, TargetId, sessionIdentity)
import Data.ByteString (ByteString)
import Hetoimasia.GPU.Vulkan.Native.Naming
  ( Instrumentation (..)
  , NativeObjectKind (..)
  , deviceName
  , queueName
  , surfaceName
  )
import Hetoimasia.GPU.Vulkan.Native.Presentation (GenerationPlan, SurfaceOffer)
import Hetoimasia.GPU.Vulkan.Native.Profile
  ( DevicePlan (..)
  , InstancePlan (..)
  , InstanceRequest
  , TargetRejection (..)
  , debugUtilsExtension
  , planInstance
  , selectDevice
  , InstanceOffer
  , DeviceOffer
  )

-- ---------------------------------------------------------------------------
-- The native layer

-- | Every native call the roots make, over open handle types: @inst@ the
-- instance, @msgr@ the explicit messenger, @phys@ a physical device, @dev@
-- the logical device, and @q@ what the instance's destruction proves — the
-- diagnostic capture's quiescence evidence in production.
--
-- A surface is its 64-bit handle, the representation VK-2 established for a
-- non-dispatchable handle on every supported ABI.
data RootOps q inst msgr phys dev = RootOps
  { opsInstanceOffer ∷ IO InstanceOffer
    -- ^ What the loader offers: its version, its extensions, its layers.
  , opsCreateInstance ∷ InstancePlan → IO inst
    -- ^ @vkCreateInstance@, with the capture's messenger chained into its
    -- create info so the call itself reports.
  , opsCreateMessenger ∷ inst → IO msgr
    -- ^ The explicit messenger, which hears everything between the
    -- instance's creation and its destruction.
  , opsDestroyMessenger ∷ inst → msgr → IO ()
  , opsDestroyInstance ∷ inst → IO q
    -- ^ @vkDestroyInstance@: the last call that can invoke the capture's
    -- callback, answering the evidence that none can still run.
  , opsDeviceOffers ∷ inst → Word64 → IO [DeviceOffer phys]
    -- ^ Every physical device, with each queue family's presentation support
    -- for the given bootstrap surface.
  , opsCreateDevice ∷ inst → DevicePlan phys → IO dev
  , opsDestroyDevice ∷ dev → IO ()
  , opsSurfaceSupport ∷ inst → phys → Word32 → Word64 → IO Bool
    -- ^ Whether that queue family of that device presents to that surface.
  , opsDeviceLoss ∷ SomeException → Bool
    -- ^ Whether a failure one of these calls raised is the loss of the device.
  , opsDeviceHandle ∷ dev → Word64
    -- ^ The device's dispatchable handle, as its pointer's value.
  , opsDeviceQueue ∷ dev → Word32 → IO Word64
    -- ^ @vkGetDeviceQueue@: the dispatchable handle of the device's first
    -- queue of that family, as its pointer's value.
  , opsInstrumentation ∷ dev → IO (Maybe Instrumentation)
    -- ^ The device's naming call, when it offers one. The roots ask only when
    -- the instance enabled @VK_EXT_debug_utils@; 'Nothing' names nothing.
  , opsGenerations ∷ GenerationOps phys dev
    -- ^ The calls a target's swapchain generations are built and destroyed
    -- with ("Hetoimasia.GPU.Vulkan.Native.Generations").
  }

-- | Every native call a target's swapchain generations need. A swapchain, a
-- swapchain image and an image view are each their 64-bit handle, as a surface
-- is.
data GenerationOps phys dev = GenerationOps
  { opsSurfaceOffer ∷ phys → Word64 → IO SurfaceOffer
    -- ^ The surface's capabilities, formats and presentation modes for the
    -- session's physical device.
  , opsCreateSwapchain ∷ dev → SwapchainRequest → IO Word64
    -- ^ @vkCreateSwapchainKHR@. Passing an @oldSwapchain@ retires it whether
    -- or not the creation succeeds.
  , opsSwapchainImages ∷ dev → Word64 → IO [Word64]
    -- ^ @vkGetSwapchainImagesKHR@. The images are the swapchain's: they go
    -- with its destruction and are never destroyed on their own.
  , opsCreateImageView ∷ dev → Word64 → Word32 → IO Word64
    -- ^ A color view of one swapchain image in the given format.
  , opsDestroyImageView ∷ dev → Word64 → IO ()
  , opsDestroySwapchain ∷ dev → Word64 → IO ()
  }

-- | One swapchain creation: the surface, the plan, the session's queue family,
-- and the active generation's swapchain being handed over, if any.
data SwapchainRequest = SwapchainRequest
  { requestSurface ∷ !Word64
  , requestPlan ∷ !GenerationPlan
  , requestQueueFamily ∷ !Word32
  , requestOldSwapchain ∷ !(Maybe Word64)
  }
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- The roots

-- | Where one root stands. It only advances.
data RootStanding
  = RootAbsent
  | RootLive
  | RootDestroyed
  | RootUncertain !Text
    -- ^ Its destruction raised, with what it raised. It is never attempted
    -- again, and every parent it has is retained.
  deriving (Eq, Show)

data Root a
  = Absent
  | Live !a
  | Destroyed
  | Uncertain !Text

standingOf ∷ Root a → RootStanding
standingOf = \case
  Absent → RootAbsent
  Live _ → RootLive
  Destroyed → RootDestroyed
  Uncertain reason → RootUncertain reason

-- | The device the session selected and created.
data Selected phys dev = Selected
  { selectedPlan ∷ !(DevicePlan phys)
  , selectedDevice ∷ !dev
  }

-- | How a target's surface is destroyed, and what that answered.
data SurfaceDestruction
  = SurfaceDestroyed
    -- ^ The destruction returned; the surface no longer exists.
  | SurfaceDestructionUncertain !(ExceptionWithContext SomeException)
    -- ^ It raised, or its outcome is otherwise unknown. The surface may still
    -- exist.

-- | A surface offered to the roots as a target: its handle, and the one action
-- that destroys it. The roots run that action at most once, on their own
-- thread, and only while retiring the target.
data TargetSurface = TargetSurface
  { targetSurfaceHandle ∷ !Word64
  , targetSurfaceDestroy ∷ IO SurfaceDestruction
  }

data TargetRecord = TargetRecord
  { recordClass ∷ !TargetClass
  , recordSurface ∷ !Word64
  , recordDestroy ∷ IO SurfaceDestruction
  , recordUncertain ∷ !(Maybe Text)
  }

-- | One graphics session's roots.
data Roots q inst msgr phys dev = Roots
  { rootsOps ∷ !(RootOps q inst msgr phys dev)
  , rootsClock ∷ !MonotonicSource
  , rootsInstance ∷ !(TVar (Root inst))
  , rootsMessenger ∷ !(TVar (Root msgr))
  , rootsDevice ∷ !(TVar (Root (Selected phys dev)))
  , rootsQuiesced ∷ !(TVar (Maybe q))
  , rootsTargets ∷ !(TVar (Map TargetId TargetRecord))
  , rootsModel ∷ !(TVar GpuModel)
  , rootsAdmitting ∷ !(TVar Bool)
  , rootsLoss ∷ !(TVar (Maybe GraphicsDeviceLost))
  , rootsDebugUtils ∷ !(TVar Bool)
    -- ^ Whether the instance was created with @VK_EXT_debug_utils@.
  , rootsNamed ∷ !(TVar Bool)
    -- ^ Whether the device and its queue have been named.
  , rootsSession ∷ !SessionIdentity
  , rootsDeviceIdentity ∷ !DeviceId
  }

-- | Empty roots over a native layer. Nothing native happens until
-- 'startRoots'.
--
-- The session identity is minted here, from a 'Data.Unique.Unique' made for
-- this session alone, which is the premise the model's identities rest on.
-- The clock is the one the model's progress reads; it must be the host's.
newRoots ∷ RootOps q inst msgr phys dev → Budgets → MonotonicSource → IO (Roots q inst msgr phys dev)
newRoots ops budgets clock = do
  session ← sessionIdentity <$> newUnique
  let (model, device) = newGpuModel session budgets
  Roots ops clock
    <$> newTVarIO Absent
    <*> newTVarIO Absent
    <*> newTVarIO Absent
    <*> newTVarIO Nothing
    <*> newTVarIO Map.empty
    <*> newTVarIO model
    <*> newTVarIO True
    <*> newTVarIO Nothing
    <*> newTVarIO False
    <*> newTVarIO False
    <*> pure session
    <*> pure device

rootsSessionIdentity ∷ Roots q inst msgr phys dev → SessionIdentity
rootsSessionIdentity = rootsSession

-- | The model's identity for the session's one device, which exists from the
-- start: a device that has not been created yet is still the only one this
-- session will ever have.
rootsDeviceId ∷ Roots q inst msgr phys dev → DeviceId
rootsDeviceId = rootsDeviceIdentity

-- ---------------------------------------------------------------------------
-- Failures

-- | 'startRoots' ran on roots that had already begun.
data RootsAlreadyStarted = RootsAlreadyStarted
  deriving (Eq, Show)

instance Exception RootsAlreadyStarted

-- | A target was offered before the instance existed.
data RootsNotStarted = RootsNotStarted
  deriving (Eq, Show)

instance Exception RootsNotStarted

-- | A target identity these roots hold no record for.
newtype UnknownRootTarget = UnknownRootTarget TargetId
  deriving (Eq, Show)

instance Exception UnknownRootTarget

-- | The session's device was lost. It is terminal for the session (D-17):
-- admission closed when it was latched, and nothing is recreated.
data GraphicsDeviceLost = GraphicsDeviceLost
  { lostDuring ∷ !Text
    -- ^ The native operation that reported it.
  , lostDetail ∷ !Text
    -- ^ What it reported.
  }
  deriving (Eq, Show)

instance Exception GraphicsDeviceLost where
  displayException loss =
    "the Vulkan device was lost during " <> Text.unpack (lostDuring loss) <> ": " <> Text.unpack (lostDetail loss)

-- | A target's surface destruction raised. The record stays, explicitly
-- uncertain, and the device and the instance are retained behind it.
data SurfaceDestructionFailed = SurfaceDestructionFailed !TargetId !Text
  deriving (Eq, Show)

instance Exception SurfaceDestructionFailed where
  displayException (SurfaceDestructionFailed target reason) =
    "destroying the surface of " <> show target <> " did not complete: " <> Text.unpack reason

-- | A target's surface was not destroyed because the model still holds
-- swapchain generations of that target: they are the surface's children, and
-- go first.
data TargetGenerationsRemain = TargetGenerationsRemain !TargetId !Natural
  deriving (Eq, Show)

instance Exception TargetGenerationsRemain where
  displayException (TargetGenerationsRemain target count) =
    "the surface of " <> show target <> " is retained: " <> show count <> " of its swapchain generations remain"

-- | A root's destruction raised. It is recorded uncertain, never attempted
-- again, and its parents are retained.
data RootDestructionFailed = RootDestructionFailed !Text !Text
  deriving (Eq, Show)

instance Exception RootDestructionFailed where
  displayException (RootDestructionFailed root reason) =
    "destroying the " <> Text.unpack root <> " did not complete: " <> Text.unpack reason

-- | A destruction step was refused because something that must go first has
-- not verifiably gone. Nothing was destroyed by the refused step.
data RootsRetained
  = TargetsRemain ![TargetId]
    -- ^ These targets' surfaces have not been destroyed, so the device and
    -- the instance are retained.
  | DeviceRemains !RootStanding
    -- ^ The device is live or uncertain, so the messenger and the instance are
    -- retained.
  | MessengerUncertain !Text
    -- ^ The explicit messenger's destruction raised, so the instance is
    -- retained.
  | InstanceUncertain !Text
    -- ^ An earlier attempt to destroy the instance raised.
  deriving (Eq, Show)

instance Exception RootsRetained where
  displayException = \case
    TargetsRemain targets → "the Vulkan roots are retained: " <> show (length targets) <> " target surfaces have not verifiably been destroyed"
    DeviceRemains standing → "the Vulkan messenger and instance are retained: the device is " <> show standing
    MessengerUncertain reason → "the Vulkan instance is retained: its explicit messenger's destruction did not complete (" <> Text.unpack reason <> ")"
    InstanceUncertain reason → "the Vulkan instance's earlier destruction did not complete (" <> Text.unpack reason <> ")"

-- ---------------------------------------------------------------------------
-- Startup

-- | Create the instance and its explicit messenger, in that order, on the
-- calling thread.
--
-- The loader's offer is planned first ('planInstance'), so a loader that
-- cannot satisfy the profile raises 'Hetoimasia.GPU.Vulkan.Native.Profile.InstanceRefusal'
-- before anything is created. Each handle is recorded as it is created; a
-- failure after the instance leaves it recorded for retirement to destroy.
startRoots ∷ Roots q inst msgr phys dev → InstanceRequest → IO InstancePlan
startRoots roots request = do
  begun ← atomically (standingOf <$> readTVar (rootsInstance roots))
  unless (begun == RootAbsent) (throwIO RootsAlreadyStarted)
  offer ← opsInstanceOffer ops
  plan ← either throwIO pure (planInstance request offer)
  created ← creating (rootsInstance roots) (opsCreateInstance ops plan)
  atomically (writeTVar (rootsDebugUtils roots) (debugUtilsExtension `elem` planInstanceExtensions plan))
  _ ← creating (rootsMessenger roots) (opsCreateMessenger ops created)
  pure plan
  where
    ops = rootsOps roots

-- | Run a creation and record its handle in the same masked step, so nothing
-- can land between the handle existing and the roots owning it. A creation
-- that raised created nothing.
creating ∷ TVar (Root a) → IO a → IO a
creating slot create = mask_ $ do
  created ← create
  atomically (writeTVar slot (Live created))
  pure created

-- ---------------------------------------------------------------------------
-- Targets

-- | Offer one surface as a target, classified required or optional.
--
-- The first target is the bootstrap: the device is selected against its
-- surface and created — owned by the roots, not by the target — before the
-- target is admitted. A later target is checked against the queue family
-- already chosen, and a surface that family cannot present to is refused with
-- 'TargetSurfaceUnsupported'; no second device is ever created.
--
-- An answer, either way, says who owns the surface: 'Right' means the roots
-- do, and will destroy it in 'retireRootTarget'; 'Left' means its creator
-- still does. So does a raise: 'Hetoimasia.GPU.Vulkan.Native.Profile.NoCompatibleDevice'
-- for a bootstrap no device can serve, which is a structured startup failure,
-- 'GraphicsDeviceLost' after latching a loss, and anything else the layer
-- raised. Whatever roots exist by then stay recorded for retirement.
admitRootTarget
  ∷ Roots q inst msgr phys dev → TargetClass → TargetSurface → IO (Either TargetRejection TargetId)
admitRootTarget roots classification surface = do
  open ← atomically ((&&) <$> readTVar (rootsAdmitting roots) <*> (not . isJust <$> readTVar (rootsLoss roots)))
  if not open
    then pure (Left TargetAdmissionClosed)
    else
      readTVarIO (rootsInstance roots) >>= \case
        Live created →
          readTVarIO (rootsDevice roots) >>= \case
            Live selected → do
              let plan = selectedPlan selected
              supported ←
                guarded roots "vkGetPhysicalDeviceSurfaceSupportKHR" $
                  opsSurfaceSupport ops created (planDevice plan) (planQueueFamily plan) handle
              if supported
                then admit
                else pure (Left (TargetSurfaceUnsupported (planQueueFamily plan)))
            Absent → do
              offers ← guarded roots "the device query" (opsDeviceOffers ops created handle)
              plan ← either throwIO pure (selectDevice offers)
              _ ← creating (rootsDevice roots) (Selected plan <$> guarded roots "vkCreateDevice" (opsCreateDevice ops created plan))
              admit
            _ → pure (Left TargetAdmissionClosed)
        Absent → throwIO RootsNotStarted
        _ → pure (Left TargetAdmissionClosed)
  where
    ops = rootsOps roots
    handle = targetSurfaceHandle surface
    -- The surface is named under the identity the model is about to issue, and
    -- admitted only if the model still issues exactly that one: every
    -- mutation of the model's targets is this owner's, so it does, and a model
    -- that moved regardless is asked again rather than trusted.
    admit = do
      nameRoots roots
      predicted ← atomically (admitTarget classification <$> readTVar (rootsModel roots))
      case predicted of
        Admitted (_, target) → do
          instrumented ← readRootsInstrumentation roots
          for_ instrumented $ \(_, instrumentation) →
            nameRootsObject roots instrumentation ObjectSurface handle (surfaceName target)
          settled ← atomically $ do
            model ← readTVar (rootsModel roots)
            case admitTarget classification model of
              Admitted (next, admitted)
                | admitted == target → do
                    writeTVar (rootsModel roots) next
                    modifyTVar' (rootsTargets roots) $
                      Map.insert target (TargetRecord classification handle (targetSurfaceDestroy surface) Nothing)
                    pure (Just (Right target))
                | otherwise → pure Nothing
              Backpressure kind → pure (Just (Left (TargetBudgetExhausted kind)))
              Rejected _ → pure (Just (Left TargetAdmissionClosed))
          maybe admit pure settled
        Backpressure kind → pure (Left (TargetBudgetExhausted kind))
        Rejected _ → pure (Left TargetAdmissionClosed)

-- | Name the device and its queue, once, when the device offers naming. A
-- call that raised leaves them unnamed, to be named again at the next
-- admission. The explicit messenger is never named (see "Names" above).
nameRoots ∷ Roots q inst msgr phys dev → IO ()
nameRoots roots = do
  named ← readTVarIO (rootsNamed roots)
  unless named $
    readRootsInstrumentation roots >>= \case
      Nothing → pure ()
      Just (device, instrumentation) → do
        let ops = rootsOps roots
            name = nameRootsObject roots instrumentation
        name ObjectDevice (opsDeviceHandle ops device) deviceName
        family ← fmap (planQueueFamily . fst) <$> atomically (readRootsDevice roots)
        for_ family $ \index → do
          queue ← guarded roots "vkGetDeviceQueue" (opsDeviceQueue ops device index)
          name ObjectQueue queue (queueName index 0)
        atomically (writeTVar (rootsNamed roots) True)

-- | Destroy one target's surface and forget the target.
--
-- The destroy action runs once. Running it and recording what it did are one
-- masked step, so no cancellation can land between the two: a destruction
-- that returned always removes the record, and one that did not — it answered
-- uncertain, or it raised, synchronously or with a cancellation of its own —
-- always leaves the record marked uncertain. Only then is
-- 'SurfaceDestructionFailed' raised, or the cancellation re-raised. Asking
-- again raises without running the action, because an action that failed
-- once may have destroyed part of what it owned. Only a destruction that
-- returned removes the record, and with it the model's target.
retireRootTarget ∷ Roots q inst msgr phys dev → TargetId → IO ()
retireRootTarget roots target =
  readTVarIO (rootsTargets roots) >>= \records → case Map.lookup target records of
    Nothing → throwIO (UnknownRootTarget target)
    Just record → case recordUncertain record of
      Just reason → throwIO (SurfaceDestructionFailed target reason)
      Nothing → do
        -- A swapchain generation is the surface's child: while the model holds
        -- one, the surface is refused rather than destroyed under it.
        remaining ← atomically (maybe 0 viewTargetGenerations . targetView target <$> readTVar (rootsModel roots))
        when (remaining > 0) (throwIO (TargetGenerationsRemain target remaining))
        -- Read before the destruction, so nothing that can fail stands
        -- between a destruction that returned and its record.
        now ← readInstant (rootsClock roots)
        mask_ $
          tryWithContext (recordDestroy record) >>= \case
            Right SurfaceDestroyed →
              atomically $ do
                modifyTVar' (rootsTargets roots) (Map.delete target)
                modifyTVar' (rootsModel roots) $ \model → case closeTarget target model of
                  -- The model forgets a retiring target with nothing left at
                  -- its next progress turn, which frees its record for a later
                  -- one.
                  Admitted closed → fst (runProgressTurn silentEvidence now closed)
                  _ → model
            Right (SurfaceDestructionUncertain failure) → settleUncertain failure
            Left failure → settleUncertain failure
  where
    settleUncertain failure@(ExceptionWithContext _ exception) = do
      let reason = Text.pack (displayException exception)
      atomically $
        modifyTVar' (rootsTargets roots) (Map.adjust (\held → held {recordUncertain = Just reason}) target)
      if isAsynchronous exception
        then rethrowIO failure
        else throwIO (SurfaceDestructionFailed target reason)

-- ---------------------------------------------------------------------------
-- Device loss

-- | Run one native call, latching device loss if that is what it raised.
guarded ∷ Roots q inst msgr phys dev → Text → IO a → IO a
guarded roots during call =
  tryWithContext call >>= \case
    Right value → pure value
    Left failure@(ExceptionWithContext _ exception)
      | isAsynchronous exception → rethrowIO failure
      | opsDeviceLoss (rootsOps roots) exception → do
          let loss = GraphicsDeviceLost during (Text.pack (displayException exception))
          latchDeviceLoss roots loss
          throwIO loss
      | otherwise → rethrowIO failure

isAsynchronous ∷ SomeException → Bool
isAsynchronous exception = isJust (fromException exception ∷ Maybe SomeAsyncException)

-- | Latch a device loss: close admission and fail the model's session in one
-- transaction. The first loss is kept.
latchDeviceLoss ∷ Roots q inst msgr phys dev → GraphicsDeviceLost → IO ()
latchDeviceLoss roots loss = atomically $ do
  held ← readTVar (rootsLoss roots)
  unless (isJust held) (writeTVar (rootsLoss roots) (Just loss))
  writeTVar (rootsAdmitting roots) False
  modifyTVar' (rootsModel roots) (escalateSession DeviceLost)

-- | Raise the latched device loss, if there is one. It is what a progress
-- step calls, so an owner whose loss was latched outside a call it made
-- still ends its run with the loss as its failure.
checkRoots ∷ Roots q inst msgr phys dev → IO ()
checkRoots roots = readTVarIO (rootsLoss roots) >>= maybe (pure ()) throwIO

-- ---------------------------------------------------------------------------
-- Retirement

-- | Destroy the device, once every target's surface has gone.
--
-- Admission closes first, whatever follows. A target record that remains —
-- one never retired, or one whose surface destruction was uncertain — retains
-- the device and everything above it, and this raises 'RootsRetained' having
-- destroyed nothing. A device that was never created is answered as such.
-- After a device loss the same destruction runs, as Vulkan permits.
retireRoots ∷ Roots q inst msgr phys dev → IO Text
retireRoots roots = do
  atomically (writeTVar (rootsAdmitting roots) False)
  remaining ← Map.keys <$> readTVarIO (rootsTargets roots)
  unless (null remaining) (throwIO (TargetsRemain remaining))
  lost ← isJust <$> readTVarIO (rootsLoss roots)
  readTVarIO (rootsDevice roots) >>= \case
    Absent → pure "no device was created"
    Destroyed → pure "the device was already destroyed"
    Uncertain reason → throwIO (DeviceRemains (RootUncertain reason))
    Live selected → do
      destroying (rootsDevice roots) "device" (opsDestroyDevice (rootsOps roots) (selectedDevice selected))
      pure ("destroyed the device " <> planDeviceName (selectedPlan selected) <> if lost then " after its loss" else "")

-- | Destroy the explicit messenger and then the instance, once the device has
-- gone, and keep what the instance's destruction proved.
--
-- Anything still above them retains both: a live or uncertain device, or a
-- target record, raises 'RootsRetained' before any destruction. An uncertain
-- messenger retains the instance. Roots whose instance was never created
-- answer 'Nothing', since there is nothing for a destruction to prove.
destroyRoots ∷ Roots q inst msgr phys dev → IO (Maybe q)
destroyRoots roots = do
  atomically (writeTVar (rootsAdmitting roots) False)
  remaining ← Map.keys <$> readTVarIO (rootsTargets roots)
  unless (null remaining) (throwIO (TargetsRemain remaining))
  device ← standingOf <$> readTVarIO (rootsDevice roots)
  when (device `elem` [RootLive] || isUncertain device) (throwIO (DeviceRemains device))
  readTVarIO (rootsInstance roots) >>= \case
    Absent → pure Nothing
    Destroyed → readTVarIO (rootsQuiesced roots)
    Uncertain reason → throwIO (InstanceUncertain reason)
    Live created → do
      readTVarIO (rootsMessenger roots) >>= \case
        Live messenger → destroying (rootsMessenger roots) "explicit messenger" (opsDestroyMessenger ops created messenger)
        Uncertain reason → throwIO (MessengerUncertain reason)
        _ → pure ()
      proved ← mask_ $
        tryWithContext (opsDestroyInstance ops created) >>= \case
          Right proved → do
            atomically $ do
              writeTVar (rootsInstance roots) Destroyed
              writeTVar (rootsQuiesced roots) (Just proved)
            pure proved
          Left failure → uncertainly (rootsInstance roots) "instance" failure
      pure (Just proved)
  where
    ops = rootsOps roots
    isUncertain = \case
      RootUncertain _ → True
      _ → False

-- | Run one root's destruction, which only a live root reaches, and record
-- what it did in the same masked step.
destroying ∷ TVar (Root a) → Text → IO () → IO ()
destroying slot name destroy = mask_ $
  tryWithContext destroy >>= \case
    Right () → atomically (writeTVar slot Destroyed)
    Left failure → uncertainly slot name failure

uncertainly ∷ TVar (Root a) → Text → ExceptionWithContext SomeException → IO b
uncertainly slot name failure@(ExceptionWithContext _ exception)
  | isAsynchronous exception = do
      -- A cancellation cannot land inside the masked call, so one here was
      -- raised by the call itself; its outcome is no better known for that.
      atomically (writeTVar slot (Uncertain (Text.pack (displayException exception))))
      rethrowIO failure
  | otherwise = do
      let reason = Text.pack (displayException exception)
      atomically (writeTVar slot (Uncertain reason))
      throwIO (RootDestructionFailed name reason)

-- ---------------------------------------------------------------------------
-- Observation

-- | Where every root stands, read in one transaction.
data RootsView = RootsView
  { viewInstance ∷ !RootStanding
  , viewMessenger ∷ !RootStanding
  , viewDevice ∷ !RootStanding
  , viewDeviceName ∷ !(Maybe Text)
  , viewQueueFamily ∷ !(Maybe Word32)
  , viewTargets ∷ ![TargetId]
  , viewAdmitting ∷ !Bool
  , viewLoss ∷ !(Maybe GraphicsDeviceLost)
  }
  deriving (Eq, Show)

readRootsView ∷ Roots q inst msgr phys dev → STM RootsView
readRootsView roots = do
  instanceRoot ← readTVar (rootsInstance roots)
  messenger ← readTVar (rootsMessenger roots)
  device ← readTVar (rootsDevice roots)
  targets ← readTVar (rootsTargets roots)
  admitting ← readTVar (rootsAdmitting roots)
  loss ← readTVar (rootsLoss roots)
  let plan = case device of
        Live selected → Just (selectedPlan selected)
        _ → Nothing
  pure
    RootsView
      { viewInstance = standingOf instanceRoot
      , viewMessenger = standingOf messenger
      , viewDevice = standingOf device
      , viewDeviceName = planDeviceName <$> plan
      , viewQueueFamily = planQueueFamily <$> plan
      , viewTargets = Map.keys targets
      , viewAdmitting = admitting && not (isJust loss)
      , viewLoss = loss
      }

-- | One target record, as any thread may read it.
data RootTargetView = RootTargetView
  { targetViewIdentity ∷ !TargetId
  , targetViewClass ∷ !TargetClass
  , targetViewSurface ∷ !Word64
  , targetViewUncertain ∷ !(Maybe Text)
  }
  deriving (Eq, Show)

readRootTargets ∷ Roots q inst msgr phys dev → STM [RootTargetView]
readRootTargets roots =
  map (\(target, record) → RootTargetView target (recordClass record) (recordSurface record) (recordUncertain record))
    . Map.toAscList
    <$> readTVar (rootsTargets roots)

-- | The retention model the roots keep their identities in.
readRootsModel ∷ Roots q inst msgr phys dev → STM GpuModel
readRootsModel = readTVar . rootsModel

-- | What the instance's destruction proved, once it has returned.
readRootsQuiesced ∷ Roots q inst msgr phys dev → STM (Maybe q)
readRootsQuiesced = readTVar . rootsQuiesced

-- | The session's device, with the plan it was selected by, once it is live.
readRootsDevice ∷ Roots q inst msgr phys dev → STM (Maybe (DevicePlan phys, dev))
readRootsDevice roots =
  readTVar (rootsDevice roots) >>= \case
    Live selected → pure (Just (selectedPlan selected, selectedDevice selected))
    _ → pure Nothing

-- | The live device and its naming call, when the instance enabled
-- @VK_EXT_debug_utils@ and the device offers one. 'Nothing' means nothing is
-- named or labelled, which is never a failure.
readRootsInstrumentation ∷ Roots q inst msgr phys dev → IO (Maybe (dev, Instrumentation))
readRootsInstrumentation roots = do
  (enabled, device) ← atomically ((,) <$> readTVar (rootsDebugUtils roots) <*> readRootsDevice roots)
  case device of
    Just (_, live) | enabled → fmap ((,) live) <$> opsInstrumentation (rootsOps roots) live
    _ → pure Nothing

-- | Name one native object through the device's naming call, on the owner's
-- thread, latching device loss if that is what it raised. A call that raised
-- named nothing, and its failure is the caller's.
nameRootsObject ∷ Roots q inst msgr phys dev → Instrumentation → NativeObjectKind → Word64 → ByteString → IO ()
nameRootsObject roots instrumentation kind handle name =
  guarded roots "vkSetDebugUtilsObjectNameEXT" (instrumentName instrumentation kind handle name)

-- | The generation calls of the roots' native layer.
rootsGenerationOps ∷ Roots q inst msgr phys dev → GenerationOps phys dev
rootsGenerationOps = opsGenerations . rootsOps

-- | Run one native call against the roots' device, latching device loss if
-- that is what it raised, exactly as the roots' own calls are run.
rootsCall ∷ Roots q inst msgr phys dev → Text → IO a → IO a
rootsCall = guarded

-- | Read and replace the roots' model in one transaction.
stateRootsModel ∷ Roots q inst msgr phys dev → (GpuModel → (a, GpuModel)) → STM a
stateRootsModel roots = stateTVar (rootsModel roots)

-- | Enter the session-level safety failure: an effect whose outcome is
-- unknown, or a cleanup that failed. Admission closes and the model's session
-- fails with the cause, in one transaction; nothing is rolled back, and every
-- parent of what is unverified stays retained.
failRootsSession ∷ Roots q inst msgr phys dev → SessionFailureCause → STM ()
failRootsSession roots cause = do
  writeTVar (rootsAdmitting roots) False
  modifyTVar' (rootsModel roots) (escalateSession cause)

-- | The live instance, for the caller that leases it to a surface bridge.
readRootsInstance ∷ Roots q inst msgr phys dev → STM (Maybe inst)
readRootsInstance roots =
  readTVar (rootsInstance roots) >>= \case
    Live created → pure (Just created)
    _ → pure Nothing
