-- | Subscriptions owned by a holder: an owner that is not one of the session's tasks.
--
-- An instance of a script outlives each of its invocations, so the subscriptions it makes
-- cannot be owned by the task of the invocation that made them (LUA-26). These examples pin
-- what a holder is for: it owns subscriptions across its owner's tasks, ending it ends exactly
-- what retiring a task does, an epoch change invalidates them with the rest, and nothing about
-- the task-owned operations changes.
module Test.Lua.Protocol.HolderSubscriptions (spec) where

import qualified Data.Map.Strict as Map
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( EndpointId (EndpointId)
  , SubscriptionName (SubscriptionName)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request (CancelCause (CancelledByTaskInvalidation))
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session
  ( Counters (countDiscardedEvents, countInvalidatedSubscriptions)
  , EpochChange (invalidatedSubscriptions)
  , Session (sessionCounters, sessionSubscriptions)
  , SessionRejection (SessionAlreadyStopped, UnknownTask)
  , advanceEpoch
  , applyOutcome
  , deliverEvent
  , endHolder
  , issueHolder
  , registerSubscription
  , registerSubscriptionFor
  , stopSession
  , takeEventIn
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription (OverloadPolicy (OrderedEvents), Subscription (subscriptionOwner))
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task (SegmentOutcome (SegmentCompleted))
import Test.Hspec (Spec, describe, it, shouldBe, shouldNotBe)
import Test.Lua.Protocol.Support (message, ok, openSession, rejected, runningTask)

endpoint ∷ EndpointId
endpoint = EndpointId "events.holders"

spec ∷ Spec
spec = describe "holders of subscriptions" $ do
  it "owns a subscription without being a task" $ do
    session ← openSession
    (a, task) ← runningTask 1 session
    let (holder, b) = issueHolder a
    (c, identity) ← ok (registerSubscriptionFor holder (SubscriptionName 1) endpoint OrderedEvents b)
    fmap subscriptionOwner (Map.lookup identity (sessionSubscriptions c)) `shouldBe` Just holder
    holder `shouldNotBe` task

  it "accepts a subscription only for a holder it issued and has not ended" $ do
    session ← openSession
    let (stranger, _) = issueHolder session
    (_, never) ← rejected (registerSubscriptionFor stranger (SubscriptionName 1) endpoint OrderedEvents session)
    never `shouldBe` UnknownTask stranger
    let (holder, a) = issueHolder session
        b = endHolder holder CancelledByTaskInvalidation a
    (_, ended) ← rejected (registerSubscriptionFor holder (SubscriptionName 1) endpoint OrderedEvents b)
    ended `shouldBe` UnknownTask holder

  it "keeps its subscriptions and what they hold when one of its owner's tasks retires, and a task's own end" $ do
    session ← openSession
    (a, task) ← runningTask 1 session
    let (holder, b) = issueHolder a
    (c, held) ← ok (registerSubscriptionFor holder (SubscriptionName 1) endpoint OrderedEvents b)
    (d, own) ← ok (registerSubscription task (SubscriptionName 2) endpoint OrderedEvents c)
    (e, _) ← ok (deliverEvent held (message 1 "kept") d)
    (f, _) ← ok (applyOutcome task (SegmentCompleted "done") e)
    Map.member held (sessionSubscriptions f) `shouldBe` True
    Map.member own (sessionSubscriptions f) `shouldBe` False
    (_, delivery) ← ok (takeEventIn held f)
    delivery `shouldBe` message 1 "kept"

  it "ends what it holds when it ends, counting what the subscription had not delivered, as a task's retirement does" $ do
    session ← openSession
    let (holder, a) = issueHolder session
    (b, identity) ← ok (registerSubscriptionFor holder (SubscriptionName 1) endpoint OrderedEvents a)
    (c, _) ← ok (deliverEvent identity (message 1 "one") b)
    (d, _) ← ok (deliverEvent identity (message 1 "two") c)
    let e = endHolder holder CancelledByTaskInvalidation d
    Map.member identity (sessionSubscriptions e) `shouldBe` False
    countInvalidatedSubscriptions (sessionCounters e) `shouldBe` 1
    countDiscardedEvents (sessionCounters e) `shouldBe` 2

  it "is invalidated with the rest in an epoch change, and a late delivery cannot reach the epoch that replaced it" $ do
    session ← openSession
    let (holder, a) = issueHolder session
    (b, identity) ← ok (registerSubscriptionFor holder (SubscriptionName 1) endpoint OrderedEvents a)
    (c, change) ← ok (advanceEpoch b)
    invalidatedSubscriptions change `shouldBe` 1
    Map.null (sessionSubscriptions c) `shouldBe` True
    (_, late) ← rejected (deliverEvent identity (message 1 "late") c)
    show late `shouldNotBe` ""

  it "is refused once the session has stopped" $ do
    session ← openSession
    let (holder, a) = issueHolder session
        (b, _) = stopSession a
    (_, refusal) ← rejected (registerSubscriptionFor holder (SubscriptionName 1) endpoint OrderedEvents b)
    refusal `shouldBe` SessionAlreadyStopped
