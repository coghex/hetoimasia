-- | The transactions over one owner's requests: admitting one, answering it, cancelling,
-- reading and taking it, serving the ones due at a tick, and ending what a requester or an
-- epoch or the owner held.
--
-- Each is one STM transaction that never blocks and never retries. What needs IO (calling a
-- provider, disposing of what its work needed) is "Hetoimasia.Scripting.Lua.Provider.Serve"'s,
-- which claims the work in a transaction here first, so a thread that has claimed it is the
-- only one that does it.
--
-- = The invariants every path here keeps
--
-- * /A request settles exactly once/, in the protocol model's slot, and every path that
--   ends a request goes through the model: a reply ('reply'), a cancel ('cancelOf'), the end
--   of its requester ('endRequesterSTM'), an epoch change ('advanceEpochSTM') and the owner's
--   exit ('closeSTM'). None writes a settlement of its own.
-- * /A held completion is not a settlement/ (D-39). On an owner that settles at assigned
--   ticks, a reply that arrives before its tick is kept in the request's record. The first is
--   kept, a later one is counted and never replaces it, and nothing about the model's slot
--   changes until the tick is served or a cancel settles the request first.
-- * /A tick that waits for a request does not begin/. A request holds its due tick, with the
--   scheduler, from its admission until it is complete: its completion is held, or it is
--   cancelled, or whatever owned it has ended. Every path that makes it complete gives the
--   hold back through 'dropGate', which gives it back once.
-- * /The provider's work is accounted separately/, in 'Work', and ends only when the provider
--   has proved it over: it replied, or its own reading of its retirement says so. Withdrawing
--   interest does neither. The work is held in the retained-obligation primitive instance
--   leases use ("Hetoimasia.Scripting.Lua.Retention"), charged to the request's place in the
--   owner's bound, and the model is told it ended whenever its request has settled and the
--   work is known over, whichever came last.
module Hetoimasia.Scripting.Lua.Provider.State
  ( -- * Making a service
    newProviderState
  , validateGrant
  , requestLimits

    -- * Who asks
  , Caller (..)
  , callerOf
  , requesterOf
  , markClosing
  , unmarkClosing
  , peekNumber

    -- * Admitting
  , Placement (..)
  , Admitted (..)
  , admissible
  , admit
  , commitSubmitted
  , withdrawAdmission

    -- * Answering
  , Checked (..)
  , checkReply
  , replyTo
  , settlementFields
  , deliverable

    -- * What a script does with a request
  , readyOf
  , TakeAnswer (..)
  , takeOf
  , CancelAnswer (..)
  , cancelOf
  , WaitStatus (..)
  , waitStatus
  , settledNumber

    -- * Serving ticks
  , takeDue
  , nextDueTick
  , serveDue

    -- * Ending
  , EndReport (..)
  , endRequesterSTM
  , goneRequesters
  , EpochReport (..)
  , advanceEpochSTM
  , closeSTM

    -- * The provider's work
  , Claimed (..)
  , claimCancels
  , sweepWorks
  , failWork
  , reapWorks
  , pendingWorkFor
  , anyWorkPending
  , anyInstanceWorkPending
  , workPendingCount
  , workWaiting

    -- * Reading
  , diagnosticsSTM
  ) where

import Control.Concurrent.STM
  ( STM
  , modifyTVar'
  , newTVarIO
  , readTVar
  , writeTVar
  )
import Control.Exception
  ( ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , fromException
  , throwIO
  )
