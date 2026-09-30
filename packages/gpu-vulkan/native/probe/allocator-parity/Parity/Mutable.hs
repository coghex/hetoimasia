{-# LANGUAGE BangPatterns #-}

-- | The mutable prototype's side of the probe: a trace replayed into one
-- 'MutableBlock', owned by the probe's thread and driven through 'stToIO'.
--
-- The modes, the checksum, the forcing and the evidence are those of
-- "Parity.Haskell", so every figure compares like with like. Each placement or
-- release runs to completion inside its 'ST' action; the answer is forced with
-- 'evaluate' as well, so the timed interval holds all of its work.
module Parity.Mutable
  ( MutableEvidence (..)
  , replayMutable
  ) where

import Control.Exception (evaluate)
import Control.Monad (when)
import Control.Monad.ST (stToIO)
import Data.IORef (modifyIORef', newIORef, readIORef)
import qualified Data.Vector.Storable as Storable
import qualified Data.Vector.Storable.Mutable as StorableMutable
import qualified Data.Vector.Unboxed as Unboxed
import qualified Data.Vector.Unboxed.Mutable as UnboxedMutable
import Data.Word (Word64)
import GHC.Stats (GCDetails (gcdetails_live_bytes), RTSStats (gc), getRTSStats, getRTSStatsEnabled)
import Hetoimasia.GPU.Model.Placement (BlockUsage (..), ResourceTiling (OptimalResource))
import Parity.Replay (Evidence (..), Mode (..), Pass (..), sampleEvery)
import Parity.Trace (OpKind (..), Trace (..), opKind)
import Parity.Vma (probeNow)
import Prototype.MutableBestFit
import System.Mem (performMajorGC)

-- | What the prototype's evidence pass records beyond the shared 'Evidence'.
data MutableEvidence = MutableEvidence
  { mutableShared ∷ !Evidence
  , mutableFootprint ∷ ![Word64]
    -- ^ Live heap above the empty block after a major collection, every
    -- thousand operations.
  , mutableWalk ∷ !Int
    -- ^ The deepest treap path any insertion took.
  }

replayMutable ∷ Trace → Mode → IO (Pass, Maybe MutableEvidence)
replayMutable trace mode = do
  opened ← stToIO (newMutableBlock (toInteger (traceCapacity trace)) 1)
  block ← either (fail . ("the trace's block was refused: " <>) . show) pure opened
  let count = Unboxed.length (traceKinds trace)
      checkpoints = length (traceCheckpoints trace)
      samples = count `div` sampleEvery
      evidence = case mode of EvidenceMode → True; _ → False
      (perOperation, elapsedPerOperation) = case mode of
        PerOperation vector → (True, vector)
        _ → (False, dummy)
      (bounds, elapsedIntervals) = case mode of
        Intervals boundaries vector → (boundaries, vector)
        _ → (Storable.empty, dummy)
      intervalCount = Storable.length bounds `div` 2
      dummy = error "no elapsed vector in this mode"
      identities = max 1 (traceIdentities trace)
  -- Each identity's live handle: its slot, or -1, and its generation.
  liveSlot ← UnboxedMutable.replicate identities (-1 ∷ Int)
  liveGeneration ← UnboxedMutable.replicate identities (0 ∷ Int)
  placed ← UnboxedMutable.replicate (if evidence then max 1 count else 1) False
  offsets ← UnboxedMutable.replicate (if evidence then max 1 count else 1) (0 ∷ Word64)
  sampleFree ← UnboxedMutable.replicate (max 1 samples) (0 ∷ Word64)
  sampleLargest ← UnboxedMutable.replicate (max 1 samples) (0 ∷ Word64)
  checkpointFree ← UnboxedMutable.replicate (max 1 checkpoints) (0 ∷ Word64)
  checkpointLargest ← UnboxedMutable.replicate (max 1 checkpoints) (0 ∷ Word64)
  footprint ← newIORef []
  statistics ← getRTSStatsEnabled
  baseline ← if evidence && statistics then liveBytes else pure 0
  let bound k = fromIntegral (Storable.unsafeIndex bounds k) ∷ Int
      loop !i !checksum !placedCount !executed !timed !interval !intervalStart
        | i == count = pure (Pass checksum placedCount executed timed 0 0 0)
        | otherwise = do
            start ←
              if intervalCount > interval && i == bound (2 * interval) then probeNow else pure intervalStart
            let identity = fromIntegral (traceIds trace `Unboxed.unsafeIndex` i)
                continue !checksum' !placedCount' !executed' !timed' = do
                  (interval', timed'') ←
                    if intervalCount > interval && i + 1 == bound (2 * interval + 1)
                      then do
                        end ← probeNow
                        StorableMutable.unsafeModify elapsedIntervals (+ (end - start)) interval
                        pure (interval + 1, timed' + (end - start))
                      else pure (interval, timed')
                  when evidence $ record i
                  loop (i + 1) checksum' placedCount' executed' timed'' interval' start
            case opKind (traceKinds trace `Unboxed.unsafeIndex` i) of
              Allocate → do
                let size = traceSizes trace `Unboxed.unsafeIndex` i
                    alignment = traceAlignments trace `Unboxed.unsafeIndex` i
                before ← if perOperation then probeNow else pure 0
                answer ← stToIO (placeMutable block size alignment OptimalResource) >>= evaluate
                spent ←
                  if perOperation
                    then do
                      after ← probeNow
                      StorableMutable.unsafeModify elapsedPerOperation (+ (after - before)) i
                      pure (after - before)
                    else pure 0
                case answer of
                  MutablePlaced (Allocation slot generation offset) → do
                    UnboxedMutable.unsafeWrite liveSlot identity slot
                    UnboxedMutable.unsafeWrite liveGeneration identity generation
                    when evidence $ do
                      UnboxedMutable.unsafeWrite placed i True
                      UnboxedMutable.unsafeWrite offsets i offset
                    continue (checksum + offset + 1) (placedCount + 1) (executed + 1) (timed + spent)
                  MutableRefused → do
                    UnboxedMutable.unsafeWrite liveSlot identity (-1)
                    continue checksum placedCount (executed + 1) (timed + spent)
                  MutableInvalid rejection → fail ("a checked trace request was rejected: " <> show rejection)
              Free → do
                slot ← UnboxedMutable.unsafeRead liveSlot identity
                if slot < 0
                  then continue checksum placedCount executed timed
                  else do
                    generation ← UnboxedMutable.unsafeRead liveGeneration identity
                    before ← if perOperation then probeNow else pure 0
                    released ← stToIO (releaseMutable block (Allocation slot generation 0)) >>= evaluate
                    spent ←
                      if perOperation
                        then do
                          after ← probeNow
                          StorableMutable.unsafeModify elapsedPerOperation (+ (after - before)) i
                          pure (after - before)
                        else pure 0
                    when (not released) $ fail ("the prototype refused a live handle at operation " <> show i)
                    UnboxedMutable.unsafeWrite liveSlot identity (-1)
                    continue checksum placedCount (executed + 1) (timed + spent)
              Checkpoint → do
                when evidence $ do
                  usage ← stToIO (mutableUsage block)
                  UnboxedMutable.unsafeWrite checkpointFree identity (usageFreeBytes usage)
                  UnboxedMutable.unsafeWrite checkpointLargest identity (usageLargestFreeRange usage)
                continue checksum placedCount executed timed
      record i = do
        when ((i + 1) `mod` sampleEvery == 0) $ do
          usage ← stToIO (mutableUsage block)
          let sample = (i + 1) `div` sampleEvery - 1
          UnboxedMutable.unsafeWrite sampleFree sample (usageFreeBytes usage)
          UnboxedMutable.unsafeWrite sampleLargest sample (usageLargestFreeRange usage)
        when (statistics && (i + 1) `mod` 1000 == 0) $ do
          bytes ← liveBytes
          modifyIORef' footprint ((if bytes > baseline then bytes - baseline else 0) :)
  pass ← loop 0 0 0 0 0 0 0
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
      footprinted ← reverse <$> readIORef footprint
      walk ← stToIO (mutableDeepestPath block)
      -- The block is used after the last footprint reading, so it was live
      -- through every collection that measured it.
      _ ← stToIO (mutableUsage block) >>= evaluate
      pure (pass, Just (MutableEvidence shared footprinted walk))
    else pure (pass, Nothing)

liveBytes ∷ IO Word64
liveBytes = do
  performMajorGC
  gcdetails_live_bytes . gc <$> getRTSStats
