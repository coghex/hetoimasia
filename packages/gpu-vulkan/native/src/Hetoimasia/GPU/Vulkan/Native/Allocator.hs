-- | The device-memory allocator's native layer (GRS-11, D-38): the shape of
-- the one allocator the roots own per device, and the engine's memory-type
-- policy above it.
--
-- The allocator is an open record of calls, 'AllocatorOps', in the manner of
-- the roots' and the recording's layers. Its production form is VMA, through
-- the engine's own shim ("Hetoimasia.GPU.Vulkan.Native.Allocator.Vulkan"); the
-- headless examples supply a stand-in that keeps its blocks in Haskell. No VMA
-- type appears here or anywhere else in the package's public modules: a buffer
-- and its allocation are 64-bit handles, as every other native object is.
--
-- = What the engine decides
--
-- * __The memory type.__ A request names a 'MemoryUsage', which states the
--   property flags it requires and prefers (D-16). The engine applies them to
--   the resource's allowed types and picks one ('chooseMemoryType'); the
--   allocator is given only that type, and can neither choose nor fall back to
--   another. A usage no allowed type serves is refused, naming the usage.
-- * __The bound on what an allocating call can open.__ The larger of the
--   type's preferred block size and the request's size ('reservationBound').
--   The preferred size is VMA's own computation ('preferredBlockSize') over
--   the large-heap size the allocator is configured with
--   ('largeHeapBlockSize').
--
-- Everything about how memory is laid out — blocks, placement, dedicated
-- allocations, retained empty blocks, mapping and atom alignment — is the
-- allocator's. Accounting, backpressure, recovery and lifetime stay the
-- engine's, in the package's private allocation protocol, which reads every
-- call's 'MemoryEvents'.
module Hetoimasia.GPU.Vulkan.Native.Allocator
  ( -- * The native layer
    AllocatorOps (..)
  , BufferRequest (..)
  , MemoryRequirements (..)
  , Placement (..)
  , MemoryEvents (..)
  , noMemoryEvents
  , BufferMemory (..)

    -- * Memory types
  , MemoryProperty (..)
  , MemoryTypeOffer (..)
  , MemoryUsage (..)
  , usageProperties
  , chooseMemoryType
  , MemoryTypeRefused (..)

    -- * Failures
  , AllocatorAccountingDefect (..)

    -- * Block sizes
  , largeHeapBlockSize
  , smallHeapLimit
  , preferredBlockSize
  , reservationBound
  ) where

import Control.Exception (Exception (displayException), SomeException)
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.List (sortOn)
import Data.Ord (Down (..))
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Memory types

-- | The memory properties the engine's usages speak of.
data MemoryProperty
  = DeviceLocal
  | HostVisible
  | HostCoherent
  | HostCached
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | One memory type the device offers: its index, its properties, and the
-- preferred size of a block of it, as 'preferredBlockSize' computes it from
-- its heap.
data MemoryTypeOffer = MemoryTypeOffer
  { offerTypeIndex ∷ !Word32
  , offerProperties ∷ ![MemoryProperty]
  , offerPreferredBlock ∷ !Natural
  }
  deriving (Eq, Show)

-- | What the data in an allocation is, which decides the memory it lives in
-- (D-16).
data MemoryUsage
  = UsageTexture
    -- ^ Always staged into device-local memory.
  | UsageStaticGeometry
    -- ^ Staged into device-local memory.
  | UsageStaging
    -- ^ Written by the host, copied by the device.
  | UsageFrameRing
    -- ^ Per-frame data the device reads directly.
  | UsageReadback
    -- ^ Written by the device, read by the host: cached where the device
    -- offers it, which is where a read is fast.
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The properties a usage requires, and those it prefers.
usageProperties ∷ MemoryUsage → ([MemoryProperty], [MemoryProperty])
usageProperties = \case
  UsageTexture → ([DeviceLocal], [])
  UsageStaticGeometry → ([DeviceLocal], [])
  UsageStaging → ([HostVisible], [HostCoherent])
  UsageFrameRing → ([HostVisible], [HostCoherent])
  UsageReadback → ([HostVisible], [HostCached])

