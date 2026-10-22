-- | The opt-in admission of an instance's requests, and what an adapter reads of one (D-52 to
-- D-54, D-67, LFE-7).
--
-- "Hetoimasia.Scripting.Lua.Request" starts a request the generic way: when every place is held
-- it refuses the call, and a script that made it is failed. This module is the other way. A
-- binding's author who wants a request admitted atomically asks 'startAdmitted' with an
-- 'Admission', and gets 'Started' or 'Unavailable': the second is an answer that nothing was
-- accepted, which the binding hands the script as data (a busy answer), not as an error and not as
-- the instance's failure. Nothing here changes the generic requests, the owner's defaults or the
-- behaviour of an owner whose bindings do not use it.
--
-- = One transaction
--
-- 'startAdmitted' reserves, in one transaction, and only then asks the provider anything:
--
-- * the request's record and its terminal result's storage in the protocol model;
-- * a place in the instance's accepted, unretired requests, and in the VM's;
-- * a result lease in the instance's lease scope, when the admission asks for one;
-- * every 'Credit' the provider declared;
-- * for an owner on logical time, the position its settlement is due at: the tick the instance
--   is at (0 in @init@) plus the offset, and the request number as the sequence, both fixed here,
--   once, and checked against the ceiling the admission carries; and the owner's hold on that tick.
--
-- A bank without room, or a permanent refusal, ends the transaction before anything stays
-- reserved: there is no handle, no hold, no credit and no lease slot, the provider is asked
-- nothing, and the instance has no latent failure. A later call may succeed. That is the whole of
-- how the answer is made: the capacity is not queried and then used, and no exception is
-- caught and relabelled.
--
-- = The banks, and when they are given back
--
-- Per-instance and per-VM places are counted by the service's ledger, which holds one entry for
-- each accepted request from its admission until /both/ its result has been taken or discarded
-- /and/ its provider's work has been accounted retired by the owner. Losing the handle, waiting,
-- cancelling and a provider's reply do none of that on their own.
--
-- A freed place is visible to admission only where it is accounted, never from a provider's thread:
--
-- * take-after-retirement: the work has been reaped by an owner boundary already, so the take
--   that discards the result releases the places at once, on the owner's thread, and the next
--   admission in the same invocation sees them;
-- * retirement-after-take: the work completes on a provider's thread, and the places are
--   released by the owner's next boundary that reaps it, not by the completion.
--
-- A 'Credit' is returned at the same point, with 'CreditSettled'; an admission taken back before the
-- provider was handed anything returns it with 'CreditUnused'. A credit that
-- 'creditTransfers' is the resource's, once the resource was adopted: the provider's own
-- release of the resource gives it back. A reserved lease that was never used is discharged
-- as soon as the provider's work is retired and the request has settled or gone; one that was
-- adopted is the instance's live resource, released with the instance, and taking the request
-- does not release it.
--
-- = Settlement
--
-- The settlement is the terminal result in the shape the service declared ('Terminal'):
-- a success carrying the provider's value (composed with the adopted lease's handle by
-- 'admitCombine'), an expected failure with the code its service supplies, or a cancellation. A
-- reply that is none of these is a provider defect ('ReplyDefective'): it fails the owner at its
-- next boundary, whatever the request's requirement, and settles nothing.
--
-- On an owner on logical time a reply that arrives before its position is held and invisible, a
-- late one holds the tick, and a cancel before the position wins. On an owner on elapsed time the
-- first settlement wins. A required request's expected failure, at its /eligible/ settlement,
-- latches the failure of its instance whether the script ever reads it, and the owner applies it at
-- its next safe boundary; nothing a script does afterwards (catching an error, cancelling late)
-- clears it.
module Hetoimasia.Scripting.Lua.Admission
  ( -- * What a request asks
    Admission (..)
  , admission
  , Necessity (..)
  , Credit (..)
  , CreditEnd (..)
  , ExpectedFailure (..)
  , Adoption (..)
  , Retirements

    -- * Asking
  , Started (..)
  , Bank (..)
  , renderBank
  , startAdmitted
  , preflightAdmission
  , CallerPhase (..)
  , callerPhase

    -- * Settling
  , Terminal (..)
  , Taken (..)
  , readyAdmitted
  , takeAdmitted
  , CancelResult (..)
  , cancelAdmitted

    -- * Handles
  , RequestHandles
  , RequestHandlesRefused (..)
  , newRequestHandles
  , admittedHandleType

    -- * What goes wrong
  , AdmissionDefect (..)
  , ProviderDefect (..)
  ) where

