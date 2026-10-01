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
--    nothing and charges nothing new; 'NotPlaced' — nothing held fits, or the
--    driver requires a dedicated allocation — is the expected miss, not a
--    failure, and spends no recovery.
-- 3. On a miss, the attempt reserves the most the allocating call could open
--    ('reservationBound'): the type's preferred block size or the requirements'
--    size, whichever is larger. A reservation the byte budget cannot hold is
--    backpressure, and one the model rejects is refused with its misuse, each
--    answered before the call that could open memory, which is then never
--    made.
-- 4. The allocating call ('MayOpenMemory'). Its effect is settled at once —
--    the reservation replaced by what it opened, what it freed released —
--    whether it succeeded or not. A failure is raised as the call raised it,
--    so an out-of-memory result reaches the caller's VK-14 recovery with its
--    reservation already returned; a retry reserves again against the
--    reconciled accounting.
-- 5. Any effect that disagrees with the accounting is a defect
--    ('AccountingFinding'): more opened than was reserved, more freed than was
--    held, or an effect the model refused to settle under the attempt. The
--    buffer is destroyed and its allocation freed, that effect settled too,
--    and 'AllocatorAccountingDefect' raised. The session fails, with nothing
--    else freed, unless the defect is memory opened beyond a reservation that
--    the budget still holds.
-- 6. A host-visible allocation is mapped for its lifetime. A map that failed
--    destroys what was made, settling that effect, and is raised.
--
-- Every allocation made is counted with the roots ('noteRootsAllocation'),
-- which refuse to destroy the allocator while any remain.
--
-- = Freeing
--
-- 'freeBuffer' unmaps a mapped allocation, destroys the buffer and frees its
-- allocation — the resource before its memory — and settles what that freed;
-- an effect that disagrees with the accounting fails the session, as at
-- creation, though the destruction itself returned.
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
import Control.Exception (Exception (displayException), SomeException, onException, throwIO)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.Foldable (for_, traverse_)
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
import Hetoimasia.GPU.Model.Identity (AllocationId, Misuse)
import Hetoimasia.GPU.Vulkan.Native.Allocator
  ( AccountingFinding (..)
  , AllocatorAccountingDefect (..)
  , AllocatorOps (..)
  , BufferMemory (..)
  , BufferRequest (..)
  , Creation (..)
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
  ( Roots
  , failRootsSessionBecause
  , noteRootsAllocation
  , readRootsAllocator
  , rootsCall
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
  | AllocationRejected !Misuse
    -- ^ The model would not reserve for the attempt — the session failed, or
    -- the attempt is no longer one that may allocate — so the call that could
    -- open memory was never made.
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
              heldCall = "vmaCreateBuffer in held memory"
          (heldEvents, held) ← rootsCall roots heldCall (allocatorCreateBuffer ops request index InHeldMemory)
          heldFinding ← atomically (settle roots Nothing 0 heldEvents)
          -- A placement in held memory opens nothing; one that did, or any
          -- effect the accounting cannot take, fails the request.
          for_ heldFinding (failRequest roots ops heldCall held)
          case held of
            Created memory → Right <$> finish ops offer memory
            CreationFailed failure → raise roots heldCall failure
            NotPlaced → do
              let bound = reservationBound offer (requirementSize needs)
              reserved ← atomically $ stateRootsModel roots $ \model → case reserveDeviceMemory attempt bound model of
                Admitted next → (Right (), next)
                Backpressure budget → (Left (AllocationBackpressure budget), model)
                Rejected misuse → (Left (AllocationRejected misuse), model)
              case reserved of
                Left refusal → pure (Left refusal)
                Right () → do
                  let call = "vmaCreateBuffer"
                  (events, made) ←
                    rootsCall roots call (allocatorCreateBuffer ops request index MayOpenMemory)
                      `onException` atomically (settle roots (Just attempt) bound noMemoryEvents)
                  finding ← atomically (settle roots (Just attempt) bound events)
                  for_ finding (failRequest roots ops call made)
                  case made of
                    Created memory → Right <$> finish ops offer memory
                    CreationFailed failure → raise roots call failure
                    NotPlaced → throwIO (userError "the allocator answered an allocating call as a placement miss")
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
-- effect; the caller retains what it concerns. The destruction itself
-- returned even when its effect disagrees with the accounting, so that
-- defect fails the session rather than the destruction.
freeBuffer ∷ Roots q inst msgr phys dev → AllocatedBuffer → IO ()
freeBuffer roots allocated =
  atomically (readRootsAllocator roots) >>= \case
    Nothing → throwIO (userError "the device's allocator is gone while an allocation made from it remains")
    Just ops → do
      let memory = allocatedMemory allocated
      for_ (allocatedMapped allocated) $ \_ → rootsCall roots "vmaUnmapMemory" (allocatorUnmap ops memory)
      events ← rootsCall roots "vmaDestroyBuffer" (allocatorDestroyBuffer ops memory)
      atomically $ do
        finding ← settle roots Nothing 0 events
        noteRootsAllocation roots False
        for_ finding (defectFails roots "vmaDestroyBuffer")

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

-- | Settle one call's events into the model, under the attempt's reservation
-- of this many bytes or under none, answering what disagreed, if anything.
-- An effect the model refuses to settle under the attempt is settled under no
-- reservation instead, so nothing held goes uncharged, and is a finding too.
settle ∷ Roots q inst msgr phys dev → Maybe AllocationId → Natural → MemoryEvents → STM (Maybe AccountingFinding)
settle roots attempt reserved events =
  stateRootsModel roots $ \model → case settleDeviceMemory attempt effect model of
    Admitted (next, settlement) → (judged settlement, next)
    refused →
      let why = Text.pack (show (fmap fst refused))
       in case settleDeviceMemory Nothing effect model of
            Admitted (next, _) → (Just (SettlementRefused why), next)
            _ → (Just (SettlementRefused why), model)
  where
    opened = eventsOpenedBytes events
    effect = MemoryEffect opened (eventsFreedBytes events)
    judged = \case
      MemorySettled → Nothing
      MemoryBeyondReservation _ → Just (OpenedBeyondReservation reserved opened)
      MemoryFreedUnheld excess → Just (FreedBeyondHeld excess)

-- | A request's call disagreed with the accounting: destroy what it made,
-- settling that, fail the session as the finding requires, and raise the
-- defect.
failRequest ∷ Roots q inst msgr phys dev → AllocatorOps → Text → Creation → AccountingFinding → IO a
failRequest roots ops operation made finding = do
  case made of
    Created memory → destroyMade roots ops memory
    _ → pure ()
  atomically (defectFails roots operation finding)
  throwIO (AllocatorAccountingDefect operation finding)

-- | Destroy what a creation made before it is returned, settling what that
-- freed. Used on the paths that raise afterwards, so a destruction that
-- raised too is left to propagate in its place.
destroyMade ∷ Roots q inst msgr phys dev → AllocatorOps → BufferMemory → IO ()
destroyMade roots ops memory = do
  events ← rootsCall roots "vmaDestroyBuffer" (allocatorDestroyBuffer ops memory)
  atomically (settle roots Nothing 0 events >>= traverse_ (defectFails roots "vmaDestroyBuffer"))

-- | Fail the session for an accounting defect, unless it is memory opened
-- beyond a reservation that the budget still holds: admission never resumes
-- over memory the accounting does not bound. Nothing else is freed for it.
defectFails ∷ Roots q inst msgr phys dev → Text → AccountingFinding → STM ()
defectFails roots operation finding = do
  over ← stateRootsModel roots $ \model → (usageBytes (usage model) > byteLimit (modelBudgets model), model)
  let fails = case finding of
        OpenedBeyondReservation _ _ → over
        _ → True
  when fails $
    failRootsSessionBecause roots CleanupFailed $
      Text.pack (displayException (AllocatorAccountingDefect operation finding))
        <> if over then "; what is held exceeds the byte budget" else ""

-- | Raise an allocator call's failure through the roots, so a device loss is
-- latched as any other call's is.
raise ∷ Roots q inst msgr phys dev → Text → SomeException → IO a
raise roots operation failure = rootsCall roots operation (throwIO failure)
