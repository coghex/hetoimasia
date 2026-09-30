-- | Placement across memory types, blocks and dedicated allocations.
--
-- An allocator routes each request by its memory type. A request the driver
-- prefers or requires dedicated, or one of at least 'dedicatedThreshold' bytes,
-- becomes a dedicated allocation. Anything else goes to the first of its memory
-- type's blocks, in the order they were opened, whose strategy can place it;
-- when none can, a new block is opened for it. Each memory type's blocks grow
-- on their own from the initial size, doubling to the maximum, and a request
-- larger than the next size advances straight to the first size that fits it
-- without opening the sizes in between.
--
-- Everything is a value. Nothing here allocates memory: a placement in a newly
-- opened block tells the owning boundary to back that block, and a released
-- placement that left its block empty says so, but whether an empty block is
-- freed or kept is a later slice's decision. The allocator keeps an empty block
-- and places into it again.
module Hetoimasia.GPU.Model.Internal.Placement.Allocator
  ( -- * An allocator
    Allocator
  , newAllocator
  , allocatorConfig
  , allocatorStrategyLabel

    -- * Placing
  , PlacementRequest (..)
  , Placement (..)
  , PlacementLocation (..)
  , BlockId (..)
  , place

    -- * Releasing
  , Released (..)
  , release

    -- * Observing
  , EmptyBlock (..)
  , emptyBlocks
  , allocatorBlocks
  , nextBlockBytes
  , livePlacementCount
  ) where

import qualified Data.IntMap.Strict as IntMap
import Data.IntMap.Strict (IntMap)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Word (Word64)
import Hetoimasia.GPU.Model.Internal.Placement.Config
  ( PlacementConfig
  , configDedicatedThreshold
  , configGranularity
  , configInitialBlock
  , configMaximumBlock
  )
import Hetoimasia.GPU.Model.Internal.Placement.Strategy
  ( Block
  , Fitted (..)
  , PlacementStrategy
  , blockCapacity
  , blockIsEmpty
  , openBlock
  , placeInBlock
  , releaseInBlock
  , strategyLabel
  )
import Hetoimasia.GPU.Model.Internal.Placement.Types
  ( Dedication (..)
  , Fit (..)
  , MemoryTypeIndex
  , PlacementId (..)
  , PlacementRejected (..)
  , ResourceTiling
  , validateFit
  )

-- ---------------------------------------------------------------------------
-- An allocator

-- | Every memory type's blocks, every live placement, and the counters that
-- issue identities. Identities are unique within one allocator; the owning
-- boundary keeps one allocator per device, so an identity is never handed to an
-- allocator other than the one that issued it.
data Allocator = Allocator
  { allocatorStrategy ∷ !PlacementStrategy
  , allocatorConfig ∷ !PlacementConfig
  , allocatorTypes ∷ !(Map MemoryTypeIndex TypeBlocks)
  , allocatorLive ∷ !(IntMap Record)
    -- ^ Keyed by placement number.
  , allocatorNextPlacement ∷ !Word64
  , allocatorNextBlock ∷ !Word64
  }

