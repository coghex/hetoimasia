-- | Requests at the session level: accepting one for a live task, applying a
-- provider's reply, cancellation, observation, and provider completion.
--
-- A request holds two obligations — its result observed or discarded, and its
-- provider's work known to have ended — and its bookkeeping is reclaimed
-- through "Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Revocation"
-- only when both are discharged. The reply path here is the one place a
-- rejection settles a request: an oversized reply is refused and still
-- discharges it.
--
-- = Who owns a request
--
-- A request is owned by an identity, and 'acceptRequest' takes a live task of
-- the session. An owner that is /not/ one of the session's tasks, an instance
-- of a script that outlives each of its invocations, owns requests through a
-- /holder/: an identity the session issues ('issueHolder'), that keeps its
-- requests until its owner ends it ('endHolder') and not before, and that
-- accepts requests ('acceptRequestFor') for exactly as long. A holder is
-- revoked through the same path a retiring task's requests are, so the two
-- cannot differ in what ending an owner settles, discards or leaves for the
-- provider.
module Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Requests
  ( acceptRequest
  , issueHolder
  , acceptRequestFor
  , endHolder
  , holderLive
  , withdrawRequest
  , applyReplyIn
  , cancelRequestIn
  , cancelRequestWith
  , observeRequestIn
  , completeProviderWorkIn
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Hetoimasia.Scripting.Lua.Internal.Protocol.Failure (ReasonCode (ValidationFault), failureReason)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( EndpointId
  , RequestId (RequestId)
  , RequestName
  , TaskId (TaskId)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits
  ( Limits (maxOutstandingRequests, maxPayloadBytes)
  , LimitName (OutstandingRequests)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request
  ( CancelCause (CancelledByOwner)
  , Reply (ReplyFailure, ReplyResult)
  , Settlement
  , applyReply
  , cancelLocally
  , completeProviderWork
  , observeSettlement
  , openRequest
  , requestSettled
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Revocation (invalidateHoldingsOf, reclaim)
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
  , takeTaskName
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task (Task (taskState), isTerminal)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Value (Payload (payloadBytes))

-- | Accept a request for a live task, reserving its bookkeeping.
--
-- The caller supplies its own handle; the session stamps the generation, so a
-- handle reused after its earlier request was reclaimed names a new identity
-- and a reply still travelling for the old one cannot settle this one.
acceptRequest
  ∷ TaskId
  → RequestName
  → EndpointId
  → Session v
  → (Session v, Either SessionRejection RequestId)
acceptRequest owner name endpoint session = accepted owner name endpoint ownerLive session
  where
    ownerLive = case Map.lookup owner (sessionTasks session) of
      Nothing → Left (UnknownTask owner)
      Just task
        | isTerminal (taskState task) → Left (UnknownTask owner)
        | otherwise → Right ()

-- | Issue a holder: an identity that can own requests and is not a task.
--
-- It takes the next name of the session's one counter, which is never rewound,
-- so a holder is never mistaken for a task or for another holder. Nothing is
-- stored beyond its being live until 'endHolder'.
issueHolder ∷ Session v → (TaskId, Session v)
issueHolder session =
  let (name, named) = takeTaskName session
      identity = TaskId (sessionKey session) name
   in (identity, named {sessionHolders = Set.insert identity (sessionHolders named)})

-- | Whether a holder is live: issued in this epoch and not ended.
holderLive ∷ TaskId → Session v → Bool
holderLive identity session = Set.member identity (sessionHolders session)

-- | Accept a request for a live holder, reserving its bookkeeping exactly as
-- 'acceptRequest' does for a task.
acceptRequestFor
  ∷ TaskId
  → RequestName
  → EndpointId
  → Session v
  → (Session v, Either SessionRejection RequestId)
acceptRequestFor holder name endpoint session = accepted holder name endpoint holderOpen session
  where
    holderOpen
      | holderLive holder session = Right ()
      | otherwise = Left (UnknownTask holder)

-- | End a holder: every request it still has an interest in is revoked, for
-- this cause, the way a retiring task's are, and the holder accepts no more.
--
-- A request that had settled and was observed is untouched, and so is the
-- accounting for provider work that has not ended: that outlives its owner,
-- as P-7 requires. Ending a holder that is not live changes nothing.
endHolder ∷ TaskId → CancelCause → Session v → Session v
endHolder holder cause session
  | holderLive holder session =
      invalidateHoldingsOf holder cause session {sessionHolders = Set.delete holder (sessionHolders session)}
  | otherwise = session

-- | Take back a request that was accepted and never reached its provider.
--
-- The admission did not happen: nothing was asked of anyone, so nothing is
-- settled, invalidated or counted, and the capacity it reserved is free again.
-- It is for the caller whose handoff to the provider failed before the provider
-- could have started work, and for nothing else.
withdrawRequest ∷ RequestId → Session v → Session v
withdrawRequest identity session = session {sessionRequests = Map.delete identity (sessionRequests session)}

accepted
  ∷ TaskId
  → RequestName
  → EndpointId
  → Either SessionRejection ()
  → Session v
  → (Session v, Either SessionRejection RequestId)
accepted owner name endpoint ownerOpen session = case checks of
  Left rejection → refuse session rejection
  Right () →
    let (generation, stamped) = takeGeneration session
        identity = RequestId (sessionKey session) name generation
     in ( stamped
            { sessionRequests =
                Map.insert
                  identity
                  (openRequest identity owner endpoint)
                  (sessionRequests stamped)
            }
        , Right identity
        )
  where
    limits = limitsIn session
    checks = do
      notStopped session
      ownerOpen
      if Map.size (sessionRequests session) >= maxOutstandingRequests limits
        then Left (CapReached OutstandingRequests (maxOutstandingRequests limits))
        else Right ()

-- | Apply a provider's reply.
--
-- A reply for an identity this session does not hold — a foreign one, or one
-- of an epoch whose records are gone — is rejected as 'UnknownRequest' and
-- counted. It cannot reach a record of the current epoch, because the epoch is
-- part of the identity it was matched on.
--
-- A reply whose declared payload exceeds the cap is refused with
-- 'PayloadTooLarge', and its value is never stored. It still discharges the
-- request: an unsettled request settles as a provider failure naming the
-- overrun, and one that had already settled is counted as a late reply. Either
-- way the provider's work is retired, because a provider that overran still
-- answered, and a refusal that left its accounting outstanding would hold
-- capacity nothing could ever release.
applyReplyIn
  ∷ RequestId
  → Reply v
  → Session v
  → (Session v, Either SessionRejection ())
applyReplyIn identity reply session = case Map.lookup identity (sessionRequests session) of
  Nothing →
    ( counting
        (\counters → counters {countUnknownReplies = countUnknownReplies counters + 1})
        session
    , Left (UnknownRequest identity)
    )
  Just record →
    -- The lookup comes first, and the size check applies only to a payload
    -- that would actually be stored. A reply to a request that has already
    -- settled publishes nothing whatever its size, so refusing it on size
    -- would leave its provider's work outstanding for ever and hold the
    -- capacity that accounting occupies.
    case applyReply (bounded record) record of
      (next, Left rejection) →
        ( counting late (counted (reclaim identity next session))
        , Left (rejectionFor rejection)
        )
      (next, Right ()) → (counted (reclaim identity next session), answer)
  where
    cap = maxPayloadBytes (limitsIn session)
    declared = case reply of
      ReplyResult message → payloadBytes message
      ReplyFailure _ → 0
    oversize = case reply of
      ReplyResult message → payloadBytes message < 0 || payloadBytes message > cap
      ReplyFailure _ → False
    -- An oversize result settles the request as a failure rather than being
    -- turned away. The value is never stored, so the cap still holds; what the
    -- request must not do is stay unsettled for ever because the one provider
    -- that was going to answer it overran.
    bounded record
      | oversize && not (requestSettled record) =
          ReplyFailure (failureReason ValidationFault "the provider's result exceeded the payload cap")
      | otherwise = reply
    late counters = counters {countLateReplies = countLateReplies counters + 1}
    counted current
      | oversize =
          counting
            (\counters → counters {countOversizePayloads = countOversizePayloads counters + 1})
            current
      | otherwise = current
    rejectionFor rejection
      | oversize = PayloadTooLarge declared cap
      | otherwise = ReplyRefused rejection
    answer
      | oversize = Left (PayloadTooLarge declared cap)
      | otherwise = Right ()

-- | Cancel a request at its owner's request.
--
-- Settles the waiter and leaves provider accounting outstanding, so the
-- request keeps its capacity until explicit completion evidence arrives.
cancelRequestIn ∷ RequestId → Session v → (Session v, Either SessionRejection ())
cancelRequestIn = cancelRequestWith CancelledByOwner

-- | Cancel a request, for this cause, with everything 'cancelRequestIn' does.
--
-- The settlement is kept for its owner to observe, which is what separates it
-- from a revocation: an owner that is still there, and was cancelled for a
-- reason that is not its own asking (a replaced epoch), is told how its
-- request ended.
cancelRequestWith ∷ CancelCause → RequestId → Session v → (Session v, Either SessionRejection ())
cancelRequestWith cause identity session = case Map.lookup identity (sessionRequests session) of
  Nothing → refuse session (UnknownRequest identity)
  Just record → case cancelLocally cause record of
    (_, Left rejection) → refuse session (ReplyRefused rejection)
    (next, Right ()) →
      (session {sessionRequests = Map.insert identity next (sessionRequests session)}, Right ())

-- | Observe a request's settlement, releasing only its result storage.
observeRequestIn
  ∷ RequestId
  → Session v
  → (Session v, Either SessionRejection (Settlement v))
observeRequestIn identity session = case Map.lookup identity (sessionRequests session) of
  Nothing → refuse session (UnknownRequest identity)
  Just record → case observeSettlement record of
    Left rejection → refuse session (ObserveRefused rejection)
    Right (settled, next) → (reclaim identity next session, Right settled)

-- | Apply explicit evidence that a provider's work ended.
completeProviderWorkIn ∷ RequestId → Session v → (Session v, Either SessionRejection ())
completeProviderWorkIn identity session = case Map.lookup identity (sessionRequests session) of
  Nothing → refuse session (UnknownRequest identity)
  Just record → case completeProviderWork record of
    (next, Left rejection) →
      ( counting
          ( \counters →
              counters
                { countLateProviderCompletions = countLateProviderCompletions counters + 1
                }
          )
          session {sessionRequests = Map.insert identity next (sessionRequests session)}
      , Left (ProviderRefused rejection)
      )
    (next, Right ()) → (reclaim identity next session, Right ())
