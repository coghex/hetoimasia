-- | Providers of engine operations, and the service an owner is granted over them (LUA-7).
--
-- A provider is application code that does work on a script's behalf and answers later, from
-- any thread: pathfinding, an asset load, a query. A script never calls one and a provider
-- never enters Lua. The owner is /granted/ the service, 'RequestGrant', when it is created
-- ('Hetoimasia.Scripting.Lua.Scheduled.scheduledRequests'); the grant is the whole of the
-- authority, and an owner created with none keeps the not-yet-supported fault every
-- asynchronous request answered before. "Hetoimasia.Scripting.Lua.Request" is what a binding's
-- author uses to start a request and what a script calls on one.
--
-- = What the owner guarantees about every request (P-7)
--
-- * /A place is reserved before a request is accepted/, bounded by the grant, and held until the
--   settlement has been taken or discarded /and/ the provider has proved its work over. A
--   completion never waits for anything: filling a slot is one transaction.
-- * /Every request settles exactly once/ in the protocol model's single-assignment slot, as a
--   result, a failure or a cancellation, on every path: the provider's reply, the script's
--   cancel, the end of the instance or task that made it, an epoch change, the owner's stop,
--   failure or cancellation. A duplicate, late or stale reply never overwrites a settlement; it
--   is counted, and it still retires the provider's work.
-- * /A reply is bounded before it is retained/: against the owner's value limits and the
--   endpoint's schema. One that is not within them settles an unsettled request as a failure and
--   its value is never kept.
-- * /Cancelling revokes interest and is not proof the work ended/. The provider is told, once,
--   and keeps the dependencies of its work until it proves the work over, by replying or by its
--   own reading of its retirement ('workRetirement'). Nothing is reported as reclaimed merely
--   because interest was withdrawn, and the instance's settlement, and the owner's exit, wait.
--
-- = Settling on arrival, and at an assigned tick
--
-- An owner on elapsed time ('SettleOnArrival') settles a request when the reply arrives, the
-- first settlement wins, and the script resumes at the next safe boundary after it.
--
-- An owner on logical time ('SettleAtAssignedTick', D-36, D-39) settles at a tick the
-- application assigned when the request was admitted, by default the next, in the order of
-- (tick, sequence):
--
-- * a reply that arrives earlier is a /held completion/, not a settlement: the first is kept,
--   a later one is counted and never replaces it, and the script cannot see it;
-- * the tick does not begin until the request is complete. The scheduler holds the grant that
--   reaches it, as LUA-23 holds a tick for its controls, until the completion is held or the
--   request is cancelled, so a slow provider stalls the owner only at its tick, and one that
--   never answers stalls it there until stop or failure ends the request;
-- * a cancel before the tick always wins: the request settles as cancelled whatever the
--   provider has done, the held value is discarded without reaching Lua, the tick's hold is
--   released, and the provider's work is retired;
-- * a request that is not cancelled settles at its tick with what the provider delivered, and
--   that is what readiness reports: pending before the tick, settled from it on.
--
-- Identical admissions with their assigned ticks, cancels at logical points and grants give
-- identical settlements in an identical order, however provider delays and arrival order vary.
--
-- = Shared by owned subscriptions
--
-- The grant, the guard every call into provider code goes through ('guarded') and the epoch
-- operation ('advanceRequestEpoch') are what LUA-26's subscriptions are built on, unchanged.
module Hetoimasia.Scripting.Lua.Provider
  ( -- * Granting
    RequestGrant (..)
  , requestGrant
  , defaultRequestBound
  , maxRequestBound
  , RequestTiming (..)
  , DueSlot (..)
  , RequestInfo (..)
  , AssignRequest
  , RequestGrantViolation (..)
  , RequestGrantRefused (..)

    -- * What a provider implements
  , RequestEndpoint (..)
  , Submission (..)
  , ProviderWork (..)
  , RetirementState (..)
  , Completion (..)
  , ProviderReply (..)
  , ReplyAnswer (..)

    -- * The guard
  , guarded

    -- * Epochs
  , EpochReport (..)
  , EpochChange (..)
  , advanceRequestEpoch

    -- * Reading
  , ProviderDiagnostics (..)
  , requestDiagnostics
  ) where

import Control.Concurrent.STM (STM)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session (EpochChange (..))
import Hetoimasia.Scripting.Lua.Retention (RetirementState (..))
import Hetoimasia.Scripting.Lua.Provider.Serve (guarded)
import qualified Hetoimasia.Scripting.Lua.Provider.Serve as Serve
import Hetoimasia.Scripting.Lua.Provider.State (EpochReport (..), diagnosticsSTM)
import Hetoimasia.Scripting.Lua.Provider.Types
import Hetoimasia.Scripting.Lua.Scheduled.Types (Control (controlProvider), ScheduledEndpoint (ScheduledEndpoint))

-- | Replace the generation of an owner's records (P-9), at a point of the application's
-- choosing: every outstanding request settles, once, as cancelled by the epoch change, and
-- its script can take that; a settled result nobody had taken is discarded with the epoch's
-- records, as the model discards it; the ticks the requests held are let go; and the
-- providers whose work that was are to be told, once. The accounting for work that is not over
-- is retained, under the identities it was issued under, so a late reply retires it without
-- reaching anything the new epoch issues. A cancellation nobody has taken is still a place
-- held, charged to the owner's bound until its script takes it.
--
-- The epoch is the request service's: instances and tasks are not invalidated by it. Answers
-- what was invalidated, or 'Nothing' for an owner with no request service, or one that has
-- exited. The providers are told by the owner, at its next boundary, as for every other
-- withdrawal of interest, so a provider that raises when told is a failure of the host under
-- the owner's policy, first as the owner's failure and the others whole as cleanup evidence;
-- nothing is raised on the application's thread.
advanceRequestEpoch ∷ ScheduledEndpoint → IO (Maybe EpochReport)
advanceRequestEpoch (ScheduledEndpoint control) = case controlProvider control of
  Nothing → pure Nothing
  Just service → Serve.advanceRequestEpoch service

-- | A reading of the owner's request service in one transaction, or 'Nothing' for an owner
-- with none.
requestDiagnostics ∷ ScheduledEndpoint → STM (Maybe ProviderDiagnostics)
requestDiagnostics (ScheduledEndpoint control) = traverse diagnosticsSTM (controlProvider control)
