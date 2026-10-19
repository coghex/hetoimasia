-- | The run itself: reading the scripts, starting the VM, admitting the instances, waiting for the
-- run to end, ending it in order and answering.
--
-- "Hetoimasia.Scripting.Lua.Runner" documents the behavior; this module is where it is done. The
-- shape of it is a few single places every path goes through:
--
-- * one wait ('awaitStep'), composed in STM with supervision, which is the only place the run
--   waits: it sees a failure to report, every instance having ended, the stop request, the owner's
--   exit, the tick limit and the duration limit's wake, in that order of precedence, and then
--   whatever the step the run is in is waiting for (the admission of a script, the tick that is due,
--   the tick that has completed);
-- * one function that takes the failures not yet reported ('takeFailures') and one that writes
--   them, so a failure is written exactly once whichever wake or ending finds it;
-- * one retirement ('retireOwner'), run when the run ends and again on every other way out, which
--   is idempotent: stopping the owner asks it once and waiting for it is waiting for a terminal
--   status.
module Hetoimasia.Scripting.Lua.Runner.Run
  ( RunnerInternals (..)
  , noInternals
  , RunnerBug (..)
  , runWith
  ) where

import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry, throwSTM, writeTVar)
import Control.Exception (Exception, ExceptionWithContext (ExceptionWithContext), SomeException, finally, fromException, mask, onException, rethrowIO, throwIO, tryWithContext)
import Control.Monad (forM, forM_, unless, void, when)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (elemIndex)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe, isJust)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Foundation.Log (Component, logInfo, unsafeComponent, withFields)
import Hetoimasia.Foundation.Resource (withResource)
import Hetoimasia.Foundation.Worker (awaitCompletion)
import Hetoimasia.Foundation.Time (Duration, Instant, addDuration, deadlineReached, readInstant, zeroDuration)
import Hetoimasia.Runtime.Supervision
  ( Disposition (Optional)
  , Recognition (Recognized, Unrecognized)
  , Role (Service)
  , WorkerPolicy (..)
  , WorkerStatus (WorkerLive)
  , awaitSupervised
  , supervisedWorker
  )
import Hetoimasia.Scripting.Lua.Instance
  ( EventSource
  , InstanceAdmission (InstanceAccepted, InstanceAdmissionClosed, InstanceFull, InstanceIntervalRefused)
  , InstanceRequest (..)
  , Interval (ElapsedEvery, LogicalTicks)
  , admitInstance
  , hookEntries
  , inspectInstances
  , moduleHooks
  )
import Hetoimasia.Scripting.Lua.Instance.Types
  ( ControlAdmission (AdmitLogically, AdmitOnArrival)
  , ControlSlot (ControlSlot)
  , Escalation (Isolate)
  , ICell (icResult)
  , InstanceConfig (..)
  , InstanceId (..)
  , InstanceKind (EventOnly, Periodic, RunOnce)
  , InstanceOutcome (InstanceCompleted, InstanceDiscarded, InstanceFailed, InstanceStopped)
  , InstancePhase (Initializing, Stopping)
  , InstanceSettlement (..)
  , InstanceSnapshot (..)
  , InstanceTicket (..)
  , ModuleHooks (..)
  , ShutdownDisposition (ShutdownSkippedNoInit)
  , Termination (terminationShutdown)
  )
import Hetoimasia.Scripting.Lua.Internal.Fault (raisedByApplication)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits (ServiceClass (OrdinaryClass))
import Hetoimasia.Scripting.Lua.Lifecycle
  ( GrantTarget (..)
  , GrantedOwner (GrantedSelf)
  , Permit (PermitControl, PermitInspect)
  , lifecycleGrant
  , lifecycleNamespace
  )
import Hetoimasia.Scripting.Lua.Provider
  ( RequestGrant (RequestGrant, grantEndpoints, grantRequestBound, grantTiming)
  , RequestTiming (SettleAtAssignedTick, SettleOnArrival)
  , SubscriptionDiagnostics (sdFailures)
  , SubscriptionGrant (SubscriptionGrant, grantEvents, grantStagingBound, grantSubscriptionBound)
  , subscriptionDiagnostics
  )
import Hetoimasia.Scripting.Lua.Owner
  ( BoundaryFault (boundaryModule, boundaryOperation, boundaryReason, boundaryTraceback)
  , ErrorValue (ErrorAbsent, ErrorMessage, ErrorOpaque)
  , FaultOperation (LoadModule)
  , FaultReason (ModuleRefused, ScriptFailed)
  , Library (LibraryBase, LibraryCoroutine, LibraryMath, LibraryString, LibraryTable)
  , ModuleRef
  , ModuleSource (ModuleSource)
  , VmConfig (vmInitialChunks, vmModules, vmOwnerName, vmPolicy, vmRegistration)
  , chunkName
  , vmConfig
  )
import Hetoimasia.Scripting.Lua.Registration (Namespace, namespaceName, registration)
import Hetoimasia.Scripting.Lua.Runner.Events
import Hetoimasia.Scripting.Lua.Runner.Gate
import Hetoimasia.Scripting.Lua.Runner.Output (outputChunk, outputNamespace, outputNamespaceName)
import Hetoimasia.Scripting.Lua.Runner.Render
import Hetoimasia.Scripting.Lua.Runner.Source (ReadProblem (..), defaultName, distinctPaths, moduleRefFor, readSources)
import Hetoimasia.Scripting.Lua.Runner.Types
import Hetoimasia.Scripting.Lua.Scheduled.Shared (awaitWorkerEnded, propagateAll)
import Hetoimasia.Scripting.Lua.Runtime.Shared (LuaRuntime (runtimeControl))
import Hetoimasia.Scripting.Lua.Scheduled
  ( ScheduledEndpoint
  , ScheduledOwner
  , ScheduledSpec (..)
  , ScheduledStart (..)
  , retireScheduled
  , GrantAnswer (GrantAccepted, GrantClosed, GrantFull, GrantNotPositive)
  , grantScheduledStep
  , scheduledEndpoint
  , scheduledSpec
  , scheduledStatus
  , scheduledSupervised
  , scheduledTick
  , startScheduledOwner
  , ticksOutstanding
  )
