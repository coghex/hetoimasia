-- | Device-memory accounting (D-15, D-40): the bytes of device memory the
-- allocator holds — each block and each dedicated allocation — charged to the
-- model's accounted bytes for as long as it holds them, and the bounded
-- reservation an allocating call is admitted under.
--
-- These charges belong to the device memory, never to a resource: a block
-- serves many resources and outlives them, and the allocator may keep an empty
-- one. So disposing of or abandoning a resource releases none of them; only an
-- effect the boundary reports — memory opened or freed during one allocator
-- call — moves them.
--
-- The boundary reserves before an allocating call, from an allocation attempt
-- ('reserveDeviceMemory'), and settles every allocator call's effect after it
-- ('settleDeviceMemory'): the reservation is replaced by what the call opened,
-- the rest returned at once, and what it freed is released. Settlement is
-- never refused for a failed session, since it records what already happened.
module Hetoimasia.GPU.Model.Internal.Memory
  ( MemoryEffect (..)
  , noMemoryEffect
  , MemorySettlement (..)
  , reserveDeviceMemory
  , settleDeviceMemory
  ) where

import qualified Data.Map.Strict as Map
import Hetoimasia.GPU.Model.Internal.Accounting (saturatingMinus)
import Hetoimasia.GPU.Model.Internal.Budget (BudgetKind (ByteBudget), byteLimit)
import Hetoimasia.GPU.Model.Internal.Identity
import Hetoimasia.GPU.Model.Internal.Recovery (AllocationAttempt (attemptFailed, attemptMemoryReserved))
import Hetoimasia.GPU.Model.Internal.Resolve (resolveAllocation)
import Hetoimasia.GPU.Model.Internal.Scheduling (scheduling, scheduling_)
import Hetoimasia.GPU.Model.Internal.State
import Numeric.Natural (Natural)

-- | What one allocator call did to the device memory it holds: the bytes it
-- opened and the bytes it freed, over every block and dedicated allocation.
-- A call may do both, such as a creation whose bind failed after opening a
-- block it then freed.
data MemoryEffect = MemoryEffect
  { effectOpened ∷ !Natural
  , effectFreed ∷ !Natural
  }
  deriving (Eq, Show)

noMemoryEffect ∷ MemoryEffect
noMemoryEffect = MemoryEffect 0 0

-- | What settling an effect found. Anything but 'MemorySettled' is an
-- accounting defect the boundary must act on; the charges already say what
-- is held.
data MemorySettlement
  = MemorySettled
    -- ^ Everything opened was reserved, and everything freed was held.
  | MemoryBeyondReservation !Natural
    -- ^ The call opened this many bytes more than it had reserved. They are
    -- charged, because they are held, even past the byte budget; the boundary
    -- frees what the call made and treats the request as failed.
  | MemoryFreedUnheld !Natural
    -- ^ The call freed this many bytes more than the model held. The held
    -- charge stops at zero.
  deriving (Eq, Show)

-- | Reserve the most an allocating call could open for this attempt: the
-- boundary's bound, before the call. Exceeding the byte budget is
-- 'Backpressure' and changes nothing. An attempt holds at most one
-- reservation, which settlement or abandonment ends, and a failed attempt
-- reserves nothing until its retry is permitted.
reserveDeviceMemory ∷ AllocationId → Natural → GpuModel → Outcome GpuModel
reserveDeviceMemory identity bytes model =
  scheduling_ model $
    resolved (running model) $ \() →
      resolved (resolveAllocation model identity) $ \(number, attempt) →
        if bytes == 0
          then Rejected EmptyAllocation
          else
            if attemptFailed attempt || attemptMemoryReserved attempt /= 0
              then Rejected (WrongPhase AllocationIdentity)
              else
                if gpuBytes model + bytes > byteLimit (gpuBudgets model)
                  then Backpressure ByteBudget
                  else
                    Admitted
                      model
                        { gpuBytes = gpuBytes model + bytes
                        , gpuAllocations = Map.insert number attempt {attemptMemoryReserved = bytes} (gpuAllocations model)
                        }

-- | Settle one allocator call's effect, made under this attempt's reservation
-- or, given none, under no reservation at all: the reservation is released,
-- what the call opened is charged as held, and what it freed is released.
-- Nothing else is ever charged or released for device memory.
settleDeviceMemory ∷ Maybe AllocationId → MemoryEffect → GpuModel → Outcome (GpuModel, MemorySettlement)
settleDeviceMemory identity effect model =
  scheduling model $ case identity of
    Nothing → Admitted (settle 0 model)
    Just attempt →
      resolved (resolveAllocation model attempt) $ \(number, held) →
        Admitted
          ( settle
              (attemptMemoryReserved held)
              model {gpuAllocations = Map.insert number held {attemptMemoryReserved = 0} (gpuAllocations model)}
          )
  where
    opened = effectOpened effect
    freed = effectFreed effect
    settle reserved current =
      let before = gpuDeviceMemory current
          available = before + opened
          after = if freed > available then 0 else available - freed
          -- The reservation and the memory held before were both accounted
          -- bytes; they are replaced by what is held now.
          bytes = saturatingMinus (saturatingMinus (gpuBytes current) reserved) before + after
          settlement
            | opened > reserved = MemoryBeyondReservation (opened - reserved)
            | freed > available = MemoryFreedUnheld (freed - available)
            | otherwise = MemorySettled
       in (current {gpuBytes = bytes, gpuDeviceMemory = after}, settlement)
