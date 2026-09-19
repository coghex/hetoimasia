-- | Epoch change: what it invalidates before the replacement publishes, and
-- what a message of the old epoch can still do afterwards.
module Test.Lua.Protocol.Epochs (spec) where

import qualified Data.Map.Strict as Map
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( EndpointId (EndpointId)
  , RequestName (RequestName)
  , SessionKey (keyEpoch)
  , TaskId (TaskId)
  , taskName
  , SubscriptionName (SubscriptionName)
  , nextEpoch
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request
  ( CancelCause (CancelledByEpochChange)
  , Reply (ReplyResult)
  , RequestRecord (requestProviderOutstanding, requestResultHeld, requestSettlement)
  , ReplyRejection (ReplyAlreadySettled)
  , Settlement (SettledCancelled)
  , SettlementKind (KindCancelled)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session
  ( Counters (countDiscardedRequestResults, countInvalidatedRequests)
  , EpochChange (changedFrom, changedTo, invalidatedAdmissions, invalidatedRequests, invalidatedSubscriptions, invalidatedTasks, retainedProviderWork)
  , Session (sessionCounters, sessionKey, sessionQueued, sessionRequests, sessionReservations, sessionSubscriptions, sessionTasks)
  , SessionRejection (ReplyRefused, UnknownRequest, UnknownSubscription, UnknownTask)
  , acceptRequest
  , advanceEpoch
  , applyReplyIn
  , cancelRequestIn
  , completeProviderWorkIn
  , deliverEvent
  , registerSubscription
  , requestAdmission
  , startSegment
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription (OverloadPolicy (OrderedEvents))
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Lua.Protocol.Support
  ( admission
  , message
  , ok
  , openSession
  , rejected
  , runningTask
  )

endpoint ∷ EndpointId
endpoint = EndpointId "provider.sample"

spec ∷ Spec
spec = describe "epochs" $ do
  it "invalidates every record of the previous epoch before the new one publishes" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, request) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, subscription) ← ok (registerSubscription owner (SubscriptionName 1) endpoint OrderedEvents b)
    (d, _) ← ok (deliverEvent subscription (message 1 "one") c)
    (e, _) ← ok (requestAdmission (admission 2) d)
    (f, change) ← ok (advanceEpoch e)
    changedFrom change `shouldBe` keyEpoch (sessionKey session)
    changedTo change `shouldBe` nextEpoch (keyEpoch (sessionKey session))
    keyEpoch (sessionKey f) `shouldBe` changedTo change
    invalidatedTasks change `shouldBe` 1
    invalidatedAdmissions change `shouldBe` 1
    invalidatedRequests change `shouldBe` 1
    invalidatedSubscriptions change `shouldBe` 1
    Map.null (sessionTasks f) `shouldBe` True
    Map.null (sessionSubscriptions f) `shouldBe` True
    length (sessionQueued f) `shouldBe` 0
    sessionReservations f `shouldBe` 0
    retainedProviderWork change `shouldBe` [request]
    countInvalidatedRequests (sessionCounters f) `shouldBe` 1
    countDiscardedRequestResults (sessionCounters f) `shouldBe` 1

  it "rejects work addressed to an identity the previous epoch issued" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, subscription) ← ok (registerSubscription owner (SubscriptionName 1) endpoint OrderedEvents a)
    (c, _) ← ok (advanceEpoch b)
    (_, taskRefusal) ← rejected (startSegment owner c)
    taskRefusal `shouldBe` UnknownTask owner
    (_, eventRefusal) ← rejected (deliverEvent subscription (message 1 "late") c)
    eventRefusal `shouldBe` UnknownSubscription subscription

  it "admits the same local names again in the new epoch, as different identities" $ do
    session ← openSession
    (a, before) ← runningTask 1 session
    (b, _) ← ok (advanceEpoch a)
    (c, after) ← runningTask 1 b
    (before == after) `shouldBe` False
    Map.member before (sessionTasks c) `shouldBe` False
    Map.member after (sessionTasks c) `shouldBe` True

  it "keeps an invalidated request's provider accounting and discards its result" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, request) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, _) ← ok (advanceEpoch b)
    case Map.lookup request (sessionRequests c) of
      Nothing → fail "the provider stub was not retained"
      Just record → do
        requestSettlement record `shouldBe` Just (SettledCancelled CancelledByEpochChange)
        requestResultHeld record `shouldBe` False
        requestProviderOutstanding record `shouldBe` True
    (d, ()) ← ok (completeProviderWorkIn request c)
    Map.member request (sessionRequests d) `shouldBe` False

  it "retires old provider work with an old-epoch reply without releasing a new request" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, older) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, _) ← ok (advanceEpoch b)
    (d, newOwner) ← runningTask 1 c
    (e, newer) ← ok (acceptRequest newOwner (RequestName 1) endpoint d)
    (older == newer) `shouldBe` False
    (f, refusal) ← rejected (applyReplyIn older (ReplyResult (message 1 "stale")) e)
    refusal `shouldBe` ReplyRefused (ReplyAlreadySettled KindCancelled)
    Map.member older (sessionRequests f) `shouldBe` False
    case Map.lookup newer (sessionRequests f) of
      Nothing → fail "the new epoch's request was released by an old-epoch reply"
      Just record → do
        requestSettlement record `shouldBe` Nothing
        requestResultHeld record `shouldBe` True
        requestProviderOutstanding record `shouldBe` True

  it "invalidates only the epoch it replaces, not stubs it already revoked" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, older) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, first) ← ok (advanceEpoch b)
    invalidatedRequests first `shouldBe` 1
    countInvalidatedRequests (sessionCounters c) `shouldBe` 1
    Map.member older (sessionRequests c) `shouldBe` True
    (d, second) ← ok (advanceEpoch c)
    invalidatedRequests second `shouldBe` 0
    countInvalidatedRequests (sessionCounters d) `shouldBe` 1
    countDiscardedRequestResults (sessionCounters d) `shouldBe` 1
    Map.member older (sessionRequests d) `shouldBe` True
    (e, ()) ← ok (completeProviderWorkIn older d)
    Map.member older (sessionRequests e) `shouldBe` False

  it "treats a task number of the previous epoch as one it never issued" $ do
    session ← openSession
    (a, before) ← runningTask 1 session
    (b, _) ← ok (advanceEpoch a)
    let reused = TaskId (sessionKey b) (taskName before)
    (_, refusal) ← rejected (startSegment reused b)
    refusal `shouldBe` UnknownTask reused

  it "refuses a cancellation addressed to an identity of a replaced epoch" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, older) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, ()) ← ok (completeProviderWorkIn' older b)
    (d, _) ← ok (advanceEpoch c)
    (_, refusal) ← rejected (cancelRequestIn older d)
    refusal `shouldBe` UnknownRequest older
  where
    completeProviderWorkIn' identity session = case cancelRequestIn identity session of
      (cancelled, Right ()) → completeProviderWorkIn identity cancelled
      (unchanged, Left rejection) → (unchanged, Left rejection)
