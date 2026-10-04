-- | The bindless texture table's pure bookkeeping (GRS-7): configuration,
-- handles, versions published only on change, versions held until free,
-- backpressure, slot reuse only once no live version maps a slot, and stale
-- handles refused. Whether a ring entry is held is given as a set, as the
-- native table reads it from the GPU model's holds.
module Test.GPU.Model.TextureTable (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word32)
import Hetoimasia.GPU.Model.TextureTable
import Hetoimasia.GPU.Model
import Hetoimasia.GPU.Model.Identity (HoldSubject (ResourceSubject))
import Test.GPU.Model.Support
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "texture table" $ do
  describe "configuration" $ do
    it "validates the cap, the initial size and the version count, refusing zero, negative, unrepresentable and inconsistent values, never clamping" $ do
      fmap (\config → (tableCapacity config, tableInitialSlots config, tableVersionCount config)) (validateTableConfig 1024 64 defaultVersionCount)
        `shouldBe` Right (1024, 64, 8)
      validateTableConfig 0 2 8 `shouldBe` Left (TableCapacityInvalid 0)
      validateTableConfig (-1) 2 8 `shouldBe` Left (TableCapacityInvalid (-1))
      validateTableConfig (2 ^ (32 ∷ Int)) 2 8 `shouldBe` Left (TableCapacityInvalid (2 ^ (32 ∷ Int)))
      -- Slot 0 is the placeholder and counts against the size: one slot holds
      -- no texture.
      validateTableConfig 8 1 8 `shouldBe` Left (TableInitialInvalid 1)
      validateTableConfig 8 16 8 `shouldBe` Left (TableInitialAboveCapacity 16 8)
      validateTableConfig 8 4 0 `shouldBe` Left (TableVersionsInvalid 0)

  describe "handles" $ do
    it "registers a texture into a reserved slot that resolves to the placeholder until its upload completes, and to its own slot after" $ do
      let table = fresh 4 2
      (registered, handle) ← expectRight (registerTexture "a" table)
      handleStanding handle registered `shouldBe` HandlePending 1
      Map.lookup (handleIndex handle) (currentMapping registered) `shouldBe` Just (LookupEntry 0 (handleGeneration handle))
      (completed, descriptor) ← expectRight (completeTexture handle registered)
      descriptor `shouldBe` (1, "a")
      handleStanding handle completed `shouldBe` HandleReady 1
      resolveHandle 4 (currentMapping completed) handle `shouldBe` 1

    it "refuses a stale handle wherever it is used: released, of an older generation, or completed after its release" $ do
      let table = fresh 4 2
      (registered, first) ← expectRight (registerTexture "a" table)
      released ← expectRight (releaseTexture first registered)
      -- Releasing before the upload completes: its later completion cannot
      -- resurrect the handle.
      completeTexture first released `shouldBe` Left (TableStaleHandle first)
      releaseTexture first released `shouldBe` Left (TableStaleHandle first)
      handleStanding first released `shouldBe` HandleStale
      -- The index is issued again under the next generation, and the old
      -- handle stays stale against it.
      (reissued, second) ← expectRight (registerTexture "b" released)
      handleIndex second `shouldBe` handleIndex first
      handleGeneration second `shouldBe` handleGeneration first + 1
      releaseTexture first reissued `shouldBe` Left (TableStaleHandle first)
      resolveHandle 4 (currentMapping reissued) first `shouldBe` 0
      -- An index out of bounds resolves to the placeholder.
      resolveHandle 4 (currentMapping reissued) (TextureHandle 9 1) `shouldBe` 0

    it "answers backpressure when every slot is taken, reserving nothing, and slot 0 counts against the size" $ do
      let table = fresh 3 2
      (one, _) ← expectRight (registerTexture "a" table)
      (two, _) ← expectRight (registerTexture "b" one)
      registerTexture "c" two `shouldBe` Left TableFull
      freeSlots two `shouldBe` Set.empty

  describe "versions" $ do
    it "publishes a new version only when a mapping changed, and shares the current one otherwise" $ do
      let table = fresh 4 2
      (first, binding) ← expectRight (bindVersion none table)
      binding `shouldSatisfy` written
      (again, shared) ← expectRight (bindVersion none first)
      shared `shouldBe` VersionBinding (bindingVersion binding) Nothing
      -- Registering changes a mapping even though its slot is still 0;
      -- completing, and releasing, change it again.
      (registered, handle) ← expectRight (registerTexture "a" again)
      (afterRegister, published) ← expectRight (bindVersion none registered)
      published `shouldSatisfy` written
      (completed, _) ← expectRight (completeTexture handle afterRegister)
      (afterComplete, completeBinding) ← expectRight (bindVersion none completed)
      completeBinding `shouldSatisfy` written
      released ← expectRight (releaseTexture handle afterComplete)
      (_, releaseBinding) ← expectRight (bindVersion none released)
      releaseBinding `shouldSatisfy` written

    it "never overwrites a version a batch holds, and reuses an entry once nothing holds it" $ do
      let table = fresh 4 2
      (first, one) ← expectRight (bindVersion none table)
      (changed, _) ← expectRight (registerTexture "a" first)
      -- The batch holding the first version keeps it: the new version goes
      -- elsewhere.
      (second, two) ← expectRight (bindVersion (heldBy [bindingVersion one]) changed)
      bindingVersion two `shouldSatisfy` (/= bindingVersion one)
      versionMapping (bindingVersion one) second `shouldBe` Just Map.empty
      -- Once the first version is free, it is reused for the next change.
      (changedAgain, _) ← expectRight (registerTexture "b" second)
      (_, three) ← expectRight (bindVersion (heldBy [bindingVersion two]) changedAgain)
      bindingVersion three `shouldBe` bindingVersion one

    it "answers backpressure when a new version is owed and every entry is held, yet keeps an unchanged current version bindable" $ do
      let table = fresh 4 2
      (first, one) ← expectRight (bindVersion none table)
      (changed, _) ← expectRight (registerTexture "a" first)
      (second, two) ← expectRight (bindVersion (heldBy [bindingVersion one]) changed)
      let everything = heldBy [bindingVersion one, bindingVersion two]
      -- Nothing changed since the second version: it is still bindable.
      (_, shared) ← expectRight (bindVersion everything second)
      shared `shouldBe` VersionBinding (bindingVersion two) Nothing
      (changedAgain, _) ← expectRight (registerTexture "b" second)
      bindVersion everything changedAgain `shouldBe` Left TableVersionsHeld

  describe "growth" $ do
    it "doubles past 2^31 to the cap, never wrapping" $ do
      grownSlots 2147483648 2147483649 `shouldBe` 2147483649
      grownSlots 2147483648 maxBound `shouldBe` maxBound
      grownSlots 2147483647 maxBound `shouldBe` 4294967294
      grownSlots maxBound maxBound `shouldBe` maxBound
      grownSlots 3 10 `shouldBe` 6
      grownSlots 6 10 `shouldBe` 10

    it "grows only when no slot is free, doubling the allocated slots and never past a non-power-of-two cap, which is backpressure" $ do
      let table = newTextureTable (either (error . show) id (validateTableConfig 10 3 8)) ∷ TextureTable String
      allocatedSlots table `shouldBe` 3
      growTable table `shouldBe` Left TableHasFreeSlot
      (one, _) ← expectRight (registerTexture "a" table)
      (two, _) ← expectRight (registerTexture "b" one)
      registerTexture "c" two `shouldBe` Left TableFull
      (grown, count) ← expectRight (growTable two)
      (count, allocatedSlots grown, freeSlots grown) `shouldBe` (6, 6, Set.fromList [3, 4, 5])
      full ← foldr (\name next → next >>= \t → fst <$> expectRight (registerTexture name t)) (pure grown) ["c", "d", "e"]
      (atCap, capped) ← expectRight (growTable full)
      (capped, allocatedSlots atCap, freeSlots atCap) `shouldBe` (10, 10, Set.fromList [6 .. 9])
      filled ← foldr (\name next → next >>= \t → fst <$> expectRight (registerTexture name t)) (pure atCap) ["f", "g", "h", "i"]
      registerTexture "j" filled `shouldBe` Left TableFull
      growTable filled `shouldBe` Left TableAtCapacity

    it "grows while released slots are still retiring, leaving them retiring and every handle and version as it was" $ do
      let table = fresh 3 2
      (one, first) ← expectRight (registerTexture "a" table)
      (completed, (slot, _)) ← expectRight (completeTexture first one)
      (two, second) ← expectRight (registerTexture "b" completed)
      (bound, binding) ← expectRight (bindVersion none two)
      released ← expectRight (releaseTexture first bound)
      -- The batch that bound the version still maps the first slot, so it
      -- retires rather than frees: no slot is free, and the table grows.
      let held = heldBy [bindingVersion binding]
      freeSlots (fst (reclaimSlots held released)) `shouldBe` Set.empty
      (grown, count) ← expectRight (growTable (fst (reclaimSlots held released)))
      -- Three slots (the fixture's cap is 16) double to six.
      count `shouldBe` 6
      retiringSlots grown `shouldBe` [slot]
      handleStanding second grown `shouldBe` handleStanding second released
      versionMapping (bindingVersion binding) grown `shouldBe` versionMapping (bindingVersion binding) released
      -- The retiring slot is freed, and reused, once that batch's version is
      -- no longer live.
      let (reclaimed, freed) = reclaimSlots none grown
      map fst freed `shouldBe` [slot]
      Set.member slot (freeSlots reclaimed) `shouldBe` True

    it "names the written slots a growth copies: completed textures', until their slots are freed or their registration undone" $ do
      let table = fresh 4 2
      (one, first) ← expectRight (registerTexture "a" table)
      (two, second) ← expectRight (registerTexture "b" one)
      writtenSlots two `shouldBe` Set.empty
      (completed, (slot, _)) ← expectRight (completeTexture first two)
      (completedBoth, (other, _)) ← expectRight (completeTexture second completed)
      writtenSlots completedBoth `shouldBe` Set.fromList [slot, other]
      released ← expectRight (releaseTexture first completedBoth)
      writtenSlots released `shouldBe` Set.fromList [slot, other]
      writtenSlots (fst (reclaimSlots none released)) `shouldBe` Set.fromList [other]
      undone ← expectRight (unregisterTexture second completedBoth)
      writtenSlots undone `shouldBe` Set.fromList [slot]

    it "keeps a superseded set's pool until the batch that bound it completes, and the current set's regardless (the model's holds)" $ do
      model ← freshModel
      (active, target, _) ← activeTarget 2 model
      (withOld, oldPool) ← aResource 1024 active
      (withNew, newPool) ← aResource 2048 withOld
      (framed, frame) ← acquiredFrame target withNew
      (recorded, _) ← admitted "recording a batch that bound the old set" (recordBatch frame [oldPool] framed)
      -- Growth supersedes the old set: its pool is released and its CPU use
      -- ends, but the batch's recorded reference still holds it.
      released ← admitted_ "releasing the old set's pool" (releaseResource oldPool recorded)
      ended ← admitted_ "ending its CPU use" (endResourceCpuUse oldPool released)
      disposalEligible (ResourceSubject oldPool) ended `shouldBe` False
      (submitted, answer) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted ended)
      submission ← case answer of
        SubmissionRecorded identity → pure identity
        other → fail ("expected a submission record, got " <> show other)
      disposalEligible (ResourceSubject oldPool) submitted `shouldBe` False
      completedModel ← admitted_ "completing the submission" (recordCompletion (atMilliseconds 1) (SubmissionCompleted submission) submitted)
      disposalEligible (ResourceSubject oldPool) completedModel `shouldBe` True
      disposalEligible (ResourceSubject newPool) completedModel `shouldBe` False

  describe "slots" $ do
    it "undoes a registration whose handle was never handed out: its slot is free at once, nothing retires, and its index is issued again" $ do
      let table = fresh 3 2
      (registered, handle) ← expectRight (registerTexture "a" table)
      undone ← expectRight (unregisterTexture handle registered)
      freeSlots undone `shouldBe` freeSlots table
      retiringSlots undone `shouldBe` []
      currentMapping undone `shouldBe` Map.empty
      unregisterTexture handle undone `shouldBe` Left (TableStaleHandle handle)
      (_, again) ← expectRight (registerTexture "a" undone)
      handleIndex again `shouldBe` handleIndex handle
      handleGeneration again `shouldSatisfy` (/= handleGeneration handle)
      -- A handle a version maps was handed out, and is not undone.
      (completed, (slot, _)) ← expectRight (completeTexture handle registered)
      (bound, _) ← expectRight (bindVersion (const False) completed)
      unregisterTexture handle bound `shouldBe` Left (TableStaleHandle handle)
      -- A version naming the slot for an earlier occupant is no obstacle:
      -- once that texture is released and its slot reclaimed, a registration
      -- reusing the slot is undone.
      released ← expectRight (releaseTexture handle bound)
      let (reclaimed, freed) = reclaimSlots (const False) released
      map fst freed `shouldBe` [slot]
      (reused, replacement) ← expectRight (registerTexture "b" reclaimed)
      (completedAgain, (reusedSlot, _)) ← expectRight (completeTexture replacement reused)
      reusedSlot `shouldBe` slot
      undoneAgain ← expectRight (unregisterTexture replacement completedAgain)
      freeSlots undoneAgain `shouldBe` freeSlots reclaimed

    it "frees a released texture's slot at once when no batch holds a version mapping it: the release made the current version unbindable" $ do
      let table = fresh 3 2
      (registered, handle) ← expectRight (registerTexture "a" table)
      (completed, (slot, _)) ← expectRight (completeTexture handle registered)
      (bound, _) ← expectRight (bindVersion none completed)
      released ← expectRight (releaseTexture handle bound)
      snd (reclaimSlots none released) `shouldBe` [(slot, "a")]

    it "reuses a released slot only once no live version maps it: not while a batch holds a version mapping it, nor while the current version is still bindable" $ do
      let table = fresh 3 2
      (registered, handle) ← expectRight (registerTexture "a" table)
      (completed, (slot, _)) ← expectRight (completeTexture handle registered)
      (bound, mapping) ← expectRight (bindVersion none completed)
      -- The current version maps the slot and is still bindable: live.
      mappedSlots none bound `shouldSatisfy` Set.member slot
      released ← expectRight (releaseTexture handle bound)
      -- A batch holds the version that maps it, so it stays retiring, with
      -- or without a new version published.
      let held = heldBy [bindingVersion mapping]
      retiringSlots (fst (reclaimSlots held released)) `shouldBe` [slot]
      (republished, _) ← expectRight (bindVersion held released)
      let (stillHeld, none') = reclaimSlots held republished
      none' `shouldBe` []
      retiringSlots stillHeld `shouldBe` [slot]
      -- Once that batch's version is free, the slot is reclaimed with what
      -- was kept for it, and can be registered into again.
      let (reclaimed, freed) = reclaimSlots none stillHeld
      freed `shouldBe` [(slot, "a")]
      Set.member slot (freeSlots reclaimed) `shouldBe` True
      (reregistered, again) ← expectRight (registerTexture "b" reclaimed)
      handleStanding again reregistered `shouldBe` HandlePending slot

    it "preserves an earlier batch's valid mapping across release and index reuse: its version still resolves the old handle to the old slot" $ do
      let table = fresh 4 2
      (registered, old) ← expectRight (registerTexture "a" table)
      (completed, (oldSlot, _)) ← expectRight (completeTexture old registered)
      (bound, earlier) ← expectRight (bindVersion none completed)
      released ← expectRight (releaseTexture old bound)
      (reused, new) ← expectRight (registerTexture "b" released)
      handleIndex new `shouldBe` handleIndex old
      (_, later) ← expectRight (bindVersion (heldBy [bindingVersion earlier]) reused)
      let frozen = maybe Map.empty id (bindingWrite earlier)
          current = maybe Map.empty id (bindingWrite later)
      -- The earlier batch's version still resolves the old handle to its
      -- slot; the new version resolves it to nothing but the placeholder, and
      -- the new handle to the placeholder until its upload completes.
      resolveHandle 4 frozen old `shouldBe` oldSlot
      resolveHandle 4 current old `shouldBe` 0
      resolveHandle 4 current new `shouldBe` 0
      resolveHandle 4 frozen new `shouldBe` 0
      -- The earlier version still names the released texture as one a batch
      -- binding it must keep; the later one maps no texture yet.
      (afterLater, later') ← expectRight (bindVersion (heldBy [bindingVersion earlier]) reused)
      versionTextures (bindingVersion earlier) afterLater `shouldBe` ["a"]
      versionTextures (bindingVersion later') afterLater `shouldBe` []
  where
    fresh ∷ Integer → Integer → TextureTable String
    fresh slots versions = newTextureTable (either (error . show) id (validateTableConfig 16 slots versions))
    none ∷ Word32 → Bool
    none = const False
    heldBy entries = (`elem` entries)
    written binding = maybe False (const True) (bindingWrite binding)

expectRight ∷ Show e ⇒ Either e a → IO a
expectRight = \case
  Right value → pure value
  Left refusal → expectationFailure ("refused: " <> show refusal) >> fail (show refusal)
