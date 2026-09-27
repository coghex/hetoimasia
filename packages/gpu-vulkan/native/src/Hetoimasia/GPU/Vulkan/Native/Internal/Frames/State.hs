-- | The state of frame acquisition, submission, presentation and abandonment
-- ("Hetoimasia.GPU.Vulkan.Native.Frames"): the 'Frames' itself and the five
-- maps it owns — each frame slot's synchronization, each target's
-- presentation pool, each live frame's record, each outstanding native
-- submission and each enqueued presentation — with the answers, failures and
-- views every part of it shares, and the helpers more than one part needs.
--
-- This module creates the state ('newFrames') and defines the only edits made
-- to it; @Acquisition@, @Submission@, @Presentation@, @Abandonment@ and
-- @Progress@ apply them, each to the entries its own operation concerns, on
-- the graphics owner's thread. It is private to the package: clients see the
-- 'Frames' only abstractly, through the public module.
module Hetoimasia.GPU.Vulkan.Native.Internal.Frames.State
  ( -- * Records
    FenceState (..)
  , SemaphoreState (..)
  , SlotSync (..)
  , PoolHolder (..)
  , PoolSync (..)
  , FrameStage (..)
  , FrameRecord (..)
  , SubmissionRecord (..)
  , PresentStanding (..)
  , PresentationRecord (..)

    -- * The frames
  , Frames (..)
  , newFrames

    -- * Answers
  , OwnedFrame (..)
  , Acquisition (..)
  , PendingReason (..)
  , Submitted (..)
  , Presented (..)
  , Progress (..)

    -- * Failures
  , FrameEffectUncertain (..)
  , FrameCleanupFailed (..)
  , FramesRetained (..)
  , PresentationUncertain (..)

    -- * Observation
  , FrameStanding (..)
  , readFrameStandings
  , SlotView (..)
  , readSlots
  , readOutstandingSubmissions
  , PoolView (..)
  , readPool
  , PresentationStanding (..)
  , readPresentations

    -- * Shared steps
  , framesRoots
  , framesGenerations
  , readModel
  , deviceOf
  , editSlot
  , editPool
  , editFrame
  , slotOf
  , poolOf
  , freePoolOf
  , uncertain
  , frameMisuse
  ) where

