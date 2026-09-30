{-# LANGUAGE BangPatterns #-}

-- | A bounded prototype: best fit over one block, in mutable arrays.
--
-- __Status.__ An experiment for #331's parity probe, not production code. The
-- production strategy is the pure 'Hetoimasia.GPU.Model.Placement.bestFit'
-- (D-13), and this prototype is measured against it. It exists to show what
-- the persistent maps cost, so it keeps the reference's decisions exactly: the
-- smallest free range the request fits once aligned, the lowest offset among
-- ranges of that size, the same granularity rule and the same validation. The
-- probe checks, offset for offset, that it places what the reference places.
--
-- __Mutation and ownership are explicit.__ A 'MutableBlock' @s@ is mutated in
-- place by operations in @'ST' s@. It has one owner. There is no lock and no
-- pure facade: nothing here may be shared between threads, and a caller that
-- wants a value must copy one out with 'mutableUsage'.
--
-- __Representation.__
--
-- * /Segments./ Every range of the block, free or live, is a segment in a slot
--   of one unboxed 'Int' array, eight fields per slot. Segments link to their
--   physical neighbours and to their neighbours in a free-list bin by slot
--   index, so no operation shifts an array. Slots are recycled through a stack;
--   the array doubles only when every slot is in use, and that happens before
--   an operation writes anything.
-- * /Coalescing./ A release looks at its two physical neighbours and absorbs a
--   free one, in constant time.
-- * /The size index./ Free segments are binned TLSF-style — 32 exact bins
--   below 32 bytes, then 32 linear bins per power of two — with a first-level
--   bitmap and a second-level bitmap per level, so the next non-empty bin is
--   one count of trailing zeros away. Unlike TLSF, each bin holds its segments
--   in a treap ordered by (size, offset): a binary search tree kept balanced in
--   expectation by random heap priorities. The search takes the bin's first
--   segment at least as large as the request and walks in-order successors,
--   which visits candidates in exactly the reference's (size, offset) order.
--   Insertion and removal are rotations, so a bin of many equal-sized ranges
--   costs O(log n) rather than a walk of the bin. The tree's links, parent and
--   priority are four more fields of the same slot, so nothing is shifted.
--   'mutableDeepestPath' reports the deepest insertion path taken.
-- * /Handles./ A placement answers its slot, the slot's generation and its
--   offset. A release checks the generation, which every release advances, so
--   a stale or repeated release is rejected in constant time.
module Prototype.MutableBestFit
  ( MutableBlock
  , Allocation (..)
  , MutablePlaced (..)
  , newMutableBlock
  , placeMutable
  , releaseMutable
  , mutableUsage
  , mutableDeepestPath
  ) where

import Control.Monad (when)
import Control.Monad.ST (ST)
import Data.Bits (complement, countLeadingZeros, countTrailingZeros, shiftL, shiftR, xor, (.&.), (.|.))
import Data.STRef (STRef, newSTRef, readSTRef, writeSTRef)
import qualified Data.Vector.Unboxed.Mutable as Mutable
import Data.Word (Word64)
import Hetoimasia.GPU.Model.Placement
  ( BlockUsage (..)
  , ConfigField (..)
  , PlacementConfigRejected (..)
  , PlacementRejected
  , ResourceTiling (..)
  , placementCeiling
  , validateFit
  )

-- | One block, owned by whoever holds it in @'ST' s@.
data MutableBlock s = MutableBlock
  { blockSegments ∷ !(STRef s (Mutable.MVector s Int))
    -- ^ Ten fields per slot; replaced when it doubles.
  , blockBins ∷ !(Mutable.MVector s Int)
    -- ^ The root of each bin's treap, or -1.
  , blockLevels ∷ !(Mutable.MVector s Int)
    -- ^ The second-level bitmap of each first level.
  , blockCounters ∷ !(Mutable.MVector s Int)
    -- ^ See the @counter@ indices below.
  }

-- | A live placement's handle.
data Allocation = Allocation
  { allocationSlot ∷ {-# UNPACK #-} !Int
  , allocationGeneration ∷ {-# UNPACK #-} !Int
  , allocationOffset ∷ {-# UNPACK #-} !Word64
  }
  deriving (Eq, Show)

-- | A placement's answer. Its fields are strict, so forcing it finishes the
-- placement.
data MutablePlaced
  = MutableInvalid !PlacementRejected
    -- ^ The request failed the same validation the reference applies.
  | MutableRefused
    -- ^ No free range can take it. Nothing changed.
  | MutablePlaced {-# UNPACK #-} !Allocation

-- Segment fields.
fieldOffset, fieldSize, fieldState, fieldPreviousPhysical, fieldNextPhysical, fieldLeft, fieldRight, fieldGeneration, fieldParent, fieldPriority, stride ∷ Int
fieldOffset = 0
fieldSize = 1
fieldState = 2
fieldPreviousPhysical = 3
fieldNextPhysical = 4
fieldLeft = 5
fieldRight = 6
fieldGeneration = 7
fieldParent = 8
fieldPriority = 9
stride = 10

-- Segment states.
stateFree, stateLinear, stateOptimal, stateRecycled ∷ Int
stateFree = 0
stateLinear = 1
stateOptimal = 2
stateRecycled = 3

-- Counters.
counterFirstLevel, counterSlotsUsed, counterRecycled, counterLiveCount, counterFreeBytes, counterFreeCount, counterCapacity, counterGranularity, counterDeepestPath, counterPriorityState, counters ∷ Int
counterFirstLevel = 0
counterSlotsUsed = 1
counterRecycled = 2
counterLiveCount = 3
counterFreeBytes = 4
counterFreeCount = 5
counterCapacity = 6
counterGranularity = 7
counterDeepestPath = 8
counterPriorityState = 9
counters = 10

secondLevelBits, secondLevels, firstLevels ∷ Int
secondLevelBits = 5
secondLevels = 32
firstLevels = 64

-- | The bin a size belongs to: exact below 32 bytes, then 32 linear bins per
-- power of two. Bin numbers increase with size.
binOf ∷ Int → Int
binOf size
  | size < secondLevels = size
  | otherwise =
      let level = 63 - countLeadingZeros size
          sub = (size `shiftR` (level - secondLevelBits)) .&. (secondLevels - 1)
       in (level - secondLevelBits + 1) * secondLevels + sub
{-# INLINE binOf #-}

-- | An empty block, validated by the reference's rules: a capacity from one
-- byte to the ceiling, and a power-of-two granularity no larger than it.
newMutableBlock ∷ Integer → Integer → ST s (Either PlacementConfigRejected (MutableBlock s))
newMutableBlock capacity granularity
  | capacity <= 0 = pure (Left (ConfigNotPositive BlockCapacityField capacity))
  | capacity > ceiling' = pure (Left (ConfigAboveCeiling BlockCapacityField capacity))
  | granularity <= 0 = pure (Left (ConfigNotPositive GranularityField granularity))
  | granularity > ceiling' = pure (Left (ConfigAboveCeiling GranularityField granularity))
  | granularity .&. (granularity - 1) /= 0 = pure (Left (ConfigNotPowerOfTwo GranularityField granularity))
  | otherwise = do
      segments ← Mutable.replicate (64 * stride) (-1)
      reference ← newSTRef segments
      bins ← Mutable.replicate (firstLevels * secondLevels) (-1)
      levels ← Mutable.replicate firstLevels 0
      counts ← Mutable.replicate counters 0
      let block = MutableBlock reference bins levels counts
      Mutable.write counts counterCapacity (fromInteger capacity)
      Mutable.write counts counterGranularity (fromInteger granularity)
      Mutable.write counts counterRecycled (-1)
      Mutable.write counts counterPriorityState 331
      Mutable.write counts counterFreeBytes (fromInteger capacity)
      slot ← takeSlot block segments
      set segments slot fieldOffset 0
      set segments slot fieldSize (fromInteger capacity)
      set segments slot fieldPreviousPhysical (-1)
      set segments slot fieldNextPhysical (-1)
      set segments slot fieldGeneration 0
      insertFree block segments slot
      pure (Right block)
  where
    ceiling' = toInteger placementCeiling

get ∷ Mutable.MVector s Int → Int → Int → ST s Int
get segments slot field = Mutable.unsafeRead segments (slot * stride + field)
{-# INLINE get #-}

set ∷ Mutable.MVector s Int → Int → Int → Int → ST s ()
set segments slot field = Mutable.unsafeWrite segments (slot * stride + field)
{-# INLINE set #-}

counter ∷ MutableBlock s → Int → ST s Int
counter block = Mutable.unsafeRead (blockCounters block)
{-# INLINE counter #-}

setCounter ∷ MutableBlock s → Int → Int → ST s ()
setCounter block = Mutable.unsafeWrite (blockCounters block)
{-# INLINE setCounter #-}

-- | Make room for two more segments, doubling the array if it could run out,
-- and answer the array every later write in the operation uses.
reserve ∷ MutableBlock s → ST s (Mutable.MVector s Int)
reserve block = do
  segments ← readSTRef (blockSegments block)
  used ← counter block counterSlotsUsed
  if (used + 2) * stride <= Mutable.length segments
    then pure segments
    else do
      grown ← Mutable.unsafeGrow segments (Mutable.length segments)
      Mutable.set (Mutable.unsafeSlice (Mutable.length segments) (Mutable.length segments) grown) (-1)
      writeSTRef (blockSegments block) grown
      pure grown

-- | A slot for a new segment: a recycled one, or the next unused one.
takeSlot ∷ MutableBlock s → Mutable.MVector s Int → ST s Int
takeSlot block segments = do
  recycled ← counter block counterRecycled
  if recycled >= 0
    then do
      next ← get segments recycled fieldRight
      setCounter block counterRecycled next
      pure recycled
    else do
      used ← counter block counterSlotsUsed
      setCounter block counterSlotsUsed (used + 1)
      set segments used fieldGeneration 0
      pure used

recycleSlot ∷ MutableBlock s → Mutable.MVector s Int → Int → ST s ()
recycleSlot block segments slot = do
  set segments slot fieldState stateRecycled
  counter block counterRecycled >>= set segments slot fieldRight
  setCounter block counterRecycled slot

-- | Whether a segment of this size and offset comes before segment @other@
-- in (size, offset) order.
precedes ∷ Mutable.MVector s Int → Int → Int → Int → ST s Bool
precedes segments size offset other = do
  otherSize ← get segments other fieldSize
  if size /= otherSize
    then pure (size < otherSize)
    else (offset <) <$> get segments other fieldOffset
{-# INLINE precedes #-}

-- | The next treap priority: a splitmix64 step, so priorities are
-- deterministic and a run is reproducible.
nextPriority ∷ MutableBlock s → ST s Int
nextPriority block = do
  state ← counter block counterPriorityState
  let state' = state + (-7046029254386353131)
      -- Logical shifts, as splitmix64 uses; the state is an Int only because
      -- the counters are.
      logical x n = fromIntegral ((fromIntegral x ∷ Word64) `shiftR` n) ∷ Int
      mix1 = (state' `xor` logical state' 30) * (-4658895280553007687)
      mix2 = (mix1 `xor` logical mix1 27) * (-7723592293110705685)
      mixed = mix2 `xor` logical mix2 31
  setCounter block counterPriorityState state'
  pure (mixed .&. maxBound)

-- | Rotate @node@ above its parent, keeping (size, offset) order.
rotateUp ∷ MutableBlock s → Mutable.MVector s Int → Int → Int → ST s ()
rotateUp block segments bin node = do
  parent ← get segments node fieldParent
  grandparent ← get segments parent fieldParent
  isLeft ← (== node) <$> get segments parent fieldLeft
  if isLeft
    then do
      inner ← get segments node fieldRight
      set segments parent fieldLeft inner
      when (inner >= 0) $ set segments inner fieldParent parent
      set segments node fieldRight parent
    else do
      inner ← get segments node fieldLeft
      set segments parent fieldRight inner
      when (inner >= 0) $ set segments inner fieldParent parent
      set segments node fieldLeft parent
  set segments parent fieldParent node
  set segments node fieldParent grandparent
  if grandparent < 0
    then Mutable.unsafeWrite (blockBins block) bin node
    else do
      wasLeft ← (== parent) <$> get segments grandparent fieldLeft
      set segments grandparent (if wasLeft then fieldLeft else fieldRight) node

-- | Insert a free segment into its bin's treap.
insertFree ∷ MutableBlock s → Mutable.MVector s Int → Int → ST s ()
insertFree block segments slot = do
  size ← get segments slot fieldSize
  offset ← get segments slot fieldOffset
  priority ← nextPriority block
  set segments slot fieldState stateFree
  set segments slot fieldLeft (-1)
  set segments slot fieldRight (-1)
  set segments slot fieldPriority priority
  let bin = binOf size
  root ← Mutable.unsafeRead (blockBins block) bin
  if root < 0
    then do
      set segments slot fieldParent (-1)
      Mutable.unsafeWrite (blockBins block) bin slot
    else do
      let descend !depth node = do
            goLeft ← precedes segments size offset node
            let side = if goLeft then fieldLeft else fieldRight
            child ← get segments node side
            if child < 0
              then do
                set segments node side slot
                set segments slot fieldParent node
                pure depth
              else descend (depth + 1) child
          siftUp = do
            parent ← get segments slot fieldParent
            when (parent >= 0) $ do
              parentPriority ← get segments parent fieldPriority
              when (priority > parentPriority) $ rotateUp block segments bin slot >> siftUp
      depth ← descend (1 ∷ Int) root
      deepest ← counter block counterDeepestPath
      when (depth > deepest) $ setCounter block counterDeepestPath depth
      siftUp
  let level = bin `shiftR` secondLevelBits
      sub = bin .&. (secondLevels - 1)
  levelBits ← Mutable.unsafeRead (blockLevels block) level
  Mutable.unsafeWrite (blockLevels block) level (levelBits .|. (1 `shiftL` sub))
  firsts ← counter block counterFirstLevel
  setCounter block counterFirstLevel (firsts .|. (1 `shiftL` level))
  counter block counterFreeCount >>= setCounter block counterFreeCount . (+ 1)

-- | Remove a free segment from its bin's treap: rotate it down below its
-- higher-priority child until it has at most one, then splice it out.
removeFree ∷ MutableBlock s → Mutable.MVector s Int → Int → ST s ()
removeFree block segments slot = do
  size ← get segments slot fieldSize
  let bin = binOf size
      sink = do
        left ← get segments slot fieldLeft
        right ← get segments slot fieldRight
        if left >= 0 && right >= 0
          then do
            leftPriority ← get segments left fieldPriority
            rightPriority ← get segments right fieldPriority
            rotateUp block segments bin (if leftPriority > rightPriority then left else right)
            sink
          else pure (if left >= 0 then left else right)
  child ← sink
  parent ← get segments slot fieldParent
  when (child >= 0) $ set segments child fieldParent parent
  if parent < 0
    then Mutable.unsafeWrite (blockBins block) bin child
    else do
      wasLeft ← (== slot) <$> get segments parent fieldLeft
      set segments parent (if wasLeft then fieldLeft else fieldRight) child
  root ← Mutable.unsafeRead (blockBins block) bin
  when (root < 0) $ do
    let level = bin `shiftR` secondLevelBits
        sub = bin .&. (secondLevels - 1)
    levelBits ← Mutable.unsafeRead (blockLevels block) level
    let remaining = levelBits .&. complement (1 `shiftL` sub)
    Mutable.unsafeWrite (blockLevels block) level remaining
    when (remaining == 0) $ do
      firsts ← counter block counterFirstLevel
      setCounter block counterFirstLevel (firsts .&. complement (1 `shiftL` level))
  counter block counterFreeCount >>= setCounter block counterFreeCount . subtract 1

-- | The first segment of a treap at least @size@ bytes large, or -1.
lowerBound ∷ Mutable.MVector s Int → Int → Int → ST s Int
lowerBound segments size = go (-1)
  where
    go best node
      | node < 0 = pure best
      | otherwise = do
          nodeSize ← get segments node fieldSize
          if nodeSize >= size
            then get segments node fieldLeft >>= go node
            else get segments node fieldRight >>= go best

-- | The next segment in (size, offset) order within a treap, or -1.
successor ∷ Mutable.MVector s Int → Int → ST s Int
successor segments node = do
  right ← get segments node fieldRight
  if right >= 0
    then leftmost right
    else climb node
  where
    leftmost n = do
      left ← get segments n fieldLeft
      if left < 0 then pure n else leftmost left
    climb child = do
      parent ← get segments child fieldParent
      if parent < 0
        then pure (-1)
        else do
          fromRight ← (== child) <$> get segments parent fieldRight
          if fromRight then climb parent else pure parent

-- | The first non-empty bin after @bin@, or -1.
nextBin ∷ MutableBlock s → Int → ST s Int
nextBin block bin = do
  let level = bin `shiftR` secondLevelBits
      sub = bin .&. (secondLevels - 1)
  levelBits ← Mutable.unsafeRead (blockLevels block) level
  let above = if sub + 1 >= secondLevels then 0 else levelBits .&. complement ((1 `shiftL` (sub + 1)) - 1)
  if above /= 0
    then pure (level * secondLevels + countTrailingZeros above)
    else do
      firsts ← counter block counterFirstLevel
      let higher = if level + 1 >= firstLevels then 0 else firsts .&. complement ((1 `shiftL` (level + 1)) - 1)
      if higher == 0
        then pure (-1)
        else do
          let level' = countTrailingZeros higher
          levelBits' ← Mutable.unsafeRead (blockLevels block) level'
          pure (level' * secondLevels + countTrailingZeros levelBits')

tilingState ∷ ResourceTiling → Int
tilingState LinearResource = stateLinear
tilingState OptimalResource = stateOptimal

-- | Place a request, validated exactly as the reference validates it.
placeMutable ∷ MutableBlock s → Word64 → Word64 → ResourceTiling → ST s MutablePlaced
placeMutable block size64 alignment64 tiling =
  case validateFit size64 alignment64 tiling of
    Left rejection → pure (MutableInvalid rejection)
    Right _ → do
      segments ← reserve block
      granularity ← counter block counterGranularity
      capacity ← counter block counterCapacity
      let size = fromIntegral size64
          alignment = fromIntegral alignment64
          want = tilingState tiling
          page offset = offset `div` granularity
          -- Where the request would go in free segment @slot@, if anywhere;
          -- the reference's rule, with neighbours read from the links.
          candidate slot = do
            start ← get segments slot fieldOffset
            rangeSize ← get segments slot fieldSize
            let end = start + rangeSize
                offset0 = alignUp start alignment
            if offset0 > end - size
              then pure (-1)
              else do
                aligned ←
                  if granularity > 1 && start > 0
                    then do
                      previous ← get segments slot fieldPreviousPhysical
                      previousState ← get segments previous fieldState
                      previousStart ← get segments previous fieldOffset
                      previousSize ← get segments previous fieldSize
                      pure $
                        if previousState /= want && page (previousStart + previousSize - 1) == page offset0
                          then alignUp offset0 granularity
                          else offset0
                    else pure offset0
                if aligned > end - size
                  then pure (-1)
                  else
                    if granularity > 1 && end < capacity
                      then do
                        next ← get segments slot fieldNextPhysical
                        nextState ← get segments next fieldState
                        pure (if nextState /= want && page (aligned + size - 1) == page end then -1 else aligned)
                      else pure aligned
          -- Walk one bin in (size, offset) order from its first segment at
          -- least as large as the request.
          scan slot
            | slot < 0 = pure (-1, -1)
            | otherwise = do
                at ← candidate slot
                if at >= 0 then pure (slot, at) else successor segments slot >>= scan
          search bin
            | bin < 0 = pure (-1, -1)
            | otherwise = do
                root ← Mutable.unsafeRead (blockBins block) bin
                found@(slot, _) ← lowerBound segments size root >>= scan
                if slot >= 0 then pure found else nextBin block bin >>= search
      let startBin = binOf size
      first ← Mutable.unsafeRead (blockBins block) startBin
      (slot, aligned) ← if first >= 0 then search startBin else nextBin block startBin >>= search
      if slot < 0
        then pure MutableRefused
        else do
          commit block segments slot aligned size want
          generation ← get segments slot fieldGeneration
          pure (MutablePlaced (Allocation slot generation (fromIntegral aligned)))

-- | Carve @[aligned, aligned + size)@ out of free segment @slot@, which then
-- holds the placement; padding before and remainder after become free
-- segments linked in beside it.
commit ∷ MutableBlock s → Mutable.MVector s Int → Int → Int → Int → Int → ST s ()
commit block segments slot aligned size state = do
  removeFree block segments slot
  start ← get segments slot fieldOffset
  rangeSize ← get segments slot fieldSize
  let padding = aligned - start
      remainder = start + rangeSize - (aligned + size)
  when (padding > 0) $ do
    before ← takeSlot block segments
    previous ← get segments slot fieldPreviousPhysical
    set segments before fieldOffset start
    set segments before fieldSize padding
    set segments before fieldPreviousPhysical previous
    set segments before fieldNextPhysical slot
    when (previous >= 0) $ set segments previous fieldNextPhysical before
    set segments slot fieldPreviousPhysical before
    insertFree block segments before
  when (remainder > 0) $ do
    after ← takeSlot block segments
    next ← get segments slot fieldNextPhysical
    set segments after fieldOffset (aligned + size)
    set segments after fieldSize remainder
    set segments after fieldPreviousPhysical slot
    set segments after fieldNextPhysical next
    when (next >= 0) $ set segments next fieldPreviousPhysical after
    set segments slot fieldNextPhysical after
    insertFree block segments after
  set segments slot fieldOffset aligned
  set segments slot fieldSize size
  set segments slot fieldState state
  counter block counterLiveCount >>= setCounter block counterLiveCount . (+ 1)
  counter block counterFreeBytes >>= setCounter block counterFreeBytes . subtract size

-- | Release a live placement, coalescing it with free neighbours. 'False', and
-- no change, for a handle that is not live: never issued, already released,
-- or from a slot since reused.
releaseMutable ∷ MutableBlock s → Allocation → ST s Bool
releaseMutable block (Allocation slot generation _) = do
  segments ← readSTRef (blockSegments block)
  used ← counter block counterSlotsUsed
  if slot < 0 || slot >= used
    then pure False
    else do
      state ← get segments slot fieldState
      current ← get segments slot fieldGeneration
      if (state /= stateLinear && state /= stateOptimal) || current /= generation
        then pure False
        else do
          size ← get segments slot fieldSize
          set segments slot fieldGeneration (current + 1)
          counter block counterLiveCount >>= setCounter block counterLiveCount . subtract 1
          counter block counterFreeBytes >>= setCounter block counterFreeBytes . (+ size)
          previous ← get segments slot fieldPreviousPhysical
          previousFree ← if previous >= 0 then (== stateFree) <$> get segments previous fieldState else pure False
          when previousFree $ do
            removeFree block segments previous
            previousStart ← get segments previous fieldOffset
            previousSize ← get segments previous fieldSize
            outer ← get segments previous fieldPreviousPhysical
            set segments slot fieldOffset previousStart
            get segments slot fieldSize >>= set segments slot fieldSize . (+ previousSize)
            set segments slot fieldPreviousPhysical outer
            when (outer >= 0) $ set segments outer fieldNextPhysical slot
            recycleSlot block segments previous
          next ← get segments slot fieldNextPhysical
          nextFree ← if next >= 0 then (== stateFree) <$> get segments next fieldState else pure False
          when nextFree $ do
            removeFree block segments next
            nextSize ← get segments next fieldSize
            outer ← get segments next fieldNextPhysical
            get segments slot fieldSize >>= set segments slot fieldSize . (+ nextSize)
            set segments slot fieldNextPhysical outer
            when (outer >= 0) $ set segments outer fieldPreviousPhysical slot
            recycleSlot block segments next
          insertFree block segments slot
          pure True

-- | A copy of the block's occupancy, in the reference's terms.
mutableUsage ∷ MutableBlock s → ST s BlockUsage
mutableUsage block = do
  segments ← readSTRef (blockSegments block)
  capacity ← counter block counterCapacity
  live ← counter block counterLiveCount
  free ← counter block counterFreeBytes
  freeCount ← counter block counterFreeCount
  firsts ← counter block counterFirstLevel
  largest ←
    if firsts == 0
      then pure 0
      else do
        let level = 63 - countLeadingZeros firsts
        levelBits ← Mutable.unsafeRead (blockLevels block) level
        let bin = level * secondLevels + (63 - countLeadingZeros levelBits)
            rightmost slot = do
              right ← get segments slot fieldRight
              if right < 0 then get segments slot fieldSize else rightmost right
        Mutable.unsafeRead (blockBins block) bin >>= rightmost
  pure
    BlockUsage
      { usageCapacity = fromIntegral capacity
      , usageLiveCount = live
      , usageLiveBytes = fromIntegral (capacity - free)
      , usageFreeBytes = fromIntegral free
      , usageLargestFreeRange = fromIntegral largest
      , usageFreeRangeCount = freeCount
      }

-- | The deepest path one insertion has descended in its bin's treap, since
-- the block was made.
mutableDeepestPath ∷ MutableBlock s → ST s Int
mutableDeepestPath block = counter block counterDeepestPath

alignUp ∷ Int → Int → Int
alignUp offset alignment = (offset + alignment - 1) .&. complement (alignment - 1)
{-# INLINE alignUp #-}
