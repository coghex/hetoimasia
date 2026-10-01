-- | The allocation protocol (GRS-11, D-40): how a buffer's or an image's
-- memory is made from the device's allocator beneath the model's accounting,
-- and how it is freed. A buffer and an image (GRS-2) follow it alike; they
-- differ only in the allocator's calls that make and destroy them, and in
-- that an image is never mapped.
--
-- = Making
--
-- For an allocation attempt the caller holds ('allocateBuffer',
-- 'allocateImage'):
--
-- 1. The resource's memory requirements are asked of the device, and the
--    engine chooses the one memory type ('chooseMemoryType'). A usage no
--    allowed type serves is refused, naming it, before any allocation.
-- 2. The resource is created in held memory only ('InHeldMemory'). That opens
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
--    resource is destroyed and its allocation freed, that effect settled too,
--    and 'AllocatorAccountingDefect' raised. The session fails, with nothing
--    else freed, unless the defect is memory opened beyond a reservation that
--    the budget still holds.
-- 6. A buffer's host-visible allocation is mapped for its lifetime. A map
--    that failed destroys what was made, settling that effect, and is raised.
--    An image's allocation is never mapped: it is optimally tiled, and the
--    host never writes it directly (D-16).
--
-- Every allocation made is counted with the roots ('noteRootsAllocation') the
-- moment the call that made it returns, and the roots refuse to destroy the
-- allocator while any remain. A request that destroys what it made, on a
-- failure, counts it gone only once that destruction returned; one that
-- raised leaves it counted, and fails the session with 'CleanupFailed'.
--
-- = Freeing
--
-- 'freeBuffer' unmaps a mapped allocation, destroys the buffer and frees its
-- allocation — the resource before its memory — and settles what that freed;
-- 'freeImage' destroys an image and frees its allocation the same way;
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
  , allocateImage
  , freeBuffer
  , freeImage
  , flushBuffer
  , invalidateBuffer
  , nameBuffer
  , nameAllocation
  ) where

