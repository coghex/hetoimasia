-- | Event orderings, driven systematically rather than one story at a time.
--
-- The contracts that broke repeatedly in review were not about single
-- transitions but about the order two of them arrived in: a presentation
-- retiring before or after its submission completed, a recovery attempt falling
-- between the two halves of a cycle, a frame slot recycled before the record
-- that outlived it, a close arriving mid-flight. Each was found one ordering at
-- a time. This module enumerates the bounded legal orderings instead, and
-- checks the model's invariants after /every/ step of /every/ one of them, so
-- that an ordering nobody thought to write down is still covered.
--
-- The three reproductions supplied with the structural repair are kept first and
-- by name, so they can never be silently lost in the enumeration.
module Test.GPU.Model.Sequences (spec) where

import Control.Monad (foldM, forM_, unless)
import Data.List (inits)
import GHC.Stack (HasCallStack)
import Hetoimasia.GPU.Model
import Hetoimasia.GPU.Model.Budget (BudgetRequest (..), byteLimit, defaultBudgetRequest, objectLimit)
import Hetoimasia.GPU.Model.Identity
import Numeric.Natural (Natural)
import Test.GPU.Model.Support
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

-- ---------------------------------------------------------------------------
-- What a script is driving

-- | One target being driven, with whichever records the script has made so far.
data Stage = Stage
  { stageModel ∷ GpuModel
  , stageTarget ∷ TargetId
  , stageFrame ∷ Maybe FrameSlotId
  , stageSubmission ∷ Maybe SubmissionId
  , stagePresentation ∷ Maybe PresentationId
  , stageEpoch ∷ Natural
  }

-- | One named step of a script.
data Step = Step
  { stepName ∷ String
  , stepRun ∷ Stage → IO Stage
  }

