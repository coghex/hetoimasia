-- | Stopping a session: closing admission, aborting what was queued or live,
-- and answering an 'ExitRecord' of dispositions and discard counts.
--
-- A stop records what was outstanding; it never claims accepted work drained,
-- and there is no operation that waits for every task to finish. Its
-- invalidation is its own rather than a shared reset: unlike an unsafe
-- failure it discards finished results, and unlike an epoch change it closes
-- the session for good.
module Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Stop
  ( stopSession
  ) where

import Data.Foldable (toList)
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request
  ( CancelCause (CancelledByStop)
  , RequestRecord (requestProviderOutstanding, requestSettlement)
  , settlementKind
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Revocation (revocableRequests, revokeOne)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.State
  ( AdmissionState (AdmissionClosed)
  , Counters (..)
  , DiscardCounts (..)
  , ExitRecord (..)
  , QueuedAdmission (queuedTask)
  , RequestDisposition (..)
  , Session (..)
  , TaskDisposition (..)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Step (counting)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription (unsubscribe)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task
  ( Task (taskState)
  , TaskState (Running)
  , isTerminal
  , terminalOutcome
  )

-- | Stop the session.
--
-- Admission closes, queued work is aborted, live tasks are aborted, and a task
-- inside a segment is recorded as outstanding rather than waited for. Stopping
-- an already stopped session answers the record it already produced and
-- changes nothing.
stopSession ∷ Session v → (Session v, ExitRecord)
stopSession session = case sessionExit session of
  Just settled → (session, settled)
  Nothing → (stopped {sessionExit = Just record}, record)
  where
    tasks = sessionTasks session
    queued = sessionQueued session
    running = Map.keys (Map.filter ((== Running) . taskState) tasks)
    dispositionOf task = case terminalOutcome (taskState task) of
      Just outcome → DispositionTerminal outcome
      Nothing
        | taskState task == Running → DispositionOutstandingSegment
        | otherwise → DispositionAborted
    requestDisposition entry = case requestSettlement entry of
      Just settled → RequestSettledAs (settlementKind settled)
      Nothing → RequestRevokedAt CancelledByStop
    discardedBacklog = Map.map unsubscribe (sessionSubscriptions session)
    revoked =
      foldl'
        (flip (revokeOne CancelledByStop))
        session
        (revocableRequests session)
    record =
      ExitRecord
        { exitScope = sessionKey session
        , exitTasks =
            Map.union
              (Map.map dispositionOf tasks)
              (Map.fromList [(queuedTask entry, DispositionNotAdmitted) | entry ← toList queued])
        , exitRequests = Map.map requestDisposition (sessionRequests session)
        , exitSubscriptions = discardedBacklog
        , exitOutstandingSegments = running
        , exitOutstandingProviderWork =
            Map.keys (Map.filter requestProviderOutstanding (sessionRequests revoked))
        , exitDiscards =
            DiscardCounts
              { discardedResults = Map.size (sessionResults session)
              , discardedRequestResults =
                  countDiscardedRequestResults (sessionCounters revoked)
                    - countDiscardedRequestResults (sessionCounters session)
              , discardedAdmissions = Seq.length queued
              , discardedEvents = sum (Map.elems discardedBacklog)
              }
        }
    stopped =
      counting
        ( \counters →
            counters
              { countInvalidatedTasks =
                  countInvalidatedTasks counters
                    + Map.size (Map.filter (not . isTerminal . taskState) tasks)
              , countInvalidatedSubscriptions =
                  countInvalidatedSubscriptions counters
                    + Map.size (sessionSubscriptions session)
              , countDiscardedAdmissions =
                  countDiscardedAdmissions counters + Seq.length queued
              , countDiscardedResults =
                  countDiscardedResults counters + Map.size (sessionResults session)
              , countDiscardedEvents =
                  countDiscardedEvents counters + sum (Map.elems discardedBacklog)
              }
        )
        revoked
          { sessionAdmission = AdmissionClosed
          , sessionTasks = Map.empty
          , sessionQueued = Seq.empty
          , sessionResults = Map.empty
          , sessionReservations = 0
          , sessionSubscriptions = Map.empty
          }
