{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}

-- | GRS-18's completion-deferred free (D-39): a trace replayed in batches
-- that the GPU actually executes, where every resource is used by the batch
-- that creates it and by the batch that frees it, and its free waits until
-- that batch's fence has signalled — as the model will defer frees.
--
-- Batches of 'batchOperations' trace operations are recorded into one of
-- 'inFlight' command buffers and submitted with that slot's fence. A
-- resource's use is a transfer command: geometry and readback buffers are
-- filled, staging buffers are copied into a scratch buffer, each copy into
-- its own region. Every command buffer begins with one transfer-to-transfer
-- memory barrier, which orders it after every earlier batch's transfers.
-- Before a slot is reused its fence is waited on, and only then are the
-- frees that batch deferred destroyed. Each destroy first checks that the
-- fence of the batch that last used the resource is signalled and still that
-- batch's; one that is not is an early free, and any early free makes the
-- run invalid. The correctness pass runs on a validating device, where the
-- layer's own lifetime checks and synchronization validation watch the same
-- frees.
--
-- It runs in any Haskell configuration: allocation follows D-40 and every
-- creation and destroy goes through that configuration's API, with its
-- callbacks, exactly as in the trace replays.
module Production.Deferred
  ( DeferredRun (..)
  , runDeferred
  , batchOperations
  , inFlight
  ) where

import Control.Exception (bracket)
import Control.Monad (forM_, unless, when)
import Data.Bits ((.|.))
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.IntMap.Strict as IntMap
import qualified Data.Vector as Vector
import qualified Data.Vector.Storable.Mutable as StorableMutable
import qualified Data.Vector.Unboxed as Unboxed
import Data.Word (Word64, Word8)
import Foreign.Marshal.Alloc (callocBytes, free)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peekByteOff)
import Production.Device (Device (..))
import Production.Driver
  ( Api (..)
  , CallSafety (..)
  , Configuration (..)
  , Driver (..)
  , Session (..)
  , allocatorCreateInfo
  , callbacksFor
  , hackageApi
  , prepare
  , probeNow
  , safeDestroyAllocator
  , shimApi
  , shimResultBytes
  )
import Production.Script
import Vulkan.CStruct.Extends (SomeStruct (..))
import qualified Vulkan.Core10 as Vk
import Vulkan.Zero (zero)
import qualified VulkanMemoryAllocator as Vma

-- | Trace operations per batch.
batchOperations ∷ Int
batchOperations = 64

-- | Batches in flight: a slot's fence is waited on only when it is reused.
inFlight ∷ Int
inFlight = 3

-- | One deferred-free pass.
data DeferredRun = DeferredRun
  { deferredBatches ∷ !Int
  , deferredCreates ∷ !Word64
  , deferredDestroys ∷ !Word64
  , deferredEarly ∷ !Word64
    -- ^ Destroys whose last-use batch's fence was not observed signalled.
  , deferredFailures ∷ !Word64
  , deferredPendingPeak ∷ !Int
    -- ^ The most frees waiting at once.
  , deferredPendingMean ∷ !Double
    -- ^ Frees waiting, averaged over the batches.
  , deferredWholeNanoseconds ∷ !Word64
  , deferredAllocateNanoseconds ∷ !Word64
  , deferredRecordNanoseconds ∷ !Word64
    -- ^ Recording and submitting, the command buffer's reset included.
  , deferredWaitNanoseconds ∷ !Word64
  , deferredDrainNanoseconds ∷ !Word64
    -- ^ Draining the frees a waited batch released, destroys included.
  , deferredDestroyNanoseconds ∷ !Word64
    -- ^ The destroy calls alone.
  , deferredDestroySamples ∷ ![Word64]
    -- ^ Each destroy's nanoseconds, by trace operation.
  , deferredOpened ∷ !Word64
  , deferredFreedBlocks ∷ !Word64
  }

data Pending = Pending
  { pendingOperation ∷ !Int
  , pendingBuffer ∷ !Word64
  , pendingAllocation ∷ !Word64
  , pendingBatch ∷ !Int
  }

