-- | The runner's instance events: the one @instances@ endpoint every instance is granted, who is
-- subscribed to it, what an event is, how a delivery's answer is classified and what is counted.
--
-- The endpoint is a LUA-26 provider endpoint ("Hetoimasia.Scripting.Lua.Provider"), used unchanged. A
-- script subscribes with @api.subscribe("instances", callback)@ and is handed LUA-26's callback record,
-- @{source, sequence, tick, subscription, payload}@, whose @payload@ is the event:
--
-- * @event@: @"started"@ or @"ended"@;
-- * @tid@: the record the lifecycle namespace uses for a TID, @{runtime, owner, id}@, so a watcher can
--   hand it to @pause@, @resume@, @stop@ and @inspect@;
-- * @name@: present only when the instance has a name;
-- * @outcome@: present only on an end, @"completed"@, @"stopped"@ or @"failed"@.
--
-- This module knows nothing of when an event is produced: that is the run's, which produces events only at
-- moments the owner is not running anything, so that which events are produced, in what order and to whom
-- never depends on when the runner's own thread happens to resume. What it owns is the registry of
-- subscriptions (kept by the owner's thread, as the engine hands each subscription to the provider and
-- withdraws interest in it), the places of deliveries on a tick VM, and the tally.
module Hetoimasia.Scripting.Lua.Runner.Events
  ( -- * The endpoint
    Registry
  , newRegistry
  , instancesEndpoint
  , unreachableEndpoint
  , UnreachableRequest (..)
  , subscribers

    -- * Events
  , InstanceEvent (..)
  , eventValue
  , eventSchema

    -- * Producing them
  , produceEvents
  , Place (..)

    -- * What an answer means
  , AnswerClass (..)
  , Refusal (..)
  , classifyAnswer
  , EventDefect (..)
  , tallyOf
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (Exception, throwIO)
import Control.Monad (foldM)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Instance.Types (InstanceId)
import Hetoimasia.Scripting.Lua.Lifecycle (instanceIdValue)
import Hetoimasia.Scripting.Lua.Provider
  ( DueSlot (DueSlot)
  , EventAnswer (..)
  , EventEndpoint (EventEndpoint, eventName, eventPayload, eventPolicy, eventSubscribe)
  , EventFeed (feedDeliver)
  , EventSubscription (subscriptionFeed, subscriptionInfo)
  , OverloadPolicy (OrderedEvents)
  , ProviderWork (ProviderWork, workCancel, workRetirement)
  , RequestEndpoint (RequestEndpoint, endpointName, endpointResult, endpointSubmit)
  , RetirementState (ProviderComplete)
  , SubscriptionInfo (subscriptionNumber)
  )
import Hetoimasia.Scripting.Lua.Runner.Types
import Hetoimasia.Scripting.Lua.Value (Schema (SInteger, SNil, SOptional, SRecord, SText), Value (VRecord, VText))

-- The registry -----------------------------------------------------------------------------------

-- | One subscription of the @instances@ endpoint, as the engine handed it over.
newtype Subscriber = Subscriber {subscriberFeed ∷ EventFeed}

-- | Who is subscribed, by the subscription's number, and the places the next deliveries take.
--
-- Written by the owner's thread alone (the engine hands a subscription over, and withdraws interest in
-- it, from there); read by the runner's thread only at a moment the owner is not running anything.
data Registry = Registry
  { registrySubscribers ∷ !(TVar (Map Word64 Subscriber))
  , registryNext ∷ !(TVar Word64)
    -- ^ The next place's sequence: unique across the run and increasing in production order and then
    -- recipient order. A place is unique across the owner, so a place is never used twice.
  , registryTally ∷ !(TVar EventTally)
  }

newRegistry ∷ IO Registry
newRegistry = Registry <$> newTVarIO Map.empty <*> newTVarIO 1 <*> newTVarIO noTally

-- | The subscriptions that exist now, ascending by number.
subscribers ∷ Registry → STM [Word64]
subscribers = fmap Map.keys . readTVar . registrySubscribers

-- | What has been counted so far.
tallyOf ∷ Registry → IO EventTally
tallyOf = readTVarIO . registryTally

