-- | Target lifecycle: admission, suspension and resumption, render demand, and
-- close.
--
-- This module owns a target's phase and render demand, and the reuse of a
-- target number under a fresh incarnation. What a target holds — generations,
-- frames and recovery accounting — changes through the modules named for those
-- responsibilities.
module Hetoimasia.GPU.Model.Internal.Targets
  ( admitTarget
  , suspendTarget
  , resumeTarget
  , requestRender
  , closeTarget
  ) where

import qualified Data.Map.Strict as Map
import Hetoimasia.GPU.Model.Internal.Accounting (editTarget)
import Hetoimasia.GPU.Model.Internal.Budget (BudgetKind (TargetRecordBudget), targetRecordLimit)
import Hetoimasia.GPU.Model.Internal.Identity
import Hetoimasia.GPU.Model.Internal.Records
import Hetoimasia.GPU.Model.Internal.Recovery (freshEpisode)
import Hetoimasia.GPU.Model.Internal.Resolve (resolveTarget)
import Hetoimasia.GPU.Model.Internal.Scheduling (observing_, scheduling, scheduling_)
import Hetoimasia.GPU.Model.Internal.State
import Numeric.Natural (Natural)

-- | Admit a target. Retiring targets still occupy a record, so the limit binds
-- on everything the model still tracks rather than on what is currently
-- rendering. A target number is reused once its record is forgotten, and the
-- reuse carries a fresh incarnation, so an identity for the earlier target is
-- stale rather than a handle on its successor.
admitTarget ∷ TargetClass → GpuModel → Outcome (GpuModel, TargetId)
admitTarget classification model =
  scheduling model $
  resolved (running model) $ \() →
    if fromIntegral (Map.size (gpuTargets model)) >= targetRecordLimit (gpuBudgets model)
      then Backpressure TargetRecordBudget
      else
        let number = freeTargetNumber model
            incarnation = maybe 1 (+ 1) (Map.lookup number (gpuIncarnations model))
            target =
              Target
                { targetIncarnationNumber = incarnation
                , targetClassOf = classification
                , targetPhase = TargetAdmitted
                , targetGenerations = Map.empty
                , targetNextGeneration = 0
                , targetActiveGeneration = Nothing
                , targetFrames = Map.empty
                , targetSlotUse = Map.empty
                , targetPool = Map.empty
                , targetRecovery = freshEpisode
                , targetRecoveryEpoch = 0
                , targetCycles = Map.empty
                , targetReplacementRequested = 0
                , targetReplacementServed = 0
                , targetRenderDemand = False
                , targetSuboptimalSeen = False
                }
         in Admitted
              ( model
                  { gpuTargets = Map.insert number target (gpuTargets model)
                  , gpuIncarnations = Map.insert number incarnation (gpuIncarnations model)
                  , gpuNextTarget = max (gpuNextTarget model) (number + 1)
                  }
              , TargetId (gpuSession model) number incarnation
              )

freeTargetNumber ∷ GpuModel → Natural
freeTargetNumber model = search 0
  where
    search candidate
      | Map.member candidate (gpuTargets model) = search (candidate + 1)
      | otherwise = candidate

-- | Suspend a target: it keeps every obligation and its retirement demand, and
-- stops contributing a render deadline.
suspendTarget ∷ TargetId → GpuModel → Outcome GpuModel
suspendTarget identity model =
  scheduling_ model $
  resolved (running model) $ \() →
    resolved (resolveTarget model identity) $ \(number, target) →
      case targetPhase target of
        TargetAdmitted →
          Admitted (editTarget number (\record → record {targetPhase = TargetSuspended}) model)
        TargetSuspended → Admitted model
        _ → Rejected (WrongPhase TargetIdentity)

resumeTarget ∷ TargetId → GpuModel → Outcome GpuModel
resumeTarget identity model =
  scheduling_ model $
  resolved (running model) $ \() →
    resolved (resolveTarget model identity) $ \(number, target) →
      case targetPhase target of
        TargetSuspended →
          Admitted
            ( editTarget number (\record → record {targetPhase = TargetAdmitted}) model
            )
        TargetAdmitted → Admitted model
        _ → Rejected (WrongPhase TargetIdentity)

-- | New render demand. It schedules an immediate progress opportunity and
-- restarts the idle backoff.
requestRender ∷ TargetId → GpuModel → Outcome GpuModel
requestRender identity model =
  scheduling_ model $
  resolved (running model) $ \() →
    resolved (resolveTarget model identity) $ \(number, target) →
      case targetPhase target of
        TargetRetiring → Rejected (WrongPhase TargetIdentity)
        TargetUnavailable → Rejected (WrongPhase TargetIdentity)
        _ →
          Admitted
            ( editTarget number (\record → record {targetRenderDemand = True}) model
            )

-- | Close a target. Close wins: it drops render demand, and from here no
-- construction may be published back into active rendering.
closeTarget ∷ TargetId → GpuModel → Outcome GpuModel
closeTarget identity model =
  resolved (resolveTarget model identity) $ \(number, target) →
    -- Requirement 7 resets the schedule for a close /transition/, not for a
    -- close /call/. A target that is already retiring transitions nowhere, so a
    -- repeated close notification must leave the schedule of the cleanup the
    -- first one started exactly where it is; otherwise repeating it is enough to
    -- defeat the backoff for ever.
    if targetPhase target == TargetRetiring
      then Admitted model
      else
        observing_ model $
          Admitted
            ( editTarget
                number
                (\record → record {targetPhase = TargetRetiring, targetRenderDemand = False})
                model
            )
