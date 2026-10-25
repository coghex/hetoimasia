{-# LANGUAGE OverloadedStrings #-}

-- | The session coordinator (LFE-13): the composition of one or two roles' VMs into one session, how
-- they start, advance, fail and stop together.
--
-- = What it does
--
-- 'runSession' makes the session's lifecycle record first and hands its handle to the caller, then, on the calling
-- thread (the thread that owns the supervision control, because the driver's waits are supervised
-- ones):
--
-- 1. checks, before any Lua, what can be impossible (the first logical deadline on the clock);
-- 2. builds each selected role's VM, registering every component with the lifecycle record in the step that
--    acquires it: a module coordinator over the session's pool, a data service, the facade, and a supervised
--    scheduled owner that hosts instances;
-- 3. evaluates each selected entry and its imports in its own VM, without running either root;
-- 4. admits each role's root instance (and the harness's second, where a composition asks for one).
--    The owner constructs and validates the behavior, and, at the point its @init@ would begin, a hook
--    parks the owner at the /dispatch gate/ until every first instance has been validated and admission
--    is complete: no root's @init@ is dispatched before every selected entry, export, hook and cadence
--    has been validated. A failure or stop before that aborts the gate, and a parked owner ends without
--    running its @init@;
-- 5. drives the session: observes the @init@s succeed, opens the /start gate/ when every selected role's
--    has (a one-role session needs only its own), and, for a gameplay role, grants real-time ticks of
--    exactly the manifest's duration, each followed by the owner's own accounting, until the session
--    ends; and
-- 6. returns, only once every role has actually retired, the session's outcome.
--
-- = The teardown protocol (D-82)
--
-- There is one protocol for every way out, and it does not depend on which scope an exception was caught in.
--
-- * /Own the unwind before exposing anything./ The outer masked continuation is installed before the handle is
--   given to the caller, before any diagnostic or clock and before any construction. Every acquired component is
--   registered with the lifecycle record in the same masked step that acquires it, before any probe, callback or
--   further acquisition.
-- * /Stop everything, then wait./ A normal or exceptional exit first commits the closure of the whole session (or of
--   the logical role, for an ordinary logical failure after boot), and then requests the stop of every constructed
--   owner and the close of its coordinator, in one pass of finite non-waiting primitives, before anything waits
--   for anything. The pass is repeated for an owner that is constructed late and after a new fatal entry widens
--   the set.
-- * /Observe, account, drain, release, publish./ Each role in turn, as its owner's raw completion arrives (a slow role does
--   not hold back accounting a peer already terminal): the completion and every settlement are accounted in one
--   recovery commit; the coordinator's drain is proven; the role's registered finite releases are attempted once
--   each; and only then is the role published as retired, if nothing is outstanding and no release failed.
-- * /A recovery path only commits./ It runs no stop, no diagnostic, no clock, and no probe inside the commit;
--   probes sit beside it in protected boundary wrappers.
-- * /Diagnostics never gate the lifecycle./ No step of the driver, no stop pass and no step of the teardown calls the
--   session's logger: the diagnostics are data in the lifecycle record, and a writer of the session's own, a thread
--   it starts before anything else and ends last, is the only caller of the sink. A logger that holds a write holds
--   the writer and nothing else: a stop is handed, an owner's end is accounted, its drain proven, its releases run and
--   its retirement published while it is held, and the call returns. Nothing waits for the writer (D-87): once every
--   role has retired and every release has run, the writer is abandoned, cancelled and not waited for, and every
--   diagnostic it had not delivered is recorded in the outcome, as evidence and never as the session's failure. A sink
--   that raises, or whose write is cancelled, is evidence of the same kind.
-- * /Mask bookkeeping, not waits./ Every wait runs through the enclosing @restore@ with a handler installed; an
--   interruption is retained with its context, the pass repeated, and the wait resumed. No drain, probe, or arbitrary
--   backend wait sits inside an uninterruptible release.
--
-- = Who runs what
--
-- * The /application's thread/ (the caller) builds, validates, admits and drives. It is the only thread
--   that grants ticks, finalizes an owner that ended and marks a role retired. It writes no diagnostic: the session's
--   own writer does.
-- * Each /owner's thread/ runs the hooks the coordinator installs: the dispatch gate (it parks there),
--   and the callbacks that report an instance's failure. Both are brief, commit and hand off stops only, and never
--   wait for the application's thread except for the tracking that was masked to be quick.
-- * Any thread may ask for a stop, an interruption or the terminal failure latch ('requestStop',
-- 'latchTerminalFailure'). Each is one transaction on the state followed by the finite stop pass.
--
-- = The invariants
--
-- * /Admission is closed before the stop is issued./ Every stop and failure is one 'step' of the
--   state: it closes the roles' admission and owes the owners' stops, and only then are they asked.
-- * /Nothing escapes tracking./ An admission is intended before it is issued and tracked before the
--   instance may run: the owner parks the new instance's first hook, and its failure report waits, until
--   the application's thread has recorded it. A role does not retire while an intent is outstanding.
-- * /No gate reopens./ The start gate opens in the transaction that records the last selected @init@;
--   a stop or failure that comes first shuts it for good.
-- * /Retired is actual./ A role retires only when 'Hetoimasia.LuaEngine.Session.State.retirable' says so: its owner's
--   completion and settlements accounted, its coordinator drained, its registered releases attempted without
--   failing.
-- * /The first failure stays./ A role's failure latches once; later failures are accounted in the
--   engine report and cannot replace it.
--
-- = Where the policy lives
--
-- The transitions are pure ("Hetoimasia.LuaEngine.Session.State"); this module applies them, performs
-- the effects they owe and observes the world. It adds no scheduling: the cadence, the FIFO order,
-- the tick and the required-failure latch are the Lua host's.
module Hetoimasia.LuaEngine.Session.Run
  ( runSession
  , Session
  , sessionStatus
  , sessionOutcomeNow
  , sessionHistory
  , requestStop
  , latchTerminalFailure
  , sessionDiagnosticsEnded
  ) where

import Control.Concurrent (ThreadId, forkIO, forkIOWithUnmask, throwTo, yield)
import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , check
  , modifyTVar'
  , newTVarIO
  , orElse
  , readTVar
  , readTVarIO
  , retry
  , throwSTM
  , writeTVar
  )
import Control.Exception
  ( Exception (fromException, toException)
  , ExceptionWithContext (ExceptionWithContext)
  , MaskingState (MaskedUninterruptible)
  , SomeAsyncException
  , SomeException
  , asyncExceptionFromException
  , asyncExceptionToException
  , displayException
  , evaluate
  , finally
  , getMaskingState
  , mask
  , mask_
  , onException
  , rethrowIO
  , throwIO
  , tryWithContext
  , uninterruptibleMask_
  )
import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Control.Exception.Context (addExceptionAnnotation, getExceptionAnnotations)
import Control.Monad (forM, forM_, unless, void, when)
import Data.Unique (Unique, newUnique)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, isJust, listToMaybe, mapMaybe)
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Content.Identity (ContentKey, rootKeyBytes)
import Hetoimasia.Content.Inventory (inventoryRootKey)
import Hetoimasia.Foundation.Log (Component, logError, logInfo, unsafeComponent)
import Hetoimasia.Foundation.Resource
  ( CleanupFailureId
  , cleanupFailureException
  , cleanupFailureId
  , cleanupFailureLabel
  , cleanupFailuresInContext
  , composeCleanup
  , displayCleanupFailure
  )
import Hetoimasia.Foundation.Time (Duration, Instant, deadlineReached, readInstant)
import Hetoimasia.Foundation.Worker (Completion (..), awaitCompletion, workerId)
import qualified Hetoimasia.Foundation.Worker as Worker
import Hetoimasia.LuaEngine.Behavior (behaviorRequest)
import Hetoimasia.LuaEngine.Boot (Checkpoint (..))
import Hetoimasia.LuaEngine.Data (dataService, newByteBankFor)
import Hetoimasia.LuaEngine.Facade
  ( AdmissionState (..)
  , Declared (..)
  , EngineFailure (..)
  , FacadeEndpoints (..)
  , FacadeSpec (..)
  , InstanceIds
  , declareInstance
  , facadeInstanceConfig
  , facadeRefusedWait
  , facadeRequestEndpoints
  , forgetInstance
  , inventoryResolver
  , installFacade
  , newFacade
  , newInstanceIds
  )
import qualified Hetoimasia.LuaEngine.Facade as Facade
import Hetoimasia.LuaEngine.Manifest
  ( GameplayRole (..)
  , Manifest (..)
  , PresentationRole (..)
  , Role (..)
  , RoleSelection (..)
  )
import Hetoimasia.LuaEngine.Modules
  ( BootOutcome (..)
  , Coordinator
  , ModuleSpec (..)
  , attachLoader
  , awaitBoot
  , awaitDrained
  , bootModule
  , closeModuleCoordinator
  , coordinatorPlan
  , moduleIdentity
  , withModuleCoordinator
  )
import qualified Hetoimasia.LuaEngine.Modules as Modules
import Hetoimasia.LuaEngine.Profile
  ( CountLimit (InstancesPerVm, RequestsPerVm)
  , Count (Count)
  , countLimit
  )
import Hetoimasia.LuaEngine.Request (m1Requests, withM1Gate)
import Hetoimasia.LuaEngine.Session.Failure
import Hetoimasia.LuaEngine.Session.Harness
import Hetoimasia.LuaEngine.Session.Pacing
import Hetoimasia.LuaEngine.Session.State
import Hetoimasia.LuaEngine.Session.Timer (BackendRaised (..), Timer, backendOwner, clearTimerWake, disposeTimer, newTimer, syncTimer, timerWoken)
import Hetoimasia.LuaEngine.Session.Types
import Hetoimasia.Runtime.Supervision
  ( Disposition (Required)
  , Recognition (Unrecognized)
  , WorkerPolicy (..)
  , awaitSupervised
  , supervisedWorker
  )
import qualified Hetoimasia.Runtime.Supervision as Supervision
import Hetoimasia.Scripting.Lua.Admission (Credit (..), CreditRefused (..), newRequestHandles)
import Hetoimasia.Scripting.Lua.Instance
  ( Escalation (Isolate)
  , InstanceAdmission (..)
  , InstanceBounds (..)
  , InstanceConfig (..)
  , InstanceFailure (failureInstance)
  , InstanceId (..)
  , InstanceOutcome (..)
  , InstancePhase (..)
  , InstanceSettlement (..)
  , InstanceSnapshot (..)
  , InstanceTicket
  , ShutdownDisposition (..)
  , Termination (terminationShutdown)
  , admitBehaviorInstance
  , defaultInstanceConfig
  , inspectInstance
  , pollInstance
  , releaseHeldInstance
  )
import Hetoimasia.Scripting.Lua.Owner (LibraryProfile (LibraryProfileM1), VmConfig (vmInitialChunks, vmOwnerName), chunkName, newModulePhase, vmProfileConfig)
import Hetoimasia.Scripting.Lua.Provider (RequestGrant (..), RequestTiming (SettleAtAssignedTick, SettleOnArrival))
import Hetoimasia.Scripting.Lua.Scheduled
  ( AccountingWait (AccountingComplete, AccountingOwnerEnded)
  , GrantAnswer (GrantAccepted, GrantClosed, GrantFull, GrantNotPositive)
  , Quanta (..)
  , Quantum (..)
  , ScheduledEndpoint
  , ScheduledOwner
  , ScheduledSpec (..)
  , ScheduledStart (..)
  , SchedulerBounds (..)
  , ServiceClass (OrdinaryClass)
  , awaitScheduledAccounting
  , scheduledAccountingStep
  , unwatchScheduledAccounting
  , watchScheduledAccounting
  , cancelScheduled
  , grantScheduledStep
  , grantScheduledStepSTM
  , retireScheduled
  , scheduledEndpoint
  , scheduledLoaderEndpoint
  , scheduledSpec
  , scheduledSupervised
  , scheduledTick
  , startScheduledOwner
  , ticksOutstanding
  )

-- | The component the coordinator reports under, and its owners' supervision policy is reported under.
sessionComponent ∷ Component
sessionComponent = unsafeComponent "luaengine.session"

-- | An exception with the context it was caught with.
type Caught = ExceptionWithContext SomeException

isAsync ∷ Caught → Bool
isAsync (ExceptionWithContext _ exception) = isJust (fromException exception ∷ Maybe SomeAsyncException)

-- The commit ---------------------------------------------------------------------------------------------

-- | Commit an event in a transaction the caller composes: the registry changes and the facts that say what they
-- mean are one transaction. It does not retry and reads nothing outside the session's own cells.
commitSTM ∷ Session → Event → STM Answer
commitSTM session event = do
  current ← readTVar (sessionState session)
  let (next, found) = step event current
  writeTVar (sessionState session) next
  pure found

-- | The one masked, non-retrying commit: the pure 'step' changes everything the event means in one transaction, and
-- that is all. It runs no probe, no stop, no diagnostic, no clock and no queue, so a path that only commits
-- cannot be kept from the obligations that follow it by a blocked sink, a failing probe or a cancellation.
commit ∷ Session → Event → IO Answer
commit session = mask_ . atomically . commitSTM session