-- | The endpoint: a subscription is entered in the registry as the engine hands it over, and leaves it,
-- retired at once, as soon as the engine withdraws interest in it, however that happens (an unsubscribe,
-- the instance's end, a stop): nothing is delivered to it after, and nothing waits on the runner.
instancesEndpoint ∷ Registry → EventEndpoint
instancesEndpoint registry =
  EventEndpoint
    { eventName = runnerEventsName
    , eventPayload = eventSchema
    , eventPolicy = OrderedEvents
    , eventSubscribe = \subscription → do
        let number = subscriptionNumber (subscriptionInfo subscription)
        atomically (modifyTVar' (registrySubscribers registry) (Map.insert number (Subscriber (subscriptionFeed subscription))))
        pure
          ProviderWork
            { workCancel = atomically (modifyTVar' (registrySubscribers registry) (Map.delete number))
            , workRetirement = pure ProviderComplete
            }
    }

-- | The one request endpoint the subscription service requires, which nothing can start: no namespace of
-- the VM binds a request to it, so its submit is never called by a script. Were it ever called, that is a
-- defect of the runner, raised as a failure of the host.
unreachableEndpoint ∷ RequestEndpoint
unreachableEndpoint =
  RequestEndpoint
    { endpointName = "unreachable"
    , endpointResult = SNil
    , endpointSubmit = \_ → throwIO (UnreachableRequest "the runner's request endpoint was started")
    }

-- | The runner's request endpoint was started, which nothing it grants can do.
newtype UnreachableRequest = UnreachableRequest Text
  deriving (Eq, Show)

instance Exception UnreachableRequest

-- Events -----------------------------------------------------------------------------------------

-- | What happened to an instance.
data InstanceEvent = InstanceEvent
  { eventStarted ∷ !Bool
    -- ^ @True@ for /started/, @False@ for /ended/.
  , eventInstance ∷ !InstanceId
  , eventInstanceName ∷ !(Maybe Text)
  , eventOutcome ∷ !(Maybe Text)
    -- ^ Present only on an end.
  }

-- | The shape of every delivery's payload.
eventSchema ∷ Schema
eventSchema =
  SRecord
    [ ("event", SText)
    , ("tid", SRecord [("runtime", SInteger), ("owner", SInteger), ("id", SInteger)])
    , ("name", SOptional SText)
    , ("outcome", SOptional SText)
    ]

-- | The payload a delivery carries.
eventValue ∷ InstanceEvent → Value
eventValue event =
  VRecord $
    [("event", VText (if eventStarted event then "started" else "ended")), ("tid", instanceIdValue (eventInstance event))]
      <> [("name", VText name) | Just name ← [eventInstanceName event]]
      <> [("outcome", VText outcome) | Just outcome ← [eventOutcome event]]

-- Answers ----------------------------------------------------------------------------------------

-- | Why a delivery was refused when it was offered.
data Refusal
  = -- | The subscriber's queue had no place.
    RefusedQueueFull
  | -- | The store of events held for ticks had no place.
    RefusedStagingFull
  deriving (Eq, Show)

-- | What an engine's answer to a delivery means for the run.
data AnswerClass
  = -- | Admitted on arrival, or accepted for its tick: delivered. A staged one can still fail at its tick,
    -- which is the engine's, not an answer the runner gets.
    AnswerAdmitted
  | AnswerStaged
  | -- | Refused when offered, because full: counted, nothing evicted or retried, nothing fails.
    AnswerRefused !Refusal
  | -- | The subscription ended meanwhile (its instance stopped, or it was unsubscribed): counted, benign.
    AnswerEnded
  | -- | A defect of the runner or of its configuration: late, duplicate, unassigned, not logical, a value
    -- the endpoint's own schema refuses, or coalesced (the endpoint is ordered events, so coalescing is
    -- one). Raised as a failure of the host, never counted away.
    AnswerDefect !EventAnswer
  deriving (Eq, Show)

-- | The one function every immediate answer to a delivery goes through.
classifyAnswer ∷ EventAnswer → AnswerClass
classifyAnswer = \case
  EventAdmitted → AnswerAdmitted
  EventStaged → AnswerStaged
  EventQueueFull → AnswerRefused RefusedQueueFull
  EventStagingFull → AnswerRefused RefusedStagingFull
  EventEnded → AnswerEnded
  other@EventCoalesced → AnswerDefect other
  other@EventRefusedValue → AnswerDefect other
  other@EventLate → AnswerDefect other
  other@EventDuplicate → AnswerDefect other
  other@EventUnassigned → AnswerDefect other
  other@EventNotLogical → AnswerDefect other

-- | An answer that is a defect of the runner or its configuration, raised as a failure of the host.
newtype EventDefect = EventDefect EventAnswer
  deriving (Eq, Show)

instance Exception EventDefect

-- Producing -------------------------------------------------------------------------------------

-- | Where a delivery is placed: on arrival, on an elapsed VM, or at this tick, on a tick VM, each with a
-- place of its own.
newtype Place = PlaceAt (Maybe Word64)

-- | Produce these events, in this order: each is delivered once to every subscription that exists now, in
-- ascending order of the subscription's number. On a tick VM every /delivery/, not every event, takes the
-- tick given and a place of its own: a sequence that is unique and increases in production order and then
-- recipient order. Each answer is classified and counted; a defect is raised.
--
-- Called only when the owner is running nothing, so the subscriptions it reads are the ones that exist
-- at that moment and no other.
produceEvents ∷ Registry → Place → [InstanceEvent] → IO ()
produceEvents registry (PlaceAt tick) events = mapM_ produceOne events
  where
    produceOne event = do
      recipients ← atomically (Map.elems <$> readTVar (registrySubscribers registry))
      atomically (modifyTVar' (registryTally registry) (bump event))
      _ ← foldM (\() recipient → deliverTo event recipient) () recipients
      pure ()
    bump event tally
      | eventStarted event = tally {tallyStarted = tallyStarted tally + 1}
      | otherwise = tally {tallyEnded = tallyEnded tally + 1}
    deliverTo event recipient = do
      slot ← case tick of
        Nothing → pure Nothing
        Just due → atomically $ do
          sequenceNumber ← readTVar (registryNext registry)
          writeTVar (registryNext registry) (sequenceNumber + 1)
          pure (Just (DueSlot due sequenceNumber))
      answer ← feedDeliver (subscriberFeed recipient) slot (eventValue event)
      atomically (modifyTVar' (registryTally registry) (counted (classifyAnswer answer)))
      case classifyAnswer answer of
        AnswerDefect defect → throwIO (EventDefect defect)
        _ → pure ()
    counted answerClass tally =
      let attempted = tally {tallyAttempts = tallyAttempts tally + 1}
       in case answerClass of
            AnswerAdmitted → attempted {tallyAdmitted = tallyAdmitted attempted + 1}
            AnswerStaged → attempted {tallyStaged = tallyStaged attempted + 1}
            AnswerRefused RefusedQueueFull → attempted {tallyQueueFull = tallyQueueFull attempted + 1}
            AnswerRefused RefusedStagingFull → attempted {tallyStagingFull = tallyStagingFull attempted + 1}
            AnswerEnded → attempted {tallySubscriptionEnded = tallySubscriptionEnded attempted + 1}
            AnswerDefect _ → attempted