import Control.Concurrent.STM (STM, TVar, modifyTVar', newTVarIO, readTVar)
import Control.Exception (Exception (displayException))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Model (GpuModel, Outcome (..), PresentOutcome, SessionFailureCause, frameView)
import Hetoimasia.GPU.Model.Budget (BudgetKind)
import Hetoimasia.GPU.Model.Identity (FrameSlotId, IdentityKind (..), ImageId, Misuse (..), PresentationId, SubmissionId, TargetId, frameSlotNumber, frameTarget)
import Hetoimasia.GPU.Vulkan.Native.Generations (Generations)
import Hetoimasia.GPU.Vulkan.Native.Internal.Frames.Layer (FrameOps)
import Hetoimasia.GPU.Vulkan.Native.Internal.Recording.State (Recording (..))
import Hetoimasia.GPU.Vulkan.Native.Profile (DevicePlan (..))
import Hetoimasia.GPU.Vulkan.Native.Roots (Roots, failRootsSession, readRootsDevice, stateRootsModel)

-- ---------------------------------------------------------------------------
-- Records

-- | Where one fence stands. Only a fence a native submission made pending is
-- ever asked whether it has signalled, and only an idle or signalled one is
-- ever reset.
data FenceState
  = FenceIdle
    -- ^ Unsignalled, and no submission will signal it: created, or reset and
    -- then not submitted with.
  | FencePending
    -- ^ A native submission returned with it.
  | FenceSignalled
    -- ^ It signalled: the submission that carried it has completed.
  | FenceUncertain !Text
    -- ^ A call on it raised; nothing uses it again.
  deriving (Eq, Show)

-- | Where one binary semaphore stands. It is waited on only while a signal is
-- owed to it, and made to signal only while it is unsignalled with no wait
-- outstanding.
data SemaphoreState
  = SemaphoreUnsignalled
  | SemaphoreSignalOwed
    -- ^ An acquisition or a submission will signal it, and nothing waits on it
    -- yet.
  | SemaphoreWaitOwed
    -- ^ A submission waits on it; its fence is pending.
  | SemaphoreUncertain !Text
  deriving (Eq, Show)

-- | One frame slot's synchronization: its acquisition semaphore, the fence of
-- a native submission it leads, and the fence of its cleanup submissions. They
-- are made together, the first time the slot is reserved, before any
-- acquisition — so a frame that has an image always has what abandoning it
-- needs — and live until the target's frames are retired. The render-finished
-- semaphore is not the slot's: a presentation waits on it for longer than the
-- slot is held, so it belongs to the target's presentation pool ('PoolSync').
data SlotSync = SlotSync
  { syncAcquire ∷ !Word64
  , syncAcquireState ∷ !SemaphoreState
  , syncFence ∷ !Word64
  , syncFenceState ∷ !FenceState
  , syncCleanup ∷ !Word64
  , syncCleanupState ∷ !FenceState
  }
  deriving (Eq, Show)

-- | Whom a presentation-pool record serves.
data PoolHolder
  = PoolFree
    -- ^ Nobody: it may be bound to the next frame reserved on its target.
  | PoolHeldByFrame !FrameSlotId
    -- ^ The frame reserved with it, from its acquisition until it is
    -- presented or settled.
  | PoolHeldByPresentation !PresentationId
    -- ^ The presentation enqueued with it, until its present fence has
    -- signalled.
  deriving (Eq, Show)

-- | One record of a target's presentation pool (P-2): the render-finished
-- semaphore a frame's rendering signals and its presentation waits on, and
-- the present fence that presentation carries. They are made together, the
-- first time the pool needs another record, and bound to a frame when it is
-- reserved — before its acquisition — so presenting never makes, waits for or
-- is refused a record. The model's presentation-pool capacity bounds how many
-- a target ever holds. A record is recycled only once the model has let go of
-- the one it served: after its present fence signalled, or after the explicit
-- settlement of a frame that was never presented — never because the frame's
-- rendering completed, and never because its image was acquired again.
data PoolSync = PoolSync
  { poolRendered ∷ !Word64
  , poolRenderedState ∷ !SemaphoreState
  , poolFence ∷ !Word64
  , poolFenceState ∷ !FenceState
  , poolHolder ∷ !PoolHolder
  }
  deriving (Eq, Show)
-- | Where one frame this owner acquired stands.
data FrameStage
  = StageAcquired
    -- ^ It owns its image; nothing of it has been submitted.
  | StageSubmitted !SubmissionId
    -- ^ Its rendering was submitted, and it has been neither presented nor
    -- abandoned. A presentation removes the frame's record: what remains of it
    -- is the submission's and the presentation's.
  | StageSkipping
    -- ^ Skipped: a cleanup submission waiting on its acquisition semaphore is
    -- pending on the slot's cleanup fence. The image goes back once it has
    -- signalled.
  | StageClosing !SubmissionId
    -- ^ Submitted, then closed without presenting: its rendering must complete
    -- before anything of it is settled.
  | StageSettling
    -- ^ Its rendering completed and a cleanup submission waiting on its
    -- render-finished semaphore is pending on the slot's cleanup fence.
  | StageFailed !Text
    -- ^ A cleanup submission or an image release raised. Everything is
    -- retained, never attempted again, and the session has failed.
  | StageUncertain !Text
    -- ^ A native effect whose bookkeeping did not commit, or whose outcome is
    -- unknown — a submission's or a presentation's. Everything is retained and
    -- the session has failed.
  deriving (Eq, Show)

data FrameRecord = FrameRecord
  { recordImage ∷ !ImageId
  , recordSwapchain ∷ !Word64
    -- ^ The swapchain the image was acquired from, which is the one it is
    -- presented or released to.
  , recordPool ∷ !Natural
    -- ^ The target's presentation-pool record bound to it at its reservation.
  , recordStage ∷ !FrameStage
  }
  deriving (Eq, Show)

-- | One native submission this owner made: the slot whose fence it signals,
-- and every frame it carried.
data SubmissionRecord = SubmissionRecord
  { submissionSlot ∷ !(TargetId, Natural)
  , submissionFrames ∷ ![FrameSlotId]
  }
  deriving (Eq, Show)

-- | Where one enqueued presentation stands.
data PresentStanding
  = PresentPending
    -- ^ Its present fence is pending: the presentation engine may still hold
    -- the semaphore it waited on.
  | PresentUncertain !Text
    -- ^ Asking its present fence raised. It is retained for ever, and the
    -- session has failed.
  deriving (Eq, Show)

-- | One presentation this owner enqueued: the frame and the exact image it
-- presented, the pool record it holds, and what the presentation engine
-- answered for its swapchain.
data PresentationRecord = PresentationRecord
  { presentedFrame ∷ !FrameSlotId
  , presentedImage ∷ !ImageId
  , presentedPool ∷ !Natural
  , presentedOutcome ∷ !PresentOutcome
  , presentedStanding ∷ !PresentStanding
  }
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- The frames

-- | The frames of one session, over its recording and, through it, its
-- generations and roots.
data Frames q inst msgr phys dev cmd = Frames
  { framesOps ∷ !(FrameOps dev cmd)
  , framesRecording ∷ !(Recording q inst msgr phys dev cmd)
  , framesSlots ∷ !(TVar (Map (TargetId, Natural) SlotSync))
  , framesPool ∷ !(TVar (Map (TargetId, Natural) PoolSync))
  , framesLive ∷ !(TVar (Map FrameSlotId FrameRecord))
  , framesSubmissions ∷ !(TVar (Map SubmissionId SubmissionRecord))
  , framesPresentations ∷ !(TVar (Map PresentationId PresentationRecord))
  , framesCursor ∷ !(TVar Natural)
    -- ^ Where the owner's next progress step starts in its work, so a small
    -- action budget reaches every piece of work in turn.
  }

-- | The frames over this recording, owned by the thread that owns it — the
-- graphics owner's.
newFrames ∷ FrameOps dev cmd → Recording q inst msgr phys dev cmd → IO (Frames q inst msgr phys dev cmd)
newFrames ops recording =
  Frames ops recording
    <$> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO 0

framesRoots ∷ Frames q inst msgr phys dev cmd → Roots q inst msgr phys dev
framesRoots = recordingRoots . framesRecording

framesGenerations ∷ Frames q inst msgr phys dev cmd → Generations q inst msgr phys dev
framesGenerations = recordingGenerations . framesRecording

-- ---------------------------------------------------------------------------
-- Answers

-- | An acquired frame: the capability to record, submit or skip it.
data OwnedFrame = OwnedFrame
  { ownedFrame ∷ !FrameSlotId
  , ownedImage ∷ !ImageId
    -- ^ The exact generation and image it owns. A later replacement cannot
    -- change it.
  , ownedSuboptimal ∷ !Bool
    -- ^ The acquisition answered @VK_SUBOPTIMAL_KHR@; a replacement has been
    -- requested beside it, and the frame is still an ordinary one.
  }
  deriving (Eq, Show)

-- | Why no frame was acquired now, when trying again later may acquire one.
data PendingReason
  = PendingNoImage
    -- ^ The swapchain answered not ready or timed out.
  | PendingReplacement
    -- ^ The swapchain is out of date; a replacement was requested.
  | PendingSurfaceLost
    -- ^ The surface was lost; a replacement was requested.
  | PendingGeneration
    -- ^ The target has no generation to acquire from yet.
  | PendingBackpressure !BudgetKind
    -- ^ A frame could not be reserved; nothing was reserved.
  deriving (Eq, Show)

-- | What trying to acquire a frame answered.
data Acquisition
  = AcquisitionOwned !OwnedFrame
  | AcquisitionPending !PendingReason
  | AcquisitionSuspended
    -- ^ The target has no usable extent now.
  | AcquisitionClosing
    -- ^ The target is retiring.
  | AcquisitionUnavailable
    -- ^ The target can no longer render, or the session admits nothing more.
  deriving (Eq, Show)

-- | What a submission did.
data Submitted
  = SubmittedAs !SubmissionId
    -- ^ One native submission is pending, and every frame of the request
    -- shares its one completion obligation.
  | SubmittedNothing !Text
    -- ^ The specified no-effect failure: nothing is pending, the fence is not
    -- waited on, and every frame is still acquired with its batch sealed and
    -- resubmittable.
  deriving (Eq, Show)

-- | What a presentation did.
data Presented
  = PresentedAs !PresentationId !PresentOutcome
    -- ^ A presentation was enqueued, with what the presentation engine
    -- answered for the swapchain: its present fence is pending, and the frame
    -- is the presentation's now. A suboptimal, out-of-date or surface-lost
    -- answer was enqueued all the same and has requested the target's
    -- replacement.
  | PresentedNothing !Text
    -- ^ The specified no-effect failure — out of memory — enqueued nothing
    -- and no present fence: the frame is still submitted and owns its image,
    -- its semaphore and its pool record, and the fence is never waited on.
  deriving (Eq, Show)

-- | What one bounded progress step observed.
data Progress = Progress
  { progressCompleted ∷ ![SubmissionId]
    -- ^ Submissions whose fences had signalled, now recorded as completed.
  , progressRetired ∷ ![PresentationId]
    -- ^ Presentations whose present fences had signalled, now recorded as
    -- retired, their pool records free again.
  , progressSettled ∷ ![FrameSlotId]
    -- ^ Frames whose images went back and whose synchronization was settled.
  , progressCleanups ∷ ![FrameSlotId]
    -- ^ Closed frames whose rendering completed and whose cleanup submission
    -- was made.
  , progressOutstanding ∷ !Natural
    -- ^ Fences still pending after the step.
  }
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Failures

-- | A native effect whose outcome is unknown, or whose bookkeeping could not
-- be committed: the frames concerned are retained for ever, admission has
-- stopped and the session has failed.
data FrameEffectUncertain = FrameEffectUncertain ![FrameSlotId] !Text
  deriving (Eq, Show)

instance Exception FrameEffectUncertain where
  displayException (FrameEffectUncertain frames reason) =
    "the outcome for " <> show frames <> " is uncertain: " <> Text.unpack reason

-- | A cleanup submission or an image release raised. The frame keeps its image
-- and its synchronization, nothing about it is attempted again, and the session
-- has failed with 'CleanupFailed'.
data FrameCleanupFailed = FrameCleanupFailed !FrameSlotId !Text
  deriving (Eq, Show)

instance Exception FrameCleanupFailed where
  displayException (FrameCleanupFailed frame reason) =
    "abandoning " <> show frame <> " did not complete: " <> Text.unpack reason

-- | A target's frames could not be retired: frames that have not settled,
-- presentations that have not retired, or slot or pool synchronization that is
-- still pending or uncertain. They are retained.
data FramesRetained = FramesRetained !TargetId ![FrameSlotId] ![Natural] ![PresentationId] ![Natural]
  deriving (Eq, Show)

instance Exception FramesRetained where
  displayException (FramesRetained target frames slots presentations pool) =
    "the frames of " <> show target <> " are retained: frames " <> show frames <> ", slots " <> show slots
      <> ", presentations " <> show presentations <> ", pool records " <> show pool

-- | Asking a presentation's present fence raised: the presentation, its pool
-- record and its generation's presentation hold are retained for ever, and the
-- session has failed with 'CleanupFailed'.
data PresentationUncertain = PresentationUncertain !PresentationId !Text
  deriving (Eq, Show)

instance Exception PresentationUncertain where
  displayException (PresentationUncertain presentation reason) =
    "whether " <> show presentation <> " retired is uncertain: " <> Text.unpack reason

-- ---------------------------------------------------------------------------
-- Observation

data FrameStanding = FrameStanding
  { standingFrame ∷ !FrameSlotId
  , standingImage ∷ !ImageId
  , standingStage ∷ !FrameStage
  }
  deriving (Eq, Show)

readFrameStandings ∷ Frames q inst msgr phys dev cmd → STM [FrameStanding]
readFrameStandings frames =
  map (\(frame, record) → FrameStanding frame (recordImage record) (recordStage record)) . Map.toAscList
    <$> readTVar (framesLive frames)

data SlotView = SlotView
  { viewSlotTarget ∷ !TargetId
  , viewSlotNumber ∷ !Natural
  , viewSlotSync ∷ !SlotSync
  }
  deriving (Eq, Show)

readSlots ∷ Frames q inst msgr phys dev cmd → STM [SlotView]
readSlots frames = map (\((target, slot), sync) → SlotView target slot sync) . Map.toAscList <$> readTVar (framesSlots frames)

readOutstandingSubmissions ∷ Frames q inst msgr phys dev cmd → STM [SubmissionId]
readOutstandingSubmissions frames = Map.keys <$> readTVar (framesSubmissions frames)

data PoolView = PoolView
  { viewPoolTarget ∷ !TargetId
  , viewPoolNumber ∷ !Natural
  , viewPoolSync ∷ !PoolSync
  }
  deriving (Eq, Show)

-- | Every presentation-pool record, of every target.
readPool ∷ Frames q inst msgr phys dev cmd → STM [PoolView]
readPool frames = map (\((target, number), sync) → PoolView target number sync) . Map.toAscList <$> readTVar (framesPool frames)

data PresentationStanding = PresentationStanding
  { standingPresentation ∷ !PresentationId
  , standingPresentedFrame ∷ !FrameSlotId
  , standingPresentedImage ∷ !ImageId
  , standingPresentedOutcome ∷ !PresentOutcome
  , standingPresent ∷ !PresentStanding
  }
  deriving (Eq, Show)

-- | Every presentation whose present fence has not been observed signalled.
readPresentations ∷ Frames q inst msgr phys dev cmd → STM [PresentationStanding]
readPresentations frames =
  map
    ( \(presentation, record) →
        PresentationStanding presentation (presentedFrame record) (presentedImage record) (presentedOutcome record) (presentedStanding record)
    )
    . Map.toAscList
    <$> readTVar (framesPresentations frames)

-- ---------------------------------------------------------------------------
-- Shared steps

readModel ∷ Frames q inst msgr phys dev cmd → STM GpuModel
readModel frames = stateRootsModel (framesRoots frames) (\model → (model, model))

-- | The live device and the one queue family every target shares.
deviceOf ∷ Frames q inst msgr phys dev cmd → STM (Maybe (dev, Word32))
deviceOf frames = fmap (\(plan, device) → (device, planQueueFamily plan)) <$> readRootsDevice (framesRoots frames)

editSlot ∷ Frames q inst msgr phys dev cmd → (TargetId, Natural) → (SlotSync → SlotSync) → STM ()
editSlot frames key edit = modifyTVar' (framesSlots frames) (Map.adjust edit key)

editPool ∷ Frames q inst msgr phys dev cmd → (TargetId, Natural) → (PoolSync → PoolSync) → STM ()
editPool frames key edit = modifyTVar' (framesPool frames) (Map.adjust edit key)

editFrame ∷ Frames q inst msgr phys dev cmd → FrameSlotId → (FrameRecord → FrameRecord) → STM ()
editFrame frames frame edit = modifyTVar' (framesLive frames) (Map.adjust edit frame)

slotOf ∷ FrameSlotId → (TargetId, Natural)
slotOf frame = (frameTarget frame, frameSlotNumber frame)

-- | The key of the pool record a frame holds.
poolOf ∷ FrameSlotId → FrameRecord → (TargetId, Natural)
poolOf frame record = (frameTarget frame, recordPool record)

-- | Let go of the pool record a frame holds: it serves nobody now. Its
-- objects are left as they are, so it is reused only once they are idle.
freePoolOf ∷ Frames q inst msgr phys dev cmd → FrameSlotId → STM ()
freePoolOf frames frame =
  modifyTVar' (framesPool frames) $
    Map.map (\sync → if poolHolder sync == PoolHeldByFrame frame then sync {poolHolder = PoolFree} else sync)

-- | Enter the uncertain state for these frames: each is retained for ever, and
-- admission closes and the session fails with the cause, in one transaction.
uncertain ∷ Frames q inst msgr phys dev cmd → SessionFailureCause → [FrameSlotId] → Text → STM ()
uncertain frames cause members reason = do
  mapM_ (\frame → editFrame frames frame (\record → record {recordStage = StageUncertain reason})) members
  failRootsSession (framesRoots frames) cause

-- | The model's own classification of a frame this owner holds no record of:
-- asking it to perform the operation, and keeping only the refusal, changes
-- nothing. A frame the model holds that this owner never acquired, or no
-- longer holds a record of, is unknown to it.
frameMisuse ∷ GpuModel → FrameSlotId → (FrameSlotId → GpuModel → Outcome a) → Misuse
frameMisuse model frame operation = case frameView frame model of
  Nothing → case operation frame model of
    Rejected misuse → misuse
    _ → UnknownIdentity FrameIdentity
  Just _ → UnknownIdentity FrameIdentity
