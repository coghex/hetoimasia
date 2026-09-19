-- | One owned subscription and its bounded delivery.
--
-- A subscription is a record owned by a task, not a channel handed to a
-- producer. Nothing here invokes anything: a producer applies a delivery to
-- the record, and the VM owner later takes what the record kept. That is what
-- keeps a producer's thread out of Lua.
--
-- = Overload is declared, not assumed
--
-- P-7 refuses a universal lossy stream, so every endpoint declares which of
-- two things its events are:
--
-- * 'OrderedEvents' — a sequence where each element matters. It has a bounded
--   backlog, and a delivery into a full one is __rejected__ and counted. The
--   producer learns that the event did not land.
-- * 'ReplaceableState' — a value where only the newest matters. It holds
--   exactly one, and a delivery into an occupied slot __replaces__ it and is
--   counted as a coalesce. Nothing is rejected, and nothing older is claimed
--   to have been seen.
--
-- A capacity applies to 'OrderedEvents' only. 'ReplaceableState' is a snapshot
-- of one value whatever the session's queue cap says, because coalescing to
-- the newest value is the whole of what the policy means.
--
-- = After unsubscribe
--
-- 'unsubscribe' answers the backlog it discarded, and the session forgets the
-- record. A delivery that was already in flight then names an identity the
-- session no longer holds, and is rejected and counted there. The identity
-- carries a generation, so registering the same local number again does not
-- give that in-flight event somewhere new to land.
module Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription
  ( -- * Policy
    OverloadPolicy (..)
  , policyCapacity

    -- * The record
  , Subscription (..)
  , newSubscription
  , subscriptionBacklog

    -- * Delivery
  , Acceptance (..)
  , DeliveryRejection (..)
  , deliver
  , takeDelivery
  , unsubscribe
  ) where

import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( EndpointId
  , SubscriptionId
  , TaskId
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Value (Payload)

-- | What an endpoint's events are, and therefore what overload means.
data OverloadPolicy
  = -- | Ordered events. A full backlog rejects.
    OrderedEvents
  | -- | Replaceable state. A newer value coalesces over the older one.
    ReplaceableState
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | How much a policy retains, given the session's ordered-event cap.
policyCapacity ∷ Int → OverloadPolicy → Int
policyCapacity queueCap OrderedEvents = queueCap
policyCapacity _ ReplaceableState = 1

-- | One registered subscription.
data Subscription v = Subscription
  { subscriptionIdentity ∷ !SubscriptionId
  , subscriptionOwner ∷ !TaskId
  , subscriptionEndpoint ∷ !EndpointId
  , subscriptionPolicy ∷ !OverloadPolicy
  , subscriptionCapacity ∷ !Int
  , subscriptionQueue ∷ !(Seq (Payload v))
  , subscriptionAccepted ∷ !Int
  , subscriptionCoalesced ∷ !Int
  , subscriptionRejected ∷ !Int
  }
  deriving (Eq, Show)

-- | Register a subscription with the capacity its policy implies.
newSubscription
  ∷ SubscriptionId
  → TaskId
  → EndpointId
  → OverloadPolicy
  → Int
  -- ^ The session's ordered-event backlog cap.
  → Subscription v
newSubscription identity owner endpoint policy queueCap =
  Subscription
    { subscriptionIdentity = identity
    , subscriptionOwner = owner
    , subscriptionEndpoint = endpoint
    , subscriptionPolicy = policy
    , subscriptionCapacity = policyCapacity queueCap policy
    , subscriptionQueue = Seq.empty
    , subscriptionAccepted = 0
    , subscriptionCoalesced = 0
    , subscriptionRejected = 0
    }

-- | How much is waiting to be taken.
subscriptionBacklog ∷ Subscription v → Int
subscriptionBacklog = Seq.length . subscriptionQueue

-- | How a delivery was taken.
data Acceptance
  = -- | Appended to an ordered backlog, or filled an empty state slot.
    AcceptedQueued
  | -- | Replaced the value a replaceable-state slot held.
    AcceptedCoalesced
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Why a delivery was refused.
newtype DeliveryRejection
  = -- | An ordered backlog at capacity.
    BacklogFull Int
  deriving (Eq, Show)

-- | Apply one delivery.
--
-- A rejection still updates the record: 'subscriptionRejected' counts it,
-- because how often a producer overran a subscriber is evidence about the
-- endpoint that only the record can keep.
deliver
  ∷ Payload v
  → Subscription v
  → (Subscription v, Either DeliveryRejection Acceptance)
deliver message subscription = case subscriptionPolicy subscription of
  ReplaceableState
    | Seq.null queue → (queued (Seq.singleton message), Right AcceptedQueued)
    | otherwise →
        ( (queued (Seq.singleton message))
            {subscriptionCoalesced = subscriptionCoalesced subscription + 1}
        , Right AcceptedCoalesced
        )
  OrderedEvents
    | Seq.length queue >= subscriptionCapacity subscription →
        (rejected, Left (BacklogFull (subscriptionCapacity subscription)))
    | otherwise → (queued (queue |> message), Right AcceptedQueued)
  where
    queue = subscriptionQueue subscription
    rejected = subscription {subscriptionRejected = subscriptionRejected subscription + 1}
    queued next =
      subscription
        { subscriptionQueue = next
        , subscriptionAccepted = subscriptionAccepted subscription + 1
        }

-- | Take the oldest retained delivery, if any.
takeDelivery ∷ Subscription v → Maybe (Payload v, Subscription v)
takeDelivery subscription = case Seq.viewl (subscriptionQueue subscription) of
  Seq.EmptyL → Nothing
  message Seq.:< rest → Just (message, subscription {subscriptionQueue = rest})

-- | How much backlog ending a subscription discards.
--
-- The session records the number rather than dropping it silently, and then
-- forgets the record.
unsubscribe ∷ Subscription v → Int
unsubscribe = subscriptionBacklog