import Hetoimasia.Scripting.Lua.Scheduler.Timer (Timer, clearTimerWake, disposeTimer, newTimer, syncTimer, timerWoken)

runnerComponent ∷ Component
runnerComponent = unsafeComponent "scripting.lua.runner"

-- | What only a test, and the follow-on slice that adds the runner's events, reaches. None of it is
-- part of the runner's contract, and 'noInternals' is what every run of the public runner has.
data RunnerInternals = RunnerInternals
  { internalSources ∷ [EventSource]
    -- ^ Event sources the owner offers, which a test delivers to through the endpoint it is handed.
  , internalGrants ∷ [Text]
    -- ^ The sources each instance's @api@ may connect a function to.
  , internalNamespaces ∷ [Namespace]
    -- ^ Bindings beside the runner's own, granted to every script.
  , internalAdmitted ∷ ScheduledEndpoint → [(InstanceId, InstanceTicket)] → IO ()
    -- ^ Told, once, after every instance has been admitted and before the run waits: the owner's
    -- endpoint and the instances with their tickets, in script order.
  }

-- | Nothing beyond the runner's own: no source, no grant, no namespace, nobody told.
noInternals ∷ RunnerInternals
noInternals = RunnerInternals [] [] [] (\_ _ → pure ())

-- | The runner found itself in a state its own checks make impossible. It is the runner's own
-- failure, a failure of the host: it propagates after the orderly retirement, as any does.
newtype RunnerBug = RunnerBug Text
  deriving (Eq, Show)

instance Exception RunnerBug

-- | One instance the run admitted.
data Admitted = Admitted
  { admittedId ∷ !InstanceId
  , admittedTicket ∷ !InstanceTicket
  , admittedFile ∷ !Text
  , admittedName ∷ !Text
  }

-- | The sinks, each writing its lines together under one lock, so a table or a report is never cut
-- by a script's output and a sink is never called by two threads at once.
data Sinks = Sinks
  { sinkOut ∷ [Text] → IO ()
  , sinkErr ∷ [Text] → IO ()
  }

newSinks ∷ RunnerConfig → IO Sinks
newSinks config = do
  lock ← newMVar ()
  let locked sink ls = withMVar lock (\_ → mapM_ sink ls)
  pure (Sinks (locked (runnerOutput config)) (locked (runnerErrors config)))

-- Entry -----------------------------------------------------------------------------------------

-- | Run the scripts.
runWith ∷ RunnerInternals → LuaRuntime → RunnerConfig → IO RunOutcome
runWith internals runtime config =
  case NonEmpty.nonEmpty (usageViolations config) of
    Just violations → pure (Refused (UsageRefusal violations))
    Nothing → do
      stopped ← atomically (runnerStop config)
      if stopped
        then ended EndedStopRequest []
        else begin internals runtime config
  where
    ended ending reports = finished config (RunReport ending reports Nothing (runStatusOf (any failedReport reports) ending) 0 noTally)

-- | The arguments the runner can refuse without a VM: the scripts, the limits and the clock they are
-- given are checked against each other and against what a tick can be, before anything is read.
usageViolations ∷ RunnerConfig → [UsageViolation]
usageViolations config =
  [UsageViolation Nothing NoScripts | null scripts]
    <> [UsageViolation Nothing (TooManyScripts (length scripts) runnerMaxScripts) | length scripts > runnerMaxScripts]
    <> [UsageViolation Nothing LimitNotPositive | runnerLimit config == Just zeroDuration]
    <> [UsageViolation Nothing TickDurationNotPositive | runnerTick config == Just zeroDuration]
    <> [UsageViolation Nothing reason | Just count ← [runnerTickLimit config], reason ← tickCountProblems count]
    <> [UsageViolation Nothing TickLimitNeedsTickClock | isJust (runnerTickLimit config), not tickVm]
    <> concat
      [ [UsageViolation (Just (pathText item)) IntervalNotPositive | not tickVm, scriptInterval item == Just zeroDuration]
          <> [UsageViolation (Just (pathText item)) ElapsedIntervalOnTickClock | tickVm, isJust (scriptInterval item)]
          <> [UsageViolation (Just (pathText item)) TickIntervalOnElapsedClock | not tickVm, isJust (scriptTicks item)]
          <> [UsageViolation (Just (pathText item)) reason | tickVm, Just count ← [scriptTicks item], reason ← tickCountProblems count]
      | item ← scripts
      ]
  where
    scripts = runnerScripts config
    tickVm = isJust (runnerTick config)

-- | Why a number of ticks cannot be one: not positive, or not a 64-bit tick.
tickCountProblems ∷ Integer → [UsageReason]
tickCountProblems count =
  [TickCountNotPositive | count < 1] <> [TickCountTooLarge | count > toInteger (maxBound ∷ Word64)]

pathText ∷ Script → Text
pathText = bounded pathLimit . Text.pack . scriptPath

-- | The report of a run is logged once, as it is returned.
finished ∷ RunnerConfig → RunReport → IO RunOutcome
finished config report = do
  logInfo
    (withFields [("vm", runnerName config)] (runnerLogger config))
    runnerComponent
    "script run ended"
    [ ("ending", Text.pack (show (reportEnding report)))
    , ("status", Text.pack (show (reportStatus report)))
    , ("instances", Text.pack (show (length (reportInstances report))))
    ]
  pure (Ran report)

failedReport ∷ InstanceReport → Bool
failedReport report = case instanceEnd report of
  EndFailed _ → True
  _ → False

-- Starting --------------------------------------------------------------------------------------

