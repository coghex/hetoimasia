-- | The hold ledger: what is owed on a generation or a managed resource, which
-- operations discharge which holds, and the one condition under which anything
-- may be disposed of.
module Test.GPU.Model.Holds (spec) where

import Data.List (sort)
import Hetoimasia.GPU.Model
import Hetoimasia.GPU.Model.Budget (BudgetRequest (requestedFrameSlots), defaultBudgetRequest)
import Hetoimasia.GPU.Model.Identity
import Test.GPU.Model.Support
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain, shouldNotContain, shouldSatisfy)

spec ∷ Spec
spec = describe "holds" $ do
  it "refuses disposal while any single hold remains, and allows it only once the last one ends" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    (framed, frame) ← acquiredFrame target active
    let subject = GenerationSubject generation

    -- A published generation owes its logical release and the end of CPU use
    -- before anything else, and the acquisition added a presentation obligation.
    owed framed subject
      `shouldBe` [LogicalReleaseOwed, CpuUseOwed, PresentationObligationOwed]

    (submitted, answer) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted framed)
    submission ← case answer of
      SubmissionRecorded identity → pure identity
      other → fail ("expected a submission record, got " ++ show other)
    (presented, presentAnswer) ← admitted "presenting" (enqueuePresentation frame PresentationEnqueued submitted)
    presentation ← case presentAnswer of
      PresentationTracked identity → pure identity
      other → fail ("expected a presentation record, got " ++ show other)

    retired ← admitted_ "retiring" (retireGeneration generation presented)
    ended ← admitted_ "ending CPU use" (endGenerationCpuUse generation retired)
    -- Two holds down, two to go. Retirement and ended CPU use are not evidence
    -- that anything the GPU is doing has finished.
    owed ended subject `shouldBe` [SubmittedUseOwed, PresentationObligationOwed]
    disposalEligible subject ended `shouldBe` False

    completed ← admitted_ "completing the submission" (recordCompletion (atMilliseconds 1) (SubmissionCompleted submission) ended)
    owed completed subject `shouldBe` [PresentationObligationOwed]
    disposalEligible subject completed `shouldBe` False

    settled ← admitted_ "retiring the presentation" (recordCompletion (atMilliseconds 2) (PresentationRetired presentation) completed)
    owed settled subject `shouldBe` []
    disposalEligible subject settled `shouldBe` True

  it "never completes a hold the owner has supplied no fact for, however many turns run" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    (framed, frame) ← acquiredFrame target active
    (submitted, _) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted framed)
    retired ← admitted_ "retiring" (retireGeneration generation submitted)
    ended ← admitted_ "ending CPU use" (endGenerationCpuUse generation retired)

    -- An evidence source that proves nothing and disposes of nothing. Thirty-two
    -- turns of it change no hold: elapsed turns are not completion.
    let turns 0 current = current
        turns count current = turns (count - 1 ∷ Int) (fst (runProgressTurn silentEvidence (atMilliseconds 1) current))
        exhausted = turns 32 ended
    owed exhausted (GenerationSubject generation)
      `shouldBe` [SubmittedUseOwed, PresentationObligationOwed]
    disposalEligible (GenerationSubject generation) exhausted `shouldBe` False

    -- And an evidence source that would dispose of anything offered still
    -- disposes of nothing, because nothing is offered.
    let eager = silentEvidence {disposalEvidence = const DisposalCompleted}
        (worked, report) = runProgressTurn eager (atMilliseconds 2) exhausted
    turnDisposed report `shouldBe` []
    disposalEligible (GenerationSubject generation) worked `shouldBe` False

  it "discharges exactly the references a discarded batch held, and no others" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    (resourced, kept) ← aResource 1024 active
    (resourced', discarded) ← aResource 2048 resourced
    (framed, frame) ← acquiredFrame target resourced'
    (recordedKept, keptBatch) ← admitted "recording the kept batch" (recordBatch frame [kept] framed)
    (recordedBoth, discardedBatch) ← admitted "recording the discarded batch" (recordBatch frame [discarded] recordedKept)

    recorded recordedBoth (ResourceSubject kept) `shouldContain` [keptBatch]
    recorded recordedBoth (ResourceSubject discarded) `shouldContain` [discardedBatch]

    dropped ← admitted_ "discarding one batch" (discardBatch discardedBatch recordedBoth)
    recorded dropped (ResourceSubject kept) `shouldBe` [keptBatch]
    recorded dropped (ResourceSubject discarded) `shouldBe` []
    -- The swapchain generation both batches referenced still has the kept
    -- batch's reference, so discarding one did not release it.
    recorded dropped (GenerationSubject generation) `shouldBe` [keptBatch]

  it "discharges every unsubmitted batch of a frame when its recorder is reset, and nothing else" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    (resourced, resource) ← aResource 1024 active
    (first, frameOne) ← acquiredFrame target resourced
    (second, frameTwo) ← acquiredFrame target first
    (recordedOne, batchOne) ← admitted "recording on the first frame" (recordBatch frameOne [resource] second)
    (recordedTwo, batchTwo) ← admitted "recording on the second frame" (recordBatch frameTwo [resource] recordedOne)

    sort (recorded recordedTwo (ResourceSubject resource)) `shouldBe` sort [batchOne, batchTwo]
    reset ← admitted_ "resetting the first recorder" (resetRecorder frameOne recordedTwo)
    -- Only the reset frame's own batch went; the other frame's is untouched.
    recorded reset (ResourceSubject resource) `shouldBe` [batchTwo]
    recorded reset (GenerationSubject generation) `shouldBe` [batchTwo]

  it "gives one submission record to frames submitted together and separate records to frames submitted apart" $ do
    -- Four slots, because this example keeps four frames submitted at once and
    -- a submitted frame holds its slot until its own record completes.
    model ← freshModelWith defaultBudgetRequest {requestedFrameSlots = 4}
    (active, target, _) ← activeTarget 4 model
    (resourced, resource) ← aResource 1024 active
    (first, frameOne) ← acquiredFrame target resourced
    (second, frameTwo) ← acquiredFrame target first
    (recordedOne, _) ← admitted "recording on the first frame" (recordBatch frameOne [resource] second)
    (recordedTwo, _) ← admitted "recording on the second frame" (recordBatch frameTwo [resource] recordedOne)

    (together, togetherAnswer) ←
      admitted "submitting both frames in one call" (submitFrames [frameOne, frameTwo] SubmissionAccepted recordedTwo)
    shared ← case togetherAnswer of
      SubmissionRecorded identity → pure identity
      other → fail ("expected a submission record, got " ++ show other)
    -- One call, one record: the resource both frames referenced owes exactly one
    -- submitted use, and completing it discharges both frames at once.
    submittedOn together (ResourceSubject resource) `shouldBe` [shared]

    -- The same two frames submitted apart owe two records, and completing one
    -- leaves the other owed.
    (firstApart, frameThree) ← acquiredFrame target together
    (secondApart, frameFour) ← acquiredFrame target firstApart
    (recordedThree, _) ← admitted "recording on the third frame" (recordBatch frameThree [resource] secondApart)
    (recordedFour, _) ← admitted "recording on the fourth frame" (recordBatch frameFour [resource] recordedThree)
    (submittedThree, threeAnswer) ← admitted "submitting the third frame" (submitFrames [frameThree] SubmissionAccepted recordedFour)
    (submittedFour, fourAnswer) ← admitted "submitting the fourth frame" (submitFrames [frameFour] SubmissionAccepted submittedThree)
    three ← recordOf threeAnswer
    four ← recordOf fourAnswer
    three `shouldSatisfy` (/= four)
    sort (submittedOn submittedFour (ResourceSubject resource)) `shouldSatisfy` (`shouldContainAll` [shared, three, four])

    discharged ←
      admitted_ "completing the third frame's submission" (recordCompletion (atMilliseconds 1) (SubmissionCompleted three) submittedFour)
    submittedOn discharged (ResourceSubject resource) `shouldNotContain` [three]
    submittedOn discharged (ResourceSubject resource) `shouldContain` [four]

  it "keeps the exact generation a batch recorded when the resource is rebuilt beneath it" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    (resourced, original) ← aResource 1024 active
    (framed, frame) ← acquiredFrame target resourced
    (recordedBatch, batch) ← admitted "recording" (recordBatch frame [original] framed)
    (allocated, allocation) ← admitted "reserving a rebuild" (beginAllocation 2048 1 recordedBatch)
    (rebuilt, replacement) ← admitted "rebuilding the resource" (rebuildResource original allocation allocated)

    replacement `shouldSatisfy` (\identity → resourceGeneration identity == resourceGeneration original + 1)
    -- The recorded batch still names the generation it recorded, which is
    -- therefore still undisposable, while the replacement owes nothing yet.
    recorded rebuilt (ResourceSubject original) `shouldBe` [batch]
    disposalEligible (ResourceSubject original) rebuilt `shouldBe` False
    recorded rebuilt (ResourceSubject replacement) `shouldBe` []

  it "refuses to record against a subject whose release or ended CPU use has been certified" $ do
    model ← freshModel
    (active, target, generation) ← activeTarget 2 model
    (resourced, released) ← aResource 1024 active
    (resourcedAgain, ended) ← aResource 1024 resourced
    (usable, live) ← aResource 1024 resourcedAgain
    (framed, frame) ← acquiredFrame target usable

    -- Both certifications say the same thing in different words: nothing can
    -- record this any more. A batch admitted afterwards would make that false.
    sealedByRelease ← admitted_ "releasing one resource" (releaseResource released framed)
    sealedByCpu ← admitted_ "ending another's CPU use" (endResourceCpuUse ended sealedByRelease)

    rejected "recording a released resource" (recordBatch frame [released] sealedByCpu)
      >>= (`shouldBe` WrongPhase ResourceIdentity)
    rejected "recording a resource whose CPU use ended" (recordBatch frame [ended] sealedByCpu)
      >>= (`shouldBe` WrongPhase ResourceIdentity)
    -- Nothing was charged and nothing was written by either refusal.
    usageBatches (usage sealedByCpu) `shouldBe` 0
    usageObjects (usage sealedByCpu) `shouldBe` usageObjects (usage framed)

    -- The still-live resource records normally, so this is about the
    -- certification and not about recording.
    (recorded', batch) ← admitted "recording a live resource" (recordBatch frame [live] sealedByCpu)
    recorded recorded' (ResourceSubject live) `shouldBe` [batch]
    -- And the batch already recorded survives a later certification.
    afterwards ← admitted_ "releasing it afterwards" (releaseResource live recorded')
    recorded afterwards (ResourceSubject live) `shouldBe` [batch]

    -- The frame's own generation is held to the same rule, proved with a
    -- resource that is still recordable so the generation is what refuses.
    (spare, another) ← aResource 1024 afterwards
    sealedGeneration ← admitted_ "ending the generation's CPU use" (endGenerationCpuUse generation spare)
    rejected "recording into a sealed generation" (recordBatch frame [another] sealedGeneration)
      >>= (`shouldBe` WrongPhase GenerationIdentity)

  it "refuses a rebuild through a retained older identity, so a live generation is never reissued" $ do
    model ← freshModel
    (resourced, first) ← aResource 1024 model
    (allocatedOnce, allocationOnce) ← admitted "reserving a rebuild" (beginAllocation 2048 1 resourced)
    (rebuilt, second) ← admitted "rebuilding once" (rebuildResource first allocationOnce allocatedOnce)
    resourceGeneration second `shouldBe` resourceGeneration first + 1

    -- The older identity still resolves — its generation is live and still
    -- undisposable — but it is no longer the resource's current generation.
    -- Rebuilding through it would insert a second record under the number the
    -- first replacement already holds, reissuing that identity and leaking the
    -- accounting of whichever record it overwrote.
    (allocatedTwice, allocationTwice) ← admitted "reserving another rebuild" (beginAllocation 4096 1 rebuilt)
    rejected "rebuilding through the older identity" (rebuildResource first allocationTwice allocatedTwice)
      >>= (`shouldBe` StaleIdentity ResourceIdentity)
    usageResources (usage allocatedTwice) `shouldBe` 2

    -- The current identity rebuilds, and its successor is the counter's, not the
    -- one the caller happened to hand in.
    (again, third) ← admitted "rebuilding through the current identity" (rebuildResource second allocationTwice allocatedTwice)
    resourceGeneration third `shouldBe` resourceGeneration second + 1
    usageResources (usage again) `shouldBe` 3

    -- A released current generation is not a rebuild candidate either.
    (allocatedThrice, allocationThrice) ← admitted "reserving once more" (beginAllocation 1024 1 again)
    released ← admitted_ "releasing the current generation" (releaseResource third allocatedThrice)
    rejected "rebuilding a released generation" (rebuildResource third allocationThrice released)
      >>= (`shouldBe` AlreadyConsumed ResourceIdentity)

  it "settles a resource only when its release, its CPU use and every record naming it have ended" $ do
    model ← freshModel
    (active, target, _) ← activeTarget 2 model
    (resourced, resource) ← aResource 1024 active
    (framed, frame) ← acquiredFrame target resourced
    (recordedBatch, _) ← admitted "recording" (recordBatch frame [resource] framed)
    (submittedFrame, answer) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted recordedBatch)
    submission ← recordOf answer

    released ← admitted_ "releasing" (releaseResource resource submittedFrame)
    ended ← admitted_ "ending CPU use" (endResourceCpuUse resource released)
    owed ended (ResourceSubject resource) `shouldBe` [SubmittedUseOwed]
    settled ← admitted_ "completing" (recordCompletion (atMilliseconds 1) (SubmissionCompleted submission) ended)
    owed settled (ResourceSubject resource) `shouldBe` []
    disposalEligible (ResourceSubject resource) settled `shouldBe` True
  where
    view subject model = case holdView subject model of
      Nothing → error "the fixture's subject should belong to this model"
      Just value → value
    owed model subject = viewOutstanding (view subject model)
    recorded model subject = viewRecorded (view subject model)
    submittedOn model subject = viewSubmitted (view subject model)
    recordOf = \case
      SubmissionRecorded identity → pure identity
      other → fail ("expected a submission record, got " ++ show other)
    shouldContainAll haystack needles = all (`elem` haystack) needles
