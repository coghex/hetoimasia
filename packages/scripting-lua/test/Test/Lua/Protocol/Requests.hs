-- | Single-assignment settlement, and the two obligations a request holds.
--
-- The orderings matter more than any single step here: cancel then complete,
-- complete then observe, observe then complete, and complete twice all have to
-- leave the same bounded bookkeeping behind.
module Test.Lua.Protocol.Requests (spec) where

import qualified Data.Map.Strict as Map
import Hetoimasia.Scripting.Lua.Internal.Protocol.Failure
  ( ReasonCode (ProviderFault)
  , failureReason
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( EndpointId (EndpointId)
  , RequestName (RequestName)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits
  ( LimitName (OutstandingRequests)
  , Limits (maxOutstandingRequests, maxPayloadBytes)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request
  ( CancelCause (CancelledByOwner, CancelledByTaskInvalidation)
  , ObserveRejection (ResultNotHeld, ResultUnsettled)
  , ProviderRejection (ProviderAlreadyComplete, ProviderStillAwaitingReply)
  , Reply (ReplyFailure, ReplyResult)
  , ReplyRejection (ReplyAlreadySettled)
  , RequestRecord (requestProviderOutstanding, requestResultHeld, requestSettlement)
  , Settlement (SettledCancelled, SettledFailure, SettledResult)
  , SettlementKind (KindCancelled, KindFailure, KindResult)
  , settlementKind
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session
  ( Counters (countInvalidatedRequests, countLateProviderCompletions, countLateReplies, countOversizePayloads, countUnknownReplies)
  , Session (sessionCounters, sessionRequests, sessionTasks)
  , SessionRejection (CapReached, NotTaskOwner, ObserveRefused, PayloadTooLarge, ProviderRefused, ReplyRefused, UnknownRequest)
  , acceptRequest
  , advanceEpoch
  , applyOutcome
  , applyReplyIn
  , cancelRequestIn
  , cancelTaskIn
  , completeProviderWorkIn
  , observeRequestIn
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task
  ( SegmentOutcome (SegmentWaiting)
  , TaskState (Waiting)
  , Task (taskState)
  , WaitCause (WaitingOnRequest)
  )
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
endpoint = EndpointId "provider.sample"

spec ∷ Spec
spec = describe "requests" $ do
  it "settles once, and a duplicate reply neither overwrites nor disappears" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, identity) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, ()) ← ok (applyReplyIn identity (ReplyResult (message 4 "first")) b)
    (d, refusal) ← rejected (applyReplyIn identity (ReplyResult (message 4 "second")) c)
    refusal `shouldBe` ReplyRefused (ReplyAlreadySettled KindResult)
    countLateReplies (sessionCounters d) `shouldBe` 1
    (_, settled) ← ok (observeRequestIn identity d)
    settled `shouldBe` SettledResult (message 4 "first")

  it "refuses a reply for an identity it does not hold, and counts it" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, identity) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, ()) ← ok (applyReplyIn identity (ReplyResult (message 1 "answer")) b)
    (d, _) ← ok (observeRequestIn identity c)
    (e, refusal) ← rejected (applyReplyIn identity (ReplyResult (message 1 "again")) d)
    refusal `shouldBe` UnknownRequest identity
    countUnknownReplies (sessionCounters e) `shouldBe` 1

  it "lets a task wait only on a request it owns" $ do
    session ← openSession
    (a, first) ← runningTask 1 session
    (b, second) ← runningTask 2 a
    (c, identity) ← ok (acceptRequest first (RequestName 1) endpoint b)
    (_, refusal) ←
      rejected (applyOutcome second (SegmentWaiting "held" (WaitingOnRequest identity)) c)
    refusal `shouldBe` NotTaskOwner first second
    (d, ()) ← ok (applyOutcome first (SegmentWaiting "held" (WaitingOnRequest identity)) c)
    fmap taskState (Map.lookup first (sessionTasks d))
      `shouldBe` Just (Waiting (WaitingOnRequest identity))

  it "keeps provider accounting outstanding when the owner cancels" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, identity) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, ()) ← ok (cancelRequestIn identity b)
    record ← heldRecord identity c
    requestSettlement record `shouldBe` Just (SettledCancelled CancelledByOwner)
    requestResultHeld record `shouldBe` True
    requestProviderOutstanding record `shouldBe` True

  it "does not release provider accounting by observing a cancellation" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, identity) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, ()) ← ok (cancelRequestIn identity b)
    (d, settled) ← ok (observeRequestIn identity c)
    settled `shouldBe` SettledCancelled CancelledByOwner
    record ← heldRecord identity d
    requestResultHeld record `shouldBe` False
    requestProviderOutstanding record `shouldBe` True
    (e, ()) ← ok (completeProviderWorkIn identity d)
    Map.member identity (sessionRequests e) `shouldBe` False

  it "does not release an unobserved result's storage by completing the provider" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, identity) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, ()) ← ok (cancelRequestIn identity b)
    (d, ()) ← ok (completeProviderWorkIn identity c)
    record ← heldRecord identity d
    requestProviderOutstanding record `shouldBe` False
    requestResultHeld record `shouldBe` True
    (e, settled) ← ok (observeRequestIn identity d)
    settled `shouldBe` SettledCancelled CancelledByOwner
    Map.member identity (sessionRequests e) `shouldBe` False

  it "refuses and counts a repeated provider completion without observation" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, identity) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, ()) ← ok (cancelRequestIn identity b)
    (d, ()) ← ok (completeProviderWorkIn identity c)
    (e, refusal) ← rejected (completeProviderWorkIn identity d)
    refusal `shouldBe` ProviderRefused ProviderAlreadyComplete
    countLateProviderCompletions (sessionCounters e) `shouldBe` 1
    record ← heldRecord identity e
    requestResultHeld record `shouldBe` True

  it "refuses provider completion for a request that has not settled" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, identity) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, refusal) ← rejected (completeProviderWorkIn identity b)
    refusal `shouldBe` ProviderRefused ProviderStillAwaitingReply
    record ← heldRecord identity c
    requestProviderOutstanding record `shouldBe` True

  it "retires provider work with a late reply that publishes nothing" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, identity) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, ()) ← ok (cancelRequestIn identity b)
    (d, refusal) ← rejected (applyReplyIn identity (ReplyResult (message 4 "late")) c)
    refusal `shouldBe` ReplyRefused (ReplyAlreadySettled KindCancelled)
    countLateReplies (sessionCounters d) `shouldBe` 1
    record ← heldRecord identity d
    requestProviderOutstanding record `shouldBe` False
    requestSettlement record `shouldBe` Just (SettledCancelled CancelledByOwner)
    (e, settled) ← ok (observeRequestIn identity d)
    settled `shouldBe` SettledCancelled CancelledByOwner
    Map.member identity (sessionRequests e) `shouldBe` False

  it "settles a failure reply once and reclaims it when observed" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, identity) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, ()) ← ok (applyReplyIn identity (ReplyFailure (failureReason ProviderFault "no")) b)
    (d, settled) ← ok (observeRequestIn identity c)
    settled `shouldBe` SettledFailure (failureReason ProviderFault "no")
    Map.member identity (sessionRequests d) `shouldBe` False

  it "refuses observing an unsettled request, and observing one twice" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, identity) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, refusal) ← rejected (observeRequestIn identity b)
    refusal `shouldBe` ObserveRefused ResultUnsettled
    (d, ()) ← ok (cancelRequestIn identity c)
    (e, _) ← ok (observeRequestIn identity d)
    (_, second) ← rejected (observeRequestIn identity e)
    second `shouldBe` ObserveRefused ResultNotHeld

  it "counts a request against the cap until both obligations are discharged" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, first) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, _) ← ok (acceptRequest owner (RequestName 2) endpoint b)
    (d, refusal) ← rejected (acceptRequest owner (RequestName 3) endpoint c)
    refusal `shouldBe` CapReached OutstandingRequests (maxOutstandingRequests sampleLimits)
    (e, ()) ← ok (cancelRequestIn first d)
    (f, _) ← ok (observeRequestIn first e)
    (g, stillFull) ← rejected (acceptRequest owner (RequestName 3) endpoint f)
    stillFull `shouldBe` CapReached OutstandingRequests (maxOutstandingRequests sampleLimits)
    (h, ()) ← ok (completeProviderWorkIn first g)
    Map.size (sessionRequests h) `shouldBe` 1
    (final, _) ← ok (acceptRequest owner (RequestName 3) endpoint h)
    Map.size (sessionRequests final) `shouldBe` 2

  it "does not re-invalidate a stub when its owning task terminates" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, identity) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, ()) ← ok (cancelRequestIn identity b)
    (d, _) ← ok (observeRequestIn identity c)
    countInvalidatedRequests (sessionCounters d) `shouldBe` 0
    (e, ()) ← ok (cancelTaskIn owner d)
    countInvalidatedRequests (sessionCounters e) `shouldBe` 0
    record ← heldRecord identity e
    requestSettlement record `shouldBe` Just (SettledCancelled CancelledByOwner)
    requestProviderOutstanding record `shouldBe` True
    (f, ()) ← ok (completeProviderWorkIn identity e)
    Map.member identity (sessionRequests f) `shouldBe` False

  it "still invalidates a live request when its owning task terminates" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, identity) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, ()) ← ok (cancelTaskIn owner b)
    countInvalidatedRequests (sessionCounters c) `shouldBe` 1
    record ← heldRecord identity c
    requestSettlement record
      `shouldBe` Just (SettledCancelled CancelledByTaskInvalidation)
    requestResultHeld record `shouldBe` False
    requestProviderOutstanding record `shouldBe` True

  it "stamps a new generation on every reuse of one request handle" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, older) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, newer) ← ok (acceptRequest owner (RequestName 1) endpoint b)
    (older == newer) `shouldBe` False
    (d, ()) ← ok (applyReplyIn older (ReplyResult (message 1 "old")) c)
    record ← heldRecord newer d
    requestSettlement record `shouldBe` Nothing

  it "refuses an oversize reply's value and settles the request as a failure" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, identity) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    let tooBig = maxPayloadBytes sampleLimits + 1
    (c, refusal) ← rejected (applyReplyIn identity (ReplyResult (message tooBig "huge")) b)
    refusal `shouldBe` PayloadTooLarge tooBig (maxPayloadBytes sampleLimits)
    countOversizePayloads (sessionCounters c) `shouldBe` 1
    record ← heldRecord identity c
    requestProviderOutstanding record `shouldBe` False
    fmap settlementKind (requestSettlement record) `shouldBe` Just KindFailure
    (d, settled) ← ok (observeRequestIn identity c)
    settlementKind settled `shouldBe` KindFailure
    Map.member identity (sessionRequests d) `shouldBe` False

  it "retires provider work when an oversize reply arrives for a cancelled request" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, identity) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, ()) ← ok (cancelRequestIn identity b)
    let tooBig = maxPayloadBytes sampleLimits + 1
    (d, refusal) ← rejected (applyReplyIn identity (ReplyResult (message tooBig "huge")) c)
    refusal `shouldBe` PayloadTooLarge tooBig (maxPayloadBytes sampleLimits)
    record ← heldRecord identity d
    requestProviderOutstanding record `shouldBe` False
    requestSettlement record `shouldBe` Just (SettledCancelled CancelledByOwner)
    (e, _) ← ok (observeRequestIn identity d)
    Map.member identity (sessionRequests e) `shouldBe` False

  it "retires provider work when an oversize reply arrives for an epoch-invalidated stub" $ do
    session ← openSession
    (a, owner) ← runningTask 1 session
    (b, identity) ← ok (acceptRequest owner (RequestName 1) endpoint a)
    (c, _) ← ok (advanceEpoch b)
    let tooBig = maxPayloadBytes sampleLimits + 1
    (d, refusal) ← rejected (applyReplyIn identity (ReplyResult (message tooBig "huge")) c)
    refusal `shouldBe` PayloadTooLarge tooBig (maxPayloadBytes sampleLimits)
    Map.member identity (sessionRequests d) `shouldBe` False
  where
    heldRecord identity session = case Map.lookup identity (sessionRequests session) of
      Just record → pure record
      Nothing → fail ("the session no longer holds " <> show identity)