begin ∷ RunnerInternals → LuaRuntime → RunnerConfig → IO RunOutcome
begin internals runtime config = do
  sinks ← newSinks config
  gate ← newGate
  registry ← newRegistry
  endpointVar ← newTVarIO Nothing
  controlCounter ← newTVarIO 1
  (readable, problem) ← readSources paths
  let sources = [ModuleSource (refOf path) bytes hookEntries | (path, bytes) ← readable]
      readFailure = uncurry (readFailureOf config) <$> problem
  case (sources, readFailure) of
    ([], Just failure) → startupFailure config sinks failure
    ([], Nothing) → throwIO (RunnerBug "no script was read and none failed to be")
    _ → do
      built ← either (throwIO . RunnerBug . Text.pack . show) pure (registrationFor sinks)
      let spec = specFor gate registry (assignControl endpointVar controlCounter) sources built
      withStartedOwner runtime spec (atomically (freeGate gate)) $ \case
        ScheduledUnavailable failure → sourceFault sinks failure
        ScheduledRejected → stoppedBeforeStart
        ScheduledEnded → stoppedBeforeStart
        ScheduledStarted owner → case readFailure of
          -- The modules before the file that could not be read have loaded, as the load order has
          -- it, and the VM is retired on the way out.
          Just failure → startupFailure config sinks failure
          Nothing → do
            atomically (writeTVar endpointVar (Just (scheduledEndpoint owner)))
            ran internals runtime config sinks refOf gate registry owner
  where
    scripts = runnerScripts config
    paths = distinctPaths (map scriptPath scripts)
    refOf path = moduleRefFor (fromMaybe 0 (elemIndex path paths)) path
    files = Map.fromList [(refOf path, Text.pack path) | path ← paths]
    registrationFor sinks =
      registration
        []
        ( outputNamespace (sinkOut sinks) (sinkErr sinks)
            : lifecycleNamespace runnerLifecycleName
            : internalNamespaces internals
        )
    tickVm = isJust (runnerTick config)
    specFor gate registry assign sources built =
      let vm =
            (vmConfig [LibraryBase, LibraryString, LibraryTable, LibraryMath, LibraryCoroutine])
              { vmInitialChunks = [(chunkName "runner output", outputChunk)]
              , vmOwnerName = runnerName config
              , vmRegistration = built
              , vmPolicy = [outputNamespaceName, runnerLifecycleName] <> map namespaceName (internalNamespaces internals)
              , vmModules = sources
              }
       in (scheduledSpec vm workerPolicy runnerSchedulerBounds)
            { scheduledClock = runnerClock config
            , scheduledTimer = runnerTimer config
            , scheduledObserve = gateHook gate
            , scheduledInstances =
                Just
                  InstanceConfig
                    { instanceBounds = runnerInstanceBounds
                    , instanceSources = internalSources internals
                    , instanceTickDuration = runnerTick config
                    , instanceControlAdmission = if tickVm then AdmitLogically else AdmitOnArrival
                    , instanceEscalate = \_ → pure Isolate
                    }
            , scheduledLifecycle = Just (lifecycleGrant [GrantTarget GrantedSelf [PermitInspect, PermitControl] (if tickVm then Just assign else Nothing)])
            , scheduledRequests =
                Just
                  RequestGrant
                    { grantEndpoints = [unreachableEndpoint]
                    , grantRequestBound = 1
                    , grantTiming = if tickVm then SettleAtAssignedTick Nothing else SettleOnArrival
                    }
            , scheduledSubscriptions =
                Just
                  SubscriptionGrant
                    { grantEvents = [instancesEndpoint registry]
                    , grantSubscriptionBound = runnerSubscriptionBound
                    , grantStagingBound = runnerStagingBound
                    }
            }
    -- Every Lua control a script requests on a tick VM is placed by the runner, never declined: at the first
    -- tick the owner has not begun, and a sequence of its own, unique and increasing in the order the
    -- requests are made, which is the order the owner runs the scripts that make them.
    assignControl endpointVar counter _ =
      readTVarIO endpointVar >>= \case
        Nothing → throwIO (RunnerBug "a Lua control was requested before the VM's endpoint was known")
        Just endpoint → atomically $ do
          tick ← scheduledTick endpoint
          next ← readTVar counter
          writeTVar counter (next + 1)
          pure (Just (ControlSlot (tick + 1) next))
    -- A boundary that is closing, or an owner that ended before it was ready: the run was asked to
    -- end by supervision, which is a stop.
    stoppedBeforeStart = finished config (RunReport EndedStopRequest [] Nothing StatusInterrupted 0 noTally)
    -- A source that does not load fails the VM's start: the one failure supervision lets the
    -- creation answer, as data, and only for a fault of loading a module that no application code
    -- raised. Anything else, a failure of the host, propagates unchanged.
    sourceFault sinks failure@(ExceptionWithContext _ exception)
      | isSourceFault failure, Just fault ← fromException exception = startupFailure config sinks (rejectedBy config files fault)
      | otherwise = rethrowIO failure

-- | The owner is optional, so that a source that does not load is a failure supervision commits as
-- the owner being unavailable and creation answers as such, and the classifier recognizes exactly
-- that failure. Every other failure of the owner is unrecognized, so fatal under supervision, and
-- propagates unchanged.
workerPolicy ∷ WorkerPolicy
workerPolicy =
  WorkerPolicy
    { policyRole = Service
    , policyDisposition = Optional
    , policyComponent = runnerComponent
    , policyClassifier = \failure → pure (if isSourceFault failure then Recognized else Unrecognized)
    }

-- | Whether a failure of the owner is a module that did not load: the host's fault of loading a
-- module, and not one an application's code raised, whatever its type.
isSourceFault ∷ ExceptionWithContext SomeException → Bool
isSourceFault (ExceptionWithContext context exception)
  | raisedByApplication context = False
  | Just fault ← fromException exception, LoadModule ← boundaryOperation fault = True
  | otherwise = False

-- | The report of a run that did not start because a source did not load: written to the error
-- sink, and the run's answer.
startupFailure ∷ RunnerConfig → Sinks → LoadFailure → IO RunOutcome
startupFailure config sinks failure = do
  sinkErr sinks (loadFailureLines failure)
  finished config (RunReport EndedStartupFailure [] (Just failure) StatusFailure 0 noTally)

readFailureOf ∷ RunnerConfig → FilePath → ReadProblem → LoadFailure
readFailureOf config path problem =
  LoadFailure
    { loadFile = bounded pathLimit (Text.pack path)
    , loadVm = vmText config
    , loadProblem = case problem of
        ReadMissing → LoadMissing
        ReadUnreadable _ → LoadUnreadable
        ReadTooLarge → LoadTooLarge
    , loadError = bounded errorLimit $ case problem of
        ReadMissing → "the file does not exist"
        ReadUnreadable why → "the file could not be read: " <> why
        ReadTooLarge → "the file is larger than the host's source limit"
    , loadTraceback = Nothing
    }