-- | Replay a buffer script in GPU-executed batches with deferred frees, in
-- one Haskell configuration.
runDeferred ∷ Session → Configuration → Script → IO DeferredRun
runDeferred session configuration script =
  bracket (callocBytes shimResultBytes) free $ \out → case configurationDriver configuration of
    DriverHackage → deferredWith (hackageApi out) out session configuration script
    DriverShim UnsafeCalls → deferredWith (shimApi UnsafeCalls out) out session configuration script
    DriverShim SafeCalls → deferredWith (shimApi SafeCalls out) out session configuration script
    DriverC → fail "the deferred-free workload runs from Haskell"

{-# INLINE deferredWith #-}
deferredWith ∷ Api → Ptr Word8 → Session → Configuration → Script → IO DeferredRun
deferredWith api out session configuration script =
  bracket (callocBytes 80) free $ \counters →
    bracket (Vma.createAllocator (allocatorCreateInfo device onAllocate onFree (castPtr counters))) safeDestroyAllocator $ \allocator →
      bracket (Vk.createCommandPool logical poolInfo Nothing) (\pool → Vk.destroyCommandPool logical pool Nothing) $ \pool → do
        commandBuffers ←
          Vk.allocateCommandBuffers logical (Vk.CommandBufferAllocateInfo pool Vk.COMMAND_BUFFER_LEVEL_PRIMARY (fromIntegral inFlight))
        fences ← Vector.replicateM inFlight (Vk.createFence logical (Vk.FenceCreateInfo {Vk.next = (), Vk.flags = zero} ∷ Vk.FenceCreateInfo '[]) Nothing)
        geometry ← case [c | c ← Vector.toList classes, specName (classSpec c) == "geometry"] of
          c : _ → pure c
          [] → fail "no geometry class"
        let scratchBytes = max (64 * 1024) (scratchNeeded script)
        scratchResult ← apiCreateBuffer api allocator (prepare geometry) scratchBytes False
        unless (scratchResult == 0) $ fail ("the scratch buffer failed with " <> show scratchResult)
        scratchHandle ← peekByteOff out 0 ∷ IO Word64
        scratchAllocation ← peekByteOff out 8 ∷ IO Word64
        result ← replay allocator (Vector.toList commandBuffers) fences (Vk.Buffer scratchHandle)
        apiDestroyBuffer api allocator scratchHandle scratchAllocation
        Vector.mapM_ (\f → Vk.destroyFence logical f Nothing) fences
        Vk.freeCommandBuffers logical pool commandBuffers
        opened ← peekCounter counters 0
        freedBlocks ← peekCounter counters 16
        pure result {deferredOpened = opened, deferredFreedBlocks = freedBlocks}
  where
    device = sessionDevice session
    (onAllocate, onFree) = callbacksFor session configuration
    classes = scriptClasses script
    prepared = Vector.map prepare classes
    logical = deviceVulkan device
    poolInfo =
      Vk.CommandPoolCreateInfo {Vk.next = (), Vk.flags = Vk.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, Vk.queueFamilyIndex = deviceQueueFamily device}
        ∷ Vk.CommandPoolCreateInfo '[]
    count = Unboxed.length (scriptKinds script)
    batches = (count + batchOperations - 1) `div` batchOperations
    classIndexOf i = fromIntegral (scriptClassIndices script Unboxed.! i)
    replay allocator commandBuffers fences scratch = do
      -- Each live resource, with the batch that last used it.
      live ← newIORef (IntMap.empty ∷ IntMap.IntMap (Word64, Word64, ResourceClass, Word64, Int))
      pending ← newIORef (IntMap.empty ∷ IntMap.IntMap [Pending])
      slotBatch ← StorableMutable.replicate inFlight (-1 ∷ Int)
      destroySamples ← StorableMutable.replicate (max 1 count) (0 ∷ Word64)
      totals ← newIORef (0, 0, 0, 0, 0, 0 ∷ Word64)
      tallies ← newIORef (0, 0, 0, 0 ∷ Word64)
      pendingStats ← newIORef (0 ∷ Int, 0 ∷ Int)
      let addTime (k ∷ Int) by = modifyIORef' totals $ \(a, r, w, d, x, y) → case k of
            0 → (a + by, r, w, d, x, y)
            1 → (a, r + by, w, d, x, y)
            2 → (a, r, w + by, d, x, y)
            3 → (a, r, w, d + by, x, y)
            _ → (a, r, w, d, x + by, y)
          tally (k ∷ Int) = modifyIORef' tallies $ \(c, d, e, f) → case k of
            0 → (c + 1, d, e, f)
            1 → (c, d + 1, e, f)
            2 → (c, d, e + 1, f)
            _ → (c, d, e, f + 1)
          drain batch = do
            waiting ← readIORef pending
            let released = IntMap.findWithDefault [] batch waiting
            writeIORef pending (IntMap.delete batch waiting)
            forM_ released $ \p → do
              let slot = pendingBatch p `mod` inFlight
              owner ← StorableMutable.read slotBatch slot
              status ← Vk.getFenceStatus logical (fences Vector.! slot)
              unless (owner == pendingBatch p && status == Vk.SUCCESS) $ tally 2
              start ← probeNow
              apiDestroyBuffer api allocator (pendingBuffer p) (pendingAllocation p)
              end ← probeNow
              StorableMutable.write destroySamples (pendingOperation p) (end - start)
              addTime 4 (end - start)
              tally 1
          use commandBuffer scratchOffset handle resourceClass size =
            if specUsage (classSpec resourceClass) == 0x1
              then do
                Vk.cmdCopyBuffer commandBuffer (Vk.Buffer handle) scratch (Vector.singleton (Vk.BufferCopy 0 scratchOffset size))
                pure (scratchOffset + roundUp size)
              else do
                Vk.cmdFillBuffer commandBuffer (Vk.Buffer handle) 0 Vk.WHOLE_SIZE 0
                pure scratchOffset
      wholeStart ← probeNow
      forM_ [0 .. batches - 1] $ \batch → do
        let slot = batch `mod` inFlight
            commandBuffer = commandBuffers !! slot
            fence = fences Vector.! slot
        when (batch >= inFlight) $ do
          waitStart ← probeNow
          _ ← Vk.waitForFences logical (Vector.singleton fence) True maxBound
          waitEnd ← probeNow
          addTime 2 (waitEnd - waitStart)
          drain (batch - inFlight)
          drainEnd ← probeNow
          addTime 3 (drainEnd - waitEnd)
        recordStart ← probeNow
        Vk.resetFences logical (Vector.singleton fence)
        Vk.resetCommandBuffer commandBuffer zero
        Vk.beginCommandBuffer commandBuffer (Vk.CommandBufferBeginInfo () Vk.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT Nothing ∷ Vk.CommandBufferBeginInfo '[])
        Vk.cmdPipelineBarrier
          commandBuffer
          Vk.PIPELINE_STAGE_TRANSFER_BIT
          Vk.PIPELINE_STAGE_TRANSFER_BIT
          zero
          (Vector.singleton (Vk.MemoryBarrier Vk.ACCESS_TRANSFER_WRITE_BIT (Vk.ACCESS_TRANSFER_READ_BIT .|. Vk.ACCESS_TRANSFER_WRITE_BIT)))
          Vector.empty
          Vector.empty
        recordPause ← probeNow
        addTime 1 (recordPause - recordStart)
        offset ← newIORef (0 ∷ Word64)
        forM_ [batch * batchOperations .. min count ((batch + 1) * batchOperations) - 1] $ \i →
          case opCode (scriptKinds script Unboxed.! i) of
            CreateD40 → do
              let resourceClass = classes Vector.! classIndexOf i
                  spec = prepared Vector.! classIndexOf i
                  size = scriptSizes script Unboxed.! i
              start ← probeNow
              placed ← apiCreateBuffer api allocator spec size True
              created ← if placed == 0 then pure placed else apiCreateBuffer api allocator spec size False
              end ← probeNow
              addTime 0 (end - start)
              if created /= 0
                then tally 3
                else do
                  buffer ← peekByteOff out 0 ∷ IO Word64
                  allocation ← peekByteOff out 8 ∷ IO Word64
                  tally 0
                  modifyIORef' live (IntMap.insert (fromIntegral (scriptIds script Unboxed.! i)) (buffer, allocation, resourceClass, size, batch))
                  readIORef offset >>= \o → use commandBuffer o buffer resourceClass size >>= writeIORef offset
            Destroy → do
              let identity = fromIntegral (scriptIds script Unboxed.! i)
              resources ← readIORef live
              case IntMap.lookup identity resources of
                Nothing → pure ()
                Just (buffer, allocation, resourceClass, size, lastUse) → do
                  writeIORef live (IntMap.delete identity resources)
                  -- The batch that frees it uses it, once: a resource this
                  -- batch created is already used by it.
                  unless (lastUse == batch) $
                    readIORef offset >>= \o → use commandBuffer o buffer resourceClass size >>= writeIORef offset
                  modifyIORef' pending (IntMap.insertWith (<>) batch [Pending i buffer allocation batch])
            _ → pure ()
        submitStart ← probeNow
        Vk.endCommandBuffer commandBuffer
        Vk.queueSubmit
          (deviceQueue device)
          (Vector.singleton (SomeStruct (Vk.SubmitInfo () Vector.empty Vector.empty (Vector.singleton (Vk.commandBufferHandle commandBuffer)) Vector.empty ∷ Vk.SubmitInfo '[])))
          fence
        StorableMutable.write slotBatch slot batch
        submitEnd ← probeNow
        addTime 1 (submitEnd - submitStart)
        waiting ← sum . map length . IntMap.elems <$> readIORef pending
        modifyIORef' pendingStats $ \(peak, total) → (max peak waiting, total + waiting)
      -- The last batches: wait for each in submission order, then drain it.
      forM_ [max 0 (batches - inFlight) .. batches - 1] $ \batch → do
        let fence = fences Vector.! (batch `mod` inFlight)
        waitStart ← probeNow
        _ ← Vk.waitForFences logical (Vector.singleton fence) True maxBound
        waitEnd ← probeNow
        addTime 2 (waitEnd - waitStart)
        drain batch
        drainEnd ← probeNow
        addTime 3 (drainEnd - waitEnd)
      wholeEnd ← probeNow
      -- Whatever the trace left live was never freed by it; free it untimed.
      remaining ← readIORef live
      forM_ (IntMap.elems remaining) $ \(buffer, allocation, _, _, _) → apiDestroyBuffer api allocator buffer allocation
      (allocateTime, recordTime, waitTime, drainTime, destroyTime, _) ← readIORef totals
      (creates, destroys, early, failures) ← readIORef tallies
      (peak, total) ← readIORef pendingStats
      samples ← mapM (StorableMutable.read destroySamples) [i | i ← [0 .. count - 1], opCode (scriptKinds script Unboxed.! i) == Destroy]
      pure
        DeferredRun
          { deferredBatches = batches
          , deferredCreates = creates
          , deferredDestroys = destroys
          , deferredEarly = early
          , deferredFailures = failures
          , deferredPendingPeak = peak
          , deferredPendingMean = fromIntegral total / fromIntegral (max 1 batches)
          , deferredWholeNanoseconds = wholeEnd - wholeStart
          , deferredAllocateNanoseconds = allocateTime
          , deferredRecordNanoseconds = recordTime
          , deferredWaitNanoseconds = waitTime
          , deferredDrainNanoseconds = drainTime
          , deferredDestroyNanoseconds = destroyTime
          , deferredDestroySamples = samples
          , deferredOpened = 0
          , deferredFreedBlocks = 0
          }

peekCounter ∷ Ptr a → Int → IO Word64
peekCounter = peekByteOff

roundUp ∷ Word64 → Word64
roundUp size = ((size + 255) `div` 256) * 256

-- | The scratch bytes the busiest batch copies, each copy in its own region.
scratchNeeded ∷ Script → Word64
scratchNeeded script =
  maximum
    ( 0
        : [ sum
              [ roundUp (sizeOf identity)
              | i ← [b * batchOperations .. min count ((b + 1) * batchOperations) - 1]
              , let identity = scriptIds script Unboxed.! i
              , opCode (scriptKinds script Unboxed.! i) `elem` [CreateD40, Destroy]
              , isStaging identity
              ]
          | b ← [0 .. (count - 1) `div` batchOperations]
          ]
    )
  where
    count = Unboxed.length (scriptKinds script)
    creations =
      IntMap.fromList
        [ (fromIntegral (scriptIds script Unboxed.! i), i)
        | i ← [0 .. count - 1]
        , opCode (scriptKinds script Unboxed.! i) == CreateD40
        ]
    creationOf identity = creations IntMap.! fromIntegral identity
    sizeOf identity = scriptSizes script Unboxed.! creationOf identity
    isStaging identity =
      specUsage (classSpec (scriptClasses script Vector.! fromIntegral (scriptClassIndices script Unboxed.! creationOf identity))) == 0x1
