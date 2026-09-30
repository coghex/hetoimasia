-- | Best-fit placement over a free list, coalescing freed neighbours (D-13).
--
-- A block's bytes are tiled exactly by live placements and free ranges. The
-- free ranges are indexed twice: by offset, to find a released range's
-- neighbours, and by size, to find the smallest range that can take a request.
-- A request goes to the smallest free range it fits once aligned, the lowest
-- offset among ranges of that size; alignment padding before it and the
-- remainder after it stay free. A released placement merges with a free range
-- that ends where it starts and with one that starts where it ends, so no two
-- free ranges are ever adjacent and a block whose placements are all released
-- is one free range again.
--
-- __Granularity.__ Linear and optimally tiled placements never share a
-- @bufferImageGranularity@ page. Because free ranges are coalesced, the only
-- placements that can share a page with a candidate are the placement ending
-- where its free range starts and the one starting where it ends: every page a
-- candidate touches that another placement also touches holds one of those two,
-- and a page already holds placements of one tiling only. A conflict with the
-- previous neighbour moves the offset up to the next page boundary; a conflict
-- with the next neighbour rejects the candidate, and the search moves on.
module Hetoimasia.GPU.Model.Internal.Placement.BestFit
  ( bestFit
  , BestFit
  ) where

import Data.Bits (complement, (.&.))
import qualified Data.IntMap.Strict as IntMap
import Data.IntMap.Strict (IntMap)
import qualified Data.IntSet as IntSet
import Data.IntSet (IntSet)
import Data.Maybe (isJust)
import Hetoimasia.GPU.Model.Internal.Placement.Strategy (Placed (..), PlacementStrategy (..), Strategy (..))
import Hetoimasia.GPU.Model.Internal.Placement.Types
  ( BlockRange (..)
  , BlockUsage (..)
  , Fit (..)
  , ResourceTiling
  )

-- | The best-fit strategy.
bestFit ∷ PlacementStrategy
bestFit =
  PlacementStrategy
    Strategy
      { strategyName = "best-fit"
      , strategyEmpty = emptyBestFit
      , strategyPlace = place
      , strategyRelease = release
      , strategyUsage = usage
      , strategyRanges = ranges
      }