-- | A normal step: commit, then tell the probe (the harness's boundary between a commit and its effects), then
-- pay the stops the event owed, which is a finite pass. The diagnostics it meant are not written here: only the driver
-- writes them, outside every owner callback.
applyEvent ∷ Session → Event → IO Answer
applyEvent session event = mask_ $ do
  answer ← commit session event
  sessionProbe session (Committed (Text.unpack (eventName event)))
  stopPass session
  pure answer

-- | The finite pass that hands every stop the session owes to its owner. It has no wait, no probe, no logging, no
-- clock, no callback and no @throwTo@ in it; it is repeated whenever a wait ended, an owner was registered late or a
-- new fatal entry widened the set, and repeating it is harmless. A stop owed to an owner that is not registered yet
-- stays owed (the coordinator that serves it is closed at once if it is registered). A primitive that raises is recorded once and the pass still attempts every other stop; its stop stays
-- owed, is not retried inside the pass, and is not declared handed.
stopPass ∷ Session → IO ()
stopPass session = stopPassOf session [minBound .. maxBound]

-- | The pass over these roles: all of them, or, under a negative control that removed the barrier, one scope's own.
stopPassOf ∷ Session → [Role] → IO ()
stopPassOf session roles = mask_ $ do
  (owed, registry) ← atomically ((,) <$> (attemptable <$> readTVar (sessionState session)) <*> readTVar (sessionRegistry session))
  forM_ [role | role ← roles, role `elem` owed] $ \role →
    forM_ (Map.lookup role (regRoles registry)) $ \registered →
      tryWithContext @SomeException (regStop registered) >>= \case
        -- A coordinator that is registered before its owner exists is closed now, and the stop stays owed to the
        -- owner, which the pass made when it is registered will find.
        Right () → when (isJust (regCompletion registered)) (void (commit session (StopHanded role)))
        Left defect@(ExceptionWithContext _ raised) → do
          entry ← settledEntry HostFailure (Just role) OnEngine ("the owner could not be asked to stop: " <> Text.take 512 (Text.pack (displayException raised)))
          carried ← contextEvidence defect
          void (commit session (StopDefect role entry carried))

-- | The stops owed that the pass has not already found defective: a primitive that raised is attempted once, recorded,
-- kept owed and never retried, so a defect cannot make the pass spin.
attemptable ∷ SessionState → [Role]
attemptable state = [role | role ← owedStops state, role `Set.notMember` stStopDefects state]

-- | Whether a stop is owed that the pass can hand over now.
stopsRunnable ∷ Session → STM Bool
stopsRunnable session = do
  owed ← attemptable <$> readTVar (sessionState session)
  registry ← readTVar (sessionRegistry session)
  pure (any (maybe False (isJust . regCompletion) . (`Map.lookup` regRoles registry)) owed)

-- | The status the session publishes now: coherent, bounded and nonblocking. A reader that polls may
-- miss an intermediate phase; none is promised to be seen.
sessionStatus ∷ Session → STM SessionStatus
sessionStatus session = statusOf <$> readTVar (sessionState session)

-- | The outcome data the session holds now, failure over interruption over success: what a composing
-- application reports, as soon as a failure has latched, without waiting for the session to end.
sessionOutcomeNow ∷ Session → STM SessionOutcome
sessionOutcomeNow session = outcomeOf <$> readTVar (sessionState session)

-- | The historical facts the session holds now: what each admitted instance's settlement proved (its @init@, how
-- its shutdown ended and how it ended), kept once. Bounded by the fixed set of instances.
sessionHistory ∷ Session → STM History
sessionHistory session = historyOf <$> readTVar (sessionState session)

-- | Whether the diagnostics writer, and the helper that cancels it, have ended, or were never started. The call to
-- 'runSession' never waits for the writer (D-87): a writer still blocked in the sink is cancelled and abandoned, and may
-- outlive the call. Its end stays observable here, so that whoever owns the logger (the assembly, after the producers have
-- stopped) can join it before the logger is released; a sink stuck for good is then the application quit watchdog's case.
-- The writer's end, failure or cancellation never reaches the driver and never becomes the exception that propagates.
sessionDiagnosticsEnded ∷ Session → STM Bool
sessionDiagnosticsEnded = sessionWriterEnd

-- | Ask for a stop. It takes no slot and cannot be refused: one transaction closes the whole session's
-- admission and its tick grants, and then each owner is asked to stop without waiting. Idempotent. A
-- failure that is already latched stays the outcome; an interruption outranks a normal quit.
requestStop ∷ Session → StopKind → IO ()
requestStop session kind = void (applyEvent session (Stop kind))

-- | Latch the terminal failure of the unavailable-state guard, and end the whole session. Answers
-- whether this was the first such failure, which is when the guard prints.
latchTerminalFailure ∷ Session → RoleFailure → IO Bool
latchTerminalFailure session failure = do
  -- the state bounds the failure an event carries, whoever built it
  answer ← applyEvent session (Terminal failure)
  pure (answer == Latched True)

-- The environment -------------------------------------------------------------------------------------

-- | What one selected role is, read once from the manifest and the checkpoint.
data RoleInfo = RoleInfo
  { riRole ∷ !Role
  , riContent ∷ !Text
  , riEntry ∷ !ContentKey
  , riEntryPath ∷ !Text
  , riTick ∷ !(Maybe Duration)
  , riInstances ∷ !Int
  }

-- | An instance the application's thread admitted and tracked.
data Held = Held
  { hdKey ∷ !InstanceKey
  , hdId ∷ !InstanceId
  , hdTicket ∷ !InstanceTicket
  , hdName ∷ !Text
  }

-- | An exception the session caught and accounted, kept in the order it was caught until the session returns.
data Retained = Retained
  { rtSerial ∷ !Int
  , rtCaught ∷ !Caught
  }

-- | Cleanup evidence the session keeps raw, by the identity it had when it has one, to attach beside whatever it
-- raises in the end. The accounting of it is in the state; this is only so it is not lost from the exception.
data RawEvidence = RawEvidence !(Maybe EvidenceKey) !Text !Caught

reKey ∷ RawEvidence → Maybe EvidenceKey
reKey (RawEvidence key _ _) = key

-- | The mark an exception carries once a session has accounted it, so that no scope of that session it passes through
-- accounts it again. The session's own identity says whose mark it is, and its serial finds the copy that session keeps:
-- an exception a session raised and another session catches (nested, successive, or rethrown from a callback) carries a
-- mark that is not the catching session's, which that session has not accounted, and accounts as its own.
data Accounted = Accounted !Unique !Int

instance Show Accounted where
  show (Accounted _ serial) = "Accounted #" <> show serial

instance ExceptionAnnotation Accounted where
  displayExceptionAnnotation (Accounted _ serial) = "accounted by a session as #" <> show serial

-- | What every step of the session shares. Nothing here is global: it is made by 'runSession' and
-- passed to what needs it.
data Env = Env
  { envSpec ∷ !SessionSpec
  , envSession ∷ !Session
  , envLimits ∷ !FailureLimits
  , envIds ∷ !InstanceIds
  , envSeen ∷ !(TVar (Set InstanceId))
  -- ^ The host instances whose first hook the gate has been told of.
  , envTracked ∷ !(TVar (Map.Map InstanceId Held))
  , envRoles ∷ !(Map.Map Role RoleInfo)
  , envRetained ∷ !(IORef [Retained])
  -- ^ Owner: the session's protected paths. Written when an exception is caught on one, read at the very end.
  , envSerial ∷ !(IORef Int)
  , envIdentity ∷ !Unique
  -- ^ This run's identity: the marks it makes carry it, and it reads no mark that does not.
  , envRaw ∷ !(IORef [RawEvidence])
  , envWriter ∷ !Writer
  }

-- | The session's diagnostics writer: the one thread that calls the sink. Owner: 'runSession', which starts it in a masked
-- step after its outer continuation is installed and before the first diagnostic, and cuts it off after the last role has
-- retired. Readers and writers: the writer reads the queue the lifecycle record holds and commits each attempt's claim
-- and acknowledgement there; the call reads 'wrEnded' and 'wrHelper' through 'sessionDiagnosticsEnded'; nothing else
-- touches it. It is not in the stop set and nothing in the stop pass touches it. Lifetime: it may outlive the call, which
-- never waits for it, and its end is observable after the call returns ('sessionDiagnosticsEnded'): whoever owns the
-- logger it borrows (the assembly, after the producers have stopped) joins it before the logger is released. It never
-- resets.
data Writer = Writer
  { wrPhase ∷ !(TVar WriterPhase)
  , wrThread ∷ !(IORef (Maybe ThreadId))
  -- ^ The writer's thread, for the cancellation that abandons it.
  , wrEnded ∷ !(TVar Bool)
  -- ^ The thread has returned (or never ran: a composition whose driver writes itself, or one that never started it).
  , wrHelper ∷ !(TVar Bool)
  -- ^ The helper that delivers the cancellation has returned (or none was made): delivery can block for as long as the
  -- writer is inside an uninterruptible region or a foreign call, and it never runs on the requesting thread.
  }

-- | What the writer does when the queue is empty.
data WriterPhase
  = -- | Wait for the next diagnostic.
    WriterOpen
  | -- | The session is over: write nothing more, and end when the write in hand returns or is cancelled.
    WriterClosed
  deriving (Eq)

-- | What cancels the writer when the session abandons it. Asynchronous, so that the write it interrupts is a cancellation
-- (which is not a failure of the sink) and never a failure of the engine.
data WriterAbandoned = WriterAbandoned
  deriving (Show)

instance Exception WriterAbandoned where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

-- | One role's VM and what it borrows.
data RoleVm = RoleVm
  { rvInfo ∷ !RoleInfo
  , rvCoordinator ∷ !Coordinator
  , rvOwner ∷ !ScheduledOwner
  , rvEndpoint ∷ !ScheduledEndpoint
  , rvFacade ∷ !Facade.Facade
  }

probeAt ∷ Env → Point → IO ()
probeAt env = sessionProbe (envSession env)

-- | Whether a negative control removed this protection. Always false in a real composition.
removed ∷ Env → Protection → Bool
removed env protection = protection `elem` sessionRemoved (envSession env)

stateOf ∷ Env → STM SessionState
stateOf = readTVar . sessionState . envSession

-- | The admission a role's facade reads before a content request starts.
admissionOf ∷ Env → Role → IO AdmissionState
admissionOf env role = do
  state ← readTVarIO (sessionState (envSession env))
  let found = case roleAdmit role state of
        AdmitOpen → AdmissionOpen
        AdmitStopping → AdmissionStopping
        AdmitClosed → AdmissionClosed
  -- (this read is a hint that refuses early; the decision is the admission's own gate, read in the transaction that
  -- admits the request, so a closure that commits after this read refuses the request for good)
  when (found == AdmissionOpen) (probeAt env (RequestChecked role))
  pure found

-- | The credit a role's request policy reserves first: nothing to hold, and a final refusal (an ordinary Lua error, never
-- busy) when the role takes no new work, read in the transaction that admits the request.
sessionGate ∷ Env → Role → Credit
sessionGate env role =
  Credit
    { creditName = "session admission"
    , creditReserve = do
        state ← stateOf env
        if roleAdmit role state == AdmitOpen then pure True else throwSTM (CreditRefused "the session is stopping: no request starts")
    , creditRelease = \_ → pure ()
    , creditTransfers = False
    }

-- Protected steps -----------------------------------------------------------------------------------------

-- | The next serial for a retained exception.
nextSerial ∷ Env → IO Int
nextSerial env = atomicModifyIORef' (envSerial env) (\n → (n + 1, n))

-- | The serial an exception was accounted under by this session, if it was; a mark of another session is not read.
accountedSerial ∷ Env → Caught → Maybe Int
accountedSerial env (ExceptionWithContext context _) =
  listToMaybe [serial | Accounted identity serial ← getExceptionAnnotations context, identity == envIdentity env]

mark ∷ Env → Int → Caught → Caught
mark env serial (ExceptionWithContext context exception) = ExceptionWithContext (addExceptionAnnotation (Accounted (envIdentity env) serial) context) exception

-- | The engine entry for a text, forced before it is committed: a message whose rendering raises is replaced by a
-- statement of that, so that the evaluation of a user's formatter is never part of accounting, and a thunk never
-- reaches the state.
settledEntry ∷ FailureCode → Maybe Role → FailureStage → Text → IO EngineEntry
settledEntry code role stage text =
  tryWithContext @SomeException (evaluate (Text.length text)) >>= \case
    Right _ → pure (engineEntry code role stage text)
    Left _ → pure (engineEntry code role stage "a message could not be rendered")

-- | The evidence a caught exception carries: its cleanup failures, each by the identity it already had, and, for
-- an exception that is not a cancellation, the exception itself as a failure of the engine. A cancellation is not a
-- failure of the engine. What the timer's backend raised is a failure of that cleanup or of the backend, whatever its
-- type, because it was raised, not delivered.
evidenceFrom ∷ Env → Bool → Caught → IO [Evidence]
evidenceFrom env primary failure@(ExceptionWithContext _ raised) = do
  head' ←
    if not primary
      then pure []
      else case fromException raised of
        -- (only the run's own timer's failure: one that reached it from another run is an exception like any other)
        Just backend | backendOwner backend == envIdentity env → backendEvidence env backend
        _
          | isAsync failure → pure []
          | otherwise → (\entry → [evidenceOf entry]) <$> settledEntry HostFailure Nothing OnEngine (Text.pack (displayException raised))
  -- (a negative control removes the accounting of what a cancellation carries)
  tails ← if isAsync failure && removed env ProtectCancellationEvidence then pure [] else contextEvidence failure
  pure (head' <> tails)

-- | The cleanup failures an exception carries in its context, each as the evidence it is, by the identity it was issued,
-- whether it is carried by the exception itself, by what the timer's backend raised (which keeps the original and its
-- context inside), or by a cleanup failure that is itself such a wrapper, to any depth.
contextEvidence ∷ Caught → IO [Evidence]
contextEvidence failure =
  forM (cleanupDeep failure) $ \(item, label, ExceptionWithContext _ inner) → do
    entry ← settledEntry CleanupFailure Nothing OnCleanup (label <> ": " <> Text.pack (displayException inner))
    pure (Evidence (Just (evidenceKeyOf item)) entry)

