-- | The run itself: reading the scripts, starting the VM, admitting the instances, waiting for the
-- run to end, ending it in order and answering.
--
-- "Hetoimasia.Scripting.Lua.Runner" documents the behavior; this module is where it is done. The
-- shape of it is a few single places every path goes through:
--
-- * one wait ('awaitWake'), composed in STM with supervision, which is the only place the run
--   waits: it sees a failure to report, the start-table barrier, every instance having ended, the
--   stop request and the timer's wake, in that order of precedence;
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
import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, retry, writeTVar)
import Control.Exception (Exception, ExceptionWithContext (ExceptionWithContext), SomeException, fromException, mask, rethrowIO, throwIO, tryWithContext)
import Control.Monad (forM, forM_, void)
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
import Hetoimasia.Foundation.Time (Instant, addDuration, deadlineReached, readInstant, zeroDuration)
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
  , Interval (ElapsedEvery)
  , admitInstance
  , hookEntries
  , inspectInstances
  , moduleHooks
  )
import Hetoimasia.Scripting.Lua.Instance.Types
  ( ControlAdmission (AdmitOnArrival)
  , Escalation (Isolate)
  , ICell (icResult)
  , InstanceConfig (..)
  , InstanceId (..)
  , InstanceKind (EventOnly, Periodic, RunOnce)
  , InstanceOutcome (InstanceCompleted, InstanceDiscarded, InstanceFailed, InstanceStopped)
  , InstancePhase (Initializing)
  , InstanceSettlement (..)
  , InstanceSnapshot (..)
  , InstanceTicket (..)
  , ModuleHooks (..)
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
  , scheduledEndpoint
  , scheduledSpec
  , scheduledStatus
  , scheduledSupervised
  , startScheduledOwner
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
    ended ending reports = finished config (RunReport ending reports Nothing (runStatusOf (any failedReport reports) ending))

-- | The arguments the runner can refuse without a VM.
usageViolations ∷ RunnerConfig → [UsageViolation]
usageViolations config =
  [UsageViolation Nothing NoScripts | null scripts]
    <> [UsageViolation Nothing (TooManyScripts (length scripts) runnerMaxScripts) | length scripts > runnerMaxScripts]
    <> [UsageViolation Nothing LimitNotPositive | runnerLimit config == Just zeroDuration]
    <> [UsageViolation (Just (pathText item)) IntervalNotPositive | item ← scripts, scriptInterval item == Just zeroDuration]
  where
    scripts = runnerScripts config

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
  (readable, problem) ← readSources paths
  let sources = [ModuleSource (refOf path) bytes hookEntries | (path, bytes) ← readable]
      readFailure = uncurry (readFailureOf config) <$> problem
  case (sources, readFailure) of
    ([], Just failure) → startupFailure config sinks failure
    ([], Nothing) → throwIO (RunnerBug "no script was read and none failed to be")
    _ → do
      built ← either (throwIO . RunnerBug . Text.pack . show) pure (registrationFor sinks)
      let spec = specFor sources built
      withStartedOwner runtime spec $ \case
        ScheduledUnavailable failure → sourceFault sinks failure
        ScheduledRejected → stoppedBeforeStart
        ScheduledEnded → stoppedBeforeStart
        ScheduledStarted owner → case readFailure of
          -- The modules before the file that could not be read have loaded, as the load order has
          -- it, and the VM is retired on the way out.
          Just failure → startupFailure config sinks failure
          Nothing → ran internals runtime config sinks refOf owner
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
    specFor sources built =
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
            , scheduledInstances =
                Just
                  InstanceConfig
                    { instanceBounds = runnerInstanceBounds
                    , instanceSources = internalSources internals
                    , instanceTickDuration = Nothing
                    , instanceControlAdmission = AdmitOnArrival
                    , instanceEscalate = \_ → pure Isolate
                    }
            , scheduledLifecycle = Just (lifecycleGrant [GrantTarget GrantedSelf [PermitInspect, PermitControl] Nothing])
            }
    -- A boundary that is closing, or an owner that ended before it was ready: the run was asked to
    -- end by supervision, which is a stop.
    stoppedBeforeStart = finished config (RunReport EndedStopRequest [] Nothing StatusInterrupted)
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
  finished config (RunReport EndedStartupFailure [] (Just failure) StatusFailure)

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
withStartedOwner ∷ LuaRuntime → ScheduledSpec → (ScheduledStart → IO a) → IO a
withStartedOwner runtime spec body = mask $ \restore → do
  started ← startScheduledOwner runtime spec
  outcome ← tryWithContext @SomeException (restore (body started))
  interruptions ← case started of
    ScheduledStarted owner → retireScheduled owner >> awaitWorkerEnded restore (scheduledSupervised owner)
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

