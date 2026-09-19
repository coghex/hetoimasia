-- | Validated limits, bounded admission, and the reservation a result holds.
module Test.Lua.Protocol.Admission (spec) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits
  ( LimitName (ActiveTasks, QueuedAdmissions, RetainedResults)
  , LimitViolation (NonPositiveLimit, NonPositiveQuantum)
  , Limits (limitQuanta, maxActiveTasks, maxQueuedAdmissions, maxRetainedResults)
  , Quanta (ordinaryQuantum)
  , Quantum (Quantum)
  , ServiceClass (OrdinaryClass)
  , validateLimits
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session
  ( Session (sessionReservations, sessionTasks)
  , SessionRejection (CapReached)
  , TerminalResult (ResultCompleted)
  , activateNext
  , applyOutcome
  , observeResult
  , requestAdmission
  , startSegment
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task (SegmentOutcome (SegmentCompleted))
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)
import Test.Lua.Protocol.Support
  ( admission
  , admitted
  , ok
  , openSession
  , rejected
  , sampleLimits
  )

spec ∷ Spec
spec = describe "admission" $ do
  it "answers every violated cap and quantum at construction" $ do
    let broken =
          sampleLimits
            { maxActiveTasks = 0
            , maxQueuedAdmissions = -1
            , limitQuanta = (limitQuanta sampleLimits) {ordinaryQuantum = Quantum 0}
            }
    case validateLimits broken of
      Right _ → expectationFailure "a configuration with three violations was accepted"
      Left violations →
        NonEmpty.toList violations
          `shouldBe` [ NonPositiveLimit ActiveTasks 0
                     , NonPositiveLimit QueuedAdmissions (-1)
                     , NonPositiveQuantum OrdinaryClass 0
                     ]

  it "accepts a configuration whose caps and quanta are all at least one" $
    case validateLimits sampleLimits of
      Right _ → pure () ∷ IO ()
      Left violations → expectationFailure ("rejected: " <> show violations)

  it "issues a distinct task name for every admission it accepts" $ do
    session ← openSession
    (queued, first) ← ok (requestAdmission (admission 1) session)
    (twice, second) ← ok (requestAdmission (admission 1) queued)
    (first == second) `shouldBe` False
    (active, activated) ← ok (activateNext twice)
    activated `shouldBe` first
    (thrice, third) ← ok (requestAdmission (admission 1) active)
    length [name | name ← [first, second, third], name == first] `shouldBe` 1
    Map.size (sessionTasks thrice) `shouldBe` 1

  it "refuses an admission beyond the queued-admission cap" $ do
    session ← openSession
    (one, _) ← ok (requestAdmission (admission 1) session)
    (two, _) ← ok (requestAdmission (admission 2) one)
    (_, refusal) ← rejected (requestAdmission (admission 3) two)
    refusal `shouldBe` CapReached QueuedAdmissions (maxQueuedAdmissions sampleLimits)

  it "refuses an activation beyond the active-task cap" $ do
    session ← openSession
    (a, _) ← admitted 1 session
    (b, _) ← admitted 2 a
    (c, _) ← admitted 3 b
    Map.size (sessionTasks c) `shouldBe` 3
    (d, _) ← ok (requestAdmission (admission 4) c)
    (_, refusal) ← rejected (activateNext d)
    refusal `shouldBe` CapReached ActiveTasks (maxActiveTasks sampleLimits)

  it "refuses an admission beyond the retained-result cap" $ do
    session ← openSession
    (a, _) ← admitted 1 session
    (b, _) ← admitted 2 a
    (c, _) ← admitted 3 b
    (d, _) ← ok (requestAdmission (admission 4) c)
    sessionReservations d `shouldBe` maxRetainedResults sampleLimits
    (_, refusal) ← rejected (requestAdmission (admission 5) d)
    refusal `shouldBe` CapReached RetainedResults (maxRetainedResults sampleLimits)

  it "keeps an unobserved result inside the cap admission already paid for" $ do
    session ← openSession
    (a, first) ← admitted 1 session
    (b, _) ← ok (startSegment first a)
    (c, ()) ← ok (applyOutcome first (SegmentCompleted "done") b)
    sessionReservations c `shouldBe` 1
    (d, _) ← admitted 2 c
    (e, _) ← admitted 3 d
    (f, _) ← ok (requestAdmission (admission 4) e)
    (_, refusal) ← rejected (requestAdmission (admission 5) f)
    refusal `shouldBe` CapReached RetainedResults (maxRetainedResults sampleLimits)

  it "releases the reservation when the terminal result is observed" $ do
    session ← openSession
    (a, first) ← admitted 1 session
    (b, _) ← ok (startSegment first a)
    (c, ()) ← ok (applyOutcome first (SegmentCompleted "done") b)
    (d, _) ← admitted 2 c
    (e, _) ← admitted 3 d
    (f, _) ← ok (requestAdmission (admission 4) e)
    (_, refusal) ← rejected (requestAdmission (admission 5) f)
    refusal `shouldBe` CapReached RetainedResults (maxRetainedResults sampleLimits)
    (observed, result) ← ok (observeResult first f)
    result `shouldBe` ResultCompleted "done"
    sessionReservations observed `shouldBe` 3
    Map.member first (sessionTasks observed) `shouldBe` False
    (admitAgain, _) ← ok (requestAdmission (admission 5) observed)
    sessionReservations admitAgain `shouldBe` 4
