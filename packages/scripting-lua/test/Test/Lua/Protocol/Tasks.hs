-- | The task state machine: every state it reaches, and every way it refuses.
--
-- The first two examples are the transition table itself, driven as data so
-- the accepted and refused entries are read off one list rather than spread
-- over a dozen examples that each assert one cell.
module Test.Lua.Protocol.Tasks (spec) where

import Data.Text (Text)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Failure
  ( ReasonCode (ScriptFault)
  , RecoverySafety (RecoverySafe)
  , failureReason
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( BehaviorId (BehaviorId)
  , Ordinal
  , SessionKey
  , TaskId (TaskId)
  , TaskName (TaskName)
  , firstOrdinal
  , nextOrdinal
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits (ServiceClass (OrdinaryClass))
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task
  ( ExpectedState (ExpectedPaused, ExpectedReady, ExpectedRunning, ExpectedWaiting)
  , Readiness (Readiness)
  , SegmentOutcome (SegmentCompleted, SegmentWaiting, SegmentYielded)
  , Task (taskCursor, taskOrdinal, taskSegments, taskState)
  , TaskFailure (TaskFailure)
  , TaskOutcome (OutcomeCancelled, OutcomeCompleted, OutcomeFailed)
  , TaskState (Cancelled, Completed, Failed, Paused, Ready, Running, Waiting)
  , TransitionRejection (AheadOfScope, AlreadyTerminal, ForeignScope, StaleScope, WrongState)
  , WaitCause (WaitingUntil)
  , applySegment
  , cancelTask
  , failTask
  , isTerminal
  , newTask
  , pauseTask
  , resumeTask
  , startTask
  , terminalOutcome
  , wakeTask
  )
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Lua.Protocol.Support (cursor, gameplay, interfaceSide, laterEpoch, otherMod, otherSession)

-- | One named transition, applied in the session's own scope.
type Step = SessionKey → Task Text → Either TransitionRejection (Task Text)

spec ∷ Spec
spec = describe "tasks" $ do
  it "runs the accepted transition table" $ do
    let cases =
          [ ("ready starts", readyTask, startTask', Running)
          , ("running yields to ready", runningTask', yieldStep, Ready)
          , ("running completes", runningTask', completeStep, Completed)
          , ("running waits", runningTask', waitStep, Waiting (WaitingUntil (Readiness 7)))
          , ("waiting wakes to ready", waitingTask, wakeStep, Ready)
          , ("ready pauses", readyTask, pauseTask, Paused)
          , ("paused resumes to ready", pausedTask, resumeStep, Ready)
          , ("ready cancels", readyTask, cancelTask, Cancelled)
          , ("waiting cancels", waitingTask, cancelTask, Cancelled)
          , ("paused cancels", pausedTask, cancelTask, Cancelled)
          , ("running cancels", runningTask', cancelTask, Cancelled)
          , ("ready fails", readyTask, failStep, Failed handledFailure)
          , ("running fails", runningTask', failStep, Failed handledFailure)
          ]
    mapM_ acceptsInto cases

  it "runs the refused transition table" $ do
    let cases =
          [ ("running cannot start", runningTask', startTask', WrongState ExpectedReady Running)
          , ("waiting cannot start", waitingTask, startTask', WrongState ExpectedReady (Waiting (WaitingUntil (Readiness 7))))
          , ("paused cannot start", pausedTask, startTask', WrongState ExpectedReady Paused)
          , ("ready has no segment outcome", readyTask, yieldStep, WrongState ExpectedRunning Ready)
          , ("waiting has no segment outcome", waitingTask, completeStep, WrongState ExpectedRunning (Waiting (WaitingUntil (Readiness 7))))
          , ("ready does not wake", readyTask, wakeStep, WrongState ExpectedWaiting Ready)
          , ("running does not resume", runningTask', resumeStep, WrongState ExpectedPaused Running)
          , ("waiting does not pause", waitingTask, pauseTask, WrongState ExpectedReady (Waiting (WaitingUntil (Readiness 7))))
          ]
    mapM_ refusesWith cases

  it "refuses every transition of a terminal task, whichever terminal it is" $ do
    let terminals =
          [ (completedTask, OutcomeCompleted)
          , (cancelledTask, OutcomeCancelled)
          , (failedTask, OutcomeFailed)
          ]
        steps = [startTask', yieldStep, completeStep, wakeStep, pauseTask, resumeStep, cancelTask, failStep]
    sequence_
      [ step gameplay task `shouldBe` Left (AlreadyTerminal outcome)
      | (task, outcome) ← terminals
      , step ← steps
      ]

  it "gives a task exactly one terminal outcome" $ do
    let once = do
          finished ← cancelTask gameplay readyTask
          cancelTask gameplay finished
    once `shouldBe` Left (AlreadyTerminal OutcomeCancelled)
    terminalOutcome (taskState completedTask) `shouldBe` Just OutcomeCompleted
    completedTask `shouldSatisfy` (isTerminal . taskState)

  it "advances the cursor only by applying a segment outcome" $ do
    let started = startTask gameplay readyTask
    fmap taskCursor started `shouldBe` Right (cursor 1)
    fmap taskCursor (started >>= applySegment gameplay laterOrdinal (SegmentYielded "moved"))
      `shouldBe` Right "moved"
    fmap taskCursor (started >>= cancelTask gameplay) `shouldBe` Right (cursor 1)
    fmap taskCursor (started >>= failStep gameplay) `shouldBe` Right (cursor 1)

  it "counts a segment for every outcome applied" $ do
    fmap taskSegments (yieldStep gameplay runningTask') `shouldBe` Right 1
    fmap taskSegments (completeStep gameplay runningTask') `shouldBe` Right 1

  it "puts a yielded task behind its ready peers with a fresh ordinal" $ do
    taskOrdinal runningTask' `shouldBe` firstOrdinal
    fmap taskOrdinal (yieldStep gameplay runningTask') `shouldBe` Right laterOrdinal
    fmap taskOrdinal (completeStep gameplay runningTask') `shouldBe` Right firstOrdinal
    fmap taskOrdinal (waitStep gameplay runningTask') `shouldBe` Right firstOrdinal
    fmap taskOrdinal (wakeStep gameplay waitingTask) `shouldBe` Right laterOrdinal
    fmap taskOrdinal (resumeStep gameplay pausedTask) `shouldBe` Right laterOrdinal

  it "refuses a resume offered an earlier epoch of its own session" $ do
    let replaced = newTask (mkTask (laterEpoch gameplay)) (BehaviorId "behaviour") OrdinaryClass (cursor 1) firstOrdinal Nothing
    startTask gameplay replaced
      `shouldBe` Left (StaleScope (laterEpoch gameplay) gameplay)

  it "refuses a transition offered a later epoch than the task's" $
    startTask (laterEpoch gameplay) readyTask
      `shouldBe` Left (AheadOfScope gameplay (laterEpoch gameplay))

  it "refuses a transition offered another owner's or another session's scope" $ do
    startTask interfaceSide readyTask `shouldBe` Left (ForeignScope gameplay interfaceSide)
    startTask otherMod readyTask `shouldBe` Left (ForeignScope gameplay otherMod)
    startTask otherSession readyTask `shouldBe` Left (ForeignScope gameplay otherSession)

  it "reports a wrong scope before a wrong state" $
    startTask otherMod completedTask `shouldBe` Left (ForeignScope gameplay otherMod)
  where
    acceptsInto ∷ (String, Task Text, Step, TaskState) → Expectation
    acceptsInto (label, task, step, expected) =
      (label, fmap taskState (step gameplay task)) `shouldBe` (label, Right expected)
    refusesWith ∷ (String, Task Text, Step, TransitionRejection) → Expectation
    refusesWith (label, task, step, expected) =
      (label, step gameplay task) `shouldBe` (label, Left expected)

-- Fixtures -------------------------------------------------------------------

mkTask ∷ SessionKey → TaskId
mkTask key = TaskId key (TaskName 1)

laterOrdinal ∷ Ordinal
laterOrdinal = nextOrdinal firstOrdinal

readyTask ∷ Task Text
readyTask = newTask (mkTask gameplay) (BehaviorId "behaviour") OrdinaryClass (cursor 1) firstOrdinal Nothing

runningTask' ∷ Task Text
runningTask' = readyTask {taskState = Running}

waitingTask ∷ Task Text
waitingTask = readyTask {taskState = Waiting (WaitingUntil (Readiness 7))}

pausedTask ∷ Task Text
pausedTask = readyTask {taskState = Paused}

completedTask ∷ Task Text
completedTask = readyTask {taskState = Completed}

cancelledTask ∷ Task Text
cancelledTask = readyTask {taskState = Cancelled}

failedTask ∷ Task Text
failedTask = readyTask {taskState = Failed handledFailure}

handledFailure ∷ TaskFailure
handledFailure = TaskFailure (failureReason ScriptFault "raised") RecoverySafe

startTask' ∷ Step
startTask' = startTask

yieldStep ∷ Step
yieldStep key = applySegment key laterOrdinal (SegmentYielded "moved")

completeStep ∷ Step
completeStep key = applySegment key laterOrdinal (SegmentCompleted "final")

waitStep ∷ Step
waitStep key = applySegment key laterOrdinal (SegmentWaiting "held" (WaitingUntil (Readiness 7)))

wakeStep ∷ Step
wakeStep key = wakeTask key laterOrdinal

resumeStep ∷ Step
resumeStep key = resumeTask key laterOrdinal

failStep ∷ Step
failStep key = failTask key handledFailure
