-- | Recorded batches: recording against an acquired frame, extending a batch's
-- references, discarding one, and resetting a frame's recorder.
--
-- This module owns the recorded-reference hold and the rule that a subject
-- whose logical release or ended CPU use has been certified gains no new
-- recorded reference. Submitting a frame's batches is
-- "Hetoimasia.GPU.Model.Internal.Submission".
module Hetoimasia.GPU.Model.Internal.Recording
  ( recordBatch
  , extendBatch
  , discardBatch
  , dropBatch
  , resetRecorder
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Hetoimasia.GPU.Model.Internal.Accounting (chargeObjects, editFrame, editHolds, holdsOf, releaseObjects)
import Hetoimasia.GPU.Model.Internal.Hold (Holds (cpuUseEnded, logicalReleased), dischargeRecorded, retainRecorded)
import Hetoimasia.GPU.Model.Internal.Identity
import Hetoimasia.GPU.Model.Internal.Records
import Hetoimasia.GPU.Model.Internal.Resolve (resolveBatch, resolveFrame, resolveResource)
import Hetoimasia.GPU.Model.Internal.Scheduling (scheduling, scheduling_)
import Hetoimasia.GPU.Model.Internal.State
import Numeric.Natural (Natural)

-- | Record a batch against an acquired frame. The batch retains exactly the
-- resource generations it names and the swapchain generation it renders into.
recordBatch ∷ FrameSlotId → [ResourceId] → GpuModel → Outcome (GpuModel, BatchId)
recordBatch identity references model =
  scheduling model $
  resolved (running model) $ \() →
    resolved (resolveFrame model identity) $ \(number, slot, frame) →
      if framePhase frame /= FrameAcquired
        then Rejected (WrongPhase FrameIdentity)
        else resolved (traverse (resolveResource model) references) $ \resolvedResources →
          let keys = map (uncurry ResourceKey . fst) resolvedResources
           in if length (Set.toList (Set.fromList keys)) /= length keys
                then Rejected (DuplicateSubject ResourceIdentity)
                else
                  -- A subject whose logical release or ended CPU use has been
                  -- certified may not gain a new recorded reference: the owner
                  -- has already said that nothing can still record it, and a
                  -- batch admitted afterwards would make that certification
                  -- false. Batches already recorded are untouched, and this is
                  -- decided before anything is charged or written.
                  if any (sealed model) (map (uncurry ResourceKey . fst) resolvedResources)
                    then Rejected (WrongPhase ResourceIdentity)
                    else
                      if any (sealed model) [GenerationKey number generation | Just generation ← [frameGeneration frame]]
                        then Rejected (WrongPhase GenerationIdentity)
                        else case chargeObjects 1 model of
                  Left kind → Backpressure kind
                  Right charged →
                    let batch = gpuNextBatch charged
                        generationKeys =
                          [GenerationKey number generation | Just generation ← [frameGeneration frame]]
                        subjects = Set.fromList (keys ++ generationKeys)
                        retained = foldl' (\current key → editHolds key (retainRecorded batch) current) charged (Set.toList subjects)
                     in Admitted
                          ( editFrame
                              number
                              slot
                              (\entry → entry {frameBatches = Set.insert batch (frameBatches entry)})
                              retained
                                { gpuBatches =
                                    Map.insert
                                      batch
                                      Batch
                                        { batchTargetNumber = number
                                        , batchSlot = slot
                                        , batchSubjects = subjects
                                        }
                                      (gpuBatches retained)
                                , gpuNextBatch = batch + 1
                                }
                          , BatchId (frameTarget identity) batch
                          )

-- | Extend a recorded batch's references before the next command that names
-- them is recorded into it. The batch keeps its one identity; each subject is
-- retained once however many commands use it, so naming a subject the batch
-- already holds is ordinary repeated use and changes nothing. A request that
-- names one subject twice is misuse, and so is any subject whose logical
-- release or ended CPU use has been certified, whether or not the batch
-- already holds it: nothing may record through it again. Nothing is charged:
-- the batch's one record was reserved when it was recorded, and a reference is
-- an entry in a subject's hold, not a record of its own.
extendBatch ∷ BatchId → [ResourceId] → GpuModel → Outcome GpuModel
extendBatch identity references model =
  scheduling_ model $
  resolved (running model) $ \() →
    resolved (resolveBatch model identity) $ \(number, batch) →
      resolved (traverse (resolveResource model) references) $ \resolvedResources →
        let keys = map (uncurry ResourceKey . fst) resolvedResources
            unique = Set.fromList keys
         in if Set.size unique /= length keys
              then Rejected (DuplicateSubject ResourceIdentity)
              else
                if any (sealed model) keys
                  then Rejected (WrongPhase ResourceIdentity)
                  else
                    let added = Set.difference unique (batchSubjects batch)
                        retained = foldl' (\current key → editHolds key (retainRecorded number) current) model (Set.toList added)
                     in Admitted
                          retained
                            { gpuBatches =
                                Map.insert number batch {batchSubjects = Set.union (batchSubjects batch) added} (gpuBatches retained)
                            }

-- | Whether a subject has been certified as recordable no longer: either the
-- owner released it, or it certified that no retained capability can reach it.
sealed ∷ GpuModel → SubjectKey → Bool
sealed model key = case holdsOf model key of
  Nothing → True
  Just holds → logicalReleased holds || cpuUseEnded holds

-- | Discard one recorded batch. It discharges exactly its own references.
discardBatch ∷ BatchId → GpuModel → Outcome GpuModel
discardBatch identity model =
  scheduling_ model $
  resolved (resolveBatch model identity) $ \(number, batch) →
    Admitted (dropBatch number batch model)

dropBatch ∷ Natural → Batch → GpuModel → GpuModel
dropBatch number batch model =
  releaseObjects 1 $
    editFrame
      (batchTargetNumber batch)
      (batchSlot batch)
      (\entry → entry {frameBatches = Set.delete number (frameBatches entry)})
      (foldl' (\current key → editHolds key (dischargeRecorded number) current) model (Set.toList (batchSubjects batch)))
        {gpuBatches = Map.delete number (gpuBatches model)}

-- | Reset a frame's recorder: every one of its unsubmitted batches is
-- discarded, and nothing else is.
resetRecorder ∷ FrameSlotId → GpuModel → Outcome GpuModel
resetRecorder identity model =
  scheduling_ model $
  resolved (resolveFrame model identity) $ \(_, _, frame) →
    Admitted (foldl' discard model (Set.toList (frameBatches frame)))
  where
    discard current number = case Map.lookup number (gpuBatches current) of
      Nothing → current
      Just batch → dropBatch number batch current