-- | The report of a module the host rejected: the file it was read from, as the script gave it.
rejectedBy ∷ RunnerConfig → Map ModuleRef Text → BoundaryFault → LoadFailure
rejectedBy config files fault =
  LoadFailure
    { loadFile = maybe "" (bounded pathLimit) (boundaryModule fault >>= (`Map.lookup` files))
    , loadVm = vmText config
    , loadProblem = LoadRejected
    , loadError = bounded errorLimit (reasonText (boundaryReason fault))
    , loadTraceback = boundedLines tracebackLimit <$> boundaryTraceback fault
    }
  where
    reasonText = \case
      ScriptFailed _ value → case value of
        ErrorMessage message _ → message
        ErrorOpaque kind → "an error value of type " <> kind
        ErrorAbsent → "no error value"
      ModuleRefused problem → Text.pack (show problem)
      other → Text.pack (show other)

vmText ∷ RunnerConfig → Text
vmText = bounded columnLimit . runnerName

-- | Start the owner and run a body over how it started, and retire the owner on every way out of it: the
-- body's return, a failure of the host, a failure of the runner's own thread and a cancellation.
--
-- The retirement asks the owner to stop in order, which never blocks, and then waits for the owner to
-- have ended. The wait is for the worker's raw completion (the owner's thread has finished, its VM is
-- closed and every instance settled), which supervision's latch of a failure never makes unavailable, so
-- a failure another supervised worker latched cannot make the run propagate while the owner is still
-- running: whoever the run's sinks and bindings are borrowed from cannot release them under Lua. The
-- wait is for arbitrary Lua segments and shutdown hooks, so it is interruptible and never runs under
-- an uninterruptible mask, but an interruption does not end it: each is recorded and the wait goes on
-- until the worker has actually ended ('awaitWorkerEnded'), and then what happened is raised in order,
-- a cancellation as itself and the rest beside it as evidence ('propagateAll'). The owner never outlives
-- the call, however many times the runner's thread is interrupted; a segment that never returns keeps the
-- call pending, as it keeps the worker (D-27). Creation is the same: 'startScheduledOwner' does not return
-- or raise while the worker it started is alive. The failures themselves are the body's and supervision's:
-- waiting does not raise the owner's failure again, which supervision delivers (to the next supervised
-- wait, and at the boundary's exit beside the body's own).
withStartedOwner ∷ LuaRuntime → ScheduledSpec → IO () → (ScheduledStart → IO a) → IO a
withStartedOwner runtime spec release body = mask $ \restore → do
  started ← startScheduledOwner runtime spec
  outcome ← tryWithContext @SomeException (restore (body started))
  interruptions ← case started of
    -- What holds the owner back (the gate it parks at) is let go before it is asked to stop and waited for:
    -- an owner parked at it could not end.
    ScheduledStarted owner → release >> retireScheduled owner >> awaitWorkerEnded restore (scheduledSupervised owner)
    _ → pure []
  case outcome of
    Right value → propagateAll interruptions >> pure value
    Left failure → propagateAll (failure : interruptions) >> rethrowIO failure

-- | Wait for the owner's worker to have ended, whatever supervision has latched: its raw completion.
awaitOwnerEnded ∷ ScheduledOwner → IO ()
awaitOwnerEnded owner = atomically (void (awaitCompletion (supervisedWorker (scheduledSupervised owner))))

-- | Retire the owner in order, wait for it to end and raise what supervision committed of it: the step
-- that ends a run. Asking again changes nothing and an owner that has ended is answered at once.
retireOwner ∷ LuaRuntime → ScheduledOwner → IO ()
retireOwner runtime owner = do
  retireScheduled owner
  awaitOwnerEnded owner
  void . awaitSupervised (runtimeControl runtime) $
    scheduledStatus owner >>= \case
      WorkerLive → retry
      status → pure status

-- Running ---------------------------------------------------------------------------------------

-- | What every step of the run holds.
data Env = Env
  { envRuntime ∷ LuaRuntime
  , envConfig ∷ RunnerConfig
  , envSinks ∷ Sinks
  , envOwner ∷ ScheduledOwner
  , envEndpoint ∷ ScheduledEndpoint
  , envGate ∷ Gate
  , envRegistry ∷ Registry
  , envReported ∷ TVar (Set Word64)
    -- ^ The instances whose failure has been written.
  , envEnded ∷ TVar (Set Word64)
    -- ^ The instances whose end has been taken to produce its event.
  , envCompleted ∷ TVar Word64
    -- ^ The ticks the run has seen complete: granted, finished and quiet.
  , envLimit ∷ Maybe (Timer, Instant)
  }

