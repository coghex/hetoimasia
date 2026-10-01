-- | Managed resources and the allocation attempts they are made from.
--
-- This module owns an attempt's reserved byte and object accounting from
-- before its native call, its single retry, and its conversion into a managed
-- resource generation; and a resource's generations, logical release and end
-- of CPU use. A released generation is disposed of only through
-- "Hetoimasia.GPU.Model.Internal.Disposal", whose reclamation pass is also what credits a
-- failed attempt's retry.
module Hetoimasia.GPU.Model.Internal.Resources
  ( -- * Managed resources
    createResource
  , rebuildResource
  , releaseResource
  , endResourceCpuUse

    -- * Allocation attempts
  , beginAllocation
  , recordAllocationFailure
  , noteOldSwapchainRetired
  , retryAllocation
  , abandonAllocation
  ) where

import qualified Data.Map.Strict as Map
import Hetoimasia.GPU.Model.Internal.Accounting (chargeObjects, editHolds, releaseBytes, releaseObjects)
import Hetoimasia.GPU.Model.Internal.Budget (BudgetKind (ByteBudget), byteLimit)
import Hetoimasia.GPU.Model.Internal.Hold (Holds (logicalReleased), endCpuUse, newHolds, releaseLogically)
import Hetoimasia.GPU.Model.Internal.Identity
import Hetoimasia.GPU.Model.Internal.Records
import Hetoimasia.GPU.Model.Internal.Recovery
  ( AllocationAttempt
      ( attemptBytes
      , attemptFailed
      , attemptMemoryReserved
      , attemptObjects
      , attemptReclaimedSince
      , attemptRetiredOldSwapchain
      , attemptRetrySpent
      )
  , RetryVerdict (RetryPermitted)
  , judgeRetry
  , newAllocationAttempt
  )
import Hetoimasia.GPU.Model.Internal.Resolve (resolveAllocation, resolveGeneration, resolveResource)
import Hetoimasia.GPU.Model.Internal.Scheduling (scheduling, scheduling_)
import Hetoimasia.GPU.Model.Internal.State
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Managed resources

-- | Turn a successful allocation attempt into a managed resource generation.
-- An attempt whose device-memory reservation is still unsettled is refused:
-- its memory is not the resource's to keep.
createResource ∷ AllocationId → GpuModel → Outcome (GpuModel, ResourceId)
createResource identity model =
  scheduling model $
  resolved (running model) $ \() →
    resolved (resolveAllocation model identity) $ \(number, attempt) →
      if attemptFailed attempt || attemptMemoryReserved attempt /= 0
        then Rejected (WrongPhase AllocationIdentity)
        else
          let logical = gpuNextResource model
              record =
                Resource
                  { resourceHolds = newHolds
                  , resourceBytes = attemptBytes attempt
                  , resourceObjects = attemptObjects attempt
                  }
           in Admitted
                ( model
                    { gpuResources = Map.insert (logical, 1) record (gpuResources model)
                    , gpuResourceGenerations = Map.insert logical 1 (gpuResourceGenerations model)
                    , gpuNextResource = logical + 1
                    , gpuAllocations = Map.delete number (gpuAllocations model)
                    }
                , ResourceId (gpuSession model) logical 1
                )

-- | Rebuild a resource under a new generation. The previous generation is
-- released logically and keeps every hold it had, so a batch that recorded it
-- still names exactly the contents it recorded.
rebuildResource ∷ ResourceId → AllocationId → GpuModel → Outcome (GpuModel, ResourceId)
rebuildResource identity allocation model =
  scheduling model $
  resolved (running model) $ \() →
    resolved (resolveResource model identity) $ \((logical, generation), existing) →
      resolved (resolveAllocation model allocation) $ \(number, attempt) →
        -- Only the resource's current generation may be rebuilt, and the
        -- successor is derived from the resource's own counter rather than from
        -- the identity handed in. Rebuilding through a retained older identity
        -- would otherwise reissue a number that is already live, overwriting one
        -- replacement with another and leaking the accounting of the first.
        if Map.lookup logical (gpuResourceGenerations model) /= Just generation
          then Rejected (StaleIdentity ResourceIdentity)
          else
            if logicalReleased (resourceHolds existing)
              then Rejected (AlreadyConsumed ResourceIdentity)
              else
                if attemptFailed attempt || attemptMemoryReserved attempt /= 0
                  then Rejected (WrongPhase AllocationIdentity)
                  else
                    let next = generation + 1
                        built =
                          Resource
                            { resourceHolds = newHolds
                            , resourceBytes = attemptBytes attempt
                            , resourceObjects = attemptObjects attempt
                            }
                        released = editHolds (ResourceKey logical generation) releaseLogically model
                     in Admitted
                          ( released
                              { gpuResources = Map.insert (logical, next) built (gpuResources released)
                              , gpuResourceGenerations = Map.insert logical next (gpuResourceGenerations released)
                              , gpuAllocations = Map.delete number (gpuAllocations released)
                              }
                          , ResourceId (gpuSession model) logical next
                          )

