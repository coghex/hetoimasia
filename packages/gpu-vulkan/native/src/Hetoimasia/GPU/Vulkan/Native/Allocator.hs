-- | The device-memory allocator's native layer (GRS-11, D-38): the shape of
-- the one allocator the roots own per device, and the engine's memory-type
-- policy above it.
--
-- The allocator is an open record of calls, 'AllocatorOps', in the manner of
-- the roots' and the recording's layers. Its production form is VMA, through
-- the engine's own shim ("Hetoimasia.GPU.Vulkan.Native.Allocator.Vulkan"); the
-- headless examples supply a stand-in that keeps its blocks in Haskell. No VMA
-- type appears here or anywhere else in the package's public modules: a buffer
-- or an image and its allocation are 64-bit handles, as every other native
-- object is.
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
  , ImageRequest (..)
  , MemoryRequirements (..)
  , Placement (..)
  , Creation (..)
  , MemoryEvents (..)
  , noMemoryEvents
  , BoundMemory (..)

    -- * Memory types
  , MemoryProperty (..)
  , MemoryTypeOffer (..)
  , MemoryUsage (..)
  , usageProperties
  , chooseMemoryType
  , MemoryTypeRefused (..)

    -- * Failures
  , AllocatorAccountingDefect (..)
  , AccountingFinding (..)

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
    -- ^ Always staged into device-local memory. Depth and color targets,
    -- which only the device writes and reads, live there too.
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

-- | The device-memory accounting stopped agreeing with what the allocator
-- reported (D-40). What the request made was destroyed and freed, and the
-- request failed. Memory that stays held stays charged.
data AllocatorAccountingDefect = AllocatorAccountingDefect
  { defectOperation ∷ !Text
  , defectFinding ∷ !AccountingFinding
  }
  deriving (Eq, Show)

-- | What disagreed.
data AccountingFinding
  = OpenedBeyondReservation !Natural !Natural
    -- ^ A call opened more than was reserved for it: the reservation, and
    -- what it opened. A placement in held memory reserves nothing. The
    -- session fails only if what stays held exceeds the byte budget.
  | FreedBeyondHeld !Natural
    -- ^ A call freed this many bytes more than the model held. The charge
    -- stops at zero, so the budget no longer bounds what is held, and the
    -- session fails.
  | SettlementRefused !Text
    -- ^ The model refused to settle a call's effect under its attempt; the
    -- effect was settled under no reservation instead, and the session
    -- fails.
  deriving (Eq, Show)

instance Exception AllocatorAccountingDefect where
  displayException found =
    Text.unpack (defectOperation found) <> ": " <> case defectFinding found of
      OpenedBeyondReservation reserved opened →
        "opened " <> show opened <> " bytes of device memory where at most " <> show reserved <> " were reserved"
      FreedBeyondHeld excess → "freed " <> show excess <> " bytes of device memory more than were charged as held"
      SettlementRefused why → "its device-memory effect could not be settled under its attempt (" <> Text.unpack why <> ")"

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

-- | An image to create: two-dimensional, optimally tiled, one array layer and
-- one sample, exclusive to one queue family, in the undefined layout — its
-- format, its extent, how many mip levels it has, and its Vulkan usage flags.
data ImageRequest = ImageRequest
  { requestImageFormat ∷ !Word32
  , requestImageWidth ∷ !Word32
  , requestImageHeight ∷ !Word32
  , requestImageMipLevels ∷ !Word32
  , requestImageUsage ∷ !Word32
  }
  deriving (Eq, Show)

-- | What a buffer or image of that request needs: the size of its memory and
-- the memory types it may live in, as a bit mask.
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

-- | What a buffer's or an image's creation answered.
data Creation
  = Created !BoundMemory
  | NotPlaced
    -- ^ Asked for in held memory only, it could not be placed there: nothing
    -- held fits it, or the driver requires a dedicated allocation, which only
    -- an allocating call may make (VMA answers that one
    -- @VK_ERROR_FEATURE_NOT_PRESENT@). Nothing was made. It is the expected
    -- miss, never a failure, and never the answer to an allocating call.
  | CreationFailed !SomeException
    -- ^ The creation failed, having destroyed whatever it made. Its failure
    -- is what the roots' native layer classifies: out of memory for an
    -- allocation that could not be made.
  deriving (Show)

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

-- | One buffer or image with its allocation, bound.
data BoundMemory = BoundMemory
  { memoryResource ∷ !Word64
    -- ^ The buffer or the image.
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
-- value, so its effect is never lost to an exception.
data AllocatorOps = AllocatorOps
  { allocatorMemoryTypes ∷ ![MemoryTypeOffer]
    -- ^ Every memory type of the device, with its preferred block size.
  , allocatorBufferRequirements ∷ BufferRequest → IO MemoryRequirements
    -- ^ What a buffer of the request would need, asked of the device without
    -- creating one.
  , allocatorCreateBuffer ∷ BufferRequest → Word32 → Placement → IO (MemoryEvents, Creation)
    -- ^ Create the buffer and its allocation in exactly that memory type,
    -- bound.
  , allocatorDestroyBuffer ∷ BoundMemory → IO MemoryEvents
    -- ^ Destroy the buffer, then free its allocation.
  , allocatorImageRequirements ∷ ImageRequest → IO MemoryRequirements
    -- ^ What an image of the request would need, asked of the device without
    -- creating one.
  , allocatorCreateImage ∷ ImageRequest → Word32 → Placement → IO (MemoryEvents, Creation)
    -- ^ Create the image and its allocation in exactly that memory type,
    -- bound.
  , allocatorDestroyImage ∷ BoundMemory → IO MemoryEvents
    -- ^ Destroy the image, then free its allocation.
  , allocatorMap ∷ BoundMemory → IO Word64
    -- ^ Map the allocation, answering its address. Opens nothing.
  , allocatorUnmap ∷ BoundMemory → IO ()
  , allocatorFlush ∷ BoundMemory → (Natural, Natural) → IO ()
    -- ^ Flush a range of the allocation — an offset from its start and a
    -- size — after host writes to non-coherent memory. The allocator
    -- translates it into its device memory and aligns it to the atom.
  , allocatorInvalidate ∷ BoundMemory → (Natural, Natural) → IO ()
    -- ^ Invalidate such a range before host reads.
  , allocatorName ∷ BoundMemory → ByteString → IO ()
    -- ^ Name the allocation inside the allocator.
  , allocatorDestroy ∷ IO MemoryEvents
    -- ^ Destroy the allocator once every allocation is freed, which frees the
    -- device memory it still holds.
  }
