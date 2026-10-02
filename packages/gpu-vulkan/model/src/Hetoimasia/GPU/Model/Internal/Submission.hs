-- | Submission: resetting a frame's submission fence, submitting acquired
-- frames under one shared record, and asking which batches an outstanding
-- submission consumed.
--
-- This module owns the promotion of recorded references to submitted uses and
-- the uncertain-effect state that retains its parents and stops admission. A
-- submitted use ends only through the completion evidence in
-- "Hetoimasia.GPU.Model.Internal.Completion", or through the device-loss release in
-- "Hetoimasia.GPU.Model.Internal.Session".
module Hetoimasia.GPU.Model.Internal.Submission
  ( SubmitOutcome (..)
  , SubmitAnswer (..)
  , resetSubmissionFence
  , submitFrames
  , submissionCarries
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Hetoimasia.GPU.Model.Internal.Accounting (editFrame, editHolds, releaseObjects, reservedSubmission, saturatingMinus)
import Hetoimasia.GPU.Model.Internal.Hold (dischargeRecorded, retainSubmitted)
import Hetoimasia.GPU.Model.Internal.Identity
import Hetoimasia.GPU.Model.Internal.Initialization (publishInitialization, withdrawInitialization)
import Hetoimasia.GPU.Model.Internal.Records
import Hetoimasia.GPU.Model.Internal.Resolve (resolveFrame, resolveSubmission, targetIdOf)
import Hetoimasia.GPU.Model.Internal.Scheduling (scheduling, scheduling_)
import Hetoimasia.GPU.Model.Internal.Session (escalateSession)
import Hetoimasia.GPU.Model.Internal.State

-- | Reset the frame's submission fence. A reset fence with nothing submitted is
-- never pending work: it adds no obligation here and none is counted for it.
resetSubmissionFence ∷ FrameSlotId → GpuModel → Outcome GpuModel
resetSubmissionFence identity model =
  scheduling_ model $
  resolved (resolveFrame model identity) $ \(number, slot, frame) →
    if framePhase frame /= FrameAcquired
      then Rejected (WrongPhase FrameIdentity)
      else Admitted (editFrame number slot (\entry → entry {frameFenceReset = True}) model)

-- | What the submission call did.
data SubmitOutcome
  = SubmissionAccepted
  | SubmissionFailedWithoutEffect
    -- ^ A specified result with no effects. Nothing is pending.
  | SubmissionEffectUncertain
    -- ^ Bookkeeping could not be committed after a possibly effective call.
  deriving (Eq, Show)

data SubmitAnswer
  = SubmissionRecorded !SubmissionId
  | AcquisitionRetained
    -- ^ No submission is pending; the acquisition and its recording stay owned.
  | EffectUncertain
    -- ^ The frames entered the uncertain-effect state: parents are retained,
    -- the record can never be discharged, and admission has stopped.
  deriving (Eq, Show)

-- | Submit one or more acquired frames. Frames listed in one call share exactly
-- one submission record; frames submitted by separate calls do not.
submitFrames ∷ [FrameSlotId] → SubmitOutcome → GpuModel → Outcome (GpuModel, SubmitAnswer)
submitFrames identities outcome model
  | null identities = Rejected EmptySubmission
  | otherwise =
      scheduling model $
      -- Only an accepted submission is new work. A call that failed — with no
      -- effect, or with an effect nobody can know — is the outcome of a
      -- submission admitted while the session ran, and it is recorded even
      -- when that same call's failure ended the session, so an uncertain
      -- effect still retains what it concerns.
      resolved (if outcome == SubmissionAccepted then running model else Right ()) $ \() →
        resolved (traverse (resolveFrame model) identities) $ \frames →
          let keys = [(number, slot) | (number, slot, _) ← frames]
           in if length (Set.toList (Set.fromList keys)) /= length keys
                then Rejected (DuplicateSubject FrameIdentity)
                else
                  if any (\(_, _, frame) → framePhase frame /= FrameAcquired) frames
                    then Rejected (WrongPhase FrameIdentity)
                    else case outcome of
                      SubmissionFailedWithoutEffect →
                        Admitted (foldl' clearFence model frames, AcquisitionRetained)
                      SubmissionAccepted → accept frames False
                      SubmissionEffectUncertain → accept frames True
  where
    clearFence current (number, slot, _) =
      editFrame number slot (\entry → entry {frameFenceReset = False}) current
    -- No accounting is charged here, and none can be refused here. The object
    -- this record occupies was reserved with the frame, before the native call
    -- whose outcome is now being committed; the other frames of a shared
    -- submission give theirs back, because one record covers them all.
    accept frames uncertain =
      let charged =
            releaseObjects
              (sum [reservedSubmission frame | (_, _, frame) ← frames] `saturatingMinus` 1)
              model
       in accepted charged frames uncertain
    accepted charged frames uncertain =
        let submission = gpuNextSubmission charged
            batches = concat [Set.toList (frameBatches frame) | (_, _, frame) ← frames]
            referenced batch = maybe Set.empty batchSubjects (Map.lookup batch (gpuBatches charged))
            -- Every frame's own swapchain generation is a subject of the
            -- submission whether or not a batch named it: the submitted work
            -- renders into that generation's image, so its completion is owed
            -- even for a submission that recorded nothing.
            rendered =
              Set.fromList
                [ GenerationKey number generation
                | (number, _, frame) ← frames
                , Just generation ← [frameGeneration frame]
                ]
            subjects = Set.unions (rendered : map referenced batches)
            -- A confirmed submission publishes what its batches initialize;
            -- one whose effect is unknown publishes nothing, and what its
            -- batches were initializing awaits initialization again.
            settled =
              foldl'
                ( \current batch → case Map.lookup batch (gpuBatches charged) of
                    Nothing → current
                    Just record → (if uncertain then withdrawInitialization else publishInitialization) batch record current
                )
                charged
                batches
            promoted =
              foldl' (\current key → editHolds key (retainSubmitted submission) current) settled (Set.toList subjects)
            dischargedRefs =
              foldl'
                ( \current batch →
                    foldl' (\inner key → editHolds key (dischargeRecorded batch) inner) current (Set.toList (referenced batch))
                )
                promoted
                batches
            withoutBatches =
              (releaseObjects (fromIntegral (length batches)) dischargedRefs)
                {gpuBatches = foldl' (flip Map.delete) (gpuBatches dischargedRefs) batches}
            phase = if uncertain then FrameUncertainEffect else FrameSubmitted
            advanced =
              foldl'
                ( \current (number, slot, _) →
                    editFrame
                      number
                      slot
                      ( \entry →
                          entry
                            { framePhase = phase
                            , frameSubmission = Just submission
                            , frameSubmissionReserved = False
                            , frameBatches = Set.empty
                            , frameFenceReset = False
                            }
                      )
                      current
                )
                withoutBatches
                frames
            recorded =
              advanced
                { gpuSubmissions =
                    Map.insert
                      submission
                      Submission
                        { submissionFrames = [(number, slot) | (number, slot, _) ← frames]
                        , submissionBatches =
                            Set.fromList
                              [ BatchId (targetIdOf charged (batchTargetNumber record) target) number
                              | number ← batches
                              , Just record ← [Map.lookup number (gpuBatches charged)]
                              , Just target ← [Map.lookup (batchTargetNumber record) (gpuTargets charged)]
                              ]
                        , submissionSubjects = subjects
                        , submissionUncertain = uncertain
                        }
                      (gpuSubmissions advanced)
                , gpuNextSubmission = submission + 1
                }
         in if uncertain
              then Admitted (escalateSession UnknownSubmissionEffect recorded, EffectUncertain)
              else Admitted (recorded, SubmissionRecorded (SubmissionId (gpuSession recorded) submission))

-- | Whether an outstanding submission consumed this exact batch — this
-- session's, this target incarnation's, this number: the positive evidence
-- that a batch's recorded work was submitted, rather than discarded, reset or
-- skipped. Another session's batch of the same number is not it. 'Nothing' when the submission is not outstanding — never
-- issued, another session's, or already completed.
submissionCarries ∷ SubmissionId → BatchId → GpuModel → Maybe Bool
submissionCarries submission batch model = case resolveSubmission model submission of
  Right (_, record) → Just (batch `Set.member` submissionBatches record)
  Left _ → Nothing
