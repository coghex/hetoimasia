-- | Subscriptions at the session level: registering one for a live task,
-- ending it, delivering events into it, and taking them out.
--
-- The subscription record applies its own overload policy; this module
-- enforces the session's payload cap and subscription cap, and keeps the
-- session-lifetime counts of what was rejected, coalesced, or discarded.
module Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Subscriptions
  ( registerSubscription
  , unsubscribeIn
  , deliverEvent
  , takeEventIn
  ) where

import qualified Data.Map.Strict as Map
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( EndpointId
  , SubscriptionId (SubscriptionId)
  , SubscriptionName
  , TaskId
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits
  ( Limits (maxPayloadBytes, maxSubscriptionQueue, maxSubscriptions)
  , LimitName (Subscriptions)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.State
  ( Counters (..)
  , Session (..)
  , SessionRejection (..)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Step
  ( counting
  , limitsIn
  , notStopped
  , refuse
  , takeGeneration
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription
  ( Acceptance
  , OverloadPolicy
  , deliver
  , newSubscription
  , takeDelivery
  , unsubscribe
  )
import qualified Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription as Subscription
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task (Task (taskState), isTerminal)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Value (Payload (payloadBytes))

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
