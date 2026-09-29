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
-- retirement that follows is the ordinary child-before-parent one, and Vulkan
-- permits destroying a lost device's objects without waiting for work that may
-- never complete: what only the lost device could have discharged is released
-- by the frames' device-loss release, never completed. An outcome that is
-- unknown rather than lost is not loss: it is an uncertain destruction, and it
-- retains its parents.
--
-- = The terminal latch
--
-- The loss is one source of the session's terminal failure. The latch
-- ('latchTerminal') keeps the first failure from any source — the loss, a
-- validation error or sink failure a checkpoint learns from the diagnostic
-- watch, an uncertain effect, a failed cleanup, a required target's exhausted
-- recovery — as the primary, closes admission and fails the model's session
-- with it, and keeps every later failure, and what teardown retained, as
-- evidence beside it. The loss itself is kept apart from the primary, so a
-- later loss switches the teardown to its rules without displacing an earlier
-- failure. A checkpoint ('checkpointRoots', 'checkRoots') asks the watch and
-- answers the primary; retirement never passes through one.
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
-- |                  |           | retirement removes; recovery|            | destroyed        | destruction that returned |
-- |                  |           | releases and replaces a lost|            |                  |                           |
-- |                  |           | surface in place            |            |                  |                           |
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
-- | The model        | The roots | Admission, retirement and   | As above   | The session      | Never reset               |
-- |                  |           | loss                        |            |                  |                           |
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
-- | The loss latch   | The roots | Set once; any thread reads  | Any        | The session      | Never cleared             |
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
-- | Disposers        | The roots | Each layer above registers  | The owner  | The session      | Never removed             |
-- |                  |           | its own as it is made; a    |            |                  |                           |
-- |                  |           | reclamation pass reads them |            |                  |                           |
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
-- | The terminal     | The roots | 'latchTerminal' sets the    | Any, in    | The session      | Never cleared; evidence   |
-- | latch            |           | primary once and appends    | STM        |                  | bounded, the rest counted |
-- |                  |           | evidence; any thread reads  |            |                  |                           |
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
-- | The diagnostic   | The roots | Installed once; every       | The owner  | The session      | —                         |
-- | watch            |           | checkpoint reads it         |            |                  |                           |
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
-- | Owner claims     | The roots | A claiming attempt enters a | Any; not   | The session      | An attempt is dropped     |
-- |                  |           | weak token and writes it    | STM, so an |                  | once a collection finds   |
-- |                  |           | into its log; checkpoints   | abandoned  |                  | its token gone            |
-- |                  |           | and later claims read them  | claim stays|                  |                           |
-- +------------------+-----------+-----------------------------+------------+------------------+---------------------------+
--
-- Every mutating operation is meant for one serialized owner — the graphics
-- owner's thread — and none is safe to run concurrently with another.
module Hetoimasia.GPU.Vulkan.Native.Roots
  ( -- * The native layer
    RootOps (..)
  , GenerationOps (..)
  , SwapchainRequest (..)
  , NativeFailure (..)

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
  , releaseRootSurface
  , installRootSurface
  , rootSurfaceHeld
  , SurfaceStillHeld (..)
  , RootsNotStarted (..)
  , UnknownRootTarget (..)
  , SurfaceDestructionFailed (..)
  , TargetGenerationsRemain (..)

    -- * Device loss
  , GraphicsDeviceLost (..)
  , latchDeviceLoss
  , checkRoots

    -- * The terminal latch
  , TerminalCause (..)
  , TeardownEvidence (..)
  , TerminalReport (..)
  , GraphicsSessionFailed (..)
  , DiagnosticAlarm (..)
  , Checkpoint (..)
  , terminalEvidenceLimit
  , latchTerminal
  , noteTeardownEvidence
  , watchRootsDiagnostics
  , watchRootsDiagnosticsOrdered
  , DiagnosticWatch (..)
  , DiagnosticOrder (..)
  , DiagnosticArrivals (..)
  , noDiagnosticArrivals
  , checkpointRoots
  , syncRootsDiagnostics
  , checkpointRootsSettled
  , readRootsTerminal
  , terminalFailure

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
  , rootsNativeFailure
  , rootsCall
  , stateRootsModel
  , failRootsSession
  , failRootsSessionBecause

    -- * Reclamation (VK-14)
  , SubjectDisposer (..)
  , registerRootsDisposer
  , readRootsDisposers
  ) where

import Control.Concurrent (threadDelay, yield)
import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import GHC.Conc (unsafeIOToSTM)
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
  , toException
  , tryWithContext
  )
import Control.Monad (filterM, unless, when)
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', mkWeakIORef, newIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.List ((\\))
import Data.Maybe (isJust, isNothing)
import System.Mem (performMajorGC)
import System.Mem.Weak (Weak, deRefWeak)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Unique (Unique, newUnique)
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)
import Hetoimasia.Foundation.Time (MonotonicSource, readInstant)
import Hetoimasia.GPU.Model
  ( DisposalResult
  , Escalation (..)
  , GpuModel
  , Outcome (..)
  , SessionFailureCause (..)
  , SessionState (..)
  , TargetPhase (TargetRetiring, TargetUnavailable)
  , TargetView (viewTargetGenerations, viewTargetPhase)
  , admitTarget
  , closeTarget
  , escalateSession
  , escalations
  , newGpuModel
  , noteDeviceLoss
  , runProgressTurn
  , sessionState
  , silentEvidence
  , targetView
  )
import Hetoimasia.GPU.Model.Budget (Budgets)
import Hetoimasia.GPU.Model.Identity (DeviceId, HoldSubject, SessionIdentity, TargetClass, TargetId, sessionIdentity)
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
  , opsNativeFailure ∷ SomeException → Maybe NativeFailure
    -- ^ Which of the results recovery acts on a failure one of these calls
    -- raised was, if any (VK-14). Device loss is 'opsDeviceLoss''s, never
    -- this.
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

