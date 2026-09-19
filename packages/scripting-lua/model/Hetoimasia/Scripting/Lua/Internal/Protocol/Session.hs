-- | One owner's session: the aggregate that holds tasks, admissions, requests,
-- and subscriptions together and enforces the bounds between them.
--
-- The single-record modules beside this one decide what one task, one request,
-- or one subscription may do next. This module decides what the /session/ may
-- do: which caps an admission draws on, which records an epoch change
-- invalidates, what a failure closes, and what a stop records. Nothing here
-- reads a clock, forks a thread, or performs IO, and nothing here chooses
-- which task to run — that is LUA-6's, and this model only records what such a
-- choice would need.
--
-- = Shape of every operation
--
-- Each operation takes the session last and answers
-- @('Session' v, 'Either' 'SessionRejection' a)@.
--
-- A rejection never advances the protocol: no task changes state, no cursor
-- moves, no settled slot is overwritten, no event is delivered, and no
-- admission is accepted. That is the guarantee downstream slices may build on,
-- and it is narrower than "a rejection changes nothing", which is not true and
-- should not be relied upon.
--
-- What a rejection may do is record evidence. Always on 'sessionCounters',
-- because how often something was refused is evidence only the session can
-- keep, and in four places on the record the rejection was about:
--
-- * a reply for a request that has __already settled__ is refused and still
--   retires that request's provider accounting, because an answer is evidence
--   the provider finished whether or not anyone was waiting for it (P-7);
-- * a reply whose payload __exceeds the cap__ is refused, its value never
--   stored, and the request still discharged — settled as a provider failure
--   if it was unsettled, counted as a late reply if it was not. A refusal that
--   left the accounting outstanding would hold capacity nothing could release;
-- * a repeated provider completion is refused and counted on the request, as
--   'requestLateCompletions';
-- * a delivery into a full ordered backlog is refused and counted on the
--   subscription, as @subscriptionRejected@.
--
-- The second of those is the only rejection that settles a request, and it is
-- the only place in this module where a refused operation moves a record's
-- protocol state. Everything else above is a counter.
--
-- = Reservations
--
-- 'sessionReservations' counts terminal-result storage taken at admission and
-- released when a terminal result is observed or discarded. It is compared
-- against 'RetainedResults', so a completed task whose result nobody reads
-- keeps occupying the storage its admission already paid for, and the session
-- stops admitting rather than growing. Requests are bounded separately by
-- 'OutstandingRequests', which a request holds until both of its obligations
-- are discharged.
--
-- = Consumption-time identity
--
-- Every record is keyed by an identity that carries its epoch. An epoch change
-- does not have to hunt down replies and events already in flight: they name
-- identities of the old epoch, which are simply not the identities the new
-- epoch issued. A stale reply therefore finds either the retained provider
-- stub it belongs to, or nothing at all, and in neither case can it touch a
-- record of the current epoch. That is the check at consumption that P-9 asks
-- for, and it is structural rather than a comparison somebody has to remember
-- to write.
--
-- = What this module deliberately does not offer
--
-- There is no operation that waits for every task to finish. P-9 refuses one:
-- a subscription or an endless behaviour may never finish, so an application
-- that wants a graceful boundary stops admitting, awaits its own explicit
-- batch, and then stops. 'stopSession' records what was outstanding; it never
-- claims accepted work drained.
--
-- There is also no operation that restarts or continues a failed session.
-- 'advanceEpoch' refuses one, and replacing a failed domain means constructing
-- a new 'Session'.
--
-- = A failed session still reports
--
-- An unsafe failure ends the session's authoritative work: every live task,
-- queued admission, subscription, and pending request of that moment is
-- invalidated, and 'Mutating' admission closes. What stays open is 'Observing'
-- admission, so the owner can admit work that reports on the failure it just
-- had. That is P-8's quiescent failed-session state: alive enough to be asked
-- what happened, and unable to touch authoritative state again.
module Hetoimasia.Scripting.Lua.Internal.Protocol.Session
  ( -- * The session
    Session (..)
  , AdmissionState (..)
  , Authority (..)
  , Counters (..)
  , noCounters
  , newSession

    -- * Terminal results
  , TerminalResult (..)

    -- * Rejections
  , SessionRejection (..)

    -- * Admission
  , AdmissionRequest (..)
  , QueuedAdmission (..)
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

    -- * Requests
  , acceptRequest
  , applyReplyIn
  , cancelRequestIn
  , observeRequestIn
  , completeProviderWorkIn

    -- * Subscriptions
  , registerSubscription
  , unsubscribeIn
  , deliverEvent
  , takeEventIn

    -- * Epochs
  , EpochChange (..)
  , advanceEpoch

    -- * Failure
  , FailureRecord (..)
  , reportFailure

    -- * Stop
  , TaskDisposition (..)
  , RequestDisposition (..)
  , DiscardCounts (..)
  , noDiscards
  , ExitRecord (..)
  , stopSession
  ) where

