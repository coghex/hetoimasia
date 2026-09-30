-- | The vocabulary of placement: what a request asks for, the one validated
-- shape a strategy is handed, and the typed answers that reject a request.
--
-- Sizes and offsets are 'Word64', the width of a device size, and nothing a
-- validated request carries may exceed 'placementCeiling'. That ceiling is what
-- makes a strategy's arithmetic representable: an aligned offset below it plus a
-- size below it never overflows the 'Int' a strategy computes in, so a request
-- that would have overflowed is refused here rather than wrapping later.
module Hetoimasia.GPU.Model.Internal.Placement.Types
  ( -- * What a request asks for
    ResourceTiling (..)
  , Dedication (..)
  , MemoryTypeIndex (..)

    -- * The validated request a strategy places
  , Fit (..)
  , validateFit
  , placementCeiling
  , isPowerOfTwo

    -- * Why a request is refused
  , RequestField (..)
  , PlacementRejected (..)
  , PlacementId (..)

    -- * What a block looks like
  , BlockRange (..)
  , BlockUsage (..)
  , fragmentation
  ) where

import Data.Bits (Bits, (.&.))
import Data.Word (Word32, Word64)

-- ---------------------------------------------------------------------------
-- What a request asks for

-- | How a resource's memory is laid out, which decides whether it may share a
-- @bufferImageGranularity@ page with a neighbour. Buffers and linearly tiled
-- images are 'LinearResource'; optimally tiled images are 'OptimalResource'.
-- Two placements of the same tiling may share a page; two of different tilings
-- never do.
data ResourceTiling
  = LinearResource
  | OptimalResource
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | What the driver said about giving the resource its own allocation. Either
-- dedicated answer routes the request to a dedicated allocation whatever its
-- size.
data Dedication
  = NoDedicationPreference
  | DriverPrefersDedicated
  | DriverRequiresDedicated
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A device memory type, by its index in the device's memory properties. Each
-- memory type grows its own blocks independently of every other.
newtype MemoryTypeIndex = MemoryTypeIndex Word32
  deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- The validated request a strategy places

-- | A request a strategy may place: a positive size and a power-of-two
-- alignment, both no larger than 'placementCeiling', and the tiling that
-- decides page sharing. Only 'validateFit' builds one, so a strategy never
-- re-checks it.
data Fit = Fit
  { fitSize ∷ {-# UNPACK #-} !Int
  , fitAlignment ∷ {-# UNPACK #-} !Int
  , fitTiling ∷ !ResourceTiling
  }
  deriving (Eq, Show)

-- | The largest size, alignment, block capacity or granularity placement
-- accepts: 2^62 bytes. Any sum of two values at or below it fits in a 64-bit
-- 'Int', which is the only reason for this particular bound.
placementCeiling ∷ Word64
placementCeiling = 2 ^ (62 ∷ Int)

-- | Validate a size, an alignment and a tiling. The checks run in a fixed order
-- so a request with several faults reports the same one every time. Nothing is
-- rounded: a zero size is not taken as one, and a zero alignment is not taken as
-- one either, because Vulkan never reports one.
validateFit ∷ Word64 → Word64 → ResourceTiling → Either PlacementRejected Fit
validateFit size alignment tiling
  | size == 0 = Left RequestSizeZero
  | size > placementCeiling = Left (RequestAboveCeiling RequestedSize size)
  | not (isPowerOfTwo alignment) = Left (RequestAlignmentNotPowerOfTwo alignment)
  | alignment > placementCeiling = Left (RequestAboveCeiling RequestedAlignment alignment)
  | otherwise = Right (Fit (fromIntegral size) (fromIntegral alignment) tiling)
{-# INLINE validateFit #-}

-- | Whether a value is a positive power of two. Zero is not.
isPowerOfTwo ∷ (Num a, Bits a) ⇒ a → Bool
isPowerOfTwo value = value /= 0 && value .&. (value - 1) == 0
{-# INLINE isPowerOfTwo #-}

-- ---------------------------------------------------------------------------
-- Why a request is refused

-- | Which part of a request a ceiling refusal is about.
data RequestField
  = RequestedSize
  | RequestedAlignment
  deriving (Eq, Ord, Show)

-- | A placement or release that changed nothing, and why. None of these is
-- exhaustion: a request that is valid but does not fit a fixed block is
-- answered as a refusal by the block operations, not as one of these.
data PlacementRejected
  = RequestSizeZero
    -- ^ A size of zero bytes. It is not rounded up.
  | RequestAlignmentNotPowerOfTwo !Word64
    -- ^ An alignment of zero or one that is not a power of two.
  | RequestAboveCeiling !RequestField !Word64
    -- ^ A size or alignment above 'placementCeiling'.
  | UnknownPlacement !PlacementId
    -- ^ A release of a placement this allocator does not hold: never issued by
    -- it, or already released.
  deriving (Eq, Show)

-- | One placement's identity within one allocator. Identities are issued in
-- increasing order and never reused, so a released placement's identity can
-- never release the placement that later took its offset.
newtype PlacementId = PlacementId Word64
  deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- What a block looks like

-- | One range of a block, in offset order. A block's ranges tile it exactly:
-- they are contiguous, they start at zero and they end at the capacity, and no
-- two free ranges are adjacent, because freeing coalesces them.
data BlockRange
  = LiveRange !Word64 !Word64 !ResourceTiling
    -- ^ A placement: offset, size and tiling.
  | FreeRange !Word64 !Word64
    -- ^ Unplaced bytes: offset and size.
  deriving (Eq, Show)

-- | A block's occupancy, as the parity probe and the empty-block report read it.
data BlockUsage = BlockUsage
  { usageCapacity ∷ !Word64
  , usageLiveCount ∷ !Int
  , usageLiveBytes ∷ !Word64
  , usageFreeBytes ∷ !Word64
  , usageLargestFreeRange ∷ !Word64
  , usageFreeRangeCount ∷ !Int
  }
  deriving (Eq, Show)

-- | @1 − largest free range ÷ total free bytes@, and zero when no byte is free.
-- It is zero when the free space is one range and approaches one as the free
-- space splits into many small ranges.
fragmentation ∷ BlockUsage → Double
fragmentation usage
  | usageFreeBytes usage == 0 = 0
  | otherwise =
      1 - fromIntegral (usageLargestFreeRange usage) / fromIntegral (usageFreeBytes usage)