import Control.Concurrent.STM (atomically)
import Control.Exception (mask, mask_, rethrowIO)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Word (Word64)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (operation, throwFailure)
import Hetoimasia.Scripting.Lua.Instance.Types (InstancePhase (..))
import Hetoimasia.Scripting.Lua.Lease.State (Retirements)
import Hetoimasia.Scripting.Lua.Provider.Call
import Hetoimasia.Scripting.Lua.Provider.Serve (guarded, raiseAmong, tellProviders)
import Hetoimasia.Scripting.Lua.Provider.State
import Hetoimasia.Scripting.Lua.Provider.Types
import Hetoimasia.Scripting.Lua.Registration (CapabilityType, RequestContext, capabilityType)
import Hetoimasia.Scripting.Lua.Runtime.Shared (runtimeComponent)
import Hetoimasia.Scripting.Lua.Value (Value)

-- | What asking came to.
data Started
  = -- | Accepted: every bank reserved and the provider handed the request. The handle is the
    -- script's to be given.
    Started !RequestHandle
  | -- | Nothing was accepted: this bank had no room. No handle, no provider action, no partial
    -- reservation, no failure of the instance. Hand the script a busy answer.
    Unavailable !Bank
  deriving (Eq, Show)

-- | Start a request of this endpoint with the opt-in admission, and give the binding its
-- handle, or the answer that no bank had room.
--
-- The provider is handed the arguments the binding has checked, a 'Completion' and the
-- request's 'RequestInfo' (with the admission's metadata), after the transaction has committed.
-- @afterCompletion@ is what the request's work needs disposed of, once the provider has proved
-- its work over, on the owner's thread and uninterruptibly, and never if its retirement failed.
--
-- A permanent refusal (the owner or instance is not taking requests, a task asked, an offset on an
-- owner on arrival, a tick or number past the ceiling) is a fault of the call, raised before
-- anything was reserved: a binding that wants it as an ordinary Lua error asks 'preflightAdmission'
-- in its precondition, which decides the same facts and reserves nothing. An endpoint the grant
-- does not name, a provider that raises when handed the request, a bank that raises, and a
-- counter the engine cannot advance are failures of the host: the first of these before
-- anything was reserved, and the second with the admission taken back.
startAdmitted ∷ HasCallStack ⇒ RequestContext → Admission → Text → [Value] → IO () → IO Started
startAdmitted context ask name arguments afterCompletion = do
  service ← serviceOf context
  endpoint ← case Map.lookup name (psEndpoints service) of
    Just found → pure found
    Nothing → throwFailure runtimeComponent (operation "start-request") [("endpoint", name)] (userError "the grant names no such endpoint")
  requester ← requesterIn service
  mask $ \restore → do
    outcome ← atomically (admitOptIn service requester endpoint ask)
    case outcome of
      OptInRefused why → refuse why
      OptInBusy bank → pure (Unavailable bank)
      OptInAccepted found → do
        let info =
              (infoFor service requester name (admittedNumber found))
                { infoNecessity = Just (admitNecessity ask)
                , infoSource = Just (admitSource ask)
                , infoOffset = admitOffset ask
                , infoDue = admittedDue found
                }
            completion = Completion $ \reply → do
              checked ← checkReplyFor (psLimits service) (endpointResult endpoint) (Just ask) reply
              atomically (replyTo service (admittedIdentity found) checked)
        handed ← guarded (restore (endpointSubmit endpoint (Submission arguments completion info)))
        case handed of
          Left failure → do
            atomically (withdrawAdmission service (admittedIdentity found))
            rethrowIO failure
          Right provided → do
            atomically (commitSubmitted service (admittedIdentity found) provided [afterCompletion])
            -- A request revoked while the provider was being handed it has interest to withdraw
            -- now that there is a provider to tell.
            raiseAmong "lua request cancel" =<< tellProviders service
            pure (Started (RequestHandle (admittedNumber found)))