spec ∷ Spec
spec = describe "event sequences" $ do
  describe "the reported reproductions" $ do
    it "credits no cycle when a recovery attempt falls between its two halves, presentation first" $ do
      -- The presentation retires, then an attempt is admitted and succeeds, then
      -- the submission completes. The two halves are separated by the attempt,
      -- so together they are not evidence that the target recovered.
      stage ← freshStage
      final ←
        script
          "presentation, attempt, submission"
          [ acquire
          , submit
          , present
          , retirePresentation 100
          , beginAttempt 200
          , succeedAttempt
          , completeSubmission 300
          , turnAt 2000
          ]
          stage
      -- The attempt is spent and stays spent.
      attemptsOf final `shouldBe` 1
      cyclesOf final `shouldBe` 0

    it "credits no cycle when a recovery attempt falls between its two halves, submission first" $ do
      -- The same, the other way round, and with the frame slot recycled by the
      -- submission completing before the attempt — so the surviving half cannot
      -- be remembered on the frame.
      stage ← freshStage
      afterSubmission ←
        script
          "submission first"
          [acquire, submit, present, completeSubmission 100]
          stage
      framesOf afterSubmission `shouldBe` 0
      final ←
        script
          "attempt, presentation"
          [beginAttempt 200, succeedAttempt, retirePresentation 300, turnAt 2000]
          afterSubmission
      attemptsOf final `shouldBe` 1
      cyclesOf final `shouldBe` 0

    it "rouses for replacement demand raised after the backoff was already anchored" $ do
      -- One submitted frame gives the turn something pollable to anchor a
      -- deadline for; a second frame is reserved beside it. The turn then stores
      -- an absolute poll, and only afterwards does the out-of-date result return
      -- that reservation and raise a replacement request. The request is new
      -- work arriving after the anchor, and the anchor must not outlive it.
      model ← freshModelWith request
      (active, target, _) ← activeTarget 4 model
      (framed, held) ← acquiredFrame target active
      (submitted, _) ← admitted "submitting" (submitFrames [held] SubmissionAccepted framed)
      (reserved, frame) ← admitted "reserving" (reserveFrame target submitted)

      let (anchored, _) = runProgressTurn silentEvidence (atMilliseconds 0) reserved
      nextDeadline anchored `shouldBe` TurnAt (atMilliseconds 5)

      (requested, answer) ← admitted "losing the surface" (acquireImage frame AcquireOutOfDate anchored)
      answer `shouldBe` ReplacementRequested
      fmap viewTargetReplacementRequested (targetView target requested) `shouldBe` Just True
      nextDeadline requested `shouldBe` TurnNow

  describe "two presentations in flight" $ do
    it "pairs each half with its own cycle, and credits neither on a mismatch" $ do
      -- The enumeration below drove two frames at once but only checked the
      -- model's invariants, which a mismatch does not break — it produces a
      -- plausible-looking credit instead. So the pairing is asserted here
      -- directly: a half belongs to the cycle its own presentation record names,
      -- and to no other.
      (model, target, first, second) ← twoInFlight
      cyclesOnTarget target model `shouldBe` 2
      attemptsOnTarget target model `shouldBe` 1

      -- One frame's retirement and the *other* frame's rendering. Two halves
      -- have arrived and no cycle has completed, because they are halves of
      -- different cycles.
      mismatched ←
        admitted_ "retiring the first presentation" (recordCompletion (atMilliseconds 1000) (PresentationRetired (flightPresentation first)) model)
          >>= admitted_ "completing the second submission" . recordCompletion (atMilliseconds 1000) (SubmissionCompleted (flightSubmission second))
      cyclesOnTarget target mismatched `shouldBe` 2
      let (waited, _) = runProgressTurn silentEvidence (atMilliseconds 2500) mismatched
      attemptsOnTarget target waited `shouldBe` 1

      -- The halves that complete the pairs do complete them.
      matched ←
        admitted_ "completing the first submission" (recordCompletion (atMilliseconds 2500) (SubmissionCompleted (flightSubmission first)) waited)
          >>= admitted_ "retiring the second presentation" . recordCompletion (atMilliseconds 2500) (PresentationRetired (flightPresentation second))
      cyclesOnTarget target matched `shouldBe` 0
      let (healthy, _) = runProgressTurn silentEvidence (atMilliseconds 3500) matched
      attemptsOnTarget target healthy `shouldBe` 0

    it "completes only the cycle whose record retired, leaving the other waiting" $ do
      (model, target, first, second) ← twoInFlight
      -- Both submissions complete, so each cycle now waits only on its own
      -- presentation. Retiring one must complete one cycle, not both.
      completed ←
        admitted_ "completing the first submission" (recordCompletion (atMilliseconds 1000) (SubmissionCompleted (flightSubmission first)) model)
          >>= admitted_ "completing the second submission" . recordCompletion (atMilliseconds 1000) (SubmissionCompleted (flightSubmission second))
      cyclesOnTarget target completed `shouldBe` 2
      retired ←
        admitted_ "retiring the first presentation" (recordCompletion (atMilliseconds 1000) (PresentationRetired (flightPresentation first)) completed)
      cyclesOnTarget target retired `shouldBe` 1

  describe "recovery against the two completion orders" $
    forM_ recoveryScenarios $ \(name, recovery, expected) ->
      forM_ completionOrders $ \(orderName, order) ->
        it (name ++ ", " ++ orderName) $ do
          stage ← freshStage
          final ← script (name ++ " / " ++ orderName) (recovery ++ [acquire, submit, present] ++ order ++ [turnAt 4000]) stage
          -- Whether the episode got its budget back is the whole question, and
          -- it is answered by the attempt count a healthy second later.
          attemptsOf final `shouldBe` expected
          -- However it was answered, no cycle is left half-finished.
          cyclesOf final `shouldBe` 0

  describe "invariants hold after every step of every ordering" $
    forM_ scripts $ \(name, steps) ->
      it name $ do
        stage ← freshStage
        _ ← script name steps stage
        pure ()

-- ---------------------------------------------------------------------------
-- The enumeration

-- | What an attempt before the cycle leaves the attempt count at, a healthy
-- second after that cycle completes.
--
-- Only an attempt that succeeded may give the budget back, and only a cycle
-- wholly after it counts. These three put the attempt before the whole cycle;
-- the two reproductions above put one in the middle of it, where no ordering of
-- the halves may credit anything.
recoveryScenarios ∷ [(String, [Step], Natural)]
recoveryScenarios =
  [ ("no attempt at all", [], 0)
  , ("an attempt that failed", [beginAttempt 0, failAttempt 0], 1)
  , ("an attempt that succeeded", [beginAttempt 0, succeedAttempt], 0)
  ]

completionOrders ∷ [(String, [Step])]
completionOrders =
  [ ("submission then presentation", [completeSubmission 1000, retirePresentation 1000])
  , ("presentation then submission", [retirePresentation 1000, completeSubmission 1000])
  ]

