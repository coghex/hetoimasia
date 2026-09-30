-- | The VMA side of the probe: the C++ shim's whole-trace replay, the clock
-- both sides read, and the layout check that holds the shim's restated VMA
-- declarations to the Hackage binding's generated ones.
module Parity.Vma
  ( probeNow
  , probeCompiler
  , clockPairNanoseconds
  , checkLayouts
  , VmaStrategy (..)
  , replayVma
  , encodeTrace
  ) where

import Control.Monad (unless, when)
import Data.Bits ((.|.))
import qualified Data.Vector.Storable as Storable
import qualified Data.Vector.Storable.Mutable as StorableMutable
import qualified Data.Vector.Unboxed as Unboxed
import Data.Word (Word32, Word64, Word8)
import Foreign.C.String (CString, peekCString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, castPtr, intPtrToPtr, plusPtr)
import Foreign.Storable (pokeByteOff)
import Parity.Replay (Evidence (..), Mode (..), Pass (..), sampleEvery)
import Parity.Trace (Trace (..))
import Vulkan.CStruct (FromCStruct (peekCStruct), ToCStruct (cStructSize, withCStruct))
import qualified VulkanMemoryAllocator as Vma

foreign import ccall unsafe "hetoimasia_probe_now"
  probeNow ∷ IO Word64

foreign import ccall unsafe "hetoimasia_probe_clock_pair"
  c_clockPair ∷ Word64 → IO Double

foreign import ccall unsafe "hetoimasia_probe_compiler"
  c_probeCompiler ∷ IO CString

foreign import ccall unsafe "hetoimasia_vma_check_block_info"
  c_checkBlockInfo ∷ Ptr Vma.VirtualBlockCreateInfo → Word64 → Word32 → Word64 → IO CInt

foreign import ccall unsafe "hetoimasia_vma_check_allocation_info"
  c_checkAllocationInfo ∷ Ptr Vma.VirtualAllocationCreateInfo → Word64 → Word64 → Word32 → Ptr () → Word64 → IO CInt

foreign import ccall unsafe "hetoimasia_vma_fill_statistics"
  c_fillStatistics ∷ Ptr Vma.DetailedStatistics → Word64 → IO Word64

-- A whole trace is one call, so a safe call's cost is paid once per replay
-- and never inside a timed interval.
foreign import ccall safe "hetoimasia_vma_replay"
  c_replay
    ∷ Word64 → Word32 → Word32 → Ptr () → Word64 → Word64
    → Ptr Word64 → Ptr Word64 → Word64 → Ptr Word8 → Ptr Word64
    → Word64 → Ptr Word64 → Ptr Word64 → Ptr Word64 → Ptr Word64 → Ptr Word64
    → IO CInt

-- | The mean cost of one empty timed interval, as the shim measures it and as
-- the Haskell side does through the same clock: what every sample of the
-- corresponding side includes beyond the operation itself.
clockPairNanoseconds ∷ Word64 → IO (Double, Double)
clockPairNanoseconds pairs = do
  shim ← c_clockPair pairs
  let go ∷ Word64 → Word64 → IO Word64
      go 0 total = pure total
      go n total = do
        start ← probeNow
        end ← probeNow
        go (n - 1) $! total + (end - start)
  haskell ← go pairs 0
  pure (fromIntegral haskell / fromIntegral (max 1 pairs), shim)

-- | The compiler the shim, and so VMA's calls into it, were built with.
probeCompiler ∷ IO String
probeCompiler = c_probeCompiler >>= peekCString

