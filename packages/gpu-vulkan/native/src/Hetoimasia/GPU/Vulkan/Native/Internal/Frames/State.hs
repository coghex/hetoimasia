-- | The state of frame acquisition, submission and abandonment
-- ("Hetoimasia.GPU.Vulkan.Native.Frames"): the 'Frames' itself and the three
-- maps it owns — each frame slot's synchronization, each live frame's record,
-- and each outstanding native submission — with the answers, failures and
-- views every part of it shares, and the helpers more than one part needs.
--
-- This module creates the state ('newFrames') and defines the only edits made
-- to it; @Acquisition@, @Submission@ and @Abandonment@ apply them, each to the
-- entries its own operation concerns, on the graphics owner's thread. It is
-- private to the package: clients see the 'Frames' only abstractly, through
-- the public module.
module Hetoimasia.GPU.Vulkan.Native.Internal.Frames.State
  ( -- * Records
    FenceState (..)
  , SemaphoreState (..)
  , SlotSync (..)
  , FrameStage (..)
  , FrameRecord (..)
  , SubmissionRecord (..)

    -- * The frames
  , Frames (..)
  , newFrames

    -- * Answers
  , OwnedFrame (..)
  , Acquisition (..)
  , PendingReason (..)
  , Submitted (..)
  , Progress (..)

    -- * Failures
  , FrameEffectUncertain (..)
  , FrameCleanupFailed (..)
  , FramesRetained (..)

    -- * Observation
  , FrameStanding (..)
  , readFrameStandings
  , SlotView (..)
  , readSlots
  , readOutstandingSubmissions

    -- * Shared steps
  , framesRoots
  , framesGenerations
  , readModel
  , deviceOf
  , editSlot
  , editFrame
  , slotOf
  , uncertain
  ) where

import Control.Concurrent.STM (STM, TVar, modifyTVar', newTVarIO, readTVar)
import Control.Exception (Exception (displayException))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Model (GpuModel, SessionFailureCause)
import Hetoimasia.GPU.Model.Budget (BudgetKind)
import Hetoimasia.GPU.Model.Identity (FrameSlotId, ImageId, SubmissionId, TargetId, frameSlotNumber, frameTarget)
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

-- | One frame slot's synchronization: its acquisition semaphore, the
-- render-finished semaphore its submissions signal, the fence of a native
-- submission it leads, and the fence of its cleanup submissions. They are made
-- together, the first time the slot is reserved, before any acquisition — so
-- a frame that has an image always has what abandoning it needs — and live
-- until the target's frames are retired.
data SlotSync = SlotSync
  { syncAcquire ∷ !Word64
  , syncAcquireState ∷ !SemaphoreState
  , syncRendered ∷ !Word64
  , syncRenderedState ∷ !SemaphoreState
  , syncFence ∷ !Word64
  , syncFenceState ∷ !FenceState
  , syncCleanup ∷ !Word64
  , syncCleanupState ∷ !FenceState
  }
  deriving (Eq, Show)

-- | Where one frame this owner acquired stands.
data FrameStage
  = StageAcquired
    -- ^ It owns its image; nothing of it has been submitted.
  | StageSubmitted !SubmissionId
    -- ^ Its rendering was submitted, and it has not been abandoned.
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
    -- unknown. Everything is retained and the session has failed.
  deriving (Eq, Show)

data FrameRecord = FrameRecord
  { recordImage ∷ !ImageId
  , recordSwapchain ∷ !Word64
    -- ^ The swapchain the image was acquired from, which is the one it is
    -- released to.
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

-- ---------------------------------------------------------------------------
-- The frames

-- | The frames of one session, over its recording and, through it, its
-- generations and roots.
data Frames q inst msgr phys dev cmd = Frames
  { framesOps ∷ !(FrameOps dev cmd)
  , framesRecording ∷ !(Recording q inst msgr phys dev cmd)
  , framesSlots ∷ !(TVar (Map (TargetId, Natural) SlotSync))
  , framesLive ∷ !(TVar (Map FrameSlotId FrameRecord))
  , framesSubmissions ∷ !(TVar (Map SubmissionId SubmissionRecord))
  }

-- | The frames over this recording, owned by the thread that owns it — the
-- graphics owner's.
newFrames ∷ FrameOps dev cmd → Recording q inst msgr phys dev cmd → IO (Frames q inst msgr phys dev cmd)
newFrames ops recording = Frames ops recording <$> newTVarIO Map.empty <*> newTVarIO Map.empty <*> newTVarIO Map.empty

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

-- | What one bounded progress step observed.
data Progress = Progress
  { progressCompleted ∷ ![SubmissionId]
    -- ^ Submissions whose fences had signalled, now recorded as completed.
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

-- | A target's frames could not be retired: frames that have not settled, or
-- synchronization that is still pending or uncertain. They are retained.
data FramesRetained = FramesRetained !TargetId ![FrameSlotId] ![Natural]
  deriving (Eq, Show)

instance Exception FramesRetained where
  displayException (FramesRetained target frames slots) =
    "the frames of " <> show target <> " are retained: frames " <> show frames <> ", slots " <> show slots

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

-- ---------------------------------------------------------------------------
-- Shared steps

readModel ∷ Frames q inst msgr phys dev cmd → STM GpuModel
readModel frames = stateRootsModel (framesRoots frames) (\model → (model, model))

-- | The live device and the one queue family every target shares.
deviceOf ∷ Frames q inst msgr phys dev cmd → STM (Maybe (dev, Word32))
deviceOf frames = fmap (\(plan, device) → (device, planQueueFamily plan)) <$> readRootsDevice (framesRoots frames)

editSlot ∷ Frames q inst msgr phys dev cmd → (TargetId, Natural) → (SlotSync → SlotSync) → STM ()
editSlot frames key edit = modifyTVar' (framesSlots frames) (Map.adjust edit key)

editFrame ∷ Frames q inst msgr phys dev cmd → FrameSlotId → (FrameRecord → FrameRecord) → STM ()
editFrame frames frame edit = modifyTVar' (framesLive frames) (Map.adjust edit frame)

slotOf ∷ FrameSlotId → (TargetId, Natural)
slotOf frame = (frameTarget frame, frameSlotNumber frame)

-- | Enter the uncertain state for these frames: each is retained for ever, and
-- admission closes and the session fails with the cause, in one transaction.
uncertain ∷ Frames q inst msgr phys dev cmd → SessionFailureCause → [FrameSlotId] → Text → STM ()
uncertain frames cause members reason = do
  mapM_ (\frame → editFrame frames frame (\record → record {recordStage = StageUncertain reason})) members
  failRootsSession (framesRoots frames) cause