-- | The VM has started. Ask it what its modules define, refuse what that makes usage, and run.
ran ∷ RunnerInternals → LuaRuntime → RunnerConfig → Sinks → (FilePath → ModuleRef) → Gate → Registry → ScheduledOwner → IO RunOutcome
ran internals runtime config sinks refOf gate registry owner = do
  let endpoint = scheduledEndpoint owner
  hooks ← forM (runnerScripts config) $ \item →
    atomically (moduleHooks endpoint (refOf (scriptPath item))) >>= \case
      Just defined → pure (item, defined)
      Nothing → throwIO (RunnerBug "a module the owner loaded has no hooks")
  case NonEmpty.nonEmpty (concatMap hookViolations hooks) of
    Just violations → pure (Refused (UsageRefusal violations))
    Nothing → do
      origin ← readInstant (runnerClock config)
      withLimit config origin $ \limit → do
        reported ← newTVarIO Set.empty
        ended ← newTVarIO Set.empty
        completed ← newTVarIO 0
        let env = Env runtime config sinks owner endpoint gate registry reported ended completed limit
        (admitted, interrupted) ← admitScripts internals env refOf hooks
        logInfo
          (withFields [("vm", runnerName config)] (runnerLogger config))
          runnerComponent
          "script run started"
          [("scripts", Text.pack (show (length (runnerScripts config)))), ("instances", Text.pack (show (length admitted)))]
        ending ← case interrupted of
          Just early → pure early
          Nothing → steady env admitted
        -- What the provider counted of watchers failed at a tick is read while the owner still serves: its
        -- service answers nothing once the owner has exited.
        failedWatchers ← maybe 0 sdFailures <$> atomically (subscriptionDiagnostics endpoint)
        -- The run ends in order: every instance still unended is stopped, the VM is closed, and
        -- only then is anything read of what the instances became.
        retireOwner runtime owner
        writeFailures config sinks =<< atomically (takeFailures reported admitted)
        settlements ← atomically (traverse (settledNow . admittedTicket) admitted)
        done ← case sequence settlements of
          Just all' → pure all'
          Nothing → throwIO (RunnerBug "an instance had not settled when its owner had ended")
        sinkTable sinks endTitle (map rowOfSettlement done)
        let reports = zipWith (instanceReportOf config) admitted done
        ticks ← readTVarIO completed
        tally ← tallyOf registry
        finished config (RunReport ending reports Nothing (runStatusOf (any failedReport reports) ending) ticks tally {tallyWatchersFailed = fromIntegral failedWatchers})

-- | A script's instance name: its own, or the end of its path, tamed and bounded.
instanceNameOf ∷ Script → Text
instanceNameOf item = bounded nameLimit (fromMaybe (defaultName (scriptPath item)) (scriptName item))

-- | What follows from the entries a module defines: @run@ is a one-shot, @update@ a looped
-- instance on the script's interval (in ticks on a tick VM), neither an event-only instance.
kindOf ∷ Script → ModuleHooks → InstanceKind
kindOf item defined
  | hooksRun defined = RunOnce
  | hooksUpdate defined, Just interval ← scriptInterval item = Periodic (ElapsedEvery interval)
  | hooksUpdate defined, Just ticks ← scriptTicks item = Periodic (LogicalTicks ticks)
  | otherwise = EventOnly

-- | Why a script is refused as usage, once its module's hooks are known: one reason at most.
hookViolations ∷ (Script, ModuleHooks) → [UsageViolation]
hookViolations (item, defined)
  | hooksRun defined && hooksUpdate defined = [at ModuleDefinesRunAndUpdate]
  | hooksUpdate defined && not hasInterval = [at UpdateNeedsInterval]
  | hasInterval && not (hooksUpdate defined) = [at IntervalWithoutUpdate]
  | otherwise = []
  where
    at = UsageViolation (Just (pathText item))
    hasInterval = isJust (scriptInterval item) || isJust (scriptTicks item)

-- The limit's timer --------------------------------------------------------------------------------

-- | Run with the limit's timer, if the run has a limit that can be reached, and dispose of it on
-- every way out. The deadline is the limit after the origin: a limit that does not fit the clock's
-- range can never be reached, and the run has no timer.
withLimit ∷ RunnerConfig → Instant → (Maybe (Timer, Instant) → IO a) → IO a
withLimit config origin body = case runnerLimit config of
  Nothing → body Nothing
  Just limit → case addDuration origin limit of
    Left _ → body Nothing
    Right deadline → withResource (newTimer (runnerTimer config)) disposeTimer (\timer → body (Just (timer, deadline)))

-- Admission ---------------------------------------------------------------------------------------

-- | What one wait for an instance's @init@ answers.
data Initialized
  = -- | @init@ is finished or the instance is terminal: whether it succeeded, and, for the last
    -- script, the rows of the start table.
    InitDone Bool [TableRow]
  | -- | The owner was parked at the gate before the instance's @init@ could run: it was let through
    -- one segment, and the wait goes on.
    Permitted

-- | Admit the scripts one at a time, in order, each after the previous instance has finished its
-- @init@ and the owner has nothing left to do. Answers the instances admitted, in script order, and
-- why admission was cut short, if it was.
--
-- Every instance is admitted with the owner's gate held, so that the owner cannot run the one-shot's
-- @run@ (or anything else the new instance makes ready) until the instance's /started/ event has been
-- produced to the subscriptions that exist at that moment.
admitScripts ∷ RunnerInternals → Env → (FilePath → ModuleRef) → [(Script, ModuleHooks)] → IO ([Admitted], Maybe RunEnding)
admitScripts internals env refOf hooks = do
  known ← newIORef []
  told ← newIORef False
  -- The seam is told once, with the instances admitted, as soon as the last is, or as admission ends
  -- however it ends: a host failure included, because an example that reaches the endpoint after one
  -- must find it.
  let tellOnce admitted = do
        already ← atomicModifyIORef' told (\held → (True, held))
        unless already (internalAdmitted internals endpoint [(admittedId item, admittedTicket item) | item ← admitted])
  (admitted, interrupted) ← go known tellOnce [] hooks `onException` (readIORef known >>= tellOnce)
  tellOnce admitted
  pure (admitted, interrupted)
  where
    endpoint = envEndpoint env
    go _ _ soFar [] = pure (soFar, Nothing)
    go known tell soFar ((item, defined) : rest) = do
      -- The owner is quiet before anything is admitted: nothing the previous instance made ready
      -- is left to run.
      awaiting env (admitting False) soFar (quietNow env) >>= \case
        Left ending → pure (soFar, Just ending)
        Right () → do
          atomically (holdGate (envGate env))
          step ← admitOne known tell soFar item defined (null rest) `finally` atomically (freeGate (envGate env))
          case step of
            Admission now rows Nothing
              | null rest → do
                  sinkTable (envSinks env) startTitle rows
                  awaiting env (admitting True) now (quietNow env) >>= \case
                    Left ending → pure (now, Just ending)
                    Right () → do
                      pending ← atomically (takeEnded env now)
                      produce (map endedEvent pending)
                      pure (now, Nothing)
              | otherwise → go known tell now rest
            Admission now _ interrupted → pure (now, interrupted)
    admitOne known tell soFar item defined isLast =
      admitInstance endpoint (requestFor item defined) >>= \case
        InstanceAccepted identity ticket → do
          let new = Admitted identity ticket (bounded pathLimit (Text.pack (scriptPath item))) (instanceNameOf item)
              now = soFar <> [new]
          writeIORef known now
          when isLast (tell now)
          waited ← awaitInit now new isLast
          case waited of
            Left ending → pure (Admission now [] (Just ending))
            Right (started, rows) → do
              when started (produce [startedEvent new])
              pure (Admission now rows Nothing)
        -- The owner stopped admitting: supervision is closing. What was admitted is the run.
        InstanceAdmissionClosed → pure (Admission soFar [] Nothing)
        InstanceFull → throwIO (RunnerBug "admission was full for a run that holds at most the live bound")
        InstanceIntervalRefused why → throwIO (RunnerBug ("an interval the runner checked was refused: " <> Text.pack (show why)))
    awaitInit now new isLast =
      awaiting env (admitting False) {modeProgressFirst = True} now (initProgress env now new isLast) >>= \case
        Left ending → pure (Left ending)
        Right Permitted → awaitInit now new isLast
        Right (InitDone started rows) → pure (Right (started, rows))
    requestFor item defined =
      InstanceRequest
        { instanceModule = refOf (scriptPath item)
        , instanceKind = kindOf item defined
        , instanceName = Just (instanceNameOf item)
        , instanceClass = OrdinaryClass
        , instanceGrants = runnerEventsName : internalGrants internals
        }
    produce events = do
      place ← placeNow env
      produceEvents (envRegistry env) place events
    -- Every instance having ended ends the run only once the last script is admitted.
    admitting complete = Mode {modeComplete = complete, modeEnded = False, modeTickLimit = False, modeDrain = False, modeProgressFirst = False}