-- | Marshal each struct the shim restates through the binding's own layout
-- and have the shim read it back, and the reverse for the statistics it
-- writes. Any disagreement stops the probe before a replay.
checkLayouts ∷ IO ()
checkLayouts = do
  let blockFlags = Vma.VIRTUAL_BLOCK_CREATE_LINEAR_ALGORITHM_BIT
      Vma.VirtualBlockCreateFlagBits blockBits = blockFlags
      blockInfo = Vma.VirtualBlockCreateInfo {Vma.size = 0x0123456789ab, Vma.flags = blockFlags, Vma.allocationCallbacks = Nothing}
  blockOk ←
    withCStruct blockInfo $ \pointer →
      c_checkBlockInfo pointer 0x0123456789ab blockBits (fromIntegral (cStructSize @Vma.VirtualBlockCreateInfo))
  let allocationFlags = Vma.VIRTUAL_ALLOCATION_CREATE_STRATEGY_MIN_MEMORY_BIT .|. Vma.VIRTUAL_ALLOCATION_CREATE_UPPER_ADDRESS_BIT
      Vma.VirtualAllocationCreateFlagBits allocationBits = allocationFlags
      userData = intPtrToPtr 0x7654321
      allocationInfo =
        Vma.VirtualAllocationCreateInfo
          { Vma.size = 0x1111222233
          , Vma.alignment = 0x4000
          , Vma.flags = allocationFlags
          , Vma.userData = userData
          }
  allocationOk ←
    withCStruct allocationInfo $ \pointer →
      c_checkAllocationInfo
        pointer
        0x1111222233
        0x4000
        allocationBits
        userData
        (fromIntegral (cStructSize @Vma.VirtualAllocationCreateInfo))
  statistics ←
    allocaBytes (cStructSize @Vma.DetailedStatistics) $ \pointer → do
      size ← c_fillStatistics pointer 1000
      unless (size == fromIntegral (cStructSize @Vma.DetailedStatistics)) $
        fail ("VmaDetailedStatistics is " <> show size <> " bytes in the shim and " <> show (cStructSize @Vma.DetailedStatistics) <> " in the binding")
      peekCStruct pointer
  let Vma.DetailedStatistics
        { Vma.statistics = Vma.Statistics {Vma.blockCount, Vma.allocationCount, Vma.blockBytes, Vma.allocationBytes}
        , Vma.unusedRangeCount
        , Vma.allocationSizeMin
        , Vma.allocationSizeMax
        , Vma.unusedRangeSizeMin
        , Vma.unusedRangeSizeMax
        } = statistics
      statisticsOk =
        (blockCount, allocationCount, unusedRangeCount) == (1001, 1002, 1005)
          && (blockBytes, allocationBytes) == (1003, 1004)
          && (allocationSizeMin, allocationSizeMax, unusedRangeSizeMin, unusedRangeSizeMax) == (1006, 1007, 1008, 1009)
  when (blockOk == 0) $ fail "the shim's VmaVirtualBlockCreateInfo does not match the binding's layout"
  when (allocationOk == 0) $ fail "the shim's VmaVirtualAllocationCreateInfo does not match the binding's layout"
  unless statisticsOk $ fail ("the shim's VmaDetailedStatistics does not match the binding's layout: " <> show statistics)

-- | Which of VMA's allocation strategies every request asks for. Both run in
-- a virtual block with VMA's default (TLSF) algorithm; neither is the linear
-- algorithm or an upper-address allocation.
data VmaStrategy
  = VmaDefault
    -- ^ No strategy flag: VMA's default search, the gated baseline.
  | VmaMinMemory
    -- ^ @VMA_VIRTUAL_ALLOCATION_CREATE_STRATEGY_MIN_MEMORY_BIT@, VMA's closest
    -- analogue of best fit, reported beside the baseline and never gated.
  deriving (Eq, Show)

strategyFlags ∷ VmaStrategy → Word32
strategyFlags VmaDefault = 0
strategyFlags VmaMinMemory =
  let Vma.VirtualAllocationCreateFlagBits bits = Vma.VIRTUAL_ALLOCATION_CREATE_STRATEGY_MIN_MEMORY_BIT in bits

