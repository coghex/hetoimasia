-- | Session escalation and device loss: the bounded window of escalation
-- notices, the session's first failure cause, the separately recorded
-- observation of the device's loss, and the release that loss permits.
--
-- The session state itself is part of the model's representation in
-- "Hetoimasia.GPU.Model.Internal.State". This module owns how it changes: escalation keeps
-- the first cause and notifies only that one, and 'releaseToDeviceLoss' lets go
-- of exactly the obligations only the lost device could have discharged.
module Hetoimasia.GPU.Model.Internal.Session
  ( -- * Escalation
    escalations
  , escalationsDropped
  , takeEscalations
  , escalateSession
  , note

    -- * Device loss
  , noteDeviceLoss
  , deviceLossObserved
  , DeviceLossRelease (..)
  , releaseToDeviceLoss
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Hetoimasia.GPU.Model.Internal.Accounting (editHolds, editTarget, releaseObjects, reservedSubmission)
import Hetoimasia.GPU.Model.Internal.Budget (targetRecordLimit)
import Hetoimasia.GPU.Model.Internal.Hold (dischargePresentation, dischargeSubmitted)
import Hetoimasia.GPU.Model.Internal.Identity
import Hetoimasia.GPU.Model.Internal.Records
import Hetoimasia.GPU.Model.Internal.Resolve (targetIdOf)
import Hetoimasia.GPU.Model.Internal.Scheduling (settleSchedule)
import Hetoimasia.GPU.Model.Internal.State
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Escalation

-- | The escalations the model is still holding, oldest first. They are notices
-- for the owning boundary rather than state the model acts on, so a boundary
-- that reads them without 'takeEscalations' sees the retained window.
escalations ∷ GpuModel → [Escalation]
escalations = reverse . gpuEscalations

-- | How many notices were dropped to keep the retained window finite. A dropped
-- notice is counted rather than forgotten, on the same rule as every other
-- accounting here: nothing vanishes unaccounted.
escalationsDropped ∷ GpuModel → Natural
escalationsDropped = gpuEscalationsDropped

-- | Take the retained notices, leaving none behind. This is the consuming read;
-- a boundary that drains each turn never reaches the window's bound.
takeEscalations ∷ GpuModel → (GpuModel, [Escalation])
takeEscalations model = (model {gpuEscalations = []}, escalations model)

-- | Escalate the session. The first cause is kept: a teardown that then fails
-- cleanup must not overwrite the device loss that started it — and only that
-- first cause is notified, so a session cannot accumulate a notice per later
-- failure of a session that has already ended.
escalateSession ∷ SessionFailureCause → GpuModel → GpuModel
escalateSession cause model = case gpuState model of
  SessionFailed _ → model
  SessionRunning → (note (SessionEscalated cause) model) {gpuState = SessionFailed cause}

-- | Retain one escalation notice, keeping the session's notice window finite.
--
-- Deduplication alone is not a bound: a target number is reissued under a fresh
-- incarnation, so a session that admits, loses and readmits an optional target
-- for ever would produce a distinct notice every time. The window therefore
-- holds at most one notice per target record the configuration allows, plus the
-- one a failed session can ever raise; beyond that the oldest is dropped and
-- counted.
note ∷ Escalation → GpuModel → GpuModel
note escalation model
  | escalation `elem` gpuEscalations model = model
  | length retained >= capacity =
      model
        { gpuEscalations = escalation : take (capacity - 1) retained
        , gpuEscalationsDropped = gpuEscalationsDropped model + fromIntegral (length retained - (capacity - 1))
        }
  | otherwise = model {gpuEscalations = escalation : retained}
  where
    retained = gpuEscalations model
    capacity = fromIntegral (targetRecordLimit (gpuBudgets model)) + 1

-- ---------------------------------------------------------------------------
-- Device loss

-- | Record that the device was lost. The session fails with 'DeviceLost' if
-- nothing failed it first; if something did, that first cause is kept and only
-- the loss itself is recorded, which is what lets a later teardown use the
-- device-loss rules without rewriting why the session ended.
noteDeviceLoss ∷ GpuModel → GpuModel
noteDeviceLoss model = (escalateSession DeviceLost model) {gpuDeviceLost = True}

-- | Whether the boundary has recorded the device's loss, whatever the
-- session's first cause was.
deviceLossObserved ∷ GpuModel → Bool
deviceLossObserved = gpuDeviceLost

-- | What 'releaseToDeviceLoss' let go of.
data DeviceLossRelease = DeviceLossRelease
  { releasedSubmissions ∷ ![SubmissionId]
    -- ^ Every outstanding submission, certain or uncertain. None of them is
    -- recorded as completed.
  , releasedPresentations ∷ ![PresentationId]
    -- ^ Every enqueued presentation, and every record awaiting an unpresented
    -- frame's settlement. None of them is recorded as retired.
  , releasedFrames ∷ ![FrameSlotId]
    -- ^ Every frame that had left acquisition: submitted, enqueued, retiring or
    -- in the uncertain-effect state.
  , releaseRemaining ∷ ![FrameSlotId]
    -- ^ Frames still reserved or acquired, which the boundary must skip before
    -- anything of theirs can be let go.
  }
  deriving (Eq, Show)

-- | Let go of every obligation that only the lost device could have
-- discharged: submitted uses, presentation obligations, and the frames that
-- owed nothing else.
--
-- This is the specification's device-loss rule — a lost device's objects may
-- be destroyed without waiting for their pending work, because that work may
-- never complete — and nothing more. It is not completion: no submission is
-- recorded as completed, no presentation as retired, no cycle is credited and
-- no recovery episode sees healthy progress, so nothing here can be read as a
-- fence having signalled. It discharges the uncertain-effect records too,
-- since what was unknown about them is whether the device ran their work, and
-- the rule makes that irrelevant to destroying what they retained. What stays
-- is everything the device's loss says nothing about: a frame still reserved
-- or acquired, whose unsubmitted recording the boundary must invalidate and
-- skip first; recorded references, logical release and CPU use; and every
-- disposal that already failed.
--
-- It is refused as 'WrongPhase' of the device unless the loss was recorded
-- with 'noteDeviceLoss'. Releasing twice releases nothing the second time.
releaseToDeviceLoss ∷ GpuModel → Outcome (GpuModel, DeviceLossRelease)
releaseToDeviceLoss model
  | not (gpuDeviceLost model) = Rejected (WrongPhase DeviceIdentity)
  | otherwise = Admitted (settleSchedule True model released, report)
  where
    releasing phase = phase `elem` [FrameSubmitted, FramePresentationEnqueued, FrameRetiring, FrameUncertainEffect]
    frames =
      [ (number, target, slot, frame)
      | (number, target) ← Map.toList (gpuTargets model)
      , (slot, frame) ← Map.toList (targetFrames target)
      ]
    leaving = [(number, slot, frame) | (number, _, slot, frame) ← frames, releasing (framePhase frame)]
    remaining = [identityOf number target slot frame | (number, target, slot, frame) ← frames, not (releasing (framePhase frame))]
    identityOf number target slot frame = FrameSlotId (targetIdOf model number target) slot (frameUseNumber frame)
    -- A record is released when a presentation or a settlement owns it, or
    -- when the frame bound to it is released.
    bound = Set.fromList [(number, record) | (number, _, frame) ← leaving, Just record ← [framePoolRecord frame]]
    pools =
      [ (number, target, record, entry)
      | (number, target) ← Map.toList (gpuTargets model)
      , (record, entry) ← Map.toList (targetPool target)
      , poolState entry /= PoolReserved || (number, record) `Set.member` bound
      ]
    submissions = Map.toList (gpuSubmissions model)
    withoutSubmissions =
      foldl'
        ( \current (number, submission) →
            releaseObjects
              1
              ( foldl'
                  (\inner key → editHolds key (dischargeSubmitted number) inner)
                  current
                  (Set.toList (submissionSubjects submission))
              )
              { gpuSubmissions = Map.delete number (gpuSubmissions current)
              , gpuFramelessSlots = Map.filter (/= SlotSubmitted number) (gpuFramelessSlots current)
              }
        )
        model
        submissions
    withoutPools =
      foldl'
        ( \current (number, _, record, entry) →
            let discharged = case poolGeneration entry of
                  Nothing → current
                  Just generation → editHolds (GenerationKey number generation) (dischargePresentation record) current
             in editTarget
                  number
                  ( \target →
                      target
                        { targetPool = Map.delete record (targetPool target)
                        , -- The cycle this record identified can never complete,
                          -- and is dropped uncredited.
                          targetCycles = Map.delete record (targetCycles target)
                        }
                  )
                  (releaseObjects 1 discharged)
        )
        withoutSubmissions
        pools
    released =
      foldl'
        ( \current (number, slot, frame) →
            releaseObjects
              (reservedSubmission frame)
              (editTarget number (\target → target {targetFrames = Map.delete slot (targetFrames target)}) current)
        )
        withoutPools
        leaving
    report =
      DeviceLossRelease
        { releasedSubmissions = [SubmissionId (gpuSession model) number | (number, _) ← submissions]
        , releasedPresentations =
            [ PresentationId (targetIdOf model number target) record
            | (number, target, record, _) ← pools
            ]
        , releasedFrames =
            [ identityOf number target slot frame
            | (number, target, slot, frame) ← frames
            , releasing (framePhase frame)
            ]
        , releaseRemaining = remaining
        }
