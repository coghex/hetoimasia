-- | Pure placement of device allocations into blocks: a test reference.
--
-- __Status.__ This is not production code. It was #331's owned-allocator
-- placement (design decision D-13), measured against VMA and superseded when
-- the owner chose VMA for production allocation (D-38): neither it nor a
-- mutable prototype met the parity gates, recorded in
-- @docs/gpu_allocator_parity_record.md@. It lives in the model package's
-- @placement-reference@ sublibrary, which only test suites depend on, because
-- it states best fit's rules exactly and is tested against them.
--
-- __What this is.__ The placement half of an owned device-memory allocator: for
-- each memory type, a request — size, alignment, tiling and the driver's
-- dedicated-allocation answer — is placed at an offset in a block that is
-- already open, at an offset in a block opened for it, or into a dedicated
-- allocation, and a placement is released back. Freed neighbours coalesce, and
-- a block left with no placement is reported empty.
--
-- __What this is not.__ It makes no Vulkan call, names no native type and
-- allocates no memory. Backing a block, choosing a memory type, the byte budget
-- and freeing or caching empty blocks belong to the native allocator above it.
--
-- __Two levels.__ An 'Allocator' routes requests by memory type and grows each
-- type's blocks under a validated 'PlacementConfig'. A 'Block' is one block of
-- fixed capacity running a 'PlacementStrategy'; it never grows and never goes
-- dedicated, and refuses what does not fit. The allocator places through blocks
-- alone, and so does the parity probe, which is why the fixed-block comparison
-- with VMA exercises the production strategy.
--
-- __Strategies.__ 'bestFit' is the one strategy. Another is one more
-- 'PlacementStrategy' value, and neither 'Allocator' nor any caller changes.
--
-- See @docs/gpu_model.md@ for the same contract in prose.
module Hetoimasia.GPU.Model.Placement
  ( -- * Requests
    ResourceTiling (..)
  , Dedication (..)
  , MemoryTypeIndex (..)
  , PlacementRejected (..)
  , RequestField (..)
  , placementCeiling

    -- * Configuration
  , PlacementConfigRequest (..)
  , defaultPlacementConfigRequest
  , PlacementConfig
  , ConfigField (..)
  , PlacementConfigRejected (..)
  , validatePlacementConfig
  , initialBlockBytes
  , maximumBlockBytes
  , bufferImageGranularity
  , dedicatedThreshold

    -- * Strategies
  , PlacementStrategy
  , bestFit
  , strategyLabel

    -- * Allocators
  , Allocator
  , newAllocator
  , allocatorConfig
  , allocatorStrategyLabel
  , PlacementRequest (..)
  , Placement (..)
  , PlacementLocation (..)
  , PlacementId
  , placementNumber
  , BlockId
  , blockNumber
  , place
  , Released (..)
  , release
  , EmptyBlock (..)
  , emptyBlocks
  , allocatorBlocks
  , nextBlockBytes
  , livePlacementCount

    -- * Single blocks
  , Block
  , Fit
  , validateFit
  , Fitted (..)
  , openFixedBlock
  , placeInBlock
  , releaseInBlock
  , blockUsage
  , blockRanges
  , blockCapacity
  , blockIsEmpty
  , BlockRange (..)
  , BlockUsage (..)
  , fragmentation
  ) where

import Data.Word (Word64)
import Hetoimasia.GPU.Model.Internal.Placement.Allocator
import Hetoimasia.GPU.Model.Internal.Placement.BestFit (bestFit)
import Hetoimasia.GPU.Model.Internal.Placement.Config
  ( ConfigField (..)
  , PlacementConfig
  , PlacementConfigRejected (..)
  , PlacementConfigRequest (..)
  , bufferImageGranularity
  , dedicatedThreshold
  , defaultPlacementConfigRequest
  , initialBlockBytes
  , maximumBlockBytes
  , validatePlacementConfig
  )
import Hetoimasia.GPU.Model.Internal.Placement.Strategy
  ( Block
  , Fitted (..)
  , PlacementStrategy
  , blockCapacity
  , blockIsEmpty
  , blockRanges
  , blockUsage
  , openFixedBlock
  , placeInBlock
  , releaseInBlock
  , strategyLabel
  )
import Hetoimasia.GPU.Model.Internal.Placement.Types
  ( BlockRange (..)
  , BlockUsage (..)
  , Dedication (..)
  , Fit
  , MemoryTypeIndex (..)
  , PlacementId (..)
  , PlacementRejected (..)
  , RequestField (..)
  , ResourceTiling (..)
  , fragmentation
  , placementCeiling
  , validateFit
  )

-- | A placement identity's number: issued in increasing order from zero by one
-- allocator, and never reused.
placementNumber ∷ PlacementId → Word64
placementNumber (PlacementId number) = number

-- | A block identity's number: issued in the order blocks are opened, from zero,
-- across every memory type of one allocator.
blockNumber ∷ BlockId → Word64
blockNumber (BlockId number) = number