-- | One memory type's blocks, in the order they were opened, and the size the
-- next one opens at.
data TypeBlocks = TypeBlocks
  { typeBlocks ∷ !(Map BlockId Block)
  , typeNextSize ∷ {-# UNPACK #-} !Int
  }

-- | Where a live placement is, which is all releasing it needs.
data Record
  = InBlockRecord !MemoryTypeIndex !BlockId {-# UNPACK #-} !Word64
  | DedicatedRecord

-- | One block's identity within one allocator. Blocks are numbered in the order
-- they are opened, across every memory type, and never renumbered.
newtype BlockId = BlockId Word64
  deriving (Eq, Ord, Show)

-- | An allocator with no block and no placement.
newAllocator ∷ PlacementStrategy → PlacementConfig → Allocator
newAllocator strategy config =
  Allocator
    { allocatorStrategy = strategy
    , allocatorConfig = config
    , allocatorTypes = Map.empty
    , allocatorLive = IntMap.empty
    , allocatorNextPlacement = 0
    , allocatorNextBlock = 0
    }

-- | The name of the strategy the allocator's blocks run.
allocatorStrategyLabel ∷ Allocator → String
allocatorStrategyLabel = strategyLabel . allocatorStrategy

-- ---------------------------------------------------------------------------
-- Placing

-- | What the owning boundary asks to place: a resource's memory requirements,
-- the memory type chosen for it, its tiling, and what the driver said about a
-- dedicated allocation.
data PlacementRequest = PlacementRequest
  { requestMemoryType ∷ !MemoryTypeIndex
  , requestSize ∷ !Word64
  , requestAlignment ∷ !Word64
  , requestTiling ∷ !ResourceTiling
  , requestDedication ∷ !Dedication
  }
  deriving (Eq, Show)

-- | A placement the allocator made.
data Placement = Placement
  { placementId ∷ !PlacementId
  , placementMemoryType ∷ !MemoryTypeIndex
  , placementSize ∷ !Word64
  , placementLocation ∷ !PlacementLocation
  }
  deriving (Eq, Show)

-- | Where a placement went.
data PlacementLocation
  = InExistingBlock !BlockId !Word64
    -- ^ A block that was already open, at an offset.
  | InOpenedBlock !BlockId !Word64 !Word64
    -- ^ A block opened for this request, of the given capacity, at an offset.
    -- The owning boundary backs the block before using the placement.
  | DedicatedAllocation
    -- ^ An allocation of its own, of the placement's size.
  deriving (Eq, Show)

-- | Place a request. It is validated first, and a rejected request changes
-- nothing. A valid request is always placed: this slice has no byte budget, so
-- a request that fits no open block opens one.
place ∷ PlacementRequest → Allocator → Either PlacementRejected (Placement, Allocator)
place request allocator = do
  fit ← validateFit (requestSize request) (requestAlignment request) (requestTiling request)
  pure $
    if dedicated fit
      then settle (DedicatedAllocation, DedicatedRecord) (allocatorTypes allocator) (allocatorNextBlock allocator)
      else placeInType fit
  where
    config = allocatorConfig allocator
    memoryType = requestMemoryType request
    number = allocatorNextPlacement allocator
    identity = PlacementId number

    dedicated fit =
      requestDedication request /= NoDedicationPreference
        || fitSize fit >= configDedicatedThreshold config

    placeInType fit =
      case firstFitting fit (Map.toAscList (typeBlocks blocks)) of
        Just (blockId, offset, block') →
          settle
            (InExistingBlock blockId offset, InBlockRecord memoryType blockId offset)
            (Map.insert memoryType blocks {typeBlocks = Map.insert blockId block' (typeBlocks blocks)} (allocatorTypes allocator))
            (allocatorNextBlock allocator)
        Nothing → openFor fit
      where
        blocks =
          Map.findWithDefault
            (TypeBlocks Map.empty (configInitialBlock config))
            memoryType
            (allocatorTypes allocator)
        openFor _ =
          let size = growTo (typeNextSize blocks)
              blockId = BlockId (allocatorNextBlock allocator)
              opened = openBlock (allocatorStrategy allocator) size (configGranularity config)
           in case placeInBlock fit opened of
                Fitted offset block' →
                  settle
                    (InOpenedBlock blockId (fromIntegral size) offset, InBlockRecord memoryType blockId offset)
                    ( Map.insert
                        memoryType
                        TypeBlocks
                          { typeBlocks = Map.insert blockId block' (typeBlocks blocks)
                          , typeNextSize = grown size
                          }
                        (allocatorTypes allocator)
                    )
                    (allocatorNextBlock allocator + 1)
                -- A request below the dedicated threshold is smaller than the
                -- maximum block, the growth step is at least its size, offset
                -- zero satisfies every alignment and an empty block has no
                -- neighbour to share a page with.
                Refused → error "Hetoimasia.GPU.Model.Placement: an empty block refused a request it was sized for"
        growTo step
          | step >= fitSize fit = step
          | otherwise = growTo (grown step)

    -- Doubling stops at the maximum. A step below the maximum is at most half
    -- of 2^62, so doubling it cannot overflow.
    grown step = min (configMaximumBlock config) (2 * step)

    settle (location, record) types nextBlock =
      let placement =
            Placement
              { placementId = identity
              , placementMemoryType = memoryType
              , placementSize = requestSize request
              , placementLocation = location
              }
       in ( placement
          , allocator
              { allocatorTypes = types
              , allocatorLive = IntMap.insert (fromIntegral number) record (allocatorLive allocator)
              , allocatorNextPlacement = number + 1
              , allocatorNextBlock = nextBlock
              }
          )

    firstFitting _ [] = Nothing
    firstFitting fit ((blockId, block) : rest) =
      case placeInBlock fit block of
        Fitted offset block' → Just (blockId, offset, block')
        Refused → firstFitting fit rest

-- ---------------------------------------------------------------------------
-- Releasing

-- | What a release did.
data Released
  = ReleasedFromBlock !MemoryTypeIndex !BlockId !Bool
    -- ^ The placement's block, and whether the release left it empty.
  | ReleasedDedicated
    -- ^ A dedicated allocation, which the owning boundary frees.
  deriving (Eq, Show)

-- | Release a live placement. An identity this allocator does not hold — never
-- issued, or already released — is rejected and changes nothing.
release ∷ PlacementId → Allocator → Either PlacementRejected (Released, Allocator)
release identity@(PlacementId number) allocator =
  case lookupRecord of
    Nothing → Left (UnknownPlacement identity)
    Just DedicatedRecord → Right (ReleasedDedicated, forget (allocatorTypes allocator))
    Just (InBlockRecord memoryType blockId offset) →
      case released memoryType blockId offset of
        Nothing → Left (UnknownPlacement identity)
        Just (blocks, block') →
          Right
            ( ReleasedFromBlock memoryType blockId (blockIsEmpty block')
            , forget
                ( Map.insert
                    memoryType
                    blocks {typeBlocks = Map.insert blockId block' (typeBlocks blocks)}
                    (allocatorTypes allocator)
                )
            )
  where
    key = fromIntegral number
    lookupRecord
      | number > fromIntegral (maxBound ∷ Int) = Nothing
      | otherwise = IntMap.lookup key (allocatorLive allocator)
    released memoryType blockId offset = do
      blocks ← Map.lookup memoryType (allocatorTypes allocator)
      block ← Map.lookup blockId (typeBlocks blocks)
      block' ← releaseInBlock offset block
      pure (blocks, block')
    forget types =
      allocator
        { allocatorTypes = types
        , allocatorLive = IntMap.delete key (allocatorLive allocator)
        }

-- ---------------------------------------------------------------------------
-- Observing

-- | A block that holds no placement.
data EmptyBlock = EmptyBlock
  { emptyMemoryType ∷ !MemoryTypeIndex
  , emptyBlockId ∷ !BlockId
  , emptyCapacity ∷ !Word64
  }
  deriving (Eq, Show)

-- | Every block that holds no placement, by memory type and then in the order
-- the blocks were opened. A later slice frees or caches them; this one only
-- reports them.
emptyBlocks ∷ Allocator → [EmptyBlock]
emptyBlocks allocator =
  [ EmptyBlock memoryType blockId (blockCapacity block)
  | (memoryType, blockId, block) ← allocatorBlocks allocator
  , blockIsEmpty block
  ]

-- | Every open block, by memory type and then in the order they were opened.
allocatorBlocks ∷ Allocator → [(MemoryTypeIndex, BlockId, Block)]
allocatorBlocks allocator =
  [ (memoryType, blockId, block)
  | (memoryType, blocks) ← Map.toAscList (allocatorTypes allocator)
  , (blockId, block) ← Map.toAscList (typeBlocks blocks)
  ]

-- | The capacity a memory type's next block would open at, if nothing larger is
-- needed.
nextBlockBytes ∷ MemoryTypeIndex → Allocator → Word64
nextBlockBytes memoryType allocator =
  fromIntegral $
    maybe
      (configInitialBlock (allocatorConfig allocator))
      typeNextSize
      (Map.lookup memoryType (allocatorTypes allocator))

-- | How many placements are live, dedicated ones included.
livePlacementCount ∷ Allocator → Int
livePlacementCount = IntMap.size . allocatorLive
