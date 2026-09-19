-- | The stop exit record: what it names, what it counts, and what it refuses
-- to claim.
module Test.Lua.Protocol.Stop (spec) where

import qualified Data.Map.Strict as Map
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( EndpointId (EndpointId)
  , RequestName (RequestName)
  , SubscriptionName (SubscriptionName)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request
  ( CancelCause (CancelledByStop)
  , Reply (ReplyResult)
  , SettlementKind (KindResult)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session
  ( AdmissionState (AdmissionClosed)
  , DiscardCounts (discardedAdmissions, discardedEvents, discardedRequestResults, discardedResults)
  , ExitRecord (exitDiscards, exitOutstandingProviderWork, exitOutstandingSegments, exitRequests, exitScope, exitSubscriptions, exitTasks)
  , RequestDisposition (RequestRevokedAt, RequestSettledAs)
  , Session (sessionAdmission, sessionKey, sessionRequests, sessionTasks)
  , SessionRejection (SessionAlreadyStopped)
  , TaskDisposition (DispositionAborted, DispositionNotAdmitted, DispositionOutstandingSegment, DispositionTerminal)
  , acceptRequest
  , activateNext
  , advanceEpoch
  , applyOutcome
  , applyReplyIn
  , cancelTaskIn
  , deliverEvent
  , registerSubscription
  , requestAdmission
  , startSegment
  , stopSession
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription (OverloadPolicy (OrderedEvents))
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task
  ( SegmentOutcome (SegmentCompleted)
  , TaskOutcome (OutcomeCancelled, OutcomeCompleted)
  )
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Lua.Protocol.Support
  ( admission
  , admitted
  , message
  , ok
  , openSessionWith
  , rejected
  , roomyLimits
  , runningTask
  )

spec ∷ Spec
spec = describe "stop" $ do
  it "records a disposition for every task, including one still inside a segment" $ do
    session ← openSessionWith roomyLimits
    (a, finished) ← runningTask 1 session
    (b, ()) ← ok (applyOutcome finished (SegmentCompleted "done") a)
    (c, aborted) ← admitted 2 b
    (d, running) ← runningTask 3 c
    (e, ()) ← ok (cancelTaskIn aborted d)
    (f, waiting) ← admitted 4 e
    (g, queuedOnly) ← ok (requestAdmission (admission 5) f)
    let (stopped, record) = stopSession g
    exitScope record `shouldBe` sessionKey g
    Map.lookup finished (exitTasks record) `shouldBe` Just (DispositionTerminal OutcomeCompleted)
    Map.lookup aborted (exitTasks record) `shouldBe` Just (DispositionTerminal OutcomeCancelled)
    Map.lookup running (exitTasks record) `shouldBe` Just DispositionOutstandingSegment
    Map.lookup waiting (exitTasks record) `shouldBe` Just DispositionAborted
    Map.lookup queuedOnly (exitTasks record) `shouldBe` Just DispositionNotAdmitted
    exitOutstandingSegments record `shouldBe` [running]
    sessionAdmission stopped `shouldBe` AdmissionClosed

  it "does not claim accepted work drained" $ do
    session ← openSessionWith roomyLimits
    (a, running) ← runningTask 1 session
    let (_, record) = stopSession a
    exitOutstandingSegments record `shouldBe` [running]
    Map.lookup running (exitTasks record) `shouldBe` Just DispositionOutstandingSegment

  it "records request dispositions and the provider work still outstanding" $ do
    session ← openSessionWith roomyLimits
    (a, owner) ← runningTask 1 session
    (b, answered) ← ok (acceptRequest owner (RequestName 1) (EndpointId "provider") a)
    (c, ()) ← ok (applyReplyIn answered (ReplyResult (message 1 "value")) b)
    (d, pending) ← ok (acceptRequest owner (RequestName 2) (EndpointId "provider") c)
    let (stopped, record) = stopSession d
    Map.lookup answered (exitRequests record) `shouldBe` Just (RequestSettledAs KindResult)
    Map.lookup pending (exitRequests record) `shouldBe` Just (RequestRevokedAt CancelledByStop)
    exitOutstandingProviderWork record `shouldBe` [pending]
    Map.member pending (sessionRequests stopped) `shouldBe` True
    Map.member answered (sessionRequests stopped) `shouldBe` False

  it "counts what it discarded, separately per kind" $ do
    session ← openSessionWith roomyLimits
    (a, owner) ← runningTask 1 session
    (b, ()) ← ok (applyOutcome owner (SegmentCompleted "done") a)
    (c, second) ← runningTask 2 b
    (d, subscription) ← ok (registerSubscription second (SubscriptionName 1) (EndpointId "events") OrderedEvents c)
    (e, _) ← ok (deliverEvent subscription (message 1 "one") d)
    (f, request) ← ok (acceptRequest second (RequestName 1) (EndpointId "provider") e)
    (g, _) ← ok (requestAdmission (admission 3) f)
    let (_, record) = stopSession g
    discardedResults (exitDiscards record) `shouldBe` 1
    discardedAdmissions (exitDiscards record) `shouldBe` 1
    discardedEvents (exitDiscards record) `shouldBe` 1
    discardedRequestResults (exitDiscards record) `shouldBe` 1
    Map.lookup subscription (exitSubscriptions record) `shouldBe` Just 1
    Map.lookup request (exitRequests record) `shouldBe` Just (RequestRevokedAt CancelledByStop)

  it "rejects new work with a typed reason once admission has closed" $ do
    session ← openSessionWith roomyLimits
    (a, _) ← admitted 1 session
    let (stopped, _) = stopSession a
    (_, admissionRefusal) ← rejected (requestAdmission (admission 2) stopped)
    admissionRefusal `shouldBe` SessionAlreadyStopped
    (_, activationRefusal) ← rejected (activateNext stopped)
    activationRefusal `shouldBe` SessionAlreadyStopped
    (_, epochRefusal) ← rejected (advanceEpoch stopped)
    epochRefusal `shouldBe` SessionAlreadyStopped

  it "answers the record it already produced when stopped again" $ do
    session ← openSessionWith roomyLimits
    (a, identity) ← runningTask 1 session
    let (stopped, record) = stopSession a
        (again, second) = stopSession stopped
    second `shouldBe` record
    again `shouldBe` stopped
    Map.lookup identity (exitTasks second) `shouldBe` Just DispositionOutstandingSegment
    Map.null (sessionTasks again) `shouldBe` True

  it "refuses to run a task that stop aborted" $ do
    session ← openSessionWith roomyLimits
    (a, identity) ← admitted 1 session
    let (stopped, _) = stopSession a
    (_, refusal) ← rejected (startSegment identity stopped)
    refusal `shouldBe` SessionAlreadyStopped
