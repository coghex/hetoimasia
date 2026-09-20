-- | D-7's failure policy: what an unsafe authoritative failure ends, and what
-- a handled one leaves running.
module Test.Lua.Protocol.Failure (spec) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Word (Word64)
import GHC.Stack (HasCallStack)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Failure
  ( ReasonCode (AuthoritativeFault, ScriptFault)
  , RecoverySafety (RecoverySafe, RecoveryUnsafe)
  , failureReason
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( EndpointId (EndpointId)
  , RequestName (RequestName)
  , TaskId (TaskId)
  , firstTaskName
  , taskName
  , SnapshotId (SnapshotId)
  , SubscriptionName (SubscriptionName)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits
  ( Limits (maxRetainedResults)
  , LimitName (RetainedResults)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request
  ( CancelCause (CancelledBySessionFailure, CancelledByTaskInvalidation)
  , RequestRecord (requestProviderOutstanding, requestResultHeld, requestSettlement)
  , Settlement (SettledCancelled)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session
  ( AdmissionState (AdmissionOpen, MutationAdmissionClosed)
  , FailureRecord (FailureRecord, failedLastGoodSnapshot, failedReason, failedRecovery, failedTask)
  , Session (sessionAdmission, sessionFailure, sessionKey, sessionQueued, sessionRequests, sessionReservations, sessionSubscriptions, sessionTasks)
  , SessionRejection (AdmissionIsClosed, CapReached, SessionAlreadyFailed, SessionAlreadyStopped, TaskNotActivated, TaskRetired, TransitionRefused, UnknownTask)
  , TerminalResult (ResultCancelled, ResultFailed)
  , acceptRequest
  , activateNext
  , advanceEpoch
  , applyOutcome
  , cancelTaskIn
  , observeResult
  , registerSubscription
  , reportFailure
  , requestAdmission
  , startSegment
  , stopSession
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription (OverloadPolicy (OrderedEvents))
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task
  ( SegmentOutcome (SegmentCompleted)
  , Task (taskState)
  , TaskFailure (TaskFailure)
  , TaskOutcome (OutcomeCancelled)
  , TaskState (Failed, Ready, Running)
  , TransitionRejection (AlreadyTerminal)
  )
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Lua.Protocol.Support
  ( admission
  , observingAdmission
  , ok
  , openSession
  , openSessionWith
  , otherSession
  , rejected
  , roomyLimits
  , runningTask
  , sampleLimits
  )

handled ∷ FailureRecord
handled =
  FailureRecord
    { failedTask = Nothing
    , failedReason = failureReason ScriptFault "the behaviour raised"
    , failedRecovery = RecoverySafe
    , failedLastGoodSnapshot = Just (SnapshotId 7)
    }

unsafeAuthoritative ∷ FailureRecord
unsafeAuthoritative =
  handled
    { failedReason = failureReason AuthoritativeFault "half-applied"
    , failedRecovery = RecoveryUnsafe
    }

spec ∷ Spec
spec = describe "session failure" $ do
  it "keeps a handled task failure inside the session as data" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, other) ← runningTask 2 a
    (c, ()) ← ok (reportFailure handled {failedTask = Just owner} b)
    sessionFailure c `shouldBe` Nothing
    sessionAdmission c `shouldBe` AdmissionOpen
    fmap taskState (Map.lookup owner (sessionTasks c))
      `shouldBe` Just (Failed (TaskFailure (failedReason handled) RecoverySafe))
    fmap taskState (Map.lookup other (sessionTasks c)) `shouldBe` fmap taskState (Map.lookup other (sessionTasks b))
    (_, result) ← ok (observeResult owner c)
    result `shouldBe` ResultFailed (TaskFailure (failedReason handled) RecoverySafe)

  it "ends the session and invalidates its pending work on an unsafe failure" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, bystander) ← runningTask 2 a
    (c, ownRequest) ← ok (acceptRequest owner (RequestName 1) endpointName b)
    (d, otherRequest) ← ok (acceptRequest bystander (RequestName 2) endpointName c)
    (e, subscription) ← ok (registerSubscription bystander (SubscriptionName 1) endpointName OrderedEvents d)
    (f, _) ← ok (requestAdmission (admission 3) e)
    (g, ()) ← ok (reportFailure unsafeAuthoritative {failedTask = Just owner} f)
    sessionFailure g `shouldBe` Just unsafeAuthoritative {failedTask = Just owner}
    sessionAdmission g `shouldBe` MutationAdmissionClosed
    Map.member subscription (sessionSubscriptions g) `shouldBe` False
    Map.member bystander (sessionTasks g) `shouldBe` False
    length (sessionQueued g) `shouldBe` 0
    revoked g ownRequest `shouldBe` Just (SettledCancelled CancelledByTaskInvalidation)
    revoked g otherRequest `shouldBe` Just (SettledCancelled CancelledBySessionFailure)
    case Map.lookup otherRequest (sessionRequests g) of
      Nothing → fail "the invalidated request lost its provider accounting"
      Just record → do
        requestResultHeld record `shouldBe` False
        requestProviderOutstanding record `shouldBe` True

  it "marks recovery safety and names the last good snapshot on the record" $ do
    session ← openSession
    (a, _) ← runningTask 1 session
    (b, ()) ← ok (reportFailure unsafeAuthoritative a)
    fmap failedRecovery (sessionFailure b) `shouldBe` Just RecoveryUnsafe
    fmap failedLastGoodSnapshot (sessionFailure b) `shouldBe` Just (Just (SnapshotId 7))

  it "keeps the failing task's own result observable" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, ()) ← ok (reportFailure unsafeAuthoritative {failedTask = Just owner} a)
    (_, result) ← ok (observeResult owner b)
    result
      `shouldBe` ResultFailed (TaskFailure (failedReason unsafeAuthoritative) RecoveryUnsafe)

  it "closes mutation admission and leaves reporting admissible" $ do
    session ← openSession
    (a, _) ← runningTask 1 session
    (b, ()) ← ok (reportFailure unsafeAuthoritative a)
    (c, refusal) ← rejected (requestAdmission (admission 5) b)
    refusal `shouldBe` AdmissionIsClosed MutationAdmissionClosed
    (d, reporting) ← ok (requestAdmission (observingAdmission 6) c)
    (e, _) ← ok (activateNext d)
    (_, ()) ← ok (startSegment reporting e)
    pure ()

  it "ends the session for an unsafe failure whose task has already finished" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, ()) ← ok (cancelTaskIn owner a)
    (c, ()) ← ok (reportFailure unsafeAuthoritative {failedTask = Just owner} b)
    sessionFailure c `shouldBe` Just unsafeAuthoritative {failedTask = Just owner}
    sessionAdmission c `shouldBe` MutationAdmissionClosed
    (_, result) ← ok (observeResult owner c)
    result `shouldBe` ResultCancelled

  it "refuses a safe failure naming a task that has already finished" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, ()) ← ok (cancelTaskIn owner a)
    (c, refusal) ← rejected (reportFailure handled {failedTask = Just owner} b)
    refusal `shouldBe` TransitionRefused (AlreadyTerminal OutcomeCancelled)
    sessionFailure c `shouldBe` Nothing
    sessionAdmission c `shouldBe` AdmissionOpen

  it "ends the session for an unsafe failure whose task has been observed away" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, ()) ← ok (cancelTaskIn owner a)
    (c, _) ← ok (observeResult owner b)
    Map.member owner (sessionTasks c) `shouldBe` False
    (d, ()) ← ok (reportFailure unsafeAuthoritative {failedTask = Just owner} c)
    sessionFailure d `shouldBe` Just unsafeAuthoritative {failedTask = Just owner}
    sessionAdmission d `shouldBe` MutationAdmissionClosed

  it "refuses a safe failure naming a task that has been observed away" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, ()) ← ok (applyOutcome owner (SegmentCompleted "done") a)
    (c, _) ← ok (observeResult owner b)
    (d, refusal) ← rejected (reportFailure handled {failedTask = Just owner} c)
    refusal `shouldBe` TaskRetired owner
    sessionFailure d `shouldBe` Nothing
    sessionAdmission d `shouldBe` AdmissionOpen

  it "refuses a failure naming a queued admission, safe or unsafe alike" $ do
    session ← openSession
    (a, queuedOnly) ← ok (requestAdmission (admission 1) session)
    (b, unsafeRefusal) ←
      rejected (reportFailure unsafeAuthoritative {failedTask = Just queuedOnly} a)
    unsafeRefusal `shouldBe` TaskNotActivated queuedOnly
    sessionFailure b `shouldBe` Nothing
    sessionAdmission b `shouldBe` AdmissionOpen
    length (sessionQueued b) `shouldBe` 1
    (c, safeRefusal) ← rejected (reportFailure handled {failedTask = Just queuedOnly} b)
    safeRefusal `shouldBe` TaskNotActivated queuedOnly
    sessionFailure c `shouldBe` Nothing

  it "escalates nothing for a task identity this session does not hold" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, _) ← ok (advanceEpoch a)
    (c, refusal) ← rejected (reportFailure unsafeAuthoritative {failedTask = Just owner} b)
    refusal `shouldBe` UnknownTask owner
    sessionFailure c `shouldBe` Nothing
    sessionAdmission c `shouldBe` AdmissionOpen

  it "escalates nothing for a name this epoch never issued, however low it is" $ do
    session ← openSession
    (a, before) ← runningTask 1 session
    (b, _) ← ok (advanceEpoch a)
    let neverIssued = TaskId (sessionKey b) (taskName before)
    (c, refusal) ← rejected (reportFailure unsafeAuthoritative {failedTask = Just neverIssued} b)
    refusal `shouldBe` UnknownTask neverIssued
    sessionFailure c `shouldBe` Nothing
    sessionAdmission c `shouldBe` AdmissionOpen

  it "settles a safe failure of observing work admitted after the session failed" $ do
    session ← openSessionWith sampleLimits {maxRetainedResults = 2}
    (a, doomed) ← runningTask 1 session
    (b, ()) ← ok (reportFailure unsafeAuthoritative {failedTask = Just doomed} a)
    (c, reporting) ← reportingTask 6 b
    (d, ()) ← ok (reportFailure handled {failedTask = Just reporting} c)
    sessionFailure d `shouldBe` Just unsafeAuthoritative {failedTask = Just doomed}
    sessionKey d `shouldBe` sessionKey c
    sessionAdmission d `shouldBe` MutationAdmissionClosed
    fmap taskState (Map.lookup reporting (sessionTasks d))
      `shouldBe` Just (Failed (TaskFailure (failedReason handled) RecoverySafe))
    sessionReservations d `shouldBe` 2
    (e, stillHeld) ← rejected (requestAdmission (observingAdmission 7) d)
    stillHeld `shouldBe` CapReached RetainedResults 2
    (f, result) ← ok (observeResult reporting e)
    result `shouldBe` ResultFailed (TaskFailure (failedReason handled) RecoverySafe)
    Map.member reporting (sessionTasks f) `shouldBe` False
    sessionReservations f `shouldBe` 1
    (g, _) ← ok (requestAdmission (observingAdmission 7) f)
    (_, stillClosed) ← rejected (requestAdmission (admission 8) g)
    stillClosed `shouldBe` AdmissionIsClosed MutationAdmissionClosed

  it "settles a safe failure of observing work activated but not yet started" $ do
    session ← openSession
    (a, doomed) ← runningTask 1 session
    (b, ()) ← ok (reportFailure unsafeAuthoritative {failedTask = Just doomed} a)
    (c, reporting) ← ok (requestAdmission (observingAdmission 6) b)
    (d, _) ← ok (activateNext c)
    fmap taskState (Map.lookup reporting (sessionTasks d)) `shouldBe` Just Ready
    (e, ()) ← ok (reportFailure handled {failedTask = Just reporting} d)
    sessionFailure e `shouldBe` Just unsafeAuthoritative {failedTask = Just doomed}
    sessionAdmission e `shouldBe` MutationAdmissionClosed
    (f, result) ← ok (observeResult reporting e)
    result `shouldBe` ResultFailed (TaskFailure (failedReason handled) RecoverySafe)
    Map.member reporting (sessionTasks f) `shouldBe` False
    Map.size (sessionTasks f) `shouldBe` 1

  it "invalidates only the settled task's own holdings after the session failed" $ do
    session ← openSessionWith roomyLimits
    (a, doomed) ← runningTask 1 session
    (b, ()) ← ok (reportFailure unsafeAuthoritative {failedTask = Just doomed} a)
    (c, reporting) ← reportingTask 6 b
    (d, bystander) ← reportingTask 7 c
    (e, ownRequest) ← ok (acceptRequest reporting (RequestName 3) endpointName d)
    (f, ownSubscription) ←
      ok (registerSubscription reporting (SubscriptionName 2) endpointName OrderedEvents e)
    (g, otherSubscription) ←
      ok (registerSubscription bystander (SubscriptionName 3) endpointName OrderedEvents f)
    (h, ()) ← ok (reportFailure handled {failedTask = Just reporting} g)
    revoked h ownRequest `shouldBe` Just (SettledCancelled CancelledByTaskInvalidation)
    case Map.lookup ownRequest (sessionRequests h) of
      Nothing → fail "the settled task's request lost its provider accounting"
      Just record → do
        requestResultHeld record `shouldBe` False
        requestProviderOutstanding record `shouldBe` True
    Map.member ownSubscription (sessionSubscriptions h) `shouldBe` False
    Map.member otherSubscription (sessionSubscriptions h) `shouldBe` True
    fmap taskState (Map.lookup bystander (sessionTasks h)) `shouldBe` Just Running

  it "retains every refusal a failed session makes around that settlement" $ do
    session ← openSessionWith roomyLimits
    (a, doomed) ← runningTask 1 session
    (b, ()) ← ok (reportFailure unsafeAuthoritative {failedTask = Just doomed} a)
    (c, reporting) ← reportingTask 6 b
    (d, ()) ← ok (reportFailure handled {failedTask = Just reporting} c)
    refusesUnchanged d (reportFailure handled {failedTask = Just reporting})
    (e, _) ← ok (observeResult reporting d)
    refusesUnchanged e (reportFailure handled {failedTask = Just reporting})
    (f, finished) ← reportingTask 7 e
    (g, ()) ← ok (applyOutcome finished (SegmentCompleted "done") f)
    refusesUnchanged g (reportFailure handled {failedTask = Just finished})
    refusesUnchanged g (reportFailure unsafeAuthoritative {failedTask = Just finished})
    (h, queuedOnly) ← ok (requestAdmission (observingAdmission 8) g)
    refusesUnchanged h (reportFailure handled {failedTask = Just queuedOnly})
    refusesUnchanged h (reportFailure unsafeAuthoritative {failedTask = Just queuedOnly})
    refusesUnchanged h (reportFailure handled)
    refusesUnchanged h (reportFailure unsafeAuthoritative)
    refusesUnchanged h (reportFailure handled {failedTask = Just elsewhere})
    refusesUnchanged h advanceEpoch
    sessionFailure h `shouldBe` Just unsafeAuthoritative {failedTask = Just doomed}
    sessionAdmission h `shouldBe` MutationAdmissionClosed

  it "keeps a stop ahead of the settlement a failed session still allows" $ do
    session ← openSession
    (a, doomed) ← runningTask 1 session
    (b, ()) ← ok (reportFailure unsafeAuthoritative {failedTask = Just doomed} a)
    (c, reporting) ← reportingTask 6 b
    let (stopped, _) = stopSession c
    (d, refusal) ← rejected (reportFailure handled {failedTask = Just reporting} stopped)
    refusal `shouldBe` SessionAlreadyStopped
    d `shouldBe` stopped

  it "offers no retry, restart, or continuation of a failed session" $ do
    session ← openSession
    (a, _) ← runningTask 1 session
    (b, ()) ← ok (reportFailure unsafeAuthoritative a)
    (_, epochRefusal) ← rejected (advanceEpoch b)
    epochRefusal `shouldBe` SessionAlreadyFailed
    (_, secondReport) ← rejected (reportFailure handled b)
    secondReport `shouldBe` SessionAlreadyFailed
  where
    endpointName = EndpointId "provider.sample"
    revoked session identity =
      Map.lookup identity (sessionRequests session) >>= requestSettlement
    elsewhere = TaskId otherSession firstTaskName
    -- | Admit, activate, and start one 'Observing' task, which is the only
    -- work a failed session accepts.
    reportingTask ∷ HasCallStack ⇒ Word64 → Session Text → IO (Session Text, TaskId)
    reportingTask number current = do
      (queued, identity) ← ok (requestAdmission (observingAdmission number) current)
      (active, _) ← ok (activateNext queued)
      (started, ()) ← ok (startSegment identity active)
      pure (started, identity)
    -- | An operation a failed session refuses outright, leaving it as it was.
    refusesUnchanged
      ∷ (HasCallStack, Show a)
      ⇒ Session Text
      → (Session Text → (Session Text, Either SessionRejection a))
      → IO ()
    refusesUnchanged before operation = do
      (after, refusal) ← rejected (operation before)
      refusal `shouldBe` SessionAlreadyFailed
      after `shouldBe` before