-- | No memory type the resource allows serves the usage. Nothing is
-- allocated in some other type instead.
data MemoryTypeRefused = MemoryTypeRefused !MemoryUsage !Word32
  -- ^ The usage, and the resource's allowed types as a bit mask.
  deriving (Eq, Show)

-- | The one memory type a resource's allocation uses: among the types its
-- @memoryTypeBits@ allow that have every property the usage requires, the
-- one with the most properties it prefers, and of those the lowest index.
chooseMemoryType ∷ MemoryUsage → Word32 → [MemoryTypeOffer] → Either MemoryTypeRefused MemoryTypeOffer
chooseMemoryType kind allowed offers =
  case sortOn rank (filter serves offers) of
    chosen : _ → Right chosen
    [] → Left (MemoryTypeRefused kind allowed)
  where
    (required, preferred) = usageProperties kind
    serves offer =
      offerTypeIndex offer < 32
        && allowed `div` (2 ^ offerTypeIndex offer) `mod` 2 == 1
        && all (`elem` offerProperties offer) required
    rank offer = (Down (length (filter (`elem` offerProperties offer) preferred)), offerTypeIndex offer)

-- ---------------------------------------------------------------------------
-- Failures

-- | An allocating call opened more device memory than the engine reserved for
-- it, contradicting the allocator's sizing (D-40). What it made was destroyed
-- and freed, and the request failed; the memory it opened stays charged for as
-- long as the allocator holds it, and the session fails if that leaves the
-- accounted bytes over the budget.
data AllocatorAccountingDefect = AllocatorAccountingDefect
  { defectOperation ∷ !Text
  , defectReserved ∷ !Natural
  , defectOpened ∷ !Natural
  }
  deriving (Eq, Show)

instance Exception AllocatorAccountingDefect where
  displayException found =
    Text.unpack (defectOperation found)
      <> " opened "
      <> show (defectOpened found)
      <> " bytes of device memory where at most "
      <> show (defectReserved found)
      <> " were reserved"

-- ---------------------------------------------------------------------------
-- Block sizes

-- | The preferred block size the allocator is configured with for heaps
-- larger than 'smallHeapLimit': 256 MiB, VMA's own default, stated
-- explicitly as GRS-18 measured it.
largeHeapBlockSize ∷ Natural
largeHeapBlockSize = 256 * 1024 * 1024

-- | VMA's @VMA_SMALL_HEAP_MAX_SIZE@: 1 GiB. A heap no larger is small.
smallHeapLimit ∷ Natural
smallHeapLimit = 1024 * 1024 * 1024

-- | VMA 3.3.0's @CalcPreferredBlockSize@, for a memory type on a heap of this
-- size: an eighth of a small heap, otherwise the configured large-heap size,
-- aligned up to 32 bytes. VMA opens no block larger than this.
preferredBlockSize ∷ Natural → Natural
preferredBlockSize heapSize = ((raw + 31) `div` 32) * 32
  where
    raw
      | heapSize <= smallHeapLimit = heapSize `div` 8
      | otherwise = largeHeapBlockSize

-- | The most one allocating call in this type can open for a request of this
-- size (D-40): a block of the type's preferred size, or a dedicated
-- allocation of exactly the request's.
reservationBound ∷ MemoryTypeOffer → Natural → Natural
reservationBound offer size = max (offerPreferredBlock offer) size

-- ---------------------------------------------------------------------------
-- The native layer

-- | A buffer to create: its size and its Vulkan usage flags.
data BufferRequest = BufferRequest
  { requestBufferSize ∷ !Natural
  , requestBufferUsage ∷ !Word32
  }
  deriving (Eq, Show)