-- | A native result recovery acts on, as the layer classifies a failure a call
-- raised.
data NativeFailure
  = FailedOutOfMemory
    -- ^ @VK_ERROR_OUT_OF_HOST_MEMORY@ or @VK_ERROR_OUT_OF_DEVICE_MEMORY@. Only
    -- the operation that raised it knows whether it had any effect.
  | FailedSurfaceLost
    -- ^ @VK_ERROR_SURFACE_LOST_KHR@: the target's surface is unusable, and
    -- recovering it needs a new one on the same window.
  | FailedNativeWindowInUse
    -- ^ @VK_ERROR_NATIVE_WINDOW_IN_USE_KHR@: a swapchain Vulkan still counts
    -- as the window's is in the way.
  deriving (Eq, Ord, Show)

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
    -- ^ The surface held, or the last one when none is ('recordDestroy').
  , recordDestroy ∷ !(Maybe (IO SurfaceDestruction))
    -- ^ How the surface held is destroyed; 'Nothing' once recovery released a
    -- lost one ('releaseRootSurface') and until a replacement is installed.
  , recordUncertain ∷ !(Maybe Text)
  }

-- | How a layer above the roots disposes of the subjects it owns, for a
-- reclamation pass (VK-14): the roots know no generation's or managed
-- resource's native objects, and each layer registers what destroys its own.
data SubjectDisposer = SubjectDisposer
  { disposerDispose ∷ HoldSubject → IO (Maybe DisposalResult)
    -- ^ Destroy the subject natively, on the owner's thread, if it is this
    -- layer's and every native object above it allows it now, answering what
    -- the destruction did; 'Nothing', having made no call, otherwise. A
    -- destruction and the record of it are one masked step, as the layer's
    -- own disposal makes them.
  , disposerForget ∷ [HoldSubject] → STM ()
    -- ^ Forget the native records of subjects the model has recorded as
    -- disposed, in the transaction that recorded them.
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
    -- ^ The first loss observed, whatever failed the session first.
  , rootsTerminal ∷ !(TVar TerminalReport)
    -- ^ The terminal latch: the primary failure and what teardown found after
    -- it.
  , rootsWatch ∷ !(TVar DiagnosticWatch)
    -- ^ What a checkpoint asks of the diagnostic capture.
  , rootsClaims ∷ !(IORef OwnerClaims)
    -- ^ The transaction attempts that have claimed the capture's order for a
    -- failure of the owner's own. Not transactional: a claim outlives the
    -- attempt that made it, and so must this record of it.
  , rootsClaimHold ∷ !(TVar (Maybe (IORef ())))
    -- ^ Written by each claiming attempt with its own token, which its
    -- transaction's log then keeps alive until it commits or is discarded.
  , rootsDebugUtils ∷ !(TVar Bool)
    -- ^ Whether the instance was created with @VK_EXT_debug_utils@.
  , rootsNamed ∷ !(TVar Bool)
    -- ^ Whether the device and its queue have been named.
  , rootsDisposers ∷ !(TVar [SubjectDisposer])
    -- ^ What each layer above disposes of its own subjects with, registered
    -- as the layer is made.
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
    <*> newTVarIO (TerminalReport Nothing Nothing [] 0)
    <*> newTVarIO (DiagnosticWatch (pure []) (pure (OwnerFirst noDiagnosticArrivals)))
    <*> newIORef (OwnerClaims False [])
    <*> newTVarIO Nothing
    <*> newTVarIO False
    <*> newTVarIO False
    <*> newTVarIO []
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

-- | A replacement surface was offered for a target that still holds one.
newtype SurfaceStillHeld = SurfaceStillHeld TargetId
  deriving (Eq, Show)

instance Exception SurfaceStillHeld

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
                      Map.insert target (TargetRecord classification handle (Just (targetSurfaceDestroy surface)) Nothing)
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
        let forget = atomically $ do
              modifyTVar' (rootsTargets roots) (Map.delete target)
              modifyTVar' (rootsModel roots) $ \model → case closeTarget target model of
                -- The model forgets a retiring target with nothing left at
                -- its next progress turn, which frees its record for a later
                -- one.
                Admitted closed → fst (runProgressTurn silentEvidence now closed)
                _ → model
        case recordDestroy record of
          -- Recovery already destroyed the lost surface, and nothing replaced
          -- it: there is nothing left to destroy.
          Nothing → forget
          Just destroy →
            mask_ $
              tryWithContext destroy >>= \case
                Right SurfaceDestroyed → forget
                Right (SurfaceDestructionUncertain failure) → settleUncertain roots target failure
                Left failure → settleUncertain roots target failure

-- | Record a surface destruction that did not complete as uncertain, never to be
-- attempted again, and raise 'SurfaceDestructionFailed' — or re-raise the
-- cancellation that ended it. A failed cleanup is latched as a terminal
-- failure, whether retirement or recovery attempted it, and is never
-- permission to try again.
settleUncertain ∷ Roots q inst msgr phys dev → TargetId → ExceptionWithContext SomeException → IO a
settleUncertain roots target failure@(ExceptionWithContext _ exception) = do
  let reason = Text.pack (displayException exception)
  atomically $ do
    modifyTVar' (rootsTargets roots) (Map.adjust (\held → held {recordUncertain = Just reason}) target)
    -- A failed cleanup is a terminal failure of its own, or evidence beside
    -- an earlier one.
    latchTerminal roots (TerminalCleanupFailed ("destroying the surface of " <> Text.pack (show target) <> ": " <> reason))
  if isAsynchronous exception
    then rethrowIO failure
    else throwIO (SurfaceDestructionFailed target reason)

-- | Destroy a target's lost surface and keep the target, so a replacement can
-- be installed on the same window (VK-14).
--
-- It is refused, with 'TargetGenerationsRemain', while the model holds any
-- swapchain generation of the target: they are the surface's children and go
-- first. The destruction runs once, masked with its record, as
-- 'retireRootTarget''s does; one that did not complete is uncertain, retained
-- with the device and the instance above it, never attempted again, and fails
-- the session with 'CleanupFailed' before 'SurfaceDestructionFailed' is
-- raised. A surface already released is released: nothing is called.
releaseRootSurface ∷ Roots q inst msgr phys dev → TargetId → IO ()
releaseRootSurface roots target =
  readTVarIO (rootsTargets roots) >>= \records → case Map.lookup target records of
    Nothing → throwIO (UnknownRootTarget target)
    Just record → case (recordUncertain record, recordDestroy record) of
      (Just reason, _) → throwIO (SurfaceDestructionFailed target reason)
      (Nothing, Nothing) → pure ()
      (Nothing, Just destroy) → do
        remaining ← atomically (maybe 0 viewTargetGenerations . targetView target <$> readTVar (rootsModel roots))
        when (remaining > 0) (throwIO (TargetGenerationsRemain target remaining))
        mask_ $
          tryWithContext destroy >>= \case
            Right SurfaceDestroyed →
              atomically (modifyTVar' (rootsTargets roots) (Map.adjust (\held → held {recordDestroy = Nothing}) target))
            Right (SurfaceDestructionUncertain failure) → settleUncertain roots target failure
            Left failure → settleUncertain roots target failure

-- | Install a replacement surface for a target whose lost surface was released,
-- once the session's device can still present to it (VK-14).
--
-- The surface is checked against the session's one queue family with
-- @vkGetPhysicalDeviceSurfaceSupportKHR@, as a later target's is at
-- admission; one it cannot present to is refused with
-- 'TargetSurfaceUnsupported', and no second device or queue is ever made. A
-- target that has begun retiring, or is unavailable, and roots that admit
-- nothing more refuse it with 'TargetAdmissionClosed': close wins over a late
-- replacement. On 'Right' the roots own the surface and destroy it as the
-- target's; on 'Left', or a raise, it is still its creator's. A target that
-- still holds a surface raises 'SurfaceStillHeld'.
installRootSurface ∷ Roots q inst msgr phys dev → TargetId → TargetSurface → IO (Either TargetRejection ())
installRootSurface roots target surface = do
  open ← atomically ((&&) <$> readTVar (rootsAdmitting roots) <*> (not . isJust <$> readTVar (rootsLoss roots)))
  records ← readTVarIO (rootsTargets roots)
  case Map.lookup target records of
    Nothing → throwIO (UnknownRootTarget target)
    Just record
      | isJust (recordDestroy record) → throwIO (SurfaceStillHeld target)
      | not open || isJust (recordUncertain record) → pure (Left TargetAdmissionClosed)
      | otherwise → do
          closing ← atomically (retiringTarget <$> readTVar (rootsModel roots))
          (instanceRoot, device) ← atomically ((,) <$> readTVar (rootsInstance roots) <*> readTVar (rootsDevice roots))
          case (instanceRoot, device) of
            _ | closing → pure (Left TargetAdmissionClosed)
            (Live created, Live selected) → do
              let plan = selectedPlan selected
              supported ←
                guarded roots "vkGetPhysicalDeviceSurfaceSupportKHR" $
                  opsSurfaceSupport (rootsOps roots) created (planDevice plan) (planQueueFamily plan) handle
              if not supported
                then pure (Left (TargetSurfaceUnsupported (planQueueFamily plan)))
                else do
                  instrumented ← readRootsInstrumentation roots
                  for_ instrumented $ \(_, instrumentation) →
                    nameRootsObject roots instrumentation ObjectSurface handle (surfaceName target)
                  atomically $ do
                    model ← readTVar (rootsModel roots)
                    held ← Map.lookup target <$> readTVar (rootsTargets roots)
                    case held of
                      Just current
                        | not (retiringTarget model)
                        , Nothing ← recordDestroy current → do
                            modifyTVar' (rootsTargets roots) $
                              Map.insert target current {recordSurface = handle, recordDestroy = Just (targetSurfaceDestroy surface)}
                            pure (Right ())
                      _ → pure (Left TargetAdmissionClosed)
            _ → pure (Left TargetAdmissionClosed)
  where
    handle = targetSurfaceHandle surface
    retiringTarget model = maybe True ((`elem` [TargetRetiring, TargetUnavailable]) . viewTargetPhase) (targetView target model)

-- ---------------------------------------------------------------------------
-- Device loss

-- | Run one native call, latching device loss if that is what it raised.
--
-- The call runs in the caller's masking state; the loss it raised is latched
-- with asynchronous exceptions masked from the moment it returns, whatever
-- that state was, so a cancellation cannot land between the loss and its
-- latch, nor inside the latch's transaction, which never blocks.
guarded ∷ Roots q inst msgr phys dev → Text → IO a → IO a
guarded roots during call =
  mask $ \restore → tryWithContext (restore call) >>= \case
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

-- | Latch a device loss: close admission, fail the model's session and record
-- the loss in it, in one transaction. The first loss is kept, and so is any
-- earlier primary failure: the loss is then recorded beside it, and what it
-- changes is the rules the teardown follows.
latchDeviceLoss ∷ Roots q inst msgr phys dev → GraphicsDeviceLost → IO ()
latchDeviceLoss roots loss = atomically (latchTerminal roots (TerminalDeviceLost loss))

-- | A checkpoint that raises: the latched primary failure, if there is one —
-- the loss as itself, anything else as 'GraphicsSessionFailed'. It is what a
-- progress step calls, so an owner whose failure was latched outside a call
-- it made still ends its run with that failure. A pending diagnostic failure
-- raises nothing here; the checkpoint that can latch it raises it.
checkRoots ∷ Roots q inst msgr phys dev → IO ()
checkRoots roots =
  checkpointRoots roots >>= \case
    CheckpointFailed primary → throwIO (terminalFailure primary)
    _ → pure ()

-- ---------------------------------------------------------------------------
-- The terminal latch

-- | Why a graphics session ended.
data TerminalCause
  = TerminalDeviceLost !GraphicsDeviceLost
    -- ^ A queue or device call answered @VK_ERROR_DEVICE_LOST@ (D-17).
  | TerminalValidationError
    -- ^ The diagnostic capture latched an error-severity report (D-20). The
    -- report itself is the capture's, and its verdict carries it.
  | TerminalSinkFailed !Text
    -- ^ The diagnostic consumer's sink failed (D-19): a terminal status of its
    -- own, never a graphics failure's replacement.
  | TerminalUncertainEffect !Text
    -- ^ A native effect whose outcome is unknown; what it concerns is retained.
  | TerminalCleanupFailed !Text
    -- ^ A cleanup that raised; what it concerns is retained, never retried.
  | TerminalRequiredTarget !(Maybe TargetId)
    -- ^ A required target's recovery was exhausted (D-22).
  deriving (Eq, Show)

-- | Something the teardown found after the primary failure. It joins the
-- report beside the primary and never displaces it.
data TeardownEvidence
  = LaterFailure !TerminalCause
    -- ^ A failure after the first: a cleanup failure, an uncertain effect, a
    -- loss observed after another cause, a sink failure.
  | RetainedUnverified !Text
    -- ^ Something whose disposal could not be verified, and which is
    -- therefore retained with every parent it has.
  deriving (Eq, Show)

-- | The terminal latch as it stands: the primary failure, the device's loss if
-- it was observed — which may be later than the primary, and is what switches
-- a teardown to the device-loss rules — and the evidence teardown found after
-- the primary, oldest first, with how much of it was dropped to keep it
-- finite.
data TerminalReport = TerminalReport
  { reportPrimary ∷ !(Maybe TerminalCause)
  , reportDeviceLost ∷ !(Maybe GraphicsDeviceLost)
  , reportEvidence ∷ ![TeardownEvidence]
  , reportEvidenceDropped ∷ !Natural
  }
  deriving (Eq, Show)

-- | How much teardown evidence the latch keeps. The oldest is kept and later
-- evidence beyond this is counted rather than kept: the first failures after
-- the primary are the ones that explain it.
terminalEvidenceLimit ∷ Int
terminalEvidenceLimit = 64

-- | A terminal failure other than device loss, as a checkpoint raises it.
newtype GraphicsSessionFailed = GraphicsSessionFailed TerminalCause
  deriving (Eq, Show)

instance Exception GraphicsSessionFailed where
  displayException (GraphicsSessionFailed cause) = "the graphics session has failed: " <> Text.unpack (describeCause cause)

-- | The primary failure as a checkpoint raises it: a loss as itself, anything
-- else as 'GraphicsSessionFailed'.
terminalFailure ∷ TerminalCause → SomeException
terminalFailure = \case
  TerminalDeviceLost loss → toException loss
  cause → toException (GraphicsSessionFailed cause)

describeCause ∷ TerminalCause → Text
describeCause = \case
  TerminalDeviceLost loss → Text.pack (displayException loss)
  TerminalValidationError → "the validation capture latched an error-severity report"
  TerminalSinkFailed reason → "the diagnostic sink failed: " <> reason
  TerminalUncertainEffect reason → "a native effect's outcome is unknown: " <> reason
  TerminalCleanupFailed reason → "a cleanup did not complete: " <> reason
  TerminalRequiredTarget target → "the recovery of the required target " <> maybe "" (Text.pack . show) target <> " was exhausted"

-- | What a checkpoint learns from the diagnostic capture.
data DiagnosticAlarm
  = AlarmValidationError
    -- ^ The capture's error latch is set.
  | AlarmSinkFailed !Text
    -- ^ The capture's consumer met a sink failure.
  | AlarmPending
    -- ^ A diagnostic failure has happened, but the capture cannot yet say
    -- which came first: admission stays closed, and nothing is latched until
    -- it can.
  | AlarmOwnerClaimed
    -- ^ A failure of the owner's own claimed first place in the capture's
    -- order: until its transaction has recorded it, admission stays closed
    -- and nothing is latched ahead of it.
  deriving (Eq, Show)

-- | What a checkpoint answers.
data Checkpoint
  = CheckpointClear
    -- ^ No failure is known: new work may proceed.
  | CheckpointFailed !TerminalCause
    -- ^ The session has failed, with this primary.
  | CheckpointPending
    -- ^ A diagnostic failure has happened whose order is not yet readable:
    -- new work is refused, nothing is latched, and a later checkpoint latches
    -- it in order.
  deriving (Eq, Show)

-- | The model's cause, for a terminal cause.
modelCause ∷ TerminalCause → SessionFailureCause
modelCause = \case
  TerminalDeviceLost _ → DeviceLost
  TerminalValidationError → ValidationError
  TerminalSinkFailed _ → DiagnosticSinkFailed
  TerminalUncertainEffect _ → UnknownSubmissionEffect
  TerminalCleanupFailed _ → CleanupFailed
  TerminalRequiredTarget _ → RequiredTargetUnrecoverable

-- | The terminal cause a model's own failure stands for, when the model failed
-- by itself — a required target's exhausted recovery, or a disposal it
-- offered that failed — rather than through the latch.
fromModel ∷ GpuModel → Maybe TerminalCause
fromModel model = case sessionState model of
  SessionRunning → Nothing
  SessionFailed cause → Just $ case cause of
    DeviceLost → TerminalDeviceLost (GraphicsDeviceLost "the model" "the session's device was lost")
    ValidationError → TerminalValidationError
    DiagnosticSinkFailed → TerminalSinkFailed "the diagnostic sink failed"
    UnknownSubmissionEffect → TerminalUncertainEffect "the model recorded an effect whose outcome is unknown"
    CleanupFailed → TerminalCleanupFailed "a disposal the model offered failed"
    RequiredTargetUnrecoverable →
      TerminalRequiredTarget (case [target | RequiredTargetFailedSession target ← escalations model] of
        target : _ → Just target
        [] → Nothing)

-- | Latch a terminal failure, in one transaction: the first is the primary,
-- and the model's session fails with it; a later one joins the evidence
-- beside it. Admission closes either way, and a device loss is also recorded
-- as the loss, however late it came.
--
-- A model that failed by itself before anything was latched was first, and
-- its cause is the primary — unless it is the same kind of failure this one
-- describes, which is then the primary with its detail: a transition that
-- recorded an uncertain effect in the model and the latch that says what the
-- effect was are one failure, not two.
--
-- A failure of the owner's own — a loss, a cleanup, an uncertain effect —
-- that would be the primary first asks the diagnostic capture for the order
-- ('orderBehindDiagnostics'): a validation error or sink failure that claimed
-- first place before it is latched ahead of it.
latchTerminal ∷ Roots q inst msgr phys dev → TerminalCause → STM ()
latchTerminal roots cause = do
  unless (diagnostic cause) (orderBehindDiagnostics roots)
  latchCause roots cause
  where
    diagnostic = \case
      TerminalValidationError → True
      TerminalSinkFailed _ → True
      _ → False

-- | Before a failure of the owner's own takes first place — nothing latched,
-- and the model has not failed by itself — claim the capture's order for it.
-- A diagnostic failure that claimed first is latched here, ahead of it: a
-- validation error at once, a sink failure once the worker has published its
-- reason. The claim is the capture's one compare-and-swap, which answers the
-- same however often a transaction runs it.
--
-- It never blocks the transaction ('retry' would make it interruptible under
-- 'mask_', and an owner's masked record could then lose its whole
-- transaction to a cancellation). Its waits — for a sink failure that holds
-- first place to publish its reason, and for a failure that arrived behind a
-- void claim to become readable — are 'awaitPublication' and
-- 'awaitArrivals', inside the transaction.
--
-- A claim holds first place only for the transaction attempt that made it
-- ('claimHeld'). A claim made before, that no attempt which could still
-- commit holds, is void: it still holds the capture's slot, so the claim
-- made now answers 'OwnerFirst' however much came after it. Its order point
-- is then the capture's arrivals, read right after its claim: each diagnostic
-- failure that had arrived by then is latched ahead of it, once readable, and
-- one that arrives after comes after it, as it would behind a claim of its own.
orderBehindDiagnostics ∷ Roots q inst msgr phys dev → STM ()
orderBehindDiagnostics roots = do
  report ← readTVar (rootsTerminal roots)
  model ← readTVar (rootsModel roots)
  when (isNothing (reportPrimary report) && isNothing (fromModel model)) $ do
    watch ← readTVar (rootsWatch roots)
    (token, ahead) ← unsafeIOToSTM $ do
      token ← newIORef ()
      attempt ← newUnique
      held ← mkWeakIORef token (pure ())
      -- Entered before the claim, so a checkpoint that reads the claim reads
      -- this attempt too.
      made ← atomicModifyIORef' (rootsClaims roots) $ \claims →
        (OwnerClaims True ((attempt, held) : claimAttempts claims), claimsMade claims)
      void ← if made then not <$> claimHeld roots (Just attempt) else pure False
      ahead ← watchOrder watch >>= \case
        OwnerFirst arrived
          | void → awaitArrivals watch arrived
          | otherwise → pure []
        ValidationFirst → pure [AlarmValidationError]
        SinkFirst published → (\reason → [AlarmSinkFailed reason]) <$> awaitPublication published
      pure (token, ahead)
    -- The token is written into this attempt's own log, which keeps it alive
    -- while the attempt may still commit, and only while it may.
    writeTVar (rootsClaimHold roots) (Just token)
    latchAlarms roots ahead

-- | Wait for the reason of a sink failure that claimed first place. The worker
-- publishes it right after its claim, in one masked step that makes no native
-- call, delivers nothing to the sink and waits on nothing, so the wait is
-- bounded by that thread's CPU bookkeeping alone — never by a driver, the
-- sink, or anything the owner does. It promises no wall-clock bound.
--
-- It runs inside the owner's transaction and only yields between looks. Nothing
-- in it is interruptible, so a masked caller's record cannot be cancelled here
-- and an unmasked caller's can, exactly as anywhere else in its transaction;
-- it adds no masking of its own.
awaitPublication ∷ IO (Maybe Text) → IO Text
awaitPublication published = published >>= maybe (yield >> awaitPublication published) pure

-- | The alarms of the diagnostic failures that had arrived by a claim over a
-- void one, once each is readable — the validation error, then the sink's
-- failure, as the capture answers two that came after the owner's claim. A
-- failure sets its alarm right after recording its arrival — an error's
-- callback at its next step, the sink's worker in the masked step that noted
-- it — so this is bounded as 'awaitPublication' is, and waits the same way.
awaitArrivals ∷ DiagnosticWatch → DiagnosticArrivals → IO [DiagnosticAlarm]
awaitArrivals watch arrived = do
  alarms ← watchAlarms watch
  let errors = [AlarmValidationError | validationArrived arrived, AlarmValidationError `elem` alarms]
      sinks = take 1 [alarm | sinkArrived arrived, alarm@(AlarmSinkFailed _) ← alarms]
  if (validationArrived arrived && null errors) || (sinkArrived arrived && null sinks)
    then yield >> awaitArrivals watch arrived
    else pure (errors <> sinks)

-- | Whether a transaction attempt that claimed the capture's order — other
-- than this one — may still commit.
--
-- Each attempt's token is held here only weakly; the attempt itself keeps it
-- alive, from its stack until it writes it into its transaction's log
-- ('rootsClaimHold') and from that log until it commits. An attempt that is
-- abandoned — by an exception, or run again — is discarded with its log, so
-- once a collection has run its token is gone, whatever its thread goes on to
-- do. A major collection is run only when some token still answers, and those
-- gone are dropped.
claimHeld ∷ Roots q inst msgr phys dev → Maybe Unique → IO Bool
claimHeld roots this =
  answering >>= \case
    False → pure False
    True → performMajorGC >> answering
  where
    answering = do
      attempts ← filter ((/= this) . Just . fst) . claimAttempts <$> atomicModifyIORef' (rootsClaims roots) (\claims → (claims, claims))
      alive ← filterM (fmap isJust . deRefWeak . snd) attempts
      let gone = map fst attempts \\ map fst alive
      atomicModifyIORef' (rootsClaims roots) (\claims → (claims {claimAttempts = filter ((`notElem` gone) . fst) (claimAttempts claims)}, ()))
      pure (not (null alive))

-- | The claims of the capture's order made for failures of the owner's own
-- ('orderBehindDiagnostics'): whether one ever has been, and each attempt
-- that made one that has not yet been found gone.
data OwnerClaims = OwnerClaims
  { claimsMade ∷ !Bool
  , claimAttempts ∷ ![(Unique, Weak (IORef ()))]
  }

latchCause ∷ Roots q inst msgr phys dev → TerminalCause → STM ()
latchCause roots cause = do
  model ← readTVar (rootsModel roots)
  report ← readTVar (rootsTerminal roots)
  case reportPrimary report of
    Nothing → do
      let primary = case fromModel model of
            Just first | modelCause first /= modelCause cause → first
            _ → cause
      writeTVar (rootsTerminal roots) report {reportPrimary = Just primary}
      unless (primary == cause) (noteTeardownEvidence roots (LaterFailure cause))
    Just primary → unless (primary == cause) (noteTeardownEvidence roots (LaterFailure cause))
  writeTVar (rootsAdmitting roots) False
  case cause of
    TerminalDeviceLost loss → do
      held ← readTVar (rootsLoss roots)
      unless (isJust held) (writeTVar (rootsLoss roots) (Just loss))
      modifyTVar' (rootsTerminal roots) (\current → current {reportDeviceLost = Just (maybe loss id (reportDeviceLost current))})
      modifyTVar' (rootsModel roots) noteDeviceLoss
    _ → modifyTVar' (rootsModel roots) (escalateSession (modelCause cause))

-- | Keep one piece of teardown evidence beside the primary, within
-- 'terminalEvidenceLimit'. The same evidence twice is kept once.
noteTeardownEvidence ∷ Roots q inst msgr phys dev → TeardownEvidence → STM ()
noteTeardownEvidence roots evidence =
  modifyTVar' (rootsTerminal roots) $ \report →
    if evidence `elem` reportEvidence report
      then report
      else
        if length (reportEvidence report) >= terminalEvidenceLimit
          then report {reportEvidenceDropped = reportEvidenceDropped report + 1}
          else report {reportEvidence = reportEvidence report <> [evidence]}

-- | Who holds first place in the diagnostic capture's order once a failure of
-- the owner's own has claimed it.
data DiagnosticOrder
  = OwnerFirst !DiagnosticArrivals
    -- ^ No diagnostic failure came before it; and which had arrived, read
    -- right after the claim, which orders it behind them when the claim it
    -- found was void ('orderBehindDiagnostics').
  | ValidationFirst
    -- ^ An error-severity report came first.
  | SinkFirst !(IO (Maybe Text))
    -- ^ The sink failed first; its reason, once the worker has published it.
    -- It is read inside the owner's transaction, so it runs no transaction
    -- of its own.

-- | Which diagnostic failures had arrived, whether or not they claimed first
-- place: the capture records each arrival before its claim.
data DiagnosticArrivals = DiagnosticArrivals
  { validationArrived ∷ !Bool
  , sinkArrived ∷ !Bool
  }
  deriving (Eq, Show)

-- | No diagnostic failure has arrived.
noDiagnosticArrivals ∷ DiagnosticArrivals
noDiagnosticArrivals = DiagnosticArrivals False False

-- | What the roots ask of the diagnostic capture: its alarms, at a checkpoint,
-- and the order, before a failure of the owner's own is latched or taken by
-- the model. Claiming the order runs inside that transaction, so it must
-- answer the same however often it runs and must run no transaction of its
-- own. The alarms are read there too, after a claim over a void one, to
-- latch what had arrived ahead of it ('orderBehindDiagnostics'); they must run
-- no transaction of their own either.
data DiagnosticWatch = DiagnosticWatch
  { watchAlarms ∷ IO [DiagnosticAlarm]
  , watchOrder ∷ IO DiagnosticOrder
  }

-- | Install what a checkpoint asks of a diagnostic capture that keeps no order
-- of its own: its alarms are latched at checkpoints, and a failure of the
-- owner's is never ordered behind them. Roots with none installed hear no
-- alarm.
watchRootsDiagnostics ∷ Roots q inst msgr phys dev → IO [DiagnosticAlarm] → STM ()
watchRootsDiagnostics roots alarms = writeTVar (rootsWatch roots) (DiagnosticWatch alarms (pure (OwnerFirst noDiagnosticArrivals)))

-- | Install a diagnostic capture that keeps the order itself.
watchRootsDiagnosticsOrdered ∷ Roots q inst msgr phys dev → DiagnosticWatch → STM ()
watchRootsDiagnosticsOrdered roots = writeTVar (rootsWatch roots)

-- | A safe owner checkpoint: ask the diagnostic capture for its alarms and
-- latch each — an error-severity report as 'TerminalValidationError', a sink
-- failure as 'TerminalSinkFailed' — take a failure the model recorded by
-- itself as the primary if nothing was latched before it, and answer the
-- primary. It raises nothing, calls nothing native, and waits for nothing.
--
-- While the capture says a failure is pending ('AlarmPending'), or that a
-- failure of the owner's own holds first place ('AlarmOwnerClaimed') and a
-- transaction that claimed it may still record it, it latches nothing —
-- neither the capture's alarms nor the model's own failure, which might
-- otherwise be taken ahead of the diagnostic failure that came first — and
-- answers an earlier primary if there is one, 'CheckpointPending' otherwise,
-- so admission stays closed until a later checkpoint can latch them in order.
--
-- A claim whose transaction attempt was abandoned holds nothing back
-- ('claimHeld'): once no attempt that claimed can still commit, the alarms
-- beside the claim are latched as usual, whatever the claiming thread goes on
-- to do. A diagnostic failure that arrived behind that claim is answered
-- pending until its own alarm is readable, and then latched.
--
-- Only the owner's ordinary operations checkpoint. Retirement does not: it
-- runs because the session has failed, and a checkpoint there would only
-- rethrow that.
checkpointRoots ∷ Roots q inst msgr phys dev → IO Checkpoint
checkpointRoots roots = do
  alarms ← watchAlarms =<< readTVarIO (rootsWatch roots)
  -- The claiming attempts are read after the alarms, and each entered before
  -- it claimed, so the claim these alarms name has its attempt here.
  -- Only while nothing has recorded a failure is there a claim to ask after:
  -- once one is latched the capture answers the claim for good.
  unrecorded ← atomically ((&&) <$> (isNothing . reportPrimary <$> readTVar (rootsTerminal roots)) <*> (isNothing . fromModel <$> readTVar (rootsModel roots)))
  claimed ← if AlarmOwnerClaimed `elem` alarms && unrecorded then claimHeld roots Nothing else pure False
  atomically $ do
    latched ← reportPrimary <$> readTVar (rootsTerminal roots)
    modelled ← fromModel <$> readTVar (rootsModel roots)
    -- The owner's own failure claimed first place but its transaction has not
    -- recorded it yet: an alarm latched now would take a place that is its.
    let ownerInFlight = claimed && isNothing latched && isNothing modelled
    if AlarmPending `elem` alarms || ownerInFlight
      then pure (maybe CheckpointPending CheckpointFailed latched)
      else do
        latchAlarms roots alarms
        report ← readTVar (rootsTerminal roots)
        case reportPrimary report of
          Just primary → pure (CheckpointFailed primary)
          Nothing → do
            model ← readTVar (rootsModel roots)
            case fromModel model of
              Nothing → pure CheckpointClear
              Just first → do
                latchTerminal roots first
                pure (CheckpointFailed first)

-- | Latch what the diagnostic capture already holds, just before the owner
-- records a failure of its own that the model may take by itself — a required
-- target's exhausted recovery, a submission whose effect is unknown — so a
-- diagnostic failure that happened first is the primary, and the one recorded
-- after it joins the evidence.
--
-- A failure that has claimed the capture's order but not yet published its
-- alarm happened first too, so this waits until it is readable: the capture's
-- worker publishes its sink failure right after its claim with asynchronous
-- exceptions masked, and its callback sets the error latch right after its
-- own, so the wait ends however long the claimant's thread is delayed. It
-- yields at first and then sleeps briefly between looks. It is not a
-- checkpoint: it refuses nothing, and only the owner's failure and admission
-- paths call it.
syncRootsDiagnostics ∷ Roots q inst msgr phys dev → IO ()
syncRootsDiagnostics roots = go (0 ∷ Int)
  where
    go looked = do
      alarms ← watchAlarms =<< readTVarIO (rootsWatch roots)
      if AlarmPending `elem` alarms
        then pause looked >> go (looked + 1)
        else atomically (latchAlarms roots alarms)
    pause looked
      | looked < syncYields = yield
      | otherwise = threadDelay syncPause

-- | How many times 'syncRootsDiagnostics' yields before it sleeps between
-- looks, and for how long it then sleeps, in microseconds.
syncYields, syncPause ∷ Int
syncYields = 10000
syncPause = 100

-- | A checkpoint for the owner's own admission of new work, which may wait: it
-- latches what the capture holds ('syncRootsDiagnostics') and waits out a
-- pending answer — an alarm under publication, or a failure of the owner's
-- own whose transaction has not recorded it yet — so it never answers
-- 'CheckpointPending'.
checkpointRootsSettled ∷ Roots q inst msgr phys dev → IO Checkpoint
checkpointRootsSettled roots = go (0 ∷ Int)
  where
    go looked = do
      syncRootsDiagnostics roots
      checkpointRoots roots >>= \case
        CheckpointPending → (if looked < syncYields then yield else threadDelay syncPause) >> go (looked + 1)
        settled → pure settled

-- | Latch each alarm the capture named, in its order.
latchAlarms ∷ Roots q inst msgr phys dev → [DiagnosticAlarm] → STM ()
latchAlarms roots alarms = mapM_ (latchCause roots) [cause | Just cause ← map alarmCause alarms]
  where
    alarmCause = \case
      AlarmValidationError → Just TerminalValidationError
      AlarmSinkFailed reason → Just (TerminalSinkFailed reason)
      AlarmPending → Nothing
      AlarmOwnerClaimed → Nothing

-- | The terminal latch, as any thread may read it. A failure the model
-- recorded by itself and no checkpoint has latched yet is answered as the
-- primary it will be.
readRootsTerminal ∷ Roots q inst msgr phys dev → STM TerminalReport
readRootsTerminal roots = do
  report ← readTVar (rootsTerminal roots)
  model ← readTVar (rootsModel roots)
  pure (maybe report {reportPrimary = fromModel model} (const report) (reportPrimary report))

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
      destroying roots (rootsDevice roots) "device" (opsDestroyDevice (rootsOps roots) (selectedDevice selected))
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
        Live messenger → destroying roots (rootsMessenger roots) "explicit messenger" (opsDestroyMessenger ops created messenger)
        Uncertain reason → throwIO (MessengerUncertain reason)
        _ → pure ()
      proved ← mask_ $
        tryWithContext (opsDestroyInstance ops created) >>= \case
          Right proved → do
            atomically $ do
              writeTVar (rootsInstance roots) Destroyed
              writeTVar (rootsQuiesced roots) (Just proved)
            pure proved
          Left failure → uncertainly roots (rootsInstance roots) "instance" failure
      pure (Just proved)
  where
    ops = rootsOps roots
    isUncertain = \case
      RootUncertain _ → True
      _ → False

-- | Run one root's destruction, which only a live root reaches, and record
-- what it did in the same masked step.
destroying ∷ Roots q inst msgr phys dev → TVar (Root a) → Text → IO () → IO ()
destroying roots slot name destroy = mask_ $
  tryWithContext destroy >>= \case
    Right () → atomically (writeTVar slot Destroyed)
    Left failure → uncertainly roots slot name failure

uncertainly ∷ Roots q inst msgr phys dev → TVar (Root a) → Text → ExceptionWithContext SomeException → IO b
uncertainly roots slot name failure@(ExceptionWithContext _ exception)
  | isAsynchronous exception = do
      -- A cancellation cannot land inside the masked call, so one here was
      -- raised by the call itself; its outcome is no better known for that.
      atomically (settle (Text.pack (displayException exception)))
      rethrowIO failure
  | otherwise = do
      let reason = Text.pack (displayException exception)
      atomically (settle reason)
      throwIO (RootDestructionFailed name reason)
  where
    settle reason = do
      writeTVar slot (Uncertain reason)
      latchTerminal roots (TerminalCleanupFailed ("destroying the " <> name <> ": " <> reason))

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

-- | Which result recovery acts on a failure a native call raised was, as the
-- roots' native layer classifies it.
rootsNativeFailure ∷ Roots q inst msgr phys dev → SomeException → Maybe NativeFailure
rootsNativeFailure = opsNativeFailure . rootsOps

-- | Run one native call against the roots' device, latching device loss if
-- that is what it raised, exactly as the roots' own calls are run.
rootsCall ∷ Roots q inst msgr phys dev → Text → IO a → IO a
rootsCall = guarded

-- | Read and replace the roots' model in one transaction.
stateRootsModel ∷ Roots q inst msgr phys dev → (GpuModel → (a, GpuModel)) → STM a
--
-- A transition that fails a running session by itself — a required target's
-- exhausted recovery, a submission whose effect is unknown — is a failure of
-- the owner's own, so it is ordered behind the diagnostic capture first
-- ('orderBehindDiagnostics'): when a diagnostic failure came before it, that
-- failure is latched and the transition is taken on the failed session
-- instead, where it fails nothing further.
stateRootsModel roots transition = do
  before ← readTVar (rootsModel roots)
  let (answer, after) = transition before
  if sessionState before == SessionRunning && sessionState after /= SessionRunning
    then do
      orderBehindDiagnostics roots
      current ← readTVar (rootsModel roots)
      let (answer', after') = transition current
      answer' <$ writeTVar (rootsModel roots) after'
    else answer <$ writeTVar (rootsModel roots) after

-- | Enter the session-level safety failure: an effect whose outcome is
-- unknown, or a cleanup that failed. Admission closes and the model's session
-- fails with the cause, in one transaction, through the terminal latch;
-- nothing is rolled back, and every parent of what is unverified stays
-- retained.
failRootsSession ∷ Roots q inst msgr phys dev → SessionFailureCause → STM ()
failRootsSession roots cause = failRootsSessionBecause roots cause (Text.pack (show cause))

-- | 'failRootsSession', saying what failed.
failRootsSessionBecause ∷ Roots q inst msgr phys dev → SessionFailureCause → Text → STM ()
failRootsSessionBecause roots cause reason = latchTerminal roots $ case cause of
  DeviceLost → TerminalDeviceLost (GraphicsDeviceLost "a native call" reason)
  ValidationError → TerminalValidationError
  DiagnosticSinkFailed → TerminalSinkFailed reason
  UnknownSubmissionEffect → TerminalUncertainEffect reason
  CleanupFailed → TerminalCleanupFailed reason
  RequiredTargetUnrecoverable → TerminalRequiredTarget Nothing

-- | The live instance, for the caller that leases it to a surface bridge.
readRootsInstance ∷ Roots q inst msgr phys dev → STM (Maybe inst)
readRootsInstance roots =
  readTVar (rootsInstance roots) >>= \case
    Live created → pure (Just created)
    _ → pure Nothing

-- | Register what disposes of one layer's subjects in a reclamation pass.
registerRootsDisposer ∷ Roots q inst msgr phys dev → SubjectDisposer → STM ()
registerRootsDisposer roots disposer = modifyTVar' (rootsDisposers roots) (<> [disposer])

-- | Every layer's disposer, in the order they were registered.
readRootsDisposers ∷ Roots q inst msgr phys dev → STM [SubjectDisposer]
readRootsDisposers = readTVar . rootsDisposers

-- | Whether the target holds a live surface: 'False' once recovery released a
-- lost one, until a replacement is installed, and for a target these roots do
-- not hold.
rootSurfaceHeld ∷ Roots q inst msgr phys dev → TargetId → STM Bool
rootSurfaceHeld roots target = maybe False (isJust . recordDestroy) . Map.lookup target <$> readTVar (rootsTargets roots)