-- | What an injected callback or release raised, as evidence: the exception itself under this code, stage and label,
-- and every cleanup failure its context carries, each by its identity. The one place a caught failure of the session's
-- own cleanup, a stop, a sink or a settlement becomes evidence, so that none of them drops what it carried.
caughtEvidence ∷ FailureCode → Maybe Role → FailureStage → Text → Caught → IO [Evidence]
caughtEvidence code role stage label failure@(ExceptionWithContext _ raised) = do
  primary ← settledEntry code role stage (label <> ": " <> Text.pack (displayException raised))
  carried ← contextEvidence failure
  pure (evidenceOf primary : carried)

-- | What the timer's backend raised, whole: a failure of the backend's cancel is a failure of that cleanup, a failure
-- of its arm a failure of the host, and what either carried is accounted beside it.
backendEvidence ∷ Env → BackendRaised → IO [Evidence]
backendEvidence _ = \case
  CancelRaised _ inner@(ExceptionWithContext _ raised) → do
    entry ← settledEntry CleanupFailure Nothing OnCleanup ("pacing timer: " <> Text.pack (displayException raised))
    carried ← contextEvidence inner
    pure (evidenceOf entry : carried)
  ArmRaised _ inner@(ExceptionWithContext _ raised) → do
    entry ← settledEntry HostFailure Nothing OnEngine ("the pacing timer's backend raised when it was armed: " <> Text.pack (displayException raised))
    carried ← contextEvidence inner
    pure (evidenceOf entry : carried)

-- | The cleanup failures an exception carries, with the identities they were issued.
cleanupOf ∷ Caught → [(CleanupFailureId, Text, Caught)]
cleanupOf (ExceptionWithContext context _) =
  [(cleanupFailureId item, cleanupFailureLabel item, cleanupFailureException item) | item ← cleanupFailuresInContext context]

-- | The cleanup failures an exception carries and every wrapper of the timer's backend hides, each once by its
-- identity. A 'BackendRaised' keeps the original exception with the context it carried; whether it is the exception
-- itself or one of the cleanup failures beside it, what the original carried is carried too.
cleanupDeep ∷ Caught → [(CleanupFailureId, Text, Caught)]
cleanupDeep failure = once Set.empty (direct <> concatMap cleanupDeep wrapped)
  where
    once _ [] = []
    once seen (entry@(item, _, _) : rest)
      | evidenceKeyOf item `Set.member` seen = once seen rest
      | otherwise = entry : once (Set.insert (evidenceKeyOf item) seen) rest
    direct = cleanupOf failure
    wrapped = mapMaybe backendInner (failure : [inner | (_, _, inner) ← direct])

-- | What the timer's backend raised, as the original exception with its context.
backendInner ∷ Caught → Maybe Caught
backendInner (ExceptionWithContext _ raised) = case fromException raised of
  Just (ArmRaised _ inner) → Just inner
  Just (CancelRaised _ inner) → Just inner
  Nothing → Nothing

-- | Keep what an exception carries raw, so the final exception can carry it, once for each identity.
keepRaw ∷ Env → Caught → IO ()
keepRaw env failure =
  modifyIORef' (envRaw env) $ \kept →
    kept <> [RawEvidence (Just (evidenceKeyOf item)) label inner | (item, label, inner) ← cleanupDeep failure, Just (evidenceKeyOf item) `notElem` map reKey kept]

-- | The most exceptions the session keeps whole: the first cancellation and the first failure are always kept, and so
-- is anything while there is room, so that repeated cancellation cannot grow what is kept without end. What an
-- exception carries is accounted whether or not the exception itself is kept.
retainLimit ∷ Int
retainLimit = 32

-- | Keep an exception for the end, within the limit.
store ∷ Env → Retained → IO ()
store env item = modifyIORef' (envRetained env) $ \kept →
  let firstOfKind = not (any (\other → isAsync (rtCaught other) == isAsync (rtCaught item)) kept)
   in if firstOfKind || length kept < retainLimit then kept <> [item] else kept

-- | Account an exception, keep it, and mark it. If it is already accounted, the copy kept is refreshed with the
-- context the scopes it passed through added, and only what is new in that context is accounted. Never raises. The
-- boundary probe (a protected point beside the commit, not inside it) is told, so a test can hold or fail the
-- thread right after the commit; its own failure is retained without a further probe.
adopt ∷ Env → Caught → IO Caught
adopt env failure = mask_ $ do
  marked ← case accountedSerial env failure of
    Just serial → do
      modifyIORef' (envRetained env) (map (\kept → if rtSerial kept == serial then kept {rtCaught = failure} else kept))
      evidence ← evidenceFrom env False failure
      keepRaw env failure
      void (commit (envSession env) (Account evidence))
      pure failure
    Nothing → do
      serial ← nextSerial env
      let marked = mark env serial failure
      evidence ← evidenceFrom env True failure
      store env (Retained serial marked)
      keepRaw env failure
      void (commit (envSession env) (Account evidence))
      pure marked
  boundary env (Committed "Account")
  pure marked

-- | Retain an exception caught on a protected path whose own propagation is not the session's: accounted and kept
-- for the end. A probe that raises at a protected boundary is retained here too.
retain ∷ Env → Caught → IO ()
retain env failure = void (adopt env failure)

-- | A protected boundary: the harness's probe told beside a commit, outside it. What it raises or is cancelled with
-- is retained, and the next mandatory step goes on. A probe is never told again to retry the cleanup it observed:
-- what it raised is retained without telling the probe.
boundary ∷ Env → Point → IO ()
boundary env point = tryWithContext @SomeException (probeAt env point) >>= either (retainQuiet env) pure

-- | Retain without telling the probe.
retainQuiet ∷ Env → Caught → IO ()
retainQuiet env failure = mask_ $ do
  serial ← nextSerial env
  let marked = mark env serial failure
  evidence ← evidenceFrom env True failure
  store env (Retained serial marked)
  keepRaw env failure
  void (commit (envSession env) (Account evidence))


-- The hooks the owners run ----------------------------------------------------------------------------

-- | The host instance the application's thread has tracked, waiting for the tracking while an admission of
-- the role is still being made. 'Nothing' for an instance the session never admitted, which cannot happen.
awaitTracked ∷ Env → Role → InstanceId → STM (Maybe Held)
awaitTracked env role inst = do
  tracked ← readTVar (envTracked env)
  case Map.lookup inst tracked of
    Just found → pure (Just found)
    Nothing → do
      state ← stateOf env
      case Map.lookup role (stRoles state) of
        Just found | rsIntents found > 0 → retry
        _ → pure Nothing

-- | Asked, on the owner's thread and once per instance, when the instance has been constructed, its behavior
-- found, captured and validated and its cadence resolved, and nothing authored has run. The instance is held
-- there: the session records it as validated, and the owner goes on to the instance behind it. The driver
-- releases every held instance together when the dispatch gate opens, which is when every instance of every
-- role has been validated and admission is complete; an aborted gate releases none, and a held instance ends
-- with its owner, its @init@ never having run.
holdInit ∷ Env → Role → InstanceId → IO Bool
holdInit env role inst =
  atomically (awaitTracked env role inst) >>= \case
    Nothing → throwIO (SessionRefused "an instance the session did not admit was constructed")
    Just held → do
      probeAt env (Validating (hdKey held))
      void (applyEvent (envSession env) (Validated (hdKey held)))
      pure True

-- | Told, on the owner's thread, just before an instance's hook begins. The first time it is told of an instance
-- is its initialization, after it was released: the probe names the point, and holding the thread here holds the
-- @init@ without running a line of Lua.
dispatched ∷ Env → Role → InstanceId → IO ()
dispatched env role inst = do
  first ← atomically $ do
    seen ← readTVar (envSeen env)
    if Set.member inst seen
      then pure False
      else True <$ writeTVar (envSeen env) (Set.insert inst seen)
  when first $
    atomically (awaitTracked env role inst)
      >>= maybe (throwIO (SessionRefused "an instance the session did not admit began its init")) (probeAt env . Dispatched . hdKey)

-- | The host instance a failure is of, as the state keys the instances whose failure it was told of.
instanceRef ∷ InstanceFailure → Text
instanceRef = Text.pack . show . failureInstance

-- | Told, on the owner's thread and once, as an instance's ending begins with a failure: before its @shutdown@, its
-- release and the retirements its providers owe it, which its settlement waits for. The failure latches here, at
-- once: the role's admission closes and its owner is owed a stop in the transition that records it, whatever a
-- provider is slow to retire, and the failure policy is applied (D-42). The callback commits and hands the stops
-- over, which is finite, and writes nothing. Every failure is isolated; the policy is the coordinator's, and the
-- instance is marked as told so that its settlement adds only what else failed.
failingFor ∷ Env → Role → InstanceFailure → IO ()
failingFor env role failure = do
  tracked ← atomically (awaitTracked env role (failureInstance failure))
  let info = envRoles env Map.! role
      (record, secondary) =
        classifyInstance (envLimits env) role (riContent info) (hdName <$> tracked) (Just (riEntryPath info)) failure
  void (applyEvent (envSession env) (InstanceFailing (instanceRef failure) role record secondary))

-- | Told, on the owner's thread, of an instance's failure when it has settled. If the owner reported it as it
-- began, this accounts what else failed as it ended; a failure that arises only in settling (a @shutdown@ that raises
-- after a stop, a release that fails) is latched here, by the same policy.
escalateFor ∷ Env → Role → InstanceFailure → IO Escalation
escalateFor env role failure = do
  tracked ← atomically (awaitTracked env role (failureInstance failure))
  let info = envRoles env Map.! role
      (record, secondary) =
        classifyInstance (envLimits env) role (riContent info) (hdName <$> tracked) (Just (riEntryPath info)) failure
  void (applyEvent (envSession env) (InstanceEscalated (instanceRef failure) role record secondary))
  pure Isolate

-- Registration ------------------------------------------------------------------------------------------

-- | The finite release the session registers for a step: the harness's, which is nothing in a real composition.
buildRelease ∷ Env → Role → BuildStep → RoleRelease
buildRelease env role built = RoleRelease (ReleaseBuild role built) (sessionRelease (envSession env) (ReleaseBuild role built))

-- | Register a component the role acquired, in the transaction that records the acquisition, and hand over any stop
-- this makes runnable. Called masked, directly after the acquisition and before any probe, callback or further
-- acquisition, so that nothing acquired is ever out of the reach of a stop.
register ∷ Env → Role → BuildStep → (Registered → Registered) → IO ()
register env role built change = do
  atomically $ do
    modifyTVar'
      (sessionRegistry (envSession env))
      ( \registry →
          registry
            { regRoles =
                Map.alter
                  (\existing → Just (change (maybe (Registered (pure ()) Nothing Nothing []) id existing)))
                  role
                  (regRoles registry)
            }
      )
    void (commitSTM (envSession env) (Acquired role built))
  stopPass (envSession env)

