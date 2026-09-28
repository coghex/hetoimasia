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
-- = Swapchain generations
--
-- Every target the roots admit is tracked by the generations above them
-- ("Hetoimasia.GPU.Vulkan.Native.Generations"). Each progress step hands them
-- the geometry the owner folded for each constructed target — its eligibility,
-- its last coherent framebuffer observation and the bounds the platform
-- published — and they build, replace and destroy its generations on the
-- owner's thread. The observation reaches the owner through
-- 'Hetoimasia.Runtime.GLFW.publishGraphicsObservation' on the main thread.
--
-- = Recovering a lost surface
--
-- A target whose surface is lost (VK-14) is recovered on its same live window,
-- with its attachment kept throughout. The generations retire what was built
-- on the lost surface, destroy it once nothing of it remains, and ask the
-- target's episode for an attempt ("Hetoimasia.GPU.Vulkan.Native.Generations").
-- For each attempt admitted, the owner's step asks the main thread for a
-- replacement surface — the one thing it cannot make itself, since GLFW
-- creates surfaces there — and wakes it. The main thread creates it through
-- the surface bridge's admitted replacement, under the target's existing
-- attachment ('replaceVulkanSurfaces'), and deposits what it created; the
-- owner's next step offers it to the generations, which recheck the session's
-- one device's support and install it, or refuse it — and a surface the
-- device cannot present to is destroyed on the owner's thread while the target
-- is disposed of through its designation. The loop adapter
-- ("Hetoimasia.GPU.Vulkan.GLFW.Internal.Loop") services replacements on every
-- turn; an application that drives its own loop does it, as it publishes
-- observations. Close wins: a replacement deposited for a target that has
-- begun retiring is destroyed, never installed.
--
-- = Unavailability and failure
--
-- A target the model marked unavailable — its episode spent, or its
-- replacement surface one the device cannot present to — is reported once, by
-- attachment ('readVulkanUnavailability'); its generations still retire as
-- their holds end, and its attachment and window stay until the application
-- releases them. A required target's exhaustion has failed the session, and
-- the owner's step then raises 'VulkanRequiredTargetFailed', which ends the
-- owner's run and reaches the application's checkpoints like any other owner
-- failure.
--
-- = Destruction
--
-- A target's retirement destroys its swapchain generations and then its
-- surface, through the roots when they admitted it and directly when they did
-- not, and raises — manufacturing no evidence — when a destruction was
-- uncertain or a generation is still held. Whole-owner retirement
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
  , announceVulkanTarget

    -- * Observation
  , VulkanRejection (..)
  , readTargetRejection
  , rejectionsRetained
  , readVulkanTargets
  , readVulkanRoots
  , readVulkanModel
  , readVulkanTerminal

    -- * Recovery (VK-14)
  , replaceVulkanSurfaces
  , VulkanUnavailability (..)
  , UnavailableBecause (..)
  , readVulkanUnavailability
  , unavailabilitiesRetained

    -- * Swapchain generations
  , readVulkanGenerations
  , useVulkanGeneration
  , endVulkanGenerationUse
  , noteVulkanSwapchainResult
  , targetGeometry

    -- * Rendering (VK-16)
  , RenderingOps (..)
  , VulkanRenderer (..)
  , FrameRequest (..)
  , clearRenderer
  , FrameEvent (..)
  , FrameObserver
  , noFrameObserver
  , FrameStorageRefused (..)

    -- * The composition
  , VulkanHostConfig (..)
  , vulkanHostConfig
  , VulkanHost (..)
  , withVulkanOwnerHostOver
  , withVulkanOwnerHostHooked
  , ControllerHooks (..)
  , noControllerHooks
  , NativeObserver (..)
  , noObserver

    -- * Failures
  , InstanceExtensionsMissing (..)
  , OrphanSurfacesUncertain (..)
  , UnannouncedSurfaceUncertain (..)
  , LeaseRetained (..)
  , RootsOutlivedHost (..)
  , ReplacementSurfaceUncertain (..)
  , VulkanRequiredTargetFailed (..)
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
import Control.Monad (forM, forM_, join, unless, void, when)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as Char8
import Data.Foldable (for_)
import Data.Functor ((<&>))
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import Data.List (nubBy)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32)
import Hetoimasia.Foundation.Time (Instant)
import Foreign.Ptr (Ptr)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.Foundation.Messaging.Payload (Prepared)
import Hetoimasia.Foundation.Resource (Scoped)
import Hetoimasia.Foundation.Time
  ( Duration
  , DurationRequirement (RequirePositive)
  , MonotonicSource
  , SecondsConversion (convertedDuration)
  , addDuration
  , deadlineReached
  , durationFromNanoseconds
  , durationFromSeconds
  , minimumPositiveDuration
  , readInstant
  )
import Hetoimasia.GLFW.Session (Session, SessionConfig)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.GLFW.Window (Extent)
import qualified Hetoimasia.GLFW.Window as Window
import Hetoimasia.GPU.Model
  ( Escalation (OptionalTargetUnavailable, RequiredTargetFailedSession)
  , GpuModel
  , SessionFailureCause (RequiredTargetUnrecoverable)
  , SessionState (SessionFailed)
  , escalations
  , sessionState
  )
import Hetoimasia.GPU.Model.Budget (Budgets)
import Hetoimasia.GPU.Model.Identity (GenerationId, TargetClass (..), TargetId)
import Hetoimasia.GPU.Vulkan.Diagnostics
  ( CaptureAlarm (..)
  , CaptureConfig
  , CaptureOrder (..)
  , DiagnosticCapture
  , DiagnosticVerdict
  , Quiesced
  , SinkFailure (..)
  , afterLastCallback
  , captureAlarms
  , captureSinkFailure
  , claimCaptureOrder
  , retainStorage
  , withDiagnosticCapture
  )
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Bridge
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Rendering
import Hetoimasia.GPU.Vulkan.Native.Frames (FrameOps (..))
import Hetoimasia.GPU.Vulkan.Native.Recording (ClearColor (..), RecordingOps (..))
import Hetoimasia.GPU.Vulkan.Native.Generations
  ( GenerationUse
  , Generations
  , ReplacementAnswer (..)
  , StepSummary (..)
  , SwapchainResult
  , TargetCondition (PresentationUnsupported)
  , TargetGenerationsView (viewCondition)
  , UseRefusal
  , endGenerationUse
  , generationsDeadline
  , newGenerations
  , noteSwapchainResult
  , offerReplacementSurface
  , readTargetGenerations
  , replacementSurfaceFailed
  , retireTargetGenerations
  , stepGenerations
  , trackTarget
  , useGeneration
  )