-- | What a buffer of that request needs: the size of its memory and the
-- memory types it may live in, as a bit mask.
data MemoryRequirements = MemoryRequirements
  { requirementSize ∷ !Natural
  , requirementTypes ∷ !Word32
  }
  deriving (Eq, Show)

-- | Where an allocation may be made.
data Placement
  = InHeldMemory
    -- ^ Only inside device memory the allocator already holds
    -- (@VMA_ALLOCATION_CREATE_NEVER_ALLOCATE_BIT@): it opens nothing.
  | MayOpenMemory
    -- ^ Opening a block or a dedicated allocation if it must.
  deriving (Eq, Show)

-- | What the allocator's device-memory callbacks saw during one call: the
-- blocks and dedicated allocations it opened, and those it freed.
data MemoryEvents = MemoryEvents
  { eventsOpenedCount ∷ !Natural
  , eventsOpenedBytes ∷ !Natural
  , eventsFreedCount ∷ !Natural
  , eventsFreedBytes ∷ !Natural
  }
  deriving (Eq, Show)

noMemoryEvents ∷ MemoryEvents
noMemoryEvents = MemoryEvents 0 0 0 0

-- | One buffer with its allocation, bound.
data BufferMemory = BufferMemory
  { memoryBuffer ∷ !Word64
  , memoryAllocation ∷ !Word64
    -- ^ The allocator's handle for the allocation.
  , memoryDevice ∷ !Word64
    -- ^ The device memory it lies in, which other allocations may share.
  , memoryOffset ∷ !Natural
    -- ^ Where in that device memory it starts.
  , memorySize ∷ !Natural
    -- ^ The allocation's size, at least the buffer's.
  , memoryType ∷ !Word32
  }
  deriving (Eq, Show)

-- | Every call the engine makes to one device's allocator, which exists from
-- the device's creation until just before its destruction. Every call is made
-- on the graphics owner's thread alone.
--
-- A call that can open or free device memory answers what it did in
-- 'MemoryEvents', whether or not it succeeded, and answers a failure as a
-- value, so its effect is never lost to an exception. Its failure is what
-- the roots' native layer classifies ('Hetoimasia.GPU.Vulkan.Native.Roots.opsNativeFailure'):
-- out of memory for a placement that did not fit or an allocation that could
-- not be made.
data AllocatorOps = AllocatorOps
  { allocatorMemoryTypes ∷ ![MemoryTypeOffer]
    -- ^ Every memory type of the device, with its preferred block size.
  , allocatorBufferRequirements ∷ BufferRequest → IO MemoryRequirements
    -- ^ What a buffer of the request would need, asked of the device without
    -- creating one.
  , allocatorCreateBuffer ∷ BufferRequest → Word32 → Placement → IO (MemoryEvents, Either SomeException BufferMemory)
    -- ^ Create the buffer and its allocation in exactly that memory type,
    -- bound. A failure has destroyed whatever the call made.
  , allocatorDestroyBuffer ∷ BufferMemory → IO MemoryEvents
    -- ^ Destroy the buffer, then free its allocation.
  , allocatorMap ∷ BufferMemory → IO Word64
    -- ^ Map the allocation, answering its address. Opens nothing.
  , allocatorUnmap ∷ BufferMemory → IO ()
  , allocatorFlush ∷ BufferMemory → (Natural, Natural) → IO ()
    -- ^ Flush a range of the allocation — an offset from its start and a
    -- size — after host writes to non-coherent memory. The allocator
    -- translates it into its device memory and aligns it to the atom.
  , allocatorInvalidate ∷ BufferMemory → (Natural, Natural) → IO ()
    -- ^ Invalidate such a range before host reads.
  , allocatorName ∷ BufferMemory → ByteString → IO ()
    -- ^ Name the allocation inside the allocator.
  , allocatorDestroy ∷ IO MemoryEvents
    -- ^ Destroy the allocator once every allocation is freed, which frees the
    -- device memory it still holds.
  }
