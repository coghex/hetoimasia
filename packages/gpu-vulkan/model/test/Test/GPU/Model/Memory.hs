-- | Device-memory accounting (D-15, D-40): the bounded reservation an
-- allocating call is admitted under, its settlement to what the allocator
-- reported opening and freeing, and the independence of those charges from
-- the resources the memory serves.
--
-- The allocator's effects are stated directly, as the native boundary reports
-- them, so every example here is a pure sequence of model answers.
module Test.GPU.Model.Memory (spec) where

import Hetoimasia.GPU.Model
import Hetoimasia.GPU.Model.Budget
import Hetoimasia.GPU.Model.Identity
import Numeric.Natural (Natural)
import Test.GPU.Model.Support
import Test.Hspec (Spec, describe, it, shouldBe)

spec ∷ Spec
spec = describe "device memory" $ do
  describe "reservation" $ do
    it "refuses a reservation the byte budget cannot hold as backpressure, changing nothing" $ do
      model ← freshModelWith smallRequest
      (attempted, attempt) ← admitted "an attempt" (beginAllocation 0 2 model)
      backpressured "reserving past the budget" (reserveDeviceMemory attempt 4097 attempted) >>= (`shouldBe` ByteBudget)
      reserved ← admitted_ "reserving the whole budget" (reserveDeviceMemory attempt 4096 attempted)
      usageBytes (usage reserved) `shouldBe` 4096
      usageDeviceMemory (usage reserved) `shouldBe` 0

    it "holds one reservation per attempt, and none for a failed attempt" $ do
      model ← freshModelWith smallRequest
      (attempted, attempt) ← admitted "an attempt" (beginAllocation 0 2 model)
      reserved ← admitted_ "reserving" (reserveDeviceMemory attempt 1024 attempted)
      rejected_ "reserving again" (reserveDeviceMemory attempt 1024 reserved) >>= (`shouldBe` WrongPhase AllocationIdentity)
      rejected_ "reserving nothing" (reserveDeviceMemory attempt 0 attempted) >>= (`shouldBe` EmptyAllocation)
      failed ← admitted_ "failing the attempt" (recordAllocationFailure attempt attempted)
      rejected_ "reserving for a failed attempt" (reserveDeviceMemory attempt 1024 failed) >>= (`shouldBe` WrongPhase AllocationIdentity)

    it "refuses to make a resource while its attempt's reservation is unsettled" $ do
      model ← freshModelWith smallRequest
      (attempted, attempt) ← admitted "an attempt" (beginAllocation 0 2 model)
      reserved ← admitted_ "reserving" (reserveDeviceMemory attempt 1024 attempted)
      rejected "creating over an unsettled reservation" (createResource attempt reserved) >>= (`shouldBe` WrongPhase AllocationIdentity)

    it "gives an unsettled reservation back when the attempt is abandoned" $ do
      model ← freshModelWith smallRequest
      (attempted, attempt) ← admitted "an attempt" (beginAllocation 0 2 model)
      reserved ← admitted_ "reserving" (reserveDeviceMemory attempt 2048 attempted)
      abandoned ← admitted_ "abandoning" (abandonAllocation attempt reserved)
      usageBytes (usage abandoned) `shouldBe` 0
      usageObjects (usage abandoned) `shouldBe` 0

  describe "settlement" $ do
    it "charges exactly what the call opened and returns the rest of the reservation at once" $ do
      model ← freshModelWith smallRequest
      (attempted, attempt) ← admitted "an attempt" (beginAllocation 0 2 model)
      reserved ← admitted_ "reserving" (reserveDeviceMemory attempt 4096 attempted)
      (settled, answer) ← admitted "settling one 1 KiB block" (settleDeviceMemory (Just attempt) (MemoryEffect 1024 0) reserved)
      answer `shouldBe` MemorySettled
      usageBytes (usage settled) `shouldBe` 1024
      usageDeviceMemory (usage settled) `shouldBe` 1024
      -- The returned bytes are admissible again straight away.
      (again, another) ← admitted "another attempt" (beginAllocation 0 2 settled)
      _ ← admitted_ "reserving what was returned" (reserveDeviceMemory another 3072 again)
      pure ()

    it "returns the whole reservation when the call opened nothing" $ do
      model ← freshModelWith smallRequest
      (attempted, attempt) ← admitted "an attempt" (beginAllocation 0 2 model)
      reserved ← admitted_ "reserving" (reserveDeviceMemory attempt 4096 attempted)
      (settled, answer) ← admitted "settling nothing" (settleDeviceMemory (Just attempt) noMemoryEffect reserved)
      answer `shouldBe` MemorySettled
      usageBytes (usage settled) `shouldBe` 0
      _ ← admitted "making the resource" (createResource attempt settled)
      pure ()

    it "nets memory a call opened and freed within itself to nothing" $ do
      model ← freshModelWith smallRequest
      (attempted, attempt) ← admitted "an attempt" (beginAllocation 0 2 model)
      reserved ← admitted_ "reserving" (reserveDeviceMemory attempt 2048 attempted)
      (settled, answer) ← admitted "settling a block opened and freed" (settleDeviceMemory (Just attempt) (MemoryEffect 2048 2048) reserved)
      answer `shouldBe` MemorySettled
      usageBytes (usage settled) `shouldBe` 0
      usageDeviceMemory (usage settled) `shouldBe` 0

    it "keeps memory a failed request left held charged after the attempt is abandoned" $ do
      model ← freshModelWith smallRequest
      (attempted, attempt) ← admitted "an attempt" (beginAllocation 0 2 model)
      reserved ← admitted_ "reserving" (reserveDeviceMemory attempt 2048 attempted)
      -- The call opened a block and failed after it; the allocator kept the
      -- block, empty.
      (settled, _) ← admitted "settling the retained block" (settleDeviceMemory (Just attempt) (MemoryEffect 2048 0) reserved)
      abandoned ← admitted_ "abandoning" (abandonAllocation attempt settled)
      usageBytes (usage abandoned) `shouldBe` 2048
      usageDeviceMemory (usage abandoned) `shouldBe` 2048
      usageObjects (usage abandoned) `shouldBe` 0
      (freed, answer) ← admitted "the block freed" (settleDeviceMemory Nothing (MemoryEffect 0 2048) abandoned)
      answer `shouldBe` MemorySettled
      usageBytes (usage freed) `shouldBe` 0

    it "charges memory opened beyond the reservation in full and names the excess" $ do
      model ← freshModelWith smallRequest
      (attempted, attempt) ← admitted "an attempt" (beginAllocation 0 2 model)
      reserved ← admitted_ "reserving" (reserveDeviceMemory attempt 1024 attempted)
      (settled, answer) ← admitted "settling more than was reserved" (settleDeviceMemory (Just attempt) (MemoryEffect 8192 0) reserved)
      answer `shouldBe` MemoryBeyondReservation 7168
      -- Held memory is charged even past the budget, so nothing can be
      -- admitted against it until it is freed.
      usageBytes (usage settled) `shouldBe` 8192
      backpressured "another attempt" (beginAllocation 0 2 settled) >>= (`shouldBe` ByteBudget)
      (freed, freedAnswer) ← admitted "the defect freed" (settleDeviceMemory Nothing (MemoryEffect 0 8192) settled)
      freedAnswer `shouldBe` MemorySettled
      usageBytes (usage freed) `shouldBe` 0

    it "names memory opened outside any reservation" $ do
      model ← freshModelWith smallRequest
      (_, answer) ← admitted "settling an unreserved open" (settleDeviceMemory Nothing (MemoryEffect 512 0) model)
      answer `shouldBe` MemoryBeyondReservation 512

    it "names a free of more than was held, and stops the charge at zero" $ do
      model ← freshModelWith smallRequest
      (held, _) ← admitted "an unreserved open" (settleDeviceMemory Nothing (MemoryEffect 512 0) model)
      (freed, answer) ← admitted "freeing more than was held" (settleDeviceMemory Nothing (MemoryEffect 0 1024) held)
      answer `shouldBe` MemoryFreedUnheld 512
      usageDeviceMemory (usage freed) `shouldBe` 0
      usageBytes (usage freed) `shouldBe` 0

    it "answers a call that opened beyond its reservation and freed beyond what was held with the over-free" $ do
      model ← freshModelWith smallRequest
      (attempted, attempt) ← admitted "an attempt" (beginAllocation 0 2 model)
      reserved ← admitted_ "reserving" (reserveDeviceMemory attempt 10 attempted)
      (settled, answer) ← admitted "settling both defects" (settleDeviceMemory (Just attempt) (MemoryEffect 11 12) reserved)
      answer `shouldBe` MemoryFreedUnheld 1
      usageDeviceMemory (usage settled) `shouldBe` 0

    it "settles a call's effect in a failed session, admitting nothing new" $ do
      model ← freshModelWith smallRequest
      (attempted, attempt) ← admitted "an attempt" (beginAllocation 0 2 model)
      reserved ← admitted_ "reserving" (reserveDeviceMemory attempt 1024 attempted)
      let failed = escalateSession CleanupFailed reserved
      (settled, _) ← admitted "settling after the failure" (settleDeviceMemory (Just attempt) (MemoryEffect 1024 0) failed)
      usageDeviceMemory (usage settled) `shouldBe` 1024
      rejected_ "reserving again" (reserveDeviceMemory attempt 1024 settled) >>= (`shouldBe` SessionAlreadyFailed)

  describe "independence from resources" $ do
    it "keeps one charge for a block several resources share, released only when the block is freed" $ do
      model ← freshModelWith smallRequest
      (first, firstResource) ← placed (Just 2048) model
      (second, secondResource) ← placed Nothing first
      usageDeviceMemory (usage second) `shouldBe` 2048
      usageBytes (usage second) `shouldBe` 2048
      -- Disposing of both resources releases none of the block's charge.
      disposed ← disposeAll [firstResource, secondResource] second
      usageResources (usage disposed) `shouldBe` 0
      usageObjects (usage disposed) `shouldBe` 0
      usageBytes (usage disposed) `shouldBe` 2048
      -- Freeing the block does, exactly once.
      (freed, _) ← admitted "the block freed" (settleDeviceMemory Nothing (MemoryEffect 0 2048) disposed)
      usageBytes (usage freed) `shouldBe` 0
      (again, answer) ← admitted "the block freed twice" (settleDeviceMemory Nothing (MemoryEffect 0 2048) freed)
      answer `shouldBe` MemoryFreedUnheld 2048
      usageBytes (usage again) `shouldBe` 0

    it "keeps an empty block the allocator retains charged after its last resource goes" $ do
      model ← freshModelWith smallRequest
      (made, resource) ← placed (Just 1024) model
      disposed ← disposeAll [resource] made
      usageDeviceMemory (usage disposed) `shouldBe` 1024
  where
    -- A resource made by one attempt whose allocating call opened the given
    -- block, or placed in memory already held.
    placed ∷ Maybe Natural → GpuModel → IO (GpuModel, ResourceId)
    placed opened model = do
      (attempted, attempt) ← admitted "an attempt" (beginAllocation 0 2 model)
      settled ← case opened of
        Nothing → admitted "settling a placement" (settleDeviceMemory (Just attempt) noMemoryEffect attempted)
        Just bytes → do
          reserved ← admitted_ "reserving" (reserveDeviceMemory attempt bytes attempted)
          admitted "settling the block" (settleDeviceMemory (Just attempt) (MemoryEffect bytes 0) reserved)
      admitted "creating" (createResource attempt (fst settled))
    disposeAll resources model = do
      ended ← foldl (\step resource → step >>= \current → admitted_ "releasing" (releaseResource resource current) >>= admitted_ "ending CPU use" . endResourceCpuUse resource) (pure model) resources
      let (reclaimed, report) = reclaimPass silentEvidence {disposalEvidence = const DisposalCompleted} ended
      reclaimDisposed report `shouldBe` map ResourceSubject resources
      pure reclaimed