import Hetoimasia.GPU.Vulkan.Native.Naming (Instrumentation (..))
import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceExtent (..))
import qualified Hetoimasia.GPU.Vulkan.Native.Presentation as Presentation
import Hetoimasia.GPU.Vulkan.Native.Profile (InstancePlan (..), InstanceRequest (..), TargetRejection (..), ValidationFeature)
import Hetoimasia.GPU.Vulkan.Native.Roots
  ( DiagnosticAlarm (..)
  , GenerationOps (..)
  , RootOps (..)
  , GraphicsDeviceLost
  , RootStanding (..)
  , RootTargetView (..)
  , Roots
  , RootsNotStarted (..)
  , RootsView (..)
  , SurfaceDestruction (..)
  , TargetSurface (..)
  , TeardownEvidence (..)
  , TerminalCause (..)
  , TerminalReport (..)
  , Checkpoint (..)
  , admitRootTarget
  , checkpointRoots
  , checkpointRootsSettled
  , terminalFailure
  , latchTerminal
  , noteTeardownEvidence
  , readRootsTerminal
  , watchRootsDiagnosticsOrdered
  , DiagnosticWatch (..)
  , DiagnosticOrder (..)
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
  , ExtentBounds (..)
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
  , OwnerStep (..)
  , RenderEligibility (..)
  , RetirementReadiness (..)
  , RolledBack
  , SlotState (SlotAttached)
  , StepReport (..)
  , Stage (CustodyRegistered, CustodySettling)
  , TargetHandoff (..)
  , TargetRetire (..)
  , TargetRetired
  , TargetGeometry (..)
  , TargetStart (..)
  , TargetStepView (..)
  , WindowHost
  , announceGraphicsTarget
  , ownerTargetAcknowledgement
  , wakeGraphicsHost
  , custodyOf
  , graphicsAttachment
  , graphicsOwnerConfig
  , graphicsTargetProtocol
  , noStepWork
  , observedSlot
  , ownerDestroyed
  , ownerHandoff
  , ownerReady
  , ownerRetired
  , readGraphicsService
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
data VulkanController = ∀ inst msgr phys dev cmd lease obligation. VulkanController !(State inst msgr phys dev cmd lease obligation)

data State inst msgr phys dev cmd lease obligation = State
  { stateRoots ∷ !(Roots Quiesced inst msgr phys dev)
  , stateGenerations ∷ !(Generations Quiesced inst msgr phys dev)
    -- ^ Every admitted target's swapchain generations, above the roots.
  , stateRendering ∷ !(Rendering Quiesced inst msgr phys dev cmd)
    -- ^ The recording and the frames above the generations, and what each
    -- target's rendering holds (VK-16).
  , statePointer ∷ !(inst → Ptr ())
  , stateBridge ∷ !(SurfaceBridge lease obligation)
  , stateLayers ∷ ![ByteString]
  , stateValidation ∷ ![ValidationFeature]
  , stateRequest ∷ !(TVar (Maybe InstanceRequest))
    -- ^ Supplied on the main thread from the session, before the owner starts.
  , stateLease ∷ !(TVar (Lease lease))
  , stateDeposits ∷ !(TVar (Map AttachmentId (Deposit obligation)))
    -- ^ Written by a construction step on the main thread; taken by the
    -- owner's construction or retirement of that attachment.
  , stateTargets ∷ !(TVar (Map AttachmentId TargetId))
    -- ^ The owner thread's alone: which roots target each attachment is.
  , stateRejections ∷ !(TVar (Map AttachmentId VulkanRejection))
  , stateUnannounced ∷ !(TVar (Map AttachmentId Unannounced))
    -- ^ Attachments whose surface was created and deposited but whose
    -- announcement the owner's full port refused. Written by the main
    -- thread's handover; the owner's step settles each once its slot has
    -- begun retiring.
  , stateReplacements ∷ !(TVar (Map AttachmentId (Replacement obligation)))
    -- ^ Replacement surfaces the owner asked for: written by the owner's step,
    -- answered by the main thread's 'replaceVulkanSurfaces', and taken by the
    -- owner's step, or by the attachment's retirement.
  , stateHostWake ∷ !(TVar (IO ()))
    -- ^ Wakes the main thread when the owner asks for a replacement; the
    -- composition sets it once the owner exists.
  , stateUnavailable ∷ !(TVar (Map AttachmentId VulkanUnavailability))
    -- ^ Targets reported unavailable, the most recent 'unavailabilitiesRetained'.
  , stateUnsupported ∷ !(TVar (Map AttachmentId Word32))
    -- ^ Why a target became unavailable, when it was a replacement surface the
    -- device could not present to rather than a spent episode; the owner's
    -- alone.
  , stateWake ∷ !(TVar (STM Bool))
    -- ^ What wakes an idle owner: the capture's sink failure, until it is
    -- latched, and a primary failure latched on another thread that the
    -- owner's own checkpoint has not yet taken. Installed with the capture's
    -- watch.
  , stateDiagnosticPending ∷ !(TVar Bool)
    -- ^ Whether the owner's last step found a diagnostic failure pending, so
    -- it looks again within its poll. The owner thread's alone.
  , stateClock ∷ !MonotonicSource
  , statePoll ∷ !Duration
    -- ^ How soon the owner looks at them again, while any exist.
  , stateHooks ∷ !ControllerHooks
  , stateSeen ∷ !(TVar (Map TargetId (Natural, RenderEligibility)))
    -- ^ The observation revision and eligibility each target's generations
    -- were last reconciled with. The owner thread's alone.
  , stateFailureTaken ∷ !(TVar Bool)
    -- ^ Whether the owner's own step has found the session failed. Written by
    -- the owner's step; read by its wake.
  }

-- | Instants the package's own examples must reach and nothing else can: a
-- private seam, never set in production.
newtype ControllerHooks = ControllerHooks
  { hookAfterRefusal ∷ AttachmentId → IO ()
    -- ^ Runs on the main thread immediately after the owner's full port
    -- refused an announcement, before the handover answers.
  }

noControllerHooks ∷ ControllerHooks
noControllerHooks = ControllerHooks (\_ → pure ())

-- | An attachment the owner was never told about, and how to tell whether it
-- still has not been: its custody stage, as the owner's ledger holds it.
data Unannounced = Unannounced
  { unannouncedService ∷ !GraphicsService
  , unannouncedStage ∷ STM (Maybe Stage)
  }

data Lease lease
  = LeasePending
  | LeaseReady !lease
  | LeaseFailed !Text

-- | What a construction step created, and the designation the application
-- gave the target.
data Deposit obligation = Deposit !TargetClass !(Created obligation)

-- | One replacement surface the owner asked the main thread for.
data Replacement obligation
  = ReplacementAsked
    -- ^ Not yet created.
  | ReplacementCreating
    -- ^ The main thread is creating it now. Its native call is finite, and the
    -- attachment's retirement waits for its answer rather than sweeping the
    -- lease before the surface is on it.
  | ReplacementDeposited !(Either Text (Created obligation))
    -- ^ What the main thread's replacement answered: the bridge's refusal,
    -- or what it created.

-- | A controller over a native layer and a surface bridge.
--
-- The layers are the ones the instance is asked to enable, each of which the
-- loader must offer, and the validation features are the ones its create info
-- enables through them. The clock is the one the roots' model and the owner's
-- deadlines read, which must be the host's; the period is how soon the owner
-- looks again at an attachment whose announcement its port refused.
newVulkanController
  ∷ RootOps Quiesced inst msgr phys dev
  → RenderingOps phys dev cmd
  → FrameObserver
  → (inst → Ptr ())
  → SurfaceBridge lease obligation
  → [ByteString]
  → [ValidationFeature]
  → Budgets
  → MonotonicSource
  → Duration
  → IO VulkanController
newVulkanController = newVulkanControllerWith noControllerHooks

-- | 'newVulkanController' with the examples' hooks.
newVulkanControllerWith
  ∷ ControllerHooks
  → RootOps Quiesced inst msgr phys dev
  → RenderingOps phys dev cmd
  → FrameObserver
  → (inst → Ptr ())
  → SurfaceBridge lease obligation
  → [ByteString]
  → [ValidationFeature]
  → Budgets
  → MonotonicSource
  → Duration
  → IO VulkanController
newVulkanControllerWith hooks ops rendering observer pointer bridge layers validation budgets clock poll = do
  roots ← newRoots ops budgets clock
  generations ← newGenerations roots
  rendered ← newRendering roots generations rendering observer
  fmap VulkanController $
    State roots generations rendered pointer bridge layers validation
      <$> newTVarIO Nothing
      <*> newTVarIO LeasePending
      <*> newTVarIO Map.empty
      <*> newTVarIO Map.empty
      <*> newTVarIO Map.empty
      <*> newTVarIO Map.empty
      <*> newTVarIO Map.empty
      <*> newTVarIO (pure ())
      <*> newTVarIO Map.empty
      <*> newTVarIO Map.empty
      <*> newTVarIO (pure False)
      <*> newTVarIO False
      <*> pure clock
      <*> pure poll
      <*> pure hooks
      <*> newTVarIO Map.empty
      <*> newTVarIO False

-- | Supply the instance extensions the window system requires, copied from
-- the loader-aware session on the main thread. The owner's startup reads
-- them; it is refused without them.
supplyInstanceExtensions ∷ VulkanController → [ByteString] → STM ()
supplyInstanceExtensions (VulkanController state) required =
  writeTVar (stateRequest state) (Just (InstanceRequest required (stateLayers state) (stateValidation state)))

-- | The owner started before the session's instance extensions were supplied.
data InstanceExtensionsMissing = InstanceExtensionsMissing
  deriving (Eq, Show)

instance Exception InstanceExtensionsMissing

-- | Surfaces no target held could not all be destroyed, so the device and
-- the instance are retained.
newtype OrphanSurfacesUncertain = OrphanSurfacesUncertain Int
  deriving (Eq, Show)

instance Exception OrphanSurfacesUncertain

-- | The owner could not verify the destruction of a surface whose attachment
-- it was never told about, which a full port deferred and which was then
-- released or closed. The surface is retained with its attachment and the
-- instance, and its destruction is not attempted again.
data UnannouncedSurfaceUncertain = UnannouncedSurfaceUncertain !AttachmentId !Text
  deriving (Eq, Show)

instance Exception UnannouncedSurfaceUncertain where
  displayException (UnannouncedSurfaceUncertain attachment reason) =
    "destroying the surface of the unannounced attachment " <> show attachment <> " did not complete: " <> Text.unpack reason

-- | A replacement surface the owner could not use — its target had begun
-- retiring, the device cannot present to it, or it was created unusable — was
-- not verifiably destroyed. It is retained on the lease with its attachment
-- and the instance, and its destruction is not attempted again.
data ReplacementSurfaceUncertain = ReplacementSurfaceUncertain !AttachmentId !Text
  deriving (Eq, Show)

instance Exception ReplacementSurfaceUncertain where
  displayException (ReplacementSurfaceUncertain attachment reason) =
    "destroying a replacement surface of " <> show attachment <> " did not complete: " <> Text.unpack reason

-- | A required target could not be recovered, so the graphics session has
-- failed (D-22): its episode was spent, or the session's device cannot present
-- to its replacement surface. Raised by the owner's step, it ends the owner's
-- run and reaches the application's checkpoints.
data VulkanRequiredTargetFailed = VulkanRequiredTargetFailed ![(AttachmentId, TargetId)]
  deriving (Eq, Show)

instance Exception VulkanRequiredTargetFailed where
  displayException (VulkanRequiredTargetFailed targets) =
    "the graphics session failed: a required target could not be recovered (" <> show targets <> ")"

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

-- | The operations the graphics owner runs, on its own thread, rendering the
-- scene it holds with this renderer.
--
-- The progress step raises a latched failure; destroys the surface of any
-- attachment whose announcement the port refused and whose slot has since
-- begun retiring; folds the step's demand and scene into render requests and,
-- when a poll is due or a frame is to be attempted, asks the fences
-- ("Hetoimasia.GPU.Vulkan.GLFW.Internal.Rendering"); reconciles every admitted
-- target's swapchain generations with the geometry the owner folded for it —
-- its eligibility, its last coherent framebuffer observation and the bounds
-- the platform published ('targetGeometry') — whenever an observation moved,
-- the generations' own deadline came, or a frame is to be attempted; and then
-- offers each target that wants a frame one attempt. It asks for a round while
-- an unannounced attachment is watched, when the generations name a deadline —
-- a settling resize, a deferred recovery attempt, the model's poll — and when
-- rendering does: a frame wanted now, an acquisition's retry, a demand deadline
-- ahead. A target's retirement is owed until its frames and presentations have
-- gone on their own evidence.
controllerOperations ∷ VulkanController → VulkanRenderer scene → GraphicsOperations scene
controllerOperations (VulkanController state) renderer =
  GraphicsOperations
    { graphicsStartOwner = \_ → startOwner state
    , graphicsConstructTarget = constructTarget state
    , graphicsStep = \step →
        checkpointRoots (stateRoots state) >>= \case
          CheckpointFailed primary → do
            atomically (writeTVar (stateFailureTaken state) True)
            throwIO (terminalFailure primary)
          -- A diagnostic failure whose order is not yet readable: this round
          -- does nothing new, and the owner looks again within its poll.
          CheckpointPending → noStepWork <$ atomically (writeTVar (stateDiagnosticPending state) True)
          CheckpointClear → do
            atomically (writeTVar (stateDiagnosticPending state) False)
            progress step
    , graphicsNextDeadline = ownerDeadline state
    , graphicsWake = join (readTVar (stateWake state))
    , graphicsPrepareRetirement = \retiring → retaining state (prepareRetirement state retiring)
    , graphicsRetireTarget = \retiring → retaining state (retireTarget state retiring)
    , graphicsRetireOwner = retaining state . retireOwner state
    , graphicsDestroyOwner = \_ → retaining state (destroyOwner state)
    }
  where
    progress step = do
        settled ← settleUnannounced state
        mapped ← readTVarIO (stateTargets state)
        let now = stepNow step
            constructed =
              [ (target, view)
              | view ← stepTargets step
              , viewConstructed view
              , Just target ← [Map.lookup (viewTarget view) mapped]
              ]
            geometries = Map.fromList [(target, targetGeometry view) | (target, view) ← constructed]
            observed = Map.fromList [(target, (viewRevision view, viewEligibility view)) | (target, view) ← constructed]
        -- The generations are stepped when there is something for them to do:
        -- a target's observation moved, their own deadline — a settling
        -- resize, a recovery attempt, a result to reconcile, the model's poll
        -- — has come, or a frame is to be attempted. A round something
        -- unrelated woke takes no model turn, so it neither polls early nor
        -- moves the backoff on.
        seen ← readTVarIO (stateSeen state)
        let moved = any (\(target, current) → Map.lookup target seen /= Just current) (Map.toList observed)
        owed ← generationsOwed state now
        plan ←
          planStep
            (stateRendering state)
            StepInputs
              { inputsNow = now
              , inputsSceneRevision = stepSceneRevision step
              , inputsDemand = stepDemand step
              , inputsDemandRevision = stepDemandRevision step
              , inputsTargets = [(target, viewTarget view, viewEligibility view == RenderEligible) | (target, view) ← constructed]
              }
        summary ←
          if moved || owed || planPolled plan || not (null (planDue plan))
            then do
              atomically (writeTVar (stateSeen state) observed)
              stepGenerations (stateGenerations state) now geometries
            else pure (StepSummary [] [] False [])
        presented ← renderDue (stateRendering state) renderer now (stepScene step) (stepSceneRevision step) (planDue plan)
        asked ← askReplacements state (summarySurfacesWanted summary)
        replaced ← settleReplacements state now (stepTargets step)
        noticeUnavailable state
        failRequired state
        pure (if settled || summaryAdvanced summary || asked || replaced || presented then noStepWork {stepAdvanced = True} else noStepWork)

-- | Run a retirement, and if it could not verify what it owns, keep that in
-- the terminal report as retained before the failure goes on to the owner,
-- which retains its evidence and manufactures no acknowledgement. The report
-- says what was retained; it releases nothing. A cancellation is not a
-- retention and is left as it is.
retaining ∷ State inst msgr phys dev cmd lease obligation → IO a → IO a
retaining state action =
  tryWithContext action >>= \case
    Right value → pure value
    Left failure@(ExceptionWithContext _ exception)
      | isAsynchronous exception → rethrowIO failure
      | otherwise → do
          atomically (noteTeardownEvidence (stateRoots state) (RetainedUnverified (Text.pack (displayException exception))))
          rethrowIO (failure ∷ ExceptionWithContextSome)


-- | Whether the generations' own deadline has come: a result to reconcile, a
-- settling resize, a recovery attempt or the model's poll.
generationsOwed ∷ State inst msgr phys dev cmd lease obligation → Instant → IO Bool
generationsOwed state now =
  atomically (generationsDeadline (stateGenerations state)) <&> \case
    Nothing → False
    Just (Left ()) → True
    Just (Right due) → deadlineReached now due

-- | Whether one target's retirement can be performed now: once its frames and
-- presentations have all gone on their own evidence. A target the roots never
-- admitted holds none.
prepareRetirement ∷ State inst msgr phys dev cmd lease obligation → TargetRetire → IO RetirementReadiness
prepareRetirement state retiring =
  atomically (Map.lookup (retiringTarget retiring) <$> readTVar (stateTargets state)) >>= \case
    Nothing → pure RetirementReady
    Just target → do
      now ← readInstant (stateClock state)
      maybe RetirementReady RetirementOwed <$> prepareTargetRetirement (stateRendering state) now target

-- | Destroy, on the owner's thread, the surface of every attachment the owner
-- was never told about whose slot has begun retiring — released, or its window
-- closing — and forget it. An attachment still attached may yet be announced,
-- and one whose announcement was admitted is the owner's ordinary target, so
-- neither is touched. Each is settled once and forgotten, however it went. A
-- destruction that was uncertain is a failure: it stays on the lease, where it
-- retains the attachment and the instance, it is never offered again, and
-- 'UnannouncedSurfaceUncertain' is raised, which ends the owner's run and
-- reaches the application's checkpoints like any other owner failure.
settleUnannounced ∷ State inst msgr phys dev cmd lease obligation → IO Bool
settleUnannounced state = do
  entries ← Map.toList <$> readTVarIO (stateUnannounced state)
  settled ← forM entries $ \(attachment, entry) → do
    ready ← atomically $ do
      observation ← readGraphicsService (unannouncedService entry)
      stage ← unannouncedStage entry
      let retiring = observedSlot observation /= SlotAttached
          announced = stage `notElem` [Nothing, Just CustodyRegistered, Just CustodySettling]
      pure (if announced then Just False else if retiring then Just True else Nothing)
    case ready of
      Nothing → pure False
      -- Announced after all: it is the owner's ordinary target now.
      Just False → False <$ atomically (modifyTVar' (stateUnannounced state) (Map.delete attachment))
      Just True → mask_ $ do
        deposit ← atomically (stateTVar (stateDeposits state) (\held → (Map.lookup attachment held, Map.delete attachment held)))
        listed ← readTVarIO (stateLease state) >>= \case
          LeaseReady lease → atomically (obligationsOf bridge lease attachment)
          _ → pure []
        let deposited = case deposit of
              Just (Deposit _ (CreatedLive obligation)) → [obligation]
              Just (Deposit _ (CreatedUnusable obligation _)) → [obligation]
              _ → []
        let obligations = nubBy (bridgeSameObligation bridge) (deposited <> listed)
        outcomes ← mapM (bridgeDischarge bridge) obligations
        atomically (modifyTVar' (stateUnannounced state) (Map.delete attachment))
        atomically (latchDischarges state "an unannounced attachment's" (zip obligations outcomes))
        case [failure | Just (ExceptionWithContext _ failure) ← map dischargeFailure outcomes] of
          failure : _ → throwIO (UnannouncedSurfaceUncertain attachment (Text.pack (displayException failure)))
          [] → pure True
  pure (or settled)
  where
    bridge = stateBridge state

-- | Ask the main thread for a replacement surface for each target whose
-- attempt the generations just admitted, and wake it. Answers whether it
-- asked for any.
askReplacements ∷ State inst msgr phys dev cmd lease obligation → [TargetId] → IO Bool
askReplacements state wanted = do
  asked ← atomically $ do
    mapped ← Map.toList <$> readTVar (stateTargets state)
    let attachments = [attachment | (attachment, target) ← mapped, target `elem` wanted]
    for_ attachments $ \attachment → modifyTVar' (stateReplacements state) (Map.insert attachment ReplacementAsked)
    pure (not (null attachments))
  when asked (join (readTVarIO (stateHostWake state)))
  pure asked

-- | Take every replacement the main thread deposited and settle it with the
-- generations: a live surface is offered, and one they refuse — its target
-- retiring, or a surface the session's device cannot present to — is destroyed
-- here, on the owner's thread, as is one that was created unusable. A failed
-- or unusable creation fails the attempt, and the episode schedules the next.
-- A refusal by the bridge is the window closing, the attachment retiring or
-- the lease releasing: the attempt is left for the target's retirement to
-- settle, unless the owner's view shows the target still eligible, when it
-- fails too rather than waiting for a close that is not coming. Answers
-- whether it settled any.
--
-- A surface the attachment's lease still lists while its target waits for a
-- replacement — a creation whose answer a cancellation took from the main
-- thread — is destroyed too: the roots hold no surface for that target then,
-- so nothing on the lease for it is in use.
settleReplacements ∷ State inst msgr phys dev cmd lease obligation → Instant → [TargetStepView] → IO Bool
settleReplacements state now views = do
  deposited ← atomically $ do
    held ← readTVar (stateReplacements state)
    let answered = [(attachment, answer) | (attachment, ReplacementDeposited answer) ← Map.toList held]
    writeTVar (stateReplacements state) (foldr (Map.delete . fst) held answered)
    mapped ← readTVar (stateTargets state)
    pure [(attachment, target, answer) | (attachment, answer) ← answered, Just target ← [Map.lookup attachment mapped]]
  forM_ deposited $ \(attachment, target, answer) → mask_ $ case answer of
    Right (CreatedLive obligation) →
      tryWithContext (offerReplacementSurface generations now target (TargetSurface (handleOf obligation) (destruction bridge obligation))) >>= \case
        Right ReplacementInstalled → pure ()
        Right (ReplacementUnsupported family) → do
          atomically (modifyTVar' (stateUnsupported state) (Map.insert attachment family))
          discharge attachment [obligation]
        Right ReplacementNotWanted → discharge attachment [obligation]
        -- Its support query or its naming raised: the surface is still this
        -- step's, so it is destroyed, and the attempt failed. Device loss,
        -- latched by the call, and a cancellation are the owner's.
        Left failure@(ExceptionWithContext _ exception)
          | isAsynchronous exception || isJust (fromException exception ∷ Maybe GraphicsDeviceLost) → do
              discharge attachment [obligation]
              rethrowIO (failure ∷ ExceptionWithContextSome)
          | otherwise → do
              discharge attachment [obligation]
              replacementSurfaceFailed generations now target ("the replacement surface could not be installed: " <> Text.pack (displayException exception))
    Right (CreatedUnusable obligation reason) → do
      discharge attachment [obligation]
      replacementSurfaceFailed generations now target ("the replacement surface could not be used: " <> reason)
    Right (CreationFailed reason) → do
      discharge attachment =<< strays attachment
      replacementSurfaceFailed generations now target ("no replacement surface was created: " <> reason)
    Left refusal → do
      discharge attachment =<< strays attachment
      let closing = case [view | view ← views, viewTarget view == attachment] of
            view : _ → viewEligibility view == RenderExcluded
            [] → True
      unless closing (replacementSurfaceFailed generations now target ("the replacement was refused: " <> refusal))
  pure (not (null deposited))
  where
    generations = stateGenerations state
    bridge = stateBridge state
    handleOf = bridgeObligationHandle bridge
    strays attachment =
      readTVarIO (stateLease state) >>= \case
        LeaseReady lease → atomically (obligationsOf bridge lease attachment)
        _ → pure []
    discharge attachment obligations = do
      outcomes ← mapM (bridgeDischarge bridge) obligations
      case [failure | DischargeUncertain (ExceptionWithContext _ failure) ← outcomes] of
        failure : _ → throwIO (ReplacementSurfaceUncertain attachment (Text.pack (displayException failure)))
        [] → pure ()

-- | Report, once, every target that became unavailable: its episode spent, or
-- its replacement surface one the device cannot present to.
noticeUnavailable ∷ State inst msgr phys dev cmd lease obligation → IO ()
noticeUnavailable state = atomically $ do
  mapped ← Map.toList <$> readTVar (stateTargets state)
  model ← readRootsModel (stateRoots state)
  noticed ← readTVar (stateUnavailable state)
  unsupported ← readTVar (stateUnsupported state)
  -- The escalation, not the target's phase: a target that holds nothing more
  -- once it is unavailable is forgotten by the model's next progress turn.
  let unavailable = [target | OptionalTargetUnavailable target ← escalations model]
  for_ mapped $ \(attachment, target) →
    when (target `elem` unavailable && Map.notMember attachment noticed) $ do
      condition ← fmap viewCondition <$> readTargetGenerations (stateGenerations state) target
      let because = case (Map.lookup attachment unsupported, condition) of
            (Just family, _) → UnavailableSurfaceUnsupported family
            (_, Just (PresentationUnsupported gaps)) → UnavailablePresentationUnsupported gaps
            _ → UnavailableRecoverySpent
      modifyTVar' (stateUnavailable state) $ \held →
        let grown = Map.insert attachment (VulkanUnavailability target because) held
         in if Map.size grown > unavailabilitiesRetained then Map.deleteMin grown else grown

-- | Raise 'VulkanRequiredTargetFailed' once a required target's exhaustion has
-- failed the session. The roots' checkpoint latches it in the terminal report
-- first, so a diagnostic failure that happened before it stays the primary and
-- is what is raised instead; one whose order is not yet readable leaves it to
-- the next step's checkpoint.
failRequired ∷ State inst msgr phys dev cmd lease obligation → IO ()
failRequired state = do
  model ← atomically (readRootsModel (stateRoots state))
  when (sessionState model == SessionFailed RequiredTargetUnrecoverable) $
    checkpointRoots (stateRoots state) >>= \case
      CheckpointFailed (TerminalRequiredTarget _) → do
        mapped ← readTVarIO (stateTargets state)
        let failed = [target | RequiredTargetFailedSession target ← escalations model]
        throwIO (VulkanRequiredTargetFailed [(attachment, target) | (attachment, target) ← Map.toList mapped, target `elem` failed])
      CheckpointFailed primary → throwIO (terminalFailure primary)
      _ → pure ()

-- | The earliest of the unannounced watch, a replacement the owner is waiting
-- on, the generations' own deadline, and rendering's: a frame wanted now, an
-- acquisition's retry, or a demand deadline still ahead.
ownerDeadline ∷ State inst msgr phys dev cmd lease obligation → IO NextDeadline
ownerDeadline state = do
  watch ← unannouncedDeadline state
  replacing ← replacementDeadline state
  owed ← atomically (generationsDeadline (stateGenerations state))
  now ← readInstant (stateClock state)
  let generation = case owed of
        Nothing → NoOwnerDemand
        Just (Right due) → OwnerDeadline due
        Just (Left ()) → OwnerDeadline now
  rendering ← maybe NoOwnerDemand OwnerDeadline <$> renderingDeadline (stateRendering state) now
  pure (earliest watch (earliest replacing (earliest generation rendering)))
  where
    earliest NoOwnerDemand other = other
    earliest other NoOwnerDemand = other
    earliest (OwnerDeadline first) (OwnerDeadline second) = OwnerDeadline (min first second)

-- | A round now while a deposited replacement waits to be settled, and one
-- host idle bound ahead while one is still being created: the main thread's
-- deposit wakes nothing on the owner, so it looks again.
replacementDeadline ∷ State inst msgr phys dev cmd lease obligation → IO NextDeadline
replacementDeadline state = do
  held ← Map.elems <$> readTVarIO (stateReplacements state)
  now ← readInstant (stateClock state)
  pure $
    if any deposited held
      then OwnerDeadline now
      else
        if null held
          then NoOwnerDemand
          else either (const NoOwnerDemand) OwnerDeadline (addDuration now (statePoll state))
  where
    deposited = \case
      ReplacementDeposited _ → True
      _ → False

-- | The geometry one target's view carries, in the native backend's terms: its
-- eligibility, the last coherent framebuffer observation and the bounds the
-- platform published. This is D-30's seam as the owner folded it; the extent
-- policy behind it is the native backend's.
targetGeometry ∷ TargetStepView → Presentation.TargetGeometry
targetGeometry view =
  Presentation.TargetGeometry
    { Presentation.geometryEligibility = case viewEligibility view of
        RenderEligible → Right ()
        RenderSuspended → Left "suspended: hidden, minimized or without area"
        RenderDeferred → Left "deferred: no framebuffer extent observed"
        RenderExcluded → Left "closing"
    , Presentation.geometryFramebuffer = physical <$> geometryFramebuffer (viewGeometry view)
    , Presentation.geometryBounds = (\bounds → (physical (boundsMinimum bounds), physical (boundsMaximum bounds))) <$> geometryBounds (viewGeometry view)
    , Presentation.geometryRevision = viewRevision view
    }
  where
    physical ∷ Extent → SurfaceExtent
    physical extent = SurfaceExtent (dimension (Window.extentWidth extent)) (dimension (Window.extentHeight extent))
    dimension = fromIntegral . max 0 . min (fromIntegral (maxBound ∷ Word32))

-- | A round soon, while an unannounced attachment is being watched or a
-- diagnostic failure is pending; otherwise none.
unannouncedDeadline ∷ State inst msgr phys dev cmd lease obligation → IO NextDeadline
unannouncedDeadline state = do
  unannounced ← not . Map.null <$> readTVarIO (stateUnannounced state)
  pending ← readTVarIO (stateDiagnosticPending state)
  if not (unannounced || pending)
    then pure NoOwnerDemand
    else do
      now ← readInstant (stateClock state)
      pure (either (const NoOwnerDemand) OwnerDeadline (addDuration now (statePoll state)))

startOwner ∷ State inst msgr phys dev cmd lease obligation → IO OwnerReady
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
constructTarget ∷ State inst msgr phys dev cmd lease obligation → TargetStart → IO TargetHandoff
constructTarget state start = do
  deposit ← atomically (stateTVar (stateDeposits state) (\held → (Map.lookup attachment held, Map.delete attachment held)))
  readTVarIO (stateLease state) >>= \case
    LeaseReady lease → do
      listed ← atomically (obligationsOf bridge lease attachment)
      case deposit of
        -- A diagnostic failure may have arrived after the handover was
        -- queued: the session's failure is taken before anything native is
        -- done, and again once admission's native calls have returned.
        Just (Deposit classification (CreatedLive obligation)) →
          checkpointRootsSettled (stateRoots state) >>= \case
            CheckpointFailed primary → reject state attachment (RejectedSessionFailed primary) (distinct (obligation : listed))
            _ → admit classification obligation listed
        Just (Deposit _ (CreatedUnusable obligation reason)) → reject state attachment (SurfaceUnusable reason) (distinct (obligation : listed))
        Just (Deposit _ (CreationFailed reason)) → reject state attachment (SurfaceNotCreated reason) listed
        Nothing → reject state attachment SurfaceNotHandedOver listed
    -- No lease means no surface could have been created against one.
    _ → reject state attachment (RejectedByRoots TargetAdmissionClosed) []
  where
    bridge = stateBridge state
    attachment = startingTarget start
    handleOf = bridgeObligationHandle bridge
    distinct = nubBy (bridgeSameObligation bridge)
    admit classification obligation listed = do
      -- Admission and the record of which target it made are one masked
      -- step: a cancellation between them would leave the roots owning a
      -- surface no retirement could name. The native calls inside are
      -- uninterruptible in any case.
      admitted ← mask_ $ do
        answer ← admitRootTarget (stateRoots state) classification (TargetSurface (handleOf obligation) (destruction bridge obligation))
        for_ answer $ \target → atomically $ do
          modifyTVar' (stateTargets state) (Map.insert attachment target)
          trackTarget (stateGenerations state) target classification (handleOf obligation)
        pure answer
      case admitted of
        Right target → do
          view ← atomically (readRootsView (stateRoots state))
          let admittedOn =
                "admitted "
                  <> tshow target
                  <> " ("
                  <> describeClass classification
                  <> ") on surface "
                  <> hex (handleOf obligation)
                  <> maybe "" (" of device " <>) (viewDeviceName view)
                  <> maybe "" ((", queue family " <>) . tshow) (viewQueueFamily view)
          -- A layer may have reported from inside admission's own native
          -- calls: a target admitted into a session that had failed by then is
          -- the owner's to retire, never a usable one.
          checkpointRootsSettled (stateRoots state) >>= \case
            CheckpointFailed primary →
              pure . TargetPartial . targetEvidence $
                admittedOn <> ", but the session failed while it was admitted (" <> tshow primary <> "), so the owner retires it"
            _ → pure (TargetConstructed (targetEvidence admittedOn))
        Left refused → do
          -- Admission closed because the session failed: the rejection
          -- names the failure.
          primary ← reportPrimary <$> atomically (readRootsTerminal (stateRoots state))
          let reason = case (refused, primary) of
                (TargetAdmissionClosed, Just cause) → RejectedSessionFailed cause
                _ → RejectedByRoots refused
          reject state attachment reason (distinct (obligation : listed))

-- | Destroy everything an attachment left and settle it as a verified
-- rollback — or, if a destruction was uncertain, as a partial construction the
-- owner keeps and retires.
reject
  ∷ State inst msgr phys dev cmd lease obligation
  → AttachmentId
  → VulkanRejection
  → [obligation]
  → IO TargetHandoff
reject state attachment reason obligations = do
  outcomes ← mapM (bridgeDischarge (stateBridge state)) obligations
  atomically $ do
    retainRejection state attachment reason
    latchDischarges state "a rejected target's" (zip obligations outcomes)
  let uncertain = length [() | Just _ ← map dischargeFailure outcomes]
      destroyed = length obligations - uncertain
  pure $
    if uncertain == 0
      then TargetRolledBack (rollbackEvidence (describeRejection reason <> "; destroyed " <> plural destroyed "surface"))
      else
        TargetPartial . targetEvidence $
          describeRejection reason <> "; destroying " <> plural uncertain "surface" <> " did not complete, so it is retained"

-- | Retire one target: destroy its surface, through the roots when they
-- admitted it, and whatever else the lease still lists for its attachment.
retireTarget ∷ State inst msgr phys dev cmd lease obligation → TargetRetire → IO TargetRetired
retireTarget state retiring = do
  mapped ← atomically (Map.lookup attachment <$> readTVar (stateTargets state))
  retiredRoot ← case mapped of
    Just target → mask_ $ do
      -- Its swapchain generations go first: they are the surface's children.
      -- Raises, and keeps them, the surface and this mapping, if any could not
      -- be destroyed.
      now ← readInstant (stateClock state)
      -- Its frames' synchronization and its frame storages go before its
      -- generations, whose holds its presentations were: preparation waited
      -- for every one of them to end.
      retireTargetRendering (stateRendering state) now target
      retireTargetGenerations (stateGenerations state) now target
      -- Raises, and keeps the record and this mapping, if the destruction was
      -- uncertain: the owner then never offers this again.
      retireRootTarget (stateRoots state) target
      atomically (modifyTVar' (stateTargets state) (Map.delete attachment))
      pure ("destroyed the surface of " <> tshow target)
    Nothing → pure "the roots held no target for it"
  -- A deposit the owner never took, a replacement it never settled, and any
  -- obligation whose answer was lost: whatever was created is on the lease.
  -- A replacement the main thread is creating right now is waited for — its
  -- native call is finite and owes the owner nothing — so its surface is on the
  -- lease before the lease is swept.
  _ ← atomically $ do
    Map.lookup attachment <$> readTVar (stateReplacements state) >>= \case
      Just ReplacementCreating → retry
      _ → modifyTVar' (stateReplacements state) (Map.delete attachment)
    modifyTVar' (stateUnsupported state) (Map.delete attachment)
    stateTVar (stateDeposits state) (\held → (Map.lookup attachment held, Map.delete attachment held))
  swept ← readTVarIO (stateLease state) >>= \case
    LeaseReady lease → do
      left ← atomically (obligationsOf (stateBridge state) lease attachment)
      outcomes ← mapM (bridgeDischarge (stateBridge state)) left
      atomically (latchDischarges state "a retired target's" (zip left outcomes))
      case [failure | Just failure ← map dischargeFailure outcomes] of
        failure : _ → rethrowIO failure
        [] → pure (length left)
    _ → pure 0
  pure . targetRetired $
    retiredRoot <> (if swept > 0 then "; destroyed " <> plural swept "further surface" else "")
  where
    attachment = retiringTarget retiring

-- | Retire the owner: close the lease, destroy every surface no target held,
-- and destroy the device.
retireOwner ∷ State inst msgr phys dev cmd lease obligation → OwnerRetire → IO OwnerRetired
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
      atomically (latchDischarges state "an orphaned" (zip orphans outcomes))
      let uncertain = length [() | Just _ ← map dischargeFailure outcomes]
      when (uncertain > 0) (throwIO (OrphanSurfacesUncertain uncertain))
      pure (length orphans)
    _ → pure 0
  atomically $ do
    writeTVar (stateDeposits state) Map.empty
    writeTVar (stateUnannounced state) Map.empty
  -- The recording's managed resources are the device's children.
  now ← readInstant (stateClock state)
  retireRendering (stateRendering state) now
  device ← retireRoots (stateRoots state)
  pure . ownerRetired $
    (if orphaned > 0 then "destroyed " <> plural orphaned "surface" <> " no target held; " else "") <> device
  where
    bridge = stateBridge state

-- | Destroy the owner's shared state: settle the lease, then destroy the
-- explicit messenger and the instance.
destroyOwner ∷ State inst msgr phys dev cmd lease obligation → IO OwnerDestroyed
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
      outcomes ← mapM (bridgeDischarge bridge) late
      -- A late surface whose destruction did not complete is a failed
      -- cleanup, whatever else failed first; the lease then still owes it,
      -- which retains the instance below.
      atomically (latchDischarges state "a late" (zip late outcomes))
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

-- | Latch every surface destruction that did not complete as a cleanup
-- failure of its own, naming the surface, its attachment and what raised:
-- several in one pass are each accounted for. An obligation whose earlier
-- destruction already raised answers 'DischargeStillUncertain' when a later
-- pass finds it still owed, and is not latched again: what is recognised is
-- the obligation, never a handle a later surface may reuse.
latchDischarges ∷ State inst msgr phys dev cmd lease obligation → Text → [(obligation, Discharged)] → STM ()
latchDischarges state what outcomes =
  for_ [(obligation, failure) | (obligation, DischargeUncertain (ExceptionWithContext _ failure)) ← outcomes] $ \(obligation, failure) →
    latchTerminal (stateRoots state) . TerminalCleanupFailed $
      "destroying " <> what <> " surface " <> hex (bridgeObligationHandle bridge obligation)
        <> " of " <> tshow (bridgeObligationAttachment bridge obligation)
        <> ": " <> Text.pack (displayException failure)
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
    DischargeStillUncertain failure → pure (SurfaceDestructionUncertain failure)

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
    -- full. It is backpressure: announce it again with 'announceVulkanTarget',
    -- or release it. Until it is announced the owner watches it, and if it is
    -- released or its window closes first, the owner destroys its surface on
    -- its own thread so its retirement can finish.
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
  | VulkanSessionFailed !TerminalCause
    -- ^ The graphics session has failed, with this primary failure. Nothing
    -- was attached: a failed session admits no target.
  | VulkanDiagnosticPending
    -- ^ A diagnostic failure has happened whose order the capture cannot yet
    -- say. Nothing was attached; a later handover names the primary.
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
-- attachment that registered and was never announced — and has the owner watch
-- it if its port is full — so none is left that the owner never hears of: its
-- surface, if it was created, is on the lease, and the owner settles it.
handOverVulkanTarget
  ∷ VulkanController → WindowHost → GraphicsOwner scene → WindowId → TargetClass → IO VulkanHandover
handOverVulkanTarget (VulkanController state) host owner window classification =
  mask $ \restore →
    checkpointRoots (stateRoots state) >>= \case
      CheckpointFailed primary → pure (VulkanSessionFailed primary)
      CheckpointPending → pure VulkanDiagnosticPending
      CheckpointClear → handOver restore
  where
    handOver restore =
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
      announceOrWatch service >>= \case
        EventAdmitted → pure (VulkanTargetHandedOver service)
        EventRefusedFull → pure (VulkanAnnouncementDeferred service)
        EventPortClosed → pure (VulkanOwnerClosed (Just service))
    -- Every announcement this handover makes goes through here, the
    -- recovery's included: one the full port refused is watched by the owner,
    -- so a release or a close of it still has its surface destroyed. One the
    -- closed port refused needs nothing more: the owner's own retirement
    -- destroys every surface its lease still owes.
    --
    -- The watch is registered /before/ the announcement is attempted, and
    -- withdrawn if it was admitted or the port has closed. Registering it
    -- after a refusal instead would leave a gap: the owner could drain the
    -- full port, find no watch when it chose its next deadline, and go idle
    -- for good, so a later release would never reach it. With the entry in
    -- place first, whatever the owner decides after taking a refused port's
    -- events is decided with it in view. The owner's step cannot act on the
    -- entry meanwhile: it touches only an attachment whose slot has begun
    -- retiring, and only the main thread — this one — can begin that.
    announceOrWatch service = do
      atomically $
        modifyTVar' (stateUnannounced state) $
          Map.insert attachment (Unannounced service (custodyOf owner attachment))
      admitted ← announceGraphicsTarget owner service
      if admitted == EventRefusedFull
        then hookAfterRefusal (stateHooks state) attachment
        else atomically (modifyTVar' (stateUnannounced state) (Map.delete attachment))
      pure admitted
      where
        attachment = graphicsAttachment service
    recover = do
      found ← atomically (windowGraphicsService host window)
      for_ found $ \service → do
        stage ← atomically (custodyOf owner (graphicsAttachment service))
        when (stage == Just CustodyRegistered) (void (announceOrWatch service))

-- | Create, on the main thread, every replacement surface the owner asked for,
-- each under its target's existing attachment through the surface bridge's
-- admitted replacement, and deposit what each created for the owner's next
-- step. Answers how many it created or tried to. The attachment is never
-- released or reattached.
--
-- It must run on the main thread, which the owner wakes when it asks. The
-- loop adapter runs it every turn; an application that drives its own loop
-- runs it, as it publishes observations. Each replacement and its deposit are one masked
-- step; a cancellation that nonetheless takes a creation's answer leaves the
-- surface on the lease, where the owner's next step finds and destroys it.
replaceVulkanSurfaces ∷ VulkanController → WindowHost → GraphicsOwner scene → IO Int
replaceVulkanSurfaces (VulkanController state) host owner = do
  asked ← atomically $ (\held → [attachment | (attachment, ReplacementAsked) ← Map.toList held]) <$> readTVar (stateReplacements state)
  lease ← readTVarIO (stateLease state)
  for_ asked $ \attachment → mask_ $ do
    -- Only one still asked for is created: one the attachment's retirement
    -- took meanwhile is not.
    (claimed, acknowledgement) ← atomically $ do
      held ← Map.lookup attachment <$> readTVar (stateReplacements state)
      case held of
        Just ReplacementAsked → do
          modifyTVar' (stateReplacements state) (Map.insert attachment ReplacementCreating)
          (,) True <$> ownerTargetAcknowledgement owner attachment
        _ → pure (False, Nothing)
    when claimed $ create attachment lease acknowledgement
  pure (length asked)
  where
    create attachment lease acknowledgement =
      deposit attachment =<< case (lease, acknowledgement) of
        (LeaseReady leased, Just acknowledged) →
          tryWithContext (bridgeReplace (stateBridge state) host acknowledged leased) >>= \case
            Right answered → pure answered
            Left failure@(ExceptionWithContext _ exception)
              -- A cancellation that took the answer: whatever the bridge
              -- created is on the lease, where the owner's settlement finds
              -- it, and the deposit says only that nothing came back.
              | isAsynchronous exception → do
                  deposit attachment (Right (CreationFailed "a cancellation took the replacement's answer"))
                  rethrowIO (failure ∷ ExceptionWithContextSome)
              | otherwise → pure (Right (CreationFailed (Text.pack (displayException exception))))
        (LeaseReady _, Nothing) → pure (Left "the owner holds no acknowledgement for the attachment")
        _ → pure (Left "no instance is leased to the surface bridge")
    deposit attachment answer =
      atomically $
        modifyTVar' (stateReplacements state) $
          Map.adjust (\case ReplacementCreating → ReplacementDeposited answer; other → other) attachment

-- | Why a target became unavailable.
data UnavailableBecause
  = UnavailableRecoverySpent
    -- ^ Its recovery episode was spent.
  | UnavailableSurfaceUnsupported !Word32
    -- ^ The session's device, through this queue family, cannot present to
    -- the replacement surface recovery made on its window; no other device is
    -- used.
  | UnavailablePresentationUnsupported ![Presentation.PresentationGap]
    -- ^ The replacement surface recovery made cannot serve the presentation
    -- profile, naming every gap.
  deriving (Eq, Show)

-- | An optional target the model marked unavailable (D-22). Its generations
-- retire as their holds end, while every other target continues; its window
-- and attachment stay until the application releases them.
data VulkanUnavailability = VulkanUnavailability
  { unavailableTarget ∷ !TargetId
  , unavailableBecause ∷ !UnavailableBecause
  }
  deriving (Eq, Show)

-- | How many unavailability reports are kept, newest attachments first to stay.
unavailabilitiesRetained ∷ Int
unavailabilitiesRetained = 64

-- | Whether this attachment's target became unavailable, and why, while the
-- report is retained. An application waits on it in 'STM'.
readVulkanUnavailability ∷ VulkanController → AttachmentId → STM (Maybe VulkanUnavailability)
readVulkanUnavailability (VulkanController state) attachment = Map.lookup attachment <$> readTVar (stateUnavailable state)

-- | Announce an attachment whose handover answered
-- 'VulkanAnnouncementDeferred' again, now that the owner's port may have room.
-- Once admitted, the owner constructs it as any other target; until then the
-- owner keeps watching it, and destroys its surface itself if it is released
-- or its window closes first.
announceVulkanTarget ∷ VulkanController → GraphicsOwner scene → GraphicsService → IO EventAdmission
announceVulkanTarget (VulkanController state) owner service = do
  admitted ← announceGraphicsTarget owner service
  when (admitted == EventAdmitted) $
    atomically (modifyTVar' (stateUnannounced state) (Map.delete (graphicsAttachment service)))
  pure admitted

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
  | RejectedSessionFailed !TerminalCause
    -- ^ The session had failed, with this primary failure, before the target
    -- could be admitted.
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
  RejectedSessionFailed cause → "rejected: the graphics session has failed (" <> tshow cause <> ")"

-- | How many rejections are kept, newest attachments first to stay.
rejectionsRetained ∷ Int
rejectionsRetained = 64

retainRejection ∷ State inst msgr phys dev cmd lease obligation → AttachmentId → VulkanRejection → STM ()
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

-- | The session's terminal latch: its primary failure, if it has failed; the
-- device's loss, if that was observed, which may be later than the primary;
-- and what teardown found beside the primary — later failures, and what it
-- retained because it could not be verified.
readVulkanTerminal ∷ VulkanController → STM TerminalReport
readVulkanTerminal (VulkanController state) = readRootsTerminal (stateRoots state)

-- | What a checkpoint learns from the capture — its error latch, set by any
-- error-severity report whatever became of the report's detail, and its
-- sink's failure — in the order they happened, so a checkpoint that learns of
-- both latches the first as the primary.
-- | Claim the capture's order for a failure of the owner's own, and say who
-- holds it: the owner, or the error report or sink failure that came first.
diagnosticOrder ∷ DiagnosticCapture → IO DiagnosticOrder
diagnosticOrder capture =
  claimCaptureOrder capture >>= \case
    OwnerFailedFirst → pure OwnerFirst
    ErrorLatchedFirst → pure ValidationFirst
    SinkFailedFirst → pure (SinkFirst (fmap sinkFailureReason <$> captureSinkFailure capture))

-- | Whether a failure the owner has not acted on asks for a round: the
-- capture's sink has failed and nothing is latched yet — the one diagnostic
-- failure that arrives on a thread of its own rather than inside a call the
-- owner made, so the owner may be idle when it does — or a primary failure
-- has been latched by a checkpoint on another thread, a handover's on the
-- main thread, before the owner's own step took it. The owner's next step
-- then finds it and ends the run; a wake that stayed with the sink alone
-- would miss the second, and leave an idle owner running on a failed session.
failureOwed ∷ State inst msgr phys dev cmd lease obligation → DiagnosticCapture → STM Bool
failureOwed state capture = do
  failed ← isJust <$> captureSinkFailure capture
  latched ← isJust . reportPrimary <$> readRootsTerminal (stateRoots state)
  taken ← readTVar (stateFailureTaken state)
  pure ((failed && not latched) || (latched && not taken))

diagnosticAlarms ∷ DiagnosticCapture → IO [DiagnosticAlarm]
diagnosticAlarms capture =
  map
    ( \case
        CaptureErrorLatched → AlarmValidationError
        CaptureSinkFailed reason → AlarmSinkFailed reason
        CaptureAlarmPending → AlarmPending
        CaptureOwnerClaimed → AlarmOwnerClaimed
    )
    <$> captureAlarms capture

-- | The swapchain generations of the target this attachment is, while the
-- owner holds it.
readVulkanGenerations ∷ VulkanController → AttachmentId → STM (Maybe TargetGenerationsView)
readVulkanGenerations (VulkanController state) attachment =
  Map.lookup attachment <$> readTVar (stateTargets state) >>= \case
    Nothing → pure Nothing
    Just target → readTargetGenerations (stateGenerations state) target

-- | Hold a CPU use of a target's active generation from any thread; while it
-- is held, that generation is not destroyed.
useVulkanGeneration ∷ VulkanController → GenerationId → STM (Either UseRefusal GenerationUse)
useVulkanGeneration (VulkanController state) = useGeneration (stateGenerations state)

endVulkanGenerationUse ∷ VulkanController → GenerationUse → STM ()
endVulkanGenerationUse (VulkanController state) = endGenerationUse (stateGenerations state)

-- | Report what a swapchain call on a target's active generation answered. It
-- is the owner's, as the acquisitions and presentations that produce these
-- results run on its thread (VK-12, VK-13): the report makes the owner's next
-- deadline immediate, so the owner takes the round that reconciles it. A
-- report from another thread wakes nothing, so this stays in the controller's
-- private sublibrary rather than the package's public module.
noteVulkanSwapchainResult ∷ VulkanController → GenerationId → SwapchainResult → STM Bool
noteVulkanSwapchainResult (VulkanController state) = noteSwapchainResult (stateGenerations state)

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
    , opsDeviceQueue = \device family → observe "vkGetDeviceQueue" (opsDeviceQueue ops device family)
    , opsInstrumentation = \device →
        fmap
          (\instrumentation → Instrumentation (\kind handle name → observe "vkSetDebugUtilsObjectNameEXT" (instrumentName instrumentation kind handle name)))
          <$> opsInstrumentation ops device
    , opsGenerations =
        generations
          { opsSurfaceOffer = \physical surface → observe "vkGetPhysicalDeviceSurfaceCapabilitiesKHR" (opsSurfaceOffer generations physical surface)
          , opsCreateSwapchain = \device request → observe "vkCreateSwapchainKHR" (opsCreateSwapchain generations device request)
          , opsSwapchainImages = \device swapchain → observe "vkGetSwapchainImagesKHR" (opsSwapchainImages generations device swapchain)
          , opsCreateImageView = \device image format → observe "vkCreateImageView" (opsCreateImageView generations device image format)
          , opsDestroyImageView = \device view → observe "vkDestroyImageView" (opsDestroyImageView generations device view)
          , opsDestroySwapchain = \device swapchain → observe "vkDestroySwapchainKHR" (opsDestroySwapchain generations device swapchain)
          }
    }
  where
    generations = opsGenerations ops

-- | The surface bridge, with its two native calls observed.
observeBridge ∷ NativeObserver → SurfaceBridge lease obligation → SurfaceBridge lease obligation
observeBridge (NativeObserver observe) bridge =
  bridge
    { bridgeAttach = \host window build →
        bridgeAttach bridge host window (\create → build (observe "glfwCreateWindowSurface" . create))
    , bridgeReplace = \host acknowledgement lease → observe "glfwCreateWindowSurface" (bridgeReplace bridge host acknowledgement lease)
    , bridgeDischarge = observe "vkDestroySurfaceKHR" . bridgeDischarge bridge
    }

-- | The recording's and the frames' native layers, with every call observed
-- under its Vulkan name.
observeRendering ∷ NativeObserver → RenderingOps phys dev cmd → RenderingOps phys dev cmd
observeRendering (NativeObserver observe) ops =
  RenderingOps
    { renderingRecordingOps = \physical → recording <$> renderingRecordingOps ops physical
    , renderingFrameOps = frames (renderingFrameOps ops)
    }
  where
    recording layer =
      layer
        { opsCreatePipelineLayout = observe "vkCreatePipelineLayout" . opsCreatePipelineLayout layer
        , opsDestroyPipelineLayout = \device handle → observe "vkDestroyPipelineLayout" (opsDestroyPipelineLayout layer device handle)
        , opsCreatePipeline = \device request name → observe "vkCreateGraphicsPipelines" (opsCreatePipeline layer device request name)
        , opsDestroyPipeline = \device handle → observe "vkDestroyPipeline" (opsDestroyPipeline layer device handle)
        , opsCreateStorage = \device family → observe "vkCreateCommandPool" (opsCreateStorage layer device family)
        , opsResetStorage = \device pool → observe "vkResetCommandPool" (opsResetStorage layer device pool)
        , opsDestroyStorage = \device pool → observe "vkDestroyCommandPool" (opsDestroyStorage layer device pool)
        , opsBeginCommands = observe "vkBeginCommandBuffer" . opsBeginCommands layer
        , opsEndCommands = observe "vkEndCommandBuffer" . opsEndCommands layer
        }
    frames layer =
      layer
        { opsCreateSemaphore = observe "vkCreateSemaphore" . opsCreateSemaphore layer
        , opsDestroySemaphore = \device handle → observe "vkDestroySemaphore" (opsDestroySemaphore layer device handle)
        , opsCreateFence = observe "vkCreateFence" . opsCreateFence layer
        , opsDestroyFence = \device handle → observe "vkDestroyFence" (opsDestroyFence layer device handle)
        , opsResetFence = \device handle → observe "vkResetFences" (opsResetFence layer device handle)
        , opsFenceSignalled = \device handle → observe "vkGetFenceStatus" (opsFenceSignalled layer device handle)
        , opsAcquireImage = \device swapchain semaphore → observe "vkAcquireNextImageKHR" (opsAcquireImage layer device swapchain semaphore)
        , opsSubmit = \device family batches fence → observe "vkQueueSubmit2" (opsSubmit layer device family batches fence)
        , opsReleaseImages = \device swapchain indices → observe "vkReleaseSwapchainImagesEXT" (opsReleaseImages layer device swapchain indices)
        , opsPresent = \device family request status → observe "vkQueuePresentKHR" (opsPresent layer device family request status)
        , opsWaitFence = \device fence timeout → observe "vkWaitForFences" (opsWaitFence layer device fence timeout)
        }

-- | What one Vulkan graphics host is built from.
data VulkanHostConfig scene = VulkanHostConfig
  { vulkanHost ∷ !HostConfig
    -- ^ The window host; its session configuration is the loader-aware
    -- session's.
  , vulkanCapture ∷ !CaptureConfig
  , vulkanLayers ∷ ![ByteString]
    -- ^ Instance layers to enable, such as the validation layer.
  , vulkanValidationFeatures ∷ ![ValidationFeature]
    -- ^ Validation features the instance's create info enables through those
    -- layers, such as synchronization validation. Empty by default; any at
    -- all refuses the instance unless an enabled layer offers them.
  , vulkanBudgets ∷ !Budgets
  , vulkanScene ∷ !(Prepared scene)
  , vulkanOwner ∷ GraphicsOwnerConfig scene → GraphicsOwnerConfig scene
    -- ^ Adjusts the owner's configuration: its label, its port, its timer.
  , vulkanObserver ∷ DiagnosticCapture → NativeObserver
    -- ^ What observes each native call, given the session's capture.
  , vulkanRenderer ∷ VulkanRenderer scene
    -- ^ How the owner records a frame of the scene it holds.
  , vulkanFrameObserver ∷ FrameObserver
    -- ^ What the owner reports each frame's acquisition, submission,
    -- presentation and observed completion to, on its own thread.
  }

-- | A configuration with the given capture configuration and budgets, no
-- layers or validation features, the owner's defaults, no observer, and a
-- renderer that clears every frame to opaque black.
vulkanHostConfig ∷ HostConfig → CaptureConfig → Budgets → Prepared scene → VulkanHostConfig scene
vulkanHostConfig host capture budgets scene =
  VulkanHostConfig host capture [] [] budgets scene id (const noObserver) (clearRenderer (\_ _ → ClearColor 0 0 0 1)) noFrameObserver

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
  → RenderingOps phys dev cmd
  → (inst → Ptr ())
  → SurfaceBridge lease obligation
  → (SessionConfig → Scoped Session)
  → (Session → IO [ByteString])
  → VulkanHostConfig scene
  → (VulkanHost scene → IO r)
  → IO (r, DiagnosticVerdict)
withVulkanOwnerHostOver = withVulkanOwnerHostHooked noControllerHooks

-- | 'withVulkanOwnerHostOver' with the examples' hooks. Only this package's
-- private sublibrary exports it, and nothing in production calls it.
withVulkanOwnerHostHooked
  ∷ ControllerHooks
  → Logger
  → (DiagnosticCapture → RootOps Quiesced inst msgr phys dev)
  → RenderingOps phys dev cmd
  → (inst → Ptr ())
  → SurfaceBridge lease obligation
  → (SessionConfig → Scoped Session)
  → (Session → IO [ByteString])
  → VulkanHostConfig scene
  → (VulkanHost scene → IO r)
  → IO (r, DiagnosticVerdict)
withVulkanOwnerHostHooked hooks logger layer rendering pointer bridge enter extensions config use =
  withDiagnosticCapture (vulkanCapture config) logger $ \capture → do
    let observer = vulkanObserver config capture
    controller@(VulkanController state) ←
      newVulkanControllerWith
        hooks
        (observeRoots observer (layer capture))
        (observeRendering observer rendering)
        (vulkanFrameObserver config)
        pointer
        (observeBridge observer bridge)
        (vulkanLayers config)
        (vulkanValidationFeatures config)
        (vulkanBudgets config)
        (hostClock host)
        (either (const fallbackPoll) convertedDuration (durationFromSeconds RequirePositive (hostIdleWait host)))
    -- Every checkpoint of the owner's asks the capture for its latches, so a
    -- validation error or a sink failure stops the session at the next one;
    -- every failure of the owner's own is ordered by the capture's first-failure
    -- cell; and a sink failure the worker records while the owner is idle wakes
    -- it for that checkpoint.
    atomically $ do
      watchRootsDiagnosticsOrdered (stateRoots state) (DiagnosticWatch (diagnosticAlarms capture) (diagnosticOrder capture))
      writeTVar (stateWake state) (failureOwed state capture)
    let session = do
          entered ← enter (hostSessionConfig host)
          copied ← liftIO (extensions entered)
          liftIO (atomically (supplyInstanceExtensions controller copied))
          pure entered
        owner = vulkanOwner config (graphicsOwnerConfig (controllerOperations controller (vulkanRenderer config)) (vulkanScene config))
    outcome ←
      tryWithContext $
        withGraphicsOwnerHostIn logger session host owner $ \windows graphics → do
          -- From now on the owner can wake the main thread when it asks for a
          -- replacement surface.
          atomically (writeTVar (stateHostWake state) (wakeGraphicsHost graphics))
          use (VulkanHost windows graphics controller)
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

-- | The period the owner watches an unannounced attachment at when the host's
-- idle bound cannot be converted, which a validated host configuration rules
-- out.
fallbackPoll ∷ Duration
fallbackPoll = either (const minimumPositiveDuration) id (durationFromNanoseconds RequirePositive 10000000)

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
