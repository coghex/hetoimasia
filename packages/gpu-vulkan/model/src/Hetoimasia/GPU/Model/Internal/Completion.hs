-- | Injected evidence: the completion facts the owning boundary observes, the
-- disposal results it reports, the interface through which the model asks for
-- both, and the application of each fact.
--
-- This module owns the separation of submission completion, presentation
-- retirement and the settlement of an unpresented frame, and the pairing of a
-- retirement cycle's two halves within one recovery epoch. The model makes no
-- fact of its own: every one arrives here from the caller.
module Hetoimasia.GPU.Model.Internal.Completion
  ( CompletionFact (..)
  , DisposalResult (..)
  , EvidenceSource (..)
  , silentEvidence
  , recordCompletion
  ) where

import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
import qualified Data.Set as Set
import Hetoimasia.Foundation.Time (Instant)
import Hetoimasia.GPU.Model.Internal.Accounting (editFrame, editHolds, editTarget, releaseObjects, settleFrames)
import Hetoimasia.GPU.Model.Internal.Hold (dischargePresentation, dischargeSubmitted)
import Hetoimasia.GPU.Model.Internal.Identity
import Hetoimasia.GPU.Model.Internal.Records
import Hetoimasia.GPU.Model.Internal.Recovery (noteRetirementCycle)
import Hetoimasia.GPU.Model.Internal.Resolve (resolveFrame, resolvePresentation, resolveSubmission)
import Hetoimasia.GPU.Model.Internal.Scheduling (observing_)
import Hetoimasia.GPU.Model.Internal.State
import Numeric.Natural (Natural)

-- | A fact the owning boundary observed. The model never makes one, and none of
-- them names a native mechanism: what proved the fact is the boundary's
-- business.
data CompletionFact
  = SubmissionCompleted !SubmissionId
  | PresentationRetired !PresentationId
  | UnpresentedFrameSettled !FrameSlotId
    -- ^ An acquired frame that was never presented has had its image and its
    -- synchronization obligations settled.
  deriving (Eq, Show)

data DisposalResult
  = DisposalCompleted
  | DisposalRefused
    -- ^ The boundary declined to dispose of the subject now. Nothing changes.
  | DisposalFailed
    -- ^ The disposal was attempted and failed. Ownership and accounting are
    -- retained and the session escalates; a cleanup failure is never permission
    -- to proceed as though rollback succeeded.
  deriving (Eq, Show)

-- | The interface the owner injects. The model asks; it never assumes.
data EvidenceSource = EvidenceSource
  { submissionEvidence ∷ SubmissionId → Bool
  , presentationEvidence ∷ PresentationId → Bool
  , unpresentedFrameEvidence ∷ FrameSlotId → Bool
  , disposalEvidence ∷ HoldSubject → DisposalResult
  }

-- | An interface that proves nothing and disposes of nothing. A model driven by
-- it can never complete anything, which is exactly the condition storage bounds
-- have to survive.
silentEvidence ∷ EvidenceSource
silentEvidence =
  EvidenceSource
    { submissionEvidence = const False
    , presentationEvidence = const False
    , unpresentedFrameEvidence = const False
    , disposalEvidence = const DisposalRefused
    }

-- | Apply one fact. The instant is the caller's reading of the injected clock;
-- it is used only to date the healthy-progress evidence a recovery reset needs.
recordCompletion ∷ Instant → CompletionFact → GpuModel → Outcome GpuModel
recordCompletion now fact model = observing_ model $ case fact of
  SubmissionCompleted identity →
    resolved (resolveSubmission model identity) $ \(number, submission) →
      if submissionUncertain submission
        then Rejected (WrongPhase SubmissionIdentity)
        else Admitted (applySubmission now number submission model)
  PresentationRetired identity →
    resolved (resolvePresentation model identity) $ \(number, record, entry) →
      if poolState entry /= PoolEnqueued
        then Rejected (WrongPhase PresentationIdentity)
        else Admitted (applyPresentation now number record entry model)
  UnpresentedFrameSettled identity →
    resolved (resolveFrame model identity) $ \(number, slot, frame) →
      if framePhase frame /= FrameRetiring
        then Rejected (WrongPhase FrameIdentity)
        else case framePoolRecord frame of
          Nothing → Rejected (AlreadyConsumed PresentationIdentity)
          Just pool → Admitted (applySettlement number slot pool frame model)

