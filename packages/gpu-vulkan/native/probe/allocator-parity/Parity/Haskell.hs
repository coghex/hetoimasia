{-# LANGUAGE BangPatterns #-}

-- | The Haskell side of the probe: a trace replayed into one fixed block of
-- the production placement strategy.
--
-- The block never grows and never goes dedicated, so a request that does not
-- fit is refused, exactly as VMA's virtual block refuses it. Every operation's
-- answer is forced to weak head normal form with 'evaluate' before the next
-- operation starts; the block's state is strict throughout, so that is the
-- whole of the work. In the per-operation mode each such operation — the
-- request's validation and placement, or the release — is bracketed by one
-- clock pair. In the interval mode one clock pair brackets a run of
-- operations, the loop's own bookkeeping included, as the shim's does.
-- Checkpoints do nothing outside the evidence pass.
--
-- Every mode keeps the same checksum of placed offsets, so a timed pass is
-- checked against the evidence pass: if any placement had been skipped or
-- left unevaluated, the checksum or the counts would differ.
module Parity.Haskell
  ( HaskellEvidence (..)
  , replayHaskell
  ) where

import Control.Exception (evaluate)
import Control.Monad (forM, when)
import qualified Data.Vector.Storable as Storable
import qualified Data.Vector.Storable.Mutable as StorableMutable
import qualified Data.Vector.Unboxed as Unboxed
import qualified Data.Vector.Unboxed.Mutable as UnboxedMutable
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Word (Word64)
import GHC.Stats (GCDetails (gcdetails_live_bytes), RTSStats (gc), getRTSStats, getRTSStatsEnabled)
import Hetoimasia.GPU.Model.Placement
  ( Block
  , BlockUsage (..)
  , Fitted (..)
  , PlacementStrategy
  , ResourceTiling (OptimalResource)
  , blockRanges
  , blockUsage
  , openFixedBlock
  , placeInBlock
  , releaseInBlock
  , validateFit
  )
import Parity.Reference (Search (..), reconstructSearch)
import Parity.Replay (Evidence (..), Mode (..), Pass (..), sampleEvery)
import Parity.Trace (OpKind (..), Trace (..), opKind)
import Parity.Vma (probeNow)
import System.Mem (performMajorGC)

-- | What the Haskell evidence pass records beyond the shared 'Evidence'.
data HaskellEvidence = HaskellEvidence
  { haskellShared ∷ !Evidence
  , haskellSearches ∷ ![(Search, Maybe Word64)]
    -- ^ Sampled allocations: the reconstructed search, and where the
    -- implementation actually placed the request.
  , haskellFootprint ∷ ![Word64]
    -- ^ Live heap bytes above the empty block's, after a major collection,
    -- every 'footprintEvery' operations; empty when the runtime keeps no
    -- statistics.
  }

-- | At most this many allocations per trace are sampled for the search
-- reconstruction, evenly spread.
searchSamples ∷ Int
searchSamples = 2000

-- | The block's heap footprint is read every thousand operations.
footprintEvery ∷ Int
footprintEvery = 1000

-- | Replay a trace into a fresh fixed block of the given strategy.
replayHaskell ∷ PlacementStrategy → Trace → Mode → IO (Pass, Maybe HaskellEvidence)
replayHaskell strategy trace mode = do
  block0 ←
    either
      (fail . ("the trace's block was refused: " <>) . show)
      pure
      (openFixedBlock strategy (toInteger (traceCapacity trace)) 1)
  let count = Unboxed.length (traceKinds trace)
      checkpoints = length (traceCheckpoints trace)
      samples = count `div` sampleEvery
      allocations = Unboxed.length (Unboxed.filter (== 0) (traceKinds trace))
      stride = max 1 (allocations `div` searchSamples)
      evidence = case mode of EvidenceMode → True; _ → False
      (perOperation, elapsedPerOperation) = case mode of
        PerOperation vector → (True, vector)
        _ → (False, dummy)
      (bounds, elapsedIntervals) = case mode of
        Intervals boundaries vector → (boundaries, vector)
        _ → (Storable.empty, dummy)
      intervalCount = Storable.length bounds `div` 2
      dummy = error "no elapsed vector in this mode"
  -- Each identity's live offset, or -1 when it is not live here.
  live ← UnboxedMutable.replicate (max 1 (traceIdentities trace)) (-1 ∷ Int)
  placed ← UnboxedMutable.replicate (if evidence then max 1 count else 1) False
  offsets ← UnboxedMutable.replicate (if evidence then max 1 count else 1) (0 ∷ Word64)
  sampleFree ← UnboxedMutable.replicate (max 1 samples) (0 ∷ Word64)
  sampleLargest ← UnboxedMutable.replicate (max 1 samples) (0 ∷ Word64)
  checkpointFree ← UnboxedMutable.replicate (max 1 checkpoints) (0 ∷ Word64)
  checkpointLargest ← UnboxedMutable.replicate (max 1 checkpoints) (0 ∷ Word64)
  -- The search samples go into vectors allocated before the footprint's
  -- baseline is read, so recording them never counts as the block's heap.
  let searchSlots = if evidence then allocations `div` stride + 1 else 1
  examinedSlots ← UnboxedMutable.replicate searchSlots (0 ∷ Int)
  rangeSlots ← UnboxedMutable.replicate searchSlots (0 ∷ Int)
  chosenSlots ← UnboxedMutable.replicate searchSlots (noOffset ∷ Word64)
  actualSlots ← UnboxedMutable.replicate searchSlots (noOffset ∷ Word64)
  footprint ← newIORef []
  statistics ← getRTSStatsEnabled
  baseline ← if evidence && statistics then liveBytes else pure 0
  let bound k = fromIntegral (Storable.unsafeIndex bounds k) ∷ Int
      loop !i !block !checksum !placedCount !executed !timed !interval !intervalStart !allocationIndex
        | i == count = pure (Pass checksum placedCount executed timed 0 0 0)
        | otherwise = do
            start ←
              if intervalCount > interval && i == bound (2 * interval) then probeNow else pure intervalStart
            let identity = fromIntegral (traceIds trace `Unboxed.unsafeIndex` i)
                -- Every branch below ends here, in tail position, so this is a
                -- join point and the loop allocates no intermediate state.
                continue !block' !checksum' !placedCount' !executed' !timed' !allocationIndex' = do
                  (interval', timed'') ←
                    if intervalCount > interval && i + 1 == bound (2 * interval + 1)
                      then do
                        end ← probeNow
                        StorableMutable.unsafeModify elapsedIntervals (+ (end - start)) interval
                        pure (interval + 1, timed' + (end - start))
                      else pure (interval, timed')
                  when evidence $ record i block'
                  loop (i + 1) block' checksum' placedCount' executed' timed'' interval' start allocationIndex'
            case opKind (traceKinds trace `Unboxed.unsafeIndex` i) of
              Allocate → do
                let size = traceSizes trace `Unboxed.unsafeIndex` i
                    alignment = traceAlignments trace `Unboxed.unsafeIndex` i
                    sampled = evidence && allocationIndex `mod` stride == 0
                search ←
                  if sampled then Just <$> evaluate (reconstructSearch (blockRanges block) size alignment) else pure Nothing
                before ← if perOperation then probeNow else pure 0
                answer ← evaluate (placeRequest size alignment block)
                spent ←
                  if perOperation
                    then do
                      after ← probeNow
                      StorableMutable.unsafeModify elapsedPerOperation (+ (after - before)) i
                      pure (after - before)
                    else pure 0
                case answer of
                  Refused → do
                    UnboxedMutable.unsafeWrite live identity (-1)
                    mapM_ (store (allocationIndex `div` stride) noOffset) search
                    continue block checksum placedCount (executed + 1) (timed + spent) (allocationIndex + 1)
                  Fitted offset next → do
                    UnboxedMutable.unsafeWrite live identity (fromIntegral offset)
                    when evidence $ do
                      UnboxedMutable.unsafeWrite placed i True
                      UnboxedMutable.unsafeWrite offsets i offset
                    mapM_ (store (allocationIndex `div` stride) offset) search
                    continue next (checksum + offset + 1) (placedCount + 1) (executed + 1) (timed + spent) (allocationIndex + 1)
              Free → do
                offset ← UnboxedMutable.unsafeRead live identity
                if offset < 0
                  then continue block checksum placedCount executed timed allocationIndex
                  else do
                    before ← if perOperation then probeNow else pure 0
                    answer ← evaluate (releaseInBlock (fromIntegral offset) block)
                    next ← maybe (fail ("released an offset with no placement at operation " <> show i)) evaluate answer
                    spent ←
                      if perOperation
                        then do
                          after ← probeNow
                          StorableMutable.unsafeModify elapsedPerOperation (+ (after - before)) i
                          pure (after - before)
                        else pure 0
                    UnboxedMutable.unsafeWrite live identity (-1)
                    continue next checksum placedCount (executed + 1) (timed + spent) allocationIndex
              Checkpoint → do
                when evidence $ do
                  let usage = blockUsage block
                  UnboxedMutable.unsafeWrite checkpointFree identity (usageFreeBytes usage)
                  UnboxedMutable.unsafeWrite checkpointLargest identity (usageLargestFreeRange usage)
                continue block checksum placedCount executed timed allocationIndex
      store slot actual found = do
        UnboxedMutable.unsafeWrite examinedSlots slot (searchExamined found)
        UnboxedMutable.unsafeWrite rangeSlots slot (searchFreeRanges found)
        UnboxedMutable.unsafeWrite chosenSlots slot (maybe noOffset id (searchOffset found))
        UnboxedMutable.unsafeWrite actualSlots slot actual
      -- The evidence pass's samples after operation i, all outside any timing.
      record i block = do
        when ((i + 1) `mod` sampleEvery == 0) $ do
          let usage = blockUsage block
              sample = (i + 1) `div` sampleEvery - 1
          UnboxedMutable.unsafeWrite sampleFree sample (usageFreeBytes usage)
          UnboxedMutable.unsafeWrite sampleLargest sample (usageLargestFreeRange usage)
        when (statistics && (i + 1) `mod` footprintEvery == 0) $ do
          bytes ← liveBytes
          modifyIORef' footprint ((if bytes > baseline then bytes - baseline else 0) :)
          -- The block is still needed after the collection, so it was live.
          _ ← evaluate (usageLiveCount (blockUsage block))
          pure ()
  pass ← loop 0 block0 0 0 0 0 0 0 (0 ∷ Int)
  if evidence
    then do
      let frozen n vector = Unboxed.take n <$> Unboxed.freeze vector
      shared ←
        Evidence
          <$> frozen count placed
          <*> frozen count offsets
          <*> frozen samples sampleFree
          <*> frozen samples sampleLargest
          <*> frozen checkpoints checkpointFree
          <*> frozen checkpoints checkpointLargest
      let sampledCount = (allocations + stride - 1) `div` stride
          sampled = [0 .. min searchSlots sampledCount - 1]
          asOffset o = if o == noOffset then Nothing else Just o
      searched ← forM sampled $ \slot → do
        examined ← UnboxedMutable.read examinedSlots slot
        ranges ← UnboxedMutable.read rangeSlots slot
        chosen ← UnboxedMutable.read chosenSlots slot
        actual ← UnboxedMutable.read actualSlots slot
        pure (Search examined ranges (asOffset chosen), asOffset actual)
      footprinted ← reverse <$> readIORef footprint
      pure (pass, Just (HaskellEvidence shared searched footprinted))
    else pure (pass, Nothing)

-- | Marks a refusal in the search sample vectors.
noOffset ∷ Word64
noOffset = maxBound

-- | The live heap bytes after a major collection.
liveBytes ∷ IO Word64
liveBytes = do
  performMajorGC
  gcdetails_live_bytes . gc <$> getRTSStats

-- | Validate and place, as one production request would be. A trace's
-- requests were checked when it was read, so validation never refuses here.
placeRequest ∷ Word64 → Word64 → Block → Fitted
placeRequest size alignment block =
  case validateFit size alignment OptimalResource of
    Right fit → placeInBlock fit block
    Left rejection → error ("a checked trace request was rejected: " <> show rejection)
{-# NOINLINE placeRequest #-}
