-- | The device-memory allocator beneath the model's accounting (GRS-11,
-- D-38, D-40), over the stand-in allocator: the engine's choice of memory
-- type, placement in held memory before anything may open, the bounded
-- reservation and its reconciliation, charges that follow blocks rather than
-- resources, failure cleanup, mapping, recovery, and the allocator's own
-- lifetime between the device's creation and its destruction.
--
-- Readback buffers are the allocator's one consumer, so every example makes
-- memory through 'createReadback' on a surface-free device. Nothing here
-- creates a Vulkan object.
module Test.GPU.Vulkan.Native.Allocation (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (Exception, fromException, try)
import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.ByteString as ByteString
import Data.Maybe (isNothing)
import Data.Text (Text)
import Hetoimasia.GPU.Model.Identity (Misuse (SessionAlreadyFailed))
import Hetoimasia.GPU.Vulkan.Native.Allocator.Vulkan (creationAnswer)
import Vulkan.Core10.Enums.Result (Result (..))
import Vulkan.Exception (VulkanException (..))
import Data.Word (Word32, Word64, Word8)
import Numeric.Natural (Natural)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

import Hetoimasia.Foundation.Time (DurationRequirement (AllowZero), Instant, durationFromNanoseconds, scriptedInstant)
import Hetoimasia.GPU.Model (GpuModel, SessionFailureCause (..), SessionState (..), Usage (..), sessionState, usage)
import Hetoimasia.GPU.Model.Budget (BudgetKind (ByteBudget), BudgetRequest (..), Budgets, defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Vulkan.Native.Allocator
import Hetoimasia.GPU.Vulkan.Native.Generations (newGenerations)
import Hetoimasia.GPU.Vulkan.Native.Naming (readbackBufferName)
import Hetoimasia.GPU.Vulkan.Native.Recording
import Hetoimasia.GPU.Vulkan.Native.Roots
import Test.GPU.Vulkan.Native.AllocatorStandIn
import Test.GPU.Vulkan.Native.RecordingStandIn (newRecordingStandIn, recordingStandInOps)
import Test.GPU.Vulkan.Native.StandIn (Call (..), Scripted (..), StandIn (standAllocator), StandInFailure (..), StandInRoots, Step (..), calls, newStandIn, newStandInRoots, script, standardRequest)

spec ∷ Spec
spec = describe "Allocator" $ do
  describe "the native input" $
    it "builds against the VMA 3.3.0 header docs/toolchain.md pins, unchanged" $ do
      header ← ByteString.readFile "vendor/vma/vk_mem_alloc.h"
      concatMap byteHex (ByteString.unpack (SHA256.hash header)) `shouldBe` "90ce12fc4a2466235a09ae02905dd0c13aee80c1bbf11b331ab61230c2ceb112"
      header `shouldSatisfy` ByteString.isInfixOf "<b>Version 3.3.0</b>"

  describe "memory types" $ do
    it "chooses, from the types a buffer allows, one with every required property and the most preferred" $ do
      let chosen kind allowed = offerTypeIndex <$> chooseMemoryType kind allowed standInMemoryTypes
      chosen UsageReadback 0xF `shouldBe` Right hostCachedType
      chosen UsageReadback (bit deviceLocalType + bit nonCoherentType) `shouldBe` Right nonCoherentType
      chosen UsageStaging 0xF `shouldBe` Right hostCoherentType
      chosen UsageFrameRing (bit nonCoherentType) `shouldBe` Right nonCoherentType
      chosen UsageTexture 0xF `shouldBe` Right deviceLocalType
      chosen UsageStaticGeometry 0xF `shouldBe` Right deviceLocalType
      chosen UsageTexture (bit hostCoherentType) `shouldBe` Left (MemoryTypeRefused UsageTexture (bit hostCoherentType))

    it "reads VMA's answers to a placement in held memory as a miss, and an allocating call's as failures" $ do
      let answer placement result = creationAnswer placement (case result of Result code → code)
          missed = \case
            Just NotPlaced → True
            _ → False
          outOfMemory = \case
            Just (CreationFailed failure) → fromException failure == Just (VulkanException ERROR_OUT_OF_DEVICE_MEMORY)
            _ → False
      answer InHeldMemory SUCCESS `shouldSatisfy` isNothing
      -- A driver-required dedication cannot be placed in held memory.
      answer InHeldMemory ERROR_FEATURE_NOT_PRESENT `shouldSatisfy` missed
      answer InHeldMemory ERROR_OUT_OF_DEVICE_MEMORY `shouldSatisfy` missed
      answer InHeldMemory ERROR_OUT_OF_HOST_MEMORY `shouldSatisfy` (not . missed)
      answer MayOpenMemory ERROR_OUT_OF_DEVICE_MEMORY `shouldSatisfy` outOfMemory
      answer MayOpenMemory ERROR_FEATURE_NOT_PRESENT `shouldSatisfy` (not . missed)

    it "computes the preferred block size as VMA does, and bounds a reservation by it or the request" $ do
      preferredBlockSize (512 * mebibyte) `shouldBe` 64 * mebibyte
      preferredBlockSize (64 * 1024 * mebibyte) `shouldBe` 256 * mebibyte
      preferredBlockSize 1000 `shouldBe` 128
      reservationBound (MemoryTypeOffer 0 [] (64 * mebibyte)) mebibyte `shouldBe` 64 * mebibyte
      reservationBound (MemoryTypeOffer 0 [] (64 * mebibyte)) (100 * mebibyte) `shouldBe` 100 * mebibyte

    it "refuses a usage no type the buffer allows can serve, naming the usage, before any allocation" $ do
      rig ← newRig defaultBudgetRequest
      allowTypes (rigAllocator rig) (bit deviceLocalType)
      createReadback (rigRecording rig) 1024 `shouldReturn` Left (RefusedNoMemoryType UsageReadback)
      placements rig `shouldReturn` []
      (usageBytes &&& usageObjects) <$> usageOf rig `shouldReturn` (0, 0)

    it "gives the allocator only the type it chose, in every call" $ do
      rig ← newRig defaultBudgetRequest
      _ ← readbackOf rig 1024
      map (\(_, kind, _) → kind) <$> placements rig `shouldReturn` [hostCachedType, hostCachedType]

  describe "accounting" $ do
    it "makes a readback's memory in held memory first, then by an allocating call charged as the block it opened" $ do
      rig ← newRig defaultBudgetRequest
      readback ← readbackOf rig 1024
      allocatorCalls (rigAllocator rig) `shouldReturn'` \journal → do
        take 4 journal `shouldBe` [AskedRequirements 1024, Placing 1024 hostCachedType InHeldMemory, Placing 1024 hostCachedType MayOpenMemory, OpenedMemory 700 hostCachedType standInBlockSize False]
        [() | MadeBuffer {} ← journal] `shouldBe` [()]
        [() | Mapped _ ← journal] `shouldBe` [()]
        -- The allocation is named inside the allocator whether or not the
        -- device offers naming.
        [name | NamedAllocation _ name ← journal] `shouldBe` [readbackBufferName (managedResource readback)]
      use ← usageOf rig
      (usageBytes use, usageDeviceMemory use, usageObjects use) `shouldBe` (standInBlockSize, standInBlockSize, 2)
      readReadback (rigRecording rig) readback 0 4 `shouldReturn` Left (RefusedNotWritten "nothing has written the buffer")

    it "places a second readback in held memory, opening and charging nothing new" $ do
      rig ← newRig defaultBudgetRequest
      _ ← readbackOf rig 1024
      before ← length <$> allocatorCalls (rigAllocator rig)
      _ ← readbackOf rig 2048
      drop before <$> allocatorCalls (rigAllocator rig) `shouldReturn'` \journal → do
        [placement | Placing _ _ placement ← journal] `shouldBe` [InHeldMemory]
        [() | OpenedMemory {} ← journal] `shouldBe` []
      (usageBytes &&& usageObjects) <$> usageOf rig `shouldReturn` (standInBlockSize, 4)

    it "answers backpressure from the bounded reservation before any call that could open memory, and starts no recovery" $ do
      rig ← newRig defaultBudgetRequest {requestedBytes = fromIntegral standInBlockSize - 1}
      createReadback (rigRecording rig) 1024 `shouldReturn` Left (RefusedBackpressure ByteBudget)
      map (\(_, _, placement) → placement) <$> placements rig `shouldReturn` [InHeldMemory]
      heldBlocks (rigAllocator rig) `shouldReturn` []
      (usageBytes &&& usageObjects) <$> usageOf rig `shouldReturn` (0, 0)

    it "reconciles the reservation to what the call opened, returning the rest at once" $ do
      rig ← newRig defaultBudgetRequest {requestedBytes = fromIntegral standInBlockSize + 8192}
      openBlocksOf (rigAllocator rig) 8192
      _ ← readbackOf rig 1024
      (usageBytes &&& usageDeviceMemory) <$> usageOf rig `shouldReturn` (8192, 8192)
      -- The reservation's rest is admissible again: a block of the preferred
      -- size fits beside what is held.
      openBlocksOf (rigAllocator rig) standInBlockSize
      _ ← readbackOf rig 8192
      usageBytes <$> usageOf rig `shouldReturn` 8192 + standInBlockSize

    it "reconciles a reservation to nothing when the allocating call opened nothing, and reports the failure unrecovered" $ do
      rig ← newRig defaultBudgetRequest
      allocatorOutOfMemory (rigAllocator rig) 1
      failure ← raisedBy @AllocationNotRecovered (createReadback (rigRecording rig) 1024)
      notRecoveredEnd failure `shouldSatisfy` \case
        RetryRefused _ → True
        _ → False
      (usageBytes &&& usageObjects) <$> usageOf rig `shouldReturn` (0, 0)
      usageAllocations <$> usageOf rig `shouldReturn` 0

    it "charges a dedicated allocation the driver requires at exactly its size, and releases it with its buffer" $ do
      rig ← newRig defaultBudgetRequest
      requireDedicated (rigAllocator rig)
      readback ← readbackOf rig 1024
      -- The held-memory placement is not placed, as VMA answers a required
      -- dedication there, and the allocating call makes it.
      map (\(_, _, placement) → placement) <$> placements rig `shouldReturn` [InHeldMemory, MayOpenMemory]
      journalOf rig `shouldReturn'` \journal → [(dedicated, size) | OpenedMemory _ _ size dedicated ← journal] `shouldBe` [(True, 1024)]
      usageDeviceMemory <$> usageOf rig `shouldReturn` 1024
      gone rig readback
      usageDeviceMemory <$> usageOf rig `shouldReturn` 0
      heldBlocks (rigAllocator rig) `shouldReturn` []

    it "keeps one charge for a block several readbacks share, which their disposal does not release" $ do
      rig ← newRig defaultBudgetRequest
      first ← readbackOf rig 1024
      second ← readbackOf rig 1024
      gone rig first
      usageDeviceMemory <$> usageOf rig `shouldReturn` standInBlockSize
      gone rig second
      -- The block is empty and the allocator keeps it, so it stays charged.
      map (\(_, _, size, count) → (size, count)) <$> heldBlocks (rigAllocator rig) `shouldReturn` [(standInBlockSize, 0)]
      usageDeviceMemory <$> usageOf rig `shouldReturn` standInBlockSize
      usageObjects <$> usageOf rig `shouldReturn` 0
      -- A later readback reuses it, charging nothing new.
      _ ← readbackOf rig 1024
      journalOf rig `shouldReturn'` \journal → [() | OpenedMemory {} ← journal] `shouldBe` [()]
      usageDeviceMemory <$> usageOf rig `shouldReturn` standInBlockSize

    it "fails a request whose allocating call opened more than was reserved, destroying its buffer before freeing its allocation" $ do
      rig ← newRig defaultBudgetRequest
      openExtra (rigAllocator rig) 512
      defect ← raisedBy @AllocatorAccountingDefect (createReadback (rigRecording rig) 1024)
      defectFinding defect `shouldBe` OpenedBeyondReservation standInBlockSize (standInBlockSize + 512)
      journal ← allocatorCalls (rigAllocator rig)
      let ending = dropWhile (\case MadeBuffer {} → False; _ → True) journal
      [call | call ← ending, isTeardown call] `shouldSatisfy` \case
        [DestroyedBuffer _, FreedAllocation _] → True
        _ → False
      liveAllocations (rigAllocator rig) `shouldReturn` 0
      -- The block it opened is held, empty, and stays charged in full; the
      -- budget still holds it, so the session runs on.
      usageDeviceMemory <$> usageOf rig `shouldReturn` standInBlockSize + 512
      (usageObjects &&& usageAllocations) <$> usageOf rig `shouldReturn` (0, 0)
      sessionState <$> modelOf rig `shouldReturn` SessionRunning

    it "makes no allocating call when the model rejects the reservation, answering the misuse" $ do
      rig ← newRig defaultBudgetRequest
      duringPlacing (rigAllocator rig) (atomically (failRootsSession (rigRoots rig) CleanupFailed))
      createReadback (rigRecording rig) 1024 `shouldReturn` Left (RefusedMisuse SessionAlreadyFailed)
      map (\(_, _, placement) → placement) <$> placements rig `shouldReturn` [InHeldMemory]
      heldBlocks (rigAllocator rig) `shouldReturn` []
      (usageBytes &&& usageObjects) <$> usageOf rig `shouldReturn` (0, 0)

    it "fails a request whose call freed more than was charged, and the session with it" $ do
      rig ← newRig defaultBudgetRequest
      requireDedicated (rigAllocator rig)
      failAllocatorAt (rigAllocator rig) AtBind
      freeExtra (rigAllocator rig) 100
      defect ← raisedBy @AllocatorAccountingDefect (createReadback (rigRecording rig) 1024)
      defectFinding defect `shouldBe` FreedBeyondHeld 100
      sessionState <$> modelOf rig `shouldReturn` SessionFailed CleanupFailed
      (usageBytes &&& usageDeviceMemory) <$> usageOf rig `shouldReturn` (0, 0)

    it "fails the session when a destruction freed more than was charged, the destruction itself standing" $ do
      rig ← newRig defaultBudgetRequest
      requireDedicated (rigAllocator rig)
      readback ← readbackOf rig 1024
      freeExtra (rigAllocator rig) 100
      gone rig readback
      liveAllocations (rigAllocator rig) `shouldReturn` 0
      sessionState <$> modelOf rig `shouldReturn` SessionFailed CleanupFailed

    it "fails the session when what the allocator's destruction freed disagrees with what was charged" $ do
      rig ← newRig defaultBudgetRequest
      readback ← readbackOf rig 1024
      gone rig readback
      freeExtra (rigAllocator rig) 100
      _ ← retireRoots (rigRoots rig)
      sessionState <$> modelOf rig `shouldReturn` SessionFailed CleanupFailed
      view ← atomically (readRootsView (rigRoots rig))
      (viewAllocator view, viewDevice view) `shouldBe` (RootDestroyed, RootDestroyed)

    it "fails the session when what a defect left held exceeds the byte budget, freeing nothing else" $ do
      rig ← newRig defaultBudgetRequest {requestedBytes = fromIntegral standInBlockSize + 256}
      openExtra (rigAllocator rig) 512
      _ ← raisedBy @AllocatorAccountingDefect (createReadback (rigRecording rig) 1024)
      sessionState <$> modelOf rig `shouldReturn` SessionFailed CleanupFailed
      heldBlocks (rigAllocator rig) `shouldReturn'` \held → length held `shouldBe` 1

  describe "recovery" $ do
    it "retries an allocating call once after a disposal frees space, placing in the memory that disposal emptied" $ do
      rig ← newRig defaultBudgetRequest
      first ← readbackOf rig 1024
      ok (releaseManaged (rigRecording rig) first)
      -- The released readback is eligible but not yet disposed: only the
      -- reclamation pass destroys it.
      gate ← length <$> allocatorCalls (rigAllocator rig)
      limitDeviceMemory (rigAllocator rig) standInBlockSize
      -- The first readback's block is full of it; a second placement misses,
      -- and the allocating call cannot open another block.
      _ ← readbackOf rig (standInBlockSize - 512)
      journal ← drop gate <$> allocatorCalls (rigAllocator rig)
      [placement | Placing _ _ placement ← journal] `shouldBe` [InHeldMemory, MayOpenMemory, InHeldMemory]
      [() | DestroyedBuffer _ ← journal] `shouldBe` [()]
      [() | OpenedMemory {} ← journal] `shouldBe` []
      usageDeviceMemory <$> usageOf rig `shouldReturn` standInBlockSize

  describe "failure cleanup" $ do
    it "leaves nothing allocated and no reservation held when the creation fails" $ do
      rig ← newRig defaultBudgetRequest
      failAllocatorAt (rigAllocator rig) AtCreate
      raisedBy @AllocatorFailure (createReadback (rigRecording rig) 1024) `shouldReturn` AllocatorFailure AtCreate
      liveAllocations (rigAllocator rig) `shouldReturn` 0
      use ← usageOf rig
      (usageBytes use, usageObjects use, usageAllocations use) `shouldBe` (0, 0, 0)

    it "keeps a block a failed bind left empty charged, holding no reservation, and places in it next" $ do
      rig ← newRig defaultBudgetRequest
      failAllocatorAt (rigAllocator rig) AtBind
      raisedBy @AllocatorFailure (createReadback (rigRecording rig) 1024) `shouldReturn` AllocatorFailure AtBind
      liveAllocations (rigAllocator rig) `shouldReturn` 0
      use ← usageOf rig
      (usageBytes use, usageDeviceMemory use, usageObjects use, usageAllocations use) `shouldBe` (standInBlockSize, standInBlockSize, 0, 0)
      clearAllocatorAt (rigAllocator rig) AtBind
      _ ← readbackOf rig 1024
      journalOf rig `shouldReturn'` \journal → [() | OpenedMemory {} ← journal] `shouldBe` [()]

    it "nets to nothing a dedicated allocation opened and freed inside one call whose bind failed" $ do
      rig ← newRig defaultBudgetRequest
      requireDedicated (rigAllocator rig)
      failAllocatorAt (rigAllocator rig) AtBind
      _ ← raisedBy @AllocatorFailure (createReadback (rigRecording rig) 1024)
      journalOf rig `shouldReturn'` \journal → [() | FreedMemory _ 1024 ← journal] `shouldBe` [()]
      (usageBytes &&& usageDeviceMemory) <$> usageOf rig `shouldReturn` (0, 0)

    it "rolls back only the failed request when its bind fails in a populated block, and its sibling survives" $ do
      rig ← newRig defaultBudgetRequest
      sibling ← readbackOf rig 1024
      ok (fillReadback (rigRecording rig) sibling 9)
      failAllocatorAt (rigAllocator rig) AtBind
      _ ← raisedBy @AllocatorFailure (createReadback (rigRecording rig) 1024)
      liveAllocations (rigAllocator rig) `shouldReturn` 1
      map (\(_, _, _, count) → count) <$> heldBlocks (rigAllocator rig) `shouldReturn` [1]
      usageDeviceMemory <$> usageOf rig `shouldReturn` standInBlockSize
      readReadback (rigRecording rig) sibling 0 4 `shouldReturn` Right (ByteString.replicate 4 9)

    it "destroys the buffer and frees its allocation when the map fails, and its sibling survives" $ do
      rig ← newRig defaultBudgetRequest
      sibling ← readbackOf rig 1024
      ok (fillReadback (rigRecording rig) sibling 5)
      failAllocatorAt (rigAllocator rig) AtMap
      gate ← length <$> allocatorCalls (rigAllocator rig)
      raisedBy @AllocatorFailure (createReadback (rigRecording rig) 1024) `shouldReturn` AllocatorFailure AtMap
      journal ← drop gate <$> allocatorCalls (rigAllocator rig)
      [call | call ← journal, isTeardown call || isMap call] `shouldSatisfy` \case
        [Mapped _, DestroyedBuffer _, FreedAllocation _] → True
        _ → False
      liveAllocations (rigAllocator rig) `shouldReturn` 1
      (usageObjects &&& usageAllocations) <$> usageOf rig `shouldReturn` (2, 0)
      readReadback (rigRecording rig) sibling 0 4 `shouldReturn` Right (ByteString.replicate 4 5)

  describe "mapping" $ do
    it "maps each allocation once, and unmaps only its own when it goes" $ do
      rig ← newRig defaultBudgetRequest
      first ← readbackOf rig 1024
      second ← readbackOf rig 1024
      ok (fillReadback (rigRecording rig) second 3)
      [allocationOne, allocationTwo] ← allocations rig
      gone rig first
      journal ← allocatorCalls (rigAllocator rig)
      [handle | Mapped handle ← journal] `shouldBe` [allocationOne, allocationTwo]
      [handle | Unmapped handle ← journal] `shouldBe` [allocationOne]
      readReadback (rigRecording rig) second 0 4 `shouldReturn` Right (ByteString.replicate 4 3)

    it "flushes and invalidates non-coherent memory as ranges of the allocation, wherever it lies in its block" $ do
      rig ← newRig defaultBudgetRequest
      nonCoherentReadback (rigAllocator rig)
      _ ← readbackOf rig 1000
      second ← readbackOf rig 1000
      [_, allocation] ← allocations rig
      -- Both lie in one block, the second a thousand bytes into it.
      map (\(_, _, _, count) → count) <$> heldBlocks (rigAllocator rig) `shouldReturn` [2]
      ok (fillReadback (rigRecording rig) second 1)
      last <$> allocatorCalls (rigAllocator rig) `shouldReturn` Flushed allocation (0, 1000)
      -- A read ending at the allocation's boundary invalidates exactly it.
      readReadback (rigRecording rig) second 984 16 `shouldReturn` Right (ByteString.replicate 16 1)
      last <$> allocatorCalls (rigAllocator rig) `shouldReturn` Invalidated allocation (984, 16)

  describe "the allocator's lifetime" $ do
    it "creates one allocator with the device, which every user of the device shares" $ do
      rig ← newRig defaultBudgetRequest
      journalRoots rig `shouldReturn'` \journal → [() | CreatedAllocator ← journal] `shouldBe` [()]
      other ← newRecording' rig
      _ ← readbackOf rig 1024
      _ ← createReadback other 1024 >>= either (fail . show) pure
      journalOf rig `shouldReturn'` \journal → [() | OpenedMemory {} ← journal] `shouldBe` [()]
      viewAllocator <$> atomically (readRootsView (rigRoots rig)) `shouldReturn` RootLive

    it "leaves the device recorded and nothing allocatable when the allocator's creation failed" $ do
      standIn ← newStandIn
      roots ← newStandInRoots standIn (budgets defaultBudgetRequest)
      _ ← startRoots roots standardRequest
      script standIn AtCreateAllocator Fails
      raisedBy @StandInFailure (startRootsDevice roots) `shouldReturn` StandInFailure AtCreateAllocator
      view ← atomically (readRootsView roots)
      (viewDevice view, viewAllocator view) `shouldBe` (RootLive, RootAbsent)
      recording ← newRecordingOver roots
      createReadback recording 1024 `shouldReturn` Left RefusedDeviceAbsent
      _ ← retireRoots roots
      viewDevice <$> atomically (readRootsView roots) `shouldReturn` RootDestroyed

    it "refuses to destroy the allocator while an allocation remains, retaining it and the device" $ do
      rig ← newRig defaultBudgetRequest
      _ ← readbackOf rig 1024
      raisedBy @RootsRetained (retireRoots (rigRoots rig)) `shouldReturn` AllocationsRemain 1
      view ← atomically (readRootsView (rigRoots rig))
      (viewAllocator view, viewDevice view) `shouldBe` (RootLive, RootLive)
      journalOf rig `shouldReturn'` \journal → [() | DestroyedAllocator ← journal] `shouldBe` []

    it "destroys the allocator before the device, releasing what it still held exactly once" $ do
      rig ← newRig defaultBudgetRequest
      readback ← readbackOf rig 1024
      gone rig readback
      usageDeviceMemory <$> usageOf rig `shouldReturn` standInBlockSize
      _ ← retireRoots (rigRoots rig)
      journal ← allocatorCalls (rigAllocator rig)
      drop (length journal - 2) journal `shouldBe` [DestroyedAllocator, FreedMemory 700 standInBlockSize]
      use ← usageOf rig
      (usageBytes use, usageDeviceMemory use) `shouldBe` (0, 0)
      view ← atomically (readRootsView (rigRoots rig))
      (viewAllocator view, viewDevice view) `shouldBe` (RootDestroyed, RootDestroyed)

    it "retains the device when the allocator's destruction raised" $ do
      rig ← newRig defaultBudgetRequest
      failAllocatorAt (rigAllocator rig) AtDestroyAllocator
      _ ← raisedBy @RootDestructionFailed (retireRoots (rigRoots rig))
      view ← atomically (readRootsView (rigRoots rig))
      viewDevice view `shouldBe` RootLive
      viewAllocator view `shouldSatisfy` \case
        RootUncertain _ → True
        _ → False
      raisedBy @RootsRetained (retireRoots (rigRoots rig)) `shouldReturn'` \case
        AllocatorRemains (RootUncertain _) → pure ()
        other → expectationFailure ("expected the allocator to retain the device, got " <> show other)
      journalRoots rig `shouldReturn'` \journal → [() | DestroyedDevice ← journal] `shouldBe` []
  where
    bit index = 2 ^ index
    mebibyte = 1024 * 1024
    (&&&) f g value = (f value, g value)
    isTeardown = \case
      DestroyedBuffer _ → True
      FreedAllocation _ → True
      _ → False
    isMap = \case
      Mapped _ → True
      _ → False

-- ---------------------------------------------------------------------------
-- The rig

data Rig = Rig
  { rigStandIn ∷ !StandIn
  , rigRoots ∷ !StandInRoots
  , rigRecording ∷ !(Recording () Int Int Text Int Word64)
  , rigAllocator ∷ !AllocatorStandIn
  }

-- | Started roots over the stand-in with a surface-free device, and a
-- recording over them.
newRig ∷ BudgetRequest → IO Rig
newRig request = do
  standIn ← newStandIn
  roots ← newStandInRoots standIn (budgets request)
  _ ← startRoots roots standardRequest
  _ ← startRootsDevice roots
  recording ← newRecordingOver roots
  pure (Rig standIn roots recording (standAllocator standIn))

newRecordingOver ∷ StandInRoots → IO (Recording () Int Int Text Int Word64)
newRecordingOver roots = do
  generations ← newGenerations roots
  recordingStandIn ← newRecordingStandIn
  newRecording (recordingStandInOps recordingStandIn) roots generations

-- | Another recording over the rig's roots, as a second user of the device.
newRecording' ∷ Rig → IO (Recording () Int Int Text Int Word64)
newRecording' = newRecordingOver . rigRoots

budgets ∷ BudgetRequest → Budgets
budgets request = either (error . show) id (validateBudgets request)

readbackOf ∷ Rig → Natural → IO Readback
readbackOf rig bytes = createReadback (rigRecording rig) bytes >>= either (fail . ("the readback was refused: " <>) . show) pure

-- | Release a readback and dispose of it: it holds nothing else.
gone ∷ Rig → Readback → IO ()
gone rig readback = do
  ok (releaseManaged (rigRecording rig) readback)
  disposed ← disposeResources (rigRecording rig) at
  disposed `shouldBe` [managedResource readback]

ok ∷ Show refusal ⇒ IO (Either refusal ()) → IO ()
ok action = action >>= either (fail . ("refused: " <>) . show) pure

usageOf ∷ Rig → IO Usage
usageOf rig = usage <$> modelOf rig

modelOf ∷ Rig → IO GpuModel
modelOf rig = atomically (readRootsModel (rigRoots rig))

journalOf ∷ Rig → IO [AllocatorCall]
journalOf = allocatorCalls . rigAllocator

journalRoots ∷ Rig → IO [Call]
journalRoots = calls . rigStandIn

-- | Every creation the allocator was asked for: size, type and placement.
placements ∷ Rig → IO [(Natural, Word32, Placement)]
placements rig = (\journal → [(size, kind, placement) | Placing size kind placement ← journal]) <$> journalOf rig

-- | Every allocation made, in order.
allocations ∷ Rig → IO [Word64]
allocations rig = (\journal → [allocation | MadeBuffer _ allocation _ ← journal]) <$> journalOf rig

infix 1 `shouldReturn'`

shouldReturn' ∷ IO a → (a → IO ()) → IO ()
shouldReturn' action assertion = action >>= assertion

raisedBy ∷ ∀ e a. (Exception e, Show a) ⇒ IO a → IO e
raisedBy action =
  try action >>= \case
    Left failure → pure failure
    Right value → do
      expectationFailure ("nothing was raised: " <> show value)
      fail "unreachable"

byteHex ∷ Word8 → String
byteHex byte = [digits !! fromIntegral (byte `div` 16), digits !! fromIntegral (byte `mod` 16)]
  where
    digits = "0123456789abcdef"

at ∷ Instant
at = scriptedInstant (either (error . show) id (durationFromNanoseconds AllowZero 1000000))