-- | Bounded legal orderings whose invariants are checked at every step. They
-- cover a frame's whole life, both completion orders, the slot being reused, two
-- frames in flight at once, abandonment, a close arriving in each phase, and
-- replacement demand raised after the schedule has backed off.
scripts ∷ [(String, [Step])]
scripts =
  [ ("a frame completing in either order", [acquire, submit, present, completeSubmission 100, retirePresentation 200])
  , ("a frame completing presentation first", [acquire, submit, present, retirePresentation 100, completeSubmission 200])
  , ("a slot reused after its first frame settles", [acquire, submit, present, completeSubmission 100, retirePresentation 200, acquire, submit, present, completeSubmission 300, retirePresentation 400])
  , ("two frames in flight, finished in the order they started", [acquire, submit, present, acquire, submit, present, completeSubmission 100, retirePresentation 200])
  , ("an unsubmitted frame abandoned and settled", [acquire, skip, settleFrame 100])
  , ("a submitted frame closed before presenting", [acquire, submit, closeFrame, settleFrame 100, completeSubmission 200])
  , ("a close arriving while a frame is reserved", [acquire, closeTargetStep, turnAt 100])
  , ("a close arriving while a presentation is pending", [acquire, submit, present, closeTargetStep, completeSubmission 100, retirePresentation 200, turnAt 300])
  , ("a close arriving while a recovery attempt is outstanding", [beginAttempt 100, closeTargetStep, failAttempt 200, turnAt 300])
  , ("recovery failing three times", [beginAttempt 0, failAttempt 0, beginAttempt 100, failAttempt 100, beginAttempt 600, failAttempt 600, turnAt 700])
  , ("a replacement raised after the schedule backed off", [acquire, submit, turnAt 0, turnAt 5, turnAt 15, replacementDemand, turnAt 20])
  , ("a cycle straddled by an attempt, then a clean one after it", [acquire, submit, present, retirePresentation 100, beginAttempt 200, succeedAttempt, completeSubmission 300, turnAt 1400, acquire, submit, present, completeSubmission 1500, retirePresentation 1500, turnAt 2600])
  ]

-- ---------------------------------------------------------------------------
-- Driving a script

-- | A deliberately small configuration, so a script reaches a bound in a few
-- steps rather than hundreds.
request ∷ BudgetRequest
request =
  defaultBudgetRequest
    { requestedTargetRecords = 2
    , requestedFrameSlots = 2
    , requestedAggregateFrameSlots = 4
    , requestedGenerations = 2
    , requestedImageTracking = 4
    , requestedObjects = 64
    , requestedBytes = 65536
    }

freshStage ∷ HasCallStack ⇒ IO Stage
freshStage = do
  model ← freshModelWith request
  (active, target, _) ← activeTarget 4 model
  pure
    Stage
      { stageModel = active
      , stageTarget = target
      , stageFrame = Nothing
      , stageSubmission = Nothing
      , stagePresentation = Nothing
      , stageEpoch = 0
      }

-- | Run a script, checking the model's invariants after every step. A failure
-- names the script and the prefix of steps that reached the broken state, so the
-- shortest reproduction is in the message rather than left to be rediscovered.
script ∷ HasCallStack ⇒ String → [Step] → Stage → IO Stage
script name steps start = do
  checkInvariants (context []) start
  foldM step start (zip (drop 1 (inits (map stepName steps))) steps)
  where
    step stage (prefix, next) = do
      moved ← stepRun next stage
      checkInvariants (context prefix) moved
      pure moved
    context prefix = name ++ " after [" ++ unwords prefix ++ "]"