-- | One instance's admission: the instances admitted so far with it, the rows of the start table, and
-- why the run ended meanwhile.
data Admission = Admission [Admitted] [TableRow] (Maybe RunEnding)

-- | Whether an instance's @init@ is finished (or it is terminal) and the owner is still: parked at the
-- gate, before the segment it was about to run, or quiet. If the owner is parked before the instance's
-- @init@ could be served, it is let through one segment.
initProgress ∷ Env → [Admitted] → Admitted → Bool → STM (Maybe Initialized)
initProgress env admitted item isLast = do
  settled ← settledNow (admittedTicket item)
  snapshots ← inspectInstances (envEndpoint env)
  parked ← gateParked (envGate env)
  let initDone = isJust settled || maybe False (\snapshot → snapshotPhase snapshot `notElem` [Initializing, Stopping]) (lookupSnapshot (admittedId item) snapshots)
      initialized = maybe True (\settlement → terminationShutdown (resultTermination settlement) /= ShutdownSkippedNoInit) settled
  if initDone && (parked || quiet (isTick env) snapshots)
    then do
      rows ←
        if isLast
          then barrierRows (envEndpoint env) admitted >>= maybe (throwSTM (RunnerBug "an instance admitted before the last had not left its initialization")) pure
          else pure []
      pure (Just (InitDone initialized rows))
    else
      if parked && not initDone
        then (\granted → if granted then Just Permitted else Nothing) <$> permitOne (envGate env)
        else pure Nothing

-- | The owner has nothing it must do before it idles.
quietNow ∷ Env → STM (Maybe ())
quietNow env = do
  snapshots ← inspectInstances (envEndpoint env)
  pure (if quiet (isTick env) snapshots then Just () else Nothing)

-- | Whether the VM is on logical ticks.
isTick ∷ Env → Bool
isTick = isJust . runnerTick . envConfig

-- Events ------------------------------------------------------------------------------------------

startedEvent ∷ Admitted → InstanceEvent
startedEvent item = InstanceEvent True (admittedId item) (Just (admittedName item)) Nothing

endedEvent ∷ (Admitted, InstanceSettlement) → InstanceEvent
endedEvent (item, settlement) =
  InstanceEvent False (admittedId item) (resultName settlement) (Just outcome)
  where
    outcome = case resultOutcome settlement of
      InstanceCompleted → "completed"
      InstanceFailed _ → "failed"
      InstanceStopped → "stopped"
      InstanceDiscarded _ → "stopped"

-- | Where the next deliveries go: on arrival on an elapsed VM, at the first tick the owner has not begun
-- on a tick VM.
placeNow ∷ Env → IO Place
placeNow env = case runnerTick (envConfig env) of
  Nothing → pure (PlaceAt Nothing)
  Just _ → PlaceAt . Just . (+ 1) <$> atomically (scheduledTick (envEndpoint env))

-- | The instances that have settled and whose end has not been taken, and whoever takes them has them,
-- in ascending instance number.
takeEnded ∷ Env → [Admitted] → STM [(Admitted, InstanceSettlement)]
takeEnded env admitted = do
  done ← readTVar (envEnded env)
  found ← forM admitted $ \item →
    if Set.member (instanceLocal (admittedId item)) done
      then pure Nothing
      else fmap (\settlement → (item, settlement)) <$> settledNow (admittedTicket item)
  let fresh = catMaybes found
  if null fresh
    then pure []
    else writeTVar (envEnded env) (Set.union done (Set.fromList [instanceLocal (admittedId item) | (item, _) ← fresh])) >> pure fresh

-- The wait ----------------------------------------------------------------------------------------