releaseResource ∷ ResourceId → GpuModel → Outcome GpuModel
releaseResource identity model =
  scheduling_ model $
  resolved (resolveResource model identity) $ \(key, _) →
    Admitted (editHolds (uncurry ResourceKey key) releaseLogically model)

endResourceCpuUse ∷ ResourceId → GpuModel → Outcome GpuModel
endResourceCpuUse identity model =
  scheduling_ model $
  resolved (resolveResource model identity) $ \(key, _) →
    Admitted (editHolds (uncurry ResourceKey key) endCpuUse model)

-- ---------------------------------------------------------------------------
-- Allocation attempts

-- | Reserve accounting for one native allocation attempt. Reserving before the
-- call is what makes the byte and object budgets bounds on what the backend can
-- own rather than a report of what it already owns.
beginAllocation ∷ Natural → Natural → GpuModel → Outcome (GpuModel, AllocationId)
beginAllocation bytes objects model =
  scheduling model $
  resolved (running model) $ \() →
    -- An attempt that reserves neither bytes nor objects would be a record
    -- costing nothing and therefore bounding nothing, which is the one way
    -- attempts could accumulate without limit.
    if bytes == 0 && objects == 0
      then Rejected EmptyAllocation
      else admit
  where
    admit
      | gpuBytes model + bytes > byteLimit (gpuBudgets model)
      =
          Backpressure ByteBudget
      | otherwise = case chargeObjects objects model of
          Left kind → Backpressure kind
          Right charged →
            let number = gpuNextAllocation charged
             in Admitted
                  ( charged
                      { gpuBytes = gpuBytes charged + bytes
                      , gpuAllocations = Map.insert number (newAllocationAttempt bytes objects) (gpuAllocations charged)
                      , gpuNextAllocation = number + 1
                      }
                  , AllocationId (gpuSession charged) number
                  )

recordAllocationFailure ∷ AllocationId → GpuModel → Outcome GpuModel
recordAllocationFailure identity model =
  scheduling_ model $
  resolved (resolveAllocation model identity) $ \(number, attempt) →
    if attemptFailed attempt
      then Rejected (AlreadyConsumed AllocationIdentity)
      else
        Admitted
          model
            { gpuAllocations =
                Map.insert number attempt {attemptFailed = True, attemptReclaimedSince = False} (gpuAllocations model)
            }

-- | Record that this attempt's construction already passed a generation as
-- @oldSwapchain@. That retirement is irreversible, so the attempt may not later
-- replay its creation arguments.
noteOldSwapchainRetired ∷ AllocationId → GenerationId → GpuModel → Outcome GpuModel
noteOldSwapchainRetired identity generation model =
  scheduling_ model $
  resolved (resolveAllocation model identity) $ \(number, attempt) →
    resolved (resolveGeneration model generation) $ \(_, _, record) →
      if not (generationOldSwapchain record)
        then Rejected (WrongPhase GenerationIdentity)
        else
          Admitted
            model {gpuAllocations = Map.insert number attempt {attemptRetiredOldSwapchain = True} (gpuAllocations model)}

-- | Whether this attempt may retry, spending its one retry bit if it may.
retryAllocation ∷ AllocationId → GpuModel → Outcome (GpuModel, RetryVerdict)
retryAllocation identity model =
  scheduling model $
  -- A retry is an admission of new native work, so a terminal session refuses
  -- it. Permitting one would invite a native construction whose successful
  -- result 'createResource' then refuses, leaving the boundary holding something
  -- the model has no record of.
  resolved (running model) $ \() →
    resolved (resolveAllocation model identity) $ \(number, attempt) →
      case judgeRetry attempt of
        RetryPermitted →
          Admitted
            ( model
                { gpuAllocations =
                    Map.insert
                      number
                      attempt {attemptRetrySpent = True, attemptFailed = False, attemptReclaimedSince = False}
                      (gpuAllocations model)
                }
            , RetryPermitted
            )
        verdict → Admitted (model, verdict)

-- | Give up an attempt and release the accounting it reserved, including a
-- device-memory reservation it never settled. Device memory an allocator call
-- already opened under it stays charged: it is held until it is freed.
abandonAllocation ∷ AllocationId → GpuModel → Outcome GpuModel
abandonAllocation identity model =
  scheduling_ model $
  resolved (resolveAllocation model identity) $ \(number, attempt) →
    Admitted
      ( releaseBytes
          (attemptBytes attempt + attemptMemoryReserved attempt)
          (releaseObjects (attemptObjects attempt) model {gpuAllocations = Map.delete number (gpuAllocations model)})
      )
