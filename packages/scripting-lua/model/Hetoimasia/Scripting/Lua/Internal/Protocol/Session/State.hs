-- | The session's representation: the one pure value every session operation
-- threads, its construction, and the records it answers with.
--
-- This module owns the shape of a session and nothing that moves it. The
-- aggregate's contract — what a rejection may and may not do, how reservations
-- bound storage, and why identities carry their epoch — is stated once, on the
-- facade "Hetoimasia.Scripting.Lua.Internal.Protocol.Session", and the
-- operations that uphold it live in the modules beside this one.
--
-- The failure and exit records are here rather than beside the operations
-- that produce them because the session keeps them: a failed session holds its
-- 'FailureRecord', and a stopped one answers its 'ExitRecord' again.
module Hetoimasia.Scripting.Lua.Internal.Protocol.Session.State
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

    -- * Queued admissions
  , QueuedAdmission (..)

    -- * Failure
  , FailureRecord (..)

    -- * Stop
  , TaskDisposition (..)
  , RequestDisposition (..)
  , DiscardCounts (..)
  , noDiscards
  , ExitRecord (..)
  ) where

import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Hetoimasia.Scripting.Lua.Internal.Protocol.Failure (FailureReason, RecoverySafety)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( BehaviorId
  , Generation
  , Ordinal
  , RequestId
  , SessionKey
  , SnapshotId
  , SubscriptionId
  , TaskId
  , TaskName
  , firstGeneration
  , firstOrdinal
  , firstTaskName
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits
  ( LimitName
  , LimitViolation
  , Limits
  , ServiceClass
  , ValidLimits
  , validateLimits
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request
  ( CancelCause
  , ObserveRejection
  , ProviderRejection
  , ReplyRejection
  , RequestRecord
  , SettlementKind
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription (DeliveryRejection, Subscription)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task
  ( Readiness
  , Task
  , TaskFailure
  , TaskOutcome
  , TransitionRejection
  )

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