-- | One block's state under best fit.
data BestFit = BestFit
  { bfCapacity ∷ {-# UNPACK #-} !Int
  , bfGranularity ∷ {-# UNPACK #-} !Int
  , bfFreeByOffset ∷ !(IntMap Int)
    -- ^ Each free range's size, keyed by its offset.
  , bfFreeBySize ∷ !(IntMap IntSet)
    -- ^ The offsets of the free ranges of each size. No set is empty.
  , bfLive ∷ !(IntMap Live)
    -- ^ Each placement, keyed by its offset.
  , bfLiveCount ∷ {-# UNPACK #-} !Int
  , bfFreeBytes ∷ {-# UNPACK #-} !Int
  , bfFreeCount ∷ {-# UNPACK #-} !Int
  }

-- | A placement's size and tiling.
data Live = Live {-# UNPACK #-} !Int !ResourceTiling

emptyBestFit ∷ Int → Int → BestFit
emptyBestFit capacity granularity =
  BestFit
    { bfCapacity = capacity
    , bfGranularity = granularity
    , bfFreeByOffset = IntMap.singleton 0 capacity
    , bfFreeBySize = IntMap.singleton capacity (IntSet.singleton 0)
    , bfLive = IntMap.empty
    , bfLiveCount = 0
    , bfFreeBytes = capacity
    , bfFreeCount = 1
    }

-- ---------------------------------------------------------------------------
-- Placing

place ∷ Fit → BestFit → Placed BestFit
place fit@(Fit size _ _) state = search size
  where
    -- Free ranges in increasing size, starting from the first that is at least
    -- as large as the request before alignment.
    search atLeast =
      case IntMap.lookupGE atLeast (bfFreeBySize state) of
        Nothing → NoFit
        Just (rangeSize, offsets) →
          case firstFit rangeSize (IntSet.toAscList offsets) of
            Just (start, offset) → commit fit start rangeSize offset state
            Nothing → search (rangeSize + 1)
    firstFit _ [] = Nothing
    firstFit rangeSize (start : rest) =
      case candidate fit state start (start + rangeSize) of
        Just offset → Just (start, offset)
        Nothing → firstFit rangeSize rest

-- | Where a request would go in the free range @[start, end)@, if anywhere.
candidate ∷ Fit → BestFit → Int → Int → Maybe Int
candidate (Fit size alignment tiling) state start end
  -- Checked first, so the page adjustment below only ever rounds an offset
  -- already inside the block and cannot overflow.
  | offset0 > end - size = Nothing
  | aligned > end - size = Nothing
  | conflictsAfter = Nothing
  | otherwise = Just aligned
  where
    granularity = bfGranularity state
    paged = granularity > 1
    offset0 = alignUp start alignment
    -- The placement ending where this free range starts, if its last page is
    -- the candidate's first page and its tiling differs, pushes the candidate
    -- to the next page.
    aligned
      | paged
      , start > 0
      , Just (previous, Live previousSize previousTiling) ← IntMap.lookupLT start (bfLive state)
      , previousTiling /= tiling
      , page (previous + previousSize - 1) == page offset0 =
          alignUp offset0 granularity
      | otherwise = offset0
    -- The placement starting where this free range ends, if the candidate's
    -- last page is its first page and its tiling differs, rejects it.
    conflictsAfter
      | paged
      , end < bfCapacity state
      , Just (Live _ nextTiling) ← IntMap.lookup end (bfLive state)
      , nextTiling /= tiling =
          page (aligned + size - 1) == page end
      | otherwise = False
    page offset = offset `div` granularity
{-# INLINE candidate #-}

-- | Take @[offset, offset + size)@ out of the free range @[start, start +
-- rangeSize)@, leaving the padding before it and the remainder after it free.
commit ∷ Fit → Int → Int → Int → BestFit → Placed BestFit
commit (Fit size _ tiling) start rangeSize offset state =
  PlacedAt offset $!
    state
      { bfFreeByOffset = byOffset
      , bfFreeBySize = bySize
      , bfLive = IntMap.insert offset (Live size tiling) (bfLive state)
      , bfLiveCount = bfLiveCount state + 1
      , bfFreeBytes = bfFreeBytes state - size
      , bfFreeCount = bfFreeCount state - 1 + fromEnum (padding > 0) + fromEnum (remainder > 0)
      }
  where
    padding = offset - start
    remainder = start + rangeSize - (offset + size)
    after = offset + size
    withoutRange =
      ( IntMap.delete start (bfFreeByOffset state)
      , removeSized rangeSize start (bfFreeBySize state)
      )
    withPadding
      | padding > 0 = addFree start padding withoutRange
      | otherwise = withoutRange
    (byOffset, bySize)
      | remainder > 0 = addFree after remainder withPadding
      | otherwise = withPadding

-- ---------------------------------------------------------------------------
-- Releasing

release ∷ Int → BestFit → Maybe BestFit
release offset state =
  case IntMap.lookup offset (bfLive state) of
    Nothing → Nothing
    Just (Live size _) →
      Just $!
        state
          { bfFreeByOffset = byOffset
          , bfFreeBySize = bySize
          , bfLive = IntMap.delete offset (bfLive state)
          , bfLiveCount = bfLiveCount state - 1
          , bfFreeBytes = bfFreeBytes state + size
          , bfFreeCount = bfFreeCount state + 1 - fromEnum mergesBefore - fromEnum mergesAfter
          }
      where
        end = offset + size
        -- A free range ending exactly where this placement starts.
        before = case IntMap.lookupLT offset (bfFreeByOffset state) of
          Just (previous, previousSize) | previous + previousSize == offset → Just (previous, previousSize)
          _ → Nothing
        -- A free range starting exactly where this placement ends.
        afterRange = (\nextSize → (end, nextSize)) <$> IntMap.lookup end (bfFreeByOffset state)
        mergesBefore = isJust before
        mergesAfter = isJust afterRange
        mergedStart = maybe offset fst before
        mergedEnd = maybe end (\(next, nextSize) → next + nextSize) afterRange
        indexes0 = (bfFreeByOffset state, bfFreeBySize state)
        indexes1 = maybe indexes0 (\(at, sized) → removeFree at sized indexes0) before
        indexes2 = maybe indexes1 (\(at, sized) → removeFree at sized indexes1) afterRange
        (byOffset, bySize) = addFree mergedStart (mergedEnd - mergedStart) indexes2

-- ---------------------------------------------------------------------------
-- Observing

usage ∷ BestFit → BlockUsage
usage state =
  BlockUsage
    { usageCapacity = fromIntegral (bfCapacity state)
    , usageLiveCount = bfLiveCount state
    , usageLiveBytes = fromIntegral (bfCapacity state - bfFreeBytes state)
    , usageFreeBytes = fromIntegral (bfFreeBytes state)
    , usageLargestFreeRange = maybe 0 (fromIntegral . fst) (IntMap.lookupMax (bfFreeBySize state))
    , usageFreeRangeCount = bfFreeCount state
    }

ranges ∷ BestFit → [BlockRange]
ranges state =
  map snd . IntMap.toAscList $
    IntMap.union
      (IntMap.mapWithKey (\offset (Live size tiling) → LiveRange (fromIntegral offset) (fromIntegral size) tiling) (bfLive state))
      (IntMap.mapWithKey (\offset size → FreeRange (fromIntegral offset) (fromIntegral size)) (bfFreeByOffset state))

-- ---------------------------------------------------------------------------
-- The two free-range indexes

addFree ∷ Int → Int → (IntMap Int, IntMap IntSet) → (IntMap Int, IntMap IntSet)
addFree offset size (byOffset, bySize) =
  ( IntMap.insert offset size byOffset
  , IntMap.insertWith IntSet.union size (IntSet.singleton offset) bySize
  )
{-# INLINE addFree #-}

removeFree ∷ Int → Int → (IntMap Int, IntMap IntSet) → (IntMap Int, IntMap IntSet)
removeFree offset size (byOffset, bySize) =
  (IntMap.delete offset byOffset, removeSized size offset bySize)
{-# INLINE removeFree #-}

removeSized ∷ Int → Int → IntMap IntSet → IntMap IntSet
removeSized size offset = IntMap.update shrink size
  where
    shrink offsets =
      let remaining = IntSet.delete offset offsets
       in if IntSet.null remaining then Nothing else Just remaining
{-# INLINE removeSized #-}

-- | Round up to a power-of-two alignment. Both arguments are at most 2^62, so
-- the sum cannot overflow.
alignUp ∷ Int → Int → Int
alignUp offset alignment = (offset + alignment - 1) .&. complement (alignment - 1)
{-# INLINE alignUp #-}