-- | Everything that must be true of the model whatever has happened to it.
checkInvariants ∷ HasCallStack ⇒ String → Stage → IO ()
checkInvariants context stage = do
  -- Nothing is offered for disposal while it still owes something. This is the
  -- contract the whole hold ledger exists for.
  let (disposed, report) = reclaimPass (silentEvidence {disposalEvidence = const DisposalCompleted}) model
  forM_ (reclaimDisposed report) $ \subject →
    unless (maybe False (null . viewOutstanding) (holdView subject model)) $
      expectationFailure (context ++ ": " ++ show subject ++ " was disposed of while it still owed something")
  seq disposed (pure ())

  -- Accounting stays inside the configuration it was validated against.
  usageObjects (usage model) `shouldSatisfy` (<= objectLimitOf model)
  usageBytes (usage model) `shouldSatisfy` (<= byteLimitOf model)

  -- Storage is a function of the configuration, not of how much has happened.
  liveRecordCount model `shouldSatisfy` (<= 64)

  -- Silence about the schedule means there is genuinely nothing to do.
  case nextDeadline model of
    NoTurnNeeded
      | pendingObligations model > 0 →
          expectationFailure (context ++ ": the schedule reported nothing to do while work was pending")
    _ → pure ()

  -- Epochs never repeat, so evidence stamped with one can always be told apart
  -- from evidence stamped with another.
  case fmap viewTargetRecoveryEpoch (targetView (stageTarget stage) model) of
    Just epoch
      | epoch < stageEpoch stage →
          expectationFailure (context ++ ": a recovery epoch went backwards")
    _ → pure ()

  -- A cycle is held per presentation record, so it cannot outgrow the pool.
  case fmap viewTargetCycles (targetView (stageTarget stage) model) of
    Just cycles
      | cycles > 8 →
          expectationFailure (context ++ ": more cycles are in flight than the pool can hold")
    _ → pure ()
  where
    model = stageModel stage

objectLimitOf ∷ GpuModel → Natural
objectLimitOf = objectLimit . modelBudgets

byteLimitOf ∷ GpuModel → Natural
byteLimitOf = byteLimit . modelBudgets

-- ---------------------------------------------------------------------------
-- The steps

acquire ∷ Step
acquire = Step "acquire" $ \stage → do
  (model, frame) ← acquiredFrame (stageTarget stage) (stageModel stage)
  pure stage {stageModel = model, stageFrame = Just frame}

submit ∷ Step
submit = Step "submit" $ \stage → do
  frame ← required "submit" (stageFrame stage)
  (model, answer) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted (stageModel stage))
  case answer of
    SubmissionRecorded identity → pure stage {stageModel = model, stageSubmission = Just identity}
    other → fail ("submitting should have recorded a submission, got " ++ show other)

present ∷ Step
present = Step "present" $ \stage → do
  frame ← required "present" (stageFrame stage)
  (model, answer) ← admitted "presenting" (enqueuePresentation frame PresentationEnqueued (stageModel stage))
  case answer of
    PresentationTracked identity → pure stage {stageModel = model, stagePresentation = Just identity}
    other → fail ("presenting should have tracked a presentation, got " ++ show other)

completeSubmission ∷ Natural → Step
completeSubmission at = Step "complete" $ \stage → do
  submission ← required "complete" (stageSubmission stage)
  model ← admitted_ "completing" (recordCompletion (atMilliseconds at) (SubmissionCompleted submission) (stageModel stage))
  pure stage {stageModel = model, stageSubmission = Nothing}

retirePresentation ∷ Natural → Step
retirePresentation at = Step "retire" $ \stage → do
  presentation ← required "retire" (stagePresentation stage)
  model ← admitted_ "retiring" (recordCompletion (atMilliseconds at) (PresentationRetired presentation) (stageModel stage))
  pure stage {stageModel = model, stagePresentation = Nothing}

skip ∷ Step
skip = Step "skip" $ \stage → do
  frame ← required "skip" (stageFrame stage)
  model ← admitted_ "skipping" (skipUnsubmittedFrame frame (stageModel stage))
  pure stage {stageModel = model}

closeFrame ∷ Step
closeFrame = Step "close-frame" $ \stage → do
  frame ← required "close-frame" (stageFrame stage)
  model ← admitted_ "closing the frame" (closeSubmittedFrame frame (stageModel stage))
  pure stage {stageModel = model}

settleFrame ∷ Natural → Step
settleFrame at = Step "settle" $ \stage → do
  frame ← required "settle" (stageFrame stage)
  model ← admitted_ "settling" (recordCompletion (atMilliseconds at) (UnpresentedFrameSettled frame) (stageModel stage))
  pure stage {stageModel = model}

beginAttempt ∷ Natural → Step
beginAttempt at = Step "begin-recovery" $ \stage → do
  (model, _) ← admitted "beginning recovery" (beginTargetRecovery (atMilliseconds at) (stageTarget stage) (stageModel stage))
  pure stage {stageModel = model, stageEpoch = epochOf model (stageTarget stage)}

