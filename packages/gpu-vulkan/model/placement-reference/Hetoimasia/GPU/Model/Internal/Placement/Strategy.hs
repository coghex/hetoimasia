-- | The interface a placement strategy implements, and the block that hides
-- which strategy it runs.
--
-- A strategy decides where, inside one block of fixed capacity, a validated
-- request goes, and how a released range rejoins the free space. Everything
-- above one block — which memory type, which block, when to open another, when
-- to go dedicated — is the allocator's, and it reaches a strategy only through
-- 'Block'. A 'Block' packs a strategy's operations with its state, so the
-- allocator, the parity probe and every other caller are written against
-- 'Block' alone: a second strategy, such as TLSF, is one more 'Strategy' value
-- and changes none of them.
module Hetoimasia.GPU.Model.Internal.Placement.Strategy
  ( -- * The interface
    Strategy (..)
  , Placed (..)
  , PlacementStrategy (..)
  , strategyLabel

    -- * A block running some strategy
  , Block
  , Fitted (..)
  , openBlock
  , openFixedBlock
  , placeInBlock
  , releaseInBlock
  , blockUsage
  , blockRanges
  , blockCapacity
  , blockIsEmpty
  ) where

import Data.Word (Word64)
import Hetoimasia.GPU.Model.Internal.Placement.Config
  ( PlacementConfigRejected
  , validateCapacity
  , validateGranularity
  )
import Hetoimasia.GPU.Model.Internal.Placement.Types (BlockRange, BlockUsage (..), Fit)

-- ---------------------------------------------------------------------------
-- The interface

-- | One strategy's operations over its own block state @s@. Every operation is
-- total and pure; a refusal changes nothing.
data Strategy s = Strategy
  { strategyName ∷ !String
  , strategyEmpty ∷ Int → Int → s
    -- ^ An empty block of the given capacity and granularity, both already
    -- validated.
  , strategyPlace ∷ Fit → s → Placed s
    -- ^ Place a request, or refuse it without changing anything.
  , strategyRelease ∷ Int → s → Maybe s
    -- ^ Release the placement that starts at an offset, coalescing it with free
    -- neighbours; 'Nothing' when no placement starts there.
  , strategyUsage ∷ s → BlockUsage
  , strategyRanges ∷ s → [BlockRange]
    -- ^ The block's live and free ranges in offset order.
  }

-- | A strategy's answer to a request. Both fields are strict so that forcing
-- the answer forces the placement work.
data Placed s
  = NoFit
  | PlacedAt {-# UNPACK #-} !Int !s

-- | A strategy whose state type is hidden, so it can be chosen at run time and
-- handed to code that never names it.
data PlacementStrategy = ∀ s. PlacementStrategy !(Strategy s)

-- | The strategy's name, as reports and the parity record print it.
strategyLabel ∷ PlacementStrategy → String
strategyLabel (PlacementStrategy strategy) = strategyName strategy

-- ---------------------------------------------------------------------------
-- A block running some strategy

-- | One block of fixed capacity and the placements in it, run by whichever
-- strategy opened it.
data Block = ∀ s. Block !(Strategy s) !s

-- | 'placeInBlock''s answer. The block is strict, so forcing the answer to weak
-- head normal form completes the placement.
data Fitted
  = Refused
    -- ^ No free range of this block can take the request.
  | Fitted {-# UNPACK #-} !Word64 !Block
    -- ^ The offset the request was placed at, and the block holding it.

-- | An empty block of a capacity and granularity the caller has already
-- validated.
openBlock ∷ PlacementStrategy → Int → Int → Block
openBlock (PlacementStrategy strategy) capacity granularity =
  Block strategy (strategyEmpty strategy capacity granularity)

-- | An empty block of any representable capacity: the fixed block the parity
-- probe replays traces into, which never grows and never goes dedicated. The
-- granularity is validated as a configuration's is.
openFixedBlock ∷ PlacementStrategy → Integer → Integer → Either PlacementConfigRejected Block
openFixedBlock strategy capacity granularity = do
  checkedCapacity ← validateCapacity capacity
  checkedGranularity ← validateGranularity granularity
  pure (openBlock strategy checkedCapacity checkedGranularity)

-- | Place a validated request, or refuse it and change nothing.
placeInBlock ∷ Fit → Block → Fitted
placeInBlock fit (Block strategy state) =
  case strategyPlace strategy fit state of
    NoFit → Refused
    PlacedAt offset state' → Fitted (fromIntegral offset) (Block strategy state')
{-# INLINE placeInBlock #-}

-- | Release the placement starting at an offset. 'Nothing', and no change, when
-- no placement starts there.
releaseInBlock ∷ Word64 → Block → Maybe Block
releaseInBlock offset (Block strategy state)
  | offset > fromIntegral (maxBound ∷ Int) = Nothing
  | otherwise = Block strategy <$> strategyRelease strategy (fromIntegral offset) state
{-# INLINE releaseInBlock #-}

-- | The block's occupancy.
blockUsage ∷ Block → BlockUsage
blockUsage (Block strategy state) = strategyUsage strategy state

-- | The block's live and free ranges, in offset order.
blockRanges ∷ Block → [BlockRange]
blockRanges (Block strategy state) = strategyRanges strategy state

-- | The block's capacity in bytes.
blockCapacity ∷ Block → Word64
blockCapacity = usageCapacity . blockUsage

-- | Whether the block holds no placement, so a later slice may free or cache it.
blockIsEmpty ∷ Block → Bool
blockIsEmpty = (== 0) . usageLiveCount . blockUsage
