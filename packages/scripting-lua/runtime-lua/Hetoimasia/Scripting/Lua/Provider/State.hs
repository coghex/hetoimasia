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
  , validateSubscriptions
  , requestLimits

    -- * Who asks
  , Caller (..)
  , callerOf
  , callerPhaseOf
  , requesterOf
  , markClosing
  , unmarkClosing
  , peekNumber
  , skipNumbers

    -- * Admitting
  , Placement (..)
  , Admitted (..)
  , admissible
  , admit
  , commitSubmitted
  , withdrawAdmission

    -- * The opt-in admission
  , AdmissionDefect (..)
  , OptIn (..)
  , admitOptIn
  , preflightOptIn
  , Terminal (..)
  , TakeTerminal (..)
  , takeTerminal
  , releaseSettled
  , takeDefects
  , takeCleanup
  , takeDiscards
  , takePendingAdoptions
  , finishAdoption
  , failAdoption

    -- * Answering
  , Checked (..)
  , checkReply
  , checkReplyFor
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
  , catchSTM
  , modifyTVar'
  , newTVarIO
  , orElse
  , readTVar
  , throwSTM
  , writeTVar
  )
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , fromException
  , throwIO
  )
import Control.Monad (foldM, forM, forM_, unless, when)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing)
import qualified Data.ByteString as ByteString
import Data.Sequence ((|>))
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import Data.Word (Word64)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (operation, throwFailure)
import Hetoimasia.Scripting.Lua.Instance.Types
  ( ICell (icId, icState)
  , IState (isDispatchQueued, isPhase, isRequestFailure, isStopped)
  , InstanceBounds (boundInvocationQueue)
  , InstancePhase (Initializing)
  , Instances (insBounds, insCells, insInbox, insRunning)
  , Job (JobDispatch, JobForget)
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
import Hetoimasia.Scripting.Lua.Lease.State (Leases, Refusal (CapacityExhausted), Scope (scopeOpen), abandon, readScope, renderCaught, reserve, slotPresent)
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
import Hetoimasia.Scripting.Lua.Provider.Events (SubEnd (EndByEpoch, EndByOwner), awaiting, cellOf, endSubs, requesterClosed)
import Hetoimasia.Scripting.Lua.Provider.Types
import Hetoimasia.Scripting.Lua.Owner (maxEntries)
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

-- | The subscription grant's endpoints by name, or every reason it is refused. The grant is made
-- over the request service and the instances (whether the owner has each is given), and its
-- endpoints each take an entry point in the driver beside the owner's event sources, which the
-- driver module can only hold so many of.
validateSubscriptions ∷ Bool → Bool → Int → SubscriptionGrant → Either (NonEmpty SubscriptionGrantViolation) (Map Text EventEndpoint)
validateSubscriptions hasService hasInstances sources grant = case NonEmpty.nonEmpty violations of
  Just refused → Left refused
  Nothing → Right (Map.fromList [(eventName endpoint, endpoint) | endpoint ← endpoints])
  where
    endpoints = grantEvents grant
    names = map eventName endpoints
    room = maxEntries - 5 - sources
    violations =
      [SubscriptionBoundOutOfRange (grantSubscriptionBound grant) | grantSubscriptionBound grant < 1 || grantSubscriptionBound grant > maxSubscriptionBound]
        <> [StagingBoundOutOfRange (grantStagingBound grant) | grantStagingBound grant < 1 || grantStagingBound grant > maxSubscriptionBound]
        <> [NoEventEndpoints | null endpoints]
        <> [InvalidEventName name | name ← names, isJust (validName name) || isJust (validName ("subscription_" <> name))]
        <> [DuplicateEventName name | name ← nub names, length (filter (== name) names) > 1]
        <> [EventPayloadCapability (eventName endpoint) | endpoint ← endpoints, hasCapabilityIn (eventPayload endpoint)]
        <> [SubscriptionsNeedService | not hasService]
        <> [SubscriptionsNeedInstances | not hasInstances]
        <> [TooManyEventEndpoints (length endpoints) room | length endpoints > room]
    hasCapabilityIn = \case
      SCapability _ → True
      SList inner → hasCapabilityIn inner
      SOptional inner → hasCapabilityIn inner
      SRecord fields → any (hasCapabilityIn . snd) fields
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

-- | The protocol model's caps for a service: the requests and the subscriptions are the ones
-- that matter, and the rest are the least the model accepts, since this session holds no
-- tasks. A subscription's backlog is bounded by the places of its instance's queue, which it
-- shares with every other delivery, so the model's bound is never the one that refuses.
requestLimits ∷ ValueLimits → Int → RequestGrant → Maybe SubscriptionGrant → Limits
requestLimits limits queue grant subscriptions =
  Limits
    { maxActiveTasks = 1
    , maxQueuedAdmissions = 1
    , maxSubscriptions = maybe 1 grantSubscriptionBound subscriptions
    , maxSubscriptionQueue = queue
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
  → Maybe (SubscriptionGrant, Map Text EventEndpoint)
  → Ticks
  → Maybe Instances
  → Maybe Leases
  → IO ProviderState
newProviderState owner label key limits grant endpoints subscriptions ticks instances leases = do
  session ← case newSession key (requestLimits limits (maybe 1 (boundInvocationQueue . insBounds) instances) grant (fst <$> subscriptions)) of
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
        , pSubs = Map.empty
        , pSubNumbers = Map.empty
        , pStaged = Map.empty
        , pEvents = noEventCounts
        , pNextSub = 1
        , pHeld = Map.empty
        , pAdopting = Map.empty
        , pDefects = []
        , pCleanup = []
        , pDiscards = []
        , pForget = Map.empty
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
      , psLeases = leases
      , psEvents = maybe Map.empty snd subscriptions
      , psSubscriptionBound = maybe 1 (grantSubscriptionBound . fst) subscriptions
      , psStagingBound = maybe 1 (grantStagingBound . fst) subscriptions
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

-- | Move the next request number forward to at least this one, answering the number the next
-- request will be given. The number never rewinds and no number is reissued: skipping only
-- leaves some unused, which nothing observes but the ceiling the numbers are counted against. It
-- is how a qualification brings the counter to its ceiling without issuing every number.
skipNumbers ∷ ProviderState → Word64 → STM Word64
skipNumbers service wanted = do
  st ← readTVar (psVar service)
  let next = max wanted (pNext st)
  next <$ writeTVar (psVar service) st {pNext = next}

-- | The phase of the instance whose code is running, if one is: what a hook that may not wait
-- or may not start work reads. Engine-owned, never a script's claim.
callerPhaseOf ∷ ProviderState → STM (Maybe InstancePhase)
callerPhaseOf service = do
  caller ← callerOf service
  case (caller, psInstances service) of
    (CallerInstance number, Just instances) → do
      cells ← readTVar (insCells instances)
      forM (Map.lookup number cells) (fmap isPhase . readTVar . icState)
    _ → pure Nothing

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

-- | The places the owner's one bound is on, whatever kind of request holds them: the places 'chargedPlaces'
-- counts, and the opt-in requests whose results were taken or discarded but whose provider work is not
-- yet retired. A request is counted once, whichever of the two accounts holds it.
ownerPlaces ∷ PState → Int
ownerPlaces st =
  Set.size
    ( Set.fromList (Map.keys (sessionRequests (pSession st)))
        `Set.union` Set.fromList [recIdentity record | record ← Map.elems (pRecs st), isJust (recEnded record)]
        `Set.union` Map.keysSet (pHeld st)
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
              _ | ownerPlaces st >= bound → refuse (RequestsFull bound)
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
                        , recAdmission = Nothing
                        , recFailure = Nothing
                        , recLease = Nothing
                        , recAdopted = False
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
                        , workSubscription = Nothing
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
-- is settled or invalidated, and the capacity is free again, every bank the opt-in admission
-- reserved with it included: the credits are returned unused, the reserved lease discharged, the
-- places in the ledger given back and a resource reply it had already received dropped.
--
-- A credit whose release raises does not keep the rest from being taken back: each release is its
-- own undoable step, the removal of the unsubmitted work and of everything independent of the credit
-- is committed whatever it raised, and what was raised is answered, for the caller to keep beside
-- the failure that made the withdrawal necessary.
withdrawAdmission ∷ ProviderState → RequestId → STM [SomeException]
withdrawAdmission service identity = do
  st ← readTVar (psVar service)
  let gated = Map.lookup identity (pRecs st) >>= recGated
  mapM_ (ticksRelease (psTicks service)) gated
  failures ← case Map.lookup identity (pHeld st) of
    Nothing → pure []
    Just held → do
      released ← forM (heldCredits held) (\credit → releaseCredit credit CreditUnused)
      forM_ ((,) <$> psLeases service <*> heldLease held) (uncurry abandon)
      pure (catMaybes released)
  writeTVar (psVar service) st
    { pSession = withdrawRequest identity (pSession st)
    , pRecs = Map.delete identity (pRecs st)
    , pByNumber = Map.filter (/= identity) (pByNumber st)
    , pWork = Map.delete identity (pWork st)
    , pDue = Map.filter (/= identity) (pDue st)
    , pHeld = Map.delete identity (pHeld st)
    , pAdopting = unclaimed (Map.delete identity) (pAdopting st)
    }
  pure failures

-- | Give a credit back, once: what the provider's release raises is answered and not raised, with
-- what the release wrote undone, so one provider's failure never keeps another's credit, a lease or a
-- place charged.
releaseCredit ∷ Credit → CreditEnd → STM (Maybe SomeException)
releaseCredit credit end = (Nothing <$ creditRelease credit end) `catchSTM` (pure . Just)

-- The opt-in admission ----------------------------------------------------------------

-- | The engine could not keep an admission's or a settlement's bookkeeping consistent: a counter
-- past what it holds after the admission was valid, a result lease reserved without the way to
-- hand its handle to the script, a settlement an opt-in service never declared. A failure of the
-- host, raised from the transaction it was found in: never a refusal, and never busy.
newtype AdmissionDefect = AdmissionDefect Text
  deriving (Eq, Show)

instance Exception AdmissionDefect

-- | Why an opt-in admission stopped, raised inside its one transaction so that everything it had
-- reserved before is undone with it. Private to this module: nothing else raises it.
data AdmitStop
  = StopBank !Bank
  | StopRefused !RequestRefusal
  deriving (Show)

instance Exception AdmitStop

-- | Raised to undo a credit that was only being asked whether it is full for good.
data CreditProbed = CreditProbed
  deriving (Show)

instance Exception CreditProbed

-- | What an opt-in admission came to.
data OptIn
  = -- | Accepted: every bank reserved, the place assigned, nothing else done yet.
    OptInAccepted !Admitted
  | -- | A temporary bank had no room: nothing at all was reserved.
    OptInBusy !Bank
  | -- | A permanent fact refuses it: nothing was reserved.
    OptInRefused !RequestRefusal

-- | The place of an opt-in request, or the permanent reason it has none: decided from what the
-- caller read in one transaction, and the same for the preflight a binding's precondition makes
-- and for the admission itself.
--
-- The reasons are decided in this order, and the order is the contract: the owner or the requester
-- is not taking requests, the requester is no instance, the request numbers are exhausted, an
-- owner that settles on arrival was given an offset, the offset is not positive, the tick and the
-- offset do not sum to a position within the ceiling, that position has begun.
optInSlot ∷ ProviderState → Requester → Admission → Bool → Word64 → Maybe InstancePhase → Word64 → Either RequestRefusal (Maybe DueSlot)
optInSlot service requester ask taking now phase number
  | not taking = Left RequestsClosed
  | RequesterTask _ ← requester = Left RequestNotAnInstance
  | number > admitLogicalMaximum ask = Left (RequestNumbersExhausted (admitLogicalMaximum ask))
  | otherwise = case psTiming service of
      SettleOnArrival
        | isJust (admitOffset ask) → Left RequestOffsetOnArrival
        | otherwise → Right Nothing
      SettleAtAssignedTick _
        | offset == 0 → Left RequestOffsetInvalid
        | tick > toInteger (admitLogicalMaximum ask) → Left (RequestTickUnrepresentable (admitLogicalMaximum ask))
        | tick <= toInteger now → Left RequestLate
        | otherwise → Right (Just (DueSlot (fromInteger tick) number))
        where
          offset = fromMaybe 1 (admitOffset ask)
          -- Init is before tick 1: its origin is 0 (D-67). Everything else is made at the tick
          -- the owner is at.
          origin = if phase == Just Initializing then 0 else now
          tick = toInteger origin + toInteger offset

-- | What a binding's precondition may know of an opt-in request before it asks: the permanent
-- refusal the admission itself would make if it were asked now, read in one transaction. It
-- reserves nothing and writes nothing. A bank that is merely full is not here: that is busy,
-- an answer of the admission, and a fact that can change before it.
preflightOptIn ∷ ProviderState → Requester → Admission → STM (Maybe RequestRefusal)
preflightOptIn service requester ask = do
  st ← readTVar (psVar service)
  open ← ticksOpen (psTicks service)
  closedRequester ← requesterClosed service requester
  now ← ticksNow (psTicks service)
  phase ← callerPhaseOf service
  scope ← leaseScopeOpen service requester
  let taking = not (pClosed st) && open && not closedRequester
  pure $ case optInSlot service requester ask taking now phase (pNext st) of
    Left why → Just why
    Right _
      | isJust (admitLease ask) && not scope → Just RequestNoLeaseScope
      | otherwise → Nothing

-- | Whether a requester has a lease scope that is taking reservations.
leaseScopeOpen ∷ ProviderState → Requester → STM Bool
leaseScopeOpen service = \case
  RequesterInstance number | Just leases ← psLeases service → maybe False scopeOpen <$> readScope leases number
  _ → pure False

-- | Admit an opt-in request: every permanent check, then every bank, then the place, the model's
-- acceptance, the reserved result lease, the provider's credits, the owner's hold on the due
-- tick and the ledger's entry, all in the one transaction. A bank without room, or a permanent
-- refusal, raises inside it, and everything it had reserved before is undone: no handle, no
-- hold, no credit, no lease slot, no counter. The tick is read in the same transaction as the
-- hold, so a request accepted for a tick is held before that tick can begin; the sequence is the
-- request number it is given in the same transaction, never read apart from it.
--
-- The banks are decided in this order, and the order is the contract: the instance's accepted,
-- unretired requests, the VM's, the owner's places, the model's, the instance's lease capacity,
-- then each provider credit in the order they were declared. What is counted is the ledger, which
-- only the owner's own transactions shorten, never a provider's completion.
admitOptIn ∷ ProviderState → Requester → RequestEndpoint → Admission → STM OptIn
admitOptIn service requester endpoint ask = (OptInAccepted <$> attempt) `catchSTM` stopped
  where
    stopped ∷ AdmitStop → STM OptIn
    stopped stop = do
      modifyTVar' (psVar service) $ \st →
        st {pCounts = case stop of
          StopBank _ → (pCounts st) {countBusy = countBusy (pCounts st) + 1}
          StopRefused _ → (pCounts st) {countRefused = countRefused (pCounts st) + 1}}
      pure $ case stop of
        StopBank bank → OptInBusy bank
        StopRefused why → OptInRefused why
    stop' ∷ Exception e ⇒ e → STM a
    stop' = throwSTM
    -- Whether the credit says it can never be had, with everything it wrote undone.
    probeCredit ∷ Credit → STM (Maybe Text)
    probeCredit credit =
      ((creditReserve credit `orElse` pure False) *> throwSTM CreditProbed)
        `catchSTM` \(caught ∷ SomeException) → case fromException caught of
          Just CreditProbed → pure Nothing
          Nothing → case fromException caught of
            Just (CreditRefused why) → pure (Just why)
            Nothing → throwSTM caught
    attempt = do
      st ← readTVar (psVar service)
      open ← ticksOpen (psTicks service)
      closedRequester ← requesterClosed service requester
      now ← ticksNow (psTicks service)
      phase ← callerPhaseOf service
      let number = pNext st
          taking = not (pClosed st) && open && not closedRequester
      slot ← either (stop' . StopRefused) pure (optInSlot service requester ask taking now phase number)
      -- The place is taken only by an assignment the application made for a request that is not
      -- this kind; the sequence of this one is its own number, which no request shares.
      forM_ slot $ \due → when (Map.member due (pDue st)) (stop' (StopRefused RequestDuplicatePlace))
      when (number == maxBound) (stop' (AdmissionDefect "the request counter has no number after the last"))
      when (isJust (admitLease ask) && isNothing (admitCombine ask)) $
        stop' (AdmissionDefect "an admission that reserves a result lease says nothing of how its handle reaches the script")
      instanceNumber ← case requester of
        RequesterInstance found → pure found
        RequesterTask _ → stop' (StopRefused RequestNotAnInstance)
      -- A credit that is full for good refuses before any bank is asked: waiting cannot help, so a full
      -- temporary bank must not be the answer. Each credit is tried and undone, so nothing it wrote stays
      -- and nothing is decided about a bank that may empty.
      forM_ (admitCredits ask) $ \credit → do
        refused ← probeCredit credit
        forM_ refused $ \why → stop' (StopRefused (RequestCreditRefused why))
      let mine = length [() | held ← Map.elems (pHeld st), heldRequester held == requester]
          ledger = Map.size (pHeld st)
      when (mine >= admitPerInstance ask) (stop' (StopBank (BankInstanceRequests (admitPerInstance ask))))
      when (ledger >= admitPerVm ask) (stop' (StopBank (BankVmRequests (admitPerVm ask))))
      -- The owner's one bound counts every request's place, a generic request's retained result included.
      when (ownerPlaces st >= psBound service) (stop' (StopBank (BankOwnerRequests (psBound service))))
      let (holder, withHolder) = case Map.lookup requester (pHolders st) of
            Just held → (held, pSession st)
            Nothing → issueHolder (pSession st)
      (session, identity) ← case acceptRequestFor holder (RequestName number) (EndpointId (endpointName endpoint)) withHolder of
        (_, Left (CapReached OutstandingRequests full)) → stop' (StopBank (BankOwnerRequests full))
        (_, Left _) → stop' (StopRefused RequestsClosed)
        (accepted, Right found) → pure (accepted, found)
      leaseKey ← case (admitLease ask, psLeases service) of
        (Nothing, _) → pure Nothing
        (Just _, Nothing) → stop' (StopRefused RequestNoLeaseScope)
        (Just ownership, Just leases) → do
          reserved ← reserve leases instanceNumber ownership
          case reserved of
            Right key → pure (Just key)
            Left (CapacityExhausted capacity charged) → stop' (StopBank (BankLeases capacity charged))
            Left _ → stop' (StopRefused RequestNoLeaseScope)
      forM_ (admitCredits ask) $ \credit → do
        -- A provider's bank never makes the admission wait: one that retries is full.
        -- A credit that is full for good says so, and the refusal is final: it is not a bank that may empty.
        reserved ←
          (creditReserve credit `orElse` pure False)
            `catchSTM` \(CreditRefused why) → stop' (StopRefused (RequestCreditRefused why))
        unless reserved (stop' (StopBank (BankCredit (creditName credit))))
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
              , recAdmission = Just ask
              , recFailure = Nothing
              , recLease = leaseKey
              , recAdopted = False
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
              , workSubscription = Nothing
              }
      writeTVar (psVar service) st
        { pSession = session
        , pRecs = Map.insert identity record (pRecs st)
        , pByNumber = Map.insert number identity (pByNumber st)
        , pWork = Map.insert identity work (pWork st)
        , pHolders = Map.insert requester holder (pHolders st)
        , pDue = maybe id (\due → Map.insert due identity) slot (pDue st)
        , pHeld = Map.insert identity (Held requester (admitCredits ask) leaseKey Nothing) (pHeld st)
        , pNext = number + 1
        , pCounts = (pCounts st) {countAdmitted = countAdmitted (pCounts st) + 1}
        }
      pure (Admitted number identity requester slot)

-- | A terminal result, as the service hands it to the adapter that makes the record a script
-- is given: a success with the value the script is handed for it (the adopted lease's handle
-- composed in), an expected failure, or a cancellation.
data Terminal
  = TerminalSuccess !Value
  | TerminalFailure !ExpectedFailure
  | TerminalCancelled
  deriving (Show)

-- | What taking an opt-in request found.
data TakeTerminal
  = TakeTerminalRefused !RequestRefusal
  | -- | Not settled. Nothing was taken.
    TakeTerminalPending
  | -- | The terminal result, taken once. The handle names nothing now.
    TakeTerminal !Terminal

-- | Take an opt-in request's terminal result, once. Taking the record is the generic take; what
-- it adds is the terminal in the shape the service declared, and the release of the banks the
-- request held if its provider has already been accounted retired. Taking a success whose resource
-- was adopted does not release the lease: the instance owns the resource, and the handle in the
-- value is the script's way to it.
takeTerminal ∷ ProviderState → Requester → Word64 → STM TakeTerminal
takeTerminal service requester number = do
  st ← readTVar (psVar service)
  case reach requester number st of
    Left why → pure (TakeTerminalRefused why)
    Right record → do
      answer ← takeOf service requester number
      case answer of
        TakeRefused why → pure (TakeTerminalRefused why)
        TakePending → pure TakeTerminalPending
        TakeSettled settlement → do
          terminal ← case settlement of
            SettledResult payload → pure (TerminalSuccess (composed record (payloadValue payload)))
            SettledFailure _ → case recFailure record of
              Just found → pure (TerminalFailure found)
              Nothing → throwSTM (AdmissionDefect "an opt-in request settled as a failure that carries no declared failure")
            SettledCancelled _ → pure TerminalCancelled
          releaseSettled service
          pure (TakeTerminal terminal)
  where
    composed record value = case (recAdmission record >>= admitCombine, recLease record, recAdopted record) of
      (Just combine, Just key, True) → combine value key
      _ → value

-- | Give back what the opt-in requests no longer hold, on the owner's thread, where the owner
-- accounts for it. A request's places and credits are given back when its result has been taken
-- or discarded /and/ the provider's work on it has been reaped as retired; the lease it reserved
-- and never used is discharged as soon as that work is retired and the request has settled
-- or gone. A lease that was adopted is the instance's resource, and nothing here touches it. Never
-- called from a provider's completion: a capacity a native thread frees is not visible to
-- admission until the owner's next accounted boundary, or the take that finds it already
-- accounted.
releaseSettled ∷ ProviderState → STM ()
releaseSettled service = do
  st ← readTVar (psVar service)
  kept ← foldM (settle st) Map.empty (Map.toList (pHeld st))
  st' ← readTVar (psVar service)
  writeTVar (psVar service) st' {pHeld = kept}
  where
    settle st kept (identity, held) = do
      let reaped = Map.notMember identity (pWork st)
          record = Map.lookup identity (pRecs st)
          resolved = maybe True (isSettled st) record && Map.notMember identity (pAdopting st)
      -- A reservation nothing will use any more: its work is retired and the request has
      -- settled without a resource for it (or is gone).
      held' ←
        if reaped && resolved && isJust (heldLease held)
          then do
            forM_ ((,) <$> psLeases service <*> heldLease held) (uncurry abandon)
            pure held {heldLease = Nothing}
          else pure held
      -- A resource whose building failed keeps its credits charged until its rolled-back stages are
      -- retired and its slot is gone.
      retiring ← case (psLeases service, heldRetiring held') of
        (Just leases, Just key) → slotPresent leases key
        _ → pure False
      if reaped && isNothing record && not retiring
        then do
          released ← forM (heldCredits held') (\credit → releaseCredit credit CreditSettled)
          unless (null (catMaybes released)) $
            modifyTVar' (psVar service) (\now → now {pCleanup = take defectLimit (pCleanup now <> catMaybes released)})
          pure kept
        else pure (Map.insert identity held' kept)

-- | Drop entries from the resource replies waiting to be built, but never one the owner is
-- building: the building finishes or fails it.
unclaimed ∷ (Map RequestId Adopting → Map RequestId Adopting) → Map RequestId Adopting → Map RequestId Adopting
unclaimed drop' held = Map.union (Map.filter adoptingClaimed held) (drop' (Map.filter (not . adoptingClaimed) held))

-- | The adopted lease of a record whose result the script will never be handed, as the instance
-- and key to release: the resource was built for a request that is cancelled.
adoptedOf ∷ Rec → [(Word64, Word64)]
adoptedOf record = case (recAdopted record, recLease record, recRequester record) of
  (True, Just key, RequesterInstance number) → [(number, key)]
  _ → []

-- | The adopted leases to release, taken: each is the caller's to release on the owner's thread.
takeDiscards ∷ ProviderState → STM [(Word64, Word64)]
takeDiscards service = do
  st ← readTVar (psVar service)
  writeTVar (psVar service) st {pDiscards = []}
  pure (pDiscards st)

-- | The failures of providers' credit releases the owner has yet to keep as cleanup evidence, taken.
takeCleanup ∷ ProviderState → STM [SomeException]
takeCleanup service = do
  st ← readTVar (psVar service)
  writeTVar (psVar service) st {pCleanup = []}
  pure (pCleanup st)

-- | The provider defects the owner has yet to raise, taken, oldest first.
takeDefects ∷ ProviderState → STM [Text]
takeDefects service = do
  st ← readTVar (psVar service)
  writeTVar (psVar service) st {pDefects = []}
  pure (pDefects st)

-- | The resource replies the owner has yet to build into their leases, taken: each is the
-- caller's to build, and to finish with 'finishAdoption' or 'failAdoption'.
takePendingAdoptions ∷ ProviderState → STM [(RequestId, Adopting)]
takePendingAdoptions service = do
  st ← readTVar (psVar service)
  let waiting = Map.filter (not . adoptingClaimed) (pAdopting st)
  writeTVar (psVar service) st {pAdopting = Map.map (\adopting → adopting {adoptingClaimed = True}) (pAdopting st)}
  pure (Map.toList (Map.map (\adopting → adopting {adoptingClaimed = True}) waiting))

-- | The resource of a request was built into its reserved lease: the lease is live, the places
-- the credits that transfer were held for belong to the resource now, and the result is applied as
-- though the provider had just given it (held for its tick, or settled). A request that was
-- cancelled or ended while the resource was being built is no longer waiting for it: answers
-- 'Nothing', and the caller releases what it built.
finishAdoption ∷ ProviderState → RequestId → Adopting → STM (Maybe ReplyAnswer)
finishAdoption service identity adopting = do
  st ← readTVar (psVar service)
  let waiting = case Map.lookup identity (pRecs st) of
        Just record → isNothing (recEnded record) && maybe False (isNothing . requestSettlement) (Map.lookup identity (sessionRequests (pSession st)))
        Nothing → False
  if not waiting
    then -- The request is no longer waiting for it, but the resource was built: its credits that
         -- transfer are the resource's from here, whatever becomes of it, and the lease it was
         -- built into is released by the caller, which returns them.
      Nothing
        <$ writeTVar
          (psVar service)
          st
            { pAdopting = Map.delete identity (pAdopting st)
            , pHeld = Map.adjust (\held → held {heldLease = Nothing, heldCredits = filter (not . creditTransfers) (heldCredits held)}) identity (pHeld st)
            }
    else do
      writeTVar (psVar service) st
        { pRecs = Map.adjust (\record → record {recAdopted = True}) identity (pRecs st)
        , pHeld = Map.adjust (\held → held {heldLease = Nothing, heldCredits = filter (not . creditTransfers) (heldCredits held)}) identity (pHeld st)
        , pAdopting = Map.delete identity (pAdopting st)
        , pCounts = (pCounts st) {countAdopted = countAdopted (pCounts st) + 1}
        }
      Just <$> applyChecked service identity (CheckedResult (adoptingBytes adopting) (adoptingValue adopting))

-- | Building a request's resource failed: the reservation was given back by the building, and the
-- request no longer holds a lease. The failure is the owner's to raise.
failAdoption ∷ ProviderState → RequestId → STM ()
failAdoption service identity = do
  st ← readTVar (psVar service)
  -- The building rolled its stages back; a stage whose retirement the provider has yet to finish keeps the
  -- slot, and with it the credits that were to transfer, charged until it does.
  retained ← case (psLeases service, Map.lookup identity (pHeld st) >>= heldLease) of
    (Just leases, Just key) → slotPresent leases key
    _ → pure False
  writeTVar (psVar service) st
    { pHeld = Map.adjust (\held → held {heldLease = Nothing, heldRetiring = if retained then heldLease held else Nothing}) identity (pHeld st)
    , pAdopting = Map.delete identity (pAdopting st)
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
  | -- | An expected failure of an opt-in request, with a code its service supplies, its message and
    -- identities within the bounds.
    CheckedExpected !ExpectedFailure
  | -- | A result whose resource the owner is to build into the request's reserved lease: its
    -- size, the value, and the recipe.
    CheckedResource !Int !Value !Adoption
  | -- | A provider defect: what an opt-in request's service did not declare, and why (bounded).
    CheckedDefect !Text

-- | Check a reply against the owner's value limits and the endpoint's schema, evaluating it
-- fully inside the one guard, so a value that throws when it is first looked at is a
-- malformed reply and not an exception loose in a transaction.
checkReply ∷ ValueLimits → Schema → ProviderReply → IO Checked
checkReply limits schema = checkReplyFor limits schema Nothing

-- | The same, for a request that may have been admitted through the opt-in 'Admission'.
--
-- A request that was not admitted so settles a reply the generic way: what is not within the
-- limits or the schema settles it as a validation failure. One that was admitted so takes the
-- service's contract: the value must be within the admission's ceilings and its envelope (the
-- record a script is handed) within the owner's; an expected failure must carry a code the
-- service supplies and a root and path within their bound (its message is cut, visibly, until
-- the envelope fits); and a reply that is none of these is a provider defect, never a failure of
-- the request and never an invented code.
--
-- The reply itself is evaluated inside the guard before anything is read of it: a reply whose strict
-- field throws when the constructor is first looked at (a failure whose message is an error, say) is a
-- malformed reply, or a defect for an opt-in request, and never an exception loose on the provider's
-- thread with the request left pending. An asynchronous exception is never taken for one.
checkReplyFor ∷ ValueLimits → Schema → Maybe Admission → ProviderReply → IO Checked
checkReplyFor limits schema ask given =
  guarded (pure given) >>= \case
    Right reply → checkEvaluated limits schema ask reply
    Left failure@(ExceptionWithContext _ raised)
      | Just (async ∷ SomeAsyncException) ← fromException raised → throwIO async
      | otherwise → do
          why ← renderCaught failure
          pure $ case ask of
            Nothing → CheckedMalformed (fitReason limits ("the reply could not be evaluated: " <> Text.take 200 why))
            Just _ → CheckedDefect ("the provider's reply could not be evaluated: " <> Text.take 200 why)

-- | 'checkReplyFor' of a reply that is evaluated to its constructor.
checkEvaluated ∷ ValueLimits → Schema → Maybe Admission → ProviderReply → IO Checked
checkEvaluated limits schema ask reply = case ask of
  Nothing → fitted <$> judgeWith resultFields (const True) limits schema (generic reply)
  Just opted → optedIn opted
  where
    -- The one place a reason is fitted, whatever made the reply a failure: nothing reaches
    -- the model or the held completion whose record would not fit the limits.
    fitted = \case
      CheckedFailure why → CheckedFailure (fitReason limits why)
      CheckedMalformed why → CheckedMalformed (fitReason limits why)
      other → other
    -- What a request that took no opt-in makes of the two replies it does not know: the failure
    -- it would be, and a result without its resource.
    generic = \case
      ProviderExpected found → ProviderFailure (expectedMessage found)
      ProviderResource value _ → ProviderResult value
      other → other
    optedIn opted = case reply of
      ProviderFailure _ → pure (CheckedDefect "the provider answered a failure with no code its service supplies")
      ProviderExpected found → guardedVerdict (expected opted found)
      ProviderResult value → result opted value Nothing
      ProviderResource value recipe → result opted value (Just recipe)
    result opted value recipe = do
      -- The combiner shapes what a script is handed only for a result whose resource the owner builds
      -- into the reserved lease: a plain result is handed as it is, and it is that record that is measured.
      let adopting = isJust recipe && isJust (admitLease opted)
          combined found = case admitCombine opted of
            Just make | adopting → make found 0
            _ → found
          frame found = admitSuccessFrame opted (combined found)
          -- What is retained is the provider's own value, whatever the combiner hands the script in its
          -- place: for a result whose resource is built, that value too is bounded by the owner's limits
          -- and the admission's ceilings, as the plain record it would be.
          plain found = admitSuccessFrame opted found
          retainedFits found = not adopting || (fitsLimits limits (plain found) && fitsLimits (admitReplyLimits opted) (plain found))
          retainedBytes found = either (const 0) id (valuesFootprint limits [VRecord (plain found)])
          -- The ceilings are the crossing's: the complete record a script is handed, and the value kept.
          withinCeilings found = fitsLimits (admitReplyLimits opted) (frame found) && retainedFits found
      judged ← judgeWith frame withinCeilings limits schema (ProviderResult value)
      pure $ case judged of
        CheckedResult bytes found → case recipe of
          Just made | adopting → CheckedResource (max bytes (retainedBytes found)) found made
          _ → CheckedResult bytes found
        CheckedOversize _ → CheckedDefect "the provider's result is over the ceilings its service declares"
        CheckedMalformed why → CheckedDefect (Text.take 480 why)
        _ → CheckedDefect "the provider's result could not be checked"
    expected opted found
      | expectedCode found `notElem` admitExpectedCodes opted = CheckedDefect ("the provider answered a failure whose code " <> Text.take 64 (expectedCode found) <> " its service does not supply")
      | any (longerThan (admitPathBytes opted)) (catMaybes [expectedRoot found, expectedPath found]) = CheckedDefect "the provider answered a failure whose root or path is over its bound"
      | otherwise = maybe (CheckedDefect "the provider answered a failure whose envelope cannot be delivered within the limits") CheckedExpected (fitFailure opted found)
    longerThan bound text = ByteString.length (Encoding.encodeUtf8 text) > bound
    -- The verdict on a failure is evaluated here, inside the guard, as a result's is: a field that
    -- throws when it is first looked at is a provider defect, and an asynchronous exception is
    -- never taken for one.
    guardedVerdict verdict =
      guarded (pure verdict) >>= \case
        Right found → pure found
        Left failure@(ExceptionWithContext _ raised)
          | Just (async ∷ SomeAsyncException) ← fromException raised → throwIO async
          | otherwise → CheckedDefect . ("the provider answered a failure that could not be evaluated: " <>) . Text.take 200 <$> renderCaught failure
    -- The failure's envelope as a script is handed it must fit the owner's ceilings. A message
    -- that makes it too long is cut at a character, visibly, until it does.
    fitFailure opted found = go (admitMessageBytes opted)
      where
        go bound =
          let candidate = found {expectedMessage = truncateVisibly bound (expectedMessage found)}
           in if fitsLimits limits (admitFailureFrame opted candidate) && fitsLimits (admitReplyLimits opted) (admitFailureFrame opted candidate)
                then Just candidate
                else if bound <= 0 then Nothing else go (bound `div` 2)

-- | Cut text to at most this many UTF-8 bytes, at a character, and visibly: the end of what is
-- kept is an ellipsis, so a reader can tell the text was cut.
truncateVisibly ∷ Int → Text → Text
truncateVisibly bound text
  | bytes text <= bound = text
  | bound < 3 = Text.empty
  | otherwise = go (bound - 3) text <> "..."
  where
    bytes = ByteString.length . Encoding.encodeUtf8
    go room remaining = case Text.uncons remaining of
      Just (character, rest)
        | width character <= room → Text.cons character (go (room - width character) rest)
      _ → Text.empty
    width = ByteString.length . Encoding.encodeUtf8 . Text.singleton

-- | Judge a reply: the record a script is handed for the value (its frame) is measured against
-- the limits, the value against any ceilings beside them, and the value against the schema.
judgeWith ∷ (Value → [(Text, Value)]) → (Value → Bool) → ValueLimits → Schema → ProviderReply → IO Checked
judgeWith frame ceilings limits schema = \case
  ProviderFailure why → pure (CheckedFailure why)
  ProviderResult value → do
    judged ← guarded (pure (judge value))
    case judged of
      Right verdict → pure verdict
      Left failure@(ExceptionWithContext _ raised)
        | Just (async ∷ SomeAsyncException) ← fromException raised → throwIO async
        | otherwise → CheckedMalformed . ("the result could not be evaluated: " <>) <$> renderCaught failure
  other → pure (CheckedMalformed ("the reply is not a result or a failure: " <> Text.pack (take 32 (show other))))
  where
    -- What is measured is the record a script is handed on taking it, not the bare value, so
    -- that a result which is retained is a result that can be delivered within the limits.
    judge value = case valuesFootprint limits [VRecord (frame value)] of
      Left _ → CheckedOversize (limitBytes limits + 1)
      Right _ | not (ceilings value) → CheckedOversize (limitBytes limits + 1)
      Right bytes → case conformValue plainContext schema value of
        Left (_, rule) → CheckedMalformed ("the result does not conform to the endpoint's schema: " <> Text.pack (show rule))
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
  CheckedResource bytes value _ → ReplyResult (Payload bytes value)
  CheckedFailure why → ReplyFailure (failureReason ProviderFault why)
  CheckedExpected found → ReplyFailure (failureReason ProviderFault (expectedMessage found))
  -- The model settles an unsettled request as a failure, and never stores the value.
  CheckedOversize declared → ReplyResult (Payload declared VNil)
  CheckedMalformed why → ReplyFailure (failureReason ValidationFault why)
  -- A defect settles nothing: it is never applied to an unsettled request, and for a settled one
  -- the model refuses whatever it is given.
  CheckedDefect why → ReplyFailure (failureReason ProviderFault why)

-- | Answer a request. One transaction, never waiting.
--
-- A resource reply to a request that reserved a result lease is not applied yet: the owner builds
-- the resource into the lease at its next boundary and applies the result then ('finishAdoption'),
-- so a result is never visible, held or settled, before the instance owns what it names. A
-- defect is recorded for the owner to raise, once, and settles nothing: the provider's work is
-- proved over, and the request stays as it was until the owner's failure revokes it.
replyTo ∷ ProviderState → RequestId → Checked → STM ReplyAnswer
replyTo service identity checked = do
  st ← readTVar (psVar service)
  let session = pSession st
      unsettled = maybe False (isNothing . requestSettlement) (Map.lookup identity (sessionRequests session))
      record = Map.lookup identity (pRecs st)
  case (checked, record) of
    -- A reply that comes while a resource reply is waiting to be built is a duplicate whatever it
    -- is: the first accepted completion is the one, and nothing replaces it.
    _ | Map.member identity (pAdopting st) → do
          writeTVar (psVar service) st {pCounts = (pCounts st) {countDuplicateHeld = countDuplicateHeld (pCounts st) + 1}}
          pure ReplyLate
    (CheckedDefect why, Just _)
      | unsettled → do
          writeTVar (psVar service) $
            endWork identity st
              { pDefects = take defectLimit (pDefects st <> [Text.take 512 why])
              , pCounts = (pCounts st) {countDefects = countDefects (pCounts st) + 1}
              }
          pure ReplyDefective
    (CheckedResource bytes value build, Just found)
      | unsettled
      , Just key ← recLease found
      , Just number ← instanceOf (recRequester found) →
          if isJust (recHeld found) || Map.member identity (pAdopting st)
            then do
              writeTVar (psVar service) st {pCounts = (pCounts st) {countDuplicateHeld = countDuplicateHeld (pCounts st) + 1}}
              pure ReplyLate
            else do
              writeTVar (psVar service) $
                endWork identity st
                  { pAdopting = Map.insert identity (Adopting key number build value bytes False) (pAdopting st)
                  }
              pure ReplyAdoption
    _ → applyChecked service identity checked
  where
    instanceOf = \case
      RequesterInstance number → Just number
      RequesterTask _ → Nothing

-- | Apply a checked reply to its request: hold it for its tick on an owner that settles at
-- assigned ticks, or settle it. The one place a reply reaches the model, whether it arrived from
-- a provider's thread or was completed by the owner after building its resource.
applyChecked ∷ ProviderState → RequestId → Checked → STM ReplyAnswer
applyChecked service identity checked = do
  st ← readTVar (psVar service)
  let session = pSession st
      reply = modelReply checked
      refusedValue = case checked of
        CheckedOversize _ → True
        CheckedMalformed _ → True
        _ → False
      failureOf = case checked of
        CheckedExpected found → Just found
        _ → Nothing
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
              released = found {recHeld = Just held, recFailure = failureOf}
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
          recorded = case (answer, record) of
            (Right (), Just found) → Map.insert identity found {recFailure = failureOf} (pRecs st)
            _ → pRecs st
          settled = endWork identity st {pSession = session', pRecs = recorded}
      writeTVar (psVar service) $ case answer of
        Left (UnknownRequest _) → st {pSession = session'}
        _ → settled
      -- A required request's expected failure, settled on arrival, fails its instance at the
      -- owner's next safe boundary, read or not.
      case (answer, record) of
        (Right (), Just found) → latchRequired service found {recFailure = failureOf}
        _ → pure ()
      pure $ case answer of
        Right () → if refusedValue then ReplyRefusedValue else ReplySettled
        Left (UnknownRequest _) → ReplyUnknown
        Left (PayloadTooLarge _ _) → ReplyRefusedValue
        Left (ReplyRefused _) → ReplyLate
        Left _ → ReplyLate

-- | How many provider defects are kept for the owner to raise: it fails with the first, and the rest are
-- evidence; a provider that goes on answering wrongly cannot grow what the service keeps.
defectLimit ∷ Int
defectLimit = 16

-- | Fail the instance of a required request whose expected failure has just become eligible:
-- latch it on the instance, once, and wake the owner to apply it at its next safe boundary. An
-- instance that is ending, or already has a failure latched, takes none; a request that is not an
-- instance's, optional, or not an expected failure is nothing to latch. The latch is the
-- instance's, set here, and is never cleared by anything a script does: it is read by the owner
-- only. Answers whether it latched one.
latchRequired ∷ ProviderState → Rec → STM ()
latchRequired service record = case (recAdmission record, recFailure record, recRequester record) of
  (Just ask, Just failure, RequesterInstance number)
    | admitNecessity ask == RequiredRequest → do
        found ← cellOf service number
        forM_ found $ \(instances, cell) → do
          state ← readTVar (icState cell)
          unless (isStopped state || isTerminal (isPhase state) || isJust (isRequestFailure state)) $ do
            writeTVar (icState cell) state
              { isRequestFailure = Just (recEndpoint record, attributed ask failure)
              , isDispatchQueued = True
              }
            unless (isDispatchQueued state) $
              modifyTVar' (insInbox instances) (|> JobDispatch (icId cell))
            modifyTVar' (psVar service) (\st → st {pCounts = (pCounts st) {countLatched = countLatched (pCounts st) + 1}})
  _ → pure ()
  where
    attributed ask failure = "(" <> admitSource ask <> ") " <> expectedCode failure <> ": " <> expectedMessage failure

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
                    , pAdopting = unclaimed (Map.delete (recIdentity record)) (pAdopting st)
                    , pDiscards = pDiscards st <> adoptedOf record
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
            -- The completion became a settlement now: a required request's expected failure is
            -- eligible, and fails its instance at the owner's next safe boundary.
            latchRequired service record
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
  -- The subscriptions the requester owned are ended with it: the model's holder ended them, and
  -- everything else about each goes with it, through the one place that ends a subscription.
  let owned = [subIdentity sub | sub ← Map.elems (pSubs withEnded), RequesterInstance (subInstance sub) == requester]
      prelim =
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
  ended ← endSubs service EndByOwner owned prelim
  -- An instance that ended needs nothing let go of: its VM is released with it.
  writeTVar (psVar service) (retireEnded ended {pForget = foldr Map.delete (pForget ended) [number | RequesterInstance number ← [requester]], pAdopting = unclaimed (\held → foldr Map.delete held gone) (pAdopting ended)})
  -- What the requester had left uncollected is discarded now, on the owner's thread: the banks of
  -- the requests whose providers have already retired are free from here.
  releaseSettled service
  pure (EndReport (length mine) (length told))

-- | The task requesters whose tasks are gone: ended, or no longer known to the scheduler.
goneRequesters ∷ ProviderState → STM [Requester]
goneRequesters service = do
  st ← readTVar (psVar service)
  -- Every task that still has anything: a holder, a record (an epoch's cancellation outlives
  -- the holders it cleared) or work of its own.
  let requesters = Map.keys (pHolders st) <> map recRequester (Map.elems (pRecs st)) <> map workRequester (Map.elems (pWork st))
      tasks = nub [task | RequesterTask task ← requesters]
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
                , pAdopting = Map.filter adoptingClaimed (pAdopting cancelledState)
                , pCounts = (pCounts cancelledState) {countEpochCancelled = countEpochCancelled (pCounts cancelledState) + cancelled}
                }
      case advanceEpoch (pSession cancelledState) of
        (_, Left _) → Nothing <$ (writeTVar (psVar service) (committed (pSession cancelledState)) >> releaseSettled service)
        (session, Right change) → do
          -- The model invalidated every subscription with the epoch's records; the service's
          -- records of them, the events held for them and the references in the queues go with
          -- them, and the providers' interest is withdrawn. The accounting for their work is
          -- retained under the identities it was issued under, charged to the bound until the
          -- provider proves it over, so a late delivery finds nothing and churn reclaims nothing.
          let current = committed session
          ended ← endSubs service EndByEpoch (Map.keys (pSubs current)) current
          -- The owner is woken for each instance whose VM holds a callback that is no use now.
          -- Only an instance that did not have a cleanup waiting is woken for one: the owner takes
          -- everything that is named when it gets there, so the inbox holds one job per instance
          -- however often the epoch changes while the owner cannot drain it.
          let woken = Map.keys (Map.difference (pForget ended) (pForget current))
          case psInstances service of
            Nothing → pure ()
            Just instances → forM_ woken $ \number → modifyTVar' (insInbox instances) (|> JobForget number)
          writeTVar (psVar service) ended {pEvents = (pEvents ended) {evCleanupJobs = evCleanupJobs (pEvents ended) + length woken}}
          releaseSettled service
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
                  pure ((if completed then endWork identity st' else st') {pDiscards = pDiscards st' <> adoptedOf record}, kept <> [released {recEnded = Just settledCancel}], cancelled + 1, discarded)
            -- A result nobody took is discarded with the epoch: a resource built for it can no longer be reached,
            -- and is released like one built for a request cancelled.
            _ → pure (st {pWork = Map.adjust (\work → if workEnded work then work else work {workWantsCancel = True}) identity (pWork st), pDiscards = pDiscards st <> adoptedOf record}, kept, cancelled, discarded + 1)

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
      let prelim =
            withEnded
              { pSession = session
              , pRecs = Map.empty
              , pByNumber = Map.empty
              , pDue = Map.empty
              , pHolders = Map.empty
              , pClosed = True
              , pExit = Just exit
              , pAdopting = Map.filter adoptingClaimed (pAdopting withEnded)
              , pWork = Map.map (\work → if workEnded work then work else work {workWantsCancel = True}) (pWork withEnded)
              }
      ended ← endSubs service EndByOwner (Map.keys (pSubs prelim)) prelim
      writeTVar (psVar service) (retireEnded ended {pForget = Map.empty})
      releaseSettled service
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
  -- Work that is reaped here has been accounted at the owner's boundary: the banks of the requests
  -- that were already taken or discarded are visible to admission from now on.
  releaseSettled service

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
  -- A failed resource's slot that is gone: the credits kept charged with it are the owner's to give back.
  gone ← forM [key | held ← Map.elems (pHeld st), Just key ← [heldRetiring held]] $ \key →
    maybe (pure False) (\leases → not <$> slotPresent leases key) (psLeases service)
  pure (over || untold || or changed || or gone || any (not . adoptingClaimed) (Map.elems (pAdopting st)) || not (null (pDefects st)) || not (null (pCleanup st)) || not (null (pDiscards st)))

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
      , rdWorkPending = length [() | work ← Map.elems (pWork st), isNothing (workSubscription work), awaiting work]
      , rdWorkFailed = length [() | work ← Map.elems (pWork st), isNothing (workSubscription work), isJust (workFailure work)]
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
      , rdBusy = countBusy counts
      , rdHeld = Map.size (pHeld st)
      , rdHeldBy = Map.fromListWith (+) [(number, 1) | held ← Map.elems (pHeld st), RequesterInstance number ← [heldRequester held]]
      , rdAdopting = Map.size (pAdopting st)
      , rdDefects = countDefects counts
      , rdLatched = countLatched counts
      , rdAdopted = countAdopted counts
      }
