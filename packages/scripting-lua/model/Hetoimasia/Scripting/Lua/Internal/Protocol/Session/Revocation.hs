-- | Retirement and revocation: the shared accounting every domain below the
-- facade relies on to end a task's holdings and to retain provider work.
--
-- Each of these has exactly one definition, here, below every module that
-- uses it. Epoch replacement, failure invalidation, stop, a task's own
-- retirement, and a provider's reply all release requests through
-- 'revokeOne' and 'reclaim', and all choose what to revoke through
-- 'revocableRequests' or the ownership test in 'invalidateHoldingsOf', so an
-- already-revoked provider-only stub is never invalidated, or counted, twice.
module Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Revocation
  ( retire
  , invalidateHoldingsOf
  , revokeOne
  , revocableRequests
  , reclaim
  ) where

import qualified Data.Map.Strict as Map
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity (RequestId (requestScope), TaskId)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request
  ( CancelCause (CancelledByTaskInvalidation)
  , RequestRecord (requestIdentity, requestOwner, requestResultHeld)
  , Revocation (revokedResult)
  , requestReclaimable
  , revokeInterest
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.State
  ( Counters (..)
  , Session (..)
  , TerminalResult
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Step (counting)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription (Subscription (subscriptionOwner), unsubscribe)

-- | Record a task's terminal result and invalidate everything it held.
--
-- Called for every terminal outcome. The storage the result occupies was
-- reserved at admission, so nothing is taken here; it is released when the
-- result is observed, or discarded by an invalidation.
retire ∷ TaskId → TerminalResult v → Session v → Session v
retire identity result session =
  invalidateHoldingsOf identity CancelledByTaskInvalidation $
    session {sessionResults = Map.insert identity result (sessionResults session)}

-- | Revoke the requests and subscriptions one task owned.
--
-- Only the requests that still hold a local interest, for the reason
-- 'revocableRequests' gives: an owner that already observed how its request
-- ended has discharged that interest, and the stub left behind carries
-- provider accounting alone. Revoking it again would settle nothing and
-- discard nothing, and still count an invalidation that had already happened.
invalidateHoldingsOf ∷ TaskId → CancelCause → Session v → Session v
invalidateHoldingsOf identity cause session =
  dropSubscriptions (revokeRequests session)
  where
    ownedAndLive record = requestOwner record == identity && requestResultHeld record
    revokeRequests initial =
      foldl'
        (\current record → revokeOne cause (requestIdentity record) current)
        initial
        (Map.elems (Map.filter ownedAndLive (sessionRequests initial)))
    dropSubscriptions current =
      let (ended, kept) =
            Map.partition ((== identity) . subscriptionOwner) (sessionSubscriptions current)
          discarded = sum (fmap unsubscribe (Map.elems ended))
       in counting
            ( \counters →
                counters
                  { countInvalidatedSubscriptions =
                      countInvalidatedSubscriptions counters + Map.size ended
                  , countDiscardedEvents = countDiscardedEvents counters + discarded
                  }
            )
            current {sessionSubscriptions = kept}

-- | Revoke one request's interest, keeping it only for provider accounting.
revokeOne ∷ CancelCause → RequestId → Session v → Session v
revokeOne cause identity session = case Map.lookup identity (sessionRequests session) of
  Nothing → session
  Just record →
    let (revoked, evidence) = revokeInterest cause record
        kept
          | requestReclaimable revoked = Map.delete identity (sessionRequests session)
          | otherwise = Map.insert identity revoked (sessionRequests session)
     in counting
          ( \counters →
              counters
                { countInvalidatedRequests = countInvalidatedRequests counters + 1
                , countDiscardedRequestResults =
                    countDiscardedRequestResults counters
                      + (if revokedResult evidence then 1 else 0)
                }
          )
          session {sessionRequests = kept}

-- | The requests a session-wide invalidation still has something to revoke.
--
-- 'sessionRequests' holds two quite different things. Some entries are live
-- interest: an owner is still entitled to observe how the request ended.
-- Others are stubs kept for provider accounting alone, whose interest was
-- already revoked — by an earlier epoch change, by the invalidation of the
-- task that owned them, or by an owner that observed its cancellation and
-- walked away.
--
-- Only the first kind is invalidated by an epoch change, a session failure, or
-- a stop. Revoking a stub again would settle nothing, discard nothing, and
-- still count an invalidation, so an epoch would report itself as having
-- invalidated work that had already ended before it began.
--
-- A held result reservation is exactly the first kind: it is outstanding while
-- an owner may still observe the settlement, and released the moment one
-- does or an invalidation discards it.
revocableRequests ∷ Session v → [RequestId]
revocableRequests session =
  [ identity
  | (identity, record) ← Map.toList (sessionRequests session)
  , requestScope identity == sessionKey session
  , requestResultHeld record
  ]

-- | Forget a request once both of its obligations are discharged.
reclaim ∷ RequestId → RequestRecord v → Session v → Session v
reclaim identity record session
  | requestReclaimable record =
      session {sessionRequests = Map.delete identity (sessionRequests session)}
  | otherwise =
      session {sessionRequests = Map.insert identity record (sessionRequests session)}