import Control.Concurrent.STM (STM, atomically)
import Control.Exception
  ( Exception (displayException)
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , fromException
  , onException
  , rethrowIO
  , throwIO
  , tryWithContext
  )
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.Foldable (for_, traverse_)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
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
  , BoundMemory (..)
  , BufferRequest (..)
  , Creation (..)
  , ImageRequest (..)
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
  { allocatedMemory ∷ !BoundMemory
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
  | AllocationBeyondResource !Natural !Natural
    -- ^ The resource's memory requirements exceed what the device allows one
    -- resource: what it needs, and the most. Nothing was created.
  deriving (Eq, Show)

-- | How the protocol makes and destroys one kind of resource: the
-- allocator's calls, and the names they are made under.
data Shape = Shape
  { shapeRequirementsCall ∷ !Text
  , shapeRequirements ∷ AllocatorOps → IO MemoryRequirements
  , shapeCreateCall ∷ !Text
  , shapeCreate ∷ AllocatorOps → Word32 → Placement → IO (MemoryEvents, Creation)
  , shapeDestroyer ∷ !Destroyer
  , shapeMapped ∷ !Bool
    -- ^ Whether a host-visible allocation is mapped for its lifetime.
  , shapeMostSize ∷ !(Maybe Natural)
    -- ^ The most memory the device allows one such resource, when it states
    -- one.
  }

-- | How one kind of resource is destroyed with its allocation, and the name
-- of that call.
data Destroyer = Destroyer
  { destroyerCall ∷ !Text
  , destroyerDestroy ∷ AllocatorOps → BoundMemory → IO MemoryEvents
  }

bufferDestroyer, imageDestroyer ∷ Destroyer
bufferDestroyer = Destroyer "vmaDestroyBuffer" allocatorDestroyBuffer
imageDestroyer = Destroyer "vmaDestroyImage" allocatorDestroyImage

bufferShape ∷ BufferRequest → Shape
bufferShape request =
  Shape
    { shapeRequirementsCall = "vkGetDeviceBufferMemoryRequirements"
    , shapeRequirements = \ops → allocatorBufferRequirements ops request
    , shapeCreateCall = "vmaCreateBuffer"
    , shapeCreate = \ops → allocatorCreateBuffer ops request
    , shapeDestroyer = bufferDestroyer
    , shapeMapped = True
    , shapeMostSize = Nothing
    }

imageShape ∷ ImageRequest → Natural → Shape
imageShape request most =
  Shape
    { shapeRequirementsCall = "vkGetDeviceImageMemoryRequirements"
    , shapeRequirements = \ops → allocatorImageRequirements ops request
    , shapeCreateCall = "vmaCreateImage"
    , shapeCreate = \ops → allocatorCreateImage ops request
    , shapeDestroyer = imageDestroyer
    , shapeMapped = False
    , shapeMostSize = Just most
    }

-- | Make a buffer's memory for the attempt, in the memory type the usage
-- chooses, by the protocol above.
allocateBuffer
  ∷ Roots q inst msgr phys dev
  → AllocationId
  → MemoryUsage
  → BufferRequest
  → IO (Either AllocationRefusal AllocatedBuffer)
allocateBuffer roots attempt kind request = allocate roots (bufferShape request) attempt kind

-- | Make an image's memory for the attempt, in the memory type the usage
-- chooses, by the protocol above: the image and its allocation, bound, and
-- never mapped. An image whose memory requirements exceed the device's
-- largest resource (@maxResourceSize@) is refused once they are known, before
-- anything is created.
allocateImage
  ∷ Roots q inst msgr phys dev
  → AllocationId
  → MemoryUsage
  → ImageRequest
  → Natural
  → IO (Either AllocationRefusal BoundMemory)
allocateImage roots attempt kind request most = fmap allocatedMemory <$> allocate roots (imageShape request most) attempt kind

allocate
  ∷ Roots q inst msgr phys dev
  → Shape
  → AllocationId
  → MemoryUsage
  → IO (Either AllocationRefusal AllocatedBuffer)
allocate roots shape attempt kind =
  atomically (readRootsAllocator roots) >>= \case
    Nothing → pure (Left AllocationNoAllocator)
    Just ops → do
      needs ← rootsCall roots (shapeRequirementsCall shape) (shapeRequirements shape ops)
      case chooseMemoryType kind (requirementTypes needs) (allocatorMemoryTypes ops) of
        _ | Just most ← shapeMostSize shape, requirementSize needs > most → pure (Left (AllocationBeyondResource (requirementSize needs) most))
        Left refused → pure (Left (AllocationNoMemoryType refused))
        Right offer → do
          let index = offerTypeIndex offer
              heldCall = shapeCreateCall shape <> " in held memory"
          (heldEvents, held) ← rootsCall roots heldCall (shapeCreate shape ops index InHeldMemory)
          heldFinding ← atomically (counted held >> settle roots Nothing 0 heldEvents)
          -- A placement in held memory opens nothing; one that did, or any
          -- effect the accounting cannot take, fails the request.
          for_ heldFinding (failRequest roots shape ops heldCall held)
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
                  let call = shapeCreateCall shape
                  (events, made) ←
                    rootsCall roots call (shapeCreate shape ops index MayOpenMemory)
                      `onException` atomically (settle roots (Just attempt) bound noMemoryEvents)
                  finding ← atomically (counted made >> settle roots (Just attempt) bound events)
                  for_ finding (failRequest roots shape ops call made)
                  case made of
                    Created memory → Right <$> finish ops offer memory
                    CreationFailed failure → raise roots call failure
                    NotPlaced → throwIO (userError "the allocator answered an allocating call as a placement miss")
  where
    -- Count an allocation with the roots the moment a call answers it made,
    -- so it is counted for as long as anything might still hold it.
    counted = \case
      Created _ → noteRootsAllocation roots True
      _ → pure ()
    -- Map what is host-visible and mapped by this shape, and answer it. A map
    -- that failed destroys what was made, settling that, and is raised.
    finish ops offer memory = do
      let visible = shapeMapped shape && HostVisible `elem` offerProperties offer
          coherent = HostCoherent `elem` offerProperties offer
      mapped ←
        if visible
          then
            Just
              <$> rootsCall roots "vmaMapMemory" (allocatorMap ops memory)
                `onException` destroyMade roots (shapeDestroyer shape) ops memory
          else pure Nothing
      pure (AllocatedBuffer memory coherent mapped)

-- | Unmap, destroy the buffer, then free its allocation, settling what that
-- freed and counting the allocation gone. A call that raised has an unknown
-- effect; the caller retains what it concerns. The destruction itself
-- returned even when its effect disagrees with the accounting, so that
-- defect fails the session rather than the destruction.
freeBuffer ∷ Roots q inst msgr phys dev → AllocatedBuffer → IO ()
freeBuffer roots = release roots bufferDestroyer

-- | Destroy the image, then free its allocation, exactly as 'freeBuffer'
-- frees a buffer's.
freeImage ∷ Roots q inst msgr phys dev → BoundMemory → IO ()
freeImage roots memory = release roots imageDestroyer (AllocatedBuffer memory False Nothing)

release ∷ Roots q inst msgr phys dev → Destroyer → AllocatedBuffer → IO ()
release roots destroyer allocated =
  atomically (readRootsAllocator roots) >>= \case
    Nothing → throwIO (userError "the device's allocator is gone while an allocation made from it remains")
    Just ops → do
      let memory = allocatedMemory allocated
          call = destroyerCall destroyer
      for_ (allocatedMapped allocated) $ \_ → rootsCall roots "vmaUnmapMemory" (allocatorUnmap ops memory)
      events ← rootsCall roots call (destroyerDestroy destroyer ops memory)
      atomically $ do
        finding ← settle roots Nothing 0 events
        noteRootsAllocation roots False
        for_ finding (defectFails roots call)

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
nameBuffer roots allocated = nameAllocation roots (allocatedMemory allocated)

-- | Name a buffer's or an image's allocation inside the allocator.
nameAllocation ∷ Roots q inst msgr phys dev → BoundMemory → ByteString → IO ()
nameAllocation roots memory name = withAllocator roots $ \ops →
  rootsCall roots "vmaSetAllocationName" (allocatorName ops memory name)

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
failRequest ∷ Roots q inst msgr phys dev → Shape → AllocatorOps → Text → Creation → AccountingFinding → IO a
failRequest roots shape ops operation made finding = do
  case made of
    Created memory → destroyMade roots (shapeDestroyer shape) ops memory
    _ → pure ()
  atomically (defectFails roots operation finding)
  throwIO (AllocatorAccountingDefect operation finding)

-- | Destroy what a creation made before it is returned, settling what that
-- freed and counting the allocation gone. It is used on the paths that raise
-- their own failure afterwards, so a destruction that raised is not raised in
-- its place: its effect is unknown, so the allocation stays counted — the
-- allocator is never destroyed under it, nor the device — and the session
-- fails with 'CleanupFailed'. A cancellation of it is re-raised.
destroyMade ∷ Roots q inst msgr phys dev → Destroyer → AllocatorOps → BoundMemory → IO ()
destroyMade roots destroyer ops memory =
  tryWithContext @SomeException (rootsCall roots call (destroyerDestroy destroyer ops memory)) >>= \case
    Right events → atomically $ do
      settle roots Nothing 0 events >>= traverse_ (defectFails roots call)
      noteRootsAllocation roots False
    Left failure@(ExceptionWithContext _ exception) → do
      atomically $
        failRootsSessionBecause roots CleanupFailed $
          call <> " of what a failed request made raised: " <> Text.pack (displayException exception)
      when (isJust (fromException exception ∷ Maybe SomeAsyncException)) (rethrowIO failure)
  where
    call = destroyerCall destroyer

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
