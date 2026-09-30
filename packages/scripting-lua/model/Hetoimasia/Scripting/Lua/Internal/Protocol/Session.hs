-- | One owner's session: the aggregate that holds tasks, admissions, requests,
-- and subscriptions together and enforces the bounds between them.
--
-- The single-record modules beside this one decide what one task, one request,
-- or one subscription may do next. This module decides what the /session/ may
-- do: which caps an admission draws on, which records an epoch change
-- invalidates, what a failure closes, and what a stop records. Nothing here
-- reads a clock, forks a thread, or performs IO, and nothing here chooses
-- which task to run — that is LUA-6's, and this model only records what such a
-- choice would need.
--
-- = Shape of every operation
--
-- Each operation takes the session last and answers
-- @('Session' v, 'Either' 'SessionRejection' a)@.
--
-- A rejection never advances the protocol: no task changes state, no cursor
-- moves, no settled slot is overwritten, no event is delivered, and no
-- admission is accepted. That is the guarantee downstream slices may build on,
-- and it is narrower than "a rejection changes nothing", which is not true and
-- should not be relied upon.
--
-- What a rejection may do is record evidence. Always on 'sessionCounters',
-- because how often something was refused is evidence only the session can
-- keep, and in four places on the record the rejection was about:
--
-- * a reply for a request that has __already settled__ is refused and still
--   retires that request's provider accounting, because an answer is evidence
--   the provider finished whether or not anyone was waiting for it (P-7);
-- * a reply whose payload __exceeds the cap__ is refused, its value never
--   stored, and the request still discharged — settled as a provider failure
--   if it was unsettled, counted as a late reply if it was not. A refusal that
--   left the accounting outstanding would hold capacity nothing could release;
-- * a repeated provider completion is refused and counted on the request, as
--   'requestLateCompletions';
-- * a delivery into a full ordered backlog is refused and counted on the
--   subscription, as @subscriptionRejected@.
--
-- The second of those is the only rejection that settles a request, and it is
-- the only place in this module where a refused operation moves a record's
-- protocol state. Everything else above is a counter.
--
-- = Reservations
--
-- 'sessionReservations' counts terminal-result storage taken at admission and
-- released when a terminal result is observed or discarded. It is compared
-- against 'RetainedResults', so a completed task whose result nobody reads
-- keeps occupying the storage its admission already paid for, and the session
-- stops admitting rather than growing. Requests are bounded separately by
-- 'OutstandingRequests', which a request holds until both of its obligations
-- are discharged.
--
-- = Consumption-time identity
--
-- Every record is keyed by an identity that carries its epoch. An epoch change
-- does not have to hunt down replies and events already in flight: they name
-- identities of the old epoch, which are simply not the identities the new
-- epoch issued. A stale reply therefore finds either the retained provider
-- stub it belongs to, or nothing at all, and in neither case can it touch a
-- record of the current epoch. That is the check at consumption that P-9 asks
-- for, and it is structural rather than a comparison somebody has to remember
-- to write.
--
-- = What this module deliberately does not offer
--
-- There is no operation that waits for every task to finish. P-9 refuses one:
-- a subscription or an endless behaviour may never finish, so an application
-- that wants a graceful boundary stops admitting, awaits its own explicit
-- batch, and then stops. 'stopSession' records what was outstanding; it never
-- claims accepted work drained.
--
-- There is also no operation that restarts or continues a failed session.
-- 'advanceEpoch' refuses one, and replacing a failed domain means constructing
-- a new 'Session'.
--
-- = A failed session still reports
--
-- An unsafe failure ends the session's authoritative work: every live task,
-- queued admission, subscription, and pending request of that moment is
-- invalidated, and 'Mutating' admission closes. What stays open is 'Observing'
-- admission, so the owner can admit work that reports on the failure it just
-- had. That is P-8's quiescent failed-session state: alive enough to be asked
-- what happened, and unable to touch authoritative state again.
--
-- = Where each part lives
--
-- This module is the facade over one pure session value. The implementation
-- is split by responsibility beneath it, listed here from the bottom of an
-- acyclic import graph:
--
-- * "Hetoimasia.Scripting.Lua.Internal.Protocol.Session.State":
--   the representation, its construction, and the records it answers with.
-- * "Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Step":
--   refusal, counters, the preconditions, identity and ordinal issuance, and
--   one task transition.
-- * "Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Revocation":
--   retirement and revocation, the shared provider accounting every module
--   above it composes.
-- * "Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Tasks",
--   "Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Requests", and
--   "Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Subscriptions":
--   the operations on each kind of record.
-- * "Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Epoch",
--   "Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Failure", and
--   "Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Stop":
--   the three session-wide invalidations, kept apart because each retains
--   different records and reports different counts.
module Hetoimasia.Scripting.Lua.Internal.Protocol.Session
  ( -- * The session
    Session (..)
  , AdmissionState (..)
  , Authority (..)
  , Counters (..)
  , noCounters
  , newSession

    -- * Terminal results
  , TerminalResult (..)

    -- * Rejections
  , SessionRejection (..)

    -- * Admission
  , AdmissionRequest (..)
  , QueuedAdmission (..)
  , requestAdmission
  , activateNext

    -- * Running tasks
  , startSegment
  , applyOutcome
  , wakeTaskIn
  , pauseTaskIn
  , resumeTaskIn
  , cancelTaskIn
  , observeResult

    -- * Requests
  , acceptRequest
  , applyReplyIn
  , cancelRequestIn
  , observeRequestIn
  , completeProviderWorkIn

    -- * Subscriptions
  , registerSubscription
  , unsubscribeIn
  , deliverEvent
  , takeEventIn

    -- * Epochs
  , EpochChange (..)
  , advanceEpoch

    -- * Failure
  , FailureRecord (..)
  , reportFailure

    -- * Stop
  , TaskDisposition (..)
  , RequestDisposition (..)
  , DiscardCounts (..)
  , noDiscards
  , ExitRecord (..)
  , stopSession
  ) where

import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Epoch (EpochChange (..), advanceEpoch)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Failure (reportFailure)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Requests
  ( acceptRequest
  , applyReplyIn
  , cancelRequestIn
  , completeProviderWorkIn
  , observeRequestIn
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.State
  ( AdmissionState (..)
  , Authority (..)
  , Counters (..)
  , DiscardCounts (..)
  , ExitRecord (..)
  , FailureRecord (..)
  , QueuedAdmission (..)
  , RequestDisposition (..)
  , Session (..)
  , SessionRejection (..)
  , TaskDisposition (..)
  , TerminalResult (..)
  , newSession
  , noCounters
  , noDiscards
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Stop (stopSession)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Subscriptions
  ( deliverEvent
  , registerSubscription
  , takeEventIn
  , unsubscribeIn
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session.Tasks
  ( AdmissionRequest (..)
  , activateNext
  , applyOutcome
  , cancelTaskIn
  , observeResult
  , pauseTaskIn
  , requestAdmission
  , resumeTaskIn
  , startSegment
  , wakeTaskIn
  )
