-- | Trusted Lua VM owners under runtime supervision.
--
-- One owner is one supervised worker. An application creates any number of
-- them at runtime and retires them while others run; each has its own
-- configuration, its own bindings and policy, and its own 'WorkerPolicy', and
-- none shares a VM, a queue or a fate with another. There is no pool and no
-- scheduler across them. This module composes the host library
-- ("Hetoimasia.Scripting.Lua.Owner") with the runtime's supervision
-- ("Hetoimasia.Runtime.Supervision"); it adds no thread, supervisor or
-- timer of its own, and it depends on nothing of GLFW, Vulkan, the console or
-- any game.
--
-- = Creation and readiness
--
-- 'startLuaOwner' validates the configuration's bounds, issues the owner's
-- identity and starts exactly one worker through 'startSupervised'. The
-- worker's startup allocates only the owner's bounded queue and counters. The
-- VM is constructed, its registered bindings installed, its initial chunks run
-- and its configured modules loaded inside 'withVmOwner' on the worker's own
-- thread, which is the VM's execution owner. Only then does the body publish
-- readiness and open admission, and only then does creation return an
-- endpoint.
--
-- Readiness is awaited through 'awaitSupervised', composed with the worker's
-- terminal status, never through the startup acknowledgement, which means only
-- that the worker's startup finished. A failure of initialization therefore ends
-- creation under the owner's policy: a required owner's is raised as any
-- worker's failure is, and an optional one the policy recognizes is
-- 'OwnerUnavailable'. Nothing is left waiting. At handoff the adapter checks
-- that admission is still live. A creator whose wait is abandoned, cancelled
-- or woken by another worker's fatal failure, requests the owner's stop; the
-- worker group still owns the worker and drains it, and no helper outlives the
-- creation.
--
-- = Identity
--
-- Every owner is issued an 'OwnerId' by the 'LuaRuntime' that created it, once
-- and in order, and an identity is never issued again, not after the owner it
-- named is retired. The runtime boundary an identity is unique within is the
-- 'LuaRuntime' value: make one for each 'withSupervision' invocation. The
-- identity travels with the endpoint, with every settlement and with the exit
-- record, beside the application's own label ('vmOwnerName'). Neither confers
-- trust or a grant: an owner's authority is exactly the policy ('vmPolicy') it
-- was configured with.
--
-- = Submitting calls
--
-- An endpoint submits a call to an entry point of a module the owner loaded at
-- initialization, named by its 'ModuleRef', with values. It is usable from any
-- thread, including a binding's action on this owner or another, and never
-- needs the 'RuntimeControl'.
--
-- Submission never blocks. It answers 'CallAccepted' with a ticket,
-- 'CallFull' or 'CallClosed', the answers of the foundation's channel, and
-- a full or closed answer changes nothing. Closed takes precedence. Full means
-- either bound is reached: 'boundQueuedCalls' is how many accepted calls may
-- wait for the owner's thread, and 'boundResults' how many results may be
-- reserved. The reservation is taken, with the enqueue, as the call is
-- accepted, so a call never runs without a place for its result; it is held
-- while the call waits, runs, and sits settled but unobserved. Both bounds are
-- validated when the owner is created, a bound below one is refused, every
-- violation named, and the refusal ends creation before any worker starts or
-- VM is built.
--
-- The payload is prepared on the producer's thread, before publication, as
-- the foundation's messaging requires: 'prepareCall' evaluates the arguments
-- completely there, so a failure nested inside a lazy value is the producer's
-- own, and the owner's thread is handed nothing unevaluated. It checks them
-- against the owner's value limits as it goes, stopping at the first limit, so
-- an oversized or endless argument list costs no more to refuse than a small
-- one, and keeps none of it: a call whose arguments were over the bound is
-- accepted like any other, carries only the rule they broke, and settles in its
-- turn as the 'ValueRefused' fault the argument check raises. Preparing is
-- separate from submitting, so the three-way answer needs no evaluation.
--
-- = Settlement
--
-- Calls run one at a time, to completion, on the owner's thread, in the order
-- they were accepted, through 'callEntry'. Each accepted call settles exactly
-- once:
--
-- * 'CallReturned', with the entry point's 'CallResult';
-- * 'CallFaulted', with a fault of the call returned as data: a refused value, a
--   script error (a memory failure included), a call to a binding that is not
--   yet supported, a missing entry point, or a module the owner did not load.
--   The owner goes on serving the next call, and this is never a worker failure;
-- * 'CallDiscarded', when the owner exits before the call settles, recording
--   how it exited and whether the call had started.
--
-- No path settles a call twice, loses an accepted call or lets a late result
-- overwrite a settlement, including a submission that races stop, failure or
-- cancellation.
--
-- = Observing results
--
-- A caller reads a settlement without blocking ('pollCall'), or waits for it.
-- Reading a settlement is observing it. The first read that finds one gives the
-- reservation back, and every later read answers the same settlement and gives
-- nothing back, however many threads read it. 'forgetCall' withdraws interest:
-- a settled call gives its reservation back at once and an unsettled one when it
-- settles, and the ticket still reads its settlement. A ticket nobody observes or
-- forgets keeps its reservation, which is what bounds the unobserved results.
--
-- The application thread waits through 'awaitCall', composed with
-- 'awaitSupervised', so an owner's terminal outcome wakes it. Any other thread
-- may use 'waitCall'. Neither is a transaction, and nothing here hands a
-- callback a primitive to wait with.
--
-- = Waiting from a callback
--
-- A thread that is running a binding's action or any other Lua callback, of
-- any VM, may submit calls but may not wait for a reply, its own owner's
-- included: it would be a synchronous call into a thread that may be waiting for
-- it. Such a wait is refused at once, when it executes, with
-- 'CallbackWaitRefused' naming the operation, never blocking, and a wait action
-- built earlier outside the callback is refused the same way. Creating an owner
-- waits for readiness and is refused likewise.
--
-- = Host failures
--
-- A Haskell failure raised by a binding's action, or by the application's
-- liveness check, or any other exception escaping the owner, including one
-- escaping the close, ends that owner's worker. It is the worker's primary
-- outcome with its own type and context, and the VM's close failures are
-- retained beside it as cleanup evidence. It is not converted and not retried,
-- and no caller receives it. What follows is the owner's 'WorkerPolicy': an
-- optional owner whose classifier recognizes the failure, and whose cleanup
-- succeeded, becomes 'WorkerUnavailable' and every other owner goes on; any
-- other outcome, a retained cleanup failure included, is fatal as for any
-- worker. A failure is a host failure by where it was raised, not by its type:
-- a 'BoundaryFault' or 'LuaFault' thrown by a binding's action is one.
--
-- = Stop and retire
--
-- Stopping an owner ('retireOwner', 'stopSupervised', or the boundary
-- closing) closes admission first, so later submissions answer closed. It
-- discards every queued call, each settling as discarded, not started; it lets
-- the in-flight call return with its own settlement; and then 'withVmOwner'
-- closes the VM on the worker's thread. The same discarding happens on a
-- failure or cancellation, with the way the owner exited recorded, and
-- admission closes before the VM begins to close. The in-flight call of a
-- failed or cancelled owner is discarded as started: Lua or a binding may have
-- run, and nothing says its effects can be ignored.
--
-- The 'ExitRecord' counts the discarded calls, started and not started
-- separately, and names the owner's identity and label. It carries no
-- cleanup evidence, which supervision does. A stuck in-flight call keeps the
-- worker, its VM, the registration and the binding dependencies live; nothing
-- is detached and the boundary's drain still owns it.
module Hetoimasia.Scripting.Lua.Runtime
  ( -- * The runtime boundary
    LuaRuntime
  , newLuaRuntime

    -- * Creating owners
  , OwnerSpec (..)
  , OwnerStart (..)
  , startLuaOwner
  , CallBounds (..)
  , BoundViolation (..)
  , OwnerBoundsRefused (..)

    -- * Identity
  , OwnerId
  , ownerSequence

    -- * An owner
  , LuaOwner
  , ownerIdentity
  , ownerEndpoint
  , ownerSupervised
  , retireOwner
  , cancelOwner
  , ownerStatus
  , ownerExitRecord

    -- * Submitting calls
  , OwnerEndpoint
  , endpointOwner
  , endpointLabel
  , PreparedCall
  , prepareCall
  , submitPrepared
  , submitCall
  , Submission (..)

    -- * Observing results
  , CallTicket
  , ticketOwner
  , pollCall
  , waitCall
  , awaitCall
  , forgetCall

    -- * What a call settled as
  , Settlement (..)
  , Outcome (..)
  , CallFault (..)
  , callFaultEffect
  , Discard (..)
  , ExitKind (..)
  , Progress (..)
  , ExitRecord (..)

    -- * Refused waits
  , CallbackWaitRefused (..)
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, orElse, readTVar, retry)
import Control.Exception (ExceptionWithContext, SomeException, evaluate, mask_, onException)
import Control.Monad (when)
import Data.Foldable (toList)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Unique (Unique, newUnique)
import Data.Word (Word64)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure)
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Hetoimasia.Foundation.Messaging.Channel (SendResult (Accepted, Closed, Full))
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Resource (allocResource)
import Hetoimasia.Foundation.Worker (stopRequested, workerDefinition)
import Hetoimasia.Runtime.Supervision
  ( RuntimeControl
  , SupervisedStart (WorkerStartRejected, WorkerStartUnavailable, WorkerStarted)
  , SupervisedWorker
  , WorkerPolicy
  , WorkerStatus (WorkerLive, WorkerUnavailable)
  , awaitSupervised
  , cancelSupervised
  , startSupervised
  , stopSupervised
  , workerStatus
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits
  ( LimitName (QueuedAdmissions, RetainedResults)
  , LimitViolation (NonPositiveLimit)
  , Limits (..)
  , Quanta (Quanta)
  , Quantum (Quantum)
  , validateLimits
  )
import Hetoimasia.Scripting.Lua.Internal.Value (checkLimits)
import Hetoimasia.Scripting.Lua.Internal.Vm (runningLuaCallback)
import Hetoimasia.Scripting.Lua.Owner (ModuleRef (moduleRefName, moduleRefVersion), VmConfig (vmOwnerName, vmValueLimits))
import Hetoimasia.Scripting.Lua.Runtime.Admission
  ( admit
  , admitting
  , forgetSlot
  , newControl
  , newSlot
  , observeSlot
  , shutAndDiscard
  )
import Hetoimasia.Scripting.Lua.Runtime.Dispatch (runOwner)
import Hetoimasia.Scripting.Lua.Runtime.Types
import Hetoimasia.Scripting.Lua.Value (Value)
import Hetoimasia.Foundation.Messaging.Payload (Prepared)

-- | The runtime boundary owners are created in: the supervision control they
-- are started under, and the identities issued so far.
--
-- Make one for each 'withSupervision' invocation. It belongs to the
-- application thread, as the 'RuntimeControl' it holds does.
data LuaRuntime = LuaRuntime
  { runtimeControl ∷ !RuntimeControl
  , runtimeScope ∷ !Unique
  , runtimeIssued ∷ !(IORef Word64)
  }

-- | A runtime boundary over a supervision control.
newLuaRuntime ∷ RuntimeControl → IO LuaRuntime
newLuaRuntime control = LuaRuntime control <$> newUnique <*> newIORef 0

-- | The next identity of a runtime, never an earlier one.
issueOwnerId ∷ LuaRuntime → IO OwnerId
issueOwnerId runtime =
  OwnerId (runtimeScope runtime) <$> atomicModifyIORef' (runtimeIssued runtime) (\issued → (issued + 1, issued + 1))

-- | What one owner is created from.
data OwnerSpec = OwnerSpec
  { ownerVm ∷ VmConfig
    -- ^ The host configuration: libraries, initial chunks, label, registration,
    -- policy, value limits and modules. The adapter grants nothing beyond its
    -- policy.
  , ownerPolicy ∷ WorkerPolicy
    -- ^ What supervision does when the owner's worker ends.
  , ownerBounds ∷ CallBounds
  }

-- | How creating an owner ended.
data OwnerStart
  = -- | Ready, admitting, and usable from now on.
    OwnerStarted !LuaOwner
  | -- | An optional owner failed with a recognized failure before it could be
    -- handed out. Its status is committed, and the run continues without it.
    OwnerUnavailable !(ExceptionWithContext SomeException)
  | -- | The boundary had closed registration. Nothing was forked.
    OwnerRejected
  | -- | The owner ended without failing before creation could hand it out.
    OwnerEnded

-- | A ready, supervised owner.
data LuaOwner = LuaOwner
  { ownerWorker ∷ !(SupervisedWorker ())
  , ownerControl ∷ !Control
  }

runtimeComponent ∷ Component
runtimeComponent = unsafeComponent "scripting.lua.runtime"

startOperation ∷ Operation
startOperation = operation "start-lua-owner"

-- | Check both bounds, naming every one below one.
checkBounds ∷ CallBounds → Either [BoundViolation] ()
checkBounds bounds = case validateLimits limits of
  Right _ → Right ()
  Left violations → Left [violation | NonPositiveLimit name value ← toList violations, Just violation ← [named name value]]
  where
    -- The protocol model's caps cover a session the adapter does not run yet;
    -- the two this slice uses are the queue of admissions and the retained
    -- results, and the rest are held at the smallest valid value.
    limits =
      Limits
        { maxActiveTasks = 1
        , maxQueuedAdmissions = boundQueuedCalls bounds
        , maxSubscriptions = 1
        , maxSubscriptionQueue = 1
        , maxOutstandingRequests = 1
        , maxPayloadBytes = 1
        , maxRetainedResults = boundResults bounds
        , limitQuanta = Quanta (Quantum 1) (Quantum 1) (Quantum 1)
        }
    named QueuedAdmissions value = Just (QueuedCallsBelowOne value)
    named RetainedResults value = Just (ResultsBelowOne value)
    named _ _ = Nothing

-- | Refuse, at once, a wait asked from a thread that is running a Lua callback.
refuseCallbackWait ∷ HasCallStack ⇒ Text → IO ()
refuseCallbackWait name = do
  inside ← runningLuaCallback
  when inside $
    throwFailure runtimeComponent (operation name) [] (CallbackWaitRefused name)

-- | Create one owner: one supervised worker running one VM.
--
-- Raises 'OwnerBoundsRefused', before anything starts, for a bound below one,
-- and 'CallbackWaitRefused' from a thread running a Lua callback. A failure
-- of initialization, a cancellation of the creator and another worker's fatal
-- outcome propagate as supervision decides; the module header says how an
-- abandoned creation is wound down. See 'OwnerStart' for the other endings.
startLuaOwner ∷ HasCallStack ⇒ LuaRuntime → OwnerSpec → IO OwnerStart
startLuaOwner runtime spec = do
  refuseCallbackWait "start-lua-owner"
  case checkBounds (ownerBounds spec) of
    Left violations → throwFailure runtimeComponent startOperation [] (OwnerBoundsRefused violations)
    Right () → pure ()
  owner ← issueOwnerId runtime
  handoff ← newTVarIO Nothing
  let config = ownerVm spec
      label = vmOwnerName config
      definition =
        workerDefinition
          ("lua owner " <> label <> " #" <> Text.pack (show (ownerSequence owner)))
          ( \token →
              allocResource
                (newControl owner label (vmValueLimits config) (ownerBounds spec) (stopRequested token))
                -- The last word on what an exit left, after the run action:
                -- everything that already ended the owner has done this.
                (\control → atomically (shutAndDiscard control ExitFailed))
          )
          (\token control → runOwner token control handoff config)
  started ← startSupervised (runtimeControl runtime) (ownerPolicy spec) definition
  case started of
    WorkerStartRejected → pure OwnerRejected
    WorkerStartUnavailable _ failure → pure (OwnerUnavailable failure)
    WorkerStarted worker → do
      -- A creator that stops waiting does not orphan the owner.
      ready ← awaitSupervised (runtimeControl runtime) (readiness handoff worker) `onException` stopSupervised worker
      case ready of
        Just control → do
          live ← atomically (admitting control)
          if live then pure (OwnerStarted (LuaOwner worker control)) else ended worker
        Nothing → ended worker
  where
    ended worker =
      atomically (workerStatus worker) >>= \case
        WorkerUnavailable failure → pure (OwnerUnavailable failure)
        _ → pure OwnerEnded

-- | Ready, or the worker's terminal status: whichever comes first, so that a
-- failed initializer never leaves the wait hanging.
readiness ∷ TVar (Maybe a) → SupervisedWorker () → STM (Maybe a)
readiness handoff worker =
  (readTVar handoff >>= maybe retry (pure . Just))
    `orElse` ( workerStatus worker >>= \case
                 WorkerLive → retry
                 _ → pure Nothing
             )

-- | The owner's identity.
ownerIdentity ∷ LuaOwner → OwnerId
ownerIdentity = controlOwner . ownerControl

-- | Where calls are submitted.
ownerEndpoint ∷ LuaOwner → OwnerEndpoint
ownerEndpoint = OwnerEndpoint . ownerControl

-- | The supervised worker, for what supervision offers: its status, raw
-- observation of its completion.
ownerSupervised ∷ LuaOwner → SupervisedWorker ()
ownerSupervised = ownerWorker

-- | Retire the owner: ask its worker to stop, recording that its owner asked.
-- It returns at once; the worker closes admission, discards what is queued, lets
-- the in-flight call return, and closes the VM.
retireOwner ∷ LuaOwner → IO ()
retireOwner = stopSupervised . ownerWorker

-- | Request the owner's cancellation, recording that its owner asked.
cancelOwner ∷ LuaOwner → IO ()
cancelOwner = cancelSupervised . ownerWorker

-- | What supervision has decided about the owner's worker.
ownerStatus ∷ LuaOwner → STM WorkerStatus
ownerStatus = workerStatus . ownerWorker

-- | What the owner's exit discarded: 'Nothing' until it has exited.
ownerExitRecord ∷ LuaOwner → STM (Maybe ExitRecord)
ownerExitRecord = readTVar . controlExit . ownerControl

-- | Where an owner's calls are submitted. Any thread may hold and use it.
newtype OwnerEndpoint = OwnerEndpoint Control

-- | The identity of the owner an endpoint submits to.
endpointOwner ∷ OwnerEndpoint → OwnerId
endpointOwner (OwnerEndpoint control) = controlOwner control

-- | The application's label of the owner an endpoint submits to.
endpointLabel ∷ OwnerEndpoint → Text
endpointLabel (OwnerEndpoint control) = controlLabel control

-- | A call prepared for one owner on the producer's thread.
data PreparedCall = PreparedCall !Control !ModuleRef !Text !(Prepared Payload)

instance Show PreparedCall where
  show (PreparedCall control ref entry _) =
    "call of " <> show (moduleRefName ref, moduleRefVersion ref) <> " " <> show entry <> " prepared for " <> show (controlOwner control)

-- | Prepare a call: evaluate its arguments completely and check them against
-- the owner's value limits, on this thread.
--
-- A failure nested in a lazy argument is raised here, with its own type and
-- context. Arguments over the limits are neither kept nor refused here: the
-- prepared call carries the rule they broke and settles as that fault in its
-- turn.
prepareCall ∷ OwnerEndpoint → ModuleRef → Text → [Value] → IO PreparedCall
prepareCall (OwnerEndpoint control) ref entry arguments = do
  within ← evaluate (checkLimits (controlLimits control) arguments)
  payload ← prepare $ case within of
    Right () → WithinBounds arguments
    Left rule → OverBound rule
  pure (PreparedCall control ref entry payload)

-- | What submitting a call answered.
data Submission
  = -- | Accepted, with the ticket its settlement is read through.
    CallAccepted !CallTicket
  | -- | A bound is reached. Nothing changed.
    CallFull
  | -- | The owner has stopped admitting. Nothing changed.
    CallClosed
  deriving (Show)

-- | Submit a prepared call, without waiting.
submitPrepared ∷ PreparedCall → IO Submission
submitPrepared (PreparedCall control ref entry payload) = do
  slot ← newSlot
  queued ← prepare (QueuedCall ref entry payload slot)
  -- Nothing is interruptible between the commit and the answer, so an accepted
  -- call is never one whose ticket was never made.
  mask_ $
    atomically (admit control queued) >>= \case
      Accepted → pure (CallAccepted (CallTicket control slot))
      Full → pure CallFull
      Closed → pure CallClosed

-- | Prepare and submit. The preparation can raise what 'prepareCall' does.
submitCall ∷ OwnerEndpoint → ModuleRef → Text → [Value] → IO Submission
submitCall endpoint ref entry arguments = prepareCall endpoint ref entry arguments >>= submitPrepared

-- | The place an accepted call's settlement is read.
data CallTicket = CallTicket !Control !Slot

instance Show CallTicket where
  show (CallTicket control _) = "call ticket of " <> show (controlOwner control)

-- | The owner a ticket's call was accepted by.
ticketOwner ∷ CallTicket → OwnerId
ticketOwner (CallTicket control _) = controlOwner control

-- | The call's settlement if it has one, without waiting. Observes it.
pollCall ∷ CallTicket → IO (Maybe Settlement)
pollCall (CallTicket control slot) = atomically (observeSlot control slot)

-- | Wait for the call's settlement, on any thread but a Lua callback's.
--
-- Every accepted call settles, so this returns once the owner has run the call
-- or exited. Refused with 'CallbackWaitRefused' when asked from a Lua callback.
waitCall ∷ HasCallStack ⇒ CallTicket → IO Settlement
waitCall (CallTicket control slot) = do
  refuseCallbackWait "wait-call"
  atomically (observeSlot control slot >>= maybe retry pure)

-- | Wait for the call's settlement on the application thread, composed with
-- 'awaitSupervised': a worker's terminal outcome is handled first, so a fatal
-- one is raised here rather than waited out. Refused with 'CallbackWaitRefused'
-- when asked from a Lua callback.
awaitCall ∷ HasCallStack ⇒ RuntimeControl → CallTicket → IO Settlement
awaitCall supervision (CallTicket control slot) = do
  refuseCallbackWait "await-call"
  awaitSupervised supervision (observeSlot control slot >>= maybe retry pure)

-- | Withdraw interest in a call's result. See the module header.
forgetCall ∷ CallTicket → IO ()
forgetCall (CallTicket control slot) = atomically (forgetSlot control slot)
