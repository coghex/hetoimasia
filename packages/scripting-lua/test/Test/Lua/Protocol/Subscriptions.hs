-- | Owned subscriptions: both declared overload policies, and what happens
-- after one ends.
module Test.Lua.Protocol.Subscriptions (spec) where

import qualified Data.Map.Strict as Map
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( EndpointId (EndpointId)
  , SubscriptionName (SubscriptionName)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits
  ( LimitName (Subscriptions)
  , Limits (maxPayloadBytes, maxSubscriptionQueue, maxSubscriptions)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session
  ( Counters (countCoalescedEvents, countDiscardedEvents, countRejectedEvents)
  , Session (sessionCounters, sessionSubscriptions)
  , SessionRejection (CapReached, DeliveryRefused, NoDelivery, PayloadTooLarge, UnknownSubscription)
  , cancelTaskIn
  , deliverEvent
  , registerSubscription
  , takeEventIn
  , unsubscribeIn
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription
  ( Acceptance (AcceptedCoalesced, AcceptedQueued)
  , DeliveryRejection (BacklogFull)
  , OverloadPolicy (OrderedEvents, ReplaceableState)
  , Subscription (subscriptionCapacity)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Value (Payload (payloadValue))
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Lua.Protocol.Support
  ( message
  , ok
  , openSession
  , rejected
  , runningTask
  , sampleLimits
  )

endpoint ∷ EndpointId
endpoint = EndpointId "events.sample"

spec ∷ Spec
spec = describe "subscriptions" $ do
  it "rejects and counts an ordered-event delivery into a full backlog" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, identity) ← ok (registerSubscription owner (SubscriptionName 1) endpoint OrderedEvents a)
    fmap subscriptionCapacity (Map.lookup identity (sessionSubscriptions b))
      `shouldBe` Just (maxSubscriptionQueue sampleLimits)
    (c, first) ← ok (deliverEvent identity (message 1 "one") b)
    first `shouldBe` AcceptedQueued
    (d, second) ← ok (deliverEvent identity (message 1 "two") c)
    second `shouldBe` AcceptedQueued
    (e, refusal) ← rejected (deliverEvent identity (message 1 "three") d)
    refusal `shouldBe` DeliveryRefused (BacklogFull (maxSubscriptionQueue sampleLimits))
    countRejectedEvents (sessionCounters e) `shouldBe` 1
    (f, oldest) ← ok (takeEventIn identity e)
    payloadValue oldest `shouldBe` "one"
    (g, next) ← ok (takeEventIn identity f)
    payloadValue next `shouldBe` "two"
    (_, empty) ← rejected (takeEventIn identity g)
    empty `shouldBe` NoDelivery identity

  it "coalesces replaceable state to the newest value and rejects nothing" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, identity) ← ok (registerSubscription owner (SubscriptionName 1) endpoint ReplaceableState a)
    fmap subscriptionCapacity (Map.lookup identity (sessionSubscriptions b)) `shouldBe` Just 1
    (c, first) ← ok (deliverEvent identity (message 1 "v1") b)
    first `shouldBe` AcceptedQueued
    (d, second) ← ok (deliverEvent identity (message 1 "v2") c)
    second `shouldBe` AcceptedCoalesced
    (e, third) ← ok (deliverEvent identity (message 1 "v3") d)
    third `shouldBe` AcceptedCoalesced
    countCoalescedEvents (sessionCounters e) `shouldBe` 2
    countRejectedEvents (sessionCounters e) `shouldBe` 0
    (f, held) ← ok (takeEventIn identity e)
    payloadValue held `shouldBe` "v3"
    (_, empty) ← rejected (takeEventIn identity f)
    empty `shouldBe` NoDelivery identity

  it "rejects and counts a delivery after unsubscribe" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, identity) ← ok (registerSubscription owner (SubscriptionName 1) endpoint OrderedEvents a)
    (c, _) ← ok (deliverEvent identity (message 1 "one") b)
    (d, discarded) ← ok (unsubscribeIn identity c)
    discarded `shouldBe` 1
    countDiscardedEvents (sessionCounters d) `shouldBe` 1
    (e, refusal) ← rejected (deliverEvent identity (message 1 "late") d)
    refusal `shouldBe` UnknownSubscription identity
    countRejectedEvents (sessionCounters e) `shouldBe` 1

  it "invalidates a subscription with the task that owned it" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, identity) ← ok (registerSubscription owner (SubscriptionName 1) endpoint OrderedEvents a)
    (c, _) ← ok (deliverEvent identity (message 1 "one") b)
    (d, ()) ← ok (cancelTaskIn owner c)
    Map.member identity (sessionSubscriptions d) `shouldBe` False
    countDiscardedEvents (sessionCounters d) `shouldBe` 1
    (e, refusal) ← rejected (deliverEvent identity (message 1 "late") d)
    refusal `shouldBe` UnknownSubscription identity
    countRejectedEvents (sessionCounters e) `shouldBe` 1

  it "bounds registered subscriptions" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, _) ← ok (registerSubscription owner (SubscriptionName 1) endpoint OrderedEvents a)
    (c, _) ← ok (registerSubscription owner (SubscriptionName 2) endpoint OrderedEvents b)
    (_, refusal) ← rejected (registerSubscription owner (SubscriptionName 3) endpoint OrderedEvents c)
    refusal `shouldBe` CapReached Subscriptions (maxSubscriptions sampleLimits)

  it "refuses an oversize event payload and counts it as rejected" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, identity) ← ok (registerSubscription owner (SubscriptionName 1) endpoint OrderedEvents a)
    let tooBig = maxPayloadBytes sampleLimits + 1
    (c, refusal) ← rejected (deliverEvent identity (message tooBig "huge") b)
    refusal `shouldBe` PayloadTooLarge tooBig (maxPayloadBytes sampleLimits)
    countRejectedEvents (sessionCounters c) `shouldBe` 1