-- | Register a session-level finite release: the first registered is the last to run.
registerSessionRelease ∷ Env → Release → IO () → IO ()
registerSessionRelease env which action =
  atomically (modifyTVar' (sessionRegistry (envSession env)) (\registry → registry {regSession = RoleRelease which action : regSession registry}))

-- | Run a release once, uninterruptibly (it is finite and never waits), and answer what it raised. What a release itself
-- raised is a failure of that cleanup whatever its type: it was not delivered from outside, because nothing is
-- delivered to an uninterruptible release.
attemptRelease ∷ Env → RoleRelease → IO (Maybe (Text, Caught))
attemptRelease env release =
  uninterruptibleMask_ $
    tryWithContext @SomeException (rrAction release) >>= \case
      Right () → pure Nothing
      -- (a negative control takes an exception of an asynchronous type for a cancellation)
      Left failure | isAsync failure && removed env ProtectReleaseSource → rethrowIO failure
      Left failure → pure (Just (releaseLabel (rrWhich release), failure))

-- | Attempt each of these releases, once, in order, and answer every failure. The first that raises does not keep the
-- others from running.
attemptAll ∷ Env → [RoleRelease] → IO [(Text, Caught)]
attemptAll env = go
  where
    go [] = pure []
    go (release : rest) = do
      attempted ← attemptRelease env release
      case attempted of
        -- (a negative control gives the attempts up at the first failure)
        Just failure | removed env ProtectReleases → pure [failure]
        Just failure → (failure :) <$> go rest
        Nothing → go rest

releaseLabel ∷ Release → Text
releaseLabel = \case
  ReleaseBuild role built → roleWord role <> " " <> Text.pack (show built)
  ReleaseTimer → "pacing timer"
  ReleaseComposition → "composition"

-- Construction ------------------------------------------------------------------------------------------

-- | The scheduler's bounds for a role's owner. A role has one root, or two where a harness asks for the second slot
-- the design keeps, so the active tasks, the queued admissions, the retained results and the outstanding grants
-- are far above what two instances reach; the quanta are the host's smallest even share. The coordinator grants
-- one tick at a time and waits for it, so the outstanding-grant bound is never the limit.
schedulerBounds ∷ SchedulerBounds
schedulerBounds =
  SchedulerBounds
    { boundActiveTasks = 16
    , boundQueuedAdmissions = 16
    , boundRetainedResults = 32
    , boundQuanta = Quanta (Quantum 4) (Quantum 4) (Quantum 4)
    , boundOutstandingGrants = 4
    , boundControlRequests = 8
    , boundServiceBudget = Nothing
    }

-- | The owners' supervision policy: required, and no failure of an owner is recognized, so supervision delivers it
-- as it does for any worker and the session accounts for it when the owner is finalized.
ownerPolicy ∷ WorkerPolicy
ownerPolicy =
  WorkerPolicy
    { policyRole = Supervision.Service
    , policyDisposition = Required
    , policyComponent = sessionComponent
    , policyClassifier = \_ → pure Unrecognized
    }

-- | Run a body over one role's VM. Each component is acquired and registered with the lifecycle record in one
-- masked step, in the order the owner needs them: the coordinator, then the data service, the facade and the
-- owner. Nothing here waits for an owner: leaving this scope on any path runs the session's protocol, which stops
-- every constructed owner before it waits for any, and the pool, root and output the caller owns stay outside all
-- of it.
withRoleVm ∷ Env → RoleInfo → (RoleVm → IO a) → IO a
withRoleVm env info body = do
  handles ← newRequestHandles
  requests0 ← either (refuse "the request policy" . Text.pack . show) pure (m1Requests profile handles)
  let requests = if removed env ProtectRequestGate then requests0 else withM1Gate (sessionGate env (riRole info)) requests0
  phase ← newModulePhase
  holder ← newTVarIO Nothing
  let moduleSpec =
        ModuleSpec
          { specRequests = requests
          , specInventory = sxInventory spec
          , specPool = sxPool spec
          , specResolve = inventoryResolver (sxInventory spec) [riContent info]
          , specLogger = sxLogger spec
          , specRole = roleWord role
          , specSlots = 4
          , specBootWaiters = 2
          , specPhase = Just phase
          }
  probeAt env (Acquiring role BuildCoordinator)
  mask $ \restore →
    withModuleCoordinator moduleSpec $ \coordinator → do
      register
        env
        role
        BuildCoordinator
        ( \registered →
            registered
              { regStop = regStop registered >> closeModuleCoordinator coordinator
              , regDrained = Just ((awaitDrained coordinator >> pure True) `orElse` pure False)
              , regReleases = buildRelease env role BuildCoordinator : regReleases registered
              }
        )
      restore $ do
        probeAt env (Built role BuildCoordinator)
        probeAt env (Acquiring role BuildData)
        bank ← mask_ $ do
          made ← newByteBankFor profile
          register env role BuildData (\registered → registered {regReleases = buildRelease env role BuildData : regReleases registered})
          pure made
        service ← either (refuse "the data service" . Text.pack . show) pure (dataService requests (sxInventory spec) (sxPool spec) bank)
        probeAt env (Built role BuildData)
        let endpoints =
              FacadeEndpoints
                { endpointAdmission = admissionOf env role
                , endpointFailure = \(EngineFailure text) →
                    void (applyEvent (envSession env) (EngineFault (Just role) (engineEntry HostFailure (Just role) OnEngine text)))
                , endpointClock = sxClock spec
                , endpointTick = readTVarIO holder >>= maybe (pure (harnessTickBase harness)) (\found → (+ harnessTickBase harness) <$> atomically (scheduledTick found))
                }
        probeAt env (Acquiring role BuildFacade)
        facade ← mask_ $ do
          made ←
            newFacade
              FacadeSpec
                { fsRole = role
                , fsRequests = requests
                , fsCoordinator = coordinator
                , fsData = service
                , fsInventory = sxInventory spec
                , fsOutput = sxOutput spec
                , fsEndpoints = endpoints
                , fsPhase = phase
                , fsRoots = [riContent info]
                , fsIds = envIds env
                , fsTickDuration = riTick info
                }
              >>= either (refuse "the facade" . Text.pack . show) pure
          register env role BuildFacade (\registered → registered {regReleases = buildRelease env role BuildFacade : regReleases registered})
          pure made
        probeAt env (Built role BuildFacade)
        let base = (vmProfileConfig LibraryProfileM1) {vmOwnerName = "session-" <> roleWord role}
            -- (a test's chunk runs after the facade rebinds @print@, so that it can be held in the authored output)
            started = [(chunkName "harness start", Text.encodeUtf8 (Text.pack source)) | (which, source) ← harnessStartChunk harness, which == role]
        installed ← either (refuse "the facade's installation" . Text.pack . show) pure (installFacade facade [] [] base)
        let config = installed {vmInitialChunks = vmInitialChunks installed <> started}
        let Count live = countLimit profile InstancesPerVm
            Count perVm = countLimit profile RequestsPerVm
            liveBound = fromIntegral live
            instanceBase =
              defaultInstanceConfig
                { instanceBounds = InstanceBounds liveBound (2 * liveBound) (4 * liveBound) 8
                , instanceTickDuration = riTick info
                , instanceEscalate = escalateFor env role
                , instanceOnFailing = failingFor env role
                }
            withFacadeSample = facadeInstanceConfig facade instanceBase
            -- The probe is told before the facade samples the presentation clock, so the clock's origin is the
            -- instant the @init@ begins.
            instances =
              withFacadeSample
                { instanceOnSegment = \inst → dispatched env role inst >> instanceOnSegment withFacadeSample inst
                , instanceHoldInit = holdInit env role
                }
            timing = if role == Gameplay then SettleAtAssignedTick Nothing else SettleOnArrival
            owned =
              (scheduledSpec config ownerPolicy schedulerBounds)
                { scheduledInstances = Just instances
                , scheduledRequestHandles = Just handles
                , scheduledRequests = Just (RequestGrant (facadeRequestEndpoints facade) (fromIntegral perVm) timing)
                , scheduledLoader = Just (coordinatorPlan coordinator)
                , scheduledClock = sxClock spec
                , scheduledTimer = sxTimer spec
                , scheduledRefusedWait = facadeRefusedWait facade
                , scheduledOnStartAbandoned = if removed env ProtectStartAbandon then pure () else abandonedStart env role
                }
        withOwner env info owned coordinator holder facade body
  where
    spec = envSpec env
    harness = sxHarness spec
    profile = sxProfile spec
    role = riRole info
    refuse what why = throwIO (SessionRefused (what <> " was refused: " <> why))

-- | Told, on the starter's thread, when this role's start is abandoned (D-82/T1): the session closes and every
-- registered peer is handed its stop now, before the starter waits for its partly started worker to end. The point
-- is told afterwards, so a test holds the starter here and finds the receipts.
--
-- Nothing it does raises into the host: a failure of its own (the point told after the pass raised) is accounted here as a
-- failure of the host, once, and a cancellation that lands in it is retained for the end. The stops were handed over before
-- either could happen, and the readiness failure the host is about to raise is never displaced.
abandonedStart ∷ Env → Role → IO ()
abandonedStart env role = mask_ $ do
  told ← tryWithContext @SomeException $ do
    void (commit (envSession env) Unwind)
    stopPass (envSession env)
    probeAt env (StartAbandoned role)
  case told of
    Right () → pure ()
    Left failure
      | isAsync failure → retainQuiet env failure
      | otherwise → do
          evidence ← caughtEvidence HostFailure (Just role) OnEngine "the abandonment of a start could not be told" failure
          void (commit (envSession env) (Account evidence))

-- | Start a role's owner, register it with the lifecycle record in the same masked step, run a body, and on every
-- way out run the session's protocol before the scopes it borrows from are released.
--
-- The registration has no gap after the start: the owner is found by the stop pass from the moment it exists, and
-- the stop pass is made again for it at once, because a stop may have been owed before it existed. If the start
-- itself fails or is cancelled while the owner is being made ready, the starter's own protected obligation is to
-- stop that one worker and wait for it to end before it raises: that is bounded by the worker's own end, and it
-- runs before this scope regains control, so the peers already registered are stopped by the pass that follows,
-- not before it.
withOwner
  ∷ Env
  → RoleInfo
  → ScheduledSpec
  → Coordinator
  → TVar (Maybe ScheduledEndpoint)
  → Facade.Facade
  → (RoleVm → IO a)
  → IO a
withOwner env info owned coordinator holder facade body = mask $ \restore → do
  restore (probeAt env (Acquiring role BuildOwner))
  -- The start is guarded where it is made: if it fails or is cancelled, the session closes and the peers already
  -- registered are handed their stops at once, as the exception leaves the starter, before any scope it crosses.
  started ←
    tryWithContext @SomeException (startScheduledOwner (sxRuntime spec) owned) >>= \case
      Right found → pure found
      Left failure → do
        void (commit (envSession env) Unwind)
        stopPass (envSession env)
        rethrowIO failure
  case started of
    ScheduledUnavailable failure → rethrowIO failure
    ScheduledRejected → throwIO (SessionRefused "the owner was rejected")
    ScheduledEnded → throwIO (SessionRefused "the owner ended before it started")
    ScheduledStarted owner → do
      let endpoint = scheduledEndpoint owner
          worker = supervisedWorker (scheduledSupervised owner)
      let registerOwner =
            register
              env
              role
              BuildOwner
              ( \registered →
                  registered
                    { regStop = retireScheduled owner >> closeModuleCoordinator coordinator
                    , regCompletion = Just ((Just <$> awaitCompletion worker) `orElse` pure Nothing)
                    , regReleases = buildRelease env role BuildOwner : regReleases registered
                    }
              )
          -- (a negative control removes the protection: the probe comes first, and registration after it)
          late = removed env ProtectRegistration
      unless late registerOwner
      outcome ← tryWithContext @SomeException . restore $ do
        harnessOwner (sxHarness spec) role (OwnerHandles (retireScheduled owner) (cancelScheduled owner) (void (atomically (awaitCompletion worker))))
        probeAt env (Built role BuildOwner)
        when late (mask_ registerOwner)
        atomically (writeTVar holder (Just endpoint))
        loader ← maybe (throwIO (SessionRefused "the owner has no loader endpoint")) pure (scheduledLoaderEndpoint owner)
        attachLoader coordinator loader
        body RoleVm {rvInfo = info, rvCoordinator = coordinator, rvOwner = owner, rvEndpoint = endpoint, rvFacade = facade}
      -- However the body ended, the exception it ended with is accounted whole, with every cleanup failure it carries,
      -- before anything else is: it is the first failure the session knows, and the evidence the protocol finds after it
      -- cannot replace it. Then the whole protocol runs here, for every constructed owner and not only this one's: the
      -- barrier first, then the waits. Run again by an outer scope it finds nothing left to do.
      accounted ← either (fmap Left . adopt env) (pure . Right) outcome
      teardown env restore (if removed env ProtectBarrier then Just role else Nothing)
      either rethrowIO pure accounted
  where
    spec = envSpec env
    role = riRole info

-- The teardown protocol ---------------------------------------------------------------------------------

-- | What the retirement of one role needs next.
data RoleStep
  = -- | Its owner has ended: account the completion and every settlement.
    StepFinalize !Role
  | -- | Its coordinator has drained: record that.
    StepDrained !Role
  | -- | Nothing borrows what it acquired: run its registered releases.
    StepRelease !Role
  | -- | Retirement is proven: publish it.
    StepRetire !Role

-- | The first step any role can take now (any role in the scope: every role, unless a negative control removed the
-- barrier and a scope serves its own role alone), the logical role first, or nothing. A role whose owner has not ended, or
-- whose coordinator has not drained, offers none: that is what is waited for.
nextRoleStep ∷ Env → Maybe Role → STM (Maybe RoleStep)
nextRoleStep env scope = do
  state ← stateOf env
  registry ← readTVar (sessionRegistry (envSession env))
  firstSTM [stepFor state registry role found | (role, found) ← Map.toList (stRoles state), rsPhase found /= Retired, inScope role]
  where
    inScope role = maybe True (== role) scope
    stepFor state registry role found = do
      let registered = Map.lookup role (regRoles registry)
          closed = rsAdmit found /= AdmitOpen
          hasOwner = BuildOwner `Set.member` rsAcquired found
          hasCoordinator = BuildCoordinator `Set.member` rsAcquired found
      ended ← case (hasOwner, registered >>= regCompletion) of
        (True, Just completion) → isJust <$> completion
        (True, Nothing) → pure False
        (False, _) → pure True
      drained ← case (hasCoordinator, registered >>= regDrained) of
        (True, Just proof) → proof
        (True, Nothing) → pure False
        (False, _) → pure True
      pure $ case () of
        _
          -- an owner that has ended is accounted whether or not anything asked it to: an end nobody asked for is an
          -- external stop, and the transition that accounts it closes the whole session
          | hasOwner && not (rsOwnerEnded found) → if ended then Just (StepFinalize role) else Nothing
          | not closed → Nothing
          | hasCoordinator && not (rsDrained found) → if drained then Just (StepDrained role) else Nothing
          | not (Set.null (rsAcquired found)) && not (rsReleased found) → Just (StepRelease role)
          | retirable role state → Just (StepRetire role)
          | otherwise → Nothing

-- | The first of these that has an answer.
firstSTM ∷ [STM (Maybe a)] → STM (Maybe a)
firstSTM [] = pure Nothing
firstSTM (item : rest) = item >>= maybe (firstSTM rest) (pure . Just)

-- | Perform one step of a role's retirement. The commits are recovery commits; the probes beside them are told
-- through the given boundary.
performStep ∷ Env → (Point → IO ()) → RoleStep → IO ()
performStep env tell = \case
  StepFinalize role → do
    tell (OwnerEnded role)
    finalizeRole env role
    tell (Committed "OwnerFinalized")
    -- the owner is accounted and its coordinator is the next thing waited for: the first wait after the owner
    registeredDrain ← atomically (maybe False (isJust . regDrained) . Map.lookup role . regRoles <$> readTVar (sessionRegistry session))
    when registeredDrain (tell (Draining role))
  StepDrained role → do
    void (commit session (Drained role))
    tell (Committed "Drained")
  StepRelease role → runReleases env role >> tell (Committed "ReleasesDone")
  StepRetire role → do
    void (commit session (RoleRetired role))
    tell (Committed "RoleRetired")
  where
    session = envSession env

-- | Finalize a role's owner, on whichever path finds it ended first: read its raw completion, which supervision's
-- latch never hides, and what each settlement of its tracked instances proves, and commit all of it in one event:
-- the claim that the completion is accounted, how the owner ended (a failure of the host, a cancellation; an
-- engine failure the facade already reported at its boundary is not a new failure), every cleanup failure it
-- retained by the identity it has, a settlement that is missing as a fault of the host's contract, and the
-- historical facts the settlements prove (an @init@ that succeeded, how the shutdown ended). Nothing here reads a
-- clock, opens a gate or admits a tick: after the session is closed a late success updates history only.
finalizeRole ∷ Env → Role → IO ()
finalizeRole env role = mask_ $ do
  registry ← readTVarIO (sessionRegistry session)
  completion ← case Map.lookup role (regRoles registry) >>= regCompletion of
    Just wait | not (removed env ProtectRawCompletion) → atomically wait
    _ → pure Nothing
  held ← filter ((== role) . ikRole . hdKey) . Map.elems <$> readTVarIO (envTracked env)
  proven ← forM held $ \item →
    tryWithContext @SomeException (pollInstance (hdTicket item)) >>= \case
      Right (Just _) | sessionHidden session (hdKey item) → missing item
      Right (Just settlement) → pure (Just (hdKey item, factOf settlement), [])
      Right Nothing → missing item
      Left unread → do
        evidence ← caughtEvidence HostFailure (Just role) OnEngine "an instance's settlement could not be read" unread
        pure (Nothing, evidence)
  ended ← maybe (pure []) completionEvidence completion
  forM_ completion (keepCompletion env)
  let evidence = ended <> concatMap snd proven
      facts = catMaybes (map fst proven)
  if removed env ProtectBundle
    then do
      -- (a negative control removes the bundle: the claim is committed first, the evidence and the facts after it)
      void (commit session (OwnerFinalized role [] []))
      boundary env (Committed "OwnerClaimed")
      void (commit session (Account evidence))
      void (commit session (OwnerFinalized role [] facts))
    else void (commit session (OwnerFinalized role evidence facts))
  where
    session = envSession env
    missing item = do
      entry ← settledEntry HostFailure (Just role) OnEngine ("an instance the session accepted had no settlement when its owner had ended: " <> Text.pack (show (hdKey item)))
      pure (Nothing, [evidenceOf entry])
    completionEvidence found =
      case completionResult found of
        Worker.Succeeded _ → cleanup found
        Worker.Failed (ExceptionWithContext _ exception)
          | isJust (fromException exception ∷ Maybe EngineFailure) → cleanup found
          | otherwise → (:) . evidenceOf <$> settledEntry HostFailure (Just role) OnEngine (Text.pack (displayException exception)) <*> cleanup found
        Worker.Cancelled (ExceptionWithContext _ exception) →
          (:) . evidenceOf <$> settledEntry HostFailure (Just role) OnEngine ("the owner was cancelled: " <> Text.pack (displayException exception)) <*> cleanup found
    cleanup found =
      forM (completionCleanup found) $ \item → do
        entry ← settledEntry CleanupFailure (Just role) OnCleanup (cleanupFailureLabel item <> ": " <> Text.pack (displayCleanupFailure item))
        pure (Evidence (Just (evidenceKeyOf (cleanupFailureId item))) entry)

-- | Keep an owner's completion raw, to travel beside whatever is raised: its failure once, its cleanup by identity.
keepCompletion ∷ Env → Completion () → IO ()
keepCompletion env found =
  modifyIORef' (envRaw env) $ \kept →
    kept
      <> [RawEvidence Nothing "lua owner" failed | Worker.Failed failed ← [completionResult found], isJust (fromException (exceptionOf failed) ∷ Maybe EngineFailure) == False]
      <> [ RawEvidence (Just (evidenceKeyOf (cleanupFailureId item))) (cleanupFailureLabel item) (cleanupFailureException item)
         | item ← completionCleanup found
         , Just (evidenceKeyOf (cleanupFailureId item)) `notElem` map reKey kept
         ]
  where
    exceptionOf (ExceptionWithContext _ raised) = raised

-- | What a settlement proves about its instance.
factOf ∷ InstanceSettlement → InstanceFact
factOf settlement =
  InstanceFact
    { ifInitialized = shutdown /= ShutdownSkippedNoInit
    , ifShutdown = case shutdown of
        ShutdownRan → FactShutdownRan
        ShutdownRaised → FactShutdownRaised
        ShutdownAbsent → FactShutdownAbsent
        ShutdownSkippedNoInit → FactShutdownSkippedNoInit
        ShutdownSkippedUnsafe → FactShutdownSkippedUnsafe
    , ifEnded = case resultOutcome settlement of
        InstanceFailed _ → EndedFailed
        InstanceDiscarded _ → EndedDiscarded
        _ → case resultPhase settlement of
          Completed → EndedCompleted
          _ → EndedStopped
    }
  where
    shutdown = terminationShutdown (resultTermination settlement)

-- | Run a role's registered releases, each once, uninterruptibly, the last acquired first, and commit that they were
-- attempted with every one that raised. A release that raised is accounted and keeps the role from being published
-- as retired, and does not keep any other release from running.
runReleases ∷ Env → Role → IO ()
runReleases env role = mask_ $ do
  registry ← readTVarIO (sessionRegistry session)
  failures ← attemptAll env (maybe [] regReleases (Map.lookup role (regRoles registry)))
  evidence ← fmap concat . forM failures $ \(label, failure) → do
    modifyIORef' (envRaw env) (<> [RawEvidence Nothing label failure])
    caughtEvidence CleanupFailure (Just role) OnCleanup label failure
  void (commit session (ReleasesDone role evidence))
  where
    session = envSession env

-- | The session-level releases (the pacing timer, the outermost scope), each once, after every role has finished.
-- What one raises is accounted as cleanup of the engine, and does not keep another from running.
runSessionReleases ∷ Env → IO ()
runSessionReleases env = mask_ $ do
  releases ← atomically $ do
    registry ← readTVar (sessionRegistry session)
    writeTVar (sessionRegistry session) registry {regSession = []}
    pure (regSession registry)
  failures ← attemptAll env releases
  evidence ← fmap concat . forM failures $ \(label, failure) → do
    modifyIORef' (envRaw env) (<> [RawEvidence Nothing label failure])
    caughtEvidence CleanupFailure Nothing OnCleanup label failure
  unless (null evidence) (void (commit session (Account evidence)))
  where
    session = envSession env

-- | The all-owner protocol, for every way out. It runs masked and is idempotent: run by an outer scope after an inner
-- one, it finds nothing left to do.
--
-- 1. Close the session and owe every owner a stop (one commit), then the one barrier pass that hands every owed stop to
--    every constructed owner, the logical one first, with no wait before it ends.
-- 2. Then, as any role's next step becomes possible, take it: account an owner that ended, prove its coordinator
--    drained, run its registered releases, publish its retirement. Waits run through @restore@ with a handler: an
--    interruption is retained with its context, the barrier pass is made again (a new fatal entry may have widened the
--    set), and the one outstanding wait is resumed, never turned into a receipt.
teardown ∷ Env → (∀ x. IO x → IO x) → Maybe Role → IO ()
teardown env restore scope = mask_ $ do
  pending ← atomically (not . finishedIn scope <$> stateOf env)
  when pending $ do
    void (commit session Unwind)
    boundary env Unwinding
  -- (a negative control removes the protection that this pass is: the diagnostics still pending are written first, and
  -- each scope hands a stop to its own owner alone)
  when (removed env ProtectRecovery) $ tryWithContext @SomeException (forwardPending env) >>= either (retain env) pure
  stopPassFor scope
  loop Set.empty
  where
    session = envSession env
    stopPassFor = maybe (stopPass session) (stopPassOf session . (: []))
    loop announced = do
      stopPassFor scope
      next ← atomically (nextRoleStep env scope)
      case next of
        Just found → performStep env (boundary env) found >> loop announced
        Nothing → do
          finished ← atomically (finishedIn scope <$> stateOf env)
          unless finished $ do
            waiting ← atomically (waitingFor env scope)
            let fresh = [point | point ← waiting, point `Set.notMember` announced]
            forM_ fresh (boundary env . Awaiting)
            -- (a negative control makes the wait uninterruptible)
            let wait = if removed env ProtectInterruptibleWait then uninterruptibleMask_ else restore
            interrupted ← tryWithContext @SomeException (wait (atomically (blockUntilStep env scope)))
            either (retain env) pure interrupted
            loop (announced `Set.union` Set.fromList waiting)

-- | Whether the roles in the scope have all finished.
finishedIn ∷ Maybe Role → SessionState → Bool
finishedIn scope state = case scope of
  Nothing → rolesFinished state
  Just role → maybe True (\found → rsPhase found == Retired || (rsReleased found && rsReleaseFailed found)) (Map.lookup role (stRoles state))

-- | The roles whose owner the protocol waits for: acquired, not yet ended, and the session closed.
waitingFor ∷ Env → Maybe Role → STM [Role]
waitingFor env scope = do
  state ← stateOf env
  pure
    [ role
    | (role, found) ← Map.toList (stRoles state)
    , rsPhase found /= Retired
    , maybe True (== role) scope
    , BuildOwner `Set.member` rsAcquired found
    , not (rsOwnerEnded found)
    ]

-- | Block until some step of some role can be taken or every role has finished.
blockUntilStep ∷ Env → Maybe Role → STM ()
blockUntilStep env scope = do
  next ← nextRoleStep env scope
  case next of
    Just _ → pure ()
    Nothing → do
      finished ← finishedIn scope <$> stateOf env
      unless finished retry

-- Diagnostics ---------------------------------------------------------------------------------------------

-- | What one attempt at a diagnostic came to.
data Forwarded
  = -- | Written and acknowledged.
    Forwarded
  | -- | Another caller holds the attempt, or the diagnostic is gone (the cut-off).
    Unclaimed
  | -- | The sink raised: recorded as evidence.
    WriteFailed
  | -- | The write was cancelled: the data stays, marked unfinished.
    WriteCancelled !Caught

-- | Write one diagnostic the queue holds: claimed (so no other caller issues the same attempt), written,
-- acknowledged. A failure of the sink is evidence, never the session's failure, recorded without a diagnostic of its
-- own; a cancellation of the write leaves the data in the queue marked unfinished and is answered, not raised. All of
-- it is masked except the write itself, which stays interruptible. The only callers are the session's writer and, under
-- the negative control that removes it, the driver.
forwardOne ∷ Env → Diag → IO Forwarded
forwardOne env diag = mask $ \restore → do
  claimed ← commit session (DiagClaim (dgId diag))
  if claimed == Refused
    then pure Unclaimed
    else
      tryWithContext @SomeException (restore (write (dgSay diag))) >>= \case
        -- (a negative control: a write that returned is never acknowledged, and so is counted as not delivered)
        Right () → Forwarded <$ unless (removed env ProtectAcknowledge) (void (commit session (DiagDone (dgId diag))))
        Left failure
          | isAsync failure → WriteCancelled failure <$ commit session (DiagInterrupt (dgId diag))
          | otherwise → do
              text ← sinkFailureText "a diagnostic could not be written" failure
              -- one commit keeps the diagnostic, failed, for the undelivered accounting and records the failure
              -- (a negative control acknowledges it like a success and records the failure beside it)
              if removed env ProtectKeepFailed
                then void (commit session (DiagDone (dgId diag))) >> void (commit session (DiagSinkFailed text))
                else void (commit session (DiagFailedWrite (dgId diag) text))
              pure WriteFailed
  where
    session = envSession env
    write (Say level message fields) = (case level of SayInfo → logInfo; SayError → logError) (sessionLogger session) sessionComponent message fields

-- | What a sink's failure says, forced before it is committed: the exception, bounded, and the cleanup failures its
-- context carries.
sinkFailureText ∷ Text → Caught → IO Text
sinkFailureText label failure@(ExceptionWithContext _ raised) = do
  main ← settledEntry HostFailure Nothing OnEngine (label <> ": " <> Text.take 512 (Text.pack (displayException raised)))
  carried ← contextEvidence failure
  pure (Text.intercalate "; " (eeMessage main : map (eeMessage . evEntry) carried))

-- | Whether the driver writes the diagnostics itself. Never in a real composition: only the negative controls that
-- remove the writer ('ProtectOffDriver') or the rule that a recovery path writes nothing ('ProtectRecovery'), which
-- is a rule about the driver's thread and so has none beside it.
driverWritesFor ∷ [Protection] → Bool
driverWritesFor removedProtections = ProtectOffDriver `elem` removedProtections || ProtectRecovery `elem` removedProtections

driverWrites ∷ Env → Bool
driverWrites = driverWritesFor . sessionRemoved . envSession

-- | The writer's body: the states of a writer, as a machine with one exit through one handler.
--
-- * /idle/: wait for a pending diagnostic (an STM wait) or for the writer to be cut off;
-- * /writing/: claim it and call the sink (the only call of the sink in a session);
-- * /delivered/: the sink returned and the write was acknowledged, then /idle/ again;
-- * /failed/: the sink raised: the diagnostic is kept, failed, and counted as undelivered at the cut-off, the failure is
--   evidence, and the writer ends (the sink is written no more);
-- * /cancelled/: the write was cancelled by someone but the session (the sink's own cancellation): the diagnostic is kept,
--   interrupted, the cancellation is evidence, and the writer ends;
-- * /abandoned/: the session cut the writer off, at any point (idle, writing, between two writes): it ends, and the
--   cut-off has already recorded what was not acknowledged.
--
-- Nothing that happens here reaches the driver: the writer's end, failure or cancellation is evidence at most, never an
-- exception that propagates (see 'writerThread', whose handler wraps this whole loop).
writeQueued ∷ Env → IO ()
writeQueued env = do
  next ← atomically $ do
    phase ← readTVar (wrPhase writer)
    state ← stateOf env
    case (phase, listToMaybe (pendingDiagnostics state)) of
      (WriterClosed, _) → pure Nothing
      (WriterOpen, Just diag) → pure (Just diag)
      (WriterOpen, Nothing) → retry
  forM_ next $ \diag →
    forwardOne env diag >>= \case
      Forwarded → probeAt env WriterBetween >> writeQueued env
      Unclaimed → writeQueued env
      WriteFailed → pure ()
      WriteCancelled cancelled → do
        abandoned ← (== WriterClosed) <$> readTVarIO (wrPhase writer)
        -- (a negative control: a cancellation the sink raised is taken for the session's own and forgotten)
        unless (abandoned || removed env ProtectCancelEvidence) (record "a diagnostic write was cancelled" cancelled)
  where
    writer = envWriter env
    record label caught = sinkFailureText label caught >>= void . commit (envSession env) . DiagSinkFailed

-- | The writer's thread: one handler wraps the whole loop, so that the abandonment is caught wherever it lands (while the
-- writer waits, while it writes, between the two), and an exception that is not the abandonment is evidence, never an
-- exception that escapes the thread to the uncaught-exception handler (which would write to a standard stream).
writerThread ∷ Env → (∀ x. IO x → IO x) → IO ()
writerThread env unmask
  -- (a negative control: no handler at the thread's boundary)
  | removed env ProtectWriterCatch = unmask (writeQueued env)
  | otherwise =
      tryWithContext @SomeException (unmask (writeQueued env)) >>= \case
        Right () → pure ()
        -- the only asynchronous exception this thread is thrown is the cut-off
        Left caught | isAsync caught → pure ()
        Left caught → do
          text ← sinkFailureText "the diagnostics writer failed" caught
          void (commit (envSession env) (DiagSinkFailed text))

-- | Start the session's writer, in the masked step that follows the installation of the outer continuation and precedes
-- the first diagnostic. The thread runs unmasked (the write is interruptible), and records that it has ended however it
-- does. A failure to start it is a failure of the composition, not of a sink; a writer that was never started is never
-- cancelled.
startWriter ∷ Env → IO ()
startWriter env = unless (driverWrites env) $ do
  probeAt env WriterStarting
  atomically (writeTVar (wrEnded writer) False)
  thread ← forkIOWithUnmask $ \unmask →
    writerThread env unmask `finally` atomically (writeTVar (wrEnded writer) True)
  -- (a negative control: the thread is not registered, and an idle writer is never found to be cancelled)
  unless (removed env ProtectWriterRegistration) (writeIORef (wrThread writer) (Just thread))
  probeAt env WriterStarted
  where
    writer = envWriter env

-- | The writer of a composition: not running until it is started.
newWriter ∷ IO Writer
newWriter = Writer <$> newTVarIO WriterOpen <*> newIORef Nothing <*> newTVarIO True <*> newTVarIO True

-- | Wait until the queue is written, or the writer has ended. Interruptible: it runs through the caller's @restore@. Only
-- under the negative control that removes the abandonment.
awaitWritten ∷ Env → IO ()
awaitWritten env = atomically $ do
  ended ← readTVar (wrEnded (envWriter env))
  state ← stateOf env
  check (ended || not (diagnosticsOutstanding state))

-- | Let the writer have the scheduler a bounded number of times, and wait for nothing: a writer that is not blocked can
-- write the last notes meanwhile, and one that is blocked is not waited for. This is a poll that always ends, not a wait on
-- the sink; nothing depends on how it ends, and what is not delivered is recorded.
grace ∷ Env → IO ()
grace env = go (graceYields ∷ Int)
  where
    go 0 = pure ()
    go n = do
      written ← atomically $ do
        over ← readTVar (wrEnded (envWriter env))
        state ← stateOf env
        pure (over || not (diagnosticsOutstanding state))
      unless written (yield >> go (n - 1))

graceYields ∷ Int
graceYields = 1000

-- | Cut the writer off: it writes nothing more, and the cancellation is delivered to it from a helper thread, because
-- delivery can block for as long as the writer is inside an uninterruptible region or a foreign call, and it never runs
-- on the requesting thread. The caller waits for neither. An interruptible write is cancelled where it is; one that is
-- not finishes by itself and the writer ends. Done once. The end of both threads is observable ('sessionDiagnosticsEnded').
abandonWriter ∷ Env → IO ()
abandonWriter env = do
  first ← atomically $ do
    phase ← readTVar (wrPhase writer)
    writeTVar (wrPhase writer) WriterClosed
    pure (phase == WriterOpen)
  when first $ do
    registered ← readIORef (wrThread writer)
    boundary env (WriterCutOff (isJust registered))
    forM_ registered $ \thread → do
      atomically (writeTVar (wrHelper writer) False)
      void (forkIO (throwTo thread WriterAbandoned `finally` atomically (writeTVar (wrHelper writer) True)))
  where
    writer = envWriter env

-- | The driver writes what is pending, on its own thread and outside every callback, stop pass and recovery commit.
-- Only under the negative controls that remove the writer. An interruption of the write is raised after the queue is
-- consistent.
forwardPending ∷ Env → IO ()
forwardPending env = do
  next ← atomically (listToMaybe . pendingDiagnostics <$> stateOf env)
  forM_ next $ \diag →
    forwardOne env diag >>= \case
      WriteCancelled interruption → rethrowIO interruption
      WriteFailed → pure ()
      _ → forwardPending env

-- | The final path of a driver that writes itself (a negative control): one protected attempt at each diagnostic still
-- pending, after the cleanup. A sink that raises is accounted and the rest are still written. A cancellation stops the
-- forwarding, is retained with the data unfinished and is not retried before it escapes. Answers whether every attempt
-- was made.
forwardFinal ∷ Env → IO Bool
forwardFinal env = do
  next ← atomically (listToMaybe . pendingDiagnostics <$> stateOf env)
  case next of
    Nothing → pure True
    Just diag →
      forwardOne env diag >>= \case
        WriteCancelled interruption → False <$ retain env interruption
        WriteFailed → pure True
        _ → forwardFinal env

-- | Whether a driver that writes itself (a negative control) may write diagnostics now: nothing has failed and nothing
-- is stopping. Once a failure or a stop is latched, the queue is held until the final path.
writable ∷ SessionState → Bool
writable state =
  not (stStopping state)
    && null (stFailureOrder state)
    && erPrimary (stEngine state) == Nothing
    && stTerminal state == Nothing

-- Running -------------------------------------------------------------------------------------------------

-- | Run one session to its end and answer how it came out.
--
-- The handle is given to the callback before any VM exists, so a stop, an interruption or a status read
-- can be wired to whoever needs them. The callback must not block. The call returns only once every role
-- has actually retired; what failed is in the outcome. A failure of the composition itself (a service that
-- is refused, an injected fault) is the outcome too, and a cancellation of the calling thread is raised again
-- after everything acquired has been released.
--
-- The entry is refused if the calling thread is uninterruptibly masked, before anything is acquired: the waits of the
-- protocol must stay interruptible, and no mask can be undone from inside one.
runSession ∷ SessionSpec → (Session → IO ()) → IO SessionOutcome
runSession spec onReady = do
  masking ← getMaskingState
  when (masking == MaskedUninterruptible) $
    throwIO (SessionRefused "a session cannot be run uninterruptibly masked: its waits must stay interruptible")
  let limits = failureLimitsOf (sxProfile spec)
      -- A checkpoint that holds no entry for a role it selects makes a session of no roles that has already failed.
      (roles, refusal) = either (\why → ([], Just why)) (\found → (found, Nothing)) (rolesOf spec)
      counted = [(riRole info, riInstances info) | info ← roles]
  registry ← newTVarIO emptyRegistry
  cell ← newTVarIO (newSessionState limits counted)
  writer ← newWriter
  let session = Session cell registry (sxLogger spec) ((&&) <$> readTVar (wrEnded writer) <*> readTVar (wrHelper writer)) (harnessProbe (sxHarness spec)) (harnessRelease (sxHarness spec)) (harnessRemoved (sxHarness spec)) (harnessHideSettlement (sxHarness spec))
  ids ← newInstanceIds
  seen ← newTVarIO Set.empty
  tracked ← newTVarIO Map.empty
  retained ← newIORef []
  serial ← newIORef 0
  identity ← newUnique
  raw ← newIORef []
  let env = Env spec session limits ids seen tracked (Map.fromList [(riRole info, info) | info ← roles]) retained serial identity raw writer
  -- The outer continuation is installed before the handle is given away, before any diagnostic, clock or construction.
  -- The writer is started in the next masked step, before the first diagnostic: from there on a diagnostic is data in the
  -- lifecycle record, and nothing the driver does waits for it to be written. A failure to start it is a failure of the
  -- composition.
  mask $ \restore → do
    registerSessionRelease env ReleaseComposition (sessionRelease session ReleaseComposition)
    started ← tryWithContext @SomeException (startWriter env)
    result ← case started of
      Left failure → pure (Left failure)
      Right () → tryWithContext @SomeException . restore $ do
        onReady session
        void (commit session (Note (Say SayInfo "session starting" [("roles", Text.intercalate "," (map (roleWord . riRole) roles))])))
        when (driverWrites env) (forwardPending env)
        case refusal of
          Just why → void (applyEvent session (EngineFault Nothing (engineEntry HostFailure Nothing OnEngine why)))
          Nothing → conduct env roles
    finish env restore result `onException` abandonWriter env

-- | However the composition came out: account its exception whole with every cleanup failure attached to it, run the
-- protocol once more as the safety net it is, finish the session-level releases, say that the session ended unless a
-- cancellation arrived, abandon the writer and record what it had not delivered, and then raise or return. Masked
-- throughout; the waits run through @restore@ and stay interruptible.
--
-- Everything that is lifecycle is over before the first of those steps, and none of them waits for the sink (D-87):
-- every role has retired, every release has run and the outcome is readable. The writer gets the scheduler a bounded
-- number of times to write the last notes, and is then cancelled; what it had not delivered is evidence in the outcome.
finish ∷ Env → (∀ x. IO x → IO x) → Either Caught () → IO SessionOutcome
finish env restore result = do
  forM_ (either pure (const []) result) (void . adopt env)
  teardown env restore Nothing
  runSessionReleases env
  cancelled ← any (isAsync . rtCaught) <$> readIORef (envRetained env)
  if driverWrites env
    then unless cancelled $ do
      completed ← guarded (restore (forwardFinal env))
      when completed $ do
        ended
        void (guarded (restore (forwardFinal env)))
    else do
      unless cancelled ended
      -- (a negative control: the call waits for the writer to write the queue, as a blocking wait)
      if removed env ProtectAbandon
        then probeAt env WriterWait >> void (guarded (True <$ restore (awaitWritten env)))
        else unless cancelled (grace env)
      -- the cut-off: one commit closes the queue and records what was not acknowledged; then the writer is cancelled, and
      -- nothing waits for it
      boundary env CuttingOff
      void . commit session . DiagCutOff $
        if cancelled then "the caller was cancelled" else "the session returned with the diagnostics writer still working"
      abandonWriter env
  raiseRetained env
  atomically (outcomeOf <$> readTVar (sessionState session))
  where
    session = envSession env
    -- an exception that lands outside the forwarding itself is retained like any other, and ends the forwarding
    guarded action = tryWithContext @SomeException action >>= either (\failure → False <$ retain env failure) pure
    -- the verdict is said once everything before it has been done
    ended = do
      outcome ← atomically (outcomeOf <$> readTVar (sessionState session))
      void . commit session . Note $
        Say SayInfo "session ended" [("verdict", Text.pack (show (outVerdict outcome))), ("failures", Text.pack (show (length (outFailures outcome))))]

-- | Raise what the session retained, if anything: the first cancellation as itself, otherwise the first exception
-- caught, with every other exception and every cleanup failure not already in its context kept whole beside it.
-- A session that retained nothing returns.
raiseRetained ∷ Env → IO ()
raiseRetained env = do
  retained ← readIORef (envRetained env)
  raws ← readIORef (envRaw env)
  case (find (isAsync . rtCaught) retained, retained) of
    (Just chosen, _) → raiseWith chosen retained raws
    (Nothing, first : _) → raiseWith first retained raws
    (Nothing, []) → pure ()
  where
    raiseWith chosen retained raws = do
      let known = Set.fromList [evidenceKeyOf item | kept ← retained, (item, _, _) ← cleanupDeep (rtCaught kept)]
          beside = [("lua session", rtCaught other) | other ← retained, rtSerial other /= rtSerial chosen]
          extra = [(label, inner) | RawEvidence key label inner ← raws, maybe True (`Set.notMember` known) key]
      composeCleanup (Just (rtCaught chosen)) (beside <> extra) >>= maybe (rethrowIO (rtCaught chosen)) rethrowIO

-- | The roles a checkpoint selects, with what each loads, or why it cannot be read.
rolesOf ∷ SessionSpec → Either Text [RoleInfo]
rolesOf spec = case manifestRoles manifest of
  GameplayOnly g → sequence [gameplayInfo g]
  PresentationOnly p → sequence [presentationInfo p]
  BothRoles g p → sequence [gameplayInfo g, presentationInfo p]
  where
    checkpoint = sxCheckpoint spec
    manifest = checkpointManifest checkpoint
    content = Text.decodeUtf8Lenient (rootKeyBytes (inventoryRootKey (sxInventory spec)))
    second role = if role `elem` harnessSecond (sxHarness spec) then 2 else 1
    entryOf role = maybe (Left ("the checkpoint holds no entry for the " <> roleWord role <> " role")) Right (lookup role (checkpointRoleEntries checkpoint))
    gameplayInfo g = (\entry → RoleInfo Gameplay content entry (gameplayEntry g) (Just (gameplayTick g)) (second Gameplay)) <$> entryOf Gameplay
    presentationInfo p = (\entry → RoleInfo Presentation content entry (presentationEntry p) Nothing (second Presentation)) <$> entryOf Presentation

-- | Build, validate, admit and drive.
conduct ∷ Env → [RoleInfo] → IO ()
conduct env roles = do
  stopped ← isStopping env
  unless stopped $
    preflight env roles >>= \case
      Just entry → void (applyEvent (envSession env) (EngineFault (eeRole entry) entry))
      Nothing → build roles []
  where
    build [] built = operate env (reverse built)
    build (info : rest) built = withRoleVm env info (\vm → build rest (vm : built))

-- | What can be impossible before any Lua runs: a harness asking for a second instance of a role the session
-- does not have, and a first logical deadline the clock cannot count.
preflight ∷ Env → [RoleInfo] → IO (Maybe EngineEntry)
preflight env roles
  | Just missing ← find (`notElem` map riRole roles) (harnessSecond (sxHarness spec)) =
      pure (Just (engineEntry HostFailure (Just missing) OnEngine "the harness asked for a second instance of a role the session does not have"))
  | otherwise = case [(riRole info, tick) | info ← roles, Just tick ← [riTick info]] of
      [] → pure Nothing
      (role, tick) : _ → do
        now ← readInstant (sxClock spec)
        pure (either (\fault → Just (engineEntry HostFailure (Just role) OnEngine (pacingFaultText fault))) (const Nothing) (initialDeadline now tick))
  where
    spec = envSpec env

-- | With every role built: evaluate each entry, admit each role's instances, and drive. The driver's state, and
-- its timer, are made first: the waits of every step go through one supervision mode, so a failure supervision
-- delivers at the first of them is accounted once, and every wait after it is raw. The timer's disposal is a finite
-- release registered with the session in the step that makes it, and is run once, after every role has finished.
-- A failure of the driver itself (a probe, a defect) is not recorded here: it propagates, and the protocol
-- that every scope runs on the way out closes the gates, stops every owner and accounts it first.
operate ∷ Env → [RoleVm] → IO ()
operate env vms = do
  timer ← mask_ $ do
    made ← newTimer (envIdentity env) (sxTimer (envSpec env))
    registerSessionRelease env ReleaseTimer (sessionRelease (envSession env) ReleaseTimer `both` disposeTimer made)
    pure made
  driver ←
    Driver
      <$> newIORef Supervised
      <*> newIORef Nothing
      <*> newIORef Nothing
      <*> newIORef Set.empty
      <*> newIORef Set.empty
      <*> newIORef Set.empty
      <*> newIORef False
      <*> pure timer
  stopped ← isStopping env
  unless stopped (bootEntries env vms driver)
  stopped' ← isStopping env
  unless stopped' (forM_ vms (admitRole env))
  void (applyEvent (envSession env) AdmissionComplete)
  drive env vms driver

-- | Run two finite releases, both, whatever the first does; raise the first failure with the second kept beside it.
both ∷ IO () → IO () → IO ()
both first second = do
  a ← tryWithContext @SomeException first
  b ← tryWithContext @SomeException second
  case (a, b) of
    (Right (), Right ()) → pure ()
    (Left failure, Right ()) → rethrowIO failure
    (Right (), Left failure) → rethrowIO failure
    (Left failure, Left other) → composeCleanup (Just failure) [("release", other)] >>= maybe (rethrowIO failure) rethrowIO

isStopping ∷ Env → IO Bool
isStopping env = stStopping <$> readTVarIO (sessionState (envSession env))

-- Evaluating the entries ---------------------------------------------------------------------------------

-- | Evaluate each selected entry, with its imports, in its own VM, running no instance. Every boot load is
-- asked before any is waited for, so the VMs evaluate side by side. A failure is a boot failure and neither
-- root is ever dispatched: it is latched, and its policy applied, the moment its entry's outcome arrives,
-- whichever entry that is and whatever the other is still doing. The wait ends when every entry has answered or
-- the session is stopping, in which case what is left is drained by the owners' stop and the scopes that
-- follow it.
bootEntries ∷ Env → [RoleVm] → Driver → IO ()
bootEntries env vms driver = do
  asked ← forM vms $ \vm → (,) vm <$> bootModule (rvCoordinator vm) (riEntry (rvInfo vm))
  pending ← fmap catMaybes . forM asked $ \(vm, ticket) → case ticket of
    Left refusal → Nothing <$ failed vm ("the entry module's boot load was refused: " <> Text.pack (show refusal)) (riEntryPath (rvInfo vm)) Nothing
    Right found → pure (Just (vm, found))
  collect pending
  where
    collect [] = pure ()
    collect pending = do
      arrived ← waitFor env vms driver (firstArrival pending)
      case arrived of
        Nothing → pure ()
        Just ((vm, outcome), rest) → do
          case outcome of
            BootReady → pure ()
            BootStopped → pure ()
            BootFailed found → failed vm (Modules.failureMessage found) (Modules.failurePath found) (Modules.failureTraceback found)
          collect rest
    -- The first entry to have answered, with the entries still to answer; or, while none has, whether the session
    -- is stopping.
    firstArrival = go []
      where
        go _ [] = stateOf env >>= \s → if stStopping s then pure Nothing else retry
        go passed ((vm, found) : rest) =
          ((Just <$> awaitBoot found) `orElse` pure Nothing) >>= \case
            Just outcome → pure (Just ((vm, outcome), reverse passed <> rest))
            Nothing → go ((vm, found) : passed) rest
    failed vm text path traceback = do
      let info = rvInfo vm
          record =
            boundFailure
              (envLimits env)
              (newRoleFailure ModuleError OnModule (riRole info) text)
                { rfContent = Just (riContent info)
                , rfPath = Just path
                , rfTraceback = traceback
                }
      void (applyEvent (envSession env) (LatchFailure (riRole info) record []))

-- Admitting the instances ---------------------------------------------------------------------------------

-- | Admit a role's instances in order. Each admission is intended before it is issued and tracked before the
-- instance can run, and a stop that lands between any two of those steps takes the intent back whole.
admitRole ∷ Env → RoleVm → IO ()
admitRole env vm = forM_ [0 .. riInstances (rvInfo vm) - 1] (admitOne env vm)

admitOne ∷ Env → RoleVm → Int → IO ()
admitOne env vm slot = mask $ \restore → do
  -- The intent is a recovery-style commit: no probe is told inside it. From the moment it is committed it is resolved
  -- exactly once, by being tracked or abandoned, whatever follows it (the probe beside it included), so the role can
  -- always retire.
  granted ← commit session (Intend role)
  unless (granted == Refused) $ do
    settled ← newIORef False
    identity ← newIORef Nothing
    let abandon = do
          already ← atomicModifyIORef' settled (\done → (True, done))
          unless already $ do
            readIORef identity >>= mapM_ (forgetInstance (rvFacade vm))
            void (commit session (Abandoned role))
        protected action = tryWithContext @SomeException action >>= either (\failure → abandon >> rethrowIO failure) pure
    protected $ do
      restore (probeAt env (Committed "Intend"))
      declared ←
        declareInstance (rvFacade vm) (riContent info) >>= \case
          Left refused → throwIO (SessionRefused ("an instance could not be declared: " <> Text.pack (show refused)))
          Right found → pure found
      writeIORef identity (Just (declaredId declared))
      restore (probeAt env (Intended key))
      admitted ← admitBehaviorInstance (rvEndpoint vm) (request declared)
      case admitted of
        InstanceAccepted found ticket → do
          -- The owner may already be starting the instance; its first hook waits for the tracking below, so
          -- nothing it does can run before it is tracked, whatever lands in this window.
          let track = do
                atomically (modifyTVar' (envTracked env) (Map.insert found (Held key found ticket (declaredId declared))))
                already ← atomicModifyIORef' settled (\done → (True, done))
                unless already (void (commit session (Tracked role)))
          restore (probeAt env (Issued key)) `finally` track
          restore (probeAt env (Tracking key))
        other → do
          abandon
          case other of
            InstanceAdmissionClosed → pure ()
            _ → throwIO (SessionRefused ("an instance was not admitted: " <> Text.pack (take 200 (show other))))
  where
    session = envSession env
    info = rvInfo vm
    role = riRole info
    key = InstanceKey role slot
    request declared =
      behaviorRequest role (moduleIdentity (riEntry info)) (riEntryPath info) (declaredFacade declared) (Just (declaredId declared)) ordinary
    ordinary = OrdinaryClass

-- Driving ------------------------------------------------------------------------------------------------------

-- | Whether the driver's waits are supervised: they are until supervision latches a fatal failure, after
-- which every supervised wait raises it again and the drain waits on raw outcomes instead.
data Mode = Supervised | Raw

-- | What the driver does next.
data Next
  = NextStops
  | NextResume ![Held]
  | NextOrigin !Instant
  | NextRole !RoleStep
  | NextInit ![Held]
  | NextSettled ![Held]
  | NextSay !Diag
  | NextWake
  | NextFinished
  | NextAccounted !AccountingWait
  | NextDone

-- | A grant that was issued and not yet finished, one the scheduler answered full, or a tick that has finished and
-- whose accounting the driver is watching for as one more thing its single wait observes (a held provider retirement
-- can extend that accounting for as long as it likes, and nothing else waits behind it).
data InFlight = Granted | Full | Accounting

-- | The driver's own state, which only the driver reads or writes.
data Driver = Driver
  { dvMode ∷ !(IORef Mode)
  , dvSchedule ∷ !(IORef (Maybe Schedule))
  , dvInFlight ∷ !(IORef (Maybe InFlight))
  , dvInit ∷ !(IORef (Set InstanceKey))
  , dvSettled ∷ !(IORef (Set InstanceKey))
  , dvReleased ∷ !(IORef (Set InstanceKey))
  -- ^ The held instances the driver has released.
  , dvOriginTaken ∷ !(IORef Bool)
  -- ^ Whether the schedule has been derived from the origin the start gate recorded.
  , dvTimer ∷ !Timer
  }

-- | The driver: wait for what happens, in one transaction composed with supervision, and act on it, until
-- every role has finished.
drive ∷ Env → [RoleVm] → Driver → IO ()
drive env vms driver = loop `finally` forM_ (find ((== Gameplay) . riRole . rvInfo) vms) (atomically . unwatchScheduledAccounting . rvOwner)
  where
    spec = envSpec env
    loop = do
      arm
      stm ← nextStep env vms driver
      next ← waitFor env vms driver stm
      case next of
        NextDone → pure ()
        _ → act env vms driver next >> loop
    -- The timer matches the next tick's due time while the logical role takes ticks and none is in flight.
    arm = do
      schedule ← readIORef (dvSchedule driver)
      inFlight ← readIORef (dvInFlight driver)
      open ← atomically (gameplayTakes env)
      syncTimer (dvTimer driver) (sxClock spec) $ case (schedule, inFlight) of
        (Just current, Nothing) | open → Just (scDue current)
        _ → Nothing

-- | Whether the logical role takes ticks: its admission is open, the session is not stopping and the start gate
-- is open.
gameplayTakes ∷ Env → STM Bool
gameplayTakes env = do
  state ← stateOf env
  pure (roleAdmit Gameplay state == AdmitOpen && not (stStopping state) && stStart state == StartOpen)

-- | Wait for the next thing to do. Supervised until supervision delivers a fatal failure; then the failure is
-- accounted and every wait that follows is raw, since a latched failure is raised again by each supervised
-- one.
waitFor ∷ Env → [RoleVm] → Driver → STM a → IO a
waitFor env vms driver stm = readIORef (dvMode driver) >>= \case
  Raw → atomically stm
  Supervised →
    tryWithContext @SomeException (awaitSupervised (sxControl (envSpec env)) stm) >>= \case
      Right next → pure next
      Left failure
        | isAsync failure → rethrowIO failure
        | otherwise → do
            writeIORef (dvMode driver) Raw
            supervisionFailed env vms failure
            atomically stm

-- | Supervision delivered a failure. A session owner's own outcome is accounted when it is finalized, once, from its
-- raw completion; every other worker's failure the delivery carries is accounted here, each by the identity of the
-- worker whose outcome it is, and the session ends because of it.
--
-- Which failures are another worker's is read from the outcomes' own identities, never from which owner looks fatal
-- or from the order a batch was committed in. A delivery is the latched primary with every other failure the
-- invocation committed retained beside it, each with its worker's id; the primary is never repeated among them. So a
-- fatal owner of the session that is not among the retained ones is the primary, and the primary is then the
-- owner's, accounted at its finalization; when every fatal owner is among the retained ones, or none is fatal, the
-- primary is another worker's. Each foreign failure carries a key made of its worker's id, so that a repeated
-- delivery accounts it once.
supervisionFailed ∷ Env → [RoleVm] → Caught → IO ()
supervisionFailed env vms failure@(ExceptionWithContext context _) = do
  -- A failure supervision latched ends the session whoever's it is: the gates close and every owner is asked to
  -- stop now, which also ends a wait for an entry whose owner can no longer evaluate it.
  void (applyEvent (envSession env) Unwind)
  owners ← atomically (forM vms (\vm → (,) (workerOf vm) <$> Supervision.workerStatus (scheduledSupervised (rvOwner vm))))
  let retained = Supervision.supervisedFailuresInContext context
      retainedIds = map Supervision.failedWorker retained
      ownerIds = map fst owners
      primaryIsOurs = or [isFatal status | (wid, status) ← owners, wid `notElem` retainedIds]
      strangers = [found | found ← retained, Supervision.failedSeverity found == Supervision.Fatal, Supervision.failedWorker found `notElem` ownerIds]
  primary ← if primaryIsOurs then pure [] else evidenceFrom env True failure
  others ← forM strangers $ \found →
    keyed (evidenceKeyOf ("supervised worker " <> show (Supervision.failedWorker found)))
      <$> caughtEvidence HostFailure Nothing OnEngine ("another worker failed: " <> Supervision.failedLabel found) (Supervision.failedException found)
  let evidence = primary <> concat others
  unless (null evidence) (void (commit (envSession env) (Account evidence)))
  where
    workerOf vm = workerId (supervisedWorker (scheduledSupervised (rvOwner vm)))
    keyed key = \case
      first : rest → first {evKey = Just key} : rest
      [] → []
    isFatal = \case
      Supervision.WorkerFatal _ → True
      _ → False

-- | The transaction the driver waits in. The first that applies is the answer: a stop owed that can be handed over,
-- a release of the held instances, the pacing origin, the next step of a role's retirement, an @init@ that
-- succeeded, an instance that ended, whether every role has finished, (under the negative control that removes the writer,
-- a diagnostic to write while nothing has failed), the timer's wake while ticks are due, a grant that has finished.
nextStep ∷ Env → [RoleVm] → Driver → IO (STM Next)
nextStep env vms driver = do
  inited ← readIORef (dvInit driver)
  settled ← readIORef (dvSettled driver)
  schedule ← readIORef (dvSchedule driver)
  inFlight ← readIORef (dvInFlight driver)
  released ← readIORef (dvReleased driver)
  originTaken ← readIORef (dvOriginTaken driver)
  pure $ do
    held ← Map.elems <$> readTVar (envTracked env)
    state ← stateOf env
    owing ← stopsRunnable (envSession env)
    -- The dispatch gate opened: the instances held after their validation are released, together, unless
    -- their role has stopped taking work.
    let toRelease =
          [ item
          | dispatchDecision state == Just True
          , not (stStopping state)
          , item ← held
          , hdKey item `Set.notMember` released
          , roleAdmit (ikRole (hdKey item)) state == AdmitOpen
          ]
        origin = if originTaken then Nothing else stOrigin state
        say = if driverWrites env && writable state then listToMaybe (pendingDiagnostics state) else Nothing
    roleStep ← nextRoleStep env Nothing
    started ← catMaybes <$> mapM (observe inited Active) held
    stopped ← catMaybes <$> mapM (observeSettled settled) held
    open ← gameplayTakes env
    woken ← case (schedule, inFlight) of
      (Just _, Nothing) | open → timerWoken (dvTimer driver)
      _ → pure False
    outstanding ← case (inFlight, find ((== Gameplay) . riRole . rvInfo) vms) of
      (Just Accounting, _) → pure (False, False)
      (Just _, Just vm) → (,) <$> ((== 0) <$> ticksOutstanding (rvEndpoint vm)) <*> ownerEnded vm
      _ → pure (False, False)
    -- the accounting of a finished tick, watched since it finished: the last thing the wait looks at, so that every
    -- stop, role step, instance event and diagnostic comes first
    accounted ← case (inFlight, find ((== Gameplay) . riRole . rvInfo) vms) of
      (Just Accounting, Just vm) → (Just <$> scheduledAccountingStep (rvOwner vm)) `orElse` pure Nothing
      _ → pure Nothing
    case () of
      _
        | owing → pure NextStops
        | not (null toRelease) → pure (NextResume toRelease)
        | Just instant ← origin → pure (NextOrigin instant)
        | Just found ← roleStep → pure (NextRole found)
        | not (null started) → pure (NextInit started)
        | not (null stopped) → pure (NextSettled stopped)
        | rolesFinished state → pure NextDone
        | Just diag ← say → pure (NextSay diag)
        | woken → clearTimerWake (dvTimer driver) >> pure NextWake
        | fst outstanding || snd outstanding → pure NextFinished
        | Just found ← accounted → pure (NextAccounted found)
        | otherwise → retry
  where
    observe inited want item
      | hdKey item `Set.member` inited = pure Nothing
      | otherwise = snapshotOf item >>= \snapshot → pure $ case snapshot of
          Just found | snapshotPhase found `elem` [want, Paused] → Just item
          _ → Nothing
    observeSettled settled item
      | hdKey item `Set.member` settled = pure Nothing
      | otherwise = snapshotOf item >>= \snapshot → pure $ case snapshot of
          Just found | isTerminalPhase (snapshotPhase found) → Just item
          _ → Nothing
    -- The owner's snapshot of a tracked instance; a role the session has no VM for holds none.
    snapshotOf item = case find ((== ikRole (hdKey item)) . riRole . rvInfo) vms of
      Just vm → inspectInstance (rvEndpoint vm) (hdId item)
      Nothing → pure Nothing
    isTerminalPhase phase = phase `elem` [Completed, Stopped, Hetoimasia.Scripting.Lua.Instance.Failed]

-- | Whether a role's owner has ended: its worker's raw completion, which supervision's latch never hides.
ownerEnded ∷ RoleVm → STM Bool
ownerEnded vm = (awaitCompletion (supervisedWorker (scheduledSupervised (rvOwner vm))) >> pure True) `orElse` pure False

-- | Act on what happened.
act ∷ Env → [RoleVm] → Driver → Next → IO ()
act env vms driver = \case
  NextDone → pure ()
  NextStops → stopPass session
  NextResume items → forM_ items $ \item → do
    modifyIORef' (dvReleased driver) (Set.insert (hdKey item))
    void (releaseHeldInstance (hdTicket item))
    probeAt env (Resumed (hdKey item))
  NextOrigin origin → do
    writeIORef (dvOriginTaken driver) True
    startPacing origin
  NextRole found → performStep env (probeAt env) found
  NextSay diag →
    forwardOne env diag >>= \case
      WriteCancelled interruption → rethrowIO interruption
      _ → pure ()
  NextInit items → forM_ items $ \item → do
    modifyIORef' (dvInit driver) (Set.insert (hdKey item))
    initSucceeded item
  NextSettled items → forM_ items $ \item →
    pollInstance (hdTicket item) >>= \case
      Nothing → pure ()
      Just settlement → do
        modifyIORef' (dvSettled driver) (Set.insert (hdKey item))
        already ← Set.member (hdKey item) <$> readIORef (dvInit driver)
        when (not already && ifInitialized (factOf settlement)) $ do
          modifyIORef' (dvInit driver) (Set.insert (hdKey item))
          initSucceeded item
  NextWake → do
    now ← readInstant (sxClock spec)
    schedule ← readIORef (dvSchedule driver)
    forM_ schedule $ \current → when (deadlineReached now (scDue current)) (grant current)
  NextFinished → do
    inFlight ← readIORef (dvInFlight driver)
    mode ← readIORef (dvMode driver)
    case (inFlight, mode, vmOf Gameplay) of
      -- (a negative control: the driver waits for the accounting by itself, as a blocking call)
      (Just Granted, Supervised, Just vm) | removed env ProtectAccountingEvent → do
        writeIORef (dvInFlight driver) Nothing
        probeAt env AccountingWait
        waited ← tryWithContext @SomeException (awaitScheduledAccounting (sxControl spec) (rvOwner vm)) >>= \case
          Right found → pure found
          Left failure
            | isAsync failure → rethrowIO failure
            | otherwise → do
                writeIORef (dvMode driver) Raw
                supervisionFailed env vms failure
                pure AccountingOwnerEnded
        schedule ← readIORef (dvSchedule driver)
        case (waited, schedule) of
          (AccountingComplete, Just current) → case afterGrant current of
            Left fault → void (applyEvent session (EngineFault (Just Gameplay) (engineEntry HostFailure (Just Gameplay) OnEngine (pacingFaultText fault))))
            Right next → writeIORef (dvSchedule driver) (Just next)
          _ → pure ()
      -- the tick's accounting is watched from here and observed by the driver's one wait; the next grant waits for it
      (Just Granted, Supervised, Just vm) → do
        atomically (watchScheduledAccounting (rvOwner vm))
        writeIORef (dvInFlight driver) (Just Accounting)
      _ → writeIORef (dvInFlight driver) Nothing
  NextAccounted waited → do
    forM_ (vmOf Gameplay) (atomically . unwatchScheduledAccounting . rvOwner)
    writeIORef (dvInFlight driver) Nothing
    schedule ← readIORef (dvSchedule driver)
    case (waited, schedule) of
      (AccountingComplete, Just current) → case afterGrant current of
        Left fault → void (applyEvent session (EngineFault (Just Gameplay) (engineEntry HostFailure (Just Gameplay) OnEngine (pacingFaultText fault))))
        Right next → writeIORef (dvSchedule driver) (Just next)
      _ → pure ()
  where
    session = envSession env
    spec = envSpec env
    vmOf role = find ((== role) . riRole . rvInfo) vms
    initSucceeded item = do
      now ← readInstant (sxClock spec)
      void (applyEvent session (InitSucceeded (hdKey item) (Just now)))
    -- The start gate opened: the pacing origin is the clock's reading taken just before the transition that
    -- opened it, so the time the @init@s took earns no logical time and leaves no debt, and nothing the
    -- transition's diagnostics wait for moves it.
    startPacing origin = forM_ (vmOf Gameplay) $ \vm → forM_ (riTick (rvInfo vm)) $ \tick →
      case startSchedule (harnessTickBase (sxHarness spec)) origin tick of
        Left fault → void (applyEvent session (EngineFault (Just Gameplay) (engineEntry HostFailure (Just Gameplay) OnEngine (pacingFaultText fault))))
        Right schedule → writeIORef (dvSchedule driver) (Just schedule)
    -- Grant the next tick: the check of the logical role's admission and the scheduler's acceptance are one transaction
    -- (D-85), so a closure committed before it is seen by it and a grant it accepts was accepted before the closure, and
    -- no lock is held across injected work. (A negative control makes them two, with a point between.)
    grant current = forM_ (vmOf Gameplay) $ \vm → case nextTickNumber current of
      Left fault → void (applyEvent session (EngineFault (Just Gameplay) (engineEntry HostFailure (Just Gameplay) OnEngine (pacingFaultText fault))))
      Right number → do
        probeAt env (GrantIntent number)
        answer ←
          if removed env ProtectGrantAtomic
            then do
              open ← atomically (gameplayTakes env)
              probeAt env (GrantChecked number)
              if open then Just <$> grantScheduledStep (rvEndpoint vm) (scTick current) else pure Nothing
            else atomically $ do
              open ← gameplayTakes env
              if open then Just <$> grantScheduledStepSTM (rvEndpoint vm) (scTick current) else pure Nothing
        case answer of
          Nothing → pure ()
          Just (GrantAccepted _) → writeIORef (dvInFlight driver) (Just Granted) >> probeAt env (GrantIssued number)
          Just GrantFull → writeIORef (dvInFlight driver) (Just Full)
          Just GrantClosed → pure ()
          Just GrantNotPositive →
            void (applyEvent session (EngineFault (Just Gameplay) (engineEntry HostFailure (Just Gameplay) OnEngine "a tick duration the manifest checked was not positive")))
