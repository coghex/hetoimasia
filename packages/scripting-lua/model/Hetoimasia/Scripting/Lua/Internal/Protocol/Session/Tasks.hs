-- | Admission and task execution: accepting work into the queue against its
-- caps, activating it, and every transition a task takes until its terminal
-- result is observed.
--
-- Admission is where terminal-result storage is reserved, and observation is
-- where it is released; a terminal outcome in between retires the task
-- through "Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Revocation",
-- which ends everything it held.
module Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Tasks
  ( -- * Admission
    AdmissionRequest (..)
  , requestAdmission
  , activateNext

    -- * Running tasks
  , startSegment
  , applyOutcome
  , wakeTaskIn
  , pauseTaskIn
  , resumeTaskIn
  , cancelTaskIn
  , observeResult
  ) where

import qualified Data.Map.Strict as Map
import Data.Sequence ((|>))
import qualified Data.Sequence as Seq
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( BehaviorId
  , Ordinal
  , SessionKey
  , TaskId (TaskId)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits
  ( Limits (maxActiveTasks, maxQueuedAdmissions, maxRetainedResults)
  , LimitName (ActiveTasks, QueuedAdmissions, RetainedResults)
  , ServiceClass
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request (RequestRecord (requestOwner))
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Revocation (retire)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.State
  ( AdmissionState (AdmissionClosed, MutationAdmissionClosed)
  , Authority (Mutating)
  , Counters (..)
  , QueuedAdmission (..)
  , Session (..)
  , SessionRejection (..)
  , TerminalResult (ResultCancelled, ResultCompleted)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Step
  ( counting
  , discard
  , limitsIn
  , notStopped
  , refuse
  , takeOrdinal
  , takeTaskName
  , transition
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription (Subscription (subscriptionOwner))
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task
  ( Readiness
  , SegmentOutcome (SegmentCompleted, SegmentWaiting, SegmentYielded)
  , Task
  , TransitionRejection
  , WaitCause (WaitingOnRequest, WaitingOnSubscription, WaitingUntil)
  , cancelTask
  , newTask
  , pauseTask
  , resumeTask
  , startTask
  , wakeTask
  )
import qualified Hetoimasia.Scripting.Lua.Internal.Protocol.Task as Task

-- Admission ------------------------------------------------------------------

-- | What a caller asks the session to admit.
--
-- It does not name the task. The session issues the 'TaskName' and answers the
-- 'TaskId' it built, because a name a caller chose could be one this session
-- has already used and forgotten, and an outcome addressed to that earlier
-- task would land on this one.
data AdmissionRequest v = AdmissionRequest
  { admitBehavior ∷ !BehaviorId
  , admitService ∷ !ServiceClass
  , admitAuthority ∷ !Authority
  , admitCursor ∷ v
  , admitReadiness ∷ !(Maybe Readiness)
  }
  deriving (Eq, Show)

-- | Accept an admission into the queue, reserving its terminal-result storage.
--
-- The reservation is taken here rather than at completion, which is what makes
-- the storage bound hold for a result nobody observes: the session refused the
-- admission earlier rather than storing a result it had not budgeted for.
requestAdmission
  ∷ AdmissionRequest v
  → Session v
  → (Session v, Either SessionRejection TaskId)
requestAdmission wanted session = case admissionCheck of
  Left rejection → (counting rejectedAdmission session, Left rejection)
  Right () →
    let (name, named) = takeTaskName session
        (ordinal, taken) = takeOrdinal named
        identity = TaskId (sessionKey session) name
        queued =
          QueuedAdmission
            { queuedTask = identity
            , queuedBehavior = admitBehavior wanted
            , queuedService = admitService wanted
            , queuedAuthority = admitAuthority wanted
            , queuedCursor = admitCursor wanted
            , queuedReadiness = admitReadiness wanted
            , queuedOrdinal = ordinal
            }
     in ( taken
            { sessionQueued = sessionQueued taken |> queued
            , sessionReservations = sessionReservations taken + 1
            }
        , Right identity
        )
  where
    limits = limitsIn session
    rejectedAdmission counters =
      counters {countRejectedAdmissions = countRejectedAdmissions counters + 1}
    admissionCheck = do
      notStopped session
      case sessionAdmission session of
        AdmissionClosed → Left (AdmissionIsClosed AdmissionClosed)
        MutationAdmissionClosed
          | admitAuthority wanted == Mutating →
              Left (AdmissionIsClosed MutationAdmissionClosed)
        _ → Right ()
      if sessionReservations session >= maxRetainedResults limits
        then Left (CapReached RetainedResults (maxRetainedResults limits))
        else Right ()
      if Seq.length (sessionQueued session) >= maxQueuedAdmissions limits
        then Left (CapReached QueuedAdmissions (maxQueuedAdmissions limits))
        else Right ()

-- | Move the oldest queued admission into the ready set.
--
-- It keeps the ordinal it was given when it was accepted, so activation does
-- not reorder what admission ordered.
activateNext ∷ Session v → (Session v, Either SessionRejection TaskId)
activateNext session = case notStopped session of
  Left rejection → refuse session rejection
  Right () → case Seq.viewl (sessionQueued session) of
    Seq.EmptyL → refuse session NothingQueued
    queued Seq.:< rest
      | Map.size (sessionTasks session) >= maxActiveTasks limits →
          refuse session (CapReached ActiveTasks (maxActiveTasks limits))
      | otherwise →
          let task =
                newTask
                  (queuedTask queued)
                  (queuedBehavior queued)
                  (queuedService queued)
                  (queuedCursor queued)
                  (queuedOrdinal queued)
                  (queuedReadiness queued)
           in ( session
                  { sessionQueued = rest
                  , sessionTasks =
                      Map.insert (queuedTask queued) task (sessionTasks session)
                  }
              , Right (queuedTask queued)
              )
  where
    limits = limitsIn session

-- Running tasks --------------------------------------------------------------

-- | Begin a segment for a ready task.
startSegment ∷ TaskId → Session v → (Session v, Either SessionRejection ())
startSegment identity session = case notStopped session of
  Left rejection → refuse session rejection
  Right () → discard (transition identity (startTask (sessionKey session)) session)

-- | Apply a segment's outcome, which is the only way a cursor advances.
--
-- A 'SegmentWaiting' outcome is checked against the record it names: a task
-- may only wait on a request or a subscription of this epoch that it owns.
applyOutcome
  ∷ TaskId
  → SegmentOutcome v
  → Session v
  → (Session v, Either SessionRejection ())
applyOutcome identity outcome session = case preconditions of
  Left rejection → refuse session rejection
  Right () → case transition identity step session of
    (next, Left rejection) → (next, Left rejection)
    (next, Right _) →
      let advanced = advanceOrdinalAfterYield outcome next
       in case outcome of
            SegmentCompleted final → (retire identity (ResultCompleted final) advanced, Right ())
            _ → (advanced, Right ())
  where
    (ordinal, _) = takeOrdinal session
    step = Task.applySegment (sessionKey session) ordinal outcome
    preconditions = do
      notStopped session
      case outcome of
        SegmentWaiting _ (WaitingOnRequest wanted) →
          case Map.lookup wanted (sessionRequests session) of
            Nothing → Left (UnknownRequest wanted)
            Just record
              | requestOwner record /= identity →
                  Left (NotTaskOwner (requestOwner record) identity)
              | otherwise → Right ()
        SegmentWaiting _ (WaitingOnSubscription wanted) →
          case Map.lookup wanted (sessionSubscriptions session) of
            Nothing → Left (UnknownSubscription wanted)
            Just record
              | subscriptionOwner record /= identity →
                  Left (NotTaskOwner (subscriptionOwner record) identity)
              | otherwise → Right ()
        SegmentWaiting _ (WaitingUntil _) → Right ()
        SegmentYielded _ → Right ()
        SegmentCompleted _ → Right ()

-- | The ordinal a yielding outcome consumed, kept so a later admission does
-- not reuse it.
--
-- 'applyOutcome' peeks at the next ordinal before the transition so it can
-- hand one to a yield; this advances the counter once the transition stood.
advanceOrdinalAfterYield ∷ SegmentOutcome v → Session v → Session v
advanceOrdinalAfterYield (SegmentYielded _) session = snd (takeOrdinal session)
advanceOrdinalAfterYield _ session = session

-- | Wake a waiting task, behind the peers already ready.
wakeTaskIn ∷ TaskId → Session v → (Session v, Either SessionRejection ())
wakeTaskIn identity session = case notStopped session of
  Left rejection → refuse session rejection
  Right () → withFreshOrdinal identity wakeTask session

-- | Pause a ready task.
pauseTaskIn ∷ TaskId → Session v → (Session v, Either SessionRejection ())
pauseTaskIn identity session = case notStopped session of
  Left rejection → refuse session rejection
  Right () → discard (transition identity (pauseTask (sessionKey session)) session)

-- | Resume a paused task, behind the peers already ready.
resumeTaskIn ∷ TaskId → Session v → (Session v, Either SessionRejection ())
resumeTaskIn identity session = case notStopped session of
  Left rejection → refuse session rejection
  Right () → withFreshOrdinal identity resumeTask session

-- | Apply a transition that rejoins the ready set, consuming an ordinal only
-- if it stands.
--
-- A refused wake or resume must leave the session exactly as it was, and the
-- ordinal counter is part of "as it was": an ordinal spent on a transition
-- that did not happen would reorder the work that is admitted next against a
-- sequence of inputs that never included the refusal.
withFreshOrdinal
  ∷ TaskId
  → (SessionKey → Ordinal → Task v → Either TransitionRejection (Task v))
  → Session v
  → (Session v, Either SessionRejection ())
withFreshOrdinal identity step session =
  let (ordinal, taken) = takeOrdinal session
   in case transition identity (step (sessionKey session) ordinal) taken of
        (_, Left rejection) → refuse session rejection
        (next, Right _) → (next, Right ())

-- | Cancel a live task and invalidate everything it held.
cancelTaskIn ∷ TaskId → Session v → (Session v, Either SessionRejection ())
cancelTaskIn identity session = case notStopped session of
  Left rejection → refuse session rejection
  Right () → case transition identity (cancelTask (sessionKey session)) session of
    (next, Left rejection) → (next, Left rejection)
    (next, Right _) → (retire identity ResultCancelled next, Right ())

-- | Observe a terminal result, releasing the storage its admission reserved.
--
-- Observing drops the task record as well: a task nobody can ask about again
-- is not occupying an active slot.
observeResult ∷ TaskId → Session v → (Session v, Either SessionRejection (TerminalResult v))
observeResult identity session = case Map.lookup identity (sessionResults session) of
  Nothing
    | Map.member identity (sessionTasks session) → refuse session (NoTerminalResult identity)
    | otherwise → refuse session (UnknownTask identity)
  Just result →
    ( session
        { sessionResults = Map.delete identity (sessionResults session)
        , sessionTasks = Map.delete identity (sessionTasks session)
        , sessionReservations = sessionReservations session - 1
        }
    , Right result
    )