-- | Replay a trace into a fresh virtual block in the given mode.
replayVma ∷ VmaStrategy → Trace → Storable.Vector Word8 → Mode → IO (Pass, Maybe Evidence)
replayVma strategy trace encoded mode = do
  let count = Unboxed.length (traceKinds trace)
      checkpoints = length (traceCheckpoints trace)
      samples = count `div` sampleEvery
  placed ← StorableMutable.replicate (max 1 count) 0
  offsets ← StorableMutable.replicate (max 1 count) 0
  sampleFree ← StorableMutable.replicate (max 1 samples) 0
  sampleLargest ← StorableMutable.replicate (max 1 samples) 0
  checkpointFree ← StorableMutable.replicate (max 1 checkpoints) 0
  checkpointLargest ← StorableMutable.replicate (max 1 checkpoints) 0
  summary ← StorableMutable.replicate 7 0
  unused ← StorableMutable.replicate 1 0
  let noBounds = Storable.singleton 0
      (modeCode, elapsed, bounds, intervals) = case mode of
        EvidenceMode → (0, unused, noBounds, 0)
        PerOperation vector → (1, vector, noBounds, 0)
        Intervals boundaries vector → (2, vector, boundaries, Storable.length boundaries `div` 2)
        HeapCount → (3, unused, noBounds, 0)
  result ←
    Storable.unsafeWith encoded $ \ops →
      Storable.unsafeWith bounds $ \boundsPointer →
        StorableMutable.unsafeWith elapsed $ \elapsedPointer →
          StorableMutable.unsafeWith placed $ \placedPointer →
            StorableMutable.unsafeWith offsets $ \offsetPointer →
              StorableMutable.unsafeWith sampleFree $ \sampleFreePointer →
                StorableMutable.unsafeWith sampleLargest $ \sampleLargestPointer →
                  StorableMutable.unsafeWith checkpointFree $ \checkpointFreePointer →
                    StorableMutable.unsafeWith checkpointLargest $ \checkpointLargestPointer →
                      StorableMutable.unsafeWith summary $ \summaryPointer →
                        c_replay
                          (traceCapacity trace)
                          (strategyFlags strategy)
                          modeCode
                          (castPtr ops)
                          (fromIntegral count)
                          (fromIntegral (traceIdentities trace))
                          elapsedPointer
                          boundsPointer
                          (fromIntegral intervals)
                          placedPointer
                          offsetPointer
                          (fromIntegral sampleEvery)
                          sampleFreePointer
                          sampleLargestPointer
                          checkpointFreePointer
                          checkpointLargestPointer
                          summaryPointer
  unless (result == 0) $ fail ("the VMA replay failed with " <> show result)
  [checksum, placedCount, executed, timed, calls, bytes, peak] ← Storable.toList <$> Storable.freeze summary
  let pass = Pass checksum placedCount executed timed calls bytes peak
      frozen n vector = Unboxed.fromList . Storable.toList . Storable.take n <$> Storable.freeze vector
  case mode of
    EvidenceMode → do
      placed' ← frozen count placed
      offsets' ← frozen count offsets
      sampleFree' ← frozen samples sampleFree
      sampleLargest' ← frozen samples sampleLargest
      checkpointFree' ← frozen checkpoints checkpointFree
      checkpointLargest' ← frozen checkpoints checkpointLargest
      pure
        ( pass
        , Just
            Evidence
              { evidencePlaced = Unboxed.map (== 1) placed'
              , evidenceOffsets = offsets'
              , evidenceSampleFree = sampleFree'
              , evidenceSampleLargest = sampleLargest'
              , evidenceCheckpointFree = checkpointFree'
              , evidenceCheckpointLargest = checkpointLargest'
              }
        )
    _ → pure (pass, Nothing)

-- | The trace as the shim reads it: one 24-byte @hetoimasia_trace_op@ per
-- operation — kind and identity as 32-bit words, then size and alignment as
-- 64-bit ones. Encoded once per trace, before any replay.
encodeTrace ∷ Trace → IO (Storable.Vector Word8)
encodeTrace trace = do
  let count = Unboxed.length (traceKinds trace)
  buffer ← StorableMutable.replicate (max 1 count * opBytes) 0
  StorableMutable.unsafeWith buffer $ \pointer →
    Unboxed.forM_ (Unboxed.enumFromN 0 count) $ \i → do
      let at = pointer `plusPtr` (i * opBytes)
      pokeByteOff at 0 (traceKinds trace Unboxed.! i)
      pokeByteOff at 4 (traceIds trace Unboxed.! i)
      pokeByteOff at 8 (traceSizes trace Unboxed.! i)
      pokeByteOff at 16 (traceAlignments trace Unboxed.! i)
  Storable.freeze buffer
  where
    opBytes = 24
