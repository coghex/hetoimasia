-- | Holders: an owner of requests that is not one of the session's tasks.
--
-- An instance of a script outlives each of its invocations, so the requests it
-- makes cannot be owned by the task of the invocation that made them. These
-- examples pin what a holder is for: it owns requests across its owner's
-- tasks, ending it revokes exactly what retiring a task does, and nothing about
-- the task-owned operations changes.
module Test.Lua.Protocol.Holders (spec) where

import qualified Data.Map.Strict as Map
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( EndpointId (EndpointId)
  , RequestName (RequestName)
  , SessionKey (keyEpoch)
  , TaskId (taskName)
  , nextEpoch
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request
  ( CancelCause (CancelledByEpochChange, CancelledByOwner, CancelledByStop, CancelledByTaskInvalidation)
  , Reply (ReplyResult)
  , ReplyRejection (ReplyAlreadySettled)
  , RequestRecord (requestOwner, requestProviderOutstanding, requestResultHeld, requestSettlement)
  , Settlement (SettledCancelled)
  , SettlementKind (KindCancelled)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session
  ( Counters (countDiscardedRequestResults, countInvalidatedRequests)
  , Session (sessionCounters, sessionKey, sessionRequests)
  , SessionRejection (ReplyRefused, SessionAlreadyStopped, UnknownTask)
  , acceptRequest
  , acceptRequestFor
  , advanceEpoch
  , applyOutcome
  , applyReplyIn
  , cancelRequestIn
  , cancelRequestWith
  , completeProviderWorkIn
  , endHolder
  , holderLive
  , issueHolder
  , observeRequestIn
  , stopSession
  , withdrawRequest
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task (SegmentOutcome (SegmentCompleted))
import Test.Hspec (Spec, describe, it, shouldBe, shouldNotBe)
import Test.Lua.Protocol.Support (message, ok, openSession, rejected, runningTask)

endpoint ∷ EndpointId
endpoint = EndpointId "provider.holders"

spec ∷ Spec
spec = describe "holders" $ do
  it "owns a request without being a task, and takes a name no task has" $ do
    session ← openSession
    (a, task) ← runningTask 1 session
    let (holder, b) = issueHolder a
    holder `shouldNotBe` task
    taskName holder `shouldNotBe` taskName task
    holderLive holder b `shouldBe` True
    (c, identity) ← ok (acceptRequestFor holder (RequestName 1) endpoint b)
    fmap requestOwner (Map.lookup identity (sessionRequests c)) `shouldBe` Just holder

  it "accepts requests only for a holder it issued and has not ended" $ do
    session ← openSession
    let (stranger, _) = issueHolder session
    (_, never) ← rejected (acceptRequestFor stranger (RequestName 1) endpoint session)
    never `shouldBe` UnknownTask stranger
    let (holder, a) = issueHolder session
        b = endHolder holder CancelledByTaskInvalidation a
    holderLive holder b `shouldBe` False
    (_, ended) ← rejected (acceptRequestFor holder (RequestName 1) endpoint b)
    ended `shouldBe` UnknownTask holder

  it "keeps its requests when one of its owner's tasks retires, and a task's own are revoked" $ do
    session ← openSession
    (a, task) ← runningTask 1 session
    let (holder, b) = issueHolder a
    (c, held) ← ok (acceptRequestFor holder (RequestName 1) endpoint b)
    (d, own) ← ok (acceptRequest task (RequestName 2) endpoint c)
    (e, ()) ← ok (applyOutcome task (SegmentCompleted "done") d)
    fmap requestSettlement (Map.lookup held (sessionRequests e)) `shouldBe` Just Nothing
    fmap requestResultHeld (Map.lookup held (sessionRequests e)) `shouldBe` Just True
    fmap requestSettlement (Map.lookup own (sessionRequests e))
      `shouldBe` Just (Just (SettledCancelled CancelledByTaskInvalidation))
    countInvalidatedRequests (sessionCounters e) `shouldBe` 1

  it "revokes what it holds when it ends, as a task's retirement does" $ do
    session ← openSession
    let (holder, a) = issueHolder session
    (b, unsettled) ← ok (acceptRequestFor holder (RequestName 1) endpoint a)
    (c, answered) ← ok (acceptRequestFor holder (RequestName 2) endpoint b)
    (d, ()) ← ok (applyReplyIn answered (ReplyResult (message 4 "kept")) c)
    let e = endHolder holder CancelledByTaskInvalidation d
    fmap requestSettlement (Map.lookup unsettled (sessionRequests e))
      `shouldBe` Just (Just (SettledCancelled CancelledByTaskInvalidation))
    -- Nobody is left to observe either: the storage is discarded, and the
    -- provider's work stays accounted for the one that never answered.
    fmap requestResultHeld (Map.lookup unsettled (sessionRequests e)) `shouldBe` Just False
    fmap requestProviderOutstanding (Map.lookup unsettled (sessionRequests e)) `shouldBe` Just True
    Map.member answered (sessionRequests e) `shouldBe` False
    countInvalidatedRequests (sessionCounters e) `shouldBe` 2
    countDiscardedRequestResults (sessionCounters e) `shouldBe` 2
    -- A late reply to the revoked one retires the work and publishes nothing.
    (f, late) ← rejected (applyReplyIn unsettled (ReplyResult (message 4 "late")) e)
    late `shouldBe` ReplyRefused (ReplyAlreadySettled KindCancelled)
    Map.member unsettled (sessionRequests f) `shouldBe` False

  it "revokes nothing when it is ended again, or ended after its requests were observed" $ do
    session ← openSession
    let (holder, a) = issueHolder session
    (b, identity) ← ok (acceptRequestFor holder (RequestName 1) endpoint a)
    (c, ()) ← ok (cancelRequestIn identity b)
    (d, settled) ← ok (observeRequestIn identity c)
    settled `shouldBe` SettledCancelled CancelledByOwner
    let e = endHolder holder CancelledByTaskInvalidation d
    -- The cancellation was observed, so ending the holder finds no interest to
    -- revoke and counts nothing; the provider's work is all that is left.
    countInvalidatedRequests (sessionCounters e) `shouldBe` 0
    fmap requestProviderOutstanding (Map.lookup identity (sessionRequests e)) `shouldBe` Just True
    endHolder holder CancelledByTaskInvalidation e `shouldBe` e
    (f, ()) ← ok (completeProviderWorkIn identity e)
    Map.member identity (sessionRequests f) `shouldBe` False

  it "cancels for a stated cause and keeps the settlement to be observed" $ do
    session ← openSession
    let (holder, a) = issueHolder session
    (b, identity) ← ok (acceptRequestFor holder (RequestName 1) endpoint a)
    (c, ()) ← ok (cancelRequestWith CancelledByEpochChange identity b)
    (d, refusal) ← rejected (cancelRequestWith CancelledByOwner identity c)
    refusal `shouldBe` ReplyRefused (ReplyAlreadySettled KindCancelled)
    (_, settled) ← ok (observeRequestIn identity d)
    settled `shouldBe` SettledCancelled CancelledByEpochChange

  it "is not carried across an epoch change, which revokes what it held" $ do
    session ← openSession
    let (holder, a) = issueHolder session
    (b, identity) ← ok (acceptRequestFor holder (RequestName 1) endpoint a)
    (c, _) ← ok (advanceEpoch b)
    keyEpoch (sessionKey c) `shouldBe` nextEpoch (keyEpoch (sessionKey session))
    holderLive holder c `shouldBe` False
    (_, refusal) ← rejected (acceptRequestFor holder (RequestName 2) endpoint c)
    refusal `shouldBe` UnknownTask holder
    -- The request it held is revoked, and the provider's work is still accounted.
    fmap requestSettlement (Map.lookup identity (sessionRequests c))
      `shouldBe` Just (Just (SettledCancelled CancelledByEpochChange))
    -- The owner issues another for the epoch that replaced it.
    let (renewed, d) = issueHolder c
    (_, fresh) ← ok (acceptRequestFor renewed (RequestName 1) endpoint d)
    fresh `shouldNotBe` identity

  it "withdraws an admission that never reached its provider, counting nothing" $ do
    session ← openSession
    let (holder, a) = issueHolder session
    (b, identity) ← ok (acceptRequestFor holder (RequestName 1) endpoint a)
    let c = withdrawRequest identity b
    Map.member identity (sessionRequests c) `shouldBe` False
    countInvalidatedRequests (sessionCounters c) `shouldBe` 0
    countDiscardedRequestResults (sessionCounters c) `shouldBe` 0
    -- The capacity it reserved is free again, and the same name is a new identity.
    (_, second) ← ok (acceptRequestFor holder (RequestName 1) endpoint c)
    second `shouldNotBe` identity

  it "is gone when the session stops" $ do
    session ← openSession
    let (holder, a) = issueHolder session
    (b, identity) ← ok (acceptRequestFor holder (RequestName 1) endpoint a)
    let (c, _) = stopSession b
    holderLive holder c `shouldBe` False
    fmap requestSettlement (Map.lookup identity (sessionRequests c))
      `shouldBe` Just (Just (SettledCancelled CancelledByStop))
    (_, refusal) ← rejected (acceptRequestFor holder (RequestName 2) endpoint c)
    refusal `shouldBe` SessionAlreadyStopped
