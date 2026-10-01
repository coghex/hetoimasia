-- | The allocation protocol (GRS-11, D-40): how a buffer's memory is made from
-- the device's allocator beneath the model's accounting, and how it is freed.
--
-- = Making
--
-- For an allocation attempt the caller holds ('allocateBuffer'):
--
-- 1. The buffer's memory requirements are asked of the device, and the engine
--    chooses the one memory type ('chooseMemoryType'). A usage no allowed type
--    serves is refused, naming it, before any allocation.
-- 2. The buffer is created in held memory only ('InHeldMemory'). That opens
--    nothing and charges nothing new; an out-of-memory answer is the expected
--    miss, not a failure, and spends no recovery.
-- 3. On a miss, the attempt reserves the most the allocating call could open
--    ('reservationBound'): the type's preferred block size or the requirements'
--    size, whichever is larger. A reservation the byte budget cannot hold is
--    backpressure, answered before the call that could open memory.
-- 4. The allocating call ('MayOpenMemory'). Its effect is settled at once —
--    the reservation replaced by what it opened, what it freed released —
--    whether it succeeded or not. A failure is raised as the call raised it,
--    so an out-of-memory result reaches the caller's VK-14 recovery with its
--    reservation already returned; a retry reserves again against the
--    reconciled accounting.
-- 5. More opened than was reserved is an accounting defect: the buffer is
--    destroyed and its allocation freed, that effect settled too, and
--    'AllocatorAccountingDefect' raised. If the memory still held leaves the
--    accounted bytes above the budget, the session fails, with nothing else
--    freed.
-- 6. A host-visible allocation is mapped for its lifetime. A map that failed
--    destroys what was made, settling that effect, and is raised.
--
-- Every allocation made is counted with the roots ('noteRootsAllocation'),
-- which refuse to destroy the allocator while any remain.
--
-- = Freeing
--
-- 'freeBuffer' unmaps a mapped allocation, destroys the buffer and frees its
-- allocation — the resource before its memory — and settles what that freed.
-- It is only ever reached through a disposal the model allowed, after
-- completion evidence ended every submitted use: the allocator tracks no GPU
-- use and is never relied on to.
--
-- Every call is made on the graphics owner's thread through 'rootsCall', so a
-- device loss it raises is latched. This module owns no state.
module Hetoimasia.GPU.Vulkan.Native.Internal.Allocation
  ( AllocatedBuffer (..)
  , AllocationRefusal (..)
  , allocateBuffer
  , freeBuffer
  , flushBuffer
  , invalidateBuffer
  , nameBuffer
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.Exception (SomeException, onException, throwIO)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Numeric.Natural (Natural)

import Hetoimasia.GPU.Model
  ( MemoryEffect (..)
  , MemorySettlement (..)
  , Outcome (..)
  , SessionFailureCause (CleanupFailed)
  , Usage (..)
  , modelBudgets
  , reserveDeviceMemory
  , settleDeviceMemory
  , usage
  )
import Hetoimasia.GPU.Model.Budget (BudgetKind, byteLimit)
import Hetoimasia.GPU.Model.Identity (AllocationId)
import Hetoimasia.GPU.Vulkan.Native.Allocator
  ( AllocatorAccountingDefect (..)
  , AllocatorOps (..)
  , BufferMemory (..)
  , BufferRequest (..)
  , MemoryEvents (..)
  , MemoryProperty (..)
  , noMemoryEvents
  , MemoryRequirements (..)
  , MemoryTypeOffer (..)
  , MemoryTypeRefused
  , MemoryUsage
  , Placement (..)
  , chooseMemoryType
  , reservationBound
  )
import Hetoimasia.GPU.Vulkan.Native.Roots
  ( NativeFailure (FailedOutOfMemory)
  , Roots
  , failRootsSessionBecause
  , noteRootsAllocation
  , readRootsAllocator
  , rootsCall
  , rootsNativeFailure
  , stateRootsModel
  )

-- | A buffer's memory, made: the buffer and its allocation, whether its
-- memory is host-coherent, and where it is mapped, if it is host-visible.
data AllocatedBuffer = AllocatedBuffer
  { allocatedMemory ∷ !BufferMemory
  , allocatedCoherent ∷ !Bool
  , allocatedMapped ∷ !(Maybe Word64)
  }
  deriving (Eq, Show)

-- | Why no memory was made, having made nothing and charged nothing.
data AllocationRefusal
  = AllocationNoAllocator
    -- ^ The device, or its allocator, does not exist.
  | AllocationNoMemoryType !MemoryTypeRefused
    -- ^ No memory type the buffer allows serves its usage.
  | AllocationBackpressure !BudgetKind
    -- ^ The byte budget cannot hold what the allocating call could open.
  deriving (Eq, Show)

-- | Make a buffer's memory for the attempt, in the memory type the usage
-- chooses, by the protocol above.
allocateBuffer
  ∷ Roots q inst msgr phys dev
  → AllocationId
  → MemoryUsage
  → BufferRequest
  → IO (Either AllocationRefusal AllocatedBuffer)
allocateBuffer roots attempt kind request =
  atomically (readRootsAllocator roots) >>= \case
    Nothing → pure (Left AllocationNoAllocator)
    Just ops → do
      needs ← rootsCall roots "vkGetDeviceBufferMemoryRequirements" (allocatorBufferRequirements ops request)
      case chooseMemoryType kind (requirementTypes needs) (allocatorMemoryTypes ops) of
        Left refused → pure (Left (AllocationNoMemoryType refused))
        Right offer → do
          let index = offerTypeIndex offer
          (heldEvents, held) ← rootsCall roots "vmaCreateBuffer" (allocatorCreateBuffer ops request index InHeldMemory)
          settled ← settle roots Nothing heldEvents
          case (held, settled) of
            -- A placement in held memory opens nothing; one that did is the
            -- same defect as opening more than was reserved.
            (Right memory, MemoryBeyondReservation _) → defect roots ops memory "vmaCreateBuffer in held memory" 0 (eventsOpenedBytes heldEvents)
            (Left _, MemoryBeyondReservation _) → do
              overBudget roots "vmaCreateBuffer in held memory" 0 (eventsOpenedBytes heldEvents)
              throwIO (AllocatorAccountingDefect "vmaCreateBuffer in held memory" 0 (eventsOpenedBytes heldEvents))
            (Right memory, _) → Right <$> finish ops offer memory
            (Left failure, _)
              | rootsNativeFailure roots failure == Just FailedOutOfMemory → do
                  let bound = reservationBound offer (requirementSize needs)
                  reserved ← atomically $ stateRootsModel roots $ \model → case reserveDeviceMemory attempt bound model of
                    Admitted next → (Right (), next)
                    Backpressure budget → (Left budget, model)
                    Rejected _ → (Right (), model)
                  case reserved of
                    Left budget → pure (Left (AllocationBackpressure budget))
                    Right () → do
                      (events, made) ←
                        rootsCall roots "vmaCreateBuffer" (allocatorCreateBuffer ops request index MayOpenMemory)
                          `onException` atomically (settleWith roots (Just attempt) noMemoryEvents)
                      settlement ← settle roots (Just attempt) events
                      case (made, settlement) of
                        (Right memory, MemoryBeyondReservation _) → defect roots ops memory "vmaCreateBuffer" bound (eventsOpenedBytes events)
                        (Left _, MemoryBeyondReservation _) → do
                          overBudget roots "vmaCreateBuffer" bound (eventsOpenedBytes events)
                          throwIO (AllocatorAccountingDefect "vmaCreateBuffer" bound (eventsOpenedBytes events))
                        (Right memory, _) → Right <$> finish ops offer memory
                        (Left raised, _) → raise roots "vmaCreateBuffer" raised
              | otherwise → raise roots "vmaCreateBuffer" failure
  where
    -- Map what is host-visible, count the allocation, and answer it. A map
    -- that failed destroys what was made, settling that, and is raised.
    finish ops offer memory = do
      let visible = HostVisible `elem` offerProperties offer
          coherent = HostCoherent `elem` offerProperties offer
      mapped ←
        if visible
          then
            Just
              <$> rootsCall roots "vmaMapMemory" (allocatorMap ops memory)
                `onException` destroyMade roots ops memory
          else pure Nothing
      atomically (noteRootsAllocation roots True)
      pure (AllocatedBuffer memory coherent mapped)

-- | Unmap, destroy the buffer, then free its allocation, settling what that
-- freed and counting the allocation gone. A call that raised has an unknown
-- effect; the caller retains what it concerns.
freeBuffer ∷ Roots q inst msgr phys dev → AllocatedBuffer → IO ()
freeBuffer roots allocated =
  atomically (readRootsAllocator roots) >>= \case
    Nothing → throwIO (userError "the device's allocator is gone while an allocation made from it remains")
    Just ops → do
      let memory = allocatedMemory allocated
      for' (allocatedMapped allocated) $ \_ → rootsCall roots "vmaUnmapMemory" (allocatorUnmap ops memory)
      events ← rootsCall roots "vmaDestroyBuffer" (allocatorDestroyBuffer ops memory)
      settled ← settle roots Nothing events
      atomically (noteRootsAllocation roots False)
      case settled of
        MemoryBeyondReservation opened → overBudget roots "vmaDestroyBuffer" 0 opened
        _ → pure ()
  where
    for' value action = maybe (pure ()) action value

-- | Flush a range of a buffer's allocation, relative to its start, after host
-- writes to non-coherent memory.
flushBuffer ∷ Roots q inst msgr phys dev → AllocatedBuffer → (Natural, Natural) → IO ()
flushBuffer roots allocated range = withAllocator roots $ \ops →
  rootsCall roots "vmaFlushAllocation" (allocatorFlush ops (allocatedMemory allocated) range)

-- | Invalidate such a range before host reads of non-coherent memory.
invalidateBuffer ∷ Roots q inst msgr phys dev → AllocatedBuffer → (Natural, Natural) → IO ()
invalidateBuffer roots allocated range = withAllocator roots $ \ops →
  rootsCall roots "vmaInvalidateAllocation" (allocatorInvalidate ops (allocatedMemory allocated) range)

-- | Name a buffer's allocation inside the allocator.
nameBuffer ∷ Roots q inst msgr phys dev → AllocatedBuffer → ByteString → IO ()
nameBuffer roots allocated name = withAllocator roots $ \ops →
  rootsCall roots "vmaSetAllocationName" (allocatorName ops (allocatedMemory allocated) name)

withAllocator ∷ Roots q inst msgr phys dev → (AllocatorOps → IO ()) → IO ()
withAllocator roots use =
  atomically (readRootsAllocator roots) >>= \case
    Nothing → throwIO (userError "the device's allocator is gone while an allocation made from it remains")
    Just ops → use ops

-- | Settle one call's events into the model, answering what settling found.
settle ∷ Roots q inst msgr phys dev → Maybe AllocationId → MemoryEvents → IO MemorySettlement
settle roots attempt events = atomically (settleWith roots attempt events)

settleWith ∷ Roots q inst msgr phys dev → Maybe AllocationId → MemoryEvents → STM MemorySettlement
settleWith roots attempt events =
  stateRootsModel roots $ \model → case settleDeviceMemory attempt (MemoryEffect (eventsOpenedBytes events) (eventsFreedBytes events)) model of
    Admitted (next, settlement) → (settlement, next)
    _ → (MemorySettled, model)

-- | Destroy what a creation made before it is returned, settling what that
-- freed. Used on the paths that raise afterwards, so a destruction that
-- raised too is left to propagate in its place.
destroyMade ∷ Roots q inst msgr phys dev → AllocatorOps → BufferMemory → IO ()
destroyMade roots ops memory = do
  events ← rootsCall roots "vmaDestroyBuffer" (allocatorDestroyBuffer ops memory)
  _ ← settle roots Nothing events
  pure ()

-- | An allocating call opened more than was reserved: destroy what it made,
-- free its allocation, settle that, and raise the defect.
defect ∷ Roots q inst msgr phys dev → AllocatorOps → BufferMemory → Text → Natural → Natural → IO a
defect roots ops memory operation reserved opened = do
  destroyMade roots ops memory
  overBudget roots operation reserved opened
  throwIO (AllocatorAccountingDefect operation reserved opened)

-- | Fail the session if the device memory still held — after a defect's
-- rollback, which the allocator may have kept as an empty block — leaves the
-- accounted bytes above the budget: admission cannot resume over unaccounted
-- memory. Nothing else is freed for it.
overBudget ∷ Roots q inst msgr phys dev → Text → Natural → Natural → IO ()
overBudget roots operation reserved opened =
  atomically $ do
    over ← stateRootsModel roots $ \model → (usageBytes (usage model) > byteLimit (modelBudgets model), model)
    when over $
      failRootsSessionBecause roots CleanupFailed $
        operation
          <> " opened "
          <> Text.pack (show opened)
          <> " bytes of device memory where "
          <> Text.pack (show reserved)
          <> " were reserved, and what it left held exceeds the byte budget"

-- | Raise an allocator call's failure through the roots, so a device loss is
-- latched as any other call's is.
raise ∷ Roots q inst msgr phys dev → Text → SomeException → IO a
raise roots operation failure = rootsCall roots operation (throwIO failure)