applySubmission ∷ Instant → Natural → Submission → GpuModel → GpuModel
applySubmission now number submission model = settleFrames (submissionFrames submission) advanced
  where
    discharged =
      releaseObjects
        1
        ( foldl'
            (\current key → editHolds key (dischargeSubmitted number) current)
            model
            (Set.toList (submissionSubjects submission))
        )
          {gpuSubmissions = Map.delete number (gpuSubmissions model)}
    -- The rendering half arrives for every cycle waiting on this submission, on
    -- whichever targets they belong to.
    advanced =
      foldl'
        (\current target → advanceCycles now target (renders number) current)
        remembered
        (Map.keys (gpuTargets remembered))
    -- A frame whose presentation has not been enqueued yet has no cycle to put
    -- this half in, so the epoch it arrived in is remembered on the frame until
    -- the enqueue that opens one.
    remembered = foldl' remember discharged (submissionFrames submission)
    remember current (target, slot) = case Map.lookup target (gpuTargets current) of
      Nothing → current
      Just record
        | Just frame ← Map.lookup slot (targetFrames record)
        , framePhase frame /= FramePresentationEnqueued →
            editFrame target slot (\entry → entry {frameRenderedEpoch = Just (targetRecoveryEpoch record)}) current
        | otherwise → current
    -- Matched by the submission this cycle is waiting on, which is the only
    -- thing that makes it this cycle's half rather than another's.
    renders wanted epoch _ entry
      | cycleSubmission entry == Just wanted =
          Just entry {cycleSubmission = Nothing, cycleRendered = Just epoch}
      | otherwise = Nothing

applyPresentation ∷ Instant → Natural → Natural → PoolRecord → GpuModel → GpuModel
applyPresentation now number record entry model = settleFrames [(number, slot) | slot ← users] advanced
  where
    users = slotsUsing number record model
    removed =
      editTarget
        number
        (\target → target {targetPool = Map.delete record (targetPool target)})
        (releaseObjects 1 (discharge model))
    -- The presentation half arrives for this record's own cycle, and for no
    -- other: the record is what identifies a cycle, so it is what the half is
    -- matched by. Marking every unpresented cycle would let one frame's
    -- retirement pair with another frame's rendering.
    advanced = advanceCycles now number presents removed
    presents epoch key waiting
      | key /= record = Nothing
      | isJust (cyclePresented waiting) = Nothing
      | otherwise = Just waiting {cyclePresented = Just epoch}
    discharge current = case poolGeneration entry of
      Nothing → current
      Just generation → editHolds (GenerationKey number generation) (dischargePresentation record) current

-- | Apply one half to whichever of a target's cycles it belongs to, completing
-- those that now have both.
--
-- Completing a cycle credits it only when its epoch is still the target's. A
-- cycle stamped with a spent epoch spans a recovery attempt, and evidence from
-- either side of an attempt says nothing about the other; it is dropped rather
-- than credited. Dropping it touches no hold and no accounting: what it settles
-- is whether the target has been healthy, and nothing else.
advanceCycles ∷ Instant → Natural → (Natural → Natural → Cycle → Maybe Cycle) → GpuModel → GpuModel
advanceCycles now number half model = case Map.lookup number (gpuTargets model) of
  Nothing → model
  Just target → foldl' (apply (targetRecoveryEpoch target)) model (Map.toList (targetCycles target))
  where
    apply epoch current (record, pending) = case half epoch record pending of
      Nothing → current
      Just moved
        | isJust (cyclePresented moved) && isNothing (cycleSubmission moved) → complete epoch current record moved
        | otherwise → editTarget number (\entry → entry {targetCycles = Map.insert record moved (targetCycles entry)}) current
    -- Both halves must belong to the epoch the target is in now. A half that
    -- arrived in an earlier one is separated from the other by a recovery
    -- attempt, which is exactly what makes them incomparable — whichever half it
    -- was, and whether it arrived before this cycle was even opened.
    complete epoch current record settled =
      editTarget
        number
        ( \entry →
            entry
              { targetCycles = Map.delete record (targetCycles entry)
              , targetRecovery =
                  if cycleRendered settled == Just epoch && cyclePresented settled == Just epoch
                    then noteRetirementCycle now (targetRecovery entry)
                    else targetRecovery entry
              }
        )
        current

applySettlement ∷ Natural → Natural → Natural → Frame → GpuModel → GpuModel
applySettlement number slot pool frame model =
  settleFrames [(number, slot)] $
    editFrame number slot (\entry → entry {framePoolRecord = Nothing}) $
      editTarget
        number
        (\target → target {targetPool = Map.delete pool (targetPool target)})
        (releaseObjects 1 (discharge model))
  where
    discharge current = case frameGeneration frame of
      Nothing → current
      Just generation → editHolds (GenerationKey number generation) (dischargePresentation pool) current

slotsUsing ∷ Natural → Natural → GpuModel → [Natural]
slotsUsing number record model = case Map.lookup number (gpuTargets model) of
  Nothing → []
  Just target → [slot | (slot, frame) ← Map.toList (targetFrames target), framePoolRecord frame == Just record]