-- | What the common wait watches for, beyond what a phase waits on.
data Mode = Mode
  { modeComplete ∷ Bool
    -- ^ Every script is admitted, so every instance having ended ends the run.
  , modeEnded ∷ Bool
    -- ^ An instance that settles has its end produced as it is seen (an elapsed VM's ordinary run).
  , modeTickLimit ∷ Bool
    -- ^ The tick limit, once it is reached, ends the run: between ticks, not during one.
  , modeDrain ∷ Bool
    -- ^ Every instance having ended does not end the run yet, and nor does anything that ranks below it: a
    -- tick is waited out to its completion, and the run ends at the boundary after it, as every
    -- instance having ended.
  , modeProgressFirst ∷ Bool
    -- ^ What the phase waits for outranks every ending, so that what is already done is taken before the
    -- run ends: the finished @init@ of an instance, whose /started/ event and start table are owed.
  }

-- | What woke the run.
data Step a
  = -- | Failures settled and not yet written.
    StepReports [(Admitted, InstanceSettlement)]
  | -- | Ends to produce.
    StepEnded [(Admitted, InstanceSettlement)]
  | StepEnd RunEnding
  | -- | The duration limit's timer fired: look at the clock.
    StepLimitTimer
  | StepDone a

-- | The one wait of the run, composed in STM with supervision. It writes what is owed on the way (the
-- failures as they settle, the ends an elapsed VM produces as they are seen) and answers how the run
-- ended, or what the phase it is in was waiting for.
--
-- The order of precedence is the contract: a failure to report, an end to produce, every instance
-- ended, the stop request, the tick limit, the duration limit, and then what the phase waits for.
awaiting ∷ Env → Mode → [Admitted] → STM (Maybe a) → IO (Either RunEnding a)
awaiting env mode admitted progress = loop
  where
    config = envConfig env
    loop = do
      forM_ (envLimit env) $ \(timer, deadline) → syncTimer timer (runnerClock config) (Just deadline)
      step ← awaitSupervised (runtimeControl (envRuntime env)) stepNow
      case step of
        StepReports failures → writeFailures config (envSinks env) failures >> loop
        StepEnded settled → do
          place ← placeNow env
          produceEvents (envRegistry env) place (map endedEvent settled)
          loop
        StepEnd ending → pure (Left ending)
        StepLimitTimer → do
          now ← readInstant (runnerClock config)
          if any (deadlineReached now . snd) (envLimit env) then pure (Left EndedLimit) else loop
        StepDone value → pure (Right value)
    stepNow = do
      failures ← takeFailures (envReported env) admitted
      settled ← if null failures && modeEnded mode then takeEnded env admitted else pure []
      -- The phase's own progress is read for what outranks the endings only where reading it changes
      -- nothing: a finished @init@ (it permits a segment, and that is the answer) and a tick that has finished.
      early ← if null failures && null settled && modeProgressFirst mode then progress else pure Nothing
      everyone ← if modeComplete mode then allSettled admitted else pure False
      stop ← runnerStop config
      reached ← if modeTickLimit mode then tickLimitReached else pure False
      woke ← maybe (pure False) (timerWoken . fst) (envLimit env)
      finishing ← if modeDrain mode && not stop && not everyone then progress else pure Nothing
      -- The first that applies is the answer: the order is the contract.
      case concat
        [ [pure (StepReports failures) | not (null failures)]
        , [pure (StepEnded settled) | not (null settled)]
        , [pure (StepDone value) | Just value ← [early]]
        , [orRetry | everyone, modeDrain mode]
        , [pure (StepEnd EndedAllInstances) | everyone]
        , [pure (StepEnd EndedStopRequest) | stop]
        , [pure (StepDone value) | Just value ← [finishing]]
        , [pure (StepEnd EndedTickLimit) | reached]
        , [forM_ (envLimit env) (clearTimerWake . fst) >> pure StepLimitTimer | woke]
        , [orRetry | not (modeProgressFirst mode)]
        ] of
        action : _ → action
        [] → retry
      where
        orRetry = maybe retry (pure . StepDone) =<< progress
    tickLimitReached = case runnerTickLimit config of
      Nothing → pure False
      Just limit → (\done → toInteger done >= limit) <$> readTVar (envCompleted env)

-- Running on --------------------------------------------------------------------------------------

-- | The run after admission: wait for it to end, producing and writing what is owed on the way.
steady ∷ Env → [Admitted] → IO RunEnding
steady env admitted = case runnerTick (envConfig env) of
  Nothing → repeatUntilEnded (awaiting env running admitted (pure Nothing))
  Just tick → withResource (newTimer (runnerTimer (envConfig env))) disposeTimer (\timer → ticking env admitted tick timer)
  where
    running = Mode {modeComplete = True, modeEnded = True, modeTickLimit = False, modeDrain = False, modeProgressFirst = False}
    repeatUntilEnded wait = wait >>= either pure (\() → repeatUntilEnded wait)

-- | What waiting for a grant to finish answers.
data Finished = Finished | OwnerGone

-- | The tick driver: grant one tick of exactly the tick duration whenever one is due, wait for it to
-- finish, then, at the boundary, produce the ends it saw, for the next tick.
--
-- Tick /n/ is due at the origin plus /n/ ticks of real time. A late tick is granted at once, one grant
-- each, none skipped, merged or shortened. A timer wake is a notification only: the clock is read.
ticking ∷ Env → [Admitted] → Duration → Timer → IO RunEnding
ticking env admitted tick timer = do
  origin ← readInstant clock
  boundary >>= \case
    Just ending → pure ending
    Nothing → go (next (Just origin)) (1 ∷ Word64)
  where
    clock = runnerClock (envConfig env)
    -- Between ticks: nothing is running, and the ends the last tick saw are produced for the next.
    boundary =
      awaiting env between admitted (Just <$> takeEnded env admitted) >>= \case
        Left ending → pure (Just ending)
        Right settled → do
          place ← placeNow env
          produceEvents (envRegistry env) place (map endedEvent settled)
          pure Nothing
    between = Mode {modeComplete = True, modeEnded = False, modeTickLimit = True, modeDrain = False, modeProgressFirst = False}
    during = Mode {modeComplete = True, modeEnded = False, modeTickLimit = False, modeDrain = True, modeProgressFirst = False}
    -- When the tick after one due at this instant is due, if that fits the clock's range, and
    -- never otherwise.
    next = \case
      Just due → either (const Nothing) Just (addDuration due tick)
      Nothing → Nothing
    -- The deadline of tick @number@, and the number of the tick to be granted.
    go due number = do
      now ← readInstant clock
      if maybe False (deadlineReached now) due
        then
          -- Already due, and so late: granted at once, after what ranks above a tick is looked at, with no
          -- wait on a timer.
          awaiting env between admitted (pure (Just ())) >>= \case
            Left ending → pure ending
            Right () → grant due number
        else do
          syncTimer timer clock due
          awaiting env between admitted woken >>= \case
            Left ending → pure ending
            Right () → go due number
    woken = do
      fired ← timerWoken timer
      if fired then clearTimerWake timer >> pure (Just ()) else pure Nothing
    grant due number =
      grantScheduledStep (envEndpoint env) tick >>= \case
        GrantAccepted _ →
          awaiting env during admitted (finishedGrant env (envEndpoint env)) >>= \case
            Left ending → pure ending
            Right OwnerGone → pure EndedStopRequest
            Right Finished → do
              atomically (modifyTVar' (envCompleted env) (+ 1))
              boundary >>= \case
                Just ending → pure ending
                Nothing → go (next due) (number + 1)
        -- The bound on outstanding grants is reached: wait for them to finish and ask again.
        GrantFull →
          awaiting env during admitted (finishedGrant env (envEndpoint env)) >>= \case
            Left ending → pure ending
            Right OwnerGone → pure EndedStopRequest
            Right Finished → grant due number
        -- The owner is stopping: the run ends through its ordinary path.
        GrantClosed → pure EndedStopRequest
        GrantNotPositive → throwIO (RunnerBug "a tick duration the runner checked was not positive")

-- | Every grant has finished and the owner is quiet, or the owner has exited.
finishedGrant ∷ Env → ScheduledEndpoint → STM (Maybe Finished)
finishedGrant env endpoint = do
  outstanding ← ticksOutstanding endpoint
  snapshots ← inspectInstances endpoint
  status ← scheduledStatus (envOwner env)
  pure $ case status of
    WorkerLive
      | outstanding == 0 && quiet (isTick env) snapshots → Just Finished
      | otherwise → Nothing
    _ → Just OwnerGone

-- | An instance's settlement if it has one. Read from the instance's cell and not observed, so the
-- instance stays in the owner's inspection until the owner exits.
settledNow ∷ InstanceTicket → STM (Maybe InstanceSettlement)
settledNow = readTVar . icResult . ticketCell

allSettled ∷ [Admitted] → STM Bool
allSettled admitted = and <$> forM admitted (fmap isJust . settledNow . admittedTicket)

-- | The failures that have settled and have not been written, and whoever takes them has them: they
-- are marked written in the transaction that returns them. In ascending instance number.
takeFailures ∷ TVar (Set Word64) → [Admitted] → STM [(Admitted, InstanceSettlement)]
takeFailures reported admitted = do
  done ← readTVar reported
  found ← forM admitted $ \item →
    if Set.member (instanceLocal (admittedId item)) done
      then pure Nothing
      else
        settledNow (admittedTicket item) >>= \case
          Just settlement | InstanceFailed _ ← resultOutcome settlement → pure (Just (item, settlement))
          _ → pure Nothing
  let fresh = catMaybes found
  if null fresh
    then pure []
    else writeTVar reported (Set.union done (Set.fromList [instanceLocal (admittedId item) | (item, _) ← fresh])) >> pure fresh

-- | The rows of the start table, when every admitted instance has left its initialization or has
-- ended without it: one coherent read of the owner's instances. Each instance is a row, whether it
-- is still live or has settled by now.
barrierRows ∷ ScheduledEndpoint → [Admitted] → STM (Maybe [TableRow])
barrierRows _ [] = pure (Just [])
barrierRows endpoint admitted = do
  snapshots ← inspectInstances endpoint
  rows ← forM admitted $ \item → do
    settled ← settledNow (admittedTicket item)
    pure $ case settled of
      Just settlement → Just (rowOfSettlement settlement)
      Nothing
        | Just snapshot ← lookupSnapshot (admittedId item) snapshots, snapshotPhase snapshot /= Initializing → Just (rowOfSnapshot snapshot)
        | otherwise → Nothing
  pure (sequence rows)

lookupSnapshot ∷ InstanceId → [InstanceSnapshot] → Maybe InstanceSnapshot
lookupSnapshot identity snapshots = case [snapshot | snapshot ← snapshots, snapshotInstance snapshot == identity] of
  snapshot : _ → Just snapshot
  [] → Nothing

rowOfSnapshot ∷ InstanceSnapshot → TableRow
rowOfSnapshot snapshot =
  TableRow (tidText (snapshotInstance snapshot)) (snapshotOwner snapshot) (fromMaybe "" (snapshotName snapshot)) (phaseWord (snapshotPhase snapshot))

rowOfSettlement ∷ InstanceSettlement → TableRow
rowOfSettlement settlement =
  TableRow (tidText (resultInstance settlement)) (resultOwner settlement) (fromMaybe "" (resultName settlement)) (phaseWord (resultPhase settlement))

-- Writing ------------------------------------------------------------------------------------------

-- | Write a table, if there is a row: a run that admitted no instance writes none.
sinkTable ∷ Sinks → Text → [TableRow] → IO ()
sinkTable _ _ [] = pure ()
sinkTable sinks title rows = sinkOut sinks (title : tableLines rows)

-- | Write the failures, to the error sink, in the order given, each as one report.
writeFailures ∷ RunnerConfig → Sinks → [(Admitted, InstanceSettlement)] → IO ()
writeFailures config sinks failures =
  forM_ failures $ \(item, settlement) → case resultOutcome settlement of
    InstanceFailed failure → sinkErr sinks (failureLines (failureReport (runnerName config) (admittedFile item) failure))
    _ → pure ()

-- | An instance's report: its settlement, bounded.
instanceReportOf ∷ RunnerConfig → Admitted → InstanceSettlement → InstanceReport
instanceReportOf config item settlement =
  InstanceReport
    { instanceTid = resultInstance settlement
    , instanceNameText = bounded nameLimit (fromMaybe "" (resultName settlement))
    , instanceFile = admittedFile item
    , instanceStatus = resultPhase settlement
    , instanceEnd = case resultOutcome settlement of
        InstanceCompleted → EndCompleted
        InstanceStopped → EndStopped
        InstanceFailed failure → EndFailed (failureReport (runnerName config) (admittedFile item) failure)
        InstanceDiscarded discarded → EndDiscarded discarded
    , instanceShutdown = terminationShutdown (resultTermination settlement)
    }