import Control.Monad (foldM, forM, forM_)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (operation, throwFailure)
import Hetoimasia.Scripting.Lua.Instance.Types
  ( IState (isStopped, isPhase)
  , ICell (icState)
  , InstancePhase (Stopping)
  , Instances (insCells, insRunning)
  , isTerminal
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Failure
  ( ReasonCode (ProviderFault, ValidationFault)
  , failureReason
  , reasonDetail
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( EndpointId (EndpointId)
  , RequestId
  , RequestName (RequestName)
  , SessionKey (keyEpoch)
  , TaskId
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits
  ( Limits (..)
  , LimitName (OutstandingRequests)
  , Quanta (..)
  , Quantum (..)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request
  ( CancelCause (..)
  , Reply (ReplyFailure, ReplyResult)
  , RequestRecord (requestProviderOutstanding, requestSettlement)
  , Settlement (..)
  , requestSettled
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session
  ( Counters (..)
  , EpochChange
  , ExitRecord
  , Session (sessionCounters, sessionKey, sessionRequests)
  , SessionRejection (CapReached, PayloadTooLarge, ReplyRefused, UnknownRequest)
  , acceptRequestFor
  , advanceEpoch
  , applyReplyIn
  , cancelRequestWith
  , completeProviderWorkIn
  , endHolder
  , issueHolder
  , newSession
  , observeRequestIn
  , stopSession
  , withdrawRequest
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Step (counting)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Value (Payload (Payload, payloadValue))
import Hetoimasia.Scripting.Lua.Internal.Value
  ( Context (..)
  , Value (VNil, VRecord, VText)
  , ValueLimits (limitBytes)
  , VmIdentity (VmIdentity)
  , conformValue
  , valuesFootprint
  )
import Hetoimasia.Scripting.Lua.Lease.State (renderCaught)
import Hetoimasia.Scripting.Lua.Retention
  ( Ended (..)
  , Obligation (Obligation)
  , Retained (..)
  , RetirementState (ProviderPending)
  , guarded
  , noRetained
  , pollObligation
  , retain
  , sweep
  )
import Hetoimasia.Scripting.Lua.Provider.Types
import Hetoimasia.Scripting.Lua.Registration (validName)
import Hetoimasia.Scripting.Lua.Runtime.Shared (runtimeComponent)
import Hetoimasia.Scripting.Lua.Runtime.Types (OwnerId)
import Hetoimasia.Scripting.Lua.Scheduler.Types (ConfigViolation (LimitRefused), SchedulerRefused (SchedulerRefused))
import Hetoimasia.Scripting.Lua.Value (Schema (..))

-- Making a service -------------------------------------------------------------------

-- | The grant's endpoints by name, or every reason it is refused.
validateGrant ∷ ValueLimits → RequestGrant → Either (NonEmpty RequestGrantViolation) (Map Text RequestEndpoint)
validateGrant limits grant = case NonEmpty.nonEmpty violations of
  Just refused → Left refused
  Nothing → Right (Map.fromList [(endpointName endpoint, endpoint) | endpoint ← grantEndpoints grant])
  where
    endpoints = grantEndpoints grant
    names = map endpointName endpoints
    violations =
      [RequestBoundOutOfRange (grantRequestBound grant) | grantRequestBound grant < 1 || grantRequestBound grant > maxRequestBound]
        <> [NoEndpoints | null endpoints]
        <> [InvalidEndpointName name | name ← names, isJust (validName name)]
        <> [DuplicateEndpoint name | name ← nub names, length (filter (== name) names) > 1]
        <> [EndpointResultCapability (endpointName endpoint) | endpoint ← endpoints, hasCapability (endpointResult endpoint)]
        <> [SettlementsDoNotFit | not (all (fitsLimits limits) minimumRecords)]
    hasCapability = \case
      SCapability _ → True
      SList inner → hasCapability inner
      SOptional inner → hasCapability inner
      SRecord fields → any (hasCapability . snd) fields
      _ → False

-- | Whether a record fits the owner's value limits: the form every record a script is handed
-- must take, whatever it says.
fitsLimits ∷ ValueLimits → [(Text, Value)] → Bool
fitsLimits limits fields = either (const False) (const True) (valuesFootprint limits [VRecord fields])

-- | The record a script is handed for a failure.
failureFields ∷ Text → [(Text, Value)]
failureFields reason = [("status", VText "failure"), ("reason", VText reason)]

-- | The record a script is handed for a cancellation.
cancelledFields ∷ CancelCause → [(Text, Value)]
cancelledFields cause = [("status", VText "cancelled"), ("reason", VText (causeText cause))]

-- | What the service says itself when a settlement could not be delivered as it was: short
-- enough to fit every limits a grant is accepted with.
undeliverableReason ∷ Text
undeliverableReason = "the settlement exceeded the limits it could be delivered within"

-- | The smallest records a script is handed, which every limits a grant is accepted with
-- must be able to hold: every failure and cancellation the service itself makes, and the
-- fallback for one that does not fit.
minimumRecords ∷ [[(Text, Value)]]
minimumRecords =
  map failureFields [undeliverableReason, oversizedReason]
    <> map cancelledFields [CancelledByOwner, CancelledByTaskInvalidation, CancelledByEpochChange, CancelledBySessionFailure, CancelledByStop]
    <> [[("status", VText "pending")], [("status", VText "result"), ("value", VNil)]]

-- | The reason a result over the limits is held and settled as.
oversizedReason ∷ Text
oversizedReason = "the provider's result exceeded the payload cap"

-- | A failure's reason as it is retained: as the provider gave it, bounded, unless the record
-- a script is handed for it would not fit the limits, in which case the service says so.
fitReason ∷ ValueLimits → Text → Text
fitReason limits why
  | fitsLimits limits (failureFields (reasonDetail (failureReason ProviderFault why))) = why
  | otherwise = undeliverableReason

-- | The protocol model's caps for a service: the requests are the ones that matter, and the
-- rest are the least the model accepts, since this session holds no tasks.
requestLimits ∷ ValueLimits → RequestGrant → Limits
requestLimits limits grant =
  Limits
    { maxActiveTasks = 1
    , maxQueuedAdmissions = 1
    , maxSubscriptions = 1
    , maxSubscriptionQueue = 1
    , maxOutstandingRequests = grantRequestBound grant
    , maxPayloadBytes = limitBytes limits
    , maxRetainedResults = 1
    , limitQuanta = Quanta (Quantum 1) (Quantum 1) (Quantum 1)
    }

-- | Make an owner's service from a grant already validated.
newProviderState
  ∷ HasCallStack
  ⇒ OwnerId
  → Text
  → SessionKey
  → ValueLimits
  → RequestGrant
  → Map Text RequestEndpoint
  → Ticks
  → Maybe Instances
  → IO ProviderState
newProviderState owner label key limits grant endpoints ticks instances = do
  session ← case newSession key (requestLimits limits grant) of
    Right made → pure made
    Left violations → throwFailure runtimeComponent (operation "new-provider") [] (SchedulerRefused (fmap LimitRefused violations))
  task ← newTVarIO Nothing
  var ←
    newTVarIO
      PState
        { pSession = session
        , pRecs = Map.empty
        , pByNumber = Map.empty
        , pWork = Map.empty
        , pHolders = Map.empty
        , pClosing = Set.empty
        , pDue = Map.empty
        , pNext = 1
        , pClosed = False
        , pCounts = noCounts
        , pExit = Nothing
        }
  pure
    ProviderState
      { psOwner = owner
      , psLabel = label
      , psLimits = limits
      , psTiming = grantTiming grant
      , psBound = grantRequestBound grant
      , psEndpoints = endpoints
      , psTicks = ticks
      , psInstances = instances
      , psTask = task
      , psVar = var
      }

-- Who asks ----------------------------------------------------------------------------

-- | Who is calling, as the engine knows it and never as a script says: the instance whose
-- code the owner is running, else the task whose segment it is running, else nobody.
data Caller
  = CallerInstance !Word64
  | CallerTask !TaskId
  | CallerNobody
  deriving (Eq, Show)

-- | Who is calling. Read on the callback thread of a Lua call, while the owner's thread is
-- inside it, so what it reads is what the call was made in.
callerOf ∷ ProviderState → STM Caller
callerOf service = do
  running ← maybe (pure Nothing) (readTVar . insRunning) (psInstances service)
  case running of
    Just number → pure (CallerInstance number)
    Nothing → maybe CallerNobody CallerTask <$> readTVar (psTask service)

-- | The number the next request will be given, for the application's assignment to be told.
peekNumber ∷ ProviderState → STM Word64
peekNumber service = pNext <$> readTVar (psVar service)

-- | The requester a caller is, if it is one.
requesterOf ∷ Caller → Maybe Requester
requesterOf = \case
  CallerInstance number → Just (RequesterInstance number)
  CallerTask task → Just (RequesterTask task)
  CallerNobody → Nothing

-- | Note that a task's coroutine is being closed, and that it has been: its closing handlers
-- run after its stop began, and what a stopping requester is not doing is taking requests.
markClosing ∷ ProviderState → TaskId → STM ()
markClosing service task = modifyTVar' (psVar service) (\st → st {pClosing = Set.insert task (pClosing st)})

-- | The task's coroutine has been closed.
unmarkClosing ∷ ProviderState → TaskId → STM ()
unmarkClosing service task = modifyTVar' (psVar service) (\st → st {pClosing = Set.delete task (pClosing st)})

-- | Whether a requester is no longer taking requests: its instance is ending or has ended, or
-- its task has ended or is being closed.
requesterClosed ∷ ProviderState → Requester → STM Bool
requesterClosed service = \case
  RequesterTask task → do
    ended ← ticksTaskGone (psTicks service) task
    closing ← Set.member task . pClosing <$> readTVar (psVar service)
    pure (ended || closing)
  RequesterInstance number → case psInstances service of
    Nothing → pure True
    Just instances → do
      cells ← readTVar (insCells instances)
      case Map.lookup number cells of
        Nothing → pure True
        Just cell → do
          state ← readTVar (icState cell)
          pure (isStopped state || isTerminal (isPhase state) || isPhase state == Stopping)

-- Admitting ---------------------------------------------------------------------------

-- | What the application's assignment answered, for an owner that settles at assigned ticks.
data Placement
  = -- | No assignment is configured: the next tick.
    PlaceByDefault
  | -- | The application declined to place the request.
    PlaceDeclined
  | -- | The application placed it.
    PlaceAt !DueSlot
  deriving (Eq, Show)

-- | A request that was admitted: what the provider is to be told, and what identifies it.
data Admitted = Admitted
  { admittedNumber ∷ !Word64
  , admittedIdentity ∷ !RequestId
  , admittedRequester ∷ !Requester
  , admittedDue ∷ !(Maybe DueSlot)
  }

-- | The places the owner holds: every request the model still counts (an interest, a result
-- nobody took, or provider work not yet over) and every settlement retained for a script
-- outside it (an epoch's cancellations, which the model has released), each once. This is what
-- the bound is on, so a cancellation nobody has taken is a place still held.
chargedPlaces ∷ PState → Int
chargedPlaces st =
  Set.size
    ( Set.fromList (Map.keys (sessionRequests (pSession st)))
        `Set.union` Set.fromList [recIdentity record | record ← Map.elems (pRecs st), isJust (recEnded record)]
    )

-- | Whether the owner and the requester are taking requests at all, as a cheap look before the
-- application's assignment is asked anything: a request refused as closed asks nobody.
admissible ∷ ProviderState → Requester → STM Bool
admissible service requester = do
  st ← readTVar (psVar service)
  open ← ticksOpen (psTicks service)
  closedRequester ← requesterClosed service requester
  pure (not (pClosed st) && open && not closedRequester)

-- | Admit a request: every check, the model's acceptance and the reserved slot, and for an
-- owner that settles at assigned ticks the place, the hold on its tick and the owner's watch
-- on it, all in one transaction. The tick is read in the same transaction as the hold, so a
-- request accepted for a tick is always held before that tick can begin.
--
-- The refusals are decided in this order, and the order is the contract: the owner or the
-- requester is not taking requests, the application declined to place it, its tick has begun,
-- its place is taken, every place is held. A refusal changes nothing but a counter, and no
-- provider has been asked anything.
admit ∷ ProviderState → Requester → RequestEndpoint → Placement → STM (Either RequestRefusal Admitted)
admit service requester endpoint placement = do
  st ← readTVar (psVar service)
  open ← ticksOpen (psTicks service)
  closedRequester ← requesterClosed service requester
  now ← ticksNow (psTicks service)
  let number = pNext st
      refuse why = Left why <$ writeTVar (psVar service) st {pCounts = (pCounts st) {countRefused = countRefused (pCounts st) + 1}}
      -- The place, for an owner that settles at ticks: assigned, or the next tick in the
      -- order requests were admitted.
      place = case psTiming service of
        SettleOnArrival → Right Nothing
        SettleAtAssignedTick _ → case placement of
          PlaceDeclined → Left RequestUnassigned
          PlaceAt slot → Right (Just slot)
          PlaceByDefault
            | now == maxBound → Left RequestLate
            | otherwise → Right (Just (DueSlot (now + 1) number))
  if pClosed st || not open || closedRequester
    then refuse RequestsClosed
    else case place of
      Left why → refuse why
      Right slot
        | Just due ← slot, dueTick due <= now → refuse RequestLate
        | Just due ← slot, Map.member due (pDue st) → refuse RequestDuplicatePlace
        | otherwise → do
            let (holder, withHolder) = case Map.lookup requester (pHolders st) of
                  Just held → (held, pSession st)
                  Nothing → issueHolder (pSession st)
                bound = psBound service
            case acceptRequestFor holder (RequestName number) (EndpointId (endpointName endpoint)) withHolder of
              _ | chargedPlaces st >= bound → refuse (RequestsFull bound)
              (_, Left (CapReached OutstandingRequests full)) → refuse (RequestsFull full)
              (_, Left _) → refuse RequestsClosed
              (session, Right identity) → do
                forM_ slot $ \due → ticksHold (psTicks service) (dueTick due) >> ticksWatch (psTicks service) (dueTick due)
                let record =
                      Rec
                        { recNumber = number
                        , recIdentity = identity
                        , recRequester = requester
                        , recEndpoint = endpointName endpoint
                        , recSchema = endpointResult endpoint
                        , recDue = slot
                        , recHeld = Nothing
                        , recGated = dueTick <$> slot
                        , recEnded = Nothing
                        }
                    work =
                      Work
                        { workNumber = number
                        , workRequester = requester
                        , workLabel = endpointName endpoint <> " request " <> Text.pack (show number)
                        , workProvider = Nothing
                        , workWantsCancel = False
                        , workCancelClaimed = False
                        , workEnded = False
                        , workFailure = Nothing
                        , workRetained = noRetained
                        }
                writeTVar (psVar service) st
                  { pSession = session
                  , pRecs = Map.insert identity record (pRecs st)
                  , pByNumber = Map.insert number identity (pByNumber st)
                  , pWork = Map.insert identity work (pWork st)
                  , pHolders = Map.insert requester holder (pHolders st)
                  , pDue = maybe id (\due → Map.insert due identity) slot (pDue st)
                  , pNext = number + 1
                  , pCounts = (pCounts st) {countAdmitted = countAdmitted (pCounts st) + 1}
                  }
                pure (Right (Admitted number identity requester slot))

-- | Record that the provider accepted a request: its work, and what the work needs
-- disposing of once it is over. The accounting for the work was made with the admission, so
-- it is found; a reply or a revocation that came first is already in it.
commitSubmitted ∷ ProviderState → RequestId → ProviderWork → [IO ()] → STM ()
commitSubmitted service identity provided disposals = do
  st ← readTVar (psVar service)
  writeTVar (psVar service) st
    { pWork = Map.adjust record identity (pWork st)
    }
  where
    -- The obligation is the provider's own reading of its retirement, and says nothing until
    -- interest in the work was withdrawn. Work that a reply has already proved over has
    -- nothing to retire.
    record work =
      work
        { workProvider = Just provided
        , workRetained =
            (if workEnded work then id else retain (Obligation (workLabel work) reading))
              (workRetained work) {retainedDeferred = retainedDeferred (workRetained work) <> disposals}
        }
    reading = do
      st ← readTVar (psVar service)
      case Map.lookup identity (pWork st) of
        Just work | workWantsCancel work → workRetirement provided
        _ → pure ProviderPending

-- | Take back an admission whose handoff to the provider failed: it never reached it. Nothing
-- is settled or invalidated, and the capacity is free again.
withdrawAdmission ∷ ProviderState → RequestId → STM ()
withdrawAdmission service identity = do
  st ← readTVar (psVar service)
  let gated = Map.lookup identity (pRecs st) >>= recGated
  mapM_ (ticksRelease (psTicks service)) gated
  writeTVar (psVar service) st
    { pSession = withdrawRequest identity (pSession st)
    , pRecs = Map.delete identity (pRecs st)
    , pByNumber = Map.filter (/= identity) (pByNumber st)
    , pWork = Map.delete identity (pWork st)
    , pDue = Map.filter (/= identity) (pDue st)
    }

-- Answering ---------------------------------------------------------------------------

-- | A reply, checked, before anything is retained.
data Checked
  = -- | Within the limits and the endpoint's schema: its size, and the value.
    CheckedResult !Int !Value
  | -- | The provider's own failure.
    CheckedFailure !Text
  | -- | Over the owner's limits: the size it declared.
    CheckedOversize !Int
  | -- | Not what the endpoint declares, or not evaluable: why.
    CheckedMalformed !Text

-- | Check a reply against the owner's value limits and the endpoint's schema, evaluating it
-- fully inside the one guard, so a value that throws when it is first looked at is a
-- malformed reply and not an exception loose in a transaction.
checkReply ∷ ValueLimits → Schema → ProviderReply → IO Checked
checkReply limits schema = \case
  ProviderFailure why → pure (CheckedFailure (fitReason limits why))
  ProviderResult value → do
    judged ← guarded (pure (judge value))
    case judged of
      Right verdict → pure verdict
      Left failure@(ExceptionWithContext _ raised)
        | Just (async ∷ SomeAsyncException) ← fromException raised → throwIO async
        | otherwise → CheckedMalformed . ("the result could not be evaluated: " <>) <$> renderCaught failure
  where
    -- What is measured is the record a script is handed on taking it, not the bare value, so
    -- that a result which is retained is a result that can be delivered within the limits.
    judge value = case valuesFootprint limits [VRecord (resultFields value)] of
      Left _ → CheckedOversize (limitBytes limits + 1)
      Right bytes → case conformValue plainContext schema value of
        Left (_, rule) → CheckedMalformed (fitReason limits ("the result does not conform to the endpoint's schema: " <> Text.pack (show rule)))
        Right () → CheckedResult bytes value

-- | A result carries no capability, so nothing of a VM is consulted.
plainContext ∷ Context
plainContext = Context (VmIdentity 0) (const Nothing) (const Nothing)

-- | The record a script is handed for a result.
resultFields ∷ Value → [(Text, Value)]
resultFields value = [("status", VText "result"), ("value", value)]

-- | A settlement as the record a script reads.
settlementFields ∷ Settlement Value → [(Text, Value)]
settlementFields = \case
  SettledResult payload → resultFields (payloadValue payload)
  SettledFailure reason → failureFields (reasonDetail reason)
  SettledCancelled cause → cancelledFields cause

causeText ∷ CancelCause → Text
causeText = \case
  CancelledByOwner → "owner"
  CancelledByTaskInvalidation → "requester_ended"
  CancelledByEpochChange → "epoch_change"
  CancelledBySessionFailure → "session_failure"
  CancelledByStop → "stop"

-- | The record a script is handed on taking a settlement, and nothing that it could not be
-- handed: every record is checked against the limits and, for a result, the schema the taking
-- operation declares. One that does not fit (a mismatch between the operation and the endpoint
-- that answered, or limits a reply was accepted under) is delivered as a failure that says so,
-- which a grant is only accepted if the limits can hold, so that taking a settlement, which
-- retires it, never loses it to a fault.
deliverable ∷ ValueLimits → Schema → Settlement Value → [(Text, Value)]
deliverable limits schema settlement
  | fits = fields
  | otherwise = failureFields undeliverableReason
  where
    fields = settlementFields settlement
    fits = fitsLimits limits fields && case settlement of
      SettledResult payload → either (const False) (const True) (conformValue plainContext schema (payloadValue payload))
      _ → True

-- | The model's reply for a checked one.
modelReply ∷ Checked → Reply Value
modelReply = \case
  CheckedResult bytes value → ReplyResult (Payload bytes value)
  CheckedFailure why → ReplyFailure (failureReason ProviderFault why)
  -- The model settles an unsettled request as a failure, and never stores the value.
  CheckedOversize declared → ReplyResult (Payload declared VNil)
  CheckedMalformed why → ReplyFailure (failureReason ValidationFault why)

-- | Answer a request. One transaction, never waiting.
replyTo ∷ ProviderState → RequestId → Checked → STM ReplyAnswer
replyTo service identity checked = do
  st ← readTVar (psVar service)
  let session = pSession st
      reply = modelReply checked
      refusedValue = case checked of
        CheckedOversize _ → True
        CheckedMalformed _ → True
        _ → False
      unsettled = maybe False (isNothing . requestSettlement) (Map.lookup identity (sessionRequests session))
      record = Map.lookup identity (pRecs st)
      -- A completion is held while its place has not been served, whatever tick the owner has
      -- reached: the tick may have been applied and its settlements not yet served, and a
      -- duplicate arriving then is still a duplicate, not the settlement.
      holdable = case record >>= recDue of
        Just due → Map.lookup due (pDue st) == Just identity
        Nothing → False
  case (record, unsettled && holdable) of
    -- An owner that settles at ticks keeps the first completion that arrives before its tick.
    (Just found, True)
      | isJust (recHeld found) → do
          writeTVar (psVar service) st {pCounts = (pCounts st) {countDuplicateHeld = countDuplicateHeld (pCounts st) + 1}}
          pure ReplyLate
      | otherwise → do
          -- Over the limits it is held as a failure and the value is not kept, counted as
          -- the model counts an oversized reply.
          let held = case checked of
                CheckedOversize _ → ReplyFailure (failureReason ValidationFault oversizedReason)
                _ → reply
              session' = case checked of
                CheckedOversize _ → counting (\counters → counters {countOversizePayloads = countOversizePayloads counters + 1}) session
                _ → session
              released = found {recHeld = Just held}
          released' ← dropGate service released
          writeTVar (psVar service) $
            endWork identity $
              st
                { pSession = session'
                , pRecs = Map.insert identity released' (pRecs st)
                , pCounts = (pCounts st) {countHeld = countHeld (pCounts st) + 1}
                }
          pure (if refusedValue then ReplyRefusedValue else ReplyHeld)
    _ → do
      let (session', answer) = applyReplyIn identity reply session
          settled = endWork identity st {pSession = session'}
      writeTVar (psVar service) $ case answer of
        Left (UnknownRequest _) → st {pSession = session'}
        _ → settled
      pure $ case answer of
        Right () → if refusedValue then ReplyRefusedValue else ReplySettled
        Left (UnknownRequest _) → ReplyUnknown
        Left (PayloadTooLarge _ _) → ReplyRefusedValue
        Left (ReplyRefused _) → ReplyLate
        Left _ → ReplyLate

-- | The provider has proved its work over: it replied. The model is told as soon as the
-- request has settled, which for a held completion is when it is served or cancelled.
endWork ∷ RequestId → PState → PState
endWork identity st =
  st
    { pWork = Map.adjust (\work → work {workEnded = True, workRetained = (workRetained work) {retainedObligations = []}}) identity (pWork st)
    , pSession = retireProviderWork identity (pSession st)
    }

-- | Tell the model the provider's work is over, if the request has settled and the model
-- still counts the work as outstanding. A request that has not settled is told later, by
-- whatever settles it, so the model is never asked twice and never counts a late completion
-- this service caused.
retireProviderWork ∷ RequestId → Session Value → Session Value
retireProviderWork identity session = case Map.lookup identity (sessionRequests session) of
  Just found | requestSettled found && requestProviderOutstanding found → fst (completeProviderWorkIn identity session)
  _ → session

-- | Tell the model the provider's work is over for every request whose work this service
-- has accounted over. Called after the model settled requests by revocation, so a request
-- whose provider had already answered is free to be reclaimed.
retireEnded ∷ PState → PState
retireEnded st = st {pSession = foldl' (flip retireProviderWork) (pSession st) [identity | (identity, work) ← Map.toList (pWork st), workEnded work]}

-- | Give back the hold a request has on its tick, once.
dropGate ∷ ProviderState → Rec → STM Rec
dropGate service record = case recGated record of
  Nothing → pure record
  Just tick → record {recGated = Nothing} <$ ticksRelease (psTicks service) tick

-- What a script does with a request ------------------------------------------------------

-- | The record a requester may reach by its number, or why not.
reach ∷ Requester → Word64 → PState → Either RequestRefusal Rec
reach requester number st = case Map.lookup number (pByNumber st) >>= \identity → Map.lookup identity (pRecs st) of
  Nothing → Left RequestEnded
  Just record
    | recRequester record /= requester → Left NotTheRequester
    | otherwise → Right record

-- | Whether the request has settled, for its requester.
readyOf ∷ ProviderState → Requester → Word64 → STM (Either RequestRefusal Bool)
readyOf service requester number = do
  st ← readTVar (psVar service)
  pure $ reach requester number st >>= \record → Right (isSettled st record)

isSettled ∷ PState → Rec → Bool
isSettled st record =
  isJust (recEnded record)
    || maybe False requestSettled (Map.lookup (recIdentity record) (sessionRequests (pSession st)))

-- | What taking a request's settlement found.
data TakeAnswer
  = -- | Not settled yet. Nothing was taken.
    TakePending
  | -- | The settlement, taken once. The handle names nothing now.
    TakeSettled !(Settlement Value)
  | TakeRefused !RequestRefusal

-- | Take the settlement, once: it releases the result's storage, and the handle is retired.
takeOf ∷ ProviderState → Requester → Word64 → STM TakeAnswer
takeOf service requester number = do
  st ← readTVar (psVar service)
  case reach requester number st of
    Left why → pure (TakeRefused why)
    Right record
      | Just (settled, _) ← recEnded record → TakeSettled settled <$ forget st record
      | otherwise → case observeRequestIn (recIdentity record) (pSession st) of
          (_, Left _) → pure TakePending
          (session, Right settled) → TakeSettled settled <$ forget st {pSession = session} record
  where
    forget st record =
      writeTVar (psVar service) st
        { pRecs = Map.delete (recIdentity record) (pRecs st)
        , pByNumber = Map.delete (recNumber record) (pByNumber st)
        }

-- | What cancelling a request came to.
data CancelAnswer
  = -- | The request is settled as cancelled, whatever the provider had done.
    Cancelled
  | -- | The request had settled already, and keeps its settlement. Counted.
    CancelTooLate
  | CancelRefused !RequestRefusal

-- | Cancel a request: settle it as cancelled and withdraw interest.
--
-- On an owner that settles at assigned ticks, a cancel before the tick always wins (D-39): it
-- settles the request, discards any completion held, gives the tick's hold back and leaves
-- the provider's work to be retired. Where the request settled first, a later cancel is
-- refused and counted, and the settlement stands.
cancelOf ∷ ProviderState → Requester → Word64 → STM CancelAnswer
cancelOf service requester number = do
  st ← readTVar (psVar service)
  case reach requester number st of
    Left why → pure (CancelRefused why)
    Right record
      | isSettled st record → do
          writeTVar (psVar service) st {pCounts = (pCounts st) {countLateCancels = countLateCancels (pCounts st) + 1}}
          pure CancelTooLate
      | otherwise → case cancelRequestWith CancelledByOwner (recIdentity record) (pSession st) of
          (_, Left _) → pure CancelTooLate
          (session, Right ()) → do
            released ← dropGate service record {recHeld = Nothing}
            let completed = isJust (recHeld record)
                before = isJust (recDue record)
                st' =
                  st
                    { pSession = session
                    , pRecs = Map.insert (recIdentity record) released (pRecs st)
                    , pDue = Map.filter (/= recIdentity record) (pDue st)
                    , pWork = Map.adjust (\work → work {workWantsCancel = True}) (recIdentity record) (pWork st)
                    , pCounts = if before then (pCounts st) {countCancelledBeforeTick = countCancelledBeforeTick (pCounts st) + 1} else pCounts st
                    }
            -- A completion that was held is proof the provider finished, and so is any work
            -- already known over: the model is told now that the request has settled.
            writeTVar (psVar service) (retireEnded (if completed then endWork (recIdentity record) st' else st'))
            pure Cancelled

-- | Whether a wait for a request can be made, and whether it is already over.
data WaitStatus
  = WaitSettled
  | WaitPending
  | WaitRefused !RequestRefusal

-- | What a wait for this request, by this requester, would find.
waitStatus ∷ ProviderState → Requester → Word64 → STM WaitStatus
waitStatus service requester number = do
  st ← readTVar (psVar service)
  pure $ case reach requester number st of
    Left why → WaitRefused why
    Right record
      | isSettled st record → WaitSettled
      | otherwise → WaitPending

-- | Whether a waiter's request has settled, or is gone: a waiter is never kept for a request
-- that nothing can settle. The owner asks it of every waiter at each safe boundary.
settledNumber ∷ ProviderState → Word64 → STM Bool
settledNumber service number = do
  st ← readTVar (psVar service)
  pure $ case Map.lookup number (pByNumber st) >>= \identity → Map.lookup identity (pRecs st) of
    Nothing → True
    Just record → isSettled st record

-- Serving ticks -------------------------------------------------------------------------

-- | Take the requests whose places are at or before this tick out of the places not yet
-- served, in the order of their places.
takeDue ∷ ProviderState → Word64 → STM [RequestId]
takeDue service tick = do
  st ← readTVar (psVar service)
  let (due, later) = Map.partitionWithKey (\slot _ → dueTick slot <= tick) (pDue st)
  writeTVar (psVar service) st {pDue = later}
  pure (Map.elems due)

-- | The earliest tick a request not yet served is due at.
nextDueTick ∷ ProviderState → STM (Maybe Word64)
nextDueTick service = do
  st ← readTVar (psVar service)
  pure (dueTick . fst <$> Map.lookupMin (pDue st))

-- | Serve requests whose tick has been reached: each one still unsettled is settled by the
-- completion it held, so what reaches Lua is what the provider delivered, in the order of
-- the places. A request that was cancelled, or whose requester ended, has settled already
-- and is left as it is. Answers the numbers settled, in order.
serveDue ∷ ProviderState → [RequestId] → STM [Word64]
serveDue service identities = do
  settled ← forM identities $ \identity → do
    st ← readTVar (psVar service)
    case Map.lookup identity (pRecs st) of
      Just record
        | Just held ← recHeld record
        , maybe False (isNothing . requestSettlement) (Map.lookup identity (sessionRequests (pSession st))) → do
            let (session, _) = applyReplyIn identity held (pSession st)
            writeTVar (psVar service) $
              endWork identity st
                { pSession = session
                , pRecs = Map.insert identity record {recHeld = Nothing} (pRecs st)
                , pCounts = (pCounts st) {countSettledAtTick = countSettledAtTick (pCounts st) + 1}
                }
            pure [recNumber record]
      _ → pure []
  pure (concat settled)

-- Ending ---------------------------------------------------------------------------------

-- | What ending a requester's holdings did.
data EndReport = EndReport
  { endedRequests ∷ !Int
    -- ^ The requests whose interest was revoked.
  , endedWork ∷ !Int
    -- ^ The provider work that is to be told, which is not over.
  }
  deriving (Eq, Show)

-- | End a requester: every request it still had an interest in is revoked, for this cause,
-- the way a retiring task's are; its holds on ticks are given back; and the provider's work
-- on them is to be told, once, as soon as it can be. The provider's accounting is untouched:
-- it ends when the provider proves it.
endRequesterSTM ∷ ProviderState → Requester → CancelCause → STM EndReport
endRequesterSTM service requester cause = do
  st ← readTVar (psVar service)
  let mine = [record | record ← Map.elems (pRecs st), recRequester record == requester]
      theirWork = [identity | (identity, work) ← Map.toList (pWork st), workRequester work == requester]
  released ← forM mine (dropGate service)
  -- A completion the provider held is proof it finished, whatever became of the request.
  let completed = [recIdentity record | record ← mine, isJust (recHeld record)]
      withEnded = foldl' (flip endWork) st completed
      revoked = case Map.lookup requester (pHolders withEnded) of
        Just holder → endHolder holder cause (pSession withEnded)
        Nothing → pSession withEnded
      gone = map recIdentity released
      told = [() | identity ← theirWork, Just work ← [Map.lookup identity (pWork withEnded)], not (workEnded work)]
  writeTVar (psVar service) $
    retireEnded
      withEnded
        { pSession = revoked
        , pRecs = foldr Map.delete (pRecs withEnded) gone
        , pByNumber = Map.filter (`notElem` gone) (pByNumber withEnded)
        , pDue = Map.filter (`notElem` gone) (pDue withEnded)
        , pHolders = Map.delete requester (pHolders withEnded)
        , pWork =
            foldr
              (Map.adjust (\work → if workEnded work then work else work {workWantsCancel = True}))
              (pWork withEnded)
              theirWork
        }
  pure (EndReport (length mine) (length told))

-- | The task requesters whose tasks are gone: ended, or no longer known to the scheduler.
goneRequesters ∷ ProviderState → STM [Requester]
goneRequesters service = do
  st ← readTVar (psVar service)
  let tasks = [task | RequesterTask task ← Map.keys (pHolders st)]
  gone ← forM tasks $ \task → (,) task <$> ticksTaskGone (psTicks service) task
  pure [RequesterTask task | (task, True) ← gone]

-- | What an epoch change did.
data EpochReport = EpochReport
  { epochChange ∷ !EpochChange
  , epochCancelled ∷ !Int
    -- ^ Outstanding requests settled as cancelled, which their scripts take.
  , epochDiscarded ∷ !Int
    -- ^ Settled results nobody had taken, discarded with the epoch's records.
  }
  deriving (Show)

-- | Replace the generation of records (P-9).
--
-- Every outstanding request settles, once, as cancelled by the epoch change, and its script
-- can take that; a settled result nobody had taken is discarded, as the model discards it; the
-- holds on ticks are given back; and the provider's work on all of them is to be told. The
-- accounting for work that is not over is retained under the old identities, so a late reply
-- retires it without reaching anything the new epoch issues.
advanceEpochSTM ∷ ProviderState → STM (Maybe EpochReport)
advanceEpochSTM service = do
  st ← readTVar (psVar service)
  if pClosed st
    then pure Nothing
    else do
      -- First the outstanding ones are cancelled in the model, so each has a settlement to keep.
      stepped ← foldM cancelOne (st, [], 0 ∷ Int, 0 ∷ Int) (Map.elems (pRecs st))
      let (cancelledState, kept, cancelled, discarded) = stepped
      -- What the cancelling did (the holds given back, the work marked) is committed whether or
      -- not the model advances, so the records never say a hold is held that was given back.
      let committed session =
            retireEnded
              cancelledState
                { pSession = session
                , pRecs = Map.fromList [(recIdentity record, record) | record ← kept]
                , pByNumber = Map.fromList [(recNumber record, recIdentity record) | record ← kept]
                , pDue = Map.empty
                , pHolders = Map.empty
                , pCounts = (pCounts cancelledState) {countEpochCancelled = countEpochCancelled (pCounts cancelledState) + cancelled}
                }
      case advanceEpoch (pSession cancelledState) of
        (_, Left _) → Nothing <$ writeTVar (psVar service) (committed (pSession cancelledState))
        (session, Right change) → do
          writeTVar (psVar service) (committed session)
          pure (Just (EpochReport change cancelled discarded))
  where
    cancelOne (st, kept, cancelled, discarded) record
      | isJust (recEnded record) = pure (st, kept <> [record], cancelled, discarded)
      | otherwise = do
          let identity = recIdentity record
              completed = isJust (recHeld record)
          released ← dropGate service record {recHeld = Nothing}
          case Map.lookup identity (sessionRequests (pSession st)) of
            Just found
              | isNothing (requestSettlement found) → do
                  let (session, _) = cancelRequestWith CancelledByEpochChange identity (pSession st)
                      settledCancel = (SettledCancelled CancelledByEpochChange, CancelledByEpochChange)
                      st' = st {pSession = session, pWork = Map.adjust (\work → work {workWantsCancel = True}) identity (pWork st)}
                  pure ((if completed then endWork identity st' else st'), kept <> [released {recEnded = Just settledCancel}], cancelled + 1, discarded)
            _ → pure (st {pWork = Map.adjust (\work → if workEnded work then work else work {workWantsCancel = True}) identity (pWork st)}, kept, cancelled, discarded + 1)

-- | The owner has exited: nothing is admitted after it. Every request still held is revoked,
-- the holds on ticks are given back, the provider's work on all of them is to be told, and
-- the model's record of what was outstanding is kept. The accounting for work that is not over
-- stays, and is awaited: a reply or a retirement reading is still taken.
closeSTM ∷ ProviderState → STM (Maybe ExitRecord)
closeSTM service = do
  st ← readTVar (psVar service)
  if pClosed st
    then pure (pExit st)
    else do
      mapM_ (dropGate service) (Map.elems (pRecs st))
      let completed = [recIdentity record | record ← Map.elems (pRecs st), isJust (recHeld record)]
          withEnded = foldl' (flip endWork) st completed
          (session, exit) = stopSession (pSession withEnded)
      writeTVar (psVar service) $
        retireEnded
          withEnded
        { pSession = session
        , pRecs = Map.empty
        , pByNumber = Map.empty
        , pDue = Map.empty
        , pHolders = Map.empty
        , pClosed = True
        , pExit = Just exit
        , pWork = Map.map (\work → if workEnded work then work else work {workWantsCancel = True}) (pWork withEnded)
        }
      pure (Just exit)

-- The provider's work ------------------------------------------------------------------

-- | Work whose provider is to be told that interest in it was withdrawn: the provider's
-- handle and a name for evidence.
data Claimed = Claimed
  { claimedIdentity ∷ !RequestId
  , claimedLabel ∷ !Text
  , claimedWork ∷ !ProviderWork
  }

-- | Claim the provider work that is to be told, once each: the telling is the claiming
-- thread's, so no other tells it again. Work that is already over is not told, and is marked
-- so: a provider that finished is not asked to stop.
claimCancels ∷ ProviderState → STM [Claimed]
claimCancels service = do
  st ← readTVar (psVar service)
  let wanting = [(identity, work) | (identity, work) ← Map.toList (pWork st), workWantsCancel work, not (workCancelClaimed work), isJust (workProvider work)]
      toTell = [Claimed identity (workLabel work) provided | (identity, work) ← wanting, not (workEnded work), Just provided ← [workProvider work]]
  writeTVar (psVar service) st
    { pWork = foldr (Map.adjust (\work → work {workCancelClaimed = True}) . fst) (pWork st) wanting
    }
  pure toTell

-- | Read the providers' own accounts of work whose interest was withdrawn, through the one
-- reading every retained obligation goes through, and answer the disposals that are now due:
-- those of work that is over and did not fail, each once. Work a provider proves over is
-- over; work whose retirement it reports failed keeps the failure, and the failure is
-- answered once, to be recorded as cleanup evidence.
sweepWorks ∷ ProviderState → STM ([(Text, ExceptionWithContext SomeException)], [(RequestId, Text, [IO ()])])
sweepWorks service = do
  st ← readTVar (psVar service)
  swept ← forM (Map.toList (pWork st)) $ \(identity, work) → do
    (retained, ended, due) ← sweep (isJust (workFailure work)) (workRetained work)
    pure (identity, work, retained, ended, due)
  let step (current, failures, ready) (identity, work, retained, ended, due) =
        let failed = [failure | Ended _ (Just failure) ← ended]
            kept = case failed of
              failure : _ → Just (fromMaybe failure (workFailure work))
              [] → workFailure work
            completed = not (null [() | Ended _ Nothing ← ended])
            held = current {pWork = Map.adjust (\held' → held' {workRetained = retained, workFailure = kept}) identity (pWork current)}
            finished = if completed then endWork identity held else held
         in ( finished
            , failures <> [(workLabel work, failure) | failure ← take 1 failed]
            , ready <> [(identity, workLabel work, due) | not (null due)]
            )
      (final, evidence, disposals) = foldl' step (st, [], []) swept
  writeTVar (psVar service) final
  pure (evidence, disposals)

-- | Retain the failure of work's retirement or of the disposal of what it needed. The first
-- is kept, and every later release or reading of the work answers it.
failWork ∷ ProviderState → RequestId → ExceptionWithContext SomeException → STM ()
failWork service identity failure = do
  st ← readTVar (psVar service)
  writeTVar (psVar service) st
    { pWork = Map.adjust (\work → work {workFailure = Just (fromMaybe failure (workFailure work))}) identity (pWork st)
    }

-- | Forget the work that is over, disposed of and did not fail, and that the model no longer
-- counts as outstanding: nothing of it is left to await or to tell.
--
-- The model is told a provider finished when its request settles, and a request may settle
-- long after the work ended (a held completion waits for its tick; a cancel, an end or an
-- epoch settles it whenever it comes). So the fact that the work ended is kept until the model
-- has been told, and every path that settles a request retires the ended work it finds.
reapWorks ∷ ProviderState → STM ()
reapWorks service = do
  st ← readTVar (psVar service)
  let forgettable identity work =
        workEnded work && null (retainedDeferred (workRetained work)) && isJust (workProvider work) && isNothing (workFailure work)
          && not (modelOwes (pSession st) identity)
  writeTVar (psVar service) st
    { pWork = Map.filterWithKey (\identity work → not (forgettable identity work)) (pWork st)
    }

-- | Whether the model still counts the provider's work on this request as outstanding.
modelOwes ∷ Session Value → RequestId → Bool
modelOwes session identity = maybe False requestProviderOutstanding (Map.lookup identity (sessionRequests session))

-- | The work of a requester that is not yet over, or whose disposals have not run: what its
-- end waits for. Work whose retirement failed is not waited for: it is the evidence.
pendingWorkFor ∷ ProviderState → Requester → STM Int
pendingWorkFor service requester = do
  st ← readTVar (psVar service)
  pure (length [() | work ← Map.elems (pWork st), workRequester work == requester, awaiting work])

-- | Whether any work anywhere is not yet over.
anyWorkPending ∷ ProviderState → STM Bool
anyWorkPending service = do
  st ← readTVar (psVar service)
  pure (any awaiting (Map.elems (pWork st)))

-- | Whether any work an instance's request made is not yet over: what an instance's end, and the
-- owner's retirement of its instances, wait for.
anyInstanceWorkPending ∷ ProviderState → STM Bool
anyInstanceWorkPending service = do
  st ← readTVar (psVar service)
  pure (any (\work → awaiting work && isInstance (workRequester work)) (Map.elems (pWork st)))
  where
    isInstance = \case
      RequesterInstance _ → True
      RequesterTask _ → False

-- | How many pieces of work are not yet over, or have disposals still to run.
workPendingCount ∷ ProviderState → STM Int
workPendingCount service = do
  st ← readTVar (psVar service)
  pure (length (filter awaiting (Map.elems (pWork st))))

awaiting ∷ Work → Bool
awaiting work = isNothing (workFailure work) && (not (workEnded work) || not (null (retainedDeferred (workRetained work))))

-- | Whether the owner has anything to do for the provider's work: a reading that is no longer
-- pending, or disposals to run. The owner composes it into its wait for work.
workWaiting ∷ ProviderState → STM Bool
workWaiting service = do
  st ← readTVar (psVar service)
  let works = Map.elems (pWork st)
      -- Work that is over and not yet forgotten has disposals to run or itself to be forgotten,
      -- and an instance whose end waited for it can settle.
      over =
        or
          [ True
          | (identity, work) ← Map.toList (pWork st)
          , workEnded work
          , isNothing (workFailure work)
          , isJust (workProvider work)
          , not (null (retainedDeferred (workRetained work))) || not (modelOwes (pSession st) identity)
          ]
      -- Interest was withdrawn and the provider not yet told: the owner tells it.
      untold = any (\work → workWantsCancel work && not (workCancelClaimed work) && not (workEnded work) && isJust (workProvider work)) works
      polling = [obligation | work ← works, workWantsCancel work, not (workEnded work), isNothing (workFailure work), obligation ← retainedObligations (workRetained work)]
  changed ← forM polling $ \obligation →
    (\reading → case reading of ProviderPending → False; _ → True) <$> pollObligation obligation
  pure (over || untold || or changed)

-- Reading --------------------------------------------------------------------------------

-- | A reading of the service, in one transaction.
diagnosticsSTM ∷ ProviderState → STM ProviderDiagnostics
diagnosticsSTM service = do
  st ← readTVar (psVar service)
  let counters = sessionCounters (pSession st)
      counts = pCounts st
  pure
    ProviderDiagnostics
      { rdEpoch = keyEpoch (sessionKey (pSession st))
      , rdOutstanding = chargedPlaces st
      , rdHeldNow = length [() | record ← Map.elems (pRecs st), isJust (recHeld record)]
      , rdWorkPending = length [() | work ← Map.elems (pWork st), awaiting work]
      , rdWorkFailed = length [() | work ← Map.elems (pWork st), isJust (workFailure work)]
      , rdAdmitted = countAdmitted counts
      , rdRefused = countRefused counts
      , rdHeldTotal = countHeld counts
      , rdDuplicateHeld = countDuplicateHeld counts
      , rdLateCancels = countLateCancels counts
      , rdLateReplies = countLateReplies counters
      , rdUnknownReplies = countUnknownReplies counters
      , rdOversize = countOversizePayloads counters
      , rdLateCompletions = countLateProviderCompletions counters
      , rdInvalidated = countInvalidatedRequests counters
      , rdDiscardedResults = countDiscardedRequestResults counters
      , rdSettledAtTick = countSettledAtTick counts
      , rdCancelledBeforeTick = countCancelledBeforeTick counts
      , rdEpochCancelled = countEpochCancelled counts
      }