-- | The VM has started. Ask it what its modules define, refuse what that makes usage, and run.
ran ∷ RunnerInternals → LuaRuntime → RunnerConfig → Sinks → (FilePath → ModuleRef) → ScheduledOwner → IO RunOutcome
ran internals runtime config sinks refOf owner = do
  let endpoint = scheduledEndpoint owner
  hooks ← forM (runnerScripts config) $ \item →
    atomically (moduleHooks endpoint (refOf (scriptPath item))) >>= \case
      Just defined → pure (item, defined)
      Nothing → throwIO (RunnerBug "a module the owner loaded has no hooks")
  case NonEmpty.nonEmpty (concatMap hookViolations hooks) of
    Just violations → pure (Refused (UsageRefusal violations))
    Nothing → do
      origin ← readInstant (runnerClock config)
      admitted ← admitAll endpoint hooks
      internalAdmitted internals endpoint [(admittedId item, admittedTicket item) | item ← admitted]
      logInfo
        (withFields [("vm", runnerName config)] (runnerLogger config))
        runnerComponent
        "script run started"
        [("scripts", Text.pack (show (length (runnerScripts config)))), ("instances", Text.pack (show (length admitted)))]
      withLimit config origin $ \limit → do
        reported ← newTVarIO Set.empty
        ending ← waitForEnd runtime config sinks endpoint admitted reported limit
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
        finished config (RunReport ending reports Nothing (runStatusOf (any failedReport reports) ending))
  where
    admitAll endpoint hooks = go [] hooks
      where
        go done [] = pure (reverse done)
        go done ((item, defined) : rest) =
          admitInstance endpoint (requestFor item defined) >>= \case
            InstanceAccepted identity ticket → go (Admitted identity ticket (bounded pathLimit (Text.pack (scriptPath item))) : done) rest
            -- The owner stopped admitting: supervision is closing. What was admitted is the run.
            InstanceAdmissionClosed → pure (reverse done)
            InstanceFull → throwIO (RunnerBug "admission was full for a run that holds at most the live bound")
            InstanceIntervalRefused why → throwIO (RunnerBug ("an interval the runner checked was refused: " <> Text.pack (show why)))
    requestFor item defined =
      InstanceRequest
        { instanceModule = refOf (scriptPath item)
        , instanceKind = kindOf item defined
        , instanceName = Just (instanceNameOf item)
        , instanceClass = OrdinaryClass
        , instanceGrants = internalGrants internals
        }

-- | A script's instance name: its own, or the end of its path, tamed and bounded.
instanceNameOf ∷ Script → Text
instanceNameOf item = bounded nameLimit (fromMaybe (defaultName (scriptPath item)) (scriptName item))

-- | What follows from the entries a module defines: @run@ is a one-shot, @update@ a looped
-- instance on the script's interval, neither an event-only instance.
kindOf ∷ Script → ModuleHooks → InstanceKind
kindOf item defined
  | hooksRun defined = RunOnce
  | hooksUpdate defined, Just interval ← scriptInterval item = Periodic (ElapsedEvery interval)
  | otherwise = EventOnly

-- | Why a script is refused as usage, once its module's hooks are known: one reason at most.
hookViolations ∷ (Script, ModuleHooks) → [UsageViolation]
hookViolations (item, defined)
  | hooksRun defined && hooksUpdate defined = [at ModuleDefinesRunAndUpdate]
  | hooksUpdate defined && not (isJust (scriptInterval item)) = [at UpdateNeedsInterval]
  | isJust (scriptInterval item) && not (hooksUpdate defined) = [at IntervalWithoutUpdate]
  | otherwise = []
  where
    at = UsageViolation (Just (pathText item))

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

-- The wait ----------------------------------------------------------------------------------------

-- | What woke the run.
data Wake
  = -- | Failures settled and not yet written.
    WakeReports [(Admitted, InstanceSettlement)]
  | -- | Every instance has left its initialization or ended: the rows of the start table.
    WakeBarrier [TableRow]
  | WakeEnd RunEnding
  | -- | The timer fired: look at the clock.
    WakeTimer

-- | Wait for the run to end, writing what is owed on the way: the failures as they settle, and the
-- start table when every instance has left its initialization. Answers how the run ended.
waitForEnd ∷ LuaRuntime → RunnerConfig → Sinks → ScheduledEndpoint → [Admitted] → TVar (Set Word64) → Maybe (Timer, Instant) → IO RunEnding
waitForEnd runtime config sinks endpoint admitted reported limit = loop True
  where
    loop pendingStart = do
      forM_ limit $ \(timer, deadline) → syncTimer timer (runnerClock config) (Just deadline)
      wake ← awaitSupervised (runtimeControl runtime) (awaitWake pendingStart)
      case wake of
        WakeReports failures → writeFailures config sinks failures >> loop pendingStart
        WakeBarrier rows → sinkTable sinks startTitle rows >> loop False
        WakeEnd ending → pure ending
        WakeTimer → do
          now ← readInstant (runnerClock config)
          if any (deadlineReached now . snd) limit then pure EndedLimit else loop pendingStart
    -- The order of precedence is the contract: a failure to report, the start table, every
    -- instance ended, the stop request, then the limit.
    awaitWake pendingStart = do
      failures ← takeFailures reported admitted
      if not (null failures)
        then pure (WakeReports failures)
        else do
          barrier ← if pendingStart then barrierRows endpoint admitted else pure Nothing
          case barrier of
            Just rows → pure (WakeBarrier rows)
            Nothing → do
              everyone ← allSettled admitted
              stop ← runnerStop config
              woke ← maybe (pure False) (timerWoken . fst) limit
              if everyone
                then pure (WakeEnd EndedAllInstances)
                else
                  if stop
                    then pure (WakeEnd EndedStopRequest)
                    else
                      if woke
                        then forM_ limit (clearTimerWake . fst) >> pure WakeTimer
                        else retry

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