failAttempt ∷ Natural → Step
failAttempt at = Step "fail-recovery" $ \stage → do
  model ← admitted_ "failing recovery" (recordRecoveryFailure (atMilliseconds at) (stageTarget stage) (stageModel stage))
  pure stage {stageModel = model}

succeedAttempt ∷ Step
succeedAttempt = Step "succeed-recovery" $ \stage → do
  model ← admitted_ "succeeding recovery" (recordRecoverySuccess (stageTarget stage) (stageModel stage))
  pure stage {stageModel = model}

closeTargetStep ∷ Step
closeTargetStep = Step "close-target" $ \stage → do
  model ← admitted_ "closing the target" (closeTarget (stageTarget stage) (stageModel stage))
  pure stage {stageModel = model}

replacementDemand ∷ Step
replacementDemand = Step "replacement" $ \stage → do
  (reserved, frame) ← admitted "reserving" (reserveFrame (stageTarget stage) (stageModel stage))
  (model, answer) ← admitted "losing the surface" (acquireImage frame AcquireOutOfDate reserved)
  answer `shouldBe` ReplacementRequested
  pure stage {stageModel = model}

turnAt ∷ Natural → Step
turnAt at = Step "turn" $ \stage →
  pure stage {stageModel = fst (runProgressTurn silentEvidence (atMilliseconds at) (stageModel stage))}

-- ---------------------------------------------------------------------------
-- Reading a stage

required ∷ HasCallStack ⇒ String → Maybe a → IO a
required what = maybe (fail ("the script reached " ++ what ++ " with nothing to apply it to")) pure

attemptsOf ∷ Stage → Natural
attemptsOf stage = maybe 0 viewTargetRecoveryAttempts (targetView (stageTarget stage) (stageModel stage))

cyclesOf ∷ Stage → Natural
cyclesOf stage = maybe 0 viewTargetCycles (targetView (stageTarget stage) (stageModel stage))

framesOf ∷ Stage → Natural
framesOf stage = maybe 0 viewTargetFrames (targetView (stageTarget stage) (stageModel stage))

epochOf ∷ GpuModel → TargetId → Natural
epochOf model target = maybe 0 viewTargetRecoveryEpoch (targetView target model)

-- ---------------------------------------------------------------------------
-- Two frames in flight at once

-- | One frame's records, for an example that needs to tell two apart.
data Flight = Flight
  { flightSubmission ∷ SubmissionId
  , flightPresentation ∷ PresentationId
  }

-- | A target with a successful recovery behind it and two presentations
-- enqueued, each waiting on its own submission.
twoInFlight ∷ HasCallStack ⇒ IO (GpuModel, TargetId, Flight, Flight)
twoInFlight = do
  model ← freshModelWith request
  (active, target, _) ← activeTarget 4 model
  (begun, _) ← admitted "an attempt" (beginTargetRecovery (atMilliseconds 0) target active)
  recovered ← admitted_ "succeeding" (recordRecoverySuccess target begun)
  (afterFirst, first) ← enqueueOne target recovered
  (afterSecond, second) ← enqueueOne target afterFirst
  pure (afterSecond, target, first, second)

enqueueOne ∷ HasCallStack ⇒ TargetId → GpuModel → IO (GpuModel, Flight)
enqueueOne target model = do
  (framed, frame) ← acquiredFrame target model
  (submitted, submitAnswer) ← admitted "submitting" (submitFrames [frame] SubmissionAccepted framed)
  submission ← case submitAnswer of
    SubmissionRecorded identity → pure identity
    other → fail ("expected a submission record, got " ++ show other)
  (presented, presentAnswer) ← admitted "presenting" (enqueuePresentation frame PresentationEnqueued submitted)
  presentation ← case presentAnswer of
    PresentationTracked identity → pure identity
    other → fail ("expected a presentation record, got " ++ show other)
  pure (presented, Flight {flightSubmission = submission, flightPresentation = presentation})

cyclesOnTarget ∷ TargetId → GpuModel → Natural
cyclesOnTarget target model = maybe 0 viewTargetCycles (targetView target model)

attemptsOnTarget ∷ TargetId → GpuModel → Natural
attemptsOnTarget target model = maybe 0 viewTargetRecoveryAttempts (targetView target model)
