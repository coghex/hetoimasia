-- | Epoch replacement: invalidating one generation of a session's records
-- and issuing the next, retaining only provider-work accounting.
--
-- It is one of three operations that clear overlapping stores. Failure
-- invalidation in "Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Failure"
-- and stop in "Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Stop" are the
-- others, and it is deliberately not merged with them: each retains different
-- records and reports different counts.
module Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Epoch
  ( EpochChange (..)
  , advanceEpoch
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( Epoch
  , RequestId
  , SessionKey (keyEpoch)
  , nextEpoch
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request (CancelCause (CancelledByEpochChange))
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Revocation (revocableRequests, revokeOne)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.State
  ( Counters (..)
  , Session (..)
  , SessionRejection
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Step
  ( counting
  , notFailed
  , notStopped
  , refuse
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription (unsubscribe)

-- | What an epoch change invalidated.
data EpochChange = EpochChange
  { changedFrom ∷ !Epoch
  , changedTo ∷ !Epoch
  , invalidatedTasks ∷ !Int
  , invalidatedAdmissions ∷ !Int
  , invalidatedRequests ∷ !Int
  , invalidatedSubscriptions ∷ !Int
  , retainedProviderWork ∷ ![RequestId]
  }
  deriving (Eq, Show)

-- | Replace this session's generation of records.
--
-- Everything of the previous epoch is invalidated before the new epoch exists
-- to publish anything: tasks, queued admissions, subscriptions, and pending
-- requests. What survives is exactly the accounting for provider work that is
-- not known to have ended, keyed by the old identities, so late evidence can
-- retire it without reaching anything the new epoch issued.
--
-- A failed session is not advanced. Replacing it is constructing a new
-- session, which is what \"no retry, restart, or continuation\" means.
advanceEpoch ∷ Session v → (Session v, Either SessionRejection EpochChange)
advanceEpoch session = case notStopped session >> notFailed session of
  Left rejection → refuse session rejection
  Right () →
    let replacing = revocableRequests session
        revoked =
          foldl'
            (flip (revokeOne CancelledByEpochChange))
            session
            replacing
        retained = Map.keys (sessionRequests revoked)
        discardedResults = Map.size (sessionResults session)
        discardedQueued = Seq.length (sessionQueued session)
        discardedBacklog = sum (fmap unsubscribe (Map.elems (sessionSubscriptions session)))
        next =
          counting
            ( \counters →
                counters
                  { countInvalidatedTasks =
                      countInvalidatedTasks counters + Map.size (sessionTasks session)
                  , countInvalidatedSubscriptions =
                      countInvalidatedSubscriptions counters
                        + Map.size (sessionSubscriptions session)
                  , countDiscardedResults = countDiscardedResults counters + discardedResults
                  , countDiscardedAdmissions = countDiscardedAdmissions counters + discardedQueued
                  , countDiscardedEvents = countDiscardedEvents counters + discardedBacklog
                  }
            )
            revoked
              { sessionKey = replacement
              , sessionEpochFirstTask = sessionNextTask revoked
              , sessionTasks = Map.empty
              , sessionQueued = Seq.empty
              , sessionResults = Map.empty
              , sessionReservations = 0
              , sessionSubscriptions = Map.empty
              }
     in ( next
        , Right
            EpochChange
              { changedFrom = keyEpoch (sessionKey session)
              , changedTo = keyEpoch replacement
              , invalidatedTasks = Map.size (sessionTasks session)
              , invalidatedAdmissions = discardedQueued
              , invalidatedRequests = length replacing
              , invalidatedSubscriptions = Map.size (sessionSubscriptions session)
              , retainedProviderWork = retained
              }
        )
  where
    replacement =
      (sessionKey session) {keyEpoch = nextEpoch (keyEpoch (sessionKey session))}