-- | The permanent reason an opt-in request would be refused if it were asked now, as the
-- bounded text a precondition refuses with, or 'Nothing'. It reads engine-owned state in one
-- transaction and reserves nothing. It never says a bank is full: that is a fact which can change
-- before the request is asked, and its answer is 'Unavailable'.
preflightAdmission ∷ HasCallStack ⇒ RequestContext → Admission → IO (Maybe Text)
preflightAdmission context ask = do
  service ← serviceOf context
  caller ← atomically (callerOf service)
  case requesterOf caller of
    Nothing → pure (Just (renderRequestRefusal NoRequester))
    Just requester → fmap renderRequestRefusal <$> atomically (preflightOptIn service requester ask)

-- | Where the instance whose code is running is in its life.
data CallerPhase
  = -- | Its @init@ is running: finite, and no wait may be made.
    CallerInitializing
  | -- | Initialized and serving: its updates and callbacks may wait.
    CallerServing
  | -- | Being ended, or ended: its @shutdown@ is running or has run. No request starts and no wait
    -- may be made.
    CallerEnding
  deriving (Eq, Show)

-- | The phase of the instance whose code is running, or 'Nothing' when none is (a task's segment,
-- or no Lua of an instance): what a precondition reads to refuse a wait where it is not allowed.
callerPhase ∷ HasCallStack ⇒ RequestContext → IO (Maybe CallerPhase)
callerPhase context = do
  service ← serviceOf context
  phase ← atomically (callerPhaseOf service)
  pure $ phase >>= \found → Just $ case found of
    Initializing → CallerInitializing
    Active → CallerServing
    Paused → CallerServing
    _ → CallerEnding

-- | What taking a request found.
data Taken
  = -- | Not settled. Nothing was taken.
    TakenPending
  | -- | The terminal result, taken once. The handle names nothing now.
    Taken !Terminal
  deriving (Show)

-- | Whether the request has settled, without consuming anything. A handle that is another
-- requester's or names nothing is refused as a fault of the call.
readyAdmitted ∷ HasCallStack ⇒ RequestContext → Word64 → IO Bool
readyAdmitted context key = do
  service ← serviceOf context
  requester ← requesterIn service
  answer ← atomically (readyOf service requester key)
  either refuse pure answer

-- | Take the terminal result, once, or find it pending and take nothing.
takeAdmitted ∷ HasCallStack ⇒ RequestContext → Word64 → IO Taken
takeAdmitted context key = do
  service ← serviceOf context
  requester ← requesterIn service
  answer ← atomically (takeTerminal service requester key)
  case answer of
    TakeTerminalRefused why → refuse why
    TakeTerminalPending → pure TakenPending
    TakeTerminal terminal → pure (Taken terminal)

-- | What cancelling came to.
data CancelResult
  = -- | This call won the settlement: the request is cancelled, and its cancellation is a
    -- terminal result to take.
    CancelWon
  | -- | The request had settled already and keeps its settlement.
    CancelAlreadySettled
  deriving (Eq, Show)

-- | Cancel a request: the cancel wins when the request has not settled (on logical time, before its
-- position, whatever the provider has done), and withdraws interest; otherwise the settlement
-- stands, and a failure that settled first is not erased.
cancelAdmitted ∷ HasCallStack ⇒ RequestContext → Word64 → IO CancelResult
cancelAdmitted context key = do
  service ← serviceOf context
  requester ← requesterIn service
  answer ← atomically (cancelOf service requester key)
  case answer of
    CancelRefused why → refuse why
    CancelTooLate → pure CancelAlreadySettled
    Cancelled → do
      -- The claim and the raising of what the provider raised are one masked step.
      mask_ (raiseAmong "lua request cancel" =<< tellProviders service)
      pure CancelWon

-- | A capability type for the handles of opt-in requests, named, whose liveness is the registry's:
-- a handle is live for the instance that holds it while its request exists. A handle that is
-- another instance's, whose result was taken or discarded, or that was never issued is refused by
-- the value boundary before any action, as a handle that has ended. The registry is the one the
-- owner was given ('Hetoimasia.Scripting.Lua.Scheduled.scheduledRequestHandles').
admittedHandleType ∷ RequestHandles → Text → CapabilityType
admittedHandleType handles name = capabilityType name (handleLive handles)