import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Hetoimasia.Scripting.Lua.Internal.Protocol.Failure
  ( FailureReason
  , ReasonCode (ValidationFault)
  , RecoverySafety (RecoveryUnsafe)
  , failureReason
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( BehaviorId
  , EndpointId
  , Epoch
  , Generation
  , Ordinal
  , RequestId (RequestId, requestScope)
  , RequestName
  , SessionKey (keyEpoch)
  , SnapshotId
  , SubscriptionId (SubscriptionId)
  , SubscriptionName
  , TaskId (TaskId, taskName, taskScope)
  , TaskName
  , firstGeneration
  , firstOrdinal
  , firstTaskName
  , nextEpoch
  , nextGeneration
  , nextOrdinal
  , nextTaskName
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits
  ( Limits (maxActiveTasks, maxOutstandingRequests, maxPayloadBytes, maxQueuedAdmissions, maxRetainedResults, maxSubscriptionQueue, maxSubscriptions)
  , LimitName (ActiveTasks, OutstandingRequests, QueuedAdmissions, RetainedResults, Subscriptions)
  , LimitViolation
  , ServiceClass
  , ValidLimits
  , limitsOf
  , validateLimits
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request
  ( CancelCause (CancelledByEpochChange, CancelledByOwner, CancelledBySessionFailure, CancelledByStop, CancelledByTaskInvalidation)
  , ObserveRejection
  , ProviderRejection
  , Reply (ReplyFailure, ReplyResult)
  , ReplyRejection
  , RequestRecord (requestIdentity, requestOwner, requestProviderOutstanding, requestResultHeld, requestSettlement)
  , Revocation (revokedResult)
  , Settlement
  , SettlementKind
  , applyReply
  , cancelLocally
  , completeProviderWork
  , observeSettlement
  , openRequest
  , requestReclaimable
  , requestSettled
  , revokeInterest
  , settlementKind
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription
  ( Acceptance
  , DeliveryRejection
  , OverloadPolicy
  , Subscription (subscriptionOwner)
  , deliver
  , newSubscription
  , takeDelivery
  , unsubscribe
  )
import qualified Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription as Subscription
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task
  ( Readiness
  , SegmentOutcome (SegmentCompleted, SegmentWaiting, SegmentYielded)
  , Task (taskState)
  , TaskFailure (TaskFailure)
  , TaskOutcome
  , TaskState (Running)
  , Task
  , TransitionRejection (AlreadyTerminal)
  , WaitCause (WaitingOnRequest, WaitingOnSubscription, WaitingUntil)
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
import qualified Hetoimasia.Scripting.Lua.Internal.Protocol.Task as Task
import Hetoimasia.Scripting.Lua.Internal.Protocol.Value (Payload (payloadBytes))

-- | Whether a task mutates authoritative state.
--
-- The distinction exists for one reason: D-7 closes /mutation/ admission when
-- a session fails unsafely, and leaves the session able to keep reporting
-- about itself. A session that closed all admission could not.
data Authority
  = Mutating
  | Observing
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | What the session currently admits.
data AdmissionState
  = -- | Everything.
    AdmissionOpen
  | -- | 'Observing' work only. An unsafe failure leaves the session here.
    MutationAdmissionClosed
  | -- | Nothing. A stop leaves the session here.
    AdmissionClosed
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | What a terminal task left behind.
--
-- Every terminal outcome produces one, not just a completion: the storage was
-- reserved at admission, and a cancelled or failed task is exactly as
-- observable as a completed one.
data TerminalResult v
  = ResultCompleted v
  | ResultCancelled
  | ResultFailed !TaskFailure
  deriving (Eq, Show)

-- | Evidence the session accumulates about what it refused or discarded.
--
-- Counters are session-lifetime and survive an epoch change: they are about
-- the owner's behaviour, not about one generation of its records.
data Counters = Counters
  { countRejectedAdmissions ∷ !Int
  , countDiscardedAdmissions ∷ !Int
  , countDiscardedResults ∷ !Int
  , countDiscardedRequestResults ∷ !Int
  , countLateReplies ∷ !Int
  , countUnknownReplies ∷ !Int
  , countLateProviderCompletions ∷ !Int
  , countOversizePayloads ∷ !Int
  , countRejectedEvents ∷ !Int
  , countCoalescedEvents ∷ !Int
  , countDiscardedEvents ∷ !Int
  , countInvalidatedTasks ∷ !Int
  , countInvalidatedRequests ∷ !Int
  , countInvalidatedSubscriptions ∷ !Int
  }
  deriving (Eq, Show)

-- | A session that has refused and discarded nothing.
noCounters ∷ Counters
noCounters =
  Counters
    { countRejectedAdmissions = 0
    , countDiscardedAdmissions = 0
    , countDiscardedResults = 0
    , countDiscardedRequestResults = 0
    , countLateReplies = 0
    , countUnknownReplies = 0
    , countLateProviderCompletions = 0
    , countOversizePayloads = 0
    , countRejectedEvents = 0
    , countCoalescedEvents = 0
    , countDiscardedEvents = 0
    , countInvalidatedTasks = 0
    , countInvalidatedRequests = 0
    , countInvalidatedSubscriptions = 0
    }

-- | An admission accepted but not yet activated.
data QueuedAdmission v = QueuedAdmission
  { queuedTask ∷ !TaskId
  , queuedBehavior ∷ !BehaviorId
  , queuedService ∷ !ServiceClass
  , queuedAuthority ∷ !Authority
  , queuedCursor ∷ v
  , queuedReadiness ∷ !(Maybe Readiness)
  , queuedOrdinal ∷ !Ordinal
  }
  deriving (Eq, Show)

-- | One owner's session.
data Session v = Session
  { sessionKey ∷ !SessionKey
  , sessionLimits ∷ !ValidLimits
  , sessionAdmission ∷ !AdmissionState
  , sessionTasks ∷ !(Map TaskId (Task v))
  , sessionQueued ∷ !(Seq (QueuedAdmission v))
  , sessionResults ∷ !(Map TaskId (TerminalResult v))
  , sessionReservations ∷ !Int
  , sessionRequests ∷ !(Map RequestId (RequestRecord v))
  , sessionSubscriptions ∷ !(Map SubscriptionId (Subscription v))
  , sessionNextOrdinal ∷ !Ordinal
  , sessionEpochFirstTask ∷ !TaskName
  , sessionNextTask ∷ !TaskName
  , sessionNextGeneration ∷ !Generation
  , sessionCounters ∷ !Counters
  , sessionFailure ∷ !(Maybe FailureRecord)
  , sessionExit ∷ !(Maybe ExitRecord)
  }
  deriving (Eq, Show)

-- | Construct a session over validated limits.
newSession ∷ SessionKey → Limits → Either (NonEmpty LimitViolation) (Session v)
newSession key limits = do
  valid ← validateLimits limits
  pure
    Session
      { sessionKey = key
      , sessionLimits = valid
      , sessionAdmission = AdmissionOpen
      , sessionTasks = Map.empty
      , sessionQueued = Seq.empty
      , sessionResults = Map.empty
      , sessionReservations = 0
      , sessionRequests = Map.empty
      , sessionSubscriptions = Map.empty
      , sessionNextOrdinal = firstOrdinal
      , sessionEpochFirstTask = firstTaskName
      , sessionNextTask = firstTaskName
      , sessionNextGeneration = firstGeneration
      , sessionCounters = noCounters
      , sessionFailure = Nothing
      , sessionExit = Nothing
      }

-- | Why the session refused an operation.
data SessionRejection
  = -- | Admission is closed in this state.
    AdmissionIsClosed !AdmissionState
  | -- | A cap, and the value it is set to.
    CapReached !LimitName !Int
  | -- | A payload's declared size against the cap.
    PayloadTooLarge !Int !Int
  | -- | No such task in this epoch: foreign, stale, or never issued.
    UnknownTask !TaskId
  | -- | A task this session did issue, whose record has been observed and
    -- forgotten. It is not unknown, and it is not live either.
    TaskRetired !TaskId
  | -- | An admission this session accepted that has not been activated. The
    -- task exists as a queued admission and has never run.
    TaskNotActivated !TaskId
  | -- | No such request. A stale or foreign identity looks like this, which is
    -- the point: it is not a record of ours.
    UnknownRequest !RequestId
  | -- | No such subscription, including one already unsubscribed.
    UnknownSubscription !SubscriptionId
  | -- | The record belongs to a different task: its owner, then the claimant.
    NotTaskOwner !TaskId !TaskId
  | -- | The task's own state machine refused.
    TransitionRefused !TransitionRejection
  | -- | The request's slot refused a reply.
    ReplyRefused !ReplyRejection
  | -- | The request's settlement could not be observed.
    ObserveRefused !ObserveRejection
  | -- | Provider completion was refused.
    ProviderRefused !ProviderRejection
  | -- | The subscription refused a delivery.
    DeliveryRefused !DeliveryRejection
  | -- | The task has not produced a terminal result.
    NoTerminalResult !TaskId
  | -- | Nothing is queued to activate.
    NothingQueued
  | -- | The session failed unsafely and does not continue.
    SessionAlreadyFailed
  | -- | The session has stopped.
    SessionAlreadyStopped
  | -- | Nothing is waiting in the subscription's backlog.
    NoDelivery !SubscriptionId
  deriving (Eq, Show)

-- Internal helpers -----------------------------------------------------------

limitsIn ∷ Session v → Limits
limitsIn = limitsOf . sessionLimits

counting ∷ (Counters → Counters) → Session v → Session v
counting change session = session {sessionCounters = change (sessionCounters session)}

refuse ∷ Session v → SessionRejection → (Session v, Either SessionRejection a)
refuse session rejection = (session, Left rejection)

-- | The session has not stopped.
--
-- This is the precondition of every ordinary operation, and it deliberately
-- does not include "has not failed". A session that failed unsafely closes
-- mutation admission and keeps reporting: its observing tasks still run, still
-- ask providers, and still watch endpoints, because a failed gameplay session
-- that could say nothing about itself would be worse than a stopped one.
notStopped ∷ Session v → Either SessionRejection ()
notStopped session = case sessionExit session of
  Just _ → Left SessionAlreadyStopped
  Nothing → Right ()

-- | The session has not reached its terminal failed state.
--
-- Required only by the two operations that would be a continuation of it:
-- advancing its epoch, and reporting a second failure over the first.
notFailed ∷ Session v → Either SessionRejection ()
notFailed session = case sessionFailure session of
  Just record | failedRecovery record == RecoveryUnsafe → Left SessionAlreadyFailed
  _ → Right ()

takeOrdinal ∷ Session v → (Ordinal, Session v)
takeOrdinal session =
  ( sessionNextOrdinal session
  , session {sessionNextOrdinal = nextOrdinal (sessionNextOrdinal session)}
  )

-- | Whether this session issued a task identity /in its current epoch/,
-- whatever became of it.
--
-- Names come from one counter that is never rewound, and an epoch change
-- records where the new epoch's range starts, so "this epoch issued it" is two
-- comparisons and nothing has to be remembered. Both ends matter: without the
-- lower bound, a name this session issued under a /previous/ epoch would pass
-- when paired with the current scope, and an identity nothing ever issued
-- would be treated as one of ours.
--
-- It distinguishes a task whose record has been observed and forgotten from
-- one that is foreign, of a replaced epoch, or was never issued at all — a
-- distinction a failure report turns on, and one that a list of retired
-- identities would otherwise have to grow forever to make.
issuedHere ∷ TaskId → Session v → Bool
issuedHere identity session =
  taskScope identity == sessionKey session
    && taskName identity >= sessionEpochFirstTask session
    && taskName identity < sessionNextTask session

-- | Whether an identity names an admission that is accepted but not activated.
--
-- A queued admission is a task that has not run rather than one that has
-- finished, and telling the two apart is what keeps a failure report about
-- work that never happened from being honoured as one about work that did.
queuedHere ∷ TaskId → Session v → Bool
queuedHere identity session = any ((== identity) . queuedTask) (sessionQueued session)

-- | Issue the next task name.
--
-- Never rewound, and not reset by an epoch change. A task whose result has
-- been observed and whose record has been forgotten therefore cannot have its
-- name handed to another task, which is what keeps a segment outcome
-- addressed to the old one from landing on the new one.
takeTaskName ∷ Session v → (TaskName, Session v)
takeTaskName session =
  ( sessionNextTask session
  , session {sessionNextTask = nextTaskName (sessionNextTask session)}
  )

-- | Issue the next generation, for a request or a subscription identity.
--
-- One counter for both, because its job is only to differ from every
-- generation this session has issued before. A caller may reuse a
-- 'RequestName' or a 'SubscriptionName' freely: the identity the session
-- builds from it is new either way, so a reply or an event still in flight for
-- the record that handle named before cannot reach the record it names now.
takeGeneration ∷ Session v → (Generation, Session v)
takeGeneration session =
  ( sessionNextGeneration session
  , session {sessionNextGeneration = nextGeneration (sessionNextGeneration session)}
  )

-- | Apply a task transition, reporting a missing task and a refused transition
-- with the same shape.
transition
  ∷ TaskId
  → (Task v → Either TransitionRejection (Task v))
  → Session v
  → (Session v, Either SessionRejection (Task v))
transition identity step session = case Map.lookup identity (sessionTasks session) of
  Nothing → refuse session (UnknownTask identity)
  Just task → case step task of
    Left rejection → refuse session (TransitionRefused rejection)
    Right next →
      ( session {sessionTasks = Map.insert identity next (sessionTasks session)}
      , Right next
      )

-- | Record a task's terminal result and invalidate everything it held.
--
-- Called for every terminal outcome. The storage the result occupies was
-- reserved at admission, so nothing is taken here; it is released when the
-- result is observed, or discarded by an invalidation.
retire ∷ TaskId → TerminalResult v → Session v → Session v
retire identity result session =
  invalidateHoldingsOf identity CancelledByTaskInvalidation $
    session {sessionResults = Map.insert identity result (sessionResults session)}

-- | Revoke the requests and subscriptions one task owned.
--
-- Only the requests that still hold a local interest, for the reason
-- 'revocableRequests' gives: an owner that already observed how its request
-- ended has discharged that interest, and the stub left behind carries
-- provider accounting alone. Revoking it again would settle nothing and
-- discard nothing, and still count an invalidation that had already happened.
invalidateHoldingsOf ∷ TaskId → CancelCause → Session v → Session v
invalidateHoldingsOf identity cause session =
  dropSubscriptions (revokeRequests session)
  where
    ownedAndLive record = requestOwner record == identity && requestResultHeld record
    revokeRequests initial =
      foldl'
        (\current record → revokeOne cause (requestIdentity record) current)
        initial
        (Map.elems (Map.filter ownedAndLive (sessionRequests initial)))
    dropSubscriptions current =
      let (ended, kept) =
            Map.partition ((== identity) . subscriptionOwner) (sessionSubscriptions current)
          discarded = sum (fmap unsubscribe (Map.elems ended))
       in counting
            ( \counters →
                counters
                  { countInvalidatedSubscriptions =
                      countInvalidatedSubscriptions counters + Map.size ended
                  , countDiscardedEvents = countDiscardedEvents counters + discarded
                  }
            )
            current {sessionSubscriptions = kept}

-- | Revoke one request's interest, keeping it only for provider accounting.
revokeOne ∷ CancelCause → RequestId → Session v → Session v
revokeOne cause identity session = case Map.lookup identity (sessionRequests session) of
  Nothing → session
  Just record →
    let (revoked, evidence) = revokeInterest cause record
        kept
          | requestReclaimable revoked = Map.delete identity (sessionRequests session)
          | otherwise = Map.insert identity revoked (sessionRequests session)
     in counting
          ( \counters →
              counters
                { countInvalidatedRequests = countInvalidatedRequests counters + 1
                , countDiscardedRequestResults =
                    countDiscardedRequestResults counters
                      + (if revokedResult evidence then 1 else 0)
                }
          )
          session {sessionRequests = kept}

-- | The requests a session-wide invalidation still has something to revoke.
--
-- 'sessionRequests' holds two quite different things. Some entries are live
-- interest: an owner is still entitled to observe how the request ended.
-- Others are stubs kept for provider accounting alone, whose interest was
-- already revoked — by an earlier epoch change, by the invalidation of the
-- task that owned them, or by an owner that observed its cancellation and
-- walked away.
--
-- Only the first kind is invalidated by an epoch change, a session failure, or
-- a stop. Revoking a stub again would settle nothing, discard nothing, and
-- still count an invalidation, so an epoch would report itself as having
-- invalidated work that had already ended before it began.
--
-- A held result reservation is exactly the first kind: it is outstanding while
-- an owner may still observe the settlement, and released the moment one
-- does or an invalidation discards it.
revocableRequests ∷ Session v → [RequestId]
revocableRequests session =
  [ identity
  | (identity, record) ← Map.toList (sessionRequests session)
  , requestScope identity == sessionKey session
  , requestResultHeld record
  ]

-- | Forget a request once both of its obligations are discharged.
reclaim ∷ RequestId → RequestRecord v → Session v → Session v
reclaim identity record session
  | requestReclaimable record =
      session {sessionRequests = Map.delete identity (sessionRequests session)}
  | otherwise =
      session {sessionRequests = Map.insert identity record (sessionRequests session)}

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

discard ∷ (Session v, Either SessionRejection a) → (Session v, Either SessionRejection ())
discard (session, answer) = (session, () <$ answer)

-- Requests -------------------------------------------------------------------

-- | Accept a request for a live task, reserving its bookkeeping.
--
-- The caller supplies its own handle; the session stamps the generation, so a
-- handle reused after its earlier request was reclaimed names a new identity
-- and a reply still travelling for the old one cannot settle this one.
acceptRequest
  ∷ TaskId
  → RequestName
  → EndpointId
  → Session v
  → (Session v, Either SessionRejection RequestId)
acceptRequest owner name endpoint session = case checks of
  Left rejection → refuse session rejection
  Right () →
    let (generation, stamped) = takeGeneration session
        identity = RequestId (sessionKey session) name generation
     in ( stamped
            { sessionRequests =
                Map.insert
                  identity
                  (openRequest identity owner endpoint)
                  (sessionRequests stamped)
            }
        , Right identity
        )
  where
    limits = limitsIn session
    checks = do
      notStopped session
      case Map.lookup owner (sessionTasks session) of
        Nothing → Left (UnknownTask owner)
        Just task
          | isTerminal (taskState task) → Left (UnknownTask owner)
          | otherwise → Right ()
      if Map.size (sessionRequests session) >= maxOutstandingRequests limits
        then Left (CapReached OutstandingRequests (maxOutstandingRequests limits))
        else Right ()

-- | Apply a provider's reply.
--
-- A reply for an identity this session does not hold — a foreign one, or one
-- of an epoch whose records are gone — is rejected as 'UnknownRequest' and
-- counted. It cannot reach a record of the current epoch, because the epoch is
-- part of the identity it was matched on.
--
-- A reply whose declared payload exceeds the cap is refused with
-- 'PayloadTooLarge', and its value is never stored. It still discharges the
-- request: an unsettled request settles as a provider failure naming the
-- overrun, and one that had already settled is counted as a late reply. Either
-- way the provider's work is retired, because a provider that overran still
-- answered, and a refusal that left its accounting outstanding would hold
-- capacity nothing could ever release.
applyReplyIn
  ∷ RequestId
  → Reply v
  → Session v
  → (Session v, Either SessionRejection ())
applyReplyIn identity reply session = case Map.lookup identity (sessionRequests session) of
  Nothing →
    ( counting
        (\counters → counters {countUnknownReplies = countUnknownReplies counters + 1})
        session
    , Left (UnknownRequest identity)
    )
  Just record →
    -- The lookup comes first, and the size check applies only to a payload
    -- that would actually be stored. A reply to a request that has already
    -- settled publishes nothing whatever its size, so refusing it on size
    -- would leave its provider's work outstanding for ever and hold the
    -- capacity that accounting occupies.
    case applyReply (bounded record) record of
      (next, Left rejection) →
        ( counting late (counted (reclaim identity next session))
        , Left (rejectionFor rejection)
        )
      (next, Right ()) → (counted (reclaim identity next session), answer)
  where
    cap = maxPayloadBytes (limitsIn session)
    declared = case reply of
      ReplyResult message → payloadBytes message
      ReplyFailure _ → 0
    oversize = case reply of
      ReplyResult message → payloadBytes message < 0 || payloadBytes message > cap
      ReplyFailure _ → False
    -- An oversize result settles the request as a failure rather than being
    -- turned away. The value is never stored, so the cap still holds; what the
    -- request must not do is stay unsettled for ever because the one provider
    -- that was going to answer it overran.
    bounded record
      | oversize && not (requestSettled record) =
          ReplyFailure (failureReason ValidationFault "the provider's result exceeded the payload cap")
      | otherwise = reply
    late counters = counters {countLateReplies = countLateReplies counters + 1}
    counted current
      | oversize =
          counting
            (\counters → counters {countOversizePayloads = countOversizePayloads counters + 1})
            current
      | otherwise = current
    rejectionFor rejection
      | oversize = PayloadTooLarge declared cap
      | otherwise = ReplyRefused rejection
    answer
      | oversize = Left (PayloadTooLarge declared cap)
      | otherwise = Right ()

-- | Cancel a request at its owner's request.
--
-- Settles the waiter and leaves provider accounting outstanding, so the
-- request keeps its capacity until explicit completion evidence arrives.
cancelRequestIn ∷ RequestId → Session v → (Session v, Either SessionRejection ())
cancelRequestIn identity session = case Map.lookup identity (sessionRequests session) of
  Nothing → refuse session (UnknownRequest identity)
  Just record → case cancelLocally CancelledByOwner record of
    (_, Left rejection) → refuse session (ReplyRefused rejection)
    (next, Right ()) →
      (session {sessionRequests = Map.insert identity next (sessionRequests session)}, Right ())

-- | Observe a request's settlement, releasing only its result storage.
observeRequestIn
  ∷ RequestId
  → Session v
  → (Session v, Either SessionRejection (Settlement v))
observeRequestIn identity session = case Map.lookup identity (sessionRequests session) of
  Nothing → refuse session (UnknownRequest identity)
  Just record → case observeSettlement record of
    Left rejection → refuse session (ObserveRefused rejection)
    Right (settled, next) → (reclaim identity next session, Right settled)

-- | Apply explicit evidence that a provider's work ended.
completeProviderWorkIn ∷ RequestId → Session v → (Session v, Either SessionRejection ())
completeProviderWorkIn identity session = case Map.lookup identity (sessionRequests session) of
  Nothing → refuse session (UnknownRequest identity)
  Just record → case completeProviderWork record of
    (next, Left rejection) →
      ( counting
          ( \counters →
              counters
                { countLateProviderCompletions = countLateProviderCompletions counters + 1
                }
          )
          session {sessionRequests = Map.insert identity next (sessionRequests session)}
      , Left (ProviderRefused rejection)
      )
    (next, Right ()) → (reclaim identity next session, Right ())

-- Subscriptions --------------------------------------------------------------

-- | Register an owned subscription with its endpoint's overload policy.
registerSubscription
  ∷ TaskId
  → SubscriptionName
  → EndpointId
  → OverloadPolicy
  → Session v
  → (Session v, Either SessionRejection SubscriptionId)
registerSubscription owner name endpoint policy session = case checks of
  Left rejection → refuse session rejection
  Right () →
    let (generation, stamped) = takeGeneration session
        identity = SubscriptionId (sessionKey session) name generation
     in ( stamped
            { sessionSubscriptions =
                Map.insert
                  identity
                  (newSubscription identity owner endpoint policy (maxSubscriptionQueue limits))
                  (sessionSubscriptions stamped)
            }
        , Right identity
        )
  where
    limits = limitsIn session
    checks = do
      notStopped session
      case Map.lookup owner (sessionTasks session) of
        Nothing → Left (UnknownTask owner)
        Just task
          | isTerminal (taskState task) → Left (UnknownTask owner)
          | otherwise → Right ()
      if Map.size (sessionSubscriptions session) >= maxSubscriptions limits
        then Left (CapReached Subscriptions (maxSubscriptions limits))
        else Right ()

-- | End a subscription, answering how much backlog was discarded.
unsubscribeIn ∷ SubscriptionId → Session v → (Session v, Either SessionRejection Int)
unsubscribeIn identity session = case Map.lookup identity (sessionSubscriptions session) of
  Nothing → refuse session (UnknownSubscription identity)
  Just record →
    let discarded = unsubscribe record
     in ( counting
            (\counters → counters {countDiscardedEvents = countDiscardedEvents counters + discarded})
            session {sessionSubscriptions = Map.delete identity (sessionSubscriptions session)}
        , Right discarded
        )

-- | Deliver one event to a subscription.
deliverEvent
  ∷ SubscriptionId
  → Payload v
  → Session v
  → (Session v, Either SessionRejection Acceptance)
deliverEvent identity message session
  | payloadBytes message < 0 || payloadBytes message > maxPayloadBytes (limitsIn session) =
      ( counting
          ( \counters →
              counters
                { countOversizePayloads = countOversizePayloads counters + 1
                , countRejectedEvents = countRejectedEvents counters + 1
                }
          )
          session
      , Left (PayloadTooLarge (payloadBytes message) (maxPayloadBytes (limitsIn session)))
      )
  | otherwise = case Map.lookup identity (sessionSubscriptions session) of
      Nothing →
        ( counting
            (\counters → counters {countRejectedEvents = countRejectedEvents counters + 1})
            session
        , Left (UnknownSubscription identity)
        )
      Just record → case deliver message record of
        (next, Left rejection) →
          ( counting
              (\counters → counters {countRejectedEvents = countRejectedEvents counters + 1})
              (store next)
          , Left (DeliveryRefused rejection)
          )
        (next, Right acceptance) →
          ( counting (coalescing acceptance) (store next)
          , Right acceptance
          )
  where
    store next =
      session {sessionSubscriptions = Map.insert identity next (sessionSubscriptions session)}
    coalescing acceptance counters
      | acceptance == Subscription.AcceptedCoalesced =
          counters {countCoalescedEvents = countCoalescedEvents counters + 1}
      | otherwise = counters

-- | Take the oldest retained delivery.
takeEventIn
  ∷ SubscriptionId
  → Session v
  → (Session v, Either SessionRejection (Payload v))
takeEventIn identity session = case Map.lookup identity (sessionSubscriptions session) of
  Nothing → refuse session (UnknownSubscription identity)
  Just record → case takeDelivery record of
    Nothing → refuse session (NoDelivery identity)
    Just (message, next) →
      ( session {sessionSubscriptions = Map.insert identity next (sessionSubscriptions session)}
      , Right message
      )

-- Epochs ---------------------------------------------------------------------

-- | What an epoch change invalidated.
data EpochChange = EpochChange
  { changedFrom ∷ !Epoch
  , changedTo ∷ !Epoch
  , invalidatedTasks ∷ !Int
  , invalidatedAdmissions ∷ !Int
  , invalidatedRequests ∷ !Int
  , invalidatedSubscriptions ∷ !Int
  , retainedProviderWork ∷ ![RequestId]
  }
  deriving (Eq, Show)

-- | Replace this session's generation of records.
--
-- Everything of the previous epoch is invalidated before the new epoch exists
-- to publish anything: tasks, queued admissions, subscriptions, and pending
-- requests. What survives is exactly the accounting for provider work that is
-- not known to have ended, keyed by the old identities, so late evidence can
-- retire it without reaching anything the new epoch issued.
--
-- A failed session is not advanced. Replacing it is constructing a new
-- session, which is what \"no retry, restart, or continuation\" means.
advanceEpoch ∷ Session v → (Session v, Either SessionRejection EpochChange)
advanceEpoch session = case notStopped session >> notFailed session of
  Left rejection → refuse session rejection
  Right () →
    let replacing = revocableRequests session
        revoked =
          foldl'
            (flip (revokeOne CancelledByEpochChange))
            session
            replacing
        retained = Map.keys (sessionRequests revoked)
        discardedResults = Map.size (sessionResults session)
        discardedQueued = Seq.length (sessionQueued session)
        discardedBacklog = sum (fmap unsubscribe (Map.elems (sessionSubscriptions session)))
        next =
          counting
            ( \counters →
                counters
                  { countInvalidatedTasks =
                      countInvalidatedTasks counters + Map.size (sessionTasks session)
                  , countInvalidatedSubscriptions =
                      countInvalidatedSubscriptions counters
                        + Map.size (sessionSubscriptions session)
                  , countDiscardedResults = countDiscardedResults counters + discardedResults
                  , countDiscardedAdmissions = countDiscardedAdmissions counters + discardedQueued
                  , countDiscardedEvents = countDiscardedEvents counters + discardedBacklog
                  }
            )
            revoked
              { sessionKey = replacement
              , sessionEpochFirstTask = sessionNextTask revoked
              , sessionTasks = Map.empty
              , sessionQueued = Seq.empty
              , sessionResults = Map.empty
              , sessionReservations = 0
              , sessionSubscriptions = Map.empty
              }
     in ( next
        , Right
            EpochChange
              { changedFrom = keyEpoch (sessionKey session)
              , changedTo = keyEpoch replacement
              , invalidatedTasks = Map.size (sessionTasks session)
              , invalidatedAdmissions = discardedQueued
              , invalidatedRequests = length replacing
              , invalidatedSubscriptions = Map.size (sessionSubscriptions session)
              , retainedProviderWork = retained
              }
        )
  where
    replacement =
      (sessionKey session) {keyEpoch = nextEpoch (keyEpoch (sessionKey session))}

-- Failure --------------------------------------------------------------------

-- | One reported failure.
--
-- 'failedRecovery' is the whole of the policy decision: 'RecoveryUnsafe' ends
-- the session, 'RecoverySafe' does not. 'failedLastGoodSnapshot' names the
-- snapshot beside which the failure is published; the model stores its
-- identity and never a snapshot, because withholding a new one is not a
-- rollback of anything already mutated.
--
-- What cannot be reported here is a broken host or worker. Such a failure
-- follows supervision's rules, and this model has no shape for one.
data FailureRecord = FailureRecord
  { failedTask ∷ !(Maybe TaskId)
  , failedReason ∷ !FailureReason
  , failedRecovery ∷ !RecoverySafety
  , failedLastGoodSnapshot ∷ !(Maybe SnapshotId)
  }
  deriving (Eq, Show)

-- | Report a failure.
--
-- A failure naming a task fails that task, whose terminal result records it. A
-- failure marked 'RecoveryUnsafe' additionally moves the session to its
-- terminal failed state: mutation admission closes, every live task, queued
-- admission, subscription, and pending request is invalidated, and the record
-- is kept beside the identity of the last good snapshot. Nothing restarts it.
--
-- An unsafe failure whose task has /already/ finished still ends the session.
-- The task keeps the one terminal outcome it reached — nothing here gives it a
-- second — but the session cannot: "the behaviour that touched authoritative
-- state was cancelled a moment ago" is not evidence that the state it touched
-- is consistent, and a failure that arrived after its task settled is exactly
-- the case where it is not. A /safe/ failure naming a finished task is
-- refused, because there is then nothing to record and nothing to end.
--
-- The same holds once the task's record has been /forgotten/. A terminal
-- result that has been observed takes its task's record with it, and a failure
-- naming that identity is neither a live task nor an unknown one:
-- 'issuedHere' tells the two apart in a comparison, an unsafe failure still
-- ends the session, and a safe one is refused as 'TaskRetired'.
--
-- An identity that names a /queued/ admission is refused as
-- 'TaskNotActivated', safe or unsafe alike, and escalates nothing: that task
-- has never run, so it cannot have left authoritative state half-applied, and
-- a report saying it did is wrong rather than urgent.
--
-- Which task is rejected outright is unchanged: an identity this session never
-- issued, or issued under a replaced epoch, is 'UnknownTask' and escalates
-- nothing.
reportFailure ∷ FailureRecord → Session v → (Session v, Either SessionRejection ())
reportFailure record session = case notStopped session >> notFailed session of
  Left rejection → refuse session rejection
  Right () → case failedTask record of
    Nothing → (escalate session, Right ())
    Just identity
      | queuedHere identity session →
          -- A queued admission has never run, so it cannot have touched
          -- authoritative state, and a report that it did is incoherent
          -- whatever its recovery marking says. Refusing it is the answer; a
          -- session terminally failed on an impossible attribution would be a
          -- worse outcome than a caller told its report was wrong.
          refuse session (TaskNotActivated identity)
      | not (Map.member identity (sessionTasks session))
      , issuedHere identity session →
          -- The record has been observed and forgotten, so there is no task
          -- left to fail. The session is a different matter: a report that
          -- authoritative state may be half-applied does not become false
          -- because the behaviour that touched it was tidied away first, and
          -- unlike a queued admission this task did run.
          if unsafe
            then (escalate session, Right ())
            else refuse session (TaskRetired identity)
    Just identity →
      let failure = TaskFailure (failedReason record) (failedRecovery record)
       in case transition identity (failTask (sessionKey session) failure) session of
            (next, Left (TransitionRefused (AlreadyTerminal outcome)))
              | unsafe → (escalate next, Right ())
              | otherwise → (next, Left (TransitionRefused (AlreadyTerminal outcome)))
            (next, Left rejection) → (next, Left rejection)
            (next, Right _) →
              (escalate (retire identity (ResultFailed failure) next), Right ())
  where
    unsafe = failedRecovery record == RecoveryUnsafe
    escalate current
      | not unsafe = current
      | otherwise = invalidateEverything current {sessionFailure = Just record}

-- | Close mutation admission and invalidate every live record.
--
-- A live task that is invalidated is gone, so the terminal-result storage its
-- admission reserved is released and counted as discarded. The tasks that had
-- already finished keep their results: a failed session's job is to report,
-- and it cannot report a result it threw away.
invalidateEverything ∷ Session v → Session v
invalidateEverything session =
  counting
    ( \counters →
        counters
          { countInvalidatedTasks = countInvalidatedTasks counters + Map.size live
          , countInvalidatedSubscriptions =
              countInvalidatedSubscriptions counters + Map.size (sessionSubscriptions session)
          , countDiscardedAdmissions =
              countDiscardedAdmissions counters + Seq.length (sessionQueued session)
          , countDiscardedResults = countDiscardedResults counters + Map.size live
          , countDiscardedEvents = countDiscardedEvents counters + discardedBacklog
          }
    )
    revoked
      { sessionAdmission = closedAdmission
      , sessionTasks = Map.filter (isTerminal . taskState) (sessionTasks session)
      , sessionQueued = Seq.empty
      , sessionSubscriptions = Map.empty
      , sessionReservations =
          sessionReservations session - Map.size live - Seq.length (sessionQueued session)
      }
  where
    live = Map.filter (not . isTerminal . taskState) (sessionTasks session)
    discardedBacklog = sum (fmap unsubscribe (Map.elems (sessionSubscriptions session)))
    revoked =
      foldl'
        (flip (revokeOne CancelledBySessionFailure))
        session
        (revocableRequests session)
    closedAdmission = case sessionAdmission session of
      AdmissionClosed → AdmissionClosed
      _ → MutationAdmissionClosed

-- Stop -----------------------------------------------------------------------

-- | What one task was doing when the session stopped.
data TaskDisposition
  = -- | Already finished, with this outcome.
    DispositionTerminal !TaskOutcome
  | -- | Live and not running: aborted where it stood.
    DispositionAborted
  | -- | Inside a segment. Recorded as outstanding; the session does not claim
    -- it drained, and nothing here waits for it.
    DispositionOutstandingSegment
  | -- | Accepted but never activated.
    DispositionNotAdmitted
  deriving (Eq, Show)

-- | What one request was when the session stopped.
data RequestDisposition
  = RequestSettledAs !SettlementKind
  | RequestRevokedAt !CancelCause
  deriving (Eq, Show)

-- | What the session threw away rather than delivered.
data DiscardCounts = DiscardCounts
  { discardedResults ∷ !Int
  , discardedRequestResults ∷ !Int
  , discardedAdmissions ∷ !Int
  , discardedEvents ∷ !Int
  }
  deriving (Eq, Show)

-- | Nothing discarded.
noDiscards ∷ DiscardCounts
noDiscards =
  DiscardCounts
    { discardedResults = 0
    , discardedRequestResults = 0
    , discardedAdmissions = 0
    , discardedEvents = 0
    }

-- | What a stop ended.
--
-- Dispositions and discard counts, and nothing else. Worker cleanup evidence
-- is supervision's and is recorded where supervision records it; a record that
-- mixed the two would let a clean stop of this model be read as proof that a
-- worker unwound, which it is not.
data ExitRecord = ExitRecord
  { exitScope ∷ !SessionKey
  , exitTasks ∷ !(Map TaskId TaskDisposition)
  , exitRequests ∷ !(Map RequestId RequestDisposition)
  , exitSubscriptions ∷ !(Map SubscriptionId Int)
  , exitOutstandingSegments ∷ ![TaskId]
  , exitOutstandingProviderWork ∷ ![RequestId]
  , exitDiscards ∷ !DiscardCounts
  }
  deriving (Eq, Show)

-- | Stop the session.
--
-- Admission closes, queued work is aborted, live tasks are aborted, and a task
-- inside a segment is recorded as outstanding rather than waited for. Stopping
-- an already stopped session answers the record it already produced and
-- changes nothing.
stopSession ∷ Session v → (Session v, ExitRecord)
stopSession session = case sessionExit session of
  Just settled → (session, settled)
  Nothing → (stopped {sessionExit = Just record}, record)
  where
    tasks = sessionTasks session
    queued = sessionQueued session
    running = Map.keys (Map.filter ((== Running) . taskState) tasks)
    dispositionOf task = case terminalOutcome (taskState task) of
      Just outcome → DispositionTerminal outcome
      Nothing
        | taskState task == Running → DispositionOutstandingSegment
        | otherwise → DispositionAborted
    requestDisposition entry = case requestSettlement entry of
      Just settled → RequestSettledAs (settlementKind settled)
      Nothing → RequestRevokedAt CancelledByStop
    discardedBacklog = Map.map unsubscribe (sessionSubscriptions session)
    revoked =
      foldl'
        (flip (revokeOne CancelledByStop))
        session
        (revocableRequests session)
    record =
      ExitRecord
        { exitScope = sessionKey session
        , exitTasks =
            Map.union
              (Map.map dispositionOf tasks)
              (Map.fromList [(queuedTask entry, DispositionNotAdmitted) | entry ← toList queued])
        , exitRequests = Map.map requestDisposition (sessionRequests session)
        , exitSubscriptions = discardedBacklog
        , exitOutstandingSegments = running
        , exitOutstandingProviderWork =
            Map.keys (Map.filter requestProviderOutstanding (sessionRequests revoked))
        , exitDiscards =
            DiscardCounts
              { discardedResults = Map.size (sessionResults session)
              , discardedRequestResults =
                  countDiscardedRequestResults (sessionCounters revoked)
                    - countDiscardedRequestResults (sessionCounters session)
              , discardedAdmissions = Seq.length queued
              , discardedEvents = sum (Map.elems discardedBacklog)
              }
        }
    stopped =
      counting
        ( \counters →
            counters
              { countInvalidatedTasks =
                  countInvalidatedTasks counters
                    + Map.size (Map.filter (not . isTerminal . taskState) tasks)
              , countInvalidatedSubscriptions =
                  countInvalidatedSubscriptions counters
                    + Map.size (sessionSubscriptions session)
              , countDiscardedAdmissions =
                  countDiscardedAdmissions counters + Seq.length queued
              , countDiscardedResults =
                  countDiscardedResults counters + Map.size (sessionResults session)
              , countDiscardedEvents =
                  countDiscardedEvents counters + sum (Map.elems discardedBacklog)
              }
        )
        revoked
          { sessionAdmission = AdmissionClosed
          , sessionTasks = Map.empty
          , sessionQueued = Seq.empty
          , sessionResults = Map.empty
          , sessionReservations = 0
          , sessionSubscriptions = Map.empty
          }
