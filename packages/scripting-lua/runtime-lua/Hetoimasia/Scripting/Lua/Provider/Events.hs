-- | The transactions over one owner's subscriptions (LUA-26): admitting one, ending it, the
-- deliveries a provider makes to it, the events held for a tick not yet reached and their
-- admission at that tick's boundary, and the reading a callback's first segment makes.
--
-- Each is one STM transaction that never blocks and never retries. What needs IO (calling a
-- provider) is "Hetoimasia.Scripting.Lua.Provider.Serve"'s, which claims the work in a
-- transaction here first. This module is below "Hetoimasia.Scripting.Lua.Provider.State", whose
-- ending of a requester, an epoch change and the owner's exit end the subscriptions through the
-- one function here, 'endSubs'.
--
-- = A subscription is a record of the protocol model
--
-- The model's session holds the subscription ('registerSubscriptionFor', owned by the holder the
-- service issued for the instance, so it survives each invocation's end), applies its overload
-- policy ('deliverEvent'), keeps the delivery that has not started and hands it to the callback
-- when its first segment is about to run ('takeEventIn'). The instance's queue
-- ("Hetoimasia.Scripting.Lua.Instance.Types") holds a /reference/ to it, which gives the
-- delivery its place among the instance's other invocations, its sequence and the logical tick
-- it was admitted at. The two agree: a subscription has an unstarted delivery in the model
-- exactly as many times as the queue, or the invocation about to begin, refers to it (once for
-- replaceable state), and every path that changes one changes the other in the same transaction.
--
-- = The invariants every path here keeps
--
-- * /A subscription ends once/, through 'endSubs': its record in the model, its record here,
--   the events held for it and the references to it in its instance's queue go together, and the
--   provider's interest is marked withdrawn for the owner to tell, once. Unsubscribe, the end of
--   its instance, an epoch change and the owner's exit all end it there.
-- * /The provider's work is accounted separately/, in the one accounting requests use
--   ('Work', under the identity 'workIdOf' makes of the subscription's), charged to the subscription's place until the provider
--   proves its retirement over.
-- * /A delivery is admitted at one place/ ('admitDelivery'), whether it arrives from a producer's
--   thread on an owner on elapsed time or is taken out of the events held for a tick at that
--   tick's boundary: the checks, the overload policy, the counters and the queue's bound are
--   decided there and nowhere else.
-- * /A logical owner never admits by arrival/. Its events are held for the tick the application
--   assigned, in a bounded store, and admitted in the order of their places at that tick's
--   boundary, before any task the tick woke runs, so an overflow or a coalesce is decided by the
--   logical sequence and not by how fast the owner was serving.
module Hetoimasia.Scripting.Lua.Provider.Events
  ( -- * Who may subscribe
    requesterClosed
  , awaiting
  , cellOf

    -- * Subscribing
  , AdmittedSub (..)
  , admitSubscription
  , commitSubscribed
  , withdrawSubscription
  , unsubscribeOf

    -- * Ending
  , SubEnd (..)
  , endSubs
  , chargedSubs
  , takeForgotten

    -- * Delivering
  , CheckedEvent (..)
  , checkEvent
  , eventRecord
  , deliverChecked
  , EventsServed (..)
  , serveEvents
  , nextStagedAfter

    -- * Beginning a callback
  , DeliveryStart (..)
  , startDelivery

    -- * Failure
  , failDelivery

    -- * Reading
  , subscriptionDiagnosticsSTM
  ) where

import Control.Concurrent.STM (STM, modifyTVar', readTVar, writeTVar)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeAsyncException, fromException, throwIO)
import Control.Monad (foldM, forM_, unless)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
import Data.Sequence ((|>))
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Instance.Types
  ( ICell (icGrants, icId, icState)
  , IState (..)
  , InstancePhase (Stopping)
  , Instances (insBounds, insCells, insInbox)
  , InstanceBounds (boundInvocationQueue)
  , Job (JobDispatch)
  , QueuedEvent (..)
  , isTerminal
  , pendingEvents
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( EndpointId (EndpointId)
  , SubscriptionId
  , SubscriptionName (SubscriptionName)
  , SessionKey (keyEpoch)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits (LimitName (Subscriptions))
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session
  ( Counters (..)
  , Session (sessionCounters, sessionKey, sessionSubscriptions)
  , SessionRejection (CapReached, DeliveryRefused, PayloadTooLarge)
  , deliverEvent
  , issueHolder
  , registerSubscriptionFor
  , takeEventIn
  , unsubscribeIn
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription (subscriptionBacklog)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Value (Payload (Payload))
import Hetoimasia.Scripting.Lua.Internal.Value
  ( Context (..)
  , Value (VInteger, VNil, VRecord, VText)
  , ValueLimits
  , VmIdentity (VmIdentity)
  , conformValue
  , valuesFootprint
  )
import Hetoimasia.Scripting.Lua.Provider.Types
import Hetoimasia.Scripting.Lua.Runtime.Shared (compact)
import qualified Hetoimasia.Scripting.Lua.Runtime.Types as Call
import Hetoimasia.Foundation.Messaging.Payload (prepare, preparedValue)
import Hetoimasia.Scripting.Lua.Retention (Obligation (Obligation), Retained (..), RetirementState (ProviderPending), guarded, noRetained, retain)

-- Who may subscribe -----------------------------------------------------------------

-- | Whether a requester is no longer taking requests or subscriptions: its instance is ending or
-- has ended, or its task has ended or is being closed.
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

-- | Whether a piece of provider work is still awaited: not over, or with disposals still to run,
-- and not failed (a failed retirement is the evidence, and nothing waits for it).
awaiting ∷ Work → Bool
awaiting work = isNothing (workFailure work) && (not (workEnded work) || not (null (retainedDeferred (workRetained work))))

-- Subscribing -------------------------------------------------------------------------

-- | A subscription that was admitted.
data AdmittedSub = AdmittedSub
  { admittedSubNumber ∷ !Word64
  , admittedSubIdentity ∷ !SubscriptionId
  }

-- | The places the owner holds for subscriptions: every live subscription, and every ended one
-- whose provider has not proved its retirement, each once. This is what the bound is on, so
-- subscribing and unsubscribing over and over cannot reclaim a place the provider still holds.
chargedSubs ∷ PState → Int
chargedSubs st =
  Set.size
    ( Set.fromList (Map.keys (pSubs st))
        `Set.union` Set.fromList [identity | work ← Map.elems (pWork st), Just identity ← [workSubscription work], awaiting work]
    )

countRefusedSubscribe ∷ PState → PState
countRefusedSubscribe st = st {pEvents = (pEvents st) {evRefusedSubscribe = evRefusedSubscribe (pEvents st) + 1}}

-- | Admit a subscription of an instance to an endpoint: every check, the model's registration
-- and the account of the provider's work, in one transaction, before the provider is asked
-- anything.
--
-- The refusals are decided in this order, and the order is the contract: the owner or the
-- instance is not taking subscriptions, the endpoint is not one the owner offers and the
-- instance was granted, every place is held. A refusal changes nothing but a counter, and no
-- provider has been asked anything.
admitSubscription ∷ ProviderState → Word64 → Text → STM (Either SubscribeRefusal (AdmittedSub, EventEndpoint))
admitSubscription service instanceNumber name = do
  st ← readTVar (psVar service)
  open ← ticksOpen (psTicks service)
  closed ← requesterClosed service requester
  granted ← grantsOf service instanceNumber
  let number = pNextSub st
      bound = psSubscriptionBound service
      refuse why = Left why <$ writeTVar (psVar service) (countRefusedSubscribe st)
  if pClosed st || not open || closed
    then refuse SubscriptionsClosed
    else case (Map.lookup name (psEvents service), granted) of
      (Just endpoint, Just names)
        | Set.member name names →
            if chargedSubs st >= bound
              then refuse (SubscriptionsFull bound)
              else do
                let (holder, withHolder) = case Map.lookup requester (pHolders st) of
                      Just held → (held, pSession st)
                      Nothing → issueHolder (pSession st)
                case registerSubscriptionFor holder (SubscriptionName number) (EndpointId name) (eventPolicy endpoint) withHolder of
                  (_, Left (CapReached Subscriptions full)) → refuse (SubscriptionsFull full)
                  (_, Left _) → refuse SubscriptionsClosed
                  (session, Right identity) → do
                    let record =
                          Sub
                            { subNumber = number
                            , subIdentity = identity
                            , subInstance = instanceNumber
                            , subEndpoint = name
                            , subPolicy = eventPolicy endpoint
                            , subSchema = eventPayload endpoint
                            , subAdmitted = 0
                            , subCoalesced = 0
                            , subRefused = 0
                            , subDelivered = 0
                            }
                        work =
                          Work
                            { workNumber = number
                            , workRequester = requester
                            , workLabel = name <> " subscription " <> Text.pack (show number)
                            , workProvider = Nothing
                            , workWantsCancel = False
                            , workCancelClaimed = False
                            , workEnded = False
                            , workFailure = Nothing
                            , workRetained = noRetained
                            , workSubscription = Just identity
                            }
                    writeTVar (psVar service) st
                      { pSession = session
                      , pSubs = Map.insert identity record (pSubs st)
                      , pSubNumbers = Map.insert number identity (pSubNumbers st)
                      , pWork = Map.insert (workIdOf identity) work (pWork st)
                      , pHolders = Map.insert requester holder (pHolders st)
                      , pNextSub = number + 1
                      , pEvents = (pEvents st) {evSubscribed = evSubscribed (pEvents st) + 1}
                      }
                    pure (Right (AdmittedSub number identity, endpoint))
      _ → refuse (EndpointNotGranted name)
  where
    requester = RequesterInstance instanceNumber

-- | The event endpoints an instance was granted, if it is a live instance of the owner.
grantsOf ∷ ProviderState → Word64 → STM (Maybe (Set.Set Text))
grantsOf service instanceNumber = case psInstances service of
  Nothing → pure Nothing
  Just instances → do
    cells ← readTVar (insCells instances)
    pure (icGrants <$> Map.lookup instanceNumber cells)

-- | Record that the provider accepted a subscription: its work, and the reading of its
-- retirement, which says nothing until interest in it was withdrawn. The accounting for the
-- work was made with the admission, so it is found; an unsubscribe or an epoch change that came
-- first is already in it.
commitSubscribed ∷ ProviderState → SubscriptionId → ProviderWork → STM ()
commitSubscribed service identity provided = do
  st ← readTVar (psVar service)
  writeTVar (psVar service) st {pWork = Map.adjust record (workIdOf identity) (pWork st)}
  where
    record work =
      work
        { workProvider = Just provided
        , workRetained = (if workEnded work then id else retain (Obligation (workLabel work) reading)) (workRetained work)
        }
    reading = do
      st ← readTVar (psVar service)
      case Map.lookup (workIdOf identity) (pWork st) of
        Just work | workWantsCancel work → workRetirement provided
        _ → pure ProviderPending

-- | Take back a subscription whose handoff to the provider failed: it never reached it, so
-- there is no work to retire and the place is free again. What had been delivered to it in the
-- meantime is discarded and counted by the model, as an unsubscribe discards it.
withdrawSubscription ∷ ProviderState → SubscriptionId → STM ()
withdrawSubscription service identity = do
  st ← readTVar (psVar service)
  ended ← endSubs service EndByUnsubscribe [identity] st
  writeTVar (psVar service) (countRefusedSubscribe ended {pWork = Map.delete (workIdOf identity) (pWork ended)})

-- | End a subscription of an instance at the script's asking. Answers whether it ended a live
-- one: a number that names none of the instance's (ended, or never issued) is not an error, and
-- is answered 'False'. Interest in the provider's work is withdrawn for the owner to tell, once.
unsubscribeOf ∷ ProviderState → Word64 → Word64 → STM Bool
unsubscribeOf service instanceNumber number = do
  st ← readTVar (psVar service)
  case Map.lookup number (pSubNumbers st) >>= \identity → Map.lookup identity (pSubs st) of
    Just sub | subInstance sub == instanceNumber → do
      ended ← endSubs service EndByUnsubscribe [subIdentity sub] st
      True <$ writeTVar (psVar service) ended {pEvents = (pEvents ended) {evUnsubscribed = evUnsubscribed (pEvents ended) + 1}}
    _ → pure False

-- Ending ---------------------------------------------------------------------------------

-- | Who ended a subscription, which decides whether the model has already forgotten it.
data SubEnd
  = -- | The script unsubscribed (or a handoff failed): the model is told, and counts the
    -- backlog it discards. The script's own references are its to drop.
    EndByUnsubscribe
  | -- | The model already ended it, with its holder: the instance's end, or the owner's stop.
    -- The VM lets go of everything when the instance is released.
    EndByOwner
  | -- | The model already ended it in an epoch change. The instance goes on, and the callback it
    -- subscribed is of no use to anyone: its number is kept for the owner to have the driver let
    -- go of it.
    EndByEpoch

-- | End subscriptions, each once, wherever they are held: the model's record (counting what it
-- discards), the service's record, the events held for them, and the references to them in
-- their instances' queues, which are freed in the same transaction; and the provider's interest
-- is marked withdrawn, for the owner to tell it once. An identity that is not live changes
-- nothing, so ending a subscription twice, by two paths, is ending it once.
--
-- The invocation about to begin for a subscription is not taken back here: it has an
-- invocation in the scheduler that only the owner's thread can release, and it finds the
-- subscription gone when its first segment is about to run, and completes without entering Lua.
endSubs ∷ ProviderState → SubEnd → [SubscriptionId] → PState → STM PState
endSubs service how identities st = do
  let live = [sub | identity ← identities, Just sub ← [Map.lookup identity (pSubs st)]]
      gone = Set.fromList (map subIdentity live)
      session = case how of
        EndByUnsubscribe → foldl' (\current sub → fst (unsubscribeIn (subIdentity sub) current)) (pSession st) live
        EndByOwner → pSession st
        EndByEpoch → pSession st
      forgotten = case how of
        EndByEpoch → Map.unionWith (<>) (pForget st) (Map.fromListWith (flip (<>)) [(subInstance sub, [subNumber sub]) | sub ← live])
        _ → pForget st
      (discarded, kept) = Map.partition ((`Set.member` gone) . stagedSubscription) (pStaged st)
  forM_ (Set.toList (Set.fromList (map subInstance live))) (dropReferences service gone)
  pure
    st
      { pSession = session
      , pSubs = foldr Map.delete (pSubs st) (Set.toList gone)
      , pSubNumbers = Map.filter (`Set.notMember` gone) (pSubNumbers st)
      , pStaged = kept
      , pForget = forgotten
      , pWork = foldr (Map.adjust withdrawn . workIdOf) (pWork st) (Set.toList gone)
      , pEvents = (pEvents st) {evDiscarded = evDiscarded (pEvents st) + Map.size discarded}
      }
  where
    withdrawn work = if workEnded work then work else work {workWantsCancel = True}

-- | Free the places the references to subscriptions that ended held in an instance's queue.
dropReferences ∷ ProviderState → Set.Set SubscriptionId → Word64 → STM ()
dropReferences service gone instanceNumber = forM_ (psInstances service) $ \instances → do
  cells ← readTVar (insCells instances)
  forM_ (Map.lookup instanceNumber cells) $ \cell →
    modifyTVar' (icState cell) $ \state →
      state {isQueue = Seq.filter (not . refersTo) (isQueue state)}
  where
    refersTo event = maybe False (`Set.member` gone) (queuedSubscription event)

-- Delivering -------------------------------------------------------------------------------

-- | A delivery, checked before anything is retained.
data CheckedEvent
  = -- | Within the limits and the endpoint's schema.
    EventChecked !(Payload Value)
  | -- | Over the owner's limits, not what the endpoint declares, or not evaluable.
    EventUnfit

-- | The record a callback is handed for a delivery: the endpoint, the sequence admission gave
-- it, the logical tick it was admitted at, the subscription's number and the value.
eventRecord ∷ Text → Word64 → Word64 → Word64 → Value → Value
eventRecord endpoint sequenceNumber tick number payload =
  VRecord
    [ ("source", VText endpoint)
    , ("sequence", VInteger (fromIntegral sequenceNumber))
    , ("tick", VInteger (fromIntegral tick))
    , ("subscription", VInteger (fromIntegral number))
    , ("payload", payload)
    ]

-- | Check a delivery against the owner's value limits and the endpoint's schema, copy what is kept
-- to buffers of its own and evaluate it fully, all inside the one guard, so a value that throws when
-- it is first looked at is an unfit delivery and not an exception loose on the producer's thread.
--
-- What is measured is what the callback's entry point is handed: the instance's number and the record,
-- which the host checks together, so a delivery that is retained is one that can be delivered. What is
-- kept is a copy: a string that is a slice of a larger one would otherwise keep all of it alive for as
-- long as the delivery waits, which the limits do not count.
checkEvent ∷ ValueLimits → EventEndpoint → Value → IO CheckedEvent
checkEvent limits endpoint value = do
  judged ← guarded judge
  case judged of
    Right verdict → pure verdict
    Left (ExceptionWithContext _ raised)
      | Just (async ∷ SomeAsyncException) ← fromException raised → throwIO async
      | otherwise → pure EventUnfit
  where
    judge = case valuesFootprint limits [VInteger 0, eventRecord (eventName endpoint) 0 0 0 value] of
      Left _ → pure EventUnfit
      Right bytes → case conformValue plainContext (eventPayload endpoint) value of
        Left _ → pure EventUnfit
        Right () → do
          prepared ← prepare (Call.WithinBounds [compact value])
          pure $ case preparedValue prepared of
            Call.WithinBounds [kept] → EventChecked (Payload bytes kept)
            _ → EventUnfit

-- | A payload carries no capability, so nothing of a VM is consulted.
plainContext ∷ Context
plainContext = Context (VmIdentity 0) (const Nothing) (const Nothing)

-- | What a delivery came to once it was checked: on an owner on elapsed time it is admitted on
-- arrival, and on an owner on logical time it is held for the tick the application assigned.
-- One transaction, never waiting, and the delivery is refused, counted, for each reason in the
-- order of the checks: the subscription or the owner is not taking events, the value is unfit,
-- the kind of time does not match the place (or lack of one), and for a held event its tick has
-- begun, its place is taken and the store is full.
deliverChecked ∷ ProviderState → SubscriptionId → Maybe DueSlot → CheckedEvent → STM EventAnswer
deliverChecked service identity slot checked = do
  st ← readTVar (psVar service)
  open ← ticksOpen (psTicks service)
  now ← ticksNow (psTicks service)
  let counted update answer = answer <$ writeTVar (psVar service) st {pEvents = update (pEvents st)}
      logical = case psTiming service of
        SettleAtAssignedTick _ → True
        SettleOnArrival → False
  -- The instance is asked once, before anything else is decided, whether it is still taking events:
  -- an instance that is stopping, or ended, takes none, whether the delivery would be admitted now or
  -- held for a tick. Both paths are this one.
  closed ← case Map.lookup identity (pSubs st) of
    Just sub → requesterClosed service (RequesterInstance (subInstance sub))
    Nothing → pure True
  case Map.lookup identity (pSubs st) of
    Just sub | not (pClosed st) && open && not closed → case checked of
      EventUnfit → counted (\c → c {evRefusedValue = evRefusedValue c + 1}) EventRefusedValue
      EventChecked payload → case (logical, slot) of
        (False, Nothing) → do
          (st', answer) ← admitDelivery service now identity sub payload st
          answer <$ writeTVar (psVar service) st'
        (False, Just _) → counted (\c → c {evNotLogical = evNotLogical c + 1}) EventNotLogical
        (True, Nothing) → counted (\c → c {evUnassigned = evUnassigned c + 1}) EventUnassigned
        (True, Just due)
          | dueTick due <= now → counted (\c → c {evLate = evLate c + 1}) EventLate
          | Map.member due (pStaged st) → counted (\c → c {evDuplicate = evDuplicate c + 1}) EventDuplicate
          | Map.size (pStaged st) >= psStagingBound service → counted (\c → c {evStagingFull = evStagingFull c + 1}) EventStagingFull
          | otherwise -> do
              -- Held and the owner asked to be held at its tick in one step, so no grant can
              -- reach the tick between the two.
              ticksWatch (psTicks service) (dueTick due)
              writeTVar (psVar service) st
                { pStaged = Map.insert due (Staged identity payload) (pStaged st)
                , pEvents = (pEvents st) {evStaged = evStaged (pEvents st) + 1}
                }
              pure EventStaged
    _ -> counted (\c → c {evRefusedEnded = evRefusedEnded c + 1}) EventEnded

-- | Admit a delivery of a live subscription: the one place the queue's bound, the overload
-- policy and the counters are decided, whether the delivery arrived or was held for a tick.
-- The tick is what the delivery is stamped with, kept unchanged until its callback runs.
--
-- * Ordered events take a place in the instance's queue, and are refused, counted and never
--   evicted, when there is none.
-- * Replaceable state with an unstarted delivery replaces its value and its tick in place: no
--   place is taken and its place in the queue is kept, and the value it replaced is counted as
--   coalesced and never delivered. With none, it takes a place as an ordered event does.
admitDelivery ∷ ProviderState → Word64 → SubscriptionId → Sub → Payload Value → PState → STM (PState, EventAnswer)
admitDelivery service stamp identity sub payload st = do
  found ← cellOf service (subInstance sub)
  case found of
    Nothing → ended
    Just (instances, cell) → do
      state ← readTVar (icState cell)
      if isStopped state || isTerminal (isPhase state) || isPhase state == Stopping
        then ended
        else do
          let occupied = Seq.length (isQueue state) + pendingEvents state
              full = occupied >= boundInvocationQueue (insBounds instances)
              unstarted = maybe False ((> 0) . subscriptionBacklog) (Map.lookup identity (sessionSubscriptions (pSession st)))
              replacing = subPolicy sub == ReplaceableState && unstarted
              -- The one place a refusal for want of a place is made and counted.
              refuseFull session = do
                writeTVar (icState cell) state {isQueueFull = isQueueFull state + 1}
                pure
                  ( st
                      { pSession = session
                      , pSubs = Map.adjust (\held → held {subRefused = subRefused held + 1}) identity (pSubs st)
                      , pEvents = (pEvents st) {evRefusedFull = evRefusedFull (pEvents st) + 1}
                      }
                  , EventQueueFull
                  )
              refusedBy session = \case
                DeliveryRefused _ → refuseFull session
                PayloadTooLarge _ _ →
                  pure (st {pSession = session, pEvents = (pEvents st) {evRefusedValue = evRefusedValue (pEvents st) + 1}}, EventRefusedValue)
                _ → pure (st {pSession = session, pEvents = (pEvents st) {evRefusedEnded = evRefusedEnded (pEvents st) + 1}}, EventEnded)
              isRef event = queuedSubscription event == Just identity
              -- A new place in the queue, with the next sequence.
              append = do
                let sequenceNumber = isNextSequence state
                    reference = QueuedEvent (subEndpoint sub) sequenceNumber stamp VNil (Just identity)
                writeTVar (icState cell) state
                  { isQueue = isQueue state |> reference
                  , isNextSequence = sequenceNumber + 1
                  , isDelivered = isDelivered state + 1
                  , isDispatchQueued = True
                  }
                unless (isDispatchQueued state) $
                  modifyTVar' (insInbox instances) (|> JobDispatch (icId cell))
          if replacing
            then case deliverEvent identity payload (pSession st) of
              (session, Right _) → do
                -- The reference keeps its place and its sequence; its tick is the new value's.
                case Seq.findIndexL isRef (isQueue state) of
                  Just index → writeTVar (icState cell) state {isQueue = Seq.adjust' (\event → event {queuedTick = stamp}) index (isQueue state)}
                  Nothing → case isPending state of
                    Just pending | isRef pending → writeTVar (icState cell) state {isPending = Just pending {queuedTick = stamp}}
                    -- The two agree, so this is not reached; were it, the delivery is not lost.
                    _ → append
                pure
                  ( st
                      { pSession = session
                      , pSubs = Map.adjust (\held → held {subCoalesced = subCoalesced held + 1}) identity (pSubs st)
                      }
                  , EventCoalesced
                  )
              (session, Left why) → refusedBy session why
            else
              if full
                then refuseFull (pSession st)
                else case deliverEvent identity payload (pSession st) of
                  (session, Right _) → do
                    append
                    pure
                      ( st
                          { pSession = session
                          , pSubs = Map.adjust (\held → held {subAdmitted = subAdmitted held + 1}) identity (pSubs st)
                          }
                      , EventAdmitted
                      )
                  (session, Left why) → refusedBy session why
  where
    ended = pure (st {pEvents = (pEvents st) {evRefusedEnded = evRefusedEnded (pEvents st) + 1}}, EventEnded)

-- | The instance a subscription belongs to, if it is the owner's and has a cell.
cellOf ∷ ProviderState → Word64 → STM (Maybe (Instances, ICell))
cellOf service instanceNumber = case psInstances service of
  Nothing → pure Nothing
  Just instances → do
    cells ← readTVar (insCells instances)
    pure ((,) instances <$> Map.lookup instanceNumber cells)

-- | The events held for ticks the owner has reached, taken out and admitted in the order of
-- their places.
newtype EventsServed = EventsServed
  { servedInstances ∷ [Word64]
    -- ^ The instances that were handed a delivery or a failure, once each, in the order of
    -- their numbers: the owner looks at their queues.
  }

-- | Serve a tick the owner has reached: the events held for it, or for an earlier tick, are
-- admitted in the order of their places, each stamped with the tick it was assigned. This is
-- where an ordered event is refused for want of a place, or replaceable state coalesces, so the
-- decision follows the logical sequence and nothing about how fast the owner served. An ordered
-- event that cannot be admitted here is an authoritative event lost after its provider was told
-- it was accepted, so it is surfaced as the delivery failure it is.
serveEvents ∷ ProviderState → Word64 → STM EventsServed
serveEvents service tick = do
  st ← readTVar (psVar service)
  let (due, later) = Map.partitionWithKey (\slot _ → dueTick slot <= tick) (pStaged st)
      step (current, touched, lost) (slot, held) = case Map.lookup (stagedSubscription held) (pSubs current) of
        Nothing → pure (current {pEvents = (pEvents current) {evRefusedEnded = evRefusedEnded (pEvents current) + 1}}, touched, lost)
        Just sub → do
          (next, answer) ← admitDelivery service (dueTick slot) (stagedSubscription held) sub (stagedPayload held) current
          pure $ case answer of
            EventAdmitted → (next, subInstance sub : touched, lost)
            EventCoalesced → (next, subInstance sub : touched, lost)
            EventQueueFull
              | subPolicy sub == OrderedEvents → (next, subInstance sub : touched, (stagedSubscription held, "an ordered event held for a tick could not be admitted at its boundary: the queue was full") : lost)
            _ → (next, touched, lost)
  (served, touched, lost) ← foldM step (st {pStaged = later}, [], []) (Map.toAscList due)
  writeTVar (psVar service) served
  forM_ (reverse lost) (uncurry (failDelivery service))
  pure . EventsServed . Set.toAscList . Set.fromList $
    touched <> [subInstance sub | (identity, _) ← lost, Just sub ← [Map.lookup identity (pSubs served)]]

-- | The earliest tick after this one that an event still held is due at, for the owner to watch.
nextStagedAfter ∷ ProviderState → Word64 → STM (Maybe Word64)
nextStagedAfter service tick = do
  st ← readTVar (psVar service)
  pure (fst <$> Set.minView (Set.filter (> tick) (Set.map dueTick (Map.keysSet (pStaged st)))))

-- Beginning a callback ------------------------------------------------------------------------

-- | What the first segment of a subscription's callback is handed.
data DeliveryStart = DeliveryStart
  { startedNumber ∷ !Word64
    -- ^ The subscription's number, which the callback is looked up by.
  , startedPayload ∷ !Value
  }

-- | A callback's first segment is about to run: take the delivery it is for, once. From here its
-- payload is the callback's and is immutable; a delivery that arrives after it finds the slot
-- empty and takes a place of its own. 'Nothing' when the subscription has ended since the
-- delivery was admitted (unsubscribed, invalidated by an epoch change, or ended with its
-- instance), or has nothing to give: the callback is not run. What the model discarded when the
-- subscription ended is counted by the model, once.
startDelivery ∷ ProviderState → SubscriptionId → STM (Maybe DeliveryStart)
startDelivery service identity = do
  st ← readTVar (psVar service)
  case Map.lookup identity (pSubs st) of
    Nothing → pure Nothing
    Just sub → case takeEventIn identity (pSession st) of
      (_, Left _) → pure Nothing
      (session, Right (Payload _ value)) → do
        writeTVar (psVar service) st
          { pSession = session
          , pSubs = Map.adjust (\held → held {subDelivered = subDelivered held + 1}) identity (pSubs st)
          }
        pure (Just (DeliveryStart (subNumber sub) value))

-- | Take the number of one subscription an epoch change ended whose callback an instance's VM still
-- holds, once. One at a time: the answer is a scalar that fits any limits, however many ended.
takeForgotten ∷ ProviderState → Word64 → STM (Maybe Word64)
takeForgotten service instanceNumber = do
  st ← readTVar (psVar service)
  case Map.lookup instanceNumber (pForget st) of
    Just (number : rest) → Just number <$ writeTVar (psVar service) st {pForget = if null rest then Map.delete instanceNumber (pForget st) else Map.insert instanceNumber rest (pForget st)}
    _ → pure Nothing

-- Failure ---------------------------------------------------------------------------------------

-- | A delivery failure is surfaced for a subscription: its provider could not preserve an
-- authoritative event, or an event the owner accepted for a tick could not be admitted at it.
-- The instance is to fail with it, once, and the owner is woken to do it. A subscription that
-- has ended, or an instance that is ending, has nothing to fail, and the failure is only counted.
failDelivery ∷ ProviderState → SubscriptionId → Text → STM ()
failDelivery service identity reason = do
  st ← readTVar (psVar service)
  found ← maybe (pure Nothing) (\sub → cellOf service (subInstance sub)) (Map.lookup identity (pSubs st))
  case (Map.lookup identity (pSubs st), found) of
    (Just sub, Just (instances, cell)) → do
      state ← readTVar (icState cell)
      -- The first failure of an instance is the one it fails with and the one that is counted: a
      -- later one, or one for an instance that is already ending, adds nothing.
      if isStopped state || isTerminal (isPhase state) || isJust (isDeliveryFailure state)
        then pure ()
        else do
          writeTVar (icState cell) state
            { isDeliveryFailure = Just (subEndpoint sub, reason)
            , isDispatchQueued = True
            }
          unless (isDispatchQueued state) $
            modifyTVar' (insInbox instances) (|> JobDispatch (icId cell))
          writeTVar (psVar service) st {pEvents = (pEvents st) {evFailures = evFailures (pEvents st) + 1}}
    _ → writeTVar (psVar service) st {pEvents = (pEvents st) {evRefusedEnded = evRefusedEnded (pEvents st) + 1}}

-- Reading ----------------------------------------------------------------------------------------

-- | A reading of the subscription side of the service, in one transaction.
subscriptionDiagnosticsSTM ∷ ProviderState → STM SubscriptionDiagnostics
subscriptionDiagnosticsSTM service = do
  st ← readTVar (psVar service)
  let counts = pEvents st
      counters = sessionCounters (pSession st)
      works = [work | work ← Map.elems (pWork st), isJust (workSubscription work)]
      reading sub =
        SubscriptionReading
          { readingNumber = subNumber sub
          , readingInstance = subInstance sub
          , readingEndpoint = subEndpoint sub
          , readingAdmitted = subAdmitted sub
          , readingCoalesced = subCoalesced sub
          , readingRefused = subRefused sub
          , readingDelivered = subDelivered sub
          , readingBacklog = maybe 0 subscriptionBacklog (Map.lookup (subIdentity sub) (sessionSubscriptions (pSession st)))
          }
  pure
    SubscriptionDiagnostics
      { sdEpoch = keyEpoch (sessionKey (pSession st))
      , sdLive = Map.size (pSubs st)
      , sdCharged = chargedSubs st
      , sdRetiring = length (filter awaiting works)
      , sdRetirementFailed = length [() | work ← works, isJust (workFailure work)]
      , sdStaged = Map.size (pStaged st)
      , sdSubscribed = evSubscribed counts
      , sdRefusedSubscribe = evRefusedSubscribe counts
      , sdUnsubscribed = evUnsubscribed counts
      , sdStagedTotal = evStaged counts
      , sdStagingFull = evStagingFull counts
      , sdLate = evLate counts
      , sdDuplicate = evDuplicate counts
      , sdUnassigned = evUnassigned counts
      , sdNotLogical = evNotLogical counts
      , sdRefusedEnded = evRefusedEnded counts
      , sdRefusedValue = evRefusedValue counts
      , sdRefusedFull = evRefusedFull counts
      , sdDiscarded = evDiscarded counts
      , sdFailures = evFailures counts
      , sdCleanupJobs = evCleanupJobs counts
      , sdCoalesced = countCoalescedEvents counters
      , sdInvalidated = countInvalidatedSubscriptions counters
      , sdDiscardedEvents = countDiscardedEvents counters
      , sdSubscriptions = map reading (Map.elems (pSubs st))
      }
